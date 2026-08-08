import XCTest

@testable import MemoryClip

final class SensitiveFilterTests: XCTestCase {
    private let key = SensitiveFilter.filteringEnabledKey

    override func tearDown() {
        // Leave the suite's UserDefaults exactly as found.
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Luhn card detection

    func testCardWithSpaces() {
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242 4242 4242 4242"))
    }

    func testCardWithDashes() {
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242-4242-4242-4242"))
    }

    func testCardWithoutSeparators() {
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242424242424242"))
    }

    func testCardWithATrailingStrayDigitIsStillBlocked() {
        // STAYS BLOCKED. 17 digits: a valid 16-digit card with one extra
        // character selected alongside it. The first four groups are a whole
        // group-aligned candidate (`4242 4242 4242 4242`), so the card is
        // found without any mid-run window; the stray "4" is simply excluded.
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242 4242 4242 4242 4"))
    }

    func testSixteenDigitRunFailingLuhnAsAWholeIsNoLongerBlocked() {
        // FLIPPED BACK to false. The only group-aligned 13…19 digit candidate
        // here is all 16 digits, and they fail Luhn. The 13-digit window that
        // used to trip this starts mid-group — exactly the coincidence the
        // boundary rule exists to reject. A grouped 16-digit reference that
        // fails Luhn is not a card.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("4242 4242 4242 4241"))
    }

    func testTwelveDigitsTooShort() {
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("424242424242"))
    }

    func testThirteenValidCard() {
        // 13-digit Luhn-valid number (old Visa style).
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242424242422"))
    }

    func testNineteenValidCard() {
        XCTAssertTrue(SensitiveFilter.isLikelyCardNumber("4242424242424242428"))
    }

    func testNineteenDigitsFailingLuhnAsAWholeIsNoLongerBlocked() {
        // FLIPPED BACK to false. One unbroken group of 19 digits offers
        // exactly one candidate — itself — and it fails Luhn. The 28
        // sub-windows that used to be tried all start or end mid-group.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("4242424242424242429"))
    }

    func testPlainSixteenDigitReferenceIsNotACard() {
        // FLIPPED BACK to false, and it fails on two counts: the full 16
        // digits fail Luhn, and "1" is not an issuer prefix in any case.
        // This is the canonical false positive the old rule produced.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("1234567890123456"))
    }

    func testTwelveDigitRunCannotContainACardWindow() {
        // Below 13 digits there is no candidate at all — never blocked,
        // regardless of content.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("123456789012"))
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("phone +1 555 0123 ext 4242"))
    }

    func testShortNumberIsNotACard() {
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("order id 987654321"))
    }

    func testEmbeddedCardAmongWords() {
        XCTAssertTrue(
            SensitiveFilter.isLikelyCardNumber("my card is 4242-4242-4242-4242 thanks")
        )
    }

    func testEmptyText() {
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber(""))
    }

    // MARK: - Credential-app matching (pure core)

    func testBlockedByExactBundleID() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "com.agilebits.onepassword7", name: nil))
    }

    func testBlockedBundleIDIsCaseInsensitive() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "COM.AGILEBITS.ONEPASSWORD7", name: nil))
    }

    func testBlockedKeychainAccessByName() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: nil, name: "Keychain Access"))
    }

    func testBlockedEnpassByName() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: nil, name: "Enpass"))
    }

    func testBlockedGenericPasswordName() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: nil, name: "My Password Vault"))
    }

    func testBlockedGenericVaultNameCaseInsensitive() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: nil, name: "bitwarden VAULT"))
    }

    func testSafariIsNotBlocked() {
        XCTAssertFalse(SensitiveFilter.isBlocked(bundleID: "com.apple.Safari", name: "Safari"))
    }

    func testNilNilIsNotBlocked() {
        XCTAssertFalse(SensitiveFilter.isBlocked(bundleID: nil, name: nil))
    }

    // MARK: - Evasion cases the longest-run-only check let through

    func testCardBesideALongerUnrelatedDigitRun() {
        // The 21-digit reference used to be the longest run, so the card was
        // never examined at all.
        XCTAssertTrue(
            SensitiveFilter.isLikelyCardNumber(
                "Card 4111 1111 1111 1111 — ref 123456789012345678901"
            )
        )
    }

    func testTwoCardsSeparatedByASpaceMergeIntoOneLongRun() {
        // A single space between them makes one 32-digit run, which is out of
        // the 13…19 band — both cards escaped.
        XCTAssertTrue(
            SensitiveFilter.isLikelyCardNumber("4111111111111111 4242424242424242")
        )
    }

    func testCardAtTheEndOfALogLineWithALongTimestamp() {
        XCTAssertTrue(
            SensitiveFilter.isLikelyCardNumber(
                "20260807120000123456789012345 charge ok pan=4242424242424242"
            )
        )
    }

    // MARK: - Credential apps: current bundle identifiers

    func testBlocked1Password8() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "com.1password.1password", name: nil))
    }

    func testBlockedApplePasswords() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "com.apple.Passwords", name: nil))
    }

    func testBlockedProtonPass() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "me.proton.pass", name: nil))
    }

    func testBlockedStrongbox() {
        XCTAssertTrue(SensitiveFilter.isBlocked(bundleID: "com.markmcguill.strongbox.mac", name: nil))
    }

    func testBlockedHelperProcessOfAListedApp() {
        XCTAssertTrue(
            SensitiveFilter.isBlocked(bundleID: "com.1password.1password.helper", name: nil)
        )
    }

    // MARK: - Anchored bundle-ID matching

    func testUnrelatedAppMerelyContainingAListedIDIsNotBlocked() {
        // Substring matching blocked these; anchored matching does not.
        XCTAssertFalse(
            SensitiveFilter.isBlocked(bundleID: "com.example.com.bitwarden.desktop.viewer", name: nil)
        )
        XCTAssertFalse(
            SensitiveFilter.isBlocked(bundleID: "org.notkeepassxc.keepassxc-clone", name: nil)
        )
    }

    func testSiblingIdentifierWithSharedPrefixIsNotBlocked() {
        XCTAssertFalse(SensitiveFilter.isBlocked(bundleID: "me.proton.passwords-unrelated", name: nil))
    }

    // MARK: - Enablement default

    func testFilteringEnabledDefaultsToTrueOnFreshKey() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(SensitiveFilter.isFilteringEnabled)
    }

    func testRegisterDefaultsEnablesFiltering() {
        UserDefaults.standard.removeObject(forKey: key)
        SensitiveFilter.registerDefaults()
        XCTAssertTrue(SensitiveFilter.isFilteringEnabled)
    }

    func testExplicitUserPreferenceWins() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(SensitiveFilter.isFilteringEnabled)

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(SensitiveFilter.isFilteringEnabled)
    }

    // MARK: - Genuine cards across issuers
    //
    // Published, non-functional test numbers (Stripe / Adyen / network test
    // suites). Every one must be caught in every form a user might copy it in.

    private static let testCards: [(issuer: String, number: String)] = [
        ("Visa 16", "4111111111111111"),
        ("Visa 16", "4242424242424242"),
        ("Visa 16", "4000056655665556"),
        ("Visa 16", "4444333322221111"),
        ("Visa 13", "4222222222222"),
        ("Mastercard", "5555555555554444"),
        ("Mastercard", "5105105105105100"),
        ("Mastercard 2-series", "2223003122003222"),
        ("Amex", "378282246310005"),
        ("Amex", "371449635398431"),
        ("Discover", "6011111111111117"),
        ("Discover", "6011000990139424"),
        ("Discover", "6011981111111113"),
        ("JCB", "3530111333300000"),
        ("JCB", "3566002020360505"),
        ("Diners", "30569309025904"),
        ("Diners", "38520000023237"),
        ("Diners", "36227206271667"),
        ("UnionPay", "6200000000000005"),
        ("UnionPay", "6212345678901232"),
        ("UnionPay 19", "6205500000000000004"),
        ("Maestro", "6759649826438453"),
        ("Maestro", "5018000000000009"),
    ]

    /// Split into card-like groups: fours, with a short tail merged into the
    /// preceding group so no group is under 3 digits (13 -> 4-4-5,
    /// 15 -> 4-4-4-3, 19 -> 4-4-4-4-3).
    private func grouped(_ number: String, separator: String) -> String {
        var groups: [String] = []
        var index = number.startIndex
        while index < number.endIndex {
            let end = number.index(index, offsetBy: 4, limitedBy: number.endIndex) ?? number.endIndex
            groups.append(String(number[index..<end]))
            index = end
        }
        if let last = groups.last, last.count < 3, groups.count > 1 {
            groups.removeLast()
            groups[groups.count - 1] += last
        }
        return groups.joined(separator: separator)
    }

    func testGenuineCardsAreCaughtBareSpacedAndDashed() {
        for card in Self.testCards {
            let spaced = grouped(card.number, separator: " ")
            let dashed = grouped(card.number, separator: "-")
            XCTAssertTrue(
                SensitiveFilter.isLikelyCardNumber(card.number),
                "\(card.issuer) bare: \(card.number)"
            )
            XCTAssertTrue(
                SensitiveFilter.isLikelyCardNumber(spaced),
                "\(card.issuer) spaced: \(spaced)"
            )
            XCTAssertTrue(
                SensitiveFilter.isLikelyCardNumber(dashed),
                "\(card.issuer) dashed: \(dashed)"
            )
        }
    }

    func testGenuineCardsAreCaughtInContext() {
        for card in Self.testCards {
            let spaced = grouped(card.number, separator: " ")
            let contexts = [
                "my card is \(card.number)",
                "my card is \(spaced), cvc 123",
                "\(card.number)\nexpires 05/28",
                "\(spaced)\n05/28\n123",
                "pan=\(card.number);amount=1000",
                "Please charge \(spaced) — thanks!",
            ]
            for context in contexts {
                XCTAssertTrue(
                    SensitiveFilter.isLikelyCardNumber(context),
                    "\(card.issuer) in context: \(context)"
                )
            }
        }
    }

    func testGenuineCardIsCaughtBesideOtherLongNumbers() {
        // Combination of the evasion shapes: card + long reference + long
        // grouped reference, all in one clip.
        XCTAssertTrue(
            SensitiveFilter.isLikelyCardNumber(
                "inv 987654321098765432109 / 1234 5678 9012 3456 7890 / 5555 5555 5555 4444"
            )
        )
    }

    // MARK: - False-positive rate on random non-card digit strings

    /// SplitMix64 — a fixed-seed generator so the measurement below is
    /// deterministic (`Int.random` would make this test flaky).
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The previous rule, reimplemented here so the improvement is measured
    /// rather than asserted: slide every 13…19 digit window across every run
    /// and block on any Luhn-valid window.
    private func oldSlidingWindowRule(_ text: String) -> Bool {
        func luhn(_ digits: ArraySlice<Int>) -> Bool {
            var sum = 0
            for (index, digit) in digits.reversed().enumerated() {
                if index.isMultiple(of: 2) {
                    sum += digit
                } else {
                    let doubled = digit * 2
                    sum += doubled > 9 ? doubled - 9 : doubled
                }
            }
            return sum.isMultiple(of: 10)
        }
        for groups in SensitiveFilter.digitGroupRuns(in: text) {
            let run = groups.flatMap { $0 }
            guard run.count >= 13 else { continue }
            for length in 13...min(19, run.count) {
                var start = 0
                while start + length <= run.count {
                    if luhn(run[start..<(start + length)]) { return true }
                    start += 1
                }
            }
        }
        return false
    }

    /// 10,000 non-card clips in the shapes users actually copy: order
    /// numbers, tracking numbers, timestamped log lines, reference IDs and
    /// grouped references.
    private func nonCardSamples(count: Int) -> [String] {
        var rng = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
        func digits(_ n: Int) -> String {
            String((0..<n).map { _ in Character(String(Int.random(in: 0...9, using: &rng))) })
        }
        var samples: [String] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            switch index % 6 {
            case 0:
                samples.append("Order #\(digits(Int.random(in: 10...20, using: &rng)))")
            case 1:
                samples.append("Tracking: \(digits(Int.random(in: 12...22, using: &rng)))")
            case 2:
                samples.append("2026\(digits(Int.random(in: 9...16, using: &rng))) request ok")
            case 3:
                samples.append("ref-\(digits(Int.random(in: 13...19, using: &rng)))")
            case 4:
                // Grouped reference: 3-6 groups of four, the shape closest to
                // a written card and therefore the hardest case for the rule.
                let groups = Int.random(in: 3...6, using: &rng)
                samples.append((0..<groups).map { _ in digits(4) }.joined(separator: " "))
            default:
                samples.append("acct \(digits(Int.random(in: 14...18, using: &rng))) balance 1234")
            }
        }
        return samples
    }

    func testFalsePositiveRateOnRandomNonCardDigitStrings() {
        let samples = nonCardSamples(count: 10_000)
        let oldHits = samples.count(where: oldSlidingWindowRule)
        let newHits = samples.count(where: SensitiveFilter.isLikelyCardNumber)
        let oldRate = Double(oldHits) / Double(samples.count)
        let newRate = Double(newHits) / Double(samples.count)

        // Threshold: 6%. A uniformly random digit string is not merely
        // "not a card" — roughly 3% of random 16-digit strings genuinely do
        // carry a real issuer prefix AND pass Luhn (about 30% of the prefix
        // space is assigned, times the 1-in-10 Luhn chance), and no checksum
        // filter can tell those from a real card. That ~3% is the floor;
        // 6% leaves headroom for the grouped-reference shape, which offers
        // several group-aligned candidates per sample.
        XCTAssertLessThan(
            newRate, 0.06,
            "false-positive rate \(newRate) (was \(oldRate) under the sliding-window rule)"
        )
        // And it must be a large improvement, not a rounding difference.
        XCTAssertLessThan(newRate, oldRate / 5.0, "old \(oldRate) -> new \(newRate)")
        print("card-number FP rate: old \(oldRate), new \(newRate)")
    }

    // MARK: - Non-cards the boundary and IIN rules now let through

    func testLongReferenceNumbersAreNoLongerBlocked() {
        // Each of these contains a Luhn-valid 13…19 digit sub-window and was
        // dropped from the user's history by the sliding-window rule.
        let references = [
            "1234567890123456",
            "invoice 900012345678901234",
            "UPS 1Z999AA10123456784",
            "20260807120000123456",
            "9876543210987654321",
        ]
        for reference in references {
            XCTAssertFalse(
                SensitiveFilter.isLikelyCardNumber(reference),
                "should not be treated as a card: \(reference)"
            )
        }
    }

    func testGroupedNumberWithNoIssuerPrefixIsNotACard() {
        // Group-aligned and Luhn-valid, but "1234" is not an issuer range.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("1234 5678 9012 3452"))
    }

    func testCardDigitsBuriedInALongerUnbrokenRunAreNotDetected() {
        // Documented limitation: no separator and no run boundary around the
        // card, so there is no group-aligned candidate. Detecting this shape
        // is what produced the false-positive flood.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("ref20244242424242424242xyz"))
    }

    func testImplausibleGroupingIsNotDetected() {
        // Documented limitation: real cards are not written in ones and twos,
        // so groups under three digits do not form a candidate.
        XCTAssertFalse(SensitiveFilter.isLikelyCardNumber("4 2 4 2 4 2 4 2 4 2 4 2 4 2 4 2"))
    }
}
