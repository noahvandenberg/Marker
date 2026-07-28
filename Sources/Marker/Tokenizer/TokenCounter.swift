import Foundation

/// Counts tokens the way an LLM tokenizer does, using real byte-pair encoding
/// against OpenAI's `o200k_base` vocabulary.
///
/// This is a port of tiktoken's merge loop, so the number is exact for models
/// that use that vocabulary (GPT-4o, GPT-5). Other families — Claude included —
/// use vocabularies that aren't published, so for those it is a close estimate
/// rather than an exact figure.
///
/// Counting runs on a background queue: loading the vocabulary parses ~200k
/// entries, and encoding a large document is real work that must never sit on
/// the main thread.
final class TokenCounter {

    static let shared = TokenCounter()

    private let queue = DispatchQueue(label: "com.noahvandenberg.Marker.tokens",
                                      qos: .utility)
    /// Token bytes → merge rank.
    private var ranks: [Data: Int]?
    private var vocabularyUnavailable = false
    /// Whole pretokens seen before. Prose repeats itself heavily, so this turns
    /// most of a document into dictionary hits.
    ///
    /// Keyed by raw UTF-8, never by `String`: Swift string equality is Unicode
    /// canonical equivalence, so a precomposed "é" and a decomposed "e" + combining
    /// acute hash the same — while encoding to a different number of tokens.
    private var pretokenCache: [Data: Int] = [:]
    /// Supersedes in-flight work when the document changes again.
    private var generation = 0

    private let splitter: NSRegularExpression? = {
        // tiktoken's o200k_base pretokenizer.
        let pattern = [
            #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
            #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
            #"\p{N}{1,3}"#,
            #" ?[^\s\p{L}\p{N}]+[\r\n/]*"#,
            #"\s*[\r\n]+"#,
            #"\s+(?!\S)"#,
            #"\s+"#,
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern)
    }()

    private init() {}

    /// Whether a token count can be produced at all.
    var isAvailable: Bool { splitter != nil && !vocabularyUnavailable }

    /// Counts asynchronously, reporting on the main queue.
    ///
    /// Only the most recent request reports back; earlier ones are abandoned.
    func count(_ text: String, completion: @escaping (Int?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            let mine = self.generation
            let result = self.countSynchronously(text) { self.generation != mine }
            guard self.generation == mine else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Counts on the calling thread. Never call this from the main thread on a
    /// document of any size — it exists for the async path above and for tests.
    func countNow(_ text: String) -> Int? {
        queue.sync { countSynchronously(text) { false } }
    }

    // MARK: - Encoding

    /// - Parameter isCancelled: polled between pretokens so a superseded count
    ///   on a large document stops early instead of burning a core.
    private func countSynchronously(_ text: String, isCancelled: () -> Bool) -> Int? {
        guard let splitter, let ranks = loadVocabulary() else { return nil }
        guard !text.isEmpty else { return 0 }

        let string = text as NSString
        var total = 0
        var checked = 0
        var cancelled = false

        splitter.enumerateMatches(in: text,
                                  range: NSRange(location: 0, length: string.length)) {
            match, _, stop in
            guard let match else { return }
            checked += 1
            if checked % 512 == 0, isCancelled() {
                cancelled = true
                stop.pointee = true
                return
            }
            let bytes = Array(string.substring(with: match.range).utf8)
            let key = Data(bytes)
            if let cached = self.pretokenCache[key] {
                total += cached
                return
            }
            let count = TokenCounter.tokenCount(for: bytes, ranks: ranks)
            // Cap the cache so a pathological document can't grow it without end.
            if self.pretokenCache.count < 200_000 { self.pretokenCache[key] = count }
            total += count
        }

        return cancelled ? nil : total
    }

    /// Number of tokens one pretoken encodes to.
    ///
    /// A port of tiktoken's `_byte_pair_merge`: repeatedly merge the adjacent
    /// pair with the lowest rank until no pair is mergeable.
    private static func tokenCount(for piece: [UInt8], ranks: [Data: Int]) -> Int {
        guard piece.count > 1 else { return piece.isEmpty ? 0 : 1 }
        if ranks[Data(piece)] != nil { return 1 }

        let unmergeable = Int.max
        // Each entry is (start offset, rank of the pair beginning here).
        var parts: [(start: Int, rank: Int)] = []
        parts.reserveCapacity(piece.count + 1)

        var best = (rank: unmergeable, index: Int.max)
        for index in 0..<(piece.count - 1) {
            let rank = ranks[Data(piece[index...(index + 1)])] ?? unmergeable
            if rank < best.rank { best = (rank, index) }
            parts.append((index, rank))
        }
        parts.append((piece.count - 1, unmergeable))
        parts.append((piece.count, unmergeable))

        func rank(startingAt index: Int) -> Int {
            guard index + 3 < parts.count else { return unmergeable }
            return ranks[Data(piece[parts[index].start..<parts[index + 3].start])] ?? unmergeable
        }

        while best.rank != unmergeable {
            let index = best.index
            if index > 0 { parts[index - 1].rank = rank(startingAt: index - 1) }
            parts[index].rank = rank(startingAt: index)
            parts.remove(at: index + 1)

            best = (unmergeable, Int.max)
            for (position, part) in parts.dropLast().enumerated() where part.rank < best.rank {
                best = (part.rank, position)
            }
        }
        return parts.count - 1
    }

    // MARK: - Vocabulary

    private func loadVocabulary() -> [Data: Int]? {
        if let ranks { return ranks }
        guard !vocabularyUnavailable else { return nil }

        guard let url = Bundle.main.url(forResource: "o200k_base",
                                        withExtension: "tiktoken",
                                        subdirectory: "Tokenizer")
                ?? Bundle.main.url(forResource: "o200k_base", withExtension: "tiktoken"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            vocabularyUnavailable = true
            return nil
        }

        var table: [Data: Int] = [:]
        table.reserveCapacity(210_000)
        contents.enumerateLines { line, _ in
            // Each line is `<base64 token bytes> <rank>`.
            guard let separator = line.lastIndex(of: " "),
                  let rank = Int(line[line.index(after: separator)...]),
                  let bytes = Data(base64Encoded: String(line[..<separator])) else { return }
            table[bytes] = rank
        }

        guard !table.isEmpty else {
            vocabularyUnavailable = true
            return nil
        }
        ranks = table
        return table
    }
}
