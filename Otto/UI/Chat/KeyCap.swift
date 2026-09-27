//
//  KeyCap.swift
//  Otto
//
//  A small raised key cap ("⌘", "Space") for the shortcut sheet and anywhere else a chord is shown,
//  plus a row of caps that reads as one chord to VoiceOver.
//

import SwiftUI

struct KeyCap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    static let height: CGFloat = 18
    static let minWidth: CGFloat = 18
    static let cornerRadius: CGFloat = 5
    /// Between the caps of one chord.
    static let gap: CGFloat = 3

    var body: some View {
        Text(label)
            .font(Theme.font(11, .medium))
            .foregroundStyle(Theme.chipLabel)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: Self.minWidth, minHeight: Self.height, maxHeight: Self.height)
            .clay(cornerRadius: Self.cornerRadius, style: .chip)
            .accessibilityLabel(Self.spokenName(label))
    }

    /// The caps of one chord side by side ("⌘" "⇧" "C"), optionally after "Hold" for a held shortcut.
    struct Chord: View {
        let caps: [String]
        var isHold = false

        var body: some View {
            HStack(spacing: KeyCap.gap) {
                if isHold {
                    Text("Hold")
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 2)
                }
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                    KeyCap(cap)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeyCap.spokenChord(caps, isHold: isHold))
        }
    }

    /// How VoiceOver reads one cap: modifier and arrow glyphs become words, anything else is read as is.
    static func spokenName(_ cap: String) -> String {
        switch cap {
        case "⌘": return "Command"
        case "⇧": return "Shift"
        case "⌥": return "Option"
        case "⌃": return "Control"
        case "↩": return "Return"
        case "⌅": return "Enter"
        case "⌫": return "Delete"
        case "⌦": return "Forward Delete"
        case "⇥": return "Tab"
        case "↑": return "Up Arrow"
        case "↓": return "Down Arrow"
        case "←": return "Left Arrow"
        case "→": return "Right Arrow"
        case "Esc", "⎋": return "Escape"
        case ".": return "Period"
        case ",": return "Comma"
        case "/": return "Slash"
        case "[": return "Left Bracket"
        case "]": return "Right Bracket"
        default: return cap.replacingOccurrences(of: "–", with: " to ")
        }
    }

    /// "Command Shift C", or "Hold Option Space".
    static func spokenChord(_ caps: [String], isHold: Bool = false) -> String {
        let words = caps.map(spokenName)
        return ((isHold ? ["Hold"] : []) + words).joined(separator: " ")
    }
}
