import XCTest

@testable import MemoryClip

final class CalcEvaluatorTests: XCTestCase {
    // MARK: - Evaluation

    func testBasicMultiply() {
        XCTAssertEqual(CalcEvaluator.evaluate("12*7"), 84)
    }

    func testOperatorPrecedence() {
        XCTAssertEqual(CalcEvaluator.evaluate("2+3*4"), 14)
        XCTAssertEqual(CalcEvaluator.evaluate("10-4/2"), 8)
    }

    func testParentheses() {
        XCTAssertEqual(CalcEvaluator.evaluate("(2+3)*4"), 20)
        XCTAssertEqual(CalcEvaluator.evaluate("((2+3)*(4-1))"), 15)
    }

    func testUnaryMinus() {
        XCTAssertEqual(CalcEvaluator.evaluate("-5+3"), -2)
        XCTAssertEqual(CalcEvaluator.evaluate("-(2+3)"), -5)
        XCTAssertEqual(CalcEvaluator.evaluate("2*-3"), -6)
    }

    func testDecimals() {
        XCTAssertEqual(CalcEvaluator.evaluate("1.5*2"), 3)
        XCTAssertEqual(CalcEvaluator.evaluate("10/4"), 2.5)
        XCTAssertEqual(CalcEvaluator.evaluate(".5+.25"), 0.75)
    }

    func testWhitespaceTolerance() {
        XCTAssertEqual(CalcEvaluator.evaluate("  12 * 7  "), 84)
        XCTAssertEqual(CalcEvaluator.evaluate("1 + 2\t*\t3"), 7)
    }

    func testDivisionByZeroIsNil() {
        XCTAssertNil(CalcEvaluator.evaluate("1/0"))
        XCTAssertNil(CalcEvaluator.evaluate("1/(2-2)"))
    }

    func testDateLikeStringsAreNil() {
        XCTAssertNil(CalcEvaluator.evaluate("2026-08-07"))   // ISO date, not "2011"
        XCTAssertNil(CalcEvaluator.evaluate("07/08/26"))     // slash date, not division
        XCTAssertNil(CalcEvaluator.evaluate("07.08.2026"))   // dotted date
    }

    func testSimpleSubtractionStillWorks() {
        XCTAssertEqual(CalcEvaluator.evaluate("5-3"), 2)
    }

    func testMalformedInputIsNil() {
        XCTAssertNil(CalcEvaluator.evaluate(""))          // empty
        XCTAssertNil(CalcEvaluator.evaluate("   "))       // whitespace only
        XCTAssertNil(CalcEvaluator.evaluate("2+"))        // trailing operator
        XCTAssertNil(CalcEvaluator.evaluate("*7"))        // leading operator
        XCTAssertNil(CalcEvaluator.evaluate("abc"))       // letters
        XCTAssertNil(CalcEvaluator.evaluate("1e5"))       // no exponent literals
        XCTAssertNil(CalcEvaluator.evaluate("2..3"))      // malformed number
        XCTAssertNil(CalcEvaluator.evaluate("(2+3"))      // unbalanced parens
        XCTAssertNil(CalcEvaluator.evaluate("2 3"))       // missing operator
        XCTAssertNil(CalcEvaluator.evaluate("12*7=84"))   // trailing junk
    }

    // MARK: - Robustness guards
    //
    // NOTE: XCTest cannot catch a SIGSEGV in-process, so these assert the
    // guards' RETURN VALUE. Before the fix, ~80 000 nested parens (or leading
    // unary minuses) exhausted the stack and killed the process outright.

    func testDeeplyNestedParenthesesReturnNilInsteadOfCrashing() {
        for depth in [65, 200, 5_000] {
            let expression = String(repeating: "(", count: depth)
                + "1" + String(repeating: ")", count: depth)
            XCTAssertNil(CalcEvaluator.evaluate(expression), "depth \(depth)")
        }
    }

    func testUnbalancedParenthesesFloodReturnsNil() {
        XCTAssertNil(CalcEvaluator.evaluate(String(repeating: "(", count: 100_000)))
    }

    func testUnaryOperatorFloodReturnsNil() {
        XCTAssertNil(CalcEvaluator.evaluate(String(repeating: "-", count: 100_000) + "1"))
        XCTAssertNil(CalcEvaluator.evaluate(String(repeating: "+", count: 100_000) + "1"))
    }

    func testOverlongInputReturnsNil() {
        // Well-formed arithmetic, but far past the length guard.
        let long = "1" + String(repeating: "+1", count: 5_000)
        XCTAssertNil(CalcEvaluator.evaluate(long))
        // A huge non-arithmetic clip must be rejected without being copied
        // into a [Character] first; this simply must return quickly.
        XCTAssertNil(CalcEvaluator.evaluate(String(repeating: "a", count: 1_000_000)))
    }

    func testModestNestingAndUnaryChainsStillEvaluate() {
        XCTAssertEqual(CalcEvaluator.evaluate("((((((1+1))))))"), 2)
        XCTAssertEqual(CalcEvaluator.evaluate("--5"), 5)
        XCTAssertEqual(CalcEvaluator.evaluate("2*-(3+-1)"), -4)
    }

    func testLongButAcceptableExpressionStillEvaluates() {
        // 50 terms — comfortably inside the 256-character limit.
        let expression = Array(repeating: "1", count: 50).joined(separator: "+")
        XCTAssertEqual(CalcEvaluator.evaluate(expression), 50)
    }

    func testGuardedInputEvaluatesFast() {
        let start = Date()
        for _ in 0..<200 {
            _ = CalcEvaluator.evaluate(String(repeating: "(", count: 50_000))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - Formatting

    func testFormatIntegral() {
        XCTAssertEqual(CalcEvaluator.format(84), "84")
        XCTAssertEqual(CalcEvaluator.format(84.0), "84")
        XCTAssertEqual(CalcEvaluator.format(-5), "-5")
        XCTAssertEqual(CalcEvaluator.format(0), "0")
        XCTAssertEqual(CalcEvaluator.format(100.0), "100")
    }

    func testFormatFractional() {
        XCTAssertEqual(CalcEvaluator.format(0.5), "0.5")
        XCTAssertEqual(CalcEvaluator.format(2.5), "2.5")
        XCTAssertEqual(CalcEvaluator.format(0.1 + 0.2), "0.3") // no float noise
    }

    func testFormatRepeatingFractionUsesTenSignificantDigits() {
        XCTAssertEqual(CalcEvaluator.format(1.0 / 3.0), "0.3333333333")
    }

    func testFormatHugeMagnitudeUsesExponent() {
        XCTAssertEqual(CalcEvaluator.format(1e20), "1e+20")
        XCTAssertEqual(CalcEvaluator.format(1e-20), "1e-20")
        XCTAssertEqual(CalcEvaluator.format(-1.5e20), "-1.5e+20")
    }
}
