//
//  ScriptToolSupport.swift
//  Otto
//
//  Small helpers the four scripting tools share: reading input fields, the local length limits of the
//  Actions design, availability by settings group, and result JSON that stays inside the tool-result cap.
//

import Foundation

enum ScriptToolSupport {
    /// Local limits in characters, counted after trimming (actions.md §5.1).
    enum Limit {
        static let folder = 200
        static let shortcutName = 200
        static let shortcutInput = 20_000
        static let script = 20_000
        static let purpose = 300
        static let url = URLGuard.maxLength
    }

    static func string(_ input: JSONValue, _ key: String) -> String? {
        input[key]?.stringValue
    }

    /// nil when the field is valid. Empty after trimming counts as missing.
    static func checkLength(_ input: JSONValue, _ key: String, required: Bool, max: Int) -> ToolError? {
        guard let value = string(input, key) else {
            return required ? invalid("$.\(key): is required") : nil
        }
        let count = value.trimmingCharacters(in: .whitespacesAndNewlines).count
        if count == 0 {
            return required ? invalid("$.\(key): is empty") : invalid("$.\(key): is empty; leave it out instead")
        }
        if count > max {
            return invalid("$.\(key): must be \(max) characters or fewer (it has \(count))")
        }
        return nil
    }

    /// nil when the field has no hidden, bidi or control characters (line breaks and tabs are fine).
    static func checkVisible(_ input: JSONValue, _ key: String) -> ToolError? {
        guard let value = string(input, key), containsHiddenCharacters(value) else { return nil }
        return invalid("$.\(key): contains hidden or control characters; send plain text")
    }

    /// `DisplayText.containsHiddenOrBidi`, except that a zero-width joiner inside an emoji sequence (👩‍💻), which
    /// renders as one visible emoji, is allowed.
    static func containsHiddenCharacters(_ text: String) -> Bool {
        text.contains { character in
            let scalars = character.unicodeScalars
            let joined = scalars.filter { $0.value != 0x200D && !$0.properties.isVariationSelector }
            let isEmojiSequence = scalars.contains { $0.value == 0x200D } && joined.count >= 2
                && joined.allSatisfy { $0.properties.isEmoji }
                && joined.contains { $0.properties.isEmojiPresentation }
            return !isEmojiSequence && DisplayText.containsHiddenOrBidi(String(character))
        }
    }

    static func invalid(_ problem: String) -> ToolError {
        ToolError(code: .invalidInput, modelMessage: problem, userMessage: "Invalid request")
    }

    /// Demo, self-test and snapshot runs count every group except AppleScript as on.
    @MainActor static func isAvailable(_ group: ToolGroup, in environment: ToolEnvironment) -> Bool {
        if environment.isDemo, group != .appleScript { return true }
        return environment.settings.actions.isEnabled(group)
    }

    /// Compact JSON with sorted keys. When it would pass `ToolOutput.maxTextCharacters`, the string at
    /// `truncating` is shortened (ending in "…(truncated)") and `"truncated": true` is added.
    static func resultJSON(_ fields: [String: JSONValue], truncating key: String? = nil,
                           budget: Int = ToolOutput.maxTextCharacters) -> String {
        let full = JSONValue.object(fields).encodedString()
        guard full.count > budget, let key, case .string(let text)? = fields[key] else { return full }

        func encoded(keeping count: Int) -> String {
            var shortened = fields
            shortened[key] = .string(String(text.prefix(count)) + "…(truncated)")
            shortened["truncated"] = true
            return JSONValue.object(shortened).encodedString()
        }
        var low = 0
        var high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            if encoded(keeping: middle).count <= budget { low = middle } else { high = middle - 1 }
        }
        return encoded(keeping: low)
    }

    /// "“Log water”" for titles and chips: cleaned of hidden characters and capped.
    static func quoted(_ text: String, maxLength: Int = 60) -> String {
        "“\(DisplayText.sanitized(text, maxLength: maxLength))”"
    }
}
