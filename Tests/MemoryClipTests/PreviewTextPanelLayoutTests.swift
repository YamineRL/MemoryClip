import AppKit
import SwiftUI
import XCTest

@testable import MemoryClip

/// The text panel lays its text out at the panel's width, whichever tab shows.
@MainActor
final class PreviewTextPanelLayoutTests: XCTestCase {
    private static let long = String(
        repeating: "Des chercheurs marocains ont propose une nouvelle methode pour reduire la consommation. ",
        count: 12
    )

    private func panel(
        _ context: PreviewTextPanel.Context, translation: String?, translating: Bool = false
    ) -> PreviewTextPanel {
        PreviewTextPanel(
            context: context,
            original: Self.long,
            translation: translation.map {
                ClipTranslationResult(text: $0, sourceLanguage: "fr", targetLanguage: "en")
            },
            isTranslating: translating,
            targetLanguage: "en"
        )
    }

    /// Measuring the text at another width must not change the width it wraps at.
    func testMeasuringDoesNotChangeTheWrapWidth() throws {
        let host = NSHostingView(rootView: SelectableText(text: Self.long, size: 13))
        host.frame = NSRect(x: 0, y: 0, width: 336, height: 250)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> PreviewTextView? {
            if let found = view as? PreviewTextView { return found }
            return view.subviews.lazy.compactMap(find).first
        }
        let view = try XCTUnwrap(find(host))
        view.frame.size.width = 336
        _ = view.height(forWidth: 1000)
        XCTAssertEqual(view.textContainer?.size.width ?? 0, 336, accuracy: 0.5)
    }

    private static let table = """
    | Topic | Details |
    | --- | --- |
    | Solar | Moroccan researchers have proposed a new method to reduce the energy consumption of irrigation pumps in arid regions across the country |
    | Water | A second long cell that keeps going well past the width of the preview pane so that it has to wrap onto several lines to stay readable |
    """

    /// A table's long cells wrap inside the pane instead of running past its edge.
    func testTableCellsWrapAtThePaneWidth() {
        let host = NSHostingView(
            rootView: TableAwareText(text: Self.table, size: 13)
                .frame(width: 560)
                .fixedSize(horizontal: false, vertical: true)
        )
        let size = host.fittingSize
        XCTAssertEqual(size.width, 560, accuracy: 1)
        // Each long cell needs at least two lines at this width, so the two
        // data rows and the header stand well over five lines tall.
        XCTAssertGreaterThan(size.height, 5 * 13 * 1.2)
    }
}
