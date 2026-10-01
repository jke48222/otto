//
//  OttoApp.swift
//  Otto
//
//  The iPhone app's entry point.
//

import SwiftUI

@main
struct OttoApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Theme.panel.ignoresSafeArea()
                OttoOrb(size: 44, isActive: true)
            }
        }
    }
}
