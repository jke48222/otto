//
//  OttoBuild.swift
//  Otto
//
//  Which flavor of Otto this binary is (built from source, the signed paid app, or the Setapp build), chosen at
//  compile time by the flavor project's compilation conditions, plus the build-time invariants between them.
//

import Foundation

enum OttoBuild {
    enum Flavor: String, Sendable {
        case source, paid, setapp

        /// Settings → General footer suffix: "built from source", "signed app", "Setapp".
        var footerLabel: String {
            switch self {
            case .source: return "built from source"
            case .paid: return "signed app"
            case .setapp: return "Setapp"
            }
        }
    }

    #if OTTO_SETAPP
    static let flavor: Flavor = .setapp
    #elseif OTTO_LICENSING
    static let flavor: Flavor = .paid
    #else
    static let flavor: Flavor = .source
    #endif

    /// Every Otto flavor's bundle id. The launch guard (§3.5) treats a running process with any of them as
    /// "another Otto" (§14.19, AppDelegate), so only one Otto of any flavor runs at a time.
    static let allBundleIDs: Set<String> = ["com.jalenedusei.otto", "com.jalenedusei.otto-setapp"]
}

#if OTTO_SETAPP && (OTTO_LICENSING || OTTO_SPARKLE)
#error("The Setapp build carries no licensing or updater of Otto's own (Setapp review guidelines 2.7 and 2.10). Build it from project-setapp.yml only.")
#endif
#if OTTO_SPARKLE && !OTTO_LICENSING
#error("Sparkle ships only in the paid build, which also carries licensing. Build it from project-paid.yml.")
#endif
