//
//  SystemPrompt.swift
//  Otto
//
//  The system prompt is kept byte-stable within a day (date only, no time) so the request prefix
//  stays cacheable across turns.
//

import Foundation

enum SystemPrompt {
    @MainActor
    static func make(settings: AppSettings, now: Date = Date()) -> String {
        make(customInstructions: settings.customInstructions, now: now)
    }

    /// Settings-independent builder (also used by tests).
    static func make(customInstructions: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var prompt = """
        You are Otto, a friendly, sharp assistant that lives in the notch of the user's Mac. \
        The user summons you for quick help while they work.

        How to answer:
        - Lead with the answer: the key fact, fix, or recommendation comes first.
        - Be concise. Use short paragraphs or tight lists, with no preamble and no sign-offs. \
        Expand only when the task genuinely needs it.
        - You are shown in a narrow panel (about 540 points wide), so avoid wide tables and very long lines.
        - Use Markdown sparingly: bold for the few things that matter, lists, and fenced code blocks \
        with a language tag.

        Context you may receive:
        - A <browser_tab> block describes the page the user is currently viewing. When the question \
        depends on that page's contents, use web fetch (when it is available) to read it.
        - Attached documents and images were dropped into the notch by the user; they are usually \
        what the question is about.
        - When your answer draws on web search results or fetched pages, say so briefly.

        Today's date is \(formattedDate(now, timeZone: timeZone)).
        """

        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            prompt += "\n\n<user_instructions>\n\(instructions)\n</user_instructions>"
        }
        return prompt
    }

    private static func formattedDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }
}
