//
//  ShelfContracts.swift
//  Otto
//
//  A file kept on the Shelf, and how a drop over the open notch is split between the Shelf and asking
//  Otto about the files.
//

import CoreGraphics
import Foundation

struct ShelfItem: Identifiable, Equatable, Codable, Sendable {
    enum Origin: String, Codable, Sendable { case reference, owned }
    enum Availability: Equatable, Sendable { case available, missing, needsAccess }

    let id: UUID
    var origin: Origin
    /// URL.bookmarkData(options: []): plain, because Otto is unsandboxed.
    var bookmark: Data
    var lastKnownPath: String
    var name: String
    var contentTypeIdentifier: String?
    var byteCount: Int64?
    var isDirectory: Bool
    let addedAt: Date
    /// Runtime only: excluded from CodingKeys.
    var availability: Availability = .available

    private enum CodingKeys: String, CodingKey {
        case id, origin, bookmark, lastKnownPath, name, contentTypeIdentifier, byteCount, isDirectory, addedAt
    }
}

enum DropZone: Equatable, Sendable {
    case shelf, ask

    /// x < width / 2 → .shelf when acceptsShelf, else .ask.
    static func zone(forX x: CGFloat, width: CGFloat, acceptsShelf: Bool) -> DropZone {
        guard acceptsShelf, x < width / 2 else { return .ask }
        return .shelf
    }
}

struct DropSession: Equatable, Sendable { var zone: DropZone; var itemCount: Int; var acceptsShelf: Bool }
