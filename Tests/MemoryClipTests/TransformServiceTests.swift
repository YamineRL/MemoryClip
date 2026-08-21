import XCTest

@testable import MemoryClip

final class TransformServiceTests: XCTestCase {
    // MARK: - Case transforms

    func testUppercased() {
        XCTAssertEqual(TransformService.apply(.uppercased, to: "Hello Clip"), "HELLO CLIP")
    }

    func testLowercased() {
        XCTAssertEqual(TransformService.apply(.lowercased, to: "Hello Clip"), "hello clip")
    }

    func testTitleCase() {
        XCTAssertEqual(TransformService.apply(.titleCase, to: "hello wide world"), "Hello Wide World")
    }

    // MARK: - Case styles

    func testCaseStylesRewriteACamelCasedIdentifier() {
        let input = "clipItemName"
        XCTAssertEqual(TransformService.apply(.snakeCase, to: input), "clip_item_name")
        XCTAssertEqual(TransformService.apply(.kebabCase, to: input), "clip-item-name")
        XCTAssertEqual(TransformService.apply(.screamingSnakeCase, to: input), "CLIP_ITEM_NAME")
        XCTAssertEqual(TransformService.apply(.camelCase, to: input), "clipItemName")
    }

    func testCaseStylesReadEveryOtherStyleBack() {
        for input in ["clip_item_name", "clip-item-name", "CLIP_ITEM_NAME", "Clip Item Name", "ClipItemName"] {
            XCTAssertEqual(TransformService.apply(.camelCase, to: input), "clipItemName", input)
            XCTAssertEqual(TransformService.apply(.snakeCase, to: input), "clip_item_name", input)
        }
    }

    func testSnakeCaseRoundTripsThroughCamelCase() throws {
        let camel = try XCTUnwrap(TransformService.apply(.camelCase, to: "clip_item_name"))
        XCTAssertEqual(TransformService.apply(.snakeCase, to: camel), "clip_item_name")

        let screaming = try XCTUnwrap(TransformService.apply(.screamingSnakeCase, to: camel))
        XCTAssertEqual(TransformService.apply(.camelCase, to: screaming), camel)
    }

    func testCaseStylesSplitAcronymsAndDigits() {
        XCTAssertEqual(TransformService.apply(.snakeCase, to: "HTTPServerURL"), "http_server_url")
        XCTAssertEqual(TransformService.apply(.camelCase, to: "HTTPServerURL"), "httpServerUrl")
        XCTAssertEqual(TransformService.apply(.snakeCase, to: "utf8Text"), "utf8_text")
        XCTAssertEqual(TransformService.apply(.camelCase, to: "utf8_text"), "utf8Text")
    }

    func testCaseStylesRejectTextWithNoWords() {
        for transform: Transform in [.snakeCase, .camelCase, .kebabCase, .screamingSnakeCase] {
            XCTAssertNil(TransformService.apply(transform, to: ""), transform.rawValue)
            XCTAssertNil(TransformService.apply(transform, to: "   "), transform.rawValue)
            XCTAssertNil(TransformService.apply(transform, to: "!!! ---"), transform.rawValue)
        }
    }

    // MARK: - Colors

    func testHexColorConvertsFromEveryNotation() {
        XCTAssertEqual(TransformService.apply(.hexColor, to: "#336699"), "#336699")
        XCTAssertEqual(TransformService.apply(.hexColor, to: "rgb(51, 102, 153)"), "#336699")
        XCTAssertEqual(TransformService.apply(.hexColor, to: "hsl(210, 50%, 40%)"), "#336699")
        XCTAssertEqual(TransformService.apply(.hexColor, to: "#ff0000"), "#FF0000")
    }

    func testRGBColorConvertsFromEveryNotation() {
        XCTAssertEqual(TransformService.apply(.rgbColor, to: "#336699"), "rgb(51, 102, 153)")
        XCTAssertEqual(TransformService.apply(.rgbColor, to: "hsl(210, 50%, 40%)"), "rgb(51, 102, 153)")
        XCTAssertEqual(TransformService.apply(.rgbColor, to: "RGB(51,102,153)"), "rgb(51, 102, 153)")
    }

    func testHSLColorConvertsFromEveryNotation() {
        XCTAssertEqual(TransformService.apply(.hslColor, to: "#FF0000"), "hsl(0, 100%, 50%)")
        XCTAssertEqual(TransformService.apply(.hslColor, to: "rgb(51, 102, 153)"), "hsl(210, 50%, 40%)")
        XCTAssertEqual(TransformService.apply(.hslColor, to: "#000000"), "hsl(0, 0%, 0%)")
    }

    func testHexColorRoundTripsThroughHSL() throws {
        for hex in ["#FF0000", "#336699", "#00FF00", "#808080"] {
            let hsl = try XCTUnwrap(TransformService.apply(.hslColor, to: hex), hex)
            XCTAssertEqual(TransformService.apply(.hexColor, to: hsl), hex, hsl)
            let rgb = try XCTUnwrap(TransformService.apply(.rgbColor, to: hsl), hsl)
            XCTAssertEqual(TransformService.apply(.hexColor, to: rgb), hex, rgb)
        }
    }

    func testColorTransformsCarryAlphaThrough() {
        XCTAssertEqual(TransformService.apply(.hexColor, to: "rgba(255, 0, 0, 0.5)"), "#FF000080")
        XCTAssertEqual(TransformService.apply(.rgbColor, to: "#FF000080"), "rgba(255, 0, 0, 0.502)")
        XCTAssertEqual(TransformService.apply(.hslColor, to: "rgba(255, 0, 0, 0.25)"), "hsla(0, 100%, 50%, 0.25)")
    }

    func testColorTransformsRejectTextThatIsNotAColor() {
        for transform: Transform in [.hexColor, .rgbColor, .hslColor] {
            XCTAssertNil(TransformService.apply(transform, to: "hello"), transform.rawValue)
            // No "#": otherwise every six-digit number in the history is a colour.
            XCTAssertNil(TransformService.apply(transform, to: "336699"), transform.rawValue)
            XCTAssertNil(TransformService.apply(transform, to: "#12345"), transform.rawValue)
            XCTAssertNil(TransformService.apply(transform, to: "rgb(51, 102)"), transform.rawValue)
            XCTAssertNil(TransformService.apply(transform, to: "hsl(red, green, blue)"), transform.rawValue)
        }
    }

    // MARK: - Timestamps

    func testEpochToDateReadsSecondsAndMilliseconds() {
        XCTAssertEqual(TransformService.apply(.epochToDate, to: "1700000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(TransformService.apply(.epochToDate, to: "1700000000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(TransformService.apply(.epochToDate, to: "0"), "1970-01-01T00:00:00Z")
        XCTAssertEqual(TransformService.apply(.epochToDate, to: " 1700000000 "), "2023-11-14T22:13:20Z")
    }

    func testDateToEpochReadsTheShapesPeoplePaste() {
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: "2023-11-14T22:13:20Z"), "1700000000")
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: "2023-11-14T22:13:20.500Z"), "1700000000")
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: "2023-11-14T23:13:20+01:00"), "1700000000")
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: "2023-11-14 22:13:20"), "1700000000")
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: "2023-11-14"), "1699920000")
    }

    func testTimestampsRoundTrip() throws {
        let written = try XCTUnwrap(TransformService.apply(.epochToDate, to: "1700000000"))
        XCTAssertEqual(TransformService.apply(.dateToEpoch, to: written), "1700000000")

        let read = try XCTUnwrap(TransformService.apply(.dateToEpoch, to: "2023-11-14T22:13:20Z"))
        XCTAssertEqual(TransformService.apply(.epochToDate, to: read), "2023-11-14T22:13:20Z")
    }

    func testEpochToDateRejectsTextThatIsNotANumber() {
        XCTAssertNil(TransformService.apply(.epochToDate, to: "hello"))
        XCTAssertNil(TransformService.apply(.epochToDate, to: ""))
        XCTAssertNil(TransformService.apply(.epochToDate, to: "2023-11-14"))
        // Beyond the four-digit years ISO 8601 can write.
        XCTAssertNil(TransformService.apply(.epochToDate, to: "999999999999999999"))
    }

    func testDateToEpochRejectsTextThatIsNotADate() {
        XCTAssertNil(TransformService.apply(.dateToEpoch, to: "hello"))
        XCTAssertNil(TransformService.apply(.dateToEpoch, to: "1700000000"))
        XCTAssertNil(TransformService.apply(.dateToEpoch, to: "2023-13-45"))
    }

    // MARK: - Whitespace

    func testTrimLinesTrimsBothEndsOfEveryLine() {
        XCTAssertEqual(TransformService.apply(.trimLines, to: "  a  \n\tb\t"), "a\nb")
    }

    func testTrimLinesKeepsTheLineCount() {
        XCTAssertEqual(TransformService.apply(.trimLines, to: "a\n   \nb"), "a\n\nb")
    }

    func testStripTrailingSpaceKeepsIndentation() {
        XCTAssertEqual(TransformService.apply(.stripTrailingSpace, to: "  a  \n\tb\t"), "  a\n\tb")
    }

    func testCollapseBlankLinesLeavesOneEmptyLinePerRun() {
        XCTAssertEqual(TransformService.apply(.collapseBlankLines, to: "a\n\n\n \nb"), "a\n\nb")
    }

    func testCollapseBlankLinesLeavesASingleGapAlone() {
        XCTAssertEqual(TransformService.apply(.collapseBlankLines, to: "a\n\nb"), "a\n\nb")
    }

    // MARK: - JSON

    func testJSONFormatRoundTripsAndSortsKeys() throws {
        let input = #"{"b":2,"a":1,"nested":{"z":true,"y":[3,2]}}"#
        let output = try XCTUnwrap(TransformService.apply(.jsonFormat, to: input))

        // Pretty output spans multiple lines and sorts keys.
        XCTAssertTrue(output.contains("\n"), "pretty output should span multiple lines: \(output)")
        // XCTUnwrap rather than `!`: a regression here must fail this test, not
        // crash the whole test process and take the rest of the suite with it.
        let aKey = try XCTUnwrap(output.range(of: "\"a\""), "key \"a\" missing from:\n\(output)")
        let bKey = try XCTUnwrap(output.range(of: "\"b\""), "key \"b\" missing from:\n\(output)")
        XCTAssertLessThan(aKey.lowerBound, bKey.lowerBound, "top-level keys are not sorted")

        let yKey = try XCTUnwrap(output.range(of: "\"y\""), "key \"y\" missing from:\n\(output)")
        let zKey = try XCTUnwrap(output.range(of: "\"z\""), "key \"z\" missing from:\n\(output)")
        XCTAssertLessThan(yKey.lowerBound, zKey.lowerBound, "nested keys are not sorted")

        // Re-parsed content must be identical to the input.
        let reparsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(reparsed["a"] as? Int, 1)
        XCTAssertEqual(reparsed["b"] as? Int, 2)
        XCTAssertEqual((reparsed["nested"] as? [String: Any])?["y"] as? [Int], [3, 2])
    }

    func testJSONFormatAcceptsFragments() throws {
        let output = try XCTUnwrap(TransformService.apply(.jsonFormat, to: "42"))
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testJSONFormatRejectsInvalidJSON() {
        XCTAssertNil(TransformService.apply(.jsonFormat, to: "{not json"))
        XCTAssertNil(TransformService.apply(.jsonFormat, to: "{'single': 'quotes'}"))
    }

    func testJSONMinify() {
        let input = """
        {
          "a" : 1,
          "b" : [1, 2]
        }
        """
        XCTAssertEqual(TransformService.apply(.jsonMinify, to: input), #"{"a":1,"b":[1,2]}"#)
    }

    func testJSONMinifyRejectsInvalidJSON() {
        XCTAssertNil(TransformService.apply(.jsonMinify, to: "{oops"))
    }

    // MARK: - Base64

    func testBase64Encode() {
        XCTAssertEqual(TransformService.apply(.base64Encode, to: "hello"), "aGVsbG8=")
    }

    func testBase64Decode() {
        XCTAssertEqual(TransformService.apply(.base64Decode, to: "aGVsbG8="), "hello")
    }

    func testBase64DecodeRejectsGarbage() {
        XCTAssertNil(TransformService.apply(.base64Decode, to: "!!!not-base64!!!"))
        XCTAssertNil(TransformService.apply(.base64Decode, to: "abc")) // invalid length
    }

    // MARK: - URL encoding

    func testURLEncode() {
        XCTAssertEqual(TransformService.apply(.urlEncode, to: "a b&c=d"), "a%20b&c=d")
    }

    func testURLDecode() {
        XCTAssertEqual(TransformService.apply(.urlDecode, to: "a%20b%26c"), "a b&c")
    }

    func testURLDecodeRejectsBrokenEscapes() {
        XCTAssertNil(TransformService.apply(.urlDecode, to: "100%"))
        XCTAssertNil(TransformService.apply(.urlDecode, to: "%zz"))
    }

    // MARK: - Line transforms

    func testSortLinesSortsCaseInsensitively() {
        let input = "banana\napple\nCherry"
        XCTAssertEqual(TransformService.apply(.sortLines, to: input), "apple\nbanana\nCherry")
    }

    func testSortLinesKeepsAllLines() {
        XCTAssertEqual(TransformService.apply(.sortLines, to: "b\n\na"), "\na\nb")
    }

    func testDedupeLinesKeepsFirstOccurrenceCaseSensitively() {
        let input = "a\nb\na\nB\nb"
        XCTAssertEqual(TransformService.apply(.dedupeLines, to: input), "a\nb\nB")
    }

    func testReverseLines() {
        XCTAssertEqual(TransformService.apply(.reverseLines, to: "a\nb\nc"), "c\nb\na")
    }

    func testReverseLinesRoundTrips() throws {
        let input = "first\n\nthird"
        let reversed = try XCTUnwrap(TransformService.apply(.reverseLines, to: input))
        XCTAssertEqual(TransformService.apply(.reverseLines, to: reversed), input)
    }

    func testNumberLines() {
        XCTAssertEqual(TransformService.apply(.numberLines, to: "a\nb\nc"), "1. a\n2. b\n3. c")
    }

    func testNumberLinesRightAlignsPastNine() throws {
        let input = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let output = try XCTUnwrap(TransformService.apply(.numberLines, to: input))
        let numbered = output.components(separatedBy: "\n")
        XCTAssertEqual(numbered.first, " 1. line 1")
        XCTAssertEqual(numbered.last, "10. line 10")
    }

    // MARK: - Metadata

    /// Menu invariants: every transform is presentable and no two rows would
    /// render identically. (`appliesToPlainText` and `id` are not asserted here
    /// — they are hardcoded `true` / `rawValue`, so any such check would be a
    /// literal compared to itself and could never fail.)
    func testEveryTransformHasAUniqueNonEmptyLabel() {
        XCTAssertEqual(
            Transform.allCases.count, 25,
            "the transform menu changed size — add or remove the matching behaviour test above"
        )
        for transform in Transform.allCases {
            XCTAssertFalse(transform.label.isEmpty, "\(transform.rawValue) has no menu label")
        }
        let labels = Transform.allCases.map(\.label)
        XCTAssertEqual(
            Set(labels).count, labels.count,
            "duplicate transform labels would render as indistinguishable menu rows: \(labels)"
        )
    }
}
