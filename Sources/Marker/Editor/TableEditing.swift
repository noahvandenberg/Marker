import AppKit

// Editing inside a drawn table.
//
// The table is a picture, but the text under it is ordinary Markdown, so the
// selection stays a normal range in the document — the pipes and any hidden
// emphasis markers are simply skipped over. What this adds is the geometry that
// the text system can no longer provide once a block is drawn rather than laid
// out: where a click lands, where the caret goes, and what Tab means.

extension MarkdownTextView {

    struct TablePlacement {
        var region: Int
        var table: RenderedTable
        /// Table origin in view coordinates.
        var origin: CGPoint
    }

    /// Which table region a document offset falls in.
    ///
    /// Pure arithmetic over the parse — no text layout — so it is safe to call
    /// from hot paths as a guard before asking for geometry.
    func tableRegionIndex(containing location: Int) -> Int? {
        guard isParseCurrent else { return nil }
        for (index, region) in parsed.tableRegions.enumerated()
        where NSLocationInRange(location, region.charRange) { return index }
        return nil
    }

    /// Where one table sits in the view.
    ///
    /// This asks the layout manager for a fragment frame, which forces layout,
    /// so it must never be called speculatively for every table — and never
    /// from inside `draw`.
    func placement(forRegion index: Int) -> TablePlacement? {
        guard isParseCurrent, index < parsed.tableRegions.count,
              let table = styler.renderedTables[index] else { return nil }
        let region = parsed.tableRegions[index]
        guard region.lineRange.lowerBound < parsed.lines.count else { return nil }
        let anchor = parsed.lines[region.lineRange.lowerBound].fullRange.location
        guard let frame = fragmentFrame(atCharacter: anchor) else { return nil }
        return TablePlacement(
            region: index,
            table: table,
            origin: CGPoint(x: textContainerInset.width,
                            y: textContainerInset.height + frame.minY
                                + styler.theme.baseSize * 0.3))
    }

    /// Tables currently on screen, for hit-testing a click.
    func visibleTablePlacements() -> [TablePlacement] {
        guard isParseCurrent, !parsed.tableRegions.isEmpty else { return [] }
        let visible = visibleCharacterRange()
        return parsed.tableRegions.indices.compactMap { index in
            if let visible,
               NSIntersectionRange(parsed.tableRegions[index].charRange, visible).length == 0 {
                return nil
            }
            return placement(forRegion: index)
        }
    }

    private func fragmentFrame(atCharacter index: Int) -> CGRect? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location,
                                                     offsetBy: index),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame
    }

    func tablePlacement(containing index: Int) -> TablePlacement? {
        guard let region = tableRegionIndex(containing: index) else { return nil }
        return placement(forRegion: region)
    }

    func tablePlacement(at point: NSPoint) -> TablePlacement? {
        visibleTablePlacements().first { placement in
            CGRect(origin: placement.origin, size: placement.table.size)
                .insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    /// Document offset for a click inside a drawn table.
    func tableSourceIndex(at point: NSPoint) -> Int? {
        guard let placement = tablePlacement(at: point) else { return nil }
        let local = CGPoint(x: point.x - placement.origin.x, y: point.y - placement.origin.y)
        return placement.table.sourceIndex(at: local)
    }

    /// Pulls a caret that landed on a table's structure into the nearest cell.
    ///
    /// Pipes and the padding around them are real characters, so ordinary
    /// movement can stop on them — but they aren't anywhere the user can see a
    /// caret, and typing there would rewrite the table's shape.
    func snappedIntoCell(_ range: NSRange) -> NSRange {
        guard range.length == 0,
              tableRegionIndex(containing: range.location) != nil,
              let placement = tablePlacement(containing: range.location),
              placement.table.cell(containingSource: range.location) == nil else { return range }

        var best: Int?
        var bestDistance = Int.max
        for cell in placement.table.allCells {
            for candidate in [cell.sourceRange.location, NSMaxRange(cell.sourceRange)] {
                let distance = abs(candidate - range.location)
                if distance < bestDistance { bestDistance = distance; best = candidate }
            }
        }
        guard let best else { return range }
        return NSRange(location: best, length: 0)
    }

    /// Caret rectangle in view coordinates when the selection sits in a table.
    func tableCaretRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0,
              let placement = tablePlacement(containing: selection.location),
              let rect = placement.table.caretRect(forSource: selection.location) else { return nil }
        return rect.offsetBy(dx: placement.origin.x, dy: placement.origin.y)
    }
}

// MARK: - Caret

extension MarkdownTextView {

    /// The system caret is hidden while editing a cell — the real text sits on a
    /// collapsed line behind the drawing — so one is drawn here instead.
    ///
    /// It lives in its own layer rather than in `draw(_:)`. TextKit 2 composites
    /// each text fragment into its own layer above the view's backing store, so
    /// anything painted in `draw` ends up *underneath* the table it belongs to.
    /// A layer with a raised `zPosition` sits above them all, and moving it
    /// costs no drawing or layout.
    func updateTableCaretLayer() {
        // Match the system caret: only shown when this view is actually taking
        // keystrokes.
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        guard let rect = cachedTableCaretRect, focused else {
            tableCaretLayer?.isHidden = true
            return
        }
        let layer = ensureCaretLayer()
        // A dynamic colour resolves against whatever appearance is current, which
        // outside a draw pass is not this view's — so resolve it explicitly.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = styler.theme.insertionPoint.cgColor
        }
        layer.frame = NSRect(x: rect.minX.rounded(), y: rect.minY,
                             width: 1.5, height: rect.height)
        layer.isHidden = !tableCaretIsVisible
    }

    private func ensureCaretLayer() -> CALayer {
        if let tableCaretLayer { return tableCaretLayer }
        let layer = CALayer()
        layer.zPosition = 100
        // No implicit animation: the caret must snap, not glide.
        layer.actions = ["position": NSNull(), "bounds": NSNull(),
                         "hidden": NSNull(), "backgroundColor": NSNull()]
        wantsLayer = true
        self.layer?.addSublayer(layer)
        tableCaretLayer = layer
        return layer
    }

    /// Recomputes the cached caret rect. Call on selection change and after a
    /// restyle — never while drawing or scrolling.
    func refreshTableCaretState() {
        cachedTableCaretRect = tableRegionIndex(containing: selectedRange().location) == nil
            ? nil
            : tableCaretRect()
        let inTable = cachedTableCaretRect != nil
        if inTable != isEditingTableCell {
            isEditingTableCell = inTable
            // Suppress the real caret rather than let it draw on the collapsed line.
            insertionPointColor = inTable ? .clear : styler.theme.insertionPoint
        }
        guard inTable else {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            tableCaretLayer?.isHidden = true
            return
        }
        tableCaretIsVisible = true
        restartCaretBlink()
        updateTableCaretLayer()
        // Layout may still be settling from a restyle; confirm on the next turn.
        scheduleTableCaretRefresh()
    }

    /// Re-reads the caret's position once layout has settled.
    ///
    /// Coalesced to one refresh per runloop turn, and deliberately off both the
    /// draw path and the scroll path — asking for a fragment frame forces layout.
    func scheduleTableCaretRefresh() {
        guard !tableCaretRefreshScheduled else { return }
        tableCaretRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableCaretRefreshScheduled = false
            guard self.isEditingTableCell || self.cachedTableCaretRect != nil
                    || self.tableRegionIndex(containing: self.selectedRange().location) != nil
            else { return }

            let updated = self.tableCaretRect()
            guard updated != self.cachedTableCaretRect else { return }
            self.cachedTableCaretRect = updated
            self.updateTableCaretLayer()
        }
    }

    private func restartCaretBlink() {
        caretBlinkTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.56, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEditingTableCell else { return }
                self.tableCaretIsVisible.toggle()
                self.updateTableCaretLayer()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        caretBlinkTimer = timer
    }

    private func tableCaretDirtyRect() -> NSRect {
        guard let rect = cachedTableCaretRect else { return .zero }
        return rect.insetBy(dx: -3, dy: -3)
    }
}

// MARK: - Cell navigation

extension MarkdownTextView {

    /// Cell the caret is in, if any.
    private func currentCell() -> (placement: TablePlacement, cell: RenderedTable.Cell)? {
        let caret = selectedRange().location
        guard let placement = tablePlacement(containing: caret),
              let cell = placement.table.cell(containingSource: caret) else { return nil }
        return (placement, cell)
    }

    enum CellLanding {
        /// Select the whole cell, so typing replaces it.
        case selectAll
        case start
        case end
    }

    /// Moves to another cell by row/column delta, clamped to the table.
    @discardableResult
    func moveToCell(rowDelta: Int, columnDelta: Int, landing: CellLanding = .selectAll) -> Bool {
        guard let (placement, cell) = currentCell() else { return false }
        let table = placement.table

        var row = cell.row + rowDelta
        var column = cell.column + columnDelta

        if columnDelta != 0 {
            let columns = table.rows.first?.cells.count ?? 1
            if column < 0 {
                guard row > 0 else { return false }
                row -= 1
                column = columns - 1
            } else if column >= columns {
                guard row + 1 < table.rows.count else { return false }
                row += 1
                column = 0
            }
        }
        guard row >= 0, row < table.rows.count else { return false }
        guard let target = table.cell(row: row, column: column) else { return false }

        switch landing {
        case .selectAll:
            setSelectedRange(target.sourceRange)
        case .start:
            setSelectedRange(NSRange(location: target.sourceRange.location, length: 0))
        case .end:
            setSelectedRange(NSRange(location: NSMaxRange(target.sourceRange), length: 0))
        }
        scrollRangeToVisible(NSRange(location: target.sourceRange.location, length: 0))
        return true
    }

    /// Appends a row matching the table's column count.
    @discardableResult
    func appendTableRow() -> Bool {
        guard let (placement, _) = currentCell() else { return false }
        let region = parsed.tableRegions[placement.region]
        guard region.lineRange.upperBound - 1 < parsed.lines.count else { return false }

        let last = parsed.lines[region.lineRange.upperBound - 1]
        let blank = "\n|" + String(repeating: "  |", count: region.columnCount)
        let insertion = NSRange(location: NSMaxRange(last.range), length: 0)
        applyEdit(insertion, blank,
                  selecting: NSRange(location: insertion.location + 2, length: 0))
        return true
    }
}

// MARK: - Key handling inside a cell

extension MarkdownTextView {

    /// True when the caret is inside a drawn table, so table keys take over.
    var isInsideRenderedTable: Bool {
        guard let region = tableRegionIndex(containing: selectedRange().location) else {
            return false
        }
        return styler.renderedTables[region] != nil
    }

    /// Steps one visible character within the cell, hopping cells at the edges.
    ///
    /// The cell's display-to-source map is exactly the set of positions worth
    /// stopping at, so this skips pipes, padding and hidden emphasis markers
    /// without any special cases.
    private func moveWithinCell(forward: Bool) -> Bool {
        guard let (_, cell) = currentCell() else { return false }
        let caret = selectedRange().location

        if selectedRange().length > 0 {
            let edge = forward ? NSMaxRange(selectedRange()) : selectedRange().location
            setSelectedRange(NSRange(location: edge, length: 0))
            return true
        }

        let display = cell.displayIndex(forSource: caret)
        let target = forward ? display + 1 : display - 1
        if target < 0 {
            return moveToCell(rowDelta: 0, columnDelta: -1, landing: .end)
        }
        if target > cell.displayToSource.count {
            return moveToCell(rowDelta: 0, columnDelta: 1, landing: .start)
        }
        setSelectedRange(NSRange(location: cell.sourceIndex(forDisplay: target), length: 0))
        return true
    }

    func handleTableKey(_ selector: Selector) -> Bool {
        guard isInsideRenderedTable else { return false }

        switch selector {
        case #selector(moveRight(_:)), #selector(moveForward(_:)):
            return moveWithinCell(forward: true)

        case #selector(moveLeft(_:)), #selector(moveBackward(_:)):
            return moveWithinCell(forward: false)
        case #selector(insertTab(_:)):
            if !moveToCell(rowDelta: 0, columnDelta: 1) { appendTableRow() }
            return true

        case #selector(insertBacktab(_:)):
            moveToCell(rowDelta: 0, columnDelta: -1)
            return true

        case #selector(insertNewline(_:)):
            // Return moves down a row; from the last row it adds one.
            if !moveToCell(rowDelta: 1, columnDelta: 0) { appendTableRow() }
            return true

        case #selector(moveDown(_:)):
            return moveToCell(rowDelta: 1, columnDelta: 0, landing: .start)

        case #selector(moveUp(_:)):
            return moveToCell(rowDelta: -1, columnDelta: 0, landing: .start)

        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)):
            guard let (_, cell) = currentCell() else { return false }
            setSelectedRange(NSRange(location: cell.sourceRange.location, length: 0))
            return true

        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
            guard let (_, cell) = currentCell() else { return false }
            setSelectedRange(NSRange(location: NSMaxRange(cell.sourceRange), length: 0))
            return true

        case #selector(deleteBackward(_:)):
            // Never let a delete run past the start of a cell and eat a pipe.
            guard let (_, cell) = currentCell(), selectedRange().length == 0,
                  selectedRange().location <= cell.sourceRange.location else { return false }
            return true

        default:
            return false
        }
    }
}
