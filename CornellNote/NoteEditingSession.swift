import Observation
import PencilKit

@MainActor
@Observable
final class NoteEditingSession {
    let note: NoteRecord
    private(set) var titleDraft: String
    private(set) var drawingDraft = PKDrawing()
    var canEdit: Bool { canWrite() && loadState == .loaded }
    private var loadState: DrawingLoadState = .notLoaded
    private(set) var hasUnsavedChanges = false
    /// Only drawing edits need a new drawing generation; title-only saves keep the active one.
    private var hasUnsavedDrawing = false
    private(set) var saveState: NoteSaveState = .saved
    var loadFailureMessage: String? {
        guard case .failed(let message) = loadState else { return nil }
        return message
    }
    private(set) var saveFailureMessage: String?
    private(set) var needsDiscardConfirmation = false
    private let persistence: NotePersistenceController
    private let canWrite: () -> Bool
    private let waitForDebounce: (UInt64) async throws -> Void
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private enum DrawingLoadState: Equatable {
        case notLoaded
        case loaded
        case failed(String)
    }

    init(
        note: NoteRecord,
        persistence: NotePersistenceController,
        canWrite: @escaping () -> Bool = { true },
        waitForDebounce: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.note = note
        self.persistence = persistence
        self.canWrite = canWrite
        self.waitForDebounce = waitForDebounce
        titleDraft = note.title
        reload()
    }

    deinit {
        saveTask?.cancel()
    }

    func reload() {
        guard canWrite(), !hasUnsavedChanges else { return }
        saveTask?.cancel()
        loadState = .notLoaded
        do {
            let drawing = try persistence.loadDrawing(for: note)
            drawingDraft = drawing
            titleDraft = note.title
            saveFailureMessage = nil
            saveState = .saved
            loadState = .loaded
        } catch NotePersistenceError.unsupportedDrawingSchema {
            loadState = .failed("この描画のschemaには対応していません。対応する描画schemaは1です。対応するアプリで開くか、検証済みバックアップを使用してください。元のデータは変更していません。")
        } catch {
            loadState = .failed("描画ファイルまたは保存情報が見つからないか、破損しています。元のデータを保護するため編集と保存を停止しています。再読み込みするか、検証済みバックアップからの復元を検討してください。対応する描画schemaは1です。")
        }
    }

    func updateTitle(_ title: String) {
        guard canEdit, title != titleDraft else { return }
        titleDraft = title
        markUnsavedAndSchedule()
    }

    func updateDrawing(_ drawing: PKDrawing) {
        guard canEdit, Self.differs(drawing, from: drawingDraft) else { return }
        drawingDraft = drawing
        hasUnsavedDrawing = true
        markUnsavedAndSchedule()
    }

    /// A stroke count or bounds difference proves a real edit without serializing the drawing.
    /// Only drawings that match on both, such as the echo of a programmatic assignment,
    /// need the exact byte comparison.
    static func differs(_ drawing: PKDrawing, from current: PKDrawing) -> Bool {
        if drawing.strokes.count != current.strokes.count || drawing.bounds != current.bounds {
            return true
        }
        return drawing.dataRepresentation() != current.dataRepresentation()
    }

    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard canEdit, hasUnsavedChanges else { return }
        saveState = .saving
        do {
            if hasUnsavedDrawing {
                try persistence.save(note: note, drawing: drawingDraft, title: titleDraft)
            } else {
                try persistence.saveTitle(note: note, title: titleDraft)
            }
            hasUnsavedChanges = false
            hasUnsavedDrawing = false
            saveFailureMessage = nil
            saveState = .saved
        } catch {
            saveState = .saveFailed
            saveFailureMessage = "保存できませんでした。最後に保存した内容は変更していません。端末の空き容量を確認して「保存を再試行」を押してください。未保存のタイトルと描画は、編集を続ける間メモリに保持します。"
        }
    }

    func requestLeave() -> Bool {
        flushSave()
        needsDiscardConfirmation = hasUnsavedChanges
        return !hasUnsavedChanges
    }

    func cancelLeave() {
        needsDiscardConfirmation = false
    }

    func confirmDiscard() -> Bool {
        guard needsDiscardConfirmation else { return false }
        saveTask?.cancel()
        hasUnsavedChanges = false
        hasUnsavedDrawing = false
        needsDiscardConfirmation = false
        reload()
        return true
    }

    private func markUnsavedAndSchedule() {
        hasUnsavedChanges = true
        if saveState != .saveFailed { saveState = .unsavedChanges }
        saveTask?.cancel()
        let wait = waitForDebounce
        saveTask = Task { @MainActor [weak self] in
            do {
                guard !Task.isCancelled else { return }
                try await wait(450_000_000)
                guard !Task.isCancelled else { return }
                self?.flushSave()
            } catch {
                // Cancellation is expected when another edit arrives or a flush occurs.
            }
        }
    }
}
