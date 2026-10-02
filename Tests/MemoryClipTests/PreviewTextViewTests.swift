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

    /// The view laid out inside the responder its right-clicks fall through
    /// to — the pane's `.contextMenu` in the app.
    private final class Catcher: NSView {
        var rightClicks = 0
        override func rightMouseDown(with _: NSEvent) { rightClicks += 1 }
    }

    private func makeViewInACatcher(_ text: String) -> (PreviewTextView, Catcher) {
        let view = makeView(text)
        view.setFrameSize(NSSize(width: 400, height: view.height(forWidth: 400)))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let catcher = Catcher(frame: view.frame)
        catcher.addSubview(view)
        return (view, catcher)
    }

    private func rightClick(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
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

    // MARK: Selection

    func testSelectedRangeReadsBackAsItsSubstring() {
        let view = makeView("three words here")
        view.setSelectedRange(NSRange(location: 6, length: 5))
        XCTAssertEqual(view.selectedText, "words")
    }

    func testAnEmptySelectionReadsBackAsNothing() {
        let view = makeView("three words here")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertNil(view.selectedText)
    }

    func testCommandCCopiesTheSelectionAndOtherwiseTheClip() {
        let view = makeView("three words here")
        view.setSelectedRange(NSRange(location: 6, length: 5))
        XCTAssertEqual(
            PreviewCopy.copyTarget(selection: view.selectedText, clipText: view.string),
            "words"
        )
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(
            PreviewCopy.copyTarget(selection: view.selectedText, clipText: view.string),
            "three words here"
        )
    }

    /// The panel keeps first responder while a selection is live, which is
    /// what leaves the arrow keys, Space and Escape reaching it.
    func testALiveSelectionStillLeavesTheKeysToThePanel() {
        let view = makeView("three words here")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNotNil(view.selectedText)
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    /// A right-click inside the selection is passed on rather than handled
    /// here, so `NSTextView` never moves the insertion point to the click and
    /// `Copy Selection` still has something to copy.
    func testARightClickInsideTheSelectionIsPassedOn() {
        let (view, catcher) = makeViewInACatcher("three words here")
        view.setSelectedRange(NSRange(location: 0, length: 11))
        view.rightMouseDown(with: rightClick(at: NSPoint(x: 10, y: 2)))
        XCTAssertEqual(view.selectedText, "three words")
        XCTAssertEqual(catcher.rightClicks, 1, "the pane's context menu never saw the click")
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
