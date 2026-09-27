//
//  ScriptKnownApps.swift
//  Otto
//
//  Bundle identifiers of the apps scripts most often target, so a script's app chips can show an
//  icon and Automation permissions can name the app without asking macOS which apps are installed.
//

import Foundation

enum ScriptKnownApps {
    /// Lowercased app name → (display name, bundle identifier).
    private static let byName: [String: (name: String, bundleID: String)] = {
        let apps: [(String, String)] = [
            ("Finder", "com.apple.finder"),
            ("System Events", "com.apple.systemevents"),
            ("Music", "com.apple.Music"),
            ("Spotify", "com.spotify.client"),
            ("Safari", "com.apple.Safari"),
            ("Google Chrome", "com.google.Chrome"),
            ("Arc", "company.thebrowser.Browser"),
            ("Mail", "com.apple.mail"),
            ("Messages", "com.apple.MobileSMS"),
            ("Notes", "com.apple.Notes"),
            ("Calendar", "com.apple.iCal"),
            ("Reminders", "com.apple.reminders"),
            ("Contacts", "com.apple.AddressBook"),
            ("Photos", "com.apple.Photos"),
            ("Preview", "com.apple.Preview"),
            ("TextEdit", "com.apple.TextEdit"),
            ("Terminal", "com.apple.Terminal"),
            ("iTerm", "com.googlecode.iterm2"),
            ("iTerm2", "com.googlecode.iterm2"),
            ("Shortcuts", "com.apple.shortcuts"),
            ("System Settings", "com.apple.systempreferences"),
            ("System Preferences", "com.apple.systempreferences"),
            ("Keynote", "com.apple.iWork.Keynote"),
            ("Pages", "com.apple.iWork.Pages"),
            ("Numbers", "com.apple.iWork.Numbers"),
            ("Microsoft Word", "com.microsoft.Word"),
            ("Microsoft Excel", "com.microsoft.Excel"),
            ("Microsoft Outlook", "com.microsoft.Outlook"),
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Xcode", "com.apple.dt.Xcode"),
        ]
        var map: [String: (name: String, bundleID: String)] = [:]
        for (name, bundleID) in apps { map[name.lowercased()] = (name, bundleID) }
        return map
    }()

    /// Lowercased bundle identifier → display name (the first name listed wins).
    private static let byBundleID: [String: String] = {
        var map: [String: String] = [:]
        for entry in byName.values.sorted(by: { $0.name < $1.name }) where map[entry.bundleID.lowercased()] == nil {
            map[entry.bundleID.lowercased()] = entry.name
        }
        map["com.googlecode.iterm2"] = "iTerm"
        map["com.apple.systempreferences"] = "System Settings"
        return map
    }()

    /// The bundle identifier of a well-known app, by its name (case-insensitive).
    static func bundleID(forName name: String) -> String? {
        byName[name.lowercased()]?.bundleID
    }

    /// The display name of a well-known app, by its bundle identifier (case-insensitive).
    static func name(forBundleID bundleID: String) -> String? {
        byBundleID[bundleID.lowercased()]
    }
}
