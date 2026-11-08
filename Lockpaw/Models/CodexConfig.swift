import Foundation

/// Reads the top level of a Codex `config.toml`, just far enough to find `notify` and the
/// first `[table]` header. Pure and compiled into the CLI too, so the unit tests cover
/// what `lockpaw install-hook codex` runs and what Settings shows.
///
/// It is a scanner, not a full TOML parser. It knows strings (basic, literal, and their
/// multi-line forms), arrays (across lines, with comments and a trailing comma), inline
/// tables and comments, so a `[` or `#` inside a value is never mistaken for a header or
/// a comment. Anything it doesn't understand makes the whole file unreadable, and an
/// unreadable file is never rewritten.
enum CodexConfig {
    /// The top-level `notify` statement.
    struct Notify: Equatable {
        /// Character offsets of `notify = <value>`, without any trailing comment.
        var range: Range<Int>
        /// The command, when the value is an array of strings (the only shape Codex accepts).
        var argv: [String]?
    }

    struct Scan: Equatable {
        var notify: Notify?
        /// Character offset of the first `[table]` header, or the end of the file.
        var firstTable: Int
    }

    /// Codex's config directory: `$CODEX_HOME` if set, otherwise `~/.codex` under `home`.
    /// The CLI writes here and Settings reads here, so both follow the same variable.
    static func directory(environment: [String: String], home: URL) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// nil when the top level doesn't scan as TOML.
    static func scan(_ contents: String) -> Scan? {
        var scanner = Scanner(Array(contents))
        return try? scanner.scanTopLevel()
    }

    /// The argv Codex runs, written as a TOML array of basic strings.
    static func notifyLine(_ argv: [String]) -> String {
        "notify = [" + argv.map(quoted).joined(separator: ", ") + "]"
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Lockpaw's notify and the chain

    /// Separates Lockpaw's own arguments from a chained notify command that runs after the ping.
    static let chainSeparator = "--"

    /// Whether this notify argv runs a Lockpaw ping first (with or without a chain after it).
    static func isLockpawNotify(_ argv: [String]) -> Bool {
        let own = argv.firstIndex(of: chainSeparator).map { Array(argv[..<$0]) } ?? argv
        return AgentHookConfig.isLockpawPingCommand(own.joined(separator: " "))
    }

    /// The command that runs after Lockpaw's ping, or empty when nothing is chained.
    static func chainedCommand(in argv: [String]) -> [String] {
        guard let separator = argv.firstIndex(of: chainSeparator) else { return [] }
        return Array(argv[(separator + 1)...])
    }

    /// Splits `lockpaw ping --agent codex -- <their notify> <payload>` the way Codex runs it.
    /// `own` is what the ping reads. Codex appends its JSON payload as the last argument,
    /// so `own` gets a copy of it too. `chained` is the original command with the payload
    /// still last, exactly as Codex would have run it without Lockpaw.
    static func splitChain(_ arguments: [String]) -> (own: [String], chained: [String]) {
        guard let separator = arguments.firstIndex(of: chainSeparator) else { return (arguments, []) }
        var own = Array(arguments[..<separator])
        let chained = Array(arguments[(separator + 1)...])
        if chained.count >= 2, let payload = chained.last, payload.hasPrefix("{") { own.append(payload) }
        return (own, chained)
    }

    // MARK: - Scanner

    private struct Malformed: Error {}

    private indirect enum Value {
        case string(String)
        case array([Value])
        case other
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }
        var current: Character? { atEnd ? nil : chars[i] }

        mutating func scanTopLevel() throws -> Scan {
            var notify: Notify?
            while true {
                skipBlankLinesAndComments()
                guard let c = current else { return Scan(notify: notify, firstTable: chars.count) }
                if c == "[" { return Scan(notify: notify, firstTable: lineStart(of: i)) }

                let start = i
                let key = try readKey()
                skipSpaces()
                guard current == "=" else { throw Malformed() }
                i += 1
                skipSpaces()
                let value = try readValue()
                let end = i
                skipSpaces()
                if current == "#" { skipComment() }
                guard atEnd || current!.isNewline else { throw Malformed() }

                if key == ["notify"] {
                    guard notify == nil else { throw Malformed() }
                    notify = Notify(range: start..<end, argv: Self.strings(value))
                }
            }
        }

        static func strings(_ value: Value) -> [String]? {
            guard case .array(let items) = value else { return nil }
            var result: [String] = []
            for item in items {
                guard case .string(let s) = item else { return nil }
                result.append(s)
            }
            return result
        }

        func lineStart(of index: Int) -> Int {
            var j = index
            while j > 0, !chars[j - 1].isNewline { j -= 1 }
            return j
        }

        mutating func skipSpaces() {
            while let c = current, c == " " || c == "\t" { i += 1 }
        }

        mutating func skipComment() {
            while let c = current, !c.isNewline { i += 1 }
        }

        mutating func skipBlankLinesAndComments() {
            while let c = current {
                if c == " " || c == "\t" || c.isNewline { i += 1 } else if c == "#" { skipComment() } else { return }
            }
        }

        /// A dotted key: bare or quoted parts.
        mutating func readKey() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = current else { throw Malformed() }
                if c == "\"" || c == "'" {
                    guard case .string(let s) = try readString(), !isMultiLine(s) else { throw Malformed() }
                    parts.append(s)
                } else {
                    var part = ""
                    while let c = current, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                        part.append(c)
                        i += 1
                    }
                    guard !part.isEmpty else { throw Malformed() }
                    parts.append(part)
                }
                skipSpaces()
                guard current == "." else { return parts }
                i += 1
            }
        }

        func isMultiLine(_ s: String) -> Bool { s.contains(where: \.isNewline) }

        mutating func readValue() throws -> Value {
            guard let c = current else { throw Malformed() }
            switch c {
            case "\"", "'": return try readString()
            case "[": return try readArray()
            case "{": try skipInlineTable(); return .other
            default:
                let start = i
                while let c = current, !(c == " " || c == "\t" || c.isNewline || c == "," || c == "]" || c == "}" || c == "#") {
                    i += 1
                }
                guard i > start else { throw Malformed() }
                return .other
            }
        }

        mutating func readArray() throws -> Value {
            i += 1 // [
            var items: [Value] = []
            while true {
                skipBlankLinesAndComments()
                guard let c = current else { throw Malformed() }
                if c == "]" { i += 1; return .array(items) }
                items.append(try readValue())
                skipBlankLinesAndComments()
                guard let next = current else { throw Malformed() }
                if next == "," { i += 1 } else if next != "]" { throw Malformed() }
            }
        }

        mutating func skipInlineTable() throws {
            i += 1 // {
            while true {
                skipSpaces()
                guard let c = current, !c.isNewline else { throw Malformed() }
                if c == "}" { i += 1; return }
                _ = try readKey()
                skipSpaces()
                guard current == "=" else { throw Malformed() }
                i += 1
                skipSpaces()
                _ = try readValue()
                skipSpaces()
                if current == "," { i += 1 } else if current != "}" { throw Malformed() }
            }
        }

        func hasPrefix(_ text: String) -> Bool {
            let needle = Array(text)
            guard i + needle.count <= chars.count else { return false }
            return Array(chars[i..<(i + needle.count)]) == needle
        }

        mutating func readString() throws -> Value {
            let quote = chars[i]
            let literal = quote == "'"
            let triple = String(repeating: String(quote), count: 3)
            if hasPrefix(triple) {
                i += 3
                // A newline right after the opening quotes is trimmed.
                if let c = current, c.isNewline { i += 1 }
                var out = ""
                while true {
                    guard let c = current else { throw Malformed() }
                    if hasPrefix(triple) {
                        i += 3
                        // Up to two quotes may sit right before the closing three.
                        var extra = 0
                        while current == quote, extra < 2 { out.append(quote); i += 1; extra += 1 }
                        return .string(out)
                    }
                    if !literal, c == "\\" {
                        i += 1
                        // A backslash at the end of a line trims the newline and the whitespace after it.
                        var j = i
                        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                        if j < chars.count, chars[j].isNewline {
                            i = j
                            while let c = current, c == " " || c == "\t" || c.isNewline { i += 1 }
                            continue
                        }
                        out += try readEscape()
                        continue
                    }
                    out.append(c)
                    i += 1
                }
            }

            i += 1
            var out = ""
            while true {
                guard let c = current, !c.isNewline else { throw Malformed() }
                i += 1
                if c == quote { return .string(out) }
                if !literal, c == "\\" { out += try readEscape(); continue }
                out.append(c)
            }
        }

        /// The escape after a backslash in a basic string.
        mutating func readEscape() throws -> String {
            guard let c = current else { throw Malformed() }
            i += 1
            switch c {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U", "x":
                let count = c == "u" ? 4 : c == "U" ? 8 : 2
                guard i + count <= chars.count,
                      let value = UInt32(String(chars[i..<(i + count)]), radix: 16),
                      let scalar = Unicode.Scalar(value) else { throw Malformed() }
                i += count
                return String(Character(scalar))
            default: throw Malformed()
            }
        }
    }
}
