//
//  ShelfPageModel.swift
//  Otto
//
//  Pure helpers behind the Shelf page and the split drop wells: grid sizes, the action bar's summary and
//  pluralized labels, tile captions, which drop well is lit and what each well's subtitle says.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Grid geometry of the Shelf page (context-io.md §5.1): 5 columns of 92 × 100 pt tiles, 8 pt apart.
enum ShelfPageLayout {
    /// Matches `ShelfController.columns`, which moves the selection by rows of this many tiles.
    static let columns = 5
    static let tileWidth: CGFloat = 92
    static let tileHeight: CGFloat = 100
    static let spacing: CGFloat = 8
    static let thumbnailSide: CGFloat = 60
    static let nameMaxWidth: CGFloat = 88
    /// One line of a tile's 11.5 pt caption.
    static let nameLineHeight: CGFloat = 14
    /// Two rows plus a 24 pt peek of the third.
    static let maxGridHeight: CGFloat = 2 * tileHeight + spacing + 24
    static let actionBarHeight: CGFloat = 40
    static let emptyStateHeight: CGFloat = 120
    /// Fade at the top and bottom of the scrolling grid.
    static let fadeLength: CGFloat = 14
    /// Delay between tiles in the landing pulse after a Shelf drop.
    static let landingStagger: Double = 0.03

    static var gridWidth: CGFloat {
        CGFloat(columns) * tileWidth + CGFloat(columns - 1) * spacing
    }

    static func rowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + columns - 1) / columns
    }

    /// Height of the grid's scroll area: every row, capped at two rows and a peek.
    static func gridHeight(itemCount: Int) -> CGFloat {
        let rows = rowCount(itemCount: itemCount)
        guard rows > 0 else { return 0 }
        let content = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
        return min(content, maxGridHeight)
    }

    /// Whether the grid scrolls (and so draws its edge fades).
    static func scrolls(itemCount: Int) -> Bool {
        let rows = rowCount(itemCount: itemCount)
        let content = CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * spacing
        return content > maxGridHeight
    }
}

/// Every string the Shelf page shows.
enum ShelfPageText {
    static let emptyTitle = "Your shelf is empty"
    static let emptyBody = "Drop files on the notch to keep them here. Drag them out whenever you need them."
    static let missingSubtitle = "Moved or deleted"
    static let revealHelp = "Reveal in Finder (⌥⌘R)"
    static let maxNameLength = 80

    /// "1 item", "5 items".
    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// Left side of the action bar: "5 items · 12.4 MB" (size left out when unknown, e.g. folders only), or
    /// "2 of 5 selected" while there is a selection.
    static func summary(itemCount: Int, selectedCount: Int, totalBytes: Int64, locale: Locale = .current) -> String {
        if selectedCount > 0 {
            return "\(selectedCount) of \(itemCount) selected"
        }
        guard totalBytes > 0 else { return self.itemCount(itemCount) }
        return "\(self.itemCount(itemCount)) · \(byteCount(totalBytes, locale: locale))"
    }

    static func byteCount(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// How many items an action bar button acts on: the selection, or every item when nothing is selected.
    static func targetCount(itemCount: Int, selectedCount: Int) -> Int {
        selectedCount > 0 ? selectedCount : itemCount
    }

    /// "Ask Otto", or "Ask Otto about 3".
    static func askLabel(targetCount: Int) -> String {
        targetCount > 1 ? "Ask Otto about \(targetCount)" : "Ask Otto"
    }

    static func shareHelp(targetCount: Int) -> String {
        targetCount > 1 ? "Share \(targetCount) items" : "Share"
    }

    static func removeHelp(targetCount: Int) -> String {
        targetCount > 1 ? "Remove \(targetCount) items from Shelf" : "Remove from Shelf"
    }

    /// The tile's caption, cleaned of hidden and bidi characters.
    static func displayName(_ item: ShelfItem) -> String {
        DisplayText.sanitized(item.name, maxLength: maxNameLength)
    }

    /// VoiceOver: "Q3 plan.png", "notes.md, moved or deleted", "Assets, folder, selected".
    static func accessibilityLabel(for item: ShelfItem, isSelected: Bool) -> String {
        var parts = [displayName(item)]
        if item.isDirectory { parts.append("folder") }
        if item.availability == .missing { parts.append("moved or deleted") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    /// Images fill their thumbnail well; documents, folders and unknown types fit inside it.
    static func isImage(_ item: ShelfItem) -> Bool {
        guard !item.isDirectory,
              let identifier = item.contentTypeIdentifier,
              let type = UTType(identifier)
        else { return false }
        return type.conforms(to: .image)
    }

    /// SF Symbol for a tile without a thumbnail yet.
    static func placeholderSymbol(for item: ShelfItem) -> String {
        if item.isDirectory { return "folder" }
        if isImage(item) { return "photo" }
        if let identifier = item.contentTypeIdentifier, let type = UTType(identifier), type.conforms(to: .pdf) {
            return "doc.richtext"
        }
        return "doc"
    }
}

/// When the Shelf grid may hold the keyboard. Soft focus (the pointer resting on the notch, §4.4) and a Shelf drop
/// (§4.7) make the panel key without engaging it; the grid's keys (⌫ removes and deletes Otto's own copies, ⌘C
/// replaces the clipboard, Space opens Quick Look) must then stay with the user's app.
enum ShelfPageFocus {
    /// Whether a focus request (`vm.focusRequest`) gives the grid the keyboard.
    static func takesFocus(onRequest requested: Bool, isEngaged: Bool) -> Bool {
        requested && isEngaged
    }

    /// Whether a key press reaching the grid acts. The key that engages a soft-focused notch reaches the page too,
    /// before the view sees the engagement; it only engages.
    static func handlesKeys(isEngaged: Bool) -> Bool {
        isEngaged
    }
}

/// The two wells shown while files are dragged over the open notch: "Keep on Shelf" on the left, "Ask Otto"
/// on the right. The well under the pointer brightens; the other dims with a dashed edge.
enum ShelfDropWell {
    struct Appearance: Equatable {
        var isActive: Bool
        var scale: CGFloat
        var opacity: Double
        var isDashed: Bool
        var strokeOpacity: Double
        var strokeWidth: CGFloat
    }

    static let active = Appearance(isActive: true, scale: 1.02, opacity: 1, isDashed: false,
                                   strokeOpacity: 0.85, strokeWidth: 1.5)
    static let inactive = Appearance(isActive: false, scale: 1, opacity: 0.55, isDashed: true,
                                     strokeOpacity: 0.45, strokeWidth: 1)

    static let shelfTitle = "Keep on Shelf"
    static let askTitle = "Ask Otto"
    static let askSubtitle = "Attach to your message"
    static let shelfFullSubtitle = "Shelf is full"
    static let noRoomSubtitle = "No room for more attachments"

    static func appearance(of well: DropZone, in session: DropSession) -> Appearance {
        session.zone == well ? active : inactive
    }

    /// "3 files · drag out anytime"; "Shelf is full" when the drop would take the shelf past its limit.
    static func shelfSubtitle(itemCount: Int, shelfCount: Int, maxItems: Int = ShelfStore.maxItems) -> String {
        if shelfCount + itemCount > maxItems { return shelfFullSubtitle }
        let files = itemCount == 1 ? "1 file" : "\(itemCount) files"
        return "\(files) · drag out anytime"
    }

    /// Whether the Shelf well's subtitle is a warning.
    static func shelfIsOverLimit(itemCount: Int, shelfCount: Int, maxItems: Int = ShelfStore.maxItems) -> Bool {
        shelfCount + itemCount > maxItems
    }

    /// The drop still attaches the first `remainingCapacity` items; the subtitle warns when it holds more.
    static func askIsOverCapacity(itemCount: Int, remainingCapacity: Int) -> Bool {
        itemCount > remainingCapacity
    }

    static func askSubtitle(itemCount: Int, remainingCapacity: Int) -> String {
        guard askIsOverCapacity(itemCount: itemCount, remainingCapacity: remainingCapacity) else { return askSubtitle }
        guard remainingCapacity > 0 else { return noRoomSubtitle }
        return remainingCapacity == 1 ? "Up to 1 item" : "Up to \(remainingCapacity) items"
    }
}
