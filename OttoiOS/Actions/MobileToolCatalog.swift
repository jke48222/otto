//
//  MobileToolCatalog.swift
//  Otto
//
//  The actions Claude can take on iPhone: read and add calendar events and reminders, the same four tools the
//  Mac offers, on EventKit (or the demo store). Shortcuts, AppleScript, media control and links stay on the
//  Mac. Whether a tool is offered for a turn is still its own `isAvailable(in:)`, which reads Settings → Actions.
//

import Foundation
import os

@MainActor enum MobileToolCatalog {
    /// The groups Settings → Actions offers on iPhone, in display order.
    static let groups: [ToolGroup] = [.calendar, .reminders]

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    static func makeRegistry(settings: AppSettings, eventKit: any EventKitProviding) -> ToolRegistry {
        let registry = ToolRegistry(tools: [
            CalendarListEventsTool(eventKit: eventKit),
            CalendarCreateEventTool(eventKit: eventKit),
            CalendarListRemindersTool(eventKit: eventKit),
            CalendarCreateReminderTool(eventKit: eventKit),
        ])
        let enabled = groups.filter { settings.actions.isEnabled($0) }.map(\.rawValue)
        logger.info("""
            Tool catalog: \(registry.allTools.count, privacy: .public) tools; actions \
            \(settings.actions.enabled ? "on" : "off", privacy: .public) (\(enabled.joined(separator: ", "), privacy: .public))
            """)
        return registry
    }

    /// The activity log keeps entries as long as History keeps conversations; "Forever" caps it at 90 days.
    static func actionLogMaxAge(for retention: HistoryRetention) -> TimeInterval {
        retention.interval ?? 90 * 86_400
    }
}
