import AppKit

// MARK: - Editing helpers

extension MarkdownTextView {

    var nsString: NSString { (textStorage?.string ?? "") as NSString }

    func lineText(_ line: LineInfo) -> String {
        guard NSMaxRange(line.range) <= nsString.length else { return "" }
        return nsString.substring(with: line.range)
    }

    /// The parse is refreshed asynchronously after each edit; commands that run
    /// back-to-back need a guaranteed-current view of the document.
    func syncParseIfNeeded() {
        if !isParseCurrent || parsed.lines.isEmpty { reparseNow() }
    }

    var currentLine: LineInfo? {
        guard !parsed.lines.isEmpty else { return nil }
        return parsed.lines[parsed.lineIndex(at: selectedRange().location)]
    }

    var selectedLineIndices: Range<Int> {
        guard !parsed.lines.isEmpty else { return 0..<0 }
        return parsed.lineIndices(intersecting: selectedRange())
    }

    @discardableResult
    func applyEdit(_ range: NSRange, _ replacement: String, selecting: NSRange? = nil) -> Bool {
        guard let storage = textStorage else { return false }
        let clamped = NSRange(location: min(range.location, storage.length),
                              length: min(range.length, max(0, storage.length - range.location)))
        guard shouldChangeText(in: clamped, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: clamped, with: replacement)
        didChangeText()
        if let selecting { setSelectedRange(selecting) }
        return true
    }

    /// Rewrites a run of lines in a single undoable edit.
    func rewriteLines(_ lineRange: Range<Int>,
                      selecting: NSRange? = nil,
                      transform: (LineInfo, String) -> String) {
        guard !parsed.lines.isEmpty, !lineRange.isEmpty else { return }
        let lower = max(0, lineRange.lowerBound)
        let upper = min(parsed.lines.count, lineRange.upperBound)
        guard lower < upper else { return }

        var pieces: [String] = []
        for index in lower..<upper {
            let line = parsed.lines[index]
            pieces.append(transform(line, lineText(line)))
        }

        let start = parsed.lines[lower].range.location
        let end = NSMaxRange(parsed.lines[upper - 1].range)
        applyEdit(NSRange(location: start, length: end - start),
                  pieces.joined(separator: "\n"),
                  selecting: selecting)
    }
}

// MARK: - Return, Tab, Delete

extension MarkdownTextView {

    override func insertNewline(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine, selectedRange().length == 0 else {
            super.insertNewline(sender)
            return
        }
        let caret = selectedRange().location

        // Inside a table, Return is just a newline: a table being typed by hand
        // is still half-formed, and inserting a row here fights the user.
        if case .tableRow = line.kind {
            super.insertNewline(sender)
            return
        }

        if case .listItem(let marker, let markerRange, let checkbox) = line.kind {
            let contentEmpty = line.contentRange.length == 0
            if contentEmpty {
                // Enter on an empty item outdents it, then clears it entirely.
                if line.indent >= 2 {
                    let removal = NSRange(location: line.bodyStart, length: 2)
                    applyEdit(removal, "",
                              selecting: NSRange(location: max(line.bodyStart, caret - 2), length: 0))
                } else {
                    let clear = NSRange(location: line.bodyStart,
                                        length: NSMaxRange(line.range) - line.bodyStart)
                    applyEdit(clear, "", selecting: NSRange(location: line.bodyStart, length: 0))
                }
                return
            }

            var prefix = quotePrefix(for: line)
            prefix += String(repeating: " ", count: line.indent)
            switch marker {
            case .bullet(let character):
                prefix += "\(character) "
            case .ordered(let number, let delimiter):
                prefix += "\(number + 1)\(delimiter) "
            }
            if checkbox != nil { prefix += "[ ] " }
            _ = markerRange

            let insertion = NSRange(location: caret, length: 0)
            applyEdit(insertion, "\n" + prefix,
                      selecting: NSRange(location: caret + 1 + (prefix as NSString).length, length: 0))
            return
        }

        // Stay inside a blockquote when continuing it.
        if line.quoteDepth > 0, line.contentRange.length > 0 {
            let prefix = quotePrefix(for: line)
            let insertion = NSRange(location: caret, length: 0)
            applyEdit(insertion, "\n" + prefix,
                      selecting: NSRange(location: caret + 1 + (prefix as NSString).length, length: 0))
            return
        }

        super.insertNewline(sender)
    }

    private func quotePrefix(for line: LineInfo) -> String {
        String(repeating: "> ", count: line.quoteDepth)
    }

    override func insertTab(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine else { super.insertTab(sender); return }

        if case .tableRow = line.kind {
            moveToNextTableCell()
            return
        }

        let lines = selectedLineIndices
        if case .listItem = line.kind {
            let caret = selectedRange().location
            rewriteLines(lines,
                         selecting: NSRange(location: caret + 2, length: 0)) { _, text in
                "  " + text
            }
            return
        }
        if lines.count > 1 {
            rewriteLines(lines) { _, text in text.isEmpty ? text : "  " + text }
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        syncParseIfNeeded()
        let lines = selectedLineIndices
        guard !lines.isEmpty else { super.insertBacktab(sender); return }
        let caret = selectedRange().location
        var removedFromFirst = 0

        rewriteLines(lines) { line, text in
            let prefixLength = line.bodyStart - line.range.location
            let head = String(text.prefix(prefixLength))
            var body = String(text.dropFirst(prefixLength))
            var removed = 0
            while removed < 2, body.hasPrefix(" ") {
                body.removeFirst()
                removed += 1
            }
            if line.index == lines.lowerBound { removedFromFirst = removed }
            return head + body
        }
        setSelectedRange(NSRange(location: max(0, caret - removedFromFirst), length: 0))
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine else { super.moveToBeginningOfLine(sender); return }
        let caret = selectedRange().location
        let contentStart = line.contentRange.location
        // First press goes to the text, second to the true start of the line.
        let target = (caret == contentStart) ? line.range.location : contentStart
        setSelectedRange(NSRange(location: target, length: 0))
    }
}

// MARK: - Auto-pairing

extension MarkdownTextView {

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard preferences.autoPairMarkers,
              let text = (string as? String) ?? (string as? NSAttributedString)?.string,
              text.count == 1,
              let wrapper = MarkdownTextView.wrappers[text],
              selectedRange().length > 0
        else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let range = selectedRange()
        let selected = nsString.substring(with: range)
        let replacement = wrapper.open + selected + wrapper.close
        applyEdit(range, replacement,
                  selecting: NSRange(location: range.location + (wrapper.open as NSString).length,
                                     length: (selected as NSString).length))
    }

    fileprivate static let wrappers: [String: (open: String, close: String)] = [
        "*": ("*", "*"),
        "_": ("_", "_"),
        "`": ("`", "`"),
        "~": ("~", "~"),
        "=": ("=", "="),
        "[": ("[", "]"),
        "(": ("(", ")"),
        "\"": ("\"", "\""),
    ]
}

// MARK: - Formatting commands

extension MarkdownTextView {

    @objc func toggleBold(_ sender: Any?) { toggleInlineWrapper("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleInlineWrapper("*") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleInlineWrapper("`") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleInlineWrapper("~~") }
    @objc func toggleHighlight(_ sender: Any?) { toggleInlineWrapper("==") }

    private func toggleInlineWrapper(_ delimiter: String) {
        syncParseIfNeeded()
        let range = selectedRange()
        let string = nsString
        let width = (delimiter as NSString).length

        // Already wrapped? Unwrap.
        let outer = NSRange(location: range.location - width, length: range.length + width * 2)
        if outer.location >= 0, NSMaxRange(outer) <= string.length,
           string.substring(with: NSRange(location: outer.location, length: width)) == delimiter,
           string.substring(with: NSRange(location: NSMaxRange(range), length: width)) == delimiter {
            let inner = string.substring(with: range)
            applyEdit(outer, inner,
                      selecting: NSRange(location: outer.location, length: (inner as NSString).length))
            return
        }

        if range.length == 0 {
            applyEdit(range, delimiter + delimiter,
                      selecting: NSRange(location: range.location + width, length: 0))
            return
        }

        let selected = string.substring(with: range)
        applyEdit(range, delimiter + selected + delimiter,
                  selecting: NSRange(location: range.location + width,
                                     length: (selected as NSString).length))
    }

    @objc func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 0
        syncParseIfNeeded()
        let lines = selectedLineIndices
        rewriteLines(lines) { line, text in
            let prefixLength = line.bodyStart - line.range.location
            let head = String(text.prefix(prefixLength))
            var body = String(text.dropFirst(prefixLength))
            while body.hasPrefix("#") { body.removeFirst() }
            while body.hasPrefix(" ") { body.removeFirst() }
            guard level > 0 else { return head + body }
            return head + String(repeating: "#", count: level) + " " + body
        }
    }

    @objc func toggleBulletList(_ sender: Any?) { toggleListPrefix(ordered: false, task: false) }
    @objc func toggleNumberedList(_ sender: Any?) { toggleListPrefix(ordered: true, task: false) }
    @objc func toggleTaskList(_ sender: Any?) { toggleListPrefix(ordered: false, task: true) }

    private func toggleListPrefix(ordered: Bool, task: Bool) {
        syncParseIfNeeded()
        let lines = selectedLineIndices
        guard !lines.isEmpty else { return }

        // If every selected line already carries this marker, strip it instead.
        let allMatch = lines.allSatisfy { index in
            guard case .listItem(let marker, _, let checkbox) = parsed.lines[index].kind else {
                return false
            }
            if task { return checkbox != nil }
            return marker.isOrdered == ordered && checkbox == nil
        }

        var counter = 0
        rewriteLines(lines) { line, text in
            let prefixLength = line.bodyStart - line.range.location
            let head = String(text.prefix(prefixLength))
            var body = String(text.dropFirst(prefixLength))
            let leading = body.prefix { $0 == " " }
            body = String(body.dropFirst(leading.count))

            // Remove any existing list marker.
            if case .listItem(_, let markerRange, let checkbox) = line.kind {
                var strip = markerRange.length
                if let checkbox { strip = NSMaxRange(checkbox.range) - markerRange.location + 1 }
                strip = min(strip, body.count)
                body = String(body.dropFirst(strip))
            }
            guard !allMatch else { return head + leading + body }

            counter += 1
            if task { return head + leading + "- [ ] " + body }
            if ordered { return head + leading + "\(counter). " + body }
            return head + leading + "- " + body
        }
    }

    @objc func toggleBlockquote(_ sender: Any?) {
        syncParseIfNeeded()
        let lines = selectedLineIndices
        guard !lines.isEmpty else { return }
        let allQuoted = lines.allSatisfy { parsed.lines[$0].quoteDepth > 0 }

        rewriteLines(lines) { line, text in
            if allQuoted {
                guard let marker = line.quoteMarkerRange else { return text }
                let drop = min(marker.length, text.count)
                return String(text.dropFirst(drop))
            }
            return "> " + text
        }
    }

    @objc func insertCodeBlock(_ sender: Any?) {
        syncParseIfNeeded()
        let range = selectedRange()
        let selected = nsString.substring(with: range)
        let needsLeadingNewline = range.location > 0
            && nsString.character(at: range.location - 1) != 0x0A
        let lead = needsLeadingNewline ? "\n" : ""
        let replacement = "\(lead)```\n\(selected)\n```\n"
        applyEdit(range, replacement,
                  selecting: NSRange(location: range.location + (lead as NSString).length + 4,
                                     length: (selected as NSString).length))
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine else { return }
        let insertion = NSRange(location: NSMaxRange(line.range), length: 0)
        applyEdit(insertion, "\n\n---\n",
                  selecting: NSRange(location: insertion.location + 6, length: 0))
    }

    @objc func insertMarkdownLink(_ sender: Any?) {
        syncParseIfNeeded()
        let range = selectedRange()
        let selected = nsString.substring(with: range)
        let pasteboard = NSPasteboard.general.string(forType: .string) ?? ""
        let looksLikeURL = pasteboard.hasPrefix("http://") || pasteboard.hasPrefix("https://")

        if looksLikeURL, range.length > 0 {
            applyEdit(range, "[\(selected)](\(pasteboard))",
                      selecting: NSRange(location: range.location + 1,
                                         length: (selected as NSString).length))
            return
        }
        let replacement = "[\(selected)]()"
        let caret = range.location + (selected as NSString).length + 3
        applyEdit(range, replacement, selecting: NSRange(location: caret, length: 0))
    }

    @objc func toggleTaskAtCursor(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine,
              case .listItem(_, _, let checkbox) = line.kind,
              let box = checkbox else { return }
        toggleCheckbox(at: box)
    }

    func toggleCheckbox(at box: CheckboxInfo) {
        let replacement = box.checked ? "[ ]" : "[x]"
        let caret = selectedRange()
        applyEdit(box.range, replacement, selecting: caret)
    }
}

// MARK: - Tables

extension MarkdownTextView {

    @objc func insertTable(_ sender: Any?) {
        syncParseIfNeeded()
        guard let line = currentLine else { return }
        let table = """

        | Column | Column | Column |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |

        """
        let insertion = NSRange(location: NSMaxRange(line.range), length: 0)
        applyEdit(insertion, "\n" + table,
                  selecting: NSRange(location: insertion.location + 4, length: 6))
    }

    @objc func formatTable(_ sender: Any?) {
        formatTableAtCursor()
    }

    @discardableResult
    func formatTableAtCursor() -> Bool {
        syncParseIfNeeded()
        guard let line = currentLine, let regionIndex = line.tableRegion else { return false }
        let caret = selectedRange().location
        guard let start = formatTable(regionIndex: regionIndex) else { return false }
        let target = min(max(caret, start.location), NSMaxRange(start))
        setSelectedRange(NSRange(location: target, length: 0))
        return true
    }

    /// Realigns a table's source. Returns the range the rewritten table now occupies.
    @discardableResult
    func formatTable(regionIndex: Int) -> NSRange? {
        guard regionIndex < parsed.tableRegions.count else { return nil }
        let region = parsed.tableRegions[regionIndex]

        var rows: [[String]] = []
        for index in region.lineRange where index != region.delimiterLine {
            let info = parsed.lines[index]
            let cells = MarkdownParser.splitCells(chars, info.contentRange).map {
                InlineScanner.string(chars, $0).trimmingCharacters(in: .whitespaces)
            }
            rows.append(cells)
        }

        let formatted = TableFormatter.render(rows: rows,
                                              alignments: region.alignments,
                                              columnCount: region.columnCount)
        let start = parsed.lines[region.lineRange.lowerBound].range.location
        let end = NSMaxRange(parsed.lines[region.lineRange.upperBound - 1].range)
        guard formatted != nsString.substring(with: NSRange(location: start, length: end - start))
        else { return NSRange(location: start, length: end - start) }

        guard applyEdit(NSRange(location: start, length: end - start), formatted) else { return nil }
        return NSRange(location: start, length: (formatted as NSString).length)
    }

    func moveToNextTableCell() {
        syncParseIfNeeded()
        guard let refreshed = currentLine, refreshed.tableRegion != nil else { return }
        let caret = selectedRange().location
        let cells = MarkdownParser.splitCells(chars, refreshed.contentRange)
        for cell in cells where cell.location > caret {
            var start = cell.location
            let end = NSMaxRange(cell)
            while start < end, chars[start] == 0x20 { start += 1 }
            var stop = end
            while stop > start, chars[stop - 1] == 0x20 { stop -= 1 }
            setSelectedRange(NSRange(location: start, length: max(0, stop - start)))
            return
        }

        // Past the last cell: drop into the row below.
        let next = refreshed.index + 1
        if next < parsed.lines.count, parsed.lines[next].tableRegion != nil {
            let cells = MarkdownParser.splitCells(chars, parsed.lines[next].contentRange)
            if let first = cells.first {
                var start = first.location
                while start < NSMaxRange(first), chars[start] == 0x20 { start += 1 }
                setSelectedRange(NSRange(location: start, length: 0))
            }
        }
    }
}

// MARK: - Links, checkboxes and clicks

extension MarkdownTextView {

    /// The link at a document offset.
    ///
    /// Read from the parse rather than from a text attribute: a drawn table
    /// paints its own cells and never runs the inline styling pass, so an
    /// attribute-based lookup finds nothing inside one.
    func linkURL(atCharacter index: Int) -> URL? {
        syncParseIfNeeded()
        guard !parsed.lines.isEmpty, index >= 0, index <= nsString.length else { return nil }
        let line = parsed.lines[parsed.lineIndex(at: index)]
        guard line.contentRange.length > 0 else { return nil }

        let spans = InlineScanner.scan(chars,
                                       range: line.contentRange,
                                       definitions: parsed.linkDefinitions)
        for span in spans {
            switch span.kind {
            case .link, .autolink, .image:
                guard NSLocationInRange(index, span.range) || NSMaxRange(span.range) == index,
                      let destination = span.destination else { continue }
                return resolvedURL(destination)
            default:
                continue
            }
        }
        return nil
    }

    /// Document offset under a point, including inside a drawn table.
    func documentIndex(at point: NSPoint) -> Int {
        tableSourceIndex(at: point) ?? characterIndexForInsertion(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Links look like links, so a plain click follows them. Option-click puts
        // the caret inside instead, for editing the text of one.
        let placingCaret = event.modifierFlags.contains(.option)
        let index = documentIndex(at: point)

        if !placingCaret, let url = linkURL(atCharacter: index) {
            open(url)
            return
        }

        // A drawn table has no text layout of its own, so a click on it has to
        // be mapped back onto the source offset the picture stands for.
        if tableSourceIndex(at: point) != nil {
            window?.makeFirstResponder(self)
            if event.clickCount >= 2,
               let cell = tablePlacement(containing: index)?.table.cell(containingSource: index) {
                setSelectedRange(cell.sourceRange)
            } else {
                setSelectedRange(NSRange(location: index, length: 0))
            }
            return
        }
        if toggleCheckboxIfClicked(at: point) { return }
        super.mouseDown(with: event)
    }

    /// Opens the link the caret is sitting in.
    @objc func openLinkAtCaret(_ sender: Any?) {
        guard let url = linkURL(atCharacter: selectedRange().location) else { return }
        open(url)
    }

    var caretIsInLink: Bool { linkURL(atCharacter: selectedRange().location) != nil }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        linkTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Only a hover that changed character matters; this runs on mouse move,
        // never on scroll, and does no work beyond a hit test.
        let point = convert(event.locationInWindow, from: nil)
        let index = documentIndex(at: point)
        guard index != lastHoveredIndex else { return }
        lastHoveredIndex = index
        if linkURL(atCharacter: index) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    // MARK: - Code block copying

    func scheduleCodeCopyButtonRefresh() {
        guard !codeCopyButtonRefreshScheduled else { return }
        codeCopyButtonRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.codeCopyButtonRefreshScheduled = false
            self.refreshCodeCopyButtons()
        }
    }

    private func refreshCodeCopyButtons() {
        guard isParseCurrent else { return }

        var active = Set<Int>()
        for (regionIndex, region) in parsed.codeRegions.enumerated()
        where region.fenced && region.content == .code {
            guard let firstLine = region.openFenceLine,
                  firstLine < parsed.lines.count else { continue }
            active.insert(regionIndex)

            let button: NSButton
            if let existing = codeCopyButtons[regionIndex] {
                button = existing
            } else {
                button = NSButton(title: "Copy", target: self,
                                  action: #selector(copyCodeBlockFromButton(_:)))
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.focusRingType = .none
                button.toolTip = "Copy code"
                addSubview(button)
                codeCopyButtons[regionIndex] = button
            }
            button.tag = regionIndex

            let anchor = parsed.lines[firstLine].fullRange.location
            guard let fragment = fragmentFrame(atCharacter: anchor) else {
                button.isHidden = true
                continue
            }
            let blockRect = CGRect(x: textContainerInset.width,
                                   y: textContainerInset.height + fragment.minY,
                                   width: styler.context.containerWidth,
                                   height: fragment.height)
            button.frame = CodeBlockChrome.copyButtonRect(in: blockRect)
            button.isHidden = false
        }

        let stale = codeCopyButtons.keys.filter { !active.contains($0) }
        for regionIndex in stale {
            codeCopyButtons.removeValue(forKey: regionIndex)?.removeFromSuperview()
        }
    }

    /// Copies only a fenced block's body, excluding the opening/closing fences
    /// and the language info string. The code itself remains normal selectable,
    /// editable NSTextView content underneath this native button.
    @objc private func copyCodeBlockFromButton(_ sender: NSButton) {
        syncParseIfNeeded()
        guard sender.tag >= 0, sender.tag < parsed.codeRegions.count else { return }
        let region = parsed.codeRegions[sender.tag]
        guard region.fenced, region.content == .code else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CodeBlockText.body(of: region,
                                                in: parsed,
                                                source: nsString),
                             forType: .string)
    }

    // MARK: - Resolution

    private func resolvedURL(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "mailto", "file"].contains(scheme) else { return nil }
            return url
        }
        // A relative path resolves against the document's own folder.
        guard let base = (window?.windowController?.document as? MarkdownDocument)?
            .fileURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: trimmed, relativeTo: base).standardizedFileURL
    }

    private func open(_ url: URL) {
        MarkerLog.render("open link \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Checkboxes

    private func toggleCheckboxIfClicked(at point: NSPoint) -> Bool {
        syncParseIfNeeded()
        guard !parsed.lines.isEmpty else { return false }
        let index = documentIndex(at: point)
        let line = parsed.lines[parsed.lineIndex(at: index)]
        guard case .listItem(_, _, let checkbox) = line.kind, let box = checkbox else { return false }

        let contentX = textContainerInset.width
            + CGFloat(line.quoteDepth) * styler.theme.quoteIndent
            + styler.theme.listMarkerColumn(depth: line.listDepth)
        guard point.x < contentX, point.x > contentX - styler.theme.baseSize * 2 else { return false }

        toggleCheckbox(at: box)
        return true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let url = linkURL(atCharacter: documentIndex(at: point)), let menu else { return menu }
        let item = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }
}

// MARK: - Menu validation

extension MarkdownTextView {
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(formatTable(_:)):
            return currentLine?.tableRegion != nil
        case #selector(toggleTaskAtCursor(_:)):
            if case .listItem(_, _, let checkbox) = currentLine?.kind { return checkbox != nil }
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
