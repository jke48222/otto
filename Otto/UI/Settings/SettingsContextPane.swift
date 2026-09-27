//
//  SettingsContextPane.swift
//  Otto
//
//  Settings → Context: what Otto offers from the browser and the app you came from, the Accessibility and
//  Screen Recording permissions behind that, the Services menu entry, and the File Shelf.
//

import SwiftUI

struct SettingsContextPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var isWaitingForAccessibility = false
    @State private var confirmsClearShelf = false

    var body: some View {
        SettingsPane(tab: .context, settings: settings) {
            browserSection
            selectionSection
            shelfSection
        }
    }

    // MARK: Browser

    private var browserSection: some View {
        Section("Browser") {
            Toggle(isOn: $settings.suggestBrowserTab) {
                labeled("Suggest current browser tab", "Offers the page you're viewing as a chip.")
            }
            Toggle(isOn: $settings.autoAttachBrowserTab) {
                labeled("Attach tab automatically", "Adds the page right away instead of suggesting it.")
            }
            .disabled(!settings.suggestBrowserTab)
        }
    }

    // MARK: Selection & apps

    private var selectionSection: some View {
        Section("Selection & Apps") {
            FeatureToggleRow(
                title: "Offer selected text",
                detail: "Offers the text you selected in the app you came from as a chip.",
                isOn: offerSelection,
                permissions: SettingsFeatureToggle.offerSelection.displayedPermissions
            )
            if isWaitingForAccessibility {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    SettingsCaption("Waiting for Accessibility…")
                    Spacer(minLength: 8)
                    if let url = Permission.accessibility.settingsURL {
                        Button("Open System Settings") { openExternal(url) }
                    }
                }
            }
            FeatureToggleRow(
                title: "Offer the window you're using",
                detail: "Shows a “Window” chip for the app you came from. Otto reads nothing until you tap it.",
                isOn: Bindable(settings.context).offerWindow,
                permissions: SettingsFeatureToggle.offerWindow.displayedPermissions
            )
            Toggle(isOn: Bindable(settings.context).restoreClipboard) {
                labeled("Put my clipboard back after pasting",
                        "After Otto pastes an answer into your app, the clipboard gets its old contents back.")
            }
            PermissionRow(permission: .accessibility)
            PermissionRow(permission: .screenRecording)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                labeled("Services", "Ask Otto from any app: select text or files, then choose Services → Ask Otto.")
                Spacer(minLength: 8)
                if let url = SettingsLinks.keyboardSettings {
                    Button("Keyboard Shortcuts…") { openExternal(url) }
                }
            }
        }
    }

    private var offerSelection: Binding<Bool> {
        Binding(
            get: { settings.context.offerSelection },
            set: { isOn in
                SettingsFeatureToggle.offerSelection.store(isOn, in: settings)
                guard isOn else {
                    isWaitingForAccessibility = false
                    return
                }
                let permissions = services.permissions
                Task { @MainActor in
                    let results = await SettingsFeatureToggle.offerSelection.set(true, settings: settings,
                                                                                permissions: permissions)
                    guard results[.accessibility] != .granted else { return }
                    // Accessibility is switched on in System Settings, never in a dialog Otto can wait on.
                    isWaitingForAccessibility = true
                    _ = await permissions.waitForGrant(.accessibility, timeout: .seconds(180))
                    isWaitingForAccessibility = false
                }
            }
        )
    }

    // MARK: Shelf

    private var shelfSection: some View {
        Section("Shelf") {
            Toggle(isOn: Bindable(settings.shelf).enabled) {
                labeled("Shelf drop zone", "Drop files on the notch to keep them on the Shelf, ready to attach.")
            }
            Toggle(isOn: Bindable(settings.shelf).keepAfterDragOut) {
                labeled("Keep items after dragging them out",
                        "Otherwise a file leaves the Shelf when you drag it into another app.")
            }
            if let shelf = services.shelf {
                let count = shelf.store.count
                Button(count == 1 ? "Clear Shelf (1 item)…" : "Clear Shelf (\(count) items)…") {
                    confirmsClearShelf = true
                }
                .disabled(count == 0)
                .alert("Clear the Shelf?", isPresented: $confirmsClearShelf) {
                    Button("Clear", role: .destructive) { shelf.store.removeAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes \(count == 1 ? "1 item" : "\(count) items") from the Shelf. "
                         + "The original files stay where they are.")
                }
            }
        }
    }
}
