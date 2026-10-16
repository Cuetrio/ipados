import SwiftUI
import SwiftData

@main
struct CornellNoteApp: App {
    var body: some Scene {
        WindowGroup {
            CornellNoteRootView()
        }
    }
}

private struct CornellNoteRootView: View {
    @State private var container: ModelContainer

    init() {
        do {
            _container = State(initialValue: try NotePersistenceController.makeContainer(fileSystem: LocalNoteFileSystem()))
        } catch {
            fatalError("Cornell Note storage could not be opened: \(error)")
        }
    }

    var body: some View {
        LibraryView()
            .modelContainer(container)
            .onReceive(NotificationCenter.default.publisher(for: .cornellNoteStoreDidSwitch)) { _ in
                do {
                    container = try NotePersistenceController.makeContainer(fileSystem: LocalNoteFileSystem())
                } catch {
                    // The restore coordinator has already retained the safety backup and marker.
                }
            }
    }
}
