import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \NoteRecord.updatedAt, order: .reverse) private var notes: [NoteRecord]
    @State private var noteToDelete: NoteRecord?
    @Binding var restoreState: RestoreState?
    @State private var editingSession: NoteEditingSession?
    @State private var isEditorPresented = false
    @State private var capacity: Int64?
    @State private var operationError: String?

    private var isLowCapacity: Bool { LibraryBackupActions.isLowCapacity(capacity) }

    private var hasRetainedDraft: Bool {
        editingSession?.hasUnsavedChanges == true
    }

    let fileSystem: BackupFileSystem
    let writeAdmission: NoteWriteAdmission
    let startup: NoteStartupController

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    ContentUnavailableView("ノートはありません", systemImage: "note.text")
                }
                if isLowCapacity {
                    Text("空き容量が100 MB未満のため、新規ノートを作成できません。容量を確保してください。")
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
                                NoteThumbnailView(note: note, fileSystem: fileSystem, writeAdmission: writeAdmission)
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
                if !isPresented {
                    editingSession?.flushSave()
                }
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
                    .disabled(hasRetainedDraft || isLowCapacity)
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
            .alert("操作に失敗しました", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("閉じる", role: .cancel) { operationError = nil }
            } message: {
                Text(operationError ?? "")
            }
            .task {
                while !Task.isCancelled {
                    refreshCapacity()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .modifier(LibraryBackupActions(
                fileSystem: fileSystem,
                writeAdmission: writeAdmission,
                startup: startup,
                hasRetainedDraft: hasRetainedDraft,
                saveState: editingSession?.saveState ?? .saved,
                lastSaved: notes.first?.updatedAt,
                restoreState: $restoreState
            ))
            .task {
                guard writeAdmission.isAllowed else { return }
                let persistence = NotePersistenceController(modelContext: modelContext, fileSystem: fileSystem, canWrite: { [writeAdmission] in writeAdmission.isAllowed })
                notes.forEach { persistence.cleanupOrphans(for: $0) }
                let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: fileSystem)
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
                persistence: NotePersistenceController(modelContext: modelContext, fileSystem: fileSystem, canWrite: { [writeAdmission] in writeAdmission.isAllowed }),
                canWrite: { [writeAdmission] in writeAdmission.isAllowed }
            )
            if let editingSession { writeAdmission.register(editingSession) }
        }
        isEditorPresented = true
    }

    private func refreshCapacity() {
        capacity = LibraryBackupActions.availableCapacity(at: fileSystem.rootURL)
    }

    static func createNote(in context: ModelContext, save: () throws -> Void) -> Bool {
        let note = NoteRecord()
        context.insert(note)
        do {
            try save()
            return true
        } catch {
            context.delete(note)
            return false
        }
    }

    static func performDelete(_ delete: () throws -> Void) -> Bool {
        do {
            try delete()
            return true
        } catch {
            return false
        }
    }

    private func createNote() {
        refreshCapacity()
        guard writeAdmission.isAllowed, !hasRetainedDraft, !isLowCapacity else { return }
        if !Self.createNote(in: modelContext, save: { try modelContext.save() }) {
            operationError = "ノートを作成できませんでした。空き容量を確認してください。"
        }
    }

    private func deleteSelectedNote() {
        guard let note = noteToDelete else { return }
        noteToDelete = nil
        guard writeAdmission.isAllowed, !hasRetainedDraft else { return }
        if !Self.performDelete({
            try NotePersistenceController(modelContext: modelContext, fileSystem: fileSystem, canWrite: { [writeAdmission] in writeAdmission.isAllowed }).delete(note: note)
        }) {
            operationError = "ノートを削除できませんでした。もう一度お試しください。"
        }
    }
}

private struct NoteThumbnailView: View {
    @Environment(\.modelContext) private var modelContext
    let note: NoteRecord
    let fileSystem: BackupFileSystem
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
        .task(id: NotePersistenceController.thumbnailKey(for: note)) { loadThumbnail() }
    }

    private func loadThumbnail() {
        image = nil
        guard writeAdmission.isAllowed else { return }
        let persistence = NotePersistenceController(modelContext: modelContext, fileSystem: fileSystem, canWrite: { [writeAdmission] in writeAdmission.isAllowed })
        image = persistence.thumbnailImage(for: note)
    }
}
