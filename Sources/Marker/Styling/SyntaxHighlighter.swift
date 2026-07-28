import Foundation

enum CodeToken {
    case keyword, type, string, comment, number, function, punctuation, added, removed, meta
}

struct CodeLanguage {
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)?
    var stringDelimiters: [String] = ["\"", "'"]
    var multilineStrings: [String] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    var capitalizedAreTypes = false
    var preprocessorPrefixes: [String] = []
}

/// A deliberately small tokenizer covering the languages that actually show up
/// in notes. It aims for a correct-looking highlight, not a compiler front end.
enum SyntaxHighlighter {

    // MARK: - Public entry point

    static func tokens(_ chars: [unichar], range: NSRange, language: String?) -> [(NSRange, CodeToken)] {
        guard range.length > 0 else { return [] }
        let key = normalize(language)
        if key == "diff" || key == "patch" { return diffTokens(chars, range: range) }
        guard let definition = languages[key] else { return [] }
        return tokenize(chars, range: range, language: definition)
    }

    static func displayName(for language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        return prettyNames[normalize(language)] ?? language
    }

    private static func normalize(_ language: String?) -> String {
        guard let language else { return "" }
        let lowered = language.lowercased()
        return aliases[lowered] ?? lowered
    }

    // MARK: - Generic tokenizer

    private static func tokenize(_ chars: [unichar],
                                 range: NSRange,
                                 language: CodeLanguage) -> [(NSRange, CodeToken)] {
        var tokens: [(NSRange, CodeToken)] = []
        var i = range.location
        let end = NSMaxRange(range)

        while i < end {
            let c = chars[i]

            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }

            // Preprocessor / attribute lines.
            if language.preprocessorPrefixes.contains(where: {
                matches(chars, at: i, end: end, string: $0)
            }), atLineStartIgnoringSpace(chars, i, range.location) {
                var j = i
                while j < end, chars[j] != 0x0A { j += 1 }
                tokens.append((NSRange(location: i, length: j - i), .meta))
                i = j
                continue
            }

            // Block comment.
            if let block = language.blockComment, matches(chars, at: i, end: end, string: block.open) {
                var j = i + block.open.utf16.count
                while j < end, !matches(chars, at: j, end: end, string: block.close) { j += 1 }
                j = min(end, j + block.close.utf16.count)
                tokens.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }

            // Line comment.
            if language.lineComments.contains(where: {
                matches(chars, at: i, end: end, string: $0)
            }) {
                var j = i
                while j < end, chars[j] != 0x0A { j += 1 }
                tokens.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }

            // Multiline string (triple quotes, heredoc-ish).
            if let delimiter = language.multilineStrings.first(where: {
                matches(chars, at: i, end: end, string: $0)
            }) {
                let width = delimiter.utf16.count
                var j = i + width
                while j < end, !matches(chars, at: j, end: end, string: delimiter) { j += 1 }
                j = min(end, j + width)
                tokens.append((NSRange(location: i, length: j - i), .string))
                i = j
                continue
            }

            // Single-line string.
            if let delimiter = language.stringDelimiters.first(where: {
                matches(chars, at: i, end: end, string: $0)
            }) {
                let width = delimiter.utf16.count
                var j = i + width
                while j < end {
                    if chars[j] == 0x5C { j += 2; continue }
                    if chars[j] == 0x0A { break }
                    if matches(chars, at: j, end: end, string: delimiter) { j += width; break }
                    j += 1
                }
                tokens.append((NSRange(location: i, length: min(j, end) - i), .string))
                i = min(j, end)
                continue
            }

            // Number.
            if isDigit(c) || (c == 0x2E && i + 1 < end && isDigit(chars[i + 1])) {
                var j = i
                while j < end, isDigit(chars[j]) || chars[j] == 0x2E || chars[j] == 0x5F
                        || isHexLetter(chars[j]) || chars[j] == 0x78 || chars[j] == 0x58 {
                    j += 1
                }
                tokens.append((NSRange(location: i, length: j - i), .number))
                i = j
                continue
            }

            // Identifier.
            if isIdentifierStart(c) {
                var j = i
                while j < end, isIdentifierPart(chars[j]) { j += 1 }
                let word = InlineScanner.string(chars, NSRange(location: i, length: j - i))
                let tokenRange = NSRange(location: i, length: j - i)

                if language.keywords.contains(word) {
                    tokens.append((tokenRange, .keyword))
                } else if language.types.contains(word) {
                    tokens.append((tokenRange, .type))
                } else if language.capitalizedAreTypes, let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    tokens.append((tokenRange, .type))
                } else {
                    var k = j
                    while k < end, chars[k] == 0x20 { k += 1 }
                    if k < end, chars[k] == 0x28 { // '('
                        tokens.append((tokenRange, .function))
                    }
                }
                i = j
                continue
            }

            if isPunctuation(c) {
                tokens.append((NSRange(location: i, length: 1), .punctuation))
            }
            i += 1
        }

        return tokens
    }

    private static func diffTokens(_ chars: [unichar], range: NSRange) -> [(NSRange, CodeToken)] {
        var tokens: [(NSRange, CodeToken)] = []
        var i = range.location
        let end = NSMaxRange(range)

        while i < end {
            var j = i
            while j < end, chars[j] != 0x0A { j += 1 }
            let lineRange = NSRange(location: i, length: j - i)
            if lineRange.length > 0 {
                switch chars[i] {
                case 0x2B: tokens.append((lineRange, .added))       // +
                case 0x2D: tokens.append((lineRange, .removed))     // -
                case 0x40: tokens.append((lineRange, .meta))        // @
                case 0x64: tokens.append((lineRange, .meta))        // diff --git
                default: break
                }
            }
            i = j + 1
        }
        return tokens
    }

    // MARK: - Character helpers

    private static func matches(_ chars: [unichar], at index: Int, end: Int, string: String) -> Bool {
        let units = Array(string.utf16)
        guard !units.isEmpty, index + units.count <= end else { return false }
        for (offset, unit) in units.enumerated() where chars[index + offset] != unit { return false }
        return true
    }

    private static func atLineStartIgnoringSpace(_ chars: [unichar], _ index: Int, _ lowerBound: Int) -> Bool {
        var i = index - 1
        while i >= lowerBound {
            if chars[i] == 0x0A { return true }
            if chars[i] != 0x20 && chars[i] != 0x09 { return false }
            i -= 1
        }
        return true
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isHexLetter(_ c: unichar) -> Bool {
        (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    }

    private static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
    }

    private static func isIdentifierPart(_ c: unichar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    private static func isPunctuation(_ c: unichar) -> Bool {
        switch c {
        case 0x7B, 0x7D, 0x28, 0x29, 0x5B, 0x5D, 0x3B, 0x2C, 0x3A, 0x2E,
             0x3D, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3C, 0x3E, 0x21, 0x26,
             0x7C, 0x5E, 0x7E, 0x3F:
            return true
        default:
            return false
        }
    }

    // MARK: - Language table

    private static let aliases: [String: String] = [
        "objective-c": "c", "objc": "c", "cpp": "c", "c++": "c", "h": "c", "hpp": "c", "cc": "c",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python",
        "rb": "ruby",
        "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell", "shell-session": "shell",
        "yml": "yaml",
        "htm": "html", "xml": "html", "svg": "html", "vue": "html",
        "kt": "kotlin", "kts": "kotlin",
        "rs": "rust",
        "golang": "go",
        "cs": "csharp", "c#": "csharp",
        "postgres": "sql", "postgresql": "sql", "mysql": "sql", "sqlite": "sql",
        "makefile": "shell", "dockerfile": "shell",
    ]

    private static let prettyNames: [String: String] = [
        "swift": "Swift", "c": "C", "javascript": "JavaScript", "typescript": "TypeScript",
        "python": "Python", "ruby": "Ruby", "shell": "Shell", "yaml": "YAML", "json": "JSON",
        "html": "HTML", "css": "CSS", "go": "Go", "rust": "Rust", "java": "Java",
        "kotlin": "Kotlin", "php": "PHP", "sql": "SQL", "csharp": "C#", "diff": "Diff",
        "toml": "TOML", "lua": "Lua",
    ]

    private static let languages: [String: CodeLanguage] = {
        var table: [String: CodeLanguage] = [:]

        table["swift"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\""],
            multilineStrings: ["\"\"\""],
            keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                       "func", "import", "init", "inout", "internal", "let", "open", "operator",
                       "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
                       "typealias", "var", "break", "case", "continue", "default", "defer", "do",
                       "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
                       "switch", "where", "while", "as", "catch", "false", "is", "nil", "super",
                       "self", "Self", "throw", "throws", "true", "try", "async", "await", "actor",
                       "some", "any", "lazy", "weak", "unowned", "mutating", "nonmutating",
                       "override", "final", "convenience", "required", "indirect", "package"],
            types: ["Int", "Double", "Float", "String", "Bool", "Array", "Dictionary", "Set",
                    "Optional", "Result", "Data", "Date", "URL", "Character", "Any", "AnyObject",
                    "Void", "CGFloat", "NSRange"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["#if", "#else", "#endif", "#warning", "#error", "@"])

        table["c"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do",
                       "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
                       "int", "long", "register", "return", "short", "signed", "sizeof", "static",
                       "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                       "while", "class", "namespace", "template", "public", "private", "protected",
                       "virtual", "new", "delete", "this", "nullptr", "true", "false", "using",
                       "constexpr", "auto", "override", "final", "@interface", "@implementation"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["#"])

        table["javascript"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'", "`"],
            keywords: ["var", "let", "const", "function", "return", "if", "else", "for", "while",
                       "do", "break", "continue", "switch", "case", "default", "new", "delete",
                       "typeof", "instanceof", "this", "null", "undefined", "true", "false",
                       "class", "extends", "super", "import", "export", "from", "as", "async",
                       "await", "try", "catch", "finally", "throw", "yield", "static", "get", "set",
                       "of", "in", "void"],
            types: ["Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set",
                    "Symbol", "JSON", "Math", "Date", "RegExp", "Error", "console", "window",
                    "document"],
            capitalizedAreTypes: true)

        var typescript = table["javascript"]!
        typescript.keywords.formUnion(["interface", "type", "enum", "implements", "declare",
                                       "namespace", "readonly", "public", "private", "protected",
                                       "abstract", "satisfies", "keyof", "infer", "is"])
        typescript.types.formUnion(["string", "number", "boolean", "any", "unknown", "never",
                                    "void", "Record", "Partial", "Readonly", "Pick", "Omit"])
        table["typescript"] = typescript

        table["python"] = CodeLanguage(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            multilineStrings: ["\"\"\"", "'''"],
            keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "break",
                       "continue", "pass", "import", "from", "as", "with", "try", "except",
                       "finally", "raise", "lambda", "yield", "global", "nonlocal", "assert",
                       "del", "in", "is", "not", "and", "or", "None", "True", "False", "async",
                       "await", "match", "case"],
            types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes",
                    "object", "type", "self", "cls"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["@"])

        table["ruby"] = CodeLanguage(
            lineComments: ["#"],
            stringDelimiters: ["\"", "'"],
            keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while",
                       "until", "for", "do", "begin", "rescue", "ensure", "raise", "return",
                       "yield", "self", "nil", "true", "false", "and", "or", "not", "then",
                       "require", "require_relative", "attr_accessor", "attr_reader", "puts"],
            capitalizedAreTypes: true)

        table["shell"] = CodeLanguage(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                       "case", "esac", "function", "return", "in", "select", "time", "export",
                       "local", "readonly", "declare", "source", "alias", "set", "unset", "trap",
                       "echo", "cd", "exit", "shift", "eval", "exec"],
            types: ["true", "false"])

        table["yaml"] = CodeLanguage(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            keywords: ["true", "false", "null", "yes", "no", "on", "off"])

        table["toml"] = table["yaml"]

        table["json"] = CodeLanguage(
            lineComments: [],
            blockComment: nil,
            stringDelimiters: ["\""],
            keywords: ["true", "false", "null"])

        table["html"] = CodeLanguage(
            lineComments: [],
            blockComment: ("<!--", "-->"),
            stringDelimiters: ["\"", "'"],
            keywords: [])

        table["css"] = CodeLanguage(
            lineComments: [],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: ["important", "media", "import", "keyframes", "supports", "font-face",
                       "root", "hover", "focus", "active", "before", "after"])

        table["go"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "`"],
            keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else",
                       "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                       "map", "package", "range", "return", "select", "struct", "switch", "type",
                       "var", "nil", "true", "false", "iota"],
            types: ["string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                    "uint32", "uint64", "float32", "float64", "bool", "byte", "rune", "error",
                    "any"],
            capitalizedAreTypes: true)

        table["rust"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\""],
            keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn",
                       "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
                       "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                       "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                       "use", "where", "while"],
            types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128",
                    "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option",
                    "Result", "Box"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["#["])

        table["java"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                       "class", "const", "continue", "default", "do", "double", "else", "enum",
                       "extends", "final", "finally", "float", "for", "if", "implements", "import",
                       "instanceof", "int", "interface", "long", "native", "new", "package",
                       "private", "protected", "public", "return", "short", "static", "strictfp",
                       "super", "switch", "synchronized", "this", "throw", "throws", "transient",
                       "try", "void", "volatile", "while", "var", "record", "sealed", "true",
                       "false", "null"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["@"])

        table["kotlin"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            multilineStrings: ["\"\"\""],
            keywords: ["as", "break", "class", "continue", "do", "else", "false", "for", "fun",
                       "if", "in", "interface", "is", "null", "object", "package", "return",
                       "super", "this", "throw", "true", "try", "typealias", "typeof", "val",
                       "var", "when", "while", "by", "catch", "constructor", "data", "finally",
                       "get", "import", "init", "override", "private", "public", "internal",
                       "protected", "sealed", "set", "suspend", "companion", "lateinit"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["@"])

        table["php"] = CodeLanguage(
            lineComments: ["//", "#"],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                       "class", "clone", "const", "continue", "declare", "default", "do", "echo",
                       "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif",
                       "endswitch", "endwhile", "extends", "final", "finally", "fn", "for",
                       "foreach", "function", "global", "goto", "if", "implements", "include",
                       "instanceof", "insteadof", "interface", "isset", "list", "match",
                       "namespace", "new", "or", "print", "private", "protected", "public",
                       "readonly", "require", "return", "static", "switch", "throw", "trait",
                       "try", "unset", "use", "var", "while", "xor", "yield", "true", "false",
                       "null"],
            capitalizedAreTypes: true)

        table["sql"] = CodeLanguage(
            lineComments: ["--"],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["'", "\""],
            keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                       "delete", "create", "table", "alter", "drop", "index", "view", "join",
                       "inner", "left", "right", "outer", "full", "on", "group", "by", "order",
                       "having", "limit", "offset", "union", "all", "distinct", "as", "and", "or",
                       "not", "null", "is", "in", "between", "like", "exists", "case", "when",
                       "then", "else", "end", "primary", "key", "foreign", "references", "default",
                       "constraint", "unique", "with", "returning",
                       "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                       "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "LEFT", "INNER",
                       "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "AND", "OR", "NOT",
                       "NULL", "AS", "WITH", "DISTINCT", "UNION"])

        table["csharp"] = CodeLanguage(
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: ["abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char",
                       "checked", "class", "const", "continue", "decimal", "default", "delegate",
                       "do", "double", "else", "enum", "event", "explicit", "extern", "false",
                       "finally", "fixed", "float", "for", "foreach", "goto", "if", "implicit",
                       "in", "int", "interface", "internal", "is", "lock", "long", "namespace",
                       "new", "null", "object", "operator", "out", "override", "params",
                       "private", "protected", "public", "readonly", "ref", "return", "sealed",
                       "short", "sizeof", "static", "string", "struct", "switch", "this", "throw",
                       "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
                       "using", "var", "virtual", "void", "volatile", "while", "async", "await",
                       "record"],
            capitalizedAreTypes: true,
            preprocessorPrefixes: ["#", "["])

        table["lua"] = CodeLanguage(
            lineComments: ["--"],
            blockComment: ("--[[", "]]"),
            stringDelimiters: ["\"", "'"],
            keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for", "function",
                       "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
                       "then", "true", "until", "while"])

        return table
    }()
}
