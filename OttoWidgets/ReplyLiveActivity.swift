//
//  ReplyLiveActivity.swift
//  Otto
//
//  The reply's Live Activity. In the Dynamic Island the orb sits on the left and a glyph on the right says what
//  Otto is doing (thinking, searching, writing, waiting for your OK), like the ears of the closed notch on the
//  Mac; when the reply lands the glyph turns to a check and the expanded island shows its first line. The Lock
//  Screen shows the same, with the reply's text hidden while the iPhone is locked.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct ReplyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReplyActivityAttributes.self) { context in
            ReplyActivityBanner(state: context.state)
                .activityBackgroundTint(Theme.panel)
                .activitySystemActionForegroundColor(Theme.textPrimary)
                .widgetURL(OttoDeepLink.reply(context.attributes.messageID).url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OttoOrb(size: 26, isActive: false)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ReplyActivityClock(state: state)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(Theme.font(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ReplyActivityDetail(state: state)
                        .font(Theme.font(14))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                OttoOrb(size: 15, isActive: false)
            } compactTrailing: {
                ReplyActivityGlyph(state: state)
            } minimal: {
                OttoOrb(size: 15, isActive: false)
            }
            .widgetURL(OttoDeepLink.reply(context.attributes.messageID).url)
            .keylineTint(Theme.orbLight)
        }
    }
}

/// The Lock Screen and banner form: orb, headline, the time, and the detail line.
struct ReplyActivityBanner: View {
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OttoOrb(size: 30, isActive: false)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title)
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ReplyActivityClock(state: state)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                ReplyActivityDetail(state: state)
                    .font(Theme.font(14))
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// The glyph beside the camera: what Otto is doing, a check when it replied.
struct ReplyActivityGlyph: View {
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(state.title)
    }

    private var color: Color {
        switch state.stage {
        case .waitingForApproval: return Theme.attention
        case .failed: return Theme.error
        case .connecting, .thinking, .searching, .writing, .acting, .replied, .paused: return Theme.orbLight
        }
    }
}

/// Elapsed time while Otto works (the system keeps it ticking), the model once it's done.
struct ReplyActivityClock: View {
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        if state.isFinished {
            Text(state.model)
                .lineLimit(1)
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 56, alignment: .trailing)
        }
    }
}

/// What Otto is doing, or the reply's first line. The reply's own words are hidden while the iPhone is locked.
struct ReplyActivityDetail: View {
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        if state.detail.isEmpty {
            Text(state.isFinished ? "Tap to open Otto." : "Otto keeps working while you're away.")
                .foregroundStyle(Theme.textSecondary)
        } else if state.stage == .replied || state.stage == .failed {
            Text(state.detail)
                .foregroundStyle(Theme.textBody)
                .privacySensitive()
        } else {
            Text(state.detail)
                .foregroundStyle(Theme.textSecondary)
                .privacySensitive()
        }
    }
}
