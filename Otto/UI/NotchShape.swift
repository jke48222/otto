//
//  NotchShape.swift
//  Otto
//

import SwiftUI

/// The notch silhouette. The top edge spans the full width; the top corners are *concave*
/// quarter circles (`topRadius`) so the shape flares into the screen edge like the camera housing;
/// the sides drop straight down and the bottom corners are convex (`bottomRadius`).
///
/// Both radii animate, so the closed → open spring morphs the ears and the bottom corners together
/// with the frame.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(
        topRadius: CGFloat = NotchMetrics.closedTopRadius,
        bottomRadius: CGFloat = NotchMetrics.closedBottomRadius
    ) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        // Clamp so the arcs always fit, including mid-animation and for tiny frames.
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bodyWidth = rect.width - top * 2
        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))

        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))

        // Top-left ear: concave quarter circle centred outside the body at (minX, minY + top).
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: minX + top, y: minY),
                tangent2End: CGPoint(x: minX + top, y: minY + top),
                radius: top
            )
        }
        path.addLine(to: CGPoint(x: minX + top, y: maxY - bottom))

        // Bottom-left convex corner.
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: minX + top, y: maxY),
                tangent2End: CGPoint(x: minX + top + bottom, y: maxY),
                radius: bottom
            )
        }
        path.addLine(to: CGPoint(x: maxX - top - bottom, y: maxY))

        // Bottom-right convex corner.
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: maxX - top, y: maxY),
                tangent2End: CGPoint(x: maxX - top, y: maxY - bottom),
                radius: bottom
            )
        }
        path.addLine(to: CGPoint(x: maxX - top, y: minY + top))

        // Top-right ear.
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: maxX - top, y: minY),
                tangent2End: CGPoint(x: maxX, y: minY),
                radius: top
            )
        }
        path.closeSubpath()
        return path
    }
}
