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
    let writeAdmission: NoteWriteAdmission

    fileprivate init(container: ModelContainer) {
        self.container = container
        writeAdmission = NoteWriteAdmission()
    }
}

@MainActor
@Observable
final class NoteWriteAdmission {
    private(set) var isAllowed = true

    fileprivate init() {}

    fileprivate func revoke() {
        isAllowed = false
    }
}

@MainActor
@Observable
final class NoteStartupController {
    private(set) var state: NoteStartupState = .checking
    private let markerStore: RestoreMarkerStore
    private let makeContainer: () throws -> ModelContainer

    init(markerStore: RestoreMarkerStore, makeContainer: @escaping () throws -> ModelContainer) {
        self.markerStore = markerStore
        self.makeContainer = makeContainer
    }

    convenience init(fileSystem: BackupFileSystem) {
        self.init(markerStore: LocalRestoreMarkerStore(fileSystem: fileSystem)) {
            try NotePersistenceController.makeContainer(fileSystem: fileSystem)
        }
    }

    func recheck() {
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
            let container = try makeContainer()
            state = .ready(NoteStoreGeneration(container: container))
        } catch {
            state = .blocked(.storeOpenFailed)
        }
    }
}
