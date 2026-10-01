//
//  AskOttoControl.swift
//  Otto
//
//  A Control Center control (also offered for the Action button and the Lock Screen) that opens Otto ready for
//  a question.
//

import AppIntents
import SwiftUI
import WidgetKit

struct AskOttoControl: ControlWidget {
    static let kind = "com.jalenedusei.otto.control.ask"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AskOttoIntent()) {
                Label("Ask Otto", systemImage: "sparkle")
            }
        }
        .displayName("Ask Otto")
        .description("Opens Otto ready for your question.")
    }
}
