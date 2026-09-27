# Otto: architecture and design spec

This is the architecture and design specification for contributors. It describes how Otto is put
together: every module's interface and behavior, the request and streaming contract with the Anthropic
API, the notch window and pointer logic, and the visual language. For what Otto is and how to use it,
start with the [README](../README.md); for setup, workflow and the PR checklist, see
[CONTRIBUTING.md](../CONTRIBUTING.md).

Otto is a native macOS app (Swift 5 language mode, SwiftUI + AppKit, macOS 14+): the AI assistant that
lives in your MacBook's notch. Hovering the notch expands it (spring animation) into a dark, finely
textured "clay/foam" panel with context chips (files, images, the current browser tab) and a composer
(text field + `+` + white ↑ send button). Messages go to Claude via the Anthropic Messages API (raw
HTTPS + SSE; there is no official Swift SDK). Replies stream into the expanded notch.

Visual direction: near-black textured surface, soft raised chips, off-white circular send button, round
⋮ button top-right, big rounded bottom corners.

Project layout: the Xcode project is generated with **xcodegen** from `project.yml` (`Otto.xcodeproj` is
not checked in). Sources live in `Otto/**` (auto-included by folder), tests in `OttoTests/**`.
Build: `scripts/build.sh`, or `xcodegen generate && xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build build`.
Test: `xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test`.
Shared contract types are in `Otto/Chat/Models.swift`. Many modules depend on them, so change them
deliberately and update every caller and this spec in the same PR.

The "owner" labels on the module sections below record how the original build was split into modules;
treat them as module boundaries. Keep a change inside the module it belongs to where you can, and
update the matching section here when you change a module's interface or behavior.

Global conventions
- Swift 5 mode, `SWIFT_STRICT_CONCURRENCY=minimal`. Mark UI/state classes `@MainActor`. Use `@Observable`
  (Observation framework, macOS 14) for state objects; views take them as `@Bindable var` / `let`.
- No third-party dependencies. Only Apple frameworks (AppKit, SwiftUI, Observation, Carbon, PDFKit,
  UniformTypeIdentifiers, ServiceManagement, Security, ImageIO, CoreImage).
- No force-unwraps on anything that can fail at runtime. No `print` spam (use `os.Logger`, subsystem
  `com.jalenedusei.otto`).
- Every file begins with the standard header comment (`//  FileName.swift` / `//  Otto`).
- Keep code idiomatic, commented where non-obvious, no placeholder/TODO stubs; everything must work.
- Respect module boundaries: interfaces between modules are the ones listed below.

---------------------------------------------------------------------------------------------------

## Module ownership & interfaces

### 1. API module (owner: `api` agent): `Otto/API/*`, `OttoTests/API*Tests.swift`

Files: `AnthropicClient.swift`, `SSEParser.swift`, `StreamAccumulator.swift`, `MockLLMClient.swift`,
`KeychainStore.swift`.

```swift
enum KeychainStore {
    static let service = "com.jalenedusei.otto"
    static let apiKeyAccount = "anthropic-api-key"
    static func read(account: String) -> String?
    static func write(_ value: String, account: String) throws   // upsert, kSecClassGenericPassword
    static func delete(account: String) throws  // throws KeychainStoreError(.delete) unless the item is gone
}

final class AnthropicClient: LLMClient, @unchecked Sendable {
    init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared)
    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error>
    /// Pure request-body builder (unit tested).
    static func makeRequestBody(_ request: MessagesRequest) -> JSONValue
    /// Headers for a request (unit tested). Includes anthropic-beta only when needed.
    static func makeHeaders(apiKey: String, request: MessagesRequest) -> [String: String]
}

/// Parses SSE `data:` lines into JSONValue events.
struct SSEParser { mutating func consume(line: String) -> JSONValue? }

/// Folds Messages streaming events into content blocks and emits StreamEvents.
struct StreamAccumulator {
    init()
    /// Returns zero or more StreamEvents for one decoded SSE event. Throws LLMError.streamError on `error` events.
    mutating func handle(_ event: JSONValue) throws -> [StreamEvent]
    var isComplete: Bool { get }          // true after message_stop
    func result() -> StreamResult
}

final class MockLLMClient: LLMClient, @unchecked Sendable {
    init(latencyScale: Double = 1.0)     // 0 => no delays (tests/snapshots)
    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
```

Request body (`POST {baseURL}/v1/messages`), built by `makeRequestBody`:
```json
{
  "model": "<request.model.rawValue>",
  "max_tokens": <request.maxTokens>,
  "stream": true,
  "system": [{"type": "text", "text": "<request.system>"}],
  "messages": <request.messages>,
  "cache_control": {"type": "ephemeral"},
  "thinking": {"type": "adaptive", "display": "summarized"},   // only if model.supportsAdaptiveThinking
  "output_config": {"effort": "<request.effort.rawValue>"},    // only if model.supportsEffort
  "fallbacks": "default",                                      // only if model.supportsServerFallbacks
  "tools": [                                                   // only if request.webAccess
    {"type": "<model.webSearchToolType>", "name": "web_search", "max_uses": 5},
    {"type": "<model.webFetchToolType>",  "name": "web_fetch",  "max_uses": 5}   // only if webFetchToolType != nil
  ]
}
```
Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`,
`accept: text/event-stream`, and `anthropic-beta: server-side-fallback-2026-07-01` **only** when
`model.supportsServerFallbacks`. Encode the body with `JSONValue.makeEncoder()` (sorted keys ⇒ byte-stable
prefix for prompt caching). Never send `temperature`, `top_p`, `budget_tokens`, or assistant prefill.

Streaming transport: `URLSession.bytes(for:)`; check `HTTPURLResponse.statusCode` first. Non-2xx: read the
whole body, decode `{"type":"error","error":{"type":..,"message":..}}` and map: 401 → `.invalidAPIKey`;
403 (permission_error) → `.http(status: 403, type:, message:)` with the server message, falling back to
"Your API key doesn't have access to this model or feature." when empty;
429 → `.rateLimited(retryAfter: <retry-after header seconds>)`, 529 or error.type `overloaded_error` →
`.overloaded`, else `.http(status:type:message:)`. URLError → `.network(localizedDescription)` (but
`URLError.cancelled` / task cancellation → `CancellationError`). Retry up to 2 times with backoff
(1s, 3s, or retry-after if ≤ 20s) **only** for retryable errors that happen **before any StreamEvent has
been yielded**. `URLRequest.timeoutInterval = 300`. The returned `AsyncThrowingStream` must cancel its
internal Task in `onTermination`.

SSE: IMPORTANT: `AsyncBytes.lines` skips empty lines, so do **not** rely on blank-line dispatch. Every
Anthropic event carries single-line JSON in a `data:` line with its own `"type"`; parse each `data:` line
independently. Ignore `event:` lines, comments (`:`), and `ping` events.

Event → accumulator behaviour (`content_block` objects are kept as JSONValue objects indexed by `index`):
- `message_start`: remember `message.model`, `message.usage`; emit `.messageStart(model:)`.
- `content_block_start`: store `content_block` verbatim at `index`. Then by `content_block.type`:
  `thinking` → emit `.thinkingStarted`; `server_tool_use` → remember name/id (emit nothing yet; input
  arrives via deltas); `web_search_tool_result` → emit `.toolActivity(id: tool_use_id, isDone: true, …)`
  (reuse the kind/label recorded when the tool_use finished) and `.sources` for each `web_search_result`
  item in `content` (title, url) when `content` is an array (an object means an error; still mark done);
  `web_fetch_tool_result` → mark done and emit a source for `content.url` with title `content.content.title`
  if present, else the URL host; `fallback` → emit `.fallback(fromModel: from.model, toModel: to.model)`;
  `text` with a non-empty initial `text` → emit `.textDelta`.
- `content_block_delta`: `text_delta` → append to block `text`, emit `.textDelta`; `thinking_delta` →
  append to `thinking`, emit `.thinkingDelta`; `signature_delta` → set `signature`; `input_json_delta` →
  accumulate `partial_json` string for that index; `citations_delta` → append `delta.citation` to the
  block's `citations` array and, if the citation has `url`, emit `.sources([SourceLink(title: citation.title ?? host, url:)])`.
  Unknown delta types: ignore.
- `content_block_stop`: for `tool_use` / `server_tool_use` blocks, parse the accumulated partial JSON into
  `input` (keep the start `input` if nothing accumulated or parse fails). For `server_tool_use` emit
  `.toolActivity(isDone: false)`: name `web_search` → kind `.webSearch`, label `Searching “<input.query>”`;
  `web_fetch` → `.webFetch`, label `Reading <host of input.url>`; other → `.other`, label = tool name.
- `message_delta`: record `delta.stop_reason`, `delta.stop_details`, merge `usage`.
- `message_stop`: mark complete; the client then yields `.completed(result())` and finishes.
- `error` event: throw `LLMError.streamError(type: error.type, message: error.message)` (use `.overloaded`
  for `overloaded_error`).
- If the byte stream ends without `message_stop`, throw `.network("The connection closed before the reply finished.")`.
`result().content` = blocks in index order (drop nil gaps).

MockLLMClient (used by `--demo` and snapshot/tests): emits a realistic script: `messageStart(model:
"claude-opus-5 (demo)")`, `thinkingStarted`, a few `thinkingDelta`s, a web-search `toolActivity`
(start → done) + two `sources`, then a Markdown answer streamed word-by-word (25–45 ms per chunk ×
latencyScale) that references the last user message text and the number of attachments (count `image`/
`document` blocks in the last user message), including a short bullet list and a fenced `swift` code
block. Then `.completed` with matching `content` blocks (`thinking` with a fake `signature`,
`server_tool_use`, `web_search_tool_result`, `text`) and `stopReason: "end_turn"`. If the last user text
contains the word "refuse", complete with `stopReason: "refusal"` and no text instead. Honors cancellation.

Tests (`OttoTests/APIClientTests.swift`, `OttoTests/StreamAccumulatorTests.swift`): request body per
model (opus5 has thinking/effort/fallbacks, haiku45 has none of them and only web_search), beta header
logic, SSE parsing of a recorded stream (text + thinking + signature + server tool + citations +
message_delta), partial-JSON tool input assembly, `error` event → throws, fallback block event.

### 2. Context module (owner: `context` agent): `Otto/Context/*`, `OttoTests/Context*Tests.swift`

Files: `AttachmentLoader.swift`, `AttachmentBudget.swift`, `HTMLText.swift`, `BrowserContext.swift`,
`ScreenCapture.swift`.

```swift
enum AttachmentError: LocalizedError, Equatable {
    case unsupportedType(name: String)
    case tooLarge(name: String, limit: String)
    case unreadable(name: String)
    case empty(name: String)
}

struct PasteboardContent {
    var attachments: [Attachment]
    /// Short plain text that should go into the composer rather than become a document.
    var inlineText: String?
}

enum AttachmentLoader {
    static let maxImageBase64Bytes = 5 * 1024 * 1024 - 64 * 1024
    static let maxPDFBytes = 21 * 1024 * 1024       // base64 of a max-size PDF must fit the request budget
    static let maxTextCharacters = 400_000
    /// Loads a file URL entirely off the main thread (images, PDFs, text/source files, RTF/DOCX/DOC/ODT via
    /// NSAttributedString → plain text; HTML (≤ 8 MB) and .webarchive main resources via `HTMLText`, which
    /// never touches the network). Throws AttachmentError.
    static func load(fileURL: URL) async throws -> Attachment
    static func load(image: NSImage, name: String) async throws -> Attachment
    static func makeTextAttachment(_ text: String, name: String) throws -> Attachment
    static func makeWebPage(url: URL, title: String?, appBundleID: String?) -> Attachment
    /// Reads NSPasteboard: file URLs → load; image data → image; web URL string → webPage;
    /// text ≤ 600 chars → inlineText; longer text → "Clipboard.txt" text attachment.
    /// Reads at most `limit` files/images.
    static func load(pasteboard: NSPasteboard, limit: Int = .max) async -> (PasteboardContent, [Error])
    /// Loads SwiftUI/AppKit drop providers (.fileURL, .image, .url, .plainText). Same rules as pasteboard.
    static func load(providers: [NSItemProvider]) async -> (PasteboardContent, [Error])
    static func pdfPageCount(of attachment: Attachment) -> Int?
}

/// Request-level limits (the API rejects bodies over 32 MB; Haiku 4.5 accepts ≤ 100 PDF pages).
enum AttachmentBudget {
    static let maxRequestContentBytes = 30_000_000
    static let requestTooLargeDescription: String
    static func exceedsPageLimit(_ attachment: Attachment, model: ModelOption) -> Bool
    /// First reason these attachments can't go in one message to `model` (checked on insert and on send).
    static func problem(with attachments: [Attachment], model: ModelOption) -> AttachmentError?
    /// Strips attachments of the oldest user turns until the messages array fits; nil if the newest alone doesn't.
    static func fitting(_ messages: [JSONValue], limit: Int = maxRequestContentBytes) -> [JSONValue]?
    static func strippingAttachments(from content: [JSONValue]) -> [JSONValue]
}
```
Image rules: accept anything `NSImage`/ImageIO can read (png, jpeg, gif, webp, heic, tiff, bmp…). Keep
png/jpeg/gif/webp as-is when long edge ≤ 2000 px and base64 ≤ limit; otherwise re-encode (downscale long
edge to ≤ 2000 px; JPEG q 0.85, or PNG when the image has alpha and fits) and keep shrinking until
base64 ≤ `maxImageBase64Bytes`. Animated GIF over limit → first frame JPEG. Thumbnail: ≤ 64 px NSImage.
Badge = uppercased extension (max 4 chars; "JPEG"→"JPG"), screenshots "PNG".
PDF: ≤ maxPDFBytes, must open with PDFKit and have ≤ 600 pages; badge "PDF"; thumbnail = first page.
Text: decode with encoding detection (`String(contentsOf:usedEncoding:)`, fall back to UTF-8 / Latin-1),
reject if it contains NUL bytes (binary) → `.unsupportedType`; empty → `.empty`; > maxTextCharacters →
`.tooLarge`. Anything conforming to `UTType.text`, `.sourceCode`, `.json`, `.xml`, `.yaml`, `.propertyList`,
`.commaSeparatedText`, plus unknown types that decode cleanly as UTF-8, are text. Badge from extension
("TXT" default). Folders and other binaries → `.unsupportedType`.
Web page attachment: kind `.webPage`, badge "WEB", displayName = title (trimmed, fallback host),
payload `.webPage(title:url:)`.
All errors have friendly `errorDescription`s ("cat.mov isn't a supported file type", …).

```swift
struct BrowserTab: Equatable, Sendable {
    let title: String; let url: URL; let bundleID: String
    var isKnownNonPrivate: Bool = false   // true only when the browser confirmed a normal window (never Safari)
}

enum BrowserContext {
    /// Chromium family (Chrome, Chrome Canary, Chromium, Brave, Edge, Vivaldi, Opera, Arc) + Safari (+ Tech Preview).
    static func isSupportedBrowser(bundleID: String?) -> Bool
    /// Front window's active tab via AppleScript on a dedicated serial queue (never the main thread).
    /// When `allowPrompt` is false, first checks AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)
    /// and returns nil unless automation is already authorized. Returns nil for non-http(s) URLs,
    /// errors, or unsupported apps. Must time out (≈1.5 s) instead of hanging.
    static func currentTab(of app: NSRunningApplication, allowPrompt: Bool) async -> BrowserTab?
    /// Non-prompting consent query (.authorized / .wouldPrompt / .denied / .unavailable), off the main thread.
    static func automationConsentStatus(of app: NSRunningApplication) async -> AutomationConsent
}

enum ScreenCapture {
    /// Runs `/usr/sbin/screencapture -i -x -t png <tmpfile>` (interactive region/window selection).
    /// Returns nil if the user cancelled (no file). Loads the PNG as an image attachment named
    /// "Screenshot <HH.mm.ss>.png", then deletes the temp file. Throws ScreenCaptureError.permissionDenied
    /// (after asking macOS to show the request) when Screen Recording isn't allowed.
    static func captureInteractive() async throws -> Attachment?
}
```
Tests: text file load (utf8 + badge), binary rejection, empty file, image downscale keeps limit + media
type, pasteboard text short/long rules, web page attachment content block shape.

### 3. State module (owner: `state` agent): `Otto/Chat/ChatSession.swift`, `Otto/Chat/SystemPrompt.swift`, `Otto/Notch/NotchViewModel.swift`, `Otto/App/AppSettings.swift`, `OttoTests/ChatSessionTests.swift`

```swift
@MainActor @Observable final class AppSettings {
    static let shared: AppSettings
    init(defaults: UserDefaults = .standard)        // tests pass a suite
    var model: ModelOption                          // default .opus5
    var effort: EffortLevel                         // default .medium
    var webAccess: Bool                             // default true
    var suggestBrowserTab: Bool                     // default true (show ghost chip for current tab)
    var autoAttachBrowserTab: Bool                  // default false (attach it directly instead of ghost)
    var hotKeyEnabled: Bool                         // default true  (⌥Space)
    var showMenuBarIcon: Bool                       // default true
    var launchAtLogin: Bool                         // SMAppService.mainApp; setter registers/unregisters, reverts on error
    var customInstructions: String                  // default ""
    var apiKey: String                              // Keychain-backed (KeychainStore), cached in memory; "" deletes
    var hasAPIKey: Bool { get }                     // resolvedAPIKey != nil
    var resolvedAPIKey: String? { get }             // keychain key, else env ANTHROPIC_API_KEY, else nil
    var lastSettingsError: String?                  // e.g. launch-at-login failure, keychain write failure
}
```
Persist every property except apiKey in UserDefaults (keys prefixed `otto.`) via `didSet`.

```swift
enum SystemPrompt { static func make(settings: AppSettings, now: Date = Date()) -> String }
```
System prompt content (keep it stable (date only, no time) for prompt caching):
"You are Otto, a friendly, sharp assistant that lives in the notch of the user's Mac. The user summons
you for quick help while they work." Then guidance: lead with the answer; be concise (short paragraphs or
tight lists, no preamble or sign-offs; expand only when the task needs it); the panel is narrow (~540 pt)
so avoid wide tables and long lines; use Markdown sparingly (bold, lists, fenced code with a
language); a `<browser_tab>` block is the page the user is currently viewing; use web fetch to read it
when the question depends on its contents; attached documents/images were dropped into the notch by the
user; when you use web results, say so briefly. "Today's date is <EEEE, MMMM d, yyyy>." If custom
instructions are non-empty, append "\n\n<user_instructions>\n…\n</user_instructions>".

```swift
@MainActor @Observable final class ChatSession {
    init(settings: AppSettings, makeClient: @escaping @MainActor () throws -> LLMClient)
    private(set) var messages: [ChatMessage]
    private(set) var isStreaming: Bool
    private(set) var messageCount: Int              // cheap summaries, updated when turns start/settle ; 
    private(set) var lastMessageState: MessageState? //   never per delta; so views needn't observe `messages`
    private(set) var hasCopyableReply: Bool
    var lastAssistantText: String? { get }          // text of last complete assistant message
    var onReplyFinished: (() -> Void)?              // called on the main actor when a turn ends (any state)
    func send(text: String, attachments: [Attachment])
    func cancel()                                   // cancels the stream task; message state → .cancelled
    func retry(messageID: UUID)                     // re-run a failed/cancelled/refused assistant turn
    func reset()                                    // cancel + clear
    func debugSeed(messages: [ChatMessage], isStreaming: Bool)   // snapshots/tests only
}
```
send: ignore if streaming or (text trimmed empty and no attachments). User `apiContent` = all
attachments' `contentBlocks()` followed by one text block (text, or "Please take a look at the attached."
when only attachments). Append the user message and an assistant message (`state: .streaming`), set
`isStreaming`, start a Task:
1. `makeClient()`; if it throws, mark the assistant `.failed(error.localizedDescription)`.
2. Build `MessagesRequest(model: settings.model, system: SystemPrompt.make(settings:), messages: history,
   maxTokens: settings.model.maxOutputTokens, effort: settings.effort, webAccess: settings.webAccess)`.
3. Consume events and mutate the assistant message in place (text/thinking deltas are buffered and written at
   most every 33 ms; the first one, and any pending ones before every other event and at turn end, at once): `.messageStart` → model; `.thinkingStarted`
   → isThinking = true; `.thinkingDelta` → append thinking; `.textDelta` → isThinking = false, append text;
   `.toolActivity` → upsert by id; `.sources` → append unique by URL; `.fallback` → model = toModel;
   `.completed(r)` → append `r.content` to `apiContent`, record stop reason.
4. Stop reasons: `pause_turn` → re-request (≤ 5 times) with the partial assistant message included as the
   last history entry (no new user message), continuing to accumulate into the same message;
   `refusal` → `.refused("Otto can't help with that one.")` and set `includeInContext = false` on both
   this assistant message and its user message; `max_tokens` → `.complete` but append "\n\n_(Reply
   truncated.)_" to `text`; anything else → `.complete`.
5. Errors: `CancellationError` → `.cancelled`; `LLMError`/others → `.failed(localizedDescription)`.
   For failed turns set `includeInContext = false` on the assistant message; keep the user message unless the
   API rejected the request for its content (400/413, invalid_request_error, request_too_large, or the
   request exceeding `AttachmentBudget` even after trimming history), in which case it leaves the context too.
6. Finally `isStreaming = false`, `isThinking = false`, call `onReplyFinished`.
History = messages with `includeInContext`, in order, excluding the in-flight assistant unless resuming
`pause_turn`. The history is passed through `AttachmentBudget.fitting` (older attachments become notes);
earlier user turns holding a PDF over the current model's page limit send notes instead of attachments.
Assistant entries use `sanitizedAssistantContent(apiContent)`: if a `fallback` block exists,
drop every non-`text` block before the last `fallback` block; drop all `fallback` blocks; drop empty
`text` blocks. Assistant turns whose sanitized content is empty are skipped. A cancelled assistant turn is
kept in context only if it has non-empty text, as a single text block with its visible text. Consecutive
same-role turns are allowed (the API merges them).
retry(messageID:): only when not streaming; removes that assistant message, re-includes its user message,
appends a fresh streaming assistant message and re-runs.

```swift
@MainActor @Observable final class NotchViewModel {
    enum Presentation: Equatable { case closed, open }
    enum OpenReason: Equatable { case hover, click, hotkey, drag, programmatic }

    init(settings: AppSettings, chat: ChatSession)
    let settings: AppSettings
    let chat: ChatSession

    private(set) var presentation: Presentation      // .closed initially
    private(set) var openReason: OpenReason?
    var isOpen: Bool { get }
    /// The panel is key and the user is interacting with the keyboard; hover-exit must not close it.
    var isEngaged: Bool
    /// Pointer is over the closed notch (window controller sets it); UI shows a subtle grow.
    var isHovering: Bool
    var composerText: String
    private(set) var attachments: [Attachment]
    private(set) var suggestedTab: Attachment?       // ghost chip for the current browser tab
    var isDropTargeted: Bool
    private(set) var pendingAttachmentLoads: Int
    var transientError: String?                      // auto-clears after 4 s
    private(set) var focusRequest: Int               // increments when the composer should take focus
    var hasUnreadReply: Bool
    var isMenuPresented: Bool                        // a +/⋮ menu is open; do not auto-close
    /// Hardware (or virtual) notch size; set by the window controller.
    var closedNotchSize: CGSize                      // default NotchMetrics.virtualNotchSize
    var hasPhysicalNotch: Bool
    /// Size of the shape as currently rendered by the UI (UI reports it; controller hit-tests with it).
    var renderedShapeSize: CGSize
    var canSend: Bool { get }                        // !chat.isStreaming && (text or attachments) && pendingAttachmentLoads == 0
    var shouldStayOpen: Bool { get }                 // isEngaged || isMenuPresented || isDropTargeted || pendingAttachmentLoads > 0
    var showsClosedActivity: Bool { get }            // chat.isStreaming || hasUnreadReply  (closed notch grows "ears")

    // Window-controller hooks (set by NotchWindowController)
    var onPresentationChange: ((Presentation) -> Void)?
    var onRequestKey: ((Bool) -> Void)?              // true: make panel key (focus); false: give focus back
    var onOpenSettings: (() -> Void)?
    var onBeginScreenCapture: (() -> Void)?          // controller hides the panel during capture
    var onEndScreenCapture: (() -> Void)?

    func open(reason: OpenReason, focus: Bool)       // sets presentation, clears hasUnreadReply,
                                                     // refreshes suggested tab (allowPrompt only for click/hotkey),
                                                     // focus ⇒ isEngaged = true, onRequestKey(true), focusRequest += 1
    func close()                                     // presentation = .closed, isEngaged = false, isMenuPresented = false,
                                                     // suggestedTab = nil, onRequestKey(false)
    func toggle(reason: OpenReason)
    func engage()                                    // user clicked into the panel: isEngaged = true, onRequestKey(true)
    func send()                                      // chat.send(text:attachments:), clears composer + attachments,
                                                     // keeps panel open & engaged
    func stop()
    func newChat()                                   // chat.reset(), clear composer/attachments
    func addFiles(_ urls: [URL])                     // AttachmentLoader, pendingAttachmentLoads bookkeeping, errors → transientError
    func addAttachment(_ attachment: Attachment)     // dedupe by sourceURL; max 10 attachments;
                                                     // refused with AttachmentBudget.problem as transientError
    func removeAttachment(id: UUID)
    func acceptSuggestedTab()                        // moves suggestedTab into attachments
    func dismissSuggestedTab()
    func pickFiles()                                 // NSOpenPanel (multi-select), keeps notch open while shown
    func captureScreenshot()                         // onBeginScreenCapture → ScreenCapture → onEndScreenCapture → open(focus)
    func pasteFromClipboard()                        // AttachmentLoader.load(pasteboard: .general); inlineText appended to composer
    func handleDrop(_ providers: [NSItemProvider]) -> Bool   // async load; returns true if any provider is loadable; engages
    func copyLastResponse()
    func openSettings()                              // close(), onOpenSettings?()
    func debugSeed(presentation: Presentation, composerText: String, attachments: [Attachment],
                   suggestedTab: Attachment?, hasUnreadReply: Bool)   // snapshots only; no side effects
}
```
Suggested tab: the VM tracks the last *external* frontmost app via
`NSWorkspace.didActivateApplicationNotification` (ignore Otto's own bundle id; seed with
`NSWorkspace.shared.frontmostApplication`). On open, if `settings.suggestBrowserTab` and that app is a
supported browser, fetch `BrowserContext.currentTab(of:allowPrompt:)`; skip if an attachment with the same
URL already exists; if `autoAttachBrowserTab` **and** `tab.isKnownNonPrivate` add it directly, else set
`suggestedTab`. While a prompt-allowed lookup waits on the Automation consent dialog, `isMenuPresented`
reads true (so the notch stays open and engaged); the tab is looked up again once consent is decided. Ignore stale
results if the notch closed meanwhile. `chat.onReplyFinished` → if closed, `hasUnreadReply = true`.

Tests (`OttoTests/ChatSessionTests.swift`, using MockLLMClient(latencyScale: 0) and a stub LLMClient):
send builds the right user blocks; stream folds into the assistant message; refusal excludes both turns
from history; pause_turn resumes with the partial assistant content; fallback sanitization; cancel.

### 4. Shell module (owner: `shell` agent): `Otto/App/*` (except AppSettings.swift), `Otto/Notch/NotchPanel.swift`, `Otto/Notch/NotchWindowController.swift`, `Otto/Notch/NotchGeometry.swift`, `Otto/Assets.xcassets`, `scripts/*`, `README.md`

Files: `App/main.swift`, `App/AppDelegate.swift`, `App/LaunchOptions.swift`, `App/HotKeyManager.swift`,
`App/StatusItemController.swift`, `App/SettingsWindowController.swift`, `Notch/NotchPanel.swift`,
`Notch/NotchWindowController.swift`, `Notch/NotchGeometry.swift`, `Assets.xcassets/**` (AppIcon generated
by `scripts/make_icon.swift`; render a 1024 px icon: near-black squircle, subtle grain, a soft charcoal
notch silhouette and a small warm-white orb; produce every macOS size + Contents.json), `scripts/build.sh`,
`scripts/run.sh` (build then `open` the app; pass-through args e.g. `--demo`), `scripts/snapshot.sh`
(build then run the binary with `--snapshot docs/snapshots`), `README.md` (what it is, requirements,
build/run, API key, shortcuts, permissions, demo mode, architecture overview linking docs/SPEC.md).

```swift
enum LaunchOptions {
    static let arguments: [String]               // CommandLine.arguments
    static var demo: Bool { get }                // --demo  → MockLLMClient instead of AnthropicClient
    static var startOpen: Bool { get }           // --open  → open the notch at launch (focused)
    static var snapshotDirectory: URL? { get }   // --snapshot <dir>
    static var selfTestDirectory: URL? { get }   // --selftest <dir> → Debug/SelfTest.swift drives the live stack, writes report.json + PNGs
    static var isRunningTests: Bool { get }      // env XCTestConfigurationFilePath != nil
}
```
`main.swift`: plain AppKit entry; `NSApplication.shared`, set `AppDelegate`, `setActivationPolicy(.accessory)`, `run()`.

AppDelegate: if `isRunningTests` → do nothing UI-related. If `snapshotDirectory` → `SnapshotRenderer.renderAll(to:)` (owned by the ui agent, `@MainActor static func renderAll(to directory: URL) async`) then `exit(0)`. Otherwise build `AppSettings.shared`, `ChatSession(settings:makeClient:)` (demo → `MockLLMClient()`; else `AnthropicClient(apiKey:)` using `settings.resolvedAPIKey`, throwing `LLMError.missingAPIKey` when nil), `NotchViewModel`, `NotchWindowController`, `StatusItemController`, `HotKeyManager` (⌥Space toggles the notch with focus; re-register when `settings.hotKeyEnabled` changes; use `withObservationTracking` re-armed on change), `SettingsWindowController`. `--open` → `vm.open(reason: .programmatic, focus: true)` shortly after launch. If there is no API key and not demo, open Settings on first launch (UserDefaults flag `otto.didShowOnboarding`).

```swift
struct NotchGeometry: Equatable {
    let screenFrame: CGRect          // NSScreen.frame (global coords, bottom-left origin)
    let hasPhysicalNotch: Bool
    let notchRect: CGRect            // global coords of the camera housing (or virtual notch, top-centered)
    var closedSize: CGSize { notchRect.size }
    static func preferredScreen() -> NSScreen?          // first screen with auxiliaryTopLeftArea & auxiliaryTopRightArea
                                                        // (keeping the previous one), else the menu-bar screen
    static func make(for screen: NSScreen) -> NotchGeometry
    // physical: x from auxiliaryTopLeftArea.maxX to auxiliaryTopRightArea.minX, height safeAreaInsets.top
    // virtual:  NotchMetrics.virtualNotchSize centered at the top (height = max(24, menu bar thickness))
}

final class NotchPanel: NSPanel {   // borderless + nonactivatingPanel; canBecomeKey true, canBecomeMain false
}

@MainActor final class NotchWindowController {
    init(viewModel: NotchViewModel, settings: AppSettings)
    func showWindow()
    func reposition()                 // on screen parameter changes
}
```
Window: `NotchPanel(contentRect:styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)`;
`isFloatingPanel = true`, `level = NotchPanel.windowLevel` (mainMenu + 3; the file picker uses
`NotchPanel.auxiliaryWindowLevel`, one above),
`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, `isOpaque =
false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovable = false`, `hidesOnDeactivate = false`,
`acceptsMouseMovedEvents = true`, `ignoresMouseEvents = true` initially. Size `NotchMetrics.windowSize`,
top edge flush with `screenFrame.maxY`, horizontally centered on `notchRect.midX`. Content:
`NSHostingView(rootView: NotchRootView(viewModel:))` with `sizingOptions = []`. `orderFrontRegardless()`.
Set `vm.closedNotchSize` / `vm.hasPhysicalNotch` from geometry. Observe
`NSApplication.didChangeScreenParametersNotification` → `reposition()`; `NSWorkspace.activeSpaceDidChange`
→ `orderFrontRegardless()`.

Pointer logic (NSEvent global + local monitors for `.mouseMoved, .leftMouseDragged, .leftMouseDown,
.rightMouseDown, .leftMouseUp`; local monitors must return the event). Let `p = NSEvent.mouseLocation`.
- `shapeRect` (global) = rect of width/height `vm.renderedShapeSize`, top-centered at (notchRect.midX,
  screenFrame.maxY). Hot zone when closed = `notchRect.insetBy(dx: -8, dy: 0)` extended 6 pt downward
  (union with shapeRect).
- `panel.ignoresMouseEvents = !shapeRect(or hot zone when closed).contains(p)`; updated on every event, so
  clicks outside the drawn shape always pass through to apps / menu bar underneath.
- Closed: pointer in hot zone → `vm.isHovering = true`; open with `.hover` (no focus) only after the pointer
  has *rested* (moved ≤ 3 pt) for 90 ms over the notch itself (`NotchGeometry.hoverTarget`). Left →
  `isHovering = false`. All of this is the pure `NotchPointerMachine` (`handle(Event, Context) -> [Effect]`);
  the controller only feeds it snapshots and applies effects.
- Open: pointer outside `shapeRect.insetBy(dx: -14, dy: -14)` and `!vm.shouldStayOpen` → close after
  300 ms (cancel if it comes back or shouldStayOpen becomes true).
- Global `leftMouseDown`/`rightMouseDown` (i.e. a click in another app) while open → `vm.close()`.
- Local `leftMouseDown` inside the shape while open and not engaged → `vm.engage()` (clicking into the
  panel keeps it open).
- Drag: global `leftMouseDragged` whose location enters the hot zone while closed and whose
  `NSPasteboard(name: .drag).changeCount` differs from the value captured at the last mouse-down →
  `vm.open(reason: .drag, focus: false)` and `ignoresMouseEvents = false` so the SwiftUI drop target gets it.
  On `leftMouseUp` after a drag-open with no drop (`!vm.isDropTargeted`, no pending loads) → close.
- Keyboard: local `keyDown` monitor while the panel is key: Esc → `vm.close()`; ⌘N → `vm.newChat()`;
  ⌘, → `vm.openSettings()`; ⌘V when the composer is not first responder → `vm.pasteFromClipboard()`.
- `vm.onRequestKey = { focus in … }`: true → `panel.makeKeyAndOrderFront(nil)` (does not activate Otto:
  non-activating panel); false → if the panel is key, `panel.orderOut(nil); panel.orderFrontRegardless()`
  to return keyboard focus to the user's app. `vm.onBeginScreenCapture` → `panel.orderOut(nil)`;
  `onEndScreenCapture` → `panel.orderFrontRegardless()`.
- Also observe `NSWindow.didResignKeyNotification` for the panel → `vm.isEngaged = false` (unless a menu
  is presented), so a hover-exit can close it afterwards.

StatusItemController: `NSStatusItem` (variable length) with template image (SF Symbol
"sparkle" or a drawn notch glyph); menu: "Open Otto  ⌥Space", "New Chat", separator, "Settings…" (⌘,),
separator, "Quit Otto" (⌘Q). Show/hide tracks `settings.showMenuBarIcon` (observation tracking).

HotKeyManager: Carbon `RegisterEventHotKey(kVK_Space, optionKey, …)` with an `InstallEventHandler` on
`GetApplicationEventTarget()` for `kEventHotKeyPressed`; `init(handler: @escaping @MainActor () -> Void)`,
`register()`, `unregister()`, unregister in deinit. No Accessibility permission needed.

SettingsWindowController: `show()` creates (once) an `NSWindow` (titled, closable, 480×560, title "Otto
Settings") hosting `SettingsView(settings:)` (ui agent), centers it, `NSApp.activate(ignoringOtherApps: true)`,
`makeKeyAndOrderFront`. `isReleasedWhenClosed = false`.

### 5. UI module (owner: `ui` agent): `Otto/UI/*`, `Otto/Debug/SnapshotRenderer.swift`

Files: `Theme.swift` (colors, fonts, `NoiseTexture`, `ClaySurface`/`.clay(cornerRadius:)` modifier,
`OttoOrb`), `NotchShape.swift`, `NotchRootView.swift`, `NotchHeaderView.swift`, `ContextChipsView.swift`
(+ `FlowLayout` implementing `Layout`), `ComposerView.swift`, `ConversationView.swift`,
`MessageView.swift`, `MarkdownText.swift`, `SettingsView.swift`, `Debug/SnapshotRenderer.swift`.

```swift
struct NotchRootView: View { init(viewModel: NotchViewModel) }
struct SettingsView: View { init(settings: AppSettings) }
enum SnapshotRenderer { @MainActor static func renderAll(to directory: URL) async }
```

Look & feel:
- Panel: near-black `#0C0C0D` with a fine monochrome grain (`NoiseTexture`: deterministic 256×256
  grayscale noise CGImage generated once, tiled, opacity ≈ 0.07, `.blendMode(.plusLighter)` or overlay),
  giving a soft foam/felt feel. A barely-visible inner top highlight. Outer shadow (black 0.45, radius 18,
  y 8) only when open.
- Raised "clay" elements (chips, composer well, ⋮ button, + button): vertical gradient `#252527`→`#18181A`,
  the same grain, 1 px inner stroke with a top-lit gradient (white 0.10 → 0.01), drop shadow (black 0.55,
  radius 5, y 3). Pressed state darkens slightly and scales 0.97.
- Text: primary `#EDEDED`, secondary `#9A9A9F`, tertiary `#6B6B70`. UI font: SF Pro 13–15 pt. Wordmark
  "Otto" in `.system(design: .serif)` semibold 15.
- Send button: 30 pt circle filled warm off-white `#ECEAE6` with a black `arrow.up` (semibold 14);
  disabled → 35 % opacity; while streaming becomes a `stop.fill` button (same circle).
- `OttoOrb(size:, isActive:)`: small sphere; radial gradient warm white `#F4F1EA` → `#8C8A86`, soft
  glow; when active it breathes (scale/opacity pulse).

NotchShape (`Shape`, animatable over topRadius & bottomRadius): top edge spans the full width; top
corners are *concave* quarter-circles of `topRadius` (so the shape flares into the screen edge like the
hardware notch); sides go straight down; bottom corners are convex with `bottomRadius`.

NotchRootView layout: the view fills the fixed window; the notch shape is pinned to the top-center.
- Closed: shape = `vm.closedNotchSize` (+ `2 × NotchMetrics.activityEarWidth` wide when
  `vm.showsClosedActivity`; + (8×3) grow when `vm.isHovering`), radii `closedTop/BottomRadius`, pure black
  (no grain) so it disappears into the hardware notch. With activity: left ear shows `OttoOrb(isActive:
  chat.isStreaming)`, right ear shows a 3-bar animated equalizer while streaming or a small warm dot when
  `hasUnreadReply`. Tapping the closed shape → `vm.open(reason: .click, focus: true)`.
- Open: width `NotchMetrics.openWidth`, height = content height (≤ `NotchMetrics.maxOpenHeight`), radii
  `openTop/BottomRadius`. Content (padding 16 horizontal, 14 bottom):
  1. Header row, height = `vm.closedNotchSize.height` (sits beside the camera): left; `OttoOrb` +
     "Otto" wordmark + model short name in tertiary text; right; round ⋮ clay button (30 pt) with a
     `Menu`: New Chat (⌘N), Copy Last Response, Settings… (⌘,), Quit Otto. Keep the center
     (`closedNotchSize.width + 20`) empty.
  2. Conversation (only when `chat.messages` non-empty): `ScrollView` with `ScrollViewReader`, max
     height ~340, auto-scrolls to bottom while streaming.
  3. Context chips (only when attachments/suggestedTab/pending loads exist): `FlowLayout` spacing 8, max
     2 rows then scroll. Chip = clay capsule (height 30, corner 11): leading icon (browser app icon via
     `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` + `icon(forFile:)`; image thumbnail
     18×18 r4; otherwise a tiny white badge with dark text like "TXT"), name (13 pt, max ~170 pt,
     truncation `.middle`), hover-revealed remove button (×) (always visible for the most recently added chip, like the
     reference). Suggested tab chip: dashed 1 px stroke, 55 % opacity, leading "+", click → accept, the remove button →
     dismiss. Pending loads: shimmering placeholder chip.
  4. Composer well (clay, corner 20, min height 50): multi-line `TextField("Ask Otto anything…", text:,
     axis: .vertical)`, `.textFieldStyle(.plain)`, 15 pt, lineLimit 1...6, `.focused` bound to a
     `@FocusState` that follows `vm.focusRequest`; `.onSubmit { vm.send() }`; `.onExitCommand { vm.close() }`.
     Trailing: `+` clay circle `Menu` (Attach Files…, Capture Screen Region, Paste from Clipboard,
     Attach Current Tab when a suggestion exists) and the send/stop button. Menus set
     `vm.isMenuPresented` while shown (use `.onAppear/.onDisappear` of menu content or a
     `menu`-tracking helper).
  5. `transientError` line (tertiary red-ish `#FF8A80`, 12 pt) under the composer, animated.
  Drop target: `.onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $vm.isDropTargeted)` →
  `vm.handleDrop`. While targeted: dashed off-white rounded overlay + "Drop to attach" label.
  Report the shape's rendered size to `vm.renderedShapeSize` (GeometryReader/preference on the shape).
  Animations: open `.spring(response: 0.42, dampingFraction: 0.82)`, close `.spring(response: 0.34,
  dampingFraction: 0.9)`; content fades in with slight blur/offset from the top; closed state content
  removed.
- MessageView: user → right-aligned clay bubble (max width 80 %), attachment mini-chips above text.
  Assistant → left-aligned, no bubble: thinking row ("Thinking…" shimmer while `isThinking`; afterwards a
  collapsible "Thought process" disclosure when `thinking` non-empty), activity rows (spinner / checkmark +
  label), `MarkdownText(message.text)` with a blinking caret while streaming, source pills (host names,
  open URL on click), footer on hover: Copy, Retry (failed/cancelled/refused). States: `.refused(msg)` and
  `.failed(msg)` render the message in secondary/red text with Retry; missing-key failures show an "Open
  Settings" button (`vm.openSettings()`).
- MarkdownText: block-level parser (headings #…###, paragraphs, `-`/`*`/`1.` lists incl. nesting by indent,
  `>` quotes, fenced code blocks with language label + copy button in a darker clay box, horizontal rules)
  with inline formatting via `AttributedString(markdown:options: .init(interpretedSyntax:
  .inlineOnlyPreservingWhitespace))`; links clickable; text selectable (`.textSelection(.enabled)`).
  Must tolerate incomplete Markdown mid-stream (e.g. an unclosed code fence renders as code).
- SettingsView (Form, `.formStyle(.grouped)`): API key (SecureField + Save/Remove, status line, link
  "Get an API key" → https://console.anthropic.com/settings/keys), Model picker (displayName + subtitle),
  Response style (effort; disabled for Haiku), toggles: Web search & fetch, Suggest current browser tab,
  Attach tab automatically, ⌥Space shortcut, Menu bar icon, Launch at login; Custom instructions
  (TextEditor, 4 lines); footer: version + "Demo mode" note if LaunchOptions.demo. Show
  `settings.lastSettingsError`.

SnapshotRenderer.renderAll(to:): renders PNGs (2×) of the real `NotchRootView` in seeded states onto a
wallpaper-like backdrop (sky-blue → green gradient, 760×600 pt): `closed.png`, `closed-activity.png`
(streaming ears), `open-empty.png`, `open-chips.png` (reproduce the reference: chips "TechCrunch" (web,
Chrome icon), "AI_Man_cea775f8.png" (image), "PDFcea775f5d9.pdf", "cat-meme.txt", composer text "Hi
otto"), `conversation.png` (a user question with an attachment + an assistant Markdown reply with
thinking disclosure, one finished web search, a list, a code block, sources), `streaming.png` (assistant
mid-stream with activity spinner), `settings.png` (SettingsView 480×560). Use `AppSettings(defaults:
UserDefaults(suiteName: "otto.snapshots")!)`, `ChatSession(settings:makeClient: { MockLLMClient(latencyScale: 0) })`,
`debugSeed` on both objects, animations disabled. Render by hosting in an off-screen borderless `NSWindow`
(ordered front at x = -10000), spinning the run loop ~0.4 s, then
`bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`; if that yields an empty/transparent image,
fall back to `ImageRenderer`. Create the directory if needed; print each written path.
