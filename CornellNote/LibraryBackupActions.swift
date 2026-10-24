import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LibraryBackupActions: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let writeAdmission: NoteWriteAdmission
    let hasRetainedDraft: Bool
    @Binding var restoreState: RestoreState?
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = CornellNoteBackupDocument(data: Data())
    @State private var transferError: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("バックアップを書き出す", action: beginBackupExport)
                        Button("バックアップを読み込む", action: { isImportingBackup = true })
                    } label: {
                        Label("バックアップ", systemImage: "externaldrive")
                    }
                    .disabled(hasRetainedDraft)
                }
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
    }

    private func beginBackupExport() {
        guard writeAdmission.isAllowed, !hasRetainedDraft else { return }
        do {
            let coordinator = BackupExportCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
            backupDocument = CornellNoteBackupDocument(data: try coordinator.makeVerifiedEnvelope())
            isExportingBackup = true
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        guard writeAdmission.isAllowed, !hasRetainedDraft else { return }
        guard let url = try? result.get().first else {
            if case .failure(let error) = result { transferError = error.localizedDescription }
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: LocalNoteFileSystem())
        let restoreResult = try? coordinator.restore(from: url, provider: LocalDocumentProviderAdapter())
        restoreState = restoreResult?.state ?? .restoreFailed
        if restoreResult?.state == .completed || restoreResult?.state == .recoveryRequired {
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
