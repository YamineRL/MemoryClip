import Foundation

/// Instant calculation of plain arithmetic expressions (Phase-2: a copied
/// "12*7" clip can surface "= 84").
///
/// Deliberately NOT backed by `NSExpression`: NSExpression is documented to
/// raise ObjC exceptions (i.e. crash) on several classes of malformed input
/// instead of failing gracefully, which is unacceptable for content taken
/// from the clipboard. This hermetic recursive-descent parser returns `nil`
/// for anything it does not fully understand.
enum CalcEvaluator {
    /// Cheap pre-trim rejection, in UTF-8 bytes (O(1) on native Swift
    /// strings — no traversal, no copy). It exists purely to bound work:
    /// `evaluate` is called for every visible text row, and both
    /// `trimmingCharacters` and `Parser.init`'s `Array(source)` would
    /// otherwise materialise the whole clip first — a `[Character]` costs
    /// ~16 bytes per element, so a 100 MB clip would allocate ~1.6 GB
    /// before the first character was even inspected. 4 KiB leaves ample
    /// room for leading whitespace and multi-byte scalars.
    private static let maxSourceUTF8Bytes = 4096

    /// Post-trim limit on the expression itself. Arithmetic people copy is
    /// tiny ("12*7", "1024*768/2"); 256 characters is far more than any
    /// real hand-written expression and keeps parser work trivially bounded.
    private static let maxExpressionLength = 256

    /// Evaluate the WHOLE trimmed string as an arithmetic expression, or
    /// `nil` when it is not one (stray letters, trailing operators,
    /// division by zero, empty input, over-long input, …). Internal
    /// whitespace is allowed.
    static func evaluate(_ expression: String) -> Double? {
        guard expression.utf8.count <= maxSourceUTF8Bytes else { return nil }
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxExpressionLength else { return nil }
        guard !isDateLike(trimmed) else { return nil }
        var parser = Parser(source: trimmed)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value.isFinite ? value : nil
    }

    /// Date-like strings such as "2026-08-07" or "07.08.2026" would
    /// otherwise parse cleanly as subtraction/division chains (surfacing a
    /// bogus "= 2011" next to a plain date). Reject them up front; ordinary
    /// arithmetic like "5-3" has only two operands and is unaffected.
    ///
    /// Shape: exactly three digit groups (1-4 / 1-2 / 1-4 digits) joined by
    /// the SAME separator — '-', '/' or '.'. The uniform-separator rule keeps
    /// mixed-operator arithmetic like "10-4/2" evaluable while catching
    /// "2026-08-07", "07/08/26" and "07.08.2026".
    private static func isDateLike(_ text: String) -> Bool {
        var componentLengths: [Int] = []
        var separator: Character?
        var current = 0
        for character in text {
            if character.isASCII, character.isNumber {
                current += 1
            } else if character == "-" || character == "/" || character == "." {
                guard current > 0 else { return false } // leading/double separator
                if let seen = separator, seen != character { return false } // mixed → arithmetic
                separator = character
                componentLengths.append(current)
                current = 0
            } else {
                return false // anything else is arithmetic-shaped, not a date
            }
        }
        guard current > 0 else { return false } // trailing separator
        componentLengths.append(current)
        guard componentLengths.count == 3 else { return false }
        return componentLengths[0] <= 4 && componentLengths[1] <= 2 && componentLengths[2] <= 4
    }

    /// Render a result for display: integrals without a fraction
    /// ("84"), otherwise up to 10 significant digits with no trailing
    /// zeros; only very large / very tiny magnitudes use exponent form.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return String(describing: value) }
        guard value != 0 else { return "0" }

        let negative = value < 0
        let magnitude = abs(value)
        var exp10 = Int(log10(magnitude).rounded(.down))
        // log10 can be off by one for values very close to powers of ten.
        while pow(10, Double(exp10 + 1)) <= magnitude { exp10 += 1 }
        while pow(10, Double(exp10)) > magnitude { exp10 -= 1 }

        // Huge (>= 1e16) or extremely tiny (< 1e-11) → exponent form.
        if exp10 >= 16 || exp10 < -11 {
            return (negative ? "-" : "") + scientific(magnitude, exponent: exp10)
        }

        // Round to 10 significant digits, then emit as plain decimal.
        let places = 9 - exp10
        let rounded: Double
        if places >= 0 {
            let scale = pow(10, Double(places))
            rounded = (magnitude * scale).rounded() / scale
        } else {
            let scale = pow(10, Double(-places))
            rounded = (magnitude / scale).rounded() * scale
        }

        var text: String
        if places >= 0 {
            text = String(format: "%.\(places)f", rounded)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        } else {
            text = String(format: "%.0f", rounded)
        }
        return (negative ? "-" : "") + text
    }

    /// "1.23456789e+20"-style rendering with up to 10 significant digits.
    private static func scientific(_ magnitude: Double, exponent: Int) -> String {
        var mantissa = magnitude / pow(10, Double(exponent)) // in [1, 10)
        mantissa = (mantissa * 1e9).rounded() / 1e9           // 10 significant digits
        var exp = exponent
        if mantissa >= 10 { mantissa /= 10; exp += 1 }        // rounding carry

        var text = String(format: "%.9f", mantissa)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)e\(exp >= 0 ? "+" : "-")\(abs(exp))"
    }

    // MARK: - Parser

    /// Recursive-descent parser over the expression's characters.
    ///
    /// Grammar (standard precedence):
    ///   expression := term (('+' | '-') term)*
    ///   term       := factor (('*' | '/') factor)*
    ///   factor     := ('-' | '+') factor | '(' expression ')' | number
    ///   number     := digit+ ('.' digit+)?   (leading '.' also allowed)
    private struct Parser {
        /// Maximum nesting of `factor` productions. Every `(` and every
        /// leading unary `-`/`+` costs one native stack frame, so without a
        /// cap a clip of ~80 000 `(` characters overflows the stack and
        /// SIGSEGVs the app on every panel open. 64 is deeper than any
        /// human-written expression ("((((1))))" is already absurd) while
        /// leaving the recursion far inside the smallest thread stack.
        static let maxDepth = 64

        private let chars: [Character]
        private var index = 0
        /// Current `parseFactor` recursion depth (see `maxDepth`).
        private var depth = 0

        init(source: String) {
            chars = Array(source)
        }

        /// True when every character has been consumed (whitespace skipped).
        var isAtEnd: Bool { index >= chars.count }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek("+-") {
                index += 1
                guard let rhs = parseTerm() else { return nil } // "2+" → nil
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek("*/") {
                index += 1
                guard let rhs = parseFactor() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return nil } // division by zero → nil
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func parseFactor() -> Double? {
            // Depth guard: fail gracefully instead of exhausting the stack.
            guard depth < Self.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }

            skipWhitespace()
            guard index < chars.count else { return nil }

            switch chars[index] {
            case "-":
                index += 1
                guard let value = parseFactor() else { return nil }
                return -value
            case "+":
                index += 1
                return parseFactor()
            case "(":
                index += 1
                guard let value = parseExpression() else { return nil }
                skipWhitespace()
                guard index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return value
            default:
                return parseNumber()
            }
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var sawDot = false
            var sawDigit = false
            while index < chars.count {
                let c = chars[index]
                if c.isASCII, c.isNumber {
                    sawDigit = true
                    index += 1
                } else if c == ".", !sawDot {
                    sawDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigit else {
                index = start // e.g. a bare "." — leave the input untouched
                return nil
            }
            return Double(String(chars[start..<index]))
        }

        /// First upcoming character (whitespace skipped) if it is in `among`.
        private mutating func peek(_ among: String) -> Character? {
            skipWhitespace()
            guard index < chars.count, among.contains(chars[index]) else { return nil }
            return chars[index]
        }

        private mutating func skipWhitespace() {
            while index < chars.count, chars[index].isWhitespace {
                index += 1
            }
        }
    }
}
