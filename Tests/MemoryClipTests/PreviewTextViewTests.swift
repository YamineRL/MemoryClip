import AppKit
import XCTest

@testable import MemoryClip

/// Covers the preview body's text view: the one that makes the whole width of
/// a line selectable.
@MainActor
final class PreviewTextViewTests: XCTestCase {
    private func makeView(_ text: String) -> PreviewTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = PreviewTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.string = text
        view.font = NSFont.systemFont(ofSize: 13)
        return view
    }

    func testNarrowWidthWrapsAndGrowsTaller() {
        let view = makeView(String(repeating: "word ", count: 40))
        let wide = view.height(forWidth: 600)
        let narrow = view.height(forWidth: 120)
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testEachLineAddsHeight() {
        let one = makeView("one").height(forWidth: 400)
        let three = makeView("one\ntwo\nthree").height(forWidth: 400)
        XCTAssertGreaterThan(three, one * 2)
    }

    func testAPointRightOfAShortLineLandsAtItsEnd() {
        let view = makeView("hi\nthere")
        view.setFrameSize(NSSize(width: 400, height: view.height(forWidth: 400)))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let index = view.characterIndexForInsertion(at: NSPoint(x: 380, y: 2))
        XCTAssertEqual(index, 2, "expected the caret at the end of \"hi\"")
    }

    func testNeverTakesFirstResponder() {
        XCTAssertFalse(makeView("hi").acceptsFirstResponder)
    }

    func testHasNoContextMenuOfItsOwn() {
        let view = makeView("hi")
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        XCTAssertNil(view.menu(for: event))
    }
}
