//
//  OttoApp.swift
//  Otto
//
//  The iPhone app's entry point: one window with the chat, the graph behind it (rebuilt when demo mode is
//  switched), links from the widgets, the Live Activity and notifications, and requests from Siri and Shortcuts.
//

import Observation
import SwiftUI

@main
struct OttoApp: App {
    @State private var host = CompositionHost()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(composition: host.composition)
                .id(host.generation)
                .onOpenURL { host.composition.handle($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    host.scenePhaseChanged(phase)
                }
        }
    }
}

/// Owns the graph for the app's lifetime. Tests host the app too, so under XCTest the graph is inert and nothing
/// starts.
@MainActor @Observable final class CompositionHost {
    private(set) var composition: MobileComposition
    /// Bumped when the graph is replaced, so the views are rebuilt on the new one.
    private(set) var generation = 0

    @ObservationIgnored private var demoLoop: ObservationLoop<Bool>?

    init() {
        guard !LaunchOptions.isRunningTests else {
            composition = .inert()
            return
        }
        composition = .live()
        composition.start()
        OttoIntentRouter.shared.handler = { [weak self] request in
            self?.composition.model.handle(request)
        }
        let settings = composition.settings
        demoLoop = ObservationLoop(read: { settings.mobile.demoMode }) { [weak self] _ in
            self?.rebuild()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            composition.sceneBecameActive()
        case .background:
            composition.sceneEnteredBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Demo mode was switched: the old graph saves and stops, and a new one (on the other data folder and client)
    /// takes its place.
    private func rebuild() {
        composition.terminate()
        composition = .live()
        composition.start()
        generation += 1
    }
}
