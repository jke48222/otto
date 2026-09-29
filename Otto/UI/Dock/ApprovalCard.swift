//
//  ApprovalCard.swift
//  Otto
//
//  The dock card that asks before an action runs. It shows what will run, where the request came from and
//  any caution, then waits: the primary button stays disabled until the card has been on screen, reviewed,
//  for the approval's arming delay (a ring traces the capsule meanwhile), and until a calendar or list is
//  picked when one is required. Buttons only report the decision; the caller checks where the input came
//  from before anything runs.
//

import AppKit
import SwiftUI

struct ApprovalCard: View {
    let approval: PendingApproval
    @Binding var options: ApprovalOptions
    /// When the card became visible and reviewed (`vm.approvalVisibility?.since`); nil = not visible now.
    let visibleSince: Date?
    /// Something covers the card for a while without taking it down (a screen capture, the file picker, a menu:
    /// `vm.isMenuPresented`). The view model stops counting the card as on screen meanwhile; once it ends, a card
    /// that was already reviewed says so again, so it can arm again.
    let isSuspended: Bool
    /// The body fits, or has been scrolled to its end (→ `vm.noteApprovalReviewed(callID:)`).
    let onReviewed: () -> Void
    let onDecision: (ApprovalDecision) -> Void

    init(approval: PendingApproval, options: Binding<ApprovalOptions>, visibleSince: Date?, isSuspended: Bool = false,
         onReviewed: @escaping () -> Void, onDecision: @escaping (ApprovalDecision) -> Void) {
        self.approval = approval
        _options = options
        self.visibleSince = visibleSince
        self.isSuspended = isSuspended
        self.onReviewed = onReviewed
        self.onDecision = onDecision
    }

    /// The tallest the card grows on its own, the dock's own cap (§4.1); the frame may cap it lower, and the body
    /// scrolls (or, for a script, the code box takes what is left).
    static let maxHeight: CGFloat = NotchLayout.maximumDockHeight
    static let confirmHint = "⌘↩"
    static let declineHint = "esc"
    static let hardwareOnlyAnnouncement = "Approve with this Mac's keyboard or trackpad."

    @State private var bodyReviewed = false
    @State private var scrolledToEnd = false
    /// A script's code box takes the height left on the card and is its only scroller; false once that left it
    /// too short (a caution banner, a small dock), and then the whole body scrolls with every code row in it.
    @State private var codeFillsCard = true
    @State private var reportedReviewed = false
    /// The call the review was reported for; a review never carries over to another call.
    @State private var reportedCallID: String?
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var sentinelMaxY: CGFloat = .infinity
    /// Set once the arming delay has passed for the current `visibleSince`, so the ring's clock can stop.
    @State private var armedFor: Date?
    /// The review hint waits a moment, so a body that fits (reviewed on its first layout) never flashes it.
    @State private var reviewHintReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let scrollSpace = "approval-card-body"

    // MARK: - Pure helpers

    /// 0…1 along the arming delay, counted from when the card became visible. 0 while not visible.
    static func armingProgress(visibleSince: Date?, armingDelay: Duration, now: Date) -> Double {
        guard let visibleSince else { return 0 }
        let delay = armingDelay.timeInterval
        let elapsed = now.timeIntervalSince(visibleSince)
        guard delay > 0 else { return elapsed >= 0 ? 1 : 0 }
        return min(1, max(0, elapsed / delay))
    }

    /// Whether a calendar or list the body requires has been picked (always true when none is required).
    static func hasRequiredSelection(body: ApprovalBody, options: ApprovalOptions) -> Bool {
        guard body.requiresSelection else { return true }
        guard let picked = options.calendarIdentifier else { return false }
        switch body {
        case .event(let preview): return preview.calendars.contains { $0.id == picked }
        case .reminder(let preview): return preview.lists.contains { $0.id == picked }
        case .consent, .text, .shortcut, .appleScript, .url: return true
        }
    }

    /// The primary is live when the card is visible, armed and nothing still has to be picked.
    static func isPrimaryEnabled(approval: PendingApproval, options: ApprovalOptions, visibleSince: Date?,
                                 now: Date) -> Bool {
        visibleSince != nil
            && armingProgress(visibleSince: visibleSince, armingDelay: approval.armingDelay, now: now) >= 1
            && hasRequiredSelection(body: approval.body, options: options)
    }

    /// Whether a card whose review was already reported reports it again: the view model dropped the review while
    /// the card stayed up (it went off screen and came back, e.g. around a screen capture), nothing covers it now,
    /// and the review belongs to this very call. The view model restamps visibility, so arming starts over.
    static func reportsReviewAgain(reportedCallID: String?, callID: String, visibleSince: Date?,
                                   isSuspended: Bool) -> Bool {
        reportedCallID == callID && visibleSince == nil && !isSuspended
    }

    static let reviewHint = "Scroll to review"

    /// Why the primary is still disabled, in the footer's leading slot where it is always on screen: the card's
    /// body, or a box inside it (a script, a long input), hasn't been scrolled to its end yet. nil once reviewed.
    static func reviewHint(reviewed: Bool) -> String? {
        reviewed ? nil : reviewHint
    }

    /// "2 of 3" when the round asks about more than one call.
    static func counterText(position: Int, total: Int) -> String? {
        total > 1 ? "\(position) of \(total)" : nil
    }

    /// "Always allow “Log water”" for approvals that offer to remember their scope.
    static func rememberLabel(for kind: PendingApproval.Kind) -> String? {
        guard case .approval(let scope?) = kind else { return nil }
        return "Always allow \(scope.label)"
    }

    /// "Available in 1 second" (rounded up, at least one second); nil without a delay.
    static func armingAnnouncement(delay: Duration) -> String? {
        let seconds = delay.timeInterval
        guard seconds > 0 else { return nil }
        let whole = max(1, Int(seconds.rounded(.up)))
        return whole == 1 ? "Available in 1 second" : "Available in \(whole) seconds"
    }

    /// What VoiceOver hears when the card appears.
    static func appearanceAnnouncement(for approval: PendingApproval) -> String {
        let title = "Approval needed: \(approval.presentation.title)."
        guard let arming = armingAnnouncement(delay: approval.armingDelay) else { return title }
        return "\(title) \(arming)."
    }

    /// An accessibility press of the primary approves only while VoiceOver or Switch Control runs (their
    /// presses count as the user's own input); anything else is told to use the keyboard or trackpad.
    enum AccessibilityApproval: Equatable { case approve, explain(String) }

    static func accessibilityApproval(assistiveInputRunning: Bool) -> AccessibilityApproval {
        assistiveInputRunning ? .approve : .explain(hardwareOnlyAnnouncement)
    }

    /// The provenance sentence with the source it names in bold ("Requested after reading **example.com**").
    static func provenanceText(_ provenance: String) -> AttributedString {
        var result = AttributedString(provenance)
        for marker in ["reading ", " read "] {
            guard let range = provenance.range(of: marker, options: .backwards) else { continue }
            let name = provenance[range.upperBound...]
            guard !name.isEmpty,
                  let start = AttributedString.Index(range.upperBound, within: result) else { break }
            result[start..<result.endIndex].inlinePresentationIntent = .stronglyEmphasized
            break
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DockCardChrome.spacing) {
            DockCardChrome.Header(
                symbol: approval.presentation.symbol,
                title: approval.presentation.title,
                counter: Self.counterText(position: approval.position, total: approval.total)
            )
            // No `presentation.detail` row (§5.7): the body shows the same facts, and for a script the detail is the
            // model's own purpose, which appears only in the body, labeled "Otto says:" (actions.md §9).
            if let provenance = approval.provenance, !provenance.isEmpty {
                provenanceLine(provenance)
            }
            if let caution = approval.caution {
                cautionBanner(caution)
            }
            if usesFlexibleCodeBox {
                flexibleBody
            } else {
                scrollingBody
            }
            if let label = Self.rememberLabel(for: approval.kind) {
                DockCardChrome.Checkbox(isOn: $options.alwaysAllow, label: label)
            }
            footer
        }
        .dockCardChrome()
        .frame(maxHeight: Self.maxHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(approval.presentation.title)")
        .onAppear {
            options.alwaysAllow = false
            DockCardChrome.announce(Self.appearanceAnnouncement(for: approval))
        }
        .onChange(of: approval.callID) { _, _ in
            // A new call in the same slot starts over: unreviewed, unarmed, "Always allow" off.
            bodyReviewed = false
            scrolledToEnd = false
            codeFillsCard = true
            reportedReviewed = false
            reportedCallID = nil
            reviewHintReady = false
            sentinelMaxY = .infinity
            armedFor = nil
            options.alwaysAllow = false
            DockCardChrome.announce(Self.appearanceAnnouncement(for: approval))
        }
        .onChange(of: isSuspended) { _, suspended in reportAgainIfDropped(visibleSince: visibleSince, suspended: suspended) }
        .onChange(of: visibleSince) { _, since in reportAgainIfDropped(visibleSince: since, suspended: isSuspended) }
        .task(id: ArmingKey(callID: approval.callID, visibleSince: visibleSince)) {
            await waitUntilArmed()
        }
        .task(id: approval.callID) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reviewHintReady = true
        }
    }

    private func provenanceLine(_ provenance: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(Self.provenanceText(provenance))
                .font(Theme.font(11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func cautionBanner(_ caution: CautionBanner) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.attention)
                .accessibilityHidden(true)
            (Text(caution.headline).bold() + Text(" ") + Text(caution.body))
                .font(Theme.font(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(Theme.attention.opacity(0.10)))
        .overlay(shape.strokeBorder(Theme.attention.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caution. \(caution.headline) \(caution.body)")
    }

    /// A script body whose code box fills the card: nothing around the code scrolls, so the box's own review (its
    /// last row was shown) is the card's.
    private var usesFlexibleCodeBox: Bool {
        ApprovalBodyView.flexesCodeBox(approval.body) && codeFillsCard
    }

    private var flexibleBody: some View {
        ApprovalBodyView(body: approval.body, options: $options, codeSizing: .fillsCard,
                         onCodeCramped: { codeFillsCard = false }) {
            bodyReviewed = true
            reportIfReviewed()
        }
        .id(approval.callID)
    }

    /// The body scrolls inside whatever height is left; it counts as reviewed once the body itself says so
    /// (a long script's last row was shown) and the card's own scroll has reached its end.
    private var scrollingBody: some View {
        DockCardChrome.ScrollCap(idealCap: Self.maxHeight - 110) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // A script shows every code row here, so this is still the card's one scroller.
                    ApprovalBodyView(body: approval.body, options: $options,
                                     codeSizing: ApprovalBodyView.flexesCodeBox(approval.body) ? .fullHeight : .ownCap,
                                     onReviewed: {
                                         bodyReviewed = true
                                         reportIfReviewed()
                                     })
                    Color.clear
                        .frame(height: 1)
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.scrollSpace)).maxY }) {
                            sentinelMaxY = $0
                            updateScrolledToEnd()
                        }
                }
            }
            .scrollIndicators(.automatic)
            .coordinateSpace(name: Self.scrollSpace)
            .id(approval.callID)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                scrollViewportHeight = $0
                updateScrolledToEnd()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if approval.remainingInRound > 0 {
                DockCardChrome.TextButton(title: "Decline All") { onDecision(.denyAll) }
                    .accessibilityHint("Declines this and the other actions Otto asked about in this step")
            }
            if reviewHintReady, let hint = Self.reviewHint(reviewed: reportedReviewed) {
                Label(hint, systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .transition(.opacity)
                    .accessibilityLabel("Scroll to the end to review before approving")
            }
            Spacer(minLength: 8)
            DockCardChrome.SecondaryButton(title: approval.declineLabel, hint: Self.declineHint) {
                onDecision(.deny)
            }
            primaryButton
        }
        .frame(height: DockCardChrome.footerHeight)
        .animation(.easeOut(duration: 0.15), value: reportedReviewed)
    }

    private var primaryButton: some View {
        let isArmed = visibleSince != nil && armedFor == visibleSince
        let needsClock = visibleSince != nil && !isArmed
        return TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 30.0, paused: !needsClock)) { context in
            // Once armed, the paused timeline's last tick may predate the arming moment; don't read it.
            let progress = isArmed ? 1 : Self.armingProgress(visibleSince: visibleSince,
                                                             armingDelay: approval.armingDelay, now: context.date)
            DockCardChrome.PrimaryButton(
                title: approval.confirmLabel,
                hint: Self.confirmHint,
                armingProgress: progress,
                isEnabled: visibleSince != nil && Self.hasRequiredSelection(body: approval.body, options: options)
            ) {
                onDecision(.run(options))
            }
            .accessibilityLabel(approval.confirmLabel)
            .accessibilityValue(progress >= 1 ? "" : (Self.armingAnnouncement(delay: approval.armingDelay) ?? ""))
            .accessibilityAction(.default) { performAccessibilityApproval() }
        }
    }

    // MARK: - Behavior

    private func performAccessibilityApproval() {
        let workspace = NSWorkspace.shared
        let assistive = workspace.isVoiceOverEnabled || workspace.isSwitchControlEnabled
        switch Self.accessibilityApproval(assistiveInputRunning: assistive) {
        case .approve:
            guard Self.isPrimaryEnabled(approval: approval, options: options, visibleSince: visibleSince, now: Date())
            else {
                DockCardChrome.announce(Self.armingAnnouncement(delay: approval.armingDelay) ?? "Not available yet")
                return
            }
            onDecision(.run(options))
        case .explain(let text):
            DockCardChrome.announce(text)
        }
    }

    private func updateScrolledToEnd() {
        guard !scrolledToEnd, scrollViewportHeight > 0, sentinelMaxY.isFinite,
              AppleScriptCodeLayout.isLastRowVisible(lastRowMaxY: sentinelMaxY, viewportHeight: scrollViewportHeight)
        else { return }
        scrolledToEnd = true
        reportIfReviewed()
    }

    private func reportIfReviewed() {
        guard bodyReviewed, usesFlexibleCodeBox || scrolledToEnd, !reportedReviewed else { return }
        reportedReviewed = true
        reportedCallID = approval.callID
        onReviewed()
    }

    /// The card is still up and was reviewed, but the view model no longer counts it as visible: say so again once
    /// nothing covers it (its geometry didn't change, so the one-shot report above won't fire again).
    private func reportAgainIfDropped(visibleSince: Date?, suspended: Bool) {
        guard reportedReviewed, Self.reportsReviewAgain(reportedCallID: reportedCallID, callID: approval.callID,
                                                        visibleSince: visibleSince, isSuspended: suspended)
        else { return }
        onReviewed()
    }

    /// Sleeps until the arming delay has passed for the current visibility, then stops the ring's clock.
    private func waitUntilArmed() async {
        guard let since = visibleSince else { return }
        let armedAt = approval.armedAt(visibleSince: since)
        let wait = armedAt.timeIntervalSinceNow
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
        }
        armedFor = since
    }

    private struct ArmingKey: Equatable {
        let callID: String
        let visibleSince: Date?
    }
}
