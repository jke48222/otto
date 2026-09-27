//
//  LiveTranscriptView.swift
//  Otto
//
//  What the user is saying, shown over the composer while Otto listens: the confirmed words in near-white,
//  the last partial word (which the recognizer may still revise) in tertiary. Before any words arrive it
//  shows a 28-bar waveform and "Listening…". Also home to the pure text split the listening pill's caption
//  shares.
//

import SwiftUI

/// The transcript as display text (tested): both halves cleaned with `DisplayText`, joined by one space,
/// and optionally cut to the newest characters so a one-line caption keeps the words just spoken.
struct VoiceTranscriptText: Equatable, Sendable {
    /// Confirmed words.
    let settled: String
    /// The partial tail, including its leading space when it follows settled words.
    let tail: String

    /// Longer than any 2-minute utterance, so nothing is cut unless `keepingLast` asks for it.
    private static let cleaningLimit = 20_000

    /// - Parameter keepingLast: keep at most this many characters, dropping the oldest words first.
    init(finalized: String, volatile: String, keepingLast limit: Int? = nil) {
        var settled = Self.clean(finalized, limit: limit)
        var tail = Self.clean(volatile, limit: limit)
        if let limit {
            let budget = max(0, limit)
            if tail.count >= budget {
                tail = Self.newest(tail, count: budget)
                settled = ""
            } else {
                let separator = settled.isEmpty || tail.isEmpty ? 0 : 1
                settled = Self.newest(settled, count: max(0, budget - tail.count - separator))
            }
        }
        self.settled = settled
        self.tail = !settled.isEmpty && !tail.isEmpty ? " " + tail : tail
    }

    var isEmpty: Bool { settled.isEmpty && tail.isEmpty }

    /// The whole line as one string (VoiceOver reads this).
    var combined: String { settled + tail }

    func attributed(settledColor: Color, tailColor: Color) -> AttributedString {
        var settledPart = AttributedString(settled)
        settledPart.foregroundColor = settledColor
        var tailPart = AttributedString(tail)
        tailPart.foregroundColor = tailColor
        return settledPart + tailPart
    }

    private static func clean(_ text: String, limit: Int?) -> String {
        // Bound the work for a one-line caption: only the newest characters can show.
        let source = limit.map { String(text.suffix(max(0, $0) * 2 + 8)) } ?? text
        return DisplayText.sanitized(source, maxLength: cleaningLimit)
    }

    /// At most the newest `count` characters, starting on a whole word when the cut lands inside one (unless
    /// the text is a single word).
    private static func newest(_ text: String, count: Int) -> String {
        guard text.count > count else { return text }
        var cut = Substring(text.suffix(count))
        let startsInsideWord = cut.first.map { !$0.isWhitespace } ?? false
            && !(text.dropLast(count).last?.isWhitespace ?? true)
        if startsInsideWord, let space = cut.firstIndex(where: { $0.isWhitespace }) {
            cut = cut[space...]
        }
        return String(cut.drop(while: { $0.isWhitespace }))
    }
}

/// The composer's listening overlay.
struct LiveTranscriptView: View {
    static let fontSize: CGFloat = 15
    static let settledColor = Color.white.opacity(0.92)

    let finalizedText: String
    let volatileText: String
    /// Drives the empty-state waveform; read directly, never observed.
    let meter: AudioLevelMeter
    /// While the final words land the waveform flattens and the shimmer stops.
    var isFinishing: Bool

    init(finalizedText: String, volatileText: String, meter: AudioLevelMeter, isFinishing: Bool = false) {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.meter = meter
        self.isFinishing = isFinishing
    }

    var body: some View {
        let text = VoiceTranscriptText(finalized: finalizedText, volatile: volatileText)
        Group {
            if text.isEmpty {
                HStack(spacing: 10) {
                    VoiceWaveformView(style: .inline, meter: meter, isActive: !isFinishing)
                    Text("Listening…")
                        .font(Theme.font(Self.fontSize))
                        .foregroundStyle(Theme.textTertiary)
                        .shimmer(isActive: !isFinishing)
                }
            } else {
                Text(text.attributed(settledColor: Self.settledColor, tailColor: Theme.textTertiary))
                    .font(Theme.font(Self.fontSize))
                    .lineLimit(1...4)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? "Listening" : "What you said")
        .accessibilityValue(text.combined)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
