import Foundation
import PencilKit
import SwiftData
import UIKit

protocol BackupFileSystem: NoteFileSystem {}

extension LocalNoteFileSystem: BackupFileSystem {}

protocol BackupClock {
    var now: Date { get }
}

struct SystemBackupClock: BackupClock {
    var now: Date { .now }
}

struct FixedBackupClock: BackupClock {
    let now: Date
}

protocol BackupUUIDSource {
    func makeUUID() -> UUID
}

struct SystemBackupUUIDSource: BackupUUIDSource {
    func makeUUID() -> UUID { UUID() }
}

enum BackupProviderError: Error, Equatable, LocalizedError {
    case sourceMissing
    case destinationMissing
    case destinationAlreadyExists
    case cancelled
    case partialCopy
    case writeFailed
    case sizeMismatch
    case hashMismatch
    case importedFileUnreadable

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "Backup source is missing."
        case .destinationMissing: return "Backup destination is missing."
        case .destinationAlreadyExists: return "Backup destination already exists."
        case .cancelled: return "Backup export was cancelled."
        case .partialCopy: return "Backup provider copied only part of the file."
        case .writeFailed: return "Backup provider failed to write the file."
        case .sizeMismatch: return "Backup provider output size does not match."
        case .hashMismatch: return "Backup provider output hash does not match."
        case .importedFileUnreadable: return "Imported backup file could not be read."
        }
    }
}

protocol DocumentProviderAdapter: AnyObject {
    func export(
        sourceURL: URL,
        destinationURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String,
        userConfirmedReplacement: Bool
    ) throws

    func readImportedFile(at url: URL) throws -> Data
}

final class LocalDocumentProviderAdapter: DocumentProviderAdapter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(
        sourceURL: URL,
        destinationURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String,
        userConfirmedReplacement: Bool
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BackupProviderError.sourceMissing
        }
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else {
            throw BackupProviderError.destinationAlreadyExists
        }
        guard fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path) else {
            throw BackupProviderError.destinationMissing
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard userConfirmedReplacement else { throw BackupProviderError.destinationAlreadyExists }
            try fileManager.removeItem(at: destinationURL)
        }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
        } catch {
            throw BackupProviderError.sourceMissing
        }
        guard UInt64(sourceData.count) == expectedSize else { throw BackupProviderError.sizeMismatch }
        guard sourceData.backupSHA256Hex == expectedSHA256 else { throw BackupProviderError.hashMismatch }

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: destinationURL)
            try handle.write(contentsOf: sourceData)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw BackupProviderError.writeFailed
        }

        guard let copiedData = try? Data(contentsOf: destinationURL) else {
            throw BackupProviderError.partialCopy
        }
        guard UInt64(copiedData.count) == expectedSize else { throw BackupProviderError.sizeMismatch }
        guard copiedData.backupSHA256Hex == expectedSHA256 else { throw BackupProviderError.hashMismatch }
    }

    func readImportedFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw BackupProviderError.importedFileUnreadable
        }
    }
}

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
        var rootMarker: RestoreMarker?
        var rootMarkerWasUnreadable = false
        if fileSystem.fileExists(at: markerURL) {
            do {
                rootMarker = try decode(try fileSystem.readData(at: markerURL))
            } catch {
                rootMarkerWasUnreadable = true
            }
            if rootMarker?.recoveryRequired == true { return rootMarker }
        }

        let safetyRoot = BackupManagedPaths.safetyRoot(for: fileSystem)
        guard fileSystem.fileExists(at: safetyRoot), let directories = try? fileSystem.contentsOfDirectory(at: safetyRoot) else {
            return rootMarkerWasUnreadable
                ? RestoreMarker(recoveryRequired: true, safetyBackupPath: nil, lastFailureState: "unknown")
                : rootMarker
        }
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let fallbackURL = directory.appendingPathComponent("recovery-state.json")
            guard fileSystem.fileExists(at: fallbackURL), let data = try? fileSystem.readData(at: fallbackURL), let marker = try? decode(data) else {
                continue
            }
            if marker.recoveryRequired { return marker }
        }
        if rootMarkerWasUnreadable {
            return RestoreMarker(recoveryRequired: true, safetyBackupPath: nil, lastFailureState: "unknown")
        }
        return rootMarker
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
        if fileSystem.fileExists(at: destinationURL) {
            try fileSystem.removeItem(at: destinationURL)
        }
        try fileSystem.moveItem(at: temporaryURL, to: destinationURL)
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

enum RestoreState: Equatable {
    case preparing
    case validating
    case restoring
    case completed
    case restoreFailed
    case recoveryRequired

    var label: String {
        switch self {
        case .preparing: return "Preparing"
        case .validating: return "Validating"
        case .restoring: return "Restoring"
        case .completed: return "Completed"
        case .restoreFailed: return "Restore failed"
        case .recoveryRequired: return "Recovery required"
        }
    }
}

enum RestorePhase: Equatable {
    case selected
    case capacityPreflight
    case envelopeValidated
    case safetyBackupCreated
    case stagingWritten
    case stagingReadBack
    case swiftDataReopened
    case atomicSwitch
    case postSwitchReopened
    case thumbnailRegenerated
    case completed
}

struct RestoreFaultPlan {
    var failCapacityPreflight = false
    var failEnvelopeValidation = false
    var failSafetyBackup = false
    var failStagingWrite = false
    var failStagingReadBack = false
    var failSwiftDataReopen = false
    var failAtomicSwitch = false
    var failPostSwitchReopen = false
    var failRollback = false
    var failMarkerWrite = false
    var failThumbnailRegeneration = false
}

@MainActor
protocol BackupModelStoreSwitcher: AnyObject {
    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws
    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws
    func atomicSwitch(to stagingURL: URL) throws
    func reopenCurrent(expectedMetadata: BackupMetadata) throws
    func rollback(from safetyBackupURL: URL) throws
}

@MainActor
protocol BackupThumbnailRegenerator: AnyObject {
    func regenerate(metadata: BackupMetadata, drawings: [BackupDrawingRecord]) throws
}

@MainActor
final class LocalBackupThumbnailRegenerator: BackupThumbnailRegenerator {
    let fileSystem: BackupFileSystem

    init(fileSystem: BackupFileSystem) {
        self.fileSystem = fileSystem
    }

    func regenerate(metadata: BackupMetadata, drawings: [BackupDrawingRecord]) throws {
        let directory = fileSystem.rootURL.appendingPathComponent("thumbnails", isDirectory: true)
        try fileSystem.removeItem(at: directory)
        try fileSystem.createDirectory(at: directory)
        let records = Dictionary(uniqueKeysWithValues: drawings.map { ($0.path, $0.payload) })
        for note in metadata.notes {
            guard let path = note.drawingFileName, let payload = records[path] else { continue }
            let drawing = try PKDrawing(data: payload)
            let image = drawing.image(from: CGRect(x: 0, y: 0, width: 1200, height: 900), scale: 1)
            guard let data = image.pngData() else { throw BackupEnvelopeError.invalidMetadata }
            let url = directory.appendingPathComponent("\(note.id.uuidString).png")
            try fileSystem.writeAndFlush(data, to: url)
        }
    }
}

enum BackupManagedPaths {
    static func safetyRoot(for fileSystem: BackupFileSystem) -> URL {
        fileSystem.rootURL.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("safety", isDirectory: true)
    }

    static func stagingRoot(for fileSystem: BackupFileSystem) -> URL {
        fileSystem.rootURL.appendingPathComponent(".restore-staging", isDirectory: true)
    }

    static func safetyBackupURL(for fileSystem: BackupFileSystem, clock: BackupClock, uuidSource: BackupUUIDSource) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: clock.now).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let directoryName = "safety-\(timestamp)-\(uuidSource.makeUUID().uuidString.lowercased())"
        return safetyRoot(for: fileSystem).appendingPathComponent(directoryName, isDirectory: true)
    }

    static func isWithinManagedRoot(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path == root.standardizedFileURL.path || url.standardizedFileURL.path.hasPrefix(rootPath)
    }
}
