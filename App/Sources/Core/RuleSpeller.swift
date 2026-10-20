import Foundation

/// Turns a voice-command rule such as `tab (open | new) [now]` into text a person would say.
enum RuleSpeller {
    /// A concrete phrase to send to `/execute`: first alternative of every group, optionals dropped.
    /// nil when the rule needs a value from the user (`<capture>`, `{list}`) or cannot be parsed.
    static func spoken(_ rule: String) -> String? {
        guard !rule.contains("<"), !rule.contains("{") else { return nil }
        var parser = Parser(Array(rule))
        guard let text = parser.parseTop() else { return nil }
        let phrase = text.split(separator: " ").joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    /// Every word the rule can contain (all alternatives, optionals included), captures and lists removed.
    static func searchText(_ rule: String) -> String {
        var out = ""
        var depth = 0
        for char in rule {
            switch char {
            case "<", "{": depth += 1
            case ">", "}": depth = max(0, depth - 1)
            default:
                guard depth == 0 else { continue }
                out.append("()[]|^$*+?".contains(char) ? " " : char)
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        mutating func parseTop() -> String? {
            let result = parseAlternatives()
            return pos == chars.count ? result : nil
        }

        /// Parses `a b | c d` up to a closer; returns the first alternative.
        private mutating func parseAlternatives() -> String? {
            var first: String?
            var current = [String]()
            while pos < chars.count {
                let char = chars[pos]
                if char == ")" || char == "]" { break }
                if char == "|" {
                    first = first ?? current.joined(separator: " ")
                    current = []
                    pos += 1
                    continue
                }
                guard let item = parseItem() else { return nil }
                current.append(item)
            }
            return first ?? current.joined(separator: " ")
        }

        private mutating func parseItem() -> String? {
            let char = chars[pos]
            if char == " " || char == "^" || char == "$" {
                pos += 1
                return ""
            }
            var text: String
            var optional = false
            if char == "(" || char == "[" {
                let closer: Character = char == "(" ? ")" : "]"
                pos += 1
                guard let inner = parseAlternatives(), pos < chars.count, chars[pos] == closer else { return nil }
                pos += 1
                text = inner
                optional = char == "["
            } else {
                var word = ""
                while pos < chars.count, !" ()[]|^$*+?".contains(chars[pos]) {
                    word.append(chars[pos])
                    pos += 1
                }
                guard !word.isEmpty else { return nil }
                text = word
            }
            while pos < chars.count, "*+?".contains(chars[pos]) {
                if chars[pos] != "+" { optional = true }
                pos += 1
            }
            return optional ? "" : text
        }
    }
}
