//
//  ShelfThumbnailer.swift
//  Otto
//
//  Makes the small picture a Shelf tile shows. Quick Look renders the file itself when it can
//  (images, PDFs, documents); callers fall back to the file type's icon when it can't.
//

import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Renders a thumbnail for a file on disk. Tests pass a fake so no file is ever rendered.
protocol ShelfThumbnailing: Sendable {
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage?
}

/// `QLThumbnailGenerator` with the `.thumbnail` representation only: a real rendering of the content,
/// never the generic icon (the store draws that itself, so it can tell the two apart and cache only
/// real renderings).
struct QuickLookShelfThumbnailer: ShelfThumbnailing {
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } catch {
            return nil
        }
    }
}
