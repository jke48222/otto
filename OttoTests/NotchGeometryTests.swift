//
//  NotchGeometryTests.swift
//  Otto
//

import CoreGraphics
import SwiftUI
import XCTest
@testable import Otto

final class NotchGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: - make

    func testPhysicalNotchFromAuxiliaryAreas() {
        let geometry = NotchGeometry.make(
            screenFrame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryLeftWidth: 663.5,
            auxiliaryRightWidth: 663.5,
            auxiliaryHeight: 32,
            safeAreaTop: 32,
            statusBarThickness: 24
        )
        XCTAssertTrue(geometry.hasPhysicalNotch)
        XCTAssertEqual(geometry.notchRect, CGRect(x: 663.5, y: 950, width: 185, height: 32))
        XCTAssertEqual(geometry.windowFrame.maxY, screen.maxY, "window flush with the top edge")
        XCTAssertEqual(geometry.windowFrame.midX, geometry.notchRect.midX)
    }

    func testPhysicalNotchOnSecondaryDisplayUsesWidths() {
        let frame = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let geometry = NotchGeometry.make(
            screenFrame: frame,
            visibleFrame: frame,
            auxiliaryLeftWidth: 663.5,
            auxiliaryRightWidth: 663.5,
            auxiliaryHeight: 32,
            safeAreaTop: 0,
            statusBarThickness: 24
        )
        XCTAssertEqual(geometry.notchRect, CGRect(x: -848.5, y: 1150, width: 185, height: 32))
    }

    func testVirtualNotchIsTopCenteredAndMenuBarTall() {
        let geometry = NotchGeometry.make(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            auxiliaryLeftWidth: nil,
            auxiliaryRightWidth: nil,
            auxiliaryHeight: 0,
            safeAreaTop: 0,
            statusBarThickness: 24
        )
        XCTAssertFalse(geometry.hasPhysicalNotch)
        XCTAssertEqual(geometry.notchRect.width, NotchMetrics.virtualNotchSize.width)
        XCTAssertEqual(geometry.notchRect.height, 25)
        XCTAssertEqual(geometry.notchRect.midX, 1280)
        XCTAssertEqual(geometry.notchRect.maxY, 1440)
    }

    func testVirtualNotchIsAtLeast24PointsTall() {
        // Auto-hidden menu bar: visible frame reaches the top.
        let geometry = NotchGeometry.make(
            screenFrame: screen,
            visibleFrame: screen,
            auxiliaryLeftWidth: nil,
            auxiliaryRightWidth: nil,
            auxiliaryHeight: 0,
            safeAreaTop: 0,
            statusBarThickness: 22
        )
        XCTAssertEqual(geometry.notchRect.height, 24)
    }

    // MARK: - Zones

    func testHoverTargetExcludesHotZoneMargins() {
        let geometry = NotchGeometry(
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchRect: CGRect(x: 663.5, y: 950, width: 185, height: 32)
        )
        let hotZone = geometry.closedHotZone(shapeSize: geometry.closedSize)
        let hoverTarget = geometry.hoverTarget(shapeSize: geometry.closedSize)
        XCTAssertEqual(hotZone, CGRect(x: 655.5, y: 944, width: 201, height: 38))
        XCTAssertEqual(hoverTarget, geometry.notchRect)

        // Activity ears widen both.
        let withEars = CGSize(width: 185 + NotchMetrics.activityEarWidth * 2, height: 32)
        XCTAssertEqual(geometry.hoverTarget(shapeSize: withEars).width, withEars.width)
    }

    // MARK: - Tall mode

    func testTallOpenHeightIsEightyPercentWithinBounds() {
        func tall(screenHeight: CGFloat) -> CGFloat {
            NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: screenHeight),
                hasPhysicalNotch: true,
                notchRect: CGRect(x: 663.5, y: screenHeight - 32, width: 185, height: 32)
            ).tallOpenHeight
        }
        XCTAssertEqual(tall(screenHeight: 982), 785, "80 % of a 14-inch screen, floored")
        XCTAssertEqual(tall(screenHeight: 2000), 1600)
        XCTAssertEqual(tall(screenHeight: 640), NotchMetrics.maxOpenHeight, "never less than the normal cap")
        XCTAssertEqual(tall(screenHeight: 570), 546, "never closer than 24 pt to the bottom of the screen")
        for height in stride(from: CGFloat(500), through: 2400, by: 37) {
            let value = tall(screenHeight: height)
            XCTAssertLessThanOrEqual(value, height - 24)
            XCTAssertGreaterThanOrEqual(value, min(NotchMetrics.maxOpenHeight, height - 24))
        }
    }

    func testWindowFrameForAnOpenHeightLimit() {
        let geometry = NotchGeometry(
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchRect: CGRect(x: 663.5, y: 950, width: 185, height: 32)
        )
        XCTAssertEqual(geometry.windowFrame, geometry.windowFrame(openHeightLimit: NotchMetrics.maxOpenHeight),
                       "the normal frame is the frame for the normal cap")
        XCTAssertEqual(geometry.windowFrame.size, NotchMetrics.windowSize)

        let tall = geometry.windowFrame(openHeightLimit: geometry.tallOpenHeight)
        XCTAssertEqual(tall.height, geometry.tallOpenHeight + NotchMetrics.shadowMargin)
        XCTAssertEqual(tall.width, NotchMetrics.windowSize.width, "tall mode only grows downward")
        XCTAssertEqual(tall.maxY, screen.maxY, "top stays flush with the screen")
        XCTAssertEqual(tall.midX, geometry.notchRect.midX)
        XCTAssertGreaterThanOrEqual(tall.minY, screen.minY, "the tall window stays on the screen")
    }

    // MARK: - Closed shape bound

    func testMaximumClosedShapeSizeCoversEveryClosedLayout() {
        for notchWidth in [CGFloat(185), 190, 240, 300] {
            let notch = CGSize(width: notchWidth, height: 32)
            let geometry = NotchGeometry(
                screenFrame: screen,
                hasPhysicalNotch: true,
                notchRect: CGRect(origin: CGPoint(x: 756 - notchWidth / 2, y: 950), size: notch)
            )
            let limit = geometry.maximumClosedShapeSize
            XCTAssertEqual(limit.height, notch.height + 40)
            XCTAssertEqual(limit.width, max(notchWidth + 68 + 24, max(notchWidth + 112, 360) + 24, 380 + 24))

            let longText = String(repeating: "A long answer preview that runs on ", count: 6)
            let ears = ClosedGlance(left: .orb(active: true), right: .unreadDot)
            let dropped = ClosedGlance(left: .orb(active: true), right: .systemWait, drop: .systemWait(longText))
            let layouts = [
                ClosedNotchLayout.make(notchSize: notch, glance: ears, isHovering: true, isListening: false,
                                       dropText: nil),
                ClosedNotchLayout.make(notchSize: notch, glance: dropped, isHovering: true, isListening: false,
                                       dropText: longText),
                ClosedNotchLayout.make(notchSize: notch, glance: ears, isHovering: true, isListening: true,
                                       dropText: nil),
            ]
            for layout in layouts {
                XCTAssertLessThanOrEqual(layout.size.width, limit.width, "\(layout) fits \(limit) for a \(notchWidth) pt notch")
                XCTAssertLessThanOrEqual(layout.size.height, limit.height, "\(layout) fits \(limit) for a \(notchWidth) pt notch")
            }
        }
    }

    func testMaximumClosedShapeSizeForTheDropAndThePill() {
        let geometry = NotchGeometry(
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchRect: CGRect(x: 663.5, y: 950, width: 185, height: 32)
        )
        let limit = geometry.maximumClosedShapeSize
        // The drop (glance.md §5.3): notch + 28 + 12 tall, at least 380 + 24 wide.
        XCTAssertEqual(limit.height, 32 + ReplyPreviewMetrics.dropHeight + 12)
        XCTAssertGreaterThanOrEqual(limit.width, ReplyPreviewMetrics.maxWidth + 24)
        // The listening pill: max(notch + 112, 360) wide, notch + 26 tall.
        XCTAssertGreaterThanOrEqual(limit.width, max(185 + 112, 360))
        XCTAssertGreaterThanOrEqual(limit.height, 32 + ClosedNotchLayout.pillExtraHeight)

        // The hot zone follows a full-size drop instead of clamping it away.
        let drop = CGSize(width: 380, height: 32 + ReplyPreviewMetrics.dropHeight)
        let zone = geometry.closedHotZone(shapeSize: CGSize(width: min(drop.width, limit.width),
                                                            height: min(drop.height, limit.height)))
        XCTAssertTrue(NotchHitTest.contains(zone, CGPoint(x: geometry.notchRect.midX, y: 982 - drop.height + 2)))
    }

    // MARK: - Screen choice

    func testPrefersScreenWithCameraHousing() {
        let candidates = [
            ScreenCandidate(displayID: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), hasCameraHousing: false),
            ScreenCandidate(displayID: 2, frame: CGRect(x: 2560, y: 0, width: 1512, height: 982), hasCameraHousing: true),
        ]
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: nil), 1)
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: 1), 1)
    }

    func testWithoutNotchFallsBackToMenuBarScreenNotPrevious() {
        // Clamshell with two external displays; the notch must stay on the menu-bar display even if
        // it was last placed elsewhere or Otto's key window sits on the other display.
        let candidates = [
            ScreenCandidate(displayID: 7, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080), hasCameraHousing: false),
            ScreenCandidate(displayID: 5, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), hasCameraHousing: false),
        ]
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: nil), 1)
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: 7), 1)
    }

    func testKeepsPreviousScreenWhilePrimaryIsAmbiguous() {
        let candidates = [
            ScreenCandidate(displayID: 3, frame: CGRect(x: 10, y: 0, width: 1920, height: 1080), hasCameraHousing: false),
            ScreenCandidate(displayID: 4, frame: CGRect(x: 1930, y: 0, width: 1920, height: 1080), hasCameraHousing: false),
        ]
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: 4), 1)
        XCTAssertEqual(ScreenCandidate.preferredIndex(in: candidates, previous: 99), 0, "disconnected previous is ignored")
        XCTAssertNil(ScreenCandidate.preferredIndex(in: [], previous: 4))
    }

    // MARK: - Hit testing vs. the drawn shape

    /// `NotchHitTest.shapeContains` must agree with `NotchShape.path(in:)` (which the UI draws), up to
    /// a sub-point band along the anti-aliased edge.
    func testShapeHitTestMatchesDrawnPath() {
        let cases: [(size: CGSize, top: CGFloat, bottom: CGFloat)] = [
            (CGSize(width: 580, height: 320), NotchMetrics.openTopRadius, NotchMetrics.openBottomRadius),
            (CGSize(width: 185, height: 32), NotchMetrics.closedTopRadius, NotchMetrics.closedBottomRadius),
            (CGSize(width: 40, height: 20), 30, 30), // radii clamped
        ]
        for (size, top, bottom) in cases {
            // Global rect of the shape, top edge at the top of the screen.
            let rect = CGRect(x: 400, y: 982 - size.height, width: size.width, height: size.height)
            let path = NotchShape(topRadius: top, bottomRadius: bottom)
                .path(in: CGRect(origin: .zero, size: size))

            // SwiftUI draws top-down; NotchHitTest works in bottom-up global coordinates.
            func pathContains(_ global: CGPoint) -> Bool {
                path.contains(CGPoint(x: global.x - rect.minX, y: rect.maxY - global.y))
            }
            func nearPath(_ global: CGPoint) -> Bool {
                for dx in [-1.0, 0, 1] {
                    for dy in [-1.0, 0, 1] where pathContains(CGPoint(x: global.x + dx, y: global.y + dy)) {
                        return true
                    }
                }
                return false
            }

            var y = rect.minY - 4.25
            while y <= rect.maxY + 4 {
                var x = rect.minX - 4.25
                while x <= rect.maxX + 4 {
                    let point = CGPoint(x: x, y: y)
                    let exact = NotchHitTest.shapeContains(point, rect: rect, topRadius: top, bottomRadius: bottom, tolerance: 0)
                    let lenient = NotchHitTest.shapeContains(point, rect: rect, topRadius: top, bottomRadius: bottom)
                    if pathContains(point) {
                        XCTAssertTrue(lenient, "drawn point \(point) of \(size) rejected by the hit test")
                        XCTAssertTrue(
                            NotchHitTest.shapeContains(point, rect: rect, topRadius: top, bottomRadius: bottom, tolerance: 1),
                            "drawn point \(point) of \(size) rejected"
                        )
                    }
                    if exact {
                        XCTAssertTrue(nearPath(point), "hit test accepts \(point) of \(size), which is not drawn")
                    }
                    x += 1.5
                }
                y += 1.5
            }
        }
    }

    func testInclusiveContainsAcceptsTopEdge() {
        let rect = CGRect(x: 0, y: 950, width: 100, height: 32)
        XCTAssertTrue(NotchHitTest.contains(rect, CGPoint(x: 50, y: 982)))
        XCTAssertFalse(rect.contains(CGPoint(x: 50, y: 982)))
        XCTAssertFalse(NotchHitTest.contains(.null, .zero))
    }
}
