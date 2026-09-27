//
//  NotchLayoutTests.swift
//  OttoTests
//
//  The open panel's height budget (NotchLayout, §4.1), the closed notch's size as rendered against the
//  size the window controller hit-tests (ClosedNotchLayout, §4.2), where the dock may show (§4.3), and the
//  small pure rules of the header, the closed-notch clicks and the drop delegate.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class NotchLayoutTests: XCTestCase {
    private static let limits: [CGFloat] = [NotchMetrics.maxOpenHeight, 640, 720, 864, 1_100]

    // MARK: - Conversation height

    func testConversationKeepsThePanelWithinTheLimit() {
        for limit in Self.limits {
            for isTall in [false, true] {
                for chrome in stride(from: CGFloat(0), through: limit - NotchLayout.minimumConversationHeight, by: 7) {
                    let height = NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome, isTall: isTall)
                    XCTAssertLessThanOrEqual(height + chrome, limit + 0.001,
                                             "limit \(limit), chrome \(chrome), tall \(isTall)")
                    XCTAssertGreaterThanOrEqual(height, NotchLayout.minimumConversationHeight)
                }
            }
        }
    }

    func testConversationNeverGoesBelowItsMinimum() {
        for limit in Self.limits {
            for chrome in [limit - 60, limit, limit + 200] {
                XCTAssertEqual(NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome, isTall: false), 110)
                XCTAssertEqual(NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome, isTall: true), 110)
            }
        }
    }

    func testConversationPrefers340OutsideTallMode() {
        XCTAssertEqual(NotchLayout.conversationMaxHeight(openHeightLimit: 560, chrome: 120, isTall: false), 340)
        XCTAssertEqual(NotchLayout.conversationMaxHeight(openHeightLimit: 864, chrome: 120, isTall: false), 340)
        // A tall lower section squeezes it: 560 − 300 = 260.
        XCTAssertEqual(NotchLayout.conversationMaxHeight(openHeightLimit: 560, chrome: 300, isTall: false), 260)
    }

    func testTallModeFillsTheLimit() {
        for limit in Self.limits {
            for chrome in stride(from: CGFloat(80), through: limit - NotchLayout.minimumConversationHeight, by: 23) {
                let height = NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome, isTall: true)
                XCTAssertEqual(height + chrome, limit, accuracy: 0.001, "limit \(limit), chrome \(chrome)")
            }
        }
    }

    /// The view model's limit drives the budget: tall mode uses the tall height, and a system-UI wait
    /// suspends it back to the normal cap.
    func testBudgetFollowsTheViewModelLimit() {
        let viewModel = makeViewModel()
        viewModel.tallOpenHeight = 864
        viewModel.debugSeed(features: NotchDebugSeed(isTallMode: true))
        XCTAssertEqual(viewModel.openHeightLimit, 864)
        let tall = NotchLayout.conversationMaxHeight(openHeightLimit: viewModel.openHeightLimit, chrome: 150,
                                                     isTall: viewModel.isTallMode && viewModel.systemUIWait == nil)
        XCTAssertEqual(tall, 714)

        viewModel.debugSeed(features: NotchDebugSeed(isTallMode: true, systemUIWait: .systemSettings(.accessibility)))
        XCTAssertEqual(viewModel.openHeightLimit, NotchMetrics.maxOpenHeight)
        let suspended = NotchLayout.conversationMaxHeight(openHeightLimit: viewModel.openHeightLimit, chrome: 150,
                                                          isTall: viewModel.isTallMode && viewModel.systemUIWait == nil)
        XCTAssertEqual(suspended, 340)
    }

    func testChatChromeCountsEveryGap() {
        // header 40 + capsule/glance 0 + gap 10 + spacing 12 + bottom 16 + lower 100.
        XCTAssertEqual(NotchLayout.chatChrome(headerHeight: 40, topSectionHeight: 0, lowerSectionHeight: 100,
                                              hasGlanceRow: false), 178)
        // With the glance row (46 with its gap) the gap above the conversation is 12.
        XCTAssertEqual(NotchLayout.chatChrome(headerHeight: 40, topSectionHeight: 46, lowerSectionHeight: 100,
                                              hasGlanceRow: true), 226)
    }

    func testHeaderHeightFollowsTheCameraHousing() {
        XCTAssertEqual(NotchLayout.headerHeight(closedNotchHeight: 32), NotchHeaderView.minimumHeight)
        XCTAssertEqual(NotchLayout.headerHeight(closedNotchHeight: 44), 44)
        XCTAssertEqual(NotchHeaderView.minimumHeight, 40)
    }

    // MARK: - Dock height

    func testDockLeavesTheConversationItsMinimum() {
        for limit in Self.limits {
            for chromeWithoutDock in stride(from: CGFloat(60), through: limit, by: 11) {
                let dock = NotchLayout.dockMaxHeight(openHeightLimit: limit, chromeWithoutDock: chromeWithoutDock)
                XCTAssertGreaterThanOrEqual(dock, 0)
                XCTAssertLessThanOrEqual(dock, NotchLayout.maximumDockHeight)
                if chromeWithoutDock + NotchLayout.minimumConversationHeight <= limit {
                    XCTAssertLessThanOrEqual(chromeWithoutDock + dock + NotchLayout.minimumConversationHeight,
                                             limit + 0.001, "limit \(limit), chrome \(chromeWithoutDock)")
                }
            }
        }
    }

    func testDockAndConversationTogetherStayWithinTheLimit() {
        for limit in Self.limits {
            for isTall in [false, true] {
                for chromeWithoutDock in stride(from: CGFloat(100), through: limit - 110, by: 13) {
                    let dock = NotchLayout.dockMaxHeight(openHeightLimit: limit, chromeWithoutDock: chromeWithoutDock)
                    let chrome = chromeWithoutDock + dock
                    let conversation = NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome,
                                                                         isTall: isTall)
                    XCTAssertLessThanOrEqual(chrome + conversation, limit + 0.001,
                                             "limit \(limit), chrome \(chromeWithoutDock), tall \(isTall)")
                    if isTall {
                        XCTAssertEqual(chrome + conversation, limit, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testDockCapsAt300() {
        XCTAssertEqual(NotchLayout.dockMaxHeight(openHeightLimit: 864, chromeWithoutDock: 150), 300)
        XCTAssertEqual(NotchLayout.dockMaxHeight(openHeightLimit: 560, chromeWithoutDock: 200), 250)
        XCTAssertEqual(NotchLayout.dockMaxHeight(openHeightLimit: 560, chromeWithoutDock: 500), 0)
    }

    // MARK: - Open shape

    func testOpenShapeHeightIsClamped() {
        XCTAssertEqual(NotchLayout.openShapeHeight(contentHeight: 20, closedHeight: 32, openHeightLimit: 560), 32)
        XCTAssertEqual(NotchLayout.openShapeHeight(contentHeight: 300, closedHeight: 32, openHeightLimit: 560), 300)
        XCTAssertEqual(NotchLayout.openShapeHeight(contentHeight: 900, closedHeight: 32, openHeightLimit: 560), 560)
        XCTAssertEqual(NotchLayout.openShapeHeight(contentHeight: 900, closedHeight: 32, openHeightLimit: 864), 864)
    }

    func testPageHeightIsWhatIsLeftUnderTheHeader() {
        XCTAssertEqual(NotchLayout.pageHeight(openHeightLimit: 560, headerHeight: 40, topSectionHeight: 0), 520)
        XCTAssertEqual(NotchLayout.pageHeight(openHeightLimit: 560, headerHeight: 40, topSectionHeight: 36), 484)
        XCTAssertEqual(NotchLayout.pageHeight(openHeightLimit: 30, headerHeight: 40, topSectionHeight: 0), 0)
    }

    func testGlanceRowBucketsOnlyChangeWithTheRowsShape() {
        XCTAssertEqual(NotchLayout.glanceRowHeightBucket(0), 0)
        XCTAssertNotEqual(NotchLayout.glanceRowHeightBucket(NextEventChip.height),
                          NotchLayout.glanceRowHeightBucket(NowPlayingStrip.height))
        XCTAssertEqual(NotchLayout.glanceRowHeightBucket(36), NotchLayout.glanceRowHeightBucket(36.4))
    }

    // MARK: - Closed notch: rendered size = hit-test size

    /// For every form the closed notch takes (plain, hover grow, ears, phase ears, the three drops and the
    /// listening pill) the shape the root renders is exactly `closedLayout.size`, which is what the window
    /// controller hit-tests.
    func testClosedRenderedSizeMatchesTheLayoutForEveryCase() async {
        struct Case {
            let name: String
            let seed: @MainActor (NotchViewModel) -> Void
            let check: (ClosedNotchLayout.Result, ClosedGlance) -> Bool
        }
        let notch = CGSize(width: 190, height: 32)
        let cases: [Case] = [
            Case(name: "nothing", seed: { _ in }, check: { layout, glance in
                layout.size == notch && !glance.hasEars && !layout.showsPill
            }),
            Case(name: "hover", seed: { $0.isHovering = true }, check: { layout, _ in
                layout.size == CGSize(width: notch.width + 8, height: notch.height + 3)
            }),
            Case(name: "unread ears", seed: { vm in
                vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil,
                             hasUnreadReply: true)
            }, check: { layout, glance in
                glance.right == .unreadDot && layout.size.width == notch.width + 68 && glance.drop == nil
            }),
            Case(name: "phase ears and hover", seed: { vm in
                vm.glance.debugSeed(phase: .writing, preview: nil)
                vm.isHovering = true
            }, check: { layout, glance in
                glance.right == .phase(.writing) && layout.size == CGSize(width: notch.width + 76, height: notch.height + 3)
            }),
            Case(name: "reply preview drop", seed: { vm in
                vm.glance.debugSeed(phase: .idle, preview: ReplyPreview(
                    id: UUID(), outcome: .answered,
                    text: "Swift actors isolate their state, so only one task touches it at a time."))
            }, check: { layout, glance in
                glance.drop != nil && layout.size.height == notch.height + ReplyPreviewMetrics.dropHeight
                    && layout.bottomRadius == ClosedNotchLayout.dropBottomRadius
            }),
            Case(name: "short preview drop", seed: { vm in
                vm.glance.debugSeed(phase: .idle, preview: ReplyPreview(id: UUID(), outcome: .failed, text: "Oops"))
            }, check: { layout, glance in
                glance.drop != nil && layout.size.width == notch.width + 68
            }),
            Case(name: "system wait drop", seed: { vm in
                vm.debugSeed(features: NotchDebugSeed(systemUIWait: .systemSettings(.screenRecording)))
            }, check: { layout, glance in
                glance.right == .systemWait && layout.size.height == notch.height + ReplyPreviewMetrics.dropHeight
            }),
            Case(name: "listening pill", seed: { vm in
                vm.voice.debugSeed(phase: .listening, finalized: "Remind me to", volatile: " call Sam",
                                   levels: [0.2, 0.5, 0.3])
            }, check: { layout, _ in
                layout.showsPill && layout.size == CGSize(width: 360, height: notch.height + 26)
            }),
        ]

        for testCase in cases {
            let viewModel = makeViewModel()
            viewModel.closedNotchSize = notch
            viewModel.hasPhysicalNotch = true
            testCase.seed(viewModel)
            let layout = viewModel.closedLayout
            XCTAssertTrue(testCase.check(layout, viewModel.closedGlance), "\(testCase.name): unexpected layout \(layout)")

            let host = RootHost(viewModel: viewModel)
            let rendered = await host.renderedShapeSize(expecting: layout.size)
            host.close()
            XCTAssertEqual(rendered, layout.size, "\(testCase.name): rendered \(rendered) vs hit-test \(layout.size)")
            XCTAssertEqual(viewModel.renderedShapeSize, layout.size, "\(testCase.name)")
        }
    }

    // MARK: - Dock placement

    /// The dock shows its prompt on Chat only; on another page the attention capsule stands in for it.
    func testDockRendersOnlyOnChat() {
        let card = Self.neighborCard
        for route in NotchRoute.allCases {
            let dock = NotchOpenContent.dockPrompt(route: route, currentPrompt: .card(card))
            let capsule = NotchOpenContent.capsulePrompt(route: route, currentPrompt: .card(card))
            if route == .chat {
                XCTAssertEqual(dock, .card(card))
                XCTAssertNil(capsule)
            } else {
                XCTAssertNil(dock, "\(route)")
                XCTAssertEqual(capsule, .card(card), "\(route)")
            }
            XCTAssertNil(NotchOpenContent.dockPrompt(route: route, currentPrompt: nil))
            XCTAssertNil(NotchOpenContent.capsulePrompt(route: route, currentPrompt: nil))
        }
    }

    /// On Chat the rendered panel grows by the dock card (the card really is drawn there).
    func testDockCardAddsToTheRenderedChatPanel() async {
        let plain = makeViewModel()
        plain.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        let plainHost = RootHost(viewModel: plain)
        let plainHeight = await plainHost.settledShapeSize().height
        plainHost.close()

        let withCard = makeViewModel()
        withCard.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        withCard.debugSeed(features: NotchDebugSeed(route: .chat, card: Self.neighborCard))
        let cardHost = RootHost(viewModel: withCard)
        let cardHeight = await cardHost.settledShapeSize().height
        cardHost.close()

        XCTAssertGreaterThan(plainHeight, NotchMetrics.virtualNotchSize.height)
        XCTAssertGreaterThan(cardHeight, plainHeight + 60, "the card sits in the dock above the composer")
        XCTAssertLessThanOrEqual(cardHeight, withCard.openHeightLimit)
    }

    private static let neighborCard = NotchCard(
        kind: .notchNeighbor(name: "Layout Test"),
        symbol: "rectangle.topthird.inset.filled",
        title: "Another notch app is running",
        message: "Both apps react when you hover the notch.",
        footnote: nil,
        primary: NotchCard.ActionButton(title: "Open on Click", action: .useClickToOpen),
        secondary: NotchCard.ActionButton(title: "Keep Hover", action: .keepHover(neighbor: "Layout Test")),
        escapeAction: .keepHover(neighbor: "Layout Test"),
        requiresDecision: false
    )

    /// An inert graph never loads the History index, so an empty open notch shows no dock card.
    func testOpenEmptyShowsNoDockCard() {
        let viewModel = makeViewModel()
        viewModel.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        XCTAssertNil(viewModel.currentPrompt)
    }

    // MARK: - Header

    func testHeaderRightGroupFitsBesideTheCamera() {
        let worstCase = NotchHeaderView.rightGroupWidth(isPinned: true, showsShelf: true, showsHistory: true)
        XCTAssertEqual(worstCase, 142)
        // The ⋮ hit area overhangs the side by 3 pt.
        XCTAssertLessThanOrEqual(worstCase - 3, NotchHeaderView.sideWidth(closedNotchWidth: 190))
        XCTAssertEqual(NotchHeaderView.sideWidth(closedNotchWidth: 190), 149)
    }

    func testShelfPebbleShowsWithItemsOrOnItsPage() {
        XCTAssertFalse(NotchHeaderView.showsShelfPebble(isShelfAvailable: true, itemCount: 0, route: .chat))
        XCTAssertTrue(NotchHeaderView.showsShelfPebble(isShelfAvailable: true, itemCount: 2, route: .chat))
        XCTAssertTrue(NotchHeaderView.showsShelfPebble(isShelfAvailable: true, itemCount: 0, route: .shelf))
        XCTAssertFalse(NotchHeaderView.showsShelfPebble(isShelfAvailable: false, itemCount: 4, route: .chat))
    }

    // MARK: - Closed clicks

    func testClosedClickFollowsTheGlanceTable() {
        let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Done")
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(), isListening: true), .none)
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(left: .orb(active: false), right: .unreadDot,
                                                                     drop: .preview(preview)), isListening: false),
                       .openToReply(preview.id))
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(left: .orb(active: false), right: .speaking),
                                                   isListening: false), .stopSpeakingAndOpen)
        // Speaking while a reply is still in progress just opens.
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(left: .orb(active: true), right: .speaking),
                                                   isListening: false), .open)
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(left: .orb(active: true), right: .approval,
                                                                     drop: .approval(label: "Add event")),
                                                   isListening: false), .open)
        XCTAssertEqual(ClosedNotchView.clickAction(for: ClosedGlance(), isListening: false), .open)
    }

    func testEarRowLeavesRoomForTheDrop() {
        let result = ClosedNotchLayout.Result(size: CGSize(width: 300, height: 60), bottomRadius: 16, showsPill: false)
        XCTAssertEqual(ClosedNotchView.earRowHeight(layout: result, hasDrop: true), 60 - ReplyPreviewMetrics.dropHeight)
        XCTAssertEqual(ClosedNotchView.earRowHeight(layout: result, hasDrop: false), 60)
        XCTAssertEqual(ClosedNotchView.earGap(notchWidth: 190, isHovering: true), 198)
    }

    // MARK: - Drop delegate

    func testDropSessionSplitsTheShapeOnlyWhenTheShelfCanTakeTheItems() {
        let left = NotchDropDelegate.session(x: 100, width: 580, itemCount: 2, hasShelfItems: true, shelfEnabled: true)
        XCTAssertEqual(left, DropSession(zone: .shelf, itemCount: 2, acceptsShelf: true))
        let right = NotchDropDelegate.session(x: 400, width: 580, itemCount: 2, hasShelfItems: true, shelfEnabled: true)
        XCTAssertEqual(right.zone, .ask)
        let text = NotchDropDelegate.session(x: 100, width: 580, itemCount: 1, hasShelfItems: false, shelfEnabled: true)
        XCTAssertEqual(text, DropSession(zone: .ask, itemCount: 1, acceptsShelf: false))
        let shelfOff = NotchDropDelegate.session(x: 100, width: 580, itemCount: 1, hasShelfItems: true, shelfEnabled: false)
        XCTAssertEqual(shelfOff.zone, .ask)
        XCTAssertFalse(shelfOff.acceptsShelf)
    }

    // MARK: - Helpers

    private func makeViewModel() -> NotchViewModel {
        let suiteName = "otto.tests.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        settings.suggestBrowserTab = false
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        return NotchViewModel(settings: settings, chat: chat)
    }
}

/// The real root view in an off-screen window, with animations off so geometry is final at once.
@MainActor
private final class RootHost {
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private let viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        let size = NotchMetrics.windowSize
        hostingView = NSHostingView(rootView: AnyView(
            NotchRootView(viewModel: viewModel)
                .frame(width: size.width, height: size.height)
                .transaction { $0.disablesAnimations = true }
        ))
        hostingView.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
    }

    /// Lets SwiftUI lay out and report the shape, waiting up to a second for `expected`.
    func renderedShapeSize(expecting expected: CGSize) async -> CGSize {
        for _ in 0..<50 {
            hostingView.layoutSubtreeIfNeeded()
            if viewModel.renderedShapeSize == expected { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return viewModel.renderedShapeSize
    }

    /// The shape once SwiftUI has laid out, measured and settled (geometry round-trips included).
    func settledShapeSize() async -> CGSize {
        try? await Task.sleep(for: .milliseconds(400))
        hostingView.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        return viewModel.renderedShapeSize
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
