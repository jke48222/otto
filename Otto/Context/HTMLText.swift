//
//  HTMLText.swift
//  Otto
//
//  Converts HTML to readable plain text without a browser engine. Nothing is
//  fetched (no stylesheets, images, frames or tracking pixels), no scripts run,
//  and it is safe to call from any thread — unlike AppKit's WebKit-backed HTML
//  importer, which must run on the main thread and loads every subresource.
//

import Foundation

enum HTMLText {
    /// Readable text of an HTML document: tags removed, entities decoded, whitespace collapsed (except in
    /// `<pre>`), block elements on their own lines, list items prefixed, table cells tab-separated.
    /// `script`, `style`, `title`, `template`, `svg`, … contents are dropped. Conversion stops once the output
    /// passes `maxOutputBytes` (the result is then at least that long, so callers can reject it as too large).
    static func plainText(fromHTML html: String, maxOutputBytes: Int = .max) -> String {
        var html = html
        let text: String = html.withUTF8 { source in
            var converter = Converter(source: source, maxOutputBytes: maxOutputBytes)
            converter.run()
            return String(decoding: converter.writer.bytes, as: UTF8.self)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The character set named by a `<meta charset=…>` or `http-equiv` declaration near the start of the
    /// document, if it names an encoding Foundation knows. UTF-16/32 declarations are ignored (without a BOM
    /// they are almost always wrong, and the declaration itself was readable as ASCII).
    static func declaredEncoding(in data: Data) -> String.Encoding? {
        let prefix = [UInt8](data.prefix(2048)).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        let needle = Array("charset".utf8)
        guard prefix.count > needle.count else { return nil }
        var index = 0
        while index + needle.count <= prefix.count {
            if prefix[index] == needle[0], Array(prefix[index..<index + needle.count]) == needle {
                var cursor = index + needle.count
                while cursor < prefix.count, isHTMLWhitespace(prefix[cursor]) { cursor += 1 }
                guard cursor < prefix.count, prefix[cursor] == UInt8(ascii: "=") else {
                    index += needle.count
                    continue
                }
                cursor += 1
                while cursor < prefix.count,
                      isHTMLWhitespace(prefix[cursor]) || prefix[cursor] == UInt8(ascii: "\"") || prefix[cursor] == UInt8(ascii: "'") {
                    cursor += 1
                }
                let start = cursor
                while cursor < prefix.count, isCharsetNameByte(prefix[cursor]) { cursor += 1 }
                guard cursor > start else { return nil }
                return encoding(ianaName: String(decoding: prefix[start..<cursor], as: UTF8.self))
            }
            index += 1
        }
        return nil
    }

    /// Foundation encoding for an IANA character set name ("utf-8", "iso-8859-1", "windows-1252", "shift_jis", …).
    static func encoding(ianaName: String) -> String.Encoding? {
        let name = ianaName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !name.hasPrefix("utf-16"), !name.hasPrefix("utf-32"), !name.hasPrefix("ucs") else {
            return nil
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    // MARK: - Conversion

    private static func isHTMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || (byte >= 0x30 && byte <= 0x39)
    }

    private static func isCharsetNameByte(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte
    }

    /// Elements whose contents are never shown as text. (`head` is not listed: its end tag is optional, and its
    /// children — title, style, script, meta, link — are dropped individually.)
    private static let skippedElements: Set<String> = [
        "script", "style", "title", "template", "noscript", "iframe", "object", "svg", "canvas",
        "video", "audio", "select", "datalist", "noembed", "noframes",
    ]

    /// Block elements separated from their surroundings by a blank line.
    private static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "ul", "ol", "dl",
        "figure", "address", "fieldset", "hr", "listing", "xmp",
    ]

    /// Block elements that start on a new line.
    private static let lineElements: Set<String> = [
        "div", "section", "article", "header", "footer", "aside", "nav", "main", "li", "dt", "dd", "tr",
        "caption", "figcaption", "details", "summary", "legend", "center", "form", "body", "html",
        "hgroup", "menu", "dialog", "search", "option", "textarea",
    ]

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
        "track", "wbr",
    ]

    private struct Writer {
        var bytes: [UInt8] = []
        let maxOutputBytes: Int
        /// 0 = none, 1 = new line, 2 = blank line.
        var pendingBreaks = 0
        var pendingTab = false
        var pendingSpace = false
        var pendingPrefix: [UInt8] = []

        var isFull: Bool { bytes.count > maxOutputBytes }

        mutating func requestBreak(_ count: Int) {
            pendingBreaks = max(pendingBreaks, count)
        }

        mutating func lineBreak() {
            pendingBreaks = min(pendingBreaks + 1, 2)
        }

        /// Emits whatever separator is pending, then the prefix (list bullet), before visible content.
        mutating func flushPending() {
            if !bytes.isEmpty {
                if pendingBreaks > 0 {
                    // Trailing spaces never end a line.
                    while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
                    bytes.append(contentsOf: repeatElement(0x0A, count: pendingBreaks))
                } else if pendingTab {
                    bytes.append(0x09)
                } else if pendingSpace {
                    bytes.append(0x20)
                }
            }
            if !pendingPrefix.isEmpty {
                bytes.append(contentsOf: pendingPrefix)
                pendingPrefix = []
            }
            pendingBreaks = 0
            pendingTab = false
            pendingSpace = false
        }

        mutating func append<C: Collection>(visible content: C) where C.Element == UInt8 {
            flushPending()
            bytes.append(contentsOf: content)
        }

        mutating func append(scalar: Unicode.Scalar) {
            flushPending()
            bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
        }

        /// Whitespace inside `<pre>`: kept literally (line breaks become real new lines).
        mutating func appendPreformatted(_ byte: UInt8) {
            if byte == 0x0A {
                if bytes.isEmpty { return }
                pendingSpace = false
                pendingTab = false
                bytes.append(0x0A)
            } else {
                flushPending()
                bytes.append(byte)
            }
        }
    }

    private struct ListState {
        let ordered: Bool
        var counter: Int
    }

    private struct Converter {
        let source: UnsafeBufferPointer<UInt8>
        var writer: Writer
        var index = 0
        var preDepth = 0
        var lists: [ListState] = []

        init(source: UnsafeBufferPointer<UInt8>, maxOutputBytes: Int) {
            self.source = source
            writer = Writer(maxOutputBytes: maxOutputBytes)
        }

        mutating func run() {
            let count = source.count
            while index < count, !writer.isFull {
                let byte = source[index]
                if byte == UInt8(ascii: "<") {
                    handleMarkup()
                } else if byte == UInt8(ascii: "&") {
                    handleEntity()
                } else if HTMLText.isHTMLWhitespace(byte) {
                    handleWhitespace(byte)
                    index += 1
                } else {
                    let start = index
                    while index < count {
                        let next = source[index]
                        if next == UInt8(ascii: "<") || next == UInt8(ascii: "&") || HTMLText.isHTMLWhitespace(next) { break }
                        index += 1
                    }
                    writer.append(visible: source[start..<index])
                }
            }
        }

        private mutating func handleWhitespace(_ byte: UInt8) {
            if preDepth > 0 {
                if byte == 0x0D {
                    // CRLF / lone CR → one line break.
                    if index + 1 < source.count, source[index + 1] == 0x0A { return }
                    writer.appendPreformatted(0x0A)
                } else if byte != 0x0C {
                    writer.appendPreformatted(byte)
                }
            } else {
                writer.pendingSpace = true
            }
        }

        // MARK: Markup

        private mutating func handleMarkup() {
            let count = source.count
            guard index + 1 < count else {
                writer.append(visible: [UInt8(ascii: "<")])
                index += 1
                return
            }
            let next = source[index + 1]
            if next == UInt8(ascii: "!") {
                if starts(with: "<!--", at: index) {
                    index = position(after: Array("-->".utf8), from: index + 4)
                } else {
                    index = position(after: [UInt8(ascii: ">")], from: index + 2)
                }
                return
            }
            if next == UInt8(ascii: "?") {
                index = position(after: [UInt8(ascii: ">")], from: index + 2)
                return
            }
            if next == UInt8(ascii: "/") {
                let nameStart = index + 2
                guard nameStart < count, HTMLText.isASCIILetter(source[nameStart]) else {
                    // `</` followed by a non-letter is a bogus comment.
                    index = position(after: [UInt8(ascii: ">")], from: nameStart)
                    return
                }
                let name = readName(from: nameStart)
                index = endOfTag(from: nameStart + name.utf8.count).end
                closeElement(name)
                return
            }
            guard HTMLText.isASCIILetter(next) else {
                writer.append(visible: [UInt8(ascii: "<")])
                index += 1
                return
            }
            let name = readName(from: index + 1)
            let tag = endOfTag(from: index + 1 + name.utf8.count)
            index = tag.end
            openElement(name, selfClosing: tag.selfClosing)
        }

        private mutating func openElement(_ name: String, selfClosing: Bool) {
            if HTMLText.skippedElements.contains(name) {
                if !selfClosing, !HTMLText.voidElements.contains(name) {
                    skipContents(of: name)
                }
                return
            }
            switch name {
            case "br":
                if preDepth > 0 {
                    writer.appendPreformatted(0x0A)
                } else {
                    writer.lineBreak()
                }
                return
            case "pre", "listing", "xmp", "plaintext":
                preDepth += 1
            case "ul", "menu":
                lists.append(ListState(ordered: false, counter: 0))
            case "ol":
                lists.append(ListState(ordered: true, counter: 0))
            default:
                break
            }
            if HTMLText.paragraphElements.contains(name) {
                writer.requestBreak(lists.count > 1 && (name == "ul" || name == "ol") ? 1 : 2)
            } else if HTMLText.lineElements.contains(name) {
                writer.requestBreak(1)
            }
            if name == "li" {
                var marker = "- "
                if !lists.isEmpty {
                    lists[lists.count - 1].counter += 1
                    if lists[lists.count - 1].ordered {
                        marker = "\(lists[lists.count - 1].counter). "
                    }
                }
                let indent = String(repeating: "  ", count: max(0, lists.count - 1))
                writer.pendingPrefix = Array((indent + marker).utf8)
            }
            if name == "hr" { writer.requestBreak(2) }
        }

        private mutating func closeElement(_ name: String) {
            switch name {
            case "pre", "listing", "xmp", "plaintext":
                preDepth = max(0, preDepth - 1)
            case "ul", "ol", "menu":
                if !lists.isEmpty { lists.removeLast() }
            case "td", "th":
                writer.pendingTab = true
            case "li":
                writer.pendingPrefix = []
            case "br":
                // `</br>` is treated as `<br>` by browsers.
                writer.lineBreak()
                return
            default:
                break
            }
            if HTMLText.paragraphElements.contains(name) {
                writer.requestBreak(lists.isEmpty ? 2 : 1)
            } else if HTMLText.lineElements.contains(name) {
                writer.requestBreak(1)
            }
        }

        /// Lowercased tag name starting at `start` (letters, digits, `-`, `:`).
        private func readName(from start: Int) -> String {
            var cursor = start
            var name: [UInt8] = []
            while cursor < source.count {
                let byte = source[cursor]
                guard HTMLText.isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":") else { break }
                name.append(HTMLText.lowercased(byte))
                cursor += 1
            }
            return String(decoding: name, as: UTF8.self)
        }

        /// Index just past the tag's closing `>`, skipping quoted attribute values.
        private func endOfTag(from start: Int) -> (end: Int, selfClosing: Bool) {
            var cursor = start
            var lastSignificant: UInt8 = 0
            while cursor < source.count {
                let byte = source[cursor]
                if byte == UInt8(ascii: ">") {
                    return (cursor + 1, lastSignificant == UInt8(ascii: "/"))
                }
                if (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'")) && lastSignificant == UInt8(ascii: "=") {
                    var closing = cursor + 1
                    while closing < source.count, source[closing] != byte { closing += 1 }
                    cursor = closing + 1
                    lastSignificant = byte
                    continue
                }
                if !HTMLText.isHTMLWhitespace(byte) { lastSignificant = byte }
                cursor += 1
            }
            return (source.count, false)
        }

        /// Moves past the matching `</name` end tag (or to the end of the document).
        private mutating func skipContents(of name: String) {
            let needle = Array("</\(name)".utf8)
            var cursor = index
            while cursor + needle.count <= source.count {
                if source[cursor] == UInt8(ascii: "<"), matchesIgnoringCase(needle, at: cursor) {
                    let after = cursor + needle.count
                    if after >= source.count || !HTMLText.isASCIIAlphanumeric(source[after]) {
                        index = endOfTag(from: after).end
                        // Leaving a hidden block still separates what came before and after it.
                        writer.pendingSpace = true
                        return
                    }
                }
                cursor += 1
            }
            index = source.count
        }

        private func matchesIgnoringCase(_ needle: [UInt8], at position: Int) -> Bool {
            guard position + needle.count <= source.count else { return false }
            for offset in 0..<needle.count where HTMLText.lowercased(source[position + offset]) != needle[offset] {
                return false
            }
            return true
        }

        private func starts(with prefix: String, at position: Int) -> Bool {
            matchesIgnoringCase(Array(prefix.utf8), at: position)
        }

        /// Index just past the next occurrence of `terminator` at or after `start` (or the end of the document).
        private func position(after terminator: [UInt8], from start: Int) -> Int {
            var cursor = start
            while cursor + terminator.count <= source.count {
                if source[cursor] == terminator[0], matchesIgnoringCase(terminator, at: cursor) {
                    return cursor + terminator.count
                }
                cursor += 1
            }
            return source.count
        }

        // MARK: Entities

        private mutating func handleEntity() {
            let count = source.count
            var cursor = index + 1
            if cursor < count, source[cursor] == UInt8(ascii: "#") {
                cursor += 1
                var isHex = false
                if cursor < count, source[cursor] == UInt8(ascii: "x") || source[cursor] == UInt8(ascii: "X") {
                    isHex = true
                    cursor += 1
                }
                let digitsStart = cursor
                var value: UInt32 = 0
                while cursor < count, cursor - digitsStart < 8 {
                    let byte = source[cursor]
                    let digit: UInt32
                    if byte >= 0x30 && byte <= 0x39 {
                        digit = UInt32(byte - 0x30)
                    } else if isHex, byte >= 0x61 && byte <= 0x66 {
                        digit = UInt32(byte - 0x61 + 10)
                    } else if isHex, byte >= 0x41 && byte <= 0x46 {
                        digit = UInt32(byte - 0x41 + 10)
                    } else {
                        break
                    }
                    value = value * (isHex ? 16 : 10) + digit
                    cursor += 1
                }
                guard cursor > digitsStart else {
                    literalAmpersand()
                    return
                }
                if cursor < count, source[cursor] == UInt8(ascii: ";") { cursor += 1 }
                index = cursor
                emit(Unicode.Scalar(HTMLText.windows1252Remap[value] ?? value) ?? "\u{FFFD}")
                return
            }

            let nameStart = cursor
            while cursor < count, cursor - nameStart < 32, HTMLText.isASCIIAlphanumeric(source[cursor]) { cursor += 1 }
            guard cursor > nameStart else {
                literalAmpersand()
                return
            }
            let name = String(decoding: source[nameStart..<cursor], as: UTF8.self)
            if cursor < count, source[cursor] == UInt8(ascii: ";"), let scalar = HTMLText.namedEntities[name] {
                index = cursor + 1
                emit(scalar)
            } else if HTMLText.legacyEntities.contains(name), let scalar = HTMLText.namedEntities[name] {
                index = cursor
                emit(scalar)
            } else {
                literalAmpersand()
            }
        }

        private mutating func literalAmpersand() {
            writer.append(visible: [UInt8(ascii: "&")])
            index += 1
        }

        private mutating func emit(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x0A, 0x0D:
                if preDepth > 0 { writer.appendPreformatted(0x0A) } else { writer.pendingSpace = true }
            case 0x09, 0x20, 0x0C, 0xA0:
                if preDepth > 0 { writer.appendPreformatted(0x20) } else { writer.pendingSpace = true }
            case 0x00:
                break
            default:
                writer.append(scalar: scalar)
            }
        }
    }

    // MARK: - Entity tables

    /// Numeric references in the C1 range mean Windows-1252 characters (as browsers treat them).
    private static let windows1252Remap: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178, 0: 0xFFFD,
    ]

    /// Entities browsers also recognize without the trailing semicolon.
    private static let legacyEntities: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    private static let namedEntities: [String: Unicode.Scalar] = {
        var table: [String: Unicode.Scalar] = [:]
        // U+00A0 … U+00FF in order.
        let latin1 = """
        nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
        acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde \
        Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc \
        Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml \
        aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc \
        otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
        """
        for (offset, name) in latin1.split(separator: " ").enumerated() {
            table[String(name)] = Unicode.Scalar(UInt32(0xA0 + offset))
        }
        let others: [String: UInt32] = [
            "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27,
            "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E,
            "rlm": 0x200F, "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A,
            "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021,
            "bull": 0x2022, "hellip": 0x2026, "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033,
            "lsaquo": 0x2039, "rsaquo": 0x203A, "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC,
            "trade": 0x2122, "larr": 0x2190, "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194,
            "lArr": 0x21D0, "uArr": 0x21D1, "rArr": 0x21D2, "dArr": 0x21D3, "hArr": 0x21D4, "forall": 0x2200,
            "part": 0x2202, "exist": 0x2203, "empty": 0x2205, "nabla": 0x2207, "isin": 0x2208, "notin": 0x2209,
            "sum": 0x2211, "prod": 0x220F, "minus": 0x2212, "lowast": 0x2217, "radic": 0x221A, "prop": 0x221D,
            "infin": 0x221E, "and": 0x2227, "or": 0x2228, "cap": 0x2229, "cup": 0x222A, "int": 0x222B,
            "there4": 0x2234, "sim": 0x223C, "cong": 0x2245, "asymp": 0x2248, "ne": 0x2260, "equiv": 0x2261,
            "le": 0x2264, "ge": 0x2265, "sub": 0x2282, "sup": 0x2283, "sube": 0x2286, "supe": 0x2287,
            "loz": 0x25CA, "spades": 0x2660, "clubs": 0x2663, "hearts": 0x2665, "diams": 0x2666,
            "OElig": 0x0152, "oelig": 0x0153, "Scaron": 0x0160, "scaron": 0x0161, "Yuml": 0x0178,
            "fnof": 0x0192, "circ": 0x02C6, "tilde": 0x02DC, "Alpha": 0x0391, "Beta": 0x0392, "Gamma": 0x0393,
            "Delta": 0x0394, "Theta": 0x0398, "Lambda": 0x039B, "Pi": 0x03A0, "Sigma": 0x03A3, "Phi": 0x03A6,
            "Psi": 0x03A8, "Omega": 0x03A9, "alpha": 0x03B1, "beta": 0x03B2, "gamma": 0x03B3, "delta": 0x03B4,
            "epsilon": 0x03B5, "zeta": 0x03B6, "eta": 0x03B7, "theta": 0x03B8, "iota": 0x03B9, "kappa": 0x03BA,
            "lambda": 0x03BB, "mu": 0x03BC, "nu": 0x03BD, "xi": 0x03BE, "omicron": 0x03BF, "pi": 0x03C0,
            "rho": 0x03C1, "sigmaf": 0x03C2, "sigma": 0x03C3, "tau": 0x03C4, "upsilon": 0x03C5, "phi": 0x03C6,
            "chi": 0x03C7, "psi": 0x03C8, "omega": 0x03C9, "check": 0x2713, "star": 0x2606, "starf": 0x2605,
        ]
        for (name, value) in others {
            table[name] = Unicode.Scalar(value)
        }
        return table
    }()
}
