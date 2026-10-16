import PencilKit
import SwiftData
import SwiftUI

struct EditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var note: NoteRecord
    @State private var canvasView = PKCanvasView()
    @State private var selectedTool: PKTool = PKInkingTool(.pen, color: .label, width: 3)
    @State private var saveTask: Task<Void, Never>?
    @State private var saveState: NoteSaveState = .saved

    private var persistence: NotePersistenceController {
        NotePersistenceController(modelContext: modelContext)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("ノートのタイトル", text: $note.title)
                .textFieldStyle(.roundedBorder)
                .padding()
                .onChange(of: note.title) { _, _ in
                    markUnsavedAndSchedule()
                }

            GeometryReader { proxy in
                ZStack {
                    CornellBackgroundView()
                    CanvasView(canvasView: $canvasView, selectedTool: selectedTool) { _ in
                        markUnsavedAndSchedule()
                    }
                }
                .padding()
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("ペン") {
                    selectedTool = PKInkingTool(.pen, color: .label, width: 3)
                }
                Button("消しゴム") {
                    selectedTool = PKEraserTool(.vector)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Text(saveState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadDrawing)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                flushSave()
            }
        }
        .onDisappear {
            flushSave()
            saveTask?.cancel()
        }
    }

    private func loadDrawing() {
        do {
            canvasView.drawing = try persistence.loadDrawing(for: note)
            saveState = .saved
        } catch {
            saveState = .saveFailed
        }
    }

    private func markUnsavedAndSchedule() {
        saveState = .unsavedChanges
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                persistDrawing()
            } catch {
                // Cancellation is expected when another stroke arrives.
            }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        guard saveState == .unsavedChanges else { return }
        persistDrawing()
    }

    private func persistDrawing() {
        saveState = .saving
        do {
            try persistence.save(note: note, drawing: canvasView.drawing)
            saveState = .saved
        } catch {
            saveState = .saveFailed
        }
    }
}
