import Foundation

struct RestoreMarker: Codable, Equatable {
    static let schema = 1

    let schema: Int
    let recoveryRequired: Bool
    let safetyBackupPath: String?
    let lastFailureState: String?

    init(recoveryRequired: Bool, safetyBackupPath: String?, lastFailureState: String?) {
        self.schema = Self.schema
        self.recoveryRequired = recoveryRequired
        self.safetyBackupPath = safetyBackupPath
        self.lastFailureState = lastFailureState
    }

    private enum CodingKeys: String, CodingKey {
        case lastFailureState
        case recoveryRequired
        case safetyBackupPath
        case schema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.schema else { throw BackupEnvelopeError.invalidManifest }
        self.schema = schema
        self.recoveryRequired = try container.decode(Bool.self, forKey: .recoveryRequired)
        self.safetyBackupPath = try container.decodeIfPresent(String.self, forKey: .safetyBackupPath)
        self.lastFailureState = try container.decodeIfPresent(String.self, forKey: .lastFailureState)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastFailureState, forKey: .lastFailureState)
        try container.encode(recoveryRequired, forKey: .recoveryRequired)
        try container.encodeIfPresent(safetyBackupPath, forKey: .safetyBackupPath)
        try container.encode(schema, forKey: .schema)
    }
}

protocol RestoreMarkerStore: AnyObject {
    func read() throws -> RestoreMarker?
    func write(_ marker: RestoreMarker, fallbackDirectory: URL?) throws
}

final class LocalRestoreMarkerStore: RestoreMarkerStore {
    let fileSystem: BackupFileSystem

    init(fileSystem: BackupFileSystem) {
        self.fileSystem = fileSystem
    }

    var markerURL: URL {
        fileSystem.rootURL.appendingPathComponent("restore-state.json")
    }

    func read() throws -> RestoreMarker? {
        let rootMarker = try readMarkerIfPresent(at: markerURL)
        if rootMarker?.recoveryRequired == true { return rootMarker }

        let safetyRoot = BackupManagedPaths.safetyRoot(for: fileSystem)
        let safetyRootWasPresent = fileSystem.fileExists(at: safetyRoot)
        let directories: [URL]
        do {
            directories = try fileSystem.contentsOfDirectory(at: safetyRoot)
        } catch {
            guard !safetyRootWasPresent, isMissingFile(error) else { throw error }
            return rootMarker
        }
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let fallbackURL = directory.appendingPathComponent("recovery-state.json")
            if let marker = try readMarkerIfPresent(at: fallbackURL), marker.recoveryRequired {
                return marker
            }
        }
        return rootMarker
    }

    private func readMarkerIfPresent(at url: URL) throws -> RestoreMarker? {
        let wasPresent = fileSystem.fileExists(at: url)
        let data: Data
        do {
            // fileExists alone cannot distinguish absence from denied access.
            data = try fileSystem.readData(at: url)
        } catch {
            guard !wasPresent, isMissingFile(error) else { throw error }
            return nil
        }
        return try decode(data)
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }

    func write(_ marker: RestoreMarker, fallbackDirectory: URL?) throws {
        let data = try BackupCanonicalJSON.encode(marker)
        do {
            try writeAtomically(data, to: markerURL)
            if !marker.recoveryRequired {
                clearResolvedFallbackMarkers()
            }
        } catch {
            if let fallbackDirectory {
                try? writeAtomically(data, to: fallbackDirectory.appendingPathComponent("recovery-state.json"))
            }
            throw error
        }
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
        try fileSystem.createDirectory(at: destinationURL.deletingLastPathComponent())
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileSystem.removeItem(at: temporaryURL) }
        try fileSystem.writeAndFlush(data, to: temporaryURL)
        let readBack = try fileSystem.readData(at: temporaryURL)
        guard readBack == data, let decoded = try? decode(readBack), decoded.schema == RestoreMarker.schema else {
            throw BackupEnvelopeError.footerHashMismatch
        }
        // Never delete first: an interrupted update must leave the previous marker readable.
        try fileSystem.replaceItem(at: destinationURL, withItemAt: temporaryURL)
    }

    private func decode(_ data: Data) throws -> RestoreMarker {
        try JSONDecoder().decode(RestoreMarker.self, from: data)
    }

    private func clearResolvedFallbackMarkers() {
        let safetyRoot = BackupManagedPaths.safetyRoot(for: fileSystem)
        guard let directories = try? fileSystem.contentsOfDirectory(at: safetyRoot) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix("safety-") {
            let fallbackURL = directory.appendingPathComponent("recovery-state.json")
            guard fileSystem.fileExists(at: fallbackURL),
                  let data = try? fileSystem.readData(at: fallbackURL),
                  let marker = try? decode(data),
                  marker.recoveryRequired else {
                continue
            }
            try? fileSystem.removeItem(at: fallbackURL)
        }
    }
}
