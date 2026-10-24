import Foundation
import PencilKit
import SwiftData

@MainActor
protocol BackupModelStoreSwitcher: AnyObject {
    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws
    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws
    func atomicSwitch(to stagingURL: URL) throws
    func reopenCurrent(expectedMetadata: BackupMetadata) throws
    func rollback(from safetyBackupURL: URL) throws
}

@MainActor
final class LocalBackupModelStoreSwitcher: BackupModelStoreSwitcher {
    private let fileSystem: BackupFileSystem

    init(fileSystem: BackupFileSystem) {
        self.fileSystem = fileSystem
    }

    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws {
        let stagingFileSystem = LocalNoteFileSystem(rootURL: stagingURL)
        try stagingFileSystem.createDirectory(at: stagingURL)
        let container = try NotePersistenceController.makeContainer(fileSystem: stagingFileSystem)
        let context = ModelContext(container)
        for note in metadata.notes {
            context.insert(note.makeNote())
        }
        try context.save()
        for drawing in drawings {
            try BackupPathValidator.validate(drawing.path)
            let destination = stagingURL.appendingPathComponent(drawing.path)
            try stagingFileSystem.writeAndFlush(drawing.payload, to: destination)
            guard try stagingFileSystem.readData(at: destination).backupSHA256Hex == drawing.payload.backupSHA256Hex,
                  (try? PKDrawing(data: drawing.payload)) != nil else {
                throw BackupRestoreError.stagingFailed
            }
        }
    }

    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws {
        let localFileSystem = LocalNoteFileSystem(rootURL: rootURL)
        let container = try NotePersistenceController.makeContainer(fileSystem: localFileSystem)
        let context = ModelContext(container)
        let actual = BackupMetadata(noteRecords: try context.fetch(FetchDescriptor<NoteRecord>()))
        guard actual == expectedMetadata else { throw BackupRestoreError.storeReopenFailed }
        let controller = NotePersistenceController(modelContext: context, fileSystem: localFileSystem)
        for note in try context.fetch(FetchDescriptor<NoteRecord>()) {
            _ = try controller.loadDrawing(for: note)
        }
    }

    func atomicSwitch(to stagingURL: URL) throws {
        let previousURL = fileSystem.rootURL.appendingPathComponent(".restore-previous-\(UUID().uuidString)", isDirectory: true)
        let failedURL = fileSystem.rootURL.appendingPathComponent(".restore-failed-\(UUID().uuidString)", isDirectory: true)
        try fileSystem.createDirectory(at: previousURL)
        do {
            try moveActiveItems(from: fileSystem.rootURL, to: previousURL)
            try moveActiveItems(from: stagingURL, to: fileSystem.rootURL)
            try? fileSystem.removeItem(at: previousURL)
        } catch {
            do {
                try fileSystem.createDirectory(at: failedURL)
                try moveActiveItems(from: fileSystem.rootURL, to: failedURL)
                try moveActiveItems(from: previousURL, to: fileSystem.rootURL)
                try fileSystem.removeItem(at: previousURL)
                try fileSystem.removeItem(at: failedURL)
            } catch {
                // The coordinator retains the safety backup and records recovery required.
            }
            throw BackupRestoreError.atomicSwitchFailed
        }
    }

    func reopenCurrent(expectedMetadata: BackupMetadata) throws {
        try reopenStore(at: fileSystem.rootURL, expectedMetadata: expectedMetadata)
    }

    func rollback(from safetyBackupURL: URL) throws {
        let manifestURL = safetyBackupURL.appendingPathComponent("restore-manifest.cornellnote-backup")
        let data = try fileSystem.readData(at: manifestURL)
        let envelope = try BackupEnvelopeCodec().decode(data)
        let rollbackURL = BackupManagedPaths.stagingRoot(for: fileSystem)
            .appendingPathComponent("rollback-\(UUID().uuidString)", isDirectory: true)
        do {
            try writeStagingStore(metadata: envelope.metadata, drawings: envelope.drawings, at: rollbackURL)
            try atomicSwitch(to: rollbackURL)
            try? fileSystem.removeItem(at: rollbackURL)
        } catch {
            try? fileSystem.removeItem(at: rollbackURL)
            throw BackupRestoreError.rollbackFailed
        }
    }

    private func moveActiveItems(from source: URL, to destination: URL) throws {
        let entries = try fileSystem.contentsOfDirectory(at: source)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name == "drawings" || name == "metadata.store" || name.hasPrefix("metadata.store-") else { continue }
            try fileSystem.moveItem(at: entry, to: destination.appendingPathComponent(name, isDirectory: name == "drawings"))
        }
    }
}
