import AppKit

/// The editing surface.
///
/// Holds the current parse, decides how much needs restyling after each edit,
/// and reveals syntax markers on whichever lines the selection touches.
final class MarkdownTextView: NSTextView {

    // MARK: State

    private(set) var parsed = ParsedDocument.empty
    private(set) var chars: [unichar] = []

    let styler: MarkdownStyler
    private var isStyling = false
    private var revealedLines = Set<Int>()
    private var pendingFullRestyle = true
    private var pendingEdit: NSRange?
    private var hasScheduledRestyle = false
    /// Line range covered by the last viewport repaint, so scrolling only
    /// restyles when genuinely new lines come into view.
    /// Lines painted while a diagram, equation or image was still resolving.
    private var staleLines: Range<Int>?
    /// Table-cell editing state.
    var isEditingTableCell = false
    var tableCaretIsVisible = true
    var caretBlinkTimer: Timer?
    /// Caret rect in view coordinates, refreshed off the draw path.
    var cachedTableCaretRect: NSRect?
    var tableCaretRefreshScheduled = false
    var tableCaretLayer: CALayer?
    private var _lastTableSelectionKey = ""
    private var renderRepaintWork: DispatchWorkItem?
    private var isAdjustingScroll = false

    var preferences: Preferences { .shared }
    var onSelectionChange: (() -> Void)?
    var onTextChange: (() -> Void)?

    // MARK: - Init

    init(theme: Theme, textContainer: NSTextContainer) {
        styler = MarkdownStyler(theme: theme)
        super.init(frame: .zero, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = preferences.smartSubstitutions
        isAutomaticDashSubstitutionEnabled = preferences.smartSubstitutions
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = preferences.spellChecking
        isGrammarCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        drawsBackground = true
        smartInsertDeleteEnabled = true
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0

        applyTheme(styler.theme)
        textStorage?.delegate = self
        textLayoutManager?.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderDidFinish),
            name: .markerRenderDidFinish,
            object: nil)
    }

    /// A diagram, equation or image finished loading: repaint what's on screen.
    ///
    /// Scoped to the viewport because off-screen blocks will be styled anyway
    /// when they scroll into view, and a full restyle of a large document here
    /// would stutter.
    /// Coalesced: a burst of renders finishing should cause one repaint, not one
    /// per diagram.
    @objc private func renderDidFinish() {
        renderRepaintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.repaintResolvedContent() }
        renderRepaintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func repaintResolvedContent() {
        guard isParseCurrent, !parsed.lines.isEmpty else { return }

        // Everything that could have been waiting: the diagram blocks, whatever
        // is on screen, and any lines recorded as painted-while-pending.
        var ranges = MarkdownStyler.renderableLineRanges(in: parsed)
        if let visible = visibleCharacterRange() {
            ranges.append(parsed.lineIndices(intersecting: visible))
        }
        if let staleLines { ranges.append(staleLines) }
        restyle(lineRanges: ranges, preserveAnchor: true)
    }

    private func restyle(lineRanges: [Range<Int>], preserveAnchor: Bool = false) {
        guard let storage = textStorage, !parsed.lines.isEmpty else { return }
        let clamped = lineRanges.compactMap { range -> Range<Int>? in
            let lower = max(0, range.lowerBound)
            let upper = min(parsed.lines.count, range.upperBound)
            return lower < upper ? lower..<upper : nil
        }
        guard !clamped.isEmpty else { return }

        // Only worth compensating when the repaint reaches above the viewport;
        // otherwise nothing the reader is looking at can move.
        let anchorLine = visibleCharacterRange().map { parsed.lineIndices(intersecting: $0).lowerBound }
        let reachesAboveViewport = clamped.contains { range in
            guard let anchorLine else { return false }
            return range.lowerBound + 4 < anchorLine
        }

        var painted: Range<Int>?
        for range in clamped {
            painted = painted.map { min($0.lowerBound, range.lowerBound)
                                    ..< max($0.upperBound, range.upperBound) } ?? range
        }

        preservingScrollAnchor(enabled: preserveAnchor && reachesAboveViewport) {
        performStyling(affecting: charRange(covering: clamped)) {
            for range in clamped {
                styler.style(lines: range,
                             doc: parsed,
                             chars: chars,
                             storage: storage,
                             revealed: revealedLines,
                             caretLines: caretLines,
                             selection: selectedRange(),
                             focusLines: focusLineRange())
            }
        }
        }
        noteStaleness(painted: painted)
    }

    /// Remembers, or forgets, that a run of lines is waiting on something.
    private func noteStaleness(painted: Range<Int>?) {
        guard let painted else { return }
        if styler.lastPassDeferred {
            staleLines = staleLines.map { min($0.lowerBound, painted.lowerBound)
                                          ..< max($0.upperBound, painted.upperBound) } ?? painted
        } else if let current = staleLines,
                  painted.lowerBound <= current.lowerBound,
                  painted.upperBound >= current.upperBound {
            staleLines = nil
        }
    }

    /// Keeps the line at the top of the viewport where it is.
    ///
    /// A diagram or image finishing changes its block's height. If that block
    /// sits above the viewport, everything below shifts and the reader is
    /// yanked up or down the document. Measuring one anchor line before and
    /// after the repaint and compensating keeps the page visually still.
    private func preservingScrollAnchor(enabled: Bool, _ work: () -> Void) {
        guard enabled,
              let scrollView = enclosingScrollView,
              let anchor = visibleCharacterRange()?.location,
              let before = documentY(for: anchor) else { work(); return }

        let origin = scrollView.contentView.bounds.origin
        work()

        guard let after = documentY(for: anchor) else { return }
        let delta = after - before
        // A large delta means TextKit re-estimated lazily laid-out content
        // rather than a block actually changing size; don't chase that.
        guard abs(delta) > 0.5, abs(delta) < scrollView.contentSize.height else { return }

        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y + delta))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
    }

    private func documentY(for location: Int) -> CGFloat? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textLocation = contentManager.location(contentManager.documentRange.location,
                                                         offsetBy: location),
              let fragment = layoutManager.textLayoutFragment(for: textLocation) else { return nil }
        return fragment.layoutFragmentFrame.minY
    }

    /// Called when the viewport moves.
    ///
    /// Deliberately does nothing. Restyling here invalidates layout for the
    /// visible lines, and the re-layout shifts them a point or two — which reads
    /// as the view settling and then clicking up or down once scrolling stops.
    /// Correctness is handled by `staleLines` instead: lines painted while a
    /// render was in flight are repainted when it lands, not when they happen to
    /// scroll past.
    func viewportDidChange() {}

    /// Flips diagram and equation blocks between rendered and source as the
    /// caret enters and leaves them.
    ///
    /// Tracked by region rather than by line: the caret can move several times
    /// per edit, and a per-line delta loses the transition when an intermediate
    /// move already consumed it.
    private func restyleBlocksIfCaretMoved() {
        guard isParseCurrent, !parsed.lines.isEmpty else { return }
        var current = Set<BlockKey>()
        for line in caretLines where line < parsed.lines.count {
            if let region = parsed.lines[line].codeRegion { current.insert(.code(region)) }
            if let region = parsed.lines[line].tableRegion { current.insert(.table(region)) }
        }
        guard current != lastCaretRegions else { return }

        let affected = current.union(lastCaretRegions)
        lastCaretRegions = current
        let ranges = affected.compactMap { key -> Range<Int>? in
            switch key {
            case .code(let index):
                guard index < parsed.codeRegions.count else { return nil }
                return parsed.codeRegions[index].lineRange
            case .table(let index):
                guard index < parsed.tableRegions.count else { return nil }
                return parsed.tableRegions[index].lineRange
            }
        }
        guard !ranges.isEmpty else { return }
        restyle(lineRanges: ranges)
    }

    /// Repaints a table whose selection highlight changed.
    private func restyleTableSelectionIfNeeded() {
        let caret = selectedRange()
        let region = tableRegionIndex(containing: caret.location)
        let key = region.map { "\($0):\(caret.location):\(caret.length)" } ?? ""
        guard key != lastTableSelectionKey else { return }
        lastTableSelectionKey = key
        guard let region, region < parsed.tableRegions.count else { return }
        restyle(lineRanges: [parsed.tableRegions[region].lineRange])
    }

    private var lastTableSelectionKey: String {
        get { _lastTableSelectionKey }
        set { _lastTableSelectionKey = newValue }
    }

    /// Character range currently laid out in the viewport.
    func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return nil }
        let start = contentManager.offset(from: contentManager.documentRange.location,
                                          to: viewport.location)
        let end = contentManager.offset(from: contentManager.documentRange.location,
                                        to: viewport.endLocation)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Theme

    /// Resolves theme colors against the view's current appearance and hands
    /// them to the styler — the offscreen renderer has no appearance of its own.
    func refreshRenderContext() {
        let theme = styler.theme
        effectiveAppearance.performAsCurrentDrawingAppearance {
            styler.context.isDark =
                effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            styler.context.textColorHex = theme.text.cssHex
            styler.context.backgroundHex = theme.background.cssHex
            styler.context.codeBackgroundHex = theme.codeBackground.cssHex
        }
        styler.context.documentDirectory =
            (window?.windowController?.document as? MarkdownDocument)?
            .fileURL?.deletingLastPathComponent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshRenderContext()
        restyleEverything()
    }

    func applyTheme(_ theme: Theme) {
        styler.updateTheme(theme)
        refreshRenderContext()
        backgroundColor = theme.background
        insertionPointColor = theme.insertionPoint
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes = [
            .font: theme.body,
            .foregroundColor: theme.text,
        ]
        font = theme.body
        isContinuousSpellCheckingEnabled = preferences.spellChecking
        isAutomaticQuoteSubstitutionEnabled = preferences.smartSubstitutions
        isAutomaticDashSubstitutionEnabled = preferences.smartSubstitutions
        restyleEverything()
    }

    // MARK: - Parsing & styling

    /// Re-reads the whole document and repaints every line. Used on load and
    /// whenever the theme changes.
    func restyleEverything() {
        guard let storage = textStorage else { return }
        refreshCharacterBuffer(storage)
        parsed = MarkdownParser.parse(storage.string as NSString)
        styler.documentDidReparse()
        updateRevealedLines(restyle: false)
        staleLines = nil
        performStyling(affecting: nil) { styler.style(lines: 0..<parsed.lines.count,
                                      doc: parsed,
                                      chars: chars,
                                      storage: storage,
                                      revealed: revealedLines,
                                      caretLines: caretLines,
                                      selection: selectedRange(),
                                      focusLines: focusLineRange()) }
        noteStaleness(painted: 0..<parsed.lines.count)
        pendingFullRestyle = false
    }

    /// True when `parsed` and `chars` describe the storage's current contents.
    ///
    /// Reparsing is deferred out of the storage's edit cycle, so between a
    /// keystroke and that callback every range in `parsed` is off by the edit's
    /// length. Styling during that window would apply attributes at the wrong
    /// offsets, so anything that styles has to check this first.
    var isParseCurrent: Bool { parsed.length == (textStorage?.length ?? 0) }

    /// Reparses without restyling — for commands that need current ranges.
    func reparseNow() {
        guard let storage = textStorage else { return }
        refreshCharacterBuffer(storage)
        parsed = MarkdownParser.parse(storage.string as NSString)
        styler.documentDidReparse()
    }

    private func refreshCharacterBuffer(_ storage: NSTextStorage) {
        let string = storage.string as NSString
        let length = string.length
        if chars.count != length { chars = [unichar](repeating: 0, count: length) }
        guard length > 0 else { return }
        chars.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                string.getCharacters(base, range: NSRange(location: 0, length: length))
            }
        }
    }

    private func handleEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard let storage = textStorage else { return }

        let previous = parsed
        refreshCharacterBuffer(storage)
        parsed = MarkdownParser.parse(storage.string as NSString)
        styler.documentDidReparse()

        let editedLines = parsed.lineIndices(intersecting: editedRange)
        var lower = editedLines.lowerBound
        var upper = editedLines.upperBound

        // A paragraph's rendering can depend on its neighbours (setext headings,
        // table detection, code fences), so always include one line either side.
        lower = max(0, lower - 1)
        upper = min(parsed.lines.count, upper + 1)

        // Opening or closing a fence reclassifies everything below it. Find the
        // last line whose classification actually changed and repaint to there.
        if let divergence = lastDivergence(previous.signatures, parsed.signatures) {
            upper = min(parsed.lines.count, max(upper, divergence + 1))
        }

        // Tables and code blocks are styled as a unit — column widths and token
        // state depend on sibling lines — so widen to whole regions.
        for region in parsed.tableRegions where region.lineRange.overlaps(lower..<upper) {
            lower = min(lower, region.lineRange.lowerBound)
            upper = max(upper, region.lineRange.upperBound)
        }
        for region in parsed.codeRegions where region.lineRange.overlaps(lower..<upper) {
            lower = min(lower, region.lineRange.lowerBound)
            upper = max(upper, region.lineRange.upperBound)
        }
        upper = min(upper, parsed.lines.count)

        let revealChanged = updateRevealedLines(restyle: false)
        let focus = focusLineRange()
        var touched = [lower..<upper]
        touched.append(contentsOf: revealChanged.map { $0..<($0 + 1) })
        performStyling(affecting: charRange(covering: touched)) {
            styler.style(lines: lower..<upper,
                         doc: parsed,
                         chars: chars,
                         storage: storage,
                         revealed: revealedLines,
                         caretLines: caretLines,
                         selection: selectedRange(),
                         focusLines: focus)
            // Lines that gained or lost their markers may sit outside the edit.
            for line in revealChanged.sorted()
            where line < parsed.lines.count && !(lower..<upper).contains(line) {
                styler.style(lines: line..<(line + 1),
                             doc: parsed,
                             chars: chars,
                             storage: storage,
                             revealed: revealedLines,
                             caretLines: caretLines,
                             selection: selectedRange(),
                             focusLines: focus)
            }
        }
        restyleBlocksIfCaretMoved()
        if preferences.focusMode { restyleFocusContext() }
    }

    /// Index of the last line whose kind differs between two parses.
    private func lastDivergence(_ old: [Int], _ new: [Int]) -> Int? {
        var index = max(old.count, new.count) - 1
        while index >= 0 {
            let a = index < old.count ? old[index] : Int.min
            let b = index < new.count ? new[index] : Int.min
            if a != b { return index }
            index -= 1
        }
        return nil
    }

    /// Applies attribute changes, then invalidates layout for **only** the
    /// characters that changed.
    ///
    /// Invalidating the whole document here re-lays out every line on every
    /// keystroke and every scroll tick, which is what made scrolling stutter and
    /// jump in longer files.
    private func performStyling(affecting range: NSRange?, _ work: () -> Void) {
        guard !isStyling, let storage = textStorage else { return }
        isStyling = true
        storage.beginEditing()
        work()
        storage.endEditing()
        isStyling = false
        invalidateLayout(for: range)
        // The caret rect comes from a layout fragment frame, which is meaningless
        // until the layout we just invalidated has settled. Recompute next turn.
        scheduleTableCaretRefresh()
    }

    private func invalidateLayout(for range: NSRange?) {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }

        guard let range, range.length > 0 else {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            needsDisplay = true
            return
        }
        guard let start = contentManager.location(contentManager.documentRange.location,
                                                  offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            needsDisplay = true
            return
        }
        layoutManager.invalidateLayout(for: textRange)
        needsDisplay = true
    }

    /// Character range spanning a set of line ranges.
    private func charRange(covering lineRanges: [Range<Int>]) -> NSRange? {
        var lower = Int.max
        var upper = Int.min
        for range in lineRanges where !range.isEmpty {
            lower = min(lower, range.lowerBound)
            upper = max(upper, range.upperBound)
        }
        guard lower <= upper, lower != Int.max else { return nil }
        return parsed.charRange(forLines: lower..<upper)
    }

    // MARK: - Reveal

    /// Lines the selection touches. Drives block-level source display for code,
    /// math and Mermaid — not inline markers.
    private var caretLines: Set<Int> {
        var result = Set<Int>()
        for value in selectedRanges {
            for index in parsed.lineIndices(intersecting: value.rangeValue) { result.insert(index) }
        }
        return result
    }

    /// Which lines show their raw syntax markers.
    ///
    /// Normally none: markers stay hidden while you edit the rendered text, the
    /// way a word processor does. `Show Markdown Source` reveals all of them.
    private func currentRevealedLines() -> Set<Int> {
        guard preferences.showMarkdownSource, !parsed.lines.isEmpty else { return [] }
        return Set(0..<parsed.lines.count)
    }

    private func focusLineRange() -> Range<Int>? {
        guard preferences.focusMode, !parsed.lines.isEmpty else { return nil }
        let index = parsed.lineIndex(at: selectedRange().location)

        // Focus the whole Markdown block the caret sits in, not just one line.
        var lower = index
        while lower > 0, parsed.lines[lower - 1].kind != .blank { lower -= 1 }
        var upper = index + 1
        while upper < parsed.lines.count, parsed.lines[upper].kind != .blank { upper += 1 }
        return lower..<upper
    }

    @discardableResult
    private func updateRevealedLines(restyle: Bool) -> Set<Int> {
        let updated = currentRevealedLines()
        guard updated != revealedLines else { return [] }
        let changed = updated.symmetricDifference(revealedLines)
        revealedLines = updated
        guard restyle, let storage = textStorage, !changed.isEmpty else { return changed }

        performStyling(affecting: charRange(covering: changed.map { $0..<($0 + 1) })) {
            for line in changed.sorted() where line < parsed.lines.count {
                styler.style(lines: line..<(line + 1),
                             doc: parsed,
                             chars: chars,
                             storage: storage,
                             revealed: revealedLines,
                             caretLines: caretLines,
                             selection: selectedRange(),
                             focusLines: focusLineRange())
            }
        }
        return changed
    }

    private var lastFocusRange: Range<Int>?
    /// Blocks that swap between rendered and source as the caret enters them.
    enum BlockKey: Hashable {
        case code(Int)
        case table(Int)
    }
    private var lastCaretRegions = Set<BlockKey>()
    /// Which end of the selection is fixed while shift-arrow extends the other.
    private(set) var selectionAnchorIsAtStart = true
    private var previousCaret = 0

    private func restyleFocusContext() {
        guard let storage = textStorage else { return }
        let range = focusLineRange()
        guard range != lastFocusRange else { return }

        var affected: Set<Int> = []
        if let previous = lastFocusRange { affected.formUnion(previous) }
        if let range { affected.formUnion(range) }
        lastFocusRange = range

        // Repaint the old and new focus blocks plus everything between them,
        // which is what actually changes brightness.
        guard let lower = affected.min(), let upper = affected.max() else { return }
        let bounds = lower..<min(parsed.lines.count, upper + 1)
        performStyling(affecting: charRange(covering: [bounds])) {
            styler.style(lines: lower..<min(parsed.lines.count, upper + 1),
                         doc: parsed,
                         chars: chars,
                         storage: storage,
                         revealed: revealedLines,
                         caretLines: caretLines,
                         selection: selectedRange(),
                         focusLines: range)
        }
    }

    // MARK: - Selection

    override func setSelectedRanges(_ ranges: [NSValue],
                                    affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        // Clicks and vertical movement can land inside a zero-width marker run.
        // Snapping reads the laid-out table, whose cell ranges are only valid
        // while the parse matches the storage. Mid-edit the reparse has not run
        // yet, and snapping against stale geometry scatters typed characters.
        var adjusted = ranges
        if !isStyling, isParseCurrent, ranges.count == 1, let first = ranges.first {
            var snapped = snappedOutOfMarkers(first.rangeValue)
            snapped = snappedIntoCell(snapped)
            if snapped != first.rangeValue { adjusted = [NSValue(range: snapped)] }
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)

        let current = selectedRange()
        if current.length == 0 {
            selectionAnchorIsAtStart = true
        } else if previousCaret <= current.location {
            selectionAnchorIsAtStart = true
        } else if previousCaret >= NSMaxRange(current) {
            selectionAnchorIsAtStart = false
        }
        previousCaret = current.length == 0 ? current.location : previousCaret
        onSelectionChange?()
        // A pending reparse will restyle with correct offsets; doing it here with
        // stale ranges would corrupt the attributes.
        guard !isStyling, !parsed.lines.isEmpty, isParseCurrent else { return }
        refreshTableCaretState()
        restyleTableSelectionIfNeeded()
        restyleBlocksIfCaretMoved()
        updateRevealedLines(restyle: true)
        if preferences.focusMode { restyleFocusContext() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateTableCaretLayer()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateTableCaretLayer()
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    // MARK: - Spell checking

    /// Code is not prose. Split each request around fenced and indented code so
    /// identifiers never pick up red squiggles.
    override func checkText(in range: NSRange,
                            types checkingTypes: NSTextCheckingTypes,
                            options: [NSSpellChecker.OptionKey: Any] = [:]) {
        guard !parsed.codeRegions.isEmpty else {
            super.checkText(in: range, types: checkingTypes, options: options)
            return
        }
        for subrange in prose(in: range) {
            super.checkText(in: subrange, types: checkingTypes, options: options)
        }
    }

    private func prose(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)

        for region in parsed.codeRegions {
            let code = region.charRange
            guard NSMaxRange(code) > cursor else { continue }
            guard code.location < end else { break }
            if code.location > cursor {
                result.append(NSRange(location: cursor, length: code.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(code))
        }
        if cursor < end { result.append(NSRange(location: cursor, length: end - cursor)) }
        return result
    }

    /// Table keys are intercepted here so they win over the generic overrides.
    override func doCommand(by selector: Selector) {
        if handleTableKey(selector) { return }
        super.doCommand(by: selector)
    }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        styler.context.containerWidth = textContainer?.size.width ?? newSize.width
    }

    // MARK: - Focus-mode repaint on preference change

    func preferencesDidChange() {
        applyTheme(preferences.theme)
    }
}

// MARK: - NSTextStorageDelegate

extension MarkdownTextView: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isStyling else { return }

        // Styling must happen outside the storage's own edit cycle. Coalesce the
        // requests so a burst of keystrokes reparses once, not once per character.
        pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
        guard !hasScheduledRestyle else { return }
        hasScheduledRestyle = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledRestyle = false
            guard let range = self.pendingEdit else { return }
            self.pendingEdit = nil
            self.handleEdit(editedRange: range, changeInLength: delta)
        }
    }
}

// MARK: - NSTextLayoutManagerDelegate

extension MarkdownTextView: NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
