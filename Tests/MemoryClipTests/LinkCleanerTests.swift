import AppKit
import XCTest

@testable import MemoryClip

/// The link cleaner, driven through its pure core.
///
/// The corpus is the specification: one row per site MemoryClip claims to
/// clean, plus the rows that must come back untouched. A site that changes its
/// parameter names is a failing row here before it is a wrong clip in the
/// panel.
final class LinkCleanerTests: XCTestCase {
    // MARK: Helpers

    /// The cleaned URL, failing the test when nothing was cleaned.
    private func cleaned(
        _ url: String,
        options: LinkCleaner.Options = .default,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(LinkCleaner.clean(url, options: options), "\(url) was not cleaned", file: file, line: line).url
    }

    /// Assert a URL is returned exactly as it went in.
    private func assertUnchanged(
        _ url: String,
        options: LinkCleaner.Options = .default,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            LinkCleaner.clean(url, options: options),
            "\(url) should have been left alone",
            file: file,
            line: line
        )
    }

    // MARK: The manual acceptance check

    /// The URL the PRD is written around: an Instagram reel with the share
    /// identifier Instagram attaches when you copy the link.
    func testTheInstagramReelFromThePRD() throws {
        XCTAssertEqual(
            try cleaned("https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ=="),
            "https://www.instagram.com/reel/DbGys85Oyxx/"
        )
    }

    // MARK: Tier 1 — global parameters

    func testGlobalIdentifiersAreRemovedOnAnyHost() throws {
        let corpus: [(String, String)] = [
            ("https://example.com/a?fbclid=IwAR123", "https://example.com/a"),
            ("https://example.com/a?gclid=Cj0KCQ&page=2", "https://example.com/a?page=2"),
            ("https://example.com/a?dclid=x&y=1", "https://example.com/a?y=1"),
            ("https://example.com/a?gbraid=1&wbraid=2&keep=3", "https://example.com/a?keep=3"),
            ("https://example.com/a?msclkid=abc", "https://example.com/a"),
            ("https://news.example.org/p?mc_cid=aa&mc_eid=bb&id=7", "https://news.example.org/p?id=7"),
            ("https://example.com/a?twclid=1&ttclid=2&yclid=3", "https://example.com/a"),
            ("https://example.com/a?igshid=abc", "https://example.com/a"),
            ("https://example.com/a?_hsenc=p2&_hsmi=99&doc=4", "https://example.com/a?doc=4"),
            ("https://example.com/a?vero_id=1&oly_enc_id=2", "https://example.com/a"),
            ("https://example.com/a?ref_src=twsrc&wt_mc=email", "https://example.com/a"),
            ("https://example.com/a?pk_campaign=spring&pk_kwd=shoes&q=x", "https://example.com/a?q=x"),
        ]
        for (input, expected) in corpus {
            XCTAssertEqual(try cleaned(input), expected, input)
        }
    }

    func testCampaignParametersGoWithTheirOwnSwitch() throws {
        let url = "https://example.com/post?utm_source=newsletter&utm_medium=email&id=9"
        XCTAssertEqual(try cleaned(url), "https://example.com/post?id=9")

        let keeping = LinkCleaner.Options(removeCampaignParameters: false)
        assertUnchanged(url, options: keeping)
    }

    /// `utm_*` is a suffix wildcard, so a name that merely starts with the
    /// same letters must survive it.
    func testTheCampaignWildcardIsSuffixOnly() throws {
        XCTAssertEqual(
            try cleaned("https://example.com/a?utm_content=x&utmost=keep"),
            "https://example.com/a?utmost=keep"
        )
    }

    // MARK: Tier 2 — per-host parameters

    func testPerHostParametersAreRemovedOnTheirOwnHosts() throws {
        let corpus: [(String, String)] = [
            (
                "https://www.instagram.com/p/CxYz/?img_index=2",
                "https://www.instagram.com/p/CxYz/"
            ),
            (
                "https://www.youtube.com/watch?v=abc123&si=Kd9x_2Qb&utm_source=newsletter",
                "https://www.youtube.com/watch?v=abc123"
            ),
            ("https://youtu.be/abc123?si=Kd9x&t=42", "https://youtu.be/abc123?t=42"),
            ("https://www.youtube.com/watch?v=abc&feature=share&pp=xyz", "https://www.youtube.com/watch?v=abc"),
            ("https://x.com/user/status/1?s=20&t=abc", "https://x.com/user/status/1"),
            (
                "https://twitter.com/user/status/1?ref_src=twsrc%5Etfw&ref_url=https%3A%2F%2Fa.b",
                "https://twitter.com/user/status/1"
            ),
            ("https://www.amazon.com/dp/B0CX/?ref_=ast_sto&th=1&psc=1", "https://www.amazon.com/dp/B0CX/"),
            (
                "https://www.amazon.co.uk/dp/B0CX?pd_rd_w=1&pf_rd_p=2&qid=3&sr=8-1&dib=x",
                "https://www.amazon.co.uk/dp/B0CX"
            ),
            (
                "https://www.tiktok.com/@a/video/7?is_from_webapp=1&sender_device=pc&web_id=99",
                "https://www.tiktok.com/@a/video/7"
            ),
            ("https://www.facebook.com/groups/x?mibextid=abc&rdid=def", "https://www.facebook.com/groups/x"),
            (
                "https://www.linkedin.com/in/person?trackingId=aa&originalSubdomain=fr&rcm=bb",
                "https://www.linkedin.com/in/person"
            ),
            ("https://open.spotify.com/track/abc?si=deadbeef", "https://open.spotify.com/track/abc"),
            (
                "https://www.reddit.com/r/a/comments/b/c/?share_id=1&correlation_id=2&ref=share&ref_source=link",
                "https://www.reddit.com/r/a/comments/b/c/"
            ),
            (
                "https://www.ebay.com/itm/123?hash=item1&_trkparms=abc&_trksid=def",
                "https://www.ebay.com/itm/123"
            ),
            (
                "https://www.aliexpress.com/item/1.html?spm=a2g0o&algo_pvid=x&pdp_npi=y",
                "https://www.aliexpress.com/item/1.html"
            ),
        ]
        for (input, expected) in corpus {
            XCTAssertEqual(try cleaned(input), expected, input)
        }
    }

    /// The per-host tier is what keeps `si` a share identifier on YouTube and
    /// an ordinary parameter everywhere else.
    func testAPerHostParameterIsNotRemovedElsewhere() {
        assertUnchanged("https://example.com/a?si=1")
        assertUnchanged("https://example.com/search?s=shoes&t=5")
        assertUnchanged("https://example.com/list?qid=7&sr=2")
    }

    /// Rules match the registrable domain and every subdomain of it, and the
    /// `amazon.*` form covers the storefront TLDs from one row.
    func testHostMatchingCoversSubdomainsAndStorefronts() {
        XCTAssertTrue(LinkRules.host("instagram.com", matches: "instagram.com"))
        XCTAssertTrue(LinkRules.host("www.instagram.com", matches: "instagram.com"))
        XCTAssertFalse(LinkRules.host("notinstagram.com", matches: "instagram.com"))
        XCTAssertFalse(LinkRules.host("instagram.com.evil.net", matches: "instagram.com"))
        XCTAssertTrue(LinkRules.host("amazon.com", matches: "amazon.*"))
        XCTAssertTrue(LinkRules.host("www.amazon.co.uk", matches: "amazon.*"))
        XCTAssertTrue(LinkRules.host("smile.amazon.de", matches: "amazon.*"))
        XCTAssertFalse(LinkRules.host("amazon.a.b.example.com", matches: "amazon.*"))
    }

    // MARK: Tier 3 — the links that are left alone

    func testLinksThatMustComeBackUntouched() {
        // Nothing to remove.
        assertUnchanged("https://example.com/a")
        assertUnchanged("https://www.youtube.com/watch?v=abc123&t=42")
        assertUnchanged("https://example.com/a?page=2&sort=desc")
        // Not a web URL.
        assertUnchanged("mailto:someone@example.com?subject=utm_source")
        assertUnchanged("ftp://example.com/a?utm_source=x")
        assertUnchanged("not a url at all")
        // An empty query is not a query.
        assertUnchanged("https://example.com/a?")
        // Allowlisted hosts.
        assertUnchanged("https://docs.google.com/document/d/abc/edit?usp=sharing&utm_source=mail")
        assertUnchanged("https://drive.google.com/file/d/abc/view?usp=drive_link&fbclid=zz")
    }

    /// A URL that authenticates through its query string is one where any
    /// edit is a guess — so a credential-shaped name stops the clean dead,
    /// even when a rule would otherwise have fired on a different parameter.
    func testCredentialShapedParametersStopTheCleanEntirely() {
        for name in LinkRules.credentialParameters.sorted() {
            assertUnchanged("https://example.com/a?\(name)=abc123&utm_source=mail")
        }
        assertUnchanged("https://www.instagram.com/reel/x/?igsh=abc&token=zzz")
    }

    /// `sig` is a credential; `si` is YouTube's share identifier. Exact match
    /// only, or the per-host tier would never fire.
    func testCredentialMatchingIsExact() throws {
        XCTAssertEqual(
            try cleaned("https://youtu.be/abc?si=deadbeef"),
            "https://youtu.be/abc"
        )
    }

    func testAUserExcludedHostIsNeverCleaned() {
        let options = LinkCleaner.Options(excludedHosts: ["internal.example.com"])
        assertUnchanged("https://internal.example.com/report?utm_source=a&fbclid=b", options: options)
        assertUnchanged("https://build.internal.example.com/x?fbclid=b", options: options)
        // The exclusion is that host's, not everyone's.
        XCTAssertNotNil(LinkCleaner.clean("https://example.com/x?fbclid=b", options: options))
    }

    // MARK: Structure

    func testCleaningIsIdempotent() throws {
        let once = try cleaned("https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ==")
        assertUnchanged(once)
    }

    func testTheFragmentSurvives() throws {
        XCTAssertEqual(
            try cleaned("https://example.com/doc?utm_source=a&id=1#section-2"),
            "https://example.com/doc?id=1#section-2"
        )
        XCTAssertEqual(
            try cleaned("https://example.com/doc?fbclid=a#section-2"),
            "https://example.com/doc#section-2"
        )
    }

    func testParameterOrderAndEncodingAreUntouched() throws {
        XCTAssertEqual(
            try cleaned("https://example.com/s?q=a%20b%2Bc&fbclid=x&sort=%C3%A9"),
            "https://example.com/s?q=a%20b%2Bc&sort=%C3%A9"
        )
    }

    func testHostCasePortAndPathAreUntouched() throws {
        XCTAssertEqual(
            try cleaned("https://Example.COM:8443/A/B?utm_medium=x&Keep=1"),
            "https://Example.COM:8443/A/B?Keep=1"
        )
    }

    func testTheTrailingSeparatorGoesWithTheLastParameter() throws {
        XCTAssertEqual(try cleaned("https://example.com/a?fbclid=x&"), "https://example.com/a")
        XCTAssertEqual(try cleaned("https://example.com/a?keep=1&fbclid=x"), "https://example.com/a?keep=1")
        XCTAssertEqual(try cleaned("https://example.com/a?fbclid=x&keep=1"), "https://example.com/a?keep=1")
    }

    func testTheRemovedNamesAreReported() throws {
        let result = try XCTUnwrap(
            LinkCleaner.clean("https://www.youtube.com/watch?v=a&si=b&utm_source=c&fbclid=d")
        )
        XCTAssertEqual(result.removed, ["si", "utm_source", "fbclid"])
    }

    /// A scheme-less `www.` address is what `ContentParser` already classifies
    /// as a link, so it is cleaned too — and comes back without a scheme it
    /// never had.
    func testASchemelessAddressIsCleanedInPlace() throws {
        XCTAssertEqual(
            try cleaned("www.instagram.com/reel/x/?igsh=abc"),
            "www.instagram.com/reel/x/"
        )
    }

    // MARK: Exclusion-list entry

    func testTypedExclusionsAreReducedToTheHostTheyName() {
        XCTAssertEqual(LinkExclusions.normalize("  Example.COM "), "example.com")
        XCTAssertEqual(LinkExclusions.normalize("www.example.com"), "example.com")
        XCTAssertEqual(LinkExclusions.normalize("https://www.example.com/a/b?x=1"), "example.com")
        XCTAssertEqual(LinkExclusions.normalize("example.com:8443"), "example.com")
        XCTAssertNil(LinkExclusions.normalize(""))
        XCTAssertNil(LinkExclusions.normalize("nodot"))
        XCTAssertNil(LinkExclusions.normalize("two words.com"))
    }

    func testTheExclusionListStoresWhatItIsGiven() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "link-exclusions-\(UUID().uuidString)"))
        let exclusions = LinkExclusions(defaults: suite)
        XCTAssertEqual(exclusions.hosts, [])
        exclusions.add("https://Internal.Example.com/dashboard")
        exclusions.add("internal.example.com")
        XCTAssertEqual(exclusions.hosts, ["internal.example.com"], "a repeat must not be stored twice")
        exclusions.add("other.example.org")
        XCTAssertEqual(exclusions.hosts, ["internal.example.com", "other.example.org"])
        exclusions.remove("internal.example.com")
        XCTAssertEqual(exclusions.hosts, ["other.example.org"])
    }

    // MARK: The manual transform

    func testTheCleanLinkTransformSharesTheRules() {
        XCTAssertEqual(
            TransformService.apply(.cleanLink, to: "https://www.instagram.com/reel/x/?igsh=abc"),
            "https://www.instagram.com/reel/x/"
        )
        XCTAssertNil(
            TransformService.apply(.cleanLink, to: "https://example.com/a"),
            "a link with nothing to remove is an inapplicable transform"
        )
        XCTAssertNil(TransformService.apply(.cleanLink, to: "not a url"))
    }

    func testTheCleanLinkTransformIsFiledUnderLink() {
        XCTAssertEqual(Transform.cleanLink.group, .link)
        XCTAssertEqual(TransformGroup.link.transforms, [.cleanLink])
    }
}

/// The capture path with the cleaner wired into it, run the way
/// `PasteboardWatcher` actually runs it — the pure rules above are not proof
/// that a copied link reaches the store cleaned.
@MainActor
final class LinkCaptureTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: LinkSettingsKeys.cleanEnabled)
        UserDefaults.standard.set(true, forKey: LinkSettingsKeys.removeCampaignParameters)
        UserDefaults.standard.set([String](), forKey: LinkSettingsKeys.excludedHosts)
        UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
    }

    override func tearDown() {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
        for key in [
            LinkSettingsKeys.cleanEnabled,
            LinkSettingsKeys.removeCampaignParameters,
            LinkSettingsKeys.excludedHosts,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func makePasteboard(_ text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-links-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    private func capture(_ text: String, into store: ClipStore) -> Bool {
        let pasteboard = makePasteboard(text)
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        return watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil)
    }

    func testACopiedLinkIsStoredCleanedWithItsOriginalBeside() throws {
        let store = try ClipStore(inMemory: true)
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ=="
        XCTAssertTrue(capture(dirty, into: store))

        let item = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.text, "https://www.instagram.com/reel/DbGys85Oyxx/")
        XCTAssertEqual(item.originalText, dirty, "the escape hatch needs the URL as it was copied")
    }

    func testALinkWithNothingToRemoveKeepsNoOriginal() throws {
        let store = try ClipStore(inMemory: true)
        let url = "https://www.youtube.com/watch?v=abc123&t=42"
        XCTAssertTrue(capture(url, into: store))

        let item = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertEqual(item.text, url)
        XCTAssertNil(item.originalText, "an untouched link must not wear the Cleaned badge")
    }

    func testTheSwitchOffStoresTheLinkAsItWasCopied() throws {
        UserDefaults.standard.set(false, forKey: LinkSettingsKeys.cleanEnabled)
        let store = try ClipStore(inMemory: true)
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=abc"
        XCTAssertTrue(capture(dirty, into: store))

        let item = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertEqual(item.text, dirty)
        XCTAssertNil(item.originalText)
    }

    /// A link copied out of a browser page, a share sheet or any rich editor
    /// arrives with RTF beside the string. It is cleaned, stored as a link,
    /// and the pasteboard it came from is rewritten like any other link.
    func testALinkCopiedWithRTFBesideItIsStillCleaned() throws {
        let store = try ClipStore(inMemory: true)
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ=="
        let cleaned = "https://www.instagram.com/reel/DbGys85Oyxx/"
        let attributed = NSAttributedString(string: dirty, attributes: [.link: URL(string: dirty)!])
        let pasteboard = makePasteboard(dirty)
        pasteboard.setData(
            attributed.rtf(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )!,
            forType: .rtf
        )
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)

        XCTAssertTrue(watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))

        let item = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.text, cleaned)
        XCTAssertEqual(item.originalText, dirty)
        XCTAssertEqual(pasteboard.string(forType: .string), cleaned, "⌘V must paste the cleaned URL")
        XCTAssertNil(pasteboard.data(forType: .rtf), "no stale representation of the dirty URL survives")
    }

    // MARK: - The pasteboard the link was copied from

    func testCapturingADirtyLinkPutsTheCleanedURLBackOnThePasteboard() throws {
        let store = try ClipStore(inMemory: true)
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ=="
        let cleaned = "https://www.instagram.com/reel/DbGys85Oyxx/"
        let pasteboard = makePasteboard(dirty)
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)

        XCTAssertTrue(watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))

        XCTAssertEqual(pasteboard.string(forType: .string), cleaned, "⌘V must paste the cleaned URL")
        XCTAssertEqual(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")),
            cleaned,
            "the URL representation must not disagree with the plain text"
        )
        XCTAssertNil(pasteboard.data(forType: .rtf), "no stale representation of the dirty URL survives")
    }

    func testTheRewriteIsAlreadySuppressedAsOurOwnWrite() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard("https://www.instagram.com/reel/DbGys85Oyxx/?igsh=abc")
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)

        XCTAssertTrue(watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))

        XCTAssertEqual(
            watcher.lastChangeCount,
            pasteboard.changeCount,
            "the next poll must not capture the cleaned URL as a second clip"
        )
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    func testALinkWithNothingToRemoveLeavesThePasteboardAlone() throws {
        let store = try ClipStore(inMemory: true)
        let url = "https://www.youtube.com/watch?v=abc123&t=42"
        let pasteboard = makePasteboard(url)
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        let before = pasteboard.changeCount

        XCTAssertTrue(watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))

        XCTAssertEqual(pasteboard.string(forType: .string), url)
        XCTAssertEqual(pasteboard.changeCount, before, "an untouched link must not be rewritten")
    }

    func testTheSwitchOffLeavesThePasteboardAlone() throws {
        UserDefaults.standard.set(false, forKey: LinkSettingsKeys.cleanEnabled)
        let store = try ClipStore(inMemory: true)
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=abc"
        let pasteboard = makePasteboard(dirty)
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        let before = pasteboard.changeCount

        XCTAssertTrue(watcher.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))

        XCTAssertEqual(pasteboard.string(forType: .string), dirty)
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    /// The hash follows the stored text, so the same link copied twice with
    /// different tracking identifiers is one clip rather than two.
    func testTwoDirtyCopiesOfOneLinkDeduplicate() throws {
        let store = try ClipStore(inMemory: true)
        XCTAssertTrue(capture("https://www.instagram.com/reel/x/?igsh=aaa", into: store))
        XCTAssertTrue(capture("https://www.instagram.com/reel/x/?igsh=bbb", into: store))
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }
}
