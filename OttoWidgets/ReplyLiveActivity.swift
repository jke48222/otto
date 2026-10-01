//
//  ReplyLiveActivity.swift
//  Otto
//
//  The reply's Live Activity. In the Dynamic Island the orb sits on the left and a glyph on the right says what
//  Otto is doing (thinking, searching, writing, waiting for your OK), like the ears of the closed notch on the
//  Mac; when the reply lands the glyph turns to a check and the expanded island shows its first line. The Lock
//  Screen shows the same; the detail line is privacy-sensitive, so the system can redact it.
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
