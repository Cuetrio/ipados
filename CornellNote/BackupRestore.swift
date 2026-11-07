import Foundation
import PencilKit
import SwiftData

enum BackupRestoreError: Error, Equatable, LocalizedError {
    case restoreUnavailable
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
        case .restoreUnavailable: return "安全な復元の準備ができていないため、復元を一時停止しています。現在のノートは変更しません。"
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
    private let managedFileSystem: BackupFileSystem
    private let startup: NoteStartupController?
    private let encoder: BackupEnvelopeEncoder
    private let decoder: BackupEnvelopeDecoder
    private let clock: BackupClock
    private let uuidSource: BackupUUIDSource
    private let modelStoreSwitcher: BackupModelStoreSwitcher
    private let markerStore: RestoreMarkerStore
    private let thumbnailRegenerator: BackupThumbnailRegenerator?
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
        faultPlan: RestoreFaultPlan = RestoreFaultPlan(),
        startup: NoteStartupController? = nil
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.encoder = encoder
        self.decoder = decoder
        self.clock = clock
        self.uuidSource = uuidSource
        self.startup = startup
        let managedFileSystem = startup?.fileSystem ?? fileSystem
        self.managedFileSystem = managedFileSystem
        self.modelStoreSwitcher = modelStoreSwitcher ?? LocalBackupModelStoreSwitcher(
            fileSystem: managedFileSystem, isAdmitted: { [weak startup] in startup?.isRestoring == true })
        self.markerStore = markerStore ?? LocalRestoreMarkerStore(fileSystem: managedFileSystem)
        self.thumbnailRegenerator = thumbnailRegenerator
        self.faultPlan = faultPlan
    }

    func restore(from data: Data) -> RestoreResult {
        if let startup {
            do {
                guard case .ready(let generation) = startup.state,
                      generation.fileSystem.rootURL == fileSystem.rootURL,
                      generation.container === modelContext.container else {
                    throw BackupRestoreError.restoreUnavailable
                }
                try startup.beginRestore()
            } catch {
                return RestoreResult(state: .restoreFailed, phase: .selected,
                    errorDescription: error.localizedDescription, safetyBackupURL: nil, thumbnailRegenerated: false)
            }
        }
        let result = performRestore(from: data)
        startup?.finishRestore(recoveryRequired: result.state == .recoveryRequired)
        if let startup, case .blocked(.recoveryRequired) = startup.state, result.state != .recoveryRequired {
            state = .recoveryRequired
            return RestoreResult(state: .recoveryRequired, phase: result.phase,
                errorDescription: BackupRestoreError.markerWriteFailed.localizedDescription,
                safetyBackupURL: result.safetyBackupURL, thumbnailRegenerated: result.thumbnailRegenerated)
        }
        return result
    }

    private func performRestore(from data: Data) -> RestoreResult {
        state = .preparing
        phase = .selected
        if let refusal = restoreAdmissionFailure() { return refusal }
        var safetyBackupURL: URL?
        var stagingURL: URL?
        var currentMetadata: BackupMetadata?

        do {
            let current = try currentSnapshot()
            currentMetadata = current.metadata
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
                try startup?.prepareRestoredGeneration()
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
                let restoredFileSystem = try modelStoreSwitcher.restoredFileSystem(fallback: fileSystem)
                let regenerator = thumbnailRegenerator ?? LocalBackupThumbnailRegenerator(fileSystem: restoredFileSystem)
                try regenerator.regenerate(metadata: decoded.metadata, drawings: decoded.drawings)
                thumbnailRegenerated = true
                phase = .thumbnailRegenerated
            } catch {
                // A thumbnail is a cache. The restored metadata and drawings remain valid.
            }

            do {
                if faultPlan.failMarkerWrite { throw BackupRestoreError.faultInjected("marker write") }
                try resolveRecoveryMarker()
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
            if let safetyBackupURL, let currentMetadata, modelStoreSwitcher.preservesStoreDirectories {
                return handlePostSwitchFailure(error: error, currentMetadata: currentMetadata,
                    safetyBackupURL: safetyBackupURL, stagingURL: stagingURL)
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
        }
    }

    func restore(from url: URL, provider: DocumentProviderAdapter) throws -> RestoreResult {
        if let startup {
            guard startup.canRestore else {
                return RestoreResult(state: .restoreFailed, phase: .selected,
                    errorDescription: BackupRestoreError.restoreUnavailable.localizedDescription,
                    safetyBackupURL: nil, thumbnailRegenerated: false)
            }
        } else if let refusal = restoreAdmissionFailure() { return refusal }
        return restore(from: try provider.readImportedFile(at: url))
    }

    private func restoreAdmissionFailure() -> RestoreResult? {
        do {
            try modelStoreSwitcher.requireSafeRestoreAdmission()
            return nil
        } catch {
            state = .restoreFailed
            phase = .selected
            return RestoreResult(
                state: state,
                phase: phase,
                errorDescription: error.localizedDescription,
                safetyBackupURL: nil,
                thumbnailRegenerated: false
            )
        }
    }

    func recoveryMarker() -> RestoreMarker? {
        try? markerStore.read()
    }

    static let capacityReserve: UInt64 = 1_048_576

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
        let safetyEnvelope = try encoder.encode(metadata: current.metadata, drawings: current.drawings,
            createdAtUnixNanos: BackupTimestamp.unixNanos(clock.now))
        // Reserve the encoded safety snapshot and its separate drawing copies, incoming
        // envelope/payloads, plus a conservative SQLite/WAL allowance and fixed headroom.
        let incomingCopies = saturatingAdd(importedBytes, importedBytes)
        let databaseAllowance = saturatingAdd(incomingCopies, incomingCopies)
        let safetyBytes = saturatingAdd(UInt64(safetyEnvelope.count), currentPayloadBytes)
        let requiredWithReserve = saturatingAdd(saturatingAdd(incomingCopies, databaseAllowance),
            saturatingAdd(safetyBytes, Self.capacityReserve))
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
        let url = BackupManagedPaths.safetyBackupURL(for: managedFileSystem, clock: clock, uuidSource: uuidSource)
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
            guard let readBack = try? fileSystem.readData(at: envelopeURL),
                  let decoded = try? decoder.decode(readBack),
                  decoded.metadata == metadata,
                  decoded.drawings == drawings else {
                throw BackupRestoreError.safetyBackupFailed
            }
            if modelStoreSwitcher.preservesStoreDirectories {
                // Durable pending intent precedes completion, so a later full-disk marker failure
                // cannot make a restart mistake this restore for a completed operation.
                let pending = try BackupCanonicalJSON.encode(recoveryMarker(for: url, failureState: .safetyBackupCreated))
                let pendingURL = url.appendingPathComponent("recovery-state.json")
                try fileSystem.writeAndFlush(pending, to: pendingURL)
                guard try fileSystem.readData(at: pendingURL) == pending else {
                    throw BackupRestoreError.safetyBackupFailed
                }
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

    private func createStaging(envelopeData: Data, decoded: DecodedBackupEnvelope) throws -> URL {
        let url = modelStoreSwitcher.stagingURL(id: uuidSource.makeUUID(), root: managedFileSystem.rootURL)
        guard !fileSystem.fileExists(at: url) else { throw BackupRestoreError.stagingFailed }
        do {
            try fileSystem.createDirectory(at: url)
            try fileSystem.writeAndFlush(envelopeData, to: url.appendingPathComponent("restore-manifest.cornellnote-backup"))
            if faultPlan.failStagingWrite { throw BackupRestoreError.faultInjected("staging write") }
            try modelStoreSwitcher.writeStagingStore(metadata: decoded.metadata, drawings: decoded.drawings, at: url)
            return url
        } catch let error as BackupRestoreError {
            cleanupStaging(url)
            throw error
        } catch {
            cleanupStaging(url)
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
            try startup?.prepareRestoredGeneration()
            do {
                try resolveRecoveryMarker()
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

    private func resolveRecoveryMarker() throws {
        try markerStore.write(
            RestoreMarker(recoveryRequired: false, safetyBackupPath: nil, lastFailureState: nil),
            fallbackDirectory: nil)
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
        guard !modelStoreSwitcher.preservesStoreDirectories,
              let url, BackupManagedPaths.isWithinManagedRoot(url, root: managedFileSystem.rootURL) else { return }
        try? fileSystem.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if let remaining = try? fileSystem.contentsOfDirectory(at: parent), remaining.isEmpty {
            try? fileSystem.removeItem(at: parent)
        }
    }

    private func cleanupSafetyBackups(protected: URL?) {
        let root = BackupManagedPaths.safetyRoot(for: managedFileSystem)
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
        let root = managedFileSystem.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }
}

private struct CurrentSnapshot {
    let metadata: BackupMetadata
    let drawings: [BackupDrawingRecord]
}
