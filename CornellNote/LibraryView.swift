import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NoteRecord.updatedAt, order: .reverse) private var notes: [NoteRecord]
    @State private var noteToDelete: NoteRecord?
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = CornellNoteBackupDocument(data: Data())
    @State private var restoreState: RestoreState?
    @State private var transferError: String?

    init() {}

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    ContentUnavailableView("ノートはありません", systemImage: "note.text")
                }
                ForEach(notes) { note in
                    NavigationLink {
                        EditorView(note: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                NoteThumbnailView(note: note)
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
                    .swipeActions {
                        Button(role: .destructive) {
                            noteToDelete = note
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Cornell Note")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("バックアップを書き出す", action: beginBackupExport)
                        Button("バックアップを読み込む", action: { isImportingBackup = true })
                    } label: {
                        Label("バックアップ", systemImage: "externaldrive")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createNote) {
                        Label("新規ノート", systemImage: "plus")
                    }
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
            .alert("バックアップ処理に失敗しました", isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )) {
                Button("閉じる", role: .cancel) { transferError = nil }
            } message: {
                Text(transferError ?? "")
            }
            .fileImporter(
                isPresented: $isImportingBackup,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false,
                onCompletion: importBackup
            )
            .fileExporter(
                isPresented: $isExportingBackup,
                document: backupDocument,
                contentType: .data,
                defaultFilename: "CornellNote-backup.cornellnote-backup",
                onCompletion: exportCompleted
            )
            .overlay(alignment: .bottom) {
                if let restoreState {
                    Text(restoreState.localizedLabel)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            .task {
                let persistence = NotePersistenceController(modelContext: modelContext)
                notes.forEach { persistence.cleanupOrphans(for: $0) }
                let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
                if coordinator.recoveryMarker()?.recoveryRequired == true {
                    restoreState = .recoveryRequired
                }
            }
        }
    }

    private func beginBackupExport() {
        do {
            let coordinator = BackupExportCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
            backupDocument = CornellNoteBackupDocument(data: try coordinator.makeVerifiedEnvelope())
            isExportingBackup = true
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else {
            if case .failure(let error) = result { transferError = error.localizedDescription }
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
        let restoreResult = try? coordinator.restore(from: url, provider: LocalDocumentProviderAdapter())
        restoreState = restoreResult?.state ?? .restoreFailed
        if restoreResult?.state == .completed {
            NotificationCenter.default.post(name: .cornellNoteStoreDidSwitch, object: nil)
        }
        if restoreResult == nil { transferError = "バックアップを読み込めませんでした。" }
    }

    private func exportCompleted(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            transferError = error.localizedDescription
        case .success(let url):
            guard let data = try? Data(contentsOf: url),
                  data == backupDocument.data,
                  data.backupSHA256Hex == backupDocument.data.backupSHA256Hex else {
                transferError = "書き出し先のバックアップを検証できませんでした。"
                return
            }
        }
    }

    private func createNote() {
        let note = NoteRecord()
        modelContext.insert(note)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(note)
        }
    }

    private func deleteSelectedNote() {
        guard let note = noteToDelete else { return }
        do {
            try NotePersistenceController(modelContext: modelContext).delete(note: note)
        } catch {
            noteToDelete = nil
        }
    }
}

private struct CornellNoteBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension RestoreState {
    var localizedLabel: String {
        switch self {
        case .preparing: return "準備中"
        case .validating: return "検証中"
        case .restoring: return "復元中"
        case .completed: return "復元完了"
        case .restoreFailed: return "復元に失敗しました"
        case .recoveryRequired: return "復旧が必要です"
        }
    }
}

private struct NoteThumbnailView: View {
    @Environment(\.modelContext) private var modelContext
    let note: NoteRecord
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
