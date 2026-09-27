//
//  ClosedGlance.swift
//  Otto
//
//  What the closed notch shows and how big it gets: the priority resolver (one thing at a time, §4.2)
//  and the pure shape rules for ears, hover growth, the drop line and the listening pill.
//

import CoreGraphics
import Foundation

enum EarGlyph: Equatable, Sendable {
    case none, orb(active: Bool), phase(ReplyPhase), unreadDot, approval, checkmark, speaking,
         artwork(NowPlayingItem.ID), equalizer
    /// Waiting on system UI (§4.2 row 2): 11 pt `hourglass`, textSecondary, flips 180° every 2 s (static with Reduce Motion).
    case systemWait
}

enum DropContent: Equatable, Sendable {
    case preview(ReplyPreview), approval(label: String), systemWait(String)

    /// The drop line's text (the outcome glyph is drawn separately): the reply's first line,
    /// "Needs your OK · ‹title›", or the system wait's own text.
    var text: String {
        switch self {
        case .preview(let preview):
            return preview.text
        case .approval(let label):
            let title = DisplayText.sanitized(label, maxLength: 120)
            return title.isEmpty ? "Needs your OK" : "Needs your OK · \(title)"
        case .systemWait(let text):
            return text
        }
    }
}

struct ClosedGlance: Equatable, Sendable {
    var left: EarGlyph = .none
    var right: EarGlyph = .none
    var drop: DropContent?
    var hasEars: Bool { left != .none || right != .none }
    var accessibilityLabel: String

    init(left: EarGlyph = .none, right: EarGlyph = .none, drop: DropContent? = nil, accessibilityLabel: String = "Otto") {
        self.left = left
        self.right = right
        self.drop = drop
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Assembled by the view model (§4.2).
struct GlanceInputs: Equatable, Sendable {
    var isListening: Bool
    var systemWait: SystemUIWait?
    var approvalTitle: String?
    var flash: ClosedFlash?
    var preview: ReplyPreview?
    var phase: ReplyPhase
    var isSpeaking: Bool
    var hasUnreadReply: Bool
    var media: NowPlayingItem?

    init(isListening: Bool = false, systemWait: SystemUIWait? = nil, approvalTitle: String? = nil,
         flash: ClosedFlash? = nil, preview: ReplyPreview? = nil, phase: ReplyPhase = .idle,
         isSpeaking: Bool = false, hasUnreadReply: Bool = false, media: NowPlayingItem? = nil) {
        self.isListening = isListening
        self.systemWait = systemWait
        self.approvalTitle = approvalTitle
        self.flash = flash
        self.preview = preview
        self.phase = phase
        self.isSpeaking = isSpeaking
        self.hasUnreadReply = hasUnreadReply
        self.media = media
    }
}

/// The §4.2 priority table: the first matching row decides everything the closed notch shows.
enum GlanceResolver {
    static func resolve(_ input: GlanceInputs) -> ClosedGlance {
        // 1. Voice listening / finishing: the pill carries the dot, waveform and caption; no ears, no drop.
        if input.isListening {
            return ClosedGlance(accessibilityLabel: "Otto is listening")
        }
        // 2. Waiting on system UI (the fold).
        if let wait = input.systemWait {
            let text = wait.dropText
            return ClosedGlance(left: .orb(active: true), right: .systemWait, drop: .systemWait(text),
                                accessibilityLabel: "Otto is waiting. \(text)")
        }
        // 3. Approval pending.
        if let title = input.approvalTitle {
            return ClosedGlance(left: .orb(active: true), right: .approval, drop: .approval(label: title),
                                accessibilityLabel: labelled("Otto needs your OK", title))
        }
        // 4. Paste flash.
        if case .pasted(let appName)? = input.flash {
            let app = DisplayText.sanitized(appName, maxLength: 60)
            return ClosedGlance(left: .orb(active: false), right: .checkmark,
                                accessibilityLabel: app.isEmpty ? "Otto pasted the answer" : "Otto pasted the answer into \(app)")
        }
        // 5. Reply preview.
        if let preview = input.preview {
            return ClosedGlance(left: .orb(active: false), right: input.isSpeaking ? .speaking : .unreadDot,
                                drop: .preview(preview), accessibilityLabel: previewLabel(preview))
        }
        // 6. Reply in progress (the debounced phase).
        if input.phase.isActive {
            return ClosedGlance(left: .orb(active: true), right: input.isSpeaking ? .speaking : .phase(input.phase),
                                accessibilityLabel: input.isSpeaking ? "Otto is speaking" : phaseLabel(input.phase))
        }
        // 7. Speaking (reply done).
        if input.isSpeaking {
            return ClosedGlance(left: .orb(active: false), right: .speaking, accessibilityLabel: "Otto is speaking")
        }
        // 8. Unread reply.
        if input.hasUnreadReply {
            return ClosedGlance(left: .orb(active: false), right: .unreadDot, accessibilityLabel: "Otto has a new reply")
        }
        // 9. Media playing (already filtered to "enabled, in the closed notch, playing" by the monitor).
        if let item = input.media {
            return ClosedGlance(left: .artwork(item.id), right: .equalizer, accessibilityLabel: mediaLabel(item))
        }
        // 10. Nothing.
        return ClosedGlance()
    }

    // MARK: - Private

    private static func previewLabel(_ preview: ReplyPreview) -> String {
        switch preview.outcome {
        case .answered: return "Otto replied: \(preview.text)"
        case .failed: return "Otto couldn't finish: \(preview.text)"
        case .refused: return "Otto declined: \(preview.text)"
        }
    }

    private static func phaseLabel(_ phase: ReplyPhase) -> String {
        switch phase {
        case .idle: return "Otto"
        case .connecting: return "Otto is connecting"
        case .thinking: return "Otto is thinking"
        case .searching(let label): return labelled("Otto is searching", label)
        case .writing: return "Otto is writing"
        case .runningAction(let label): return labelled("Otto is running an action", label)
        case .awaitingApproval(let label): return labelled("Otto needs your OK", label)
        }
    }

    private static func mediaLabel(_ item: NowPlayingItem) -> String {
        let title = DisplayText.sanitized(item.title, maxLength: 120)
        let artist = DisplayText.sanitized(item.artist, maxLength: 120)
        switch (title.isEmpty, artist.isEmpty) {
        case (true, _): return "Playing in \(item.player.displayName)"
        case (false, true): return "Playing \(title)"
        case (false, false): return "Playing \(title) by \(artist)"
        }
    }

    private static func labelled(_ base: String, _ label: String) -> String {
        let clean = DisplayText.sanitized(label, maxLength: 120)
        return clean.isEmpty ? base : "\(base): \(clean)"
    }
}

/// Pure size rules for the closed shape (§4.2).
enum ClosedNotchLayout {
    struct Result: Equatable, Sendable {
        var size: CGSize
        var bottomRadius: CGFloat
        var showsPill: Bool
    }

    /// Hover grow of the closed shape (no pill): +8 pt wide, +3 pt tall.
    static let hoverGrowth = CGSize(width: 8, height: 3)
    /// Listening pill: at least this wide, and at least the notch plus this much on each side.
    static let pillMinimumWidth: CGFloat = 360
    static let pillSideExtension: CGFloat = 56
    static let pillExtraHeight: CGFloat = 26
    static let pillBottomRadius: CGFloat = 14
    static let dropBottomRadius: CGFloat = 16

    /// Pure: §4.2 shape rules (ears, hover grow, drop, listening pill).
    static func make(notchSize: CGSize, glance: ClosedGlance, isHovering: Bool, isListening: Bool,
                     dropText: String?) -> Result {
        if isListening {
            let width = max(notchSize.width + 2 * pillSideExtension, pillMinimumWidth)
            return Result(size: CGSize(width: width, height: notchSize.height + pillExtraHeight),
                          bottomRadius: pillBottomRadius, showsPill: true)
        }

        var size = notchSize
        var bottomRadius = NotchMetrics.closedBottomRadius
        if glance.hasEars {
            size.width += 2 * NotchMetrics.activityEarWidth
        }
        if isHovering {
            size.width += hoverGrowth.width
            size.height += hoverGrowth.height
        }
        if let drop = glance.drop {
            let text = dropText ?? drop.text
            size.height += ReplyPreviewMetrics.dropHeight
            size.width = max(size.width, min(ReplyPreviewMetrics.measuredIdealWidth(for: text), ReplyPreviewMetrics.maxWidth))
            bottomRadius = dropBottomRadius
        }
        return Result(size: size, bottomRadius: bottomRadius, showsPill: false)
    }
}
