import AppKit

/// Builds the menu bar in code — the app ships without a nib.
enum MainMenu {

    static func build(outlineDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(formatMenu())
        main.addItem(viewMenu())
        main.addItem(outlineMenu(delegate: outlineDelegate))
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    // MARK: - Helpers

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    @discardableResult
    private static func add(_ menu: NSMenu,
                            _ title: String,
                            _ action: Selector?,
                            _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command,
                            target: AnyObject? = nil,
                            tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        if let target { item.target = target }
        menu.addItem(item)
        return item
    }

    // MARK: - App

    private static func appMenu() -> NSMenuItem {
        let (item, menu) = submenu("Marker")
        add(menu, "About Marker", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        add(menu, "Hide Marker", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
            [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Marker", #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    // MARK: - File

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")
        add(menu, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")

        let recent = NSMenu(title: "Open Recent")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        recent.addItem(clear)

        menu.addItem(.separator())
        add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "Save", #selector(NSDocument.save(_:)), "s")
        add(menu, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
        add(menu, "Rename…", #selector(NSDocument.rename(_:)))
        add(menu, "Move To…", #selector(NSDocument.move(_:)))
        add(menu, "Revert To Saved", #selector(NSDocument.revertToSaved(_:)), "r")
        menu.addItem(.separator())
        add(menu, "Export as HTML…", #selector(MarkdownDocument.exportHTML(_:)))
        menu.addItem(.separator())
        add(menu, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
        add(menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        return item
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Delete", #selector(NSText.delete(_:)))
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let (findItem, find) = submenu("Find")
        add(find, "Find…", #selector(NSTextView.performTextFinderAction(_:)), "f",
            tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(find, "Find and Replace…", #selector(NSTextView.performTextFinderAction(_:)), "f",
            [.command, .option],
            tag: NSTextFinder.Action.showReplaceInterface.rawValue)
        add(find, "Find Next", #selector(NSTextView.performTextFinderAction(_:)), "g",
            tag: NSTextFinder.Action.nextMatch.rawValue)
        add(find, "Find Previous", #selector(NSTextView.performTextFinderAction(_:)), "g",
            [.command, .shift],
            tag: NSTextFinder.Action.previousMatch.rawValue)
        add(find, "Use Selection for Find", #selector(NSTextView.performTextFinderAction(_:)), "e",
            tag: NSTextFinder.Action.setSearchString.rawValue)
        menu.addItem(findItem)

        let (spellingItem, spelling) = submenu("Spelling and Grammar")
        add(spelling, "Show Spelling and Grammar",
            #selector(NSText.showGuessPanel(_:)), ":")
        add(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        spelling.addItem(.separator())
        add(spelling, "Check Spelling While Typing",
            #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        menu.addItem(spellingItem)

        menu.addItem(.separator())
        add(menu, "Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ",
            [.command, .control])
        return item
    }

    // MARK: - Format

    private static func formatMenu() -> NSMenuItem {
        let (item, menu) = submenu("Format")
        add(menu, "Bold", #selector(MarkdownTextView.toggleBold(_:)), "b")
        add(menu, "Italic", #selector(MarkdownTextView.toggleItalic(_:)), "i")
        add(menu, "Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x",
            [.command, .shift])
        add(menu, "Highlight", #selector(MarkdownTextView.toggleHighlight(_:)), "h",
            [.command, .shift])
        add(menu, "Inline Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "c",
            [.command, .control])
        add(menu, "Link…", #selector(MarkdownTextView.insertMarkdownLink(_:)), "k")
        menu.addItem(.separator())

        let (headingItem, headings) = submenu("Heading")
        add(headings, "Body Text", #selector(MarkdownTextView.setHeadingLevel(_:)), "0",
            [.command, .control], tag: 0)
        for level in 1...6 {
            add(headings, "Heading \(level)", #selector(MarkdownTextView.setHeadingLevel(_:)),
                "\(level)", [.command, .control], tag: level)
        }
        menu.addItem(headingItem)

        menu.addItem(.separator())
        add(menu, "Bullet List", #selector(MarkdownTextView.toggleBulletList(_:)), "8",
            [.command, .shift])
        add(menu, "Numbered List", #selector(MarkdownTextView.toggleNumberedList(_:)), "7",
            [.command, .shift])
        add(menu, "Task List", #selector(MarkdownTextView.toggleTaskList(_:)), "9",
            [.command, .shift])
        add(menu, "Toggle Task", #selector(MarkdownTextView.toggleTaskAtCursor(_:)), "d",
            [.command, .shift])
        add(menu, "Blockquote", #selector(MarkdownTextView.toggleBlockquote(_:)), "'",
            [.command, .control])
        menu.addItem(.separator())
        add(menu, "Code Block", #selector(MarkdownTextView.insertCodeBlock(_:)), "c",
            [.command, .option])
        add(menu, "Horizontal Rule", #selector(MarkdownTextView.insertHorizontalRule(_:)), "-",
            [.command, .control])
        menu.addItem(.separator())
        add(menu, "Insert Table", #selector(MarkdownTextView.insertTable(_:)), "t",
            [.command, .option])
        add(menu, "Reformat Table", #selector(MarkdownTextView.formatTable(_:)), "t",
            [.command, .control])
        return item
    }

    // MARK: - View

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        add(menu, "Focus Mode", #selector(EditorViewController.toggleFocusMode(_:)), "f",
            [.command, .control])
        add(menu, "Typewriter Mode", #selector(EditorViewController.toggleTypewriterMode(_:)), "y",
            [.command, .control])
        add(menu, "Show Markdown Source",
            #selector(EditorViewController.toggleMarkdownSource(_:)), "s", [.command, .option])
        menu.addItem(.separator())
        add(menu, "Bigger Text", #selector(EditorViewController.increaseFontSize(_:)), "+")
        add(menu, "Smaller Text", #selector(EditorViewController.decreaseFontSize(_:)), "-")
        add(menu, "Actual Size", #selector(EditorViewController.resetFontSize(_:)), "0")
        menu.addItem(.separator())
        add(menu, "Wider Measure", #selector(EditorViewController.increaseContentWidth(_:)), "]",
            [.command, .option])
        add(menu, "Narrower Measure", #selector(EditorViewController.decreaseContentWidth(_:)), "[",
            [.command, .option])
        menu.addItem(.separator())

        let (appearanceItem, appearance) = submenu("Appearance")
        for choice in AppearanceChoice.allCases {
            let entry = add(appearance, choice.displayName,
                            #selector(AppDelegate.setAppearance(_:)))
            entry.representedObject = choice.rawValue
            entry.state = Preferences.shared.appearance == choice ? .on : .off
        }
        menu.addItem(appearanceItem)

        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
            [.command, .control, .shift])
        return item
    }

    // MARK: - Outline

    private static func outlineMenu(delegate: NSMenuDelegate) -> NSMenuItem {
        let (item, menu) = submenu("Outline")
        menu.delegate = delegate
        menu.autoenablesItems = false
        return item
    }

    // MARK: - Window / Help

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu("Help")
        // Key equivalents are matched against charactersIgnoringModifiers, so the
        // shifted "?" has to be spelled as "/" plus an explicit .shift.
        // `NSApp.helpMenu` is deliberately left unset: it installs a search field
        // that swallows the key equivalent before this item ever sees it.
        // No key equivalent: macOS reserves ⇧⌘/ system-wide for "Show Help menu",
        // so the conventional choice never reaches the app.
        add(menu, "Markdown Cheat Sheet", #selector(AppDelegate.showCheatSheet(_:)))
        return item
    }
}
