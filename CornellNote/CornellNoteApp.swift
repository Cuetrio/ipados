import SwiftData
import SwiftUI

@main
struct CornellNoteApp: App {
    var body: some Scene {
        WindowGroup {
            CornellNoteRootView()
        }
    }
}

@MainActor
private struct CornellNoteRootView: View {
    @State private var startup = NoteStartupController(fileSystem: LocalNoteFileSystem())

    var body: some View {
        Group {
            switch startup.state {
            case .checking:
                ProgressView("保存領域を確認中")
            case .ready(let generation):
                LibraryView(writeAdmission: generation.writeAdmission)
                    .modelContainer(generation.container)
                    .id(ObjectIdentifier(generation.container))
            case .blocked(let failure):
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("安全性を再確認") { startup.recheck() }
                }
            }
        }
        .task {
            if case .checking = startup.state { startup.recheck() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cornellNoteStoreDidSwitch)) { _ in
            startup.recheck()
        }
    }
}
