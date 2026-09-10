import SwiftUI

/// Shared presentation metadata for the sidebar and the macOS Go menu.
/// Assistant continues to own the selected page and all application state.
enum AppPage: String, CaseIterable, Identifiable {
    case overview = "Overview", chat = "Chat", directory = "Chat directory", memory = "Memory"
    case connections = "Connections", settings = "Settings", activity = "Activity"
    var id: String { rawValue }
    static var allCases: [AppPage] { [.overview,.chat,.directory,.memory,.connections] }
    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .chat: "bubble.left.and.bubble.right"
        case .directory: "folder"
        case .memory: "brain"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .settings: "slider.horizontal.3"
        case .activity: "checkmark.shield"
        }
    }
}

struct JarvisNavigationCommands: Commands {
    let assistant: Assistant
    @Environment(\.openWindow) private var openWindow

    private func showExistingWindowOrOpen() {
        // WindowGroup creates a new window on every openWindow call. Menu navigation
        // should change the current page, not create duplicate chat windows.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openWindow(id: "main")
        }
    }

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(AppPage.allCases.enumerated()), id: \.element) { index, page in
                Button {
                    assistant.selectedPage = page.rawValue
                    showExistingWindowOrOpen()
                } label: {
                    Text(LocalizedStringKey(page.rawValue))
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
            }
        }
        CommandGroup(after: .appSettings) {
            Button("Settings…") {
                assistant.selectedPage = AppPage.settings.rawValue
                showExistingWindowOrOpen()
            }.keyboardShortcut(",")
        }
    }
}
