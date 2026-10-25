import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \NoteRecord.updatedAt, order: .reverse) private var notes: [NoteRecord]
    @State private var noteToDelete: NoteRecord?
    @State private var restoreState: RestoreState?
    @State private var editingSession: NoteEditingSession?
    @State private var isEditorPresented = false

    private var hasRetainedDraft: Bool {
        editingSession?.hasUnsavedChanges == true
    }

    let writeAdmission: NoteWriteAdmission

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    ContentUnavailableView("ノートはありません", systemImage: "note.text")
                }
                if hasRetainedDraft {
                    Button("未保存の変更があります。編集に戻って保存または破棄してください。") {
                        isEditorPresented = true
                    }
                }
                ForEach(notes) { note in
                    Button {
                        openNote(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                NoteThumbnailView(note: note, writeAdmission: writeAdmission)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.displayTitle)
                                        .font(.headline)
                                    Text(note.updatedAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(hasRetainedDraft && editingSession?.note.id != note.id)
                    .swipeActions {
                        Button(role: .destructive) {
                            noteToDelete = note
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .disabled(hasRetainedDraft)
                    }
                }
            }
            .navigationDestination(isPresented: $isEditorPresented) {
                if let editingSession {
                    EditorView(session: editingSession) {
                        isEditorPresented = false
                        self.editingSession = nil
                    }
                }
            }
            .onChange(of: isEditorPresented) { _, isPresented in
                if !isPresented { editingSession?.flushSave() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && !isEditorPresented { editingSession?.flushSave() }
            }
            .navigationTitle("Cornell Note")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createNote) {
                        Label("新規ノート", systemImage: "plus")
                    }
                    .disabled(hasRetainedDraft)
                }
            }
            .alert("ノートを削除しますか？", isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            )) {
                Button("削除", role: .destructive, action: deleteSelectedNote)
                Button("キャンセル", role: .cancel) { noteToDelete = nil }
            } message: {
                Text("削除したノートは元に戻せません。")
            }
            .modifier(LibraryBackupActions(
                writeAdmission: writeAdmission,
                hasRetainedDraft: hasRetainedDraft,
                restoreState: $restoreState
            ))
            .task {
                guard writeAdmission.isAllowed else { return }
                let persistence = NotePersistenceController(modelContext: modelContext)
                notes.forEach { persistence.cleanupOrphans(for: $0) }
                let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
                if coordinator.recoveryMarker()?.recoveryRequired == true {
                    restoreState = .recoveryRequired
                }
            }
        }
    }

    private func openNote(_ note: NoteRecord) {
        guard writeAdmission.isAllowed else { return }
        if !hasRetainedDraft {
            editingSession = NoteEditingSession(
                note: note,
                persistence: NotePersistenceController(modelContext: modelContext),
                canWrite: { [writeAdmission] in writeAdmission.isAllowed }
            )
        }
        isEditorPresented = true
    }

    private func createNote() {
        guard writeAdmission.isAllowed, !hasRetainedDraft else { return }
        let note = NoteRecord()
        modelContext.insert(note)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(note)
        }
    }

    private func deleteSelectedNote() {
        guard writeAdmission.isAllowed, !hasRetainedDraft, let note = noteToDelete else { return }
        do {
            try NotePersistenceController(modelContext: modelContext).delete(note: note)
        } catch {
            noteToDelete = nil
        }
    }
}

private struct NoteThumbnailView: View {
    @Environment(\.modelContext) private var modelContext
    let note: NoteRecord
    let writeAdmission: NoteWriteAdmission
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "note.text") }
            }
        }
        .frame(width: 72, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { loadThumbnail() }
    }

    private func loadThumbnail() {
        guard writeAdmission.isAllowed else { return }
        let persistence = NotePersistenceController(modelContext: modelContext)
        if let data = try? persistence.thumbnailData(for: note), let cached = UIImage(data: data) {
            image = cached
            return
        }
        guard let drawing = try? persistence.loadDrawing(for: note),
              let url = try? persistence.regenerateThumbnail(for: note, drawing: drawing),
              let data = try? Data(contentsOf: url) else { return }
        image = UIImage(data: data)
    }
}
