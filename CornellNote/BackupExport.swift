import Foundation
import PencilKit
import SwiftData

struct BackupExportResult {
    let stagingURL: URL
    let destinationURL: URL
    let byteCount: UInt64
    let sha256: String
}

@MainActor
final class BackupExportCoordinator {
    private let modelContext: ModelContext
    private let fileSystem: BackupFileSystem
    private let encoder: BackupEnvelopeEncoder
    private let decoder: BackupEnvelopeDecoder
    private let clock: BackupClock
    private let uuidSource: BackupUUIDSource
    private let provider: DocumentProviderAdapter

    init(
        modelContext: ModelContext,
        fileSystem: BackupFileSystem,
        encoder: BackupEnvelopeEncoder = BackupEnvelopeCodec(),
        decoder: BackupEnvelopeDecoder = BackupEnvelopeCodec(),
        clock: BackupClock = SystemBackupClock(),
        uuidSource: BackupUUIDSource = SystemBackupUUIDSource(),
        provider: DocumentProviderAdapter = LocalDocumentProviderAdapter()
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.encoder = encoder
        self.decoder = decoder
        self.clock = clock
        self.uuidSource = uuidSource
        self.provider = provider
    }

    func export(to destinationURL: URL, userConfirmedReplacement: Bool = false) throws -> BackupExportResult {
        let staged = try makeVerifiedStagingFile()
        try provider.export(
            sourceURL: staged.url,
            destinationURL: destinationURL,
            expectedSize: UInt64(staged.data.count),
            expectedSHA256: staged.data.backupSHA256Hex,
            userConfirmedReplacement: userConfirmedReplacement
        )
        return BackupExportResult(
            stagingURL: staged.url,
            destinationURL: destinationURL,
            byteCount: UInt64(staged.data.count),
            sha256: staged.data.backupSHA256Hex
        )
    }

    func makeVerifiedEnvelope() throws -> Data {
        try makeVerifiedStagingFile().data
    }

    private func makeVerifiedStagingFile() throws -> (url: URL, data: Data) {
        let notes: [NoteRecord]
        do {
            notes = try modelContext.fetch(FetchDescriptor<NoteRecord>())
                .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
        } catch {
            throw BackupRestoreError.currentDataUnavailable
        }
        let metadata = BackupMetadata(noteRecords: notes)
        let drawings = try activeDrawingRecords(for: notes)
        let data = try encoder.encode(
            metadata: metadata,
            drawings: drawings,
            createdAtUnixNanos: BackupTimestamp.unixNanos(clock.now)
        )

        let directory = fileSystem.rootURL.appendingPathComponent(".backup-staging", isDirectory: true)
        try fileSystem.createDirectory(at: directory)
        let url = directory.appendingPathComponent("export-\(uuidSource.makeUUID().uuidString.lowercased()).cornellnote-backup")
        try fileSystem.writeAndFlush(data, to: url)
        let readBack = try fileSystem.readData(at: url)
        guard readBack == data else { throw BackupRestoreError.stagingReadBackFailed }
        _ = try decoder.decode(readBack)
        return (url, readBack)
    }

    private func activeDrawingRecords(for notes: [NoteRecord]) throws -> [BackupDrawingRecord] {
        var records: [BackupDrawingRecord] = []
        for note in notes {
            guard let localPath = note.drawingFileName, let checksum = note.drawingChecksum else { continue }
            let envelopePath = BackupPathValidator.canonicalDrawingPath(localPath)
            try BackupPathValidator.validate(envelopePath)
            guard try BackupPathValidator.drawingNoteID(envelopePath) == note.id else {
                throw BackupEnvelopeError.invalidPath(envelopePath)
            }
            guard try BackupPathValidator.drawingChecksum(envelopePath) == checksum else {
                throw BackupEnvelopeError.invalidMetadata
            }
            let url = fileSystem.rootURL.appendingPathComponent(localPath)
            let data = try fileSystem.readData(at: url)
            guard data.backupSHA256Hex == checksum else {
                throw BackupEnvelopeError.payloadHashMismatch(envelopePath)
            }
            guard (try? PKDrawing(data: data)) != nil else {
                throw BackupEnvelopeError.invalidMetadata
            }
            records.append(BackupDrawingRecord(path: envelopePath, payload: data))
        }
        return records.sorted { $0.path < $1.path }
    }
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
