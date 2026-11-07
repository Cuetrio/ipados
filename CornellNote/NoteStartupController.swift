import Observation
import SwiftData

enum NoteStartupFailure: Equatable {
    case recoveryRequired
    case safetyCheckFailed
    case storeOpenFailed

    var title: String {
        switch self {
        case .recoveryRequired: return "復旧が必要です"
        case .safetyCheckFailed: return "保存領域の安全性を確認できません"
        case .storeOpenFailed: return "保存領域を開けません"
        }
    }

    var message: String {
        switch self {
        case .recoveryRequired:
            return "前回の復元が完了していない可能性があります。元のデータと安全バックアップを保護するため、ノートの一覧と編集を開きません。再確認で復旧情報を解除したり、データを修復・削除したりすることはありません。"
        case .safetyCheckFailed:
            return "復旧情報が読み取れないか、破損しているか、未対応のschemaです。安全バックアップ内の復旧情報を確認できない場合も、ノートを開きません。元のデータと安全バックアップは変更せず、安全性の確認だけを再試行できます。"
        case .storeOpenFailed:
            return "復旧情報の確認後に保存領域を開けませんでした。端末の空き容量や利用可能な状態を確認してから再試行してください。再試行でも復旧情報を先に確認します。データの初期化や自動修復は行いません。"
        }
    }
}

enum NoteStartupState {
    case checking
    case ready(NoteStoreGeneration)
    case blocked(NoteStartupFailure)
}

@MainActor
struct NoteStoreGeneration {
    let container: ModelContainer
    let fileSystem: BackupFileSystem
    let writeAdmission: NoteWriteAdmission

    fileprivate init(container: ModelContainer, fileSystem: BackupFileSystem) {
        self.container = container
        self.fileSystem = fileSystem
        writeAdmission = NoteWriteAdmission()
    }
}

@MainActor
@Observable
final class NoteWriteAdmission {
    private(set) var isAllowed = true

    private var sessions: [WeakSession] = []
    private final class WeakSession {
        weak var value: NoteEditingSession?
        init(_ value: NoteEditingSession) { self.value = value }
    }

    fileprivate init() {}

    func register(_ session: NoteEditingSession) {
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(session))
    }

    var canRestore: Bool {
        isAllowed && !sessions.contains {
            $0.value.map { $0.hasUnsavedChanges || $0.isDrawingStrokeInProgress } ?? false
        }
    }

    fileprivate func revoke() {
        isAllowed = false
    }
}

@MainActor
@Observable
final class NoteStartupController {
    private(set) var state: NoteStartupState = .checking
    let fileSystem: BackupFileSystem
    private let markerStore: RestoreMarkerStore
    private let makeContainer: (() throws -> ModelContainer)?
    private let openSelectedContainer: @MainActor (BackupFileSystem) throws -> ModelContainer
    private var preparedGeneration: NoteStoreGeneration?
    private var recoveryIsLatched = false
    private(set) var isRestoring = false

    var canRestore: Bool {
        guard !isRestoring, case .ready(let generation) = state else { return false }
        return generation.writeAdmission.canRestore
    }

    func beginRestore() throws {
        guard canRestore, case .ready(let generation) = state else {
            throw BackupRestoreError.restoreUnavailable
        }
        generation.writeAdmission.revoke()
        generation.container.mainContext.autosaveEnabled = false
        isRestoring = true
    }

    func prepareRestoredGeneration() throws {
        guard isRestoring else { throw BackupRestoreError.restoreUnavailable }
        let selected = try NoteStoreSelectionStore(fileSystem: fileSystem).selectedFileSystem()
        let container = try openSelectedContainer(selected)
        container.mainContext.autosaveEnabled = false
        preparedGeneration = NoteStoreGeneration(container: container, fileSystem: selected)
    }

    func finishRestore(recoveryRequired: Bool = false) {
        isRestoring = false
        recoveryIsLatched = recoveryIsLatched || recoveryRequired
        if recoveryIsLatched {
            preparedGeneration?.writeAdmission.revoke()
            preparedGeneration = nil
            state = .blocked(.recoveryRequired)
        } else if let prepared = preparedGeneration {
            preparedGeneration = nil
            // The restore pipeline committed marker resolution after all disk
            // checks. Publish its retained container without post-commit I/O.
            state = .ready(prepared)
        } else {
            recheck()
        }
    }

    init(fileSystem: BackupFileSystem, markerStore: RestoreMarkerStore, makeContainer: @escaping () throws -> ModelContainer) {
        self.fileSystem = fileSystem
        self.markerStore = markerStore
        self.makeContainer = makeContainer
        openSelectedContainer = { try NotePersistenceController.makeContainer(fileSystem: $0) }
    }

    init(fileSystem: BackupFileSystem,
         openSelectedContainer: @escaping @MainActor (BackupFileSystem) throws -> ModelContainer = {
             try NotePersistenceController.makeContainer(fileSystem: $0)
         }) {
        self.fileSystem = fileSystem
        markerStore = LocalRestoreMarkerStore(fileSystem: fileSystem)
        makeContainer = nil
        self.openSelectedContainer = openSelectedContainer
    }

    func recheck() {
        guard !isRestoring else { return }
        guard !recoveryIsLatched else {
            state = .blocked(.recoveryRequired)
            return
        }
        // Revoke before teardown can flush the old editor. A later open gets a new token.
        if case .ready(let generation) = state {
            generation.writeAdmission.revoke()
        }
        state = .checking
        do {
            if try markerStore.read()?.recoveryRequired == true {
                state = .blocked(.recoveryRequired)
                return
            }
        } catch {
            state = .blocked(.safetyCheckFailed)
            return
        }

        do {
            let selectedFileSystem: BackupFileSystem
            let container: ModelContainer
            if let makeContainer {
                selectedFileSystem = fileSystem
                container = try makeContainer()
            } else {
                selectedFileSystem = try NoteStoreSelectionStore(fileSystem: fileSystem)
                    .selectedFileSystem(allowFreshLegacy: true)
                container = try openSelectedContainer(selectedFileSystem)
            }
            container.mainContext.autosaveEnabled = false
            state = .ready(NoteStoreGeneration(container: container, fileSystem: selectedFileSystem))
        } catch {
            state = .blocked(.storeOpenFailed)
        }
    }
}
