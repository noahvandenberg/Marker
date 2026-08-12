import AppKit

/// Applies live Markdown rendering to an `NSTextStorage`.
///
/// Styling is line-scoped so an edit only repaints the lines it can affect.
/// Syntax markers are never removed from the backing store — they are given a
/// hairline font and a clear color so the source text stays byte-for-byte
/// intact while reading like rendered prose.
@MainActor
final class MarkdownStyler {

    let context: StyleContext
    var theme: Theme { context.theme }

    /// Cached per-table geometry, rebuilt whenever the document is reparsed.
    private var tableColumnWidths: [Int: [Int]] = [:]
    private var parseGeneration = 0
    /// Set while styling a table row so column alignment can run after the
    /// base attributes are applied.
    private var pendingTableAlignment: (LineInfo, Int, CGFloat)?
    /// Regions currently showing a rendered image instead of their source.
    private var renderedRegions: [Int: RenderedBlock] = [:]
    /// Tables currently drawn rather than shown as pipe source.
    private(set) var renderedTables: [Int: RenderedTable] = [:]
    private var currentSelection = NSRange(location: 0, length: 0)
    /// True when the last styling pass painted something that was still
    /// resolving — a diagram mid-render, an image mid-load. Those lines have to
    /// be painted again once it arrives.
    private(set) var lastPassDeferred = false
    private var tableLayoutCache: [TableCacheKey: RenderedTable] = [:]
    /// Space reservations for inline images and equations, applied after the
    /// concealment pass (which resets kerning).
    private var pendingInlineKerns: [(NSRange, CGFloat)] = []

    init(theme: Theme) {
        context = StyleContext(theme: theme)
    }

    func updateTheme(_ theme: Theme) {
        context.theme = theme
        context.monoAdvance = MarkdownStyler.advance(of: theme.mono)
        tableColumnWidths.removeAll()
        tableLayoutCache.removeAll()
        renderedTables.removeAll()
    }

    func documentDidReparse() {
        parseGeneration &+= 1
        tableColumnWidths.removeAll()
        tableLayoutCache.removeAll()
        renderedTables.removeAll()
    }

    // MARK: - Entry point

    func style(lines lineRange: Range<Int>,
               doc: ParsedDocument,
               chars: [unichar],
               storage: NSTextStorage,
               revealed: Set<Int>,
               caretLines: Set<Int>,
               selection: NSRange,
               focusLines: Range<Int>?) {
        guard !doc.lines.isEmpty else { return }
        if context.monoAdvance == 0 {
            context.monoAdvance = MarkdownStyler.advance(of: theme.mono)
        }

        let lower = max(0, lineRange.lowerBound)
        let upper = min(doc.lines.count, lineRange.upperBound)
        guard lower < upper else { return }

        lastPassDeferred = false
        prepareRenderedRegions(doc: doc, chars: chars, lines: lower..<upper, caretLines: caretLines)
        prepareRenderedTables(doc: doc, chars: chars, lines: lower..<upper,
                              revealed: revealed, selection: selection)

        for index in lower..<upper {
            styleLine(index,
                      doc: doc,
                      chars: chars,
                      storage: storage,
                      revealed: revealed.contains(index),
                      dimmed: focusLines.map { !$0.contains(index) } ?? false)
        }

        // Code regions are tokenized as a whole so block comments and multi-line
        // strings survive across line boundaries.
        var handled = Set<Int>()
        for index in lower..<upper {
            guard let regionIndex = doc.lines[index].codeRegion,
                  !handled.contains(regionIndex) else { continue }
            handled.insert(regionIndex)
            highlightCode(doc.codeRegions[regionIndex], doc: doc, chars: chars, storage: storage)
        }
    }

    // MARK: - Per-line styling

    private func styleLine(_ index: Int,
                           doc: ParsedDocument,
                           chars: [unichar],
                           storage: NSTextStorage,
                           revealed: Bool,
                           dimmed: Bool) {
        let line = doc.lines[index]
        guard line.fullRange.length > 0 || line.range.length > 0 else { return }
        let fullRange = clamp(line.fullRange, to: storage.length)
        guard fullRange.length > 0 else { return }

        let decoration = BlockDecoration(context: context)
        decoration.dimmed = dimmed
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple
        paragraph.lineBreakMode = .byWordWrapping

        let quoteInset = CGFloat(line.quoteDepth) * theme.quoteIndent
        paragraph.firstLineHeadIndent = quoteInset
        paragraph.headIndent = quoteInset
        decoration.quoteDepth = line.quoteDepth

        var attributes: [NSAttributedString.Key: Any] = [
            .font: theme.body,
            .foregroundColor: line.quoteDepth > 0 ? theme.quoteText : theme.text,
            .paragraphStyle: paragraph,
        ]

        var concealRanges: [NSRange] = []
        var inlineRange = line.contentRange
        var scanInlines = true
        pendingInlineKerns.removeAll(keepingCapacity: true)

        // A table the caret is outside of is drawn rather than shown as pipes.
        if let regionIndex = line.tableRegion, let table = renderedTables[regionIndex] {
            let region = doc.tableRegions[regionIndex]
            paragraph.lineHeightMultiple = 1.0
            paragraph.lineBreakMode = .byClipping
            if index == region.lineRange.lowerBound {
                decoration.renderedTable = table
                decoration.tableSelection = currentSelection.length > 0
                    ? table.selectionRects(forSource: currentSelection)
                    : []
                let height = table.size.height + theme.baseSize * 0.9
                paragraph.minimumLineHeight = height
                paragraph.maximumLineHeight = height
                paragraph.paragraphSpacingBefore = theme.baseSize * 0.4
            } else {
                paragraph.minimumLineHeight = 0.01
                paragraph.maximumLineHeight = 0.01
            }
            if index == region.lineRange.upperBound - 1 {
                paragraph.paragraphSpacing = theme.baseSize * 0.5
            }
            attributes[.paragraphStyle] = paragraph
            storage.setAttributes(attributes, range: fullRange)
            storage.addAttribute(.blockDecoration, value: decoration, range: fullRange)
            conceal(clamp(line.range, to: storage.length), in: storage, asMarker: false)
            if dimmed { dim(fullRange, in: storage) }
            return
        }

        // A diagram or equation block that has finished rendering replaces its
        // own source: every line is hidden, and one of them reserves the height.
        if let regionIndex = line.codeRegion, let block = renderedRegions[regionIndex] {
            let region = doc.codeRegions[regionIndex]
            let anchor = region.contentLineRange.isEmpty
                ? region.lineRange.lowerBound
                : region.contentLineRange.lowerBound
            paragraph.lineHeightMultiple = 1.0
            if index == anchor {
                decoration.renderedBlock = block
                let height = block.size.height + theme.baseSize * 0.6
                paragraph.minimumLineHeight = height
                paragraph.maximumLineHeight = height
                paragraph.paragraphSpacingBefore = theme.baseSize * 0.4
                paragraph.paragraphSpacing = theme.baseSize * 0.4
            } else {
                paragraph.minimumLineHeight = 0.01
                paragraph.maximumLineHeight = 0.01
            }
            attributes[.paragraphStyle] = paragraph
            storage.setAttributes(attributes, range: fullRange)
            storage.addAttribute(.blockDecoration, value: decoration, range: fullRange)
            conceal(clamp(line.range, to: storage.length), in: storage)
            if dimmed { dim(fullRange, in: storage) }
            return
        }

        switch line.kind {

        case .blank:
            paragraph.lineHeightMultiple = 1.0
            scanInlines = false

        case .paragraph:
            // A `===`/`---` underline on the next line promotes this to a heading.
            if index + 1 < doc.lines.count,
               case .setextUnderline(let level) = doc.lines[index + 1].kind {
                attributes[.font] = theme.headingFont(level: level)
                attributes[.foregroundColor] = theme.heading
                paragraph.paragraphSpacingBefore = theme.headingSpacingBefore(level: level)
                decoration.headingRuleLevel = level
            }

        case .heading(let level, let markerRange, let contentRange, let trailingHashes):
            attributes[.font] = theme.headingFont(level: level)
            attributes[.foregroundColor] = theme.heading
            paragraph.paragraphSpacingBefore = index == 0 ? 0 : theme.headingSpacingBefore(level: level)
            paragraph.paragraphSpacing = theme.headingSpacingAfter(level: level)
            decoration.headingRuleLevel = level
            inlineRange = contentRange
            if !revealed {
                concealRanges.append(markerRange)
                if let trailingHashes { concealRanges.append(trailingHashes) }
            }

        case .setextUnderline:
            scanInlines = false
            if !revealed {
                concealRanges.append(line.range)
                paragraph.minimumLineHeight = 0.01
                paragraph.maximumLineHeight = 0.01
            }

        case .thematicBreak:
            scanInlines = false
            decoration.thematicBreak = true
            paragraph.paragraphSpacingBefore = theme.baseSize * 0.7
            paragraph.paragraphSpacing = theme.baseSize * 0.7
            if !revealed {
                concealRanges.append(line.range)
                paragraph.minimumLineHeight = 2
                paragraph.maximumLineHeight = 2
            }

        case .fenceOpen(let language, _):
            scanInlines = false
            decoration.codeBlock = CodeBlockDecoration(isFirst: true,
                                                       isLast: false,
                                                       language: language)
            paragraph.firstLineHeadIndent = quoteInset + theme.codePadding
            paragraph.headIndent = quoteInset + theme.codePadding
            paragraph.paragraphSpacingBefore = theme.baseSize * 0.5
            paragraph.lineHeightMultiple = 1.0
            paragraph.minimumLineHeight = CodeBlockChrome.copyButtonSize.height
                + CodeBlockChrome.inset * 2
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: round(theme.baseSize * 0.72),
                                                            weight: .medium)
            attributes[.foregroundColor] = theme.secondaryText
            attributes[.kern] = 0.6
            if !revealed {
                // Hide the backticks but keep the language name as a label.
                concealRanges.append(fenceCharRange(chars, line: line))
            }

        case .fenceClose:
            scanInlines = false
            decoration.codeBlock = CodeBlockDecoration(isFirst: false, isLast: true, language: nil)
            paragraph.lineHeightMultiple = 1.0
            paragraph.paragraphSpacing = theme.baseSize * 0.5
            attributes[.font] = theme.mono
            attributes[.foregroundColor] = theme.marker
            if !revealed {
                concealRanges.append(line.range)
                paragraph.minimumLineHeight = 10
                paragraph.maximumLineHeight = 10
            }

        case .mathFence:
            scanInlines = false
            decoration.codeBlock = CodeBlockDecoration(isFirst: line.kind == .mathFence(open: true),
                                                       isLast: line.kind == .mathFence(open: false),
                                                       language: "math")
            paragraph.lineHeightMultiple = 1.0
            attributes[.font] = theme.mono
            attributes[.foregroundColor] = theme.marker
            paragraph.firstLineHeadIndent = quoteInset + theme.codePadding
            paragraph.headIndent = quoteInset + theme.codePadding

        case .linkDefinition(let labelRange, let destinationRange):
            scanInlines = false
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: round(theme.baseSize * 0.85),
                                                            weight: .regular)
            attributes[.foregroundColor] = theme.secondaryText
            storage.setAttributes(attributes, range: fullRange)
            storage.addAttribute(.foregroundColor, value: theme.accent,
                                 range: clamp(labelRange, to: storage.length))
            storage.addAttribute(.foregroundColor, value: theme.link,
                                 range: clamp(destinationRange, to: storage.length))
            storage.addAttribute(.blockDecoration, value: decoration, range: fullRange)
            if dimmed { dim(fullRange, in: storage) }
            return

        case .codeLine, .indentedCode:
            scanInlines = false
            let region = line.codeRegion.map { doc.codeRegions[$0] }
            let isFirst = region?.openFenceLine == nil && region?.lineRange.lowerBound == index
            let isLast = region?.closeFenceLine == nil && region?.lineRange.upperBound == index + 1
            decoration.codeBlock = CodeBlockDecoration(isFirst: isFirst,
                                                       isLast: isLast,
                                                       language: region?.language)
            attributes[.font] = theme.mono
            attributes[.foregroundColor] = theme.codeText
            paragraph.lineHeightMultiple = 1.25
            paragraph.firstLineHeadIndent = quoteInset + theme.codePadding
            paragraph.headIndent = quoteInset + theme.codePadding
            if isFirst { paragraph.paragraphSpacingBefore = theme.baseSize * 0.5 }
            if isLast { paragraph.paragraphSpacing = theme.baseSize * 0.5 }

        case .listItem(let marker, let markerRange, let checkbox):
            let contentX = quoteInset + theme.listMarkerColumn(depth: line.listDepth)
            paragraph.headIndent = contentX
            inlineRange = line.contentRange

            // Everything the marker occupies in the source: `- `, `1. `, `- [x] `.
            let rawMarker = checkbox.map {
                NSRange(location: markerRange.location,
                        length: min(NSMaxRange($0.range) + 1, NSMaxRange(line.range))
                            - markerRange.location)
            } ?? markerRange

            if checkbox?.checked == true {
                attributes[.foregroundColor] = theme.secondaryText
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = theme.faintText
            }

            if revealed {
                // The literal marker is on screen, so let it occupy the gutter
                // instead of drawing one on top of it — and keep the prose from
                // jumping sideways as the caret enters and leaves the line.
                let text = InlineScanner.string(chars, clamp(rawMarker, to: storage.length))
                let width = NSAttributedString(string: text, attributes: [.font: theme.body]).size().width
                paragraph.firstLineHeadIndent = max(quoteInset, contentX - width)
            } else {
                paragraph.firstLineHeadIndent = contentX
                concealRanges.append(rawMarker)

                var bulletText = ""
                if case .ordered(let number, let delimiter) = marker {
                    bulletText = "\(number)\(delimiter)"
                }
                decoration.bullet = BulletDecoration(text: bulletText,
                                                     contentX: contentX,
                                                     isOrdered: marker.isOrdered && checkbox == nil,
                                                     checkbox: checkbox != nil,
                                                     checked: checkbox?.checked ?? false,
                                                     depth: line.listDepth)
            }

        case .tableRow(let isDelimiter):
            // Editing view. The rendered table is gone while the caret is in
            // here, so the priority is seeing every character: the source wraps
            // rather than clipping, and sits in a tinted block like code does.
            scanInlines = false
            paragraph.lineHeightMultiple = 1.25
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.firstLineHeadIndent = quoteInset + theme.codePadding
            paragraph.headIndent = quoteInset + theme.codePadding * 2

            var sourceScale: CGFloat = 1
            if let regionIndex = line.tableRegion {
                let widths = columnWidths(regionIndex,
                                          region: doc.tableRegions[regionIndex],
                                          doc: doc,
                                          chars: chars)
                let natural = CGFloat(widths.reduce(0, +) + widths.count + 1) * context.monoAdvance
                // A little shrinking avoids wrapping on merely-slightly-wide
                // tables; past that, wrapping does the work.
                if natural > availableWidth {
                    sourceScale = max(0.8, availableWidth / natural)
                }
            }
            let sourceSize = round(theme.mono.pointSize * sourceScale)
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: sourceSize, weight: .regular)

            if let regionIndex = line.tableRegion {
                let region = doc.tableRegions[regionIndex]
                decoration.codeBlock = CodeBlockDecoration(
                    isFirst: index == region.lineRange.lowerBound,
                    isLast: index == region.lineRange.upperBound - 1,
                    language: nil)
                if index == region.headerLine {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: sourceSize,
                                                                    weight: .semibold)
                }
                if index == region.lineRange.lowerBound {
                    paragraph.paragraphSpacingBefore = theme.baseSize * 0.5
                }
                if index == region.lineRange.upperBound - 1 {
                    paragraph.paragraphSpacing = theme.baseSize * 0.5
                }
            }

            if isDelimiter, !revealed {
                concealRanges.append(line.range)
                paragraph.minimumLineHeight = 0.01
                paragraph.maximumLineHeight = 0.01
            }
            pendingTableAlignment = line.tableRegion.map { (line, $0, sourceScale) }
        }

        // Blockquote prefix.
        if let quoteMarker = line.quoteMarkerRange, !revealed {
            concealRanges.append(quoteMarker)
        }

        // Inline spans are scanned before the attributes are written, because a
        // line that holds nothing but an image becomes a block and needs its
        // paragraph height set first.
        var spans: [InlineSpan] = []
        if scanInlines, inlineRange.length > 0 {
            spans = InlineScanner.scan(chars,
                                       range: clamp(inlineRange, to: storage.length),
                                       definitions: doc.linkDefinitions)
        }
        if !revealed, let block = standaloneImageBlock(spans, line: line) {
            decoration.renderedBlock = block
            let height = block.size.height + theme.baseSize * 0.4
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.paragraphSpacingBefore = theme.baseSize * 0.4
            paragraph.paragraphSpacing = theme.baseSize * 0.4
            attributes[.paragraphStyle] = paragraph
            storage.setAttributes(attributes, range: fullRange)
            storage.addAttribute(.blockDecoration, value: decoration, range: fullRange)
            conceal(clamp(line.range, to: storage.length), in: storage)
            if dimmed { dim(fullRange, in: storage) }
            return
        }

        storage.setAttributes(attributes, range: fullRange)
        storage.addAttribute(.blockDecoration, value: decoration, range: fullRange)

        if !spans.isEmpty {
            applyInlineSpans(spans,
                             line: line,
                             chars: chars,
                             decoration: decoration,
                             storage: storage,
                             revealed: revealed,
                             conceal: &concealRanges)
        }

        // Faint pipes make table columns readable without stealing attention,
        // and kerning lines the columns up without touching the source text.
        if case .tableRow(let isDelimiter) = line.kind, !isDelimiter {
            styleTablePipes(line: line, chars: chars, storage: storage)
            if let (info, regionIndex, scale) = pendingTableAlignment {
                alignTableColumns(info,
                                  widths: columnWidths(regionIndex,
                                                       region: doc.tableRegions[regionIndex],
                                                       doc: doc,
                                                       chars: chars),
                                  advance: context.monoAdvance * scale,
                                  chars: chars,
                                  storage: storage)
            }
        }
        pendingTableAlignment = nil

        for range in concealRanges {
            conceal(clamp(range, to: storage.length), in: storage)
        }
        for (range, width) in pendingInlineKerns {
            storage.addAttribute(.kern, value: width, range: clamp(range, to: storage.length))
        }
        pendingInlineKerns.removeAll(keepingCapacity: true)

        if dimmed { dim(fullRange, in: storage) }
    }

    // MARK: - Inline spans

    private func applyInlineSpans(_ spans: [InlineSpan],
                                  line: LineInfo,
                                  chars: [unichar],
                                  decoration: BlockDecoration,
                                  storage: NSTextStorage,
                                  revealed: Bool,
                                  conceal concealRanges: inout [NSRange]) {
        for span in spans {
            let content = clamp(span.contentRange, to: storage.length)
            guard content.length >= 0 else { continue }

            switch span.kind {
            case .code:
                storage.addAttributes([
                    .font: theme.inlineCode,
                    .foregroundColor: theme.inlineCodeText,
                    .backgroundColor: theme.inlineCodeBackground,
                ], range: clamp(span.range, to: storage.length))

            case .strong:
                applyTrait(bold: true, italic: false, range: content, storage: storage)

            case .emphasis:
                applyTrait(bold: false, italic: true, range: content, storage: storage)

            case .strikethrough:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: theme.secondaryText,
                ], range: content)

            case .highlight:
                storage.addAttribute(.backgroundColor, value: theme.highlightBackground, range: content)

            case .link, .autolink:
                storage.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: theme.link.withAlphaComponent(0.4),
                    .cursor: NSCursor.pointingHand,
                ], range: content)
                if let destination = span.destination {
                    storage.addAttribute(.markdownLink, value: destination,
                                         range: clamp(span.range, to: storage.length))
                }

            case .image:
                storage.addAttributes([
                    .foregroundColor: theme.accent,
                    .font: theme.bodyItalic,
                ], range: content)
                if let destination = span.destination {
                    storage.addAttribute(.markdownLink, value: destination,
                                         range: clamp(span.range, to: storage.length))
                }
                if !revealed, let image = loadedImage(for: span) {
                    let size = fit(image.size,
                                   maxWidth: min(availableWidth, 320),
                                   maxHeight: theme.baseSize * 1.8)
                    addInlineRenderable(image: image, size: size, span: span,
                                        line: line, decoration: decoration, storage: storage)
                    concealRanges.append(span.range)
                    continue
                }

            case .math(let display):
                let source = InlineScanner.string(chars, span.contentRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                storage.addAttributes([
                    .font: theme.inlineCode,
                    .foregroundColor: theme.accent,
                ], range: content)
                guard !revealed, !source.isEmpty,
                      Preferences.shared.renderDiagrams, RenderService.isAvailable else { break }

                let request = renderRequest(source: source, kind: .math, display: display)
                let mathState = RenderService.shared.state(for: request)
                if case .pending = mathState { lastPassDeferred = true }
                if case .ready(let image) = mathState {
                    let size = fit(image.size,
                                   maxWidth: availableWidth,
                                   maxHeight: theme.baseSize * (display ? 3.2 : 2.2))
                    addInlineRenderable(image: image, size: size, span: span,
                                        line: line, decoration: decoration, storage: storage)
                    concealRanges.append(span.range)
                    continue
                }

            case .footnoteRef:
                storage.addAttributes([
                    .foregroundColor: theme.accent,
                    .baselineOffset: theme.baseSize * 0.28,
                    .font: NSFont.systemFont(ofSize: round(theme.baseSize * 0.7)),
                ], range: content)
            }

            if !revealed {
                concealRanges.append(contentsOf: span.markers)
            } else {
                for marker in span.markers {
                    storage.addAttribute(.foregroundColor, value: theme.marker,
                                         range: clamp(marker, to: storage.length))
                }
            }
        }
    }

    private func applyTrait(bold: Bool, italic: Bool, range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? theme.body
            let wasBold = current === theme.bodyBold || current === theme.bodyBoldItalic
            let wasItalic = current === theme.bodyItalic || current === theme.bodyBoldItalic
            let nowBold = bold || wasBold
            let nowItalic = italic || wasItalic

            // Headings already carry their own weight; only add a slant.
            if current.pointSize > theme.baseSize + 0.5 {
                if nowItalic {
                    let manager = NSFontManager.shared
                    storage.addAttribute(.font,
                                         value: manager.convert(current, toHaveTrait: .italicFontMask),
                                         range: subrange)
                }
                return
            }

            let font: NSFont
            switch (nowBold, nowItalic) {
            case (true, true): font = theme.bodyBoldItalic
            case (true, false): font = theme.bodyBold
            case (false, true): font = theme.bodyItalic
            case (false, false): font = theme.body
            }
            storage.addAttribute(.font, value: font, range: subrange)
        }
    }

    // MARK: - Rendered blocks

    /// Works out which math/Mermaid blocks currently show an image rather than
    /// their source, kicking off any renders that are missing.
    ///
    /// A block reverts to source while the caret is inside it — that is how you
    /// edit it — and while its render is still in flight, so nothing collapses
    /// to an empty box mid-render.
    private func prepareRenderedRegions(doc: ParsedDocument,
                                        chars: [unichar],
                                        lines: Range<Int>,
                                        caretLines: Set<Int>) {
        renderedRegions.removeAll(keepingCapacity: true)
        guard Preferences.shared.renderDiagrams, RenderService.isAvailable else { return }

        for (regionIndex, region) in doc.codeRegions.enumerated() {
            guard region.content != .code, region.lineRange.overlaps(lines) else { continue }
            guard !region.lineRange.contains(where: { caretLines.contains($0) }) else { continue }

            let contentLines = region.contentLineRange
            guard !contentLines.isEmpty else { continue }
            let sourceRange = doc.charRange(forLines: contentLines)
            let source = InlineScanner.string(chars, sourceRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }

            let request = renderRequest(source: source,
                                        kind: region.content == .mermaid ? .mermaid : .math,
                                        display: true)
            switch RenderService.shared.state(for: request) {
            case .ready(let image):
                renderedRegions[regionIndex] = RenderedBlock(image: image,
                                                             size: fit(image.size,
                                                                       maxWidth: availableWidth,
                                                                       maxHeight: 900),
                                                             centered: true,
                                                             message: nil)
            case .failed(let message):
                let text = "\(region.content == .mermaid ? "Diagram" : "Equation") error — \(message)"
                renderedRegions[regionIndex] = RenderedBlock(image: nil,
                                                             size: CGSize(width: availableWidth,
                                                                          height: theme.baseSize * 2.6),
                                                             centered: false,
                                                             message: text)
            case .pending:
                lastPassDeferred = true
                continue    // keep showing the source until the image arrives
            }
        }
    }

    struct TableCacheKey: Hashable {
        var region: Int
        var width: Int
        var fontSize: Int
    }

    /// Lays out any table the caret is not currently inside.
    ///
    /// With the caret in the table you get the pipe source, kern-aligned, which
    /// is what you want for editing. With it elsewhere the table is drawn
    /// properly: columns sized to the measure, cell text wrapped, rows as tall
    /// as their content. Monospace source can only ever be one line per row, so
    /// a wide table would otherwise run off the page.
    private func prepareRenderedTables(doc: ParsedDocument,
                                       chars: [unichar],
                                       lines: Range<Int>,
                                       revealed: Set<Int>,
                                       selection: NSRange) {
        // Deliberately *not* cleared here. The text view reads these later to
        // hit-test clicks and place the caret, and a partial restyle of unrelated
        // lines must not make a table on screen forget where its cells are.
        // `documentDidReparse` is what invalidates them.
        currentSelection = selection
        let width = availableWidth

        for (index, region) in doc.tableRegions.enumerated() {
            guard region.lineRange.overlaps(lines) else { continue }
            // Only `Show Markdown Source` drops a table back to pipes; the caret
            // being inside no longer does, because cells are editable in place.
            if region.lineRange.contains(where: { revealed.contains($0) }) {
                renderedTables.removeValue(forKey: index)
                continue
            }

            let key = TableCacheKey(region: index,
                                    width: Int(width / 8),
                                    fontSize: Int(theme.baseSize))
            if let cached = tableLayoutCache[key] {
                renderedTables[index] = cached
                continue
            }
            guard let table = TableLayoutEngine.layout(region: region,
                                                       doc: doc,
                                                       chars: chars,
                                                       theme: theme,
                                                       maxWidth: width) else { continue }
            tableLayoutCache[key] = table
            renderedTables[index] = table
        }
    }

    private func renderRequest(source: String, kind: RenderKind, display: Bool) -> RenderRequest {
        RenderRequest(kind: kind,
                      source: source,
                      display: display,
                      fontSize: theme.baseSize,
                      maxWidth: availableWidth,
                      isDark: context.isDark,
                      colorHex: context.textColorHex,
                      backgroundHex: kind == .mermaid
                        ? context.codeBackgroundHex
                        : context.backgroundHex)
    }

    /// Line ranges of every block that renders to an image, wherever it sits in
    /// the document — used to repaint precisely when a render lands off-screen.
    nonisolated static func renderableLineRanges(in doc: ParsedDocument) -> [Range<Int>] {
        doc.codeRegions.filter { $0.content != .code }.map(\.lineRange)
    }

    private var availableWidth: CGFloat {
        max(240, context.containerWidth - theme.codePadding * 2)
    }

    private func fit(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var scale = min(1, maxWidth / size.width)
        scale = min(scale, maxHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    /// Reserves horizontal room for an inline image or equation by kerning the
    /// concealed source, then records where the fragment should draw it.
    private func addInlineRenderable(image: NSImage?,
                                     size: CGSize,
                                     span: InlineSpan,
                                     line: LineInfo,
                                     decoration: BlockDecoration,
                                     storage: NSTextStorage) {
        let anchor = NSMaxRange(span.range) - 1
        guard anchor >= span.range.location else { return }
        // Concealment clears kern, so the reservation is queued and applied last.
        pendingInlineKerns.append((NSRange(location: anchor, length: 1), size.width))
        decoration.inlineRenderables.append(
            InlineRenderable(characterIndex: span.range.location - line.fullRange.location,
                             image: image,
                             size: size))
    }

    /// A line whose only content is one image becomes a block-level picture.
    private func standaloneImageBlock(_ spans: [InlineSpan], line: LineInfo) -> RenderedBlock? {
        let images = spans.filter { if case .image = $0.kind { return true }; return false }
        guard images.count == 1, let span = images[0] as InlineSpan? else { return nil }
        guard span.range.location <= line.contentRange.location,
              NSMaxRange(span.range) >= NSMaxRange(line.contentRange) else { return nil }
        guard let image = loadedImage(for: span) else { return nil }
        return RenderedBlock(image: image,
                             size: fit(image.size, maxWidth: availableWidth, maxHeight: 640),
                             centered: false,
                             message: nil)
    }

    private func loadedImage(for span: InlineSpan) -> NSImage? {
        guard case .image = span.kind, let destination = span.destination else { return nil }
        guard let url = ImageLoader.shared.resolve(destination,
                                                   relativeTo: context.documentDirectory)
        else { return nil }
        let image = ImageLoader.shared.image(for: url)
        if image == nil, !ImageLoader.shared.hasFailed(url) { lastPassDeferred = true }
        return image
    }

    // MARK: - Tables

    private func styleTablePipes(line: LineInfo, chars: [unichar], storage: NSTextStorage) {
        var i = line.range.location
        let end = NSMaxRange(line.range)
        while i < end {
            if chars[i] == 0x7C, i == line.range.location || chars[i - 1] != 0x5C {
                storage.addAttribute(.foregroundColor, value: theme.tableBorder,
                                     range: clamp(NSRange(location: i, length: 1), to: storage.length))
            }
            i += 1
        }
    }

    /// Widest cell per column, measured in characters. The delimiter row is
    /// excluded because it is concealed and its dashes are padding, not content.
    private func columnWidths(_ index: Int, region: TableRegion, doc: ParsedDocument,
                              chars: [unichar]) -> [Int] {
        if let cached = tableColumnWidths[index] { return cached }
        var widths = [Int](repeating: 3, count: region.columnCount)
        for lineIndex in region.lineRange where lineIndex != region.delimiterLine {
            guard lineIndex < doc.lines.count else { continue }
            let cells = MarkdownParser.splitCells(chars, doc.lines[lineIndex].contentRange)
            for (column, cell) in cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], cell.length)
            }
        }
        tableColumnWidths[index] = widths
        return widths
    }

    /// Pads each cell out to its column width using kerning on the character
    /// before the closing pipe, so columns line up without editing the file.
    private func alignTableColumns(_ line: LineInfo,
                                   widths: [Int],
                                   advance: CGFloat,
                                   chars: [unichar],
                                   storage: NSTextStorage) {
        let cells = MarkdownParser.splitCells(chars, line.contentRange)
        let rowEnd = NSMaxRange(line.contentRange)

        for (column, cell) in cells.enumerated() where column < widths.count {
            let closingPipe = NSMaxRange(cell)
            // Only pad cells that are actually closed by a pipe.
            guard closingPipe < rowEnd, closingPipe < chars.count,
                  chars[closingPipe] == 0x7C else { continue }
            let deficit = CGFloat(widths[column] - cell.length) * advance
            guard deficit > 0.05 else { continue }

            // Anchor on the last character inside the cell; for an empty cell
            // that is the preceding pipe, which is never another cell's anchor.
            let anchor = closingPipe - 1
            guard anchor >= line.contentRange.location else { continue }
            storage.addAttribute(.kern, value: deficit,
                                 range: clamp(NSRange(location: anchor, length: 1),
                                              to: storage.length))
        }
    }

    // MARK: - Code highlighting

    private func highlightCode(_ region: CodeRegion,
                               doc: ParsedDocument,
                               chars: [unichar],
                               storage: NSTextStorage) {
        guard let language = region.language else { return }

        let contentLower = region.openFenceLine.map { $0 + 1 } ?? region.lineRange.lowerBound
        let contentUpper = region.closeFenceLine ?? region.lineRange.upperBound
        guard contentLower < contentUpper else { return }

        let range = clamp(doc.charRange(forLines: contentLower..<contentUpper), to: storage.length)
        guard range.length > 0 else { return }

        for (tokenRange, token) in SyntaxHighlighter.tokens(chars, range: range, language: language) {
            let color: NSColor
            var font: NSFont?
            switch token {
            case .keyword: color = theme.synKeyword
            case .type: color = theme.synType
            case .string: color = theme.synString
            case .comment: color = theme.synComment
            case .number: color = theme.synNumber
            case .function: color = theme.synFunction
            case .punctuation: color = theme.synPunctuation
            case .added: color = theme.synAdded
            case .removed: color = theme.synRemoved
            case .meta: color = theme.synComment; font = theme.monoBold
            }
            let clamped = clamp(tokenRange, to: storage.length)
            guard clamped.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: clamped)
            if let font { storage.addAttribute(.font, value: font, range: clamped) }
        }
    }

    // MARK: - Concealment & dimming

    /// Hides characters without removing them.
    ///
    /// `asMarker` is false for a drawn table: its text is hidden so the drawing
    /// can stand in for it, but it is still real content the caret moves
    /// through, not syntax to be skipped over.
    private func conceal(_ range: NSRange, in storage: NSTextStorage, asMarker: Bool = true) {
        guard range.length > 0 else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: theme.concealed,
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
            .kern: 0,
        ]
        if asMarker { attributes[.concealedMarker] = true }
        storage.addAttributes(attributes, range: range)
    }

    private func dim(_ range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
            guard let color = value as? NSColor, color != .clear else { return }
            storage.addAttribute(.foregroundColor,
                                 value: color.withAlphaComponent(0.32),
                                 range: subrange)
        }
    }

    // MARK: - Utilities

    private func fenceCharRange(_ chars: [unichar], line: LineInfo) -> NSRange {
        var i = line.range.location + line.indent
        let end = NSMaxRange(line.range)
        let start = i
        while i < end, chars[i] == 0x60 || chars[i] == 0x7E { i += 1 }
        // Consume the space between the fence and the info string, if any.
        while i < end, chars[i] == 0x20 { i += 1 }
        return NSRange(location: start, length: i - start)
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }

    private static func advance(of font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: "0", attributes: [.font: font])
        return attributed.size().width
    }
}
