//
//  ClosedNotchLayoutTests.swift
//  OttoTests
//
//  §4.2 shape rules for the closed notch (ears, hover grow, drop, listening pill) and the bound every
//  closed size must respect: NotchGeometry.maximumClosedShapeSize as §4.2 defines it.
//

import XCTest
@testable import Otto

final class ClosedNotchLayoutTests: XCTestCase {
    private let notch = CGSize(width: 185, height: 32)
    private let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Short answer.")

    /// §4.2: width max(notch + 68 + 24, max(notch + 112, 360) + 24, 380 + 24), height notch + 40.
    private func maximumClosedShapeSize(notch: CGSize) -> CGSize {
        let width = max(notch.width + 68 + 24, max(notch.width + 112, 360) + 24, 380 + 24)
        return CGSize(width: width, height: notch.height + 40)
    }

    func testNothingIsTheNotch() {
        let result = ClosedNotchLayout.make(notchSize: notch, glance: ClosedGlance(), isHovering: false,
                                            isListening: false, dropText: nil)
        XCTAssertEqual(result, .init(size: notch, bottomRadius: NotchMetrics.closedBottomRadius, showsPill: false))
    }

    func testEarsWiden() {
        let glance = ClosedGlance(left: .orb(active: false), right: .unreadDot)
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                            dropText: nil)
        XCTAssertEqual(result.size, CGSize(width: 185 + 68, height: 32))
        XCTAssertEqual(result.bottomRadius, NotchMetrics.closedBottomRadius)
        XCTAssertFalse(result.showsPill)
    }

    func testOneEarStillWidensBothSides() {
        let glance = ClosedGlance(right: .speaking)
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                            dropText: nil)
        XCTAssertEqual(result.size.width, 185 + 68)
    }

    func testHoverGrows() {
        let plain = ClosedNotchLayout.make(notchSize: notch, glance: ClosedGlance(), isHovering: true,
                                           isListening: false, dropText: nil)
        XCTAssertEqual(plain.size, CGSize(width: 193, height: 35))

        let eared = ClosedNotchLayout.make(notchSize: notch, glance: ClosedGlance(left: .orb(active: true)),
                                           isHovering: true, isListening: false, dropText: nil)
        XCTAssertEqual(eared.size, CGSize(width: 185 + 68 + 8, height: 35))
    }

    func testShortDropKeepsTheEarWidth() {
        let glance = ClosedGlance(left: .orb(active: false), right: .unreadDot, drop: .preview(preview))
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                            dropText: "Hi")
        XCTAssertEqual(result.size.height, 32 + ReplyPreviewMetrics.dropHeight)
        XCTAssertEqual(result.size.width, 185 + 68)
        XCTAssertEqual(result.bottomRadius, 16)
        XCTAssertFalse(result.showsPill)
    }

    func testLongDropCapsAtMaxWidth() {
        let text = String(repeating: "A long first line of a reply ", count: 10)
        let glance = ClosedGlance(left: .orb(active: false), right: .unreadDot, drop: .preview(preview))
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                            dropText: text)
        XCTAssertEqual(result.size.width, ReplyPreviewMetrics.maxWidth)
        XCTAssertEqual(result.size.height, 32 + 28)
    }

    func testMediumDropUsesItsIdealWidth() {
        let text = "Needs your OK · Add “Dentist” to Calendar"
        let ideal = ReplyPreviewMetrics.measuredIdealWidth(for: text)
        XCTAssertGreaterThan(ideal, 185 + 68)
        XCTAssertLessThan(ideal, ReplyPreviewMetrics.maxWidth)
        let glance = ClosedGlance(left: .orb(active: true), right: .approval, drop: .approval(label: "Add “Dentist” to Calendar"))
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                            dropText: text)
        XCTAssertEqual(result.size.width, ideal)
    }

    func testDropTextFallsBackToTheDropContent() {
        let glance = ClosedGlance(left: .orb(active: true), right: .approval, drop: .approval(label: "Add “Dentist” to Calendar"))
        let implicit = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                              dropText: nil)
        let explicit = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: false,
                                              dropText: glance.drop?.text)
        XCTAssertEqual(implicit, explicit)
    }

    func testListeningPill() {
        let result = ClosedNotchLayout.make(notchSize: notch, glance: ClosedGlance(), isHovering: true,
                                            isListening: true, dropText: "ignored")
        XCTAssertEqual(result, .init(size: CGSize(width: 360, height: 32 + 26), bottomRadius: 14, showsPill: true))

        let wide = CGSize(width: 300, height: 38)
        let wideResult = ClosedNotchLayout.make(notchSize: wide, glance: ClosedGlance(), isHovering: false,
                                                isListening: true, dropText: nil)
        XCTAssertEqual(wideResult.size, CGSize(width: 300 + 112, height: 38 + 26))
    }

    func testPillHasNoDropEvenWhenTheGlanceHasOne() {
        let glance = ClosedGlance(left: .orb(active: true), right: .systemWait, drop: .systemWait("Waiting for System Settings…"))
        let result = ClosedNotchLayout.make(notchSize: notch, glance: glance, isHovering: false, isListening: true,
                                            dropText: "Waiting for System Settings…")
        XCTAssertTrue(result.showsPill)
        XCTAssertEqual(result.size.height, 32 + 26)
    }

    func testNoSizeExceedsTheGeometryMaximum() {
        let notches = [CGSize(width: 150, height: 30), CGSize(width: 185, height: 32), NotchMetrics.virtualNotchSize,
                       CGSize(width: 240, height: 38), CGSize(width: 320, height: 40)]
        let texts: [String?] = [nil, "", "OK", "Waiting for System Settings…",
                                String(repeating: "W", count: 400), String(repeating: "很长的回复", count: 60)]
        let glances: [ClosedGlance] = [
            ClosedGlance(),
            ClosedGlance(left: .orb(active: true)),
            ClosedGlance(left: .orb(active: false), right: .unreadDot, drop: .preview(preview)),
            ClosedGlance(left: .orb(active: true), right: .approval,
                         drop: .approval(label: String(repeating: "Delete everything ", count: 20))),
            ClosedGlance(left: .orb(active: true), right: .systemWait, drop: .systemWait("Waiting for System Settings…")),
            ClosedGlance(drop: .preview(preview)),
        ]
        for notchSize in notches {
            let limit = maximumClosedShapeSize(notch: notchSize)
            for glance in glances {
                for text in texts {
                    for hovering in [false, true] {
                        for listening in [false, true] {
                            let size = ClosedNotchLayout.make(notchSize: notchSize, glance: glance, isHovering: hovering,
                                                              isListening: listening, dropText: text).size
                            XCTAssertLessThanOrEqual(size.width, limit.width, "\(notchSize) \(glance) \(String(describing: text))")
                            XCTAssertLessThanOrEqual(size.height, limit.height, "\(notchSize) \(glance) \(String(describing: text))")
                            XCTAssertGreaterThanOrEqual(size.width, notchSize.width)
                            XCTAssertGreaterThanOrEqual(size.height, notchSize.height)
                        }
                    }
                }
            }
        }
    }
}
