import PencilKit
import SwiftUI

struct EditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: NoteEditingSession
    let onLeave: () -> Void
    @State private var canvasView = PKCanvasView()
    @State private var selectedTool: PKTool = PKInkingTool(.pen, color: .label, width: 3)
    @State private var isShowingLeaveWarning = false

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
                        canvasView.drawing = session.drawingDraft
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
                    ZStack {
                        CornellBackgroundView()
                        CanvasView(canvasView: $canvasView, selectedTool: selectedTool) { drawing in
                            session.updateDrawing(drawing)
                        }
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
                Button("ペン") {
                    selectedTool = PKInkingTool(.pen, color: .label, width: 3)
                }
                .disabled(!session.canEdit)
                Button("消しゴム") {
                    selectedTool = PKEraserTool(.vector)
                }
                .disabled(!session.canEdit)
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
        .onAppear {
            canvasView.drawing = session.drawingDraft
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.flushSave() }
        }
        .onDisappear {
            // Library retains the session if an unexpected navigation still leaves an unsaved draft.
            session.flushSave()
        }
    }

    private func requestLeave() {
        if session.requestLeave() {
            onLeave()
        } else {
            isShowingLeaveWarning = true
        }
    }
}
