import AppKit
import XCTest

@testable import MemoryClip

/// The panel's placement arithmetic, exercised without a window: every frame
/// it produces has to sit inside the visible frame it was given.
final class PanelGeometryTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1800, height: 1129)

    private func assertInside(
        _ frame: NSRect,
        _ visibleFrame: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY, "bottom is off screen", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY, "top is off screen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX, "left edge is off screen", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX, "right edge is off screen", file: file, line: line)
    }

    // MARK: Placement

    func testCollapsedPanelIsBottomAnchoredAndCentred() {
        let frame = PanelGeometry.panelFrame(in: laptop, previewHeight: nil)
        XCTAssertEqual(frame.minY, laptop.minY + Design.Size.panelBottomMargin)
        XCTAssertEqual(frame.height, Design.Size.panelHeight)
        XCTAssertEqual(frame.midX, laptop.midX, accuracy: 1)
        assertInside(frame, laptop)
    }

    /// A screen that is not the primary one has an origin of its own; the
    /// panel has to follow it instead of measuring from the global origin.
    func testPanelFollowsTheOriginOfTheScreenItIsPlacedOn() {
        let secondary = NSRect(x: -2560, y: -1440, width: 2560, height: 1400)
        let frame = PanelGeometry.panelFrame(in: secondary, previewHeight: nil)
        XCTAssertEqual(frame.minY, secondary.minY + Design.Size.panelBottomMargin)
        assertInside(frame, secondary)
    }

    func testExpandedPanelGrowsUpwardByTheHandleAndThePane() {
        let collapsed = PanelGeometry.panelFrame(in: laptop, previewHeight: nil)
        let expanded = PanelGeometry.panelFrame(in: laptop, previewHeight: 320)
        XCTAssertEqual(expanded.minY, collapsed.minY, "the bottom edge must stay put")
        XCTAssertEqual(
            expanded.height,
            collapsed.height + Design.Size.previewResizeHandleHeight + 320
        )
        assertInside(expanded, laptop)
    }

    func testAPreviewTallerThanTheScreenIsClampedInsideIt() {
        let frame = PanelGeometry.panelFrame(in: laptop, previewHeight: 10_000)
        XCTAssertEqual(frame.height, PanelGeometry.maxPanelHeight(in: laptop))
        assertInside(frame, laptop)
    }

    /// The panel alone is taller than this screen's usable height, which is
    /// the case the old arithmetic left hanging off the bottom.
    func testPanelShorterThanItsContentStillFitsTheScreen() {
        let short = NSRect(x: 0, y: 0, width: 1280, height: 240)
        let frame = PanelGeometry.panelFrame(in: short, previewHeight: 250)
        XCTAssertLessThanOrEqual(frame.height, PanelGeometry.maxPanelHeight(in: short))
        assertInside(frame, short)
    }

    func testNarrowScreenKeepsThePanelInsideItsEdges() {
        let narrow = NSRect(x: 0, y: 0, width: 360, height: 900)
        let frame = PanelGeometry.panelFrame(in: narrow, previewHeight: nil)
        XCTAssertEqual(frame.width, Design.Size.panelMinWidth)
        assertInside(frame, narrow)
    }

    func testAScreenNarrowerThanTheMinimumWidthStillHoldsThePanel() {
        let sliver = NSRect(x: 0, y: 0, width: 280, height: 900)
        let frame = PanelGeometry.panelFrame(in: sliver, previewHeight: nil)
        XCTAssertEqual(frame.width, sliver.width)
        assertInside(frame, sliver)
    }

    func testFrameIsIntegral() {
        let frame = PanelGeometry.panelFrame(
            in: NSRect(x: 0, y: 0, width: 1439.5, height: 899.5),
            previewHeight: 250
        )
        XCTAssertEqual(frame, frame.integral)
    }

    // MARK: Preview height

    func testStoredPreviewHeightIsHeldAboveTheMinimum() {
        XCTAssertEqual(
            PanelGeometry.clampPreviewHeight(20, in: laptop),
            Design.Size.previewPaneMinHeight
        )
    }

    func testStoredPreviewHeightIsHeldToWhatTheScreenAllows() {
        let ceiling = PanelGeometry.maxPreviewHeight(in: laptop)
        XCTAssertEqual(PanelGeometry.clampPreviewHeight(10_000, in: laptop), ceiling)
        XCTAssertEqual(
            ceiling,
            PanelGeometry.maxPanelHeight(in: laptop)
                - Design.Size.panelHeight
                - Design.Size.previewResizeHandleHeight
        )
    }

    func testAScreenWithNoRoomStillAllowsTheMinimumPane() {
        let short = NSRect(x: 0, y: 0, width: 1280, height: 300)
        XCTAssertEqual(
            PanelGeometry.maxPreviewHeight(in: short),
            Design.Size.previewPaneMinHeight
        )
        XCTAssertEqual(
            PanelGeometry.clampPreviewHeight(400, in: short),
            Design.Size.previewPaneMinHeight
        )
    }

    func testANonFiniteHeightFallsBackToTheDefault() {
        XCTAssertEqual(
            PanelGeometry.clampPreviewHeight(.nan, in: laptop),
            Design.Size.previewPaneHeight
        )
    }

    // MARK: Stored setting

    func testRegisteredDefaultIsTheDesignHeight() {
        UserDefaults.standard.removeObject(forKey: NoteSettingsKeys.previewPaneHeight)
        NoteSettingsKeys.registerDefaults()
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: NoteSettingsKeys.previewPaneHeight),
            Double(Design.Size.previewPaneHeight)
        )
    }

    @MainActor
    func testPanelStateReadsTheStoredHeight() {
        UserDefaults.standard.set(410.0, forKey: NoteSettingsKeys.previewPaneHeight)
        defer { UserDefaults.standard.removeObject(forKey: NoteSettingsKeys.previewPaneHeight) }
        XCTAssertEqual(PanelUIState().previewHeight, 410)
    }
}
