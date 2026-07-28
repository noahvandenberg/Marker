import AppKit

// Caret behaviour when syntax markers are hidden.
//
// The `**` around a bold word is still in the file, just given a hairline font
// and a clear colour. Left to itself the caret would step through those
// characters, so an arrow key press would appear to do nothing two times out of
// three. Everything here exists to make the caret move over *visible* text.

extension MarkdownTextView {

    /// Effective range of the concealed run covering `location`, if any.
    func concealedRun(at location: Int) -> NSRange? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        var effective = NSRange(location: 0, length: 0)
        let value = storage.attribute(.concealedMarker, at: location, effectiveRange: &effective)
        return value == nil ? nil : effective
    }

    private var storageLength: Int { textStorage?.length ?? 0 }

    /// Skips forward over any concealed characters starting at `location`.
    private func skippingForward(_ location: Int) -> Int {
        var result = location
        while result < storageLength, let run = concealedRun(at: result) {
            result = NSMaxRange(run)
        }
        return min(result, storageLength)
    }

    /// Skips backward over any concealed characters ending at `location`.
    private func skippingBackward(_ location: Int) -> Int {
        var result = location
        while result > 0, let run = concealedRun(at: result - 1) {
            result = run.location
        }
        return max(result, 0)
    }

    /// One visible character to the right.
    func visibleLocation(after location: Int) -> Int {
        var result = skippingForward(location)
        guard result < storageLength else { return storageLength }
        result += 1
        return skippingForward(result)
    }

    /// One visible character to the left.
    func visibleLocation(before location: Int) -> Int {
        var result = skippingBackward(location)
        guard result > 0 else { return 0 }
        result -= 1
        return result
    }

    /// Pulls a caret out of the middle of a concealed run.
    ///
    /// Clicks and vertical movement can land anywhere, including inside a run
    /// whose characters have no width. Sitting exactly at a run's start is a
    /// real position — it means "before this construct" — so only strictly
    /// interior positions are moved.
    func snappedOutOfMarkers(_ range: NSRange) -> NSRange {
        guard range.length == 0, let run = concealedRun(at: range.location) else { return range }
        guard range.location > run.location else { return range }
        return NSRange(location: NSMaxRange(run), length: 0)
    }

    // MARK: - Horizontal movement

    override func moveRight(_ sender: Any?) {
        moveCaret(forward: true, extending: false)
    }

    override func moveLeft(_ sender: Any?) {
        moveCaret(forward: false, extending: false)
    }

    override func moveForward(_ sender: Any?) {
        moveCaret(forward: true, extending: false)
    }

    override func moveBackward(_ sender: Any?) {
        moveCaret(forward: false, extending: false)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        moveCaret(forward: true, extending: true)
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        moveCaret(forward: false, extending: true)
    }

    private func moveCaret(forward: Bool, extending: Bool) {
        let selection = selectedRange()

        if !extending, selection.length > 0 {
            // Collapse to the edge, like every other Mac text view.
            let edge = forward ? NSMaxRange(selection) : selection.location
            setSelectedRange(NSRange(location: edge, length: 0))
            return
        }

        let anchorAtStart = selectionAnchorIsAtStart
        let moving = extending
            ? (anchorAtStart ? NSMaxRange(selection) : selection.location)
            : selection.location
        let target = forward ? visibleLocation(after: moving) : visibleLocation(before: moving)

        guard extending else {
            setSelectedRange(NSRange(location: target, length: 0))
            return
        }
        let anchor = anchorAtStart ? selection.location : NSMaxRange(selection)
        setSelectedRange(NSRange(location: min(anchor, target),
                                 length: abs(target - anchor)))
    }
}

// MARK: - Marker-aware deletion

extension MarkdownTextView {

    override func deleteBackward(_ sender: Any?) {
        syncParseIfNeeded()
        guard selectedRange().length == 0, let line = currentLine else {
            super.deleteBackward(sender)
            return
        }
        let caret = selectedRange().location

        // Backspacing at the start of an emphasised run unwraps it, rather than
        // eating one invisible asterisk and leaving broken syntax behind.
        if let span = inlineSpan(startingContentAt: caret, on: line) {
            unwrap(span)
            return
        }

        // At the end of a run the closing markers are invisible; delete the last
        // character of the content instead of a marker character.
        if let run = concealedRun(at: caret - 1) {
            let contentEnd = run.location
            guard contentEnd > 0 else { super.deleteBackward(sender); return }
            applyEdit(NSRange(location: contentEnd - 1, length: 1), "",
                      selecting: NSRange(location: contentEnd - 1, length: 0))
            return
        }

        if handleBlockMarkerDeletion(at: caret, on: line) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        syncParseIfNeeded()
        guard selectedRange().length == 0 else { super.deleteForward(sender); return }
        let caret = selectedRange().location
        guard let run = concealedRun(at: caret) else { super.deleteForward(sender); return }

        let after = NSMaxRange(run)
        guard after < nsString.length else { super.deleteForward(sender); return }
        applyEdit(NSRange(location: after, length: 1), "",
                  selecting: NSRange(location: caret, length: 0))
    }

    /// The inline span whose visible content begins exactly at `location`.
    private func inlineSpan(startingContentAt location: Int, on line: LineInfo) -> InlineSpan? {
        guard line.contentRange.length > 0 else { return nil }
        let spans = InlineScanner.scan(chars,
                                       range: line.contentRange,
                                       definitions: parsed.linkDefinitions)
        return spans.first { span in
            guard !span.markers.isEmpty else { return false }
            guard span.contentRange.location == location else { return false }
            // Only when the opening marker is actually hidden.
            return span.range.location < location
        }
    }

    /// Removes a span's delimiters, keeping the text between them.
    private func unwrap(_ span: InlineSpan) {
        let markers = span.markers.sorted { $0.location > $1.location }
        guard let storage = textStorage else { return }
        let full = span.range
        guard shouldChangeText(in: full, replacementString: nil) else { return }
        storage.beginEditing()
        for marker in markers {
            guard NSMaxRange(marker) <= storage.length else { continue }
            storage.replaceCharacters(in: marker, with: "")
        }
        storage.endEditing()
        didChangeText()

        let leading = markers.filter { $0.location < span.contentRange.location }
            .reduce(0) { $0 + $1.length }
        setSelectedRange(NSRange(location: max(0, span.contentRange.location - leading), length: 0))
    }

    /// Backspace at the start of a heading, quote or list item removes its marker.
    private func handleBlockMarkerDeletion(at caret: Int, on line: LineInfo) -> Bool {
        switch line.kind {
        case .heading(_, let markerRange, let contentRange, _):
            guard caret == contentRange.location, caret > markerRange.location else { return false }
            applyEdit(markerRange, "",
                      selecting: NSRange(location: markerRange.location, length: 0))
            return true

        case .listItem(_, let markerRange, let checkbox):
            let contentStart = line.contentRange.location
            guard caret == contentStart, caret > markerRange.location else { return false }
            _ = checkbox
            applyEdit(NSRange(location: markerRange.location, length: caret - markerRange.location),
                      "",
                      selecting: NSRange(location: markerRange.location, length: 0))
            return true

        default:
            if let quote = line.quoteMarkerRange, caret == NSMaxRange(quote) {
                applyEdit(quote, "", selecting: NSRange(location: quote.location, length: 0))
                return true
            }
            return false
        }
    }
}
