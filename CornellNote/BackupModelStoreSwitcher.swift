import Foundation
import PencilKit
import SwiftData

/// Only this small record moves. An opened SQLite store and its sidecars stay at their original URL.
struct NoteStoreSelection: Codable, Equatable {
    let schema: Int
    let store: String

    static let legacy = NoteStoreSelection(schema: 1, store: "legacy")
}

enum NoteStoreSelectionError: Error {
    case unsupportedSchema
}

final class NoteStoreSelectionStore {
    let fileSystem: BackupFileSystem
    private var selectionURL: URL { fileSystem.rootURL.appendingPathComponent("active-store.json") }
    private var layoutURL: URL { fileSystem.rootURL.appendingPathComponent("generation-layout") }

    init(fileSystem: BackupFileSystem) {
        self.fileSystem = fileSystem
    }

    func read() throws -> NoteStoreSelection {
        let data: Data
        do {
            data = try fileSystem.readData(at: selectionURL)
        } catch {
            guard Self.isMissing(error) else { throw error }
            do {
                _ = try fileSystem.readData(at: layoutURL)
                throw BackupRestoreError.currentDataUnavailable
            } catch {
                guard Self.isMissing(error) else { throw error }
            }
            do {
                _ = try fileSystem.contentsOfDirectory(at: fileSystem.rootURL.appendingPathComponent("generations"))
                throw BackupRestoreError.currentDataUnavailable
            } catch {
                guard Self.isMissing(error) else { throw error }
            }
            return .legacy
        }
        guard data.count <= 4096,
              try fileSystem.readData(at: layoutURL) == Data("1\n".utf8) else {
            throw BackupRestoreError.currentDataUnavailable
        }
        let selection = try JSONDecoder().decode(NoteStoreSelection.self, from: data)
        guard selection.schema == 1 else { throw NoteStoreSelectionError.unsupportedSchema }
        _ = try rootURL(for: selection)
        return selection
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    func rootURL(for selection: NoteStoreSelection) throws -> URL {
        guard selection.schema == 1 else { throw BackupRestoreError.currentDataUnavailable }
        if selection == .legacy { return fileSystem.rootURL }
        guard let id = UUID(uuidString: selection.store), id.uuidString.lowercased() == selection.store else {
            throw BackupRestoreError.currentDataUnavailable
        }
        let root = fileSystem.rootURL.appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(selection.store, isDirectory: true)
        let expected = fileSystem.rootURL.resolvingSymlinksInPath()
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(selection.store, isDirectory: true)
        let parent = root.deletingLastPathComponent()
        let expectedParent = expected.deletingLastPathComponent()
        if fileSystem.fileExists(at: parent),
           parent.resolvingSymlinksInPath().standardizedFileURL != expectedParent.standardizedFileURL {
            throw BackupRestoreError.currentDataUnavailable
        }
        if fileSystem.fileExists(at: root),
           root.resolvingSymlinksInPath().standardizedFileURL != expected.standardizedFileURL {
            throw BackupRestoreError.currentDataUnavailable
        }
        return root
    }

    func selectedFileSystem(allowFreshLegacy: Bool = false) throws -> BackupFileSystem {
        let selection = try read()
        let root = try rootURL(for: selection)
        let metadataURL = root.appendingPathComponent("metadata.store")
        if !fileSystem.fileExists(at: metadataURL) {
            let explicitSelection = fileSystem.fileExists(at: selectionURL)
            let hasDrawings = fileSystem.fileExists(at: root.appendingPathComponent("drawings"))
            let hasSidecars = fileSystem.fileExists(at: root.appendingPathComponent("metadata.store-wal")) ||
                fileSystem.fileExists(at: root.appendingPathComponent("metadata.store-shm"))
            guard allowFreshLegacy, selection == .legacy, !explicitSelection, !hasDrawings, !hasSidecars else {
                throw BackupRestoreError.currentDataUnavailable
            }
        } else {
            let values = try metadataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BackupRestoreError.currentDataUnavailable
            }
        }
        return selection == .legacy ? fileSystem : LocalNoteFileSystem(rootURL: root)
    }

    func write(_ selection: NoteStoreSelection) throws {
        _ = try rootURL(for: selection)
        try fileSystem.createDirectory(at: fileSystem.rootURL)
        // Once adopted, disappearance of the selection must never mean "open legacy".
        if !fileSystem.fileExists(at: layoutURL) {
            try fileSystem.writeAndFlush(Data("1\n".utf8), to: layoutURL)
        }
        guard try fileSystem.readData(at: layoutURL) == Data("1\n".utf8) else {
            throw BackupRestoreError.atomicSwitchFailed
        }
        let data = try BackupCanonicalJSON.encode(selection)
        let temporaryURL = fileSystem.rootURL.appendingPathComponent(".active-store-\(UUID().uuidString).tmp")
        defer { try? fileSystem.removeItem(at: temporaryURL) }
        try fileSystem.writeAndFlush(data, to: temporaryURL)
        guard try fileSystem.readData(at: temporaryURL) == data else {
            throw BackupRestoreError.atomicSwitchFailed
        }
        try fileSystem.replaceItem(at: selectionURL, withItemAt: temporaryURL)
        guard try read() == selection else { throw BackupRestoreError.atomicSwitchFailed }
    }
}

@MainActor
protocol BackupModelStoreSwitcher: AnyObject {
    func requireSafeRestoreAdmission() throws
    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws
    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws
    func atomicSwitch(to stagingURL: URL) throws
    func reopenCurrent(expectedMetadata: BackupMetadata) throws
    func rollback(from safetyBackupURL: URL) throws
    var preservesStoreDirectories: Bool { get }
    func stagingURL(id: UUID, root: URL) -> URL
    func restoredFileSystem(fallback: BackupFileSystem) throws -> BackupFileSystem
}

extension BackupModelStoreSwitcher {
    var preservesStoreDirectories: Bool { false }
    func stagingURL(id: UUID, root: URL) -> URL {
        root.appendingPathComponent(".restore-staging", isDirectory: true)
            .appendingPathComponent("restore-\(id.uuidString.lowercased())", isDirectory: true)
    }
    func restoredFileSystem(fallback: BackupFileSystem) throws -> BackupFileSystem { fallback }
}

@MainActor
final class LocalBackupModelStoreSwitcher: BackupModelStoreSwitcher {
    private let fileSystem: BackupFileSystem
    private let selectionStore: NoteStoreSelectionStore
    private let isAdmitted: () -> Bool
    private var previousSelection: NoteStoreSelection?
    private var verifiedRoots: Set<URL> = []
    var preservesStoreDirectories: Bool { true }

    init(fileSystem: BackupFileSystem, isAdmitted: @escaping () -> Bool = { false }) {
        self.fileSystem = fileSystem
        selectionStore = NoteStoreSelectionStore(fileSystem: fileSystem)
        self.isAdmitted = isAdmitted
    }

    func requireSafeRestoreAdmission() throws {
        guard isAdmitted() else { throw BackupRestoreError.restoreUnavailable }
        if previousSelection == nil {
            guard try LocalRestoreMarkerStore(fileSystem: fileSystem).read()?.recoveryRequired != true else {
                throw BackupRestoreError.restoreUnavailable
            }
            _ = try selectionStore.selectedFileSystem()
            previousSelection = try selectionStore.read()
        }
    }

    func stagingURL(id: UUID, root: URL) -> URL {
        fileSystem.rootURL.appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws {
        try requireSafeRestoreAdmission()
        let selection = NoteStoreSelection(schema: 1, store: stagingURL.lastPathComponent)
        guard try selectionStore.rootURL(for: selection).standardizedFileURL == stagingURL.standardizedFileURL else {
            throw BackupRestoreError.stagingFailed
        }
        let stagingFileSystem = LocalNoteFileSystem(rootURL: stagingURL)
        let container = try NotePersistenceController.makeContainer(fileSystem: stagingFileSystem)
        container.mainContext.autosaveEnabled = false
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for note in metadata.notes { context.insert(note.makeNote()) }
        try context.save()
        for drawing in drawings {
            try BackupPathValidator.validate(drawing.path)
            let destination = stagingURL.appendingPathComponent(drawing.path)
            try stagingFileSystem.writeAndFlush(drawing.payload, to: destination)
            guard try stagingFileSystem.readData(at: destination) == drawing.payload,
                  (try? PKDrawing(data: drawing.payload)) != nil else {
                throw BackupRestoreError.stagingFailed
            }
        }
    }

    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws {
        let metadataURL = rootURL.appendingPathComponent("metadata.store")
        guard fileSystem.fileExists(at: metadataURL) else { throw BackupRestoreError.storeReopenFailed }
        let localFileSystem = LocalNoteFileSystem(rootURL: rootURL)
        let container = try NotePersistenceController.makeContainer(fileSystem: localFileSystem)
        container.mainContext.autosaveEnabled = false
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let notes = try context.fetch(FetchDescriptor<NoteRecord>())
        guard BackupMetadata(noteRecords: notes) == expectedMetadata else { throw BackupRestoreError.storeReopenFailed }
        let controller = NotePersistenceController(modelContext: context, fileSystem: localFileSystem)
        for note in notes { _ = try controller.loadDrawing(for: note) }
        verifiedRoots.insert(rootURL.standardizedFileURL)
    }

    func atomicSwitch(to stagingURL: URL) throws {
        try requireSafeRestoreAdmission()
        guard verifiedRoots.contains(stagingURL.standardizedFileURL) else { throw BackupRestoreError.atomicSwitchFailed }
        try selectionStore.write(NoteStoreSelection(schema: 1, store: stagingURL.lastPathComponent))
    }

    func restoredFileSystem(fallback: BackupFileSystem) throws -> BackupFileSystem {
        try selectionStore.selectedFileSystem()
    }

    func reopenCurrent(expectedMetadata: BackupMetadata) throws {
        try reopenStore(at: selectionStore.selectedFileSystem().rootURL, expectedMetadata: expectedMetadata)
    }

    func rollback(from safetyBackupURL: URL) throws {
        try requireSafeRestoreAdmission()
        guard let previousSelection,
              try fileSystem.readData(at: safetyBackupURL.appendingPathComponent("safety-complete.json")) ==
                Data("{\"completed\":true,\"schema\":1}".utf8) else { throw BackupRestoreError.rollbackFailed }
        let envelope = try BackupEnvelopeCodec().decode(fileSystem.readData(
            at: safetyBackupURL.appendingPathComponent("restore-manifest.cornellnote-backup")))
        let previousRoot = try selectionStore.rootURL(for: previousSelection)
        try reopenStore(at: previousRoot, expectedMetadata: envelope.metadata)
        for drawing in envelope.drawings {
            guard try fileSystem.readData(at: safetyBackupURL.appendingPathComponent(drawing.path)) == drawing.payload else {
                throw BackupRestoreError.rollbackFailed
            }
        }
        // The previous store was never modified. Re-select it only after verifying the safety snapshot.
        try selectionStore.write(previousSelection)
    }
}
