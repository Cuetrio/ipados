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

        let savedDrawing = PKDrawing()
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
        note.title = "After"
        let failingController = NotePersistenceController(
            modelContext: context,
            fileSystem: fileSystem,
            clock: { Date(timeIntervalSince1970: 200) },
            commitMetadata: { throw NotePersistenceError.metadataCommitFailed }
        )

        XCTAssertThrowsError(try failingController.save(note: note, drawing: PKDrawing()))
        XCTAssertEqual(note.drawingFileName, oldPointer)
        XCTAssertEqual(note.drawingChecksum, oldChecksum)
        XCTAssertEqual(note.updatedAt, oldUpdatedAt)
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: try XCTUnwrap(oldPointer)))
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
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: oldPointer))
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
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: oldPointer))
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
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: oldPointer))
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
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: oldPointer))
        controller.cleanupOrphans(for: note)
        XCTAssertTrue(try fileSystem.fileExists(forRelativePath: oldPointer))
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
        XCTAssertThrowsError(try BackupPathValidator.validate("/metadata.json"))
        XCTAssertThrowsError(try BackupPathValidator.validate("drawings/11111111-1111-1111-1111-111111111111/../metadata.store"))
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

private final class FaultInjectingFileSystem: LocalNoteFileSystem {
    var availableCapacity: Int64 = .max
    var corruptNextRead = false
    var failNextWrite = false
    var failNextMove = false
    var failMetadataCommit = false
    var didRemoveAnything = false

    override func availableCapacity(for url: URL) throws -> Int64 { availableCapacity }

    override func readData(at url: URL) throws -> Data {
        let data = try super.readData(at: url)
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
