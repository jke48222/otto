//
//  ToolRegistry.swift
//  Otto
//
//  The client tools Otto can offer Claude, by name. The tool loop asks it which tools are available
//  for a turn, their wire definitions (sorted by name so the prompt cache stays stable), the groups
//  the system prompt describes, and the local-time context block sent with each user message.
//

import Foundation
import os

@MainActor final class ToolRegistry {
    private var toolsByName: [String: any OttoTool] = [:]

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    init(tools: [any OttoTool] = []) {
        for tool in tools { register(tool) }
    }

    /// Replaces a tool with the same name. Invalid or reserved names: assertionFailure + skip.
    func register(_ tool: any OttoTool) {
        guard ToolSchema.isValidToolName(tool.name) else {
            Self.logger.fault("Refused to register a tool with the name \(tool.name, privacy: .public)")
            assertionFailure("Invalid or reserved tool name: \(tool.name)")
            return
        }
        toolsByName[tool.name] = tool
    }

    func tool(named name: String) -> (any OttoTool)? {
        toolsByName[name]
    }

    /// Sorted by name.
    var allTools: [any OttoTool] {
        toolsByName.values.sorted { $0.name < $1.name }
    }

    /// Sorted by name.
    func availableTools(in environment: ToolEnvironment) -> [any OttoTool] {
        allTools.filter { $0.isAvailable(in: environment) }
    }

    /// `tool.definition()` for each tool, in the given order.
    func definitions(for tools: [any OttoTool]) -> [JSONValue] {
        tools.map { $0.definition() }
    }

    /// Groups with at least one available tool, in ToolGroup.allCases order (system prompt).
    func enabledGroups(for tools: [any OttoTool]) -> [ToolGroup] {
        let present = Set(tools.compactMap(\.group))
        return ToolGroup.allCases.filter(present.contains)
    }

    /// When `tools` is non-empty: [text "<context>Local time: Sunday, September 27, 2026, 2:03 PM
    /// (America/Los_Angeles, UTC−07:00)</context>"]; else []. en_US_POSIX weekday/month names, the given zone.
    func userContextBlocks(tools: [any OttoTool], now: Date, timeZone: TimeZone) -> [JSONValue] {
        guard !tools.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        let local = formatter.string(from: now)
        let text = "<context>Local time: \(local) (\(timeZone.identifier), \(Self.utcOffset(timeZone, at: now)))</context>"
        return [["type": "text", "text": .string(text)]]
    }

    /// "UTC−07:00" (U+2212 minus sign) or "UTC+05:30".
    private static func utcOffset(_ timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "\u{2212}" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }
}
