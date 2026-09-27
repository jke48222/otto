//
//  ToolCatalog.swift
//  Otto
//
//  The one place the action tools are put together: the services they run on (EventKit, Shortcuts,
//  osascript, the default browser, or their in-memory stand-ins) and the registry ChatSession offers to
//  Claude. The calendar, scripting and media tools never reference each other; they meet only here.
//

import Foundation
import os

/// The services behind the eight action tools. `live` talks to the Mac; `demo` answers from fixed data and
/// never touches EventKit, Shortcuts, osascript or NSWorkspace (--demo, --selftest, --snapshot, tests).
struct ActionServices: Sendable {
    var eventKit: any EventKitProviding
    var shortcuts: any ShortcutsProviding
    var scripts: any AppleScriptRunning
    var urlOpener: any URLOpening

    /// EventKit through one store, Shortcuts and AppleScript through `processRunner` (its own process group, a
    /// scrubbed environment), links through the default browser.
    static func live(processRunner: ProcessRunning) -> ActionServices {
        ActionServices(
            eventKit: EventKitService(),
            shortcuts: ShortcutsService(runner: processRunner),
            scripts: AppleScriptRunner(runner: processRunner),
            urlOpener: DefaultBrowserOpener()
        )
    }

    /// A demo calendar and reminder store, five made-up shortcuts, a script runner that returns canned output and
    /// a link opener that only records. Shared, so what one demo turn created the next one can find and undo.
    static let demo = ActionServices(
        eventKit: DemoEventKitService(),
        shortcuts: DemoShortcutsService(),
        scripts: DemoAppleScriptRunner(),
        urlOpener: DemoURLOpener()
    )
}

@MainActor enum ToolCatalog {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    /// The eight action tools on `services`, plus `extraTools` (the app passes
    /// `[MediaControlTool(monitor: nowPlaying)]`). Every tool is registered; whether one is offered for a turn is
    /// the tool's own `isAvailable(in:)`, which reads `settings.actions` (or the demo flag) at the start of that turn.
    static func makeRegistry(settings: AppSettings, services: ActionServices,
                             extraTools: [any OttoTool] = []) -> ToolRegistry {
        let registry = ToolRegistry(tools: actionTools(services: services) + extraTools)
        let enabledGroups = ToolGroup.allCases.filter { settings.actions.isEnabled($0) }.map(\.rawValue)
        logger.info("""
            Tool catalog: \(registry.allTools.count, privacy: .public) tools; actions \
            \(settings.actions.enabled ? "on" : "off", privacy: .public) \
            (\(enabledGroups.joined(separator: ", "), privacy: .public))
            """)
        return registry
    }

    /// Calendar and Reminders (read, create), Shortcuts (list, run), AppleScript and links.
    private static func actionTools(services: ActionServices) -> [any OttoTool] {
        [
            CalendarListEventsTool(eventKit: services.eventKit),
            CalendarCreateEventTool(eventKit: services.eventKit),
            CalendarListRemindersTool(eventKit: services.eventKit),
            CalendarCreateReminderTool(eventKit: services.eventKit),
            ScriptListShortcutsTool(shortcuts: services.shortcuts),
            ScriptRunShortcutTool(shortcuts: services.shortcuts),
            ScriptRunAppleScriptTool(scripts: services.scripts),
            ScriptOpenURLTool(opener: services.urlOpener),
        ]
    }
}
