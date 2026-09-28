//
//  UpdatesSection.swift
//  Otto
//
//  The Updates section of Settings (§14.11.3): in the paid build it sits on the License tab and drives Sparkle
//  (two toggles, Check Now, an update that is ready); in the Setapp build it sits on the General tab and only
//  reflects Setapp's own updater. It reads and acts on an UpdaterControlling and nothing else. The source build
//  compiles this file to nothing.
//

#if OTTO_SPARKLE || OTTO_SETAPP
import SwiftUI

struct UpdatesSection: View {
    let updater: UpdaterControlling
    /// The site the appcast comes from, named in the Sparkle caption; nil when it isn't known.
    let siteHost: String?
    /// Opens a link from Settings (the Settings window controller's `openExternal(_:)`, §6.3).
    let openExternal: (URL) -> Void

    init(updater: UpdaterControlling, siteHost: String?, openExternal: @escaping (URL) -> Void) {
        self.updater = updater
        self.siteHost = siteHost
        self.openExternal = openExternal
    }

    // MARK: - Rows

    /// One row of the section, in the order it is drawn.
    enum Row: Equatable, Identifiable {
        /// Sparkle: "Check for updates automatically" with its caption.
        case automaticChecks(title: String, caption: String)
        /// Sparkle: "Download and install updates automatically", disabled while checks are off.
        case automaticDownloads(title: String, caption: String, isEnabled: Bool)
        /// Sparkle: Check Now with "Last checked {relative}" or "Not checked yet".
        case checkNow(title: String, status: String, isEnabled: Bool)
        /// Setapp: who keeps Otto current.
        case setappNote(String)
        /// An update that is ready, with the button that installs it.
        case pending(text: String, buttonTitle: String)
        /// Setapp: "What's New…".
        case releaseNotes(title: String)

        var id: String {
            switch self {
            case .automaticChecks: return "automaticChecks"
            case .automaticDownloads: return "automaticDownloads"
            case .checkNow: return "checkNow"
            case .setappNote: return "setappNote"
            case .pending: return "pending"
            case .releaseNotes: return "releaseNotes"
            }
        }
    }

    enum Action: Equatable {
        case checkNow, install, releaseNotes
    }

    static let automaticChecksTitle = "Check for updates automatically"
    static let automaticDownloadsTitle = "Download and install updates automatically"
    static let automaticDownloadsCaption = "Updates install when Otto quits. You can install sooner here."
    static let checkNowTitle = "Check Now"
    static let setappNote = "Setapp keeps Otto up to date."
    static let releaseNotesTitle = "What's New…"

    /// "Once a day Otto asks {siteHost} for the release list. …"
    static func automaticChecksCaption(siteHost: String?) -> String {
        let host = siteHost.flatMap { $0.isEmpty ? nil : $0 } ?? "its website"
        return "Once a day Otto asks \(host) for the release list. The request carries Otto's version number "
            + "and nothing that identifies you or your Mac."
    }

    /// "Last checked today", "Last checked yesterday", "Last checked Oct 11", or "Not checked yet".
    static func lastCheckedText(_ lastCheck: Date?, now: Date, locale: Locale = .current,
                                calendar: Calendar = .current) -> String {
        guard let lastCheck else { return "Not checked yet" }
        if calendar.isDate(lastCheck, inSameDayAs: now) { return "Last checked today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(lastCheck, inSameDayAs: yesterday) {
            return "Last checked yesterday"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.abbreviated).day()
        return "Last checked \(lastCheck.formatted(style))"
    }

    @MainActor
    static func rows(updater: UpdaterControlling, siteHost: String?, now: Date, locale: Locale = .current,
                     calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        switch updater.source {
        case .sparkle:
            if updater.allowsUserSettings {
                rows.append(.automaticChecks(title: automaticChecksTitle,
                                             caption: automaticChecksCaption(siteHost: siteHost)))
                rows.append(.automaticDownloads(title: automaticDownloadsTitle, caption: automaticDownloadsCaption,
                                                isEnabled: updater.automaticallyChecks))
            }
            rows.append(.checkNow(title: checkNowTitle,
                                  status: lastCheckedText(updater.lastCheck, now: now, locale: locale,
                                                          calendar: calendar),
                                  isEnabled: updater.canCheckNow))
            if let pending = updater.pendingUpdate {
                rows.append(.pending(text: "Otto \(pending.version) is ready.", buttonTitle: "Install and Relaunch…"))
            }
        case .setapp:
            rows.append(.setappNote(setappNote))
            if let pending = updater.pendingUpdate {
                rows.append(.pending(text: "Setapp has Otto \(pending.version) ready.",
                                     buttonTitle: "Update and Relaunch…"))
            }
        }
        if updater.canShowReleaseNotes {
            rows.append(.releaseNotes(title: releaseNotesTitle))
        }
        return rows
    }

    @MainActor
    static func perform(_ action: Action, on updater: UpdaterControlling) {
        switch action {
        case .checkNow: updater.checkNow()
        case .install: updater.installPendingUpdate()
        case .releaseNotes: updater.showReleaseNotes()
        }
    }

    // MARK: - View

    var body: some View {
        Section {
            ForEach(Self.rows(updater: updater, siteHost: siteHost, now: Date())) { row in
                rowView(row)
            }
        } header: {
            Text("Updates")
        }
        .id(SettingsAnchor.updates.rawValue)
        .environment(\.openURL, OpenURLAction { url in
            openExternal(url)
            return .handled
        })
        .onAppear {
            // Setapp's pending-update state is local; reading it when the section shows is how Settings stays
            // current (§14.11.2). Sparkle checks only on its schedule or when asked.
            if updater.source == .setapp { updater.checkNow() }
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .automaticChecks(let title, let caption):
            Toggle(isOn: Binding(get: { updater.automaticallyChecks },
                                 set: { updater.automaticallyChecks = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(captionWithSiteLink(caption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .automaticDownloads(let title, let caption, let isEnabled):
            Toggle(isOn: Binding(get: { updater.automaticallyDownloads },
                                 set: { updater.automaticallyDownloads = $0 })) {
                labeled(title, caption)
            }
            .disabled(!isEnabled)
        case .checkNow(let title, _, let isEnabled):
            HStack(spacing: 10) {
                // Recomputed every minute, so "today" turns into "yesterday" while the window stays open.
                TimelineView(.everyMinute) { context in
                    Text(Self.lastCheckedText(updater.lastCheck, now: context.date))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(title) { Self.perform(.checkNow, on: updater) }
                    .disabled(!isEnabled)
            }
        case .setappNote(let text):
            Text(text)
        case .pending(let text, let buttonTitle):
            HStack(spacing: 10) {
                Label(text, systemImage: "arrow.down.circle")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(buttonTitle) { Self.perform(.install, on: updater) }
            }
        case .releaseNotes(let title):
            HStack {
                Spacer(minLength: 0)
                Button(title) { Self.perform(.releaseNotes, on: updater) }
            }
        }
    }

    /// The caption with the site host as a link to the site's home page (opened through `openExternal`).
    private func captionWithSiteLink(_ caption: String) -> AttributedString {
        var text = AttributedString(caption)
        guard let siteHost, !siteHost.isEmpty,
              let url = URL(string: "https://\(siteHost)"),
              let range = text.range(of: siteHost) else {
            return text
        }
        text[range].link = url
        return text
    }
}
#endif
