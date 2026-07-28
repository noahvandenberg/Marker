import Foundation

/// A line-oriented Markdown scanner built for a live editor.
///
/// Unlike an AST parser this keeps every source range intact and classifies
/// half-typed syntax gracefully, which is what a WYSIWYG-ish editing surface
/// needs. Parsing is whole-document but cheap: a single pass over a `unichar`
/// buffer plus a short second pass for tables.
enum MarkdownParser {

    static func parse(_ text: NSString) -> ParsedDocument {
        let length = text.length
        var doc = ParsedDocument()
        doc.length = length

        guard length > 0 else {
            doc.lines = [LineInfo(index: 0,
                                  range: NSRange(location: 0, length: 0),
                                  fullRange: NSRange(location: 0, length: 0),
                                  quoteDepth: 0, quoteMarkerRange: nil,
                                  bodyStart: 0, indent: 0, listDepth: 0,
                                  kind: .blank,
                                  contentRange: NSRange(location: 0, length: 0),
                                  codeRegion: nil, tableRegion: nil)]
            doc.signatures = [LineKind.blank.signature]
            return doc
        }

        var chars = [unichar](repeating: 0, count: length)
        text.getCharacters(&chars, range: NSRange(location: 0, length: length))

        var lines: [LineInfo] = []
        lines.reserveCapacity(length / 40 + 8)

        // Fenced-code state carried across lines.
        var fenceChar: unichar = 0
        var fenceCount = 0
        var fenceQuoteDepth = 0
        var openFenceLine: Int?
        var openMathLine: Int?

        // Active list stack, holding the content column of each open item.
        var listStack: [Int] = []

        var pos = 0
        var lineIndex = 0

        while pos <= length {
            let lineStart = pos
            var lineEnd = pos
            while lineEnd < length, chars[lineEnd] != 0x0A { lineEnd += 1 }

            // Trim a CR that belongs to a CRLF terminator.
            var contentEnd = lineEnd
            if contentEnd > lineStart, chars[contentEnd - 1] == 0x0D { contentEnd -= 1 }

            let fullEnd = lineEnd < length ? lineEnd + 1 : lineEnd
            let range = NSRange(location: lineStart, length: contentEnd - lineStart)
            let fullRange = NSRange(location: lineStart, length: fullEnd - lineStart)

            // --- blockquote prefix -------------------------------------------------
            var cursor = lineStart
            var quoteDepth = 0
            var quoteEnd = lineStart
            while true {
                var probe = cursor
                var spaces = 0
                while probe < contentEnd, chars[probe] == 0x20, spaces < 3 { probe += 1; spaces += 1 }
                guard probe < contentEnd, chars[probe] == 0x3E else { break } // '>'
                probe += 1
                if probe < contentEnd, chars[probe] == 0x20 { probe += 1 }
                quoteDepth += 1
                cursor = probe
                quoteEnd = probe
            }
            let quoteMarkerRange = quoteDepth > 0
                ? NSRange(location: lineStart, length: quoteEnd - lineStart)
                : nil

            let bodyStart = cursor
            var indent = 0
            while cursor < contentEnd, chars[cursor] == 0x20 || chars[cursor] == 0x09 {
                indent += chars[cursor] == 0x09 ? 4 : 1
                cursor += 1
            }
            let bodyContentStart = cursor
            let isBlank = bodyContentStart >= contentEnd

            var kind: LineKind = .paragraph
            var contentRange = NSRange(location: bodyContentStart,
                                       length: max(0, contentEnd - bodyContentStart))

            // --- inside a $$ display-math block ------------------------------------
            if openMathLine != nil {
                if isMathFence(chars, from: bodyContentStart, to: contentEnd) {
                    kind = .mathFence(open: false)
                    contentRange = NSRange(location: contentEnd, length: 0)
                } else {
                    kind = .codeLine
                    contentRange = NSRange(location: bodyStart,
                                           length: max(0, contentEnd - bodyStart))
                }
            } else if openFenceLine != nil {
                if quoteDepth == fenceQuoteDepth,
                   let close = matchFence(chars, from: bodyContentStart, to: contentEnd,
                                          char: fenceChar, minimum: fenceCount) {
                    kind = .fenceClose(fenceRange: NSRange(location: bodyContentStart,
                                                           length: close - bodyContentStart))
                    contentRange = NSRange(location: contentEnd, length: 0)
                } else {
                    kind = .codeLine
                    contentRange = NSRange(location: bodyStart, length: max(0, contentEnd - bodyStart))
                }
            } else if isBlank {
                kind = .blank
                listStack.removeAll(keepingCapacity: true)
            } else if isMathFence(chars, from: bodyContentStart, to: contentEnd) {
                kind = .mathFence(open: true)
                contentRange = NSRange(location: contentEnd, length: 0)
                openMathLine = lineIndex
                listStack.removeAll(keepingCapacity: true)
            } else if let fence = scanFenceOpen(chars, from: bodyContentStart, to: contentEnd) {
                kind = .fenceOpen(language: fence.language,
                                  fenceRange: NSRange(location: bodyContentStart,
                                                      length: contentEnd - bodyContentStart))
                contentRange = NSRange(location: contentEnd, length: 0)
                fenceChar = fence.char
                fenceCount = fence.count
                fenceQuoteDepth = quoteDepth
                openFenceLine = lineIndex
            } else if indent >= 4, listStack.isEmpty,
                      let prev = lines.last, prev.kind == .blank || prev.kind == .indentedCode {
                kind = .indentedCode
                contentRange = NSRange(location: bodyStart, length: max(0, contentEnd - bodyStart))
            } else if isThematicBreak(chars, from: bodyContentStart, to: contentEnd) {
                kind = .thematicBreak
                contentRange = NSRange(location: contentEnd, length: 0)
                listStack.removeAll(keepingCapacity: true)
            } else if let heading = scanATXHeading(chars, from: bodyContentStart, to: contentEnd) {
                kind = .heading(level: heading.level,
                                markerRange: heading.markerRange,
                                contentRange: heading.contentRange,
                                trailingHashes: heading.trailingHashes)
                contentRange = heading.contentRange
                listStack.removeAll(keepingCapacity: true)
            } else if let level = scanSetextUnderline(chars, from: bodyContentStart, to: contentEnd),
                      let prev = lines.last, prev.kind == .paragraph, listStack.isEmpty {
                kind = .setextUnderline(level: level)
                contentRange = NSRange(location: contentEnd, length: 0)
            } else if let definition = scanLinkDefinition(chars, from: bodyContentStart,
                                                          to: contentEnd) {
                kind = .linkDefinition(labelRange: definition.label,
                                       destinationRange: definition.destination)
                contentRange = NSRange(location: bodyContentStart,
                                       length: max(0, contentEnd - bodyContentStart))
                listStack.removeAll(keepingCapacity: true)
            } else if let item = scanListItem(chars, from: bodyContentStart, to: contentEnd) {
                kind = .listItem(marker: item.marker,
                                 markerRange: item.markerRange,
                                 checkbox: item.checkbox)
                contentRange = item.contentRange

                let contentColumn = indent + item.markerRange.length
                while let top = listStack.last, indent < top { listStack.removeLast() }
                if let top = listStack.last, indent >= top {
                    listStack.append(contentColumn)
                } else if listStack.isEmpty {
                    listStack = [contentColumn]
                }
            }

            if case .fenceClose = kind {
                openFenceLine = nil
            }
            if case .mathFence(let open) = kind, !open {
                openMathLine = nil
            }

            let listDepth = max(0, listStack.count - 1)

            lines.append(LineInfo(index: lineIndex,
                                  range: range,
                                  fullRange: fullRange,
                                  quoteDepth: quoteDepth,
                                  quoteMarkerRange: quoteMarkerRange,
                                  bodyStart: bodyStart,
                                  indent: indent,
                                  listDepth: listDepth,
                                  kind: kind,
                                  contentRange: contentRange,
                                  codeRegion: nil,
                                  tableRegion: nil))

            lineIndex += 1
            if lineEnd >= length { break }
            pos = fullEnd
        }

        // A trailing newline implies one more (empty) line.
        if length > 0, chars[length - 1] == 0x0A {
            lines.append(LineInfo(index: lineIndex,
                                  range: NSRange(location: length, length: 0),
                                  fullRange: NSRange(location: length, length: 0),
                                  quoteDepth: 0, quoteMarkerRange: nil,
                                  bodyStart: length, indent: 0, listDepth: 0,
                                  kind: openFenceLine != nil ? .codeLine : .blank,
                                  contentRange: NSRange(location: length, length: 0),
                                  codeRegion: nil, tableRegion: nil))
        }

        doc.lines = lines
        buildCodeRegions(&doc, chars: chars)
        buildTableRegions(&doc, chars: chars)
        doc.signatures = doc.lines.map { $0.kind.signature }
        collectLinkDefinitions(&doc, chars: chars)
        return doc
    }

    private static func collectLinkDefinitions(_ doc: inout ParsedDocument, chars: [unichar]) {
        var definitions: [String: String] = [:]
        for line in doc.lines {
            guard line.codeRegion == nil,
                  case .linkDefinition(let label, let destination) = line.kind else { continue }
            let key = InlineScanner.string(chars, label)
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, definitions[key] == nil else { continue }
            var value = InlineScanner.string(chars, destination)
            if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            definitions[key] = value
        }
        doc.linkDefinitions = definitions
    }

    // MARK: - Regions

    private static func buildCodeRegions(_ doc: inout ParsedDocument, chars: [unichar]) {
        var regions: [CodeRegion] = []
        var i = 0
        let lines = doc.lines

        while i < lines.count {
            switch lines[i].kind {
            case .mathFence(let open) where open:
                let start = i
                var end = i + 1
                var closeLine: Int?
                while end < lines.count {
                    if case .mathFence(let isOpen) = lines[end].kind, !isOpen {
                        closeLine = end; end += 1; break
                    }
                    end += 1
                }
                let lineRange = start..<end
                regions.append(CodeRegion(lineRange: lineRange,
                                          charRange: doc.charRange(forLines: lineRange),
                                          language: "math",
                                          fenced: true,
                                          openFenceLine: start,
                                          closeFenceLine: closeLine,
                                          content: .math))
                i = end

            case .fenceOpen(let language, _):
                let start = i
                var end = i + 1
                var closeLine: Int?
                while end < lines.count {
                    if case .fenceClose = lines[end].kind { closeLine = end; end += 1; break }
                    end += 1
                }
                let lineRange = start..<end
                regions.append(CodeRegion(lineRange: lineRange,
                                          charRange: doc.charRange(forLines: lineRange),
                                          language: language,
                                          fenced: true,
                                          openFenceLine: start,
                                          closeFenceLine: closeLine,
                                          content: CodeRegion.content(for: language)))
                i = end

            case .indentedCode:
                let start = i
                var end = i
                while end < lines.count, lines[end].kind == .indentedCode { end += 1 }
                let lineRange = start..<end
                regions.append(CodeRegion(lineRange: lineRange,
                                          charRange: doc.charRange(forLines: lineRange),
                                          language: nil,
                                          fenced: false,
                                          openFenceLine: nil,
                                          closeFenceLine: nil))
                i = end

            default:
                i += 1
            }
        }

        for (index, region) in regions.enumerated() {
            for line in region.lineRange { doc.lines[line].codeRegion = index }
        }
        doc.codeRegions = regions
    }

    private static func buildTableRegions(_ doc: inout ParsedDocument, chars: [unichar]) {
        var regions: [TableRegion] = []
        var i = 0
        let lines = doc.lines

        while i + 1 < lines.count {
            let header = lines[i]
            let delimiter = lines[i + 1]

            guard header.kind == .paragraph,
                  header.codeRegion == nil,
                  containsPipe(chars, header.contentRange),
                  let alignments = parseDelimiterRow(chars, delimiter.contentRange),
                  !alignments.isEmpty,
                  splitCells(chars, header.contentRange).count == alignments.count
            else { i += 1; continue }

            var end = i + 2
            while end < lines.count,
                  lines[end].kind == .paragraph,
                  lines[end].codeRegion == nil,
                  containsPipe(chars, lines[end].contentRange) {
                end += 1
            }

            let lineRange = i..<end
            regions.append(TableRegion(lineRange: lineRange,
                                       charRange: doc.charRange(forLines: lineRange),
                                       headerLine: i,
                                       delimiterLine: i + 1,
                                       alignments: alignments,
                                       columnCount: alignments.count))
            i = end
        }

        for (index, region) in regions.enumerated() {
            for line in region.lineRange {
                doc.lines[line].tableRegion = index
                doc.lines[line].kind = .tableRow(isDelimiter: line == region.delimiterLine)
            }
        }
        doc.tableRegions = regions
        doc.signatures = doc.lines.map { $0.kind.signature }
    }

    // MARK: - Line scanners

    private static func matchFence(_ chars: [unichar], from: Int, to: Int,
                                   char: unichar, minimum: Int) -> Int? {
        var i = from
        var count = 0
        while i < to, chars[i] == char { count += 1; i += 1 }
        guard count >= minimum else { return nil }
        var j = i
        while j < to, chars[j] == 0x20 || chars[j] == 0x09 { j += 1 }
        return j >= to ? i : nil
    }

    private static func scanFenceOpen(_ chars: [unichar], from: Int, to: Int)
        -> (char: unichar, count: Int, language: String?)? {
        guard from < to else { return nil }
        let c = chars[from]
        guard c == 0x60 || c == 0x7E else { return nil } // ` or ~
        var i = from
        var count = 0
        while i < to, chars[i] == c { count += 1; i += 1 }
        guard count >= 3 else { return nil }

        var info = ""
        var j = i
        while j < to, chars[j] == 0x20 { j += 1 }
        while j < to, chars[j] != 0x20, chars[j] != 0x60 {
            info.append(Character(UnicodeScalar(chars[j]) ?? " "))
            j += 1
        }
        // Backticks may not appear in an info string on a backtick fence.
        if c == 0x60 {
            var k = i
            while k < to { if chars[k] == 0x60 { return nil }; k += 1 }
        }
        let language = info.isEmpty ? nil : info.lowercased()
        return (c, count, language)
    }

    /// A line consisting solely of `$$`.
    private static func isMathFence(_ chars: [unichar], from: Int, to: Int) -> Bool {
        var i = from
        var count = 0
        while i < to, chars[i] == 0x24 { count += 1; i += 1 } // '$'
        guard count == 2 else { return false }
        while i < to, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        return i >= to
    }

    /// `[label]: destination "optional title"`
    private static func scanLinkDefinition(_ chars: [unichar], from: Int, to: Int)
        -> (label: NSRange, destination: NSRange)? {
        guard from < to, chars[from] == 0x5B else { return nil } // '['
        var i = from + 1
        // A footnote definition is a different construct; leave it as prose.
        if i < to, chars[i] == 0x5E { return nil }
        while i < to, chars[i] != 0x5D {
            if chars[i] == 0x5C { i += 2; continue }
            if chars[i] == 0x5B { return nil }
            i += 1
        }
        guard i < to, chars[i] == 0x5D, i > from + 1 else { return nil }
        let label = NSRange(location: from + 1, length: i - from - 1)
        i += 1
        guard i < to, chars[i] == 0x3A else { return nil } // ':'
        i += 1
        while i < to, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        guard i < to else { return nil }

        var end = i
        while end < to, chars[end] != 0x20, chars[end] != 0x09 { end += 1 }
        guard end > i else { return nil }
        return (label, NSRange(location: i, length: end - i))
    }

    private static func isThematicBreak(_ chars: [unichar], from: Int, to: Int) -> Bool {
        guard from < to else { return false }
        let c = chars[from]
        guard c == 0x2D || c == 0x2A || c == 0x5F else { return false } // - * _
        var count = 0
        var i = from
        while i < to {
            let ch = chars[i]
            if ch == c { count += 1 }
            else if ch != 0x20 && ch != 0x09 { return false }
            i += 1
        }
        return count >= 3
    }

    private static func scanATXHeading(_ chars: [unichar], from: Int, to: Int)
        -> (level: Int, markerRange: NSRange, contentRange: NSRange, trailingHashes: NSRange?)? {
        guard from < to, chars[from] == 0x23 else { return nil } // '#'
        var i = from
        var level = 0
        while i < to, chars[i] == 0x23, level < 7 { level += 1; i += 1 }
        guard level <= 6 else { return nil }
        guard i >= to || chars[i] == 0x20 || chars[i] == 0x09 else { return nil }

        var contentStart = i
        while contentStart < to, chars[contentStart] == 0x20 || chars[contentStart] == 0x09 {
            contentStart += 1
        }
        let markerRange = NSRange(location: from, length: contentStart - from)

        // A run of trailing `#` characters is a closing sequence, not content.
        var contentEnd = to
        while contentEnd > contentStart,
              chars[contentEnd - 1] == 0x20 || chars[contentEnd - 1] == 0x09 { contentEnd -= 1 }
        var hashEnd = contentEnd
        while hashEnd > contentStart, chars[hashEnd - 1] == 0x23 { hashEnd -= 1 }
        var trailing: NSRange?
        if hashEnd < contentEnd,
           hashEnd == contentStart || chars[hashEnd - 1] == 0x20 {
            var trimStart = hashEnd
            while trimStart > contentStart, chars[trimStart - 1] == 0x20 { trimStart -= 1 }
            trailing = NSRange(location: trimStart, length: contentEnd - trimStart)
            contentEnd = trimStart
        }

        return (level,
                markerRange,
                NSRange(location: contentStart, length: max(0, contentEnd - contentStart)),
                trailing)
    }

    private static func scanSetextUnderline(_ chars: [unichar], from: Int, to: Int) -> Int? {
        guard from < to else { return nil }
        let c = chars[from]
        guard c == 0x3D || c == 0x2D else { return nil } // = or -
        var i = from
        while i < to, chars[i] == c { i += 1 }
        while i < to, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        guard i >= to else { return nil }
        return c == 0x3D ? 1 : 2
    }

    private static func scanListItem(_ chars: [unichar], from: Int, to: Int)
        -> (marker: ListMarkerKind, markerRange: NSRange, checkbox: CheckboxInfo?, contentRange: NSRange)? {
        guard from < to else { return nil }

        var marker: ListMarkerKind
        var i = from
        let c = chars[from]

        if c == 0x2D || c == 0x2A || c == 0x2B { // - * +
            marker = .bullet(Character(UnicodeScalar(c) ?? "-"))
            i += 1
        } else if c >= 0x30, c <= 0x39 {
            var number = 0
            var digits = 0
            while i < to, chars[i] >= 0x30, chars[i] <= 0x39, digits < 9 {
                number = number * 10 + Int(chars[i] - 0x30)
                digits += 1
                i += 1
            }
            guard i < to, chars[i] == 0x2E || chars[i] == 0x29 else { return nil } // . or )
            marker = .ordered(number: number,
                              delimiter: Character(UnicodeScalar(chars[i]) ?? "."))
            i += 1
        } else {
            return nil
        }

        // A marker must be followed by whitespace (or end the line).
        guard i >= to || chars[i] == 0x20 || chars[i] == 0x09 else { return nil }
        var contentStart = i
        while contentStart < to, chars[contentStart] == 0x20 || chars[contentStart] == 0x09 {
            contentStart += 1
        }
        let markerRange = NSRange(location: from, length: contentStart - from)

        // Optional GFM task-list checkbox.
        var checkbox: CheckboxInfo?
        var afterCheckbox = contentStart
        if contentStart + 2 < to,
           chars[contentStart] == 0x5B, chars[contentStart + 2] == 0x5D { // [ ... ]
            let inner = chars[contentStart + 1]
            if inner == 0x20 || inner == 0x78 || inner == 0x58 { // space, x, X
                checkbox = CheckboxInfo(range: NSRange(location: contentStart, length: 3),
                                        checked: inner != 0x20)
                afterCheckbox = contentStart + 3
                while afterCheckbox < to,
                      chars[afterCheckbox] == 0x20 || chars[afterCheckbox] == 0x09 {
                    afterCheckbox += 1
                }
            }
        }

        return (marker,
                markerRange,
                checkbox,
                NSRange(location: afterCheckbox, length: max(0, to - afterCheckbox)))
    }

    // MARK: - Tables

    static func containsPipe(_ chars: [unichar], _ range: NSRange) -> Bool {
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            if chars[i] == 0x7C, i == range.location || chars[i - 1] != 0x5C { return true }
            i += 1
        }
        return false
    }

    /// Splits a table row on unescaped pipes, discarding the optional outer pipes.
    static func splitCells(_ chars: [unichar], _ range: NSRange) -> [NSRange] {
        var cells: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        guard start < end else { return [] }

        var i = start
        if chars[i] == 0x7C { i += 1; start = i }
        while i < end {
            if chars[i] == 0x7C, chars[i - 1] != 0x5C {
                cells.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
            i += 1
        }
        // Text after the last pipe is a cell unless the row ended with a pipe.
        if start < end {
            cells.append(NSRange(location: start, length: end - start))
        } else if start == end, end > range.location, chars[end - 1] != 0x7C {
            cells.append(NSRange(location: start, length: 0))
        }
        return cells
    }

    /// Parses `| --- | :--: |` into per-column alignments, or nil if it isn't one.
    static func parseDelimiterRow(_ chars: [unichar], _ range: NSRange) -> [TableAlignment]? {
        guard range.length > 0, containsPipe(chars, range) else { return nil }
        let cells = splitCells(chars, range)
        guard !cells.isEmpty else { return nil }

        var alignments: [TableAlignment] = []
        for cell in cells {
            var i = cell.location
            let end = NSMaxRange(cell)
            while i < end, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
            var j = end
            while j > i, chars[j - 1] == 0x20 || chars[j - 1] == 0x09 { j -= 1 }
            guard i < j else { return nil }

            let leadingColon = chars[i] == 0x3A
            let trailingColon = chars[j - 1] == 0x3A
            var k = leadingColon ? i + 1 : i
            let limit = trailingColon ? j - 1 : j
            guard k < limit else { return nil }
            while k < limit {
                guard chars[k] == 0x2D else { return nil }
                k += 1
            }

            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }
}
