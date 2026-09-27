//
//  HeaderModelMenu.swift
//  Otto
//
//  The model name beside the wordmark ("Opus 5 ⌄") as a quick menu: model (⌘1–3), response style, web
//  search and Settings. Picking a model goes through the caller, which shows the notice; the running reply
//  keeps the model it started with.
//

import SwiftUI

struct HeaderModelMenu: View {
    @Bindable var settings: AppSettings
    /// "Opus 5 · demo" in demo mode.
    var isDemo: Bool
    /// The view model's `selectModel(_:)`: sets the model and shows "Switched to Sonnet 5".
    let onSelectModel: (ModelOption) -> Void
    let onOpenSettings: () -> Void

    init(settings: AppSettings, isDemo: Bool = LaunchOptions.demo,
         onSelectModel: @escaping (ModelOption) -> Void, onOpenSettings: @escaping () -> Void) {
        _settings = Bindable(settings)
        self.isDemo = isDemo
        self.onSelectModel = onSelectModel
        self.onOpenSettings = onOpenSettings
    }

    /// The hit target is at least this tall.
    static let minHitHeight: CGFloat = 24

    static func label(for model: ModelOption, isDemo: Bool) -> String {
        isDemo ? "\(model.shortName) · demo" : model.shortName
    }

    /// "Opus 5 · Most capable".
    static func itemTitle(for model: ModelOption) -> String {
        "\(model.shortName) · \(model.subtitle)"
    }

    /// ⌘1, ⌘2, ⌘3 in `ModelOption.allCases` order (display only: the notch's key map performs them).
    static func shortcutDigit(for model: ModelOption) -> Character? {
        guard let index = ModelOption.allCases.firstIndex(of: model), index < 9 else { return nil }
        return Character(String(index + 1))
    }

    /// Under the disabled response styles for a model that has none.
    static func effortCaption(for model: ModelOption) -> String? {
        model.supportsEffort ? nil : "\(model.shortName) always answers quickly"
    }

    static func accessibilityLabel(for model: ModelOption) -> String {
        "Model: \(model.shortName). Change model, response style and web search."
    }

    @State private var isHovering = false

    var body: some View {
        Menu {
            Section("Model") {
                ForEach(ModelOption.allCases) { option in
                    modelItem(option)
                }
            }
            Section("Response style") {
                ForEach(EffortLevel.allCases) { level in
                    Toggle(level.displayName, isOn: Binding(
                        get: { settings.effort == level },
                        set: { isOn in if isOn { settings.effort = level } }
                    ))
                }
                .disabled(!settings.model.supportsEffort)
                if let caption = Self.effortCaption(for: settings.model) {
                    Text(caption)
                }
            }
            Toggle("Web search", isOn: $settings.webAccess)
            Divider()
            Button("Settings…", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
        } label: {
            HStack(spacing: 3) {
                Text(Self.label(for: settings.model, isDemo: isDemo))
                    .font(Theme.font(12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(isHovering ? Theme.textSecondary : Theme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(minHeight: Self.minHitHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.06 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help("Model, response style and web search")
        .accessibilityLabel(Self.accessibilityLabel(for: settings.model))
    }

    @ViewBuilder
    private func modelItem(_ option: ModelOption) -> some View {
        let toggle = Toggle(Self.itemTitle(for: option), isOn: Binding(
            get: { settings.model == option },
            set: { isOn in if isOn { onSelectModel(option) } }
        ))
        if let digit = Self.shortcutDigit(for: option) {
            toggle.keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
        } else {
            toggle
        }
    }
}
