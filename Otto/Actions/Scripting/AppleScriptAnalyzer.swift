//
//  AppleScriptAnalyzer.swift
//  Otto
//
//  Reads an AppleScript before the user is asked to run it: which apps it talks to, what it could do
//  (the capability chips on the card), and whether it must be blocked outright because it hides what
//  it does. Pure; built on ScriptLexer so strings, comments and «…» codes are seen for what they are.
//

import Foundation

/// An app a script sends commands to.
struct ScriptTarget: Hashable, Sendable {
    /// "Finder", or the bundle identifier when the script names the app only by id.
    let name: String
    /// Known for `application id "…"` and for well-known app names; nil otherwise.
    let bundleID: String?
    /// `tell application someVariable`: the app is only known while the script runs.
    var isDynamic = false
}

/// What a script could do. Chips only: capabilities never approve or block anything.
enum ScriptCapability: String, CaseIterable, Sendable {
    case shell, uiScripting, screenCapture, deletes, sendsMessages, network, secrets, system, files

    var label: String {
        switch self {
        case .shell: return "Runs shell commands"
        case .uiScripting: return "Controls other apps' windows and keys"
        case .screenCapture: return "Takes pictures of your screen"
        case .deletes: return "Moves or deletes items"
        case .sendsMessages: return "Sends messages"
        case .network: return "Uses the network"
        case .secrets: return "Touches passwords"
        case .system: return "Changes system state"
        case .files: return "Reads or writes files"
        }
    }

    /// Shown in bold with the danger tint.
    var isDanger: Bool {
        switch self {
        case .shell, .uiScripting, .screenCapture, .deletes, .sendsMessages, .network, .secrets: return true
        case .system, .files: return false
        }
    }
}

struct ScriptAnalysis: Equatable, Sendable {
    /// In the order the script first names them, without duplicates.
    var targets: [ScriptTarget]
    /// In `ScriptCapability.allCases` order.
    var capabilities: [ScriptCapability]
    /// Non-nil → the script is never shown for approval. A sentence without a final period
    /// (the tool result is `blocked: ‹reason›.`).
    var blockReason: String?
    var lineCount: Int
}

enum AppleScriptAnalyzer {
    static let maxLines = 400
    static let maxLineLength = 300
    /// Leading indentation wider than this (tab = 4 columns) hides content off to the side.
    static let maxIndentation = 32
    /// A run of spaces and tabs at least this wide after a line's first non-blank character does too.
    static let maxInnerWhitespace = 16

    enum BlockReason {
        static let unreadable = "Otto couldn't read this script safely"
        static let hiddenCharacters = "The script contains hidden characters that could disguise what it does"
        static let tooLong = "The script is longer than \(AppleScriptAnalyzer.maxLines) lines"
        static let hiddenLayout = "The script contains content hidden off to the side"
        static let administrator = "The script asks for administrator privileges"
        static let runtimeCode = "The script builds or loads code while it runs, so Otto can't show what would run"
        static let rawCodes = "The script uses raw Apple event codes («…»), which hide what they do"
        static let objectiveC = "The script uses AppleScriptObjC, which reaches into macOS without a visible command"
        static let hiddenAnswer = "The script asks for a hidden answer, the way a password prompt does"
        static let javaScript = "The script runs JavaScript in a web browser"
        static let sudo = "The script uses sudo"
    }

    static func analyze(_ source: String) -> ScriptAnalysis {
        let lines = sourceLines(source)
        var analysis = ScriptAnalysis(targets: [], capabilities: [], blockReason: nil, lineCount: lines.count)

        if DisplayText.containsHiddenOrBidi(source) {
            analysis.blockReason = BlockReason.hiddenCharacters
        } else if lines.count > maxLines {
            analysis.blockReason = BlockReason.tooLong
        } else if lines.contains(where: hidesContentOffToTheSide) {
            analysis.blockReason = BlockReason.hiddenLayout
        }

        guard case .success(let tokens) = ScriptLexer.tokenize(source) else {
            analysis.blockReason = analysis.blockReason ?? BlockReason.unreadable
            return analysis
        }

        let significant = significantTokens(tokens)
        let code = codeText(significant)
        let strings = concatenatedStrings(significant).map { $0.lowercased() }
        let searchable = [code] + strings

        analysis.targets = targets(in: significant)
        analysis.capabilities = capabilities(code: code, strings: strings, targets: analysis.targets)
        if analysis.blockReason == nil {
            analysis.blockReason = keywordBlockReason(tokens: significant, searchable: searchable, strings: strings)
        }
        return analysis
    }

    /// The source split into lines (\n, \r\n or \r); a final line break doesn't start another line.
    static func sourceLines(_ source: String) -> [Substring] {
        var lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count == 1, lines[0].isEmpty { return [] }
        return lines
    }

    // MARK: - Layout

    /// Longer than 300 characters, indented past 32 columns, or a wide blank run between two visible characters.
    private static func hidesContentOffToTheSide(_ line: Substring) -> Bool {
        if line.count > maxLineLength { return true }
        var column = 0
        var seenContent = false
        var runWidth = 0
        for character in line {
            let isBlank = character == " " || character == "\t"
            let width = character == "\t" ? 4 - column % 4 : 1
            if isBlank {
                if seenContent { runWidth += width }
            } else {
                if !seenContent, column > maxIndentation { return true }
                if seenContent, runWidth >= maxInnerWhitespace { return true }
                seenContent = true
                runWidth = 0
            }
            column += width
        }
        return false
    }

    // MARK: - Token views

    /// Comments dropped; `¬` and the line break after it dropped too (they only join lines).
    private static func significantTokens(_ tokens: [ScriptToken]) -> [ScriptToken] {
        var result: [ScriptToken] = []
        var joiningLine = false
        for token in tokens {
            switch token.kind {
            case .comment:
                continue
            case .continuation:
                joiningLine = true
            case .newline where joiningLine:
                joiningLine = false
            default:
                joiningLine = false
                result.append(token)
            }
        }
        return result
    }

    /// Words lowercased, strings as `"…"`, one space between tokens, statements on their own lines.
    private static func codeText(_ tokens: [ScriptToken]) -> String {
        var parts: [String] = []
        for token in tokens {
            switch token.kind {
            case .word: parts.append(token.text.lowercased())
            case .string: parts.append("\"…\"")
            case .chevron: parts.append("«»")
            case .possessive: parts.append("'s")
            case .newline: parts.append("\n")
            default: parts.append(token.text)
            }
        }
        return parts.joined(separator: " ")
    }

    /// Every string literal, plus the joined text of each run of literals connected by `&` (parentheses
    /// inside the run are ignored), so `"do sh" & "ell script"` is seen as "do shell script".
    private static func concatenatedStrings(_ tokens: [ScriptToken]) -> [String] {
        var results: [String] = []
        var run: [String] = []
        var runHasAmpersand = false

        func closeRun() {
            if runHasAmpersand, run.count > 1 { results.append(run.joined()) }
            run = []
            runHasAmpersand = false
        }

        for token in tokens {
            switch token.kind {
            case .string:
                results.append(token.text)
                run.append(token.text)
            case .ampersand:
                runHasAmpersand = true
            case .symbol where token.text == "(" || token.text == ")":
                continue
            default:
                closeRun()
            }
        }
        closeRun()
        return results
    }

    // MARK: - Targets

    /// `application "X"`, `app "X"`, `application id "com.x"` (literal chains joined), and
    /// `application someVariable` as a dynamic target.
    private static func targets(in tokens: [ScriptToken]) -> [ScriptTarget] {
        var found: [ScriptTarget] = []
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            let token = tokens[index]
            guard token.kind == .word, !token.isPiped else { continue }
            let word = token.text.lowercased()
            guard word == "application" || word == "app" else { continue }

            var cursor = index + 1
            var byID = false
            if cursor < tokens.count, tokens[cursor].kind == .word, tokens[cursor].text.lowercased() == "id" {
                byID = true
                cursor += 1
            }
            guard let (literal, next) = literalChain(in: tokens, from: cursor) else {
                if cursor < tokens.count, tokens[cursor].kind == .word,
                   !isNotAnAppName(tokens[cursor].text.lowercased()) {
                    append(ScriptTarget(name: "An app chosen while the script runs", bundleID: nil, isDynamic: true),
                           to: &found)
                }
                continue
            }
            index = next - 1
            let text = literal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if byID {
                let name = ScriptKnownApps.name(forBundleID: text) ?? text
                append(ScriptTarget(name: name, bundleID: text), to: &found)
            } else {
                append(ScriptTarget(name: text, bundleID: ScriptKnownApps.bundleID(forName: text)), to: &found)
            }
        }
        return found
    }

    /// Words that follow `application` without it naming an app to control: statement words
    /// (`of current application`), `path to application support`, System Events' `application process "X"`.
    private static func isNotAnAppName(_ word: String) -> Bool {
        ["to", "of", "in", "is", "and", "or", "then", "else", "with", "as", "tell", "end", "if", "return",
         "support", "process", "processes", "file", "files"].contains(word)
    }

    /// A string literal, or `(`…`)`-wrapped literals joined by `&`, starting at `start`.
    /// Returns the joined text and the index after the chain.
    private static func literalChain(in tokens: [ScriptToken], from start: Int) -> (String, Int)? {
        var cursor = start
        var text = ""
        var sawString = false
        var expectsString = true
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.kind == .symbol, token.text == "(" || token.text == ")" {
                cursor += 1
            } else if token.kind == .string, expectsString {
                text += token.text
                sawString = true
                expectsString = false
                cursor += 1
            } else if token.kind == .ampersand, !expectsString {
                expectsString = true
                cursor += 1
            } else {
                break
            }
        }
        return sawString ? (text, cursor) : nil
    }

    private static func append(_ target: ScriptTarget, to targets: inout [ScriptTarget]) {
        let key = target.bundleID?.lowercased() ?? target.name.lowercased()
        let exists = targets.contains { ($0.bundleID?.lowercased() ?? $0.name.lowercased()) == key }
        if !exists { targets.append(target) }
    }

    // MARK: - Capabilities

    private static func capabilities(code: String, strings: [String], targets: [ScriptTarget]) -> [ScriptCapability] {
        let searchable = [code] + strings
        let names = targets.map { $0.name.lowercased() } + targets.compactMap { $0.bundleID?.lowercased() }
        func mentions(_ needles: [String]) -> Bool {
            names.contains { name in needles.contains { name.contains($0) } }
                || strings.contains { string in needles.contains { string.contains($0) } }
        }
        func matches(_ pattern: String, in texts: [String]) -> Bool {
            texts.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }

        var found: Set<ScriptCapability> = []
        if matches(#"\bdo shell script\b"#, in: searchable)
            || (mentions(["terminal"]) && matches(#"\bdo script\b"#, in: searchable))
            || (mentions(["iterm"]) && matches(#"\bwrite text\b"#, in: searchable)) {
            found.insert(.shell)
        }
        if mentions(["system events", "systemevents"]),
           matches(#"\b(keystroke|key code|click|ui element|perform action|set value)\b"#, in: [code]) {
            found.insert(.uiScripting)
        }
        if matches(#"screencapture|cgwindowlistcreateimage"#, in: searchable) {
            found.insert(.screenCapture)
        }
        if matches(#"\b(delete|empty trash)\b|\bmove\b[^\n]*\btrash\b"#, in: [code])
            || matches(#"\b(rm|rmdir|unlink|srm)\b"#, in: strings) {
            found.insert(.deletes)
        }
        if (mentions(["mail", "messages", "mobilesms"]) && matches(#"\bsend\b"#, in: [code]))
            || matches(#"\boutgoing message\b"#, in: [code]) {
            found.insert(.sendsMessages)
        }
        if matches(#"\b(curl|wget|nc|ssh|scp|sftp|ftp|telnet|rsync)\b|https?://"#, in: strings)
            || matches(#"\bopen location\b"#, in: [code]) {
            found.insert(.network)
        }
        if matches(#"keychain|password|\bsecurity\s+(find|dump|export|delete)-"#, in: searchable) {
            found.insert(.secrets)
        }
        if matches(#"\b(shut down|restart|log out|sleep|set volume)\b"#, in: [code])
            || mentions(["system settings", "system preferences", "systempreferences"]) {
            found.insert(.system)
        }
        if matches(#"\bposix (file|path)\b|\balias\b|\bopen for access\b|\bclose access\b|\bread\b|\bwrite\b(?! text)"#,
                   in: [code]) {
            found.insert(.files)
        }
        return ScriptCapability.allCases.filter(found.contains)
    }

    // MARK: - Hard blocks

    private static func keywordBlockReason(tokens: [ScriptToken], searchable: [String], strings: [String]) -> String? {
        func matches(_ pattern: String, in texts: [String]) -> Bool {
            texts.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        if matches(#"\badministrator privileges\b"#, in: searchable) { return BlockReason.administrator }
        if matches(#"\b(run|load|store|use) script\b"#, in: searchable) { return BlockReason.runtimeCode }
        if tokens.contains(where: { $0.kind == .chevron }) { return BlockReason.rawCodes }
        if matches(#"\buse framework\b|\bcurrent application\s*['’]\s*s\b|\bof current application\b"#, in: searchable) {
            return BlockReason.objectiveC
        }
        if matches(#"\bhidden answer\b"#, in: searchable) { return BlockReason.hiddenAnswer }
        if matches(#"\bdo javascript\b|\bexecute\b[^\n]*\bjavascript\b"#, in: searchable) {
            return BlockReason.javaScript
        }
        if matches(#"\bsudo\b"#, in: strings) { return BlockReason.sudo }
        return nil
    }
}
