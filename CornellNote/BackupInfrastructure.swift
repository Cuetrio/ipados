import Foundation
import PencilKit
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
