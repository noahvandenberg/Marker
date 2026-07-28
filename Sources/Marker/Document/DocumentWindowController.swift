import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate {

    private var editor: EditorViewController? {
        contentViewController as? EditorViewController
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 480, height: 320)

        self.init(window: window)

        let controller = EditorViewController()
        controller.onStatsChange = { [weak window] stats in
            window?.subtitle = stats
        }
        // Assigning a content view controller resizes the window to that view's
        // fitting size, so the real geometry has to be applied afterwards.
        contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 720))
        window.center()
        window.delegate = self
        shouldCascadeWindows = true
        windowFrameAutosaveName = "MarkerDocumentWindow"
        ensureOnScreen(window)
    }

    /// Pulls a restored frame back onto a display that still exists.
    ///
    /// The saved frame follows the app across sessions, and on a machine whose
    /// displays come and go it can name a position that is now off the bottom of
    /// the screen — leaving the app running with a window nobody can see.
    private func ensureOnScreen(_ window: NSWindow) {
        let frame = window.frame
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            guard !overlap.isNull else { return false }
            // Require enough of the window to be reachable to drag it.
            return overlap.width >= min(frame.width, 200)
                && overlap.height >= min(frame.height, 120)
        }
        guard !visible else { return }

        let bounds = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(frame.width, bounds.width - 80),
                          height: min(frame.height, bounds.height - 80))
        window.setFrame(NSRect(x: bounds.midX - size.width / 2,
                               y: bounds.midY - size.height / 2,
                               width: size.width,
                               height: size.height),
                        display: false)
    }

    override var document: AnyObject? {
        didSet {
            contentViewController?.representedObject = document
            window?.appearance = Preferences.shared.appearance.nsAppearance
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        focusEditor()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusEditor()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusEditor()
    }

    /// Without this the window opens with the title bar's rename field focused,
    /// so the first thing typed renames the file instead of editing it.
    private func focusEditor() {
        guard let window, let textView = editor?.textView else { return }
        window.initialFirstResponder = textView
        guard !hasFocusedEditor else { return }
        hasFocusedEditor = true
        window.makeFirstResponder(textView)
    }

    private var hasFocusedEditor = false

    // MARK: - Outline menu

    /// Rebuilt on demand so the Outline menu always matches the document.
    func populateOutlineMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let headings = editor?.headingOutline() ?? []
        guard !headings.isEmpty else {
            let empty = NSMenuItem(title: "No Headings", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for heading in headings {
            let indent = String(repeating: "    ", count: max(0, heading.level - 1))
            let item = NSMenuItem(title: indent + heading.title,
                                  action: #selector(EditorViewController.jumpToHeading(_:)),
                                  keyEquivalent: "")
            item.target = editor
            item.representedObject = heading.location
            menu.addItem(item)
        }
    }
}
