//
//  OttoWidgetsBundle.swift
//  Otto
//
//  The widget extension: the reply's Live Activity (Dynamic Island and Lock Screen), the Ask Otto widget for
//  the Home and Lock Screen, and the Ask Otto control for Control Center and the Action button.
//

import SwiftUI
import WidgetKit

@main
struct OttoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ReplyLiveActivity()
        AskOttoWidget()
        AskOttoControl()
    }
}
