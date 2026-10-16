import XCTest

@testable import MemoryClip

@MainActor
final class PaletteActionTests: XCTestCase {
    private func makeItem(_ kind: ClipKind = .text, text: String?) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            richTextData: nil,
            imageData: nil,
            fileURLStrings: [],
            colorHex: nil,
            contentHash: UUID().uuidString
        )
    }

    /// Text each transform has something to do to. A switch rather than a
    /// table, so a new `Transform` case does not compile until it has one.
    private func sample(for transform: Transform) -> (ClipKind, String) {
        switch transform {
        case .uppercased: (.text, "hello")
        case .lowercased: (.text, "HELLO")
        case .titleCase: (.text, "hello world")
        case .snakeCase: (.text, "helloWorld")
        case .camelCase: (.text, "hello_world")
        case .kebabCase: (.text, "hello world")
        case .screamingSnakeCase: (.text, "hello world")
        case .jsonFormat: (.text, #"{"a":1}"#)
        case .jsonMinify: (.text, "{\n  \"a\": 1\n}")
        case .base64Encode: (.text, "hello")
        case .base64Decode: (.text, "aGVsbG8=")
        case .urlEncode: (.text, "a b")
        case .urlDecode: (.text, "a%20b")
        case .hexColor: (.text, "rgb(51, 102, 153)")
        case .rgbColor: (.text, "#336699")
        case .hslColor: (.text, "#336699")
        case .epochToDate: (.text, "1700000000")
        case .dateToEpoch: (.text, "2023-11-14T22:13:20Z")
        case .trimLines: (.text, "  a  \n  b  ")
        case .stripTrailingSpace: (.text, "a  \nb")
        case .collapseBlankLines: (.text, "a\n\n\n\nb")
        case .sortLines: (.text, "b\na")
        case .dedupeLines: (.text, "a\na")
        case .reverseLines: (.text, "a\nb")
        case .numberLines: (.text, "a\nb")
        case .cleanLink: (.link, "https://www.instagram.com/reel/x/?igsh=abc")
        }
    }

    // MARK: The catalogue

    func testEveryTransformIsInTheCatalogue() {
        for transform in Transform.allCases {
            XCTAssertTrue(PaletteAction.Command.all.contains(.transform(transform)), "\(transform) missing")
        }
    }

    func testEveryTransformAppearsInThePaletteForAClipItChanges() {
        for transform in Transform.allCases {
            let (kind, text) = sample(for: transform)
            let offered = PaletteAction.available(for: makeItem(kind, text: text)).map(\.command)
            XCTAssertTrue(offered.contains(.transform(transform)), "\(transform) not offered for \(text)")
        }
    }

    func testIDsAreUniqueBecauseTheyKeyTheRunCounts() {
        let ids = PaletteAction.Command.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: Menu and palette agree

    func testMenuAndPaletteOfferTheSameSet() {
        let link = makeItem(.link, text: "https://example.com/?utm_source=x")
        let screenshot = makeItem(.file, text: nil)
        screenshot.isScreenshot = true
        let secret = makeItem(.text, text: nil)
        secret.isSecret = true
        let clips = [
            makeItem(text: #"{"a":1}"#),
            makeItem(text: "Dinner Saturday at 8"),
            makeItem(text: "HELLO"),
            link,
            screenshot,
            secret,
        ]
        for clip in clips {
            let palette = Set(PaletteAction.available(for: clip).map(\.command))
            let menu = ClipCardView.menuCommands(
                for: clip,
                transforms: PaletteAction.applicableTransforms(to: clip.text)
            )
            XCTAssertEqual(menu, palette, "\(clip.kind) \(clip.text ?? "nil")")
        }
    }

    // MARK: Applicability

    func testOnlyTransformsThatChangeTheTextAreOffered() {
        let offered = PaletteAction.available(for: makeItem(text: #"{"a":1}"#)).map(\.command)
        XCTAssertTrue(offered.contains(.transform(.jsonFormat)))
        XCTAssertFalse(offered.contains(.transform(.base64Decode)), "not Base64")
        XCTAssertFalse(offered.contains(.transform(.jsonMinify)), "already minified")
    }

    func testEachOfferedActionIsApplicable() {
        let clip = makeItem(text: "hello world")
        for action in PaletteAction.available(for: clip) {
            XCTAssertTrue(action.isApplicable(to: clip), action.id)
        }
    }

    func testASecretOffersOnlyWhatActsOnCiphertext() {
        let secret = makeItem(.text, text: nil)
        secret.isSecret = true
        XCTAssertEqual(Set(PaletteAction.available(for: secret).map(\.command)), [.copy, .toggleQueue])
    }

    func testLinkAndScreenshotCommandsFollowTheKind() {
        let link = PaletteAction.available(for: makeItem(.link, text: "https://example.com")).map(\.command)
        XCTAssertTrue(link.contains(.showQR))
        XCTAssertFalse(link.contains(.revealInFinder))
        let screenshot = makeItem(.file, text: nil)
        screenshot.isScreenshot = true
        let commands = PaletteAction.available(for: screenshot).map(\.command)
        XCTAssertTrue(commands.contains(.revealInFinder))
        XCTAssertFalse(commands.contains(.showQR))
    }

    func testTitlesSayWhatASecondRunDoes() {
        let clip = makeItem(text: "hello")
        clip.notePath = "/tmp/hello.md"
        let actions = PaletteAction.available(for: clip, isQueued: true)
        XCTAssertEqual(actions.first { $0.command == .saveNote }?.title, loc("Update Note"))
        XCTAssertEqual(actions.first { $0.command == .toggleQueue }?.title, loc("Remove from Queue"))
    }

    // MARK: Ranking

    func testJSONQueryPutsFormatFirst() {
        let actions = PaletteAction.available(for: makeItem(text: #"{"a":1}"#))
        let rows = PaletteAction.ranked(actions, query: "json", counts: [:])
        XCTAssertEqual(rows.first?.command, .transform(.jsonFormat))
    }

    func testRunCountsRaiseAnAction() {
        let actions = PaletteAction.available(for: makeItem(text: "hello world"))
        let upper = PaletteAction.Command.transform(.uppercased)
        let rows = PaletteAction.ranked(actions, query: "", counts: [upper.id: 3])
        XCTAssertEqual(rows.first?.command, upper)
    }

    func testTitleMatchesOutrankGroupMatches() {
        // Both sit in the Clip group; only one says "clip" in its title,
        // and it leads even though the other has been run more.
        let groupOnly = PaletteAction(command: .copy, title: "Copy")
        let titled = PaletteAction(command: .pastePlain, title: "Clip it")
        let rows = PaletteAction.ranked([groupOnly, titled], query: "clip", counts: [groupOnly.id: 9])
        XCTAssertEqual(rows.map(\.command), [.pastePlain, .copy])
    }

    func testAQueryMatchingNothingGivesNoRows() {
        let actions = PaletteAction.available(for: makeItem(text: "hello"))
        XCTAssertTrue(PaletteAction.ranked(actions, query: "zzzz", counts: [:]).isEmpty)
    }

    func testRunCountsPersistAsCountsOnly() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "palette-tests-\(UUID().uuidString)"))
        let counts = PaletteRunCounts(defaults: defaults)
        counts.record("copy")
        counts.record("copy")
        counts.record("transform.jsonFormat")
        XCTAssertEqual(counts.load(), ["copy": 2, "transform.jsonFormat": 1])
    }

    // MARK: Return

    func testReturnModifiersPickTheMode() {
        XCTAssertEqual(CommandPaletteView.mode(for: []), .paste)
        XCTAssertEqual(CommandPaletteView.mode(for: .command), .replace)
        XCTAssertEqual(CommandPaletteView.mode(for: .option), .copy)
        XCTAssertEqual(CommandPaletteView.mode(for: [.command, .option]), .replace)
    }
}
