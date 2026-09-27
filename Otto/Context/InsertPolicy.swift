//
//  InsertPolicy.swift
//  Otto
//
//  Decides what goes on the pasteboard when Otto pastes an answer into another app: which kind of app it
//  is, which representations to write, how the text is cleaned so it can't smuggle control characters
//  into a terminal, and when a paste needs the user's confirmation first. Pure.
//

import Foundation

enum TargetCategory: Equatable, Sendable {
    /// Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty, Hyper, WezTerm, Tabby, Termius, Rio, and any app whose
    /// bundle id or name contains "term".
    case terminal
    /// Xcode, VS Code (+ Insiders), Cursor, Zed, Sublime Text, Nova, BBEdit, JetBrains IDEs.
    case codeEditor
    /// Obsidian, Bear, iA Writer, MacDown, Typora.
    case markdownNative
    /// Everything else (Notes, Mail, Pages, Slack, browsers, …).
    case standard

    private static let terminals: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "dev.warp.warp-preview",
        "com.mitchellh.ghostty", "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
        "com.github.wez.wezterm", "org.tabby", "com.termius-dmg.mac", "com.raphaelamorim.rio",
    ]
    private static let codeEditors: Set<String> = [
        "com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.sublimetext.4", "com.panic.nova", "com.barebones.bbedit",
    ]
    private static let codeEditorPrefixes = ["com.jetbrains."]
    private static let markdownApps: Set<String> = [
        "md.obsidian", "net.shinyfrog.bear", "pro.writer.mac", "com.uranusjr.macdown", "abnerworks.typora",
    ]

    static func of(bundleID: String?) -> TargetCategory {
        of(bundleID: bundleID, appName: nil)
    }

    /// Known lists first; then any bundle id or app name containing "term" (case-insensitive) is a terminal.
    /// The heuristic only ever adds caution: it never turns a known terminal into something else.
    static func of(bundleID: String?, appName: String?) -> TargetCategory {
        let id = bundleID?.lowercased() ?? ""
        if terminals.contains(id) { return .terminal }
        if codeEditors.contains(id) || codeEditorPrefixes.contains(where: { id.hasPrefix($0) }) { return .codeEditor }
        if markdownApps.contains(id) { return .markdownNative }
        if id.contains("term") || (appName?.lowercased().contains("term") ?? false) { return .terminal }
        return .standard
    }
}

struct PastePayload: Equatable, Sendable {
    var plain: String
    var rtf: Data?
    var html: String?
    /// The answer is a single fenced block tagged sh, bash, zsh, console, shell or fish (a code editor's
    /// integrated terminal may run each line).
    var isShellCommandBlock = false

    /// Lines a terminal would execute (after trimming the trailing newline); used for the confirm row.
    var lineCount: Int {
        let trimmed = InsertPolicy.trimmingTrailingNewlines(plain)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
    }
}

enum InsertPolicy {
    /// ChatSession's max_tokens marker.
    static let truncationMarker = "_(Reply truncated.)_"
    /// Fence tags whose lines a shell would run.
    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "console", "shell", "fish"]

    /// Strips "_(Reply truncated.)_" and trailing whitespace.
    static func cleanedAnswer(_ markdown: String) -> String {
        var text = trimmingTrailingWhitespace(markdown)
        if text.hasSuffix(truncationMarker) {
            text = trimmingTrailingWhitespace(String(text.dropLast(truncationMarker.count)))
        }
        return text
    }

    /// Decision table (context-io.md §3.3) after hygiene: CRLF, CR, U+2028, U+2029, U+0085, VT and FF become `\n`;
    /// every other C0 control except `\t`/`\n`, DEL, C1 controls and ESC are removed.
    static func payload(for markdown: String, category: TargetCategory, mode: InsertMode) -> PastePayload {
        let answer = cleanedAnswer(sanitized(markdown))
        let block = RichTextRenderer.codeOnlyBlock(answer)
        let code = block?.code
        switch category {
        case .terminal:
            return PastePayload(plain: trimmingTrailingNewlines(code ?? RichTextRenderer.plainText(answer)))
        case .codeEditor:
            let isShell = block?.language.map { shellLanguages.contains($0.lowercased()) } ?? false
            return PastePayload(plain: code ?? answer, isShellCommandBlock: isShell)
        case .markdownNative:
            return PastePayload(plain: answer)
        case .standard:
            if let code { return PastePayload(plain: code) }
            let plain = RichTextRenderer.plainText(answer)
            switch mode {
            case .pastePlain:
                return PastePayload(plain: plain)
            case .paste, .replaceSelection:
                return PastePayload(plain: plain, rtf: RichTextRenderer.rtf(answer), html: RichTextRenderer.html(answer))
            }
        }
    }

    /// A terminal paste of more than one line, or a code editor paste of a multi-line shell block.
    static func needsMultilineConfirmation(_ payload: PastePayload, category: TargetCategory) -> Bool {
        guard payload.lineCount > 1 else { return false }
        switch category {
        case .terminal: return true
        case .codeEditor: return payload.isShellCommandBlock
        case .markdownNative, .standard: return false
        }
    }

    /// Restore delay after posting ⌘V.
    static func restoreDelay(isChromiumOrElectron: Bool) -> Duration {
        isChromiumOrElectron ? .milliseconds(1500) : .milliseconds(700)
    }

    static func verifyDelay(isChromiumOrElectron: Bool) -> Duration {
        isChromiumOrElectron ? .milliseconds(600) : .milliseconds(300)
    }

    // MARK: Hygiene

    /// Line separators → `\n`; other C0 controls (except `\t` and `\n`), ESC, DEL and C1 controls removed, so an
    /// answer can't smuggle a line break a terminal executes or `ESC[201~` to end bracketed-paste mode early.
    static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            defer { previousWasCarriageReturn = scalar == "\r" }
            switch scalar.value {
            case 0x0A:
                // "\r\n" is one line break.
                if !previousWasCarriageReturn { scalars.append("\n") }
            case 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                scalars.append("\n")
            case 0x09:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func trimmingTrailingNewlines(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isNewline || last.isWhitespace { result = result.dropLast() }
        return String(result)
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }
}
