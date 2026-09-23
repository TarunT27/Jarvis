import SwiftUI

/// Shared presentation metadata for the sidebar and the macOS Go menu.
/// Assistant continues to own the selected page and all application state.
enum AppPage: String, CaseIterable, Identifiable {
    case overview = "Overview", chat = "Chat", directory = "Chat directory", memory = "Memory"
    case workspace = "Notes & prompts", computer = "Computer use", setup = "Setup"
    case connections = "Connections", settings = "Settings", activity = "Activity"
    var id: String { rawValue }

    /// The single ordering. The sidebar rows, the Go menu and the ⌃⌘number
    /// shortcuts all read it, so a row's position and its shortcut cannot drift
    /// apart - which they had, leaving ⌃⌘1 on the second row.
    static var allCases: [AppPage] { [.chat, .overview, .directory, .memory, .connections, .workspace, .computer, .setup] }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .chat: "bubble.left.and.bubble.right"
        case .directory: "folder"
        case .workspace: "note.text"
        case .computer: "computermouse"
        case .setup: "checklist"
        case .memory: "brain"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .settings: "slider.horizontal.3"
        case .activity: "checkmark.shield"
        }
    }

    /// Nil for pages that are not in the numbered list.
    var shortcutNumber: Int? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return index + 1
    }

    /// Printed on the row itself, so the shortcut is discoverable without opening a menu.
    var shortcutLabel: String? {
        guard let number = shortcutNumber else { return nil }
        return "⌃⌘\(number)"
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
            ForEach(AppPage.allCases) { page in
                Button {
                    assistant.selectedPage = page.rawValue
                    showExistingWindowOrOpen()
                } label: {
                    Text(LocalizedStringKey(page.rawValue))
                }
                .keyboardShortcut(KeyEquivalent(Character(String(page.shortcutNumber ?? 0))), modifiers: [.control, .command])
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
