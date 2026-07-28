import Foundation

/// Renders Markdown to a self-contained HTML document.
///
/// Reuses the editor's own parser so exported output matches what you see while
/// editing. Deliberately small: it covers the block and inline constructs the
/// editor renders, and escapes everything it doesn't.
enum HTMLExporter {

    static func export(markdown: String, title: String) -> String {
        let body = renderBody(markdown)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          max-width: 42rem; margin: 4rem auto; padding: 0 1.5rem;
          color: #1d1d1f; background: #fff;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #e8e8ea; background: #1a1a1c; }
          pre, code { background: #232326 !important; }
          blockquote { border-color: #444 !important; color: #a9a9ad !important; }
          th, td { border-color: #3a3a3d !important; }
          th { background: #232326 !important; }
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 2em 0 .6em; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        h1, h2 { border-bottom: 1px solid rgba(128,128,128,.25); padding-bottom: .3em; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        code { font: .9em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
               background: #f4f4f6; padding: .15em .35em; border-radius: 4px; }
        pre { background: #f4f4f6; padding: 1em; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #d8d8dc; margin-left: 0;
                     padding: .1em 0 .1em 1em; color: #5c5c61; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #d8d8dc; padding: .45em .75em; text-align: left; }
        th { background: #f6f6f8; }
        hr { border: none; border-top: 1px solid rgba(128,128,128,.35); margin: 2em 0; }
        img { max-width: 100%; }
        ul.task-list { list-style: none; padding-left: 1.2em; }
        .math-display { text-align: center; margin: 1.2em 0; }
        pre.mermaid { background: none; text-align: center; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Blocks

    private static func renderBody(_ markdown: String) -> String {
        let source = markdown as NSString
        let doc = MarkdownParser.parse(source)
        var chars = [unichar](repeating: 0, count: source.length)
        if source.length > 0 {
            source.getCharacters(&chars, range: NSRange(location: 0, length: source.length))
        }

        var out: [String] = []
        var paragraph: [String] = []
        var listStack: [(ordered: Bool, depth: Int)] = []
        var quoteOpen = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.joined(separator: "\n") + "</p>")
            paragraph.removeAll()
        }
        /// Leaves exactly `levels` lists open.
        func closeLists(to levels: Int) {
            while listStack.count > levels {
                let item = listStack.removeLast()
                out.append(item.ordered ? "</ol>" : "</ul>")
            }
        }
        func openList(ordered: Bool, task: Bool, depth: Int) {
            out.append(ordered ? "<ol>" : (task ? "<ul class=\"task-list\">" : "<ul>"))
            listStack.append((ordered, depth))
        }
        func closeQuotes(to depth: Int) {
            while quoteOpen > depth { out.append("</blockquote>"); quoteOpen -= 1 }
        }
        func openQuotes(to depth: Int) {
            while quoteOpen < depth { out.append("<blockquote>"); quoteOpen += 1 }
        }

        var index = 0
        while index < doc.lines.count {
            let line = doc.lines[index]

            if line.quoteDepth != quoteOpen, !line.kind.isCodeish {
                flushParagraph()
                closeLists(to: 0)
                closeQuotes(to: line.quoteDepth)
                openQuotes(to: line.quoteDepth)
            }

            switch line.kind {
            case .blank:
                flushParagraph()
                closeLists(to: 0)

            case .paragraph:
                if index + 1 < doc.lines.count,
                   case .setextUnderline(let level) = doc.lines[index + 1].kind {
                    flushParagraph()
                    out.append("<h\(level)>\(inline(chars, line.contentRange, doc.linkDefinitions))</h\(level)>")
                    index += 2
                    continue
                }
                paragraph.append(inline(chars, line.contentRange, doc.linkDefinitions))

            case .setextUnderline:
                break

            case .heading(let level, _, let contentRange, _):
                flushParagraph()
                closeLists(to: 0)
                out.append("<h\(level)>\(inline(chars, contentRange, doc.linkDefinitions))</h\(level)>")

            case .thematicBreak:
                flushParagraph()
                closeLists(to: 0)
                out.append("<hr>")

            case .fenceOpen(let language, _):
                flushParagraph()
                closeLists(to: 0)
                let classAttribute = language.map { " class=\"language-\(escape($0))\"" } ?? ""
                var body: [String] = []
                var cursor = index + 1
                while cursor < doc.lines.count {
                    if case .fenceClose = doc.lines[cursor].kind { break }
                    body.append(escape(InlineScanner.string(chars, doc.lines[cursor].range)))
                    cursor += 1
                }
                if language?.lowercased() == "mermaid" {
                    out.append("<pre class=\"mermaid\">" + body.joined(separator: "\n") + "</pre>")
                } else {
                    out.append("<pre><code\(classAttribute)>"
                               + body.joined(separator: "\n") + "</code></pre>")
                }
                index = min(cursor + 1, doc.lines.count)
                continue

            case .fenceClose, .codeLine:
                break

            case .mathFence(let open):
                guard open else { break }
                flushParagraph()
                closeLists(to: 0)
                var body: [String] = []
                var cursor = index + 1
                while cursor < doc.lines.count {
                    if case .mathFence(let isOpen) = doc.lines[cursor].kind, !isOpen { break }
                    body.append(escape(InlineScanner.string(chars, doc.lines[cursor].range)))
                    cursor += 1
                }
                // Exported math stays as TeX in the standard \\[ ... \\] delimiters.
                out.append("<div class=\"math-display\">\\[" + body.joined(separator: "\n") + "\\]</div>")
                index = min(cursor + 1, doc.lines.count)
                continue

            case .linkDefinition:
                // Definitions are resolved into the links themselves.
                flushParagraph()

            case .indentedCode:
                flushParagraph()
                var body: [String] = []
                var cursor = index
                while cursor < doc.lines.count, doc.lines[cursor].kind == .indentedCode {
                    let text = InlineScanner.string(chars, doc.lines[cursor].range)
                    body.append(escape(String(text.dropFirst(min(4, text.count)))))
                    cursor += 1
                }
                out.append("<pre><code>" + body.joined(separator: "\n") + "</code></pre>")
                index = cursor
                continue

            case .listItem(let marker, _, let checkbox):
                flushParagraph()
                let depth = line.listDepth
                let ordered = marker.isOrdered
                let task = checkbox != nil

                // An item at depth d needs exactly d + 1 open lists.
                closeLists(to: depth + 1)
                if let top = listStack.last, listStack.count == depth + 1,
                   top.ordered != ordered {
                    closeLists(to: depth)          // bullet list turning into a numbered one
                }
                while listStack.count < depth + 1 {
                    openList(ordered: ordered, task: task, depth: listStack.count)
                }
                var content = inline(chars, line.contentRange, doc.linkDefinitions)
                if let checkbox {
                    let checkedAttribute = checkbox.checked ? " checked" : ""
                    content = "<input type=\"checkbox\" disabled\(checkedAttribute)> " + content
                }
                out.append("<li>\(content)</li>")

            case .tableRow:
                flushParagraph()
                closeLists(to: 0)
                guard let regionIndex = line.tableRegion else { break }
                let region = doc.tableRegions[regionIndex]
                out.append(renderTable(region, doc: doc, chars: chars))
                index = region.lineRange.upperBound
                continue
            }

            index += 1
        }

        flushParagraph()
        closeLists(to: 0)
        closeQuotes(to: 0)
        return out.joined(separator: "\n")
    }

    private static func renderTable(_ region: TableRegion,
                                    doc: ParsedDocument,
                                    chars: [unichar]) -> String {
        var rows: [String] = ["<table>"]
        for lineIndex in region.lineRange where lineIndex != region.delimiterLine {
            let line = doc.lines[lineIndex]
            let isHeader = lineIndex == region.headerLine
            let tag = isHeader ? "th" : "td"
            var cells: [String] = []
            for (column, cell) in MarkdownParser.splitCells(chars, line.contentRange).enumerated() {
                let alignment = column < region.alignments.count ? region.alignments[column] : .none
                let style: String
                switch alignment {
                case .center: style = " style=\"text-align:center\""
                case .right: style = " style=\"text-align:right\""
                case .left, .none: style = ""
                }
                var trimmed = cell
                while trimmed.length > 0, chars[trimmed.location] == 0x20 {
                    trimmed.location += 1; trimmed.length -= 1
                }
                while trimmed.length > 0, chars[NSMaxRange(trimmed) - 1] == 0x20 {
                    trimmed.length -= 1
                }
                cells.append("<\(tag)\(style)>\(inline(chars, trimmed, doc.linkDefinitions))</\(tag)>")
            }
            if isHeader { rows.append("<thead>") }
            rows.append("<tr>" + cells.joined() + "</tr>")
            if isHeader { rows.append("</thead><tbody>") }
        }
        rows.append("</tbody></table>")
        return rows.joined()
    }

    // MARK: - Inline

    private static func inline(_ chars: [unichar],
                               _ range: NSRange,
                               _ definitions: [String: String]) -> String {
        guard range.length > 0 else { return "" }
        let spans = InlineScanner.scan(chars, range: range, definitions: definitions)

        // Build an edit list, then apply it right-to-left over the escaped text.
        struct Insertion { var location: Int; var text: String; var order: Int }
        var insertions: [Insertion] = []
        var suppressed: [NSRange] = []

        for (order, span) in spans.enumerated() {
            let (open, close): (String, String)
            switch span.kind {
            case .code: (open, close) = ("<code>", "</code>")
            case .strong: (open, close) = ("<strong>", "</strong>")
            case .emphasis: (open, close) = ("<em>", "</em>")
            case .strikethrough: (open, close) = ("<del>", "</del>")
            case .highlight: (open, close) = ("<mark>", "</mark>")
            case .footnoteRef: (open, close) = ("<sup>", "</sup>")
            case .math(let display):
                let tex = escape(InlineScanner.string(chars, span.contentRange))
                insertions.append(Insertion(location: span.range.location,
                                            text: display ? "\\[" + tex + "\\]"
                                                          : "\\(" + tex + "\\)",
                                            order: order))
                suppressed.append(span.range)
                continue
            case .link, .autolink:
                let href = escapeAttribute(span.destination ?? "")
                (open, close) = ("<a href=\"\(href)\">", "</a>")
            case .image:
                let source = escapeAttribute(span.destination ?? "")
                let alt = escapeAttribute(InlineScanner.string(chars, span.contentRange))
                insertions.append(Insertion(location: span.range.location,
                                            text: "<img src=\"\(source)\" alt=\"\(alt)\">",
                                            order: order))
                suppressed.append(span.range)
                continue
            }
            insertions.append(Insertion(location: span.contentRange.location, text: open, order: order))
            insertions.append(Insertion(location: NSMaxRange(span.contentRange), text: close, order: order))
            suppressed.append(contentsOf: span.markers)
        }

        var result = ""
        var index = range.location
        let end = NSMaxRange(range)
        let sorted = insertions.sorted { ($0.location, $0.order) < ($1.location, $1.order) }
        var pending = 0

        while index <= end {
            while pending < sorted.count, sorted[pending].location == index {
                result += sorted[pending].text
                pending += 1
            }
            guard index < end else { break }
            if suppressed.contains(where: { NSLocationInRange(index, $0) }) {
                index += 1
                continue
            }
            // Code spans keep their literal contents.
            let scalar = InlineScanner.string(chars, NSRange(location: index, length: 1))
            result += escape(scalar)
            index += 1
        }
        return result
    }

    // MARK: - Escaping

    private static func escape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
