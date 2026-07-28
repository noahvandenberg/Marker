import AppKit
import CoreText

/// A laid-out table.
///
/// Cells are typeset with CoreText rather than measured with `boundingRect`, so
/// every glyph position is known. That is what lets the caret sit inside a
/// drawn cell and lets a click land on the right character: each cell keeps the
/// map from the characters it displays back to their offsets in the Markdown
/// source, markers and all.
struct RenderedTable {

    struct TextLine {
        var line: CTLine
        /// Range within the cell's *display* string.
        var range: NSRange
        /// Baseline origin in table coordinates.
        var origin: CGPoint
        var ascent: CGFloat
        var descent: CGFloat
        var width: CGFloat
    }

    struct Cell {
        /// Trimmed content range in the document.
        var sourceRange: NSRange
        /// Display character index → document character index.
        var displayToSource: [Int]
        var text: NSAttributedString
        /// Text area in table coordinates.
        var frame: CGRect
        var alignment: TableAlignment
        var lines: [TextLine]
        var row: Int
        var column: Int
    }

    struct Row {
        var cells: [Cell]
        var frame: CGRect
        var isHeader: Bool
        /// Line index in the document this row came from.
        var sourceLine: Int
    }

    var rows: [Row]
    var separators: [CGFloat]
    var size: CGSize
    /// Document character range the whole table occupies.
    var sourceRange: NSRange
}

// MARK: - Position mapping

extension RenderedTable {

    var allCells: [Cell] { rows.flatMap(\.cells) }

    func cell(containingSource index: Int) -> Cell? {
        allCells.first { NSLocationInRange(index, $0.sourceRange) || $0.sourceRange.location == index
            || NSMaxRange($0.sourceRange) == index }
    }

    func cell(row: Int, column: Int) -> Cell? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].cells.first { $0.column == column }
    }

    /// Document offset for a point given in table coordinates.
    func sourceIndex(at point: CGPoint) -> Int? {
        guard let row = rows.first(where: { point.y < $0.frame.maxY }) ?? rows.last else { return nil }
        let cell = row.cells.min { lhs, rhs in
            distance(from: point.x, to: lhs.frame) < distance(from: point.x, to: rhs.frame)
        }
        guard let cell else { return nil }
        return cell.sourceIndex(at: point)
    }

    private func distance(from x: CGFloat, to rect: CGRect) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }

    /// Caret rectangle in table coordinates for a document offset.
    func caretRect(forSource index: Int) -> CGRect? {
        guard let cell = cell(containingSource: index) else { return nil }
        return cell.caretRect(forSource: index)
    }

    func selectionRects(forSource range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        var rects: [CGRect] = []
        for cell in allCells {
            let overlap = NSIntersectionRange(cell.sourceRange, range)
            guard overlap.length > 0 else { continue }
            guard let start = cell.caretRect(forSource: overlap.location),
                  let end = cell.caretRect(forSource: NSMaxRange(overlap)) else { continue }
            if abs(start.minY - end.minY) < 1 {
                rects.append(CGRect(x: start.minX, y: start.minY,
                                    width: max(2, end.minX - start.minX), height: start.height))
            } else {
                // Multi-line selection inside one cell: fill whole lines between.
                rects.append(CGRect(x: start.minX, y: start.minY,
                                    width: max(2, cell.frame.maxX - start.minX), height: start.height))
                rects.append(CGRect(x: cell.frame.minX, y: end.minY,
                                    width: max(2, end.minX - cell.frame.minX), height: end.height))
                if end.minY - start.maxY > 1 {
                    rects.append(CGRect(x: cell.frame.minX, y: start.maxY,
                                        width: cell.frame.width, height: end.minY - start.maxY))
                }
            }
        }
        return rects
    }
}

extension RenderedTable.Cell {

    /// Display index whose source offset is at or after `index`.
    func displayIndex(forSource index: Int) -> Int {
        var low = 0
        var high = displayToSource.count
        while low < high {
            let mid = (low + high) / 2
            if displayToSource[mid] < index { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func sourceIndex(forDisplay index: Int) -> Int {
        if index < displayToSource.count { return displayToSource[index] }
        return NSMaxRange(sourceRange)
    }

    func caretRect(forSource index: Int) -> CGRect? {
        let display = displayIndex(forSource: index)
        guard let line = lines.first(where: {
            NSLocationInRange(display, $0.range) || NSMaxRange($0.range) == display
        }) ?? lines.last else {
            return CGRect(x: frame.minX, y: frame.minY, width: 1, height: max(12, frame.height))
        }
        let offset = CTLineGetOffsetForStringIndex(line.line, display, nil)
        return CGRect(x: line.origin.x + offset,
                      y: line.origin.y - line.ascent,
                      width: 1,
                      height: line.ascent + line.descent)
    }

    func sourceIndex(at point: CGPoint) -> Int {
        guard let line = lines.first(where: { point.y < $0.origin.y + $0.descent }) ?? lines.last
        else { return sourceRange.location }
        let local = CGPoint(x: point.x - line.origin.x, y: 0)
        var display = CTLineGetStringIndexForPosition(line.line, local)
        if display == kCFNotFound { display = line.range.location }
        display = min(max(display, line.range.location), NSMaxRange(line.range))
        return sourceIndex(forDisplay: display)
    }
}

// MARK: - Layout

enum TableLayoutEngine {

    static let cellPaddingX: CGFloat = 10
    static let cellPaddingY: CGFloat = 7

    static func layout(region: TableRegion,
                       doc: ParsedDocument,
                       chars: [unichar],
                       theme: Theme,
                       maxWidth: CGFloat) -> RenderedTable? {
        let columns = region.columnCount
        guard columns > 0, maxWidth > 40 else { return nil }

        struct RawCell {
            var text: NSAttributedString
            var origins: [Int]
            var sourceRange: NSRange
        }

        var rawRows: [[RawCell]] = []
        var headerFlags: [Bool] = []
        var sourceLines: [Int] = []

        for lineIndex in region.lineRange where lineIndex != region.delimiterLine {
            guard lineIndex < doc.lines.count else { continue }
            let line = doc.lines[lineIndex]
            let header = lineIndex == region.headerLine
            let ranges = MarkdownParser.splitCells(chars, line.contentRange)

            var cells: [RawCell] = []
            for column in 0..<columns {
                let raw = column < ranges.count
                    ? ranges[column]
                    : NSRange(location: NSMaxRange(line.contentRange), length: 0)
                let trimmed = trimming(raw, chars)
                let built = attributedCell(chars, trimmed, theme: theme, bold: header)
                cells.append(RawCell(text: built.text,
                                     origins: built.origins,
                                     sourceRange: trimmed))
            }
            rawRows.append(cells)
            headerFlags.append(header)
            sourceLines.append(lineIndex)
        }
        guard !rawRows.isEmpty else { return nil }

        // --- column widths -----------------------------------------------------
        let chrome = cellPaddingX * CGFloat(columns * 2) + CGFloat(columns + 1)
        let available = max(40, maxWidth - chrome)

        var natural = [CGFloat](repeating: 0, count: columns)
        var minimum = [CGFloat](repeating: 0, count: columns)
        for cells in rawRows {
            for (column, cell) in cells.enumerated() where column < columns {
                natural[column] = max(natural[column], ceil(cell.text.size().width))
                minimum[column] = max(minimum[column], longestWordWidth(cell.text))
            }
        }
        let ceilingPerColumn = available / CGFloat(columns) * 1.8
        for column in 0..<columns {
            minimum[column] = max(24, min(minimum[column], ceilingPerColumn))
            natural[column] = max(natural[column], minimum[column])
        }
        let widths = distribute(natural: natural, minimum: minimum, available: available)

        // --- typeset -------------------------------------------------------------
        var rows: [RenderedTable.Row] = []
        var y: CGFloat = 1

        for (rowIndex, cells) in rawRows.enumerated() {
            var typeset: [[RenderedTable.TextLine]] = []
            var contentHeight: CGFloat = theme.baseSize

            for (column, cell) in cells.enumerated() where column < columns {
                let lines = typesetLines(cell.text, width: widths[column],
                                         alignment: column < region.alignments.count
                                            ? region.alignments[column] : .none)
                typeset.append(lines)
                let height = lines.reduce(CGFloat(0)) { $0 + $1.ascent + $1.descent }
                contentHeight = max(contentHeight, ceil(height))
            }
            let rowHeight = contentHeight + cellPaddingY * 2

            var laidOut: [RenderedTable.Cell] = []
            var x: CGFloat = 1
            for (column, cell) in cells.enumerated() where column < columns {
                x += cellPaddingX
                let cellFrame = CGRect(x: x, y: y + cellPaddingY,
                                       width: widths[column], height: contentHeight)
                // Shift the typeset lines into table coordinates.
                var lines = typeset[column]
                var lineY = cellFrame.minY
                for index in lines.indices {
                    lines[index].origin = CGPoint(
                        x: cellFrame.minX + lines[index].origin.x,
                        y: lineY + lines[index].ascent)
                    lineY += lines[index].ascent + lines[index].descent
                }
                laidOut.append(RenderedTable.Cell(
                    sourceRange: cell.sourceRange,
                    displayToSource: cell.origins,
                    text: cell.text,
                    frame: cellFrame,
                    alignment: column < region.alignments.count
                        ? region.alignments[column] : .none,
                    lines: lines,
                    row: rowIndex,
                    column: column))
                x += widths[column] + cellPaddingX + 1
            }

            rows.append(RenderedTable.Row(cells: laidOut,
                                          frame: CGRect(x: 0, y: y, width: x - 1, height: rowHeight),
                                          isHeader: headerFlags[rowIndex],
                                          sourceLine: sourceLines[rowIndex]))
            y += rowHeight
        }

        var separators: [CGFloat] = []
        var x: CGFloat = 1
        for column in 0..<(columns - 1) {
            x += cellPaddingX + widths[column] + cellPaddingX + 1
            separators.append(x - 1)
        }

        let totalWidth = widths.reduce(0, +) + chrome
        return RenderedTable(rows: rows,
                             separators: separators,
                             size: CGSize(width: min(totalWidth, maxWidth), height: y),
                             sourceRange: region.charRange)
    }

    // MARK: - Typesetting

    private static func typesetLines(_ text: NSAttributedString,
                                     width: CGFloat,
                                     alignment: TableAlignment) -> [RenderedTable.TextLine] {
        guard text.length > 0 else {
            let font = (text.length > 0
                ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                : nil) ?? NSFont.systemFont(ofSize: 13)
            return [RenderedTable.TextLine(line: CTLineCreateWithAttributedString(
                                            NSAttributedString(string: "", attributes: [.font: font])),
                                           range: NSRange(location: 0, length: 0),
                                           origin: .zero,
                                           ascent: font.ascender,
                                           descent: -font.descender,
                                           width: 0)]
        }

        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines: [RenderedTable.TextLine] = []
        var start = 0

        while start < text.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { count = text.length - start }
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(typesetter, range)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let offset: CGFloat
            switch alignment {
            case .center: offset = max(0, (width - lineWidth) / 2)
            case .right: offset = max(0, width - lineWidth)
            case .left, .none: offset = 0
            }

            lines.append(RenderedTable.TextLine(
                line: line,
                range: NSRange(location: start, length: count),
                origin: CGPoint(x: offset, y: 0),
                ascent: ceil(ascent),
                descent: ceil(descent + leading),
                width: lineWidth))
            start += count
        }
        return lines
    }

    // MARK: - Widths

    private static func distribute(natural: [CGFloat],
                                   minimum: [CGFloat],
                                   available: CGFloat) -> [CGFloat] {
        var widths = natural
        guard widths.reduce(0, +) > available else { return widths }

        var flexible = Set(widths.indices)
        var fixedTotal: CGFloat = 0

        while !flexible.isEmpty {
            let flexTotal = flexible.reduce(CGFloat(0)) { $0 + natural[$1] }
            guard flexTotal > 0 else { break }
            let budget = max(0, available - fixedTotal)
            let scale = budget / flexTotal

            if let pinned = flexible.first(where: { natural[$0] * scale < minimum[$0] }) {
                widths[pinned] = minimum[pinned]
                fixedTotal += minimum[pinned]
                flexible.remove(pinned)
                continue
            }
            for index in flexible { widths[index] = floor(natural[index] * scale) }
            break
        }
        return widths
    }

    private static func longestWordWidth(_ text: NSAttributedString) -> CGFloat {
        let string = text.string
        var widest: CGFloat = 0
        var location = 0
        for word in string.split(whereSeparator: { $0.isWhitespace }) {
            let length = word.utf16.count
            guard let found = string.range(of: String(word),
                                           range: string.index(string.startIndex,
                                                               offsetBy: 0)..<string.endIndex)
            else { location += length; continue }
            let nsRange = NSRange(found, in: string)
            guard nsRange.location != NSNotFound, NSMaxRange(nsRange) <= text.length else { continue }
            widest = max(widest, ceil(text.attributedSubstring(from: nsRange).size().width))
        }
        return widest
    }

    // MARK: - Cell contents

    private static func trimming(_ range: NSRange, _ chars: [unichar]) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, start < chars.count, chars[start] == 0x20 { start += 1 }
        while end > start, end - 1 < chars.count, chars[end - 1] == 0x20 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Builds a cell's display string with Markdown markers removed, alongside
    /// the map back to where each surviving character lives in the document.
    private static func attributedCell(_ chars: [unichar],
                                       _ range: NSRange,
                                       theme: Theme,
                                       bold: Bool) -> (text: NSAttributedString, origins: [Int]) {
        let base: [NSAttributedString.Key: Any] = [
            .font: bold ? theme.bodyBold : theme.body,
            .foregroundColor: theme.text,
        ]
        guard range.length > 0 else {
            return (NSAttributedString(string: "", attributes: base), [])
        }

        let spans = InlineScanner.scan(chars, range: range)
        var skip: [NSRange] = []
        for span in spans { skip.append(contentsOf: span.markers) }

        var scalars = [unichar]()
        var origins = [Int]()
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            if skip.contains(where: { NSLocationInRange(index, $0) }) { index += 1; continue }
            guard index < chars.count else { break }
            scalars.append(chars[index])
            origins.append(index)
            index += 1
        }

        let result = NSMutableAttributedString(
            string: String(utf16CodeUnits: scalars, count: scalars.count),
            attributes: base)

        func mapped(_ source: NSRange) -> NSRange? {
            var lower: Int?
            var upper: Int?
            for (position, origin) in origins.enumerated() where NSLocationInRange(origin, source) {
                if lower == nil { lower = position }
                upper = position
            }
            guard let lower, let upper else { return nil }
            return NSRange(location: lower, length: upper - lower + 1)
        }

        for span in spans {
            guard let target = mapped(span.contentRange) else { continue }
            switch span.kind {
            case .strong:
                result.addAttribute(.font, value: theme.bodyBold, range: target)
            case .emphasis:
                result.addAttribute(.font, value: bold ? theme.bodyBoldItalic : theme.bodyItalic,
                                    range: target)
            case .code:
                result.addAttributes([.font: theme.inlineCode,
                                      .foregroundColor: theme.inlineCodeText], range: target)
            case .strikethrough:
                result.addAttribute(.strikethroughStyle,
                                    value: NSUnderlineStyle.single.rawValue, range: target)
            case .highlight:
                result.addAttribute(.backgroundColor, value: theme.highlightBackground,
                                    range: target)
            case .link, .autolink:
                result.addAttributes([.foregroundColor: theme.link,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue],
                                     range: target)
            default:
                break
            }
        }
        return (result, origins)
    }
}

// MARK: - Drawing

extension RenderedTable {

    func draw(at origin: CGPoint,
              theme: Theme,
              selection: [CGRect],
              in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        for row in rows where row.isHeader {
            context.setFillColor(theme.tableHeaderBackground.cgColor)
            context.fill(CGRect(x: origin.x, y: origin.y + row.frame.minY,
                                width: size.width, height: row.frame.height))
        }

        for rect in selection {
            context.setFillColor(theme.selection.cgColor)
            context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
        }

        // Text. The context is flipped, so the text matrix flips back.
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in rows {
            for cell in row.cells {
                for line in cell.lines {
                    context.textPosition = CGPoint(x: origin.x + line.origin.x,
                                                   y: origin.y + line.origin.y)
                    CTLineDraw(line.line, context)
                }
            }
        }
        context.restoreGState()

        context.setStrokeColor(theme.tableBorder.cgColor)
        context.setLineWidth(1)
        context.beginPath()

        func horizontal(_ y: CGFloat) {
            let py = (origin.y + y).rounded() + 0.5
            context.move(to: CGPoint(x: origin.x, y: py))
            context.addLine(to: CGPoint(x: origin.x + size.width, y: py))
        }
        func vertical(_ x: CGFloat) {
            let px = (origin.x + x).rounded() + 0.5
            context.move(to: CGPoint(x: px, y: origin.y))
            context.addLine(to: CGPoint(x: px, y: origin.y + size.height))
        }

        horizontal(0)
        for row in rows { horizontal(row.frame.maxY) }
        vertical(0)
        vertical(size.width)
        for separator in separators { vertical(separator) }
        context.strokePath()
    }
}
