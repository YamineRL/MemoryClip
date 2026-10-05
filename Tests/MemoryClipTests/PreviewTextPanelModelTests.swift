import XCTest

@testable import MemoryClip

/// The preview's text panel: which tabs it offers, when it may switch to the
/// translation on its own, and that its height never follows the text.
final class PreviewTextPanelModelTests: XCTestCase {
    // MARK: Tabs

    func testTheOriginalIsTheOnlyTabWithoutATranslation() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: false)
        XCTAssertEqual(model.availableTabs, [.original])
        XCTAssertEqual(model.visibleTab, .original)
    }

    func testBothTabsAreOfferedWhileTranslating() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        XCTAssertEqual(model.availableTabs, [.original, .translation])
    }

    func testBothTabsAreOfferedOnceTranslated() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.availableTabs, [.original, .translation])
    }

    /// A translation that goes away (a refresh, a cancelled run) must never
    /// leave the panel showing an empty tab.
    func testALostTranslationFallsBackToTheOriginal() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: true, isTranslating: false)
        model.pick(.translation)
        model.update(hasTranslation: false, isTranslating: false)
        XCTAssertEqual(model.availableTabs, [.original])
        XCTAssertEqual(model.visibleTab, .original)
    }

    // MARK: The automatic switch

    func testStreamingNeverSwitches() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        for _ in 0..<20 {
            model.update(hasTranslation: true, isTranslating: true)
            XCTAssertEqual(model.visibleTab, .original)
        }
    }

    func testCompletionSwitchesExactlyOnce() {
        var model = PreviewTextPanelModel()
        var switches = 0
        var shown = model.visibleTab
        func feed(_ hasTranslation: Bool, _ isTranslating: Bool) {
            model.update(hasTranslation: hasTranslation, isTranslating: isTranslating)
            if shown == .original, model.visibleTab == .translation { switches += 1 }
            shown = model.visibleTab
        }

        feed(false, true)
        for _ in 0..<5 { feed(true, true) }
        XCTAssertEqual(switches, 0)
        feed(true, false)
        XCTAssertEqual(switches, 1)
        XCTAssertEqual(model.visibleTab, .translation)

        // The same state again, as a second body pass would report it.
        feed(true, false)
        XCTAssertEqual(switches, 1)
    }

    /// A second run on the same clip (refinement landed after the user went
    /// back to the original) does not switch again: the one switch is spent.
    func testASecondRunOnTheSameClipDoesNotSwitchAgain() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .translation)
        model.pick(.original)

        model.update(hasTranslation: false, isTranslating: false)
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .original)
    }

    func testASecondRunWithoutAPickDoesNotSwitchTwice() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertTrue(model.didAutoSwitch)
        let selectedAfterFirst = model.selected

        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.selected, selectedAfterFirst)
        XCTAssertNil(model.explicitPick)
    }

    func testCompletionWithoutAResultDoesNotSwitch() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: false, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .original)
        XCTAssertFalse(model.didAutoSwitch)
    }

    func testAUserPickDuringStreamingIsNeverOverridden() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: true)
        model.pick(.original)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .original)
        XCTAssertFalse(model.didAutoSwitch)
    }

    func testAPickOfTheTranslationMidStreamStaysPut() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: true, isTranslating: true)
        model.pick(.translation)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .translation)
        XCTAssertEqual(model.explicitPick, .translation)
    }

    /// Without a session preference, a cached translation is offered but not
    /// switched to: only a run finishing switches.
    func testACachedTranslationOpensOnTheOriginalByDefault() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .original)
    }

    // MARK: Toggle

    func testToggleFlipsAndCountsAsAPick() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: true, isTranslating: true)
        model.toggle()
        XCTAssertEqual(model.visibleTab, .translation)
        XCTAssertEqual(model.explicitPick, .translation)
        model.toggle()
        XCTAssertEqual(model.visibleTab, .original)
        // Picked, so completion leaves it where the user put it.
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .original)
    }

    func testToggleDoesNothingWithOneTab() {
        var model = PreviewTextPanelModel()
        model.update(hasTranslation: false, isTranslating: false)
        model.toggle()
        XCTAssertEqual(model.visibleTab, .original)
        XCTAssertNil(model.explicitPick)
    }

    // MARK: Session preference

    func testAPreferenceForTheTranslationOpensACachedOneImmediately() {
        var first = PreviewTextPanelModel()
        first.update(hasTranslation: true, isTranslating: false)
        first.pick(.translation)

        var next = PreviewTextPanelModel(preference: first.explicitPick)
        next.update(hasTranslation: false, isTranslating: false)
        next.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(next.visibleTab, .translation)
    }

    func testAPreferenceForTheTranslationStillWaitsForAStreamToFinish() {
        var model = PreviewTextPanelModel(preference: .translation)
        model.update(hasTranslation: false, isTranslating: true)
        model.update(hasTranslation: true, isTranslating: true)
        XCTAssertEqual(model.visibleTab, .original)
        model.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(model.visibleTab, .translation)
    }

    func testAPreferenceForTheOriginalNeverSwitches() {
        var cached = PreviewTextPanelModel(preference: .original)
        cached.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(cached.visibleTab, .original)

        var streamed = PreviewTextPanelModel(preference: .original)
        streamed.update(hasTranslation: false, isTranslating: true)
        streamed.update(hasTranslation: true, isTranslating: true)
        streamed.update(hasTranslation: true, isTranslating: false)
        XCTAssertEqual(streamed.visibleTab, .original)
        XCTAssertFalse(streamed.didAutoSwitch)
    }

    @MainActor
    func testTheSessionPreferenceStartsEmptyAndHoldsAPick() {
        let saved = PreviewTextTabPreference.lastPick
        defer { PreviewTextTabPreference.lastPick = saved }
        PreviewTextTabPreference.lastPick = .translation
        XCTAssertEqual(PreviewTextPanelModel(preference: PreviewTextTabPreference.lastPick).preference, .translation)
    }

    // MARK: Height

    func testPanelHeightIgnoresTheText() {
        // The rule takes no text at all; the model's state, fed 1, 5 and 20
        // partials, leaves the same height for the same pane.
        let pane: CGFloat = 420
        var model = PreviewTextPanelModel()
        var heights: Set<CGFloat> = []
        for partials in [1, 5, 20] {
            model.update(hasTranslation: false, isTranslating: true)
            for _ in 0..<partials {
                model.update(hasTranslation: true, isTranslating: true)
                heights.insert(PreviewTextPanelModel.panelHeight(paneHeight: pane))
            }
        }
        XCTAssertEqual(heights.count, 1)
    }

    func testPanelHeightIsTheBaseAtTheDefaultPane() {
        XCTAssertEqual(PreviewTextPanelModel.panelHeight(paneHeight: nil), Design.Size.previewTextPanelHeight)
        XCTAssertEqual(
            PreviewTextPanelModel.panelHeight(paneHeight: Design.Size.previewPaneHeight),
            Design.Size.previewTextPanelHeight
        )
        // A pane shorter than the default does not shrink the rule.
        XCTAssertEqual(
            PreviewTextPanelModel.panelHeight(paneHeight: Design.Size.previewPaneMinHeight),
            Design.Size.previewTextPanelHeight
        )
    }

    func testPanelHeightGrowsWithThePaneByItsShare() {
        let extra: CGFloat = 400
        let height = PreviewTextPanelModel.panelHeight(paneHeight: Design.Size.previewPaneHeight + extra)
        XCTAssertEqual(height, Design.Size.previewTextPanelHeight + extra * Design.Size.previewTextPanelGrowthShare)
        XCTAssertGreaterThan(height, PreviewTextPanelModel.panelHeight(paneHeight: Design.Size.previewPaneHeight + 100))
    }

    // MARK: Tables in the translation

    /// The translation goes through the same table parse as the original, so
    /// a translated table is a grid and none of its pipe lines reach the
    /// plain-text renderer.
    func testATranslatedTableIsDrawnAsAGrid() {
        let translated = """
        Prix des abonnements

        | Magazine | Prix |
        | --- | --- |
        | Science | 12 € |
        | Nature | 15 € |

        Inscrivez-vous aujourd’hui.
        """
        let blocks = MarkdownTable.blocks(in: translated)
        let tables = blocks.compactMap { block -> MarkdownTable? in
            if case .table(let table) = block { return table }
            return nil
        }
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.header, ["Magazine", "Prix"])
        XCTAssertEqual(tables.first?.rows.count, 2)

        for block in blocks {
            guard case .text(let value) = block else { continue }
            for line in value.components(separatedBy: "\n") {
                XCTAssertFalse(
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
                    "A table line reached the text renderer: \(line)"
                )
            }
        }
    }

    // MARK: One source

    /// The Original tab shows `ClipTranslation.sourceText`, the text the
    /// translation was made from: refined text first, OCR otherwise.
    func testTheOriginalTabSharesTheTranslationsSource() {
        XCTAssertEqual(
            ClipTranslation.sourceText(
                kind: .image, isScreenshot: false, text: nil, ocrText: "raw", refinedText: "refined"
            ),
            "refined"
        )
        XCTAssertEqual(
            ClipTranslation.sourceText(
                kind: .file, isScreenshot: true, text: nil, ocrText: "raw", refinedText: nil
            ),
            "raw"
        )
    }
}
