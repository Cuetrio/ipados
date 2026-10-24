import Foundation
import PencilKit
import SwiftData

extension Notification.Name {
    static let cornellNoteStoreDidSwitch = Notification.Name("CornellNote.storeDidSwitch")
}

enum BackupRestoreError: Error, Equatable, LocalizedError {
    case capacityInsufficient
    case currentDataUnavailable
    case safetyBackupFailed
    case stagingFailed
    case stagingReadBackFailed
    case storeReopenFailed
    case atomicSwitchFailed
    case rollbackFailed
    case markerWriteFailed
    case faultInjected(String)

    var errorDescription: String? {
        switch self {
        case .capacityInsufficient: return "Not enough local capacity for restore."
        case .currentDataUnavailable: return "Current local data could not be read."
        case .safetyBackupFailed: return "Safety backup could not be created."
        case .stagingFailed: return "Restore staging failed."
        case .stagingReadBackFailed: return "Restore staging read-back failed."
        case .storeReopenFailed: return "The restored store could not be reopened."
        case .atomicSwitchFailed: return "The local store switch failed."
        case .rollbackFailed: return "Rollback failed and recovery is required."
        case .markerWriteFailed: return "Restore recovery state could not be persisted."
        case .faultInjected(let name): return "Injected restore fault: \(name)."
        }
    }
}

struct RestoreResult {
    let state: RestoreState
    let phase: RestorePhase
    let errorDescription: String?
    let safetyBackupURL: URL?
    let thumbnailRegenerated: Bool
}

@MainActor
final class BackupRestoreCoordinator {
    private let modelContext: ModelContext
    private let fileSystem: BackupFileSystem
    private let encoder: BackupEnvelopeEncoder
    private let decoder: BackupEnvelopeDecoder
    private let clock: BackupClock
    private let uuidSource: BackupUUIDSource
    private let modelStoreSwitcher: BackupModelStoreSwitcher
    private let markerStore: RestoreMarkerStore
    private let thumbnailRegenerator: BackupThumbnailRegenerator
    private let faultPlan: RestoreFaultPlan

    private(set) var state: RestoreState = .preparing
    private(set) var phase: RestorePhase = .selected

    init(
        modelContext: ModelContext,
        fileSystem: BackupFileSystem,
        encoder: BackupEnvelopeEncoder = BackupEnvelopeCodec(),
        decoder: BackupEnvelopeDecoder = BackupEnvelopeCodec(),
        clock: BackupClock = SystemBackupClock(),
        uuidSource: BackupUUIDSource = SystemBackupUUIDSource(),
        modelStoreSwitcher: BackupModelStoreSwitcher? = nil,
        markerStore: RestoreMarkerStore? = nil,
        thumbnailRegenerator: BackupThumbnailRegenerator? = nil,
        faultPlan: RestoreFaultPlan = RestoreFaultPlan()
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.encoder = encoder
        self.decoder = decoder
        self.clock = clock
        self.uuidSource = uuidSource
        self.modelStoreSwitcher = modelStoreSwitcher ?? LocalBackupModelStoreSwitcher(fileSystem: fileSystem)
        self.markerStore = markerStore ?? LocalRestoreMarkerStore(fileSystem: fileSystem)
        self.thumbnailRegenerator = thumbnailRegenerator ?? LocalBackupThumbnailRegenerator(fileSystem: fileSystem)
        self.faultPlan = faultPlan
    }

    func restore(from data: Data) -> RestoreResult {
        state = .preparing
        phase = .selected
        var safetyBackupURL: URL?
        var stagingURL: URL?

        do {
            let current = try currentSnapshot()
            phase = .capacityPreflight
            try preflight(data: data, current: current)

            state = .validating
            if faultPlan.failEnvelopeValidation { throw BackupRestoreError.faultInjected("envelope validation") }
            let decoded = try decoder.decode(data)
            try validateDecodedEnvelope(decoded)
            phase = .envelopeValidated

            state = .restoring
            safetyBackupURL = try createSafetyBackup(metadata: current.metadata, drawings: current.drawings)
            phase = .safetyBackupCreated
            do {
                if faultPlan.failMarkerWrite { throw BackupRestoreError.faultInjected("marker write") }
                try markerStore.write(
                    recoveryMarker(for: safetyBackupURL!, failureState: phase),
                    fallbackDirectory: safetyBackupURL
                )
            } catch {
                markRecoveryRequired(safetyBackupURL: safetyBackupURL, failureState: phase)
                state = .recoveryRequired
                return RestoreResult(
                    state: state,
                    phase: phase,
                    errorDescription: BackupRestoreError.markerWriteFailed.localizedDescription,
                    safetyBackupURL: safetyBackupURL,
                    thumbnailRegenerated: false
                )
            }
            stagingURL = try createStaging(
                envelopeData: data,
                decoded: decoded
            )
            phase = .stagingWritten
            try reopenStaging(stagingURL: stagingURL!, expectedMetadata: decoded.metadata)
            phase = .stagingReadBack
            phase = .swiftDataReopened

            do {
                if faultPlan.failAtomicSwitch { throw BackupRestoreError.faultInjected("atomic switch") }
                phase = .atomicSwitch
                try modelStoreSwitcher.atomicSwitch(to: stagingURL!)
                if faultPlan.failPostSwitchReopen { throw BackupRestoreError.faultInjected("post-switch reopen") }
                try modelStoreSwitcher.reopenCurrent(expectedMetadata: decoded.metadata)
                phase = .postSwitchReopened
            } catch {
                return handlePostSwitchFailure(
                    error: error,
                    currentMetadata: current.metadata,
                    safetyBackupURL: safetyBackupURL!,
                    stagingURL: stagingURL
                )
            }

            var thumbnailRegenerated = false
            do {
                if faultPlan.failThumbnailRegeneration { throw BackupRestoreError.faultInjected("thumbnail regeneration") }
                try thumbnailRegenerator.regenerate(metadata: decoded.metadata, drawings: decoded.drawings)
                thumbnailRegenerated = true
                phase = .thumbnailRegenerated
            } catch {
                // A thumbnail is a cache. The restored metadata and drawings remain valid.
            }

            do {
                if faultPlan.failMarkerWrite { throw BackupRestoreError.faultInjected("marker write") }
                try markerStore.write(
                    RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil),
                    fallbackDirectory: nil
                )
            } catch {
                markRecoveryRequired(safetyBackupURL: safetyBackupURL, failureState: phase)
                state = .recoveryRequired
                return RestoreResult(
                    state: state,
                    phase: phase,
                    errorDescription: BackupRestoreError.markerWriteFailed.localizedDescription,
                    safetyBackupURL: safetyBackupURL,
                    thumbnailRegenerated: thumbnailRegenerated
                )
            }

            cleanupStaging(stagingURL)
            cleanupSafetyBackups(protected: safetyBackupURL)
            state = .completed
            phase = .completed
            return RestoreResult(
                state: state,
                phase: phase,
                errorDescription: nil,
                safetyBackupURL: safetyBackupURL,
                thumbnailRegenerated: thumbnailRegenerated
            )
        } catch {
            cleanupStaging(stagingURL)
            state = .restoreFailed
            return RestoreResult(
                state: state,
                phase: phase,
                errorDescription: error.localizedDescription,
                safetyBackupURL: safetyBackupURL,
                thumbnailRegenerated: false
            )
        }
    }

    func restore(from url: URL, provider: DocumentProviderAdapter) throws -> RestoreResult {
        restore(from: try provider.readImportedFile(at: url))
    }

    func recoveryMarker() -> RestoreMarker? {
        try? markerStore.read()
    }

    private func preflight(data: Data, current: CurrentSnapshot) throws {
        if faultPlan.failCapacityPreflight { throw BackupRestoreError.capacityInsufficient }
        func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? UInt64.max : result.partialValue
        }
        let importedBytes = UInt64(data.count)
        let currentPayloadBytes = current.drawings.reduce(UInt64(0)) { partial, drawing in
            saturatingAdd(partial, UInt64(drawing.payload.count))
        }
        let requiredWithReserve = saturatingAdd(
            saturatingAdd(importedBytes, importedBytes),
            saturatingAdd(currentPayloadBytes, 4_096)
        )
        let available = try fileSystem.availableCapacity(for: fileSystem.rootURL)
        guard available >= 0, UInt64(available) >= requiredWithReserve else {
            throw BackupRestoreError.capacityInsufficient
        }
    }

    private func validateDecodedEnvelope(_ decoded: DecodedBackupEnvelope) throws {
        guard decoded.manifest.noteCount == decoded.metadata.notes.count else {
            throw BackupEnvelopeError.invalidMetadata
        }
        let drawingPaths = decoded.drawings.map(\.path)
        guard drawingPaths == drawingPaths.sorted() else { throw BackupEnvelopeError.invalidRecordOrder }
    }

    private func currentSnapshot() throws -> CurrentSnapshot {
        do {
            let notes = try modelContext.fetch(FetchDescriptor<NoteRecord>())
                .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
            let metadata = BackupMetadata(noteRecords: notes)
            var drawings: [BackupDrawingRecord] = []
            for note in notes {
                guard (note.drawingFileName == nil) == (note.drawingChecksum == nil) else {
                    throw BackupRestoreError.currentDataUnavailable
                }
                guard let localPath = note.drawingFileName, let checksum = note.drawingChecksum else { continue }
                let envelopePath = BackupPathValidator.canonicalDrawingPath(localPath)
                try BackupPathValidator.validate(envelopePath)
                guard try BackupPathValidator.drawingNoteID(envelopePath) == note.id,
                      try BackupPathValidator.drawingChecksum(envelopePath) == checksum else {
                    throw BackupRestoreError.currentDataUnavailable
                }
                let data = try fileSystem.readData(at: fileSystem.rootURL.appendingPathComponent(localPath))
                guard data.backupSHA256Hex == checksum else {
                    throw BackupEnvelopeError.payloadHashMismatch(envelopePath)
                }
                guard note.drawingSchemaVersion == NotePersistenceController.drawingSchemaVersion,
                      (try? PKDrawing(data: data)) != nil else {
                    throw BackupRestoreError.currentDataUnavailable
                }
                drawings.append(BackupDrawingRecord(path: envelopePath, payload: data))
            }
            return CurrentSnapshot(metadata: metadata, drawings: drawings.sorted { $0.path < $1.path })
        } catch let error as BackupRestoreError {
            throw error
        } catch {
            throw BackupRestoreError.currentDataUnavailable
        }
    }

    private func createSafetyBackup(metadata: BackupMetadata, drawings: [BackupDrawingRecord]) throws -> URL {
        if faultPlan.failSafetyBackup { throw BackupRestoreError.safetyBackupFailed }
        let url = BackupManagedPaths.safetyBackupURL(for: fileSystem, clock: clock, uuidSource: uuidSource)
        do {
            try fileSystem.createDirectory(at: url)
            let envelope = try encoder.encode(
                metadata: metadata,
                drawings: drawings,
                createdAtUnixNanos: BackupTimestamp.unixNanos(clock.now)
            )
            let envelopeURL = url.appendingPathComponent("restore-manifest.cornellnote-backup")
            try fileSystem.writeAndFlush(envelope, to: envelopeURL)
            for drawing in drawings {
                try BackupPathValidator.validate(drawing.path)
                try fileSystem.writeAndFlush(drawing.payload, to: url.appendingPathComponent(drawing.path))
                guard try fileSystem.readData(at: url.appendingPathComponent(drawing.path)) == drawing.payload else {
                    throw BackupRestoreError.safetyBackupFailed
                }
            }
            try copyCurrentStoreFiles(to: url)
            guard let readBack = try? fileSystem.readData(at: envelopeURL),
                  let decoded = try? decoder.decode(readBack),
                  decoded.metadata == metadata,
                  decoded.drawings == drawings else {
                throw BackupRestoreError.safetyBackupFailed
            }
            let complete = Data("{\"completed\":true,\"schema\":1}".utf8)
            let completionURL = url.appendingPathComponent("safety-complete.json")
            try fileSystem.writeAndFlush(complete, to: completionURL)
            guard try fileSystem.readData(at: completionURL) == complete else {
                throw BackupRestoreError.safetyBackupFailed
            }
            return url
        } catch let error as BackupRestoreError {
            try? fileSystem.removeItem(at: url)
            throw error
        } catch {
            try? fileSystem.removeItem(at: url)
            throw BackupRestoreError.safetyBackupFailed
        }
    }

    private func copyCurrentStoreFiles(to safetyURL: URL) throws {
        let entries = try fileSystem.contentsOfDirectory(at: fileSystem.rootURL)
        for entry in entries where entry.lastPathComponent == "metadata.store" || entry.lastPathComponent.hasPrefix("metadata.store-") {
            let data = try fileSystem.readData(at: entry)
            try fileSystem.writeAndFlush(data, to: safetyURL.appendingPathComponent(entry.lastPathComponent))
            guard try fileSystem.readData(at: safetyURL.appendingPathComponent(entry.lastPathComponent)) == data else {
                throw BackupRestoreError.safetyBackupFailed
            }
        }
    }

    private func createStaging(envelopeData: Data, decoded: DecodedBackupEnvelope) throws -> URL {
        let directory = BackupManagedPaths.stagingRoot(for: fileSystem)
        let url = directory.appendingPathComponent("restore-\(uuidSource.makeUUID().uuidString.lowercased())", isDirectory: true)
        do {
            try fileSystem.createDirectory(at: url)
            try fileSystem.writeAndFlush(envelopeData, to: url.appendingPathComponent("restore-manifest.cornellnote-backup"))
            if faultPlan.failStagingWrite { throw BackupRestoreError.faultInjected("staging write") }
            try modelStoreSwitcher.writeStagingStore(metadata: decoded.metadata, drawings: decoded.drawings, at: url)
            return url
        } catch let error as BackupRestoreError {
            try? fileSystem.removeItem(at: url)
            throw error
        } catch {
            try? fileSystem.removeItem(at: url)
            throw BackupRestoreError.stagingFailed
        }
    }

    private func reopenStaging(stagingURL: URL, expectedMetadata: BackupMetadata) throws {
        if faultPlan.failStagingReadBack { throw BackupRestoreError.stagingReadBackFailed }
        guard let data = try? fileSystem.readData(at: stagingURL.appendingPathComponent("restore-manifest.cornellnote-backup")),
              let decoded = try? decoder.decode(data),
              decoded.metadata == expectedMetadata else {
            throw BackupRestoreError.stagingReadBackFailed
        }
        for drawing in decoded.drawings {
            guard let pathChecksum = try? BackupPathValidator.drawingChecksum(drawing.path),
                  pathChecksum == drawing.payload.backupSHA256Hex,
                  (try? PKDrawing(data: drawing.payload)) != nil else {
                throw BackupRestoreError.stagingReadBackFailed
            }
        }
        if faultPlan.failSwiftDataReopen { throw BackupRestoreError.storeReopenFailed }
        do {
            try modelStoreSwitcher.reopenStore(at: stagingURL, expectedMetadata: expectedMetadata)
        } catch {
            throw BackupRestoreError.storeReopenFailed
        }
    }

    private func handlePostSwitchFailure(
        error: Error,
        currentMetadata: BackupMetadata,
        safetyBackupURL: URL,
        stagingURL: URL?
    ) -> RestoreResult {
        do {
            if faultPlan.failRollback { throw BackupRestoreError.rollbackFailed }
            try modelStoreSwitcher.rollback(from: safetyBackupURL)
            try modelStoreSwitcher.reopenCurrent(expectedMetadata: currentMetadata)
            do {
                try markerStore.write(
                    RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil),
                    fallbackDirectory: nil
                )
            } catch {
                markRecoveryRequired(safetyBackupURL: safetyBackupURL, failureState: phase)
                state = .recoveryRequired
                return RestoreResult(
                    state: state,
                    phase: phase,
                    errorDescription: BackupRestoreError.markerWriteFailed.localizedDescription,
                    safetyBackupURL: safetyBackupURL,
                    thumbnailRegenerated: false
                )
            }
            cleanupStaging(stagingURL)
            state = .restoreFailed
            return RestoreResult(
                state: state,
                phase: phase,
                errorDescription: error.localizedDescription,
                safetyBackupURL: safetyBackupURL,
                thumbnailRegenerated: false
            )
        } catch {
            markRecoveryRequired(safetyBackupURL: safetyBackupURL, failureState: phase)
            state = .recoveryRequired
            return RestoreResult(
                state: state,
                phase: phase,
                errorDescription: BackupRestoreError.rollbackFailed.localizedDescription,
                safetyBackupURL: safetyBackupURL,
                thumbnailRegenerated: false
            )
        }
    }

    private func markRecoveryRequired(safetyBackupURL: URL?, failureState: RestorePhase) {
        guard let safetyBackupURL else { return }
        try? markerStore.write(
            recoveryMarker(for: safetyBackupURL, failureState: failureState),
            fallbackDirectory: safetyBackupURL
        )
    }

    private func recoveryMarker(for safetyBackupURL: URL, failureState: RestorePhase) -> RestoreMarker {
        RestoreMarker(
            recoveryRequired: true,
            safetyBackupPath: relativeManagedPath(safetyBackupURL),
            lastFailureState: String(describing: failureState)
        )
    }

    private func cleanupStaging(_ url: URL?) {
        guard let url, BackupManagedPaths.isWithinManagedRoot(url, root: fileSystem.rootURL) else { return }
        try? fileSystem.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if let remaining = try? fileSystem.contentsOfDirectory(at: parent), remaining.isEmpty {
            try? fileSystem.removeItem(at: parent)
        }
    }

    private func cleanupSafetyBackups(protected: URL?) {
        let root = BackupManagedPaths.safetyRoot(for: fileSystem)
        guard let entries = try? fileSystem.contentsOfDirectory(at: root) else { return }
        let protectedPath = protected?.standardizedFileURL.path
        let complete = entries.filter { entry in
            entry.lastPathComponent.hasPrefix("safety-") &&
            isVerifiedSafetyBackup(entry) &&
            entry.standardizedFileURL.path != protectedPath &&
            !isRecoveryProtected(entry)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let keepCount = protected == nil ? 2 : 1
        for entry in complete.dropFirst(keepCount) {
            try? fileSystem.removeItem(at: entry)
        }
    }

    private func isVerifiedSafetyBackup(_ directory: URL) -> Bool {
        let completionURL = directory.appendingPathComponent("safety-complete.json")
        let manifestURL = directory.appendingPathComponent("restore-manifest.cornellnote-backup")
        guard fileSystem.fileExists(at: completionURL),
              let completion = try? fileSystem.readData(at: completionURL),
              completion == Data("{\"completed\":true,\"schema\":1}".utf8),
              let manifestData = try? fileSystem.readData(at: manifestURL),
              let envelope = try? decoder.decode(manifestData) else {
            return false
        }
        for drawing in envelope.drawings {
            let drawingURL = directory.appendingPathComponent(drawing.path)
            guard BackupManagedPaths.isWithinManagedRoot(drawingURL, root: directory),
                  (try? fileSystem.readData(at: drawingURL)) == drawing.payload else {
                return false
            }
        }
        return true
    }

    private func isRecoveryProtected(_ directory: URL) -> Bool {
        let markerURL = directory.appendingPathComponent("recovery-state.json")
        guard fileSystem.fileExists(at: markerURL) else {
            return false
        }
        guard let data = try? fileSystem.readData(at: markerURL),
              let marker = try? JSONDecoder().decode(RestoreMarker.self, from: data) else {
            return true
        }
        return marker.recoveryRequired
    }

    private func relativeManagedPath(_ url: URL) -> String {
        let root = fileSystem.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }
}

private struct CurrentSnapshot {
    let metadata: BackupMetadata
    let drawings: [BackupDrawingRecord]
}
