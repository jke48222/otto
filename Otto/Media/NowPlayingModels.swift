//
//  NowPlayingModels.swift
//  Otto
//
//  Turns the distributed notifications Music and Spotify post into display-safe NowPlayingItems, decides
//  which Spotify artwork addresses Otto may load, and shrinks artwork to the size the notch draws it.
//

import AppKit
import Foundation
import ImageIO

extension MediaPlayer {
    /// The player a media_control `app` value names ("Music", "Spotify"); nil for anything else.
    init?(displayName: String) {
        guard let player = MediaPlayer.allCases.first(where: { $0.displayName == displayName }) else { return nil }
        self = player
    }
}

extension PlaybackState {
    /// Maps a player's own state word: notification payloads say "Playing", scripts say "playing" or, in Music,
    /// "fast forwarding" / "rewinding" (still audible, so playing). nil for anything unrecognized.
    init?(playerWord: String) {
        switch playerWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing", "fast forwarding", "rewinding": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: return nil
        }
    }
}

extension NowPlayingItem {
    /// Longest title, artist, album or track identifier Otto keeps.
    static let maxTextLength = 200
    /// Durations and positions beyond this (a week) are treated as garbage.
    static let maxPlausibleSeconds: TimeInterval = 7 * 86_400

    /// "\(player.rawValue)|\(trackID ?? title + "|" + artist)".
    static func makeID(player: MediaPlayer, trackID: String?, title: String, artist: String) -> String {
        "\(player.rawValue)|\(trackID ?? title + "|" + artist)"
    }

    /// The playback state a notification payload reports ("Player State"), or nil when it's missing or unknown.
    static func playbackState(in userInfo: [AnyHashable: Any]) -> PlaybackState? {
        guard let word = userInfo["Player State"] as? String else { return nil }
        return PlaybackState(playerWord: word)
    }

    /// Parses a player's distributed-notification userInfo. Any process can post these, so every string is
    /// sanitized and capped and nothing is read as an address. Music reports "Total Time" in milliseconds and no
    /// position; Spotify reports "Duration" in milliseconds and "Playback Position" in seconds. nil when the
    /// player stopped or the payload is unusable (no state, or no title).
    static func parse(player: MediaPlayer, userInfo: [AnyHashable: Any], now: Date) -> NowPlayingItem? {
        guard let state = playbackState(in: userInfo), state != .stopped else { return nil }
        let title = text(userInfo["Name"])
        guard !title.isEmpty else { return nil }
        let artist = text(userInfo["Artist"])
        let album = text(userInfo["Album"])

        let duration: TimeInterval?
        let position: TimeInterval?
        let rawTrackID: Any?
        switch player {
        case .music:
            duration = seconds(fromMilliseconds: userInfo["Total Time"])
            position = nil
            rawTrackID = userInfo["PersistentID"]
        case .spotify:
            duration = seconds(fromMilliseconds: userInfo["Duration"])
            position = plausibleSeconds(number(userInfo["Playback Position"]))
            rawTrackID = userInfo["Track ID"]
        }
        let trackID = identifier(rawTrackID)
        var clampedPosition = position
        if let known = position, let duration { clampedPosition = min(known, duration) }

        return NowPlayingItem(
            id: makeID(player: player, trackID: trackID, title: title, artist: artist),
            player: player,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: clampedPosition,
            positionDate: now,
            state: state,
            artworkURL: nil
        )
    }

    /// Display text from an untrusted value: strings only, control, bidi and zero-width characters removed,
    /// whitespace collapsed, at most `maxTextLength` characters.
    static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return DisplayText.sanitized(string, maxLength: maxTextLength)
    }

    /// A finite, non-negative number of seconds no longer than `maxPlausibleSeconds`; nil otherwise.
    static func plausibleSeconds(_ value: Double?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0, value <= maxPlausibleSeconds else { return nil }
        return value
    }

    // MARK: - Private

    private static func seconds(fromMilliseconds value: Any?) -> TimeInterval? {
        guard let milliseconds = number(value), milliseconds > 0 else { return nil }
        return plausibleSeconds(milliseconds / 1_000)
    }

    /// NSNumber (the usual case) or a numeric string; booleans are not numbers here.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    /// Music's PersistentID arrives as a signed 64-bit number and is written the way Music's scripting dictionary
    /// writes `persistent ID` (16 uppercase hex digits), so notifications and resyncs agree on the id. Spotify's
    /// Track ID is already the "spotify:track:…" string its dictionary uses.
    private static func identifier(_ value: Any?) -> String? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return String(format: "%016llX", UInt64(bitPattern: number.int64Value))
        case let string as String:
            let clean = DisplayText.sanitized(string, maxLength: maxTextLength)
            return clean.isEmpty ? nil : clean
        default:
            return nil
        }
    }
}

/// Which artwork addresses Otto may load, and which responses it accepts. The address comes from Spotify's own
/// scripting dictionary (never from a notification payload); this is the second line of defence.
enum ArtworkPolicy {
    /// Largest artwork response Otto reads.
    static let maxBytes = 2 * 1024 * 1024
    /// Longest side, in pixels, of the artwork Otto keeps (26 pt strip artwork on a 2x display, with margin).
    static let maxPixelSize = 64

    /// https only; host i.scdn.co, *.scdn.co or *.spotifycdn.com written in plain lowercase letters, digits,
    /// dots and hyphens; no user name or password, no port other than 443, no fragment.
    static func isAllowedSpotifyArtworkURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let host = components.percentEncodedHost?.lowercased(), !host.isEmpty
        else { return false }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy(allowedCharacters.contains),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..")
        else { return false }

        if host == "i.scdn.co" { return true }
        for suffix in [".scdn.co", ".spotifycdn.com"] where host.hasSuffix(suffix) {
            let label = host.dropLast(suffix.count)
            if !label.isEmpty, !label.hasSuffix("-") { return true }
        }
        return false
    }

    /// A 2xx HTTP response of an `image/*` type, from an allowed address (after any redirect), whose declared
    /// and actual sizes stay within `maxBytes`.
    static func accepts(_ response: URLResponse, byteCount: Int) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let mimeType = http.mimeType?.lowercased(), mimeType.hasPrefix("image/"),
              let finalURL = http.url, isAllowedSpotifyArtworkURL(finalURL),
              byteCount > 0, byteCount <= maxBytes,
              http.expectedContentLength <= Int64(maxBytes)
        else { return false }
        return true
    }

    /// Decodes image data with ImageIO and shrinks it to `maxPixelSize` on its longest side (never enlarges).
    /// Call off the main actor. nil when the data isn't an image.
    static func thumbnail(from data: Data, maxPixelSize: Int = ArtworkPolicy.maxPixelSize) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
