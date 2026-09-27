//
//  URLGuard.swift
//  Otto
//
//  Decides whether open_url may open an address, and what the card shows for it. Hosts are canonicalized
//  the way browsers do it (percent-decoding, IDNA, a trailing dot, numeric IPv4 forms like 127.1 or
//  0x7f000001, bracketed IPv6) before any check, so no spelling of a local address gets through.
//

import Darwin
import Foundation

enum URLGuard {
    /// A URL that may be opened, and what the card shows for it.
    struct Checked: Equatable, Sendable {
        /// What gets opened: canonical ASCII host, the path, query and fragment percent-encoded.
        let url: URL
        /// The host as a person reads it (Unicode for internationalized names).
        let displayHost: String
        /// The ASCII (punycode) host when it differs from `displayHost`.
        let punycodeHost: String?
        let warnings: [Warning]
    }

    enum Warning: String, CaseIterable, Sendable {
        case insecure, unusualHost, longQuery

        /// The chip on the card.
        var label: String {
            switch self {
            case .insecure: return "Not secure (http)"
            case .unusualHost: return "Unusual characters in address"
            case .longQuery: return "Long query string"
            }
        }
    }

    /// Why an address can't be opened.
    struct Rejection: Error, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The input is malformed: the model can fix it (`invalid_input`).
            case invalid
            /// Otto won't open it (`blocked`).
            case blocked
        }

        let kind: Kind
        /// A sentence without a final period.
        let reason: String
    }

    static let maxLength = 2_048
    static let longQueryLength = 200
    /// Names under these suffixes (and the bare suffix itself) resolve on the local network.
    static let blockedSuffixes = ["local", "localhost", "home.arpa", "internal", "lan"]

    enum Reason {
        static let local = "Otto doesn't open local network addresses"
        static let scheme = "Otto only opens http and https links"
        static let userInfo = "Otto doesn't open links with a user name or password in them"
        static let notAbsolute = "The address must be a complete http or https URL"
        static let characters = "The address contains spaces, control characters or hidden characters"
        static let backslash = "The address contains a backslash, which browsers read as a slash"
        static let host = "The address has no valid host name"
        static let port = "The address has an invalid port"
        static let tooLong = "The address is longer than \(URLGuard.maxLength) characters"
    }

    // MARK: - Check

    static func check(_ raw: String) -> Result<Checked, Rejection> {
        func invalid(_ reason: String) -> Result<Checked, Rejection> { .failure(Rejection(kind: .invalid, reason: reason)) }
        func blocked(_ reason: String) -> Result<Checked, Rejection> { .failure(Rejection(kind: .blocked, reason: reason)) }

        guard raw.count <= maxLength else { return invalid(Reason.tooLong) }
        if raw.contains(where: { $0.isWhitespace }) || DisplayText.containsHiddenOrBidi(raw)
            || raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return invalid(Reason.characters)
        }
        guard let separator = raw.range(of: "://") else {
            if let colon = raw.firstIndex(of: ":"), !raw[..<colon].isEmpty,
               !["http", "https"].contains(raw[..<colon].lowercased()) {
                return blocked(Reason.scheme)
            }
            return invalid(Reason.notAbsolute)
        }
        let scheme = raw[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return blocked(Reason.scheme) }
        if raw.contains("\\") { return invalid(Reason.backslash) }

        let afterScheme = raw[separator.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = String(afterScheme[..<authorityEnd])
        let rest = String(afterScheme[authorityEnd...])
        if authority.contains("@") { return blocked(Reason.userInfo) }

        guard let (hostPart, port) = splitHostAndPort(authority) else { return invalid(Reason.port) }
        let host: Host
        switch parseHost(hostPart) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let parsed): host = parsed
        }
        if isBlocked(host) { return blocked(Reason.local) }

        let portText = port.map { ":\($0)" } ?? ""
        let encodedRest = percentEncodedRest(rest)
        guard let url = URL(string: "\(scheme)://\(host.urlForm)\(portText)\(encodedRest)") else {
            return invalid(Reason.host)
        }

        var warnings: [Warning] = []
        if scheme == "http" { warnings.append(.insecure) }
        if host.isInternationalized { warnings.append(.unusualHost) }
        if let query = url.query(percentEncoded: true), query.count > longQueryLength { warnings.append(.longQuery) }
        let punycode = host.displayForm == host.urlForm ? nil : host.urlForm
        return .success(Checked(url: url, displayHost: host.displayForm, punycodeHost: punycode, warnings: warnings))
    }

    // MARK: - Hosts

    enum Host: Equatable, Sendable {
        case domain(ascii: String, display: String)
        case ipv4(UInt32)
        case ipv6([UInt8])

        var urlForm: String {
            switch self {
            case .domain(let ascii, _): return ascii
            case .ipv4(let address): return URLGuard.dotted(address)
            case .ipv6(let bytes): return "[" + URLGuard.ipv6String(bytes) + "]"
            }
        }

        var displayForm: String {
            switch self {
            case .domain(_, let display): return display
            case .ipv4, .ipv6: return urlForm
            }
        }

        var isInternationalized: Bool {
            if case .domain(let ascii, _) = self {
                return ascii.split(separator: ".").contains { $0.hasPrefix("xn--") }
            }
            return false
        }
    }

    /// Canonicalizes an authority's host the way a browser would. Brackets → IPv6 (inet_pton); otherwise
    /// percent-decode, map full-width dots, NFKC, lowercase, strip one trailing dot, then IPv4 (WHATWG number
    /// forms) when the last label is a number, else IDNA to ASCII.
    static func parseHost(_ raw: String) -> Result<Host, Rejection> {
        let invalidHost = Rejection(kind: .invalid, reason: Reason.host)
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]"), raw.count > 2 else { return .failure(invalidHost) }
            let inner = String(raw.dropFirst().dropLast())
            // Hex groups, colons and an embedded dotted IPv4 only: no zone IDs, which URLs don't allow.
            guard inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }),
                  let bytes = parseIPv6(inner) else { return .failure(invalidHost) }
            return .success(.ipv6(bytes))
        }
        guard !raw.isEmpty, let decoded = raw.removingPercentEncoding else { return .failure(invalidHost) }

        let forbidden = CharacterSet(charactersIn: " #%/:<>?@[\\]^|*\"'`{}")
        var mapped = decoded
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        guard mapped.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0.value > 0x20 && $0.value != 0x7F }),
              !DisplayText.containsHiddenOrBidi(mapped) else { return .failure(invalidHost) }
        if mapped.hasSuffix(".") { mapped.removeLast() }
        guard !mapped.isEmpty else { return .failure(invalidHost) }

        let labels = mapped.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return .failure(invalidHost) }

        if let last = labels.last, endsInNumber(last) {
            guard let address = parseIPv4(labels) else { return .failure(invalidHost) }
            return .success(.ipv4(address))
        }

        var asciiLabels: [String] = []
        var displayLabels: [String] = []
        for label in labels {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                guard label.unicodeScalars.allSatisfy(isHostCharacter) else { return .failure(invalidHost) }
                asciiLabels.append(label)
                if label.hasPrefix("xn--"), let unicode = Punycode.decode(String(label.dropFirst(4))) {
                    displayLabels.append(unicode)
                } else {
                    displayLabels.append(label)
                }
            } else {
                guard let encoded = Punycode.encode(label) else { return .failure(invalidHost) }
                asciiLabels.append("xn--" + encoded)
                displayLabels.append(label)
            }
        }
        guard asciiLabels.allSatisfy({ $0.count <= 63 }) else { return .failure(invalidHost) }
        let ascii = asciiLabels.joined(separator: ".")
        guard ascii.count <= 253 else { return .failure(invalidHost) }
        return .success(.domain(ascii: ascii, display: displayLabels.joined(separator: ".")))
    }

    /// Loopback, private, link-local, CGNAT, multicast and other local ranges; local suffixes; dotless names.
    static func isBlocked(_ host: Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isBlockedIPv4(address)
        case .ipv6(let bytes):
            return isBlockedIPv6(bytes)
        case .domain(let ascii, _):
            if !ascii.contains(".") { return true }
            return blockedSuffixes.contains { ascii == $0 || ascii.hasSuffix("." + $0) }
        }
    }

    static func isBlockedIPv4(_ address: UInt32) -> Bool {
        let ranges: [(base: UInt32, prefix: UInt32)] = [
            (0x0000_0000, 8),   // 0.0.0.0/8 "this network", incl. unspecified
            (0x0A00_0000, 8),   // 10/8
            (0x6440_0000, 10),  // 100.64/10 CGNAT
            (0x7F00_0000, 8),   // 127/8 loopback
            (0xA9FE_0000, 16),  // 169.254/16 link-local
            (0xAC10_0000, 12),  // 172.16/12
            (0xC000_0000, 24),  // 192.0.0/24 IETF protocol assignments
            (0xC0A8_0000, 16),  // 192.168/16
            (0xC612_0000, 15),  // 198.18/15 benchmarking
            (0xE000_0000, 4),   // 224/4 multicast
            (0xF000_0000, 4),   // 240/4 reserved, incl. 255.255.255.255 broadcast
        ]
        return ranges.contains { range in
            let mask: UInt32 = range.prefix == 0 ? 0 : ~UInt32(0) << (32 - range.prefix)
            return address & mask == range.base & mask
        }
    }

    static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        let embeddedIPv4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        let firstTen = bytes[0..<10].allSatisfy { $0 == 0 }
        // :: and ::1, and IPv4-compatible ::a.b.c.d.
        if firstTen, bytes[10] == 0, bytes[11] == 0 {
            return embeddedIPv4 <= 1 || isBlockedIPv4(embeddedIPv4)
        }
        // IPv4-mapped ::ffff:a.b.c.d.
        if firstTen, bytes[10] == 0xFF, bytes[11] == 0xFF { return isBlockedIPv4(embeddedIPv4) }
        // NAT64 64:ff9b::/96.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B, bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isBlockedIPv4(embeddedIPv4)
        }
        // 6to4 2002::/16 carries an IPv4 address in bytes 2–5.
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            let sixToFour = UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5])
            if isBlockedIPv4(sixToFour) { return true }
        }
        if bytes[0] & 0xFE == 0xFC { return true }                     // fc00::/7 unique local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }   // fe80::/10 link-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return true }   // fec0::/10 site-local (deprecated)
        if bytes[0] == 0xFF { return true }                            // ff00::/8 multicast
        return false
    }

    // MARK: - IPv4 (WHATWG URL Standard, "IPv4 parser")

    /// The last label is all digits, or a whole `0x…` hex number: the host must then parse as IPv4.
    static func endsInNumber(_ label: String) -> Bool {
        if !label.isEmpty, label.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        return ipv4Number(label) != nil
    }

    /// 1–4 dotted parts in decimal, `0x` hex or leading-`0` octal; the last part fills the remaining bytes.
    static func parseIPv4(_ labels: [String]) -> UInt32? {
        guard (1...4).contains(labels.count) else { return nil }
        var numbers: [UInt64] = []
        for label in labels {
            guard let number = ipv4Number(label) else { return nil }
            numbers.append(number)
        }
        guard let last = numbers.popLast() else { return nil }
        guard numbers.allSatisfy({ $0 <= 255 }) else { return nil }
        let remainingBytes = 4 - numbers.count
        guard last < (UInt64(1) << (8 * UInt64(remainingBytes))) else { return nil }
        var address = last
        for (index, number) in numbers.enumerated() {
            address += number << (8 * UInt64(3 - index))
        }
        return UInt32(truncatingIfNeeded: address)
    }

    private static func ipv4Number(_ label: String) -> UInt64? {
        guard !label.isEmpty else { return nil }
        var digits = Substring(label)
        var radix = 10
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count > 1, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        if digits.isEmpty { return 0 }
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        // Anything this long is out of range whatever its value; keep it out of range without overflowing.
        if digits.count > 24 { return UInt64.max }
        return UInt64(digits, radix: radix)
    }

    static func dotted(_ address: UInt32) -> String {
        [24, 16, 8, 0].map { String((address >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    // MARK: - IPv6

    static func parseIPv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        let parsed = text.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6String(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            for (index, byte) in bytes.prefix(16).enumerated() { buffer[index] = byte }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &output, socklen_t(output.count)) != nil else { return "" }
        return String(cString: output)
    }

    // MARK: - Helpers

    /// "host", "host:443", "[::1]:8080", "host:" (empty port). nil for a port that isn't 0–65535.
    private static func splitHostAndPort(_ authority: String) -> (String, Int?)? {
        var hostPart = authority
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return (authority, nil) }
            hostPart = String(authority[...close])
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            hostPart = String(authority[..<colon])
            portText = authority[authority.index(after: colon)...]
        }
        guard let portText, !portText.isEmpty else { return (hostPart, nil) }
        guard portText.allSatisfy({ $0.isASCII && $0.isNumber }), portText.count <= 5,
              let port = Int(portText), port <= 65_535 else { return nil }
        return (hostPart, port)
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
            || scalar == "-" || scalar == "_"
    }

    /// Path, query and fragment with every byte outside printable ASCII (and `"<>^`{|}`) percent-encoded;
    /// a `%` that doesn't start an escape becomes `%25`. Empty → "/".
    private static func percentEncodedRest(_ rest: String) -> String {
        guard !rest.isEmpty else { return "/" }
        let unsafe: Set<UInt8> = Set("\"<>^`{|}".utf8)
        let bytes = Array(rest.utf8)
        var output = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                let isEscape = index + 2 < bytes.count
                    && isHexDigit(bytes[index + 1]) && isHexDigit(bytes[index + 2])
                output += isEscape ? "%" : "%25"
            } else if byte <= 0x20 || byte >= 0x7F || unsafe.contains(byte) {
                output += String(format: "%%%02X", byte)
            } else {
                output.append(Character(Unicode.Scalar(byte)))
            }
            index += 1
        }
        if output.hasPrefix("?") || output.hasPrefix("#") { output = "/" + output }
        return output
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    // MARK: - Punycode (RFC 3492)

    enum Punycode {
        private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        private static let initialBias = 72, initialN = 128
        private static let limit = Int(Int32.max)

        static func encode(_ label: String) -> String? {
            let input = label.unicodeScalars.map { Int($0.value) }
            var output = String(label.unicodeScalars.filter(\.isASCII).map(Character.init))
            let basicCount = output.count
            var handled = basicCount
            if basicCount > 0 { output.append("-") }
            var n = initialN, delta = 0, bias = initialBias
            while handled < input.count {
                guard let next = input.filter({ $0 >= n }).min() else { return nil }
                guard (next - n) <= (limit - delta) / (handled + 1) else { return nil }
                delta += (next - n) * (handled + 1)
                n = next
                for code in input {
                    if code < n {
                        delta += 1
                        guard delta < limit else { return nil }
                    }
                    if code == n {
                        var q = delta
                        var k = base
                        while true {
                            let t = threshold(k, bias: bias)
                            if q < t { break }
                            output.append(digit(t + (q - t) % (base - t)))
                            q = (q - t) / (base - t)
                            k += base
                        }
                        output.append(digit(q))
                        bias = adapt(delta, points: handled + 1, first: handled == basicCount)
                        delta = 0
                        handled += 1
                    }
                }
                delta += 1
                n += 1
            }
            return output
        }

        static func decode(_ encoded: String) -> String? {
            let scalars = Array(encoded.unicodeScalars)
            guard scalars.allSatisfy(\.isASCII) else { return nil }
            var output: [Int] = []
            var position = 0
            if let dash = scalars.lastIndex(of: "-") {
                output = scalars[..<dash].map { Int($0.value) }
                position = dash + 1
            }
            var n = initialN, i = 0, bias = initialBias
            while position < scalars.count {
                let oldI = i
                var weight = 1
                var k = base
                while true {
                    guard position < scalars.count, let value = digitValue(scalars[position]) else { return nil }
                    position += 1
                    guard value <= (limit - i) / weight else { return nil }
                    i += value * weight
                    let t = threshold(k, bias: bias)
                    if value < t { break }
                    guard weight <= limit / (base - t) else { return nil }
                    weight *= base - t
                    k += base
                }
                bias = adapt(i - oldI, points: output.count + 1, first: oldI == 0)
                guard i / (output.count + 1) <= limit - n else { return nil }
                n += i / (output.count + 1)
                i %= output.count + 1
                output.insert(n, at: i)
                i += 1
            }
            var text = ""
            for code in output {
                guard let scalar = Unicode.Scalar(UInt32(code)) else { return nil }
                text.unicodeScalars.append(scalar)
            }
            return text
        }

        private static func threshold(_ k: Int, bias: Int) -> Int {
            if k <= bias { return tMin }
            if k >= bias + tMax { return tMax }
            return k - bias
        }

        private static func adapt(_ delta: Int, points: Int, first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }

        private static func digit(_ value: Int) -> Character {
            let scalar = value < 26 ? 0x61 + value : 0x30 + value - 26
            return Character(Unicode.Scalar(UInt8(scalar)))
        }

        private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
            switch scalar.value {
            case 0x30...0x39: return Int(scalar.value) - 0x30 + 26
            case 0x41...0x5A: return Int(scalar.value) - 0x41
            case 0x61...0x7A: return Int(scalar.value) - 0x61
            default: return nil
            }
        }
    }
}
