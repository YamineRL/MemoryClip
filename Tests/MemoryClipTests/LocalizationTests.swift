import XCTest
import Foundation

@testable import MemoryClip

/// The string catalogue: that it ships, that it is found in the SwiftPM
/// resource bundle, that French resolves, and that every key the sources ask
/// for is in both languages with the same format specifiers.
final class LocalizationTests: XCTestCase {
    // MARK: Catalogue

    func testCatalogueShipsEnglishAndFrench() async throws {
        XCTAssertEqual(Set(L10n.available), ["en", "fr"])
    }

    func testEveryLocalizationLoadsItsOwnBundle() async throws {
        for code in L10n.available {
            let bundle = L10n.resolveBundle(code: code)
            XCTAssertNotEqual(bundle.bundleURL, L10n.catalogue.bundleURL, "\(code) has no .lproj")
            XCTAssertFalse(try Self.catalogue(code).isEmpty, "\(code) catalogue is empty")
        }
    }

    // MARK: Language resolution

    func testFrenchPreferencesResolveToFrench() async throws {
        XCTAssertEqual(L10n.resolveCode(preferences: ["fr"]), "fr")
        XCTAssertEqual(L10n.resolveCode(preferences: ["fr-FR"]), "fr")
        XCTAssertEqual(L10n.resolveCode(preferences: ["fr-CA", "en"]), "fr")
    }

    func testEveryOtherPreferenceResolvesToEnglish() async throws {
        XCTAssertEqual(L10n.resolveCode(preferences: ["en-GB"]), "en")
        XCTAssertEqual(L10n.resolveCode(preferences: ["de", "es"]), "en")
        XCTAssertEqual(L10n.resolveCode(preferences: []), "en")
    }

    // MARK: French values

    func testSampleKeysReadBackInFrench() async throws {
        let french = L10n.resolveBundle(code: "fr")
        let expected = [
            "Settings…": "Réglages…",
            "Paste": "Coller",
            "Delete": "Supprimer",
            "Cancel": "Annuler",
            "General": "Général",
            "History": "Historique",
            "Privacy": "Confidentialité",
            "Search clips": "Rechercher un clip",
            "Reveal in Finder": "Afficher dans le Finder",
            "Launch at login": "Lancer au démarrage",
            "Delete entire clipboard history?": "Supprimer tout l’historique du presse-papiers\u{00A0}?",
        ]
        for (key, value) in expected {
            XCTAssertEqual(L10n.string(key, in: french), value, key)
        }
    }

    func testFormattedKeysSubstituteInFrench() async throws {
        let french = L10n.resolveBundle(code: "fr")
        let format = L10n.string("Keep up to %d clips", in: french)
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "fr"), 200), "Conserver jusqu’à 200 clips")
    }

    // MARK: Catalogue completeness

    func testEnglishCatalogueMapsEveryKeyToItself() async throws {
        for (key, value) in try Self.catalogue("en") {
            XCTAssertEqual(key, value, "English catalogue rewrites \(key)")
        }
    }

    func testEveryEnglishKeyHasAFrenchValue() async throws {
        let english = try Self.catalogue("en")
        let french = try Self.catalogue("fr")
        for key in english.keys.sorted() {
            guard let translation = french[key] else {
                XCTFail("No French value for \(key)")
                continue
            }
            XCTAssertFalse(translation.isEmpty, "Empty French value for \(key)")
        }
    }

    func testFrenchCatalogueHasNoOrphanKeys() async throws {
        let english = try Self.catalogue("en")
        let french = try Self.catalogue("fr")
        for key in french.keys.sorted() where english[key] == nil {
            XCTFail("French catalogue has a key the English one does not: \(key)")
        }
    }

    func testFrenchFollowsFrenchTypography() async throws {
        for (key, translation) in try Self.catalogue("fr") {
            XCTAssertFalse(translation.contains("'"), "Straight apostrophe in \(key)")
            for mark in [":", ";", "!", "?"] {
                XCTAssertFalse(translation.contains(" " + mark), "Breaking space before \(mark) in \(key)")
            }
            XCTAssertFalse(translation.contains("« "), "Breaking space after « in \(key)")
            XCTAssertFalse(translation.contains(" »"), "Breaking space before » in \(key)")
        }
    }

    func testTranslationsKeepTheirFormatSpecifiers() async throws {
        for (key, translation) in try Self.catalogue("fr") {
            XCTAssertEqual(
                Self.specifiers(in: key),
                Self.specifiers(in: translation),
                "Format specifiers differ for \(key)"
            )
        }
    }

    // MARK: The sources

    func testEveryKeyTheSourcesAskForIsInTheCatalogue() async throws {
        let english = try Self.catalogue("en")
        for (file, key) in try Self.locCalls() where english[key] == nil {
            XCTFail("\(file) asks for a key the catalogue does not have: \(key)")
        }
    }

    func testNoMigratedStringIsStillAHardcodedLiteral() async throws {
        let keys = Set(try Self.catalogue("en").keys)
        for (file, text) in try Self.sources() where text.contains("loc(") {
            for match in Self.quotedLiterals(in: Self.withoutComments(text)) where keys.contains(match.literal) {
                XCTAssertTrue(
                    match.isLocalized,
                    "\(file) still has \"\(match.literal)\" as a bare literal"
                )
            }
        }
    }

    // MARK: Fixtures

    private static func catalogue(_ code: String) throws -> [String: String] {
        let bundle = L10n.resolveBundle(code: code)
        let url = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings"),
            "\(code) has no Localizable.strings"
        )
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(code) is not a strings file")
    }

    /// `%d` / `%@` and friends, in the order they appear.
    private static func specifiers(in text: String) -> [String] {
        matches(of: "%[0-9]*[@dfs]", in: text).map { String(text[Range($0.range, in: text)!]) }
    }

    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/MemoryClip")

    private static func sources() throws -> [(file: String, text: String)] {
        let manager = FileManager.default
        let enumerator = try XCTUnwrap(manager.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(found.isEmpty, "No sources under \(root.path())")
        return found
    }

    private static func locCalls() throws -> [(file: String, key: String)] {
        var found: [(String, String)] = []
        for (file, text) in try sources() {
            for match in matches(of: "loc\\(\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: text) {
                found.append((file, unescape(String(text[Range(match.range(at: 1), in: text)!]))))
            }
        }
        return found
    }

    /// Every double-quoted literal, and whether `loc(` opens it.
    private static func quotedLiterals(in text: String) -> [(literal: String, isLocalized: Bool)] {
        matches(of: "(loc\\(\\s*)?\"((?:\\\\.|[^\"\\\\\\n])*)\"", in: text).map { match in
            (unescape(String(text[Range(match.range(at: 2), in: text)!])), match.range(at: 1).location != NSNotFound)
        }
    }

    /// `//` lines dropped, so prose quoting a UI string is not read as one.
    private static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func matches(of pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The escapes a Swift literal can carry that also change a catalogue key.
    private static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
