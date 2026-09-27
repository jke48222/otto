//
//  MediaContracts.swift
//  Otto
//
//  The players Otto can show and control, what is playing, and the transport commands shared by the
//  closed notch, the Now Playing strip, the media keys and the media_control tool.
//

import Foundation

enum MediaPlayer: String, CaseIterable, Codable, Sendable {
    case music = "com.apple.Music", spotify = "com.spotify.client"

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    /// The distributed notification the player posts when its track or playback state changes.
    var notificationName: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }
}

enum PlaybackState: String, Equatable, Codable, Sendable { case playing, paused, stopped }

struct NowPlayingItem: Equatable, Identifiable, Sendable {
    /// "\(player.rawValue)|\(trackID ?? title + "|" + artist)".
    var id: String
    var player: MediaPlayer
    /// ≤ 200 characters, control and bidi characters stripped.
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    /// At `positionDate`.
    var position: TimeInterval?
    var positionDate: Date
    var state: PlaybackState
    /// Spotify only, validated by ArtworkPolicy.
    var artworkURL: URL?

    /// Playback position at `date`: advances with the clock while playing, stays put otherwise; never below 0
    /// or past `duration`. nil when the position is unknown.
    func elapsed(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        var elapsed = position
        if state == .playing { elapsed += date.timeIntervalSince(positionDate) }
        elapsed = max(0, elapsed)
        if let duration, duration > 0 { elapsed = min(elapsed, duration) }
        return elapsed
    }
}

enum MediaCommand: Equatable, Sendable { case play, pause, playPause, next, previous, seek(TimeInterval) }
