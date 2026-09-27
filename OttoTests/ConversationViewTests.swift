//
//  ConversationViewTests.swift
//  Otto
//
//  Where the transcript rests, read off the real AppKit scroll view: the conversation is hosted in an
//  off-screen window and stepped through the panel's reveal (it slides and scales in as it opens).
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class ConversationViewTests: XCTestCase {
    /// Reopening on a finished reply taller than the transcript must land flush with the bottom.
    /// AppKit nudges the scroll offset on every frame of the reveal; left alone, the nudges settled a
    /// few points short of the bottom and the last row sat under the bottom fade.
    func testRevealEndsPinnedToTheBottom() async {
        let host = await TranscriptHost(viewModel: makeViewModel())
        defer { host.close() }
        guard let start = host.scrollPosition else { return XCTFail("no scroll view in the transcript") }
        XCTAssertGreaterThan(start.hiddenAbove, 40, "the transcript must overflow for the test to mean anything")
        XCTAssertEqual(start.hiddenBelow, 0, accuracy: 0.5, "it appears scrolled to the bottom")

        await host.reveal()

        XCTAssertEqual(host.scrollPosition?.hiddenBelow ?? .infinity, 0, accuracy: 0.5)
    }

    /// Someone who scrolled up to read keeps their place when the panel moves.
    func testRevealKeepsAPositionTheUserScrolledTo() async {
        let host = await TranscriptHost(viewModel: makeViewModel())
        defer { host.close() }
        await host.scrollUser(toHiddenBelow: 40)
        await host.reveal()

        XCTAssertEqual(host.scrollPosition?.hiddenBelow ?? 0, 40, accuracy: 6)
    }

    private func makeViewModel() -> NotchViewModel {
        let suiteName = "otto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(defaults: defaults)
        settings.suggestBrowserTab = false
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let reply = (1...8)
            .map { "\($0). A paragraph long enough to wrap onto a second line in the notch, so the reply runs taller than the transcript can show at once." }
            .joined(separator: "\n\n")
        chat.debugSeed(
            messages: [
                ChatMessage(role: .user, text: "What should I fix before Friday?"),
                ChatMessage(role: .assistant, text: reply),
            ],
            isStreaming: false
        )
        return NotchViewModel(settings: settings, chat: chat)
    }
}

/// The conversation under `NotchRevealModifier`, in an off-screen window.
@MainActor
private final class TranscriptHost {
    struct ScrollPosition {
        var hiddenAbove: CGFloat
        var hiddenBelow: CGFloat
    }

    private static let size = CGSize(width: NotchMetrics.openWidth, height: 480)
    private static let transcriptWidth: CGFloat = 508
    private static let maxHeight: CGFloat = 350

    private let viewModel: NotchViewModel
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow

    /// Hosts the transcript at the start of the reveal (progress 0) and lets it settle.
    init(viewModel: NotchViewModel) async {
        self.viewModel = viewModel
        hostingView = NSHostingView(rootView: Self.content(viewModel, progress: 0))
        hostingView.frame = CGRect(origin: .zero, size: Self.size)
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        await settle()
    }

    var scrollPosition: ScrollPosition? {
        guard let scrollView = Self.scrollView(in: hostingView), let document = scrollView.documentView else {
            return nil
        }
        let visible = scrollView.contentView.bounds
        return ScrollPosition(hiddenAbove: visible.minY, hiddenBelow: document.frame.height - visible.maxY)
    }

    /// Steps through the reveal frame by frame, eased like its spring, then lets it settle.
    func reveal(frames: Int = 30) async {
        for frame in 0...frames {
            let t = Double(frame) / Double(frames)
            show(progress: 1 - pow(1 - t, 3))
            await nextFrame()
        }
        await settle()
    }

    /// Scrolls the way a scroll wheel does: AppKit moves the clip view, SwiftUI follows.
    func scrollUser(toHiddenBelow hiddenBelow: CGFloat) async {
        guard let scrollView = Self.scrollView(in: hostingView), let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: document.frame.height - clip.bounds.height - hiddenBelow))
        scrollView.reflectScrolledClipView(clip)
        await settle()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func show(progress: Double) {
        hostingView.rootView = Self.content(viewModel, progress: progress)
        hostingView.layoutSubtreeIfNeeded()
    }

    private func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(16))
    }

    private func settle() async {
        for _ in 0..<12 {
            hostingView.layoutSubtreeIfNeeded()
            await nextFrame()
        }
    }

    private static func content(_ viewModel: NotchViewModel, progress: Double) -> AnyView {
        AnyView(
            ConversationView(viewModel: viewModel, maxHeight: maxHeight, topInset: 10)
                .frame(width: transcriptWidth)
                .modifier(NotchRevealModifier(progress: progress))
                .frame(width: size.width, height: size.height, alignment: .top)
                .environment(\.colorScheme, .dark)
        )
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}
