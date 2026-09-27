//
//  NotchNeighbors.swift
//  Otto
//
//  Other apps that also live in the notch. When one of them is running, hovering can open both at once, so
//  Otto offers to open on click instead. Detection reads only the running-application list; Otto never
//  quits, scripts or talks to these apps.
//

import AppKit
import Observation
import os

struct NotchNeighbor: Equatable, Hashable, Sendable {
    /// Display name.
    let name: String
    /// Known bundle identifiers.
    let bundleIDs: Set<String>
    /// Lowercase substrings of the app's localized name, the fallback when a bundle ID is unknown or changes.
    let namePatterns: [String]

    /// Apps that only hide the notch (TopNotch) are deliberately left out: they never react to the pointer.
    static let known: [NotchNeighbor] = [
        NotchNeighbor(name: "NotchNook", bundleIDs: ["lo.cafe.NotchNook"], namePatterns: ["notchnook"]),
        NotchNeighbor(name: "boring.notch", bundleIDs: ["theboringteam.boringnotch"],
                      namePatterns: ["boring.notch", "boringnotch"]),
        NotchNeighbor(name: "Alcove", bundleIDs: ["com.henrikruscon.Alcove"], namePatterns: ["alcove"]),
        NotchNeighbor(name: "NotchDrop", bundleIDs: ["com.lakr233.NotchDrop"], namePatterns: ["notchdrop"]),
        NotchNeighbor(name: "MediaMate", bundleIDs: [], namePatterns: ["mediamate"]),
        NotchNeighbor(name: "DynamicLake", bundleIDs: [], namePatterns: ["dynamiclake", "dynamic lake"]),
    ]

    /// Bundle-ID match first (case-insensitive), then the name patterns.
    static func match(bundleID: String?, localizedName: String?) -> NotchNeighbor? {
        if let bundleID = bundleID?.lowercased(), !bundleID.isEmpty,
           let neighbor = known.first(where: { $0.bundleIDs.contains { $0.lowercased() == bundleID } }) {
            return neighbor
        }
        guard let name = localizedName?.lowercased(), !name.isEmpty else { return nil }
        return known.first { neighbor in neighbor.namePatterns.contains { name.contains($0) } }
    }
}

/// Watches app launches and quits for notch neighbors. Observable: the Notch tab's status row reads `running`.
@MainActor @Observable final class NotchNeighborMonitor {
    /// Running neighbors, one entry each, sorted by name.
    private(set) var running: [NotchNeighbor]

    @ObservationIgnored private let onChange: ([NotchNeighbor]) -> Void
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Input")

    /// Seeds from the running applications and calls `onChange` right away when a neighbor is already running;
    /// after that, `onChange` fires whenever a launch or quit changes the list.
    init(onChange: @escaping ([NotchNeighbor]) -> Void) {
        self.onChange = onChange
        running = Self.neighbors(in: Self.runningApplicationIdentities())

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(observer)
        }

        if !running.isEmpty {
            Self.logger.info("Notch neighbors running at launch: \(self.running.count, privacy: .public)")
            onChange(running)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    /// Pure: the neighbors among these apps, deduplicated and sorted by name.
    static func neighbors(in apps: [(bundleID: String?, localizedName: String?)]) -> [NotchNeighbor] {
        let matched = Set(apps.compactMap { NotchNeighbor.match(bundleID: $0.bundleID, localizedName: $0.localizedName) })
        return matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refresh() {
        let current = Self.neighbors(in: Self.runningApplicationIdentities())
        guard current != running else { return }
        running = current
        Self.logger.info("Notch neighbors running: \(current.count, privacy: .public)")
        onChange(current)
    }

    private static func runningApplicationIdentities() -> [(bundleID: String?, localizedName: String?)] {
        NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) }
    }
}
