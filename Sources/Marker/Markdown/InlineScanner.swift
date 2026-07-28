import Foundation

struct InlineSpan {
    enum Kind {
        case code
        case strong
        case emphasis
        case strikethrough
        case highlight
        case link
        case image
        case autolink
        case footnoteRef
        /// `$x^2$` or `$$x^2$$` inside a paragraph.
        case math(display: Bool)
    }

    var kind: Kind
    /// Full extent including delimiters.
    var range: NSRange
    /// The part that stays visible when markers are concealed.
    var contentRange: NSRange
    /// Delimiter ranges to conceal.
    var markers: [NSRange]
    var destination: String?
}

/// Scans a single line for inline Markdown constructs.
///
/// Runs only over lines the styler is about to draw, so a straightforward
/// left-to-right scan with a delimiter stack is plenty fast.
enum InlineScanner {

    static func scan(_ chars: [unichar],
                     range: NSRange,
                     definitions: [String: String] = [:]) -> [InlineSpan] {
        guard range.length > 0 else { return [] }
        var spans: [InlineSpan] = []
        let start = range.location
        let end = NSMaxRange(range)

        // Regions that suppress further parsing (code spans, link destinations).
        var protectedRanges: [NSRange] = []

        // --- code spans --------------------------------------------------------
        var i = start
        while i < end {
            guard chars[i] == 0x60, !isEscaped(chars, i, start) else { i += 1; continue }
            var openCount = 0
            var j = i
            while j < end, chars[j] == 0x60 { openCount += 1; j += 1 }

            var k = j
            var closeStart = -1
            while k < end {
                if chars[k] == 0x60 {
                    var closeCount = 0
                    var m = k
                    while m < end, chars[m] == 0x60 { closeCount += 1; m += 1 }
                    if closeCount == openCount { closeStart = k; k = m; break }
                    k = m
                } else {
                    k += 1
                }
            }

            if closeStart >= 0 {
                let full = NSRange(location: i, length: k - i)
                spans.append(InlineSpan(
                    kind: .code,
                    range: full,
                    contentRange: NSRange(location: j, length: closeStart - j),
                    markers: [NSRange(location: i, length: openCount),
                              NSRange(location: closeStart, length: openCount)],
                    destination: nil))
                protectedRanges.append(full)
                i = k
            } else {
                i = j
            }
        }

        // --- inline math -------------------------------------------------------
        i = start
        while i < end {
            guard chars[i] == 0x24, !isEscaped(chars, i, start),
                  !isProtected(i, protectedRanges) else { i += 1; continue }

            var openCount = 0
            var j = i
            while j < end, chars[j] == 0x24, openCount < 2 { openCount += 1; j += 1 }
            // `$ x$` is a dollar sign, not math.
            guard j < end, !isWhitespace(chars[j]) else { i = j; continue }

            var k = j
            var closeStart = -1
            while k < end {
                if chars[k] == 0x5C { k += 2; continue }
                if chars[k] == 0x24, !isWhitespace(chars[k - 1]) {
                    var closeCount = 0
                    var m = k
                    while m < end, chars[m] == 0x24 { closeCount += 1; m += 1 }
                    if closeCount >= openCount {
                        // A trailing digit means this was currency: `$5 and $10`.
                        let after = k + openCount
                        if after < end, chars[after] >= 0x30, chars[after] <= 0x39 { break }
                        closeStart = k
                        break
                    }
                    k = m
                    continue
                }
                k += 1
            }

            guard closeStart > j else { i = j; continue }
            let full = NSRange(location: i, length: closeStart + openCount - i)
            spans.append(InlineSpan(
                kind: .math(display: openCount == 2),
                range: full,
                contentRange: NSRange(location: j, length: closeStart - j),
                markers: [NSRange(location: i, length: openCount),
                          NSRange(location: closeStart, length: openCount)],
                destination: nil))
            protectedRanges.append(full)
            i = NSMaxRange(full)
        }

        // --- links, images, autolinks -----------------------------------------
        i = start
        while i < end {
            if isProtected(i, protectedRanges) { i += 1; continue }

            // <https://example.com>
            if chars[i] == 0x3C, !isEscaped(chars, i, start) {
                if let span = scanAngleAutolink(chars, from: i, to: end) {
                    spans.append(span)
                    protectedRanges.append(span.range)
                    i = NSMaxRange(span.range)
                    continue
                }
            }

            let isImage = chars[i] == 0x21 && i + 1 < end && chars[i + 1] == 0x5B
            if chars[i] == 0x5B || isImage, !isEscaped(chars, i, start) {
                let bracketOpen = isImage ? i + 1 : i

                // [^1] footnote reference
                if !isImage, bracketOpen + 1 < end, chars[bracketOpen + 1] == 0x5E,
                   let close = findClosingBracket(chars, from: bracketOpen, to: end) {
                    let full = NSRange(location: i, length: close + 1 - i)
                    spans.append(InlineSpan(
                        kind: .footnoteRef,
                        range: full,
                        contentRange: NSRange(location: bracketOpen + 2, length: close - bracketOpen - 2),
                        markers: [NSRange(location: bracketOpen, length: 2),
                                  NSRange(location: close, length: 1)],
                        destination: nil))
                    protectedRanges.append(full)
                    i = close + 1
                    continue
                }

                if let close = findClosingBracket(chars, from: bracketOpen, to: end) {
                    let textRange = NSRange(location: bracketOpen + 1,
                                            length: close - bracketOpen - 1)

                    // Inline form: [text](destination)
                    if close + 1 < end, chars[close + 1] == 0x28,
                       let paren = findClosingParen(chars, from: close + 1, to: end) {
                        let full = NSRange(location: i, length: paren + 1 - i)
                        let dest = destinationString(
                            chars, NSRange(location: close + 2, length: paren - close - 2))
                        spans.append(InlineSpan(
                            kind: isImage ? .image : .link,
                            range: full,
                            contentRange: textRange,
                            markers: [NSRange(location: i, length: bracketOpen + 1 - i),
                                      NSRange(location: close, length: paren + 1 - close)],
                            destination: dest))
                        protectedRanges.append(full)
                        i = paren + 1
                        continue
                    }

                    // Reference forms: [text][label], [text][] and the [label] shortcut.
                    if !definitions.isEmpty {
                        var labelRange = textRange
                        var spanEnd = close + 1
                        var isCollapsed = true

                        if close + 1 < end, chars[close + 1] == 0x5B,
                           let secondClose = findClosingBracket(chars, from: close + 1, to: end) {
                            spanEnd = secondClose + 1
                            if secondClose > close + 2 {
                                labelRange = NSRange(location: close + 2,
                                                     length: secondClose - close - 2)
                                isCollapsed = false
                            }
                        }

                        let key = string(chars, labelRange)
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if let destination = definitions[key] {
                            let full = NSRange(location: i, length: spanEnd - i)
                            var markers = [NSRange(location: i, length: bracketOpen + 1 - i)]
                            markers.append(NSRange(location: close, length: spanEnd - close))
                            _ = isCollapsed
                            spans.append(InlineSpan(
                                kind: isImage ? .image : .link,
                                range: full,
                                contentRange: textRange,
                                markers: markers,
                                destination: destination))
                            protectedRanges.append(full)
                            i = spanEnd
                            continue
                        }
                    }
                }
            }

            // Bare www./http(s) autolink.
            if chars[i] == 0x68 || chars[i] == 0x77, i == start || !isURLChar(chars[i - 1]) {
                if let span = scanBareAutolink(chars, from: i, to: end) {
                    spans.append(span)
                    protectedRanges.append(span.range)
                    i = NSMaxRange(span.range)
                    continue
                }
            }

            i += 1
        }

        // --- emphasis, strong, strikethrough, highlight ------------------------
        spans.append(contentsOf: scanDelimiters(chars, start: start, end: end,
                                                protectedRanges: protectedRanges))
        return spans
    }

    // MARK: - Delimiter runs

    private struct Delimiter {
        var char: unichar
        var location: Int
        var count: Int
        var canOpen: Bool
        var canClose: Bool
        var active: Bool = true
    }

    private static func scanDelimiters(_ chars: [unichar], start: Int, end: Int,
                                       protectedRanges: [NSRange]) -> [InlineSpan] {
        var runs: [Delimiter] = []
        var i = start

        while i < end {
            if isProtected(i, protectedRanges) { i += 1; continue }
            let c = chars[i]
            guard c == 0x2A || c == 0x5F || c == 0x7E || c == 0x3D else { i += 1; continue } // * _ ~ =
            guard !isEscaped(chars, i, start) else { i += 1; continue }

            var count = 0
            var j = i
            while j < end, chars[j] == c { count += 1; j += 1 }

            let before: unichar? = i > start ? chars[i - 1] : nil
            let after: unichar? = j < end ? chars[j] : nil

            let beforeWhitespace = before.map(isWhitespace) ?? true
            let afterWhitespace = after.map(isWhitespace) ?? true
            let beforePunct = before.map(isPunctuation) ?? false
            let afterPunct = after.map(isPunctuation) ?? false

            let leftFlanking = !afterWhitespace && (!afterPunct || beforeWhitespace || beforePunct)
            let rightFlanking = !beforeWhitespace && (!beforePunct || afterWhitespace || afterPunct)

            var canOpen = leftFlanking
            var canClose = rightFlanking
            if c == 0x5F { // intraword underscores are literal
                canOpen = leftFlanking && (!rightFlanking || beforePunct)
                canClose = rightFlanking && (!leftFlanking || afterPunct)
            }
            if c == 0x7E || c == 0x3D { // ~~ and == only pair as doubles
                guard count >= 2 else { i = j; continue }
                canOpen = leftFlanking
                canClose = rightFlanking
            }

            runs.append(Delimiter(char: c, location: i, count: count,
                                  canOpen: canOpen, canClose: canClose))
            i = j
        }

        var spans: [InlineSpan] = []
        var openers: [Int] = []

        for index in runs.indices {
            guard runs[index].active else { continue }

            if runs[index].canClose {
                var matchedAny = false
                // Keep pairing until this run is used up: `***both***` matches as
                // strong first, then the leftover single delimiters as emphasis.
                var keepMatching = true
                while keepMatching, runs[index].count > 0 {
                    keepMatching = false
                    var search = openers.count - 1
                    while search >= 0 {
                        let openerIndex = openers[search]
                        guard runs[openerIndex].active,
                              runs[openerIndex].char == runs[index].char,
                              runs[openerIndex].canOpen,
                              openerIndex < index else { search -= 1; continue }

                        let isDouble = runs[index].char == 0x7E || runs[index].char == 0x3D
                        let use = isDouble
                            ? 2
                            : min(2, min(runs[openerIndex].count, runs[index].count))
                        guard runs[openerIndex].count >= use, runs[index].count >= use else {
                            search -= 1; continue
                        }

                        let openEnd = runs[openerIndex].location + runs[openerIndex].count
                        let openMarker = NSRange(location: openEnd - use, length: use)
                        let closeMarker = NSRange(location: runs[index].location, length: use)
                        let contentStart = NSMaxRange(openMarker)
                        let contentLength = closeMarker.location - contentStart
                        guard contentLength > 0 else { search -= 1; continue }

                        let kind: InlineSpan.Kind
                        switch runs[index].char {
                        case 0x7E: kind = .strikethrough
                        case 0x3D: kind = .highlight
                        default: kind = use >= 2 ? .strong : .emphasis
                        }

                        spans.append(InlineSpan(
                            kind: kind,
                            range: NSRange(location: openMarker.location,
                                           length: NSMaxRange(closeMarker) - openMarker.location),
                            contentRange: NSRange(location: contentStart, length: contentLength),
                            markers: [openMarker, closeMarker],
                            destination: nil))

                        // The opener is consumed from its right edge, the closer
                        // from its left, so the closer's start has to move too.
                        runs[openerIndex].count -= use
                        runs[index].count -= use
                        runs[index].location += use

                        // Delimiters nested between the pair can no longer match out.
                        openers.removeAll { $0 > openerIndex }
                        if runs[openerIndex].count == 0 {
                            runs[openerIndex].active = false
                            openers.removeAll { $0 == openerIndex }
                        }
                        matchedAny = true
                        keepMatching = true
                        break
                    }
                }
                if runs[index].count == 0 { runs[index].active = false }
                if matchedAny {
                    if runs[index].count > 0, runs[index].canOpen { openers.append(index) }
                    continue
                }
            }

            if runs[index].canOpen, runs[index].count > 0 {
                openers.append(index)
            }
        }

        return spans
    }

    // MARK: - Autolinks

    private static func scanAngleAutolink(_ chars: [unichar], from: Int, to: Int) -> InlineSpan? {
        var j = from + 1
        var sawColon = false
        while j < to, chars[j] != 0x3E {
            if isWhitespace(chars[j]) { return nil }
            if chars[j] == 0x3A { sawColon = true }
            if chars[j] == 0x40 { sawColon = true } // mailto-style
            j += 1
        }
        guard j < to, sawColon, j > from + 1 else { return nil }
        let content = NSRange(location: from + 1, length: j - from - 1)
        return InlineSpan(kind: .autolink,
                          range: NSRange(location: from, length: j + 1 - from),
                          contentRange: content,
                          markers: [NSRange(location: from, length: 1),
                                    NSRange(location: j, length: 1)],
                          destination: string(chars, content))
    }

    private static func scanBareAutolink(_ chars: [unichar], from: Int, to: Int) -> InlineSpan? {
        let prefixes = ["https://", "http://", "www."]
        var matchedPrefix: String?
        for prefix in prefixes where matches(chars, at: from, to: to, string: prefix) {
            matchedPrefix = prefix
            break
        }
        guard let prefix = matchedPrefix else { return nil }

        var j = from + prefix.count
        while j < to, isURLChar(chars[j]) { j += 1 }
        // Trailing punctuation usually belongs to the sentence, not the URL.
        while j > from, let last = Optional(chars[j - 1]),
              last == 0x2E || last == 0x2C || last == 0x3A || last == 0x3B ||
              last == 0x21 || last == 0x3F || last == 0x29 {
            j -= 1
        }
        guard j > from + prefix.count else { return nil }

        let range = NSRange(location: from, length: j - from)
        var dest = string(chars, range)
        if prefix == "www." { dest = "https://" + dest }
        return InlineSpan(kind: .autolink,
                          range: range,
                          contentRange: range,
                          markers: [],
                          destination: dest)
    }

    // MARK: - Helpers

    private static func findClosingBracket(_ chars: [unichar], from: Int, to: Int) -> Int? {
        var depth = 0
        var i = from
        while i < to {
            if chars[i] == 0x5C { i += 2; continue }
            if chars[i] == 0x5B { depth += 1 }
            if chars[i] == 0x5D {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findClosingParen(_ chars: [unichar], from: Int, to: Int) -> Int? {
        var depth = 0
        var i = from
        while i < to {
            if chars[i] == 0x5C { i += 2; continue }
            if chars[i] == 0x28 { depth += 1 }
            if chars[i] == 0x29 {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func destinationString(_ chars: [unichar], _ range: NSRange) -> String {
        var text = string(chars, range).trimmingCharacters(in: .whitespaces)
        // Strip an optional link title: (url "title")
        if let quote = text.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
            text = String(text[text.startIndex..<quote]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("<"), text.hasSuffix(">"), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    static func string(_ chars: [unichar], _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var buffer = [unichar]()
        buffer.reserveCapacity(range.length)
        for i in range.location..<NSMaxRange(range) where i < chars.count {
            buffer.append(chars[i])
        }
        return String(utf16CodeUnits: buffer, count: buffer.count)
    }

    private static func matches(_ chars: [unichar], at index: Int, to: Int, string: String) -> Bool {
        let units = Array(string.utf16)
        guard index + units.count <= to else { return false }
        for (offset, unit) in units.enumerated() where chars[index + offset] != unit {
            return false
        }
        return true
    }

    private static func isEscaped(_ chars: [unichar], _ index: Int, _ start: Int) -> Bool {
        var backslashes = 0
        var i = index - 1
        while i >= start, chars[i] == 0x5C { backslashes += 1; i -= 1 }
        return backslashes % 2 == 1
    }

    private static func isProtected(_ index: Int, _ ranges: [NSRange]) -> Bool {
        for range in ranges where NSLocationInRange(index, range) { return true }
        return false
    }

    static func isWhitespaceCharacter(_ c: unichar) -> Bool { isWhitespace(c) }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isPunctuation(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static func isURLChar(_ c: unichar) -> Bool {
        if c <= 0x20 { return false }
        switch c {
        case 0x3C, 0x3E, 0x22, 0x60, 0x7B, 0x7D, 0x5B, 0x5D, 0x7C, 0x5C: return false
        default: return true
        }
    }
}
