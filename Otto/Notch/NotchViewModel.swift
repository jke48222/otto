//
//  NotchViewModel.swift
//  Otto
//
//  State of the notch panel: presentation, composer, context chips and the browser-tab suggestion.
//  The window controller drives pointer/keyboard behaviour through the hooks at the bottom of the
//  property list; the SwiftUI views read and bind everything else.
//

import AppKit
import Observation
import UniformTypeIdentifiers
import os

@MainActor @Observable final class NotchViewModel {
    enum Presentation: Equatable { case closed, open }
    enum OpenReason: Equatable { case hover, click, hotkey, drag, programmatic }

    static let maxAttachments = 10
    static let attachmentLimitMessage = "You can attach up to \(maxAttachments) items."

    let settings: AppSettings
    let chat: ChatSession

    private(set) var presentation: Presentation = .closed
    private(set) var openReason: OpenReason?
    var isOpen: Bool { presentation == .open }

    /// The panel is key and the user is interacting with the keyboard — hover-exit must not close it.
    var isEngaged = false
    /// Pointer is over the closed notch (window controller sets it) — UI shows a subtle grow.
    var isHovering = false
    var composerText = ""
    private(set) var attachments: [Attachment] = []
    /// Ghost chip for the current browser tab.
    private(set) var suggestedTab: Attachment?
    var isDropTargeted = false
    private(set) var pendingAttachmentLoads = 0

    /// Short user-facing error under the composer; clears itself after `transientErrorLifetime`.
    var transientError: String? {
        didSet { scheduleTransientErrorClear() }
    }

    /// Increments whenever the composer should take keyboard focus.
    private(set) var focusRequest = 0
    var hasUnreadReply = false

    /// A +/⋮ menu is open — do not auto-close. Also reads true while the file picker, a screen
    /// capture or the system's Automation consent dialog is up, even if a menu's disappearance resets
    /// the flag in the meantime (the window controller reads only this flag to hold the notch open).
    var isMenuPresented: Bool {
        get { menuFlag || isPickingFiles || isCapturingScreen || isAwaitingAutomationConsent }
        set { menuFlag = newValue }
    }

    /// Hardware (or virtual) notch size; set by the window controller.
    var closedNotchSize: CGSize = NotchMetrics.virtualNotchSize
    var hasPhysicalNotch = false
    /// Size of the shape as currently rendered (the UI reports it; the controller hit-tests with it).
    var renderedShapeSize: CGSize = NotchMetrics.virtualNotchSize

    var canSend: Bool {
        guard !chat.isStreaming, pendingAttachmentLoads == 0 else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var shouldStayOpen: Bool {
        isEngaged || isMenuPresented || isDropTargeted || pendingAttachmentLoads > 0
    }

    /// The closed notch grows "ears" while a reply streams or an unread reply waits.
    var showsClosedActivity: Bool { chat.isStreaming || hasUnreadReply }

    // MARK: Window-controller hooks

    @ObservationIgnored var onPresentationChange: ((Presentation) -> Void)?
    /// true: make the panel key (focus); false: give focus back to the user's app.
    @ObservationIgnored var onRequestKey: ((Bool) -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// The controller hides the panel while the user picks a screen region.
    @ObservationIgnored var onBeginScreenCapture: (() -> Void)?
    @ObservationIgnored var onEndScreenCapture: (() -> Void)?

    // MARK: Private state

    private var menuFlag = false
    private var isPickingFiles = false
    private var isCapturingScreen = false
    /// A prompt-allowed tab lookup is about to show (or is showing) the Automation consent dialog.
    /// Clicking it must not close or disengage the notch.
    private var isAwaitingAutomationConsent = false

    /// How long `transientError` stays visible. Internal so tests can shorten it.
    @ObservationIgnored var transientErrorLifetime: Duration = .seconds(4)
    @ObservationIgnored private var transientErrorTask: Task<Void, Never>?

    /// File URLs currently loading, so the same file dropped twice is loaded once.
    @ObservationIgnored private var loadingFileURLs: Set<URL> = []

    /// The last app other than Otto that was frontmost (the one the user is working in).
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NotificationObservation?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    /// Bumped on every suggestion refresh and on close; a lookup only lands if it still matches.
    @ObservationIgnored private var suggestionGeneration = 0
    /// A tab the user dismissed (or removed) is not suggested again until they move to another page.
    @ObservationIgnored private var dismissedTabURL: URL?
    /// The app that was active before Otto activated itself for the file picker; it gets focus
    /// back when the notch closes.
    @ObservationIgnored private var appToReactivate: NSRunningApplication?
    /// The open file picker, so asking for it again brings it back instead of doing nothing.
    @ObservationIgnored private weak var filePanel: NSOpenPanel?
    /// The chip `autoAttachBrowserTab` added for the current tab. It stands for "the page I'm on
    /// now", so it is replaced on the next lookup and removed when the notch closes; once sent (or
    /// removed by the user) it is no longer tracked.
    @ObservationIgnored private var autoAttachedTabID: UUID?
    /// Whether the latest tab lookup was allowed to ask for Automation permission.
    @ObservationIgnored private var lastLookupAllowedPrompt = false

    /// One level above the notch panel (`NotchPanel.auxiliaryWindowLevel`), so the open notch never
    /// covers the picker, and so it stays visible (and reachable) when another app is activated while
    /// it is up — Otto is an accessory app, so ⌘Tab can't bring it back.
    static let filePickerLevel = NotchPanel.auxiliaryWindowLevel

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Notch")

    init(settings: AppSettings, chat: ChatSession) {
        self.settings = settings
        self.chat = chat

        chat.onReplyFinished = { [weak self] in
            guard let self, !self.isOpen else { return }
            self.hasUnreadReply = true
        }
        startTrackingFrontmostApp()
    }

    // MARK: - Presentation

    func open(reason: OpenReason, focus: Bool) {
        let wasOpen = isOpen
        presentation = .open
        openReason = reason
        hasUnreadReply = false
        if !wasOpen {
            onPresentationChange?(.open)
        }

        refreshSuggestedTab(allowPrompt: reason == .click || reason == .hotkey)

        if focus {
            isEngaged = true
            onRequestKey?(true)
            focusRequest += 1
        }
    }

    func close() {
        let wasOpen = isOpen
        presentation = .closed
        openReason = nil
        isEngaged = false
        isMenuPresented = false
        isAwaitingAutomationConsent = false
        suggestedTab = nil
        removeAutoAttachedTab(keepingDraftContext: true)
        suggestionGeneration += 1
        suggestionTask?.cancel()
        suggestionTask = nil

        onRequestKey?(false)
        if wasOpen {
            onPresentationChange?(.closed)
        }
        if !isPickingFiles, let app = appToReactivate {
            appToReactivate = nil
            if NSApp.isActive, !app.isTerminated {
                app.activate(options: [])
            }
        }
    }

    func toggle(reason: OpenReason) {
        if isOpen {
            close()
        } else {
            open(reason: reason, focus: reason != .hover && reason != .drag)
        }
    }

    /// The user clicked into the panel.
    func engage() {
        isEngaged = true
        onRequestKey?(true)
        // A hover (or drag) open looks the tab up without asking for Automation permission, and with
        // a 90 ms dwell it always wins the race against a click. Clicking in is a deliberate act, so
        // look again, this time allowed to show the consent prompt.
        if isOpen, !lastLookupAllowedPrompt, suggestedTab == nil, autoAttachedTabID == nil {
            refreshSuggestedTab(allowPrompt: true)
        }
    }

    // MARK: - Chat

    func send() {
        guard canSend else { return }
        // Checked again here (not only when each chip was added): the model may have changed since,
        // and a PDF within Opus's page limit can be over Haiku's. Such a message could never be answered.
        if let problem = AttachmentBudget.problem(with: attachments, model: settings.model) {
            transientError = problem.localizedDescription
            return
        }
        chat.send(text: composerText, attachments: attachments)
        composerText = ""
        attachments = []
        autoAttachedTabID = nil
        if isOpen {
            isEngaged = true
        }
    }

    func stop() {
        chat.cancel()
    }

    func newChat() {
        chat.reset()
        composerText = ""
        attachments = []
        autoAttachedTabID = nil
        hasUnreadReply = false
        transientError = nil
        if isEngaged {
            focusRequest += 1
        }
    }

    func copyLastResponse() {
        guard let text = chat.lastAssistantText else {
            transientError = "There's no reply to copy yet."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            transientError = "Couldn't copy the reply to the clipboard."
        }
    }

    func openSettings() {
        close()
        onOpenSettings?()
    }

    // MARK: - Attachments

    func addFiles(_ urls: [URL]) {
        var accepted: [URL] = []
        var hitLimit = false
        for url in urls where url.isFileURL {
            let fileURL = url.standardizedFileURL
            let isDuplicate = accepted.contains(fileURL)
                || loadingFileURLs.contains(fileURL)
                || attachments.contains { Self.isSameSource($0.sourceURL, fileURL) }
            if isDuplicate { continue }
            guard attachments.count + pendingAttachmentLoads + accepted.count < Self.maxAttachments else {
                hitLimit = true
                break
            }
            accepted.append(fileURL)
        }
        if hitLimit {
            transientError = Self.attachmentLimitMessage
        }
        guard !accepted.isEmpty else { return }

        pendingAttachmentLoads += accepted.count
        loadingFileURLs.formUnion(accepted)

        // Load concurrently (AttachmentLoader works off the main actor), but commit in the order the
        // user picked so the chips appear in that order.
        let loads = accepted.map { url in
            (url, Task { try await AttachmentLoader.load(fileURL: url) })
        }
        Task { [weak self] in
            var failures: [Error] = []
            for (url, load) in loads {
                let result = await load.result
                guard let self else { continue }
                self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - 1)
                self.loadingFileURLs.remove(url)
                switch result {
                case .success(let attachment):
                    self.addAttachment(attachment)
                case .failure(let error):
                    failures.append(error)
                }
            }
            self?.report(failures)
        }
    }

    /// Adds an attachment unless one with the same source URL is already attached; at most
    /// `maxAttachments` (reports `transientError` when full).
    func addAttachment(_ attachment: Attachment) {
        insert(attachment)
    }

    func removeAttachment(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        if removed.id == autoAttachedTabID {
            autoAttachedTabID = nil
        }
        if removed.kind == .webPage, let url = removed.sourceURL {
            dismissedTabURL = url
        }
    }

    func acceptSuggestedTab() {
        guard let tab = suggestedTab else { return }
        switch insert(tab) {
        case .added, .duplicate:
            suggestedTab = nil
        case .full, .rejected:
            break
        }
    }

    func dismissSuggestedTab() {
        guard let tab = suggestedTab else { return }
        dismissedTabURL = tab.sourceURL
        suggestedTab = nil
    }

    /// Shows an NSOpenPanel (multi-select). The notch stays open while it is up.
    func pickFiles() {
        if isPickingFiles {
            // Already up (perhaps behind another app's window): bring it back to the front.
            NSApp.activate()
            filePanel?.makeKeyAndOrderFront(nil)
            return
        }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return
        }
        isPickingFiles = true

        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.message = "Choose files for Otto to look at."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        // The notch stays open (and above normal windows) while picking, so the picker must sit above
        // it; otherwise the conversation covers its toolbar and file list and takes its clicks.
        panel.level = Self.filePickerLevel
        filePanel = panel

        // Otto is an accessory app behind a non-activating panel; activate so the open panel
        // comes to the front and takes keyboard focus.
        if !NSApp.isActive {
            appToReactivate = currentExternalApp
        }
        NSApp.activate()
        panel.begin { [weak self] response in
            let urls = response == .OK ? panel.urls : []
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPickingFiles = false
                self.filePanel = nil
                self.open(reason: .programmatic, focus: true)
                if !urls.isEmpty {
                    self.addFiles(urls)
                }
            }
        }
    }

    /// Hides the panel, lets the user pick a region, attaches it and reopens focused.
    func captureScreenshot() {
        guard !isCapturingScreen else { return }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return
        }
        isCapturingScreen = true
        onBeginScreenCapture?()

        Task { [weak self] in
            let result: Result<Attachment?, Error>
            do {
                result = .success(try await ScreenCapture.captureInteractive())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isCapturingScreen = false
            self.onEndScreenCapture?()
            switch result {
            case .success(let attachment?):
                self.addAttachment(attachment)
            case .success(nil):
                break // The user cancelled the selection.
            case .failure(let error):
                Self.logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
                self.transientError = error.localizedDescription
            }
            self.open(reason: .programmatic, focus: true)
        }
    }

    /// Attaches files/images/links from the general pasteboard; short text goes into the composer.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        // Copied files go through `addFiles`, which only loads as many as there is room for (plus
        // per-file placeholders and duplicate checks), instead of reading every one and dropping the
        // extras afterwards.
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            guard remainingCapacity > 0 else {
                transientError = Self.attachmentLimitMessage
                return
            }
            addFiles(fileURLs)
            return
        }
        // Only image reads can take a moment; plain text is instant, and a placeholder chip flashing
        // for it would make the layout jump.
        let reservesPlaceholder = Self.mayContainFilesOrImages(pasteboard)
        // Pasted images are each read and encoded, so only load as many as there is room for (at
        // least one, so a full notch still says why nothing was added).
        let limit = max(1, remainingCapacity)
        if reservesPlaceholder {
            pendingAttachmentLoads += 1
        }
        Task { [weak self] in
            let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard, limit: limit)
            guard let self else { return }
            if reservesPlaceholder {
                self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - 1)
            }
            let receivedAnything = !content.attachments.isEmpty
                || !(content.inlineText ?? "").isEmpty || !errors.isEmpty
            if receivedAnything {
                self.integrate(content, errors: errors)
            } else {
                self.transientError = "There's nothing on the clipboard to attach."
            }
        }
    }

    /// Accepts a drop onto the open notch. Returns true if any provider carries something loadable.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter(Self.isLoadable)
        guard !candidates.isEmpty else { return false }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return false
        }
        // Load only what can still be attached: every item is read and encoded in full (up to tens of
        // MB each), so loading 40 dropped PDFs to keep 10 would hold all of them in memory at once.
        let loadable = Array(candidates.prefix(remainingCapacity))
        if loadable.count < candidates.count {
            transientError = Self.attachmentLimitMessage
        }

        if isOpen {
            engage()
            focusRequest += 1
        } else {
            open(reason: .drag, focus: true)
        }

        let placeholders = loadable.count
        pendingAttachmentLoads += placeholders
        Task { [weak self] in
            let (content, errors) = await AttachmentLoader.load(providers: loadable)
            guard let self else { return }
            self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - placeholders)
            self.integrate(content, errors: errors)
        }
        return true
    }

    // MARK: - Snapshots

    /// Snapshots only: sets visible state directly, without callbacks or lookups.
    func debugSeed(
        presentation: Presentation,
        composerText: String,
        attachments: [Attachment],
        suggestedTab: Attachment?,
        hasUnreadReply: Bool
    ) {
        self.presentation = presentation
        self.openReason = presentation == .open ? .programmatic : nil
        self.composerText = composerText
        self.attachments = attachments
        self.suggestedTab = suggestedTab
        self.hasUnreadReply = hasUnreadReply
    }

    // MARK: - Attachment helpers

    private enum InsertOutcome { case added, duplicate, full, rejected }

    private var remainingCapacity: Int {
        max(0, Self.maxAttachments - attachments.count - pendingAttachmentLoads)
    }

    @discardableResult
    private func insert(_ attachment: Attachment) -> InsertOutcome {
        if let url = attachment.sourceURL, attachments.contains(where: { Self.isSameSource($0.sourceURL, url) }) {
            return .duplicate
        }
        guard attachments.count < Self.maxAttachments else {
            transientError = Self.attachmentLimitMessage
            return .full
        }
        // Keep the message sendable: a PDF over the model's page limit, or one attachment too many for
        // the request size limit, is refused here with the reason rather than failing at the API.
        if let problem = AttachmentBudget.problem(with: attachments + [attachment], model: settings.model) {
            transientError = problem.localizedDescription
            return .rejected
        }
        attachments.append(attachment)
        if let suggestion = suggestedTab, Self.isSameSource(suggestion.sourceURL, attachment.sourceURL) {
            suggestedTab = nil
        }
        return .added
    }

    private func integrate(_ content: PasteboardContent, errors: [Error]) {
        for attachment in content.attachments {
            insert(attachment)
        }
        if let text = content.inlineText, !text.isEmpty {
            appendToComposer(text)
            focusRequest += 1
        }
        report(errors)
    }

    private func appendToComposer(_ text: String) {
        if composerText.isEmpty || composerText.last?.isWhitespace == true {
            composerText += text
        } else {
            composerText += " " + text
        }
    }

    private func report(_ errors: [Error]) {
        guard let first = errors.first else { return }
        let message = first.localizedDescription
        transientError = errors.count == 1
            ? message
            : "\(message) (and \(errors.count - 1) more couldn't be attached)"
    }

    private func scheduleTransientErrorClear() {
        transientErrorTask?.cancel()
        transientErrorTask = nil
        guard let message = transientError else { return }
        let lifetime = transientErrorLifetime
        transientErrorTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.transientError == message else { return }
            self.transientError = nil
        }
    }

    private static func isSameSource(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs.isFileURL && rhs.isFileURL {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }
        return lhs.absoluteString == rhs.absoluteString
    }

    private static func isLoadable(_ provider: NSItemProvider) -> Bool {
        [UTType.fileURL, .image, .url, .plainText].contains { type in
            provider.hasItemConformingToTypeIdentifier(type.identifier)
        }
    }

    private static func mayContainFilesOrImages(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    // MARK: - Suggested browser tab

    private func startTrackingFrontmostApp() {
        let workspace = NSWorkspace.shared
        if let app = workspace.frontmostApplication, !Self.isOtto(app) {
            lastExternalApp = app
        }
        let center = workspace.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.isOtto(app) else { return }
            MainActor.assumeIsolated {
                self?.lastExternalApp = app
            }
        }
        activationObserver = NotificationObservation(center: center, token: token)
    }

    /// The app the user is working in: the frontmost app unless that is Otto itself (e.g. while
    /// the file picker is up), in which case the last other app that was frontmost.
    private var currentExternalApp: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isOtto(front), !front.isTerminated {
            return front
        }
        guard let last = lastExternalApp, !last.isTerminated else { return nil }
        return last
    }

    private func refreshSuggestedTab(allowPrompt: Bool) {
        suggestionGeneration += 1
        lastLookupAllowedPrompt = allowPrompt
        suggestionTask?.cancel()
        suggestionTask = nil
        isAwaitingAutomationConsent = false

        guard settings.suggestBrowserTab,
              let app = currentExternalApp,
              BrowserContext.isSupportedBrowser(bundleID: app.bundleIdentifier) else {
            suggestedTab = nil
            return
        }

        let generation = suggestionGeneration
        suggestionTask = Task { [weak self] in
            // A prompt-allowed lookup of a browser Otto hasn't been allowed to automate yet shows
            // the system consent dialog. Hold the notch open (via `isMenuPresented`) while it is up,
            // so clicking Allow neither closes nor disengages it.
            var consentWasPending = false
            if allowPrompt, await BrowserContext.automationConsentStatus(of: app) == .wouldPrompt {
                guard !Task.isCancelled, let self, self.isOpen, self.suggestionGeneration == generation else { return }
                self.isAwaitingAutomationConsent = true
                consentWasPending = true
            }
            var tab = await BrowserContext.currentTab(of: app, allowPrompt: allowPrompt)
            if tab == nil, consentWasPending {
                // The lookup gives up after ~1.5 s while the dialog may still be up; once the user
                // decides, look again (without prompting).
                tab = await self?.lookUpAfterConsent(app: app, generation: generation)
            }
            // Drop results that arrive after the notch closed or after a newer refresh started.
            guard !Task.isCancelled, let self, self.suggestionGeneration == generation else { return }
            self.isAwaitingAutomationConsent = false
            guard self.isOpen else { return }
            self.suggestionTask = nil
            self.applySuggestion(tab)
        }
    }

    /// Polls the Automation consent (never prompting) until the user answers the dialog, then reads
    /// the tab if they allowed it. Gives up when the notch closes, a newer lookup starts, or after a
    /// minute.
    private func lookUpAfterConsent(app: NSRunningApplication, generation: Int) async -> BrowserTab? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, isOpen, suggestionGeneration == generation else { return nil }
            switch await BrowserContext.automationConsentStatus(of: app) {
            case .authorized:
                return await BrowserContext.currentTab(of: app, allowPrompt: false)
            case .denied, .unavailable:
                return nil
            case .wouldPrompt:
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return nil
    }

    /// Internal for tests.
    func applySuggestion(_ tab: BrowserTab?) {
        guard let tab else {
            suggestedTab = nil
            return
        }
        if let dismissed = dismissedTabURL {
            if Self.isSameSource(dismissed, tab.url) {
                suggestedTab = nil
                return
            }
            dismissedTabURL = nil
        }
        if attachments.contains(where: { Self.isSameSource($0.sourceURL, tab.url) }) {
            suggestedTab = nil
            return
        }

        let attachment = AttachmentLoader.makeWebPage(url: tab.url, title: tab.title, appBundleID: tab.bundleID)
        // Only a tab the browser confirmed is not in a private window is attached (and so sent)
        // without asking; Safari tabs and unverified windows are offered as the ghost chip instead.
        if settings.autoAttachBrowserTab && tab.isKnownNonPrivate {
            suggestedTab = nil
            // The user moved to another page since the last lookup: that page's chip goes.
            removeAutoAttachedTab()
            if remainingCapacity > 0, insert(attachment) == .added {
                autoAttachedTabID = attachment.id
            }
        } else {
            // The auto-attached chip stood for the page the user was on before; it goes either way.
            removeAutoAttachedTab()
            suggestedTab = attachment
        }
    }

    /// Takes the auto-attached tab chip back out, so tabs from earlier opens (a hover in passing
    /// counts) don't pile up and ride along with an unrelated message. Once the user has started a
    /// draft it is theirs: when the notch closes with text in the composer the chip stays attached.
    private func removeAutoAttachedTab(keepingDraftContext: Bool = false) {
        guard let id = autoAttachedTabID else { return }
        autoAttachedTabID = nil
        if keepingDraftContext, !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        attachments.removeAll { $0.id == id }
    }

    nonisolated private static func isOtto(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID = app.bundleIdentifier, let ownID = Bundle.main.bundleIdentifier else { return false }
        return bundleID == ownID
    }
}

/// Removes a block-based NotificationCenter observer when released.
private final class NotificationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}
