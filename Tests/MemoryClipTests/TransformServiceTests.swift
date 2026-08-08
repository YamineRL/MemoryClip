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

    // MARK: - Metadata

    /// Menu invariants: every transform is presentable and no two rows would
    /// render identically. (`appliesToPlainText` and `id` are not asserted here
    /// — they are hardcoded `true` / `rawValue`, so any such check would be a
    /// literal compared to itself and could never fail.)
    func testEveryTransformHasAUniqueNonEmptyLabel() {
        XCTAssertEqual(
            Transform.allCases.count, 11,
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
