//
//  NotchGeometry.swift
//  Otto
//
//  Where the camera housing is (or where a virtual notch should go on displays without one),
//  plus the hit-testing geometry the window controller uses to decide which pointer events the
//  notch panel should receive.
//

import AppKit

struct NotchGeometry: Equatable {
    /// NSScreen.frame (global coordinates, bottom-left origin).
    let screenFrame: CGRect
    let hasPhysicalNotch: Bool
    /// Global coordinates of the camera housing (or the virtual notch, top-centered).
    let notchRect: CGRect

    var closedSize: CGSize { notchRect.size }

    /// Screen that hosts the notch: a screen with a camera housing, else the menu-bar screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        preferredScreen(previous: nil)
    }

    /// Screen that hosts the notch, preferring `previous` (a `CGDirectDisplayID`) when it is still
    /// an equally good candidate, so reconfigurations do not make the notch hop between displays.
    ///
    /// Without a camera housing this falls back to the menu-bar screen rather than `NSScreen.main`:
    /// `main` is the screen of Otto's key window (e.g. Settings on a secondary display), which
    /// would move the virtual notch — and its hot zone — away from the menu bar.
    @MainActor
    static func preferredScreen(previous: CGDirectDisplayID?) -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.map { screen in
            ScreenCandidate(
                displayID: displayID(of: screen),
                frame: screen.frame,
                hasCameraHousing: screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
            )
        }
        guard let index = ScreenCandidate.preferredIndex(in: candidates, previous: previous) else { return nil }
        return screens[index]
    }

    /// The display ID of `screen` (`NSScreenNumber`), nil if AppKit does not report one.
    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor
    static func make(for screen: NSScreen) -> NotchGeometry {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        return make(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxiliaryLeftWidth: left?.width,
            auxiliaryRightWidth: right?.width,
            auxiliaryHeight: max(left?.height ?? 0, right?.height ?? 0),
            safeAreaTop: screen.safeAreaInsets.top,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }

    /// Pure core of `make(for:)`, separated from NSScreen so it can be unit-tested.
    static func make(
        screenFrame frame: CGRect,
        visibleFrame: CGRect,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?,
        auxiliaryHeight: CGFloat,
        safeAreaTop: CGFloat,
        statusBarThickness: CGFloat
    ) -> NotchGeometry {
        if let leftWidth = auxiliaryLeftWidth, let rightWidth = auxiliaryRightWidth {
            // The auxiliary areas are the unobscured menu-bar strips either side of the camera housing.
            // Using their widths (rather than their origins) is independent of the coordinate space
            // they are reported in, which matters for secondary display arrangements.
            let minX = frame.minX + leftWidth
            let maxX = frame.maxX - rightWidth
            let height = safeAreaTop > 0 ? safeAreaTop : auxiliaryHeight
            if maxX - minX > 1, height > 1 {
                let rect = CGRect(x: minX, y: frame.maxY - height, width: maxX - minX, height: height)
                return NotchGeometry(screenFrame: frame, hasPhysicalNotch: true, notchRect: rect)
            }
        }

        // Virtual notch: top-centered, as tall as the menu bar on this screen (at least 24 pt).
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        let thickness = menuBarHeight > 0 ? menuBarHeight : statusBarThickness
        let size = CGSize(width: NotchMetrics.virtualNotchSize.width, height: max(24, thickness))
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        return NotchGeometry(screenFrame: frame, hasPhysicalNotch: false, notchRect: rect)
    }
}

// MARK: - Screen choice

/// What `preferredScreen` needs to know about a screen; pure so the choice can be unit-tested.
struct ScreenCandidate: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect
    var hasCameraHousing: Bool

    /// Index of the screen that should host the notch:
    /// 1. a screen with a camera housing (`previous` if it is one of them, else the first);
    /// 2. the menu-bar (primary) screen — the one whose frame origin is `.zero`;
    /// 3. `previous` while it is still connected (the primary can be momentarily ambiguous
    ///    mid-reconfiguration);
    /// 4. the first screen.
    static func preferredIndex(in candidates: [ScreenCandidate], previous: CGDirectDisplayID?) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let previousIndex = previous.flatMap { id in candidates.firstIndex { $0.displayID == id } }

        if let previousIndex, candidates[previousIndex].hasCameraHousing {
            return previousIndex
        }
        if let notched = candidates.firstIndex(where: \.hasCameraHousing) {
            return notched
        }
        if let primary = candidates.firstIndex(where: { $0.frame.origin == .zero }) {
            return primary
        }
        return previousIndex ?? 0
    }
}

// MARK: - Window & hit-testing geometry

extension NotchGeometry {
    /// Frame of the fixed-size notch window: top edge flush with the top of the screen,
    /// horizontally centered on the notch.
    var windowFrame: CGRect {
        let size = NotchMetrics.windowSize
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Global rect of a shape of `size` drawn top-centered on the notch.
    func shapeRect(size: CGSize) -> CGRect {
        CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Area around the closed notch that reacts to hover, clicks and drags: the housing widened by
    /// 8 pt on each side and extended 6 pt downward, plus whatever the closed shape currently covers.
    func closedHotZone(shapeSize: CGSize) -> CGRect {
        let housing = CGRect(
            x: notchRect.minX - 8,
            y: notchRect.minY - 6,
            width: notchRect.width + 16,
            height: notchRect.height + 6
        )
        return housing.union(shapeRect(size: shapeSize))
    }

    /// Area over which a *resting* pointer opens the closed notch: the housing itself plus whatever
    /// the closed shape covers (activity ears, hover grow) — without the hot zone's margins, so a
    /// pointer passing just beside the notch on its way to a status item does not open it.
    func hoverTarget(shapeSize: CGSize) -> CGRect {
        notchRect.union(shapeRect(size: shapeSize))
    }

    /// Upper bound for the closed shape (activity ears + hover grow, with slack). Clamps sizes that
    /// the UI has not updated yet right after a close, so a stale open-size report never turns the
    /// whole panel area into a hover zone.
    var maximumClosedShapeSize: CGSize {
        CGSize(
            width: notchRect.width + NotchMetrics.activityEarWidth * 2 + 24,
            height: notchRect.height + 12
        )
    }
}

// MARK: - Point tests

enum NotchHitTest {
    /// Inclusive containment. `CGRect.contains` is half-open, and at the very top edge of a screen
    /// `NSEvent.mouseLocation.y` equals `frame.maxY`, which a half-open test would reject.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        !rect.isNull && point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Whether `point` (global coordinates) lies on the notch shape drawn in `rect`: the top edge
    /// spans the full width, the top corners are concave quarter-circles of `topRadius` (the flare
    /// into the screen edge), the sides run straight down `topRadius` in from the edges, and the
    /// bottom corners are convex with `bottomRadius`. `tolerance` grows the accepted area outward so
    /// clicks that graze an anti-aliased edge still land on the panel.
    static func shapeContains(
        _ point: CGPoint,
        rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard contains(rect.insetBy(dx: -tolerance, dy: -tolerance), point) else { return false }
        guard rect.width > 0, rect.height > 0 else { return false }

        let top = min(max(topRadius, 0), rect.width / 4, rect.height / 2)
        let bodyMinX = rect.minX + top
        let bodyMaxX = rect.maxX - top
        let bottom = min(max(bottomRadius, 0), (bodyMaxX - bodyMinX) / 2, rect.height - top)

        // Flare band along the top edge: inside if outside the concave circle centered at the
        // outer top corner shifted down by `top`.
        if point.y >= rect.maxY - top {
            if point.x < bodyMinX {
                let center = CGPoint(x: rect.minX, y: rect.maxY - top)
                return hypot(point.x - center.x, point.y - center.y) >= top - tolerance
            }
            if point.x > bodyMaxX {
                let center = CGPoint(x: rect.maxX, y: rect.maxY - top)
                return hypot(point.x - center.x, point.y - center.y) >= top - tolerance
            }
            return true
        }

        // Body: sides inset by `top`, rounded bottom corners.
        guard point.x >= bodyMinX - tolerance, point.x <= bodyMaxX + tolerance else { return false }
        if bottom > 0, point.y < rect.minY + bottom {
            if point.x < bodyMinX + bottom {
                let center = CGPoint(x: bodyMinX + bottom, y: rect.minY + bottom)
                return hypot(point.x - center.x, point.y - center.y) <= bottom + tolerance
            }
            if point.x > bodyMaxX - bottom {
                let center = CGPoint(x: bodyMaxX - bottom, y: rect.minY + bottom)
                return hypot(point.x - center.x, point.y - center.y) <= bottom + tolerance
            }
        }
        return true
    }
}
