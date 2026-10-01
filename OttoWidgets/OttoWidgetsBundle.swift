//
//  OttoWidgetsBundle.swift
//  Otto
//
//  The widget extension: the reply's Live Activity (Dynamic Island and Lock Screen), the chat widget for
//  the Home and Lock Screen, and the chat control for Control Center and the Action button.
//

import SwiftUI
import WidgetKit

@main
struct OttoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ReplyLiveActivity()
        OttoChatWidget()
        OttoChatControl()
    }
}
