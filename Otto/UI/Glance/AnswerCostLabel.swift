//
//  AnswerCostLabel.swift
//  Otto
//
//  The right side of a reply's hover footer: which model answered and what the answer cost
//  ("Opus 5 · ≈0.8¢ · 1 search · 92% cached"), with the per-token breakdown as its tooltip. It reads only
//  this answer's entry in the usage ledger, so other replies' usage never redraws it. Before the ledger
//  knows the answer (or when the API reported no usage) it shows the model name alone.
//

import SwiftUI

struct AnswerCostLabel: View {
    let messageID: UUID
    let ledger: UsageLedger
    /// The message's own model id, shown when the ledger has nothing for this answer.
    let fallbackModel: String?

    /// Pure. The label: the ledger's summary when it knows the answer, else the fallback model's short name,
    /// else nil (nothing to show).
    static func text(answer: AnswerUsage?, fallbackModel: String?) -> String? {
        if let answer, answer.requests > 0, !answer.lines.isEmpty {
            return CostFormatter.summary(answer)
        }
        guard let fallbackModel, !fallbackModel.isEmpty else { return nil }
        let name = CostFormatter.modelName(fallbackModel)
        return name.isEmpty ? nil : name
    }

    /// Pure. The tooltip: the breakdown when the ledger knows the answer, else none.
    static func tooltip(answer: AnswerUsage?) -> String? {
        guard let answer, answer.requests > 0, !answer.lines.isEmpty else { return nil }
        return CostFormatter.tooltip(answer)
    }

    var body: some View {
        let answer = ledger.answers[messageID]
        if let text = Self.text(answer: answer, fallbackModel: fallbackModel) {
            Text(text)
                .font(Theme.font(11))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(CostTooltip(text: Self.tooltip(answer: answer)))
                .accessibilityLabel(text)
        }
    }
}

/// The breakdown tooltip, only when there is one (an empty `.help` would still show a blank tip).
private struct CostTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
