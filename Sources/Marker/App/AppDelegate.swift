import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(outlineDelegate: self)
        NSApp.appearance = Preferences.shared.appearance.nsAppearance
        _ = NSDocumentController.shared
        UpdateChecker.shared.checkIfDue()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.check(userInitiated: true) { result in
            switch result {
            case .success(let update) where update == nil:
                let alert = NSAlert()
                alert.messageText = "Marker is up to date."
                alert.informativeText =
                    "You're running version \(UpdateChecker.shared.currentVersion)."
                alert.runModal()
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't check for updates."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            case .success:
                break   // the bar appears on its own
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView()
            .environmentObject(Preferences.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc func setAppearance(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let choice = AppearanceChoice(rawValue: raw) else { return }
        Preferences.shared.appearance = choice
        for window in NSApp.windows { window.appearance = choice.nsAppearance }
        if let menu = item.menu {
            for entry in menu.items {
                entry.state = (entry.representedObject as? String) == raw ? .on : .off
            }
        }
    }

    // MARK: - Help

    @objc func showCheatSheet(_ sender: Any?) {
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            guard let markdown = document as? MarkdownDocument else { return }
            markdown.updateText(AppDelegate.cheatSheet)
            // `openUntitledDocumentAndDisplay(false)` may already have made one.
            if markdown.windowControllers.isEmpty { markdown.makeWindowControllers() }
            markdown.showWindows()
            markdown.pushTextToEditor()
            markdown.updateChangeCount(.changeCleared)
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: - Outline menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller = NSApp.keyWindow?.windowController as? DocumentWindowController else {
            menu.removeAllItems()
            let empty = NSMenuItem(title: "No Document", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        controller.populateOutlineMenu(menu)
    }

    // MARK: - Cheat sheet content

    static let cheatSheet = """
    # Marker

    A native Markdown editor. Everything below is live — put the caret on a line
    to see the raw syntax, move away and it renders.

    ## Text

    **Bold**, *italic*, ***both***, `inline code`, ~~struck through~~, ==highlighted==.

    A [link to a website](https://example.com) and a footnote reference[^1].

    [^1]: Footnotes render as superscripts.

    ## Headings

    Use `#` through `######`, or press ⌃⌘1 – ⌃⌘6. ⌃⌘0 returns a line to body text.

    ## Lists

    - A bullet
    - Another bullet
      - Nested one level
        - And another
    1. Numbered
    2. Lists
    3. Continue automatically on Return

    - [ ] An unchecked task — click the box to toggle it
    - [x] A finished task

    ## Quotes

    > Blockquotes carry a bar down the left.
    > > And they nest.

    ## Code

    ```swift
    struct Note: Identifiable {
        let id: UUID
        var title: String

        // Fenced blocks are syntax highlighted.
        func slug() -> String {
            title.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }
    ```

    ```python
    def summarize(lines: list[str]) -> str:
        \"\"\"Many languages are supported.\"\"\"
        return " ".join(line.strip() for line in lines if line)
    ```

    ## Tables

    | Feature | Shortcut | Notes |
    | --- | :---: | --- |
    | Insert table | ⌥⌘T | Starter 3×3 grid |
    | Reformat | ⌃⌘T | Pads the source so it lines up |
    | Next cell | Tab | Reformats, then jumps |

    ## Everything else

    ---

    Press ⌘, for settings — typeface, measure, line height and appearance.
    ⌃⌘F dims everything but the paragraph you're in; ⌃⌘Y keeps the caret centered.
    ⌘-click a link to open it.
    """
}
