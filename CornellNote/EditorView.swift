import PencilKit
import SwiftUI

struct EditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: NoteEditingSession
    let onLeave: () -> Void
    @State private var canvasView = NoteCanvasView()
    @State private var isShowingLeaveWarning = false
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("ノートのタイトル", text: Binding(
                get: { session.titleDraft },
                set: { session.updateTitle($0) }
            ))
                .textFieldStyle(.roundedBorder)
                .padding()
                .disabled(!session.canEdit)

            if let message = session.loadFailureMessage {
                ContentUnavailableView {
                    Label("描画を読み込めません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("再読み込み") {
                        session.reload()
                        showLoadedDrawing()
                    }
                }
            } else {
                if let message = session.saveFailureMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                        Button("保存を再試行") { session.flushSave() }
                    }
                    .padding(.horizontal)
                    .accessibilityElement(children: .contain)
                }
                if session.hasUnsavedChanges {
                    Text("未保存のタイトルと描画はメモリに保持しています。アプリの終了やOSによる強制終了の直前には保存を保証できず、失われる可能性があります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                GeometryReader { proxy in
                    // The canvas draws the Cornell background itself so it zooms with the ink.
                    CanvasView(canvasView: canvasView, isEditable: session.canEdit) { drawing in
                        session.updateDrawing(drawing)
                        refreshHistoryState()
                    }
                    .padding()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .navigationTitle(session.note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(session.hasUnsavedChanges)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(action: requestLeave) {
                    Label("ライブラリ", systemImage: "chevron.backward")
                }
                Button {
                    canvasView.undoManager?.undo()
                    refreshHistoryState()
                } label: {
                    Label("取り消す", systemImage: "arrow.uturn.backward")
                }
                .disabled(!session.canEdit || !canUndo)
                Button {
                    canvasView.undoManager?.redo()
                    refreshHistoryState()
                } label: {
                    Label("やり直す", systemImage: "arrow.uturn.forward")
                }
                .disabled(!session.canEdit || !canRedo)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("保存") { session.flushSave() }
                    .disabled(!session.canEdit || !session.hasUnsavedChanges)
                Text(session.loadFailureMessage == nil ? session.saveState.label : "Read failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("未保存の変更を破棄しますか？", isPresented: $isShowingLeaveWarning) {
            Button("保存して戻る") {
                if session.requestLeave() { onLeave() }
            }
            Button("編集を続ける", role: .cancel) { session.cancelLeave() }
            Button("変更を破棄して戻る", role: .destructive) {
                if session.confirmDiscard() { onLeave() }
            }
        } message: {
            Text("保存に失敗しました。戻ると未保存のタイトルと描画が失われます。端末の空き容量を確認して再試行するか、編集を続けてください。")
        }
        .onAppear(perform: showLoadedDrawing)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.flushSave() }
        }
        .onDisappear {
            // Library retains the session if an unexpected navigation still leaves an unsaved draft.
            session.flushSave()
        }
    }

    /// Shows the persisted drawing; loading is not an edit, so the drawing history starts empty.
    private func showLoadedDrawing() {
        canvasView.drawing = session.drawingDraft
        CanvasView.Coordinator.describeStrokes(of: canvasView)
        canvasView.undoManager?.removeAllActions()
        refreshHistoryState()
    }

    private func refreshHistoryState() {
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }

    private func requestLeave() {
        if session.requestLeave() {
            onLeave()
        } else {
            isShowingLeaveWarning = true
        }
    }
}
