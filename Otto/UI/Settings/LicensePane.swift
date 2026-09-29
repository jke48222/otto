//
//  LicensePane.swift
//  Otto
//
//  Settings → License (§14.10.2): the trial or license status, the key field, the licensed Mac's details and
//  actions, the outcome of the last action, and the Terms, Privacy and Refunds links. It reads and acts on a
//  LicenseControlling only, and every word comes from LicenseCopy or the fixed strings below. Its sections go
//  inside the License tab's SettingsPane, above the Updates section. The paid and licensing-check builds
//  compile it; the source build compiles this file to nothing.
//

#if OTTO_LICENSING
import SwiftUI

struct LicensePane: View {
    private let model: LicenseControlling?
    /// True when the pane opens for anchor `.licenseKey`: the key field takes focus as it appears.
    let focusKeyField: Bool
    /// Opens a link from Settings (the Settings window controller's `openExternal(_:)`, §6.3).
    let openExternal: (URL) -> Void

    init(model: LicenseControlling, focusKeyField: Bool, openExternal: @escaping (URL) -> Void) {
        self.model = model
        self.focusKeyField = focusKeyField
        self.openExternal = openExternal
    }

    /// Settings passes `SettingsServices.license` as it is: nil (demo mode) shows only the demo line.
    init(model: LicenseControlling?, focusKeyField: Bool, openExternal: @escaping (URL) -> Void) {
        self.model = model
        self.focusKeyField = focusKeyField
        self.openExternal = openExternal
    }

    // MARK: - Copy

    static let demoLine = "Licenses aren't checked in demo mode."
    static let problemsTitle = "This build can't check licenses:"
    static let problemsFooter = "Set them in Config/Commercial.xcconfig."
    static let sandboxBadge = "Polar sandbox"
    static let keyPlaceholder = "OTTO-… or a Gumroad key"
    static let keyFieldLabel = "License key"
    static let activateTitle = "Activate"
    static let buyTitle = "Buy a License…"
    static let checkNowTitle = "Check Now"
    static let deactivateTitle = "Deactivate This Mac…"
    static let removeTitle = "Remove from This Mac…"
    static let removeAfterFailureTitle = "Remove from This Mac"
    static let portalTitle = "Manage Macs in Polar…"
    static let dismissTitle = "Dismiss"

    /// Terms · Privacy · Refunds, each a page of the site (`LicenseConfiguration.sitePage`).
    static let footerLinks: [(title: String, path: String)] = [
        ("Terms", "terms"), ("Privacy", "privacy"), ("Refunds", "refunds"),
    ]

    enum Badge: Equatable {
        case trial, active, checkNeeded, ended

        var title: String {
            switch self {
            case .trial: return "Trial"
            case .active: return "Active"
            case .checkNeeded: return "Check needed"
            case .ended: return "Ended"
            }
        }
    }

    /// The confirmation before a license leaves this Mac: Deactivate (Polar frees the seat) or Remove (Gumroad
    /// keeps counting the Mac). Either way the confirm button calls `deactivate()`.
    struct Confirmation: Equatable {
        let title: String
        let message: String
        let confirmTitle: String

        static func forBackend(_ backend: LicenseBackendKind, seats: Int, supportEmail: String) -> Confirmation {
            switch backend {
            case .polar:
                return Confirmation(title: "Deactivate Otto on this Mac?",
                                    message: "This frees one of your \(seats) seats. You can enter the key again later.",
                                    confirmTitle: "Deactivate")
            case .gumroad:
                return Confirmation(title: "Remove the license from this Mac?",
                                    message: "Gumroad keeps counting this Mac until I reset it. "
                                        + "Email \(supportEmail) to free the seat.",
                                    confirmTitle: "Remove")
            }
        }
    }

    // MARK: - Rows

    /// One row of the pane, top to bottom (§14.10.2 rows 1–8).
    enum Row: Equatable, Identifiable {
        /// Demo mode: the only row.
        case demo(String)
        /// 1. The problems banner (a misconfigured Debug build) and the "Polar sandbox" badge.
        case configuration(problems: [String], isSandbox: Bool)
        /// 2. Title, detail (nil when the removal line below says it) and the trailing badge.
        case status(title: String, detail: String?, badge: Badge?)
        /// 3. Polar or Gumroad reported a problem once; a second answer a day later turns the license off.
        case pendingRevocation(String)
        /// 4. Why the last license left this Mac.
        case removal(String)
        /// 3 and 5. The key field with Activate, and Buy a License… when this Mac has no license.
        case keyEntry(showsBuy: Bool)
        /// 6. This Mac, Key, Seats.
        case detail(label: String, value: String)
        /// 6. Check Now, Deactivate or Remove, Manage Macs in Polar….
        case licensedActions(backend: LicenseBackendKind, confirmation: Confirmation, showsPortal: Bool)
        /// 7. The last action's outcome; after a failed deactivation it offers Remove from This Mac.
        case message(LicenseMessage, offersRemoval: Bool)
        /// 8. Terms · Privacy · Refunds.
        case footer

        var id: String {
            switch self {
            case .demo: return "demo"
            case .configuration: return "configuration"
            case .status: return "status"
            case .pendingRevocation: return "pendingRevocation"
            case .removal: return "removal"
            case .keyEntry: return "keyEntry"
            case .detail(let label, _): return "detail.\(label)"
            case .licensedActions: return "licensedActions"
            case .message: return "message"
            case .footer: return "footer"
            }
        }
    }

    enum Action: Equatable {
        case activate(String)
        case buy
        case checkNow
        /// The confirmed Deactivate or Remove.
        case deactivate
        /// After a failed deactivation: forget the license on this Mac only.
        case removeFromThisMac
        case openPortal
        case dismissMessage
        case openSitePage(String)
    }

    static func badge(for status: LicenseStatus) -> Badge? {
        switch status {
        case .trial: return .trial
        case .trialEnded: return .ended
        case .licensed: return .active
        case .licensedCheckOverdue, .licensedCheckRequired: return .checkNeeded
        case .unavailable: return nil
        }
    }

    /// "3 Macs" (the backend's seat limit, or the default of 3); "1 Mac".
    static func seatsText(_ seatLimit: Int?) -> String {
        let seats = seatLimit ?? LicensePolicy.seatsPerLicense
        return seats == 1 ? "1 Mac" : "\(seats) Macs"
    }

    /// Activate needs a key and an idle model.
    static func canActivate(key: String, activity: LicenseActivity) -> Bool {
        activity == .idle && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    static func rows(model: LicenseControlling?, now: Date, locale: Locale = .current,
                     calendar: Calendar = .current) -> [Row] {
        guard let model else { return [.demo(demoLine)] }
        let configuration = model.configuration
        let status = model.status
        let summary = status.summary
        var rows: [Row] = []

        let isSandbox = configuration.polar?.isSandbox ?? false
        if !configuration.problems.isEmpty || isSandbox {
            rows.append(.configuration(problems: configuration.problems, isSandbox: isSandbox))
        }

        let removalText = summary == nil ? model.lastRemoval.map(LicenseCopy.removalLine) : nil
        rows.append(statusRow(status: status, removal: model.lastRemoval, configuration: configuration, now: now,
                              locale: locale, calendar: calendar))

        if let summary {
            if let pending = summary.pendingRevocation {
                rows.append(.pendingRevocation(LicenseCopy.pendingRevocationLine(pending, backend: summary.backend,
                                                                                 locale: locale)))
                rows.append(.keyEntry(showsBuy: false))
            }
            rows.append(.detail(label: "This Mac", value: summary.backend == .gumroad ? "Gumroad key" : summary.label))
            rows.append(.detail(label: "Key", value: summary.displayKey))
            rows.append(.detail(label: "Seats", value: seatsText(summary.seatLimit)))
            let seats = summary.seatLimit ?? LicensePolicy.seatsPerLicense
            rows.append(.licensedActions(backend: summary.backend,
                                         confirmation: .forBackend(summary.backend, seats: seats,
                                                                   supportEmail: configuration.supportEmail),
                                         showsPortal: summary.backend == .polar
                                             && configuration.polar?.portalURL != nil))
        } else {
            if let removalText { rows.append(.removal(removalText)) }
            if case .unavailable = status {
                // The records can't be read; Otto works normally and there is nothing to enter a key into.
            } else {
                rows.append(.keyEntry(showsBuy: configuration.buyURL != nil))
            }
        }

        if let message = model.lastMessage {
            let offersRemoval = summary.map { isFailedDeactivation(message, backend: $0.backend,
                                                                   supportEmail: configuration.supportEmail) }
            rows.append(.message(message, offersRemoval: offersRemoval ?? false))
        }

        if footerLinks.contains(where: { configuration.sitePage($0.path) != nil }) {
            rows.append(.footer)
        }
        return rows
    }

    /// Row 2. The detail is left out when it is the removal line, which row 4 shows on its own.
    static func statusRow(status: LicenseStatus, removal: LicenseRemoval?, configuration: LicenseConfiguration,
                          now: Date, locale: Locale = .current, calendar: Calendar = .current) -> Row {
        let removalText = status.summary == nil ? removal.map(LicenseCopy.removalLine) : nil
        let detail = LicenseCopy.statusDetail(status, removal: removal, configuration: configuration, now: now,
                                              locale: locale, calendar: calendar)
        return .status(title: LicenseCopy.statusTitle(status, removal: removal),
                       detail: detail == removalText ? nil : detail,
                       badge: badge(for: status))
    }

    /// Runs one of the pane's buttons against the model.
    @MainActor
    static func perform(_ action: Action, model: LicenseControlling, openExternal: (URL) -> Void) {
        switch action {
        case .activate(let key):
            guard canActivate(key: key, activity: model.activity) else { return }
            model.activate(key: key)
        case .buy:
            if let url = model.configuration.buyURL { openExternal(url) }
        case .checkNow:
            guard model.activity == .idle else { return }
            model.checkNow()
        case .deactivate:
            guard model.activity == .idle else { return }
            model.deactivate()
        case .removeFromThisMac:
            model.removeFromThisMac()
        case .openPortal:
            if let url = model.configuration.polar?.portalURL { openExternal(url) }
        case .dismissMessage:
            model.dismissMessage()
        case .openSitePage(let path):
            if let url = model.configuration.sitePage(path) { openExternal(url) }
        }
    }

    private static func isFailedDeactivation(_ message: LicenseMessage, backend: LicenseBackendKind,
                                             supportEmail: String) -> Bool {
        message == LicenseCopy.deactivation(.unavailable(.offline), backend: backend, supportEmail: supportEmail)
    }

    // MARK: - View

    @State private var keyDraft = ""
    @State private var pendingConfirmation: Confirmation?
    @FocusState private var isKeyFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rows = Self.rows(model: model, now: Date())
        Group {
            if let banner = rows.first(where: { if case .configuration = $0 { return true } else { return false } }) {
                Section { rowView(banner) }
            }
            Section {
                ForEach(rows.filter { Self.isMainRow($0) }) { row in
                    rowView(row)
                }
            }
            if rows.contains(.footer) {
                Section { rowView(.footer) }
            }
        }
    }

    private static func isMainRow(_ row: Row) -> Bool {
        switch row {
        case .configuration, .footer: return false
        default: return true
        }
    }

    /// The pending-revocation line and "Check needed" in the attention amber; on a light Settings window the darker
    /// amber the other panes use for the same meaning (`SettingsTone.warning`), which passes AA as text there.
    private var attentionColor: Color {
        colorScheme == .dark ? Theme.attention : SettingsTone.warning
    }

    private func color(for tone: LicenseMessage.Tone) -> Color {
        switch tone {
        case .success: return SettingsTone.success
        case .info: return .secondary
        case .problem: return attentionColor
        }
    }

    private func badgeColor(_ badge: Badge) -> Color {
        switch badge {
        case .trial, .ended: return .secondary
        case .active: return .green
        case .checkNeeded: return attentionColor
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .demo(let text):
            Text(text)
                .foregroundStyle(.secondary)
        case .configuration(let problems, let isSandbox):
            configurationBanner(problems: problems, isSandbox: isSandbox)
        case .status:
            // Recomputed every minute, so "checked today" turns into "checked yesterday" while Settings is open.
            TimelineView(.everyMinute) { context in
                if let model,
                   case .status(let title, let detail, let badge) = Self.statusRow(
                       status: model.status, removal: model.lastRemoval, configuration: model.configuration,
                       now: context.date) {
                    statusView(title: title, detail: detail, badge: badge)
                }
            }
        case .pendingRevocation(let text):
            Label {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(attentionColor)
        case .removal(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .keyEntry(let showsBuy):
            keyEntry(showsBuy: showsBuy)
        case .detail(let label, let value):
            LabeledContent(label) {
                Text(value)
                    .textSelection(.enabled)
            }
        case .licensedActions(let backend, let confirmation, let showsPortal):
            licensedActions(backend: backend, confirmation: confirmation, showsPortal: showsPortal)
        case .message(let message, let offersRemoval):
            messageRow(message, offersRemoval: offersRemoval)
        case .footer:
            footer
        }
    }

    private func statusView(title: String, detail: String?, badge: Badge?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let badge {
                HStack(spacing: 5) {
                    Circle()
                        .fill(badgeColor(badge))
                        .frame(width: 7, height: 7)
                    Text(badge.title)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func configurationBanner(problems: [String], isSandbox: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(Self.problemsTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text(Self.problemsFooter)
                        .font(.callout)
                }
                .foregroundStyle(attentionColor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(attentionColor.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(attentionColor.opacity(0.45), lineWidth: 1)
                }
            }
            if isSandbox {
                Text(Self.sandboxBadge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    }
            }
        }
    }

    @ViewBuilder private func keyEntry(showsBuy: Bool) -> some View {
        let activity = model?.activity ?? .idle
        VStack(alignment: .leading, spacing: 10) {
            TextField(text: $keyDraft, prompt: Text(Self.keyPlaceholder)) {
                Text(Self.keyFieldLabel)
            }
            .labelsHidden()
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isKeyFieldFocused)
            .disabled(activity != .idle)
            .onSubmit { activate() }
            .accessibilityLabel(Self.keyFieldLabel)
            .onAppear { if focusKeyField { focusKeyFieldSoon() } }
            .onChange(of: focusKeyField) { _, focus in if focus { focusKeyFieldSoon() } }

            HStack(spacing: 10) {
                if activity == .activating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Activating")
                }
                Spacer(minLength: 0)
                if showsBuy {
                    Button(Self.buyTitle) { run(.buy) }
                }
                Button(Self.activateTitle) { activate() }
                    .disabled(!Self.canActivate(key: keyDraft, activity: activity))
            }
        }
        .onChange(of: model?.lastMessage) { _, message in
            // A key that was taken leaves the field; a refused one stays so it can be corrected.
            if message?.tone == .success { keyDraft = "" }
        }
    }

    private func licensedActions(backend: LicenseBackendKind, confirmation: Confirmation,
                                 showsPortal: Bool) -> some View {
        let activity = model?.activity ?? .idle
        return HStack(spacing: 10) {
            Button(Self.checkNowTitle) { run(.checkNow) }
                .disabled(activity != .idle)
            if activity == .checking || activity == .deactivating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(activity == .checking ? "Checking" : "Deactivating")
            }
            Spacer(minLength: 8)
            if showsPortal {
                Button(Self.portalTitle) { run(.openPortal) }
            }
            Button(backend == .polar ? Self.deactivateTitle : Self.removeTitle) {
                pendingConfirmation = confirmation
            }
            .disabled(activity != .idle)
        }
        .alert(pendingConfirmation?.title ?? confirmation.title,
               isPresented: Binding(get: { pendingConfirmation != nil },
                                    set: { if !$0 { pendingConfirmation = nil } }),
               presenting: pendingConfirmation) { shown in
            Button(shown.confirmTitle, role: .destructive) { run(.deactivate) }
            Button("Cancel", role: .cancel) {}
        } message: { shown in
            Text(shown.message)
        }
    }

    private func messageRow(_ message: LicenseMessage, offersRemoval: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message.text)
                .font(.callout)
                .foregroundStyle(color(for: message.tone))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if offersRemoval {
                Button(Self.removeAfterFailureTitle) { run(.removeFromThisMac) }
            }
            Button {
                run(.dismissMessage)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Self.dismissTitle)
            .accessibilityLabel(Self.dismissTitle)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.footerLinks.enumerated()), id: \.offset) { index, link in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button(link.title) { run(.openSitePage(link.path)) }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    // MARK: - Actions

    private func run(_ action: Action) {
        guard let model else { return }
        Self.perform(action, model: model, openExternal: openExternal)
    }

    private func activate() {
        run(.activate(keyDraft))
    }

    /// Focus lands once the field is in a window; asking during the same update is dropped by AppKit.
    private func focusKeyFieldSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            isKeyFieldFocused = true
        }
    }
}
#endif
