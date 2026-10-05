//
//  OttoChatWidget.swift
//  Otto
//
//  A widget that only opens Otto with the composer ready: the orb on clay for the Home Screen, and compact
//  forms for the Lock Screen. It shows nothing from your conversations.
//

import SwiftUI
import WidgetKit

struct OttoChatWidget: Widget {
    static let kind = "com.jalenedusei.otto.widget.ask"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: OttoChatTimeline()) { _ in
            OttoChatWidgetView()
                .widgetURL(OttoDeepLink.ask.url)
        }
        .configurationDisplayName("Chat with Otto")
        .description("Opens Otto ready for your question.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// One entry that never changes: the widget is a door, not a feed.
struct OttoChatTimeline: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

struct OttoChatWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkle")
                    .font(.system(size: 22, weight: .medium))
                    .widgetAccentable()
            }
            .containerBackground(for: .widget) { Color.clear }
            .accessibilityLabel("Chat with Otto")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .medium))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Otto")
                        .font(.headline)
                        .widgetAccentable()
                    Text("Ask anything")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            Label("Chat with Otto", systemImage: "sparkle")
                .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(alignment: .leading, spacing: 0) {
                OttoOrb(size: 30, isActive: false)
                Spacer(minLength: 0)
                Text("Otto")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                Text("Ask anything")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                LinearGradient(stops: Theme.slabGradient, startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
