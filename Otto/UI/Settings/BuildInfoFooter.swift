//
//  BuildInfoFooter.swift
//  Otto
//
//  The last line of Settings → General in every flavor: the version, the build number and which kind of build
//  this is ("built from source", "signed app", "Setapp"), plus " · demo" in demo mode (§14.10.3).
//

import SwiftUI

struct BuildInfoFooter: View {
    let version: String
    let build: String
    let flavor: OttoBuild.Flavor
    let isDemo: Bool

    init(version: String, build: String, flavor: OttoBuild.Flavor, isDemo: Bool) {
        self.version = version
        self.build = build
        self.flavor = flavor
        self.isDemo = isDemo
    }

    /// "Otto {version} ({build}) · {flavor.footerLabel}", then " · demo" in demo mode. An empty build number
    /// leaves out its parentheses.
    static func text(version: String, build: String, flavor: OttoBuild.Flavor, isDemo: Bool) -> String {
        let trimmedBuild = build.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmedBuild.isEmpty ? "Otto \(version)" : "Otto \(version) (\(trimmedBuild))"
        text += " · \(flavor.footerLabel)"
        if isDemo { text += " · demo" }
        return text
    }

    var body: some View {
        Text(Self.text(version: version, build: build, flavor: flavor, isDemo: isDemo))
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
