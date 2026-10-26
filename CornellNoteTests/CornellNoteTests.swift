import Foundation
import CryptoKit
import PencilKit
import SwiftData
import XCTest
@testable import CornellNote

@MainActor
final class CornellNoteTests: XCTestCase {
    func testNewNoteUsesUntitledDisplayTitle() {
        let note = NoteRecord()

        XCTAssertEqual(note.displayTitle, "無題のノート")
        XCTAssertEqual(note.drawingSchemaVersion, 1)
    }

    func testRestoreStateLabelsRemainSeparateFromSaveState() {
        XCTAssertEqual(RestoreState.preparing.label, "Preparing")
        XCTAssertEqual(RestoreState.validating.label, "Validating")
        XCTAssertEqual(RestoreState.restoring.label, "Restoring")
        XCTAssertEqual(RestoreState.completed.label, "Completed")
        XCTAssertEqual(RestoreState.restoreFailed.label, "Restore failed")
        XCTAssertEqual(RestoreState.recoveryRequired.label, "Recovery required")
        XCTAssertNotEqual(RestoreState.restoreFailed.label, NoteSaveState.saveFailed.label)
    }

    func testManagedFileWriteTruncatesExistingStagingFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let url = root.appendingPathComponent("staging.bin")

        try fileSystem.writeAndFlush(Data([1, 2, 3, 4]), to: url)
        try fileSystem.writeAndFlush(Data([9]), to: url)

        XCTAssertEqual(try fileSystem.readData(at: url), Data([9]))
    }

    func testSaveReopenAndReadBackKeepsMetadataAndDrawing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let firstContainer = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let firstContext = ModelContext(firstContainer)
        let firstController = NotePersistenceController(modelContext: firstContext, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 100) })
        let note = NoteRecord(title: "Reading", now: Date(timeIntervalSince1970: 10))
        firstContext.insert(note)
        try firstContext.save()

        let savedDrawing = nonemptyDrawing(offset: 0)
        try firstController.save(note: note, drawing: savedDrawing)
        let pointer = try XCTUnwrap(note.drawingFileName)
        let checksum = try XCTUnwrap(note.drawingChecksum)

        let secondContainer = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let secondContext = ModelContext(secondContainer)
        let reopened = try XCTUnwrap(try secondContext.fetch(FetchDescriptor<NoteRecord>()).first)
        let secondController = NotePersistenceController(modelContext: secondContext, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 200) })
        let drawing = try secondController.loadDrawing(for: reopened)

        XCTAssertEqual(reopened.id, note.id)
        XCTAssertEqual(reopened.title, "Reading")
        XCTAssertEqual(reopened.drawingFileName, pointer)
        XCTAssertEqual(reopened.drawingChecksum, checksum)
        XCTAssertEqual(reopened.drawingSchemaVersion, 1)
        XCTAssertEqual(reopened.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(drawing.strokes.count, savedDrawing.strokes.count)
        XCTAssertEqual(drawing.bounds, savedDrawing.bounds)
        XCTAssertNoThrow(try PKDrawing(data: drawing.dataRepresentation()))
    }

    func testCorruptReadBackPreservesOldActiveGenerationAndMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 100) })
        let note = NoteRecord(title: "Before", now: Date(timeIntervalSince1970: 10))
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let oldPointer = note.drawingFileName
        let oldChecksum = note.drawingChecksum
        let oldUpdatedAt = note.updatedAt

        fileSystem.corruptNextRead = true
        let failingController = NotePersistenceController(
            modelContext: context,
            fileSystem: fileSystem,
            clock: { Date(timeIntervalSince1970: 200) },
            commitMetadata: { throw NotePersistenceError.metadataCommitFailed }
        )

        XCTAssertThrowsError(try failingController.save(note: note, drawing: PKDrawing(), title: "After"))
        XCTAssertEqual(note.title, "Before")
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertEqual(note.drawingChecksum, oldChecksum)
        XCTAssertEqual(note.updatedAt, oldUpdatedAt)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: try XCTUnwrap(oldPointer)))
    }

    func testCapacityFailureDoesNotDeleteActiveGeneration() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 100) })
        let note = NoteRecord(now: Date(timeIntervalSince1970: 10))
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let oldPointer = try XCTUnwrap(note.drawingFileName)
        fileSystem.availableCapacity = 0

        XCTAssertThrowsError(try controller.save(note: note, drawing: PKDrawing()))
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: oldPointer))
        XCTAssertFalse(fileSystem.didRemoveAnything)
    }

    func testRenameFailurePreservesOldActiveGenerationAndMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 100) })
        let note = NoteRecord(now: Date(timeIntervalSince1970: 10))
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let oldPointer = try XCTUnwrap(note.drawingFileName)
        fileSystem.failNextMove = true

        XCTAssertThrowsError(try controller.save(note: note, drawing: PKDrawing()))
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: oldPointer))
    }

    func testTemporaryWriteFailurePreservesOldActiveGenerationAndMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem, clock: { Date(timeIntervalSince1970: 100) })
        let note = NoteRecord(now: Date(timeIntervalSince1970: 10))
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let oldPointer = try XCTUnwrap(note.drawingFileName)
        fileSystem.failNextWrite = true

        XCTAssertThrowsError(try controller.save(note: note, drawing: PKDrawing()))
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: oldPointer))
    }

    func testCommitFailureLeavesOrphanForSafeCleanupWithoutDeletingActiveFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(
            modelContext: context,
            fileSystem: fileSystem,
            clock: { Date(timeIntervalSince1970: 100) },
            commitMetadata: {
                if fileSystem.failMetadataCommit {
                    throw NotePersistenceError.metadataCommitFailed
                }
                try context.save()
            }
        )
        let note = NoteRecord(now: Date(timeIntervalSince1970: 10))
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let oldPointer = try XCTUnwrap(note.drawingFileName)
        fileSystem.failMetadataCommit = true

        XCTAssertThrowsError(try controller.save(note: note, drawing: PKDrawing()))
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: oldPointer))
        controller.cleanupOrphans(for: note)
        XCTAssertTrue(fileSystem.fileExists(forRelativePath: oldPointer))
    }

    func testLibraryDeleteRemovesMetadataGenerationsAndThumbnail() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        let note = NoteRecord(title: " ")
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        _ = try controller.regenerateThumbnail(for: note, drawing: PKDrawing())
        let id = note.id

        try controller.delete(note: note)

        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteRecord>()).isEmpty)
        XCTAssertFalse(fileSystem.fileExists(at: root.appendingPathComponent("drawings/\(id.uuidString)")))
        XCTAssertFalse(fileSystem.fileExists(at: root.appendingPathComponent("thumbnails/\(id.uuidString).png")))
        XCTAssertEqual(note.displayTitle, "無題のノート")
    }

    func testThumbnailCanBeRegeneratedAfterCacheIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        let note = NoteRecord()
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: PKDrawing())
        let thumbnailURL = try controller.regenerateThumbnail(for: note, drawing: try controller.loadDrawing(for: note))
        try FileManager.default.removeItem(at: thumbnailURL)

        let regenerated = try controller.regenerateThumbnail(for: note, drawing: try controller.loadDrawing(for: note))

        XCTAssertTrue(FileManager.default.fileExists(atPath: regenerated.path))
        XCTAssertFalse(try XCTUnwrap(try Data(contentsOf: regenerated)).isEmpty)
    }

    func testBackupEnvelopeHasDeterministicCanonicalGoldenBytes() throws {
        let noteID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let drawingPayload = Data([0x01, 0x02, 0x03, 0x04])
        let drawingPath = "drawings/\(noteID.uuidString.lowercased())/00000000-0000-0000-0000-000000000001-\(drawingPayload.sha256HexForTest).drawing"
        let metadata = BackupMetadata(notes: [
            BackupMetadataNote(
                id: noteID,
                title: "Reading",
                createdAtUnixNanos: 10_000_000_000,
                updatedAtUnixNanos: 20_000_000_000,
                drawingFileName: drawingPath,
                drawingChecksum: drawingPayload.sha256HexForTest,
                drawingSchemaVersion: 1
            )
        ])
        let drawings = [BackupDrawingRecord(path: drawingPath, payload: drawingPayload)]
        let codec = BackupEnvelopeCodec()

        let first = try codec.encode(metadata: metadata, drawings: drawings, createdAtUnixNanos: 30_000_000_000)
        let second = try codec.encode(metadata: metadata, drawings: drawings, createdAtUnixNanos: 30_000_000_000)
        let decoded = try codec.decode(first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sha256HexForTest, "4e36e42027ac90f22506ea65e467eae3cca43ee9f6b7418e6d4c9c12bdfa428f")
        XCTAssertEqual(Data(first.prefix(16)), Data("CORNELLNOTE-BKP\0".utf8))
        XCTAssertEqual(decoded.metadata.notes.map(\.id), [noteID])
        XCTAssertEqual(decoded.drawings.map(\.path), [drawingPath])
        XCTAssertEqual(decoded.drawings.first?.payload, drawingPayload)
        XCTAssertNil(first.range(of: Data("thumbnail".utf8)))
    }

    func testBackupEnvelopeUsesInjectedManifestHasher() throws {
        let hasher = CountingManifestHasher()
        let codec = BackupEnvelopeCodec(hasher: hasher)

        _ = try codec.decode(try makeBackupEnvelopeFixture())

        XCTAssertGreaterThan(hasher.hexCallCount, 0)
        XCTAssertGreaterThan(hasher.digestCallCount, 0)
    }

    func testBackupMetadataCanonicalizesLegacyUppercaseDrawingPointer() throws {
        let noteID = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let payload = Data([0x01, 0x02])
        let checksum = payload.sha256HexForTest
        let legacyPath = "drawings/\(noteID.uuidString)/00000000-0000-0000-0000-000000000005-\(checksum).drawing"
        let note = NoteRecord(title: "Legacy")
        note.id = noteID
        note.drawingFileName = legacyPath
        note.drawingChecksum = checksum

        let metadata = BackupMetadata(noteRecords: [note])

        XCTAssertEqual(
            metadata.notes.first?.drawingFileName,
            legacyPath.replacingOccurrences(of: noteID.uuidString, with: noteID.uuidString.lowercased())
        )
    }

    func testPersistenceReadsCanonicalLowercaseDrawingPointer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let noteID = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let payload = PKDrawing().dataRepresentation()
        let checksum = payload.sha256HexForTest
        let path = "drawings/\(noteID.uuidString.lowercased())/00000000-0000-0000-0000-000000000006-\(checksum).drawing"
        let note = NoteRecord(title: "Restored")
        note.id = noteID
        note.drawingFileName = path
        note.drawingChecksum = checksum
        context.insert(note)
        try context.save()
        try fileSystem.writeAndFlush(payload, to: root.appendingPathComponent(path))

        XCTAssertNoThrow(try NotePersistenceController(modelContext: context, fileSystem: fileSystem).loadDrawing(for: note))
    }

    func testBackupEnvelopeRejectsTruncatedAndMutatedGoldenBytes() throws {
        let fixture = try makeBackupEnvelopeFixture()
        let codec = BackupEnvelopeCodec()

        for mutation in [
            fixture.dropLast(),
            fixture.dropLast(40),
            fixture.mutatingByte(at: 24)
        ] {
            XCTAssertThrowsError(try codec.decode(mutation))
        }
    }

    func testBackupEnvelopeRejectsUnknownSchemaAndNonCanonicalPath() throws {
        let fixture = try makeBackupEnvelopeFixture()
        let codec = BackupEnvelopeCodec()
        let manifestRange = try XCTUnwrap(fixture.manifestByteRangeForTest)

        var unknownSchema = fixture
        unknownSchema.replaceSubrange(manifestRange, with: Data(fixture[manifestRange].map { $0 }))
        let schemaMarker = Data("\"envelopeSchema\":1".utf8)
        let schemaReplacement = Data("\"envelopeSchema\":2".utf8)
        unknownSchema.replaceSubrange(try XCTUnwrap(unknownSchema.range(of: schemaMarker)), with: schemaReplacement)
        XCTAssertThrowsError(try codec.decode(unknownSchema))

        var unknownAppDataSchema = fixture
        let appSchemaMarker = Data("\"appDataSchema\":1".utf8)
        let appSchemaReplacement = Data("\"appDataSchema\":2".utf8)
        unknownAppDataSchema.replaceSubrange(try XCTUnwrap(unknownAppDataSchema.range(of: appSchemaMarker)), with: appSchemaReplacement)
        XCTAssertThrowsError(try codec.decode(unknownAppDataSchema))

        var unknownDrawingSchema = fixture
        let drawingSchemaMarker = Data("\"drawingSchemaVersion\":1".utf8)
        let drawingSchemaReplacement = Data("\"drawingSchemaVersion\":2".utf8)
        unknownDrawingSchema.replaceSubrange(try XCTUnwrap(unknownDrawingSchema.range(of: drawingSchemaMarker)), with: drawingSchemaReplacement)
        XCTAssertThrowsError(try codec.decode(unknownDrawingSchema))

        var traversal = fixture
        if let validRange = traversal.range(of: Data("drawings/".utf8)) {
            traversal.replaceSubrange(validRange, with: Data("drawings/../".utf8))
        }
        XCTAssertThrowsError(try codec.decode(traversal))

        var sizeMismatch = fixture
        let sizeMarker = Data("\"size\":4".utf8)
        sizeMismatch.replaceSubrange(try XCTUnwrap(sizeMismatch.range(of: sizeMarker)), with: Data("\"size\":5".utf8))
        XCTAssertThrowsError(try codec.decode(sizeMismatch))

        var payloadMismatch = fixture
        payloadMismatch.replaceSubrange(try XCTUnwrap(payloadMismatch.range(of: Data([0x01, 0x02, 0x03, 0x04]))), with: Data([0x01, 0x02, 0x03, 0x05]))
        XCTAssertThrowsError(try codec.decode(payloadMismatch))

        let decomposedPath = "drawings/11111111-1111-1111-1111-111111111111/e\u{301}-\(String(repeating: "0", count: 64)).drawing"
        XCTAssertThrowsError(try BackupPathValidator.validate(decomposedPath))
        let composedPath = "drawings/11111111-1111-1111-1111-111111111111/\u{e9}-\(String(repeating: "0", count: 64)).drawing"
        XCTAssertNoThrow(try BackupPathValidator.validate(composedPath))
        XCTAssertNoThrow(try BackupPathValidator.validate("metadata.json"))
        XCTAssertThrowsError(try BackupPathValidator.validate("/metadata.json"))
        XCTAssertThrowsError(try BackupPathValidator.validate("drawings/11111111-1111-1111-1111-111111111111/../metadata.store"))
    }

    func testUITestStoreIsIsolatedFromTheUserStore() {
        let key = LocalNoteFileSystem.uiTestStoreEnvironmentKey
        let userStore = LocalNoteFileSystem.defaultRootURL(environment: [:])
        XCTAssertEqual(userStore.lastPathComponent, "CornellNote")

        let id = UUID()
        let testStore = LocalNoteFileSystem.defaultRootURL(environment: [key: id.uuidString])
        XCTAssertEqual(testStore.lastPathComponent, id.uuidString)
        XCTAssertEqual(testStore.deletingLastPathComponent().lastPathComponent, "CornellNote-UITests")
        XCTAssertTrue(testStore.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(testStore.path.hasPrefix(userStore.path))

        // Anything but a UUID cannot steer the store to another path.
        for value in ["", "../CornellNote", "/tmp/elsewhere"] {
            XCTAssertEqual(LocalNoteFileSystem.defaultRootURL(environment: [key: value]), userStore, value)
        }
    }

    func testRestoreMarkerRoundTripAndProviderRequiresExplicitReplacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let markerStore = LocalRestoreMarkerStore(fileSystem: fileSystem)
        let marker = RestoreMarker(
            recoveryRequired: true,
            safetyBackupPath: "Backups/safety/safety-20260922T000000Z-11111111-1111-1111-1111-111111111111",
            lastFailureState: RestoreState.recoveryRequired.label
        )

        try markerStore.write(marker, fallbackDirectory: nil)
        XCTAssertEqual(try markerStore.read(), marker)

        let sourceURL = root.appendingPathComponent("staging.backup")
        let destinationURL = root.appendingPathComponent("export.backup")
        try Data([0x01, 0x02]).write(to: sourceURL)
        try Data([0x09]).write(to: destinationURL)
        let provider = LocalDocumentProviderAdapter(fileManager: .default)

        XCTAssertThrowsError(try provider.export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            expectedSize: 2,
            expectedSHA256: Data([0x01, 0x02]).sha256HexForTest,
            userConfirmedReplacement: false
        ))
        try provider.export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            expectedSize: 2,
            expectedSHA256: Data([0x01, 0x02]).sha256HexForTest,
            userConfirmedReplacement: true
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data([0x01, 0x02]))
    }

    func testMarkerWriteFailureLeavesRecoveryMarkerInSafetyBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let safetyURL = root.appendingPathComponent("Backups/safety/safety-test", isDirectory: true)
        try fileSystem.createDirectory(at: safetyURL)
        let marker = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "post-switch")
        fileSystem.failNextWrite = true

        XCTAssertThrowsError(try LocalRestoreMarkerStore(fileSystem: fileSystem).write(marker, fallbackDirectory: safetyURL))
        XCTAssertEqual(try LocalRestoreMarkerStore(fileSystem: fileSystem).read(), marker)
    }

    func testRestoreCapacityFailureLeavesCurrentDataAndDoesNotSwitch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        fileSystem.availableCapacity = 0
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let switcher = RecordingModelStoreSwitcher()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: switcher,
            markerStore: RecordingMarkerStore(),
            thumbnailRegenerator: RecordingThumbnailRegenerator()
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, .restoreFailed)
        XCTAssertFalse(switcher.didSwitch)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteRecord>()).first?.title, "Current")
    }

    func testPostSwitchReopenFailureRollsBackAndRollbackFailureRequiresRecovery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let switcher = RecordingModelStoreSwitcher()
        switcher.failPostSwitchReopen = true
        switcher.failRollback = true
        let markerStore = RecordingMarkerStore()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: switcher,
            markerStore: markerStore,
            thumbnailRegenerator: RecordingThumbnailRegenerator()
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, .recoveryRequired)
        XCTAssertTrue(switcher.didSwitch)
        XCTAssertTrue(switcher.didRollback)
        XCTAssertTrue(markerStore.marker?.recoveryRequired == true)
        XCTAssertNotNil(result.safetyBackupURL)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteRecord>()).first?.title, "Current")
    }

    func testPostSwitchReopenFailureCanRollbackAndKeepRestoreFailedState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let switcher = RecordingModelStoreSwitcher()
        switcher.failPostSwitchReopen = true
        let markerStore = RecordingMarkerStore()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: switcher,
            markerStore: markerStore,
            thumbnailRegenerator: RecordingThumbnailRegenerator()
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, .restoreFailed)
        XCTAssertTrue(switcher.didRollback)
        XCTAssertEqual(markerStore.marker?.recoveryRequired, false)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteRecord>()).first?.title, "Current")
    }

    func testRollbackFailureWithMarkerWriteFailureRetainsSafetyBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let switcher = RecordingModelStoreSwitcher()
        switcher.failPostSwitchReopen = true
        switcher.failRollback = true
        let markerStore = RecordingMarkerStore()
        markerStore.failAfterFirstWrite = true
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: switcher,
            markerStore: markerStore,
            thumbnailRegenerator: RecordingThumbnailRegenerator()
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, .recoveryRequired)
        XCTAssertNotNil(result.safetyBackupURL)
        XCTAssertTrue(fileSystem.fileExists(at: try XCTUnwrap(result.safetyBackupURL).appendingPathComponent("safety-complete.json")))
    }

    func testValidRestoreCompletesAndRegeneratesThumbnailWithoutRestoringCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let switcher = RecordingModelStoreSwitcher()
        let thumbnail = RecordingThumbnailRegenerator()
        let markerStore = RecordingMarkerStore()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            clock: FixedBackupClock(now: Date(timeIntervalSince1970: 30)),
            uuidSource: FixedBackupUUIDSource(),
            modelStoreSwitcher: switcher,
            markerStore: markerStore,
            thumbnailRegenerator: thumbnail
        )

        let result = coordinator.restore(from: try makeValidDrawingBackupData(title: "Imported").data)

        XCTAssertEqual(result.state, RestoreState.completed)
        XCTAssertTrue(result.thumbnailRegenerated)
        XCTAssertTrue(thumbnail.didRegenerate)
        XCTAssertTrue(switcher.didSwitch)
        XCTAssertEqual(markerStore.marker?.recoveryRequired, false)
        XCTAssertNotNil(result.safetyBackupURL)
        XCTAssertFalse(fileSystem.fileExists(at: root.appendingPathComponent(".restore-staging")))
    }

    func testPreSwitchFailuresPreserveDrawingPointerAndThumbnail() throws {
        let faultPlans: [RestoreFaultPlan] = [
            RestoreFaultPlan(failEnvelopeValidation: true),
            RestoreFaultPlan(failSafetyBackup: true),
            RestoreFaultPlan(failStagingWrite: true),
            RestoreFaultPlan(failStagingReadBack: true),
            RestoreFaultPlan(failSwiftDataReopen: true),
            RestoreFaultPlan(failAtomicSwitch: true)
        ]

        for faultPlan in faultPlans {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileSystem = FaultInjectingFileSystem(rootURL: root)
            let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
            let context = ModelContext(container)
            let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
            context.insert(current)
            try context.save()
            let persistence = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
            try persistence.save(note: current, drawing: PKDrawing())
            let pointer = try XCTUnwrap(current.drawingFileName)
            let thumbnailURL = try persistence.regenerateThumbnail(for: current, drawing: PKDrawing())
            let thumbnailBefore = try Data(contentsOf: thumbnailURL)
            let switcher = RecordingModelStoreSwitcher()
            let coordinator = BackupRestoreCoordinator(
                modelContext: context,
                fileSystem: fileSystem,
                modelStoreSwitcher: switcher,
                markerStore: RecordingMarkerStore(),
                thumbnailRegenerator: RecordingThumbnailRegenerator(),
                faultPlan: faultPlan
            )

            let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

            XCTAssertEqual(result.state, .restoreFailed)
            XCTAssertFalse(switcher.didSwitch)
            XCTAssertEqual(current.drawingFileName, pointer)
            XCTAssertTrue(fileSystem.fileExists(forRelativePath: pointer))
            XCTAssertEqual(try Data(contentsOf: thumbnailURL), thumbnailBefore)
        }
    }

    func testExportDoesNotIncludeThumbnailAndProviderFailureLeavesCurrentData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let current = NoteRecord(title: "Current", now: Date(timeIntervalSince1970: 10))
        context.insert(current)
        try context.save()
        let thumbnailURL = root.appendingPathComponent("thumbnails/current.png")
        try fileSystem.writeAndFlush(Data([0x55]), to: thumbnailURL)
        let provider = RecordingDocumentProvider()
        let coordinator = BackupExportCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            clock: FixedBackupClock(now: Date(timeIntervalSince1970: 30)),
            uuidSource: FixedBackupUUIDSource(),
            provider: provider
        )
        let destinationURL = root.appendingPathComponent("exported.backup")

        let result = try coordinator.export(to: destinationURL)

        XCTAssertTrue(provider.didExport)
        XCTAssertEqual(result.byteCount, UInt64(try Data(contentsOf: destinationURL).count))
        XCTAssertNil(try BackupEnvelopeCodec().decode(Data(contentsOf: destinationURL)).manifest.records.first(where: { $0.path.contains("thumbnail") }))
        XCTAssertEqual(try Data(contentsOf: thumbnailURL), Data([0x55]))

        provider.failExport = true
        XCTAssertThrowsError(try coordinator.export(to: root.appendingPathComponent("failed.backup")))
        XCTAssertEqual(try Data(contentsOf: thumbnailURL), Data([0x55]))
        XCTAssertEqual(current.title, "Current")
    }

    func testProviderFailureVectorsNeverBecomeSuccessfulExport() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let note = NoteRecord(title: "Current")
        context.insert(note)
        try context.save()
        let provider = RecordingDocumentProvider()
        let coordinator = BackupExportCoordinator(modelContext: context, fileSystem: fileSystem, provider: provider)
        let failures: [BackupProviderError] = [.partialCopy, .cancelled, .writeFailed, .destinationMissing, .sizeMismatch, .hashMismatch]

        for (index, failure) in failures.enumerated() {
            provider.failure = failure
            XCTAssertThrowsError(try coordinator.export(to: root.appendingPathComponent("provider-failure-\(index).backup")))
        }
    }

    func testThumbnailRegenerationFailureDoesNotInvalidateRestore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let note = NoteRecord(title: "Current")
        context.insert(note)
        try context.save()
        let thumbnail = RecordingThumbnailRegenerator()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: RecordingModelStoreSwitcher(),
            markerStore: RecordingMarkerStore(),
            thumbnailRegenerator: thumbnail,
            faultPlan: RestoreFaultPlan(failThumbnailRegeneration: true)
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, RestoreState.completed)
        XCTAssertFalse(result.thumbnailRegenerated)
        XCTAssertFalse(thumbnail.didRegenerate)
    }

    func testLocalThumbnailRegenerationDropsOmittedCacheAndWritesActiveDrawing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let staleURL = root.appendingPathComponent("thumbnails/stale.png")
        try fileSystem.writeAndFlush(Data([0x55]), to: staleURL)

        let id = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let payload = PKDrawing().dataRepresentation()
        let checksum = payload.sha256HexForTest
        let path = "drawings/\(id.uuidString.lowercased())/00000000-0000-0000-0000-000000000007-\(checksum).drawing"
        let metadata = BackupMetadata(notes: [
            BackupMetadataNote(
                id: id,
                title: "Restored",
                createdAtUnixNanos: 1,
                updatedAtUnixNanos: 2,
                drawingFileName: path,
                drawingChecksum: checksum,
                drawingSchemaVersion: 1
            )
        ])

        try LocalBackupThumbnailRegenerator(fileSystem: fileSystem).regenerate(
            metadata: metadata,
            drawings: [BackupDrawingRecord(path: path, payload: payload)]
        )

        XCTAssertFalse(fileSystem.fileExists(at: staleURL))
        XCTAssertTrue(fileSystem.fileExists(at: root.appendingPathComponent("thumbnails/\(id.uuidString).png")))
    }

    func testMarkerWriteFailureRetainsSafetyBackupAndRequiresRecovery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        let context = ModelContext(container)
        let note = NoteRecord(title: "Current")
        context.insert(note)
        try context.save()
        let markerStore = RecordingMarkerStore()
        let coordinator = BackupRestoreCoordinator(
            modelContext: context,
            fileSystem: fileSystem,
            modelStoreSwitcher: RecordingModelStoreSwitcher(),
            markerStore: markerStore,
            thumbnailRegenerator: RecordingThumbnailRegenerator(),
            faultPlan: RestoreFaultPlan(failMarkerWrite: true)
        )

        let result = coordinator.restore(from: try makeSimpleBackupData(title: "Imported"))

        XCTAssertEqual(result.state, .recoveryRequired)
        XCTAssertEqual(markerStore.marker?.recoveryRequired, true)
        XCTAssertNotNil(result.safetyBackupURL)
    }

    // MARK: - Editing session and save/read safety

    func testStrictLoadRejectsUnknownSchemaBeforeEmptyPointerAndPartialMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let note = NoteRecord(title: "Unchanged")
        context.insert(note)
        try context.save()
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        XCTAssertTrue(try controller.loadDrawing(for: note).strokes.isEmpty)

        note.drawingSchemaVersion = 99
        XCTAssertThrowsError(try controller.loadDrawing(for: note)) { error in
            guard case NotePersistenceError.unsupportedDrawingSchema = error else {
                return XCTFail("Schema must be checked before the absent pointer: \(error)")
            }
        }
        note.drawingSchemaVersion = 1
        note.drawingFileName = "drawings/\(note.id.uuidString)/missing.drawing"
        XCTAssertThrowsError(try controller.loadDrawing(for: note))
        note.drawingFileName = nil
        note.drawingChecksum = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try controller.loadDrawing(for: note))
    }

    func testEverySaveFailurePreservesCommittedTitleMetadataAndBytesThenRetries() throws {
        for existing in [false, true] {
            for failure in ["capacity", "write", "read", "checksum", "rename", "commit"] {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                var committed: SavedNoteSnapshot!
                do {
                    let fileSystem = FaultInjectingFileSystem(rootURL: root)
                    let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
                    let context = ModelContext(container)
                    context.autosaveEnabled = true
                    let controller = NotePersistenceController(
                        modelContext: context,
                        fileSystem: fileSystem,
                        clock: { Date(timeIntervalSince1970: 200) },
                        commitMetadata: {
                            XCTAssertFalse(context.autosaveEnabled, "Title and drawing metadata must share one explicit commit")
                            if fileSystem.failMetadataCommit { throw NotePersistenceError.metadataCommitFailed }
                            try context.save()
                        }
                    )
                    let note = NoteRecord(title: "Committed", now: Date(timeIntervalSince1970: 10))
                    context.insert(note)
                    try context.save()
                    if existing { try controller.save(note: note, drawing: nonemptyDrawing(offset: 0)) }
                    let old = try SavedNoteSnapshot(note: note, root: root)
                    let session = NoteEditingSession(note: note, persistence: controller)
                    let draft = nonemptyDrawing(offset: 100)
                    session.updateTitle("Draft")
                    session.updateDrawing(draft)
                    XCTAssertEqual(note.title, "Committed", "Draft must not enter an autosaving model")
                    try context.save()
                    try assertReopenedStore(root: root, equals: old)

                    switch failure {
                    case "capacity": fileSystem.availableCapacity = 0
                    case "write": fileSystem.failNextWrite = true
                    case "read": fileSystem.failNextTemporaryRead = true
                    case "checksum": fileSystem.corruptNextTemporaryRead = true
                    case "rename": fileSystem.failNextMove = true
                    default: fileSystem.failMetadataCommit = true
                    }
                    session.flushSave()

                    XCTAssertEqual(session.saveState, .saveFailed, failure)
                    XCTAssertTrue(session.hasUnsavedChanges)
                    XCTAssertNotNil(session.saveFailureMessage)
                    XCTAssertEqual(session.titleDraft, "Draft")
                    XCTAssertEqual(session.drawingDraft.dataRepresentation(), draft.dataRepresentation())
                    XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), old, failure)
                    XCTAssertTrue(context.autosaveEnabled)
                    // A subsequent autosave/explicit context save must still commit only the old values.
                    try context.save()
                    try assertReopenedStore(root: root, equals: old)

                    fileSystem.availableCapacity = .max
                    fileSystem.failMetadataCommit = false
                    session.flushSave()
                    XCTAssertEqual(session.saveState, .saved)
                    XCTAssertFalse(session.hasUnsavedChanges)
                    XCTAssertNil(session.saveFailureMessage)
                    XCTAssertEqual(note.title, "Draft")
                    XCTAssertEqual(note.updatedAt, Date(timeIntervalSince1970: 200))
                    XCTAssertEqual(note.drawingSchemaVersion, 1)
                    XCTAssertEqual(try controller.loadDrawing(for: note).strokes.count, 1)
                    XCTAssertEqual(try controller.loadDrawing(for: note).bounds, draft.bounds)
                    committed = try SavedNoteSnapshot(note: note, root: root)
                    XCTAssertNotEqual(committed.pointer, old.pointer)
                    if let pointer = old.pointer {
                        XCTAssertFalse(fileSystem.fileExists(at: root.appendingPathComponent(pointer)))
                    }
                }
                // Reopen the actual disk store after the editing context/container have left scope.
                try assertReopenedStore(root: root, equals: committed)
            }
        }
    }

    func testTitleOnlyEditCommitsWithVerifiedNonemptyDrawingAndReopens() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved: SavedNoteSnapshot!
        do {
            let fileSystem = LocalNoteFileSystem(rootURL: root)
            let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
            let context = ModelContext(container)
            let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
            let note = NoteRecord(title: "Before")
            context.insert(note)
            try context.save()
            try controller.save(note: note, drawing: nonemptyDrawing(offset: 0))
            let original = try SavedNoteSnapshot(note: note, root: root)
            let session = NoteEditingSession(note: note, persistence: controller)
            session.updateTitle("Title only")
            XCTAssertEqual(note.title, "Before")
            XCTAssertTrue(session.requestLeave())
            XCTAssertEqual(session.saveState, .saved)
            saved = try SavedNoteSnapshot(note: note, root: root)
            XCTAssertEqual(saved.title, "Title only")
            let originalDrawing = try PKDrawing(data: XCTUnwrap(original.bytes))
            let savedDrawing = try PKDrawing(data: XCTUnwrap(saved.bytes))
            XCTAssertEqual(savedDrawing.strokes.count, originalDrawing.strokes.count)
            XCTAssertEqual(savedDrawing.bounds, originalDrawing.bounds)
            XCTAssertEqual(savedDrawing.strokes.first?.path.first?.location, originalDrawing.strokes.first?.path.first?.location)
            XCTAssertEqual(saved.pointer, original.pointer, "A title-only save keeps the verified drawing generation")
            XCTAssertEqual(saved.checksum, original.checksum)
            XCTAssertEqual(saved.bytes, original.bytes)
        }
        try assertReopenedStore(root: root, equals: saved)
    }

    func testTitleOnlySaveNeedsNoCapacityOrDrawingWriteAndRollsBackFailedCommit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var committed: SavedNoteSnapshot!
        do {
            let fileSystem = FaultInjectingFileSystem(rootURL: root)
            let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
            let context = ModelContext(container)
            let controller = NotePersistenceController(
                modelContext: context,
                fileSystem: fileSystem,
                clock: { Date(timeIntervalSince1970: 300) },
                commitMetadata: {
                    if fileSystem.failMetadataCommit { throw NotePersistenceError.metadataCommitFailed }
                    try context.save()
                }
            )
            let note = NoteRecord(title: "Before", now: Date(timeIntervalSince1970: 10))
            context.insert(note)
            try context.save()
            try controller.save(note: note, drawing: nonemptyDrawing(offset: 0))
            let original = try SavedNoteSnapshot(note: note, root: root)
            let drawingDirectory = root.appendingPathComponent("drawings/\(note.id.uuidString)")
            let originalFiles = try FileManager.default.contentsOfDirectory(atPath: drawingDirectory.path).sorted()
            let session = NoteEditingSession(note: note, persistence: controller)

            // A failed metadata commit restores the committed title and keeps the pointer.
            session.updateTitle("Failed title")
            fileSystem.failMetadataCommit = true
            session.flushSave()
            XCTAssertEqual(session.saveState, .saveFailed)
            XCTAssertTrue(session.hasUnsavedChanges)
            XCTAssertEqual(session.titleDraft, "Failed title")
            XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), original)

            // No capacity is needed and any drawing write would fail the save.
            fileSystem.failMetadataCommit = false
            fileSystem.availableCapacity = 0
            fileSystem.failNextWrite = true
            session.updateTitle("After")
            session.flushSave()
            XCTAssertEqual(session.saveState, .saved)
            XCTAssertFalse(session.hasUnsavedChanges)
            XCTAssertTrue(fileSystem.failNextWrite, "A title-only save must not write a drawing file")
            committed = try SavedNoteSnapshot(note: note, root: root)
            XCTAssertEqual(committed.title, "After")
            XCTAssertEqual(committed.updatedAt, Date(timeIntervalSince1970: 300))
            XCTAssertEqual(committed.pointer, original.pointer)
            XCTAssertEqual(committed.checksum, original.checksum)
            XCTAssertEqual(committed.bytes, original.bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drawingDirectory.path).sorted(), originalFiles)

            // A later drawing edit still creates a new verified generation.
            fileSystem.availableCapacity = .max
            fileSystem.failNextWrite = false
            session.updateDrawing(nonemptyDrawing(offset: 100))
            session.flushSave()
            XCTAssertEqual(session.saveState, .saved)
            XCTAssertNotEqual(note.drawingFileName, original.pointer)
            XCTAssertEqual(try controller.loadDrawing(for: note).bounds, nonemptyDrawing(offset: 100).bounds)
            committed = try SavedNoteSnapshot(note: note, root: root)
        }
        try assertReopenedStore(root: root, equals: committed)
    }

    func testDrawingEchoIsNotDirtyAndRealEditsSkipSerialization() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        let note = NoteRecord(title: "Large")
        context.insert(note)
        try context.save()
        let large = largeDrawing(strokeCount: 2000)
        try controller.save(note: note, drawing: large)
        let session = NoteEditingSession(note: note, persistence: controller)

        // Programmatic assignment echoes the loaded value, possibly as a decoded copy.
        session.updateDrawing(session.drawingDraft)
        session.updateDrawing(try PKDrawing(data: session.drawingDraft.dataRepresentation()))
        XCTAssertFalse(session.hasUnsavedChanges, "Re-assigning the same drawing must not mark it dirty")

        var appended = session.drawingDraft
        appended.strokes.append(contentsOf: nonemptyDrawing(offset: 900).strokes)
        XCTAssertTrue(NoteEditingSession.differs(appended, from: session.drawingDraft))
        var erased = session.drawingDraft
        erased.strokes.removeLast()
        XCTAssertTrue(NoteEditingSession.differs(erased, from: session.drawingDraft))

        // The stroke-count path must cost far less than the two full serializations it replaces.
        let clock = ContinuousClock()
        let fastPath = clock.measure {
            for _ in 0..<20 { _ = NoteEditingSession.differs(appended, from: session.drawingDraft) }
        }
        let serialization = clock.measure {
            for _ in 0..<20 { _ = appended.dataRepresentation() != session.drawingDraft.dataRepresentation() }
        }
        print("Drawing change detection for 2000 strokes x20: fast path \(fastPath), serialization \(serialization)")
        XCTAssertLessThan(fastPath * 5, serialization)

        session.updateDrawing(appended)
        XCTAssertTrue(session.hasUnsavedChanges)
        session.flushSave()
        XCTAssertEqual(session.saveState, .saved)
        XCTAssertEqual(try controller.loadDrawing(for: note).strokes.count, 2001)
    }

    func testLoadFailuresBlockTitleDrawingAutosaveManualSaveAndLeaveWrites() async throws {
        for failure in ["schema", "partialPointer", "partialChecksum", "path", "missing", "checksum", "decode"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var unchanged: SavedNoteSnapshot!
            do {
                let fileSystem = FaultInjectingFileSystem(rootURL: root)
                let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
                let context = ModelContext(container)
                let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
                let note = NoteRecord(title: "Do not overwrite")
                context.insert(note)
                try context.save()
                try controller.save(note: note, drawing: nonemptyDrawing(offset: 0))
                let validPointer = try XCTUnwrap(note.drawingFileName)
                let validBytes = try Data(contentsOf: root.appendingPathComponent(validPointer))
                switch failure {
                case "schema": note.drawingSchemaVersion = 99
                case "partialPointer": note.drawingChecksum = nil
                case "partialChecksum": note.drawingFileName = nil
                case "path": note.drawingFileName = "drawings/../metadata.store"
                case "missing": try FileManager.default.removeItem(at: root.appendingPathComponent(validPointer))
                case "checksum": note.drawingChecksum = String(repeating: "0", count: 64)
                default:
                    let invalidBytes = Data("not a PKDrawing".utf8)
                    try invalidBytes.write(to: root.appendingPathComponent(validPointer))
                    note.drawingChecksum = invalidBytes.sha256HexForTest
                }
                try context.save()
                unchanged = try SavedNoteSnapshot(note: note, root: root)
                let generationURLs = try fileSystem.contentsOfDirectory(at: root.appendingPathComponent("drawings/\(note.id.uuidString)"))
                let generationBytes = try generationURLs.map { try Data(contentsOf: $0) }
                let sleeper = ControlledDebounceSleeper()
                let session = NoteEditingSession(note: note, persistence: controller, waitForDebounce: sleeper.wait)
                XCTAssertFalse(session.canEdit, failure)
                XCTAssertNotNil(session.loadFailureMessage)
                XCTAssertThrowsError(try controller.loadDrawing(for: note))
                session.updateTitle("Forbidden")
                session.updateDrawing(nonemptyDrawing(offset: 100))
                session.flushSave()
                XCTAssertTrue(session.requestLeave())
                await Task.yield()
                XCTAssertTrue(sleeper.delays.isEmpty, "Load failure must not schedule autosave")
                XCTAssertFalse(session.hasUnsavedChanges)
                XCTAssertEqual(session.titleDraft, "Do not overwrite")
                XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), unchanged)
                controller.cleanupOrphans(for: note) // Library also invokes cleanup before opening Editor.
                XCTAssertEqual(try fileSystem.contentsOfDirectory(at: root.appendingPathComponent("drawings/\(note.id.uuidString)")).count, generationURLs.count)
                XCTAssertEqual(try generationURLs.map { try Data(contentsOf: $0) }, generationBytes)
                try assertReopenedStore(root: root, equals: unchanged)

                // Retry uses the same record after the test fixture's corruption is repaired.
                note.drawingSchemaVersion = 1
                note.drawingFileName = validPointer
                note.drawingChecksum = validBytes.sha256HexForTest
                try validBytes.write(to: root.appendingPathComponent(validPointer))
                try context.save()
                session.reload()
                XCTAssertTrue(session.canEdit)
                XCTAssertNil(session.loadFailureMessage)
                XCTAssertEqual(session.drawingDraft.strokes.count, 1)
                unchanged = try SavedNoteSnapshot(note: note, root: root)
            }
            try assertReopenedStore(root: root, equals: unchanged)
        }
    }

    func testDebounceUses450msCancelsPreviousEditsAndBackgroundFlushRetriesFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        let note = NoteRecord(title: "Original")
        context.insert(note)
        try context.save()
        let sleeper = ControlledDebounceSleeper()
        let session = NoteEditingSession(note: note, persistence: controller, waitForDebounce: sleeper.wait)
        session.updateDrawing(nonemptyDrawing(offset: 0))
        await sleeper.waitForCallCount(1)
        session.updateTitle("Latest")
        await sleeper.waitForCallCount(2)
        XCTAssertEqual(sleeper.delays, [450_000_000, 450_000_000])
        XCTAssertEqual(session.saveState, .unsavedChanges)
        XCTAssertNil(note.drawingFileName)
        sleeper.release(at: 0)
        await Task.yield()
        XCTAssertNil(note.drawingFileName, "Cancelled debounce must not save")
        fileSystem.availableCapacity = 0
        sleeper.release(at: 1)
        for _ in 0..<100 where session.saveState != .saveFailed { await Task.yield() }
        XCTAssertEqual(session.saveState, .saveFailed)
        XCTAssertEqual(session.titleDraft, "Latest")
        XCTAssertEqual(session.drawingDraft.strokes.count, 1)

        fileSystem.availableCapacity = .max
        session.flushSave() // Scene background calls this exact method, including from Save failed.
        XCTAssertEqual(session.saveState, .saved)
        XCTAssertEqual(note.title, "Latest")
        try assertReopenedStore(root: root, equals: SavedNoteSnapshot(note: note, root: root))

        session.updateTitle("Background before debounce")
        await sleeper.waitForCallCount(3)
        session.flushSave()
        let pointer = note.drawingFileName
        sleeper.release(at: 2)
        await Task.yield()
        XCTAssertEqual(note.title, "Background before debounce")
        XCTAssertEqual(note.drawingFileName, pointer, "Background flush cancels pending timer")
        try assertReopenedStore(root: root, equals: SavedNoteSnapshot(note: note, root: root))

        session.updateDrawing(nonemptyDrawing(offset: 200))
        await sleeper.waitForCallCount(4)
        sleeper.release(at: 3)
        for _ in 0..<100 where session.saveState != .saved { await Task.yield() }
        XCTAssertEqual(session.saveState, .saved, "The latest debounce also saves without a manual flush")
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try controller.loadDrawing(for: note).bounds, nonemptyDrawing(offset: 200).bounds)
        try assertReopenedStore(root: root, equals: SavedNoteSnapshot(note: note, root: root))
    }

    func testLeaveFailureRetainsDraftUntilRetryOrExplicitWarnedDiscard() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultInjectingFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        let controller = NotePersistenceController(modelContext: context, fileSystem: fileSystem)
        let note = NoteRecord(title: "Old")
        context.insert(note)
        try context.save()
        try controller.save(note: note, drawing: nonemptyDrawing(offset: 0))
        let session = NoteEditingSession(note: note, persistence: controller)
        XCTAssertFalse(session.confirmDiscard(), "Discard requires the leave loss warning first")
        session.updateTitle("Retained")
        session.updateDrawing(nonemptyDrawing(offset: 100))
        fileSystem.availableCapacity = 0
        XCTAssertFalse(session.requestLeave())
        XCTAssertTrue(session.needsDiscardConfirmation)
        XCTAssertEqual(session.titleDraft, "Retained")
        XCTAssertEqual(session.drawingDraft.bounds, nonemptyDrawing(offset: 100).bounds)
        session.cancelLeave()
        XCTAssertFalse(session.needsDiscardConfirmation)
        XCTAssertTrue(session.hasUnsavedChanges)
        session.reload()
        XCTAssertEqual(session.titleDraft, "Retained", "Reload must not discard an editable draft")
        fileSystem.availableCapacity = .max
        XCTAssertTrue(session.requestLeave())
        XCTAssertEqual(note.title, "Retained")
        let saved = try SavedNoteSnapshot(note: note, root: root)

        session.updateTitle("Discard me")
        session.updateDrawing(nonemptyDrawing(offset: 200))
        fileSystem.availableCapacity = 0
        XCTAssertFalse(session.requestLeave())
        XCTAssertTrue(session.confirmDiscard())
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.titleDraft, "Retained")
        XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), saved)
        try assertReopenedStore(root: root, equals: saved)
    }

    // MARK: - Startup admission and generation revocation

    func testStartupNormalAdmissionReadsMarkerBeforeCreatingContainer() throws {
        for marker in [nil, RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let markerStore = StartupRecordingMarkerStore()
            markerStore.marker = marker
            var events: [String] = []
            markerStore.onRead = { events.append("read") }
            let startup = NoteStartupController(markerStore: markerStore) {
                events.append("open")
                return try NotePersistenceController.makeContainer(fileSystem: LocalNoteFileSystem(rootURL: root), inMemory: true)
            }
            if case .checking = startup.state {} else { XCTFail("Initialization must not open the store") }
            XCTAssertTrue(events.isEmpty)

            startup.recheck()

            if case .ready = startup.state {} else { XCTFail("Verified storage should open") }
            XCTAssertEqual(events, ["read", "open"])
            XCTAssertEqual(markerStore.writeCount, 0)
        }
    }

    func testStartupRootRecoveryBlocksContainerAndPreservesAllFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try makeStartupFixture(root: root)
        let marker = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "post-switch")
        try fileSystem.writeAndFlush(try JSONEncoder().encode(marker), to: root.appendingPathComponent("restore-state.json"))
        let before = try StartupFileSnapshot(root: root)
        fileSystem.mutations.removeAll()
        var opens = 0
        let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
            opens += 1
            throw BackupEnvelopeError.invalidMetadata
        }

        startup.recheck()
        assertStartupBlocked(startup, by: .recoveryRequired)
        startup.recheck() // Retry cannot clear the recovery marker.
        assertStartupBlocked(startup, by: .recoveryRequired)

        XCTAssertEqual(opens, 0)
        XCTAssertEqual(try LocalRestoreMarkerStore(fileSystem: fileSystem).read(), marker)
        XCTAssertEqual(try StartupFileSnapshot(root: root), before)
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testInterruptedRecoveryMarkerRewriteKeepsStartupBlockedWithoutFallback() throws {
        let marker = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "post-switch")
        let rewrite = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "rollback")
        for crashPoint in MarkerCrashPoint.allCases {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeStartupFixture(root: root)
            let markerURL = root.appendingPathComponent("restore-state.json")
            let safetyURL = root.appendingPathComponent("Backups/safety/safety-test", isDirectory: true)
            try LocalRestoreMarkerStore(fileSystem: fixture).write(marker, fallbackDirectory: safetyURL)
            XCTAssertFalse(fixture.fileExists(at: safetyURL.appendingPathComponent("recovery-state.json")), "A successful root write leaves no fallback marker")
            let dataBefore = try StartupFileSnapshot(root: root).files.filter { $0.key != "restore-state.json" }

            let crashing = MarkerCrashFileSystem(rootURL: root, crashPoint: crashPoint)
            XCTAssertThrowsError(try LocalRestoreMarkerStore(fileSystem: crashing).write(rewrite, fallbackDirectory: safetyURL), "\(crashPoint)")
            XCTAssertTrue(crashing.crashed, "\(crashPoint)")
            XCTAssertFalse(crashing.removedURLs.contains(markerURL), "The previous marker must never be deleted: \(crashPoint)")

            // Restart with an ordinary file system.
            let restarted = LocalNoteFileSystem(rootURL: root)
            let survivor = try XCTUnwrap(try LocalRestoreMarkerStore(fileSystem: restarted).read(), "\(crashPoint)")
            XCTAssertTrue(survivor.recoveryRequired, "\(crashPoint)")
            XCTAssertEqual(survivor, crashPoint == .afterReplace ? rewrite : marker, "\(crashPoint)")
            var opens = 0
            let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: restarted)) {
                opens += 1
                throw BackupEnvelopeError.invalidMetadata
            }
            startup.recheck()
            assertStartupBlocked(startup, by: .recoveryRequired)
            XCTAssertEqual(opens, 0, "\(crashPoint)")
            let dataAfter = try StartupFileSnapshot(root: root).files.filter {
                $0.key != "restore-state.json" && !$0.key.hasSuffix(".tmp")
            }
            XCTAssertEqual(dataAfter, dataBefore, "Current data and safety backup must be unchanged: \(crashPoint)")
        }
    }

    func testResolvedMarkerReplacementReopensNormallyWithoutDeletingFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeStartupFixture(root: root)
        let markerURL = root.appendingPathComponent("restore-state.json")
        let required = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "post-switch")
        let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
        try LocalRestoreMarkerStore(fileSystem: fixture).write(required, fallbackDirectory: nil)
        fixture.mutations.removeAll()

        try LocalRestoreMarkerStore(fileSystem: fixture).write(resolved, fallbackDirectory: nil)

        // The replacement happens before any removal; the trailing remove is the
        // no-op cleanup of the already consumed temporary file.
        XCTAssertEqual(fixture.mutations.filter { $0 != "create" }, ["write", "replace", "remove"])
        XCTAssertTrue(fixture.fileExists(at: markerURL))
        XCTAssertEqual(try LocalRestoreMarkerStore(fileSystem: fixture).read(), resolved)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
        var opens = 0
        let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: LocalNoteFileSystem(rootURL: root))) {
            opens += 1
            return try NotePersistenceController.makeContainer(fileSystem: LocalNoteFileSystem(rootURL: root), inMemory: true)
        }
        startup.recheck()
        if case .ready = startup.state {} else { XCTFail("A resolved marker should allow normal startup") }
        XCTAssertEqual(opens, 1)
    }

    func testStartupFallbackRecoveryOverridesMissingOrResolvedRoot() throws {
        for hasRootMarker in [false, true] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileSystem = try makeStartupFixture(root: root)
            if hasRootMarker {
                let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: root.appendingPathComponent("restore-state.json"))
            }
            let recovery = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "rollback")
            try fileSystem.writeAndFlush(try JSONEncoder().encode(recovery), to: root.appendingPathComponent("Backups/safety/safety-test/recovery-state.json"))
            let before = try StartupFileSnapshot(root: root)
            fileSystem.mutations.removeAll()
            var opens = 0
            let markerStore = LocalRestoreMarkerStore(fileSystem: fileSystem)
            let startup = NoteStartupController(markerStore: markerStore) {
                opens += 1
                throw BackupEnvelopeError.invalidMetadata
            }

            XCTAssertEqual(try markerStore.read(), recovery)
            startup.recheck()
            assertStartupBlocked(startup, by: .recoveryRequired)
            XCTAssertEqual(opens, 0)
            XCTAssertEqual(try StartupFileSnapshot(root: root), before)
            XCTAssertTrue(fileSystem.mutations.isEmpty)
        }
    }

    func testStartupCorruptAndUnknownRootAndFallbackMarkersFailClosed() throws {
        let invalidMarkers = [
            Data("not JSON".utf8),
            Data("{\"schema\":99,\"recoveryRequired\":false}".utf8),
            Data("{\"schema\":1,\"recoveryRequired\":\"false\"}".utf8)
        ]
        for path in ["restore-state.json", "Backups/safety/safety-test/recovery-state.json"] {
            for data in invalidMarkers {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fileSystem = try makeStartupFixture(root: root)
                let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: root.appendingPathComponent("restore-state.json"))
                try fileSystem.writeAndFlush(data, to: root.appendingPathComponent(path))
                let before = try StartupFileSnapshot(root: root)
                fileSystem.mutations.removeAll()
                var opens = 0
                let markerStore = LocalRestoreMarkerStore(fileSystem: fileSystem)
                let startup = NoteStartupController(markerStore: markerStore) {
                    opens += 1
                    throw BackupEnvelopeError.invalidMetadata
                }

                XCTAssertThrowsError(try markerStore.read(), path)
                startup.recheck()
                assertStartupBlocked(startup, by: .safetyCheckFailed)
                startup.recheck()
                assertStartupBlocked(startup, by: .safetyCheckFailed)
                XCTAssertEqual(opens, 0, path)
                XCTAssertEqual(try StartupFileSnapshot(root: root), before)
                XCTAssertTrue(fileSystem.mutations.isEmpty)
            }
        }
    }

    func testStartupRootAndFallbackReadFailuresDoNotTrustFileExists() throws {
        for path in ["restore-state.json", "Backups/safety/safety-test/recovery-state.json"] {
            for hidden in [false, true] {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fileSystem = try makeStartupFixture(root: root)
                let marker = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                let url = root.appendingPathComponent(path)
                try fileSystem.writeAndFlush(try JSONEncoder().encode(marker), to: url)
                let before = try StartupFileSnapshot(root: root)
                fileSystem.mutations.removeAll()
                fileSystem.readFailures.insert(url)
                if hidden { fileSystem.hiddenPaths.insert(url) }
                var opens = 0
                let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
                    opens += 1
                    throw BackupEnvelopeError.invalidMetadata
                }

                startup.recheck()

                assertStartupBlocked(startup, by: .safetyCheckFailed)
                XCTAssertEqual(opens, 0)
                XCTAssertEqual(try StartupFileSnapshot(root: root), before)
                XCTAssertTrue(fileSystem.mutations.isEmpty)
            }
        }
    }

    func testStartupSafetyDirectoryListFailureBlocksMissingOrResolvedRoot() throws {
        for hasRootMarker in [false, true] {
            for hidden in [false, true] {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fileSystem = try makeStartupFixture(root: root)
                if hasRootMarker {
                    let marker = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                    try fileSystem.writeAndFlush(try JSONEncoder().encode(marker), to: root.appendingPathComponent("restore-state.json"))
                }
                let before = try StartupFileSnapshot(root: root)
                fileSystem.mutations.removeAll()
                let safetyRoot = BackupManagedPaths.safetyRoot(for: fileSystem)
                fileSystem.directoryFailures.insert(safetyRoot)
                if hidden { fileSystem.hiddenPaths.insert(safetyRoot) }
                var opens = 0
                let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
                    opens += 1
                    throw BackupEnvelopeError.invalidMetadata
                }

                startup.recheck()

                assertStartupBlocked(startup, by: .safetyCheckFailed)
                XCTAssertEqual(opens, 0)
                XCTAssertEqual(try StartupFileSnapshot(root: root), before)
                XCTAssertTrue(fileSystem.mutations.isEmpty)
            }
        }
    }

    func testStartupConfirmedAbsenceAllowsFreshInstallWithoutCreatingFilesDuringCheck() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = StartupFaultFileSystem(rootURL: root.appendingPathComponent("not-created"))
        let before = try StartupFileSnapshot(root: root)
        var opens = 0
        let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
            opens += 1
            XCTAssertEqual(try StartupFileSnapshot(root: root), before, "Admission must not create the root")
            return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        }

        startup.recheck()

        if case .ready = startup.state {} else { XCTFail("A confirmed absent root is a fresh install") }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(try StartupFileSnapshot(root: root), before)
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testStartupResolvedFallbacksAndMarkerFreeSafetyBackupsAllowOpenUnchanged() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try makeStartupFixture(root: root)
        let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: nil)
        try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: root.appendingPathComponent("restore-state.json"))
        try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: root.appendingPathComponent("Backups/safety/safety-test/recovery-state.json"))
        try fileSystem.createDirectory(at: root.appendingPathComponent("Backups/safety/safety-without-marker"))
        let before = try StartupFileSnapshot(root: root)
        fileSystem.mutations.removeAll()
        var opens = 0
        let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
            opens += 1
            return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        }

        startup.recheck()

        if case .ready = startup.state {} else { XCTFail("Resolved fallback markers should not block") }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(try StartupFileSnapshot(root: root), before)
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testStartupStoreOpenFailureRetryAlwaysRepeatsAdmissionWithoutMutatingFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try makeStartupFixture(root: root)
        let before = try StartupFileSnapshot(root: root)
        fileSystem.mutations.removeAll()
        let markerStore = StartupRecordingMarkerStore()
        var events: [String] = []
        markerStore.onRead = { events.append("read") }
        var opens = 0
        let startup = NoteStartupController(markerStore: markerStore) {
            events.append("open")
            opens += 1
            if opens < 3 { throw BackupEnvelopeError.invalidMetadata }
            return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        }

        startup.recheck()
        assertStartupBlocked(startup, by: .storeOpenFailed)
        startup.recheck()
        assertStartupBlocked(startup, by: .storeOpenFailed)
        startup.recheck()
        if case .ready = startup.state {} else { XCTFail("A successful retry should open verified storage") }

        XCTAssertEqual(events, ["read", "open", "read", "open", "read", "open"])
        XCTAssertEqual(markerStore.writeCount, 0)
        XCTAssertEqual(try StartupFileSnapshot(root: root), before)
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testStartupRetryCannotBypassNewRecoveryOrUnreadableMarker() throws {
        let markerStore = StartupRecordingMarkerStore()
        var opens = 0
        let startup = NoteStartupController(markerStore: markerStore) {
            opens += 1
            throw BackupEnvelopeError.invalidMetadata
        }
        startup.recheck()
        assertStartupBlocked(startup, by: .storeOpenFailed)

        markerStore.marker = RestoreMarker(recoveryRequired: true, safetyBackupPath: "retained", lastFailureState: "rollback")
        startup.recheck()
        assertStartupBlocked(startup, by: .recoveryRequired)
        markerStore.readError = BackupEnvelopeError.invalidManifest
        startup.recheck()
        assertStartupBlocked(startup, by: .safetyCheckFailed)

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(markerStore.readCount, 3)
        XCTAssertEqual(markerStore.writeCount, 0)
    }

    func testStartupRecheckDropsReadyContainerOnRecoveryReadOrOpenFailure() throws {
        for failure in [NoteStartupFailure.recoveryRequired, .safetyCheckFailed, .storeOpenFailed] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileSystem = try makeStartupFixture(root: root)
            let before = try StartupFileSnapshot(root: root)
            fileSystem.mutations.removeAll()
            let markerStore = StartupRecordingMarkerStore()
            var opens = 0
            let startup = NoteStartupController(markerStore: markerStore) {
                opens += 1
                if opens > 1 { throw BackupEnvelopeError.invalidMetadata }
                return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
            }
            markerStore.onRead = { [weak startup] in
                guard let startup else { return XCTFail("Startup controller should still be alive") }
                if case .checking = startup.state {} else { XCTFail("Discard the old ready state before reading markers") }
            }
            startup.recheck()
            if case .ready = startup.state {} else { XCTFail("First open should succeed") }
            switch failure {
            case .recoveryRequired:
                markerStore.marker = RestoreMarker(recoveryRequired: true, safetyBackupPath: "retained", lastFailureState: nil)
            case .safetyCheckFailed:
                markerStore.readError = BackupEnvelopeError.invalidManifest
            case .storeOpenFailed:
                break
            }

            startup.recheck() // The root's store-switch receiver uses this same entry point.

            assertStartupBlocked(startup, by: failure)
            XCTAssertEqual(opens, failure == .storeOpenFailed ? 2 : 1)
            XCTAssertEqual(markerStore.readCount, 2)
            XCTAssertEqual(markerStore.writeCount, 0)
            XCTAssertEqual(try StartupFileSnapshot(root: root), before)
            XCTAssertTrue(fileSystem.mutations.isEmpty)
        }
    }

    func testStartupRetryAfterExternalMarkerRepairDoesNotPerformItsOwnRepair() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try makeStartupFixture(root: root)
        let markerURL = root.appendingPathComponent("restore-state.json")
        try fileSystem.writeAndFlush(Data("corrupt marker".utf8), to: markerURL)
        let corruptSnapshot = try StartupFileSnapshot(root: root)
        fileSystem.mutations.removeAll()
        var opens = 0
        let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
            opens += 1
            return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        }
        startup.recheck()
        assertStartupBlocked(startup, by: .safetyCheckFailed)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(try StartupFileSnapshot(root: root), corruptSnapshot)
        XCTAssertTrue(fileSystem.mutations.isEmpty)

        // Only the fixture repairs the marker; the retry action has no repair capability.
        let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
        try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: markerURL)
        let repairedSnapshot = try StartupFileSnapshot(root: root)
        fileSystem.mutations.removeAll()
        startup.recheck()

        if case .ready = startup.state {} else { XCTFail("An externally repaired marker may pass a fresh check") }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(try StartupFileSnapshot(root: root), repairedSnapshot)
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testStartupSuccessfulStoreSwitchGetsNewContainerIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let markerStore = StartupRecordingMarkerStore()
        let startup = NoteStartupController(markerStore: markerStore) {
            try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: true)
        }
        startup.recheck()
        guard case .ready(let first) = startup.state else { return XCTFail("First open should succeed") }

        startup.recheck()

        guard case .ready(let second) = startup.state else { return XCTFail("Second open should succeed") }
        XCTAssertFalse(first.container === second.container, "Library identity must change with the container")
        XCTAssertEqual(markerStore.readCount, 2)
        XCTAssertEqual(markerStore.writeCount, 0)
    }

    func testStartupDisappearingKnownMarkerOrSafetyDirectoryIsNotConfirmedAbsence() throws {
        for path in ["restore-state.json", "Backups/safety/safety-test/recovery-state.json", "Backups/safety"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileSystem = try makeStartupFixture(root: root)
            let url = root.appendingPathComponent(path)
            if path == "Backups/safety" {
                fileSystem.directoryFailures.insert(BackupManagedPaths.safetyRoot(for: fileSystem))
            } else {
                let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: url)
                fileSystem.readFailures.insert(url)
            }
            fileSystem.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            let before = try StartupFileSnapshot(root: root)
            fileSystem.mutations.removeAll()
            var opens = 0
            let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
                opens += 1
                throw BackupEnvelopeError.invalidMetadata
            }

            startup.recheck()

            assertStartupBlocked(startup, by: .safetyCheckFailed)
            XCTAssertEqual(opens, 0)
            XCTAssertEqual(try StartupFileSnapshot(root: root), before)
            XCTAssertTrue(fileSystem.mutations.isEmpty)
        }
    }

    func testStartupRevokesOldAdmissionBeforeMarkerReadAndCreatesNewGenerationOnlyAfterOpen() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let markerStore = StartupRecordingMarkerStore()
        var oldAdmission: NoteWriteAdmission?
        let startup = NoteStartupController(markerStore: markerStore) {
            if let oldAdmission { XCTAssertFalse(oldAdmission.isAllowed) }
            return try NotePersistenceController.makeContainer(fileSystem: LocalNoteFileSystem(rootURL: root), inMemory: true)
        }
        if case .checking = startup.state {} else { XCTFail("No generation should exist before checking") }
        startup.recheck()
        guard case .ready(let firstGeneration) = startup.state else { return XCTFail("First open should succeed") }
        let first = firstGeneration.writeAdmission
        XCTAssertTrue(first.isAllowed)
        oldAdmission = first
        markerStore.onRead = { [weak startup] in
            guard let startup else { return XCTFail("Startup controller should still be alive") }
            XCTAssertFalse(first.isAllowed, "Revoke before marker read or any view teardown")
            if case .checking = startup.state {} else { XCTFail("Old Library must already be detached with no generation") }
        }

        startup.recheck()

        guard case .ready(let secondGeneration) = startup.state else { return XCTFail("Second open should succeed") }
        let second = secondGeneration.writeAdmission
        XCTAssertTrue(second.isAllowed)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.isAllowed, "A successful recheck must never revive an old generation")
        XCTAssertEqual(markerStore.readCount, 2)
        XCTAssertEqual(markerStore.writeCount, 0)
    }

    func testStartupRecheckPermanentlyBlocksDirtyOldSessionTeardownTimerAndRetryWrites() async throws {
        for failure in [NoteStartupFailure.recoveryRequired, .safetyCheckFailed, .storeOpenFailed] {
            for timerOrder in ["timerFirst", "teardownFirst", "afterSuccessfulRetry"] {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fileSystem = StartupFaultFileSystem(rootURL: root)
                let markerURL = root.appendingPathComponent("restore-state.json")
                let fallbackURL = root.appendingPathComponent("Backups/safety/safety-test/recovery-state.json")
                let resolved = RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil)
                try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: markerURL)
                var opens = 0
                var failOpen = false
                let startup = NoteStartupController(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
                    opens += 1
                    if failOpen { throw BackupEnvelopeError.invalidMetadata }
                    // Only the first generation uses the old disk store; retry is an isolated factory result.
                    return try NotePersistenceController.makeContainer(fileSystem: fileSystem, inMemory: opens > 1)
                }
                startup.recheck()
                guard case .ready(let generation) = startup.state else { return XCTFail("First open should succeed") }
                let oldAdmission = generation.writeAdmission
                let context = ModelContext(generation.container)
                context.autosaveEnabled = true
                var commits = 0
                let persistence = NotePersistenceController(modelContext: context, fileSystem: fileSystem, commitMetadata: {
                    commits += 1
                    try context.save()
                })
                let note = NoteRecord(title: "Committed", now: Date(timeIntervalSince1970: 10))
                context.insert(note)
                try context.save()
                try persistence.save(note: note, drawing: nonemptyDrawing(offset: 0))
                let saved = try SavedNoteSnapshot(note: note, root: root)
                let safetyURL = root.appendingPathComponent("Backups/safety/safety-test")
                try fileSystem.writeAndFlush(Data("untouched safety metadata".utf8), to: safetyURL.appendingPathComponent("metadata.store"))
                try fileSystem.writeAndFlush(try XCTUnwrap(saved.bytes), to: safetyURL.appendingPathComponent("drawings/old.drawing"))
                try fileSystem.writeAndFlush(Data("complete".utf8), to: safetyURL.appendingPathComponent("safety-complete.json"))
                let sleeper = ControlledDebounceSleeper()
                let session = NoteEditingSession(
                    note: note,
                    persistence: persistence,
                    canWrite: { oldAdmission.isAllowed },
                    waitForDebounce: sleeper.wait
                )
                let draft = nonemptyDrawing(offset: 100)
                session.updateTitle("Pending title")
                session.updateDrawing(draft)
                await sleeper.waitForCallCount(1)
                XCTAssertTrue(session.canEdit)
                XCTAssertTrue(session.hasUnsavedChanges)
                XCTAssertEqual(note.title, "Committed")
                switch failure {
                case .recoveryRequired:
                    let recovery = RestoreMarker(recoveryRequired: true, safetyBackupPath: "Backups/safety/safety-test", lastFailureState: "rollback")
                    try fileSystem.writeAndFlush(try JSONEncoder().encode(recovery), to: markerURL)
                case .safetyCheckFailed:
                    try fileSystem.writeAndFlush(Data("corrupt fallback".utf8), to: fallbackURL)
                case .storeOpenFailed:
                    failOpen = true
                }
                let before = try StartupFileSnapshot(root: root)
                fileSystem.mutations.removeAll()

                startup.recheck()

                assertStartupBlocked(startup, by: failure)
                XCTAssertEqual(opens, failure == .storeOpenFailed ? 2 : 1)
                // The blocked state has no container or admission payload.
                XCTAssertFalse(oldAdmission.isAllowed)
                XCTAssertFalse(session.canEdit)
                if timerOrder == "timerFirst" {
                    sleeper.release(at: 0) // Not cancelled: the admission guard must stop this autosave.
                    await sleeper.waitForCompletionCount(1)
                }
                if timerOrder != "afterSuccessfulRetry" {
                    session.flushSave() // Editor onDisappear / Library navigation flush.
                    session.flushSave() // Background flush.
                    session.flushSave() // Manual save retry.
                    if timerOrder == "teardownFirst" {
                        sleeper.release(at: 0)
                        await sleeper.waitForCompletionCount(1)
                    }
                }
                session.updateTitle("Forbidden title")
                session.updateDrawing(nonemptyDrawing(offset: 200))
                session.reload()
                XCTAssertEqual(session.titleDraft, "Pending title")
                XCTAssertEqual(session.drawingDraft.dataRepresentation(), draft.dataRepresentation())
                XCTAssertTrue(session.hasUnsavedChanges)
                XCTAssertEqual(commits, 1)
                XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), saved)
                XCTAssertEqual(try StartupFileSnapshot(root: root), before)
                XCTAssertTrue(fileSystem.mutations.isEmpty)

                // Only the fixture resolves the hazard. Neither recheck nor the editor repairs anything.
                try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: markerURL)
                if failure == .safetyCheckFailed {
                    try fileSystem.writeAndFlush(try JSONEncoder().encode(resolved), to: fallbackURL)
                }
                failOpen = false
                let beforeRetry = try StartupFileSnapshot(root: root)
                fileSystem.mutations.removeAll()
                startup.recheck()
                guard case .ready(let newGeneration) = startup.state else { return XCTFail("Safe retry should succeed") }
                let newAdmission = newGeneration.writeAdmission
                XCTAssertTrue(newAdmission.isAllowed)
                XCTAssertFalse(newAdmission === oldAdmission)
                XCTAssertFalse(oldAdmission.isAllowed)
                XCTAssertFalse(session.canEdit)
                if timerOrder == "afterSuccessfulRetry" {
                    sleeper.release(at: 0) // The old pending timer is still not cancelled, even after a new open.
                    await sleeper.waitForCompletionCount(1)
                }
                session.updateTitle("Still forbidden")
                session.updateDrawing(nonemptyDrawing(offset: 300))
                session.flushSave()
                XCTAssertFalse(session.requestLeave())
                session.reload()
                XCTAssertTrue(session.hasUnsavedChanges)
                XCTAssertEqual(session.titleDraft, "Pending title")
                XCTAssertEqual(session.drawingDraft.dataRepresentation(), draft.dataRepresentation())
                XCTAssertEqual(commits, 1, "No old-context commit is permitted after revocation")
                XCTAssertEqual(try SavedNoteSnapshot(note: note, root: root), saved)
                XCTAssertEqual(try StartupFileSnapshot(root: root), beforeRetry)
                XCTAssertTrue(fileSystem.mutations.isEmpty)
                try assertReopenedStore(root: root, equals: saved)
            }
        }
    }

    // MARK: - Fixture and assertion helpers

    private func assertStartupBlocked(_ startup: NoteStartupController, by failure: NoteStartupFailure, file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked(let actual) = startup.state else {
            return XCTFail("Unsafe storage must not retain a ready container", file: file, line: line)
        }
        XCTAssertEqual(actual, failure, file: file, line: line)
    }

    private func makeStartupFixture(root: URL) throws -> StartupFaultFileSystem {
        let fileSystem = StartupFaultFileSystem(rootURL: root)
        let files = [
            "metadata.store", "metadata.store-wal", "metadata.store-shm",
            "drawings/current/old.drawing", "thumbnails/current.png",
            "Backups/safety/safety-test/metadata.store",
            "Backups/safety/safety-test/drawings/current/old.drawing",
            "Backups/safety/safety-test/safety-complete.json"
        ]
        for path in files {
            try fileSystem.writeAndFlush(Data("unchanged: \(path)".utf8), to: root.appendingPathComponent(path))
        }
        return fileSystem
    }

    private func nonemptyDrawing(offset: CGFloat) -> PKDrawing {
        let points = [CGPoint(x: 20 + offset, y: 30), CGPoint(x: 70 + offset, y: 90)]
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 1))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    private func largeDrawing(strokeCount: Int) -> PKDrawing {
        let strokes = (0..<strokeCount).map { index -> PKStroke in
            let origin = CGPoint(x: CGFloat(index % 40) * 25, y: CGFloat(index / 40) * 18)
            let controlPoints = (0..<24).map { step in
                PKStrokePoint(
                    location: CGPoint(x: origin.x + CGFloat(step), y: origin.y + CGFloat(step % 6)),
                    timeOffset: Double(step) * 0.01,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 1))
            return PKStroke(ink: PKInk(.pen, color: .black), path: path)
        }
        return PKDrawing(strokes: strokes)
    }

    private func assertReopenedStore(root: URL, equals snapshot: SavedNoteSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let fileSystem = LocalNoteFileSystem(rootURL: root)
        let container = try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let records = try context.fetch(FetchDescriptor<NoteRecord>())
        XCTAssertEqual(records.count, 1, file: file, line: line)
        let reopened = try XCTUnwrap(records.first, file: file, line: line)
        XCTAssertEqual(try SavedNoteSnapshot(note: reopened, root: root), snapshot, file: file, line: line)
        if let bytes = snapshot.bytes, let drawing = try? PKDrawing(data: bytes) {
            let loaded = try? NotePersistenceController(modelContext: context, fileSystem: fileSystem).loadDrawing(for: reopened)
            if snapshot.schema == 1, snapshot.checksum == bytes.sha256HexForTest {
                XCTAssertEqual(loaded?.strokes.count, drawing.strokes.count, file: file, line: line)
                XCTAssertEqual(loaded?.bounds, drawing.bounds, file: file, line: line)
            }
        }
    }

    private func makeSimpleBackupData(title: String) throws -> Data {
        let id = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let metadata = BackupMetadata(notes: [
            BackupMetadataNote(
                id: id,
                title: title,
                createdAtUnixNanos: 10_000_000_000,
                updatedAtUnixNanos: 20_000_000_000,
                drawingFileName: nil,
                drawingChecksum: nil,
                drawingSchemaVersion: 1
            )
        ])
        return try BackupEnvelopeCodec().encode(metadata: metadata, drawings: [], createdAtUnixNanos: 30_000_000_000)
    }

    private func makeBackupEnvelopeFixture() throws -> Data {
        let noteID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let drawingPayload = Data([0x01, 0x02, 0x03, 0x04])
        let drawingPath = "drawings/\(noteID.uuidString.lowercased())/00000000-0000-0000-0000-000000000001-\(drawingPayload.sha256HexForTest).drawing"
        let metadata = BackupMetadata(notes: [
            BackupMetadataNote(
                id: noteID,
                title: "Reading",
                createdAtUnixNanos: 10_000_000_000,
                updatedAtUnixNanos: 20_000_000_000,
                drawingFileName: drawingPath,
                drawingChecksum: drawingPayload.sha256HexForTest,
                drawingSchemaVersion: 1
            )
        ])
        return try BackupEnvelopeCodec().encode(
            metadata: metadata,
            drawings: [BackupDrawingRecord(path: drawingPath, payload: drawingPayload)],
            createdAtUnixNanos: 30_000_000_000
        )
    }

    private func makeValidDrawingBackupData(title: String) throws -> (data: Data, drawingPath: String) {
        let id = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let payload = PKDrawing().dataRepresentation()
        XCTAssertNoThrow(try PKDrawing(data: payload))
        let checksum = payload.sha256HexForTest
        let path = "drawings/\(id.uuidString.lowercased())/00000000-0000-0000-0000-000000000004-\(checksum).drawing"
        let metadata = BackupMetadata(notes: [
            BackupMetadataNote(
                id: id,
                title: title,
                createdAtUnixNanos: 10_000_000_000,
                updatedAtUnixNanos: 20_000_000_000,
                drawingFileName: path,
                drawingChecksum: checksum,
                drawingSchemaVersion: 1
            )
        ])
        return (
            try BackupEnvelopeCodec().encode(
                metadata: metadata,
                drawings: [BackupDrawingRecord(path: path, payload: payload)],
                createdAtUnixNanos: 30_000_000_000
            ),
            path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CornellNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Data {
    var sha256HexForTest: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }

    func mutatingByte(at index: Int) -> Data {
        var copy = self
        if copy.indices.contains(index) {
            copy[index] ^= 0xff
        }
        return copy
    }

    var manifestByteRangeForTest: Range<Int>? {
        guard count >= 24 else { return nil }
        let length = Int(self[20]) | (Int(self[21]) << 8) | (Int(self[22]) << 16) | (Int(self[23]) << 24)
        return 24..<(24 + length)
    }
}

private struct StartupFileSnapshot: Equatable {
    let paths: [String]
    let files: [String: Data]

    init(root: URL) throws {
        paths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        var files: [String: Data] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files[path] = try Data(contentsOf: url)
            }
        }
        self.files = files
    }
}

private final class StartupFaultFileSystem: LocalNoteFileSystem {
    var readFailures: Set<URL> = []
    var directoryFailures: Set<URL> = []
    var hiddenPaths: Set<URL> = []
    var failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    var mutations: [String] = []

    override func fileExists(at url: URL) -> Bool {
        !hiddenPaths.contains(url) && super.fileExists(at: url)
    }

    override func readData(at url: URL) throws -> Data {
        if readFailures.contains(url) { throw failure }
        return try super.readData(at: url)
    }

    override func contentsOfDirectory(at url: URL) throws -> [URL] {
        if directoryFailures.contains(url) { throw failure }
        return try super.contentsOfDirectory(at: url)
    }

    override func createDirectory(at url: URL) throws {
        mutations.append("create")
        try super.createDirectory(at: url)
    }

    override func writeAndFlush(_ data: Data, to url: URL) throws {
        mutations.append("write")
        try super.writeAndFlush(data, to: url)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        mutations.append("move")
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    override func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        mutations.append("replace")
        try super.replaceItem(at: destinationURL, withItemAt: sourceURL)
    }

    override func removeItem(at url: URL) throws {
        mutations.append("remove")
        try super.removeItem(at: url)
    }
}

private enum MarkerCrashPoint: CaseIterable {
    case temporaryWrite
    case readBack
    case beforeReplace
    case afterReplace
}

/// Simulates a process kill: the crash point throws, and every later mutation fails,
/// so no recovery or fallback code can run after the interruption.
private final class MarkerCrashFileSystem: LocalNoteFileSystem {
    let crashPoint: MarkerCrashPoint
    private(set) var crashed = false
    private(set) var removedURLs: [URL] = []

    init(rootURL: URL, crashPoint: MarkerCrashPoint) {
        self.crashPoint = crashPoint
        super.init(rootURL: rootURL)
    }

    private func crash() -> Error {
        crashed = true
        return POSIXError(.EINTR)
    }

    override func createDirectory(at url: URL) throws {
        if crashed { throw crash() }
        try super.createDirectory(at: url)
    }

    override func writeAndFlush(_ data: Data, to url: URL) throws {
        if crashed || crashPoint == .temporaryWrite { throw crash() }
        try super.writeAndFlush(data, to: url)
    }

    override func readData(at url: URL) throws -> Data {
        if !crashed, crashPoint == .readBack, url.pathExtension == "tmp" { throw crash() }
        return try super.readData(at: url)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if crashed { throw crash() }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    override func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        if crashed || crashPoint == .beforeReplace { throw crash() }
        try super.replaceItem(at: destinationURL, withItemAt: sourceURL)
        if crashPoint == .afterReplace { throw crash() }
    }

    override func removeItem(at url: URL) throws {
        if crashed { throw crash() }
        removedURLs.append(url)
        try super.removeItem(at: url)
    }
}

private final class StartupRecordingMarkerStore: RestoreMarkerStore {
    var marker: RestoreMarker?
    var readError: Error?
    var onRead: (() -> Void)?
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func read() throws -> RestoreMarker? {
        readCount += 1
        onRead?()
        if let readError { throw readError }
        return marker
    }

    func write(_ marker: RestoreMarker, fallbackDirectory: URL?) throws {
        writeCount += 1
        XCTFail("Startup must never write or resolve a restore marker")
        throw BackupEnvelopeError.invalidManifest
    }
}

private struct SavedNoteSnapshot: Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let pointer: String?
    let checksum: String?
    let schema: Int
    let bytes: Data?

    @MainActor
    init(note: NoteRecord, root: URL) throws {
        id = note.id
        title = note.title
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        pointer = note.drawingFileName
        checksum = note.drawingChecksum
        schema = note.drawingSchemaVersion
        if let pointer,
           pointer.hasPrefix("drawings/\(note.id.uuidString)/"),
           !pointer.contains(".."),
           FileManager.default.fileExists(atPath: root.appendingPathComponent(pointer).path) {
            bytes = try Data(contentsOf: root.appendingPathComponent(pointer))
        } else {
            bytes = nil
        }
    }
}

@MainActor
private final class ControlledDebounceSleeper {
    private(set) var delays: [UInt64] = []
    private(set) var completionCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]

    func wait(_ nanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let index = delays.count
            continuations[index] = continuation
            delays.append(nanoseconds)
        }
        completionCount += 1
    }

    func waitForCompletionCount(_ count: Int) async {
        for _ in 0..<100 where completionCount < count { await Task.yield() }
        XCTAssertEqual(completionCount, count)
    }

    func waitForCallCount(_ count: Int) async {
        for _ in 0..<100 where delays.count < count { await Task.yield() }
        XCTAssertEqual(delays.count, count)
    }

    func release(at index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }
}

private final class FaultInjectingFileSystem: LocalNoteFileSystem {
    var availableCapacity: Int64 = .max
    var corruptNextRead = false
    var failNextTemporaryRead = false
    var corruptNextTemporaryRead = false
    var failNextWrite = false
    var failNextMove = false
    var failMetadataCommit = false
    var didRemoveAnything = false

    override func availableCapacity(for url: URL) throws -> Int64 { availableCapacity }

    override func readData(at url: URL) throws -> Data {
        if failNextTemporaryRead && url.pathExtension == "tmp" {
            failNextTemporaryRead = false
            throw NotePersistenceError.invalidDrawingData
        }
        let data = try super.readData(at: url)
        if corruptNextTemporaryRead && url.pathExtension == "tmp" {
            corruptNextTemporaryRead = false
            return data + Data([0xff])
        }
        if corruptNextRead {
            corruptNextRead = false
            var corrupted = data
            corrupted.append(0xff)
            return corrupted
        }
        return data
    }

    override func writeAndFlush(_ data: Data, to url: URL) throws {
        if failNextWrite {
            failNextWrite = false
            throw NotePersistenceError.metadataCommitFailed
        }
        try super.writeAndFlush(data, to: url)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if failNextMove {
            failNextMove = false
            throw NotePersistenceError.metadataCommitFailed
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    override func removeItem(at url: URL) throws {
        didRemoveAnything = true
        try super.removeItem(at: url)
    }

    func fileExists(forRelativePath path: String) -> Bool {
        fileExists(at: rootURL.appendingPathComponent(path))
    }
}

@MainActor
private final class RecordingModelStoreSwitcher: BackupModelStoreSwitcher {
    var didSwitch = false
    var didRollback = false
    var failPostSwitchReopen = false
    var failRollback = false
    private var reopenCount = 0

    func writeStagingStore(metadata: BackupMetadata, drawings: [BackupDrawingRecord], at stagingURL: URL) throws {}

    func reopenStore(at rootURL: URL, expectedMetadata: BackupMetadata) throws {}

    func atomicSwitch(to stagingURL: URL) throws {
        didSwitch = true
    }

    func reopenCurrent(expectedMetadata: BackupMetadata) throws {
        reopenCount += 1
        if failPostSwitchReopen && reopenCount == 1 { throw BackupEnvelopeError.invalidMetadata }
    }

    func rollback(from safetyBackupURL: URL) throws {
        didRollback = true
        if failRollback { throw BackupEnvelopeError.invalidMetadata }
    }
}

private final class RecordingMarkerStore: RestoreMarkerStore {
    var marker: RestoreMarker?
    var failWrite = false
    var failAfterFirstWrite = false
    private var writeCount = 0

    func read() throws -> RestoreMarker? { marker }

    func write(_ marker: RestoreMarker, fallbackDirectory: URL?) throws {
        writeCount += 1
        if failWrite || (failAfterFirstWrite && writeCount > 1) {
            throw BackupEnvelopeError.invalidMetadata
        }
        self.marker = marker
    }
}

@MainActor
private final class RecordingThumbnailRegenerator: BackupThumbnailRegenerator {
    var didRegenerate = false

    func regenerate(metadata: BackupMetadata, drawings: [BackupDrawingRecord]) throws {
        didRegenerate = true
    }
}

private struct FixedBackupUUIDSource: BackupUUIDSource {
    func makeUUID() -> UUID {
        UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    }
}

private final class RecordingDocumentProvider: DocumentProviderAdapter {
    var didExport = false
    var failExport = false
    var failure: BackupProviderError?

    func export(
        sourceURL: URL,
        destinationURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String,
        userConfirmedReplacement: Bool
    ) throws {
        if let failure { throw failure }
        if failExport { throw BackupProviderError.partialCopy }
        let data = try Data(contentsOf: sourceURL)
        XCTAssertEqual(UInt64(data.count), expectedSize)
        XCTAssertEqual(data.backupSHA256Hex, expectedSHA256)
        try data.write(to: destinationURL)
        didExport = true
    }

    func readImportedFile(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

private final class CountingManifestHasher: ManifestHasher {
    var hexCallCount = 0
    var digestCallCount = 0

    func sha256Hex(_ data: Data) -> String {
        hexCallCount += 1
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func digest(_ data: Data) -> Data {
        digestCallCount += 1
        return Data(SHA256.hash(data: data))
    }
}
