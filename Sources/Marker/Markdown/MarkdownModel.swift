import Foundation

// MARK: - List markers

enum ListMarkerKind: Equatable {
    case bullet(Character)
    case ordered(number: Int, delimiter: Character)

    var isOrdered: Bool {
        if case .ordered = self { return true }
        return false
    }
}

struct CheckboxInfo: Equatable {
    /// Range of the whole `[ ]` / `[x]` token.
    var range: NSRange
    var checked: Bool
}

// MARK: - Table alignment

enum TableAlignment: Equatable {
    case none, left, center, right
}

// MARK: - Line classification

enum LineKind: Equatable {
    case blank
    case paragraph

    /// `## Heading`
    case heading(level: Int, markerRange: NSRange, contentRange: NSRange, trailingHashes: NSRange?)

    /// `====` / `----` underline beneath a paragraph.
    case setextUnderline(level: Int)

    /// `***`, `---`, `___`
    case thematicBreak

    /// Opening fence of a fenced code block.
    case fenceOpen(language: String?, fenceRange: NSRange)

    /// Closing fence of a fenced code block.
    case fenceClose(fenceRange: NSRange)

    /// A line living inside a fenced code block.
    case codeLine

    /// A line indented by 4+ spaces forming an indented code block.
    case indentedCode

    /// `- item`, `1. item`, `- [ ] task`
    case listItem(marker: ListMarkerKind, markerRange: NSRange, checkbox: CheckboxInfo?)

    /// A row of a GFM pipe table.
    case tableRow(isDelimiter: Bool)

    /// `$$` opening or closing a display-math block.
    case mathFence(open: Bool)

    /// `[label]: https://example.com "Title"`
    case linkDefinition(labelRange: NSRange, destinationRange: NSRange)
}

extension LineKind {
    /// A cheap discriminator used to diff two parses and decide how much to restyle.
    var signature: Int {
        var hasher = Hasher()
        switch self {
        case .blank: hasher.combine(0)
        case .paragraph: hasher.combine(1)
        case .heading(let level, let m, _, _):
            hasher.combine(2); hasher.combine(level); hasher.combine(m.length)
        case .setextUnderline(let level): hasher.combine(3); hasher.combine(level)
        case .thematicBreak: hasher.combine(4)
        case .fenceOpen(let lang, _): hasher.combine(5); hasher.combine(lang ?? "")
        case .fenceClose: hasher.combine(6)
        case .codeLine: hasher.combine(7)
        case .indentedCode: hasher.combine(8)
        case .listItem(let marker, let m, let cb):
            hasher.combine(9)
            hasher.combine(marker.isOrdered)
            hasher.combine(m.length)
            hasher.combine(cb?.checked)
        case .tableRow(let isDelimiter): hasher.combine(10); hasher.combine(isDelimiter)
        case .mathFence(let open): hasher.combine(11); hasher.combine(open)
        case .linkDefinition(let label, _): hasher.combine(12); hasher.combine(label.length)
        }
        return hasher.finalize()
    }

    var isCodeish: Bool {
        switch self {
        case .codeLine, .indentedCode, .fenceOpen, .fenceClose, .mathFence: return true
        default: return false
        }
    }
}

// MARK: - Line

struct LineInfo {
    var index: Int
    /// Range of the line's characters, excluding the trailing newline.
    var range: NSRange
    /// Range including the trailing newline (if any).
    var fullRange: NSRange

    /// Number of `>` levels this line sits inside.
    var quoteDepth: Int
    /// Range covering the whole `> > ` prefix, if present.
    var quoteMarkerRange: NSRange?

    /// Character offset where content begins (after quote prefix).
    var bodyStart: Int
    /// Leading-space count measured from `bodyStart`.
    var indent: Int
    /// Nesting depth for list items (0 for top level).
    var listDepth: Int

    var kind: LineKind

    /// Range of the actual prose on this line, after every marker.
    var contentRange: NSRange

    /// Index into `ParsedDocument.codeRegions`, if this line is inside one.
    var codeRegion: Int?
    /// Index into `ParsedDocument.tableRegions`, if this line is inside one.
    var tableRegion: Int?
}

// MARK: - Regions

struct CodeRegion {
    /// What the block's contents actually are, which decides how it renders.
    enum Content: Equatable {
        case code
        case math
        case mermaid
    }

    var lineRange: Range<Int>
    var charRange: NSRange
    var language: String?
    var fenced: Bool
    var openFenceLine: Int?
    var closeFenceLine: Int?
    var content: Content = .code

    /// Lines holding the block's body, excluding any fence lines.
    var contentLineRange: Range<Int> {
        let lower = openFenceLine.map { $0 + 1 } ?? lineRange.lowerBound
        let upper = closeFenceLine ?? lineRange.upperBound
        return lower..<max(lower, upper)
    }

    static func content(for language: String?) -> Content {
        switch language?.lowercased() {
        case "mermaid": return .mermaid
        case "math", "latex", "tex", "katex": return .math
        default: return .code
        }
    }
}

enum CodeBlockText {
    /// Returns the visible body of a code block without fence lines or quote
    /// prefixes, while preserving the document's line-ending style internally.
    static func body(of region: CodeRegion,
                     in document: ParsedDocument,
                     source: NSString) -> String {
        let lines = region.contentLineRange
        guard !lines.isEmpty,
              lines.lowerBound >= 0,
              lines.upperBound <= document.lines.count else { return "" }

        var result = ""
        for index in lines {
            let line = document.lines[index]
            guard NSMaxRange(line.contentRange) <= source.length else { return "" }
            result += source.substring(with: line.contentRange)
            if index < lines.upperBound - 1 {
                let separator = NSRange(location: NSMaxRange(line.range),
                                        length: NSMaxRange(line.fullRange)
                                            - NSMaxRange(line.range))
                guard NSMaxRange(separator) <= source.length else { return "" }
                result += source.substring(with: separator)
            }
        }
        return result
    }
}

struct TableRegion {
    var lineRange: Range<Int>
    var charRange: NSRange
    var headerLine: Int
    var delimiterLine: Int
    var alignments: [TableAlignment]
    var columnCount: Int
}

// MARK: - Parsed document

struct ParsedDocument {
    var lines: [LineInfo] = []
    var codeRegions: [CodeRegion] = []
    var tableRegions: [TableRegion] = []
    /// Per-line signature, used to find where two parses diverge.
    var signatures: [Int] = []
    /// Reference-link definitions, keyed by lowercased label.
    var linkDefinitions: [String: String] = [:]
    var length: Int = 0

    static let empty = ParsedDocument()

    /// Index of the line containing `location`. Clamped to the valid range.
    func lineIndex(at location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high) / 2
            let line = lines[mid]
            if location < line.fullRange.location {
                high = mid - 1
                if high < low { return low }
            } else if location >= NSMaxRange(line.fullRange) {
                low = mid + 1
            } else {
                return mid
            }
        }
        return min(max(low, 0), lines.count - 1)
    }

    /// Every line index intersecting `range`.
    func lineIndices(intersecting range: NSRange) -> Range<Int> {
        guard !lines.isEmpty else { return 0..<0 }
        let first = lineIndex(at: range.location)
        let last = lineIndex(at: max(range.location, NSMaxRange(range) - (range.length > 0 ? 1 : 0)))
        return first..<min(last + 1, lines.count)
    }

    /// Character range spanning a run of lines.
    func charRange(forLines lineRange: Range<Int>) -> NSRange {
        guard !lines.isEmpty, !lineRange.isEmpty else { return NSRange(location: 0, length: 0) }
        let lo = min(max(lineRange.lowerBound, 0), lines.count - 1)
        let hi = min(max(lineRange.upperBound - 1, 0), lines.count - 1)
        let start = lines[lo].fullRange.location
        let end = NSMaxRange(lines[hi].fullRange)
        return NSRange(location: start, length: max(0, end - start))
    }
}
