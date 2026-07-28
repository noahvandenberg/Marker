import AppKit

/// Hosts the text view: builds the TextKit 2 stack, keeps the measure centered,
/// and implements typewriter scrolling.
final class EditorViewController: NSViewController, NSUserInterfaceValidations {

    private(set) var textView: MarkdownTextView!
    private var scrollView: NSScrollView!
    private var titlebarBackdrop: NSVisualEffectView!
    private var updateBar: UpdateBar?
    private var updateBarTop: NSLayoutConstraint?
    private var contentStorage: NSTextContentStorage!
    private var layoutManager: NSTextLayoutManager!

    private var wordCountWorkItem: DispatchWorkItem?
    private var measureRestyleWork: DispatchWorkItem?
    private var latestWords = 0
    private var latestCharacters = 0
    private var latestTokens: Int?
    var onStatsChange: ((String) -> Void)?

    private var preferences: Preferences { .shared }

    var document: MarkdownDocument? {
        representedObject as? MarkdownDocument
    }

    // MARK: - Lifecycle

    override func loadView() {
        contentStorage = NSTextContentStorage()
        layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager

        let container = NSTextContainer(size: NSSize(width: 0,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container

        textView = MarkdownTextView(theme: preferences.theme, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.onTextChange = { [weak self] in self?.textDidChange() }
        textView.onSelectionChange = { [weak self] in self?.selectionDidChange() }

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = preferences.theme.background
        scrollView.documentView = textView
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerStyle = .overlay

        // The window uses a full-size content view, so text scrolls up behind the
        // title. Without something opaque back there it collides with the title
        // text; this is the blur a toolbar would otherwise provide.
        titlebarBackdrop = NSVisualEffectView()
        titlebarBackdrop.material = .headerView
        titlebarBackdrop.blendingMode = .withinWindow
        titlebarBackdrop.state = .followsWindowActiveState

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(titlebarBackdrop)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        titlebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titlebarBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebarBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarBackdrop.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .markerPreferencesDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAvailable(_:)),
            name: .markerUpdateAvailable,
            object: nil)
        if let update = UpdateChecker.shared.available { showUpdateBar(update) }


    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMeasure()
    }

    override var representedObject: Any? {
        didSet {
            guard let document else { return }
            document.editor = self
            textView.refreshRenderContext()
            setText(document.text)
        }
    }

    // MARK: - Text

    func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        textView.restyleEverything()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        updateStats()
    }

    private func textDidChange() {
        document?.updateText(textView.string)
        scheduleStatsUpdate()
        if preferences.typewriterMode { centerCaret(animated: false) }
    }

    private func selectionDidChange() {
        if preferences.typewriterMode { centerCaret(animated: false) }
    }

    // MARK: - Update bar

    @objc private func updateAvailable(_ note: Notification) {
        guard let update = note.object as? AvailableUpdate else { return }
        showUpdateBar(update)
    }

    private func showUpdateBar(_ update: AvailableUpdate) {
        guard updateBar == nil else { return }
        let bar = UpdateBar()
        bar.present(update)
        bar.onView = { NSWorkspace.shared.open(update.url) }
        bar.onDismiss = { [weak self] in
            UpdateChecker.shared.skip(update)
            self?.hideUpdateBar()
        }
        view.addSubview(bar)

        // Sits under the titlebar, above the text, and pushes nothing around:
        // the scroll view's top inset makes room for it.
        let top = bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top,
        ])
        updateBarTop = top
        updateBar = bar
        updateMeasure()
    }

    private func hideUpdateBar() {
        updateBar?.removeFromSuperview()
        updateBar = nil
        updateBarTop = nil
        updateMeasure()
    }

    // MARK: - Measure

    private func updateMeasure() {
        let available = scrollView.contentSize.width
        let target = min(preferences.contentWidth, max(320, available - 64))
        let horizontal = max(24, (available - target) / 2)
        let inset = NSSize(width: horizontal, height: 28)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        let width = max(0, available - horizontal * 2)
        if abs(width - textView.styler.context.containerWidth) > 0.5 {
            textView.styler.context.containerWidth = width
            scheduleMeasureRestyle()
        }

        // Content scrolls under the transparent titlebar, so the top inset comes
        // from the safe area rather than a hard-coded titlebar height.
        let top = scrollView.safeAreaInsets.top + 8 + (updateBar?.frame.height ?? 0)
        let bottom = preferences.typewriterMode ? scrollView.frame.height * 0.45 : 80
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInsets.top != insets.top
            || scrollView.contentInsets.bottom != insets.bottom {
            scrollView.contentInsets = insets
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -bottom, right: 0)
        }
    }

    /// Repaints once a resize settles: tables and diagrams are laid out to the
    /// measure, so a new width changes their geometry.
    private func scheduleMeasureRestyle() {
        measureRestyleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.textView.restyleEverything() }
        measureRestyleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - Typewriter scrolling

    private func centerCaret(animated: Bool) {
        guard let caretRect = caretRectInTextView() else { return }
        let visible = scrollView.contentView.bounds
        let target = caretRect.midY - visible.height * 0.42
        let maxOffset = max(0, textView.bounds.height - visible.height
                            + scrollView.contentInsets.bottom)
        let clamped = min(max(0, target), maxOffset)
        guard abs(clamped - visible.origin.y) > 1 else { return }

        let destination = NSPoint(x: visible.origin.x, y: clamped)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                scrollView.contentView.animator().setBoundsOrigin(destination)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(destination)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func caretRectInTextView() -> NSRect? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let caret = textView.selectedRange().location
        guard let location = contentManager.location(contentManager.documentRange.location,
                                                     offsetBy: caret),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        var frame = fragment.layoutFragmentFrame
        frame.origin.y += textView.textContainerInset.height
        return frame
    }

    // MARK: - Stats

    private func scheduleStatsUpdate() {
        wordCountWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.updateStats() }
        wordCountWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func updateStats() {
        let text = textView.string
        latestCharacters = text.count
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .localized]) { _, _, _, _ in
            words += 1
        }
        latestWords = words
        publishStats()

        guard preferences.showTokenCount else {
            latestTokens = nil
            return
        }
        // Real byte-pair encoding, so it runs off the main thread. The previous
        // figure stays on screen until the new one lands rather than blinking out.
        TokenCounter.shared.count(text) { [weak self] tokens in
            guard let self, let tokens else { return }
            self.latestTokens = tokens
            self.publishStats()
        }
    }

    private func publishStats() {
        var parts = ["\(Self.decimal.string(from: latestWords as NSNumber) ?? "0") "
                     + (latestWords == 1 ? "word" : "words"),
                     "\(Self.decimal.string(from: latestCharacters as NSNumber) ?? "0") characters"]
        if let latestTokens {
            parts.append("\(Self.decimal.string(from: latestTokens as NSNumber) ?? "0") "
                         + (latestTokens == 1 ? "token" : "tokens"))
        }
        onStatsChange?(parts.joined(separator: " · "))
    }

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // MARK: - Preferences

    @objc private func preferencesDidChange() {
        textView.preferencesDidChange()
        updateStats()
        scrollView.backgroundColor = preferences.theme.background
        updateMeasure()
        if preferences.typewriterMode { centerCaret(animated: false) }
    }

    // MARK: - View menu actions

    @IBAction func toggleTypewriterMode(_ sender: Any?) {
        preferences.typewriterMode.toggle()
        updateMeasure()
        if preferences.typewriterMode { centerCaret(animated: true) }
    }

    @IBAction func toggleMarkdownSource(_ sender: Any?) {
        preferences.showMarkdownSource.toggle()
        textView.restyleEverything()
    }

    @IBAction func toggleFocusMode(_ sender: Any?) {
        preferences.focusMode.toggle()
        textView.restyleEverything()
    }

    @IBAction func increaseContentWidth(_ sender: Any?) {
        preferences.contentWidth = min(1100, preferences.contentWidth + 60)
    }

    @IBAction func decreaseContentWidth(_ sender: Any?) {
        preferences.contentWidth = max(420, preferences.contentWidth - 60)
    }

    @IBAction func increaseFontSize(_ sender: Any?) {
        preferences.fontSize = min(32, preferences.fontSize + 1)
    }

    @IBAction func decreaseFontSize(_ sender: Any?) {
        preferences.fontSize = max(11, preferences.fontSize - 1)
    }

    @IBAction func resetFontSize(_ sender: Any?) {
        preferences.fontSize = 17
    }

    /// Jumps to a heading chosen from the Outline menu.
    @IBAction func jumpToHeading(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let location = item.representedObject as? Int else { return }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        view.window?.makeFirstResponder(textView)
    }

    func headingOutline() -> [(title: String, level: Int, location: Int)] {
        textView.syncParseIfNeeded()
        var result: [(String, Int, Int)] = []
        for line in textView.parsed.lines {
            switch line.kind {
            case .heading(let level, _, let contentRange, _):
                let title = textView.nsString.substring(with: contentRange)
                result.append((title.isEmpty ? "Untitled" : title, level, line.range.location))
            case .paragraph:
                let next = line.index + 1
                if next < textView.parsed.lines.count,
                   case .setextUnderline(let level) = textView.parsed.lines[next].kind {
                    let title = textView.nsString.substring(with: line.contentRange)
                    result.append((title.isEmpty ? "Untitled" : title, level, line.range.location))
                }
            default:
                break
            }
        }
        return result
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem {
            switch menuItem.action {
            case #selector(toggleTypewriterMode(_:)):
                menuItem.state = preferences.typewriterMode ? .on : .off
            case #selector(toggleFocusMode(_:)):
                menuItem.state = preferences.focusMode ? .on : .off
            case #selector(toggleMarkdownSource(_:)):
                menuItem.state = preferences.showMarkdownSource ? .on : .off
            default:
                break
            }
        }
        return true
    }
}
