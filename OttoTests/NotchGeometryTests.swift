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
