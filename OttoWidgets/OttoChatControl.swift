//
//  OttoChatControl.swift
//  Otto
//
//  A Control Center control (also offered for the Action button and the Lock Screen) that opens Otto ready for
//  a question.
//

import AppIntents
import SwiftUI
import WidgetKit

struct OttoChatControl: ControlWidget {
    static let kind = "com.jalenedusei.otto.control.ask"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ChatWithOttoIntent()) {
                Label("Chat with Otto", systemImage: "sparkle")
            }
        }
        .displayName("Chat with Otto")
        .description("Opens Otto ready for your question.")
    }
}
