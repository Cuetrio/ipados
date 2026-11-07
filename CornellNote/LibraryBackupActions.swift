import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LibraryBackupActions: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let fileSystem: BackupFileSystem
    let writeAdmission: NoteWriteAdmission
    let startup: NoteStartupController
    let hasRetainedDraft: Bool
    let saveState: NoteSaveState
    let lastSaved: Date?
    @Binding var restoreState: RestoreState?
    @State private var isSettingsPresented = false
    @State private var isConfirmingRestore = false
    @State private var capacity: Int64?
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = CornellNoteBackupDocument(data: Data())
    @State private var transferError: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("設定 / バックアップ", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                NavigationStack {
                    Form {
                        Section("保存") {
                            LabeledContent("保存状態", value: saveState.label)
                            LabeledContent("現存ノートの最新更新日時") {
                                Text(lastSaved.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "確認できません")
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("現存ノートの最新更新日時")
                            .accessibilityValue(lastSaved.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "確認できません")
                            .accessibilityIdentifier("latestNoteUpdateDate")
                            Text("ノートの作成・編集日時です。復元したノートはバックアップ内の日時で、削除やバックアップ操作の日時は含みません。")
                            LabeledContent("利用可能容量", value: Self.capacityLabel(capacity))
                            Text("容量は変動します。保存やバックアップに必要な容量を確保できるとは限りません。")
                            if Self.isLowCapacity(capacity) {
                                Text("空き容量が100 MB未満です。早期警告の目安であり、必要な容量はデータ量によって異なります。保存やバックアップの前に容量を確保してください。")
                            }
                            if Self.isLowCapacity(capacity) || hasRetainedDraft || saveState == .saveFailed {
                                Text("容量不足や保存失敗時は安全に失敗し、最後に保存した内容を保護します。未保存の描画はアプリ終了時に失われる可能性があります。")
                            }
                        }
                        Section("バックアップ") {
                            Button("バックアップを書き出す", action: beginBackupExport)
                                .disabled(hasRetainedDraft || !writeAdmission.isAllowed)
                            Button("バックアップを読み込む") { isConfirmingRestore = true }
                                .disabled(!startup.canRestore)
                            if !startup.canRestore {
                                Text("すべてのウィンドウで描画を終え、未保存の変更を保存または破棄してから復元してください。")
                            }
                            if hasRetainedDraft {
                                Text("未保存の変更を保存または破棄してからバックアップを操作してください。")
                            }
                            if let restoreState {
                                LabeledContent("復元結果", value: restoreState.localizedLabel)
                            } else {
                                LabeledContent("復元結果", value: "なし")
                            }
                            if restoreState == .restoreFailed {
                                Text("復元できませんでした。既存のノートは保護されています。空き容量とバックアップを確認してください。")
                            }
                        }
                    }
                    .navigationTitle("設定 / バックアップ")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { isSettingsPresented = false }
                        }
                    }
                    .onAppear { refreshCapacity() }
                    .alert("すべてのノートを置き換えますか？", isPresented: $isConfirmingRestore) {
                        Button("ファイルを選択", role: .destructive) { isImportingBackup = true }
                        Button("キャンセル", role: .cancel) { }
                    } message: {
                        Text("復元すると現在のすべてのノートがバックアップの内容に置き換わります。元に戻せません。必要なノートは先にバックアップしてください。")
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
                }
            }
    }

    static func capacityLabel(_ capacity: Int64?) -> String {
        guard let capacity, capacity >= 0 else { return "取得できません" }
        if capacity == 0 { return "空き容量なし" }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    // An early warning, not a preflight: restore also needs space for current and incoming data.
    static let lowCapacityWarningBytes: Int64 = 100_000_000

    static func isLowCapacity(_ capacity: Int64?) -> Bool {
        guard let capacity, capacity >= 0 else { return false }
        return capacity < lowCapacityWarningBytes
    }

    private func refreshCapacity() {
        let root = fileSystem.rootURL
        capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func beginBackupExport() {
        guard writeAdmission.isAllowed, !hasRetainedDraft else { return }
        do {
            let coordinator = BackupExportCoordinator(modelContext: modelContext, fileSystem: fileSystem)
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
        let coordinator = BackupRestoreCoordinator(modelContext: modelContext, fileSystem: fileSystem, startup: startup)
        let restoreResult = try? coordinator.restore(from: url, provider: LocalDocumentProviderAdapter())
        restoreState = restoreResult?.state ?? .restoreFailed
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
