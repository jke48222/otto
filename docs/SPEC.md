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

Sections 1 to 5 describe Otto 1.0. [Otto 1.1: modules added and changed](#otto-11-modules-added-and-changed),
sections 6 to 18, adds actions, permissions, voice, history, usage, the closed-notch glance, Now Playing, the
calendar chip, the File Shelf, selection and window context, paste-back and the tabbed Settings window, and
lists what changed in the 1.0 modules. Where the two parts disagree, the 1.1 part is current. Section 19 covers
the paid and Setapp builds: the trial, license keys and updates.

Global conventions
- Swift 5 mode, `SWIFT_STRICT_CONCURRENCY=minimal`. Mark UI/state classes `@MainActor`. Use `@Observable`
  (Observation framework, macOS 14) for state objects; views take them as `@Bindable var` / `let`.
- The source build has no third-party dependencies: only Apple frameworks (AppKit, SwiftUI, Observation, Carbon,
  PDFKit, UniformTypeIdentifiers, ServiceManagement, Security, ImageIO, CoreImage, AVFoundation, AVFAudio, Speech,
  NaturalLanguage, EventKit, UserNotifications, ScreenCaptureKit, ApplicationServices, QuickLookUI,
  QuickLookThumbnailing, CryptoKit). The paid build adds Sparkle 2.10.0 and the Setapp build adds the Setapp
  Framework 5.5.0, each through Swift Package Manager in its own generated project (`project-paid.yml`,
  `project-setapp.yml`); `Otto.xcodeproj` never resolves a package. Flavor code sits behind `OTTO_LICENSING`,
  `OTTO_SPARKLE` and `OTTO_SETAPP` (section 19).
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

---------------------------------------------------------------------------------------------------

## Otto 1.1: modules added and changed

Otto 1.1 adds actions (Claude tools), permissions, voice, history, usage, the closed-notch glance, Now
Playing, the calendar chip, the File Shelf, selection and window context, paste-back, a custom shortcut and a
tabbed Settings window. This part describes those modules. Where it disagrees with sections 1 to 5 above,
this part is current. The sections above stay accurate for the API client, attachment loading, the Markdown
renderer, the notch shape and the look and feel.

What changed in the v1.0 modules, in one place:

- **Keyboard.** `NotchWindowController` no longer switches on keys itself. It maps every key through
  `NotchKeyCommands` and `vm.perform(_:input:)` (section 13 below).
- **Hot key.** `HotKeyManager` registers any `HotKeyCombo`, reports press and release, and is driven by
  `GlobalShortcutRouter` (tap toggles the notch, hold talks to Otto). The combo is set in Settings.
- **Settings.** `SettingsWindowController` hosts a non-activating `SettingsPanel` with seven tabs and opens on
  the current Space without activating Otto (section 16).
- **Closed notch.** The ears come from one resolver, `GlanceResolver`, with a fixed priority (section 12).
- **App start.** `AppDelegate` builds everything through `AppComposition.live()` after the launch guard
  (section 8). Tests, snapshots, the promo stage and the self-test build their own graphs.
- **Data on disk.** v1.0 kept nothing on disk. 1.1 writes under `~/Library/Application Support/Otto`
  (section 9).

### 6. Conventions added in 1.1

- Every `os.Logger` uses subsystem `com.jalenedusei.otto` and one of the categories `Tools`, `Actions`,
  `Permissions`, `Voice`, `History`, `Usage`, `Glance`, `NowPlaying`, `Calendar`, `Context`, `Shelf`, `Input`,
  `Settings`, and `License`, `Updates` and `Setapp` in the paid and Setapp builds (section 19). User content (prompts, replies, tool inputs and outputs, file paths, selections, event titles) is
  logged only with `privacy: .private`. Ids, counts, statuses and error codes may be `.public`.
- State classes are `@MainActor @Observable final class`. Values that cross actors are `Sendable`. Persisted
  stored properties of an `@Observable` class have no default value and are assigned in `init`, so `didSet`
  never fires during init.
- Text that comes from outside Otto and is only displayed (track titles, event titles, shelf and history
  names, script chips) goes through `DisplayText.sanitized(_:maxLength:)`. Nothing re-implements it.
- Otto writes its own files only through `SecureFile` into directories from `AppSupport` (section 9).
- Top-level declarations that aren't part of a module's public surface are `private`, nested in their owning
  type, or carry the module prefix (`Media…`, `Shelf…`, `Voice…`, `History…`, `Calendar…`, `Script…`,
  `Glance…`, `Context…`, `Usage…`, `Permission…`, `Input…`).
- Every seam that tests and snapshots rely on has a default, so no test touches TCC, Apple Events, real hot
  keys, the network or the user's data. These stay compiling and behaving: `ChatSession(settings:makeClient:)`,
  `ChatSession.debugSeed(messages:isStreaming:)`, `NotchViewModel(settings:chat:)`,
  `NotchViewModel.debugSeed(presentation:composerText:attachments:suggestedTab:hasUnreadReply:)`,
  `NotchWindowController(viewModel:settings:)`, `NotchRootView(viewModel:)`, `SettingsView(settings:)`,
  `SettingsWindowController(settings:)`, `NotchPointerMachine()` and its `Context` initializer (every new field
  is defaulted), `NotchPointerMachine.Effect.close` as a case with no payload, `MockLLMClient(latencyScale:)` and
  `AppSettings(defaults:usesKeychain:)`.

### 7. Module map and ownership

Otto 1.1 was built in waves by parallel agents, each owning a disjoint set of files. The owner column records
that split; treat it as the module boundary, like the owner labels in sections 1 to 5.

| Folder | Responsibility | Owner |
|---|---|---|
| `Otto/Chat/` | Shared model contract (`Models.swift`), `ChatSession` (conversation and tool loop), `SystemPrompt` | contracts (models), loop (session, prompt) |
| `Otto/API/` | HTTPS and SSE client, stream accumulator (now with `tool_use` and usage events), mock client with scripted tools | loop |
| `Otto/Tools/` | `OttoTool` protocol, `ToolRegistry`, `ToolSchema`, `InputProvenance`; `ToolExecutor`, `JSONSchemaValidator`, `TrustLedger`, `EchoDetector`, `ToolRateLimiter`, `ApprovalStore`, `ActionLog`, `ProcessRunner`; `ToolHistory`; `ToolCatalog` | contracts, exec, loop, app |
| `Otto/Actions/Calendar/` | `calendar_list_events`, `calendar_create_event`, `reminders_list`, `reminders_create`; `EventKitService` actor, `DemoEventKitService`, `DateInput` | actions-calendar |
| `Otto/Actions/Scripting/` | `list_shortcuts`, `run_shortcut`, `run_applescript`, `open_url`; `ShortcutsService`, `AppleScriptRunner`, `AppleScriptAnalyzer` (with `ScriptLexer`), `AppleScriptHighlighter`, `URLGuard`, demo services | actions-scripting |
| `Otto/Media/` | `NowPlayingMonitor`, `MediaScripting`, the `media_control` tool | media |
| `Otto/Permissions/` | `PermissionsCenter` (the only code that checks or requests TCC), `PermissionCardContent`, `AppRelauncher` | contracts (types), perm |
| `Otto/Voice/` | `SFSpeechEngine`, `AudioLevelMeter`, `SpeechChunker`, `ReplySpeaker`, `VoiceController`, `VoiceInterruptions` | contracts (types), voice |
| `Otto/History/` | `ConversationStore`, codec, blobs, `ConversationTitler`, `HistorySearch`, `HistoryController`, `RecentsState` | contracts (types), history |
| `Otto/Usage/` | `ModelPricing`, `UsageLedger`, `CostFormatter` | contracts (protocol), usage |
| `Otto/Glance/` | `PhaseDebouncer`, `GlanceResolver`, `ClosedNotchLayout`, reply preview, `AttentionMonitor`, `NotificationPresenter`, `GlanceController`; `Calendar/` (`CalendarGlance`, `NextEventPicker`, `MeetingLinkDetector`) | contracts (types), glance |
| `Otto/Context/` | v1.0 attachments and browser tab, plus `SelectionReader`, `WindowCapture`, `SensitiveApps`, `ContextSuggestions`, `InsertPolicy`, `PasteboardSnapshot`, `KeySender`, `AnswerInserter`, `InsertCoordinator`, `RichTextRenderer` | context |
| `Otto/Shelf/` | `ShelfStore`, ingest, thumbnails, drag source, sharing, Quick Look, `ShelfController` | contracts (types), shelf |
| `Otto/App/` | `Settings/*` groups and `PreferenceStore`, `AppSupport`, `ObservationLoop`; `HotKeyCombo`, `HotKeyManager`, `GlobalShortcutRouter`, `NotchNeighbors`; `ServicesProvider`; `SettingsPanel`, `SettingsWindowController`; `StatusItemController`, `AppComposition`; `AppDelegate` | contracts, input, context, settings, app, integration |
| `Otto/Notch/` | `NotchContracts`, `NotchServices`, `NotchKeyCommands`, `ReadingRestore`; `NotchViewModel` and its `+Actions`, `+Commands`, `+Context`, `+Glance`, `+History`, `+Interaction`, `+Prompts`, `+Shelf`, `+Voice` extensions; window, pointer machine, geometry, panel, `NotchDropDelegate` | contracts, input, vm-core, vm-features, shell, ui-frame |
| `Otto/UI/` | `Components/`, `Dock/`, `Glance/`, `Voice/`, `Pages/`, `Chat/`, `Settings/` components; `ClosedNotchView`, `NotchOpenContent`, `NotchRootView`, `NotchHeaderView`, `ComposerView`, `ConversationView`, `MessageView`, `MessageSegments` | ui-dock, ui-glance, ui-voice, ui-pages, ui-chat, settings, ui-frame |
| `Otto/Debug/` | `SnapshotRenderer`, `SelfTest`, the promo stage | snapshots, integration |
| `Otto/Licensing/` | Paid build only (section 19): `LicenseContracts`, `LicensePolicy`, `LicenseKeyRouter`, `LicenseCopy`, `StaticLicenseModel`, `LicenseConfiguration+Load`; `LicenseController`, the Keychain and in-memory stores, transport and scheduler; the Polar and Gumroad backends | contracts, license-engine, license-backends |
| `Otto/Updates/`, `Otto/Setapp/` | `UpdateContracts`, `SparkleUpdater` (paid), `SetappUpdater` and `SetappBridge` (Setapp) | contracts, updates |

Frameworks: everything in the global conventions list above. 1.1 added AVFoundation (voice input and spoken
replies), Speech, NaturalLanguage (spoken-reply chunks and conversation titles), EventKit (calendar and
reminders), UserNotifications, ScreenCaptureKit (window chip), ApplicationServices (reading a selection and
posting ⌘V), QuickLookUI and QuickLookThumbnailing (Shelf) and CryptoKit (activity-log fingerprints, selection
fingerprints and blob hashes). They all link through `import`, so `project.yml` lists no frameworks.

### 8. Object graph and app lifecycle

`AppComposition` (in `Otto/App/AppComposition.swift`) builds the whole graph. `AppComposition.live()` is the
running app, `AppComposition.selfTest(directory:)` is the self-test with demo services and temporary stores, and
`AppComposition.inert(settings:)` builds the same graph with no side effects for tests.

```
AppSettings.shared ──┬─ groups: notch, shortcuts, voice, context, shelf, actions, glance, usage, history
                     │
PermissionsCenter ───┤                         ApprovalStore   ActionLog   ToolRateLimiter
                     │                               └──────────┬────┘            │
ToolCatalog.makeRegistry(settings:services:extraTools:) ─► ToolRegistry   ToolExecutor ◄──┘
                     │                                 │            ▲ (PermissionProviding)
                     ▼                                 ▼            │
ChatSession(settings:makeClient:tools:executor:permissions:) ──usageRecorder──► UsageLedger
      │ onTranscriptChanged ──► HistoryController ◄── ConversationStore(.directory(AppSupport/Otto))
      │ phase / lastFinishedAssistantID ──► GlanceController (debounce, preview, notifications)
      ▼
NotchViewModel(settings:chat:services: NotchServices)
      services = PermissionsCenter, VoiceController, HistoryController(+RecentsState), GlanceController,
                 UsageLedger, NowPlayingMonitor, CalendarGlance, ShelfController(ShelfStore),
                 ContextSuggestions, InsertCoordinator(AnswerInserter), NotificationPresenter
      ▲                         ▲
NotchWindowController      SettingsWindowController(settings:services: SettingsServices)
StatusItemController       HotKeyManager ◄── GlobalShortcutRouter ── (tap/hold) ──► VM / voice
ServicesProvider(handler: VM as ServicesHandling)      NotchNeighborMonitor ──► VM neighbor card
```

- There is exactly one `PermissionsCenter` (no `shared`); the composition passes it to every consumer.
- History deletions reach the activity log and delivered notifications only through
  `HistoryController.onDataRemoved`, which the composition wires. Engines never reference each other.
- **Launch guard** (live and `--demo` only). If another process with any of Otto's bundle ids
  (`OttoBuild.allBundleIDs`: `com.jalenedusei.otto`, `com.jalenedusei.otto-setapp`) is running,
  Otto waits up to 3 s for it to exit before it registers the hot key or opens a store. If it is still running,
  live mode asks the running copy to open its notch and quits; `--demo` keeps running without the hot key.
- `applicationWillTerminate` calls `composition.terminate()`: cancel the reply, flush history, shelf and the
  ledger, stop the monitors, unregister the hot key.
- Hot key tap (`AppComposition.tapAction(for:)`): speaking → stop speech; toggle-mode listening → finish and
  send; pinned and engaged → give the keyboard back; pinned and not engaged → focus; open and engaged → close;
  otherwise open focused. Holding for 300 ms or more talks to Otto when Voice and hold-to-talk are on.

### 9. Persistence

`AppSupport.rootURL()` is `~/Library/Application Support/Otto/` (`…/Otto/Demo/` with `--demo`). Every call
`lstat`s the root and the data directory, refuses a symlink or a path not owned by the user, forces mode `0700`,
and excludes the root from Time Machine. Every data directory's name ends in `.noindex`, the per-folder
exclusion Spotlight honors anywhere on a volume. An empty `.metadata_never_index` at the root is a best-effort
extra.

| Data | Location | Owner |
|---|---|---|
| Conversations, index, damaged files | `Conversations.noindex/<UUID>.json`, `Conversations.noindex/index.json`, `Conversations.noindex/Damaged/` | History |
| Attachment payload blobs | `Attachments.noindex/ab/<sha256>` | History |
| Shelf index, owned copies, thumbnails | `Shelf.noindex/shelf.json`, `Shelf.noindex/Owned/<uuid>/<name>`, `Shelf.noindex/Thumbnails/<uuid>.png` | Shelf |
| Usage ledger (token counts, models and costs, no content) | `usage-ledger.json` at the root | Usage |
| Actions activity log | `Logs.noindex/actions.jsonl` and `actions.1.jsonl`, rotated at 1 MB, pruned to the History retention | Tools |
| Preferences, consents, remembered approvals | `UserDefaults` (`otto.*`) | Settings, `ApprovalStore` |
| API key | Keychain (unchanged) | API |
| License, trial and counted Gumroad keys (paid build) | Keychain, service `com.jalenedusei.otto`, accounts in section 19 | Licensing |

`SecureFile.write(_:to:)` creates a temp file with `open(O_CREAT | O_EXCL | O_WRONLY, 0o600)` in the destination
directory, writes it and `rename(2)`s it over the destination. Content-addressed blobs use
`SecureFile.writeIfAbsent`. Window pictures, selections and Services text set
`Attachment.retainsPayloadInHistory = false`: History keeps the chip and thumbnail, never the payload.

### 10. Contracts by module

These are the surfaces other modules call, trimmed to the members they use. Bodies and edge cases live in the
code and its tests.

**Models** (`Otto/Chat/Models.swift`, additive):

```swift
struct MessagesRequest {                     // three defaulted fields added
    var clientTools: [JSONValue] = []        // sorted by name; strict, eager_input_streaming
    var toolChoice: JSONValue? = nil         // only {"type":"none"}, and only when tools exist
    var serverToolLimits = ServerToolLimits()  // max_uses per server tool; 0 omits the tool
}
enum StreamEvent {                           // three cases added
    case toolUseStarted(id: String, name: String)
    case toolUseReady(id: String, name: String, input: JSONValue?, rawInput: String)
    case usage(JSONValue)
}
enum ToolCallStatus { case preparing, queued, needsPermission, awaitingApproval, waitingForSystem(String),
                      running, succeeded, failed(String), denied, blocked(String), cancelled, skipped(String), undone }
struct ToolCall: Identifiable, Codable { id, name, input, invalidInput, presentation, status, result, provenance,
                                         caution, approvedVia, recovery, undo, progressNote, startedAt, finishedAt }
struct ToolExchange: Codable { let contentEnd: Int; let textEnd: Int; let callIDs: [String] }
struct ToolOutput: Codable { var parts: [Part]; var isError: Bool }   // 16,000 characters, 4 images
// ChatMessage gains toolCalls and toolExchanges; Attachment gains retainsPayloadInHistory (default true).
```

**Tools** (`Otto/Tools/`):

```swift
enum ToolGroup: String, CaseIterable { case calendar, reminders, shortcuts, media, links, appleScript }
enum ApprovalRequirement { case none, consentOnce(ConsentKey), everyCall(rememberScope: ApprovalScope?) }
protocol OttoTool: Sendable {
    var name: String { get }; var group: ToolGroup? { get }; var description: String { get }
    var inputSchema: JSONValue { get }; var isStrict: Bool { get }; var isConcurrencySafe: Bool { get }
    var producesUntrustedOutput: Bool { get }; var privateDataSource: String? { get }
    var timeout: Duration { get }; var rateLimit: ToolRateLimit { get }; var minimumArmingDelay: Duration { get }
    var mayPresentUI: Bool { get }; var inheritsOttoPermissions: Bool { get }
    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool
    func requiredPermissions(for input: JSONValue) -> [Permission]
    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement
    func egressStrings(in input: JSONValue) -> [String]
    func validate(_ input: JSONValue) -> ToolError?
    func blockReason(for input: JSONValue) -> String?
    func describe(_ input: JSONValue) -> ToolCallPresentation
    func approvalBody(for input: JSONValue) async -> ApprovalBody
    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult
    func undo(_ token: UndoToken) async throws
}
@MainActor protocol ToolExecuting: AnyObject {  // ToolExecutor implements it; tests use FakeToolExecutor
    var pendingApproval: PendingApproval? { get }
    func beginTurn()
    func execute(_ round: ToolRound, store: ToolCallStore) async throws -> ToolRoundOutcome
    func resolve(_ decision: ApprovalDecision, callID: String, hardwareConfirmed: Bool, visibleSince: Date?)
    func cancelAll()
    func undo(callID: String, messageID: UUID, store: ToolCallStore) async -> String?
    func stop(callID: String)
    // plus onAttentionNeeded and consumeContextNotes() (undo notes for the next user message)
}
@MainActor enum ToolCatalog {
    static func makeRegistry(settings: AppSettings, services: ActionServices,
                             extraTools: [any OttoTool] = []) -> ToolRegistry
}
struct ActionServices { static func live(processRunner: ProcessRunning) -> ActionServices; static let demo }
enum InputProvenance {                            // who pressed the key or clicked
    @MainActor static func evidence(for event: NSEvent?,
                                    mouseDown: (uptime: TimeInterval, isHardware: Bool)?) -> InputEvidence
}
```

**Permissions** (`Otto/Permissions/`):

```swift
enum Permission: Hashable, Codable { case accessibility, screenRecording, microphone, speechRecognition,
    calendars, reminders, notifications, automation(bundleID: String, appName: String) }
enum PermissionStatus { case granted, notDetermined, denied, restricted, limited, needsRelaunch, unavailable }
@MainActor protocol PermissionProviding: AnyObject {
    func status(_ permission: Permission) -> PermissionStatus
    @discardableResult func request(_ permission: Permission) async -> PermissionStatus
    func openSystemSettings(for permission: Permission)
    func waitForGrant(_ permission: Permission, timeout: Duration) async -> Bool
    var awaiting: PermissionWait? { get }
    func grantedPermissions() -> [Permission]
}
@MainActor @Observable final class PermissionsCenter: PermissionProviding {
    init(probe: PermissionProbe = SystemPermissionProbe(), defaults: UserDefaults = .standard,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         pollInterval: Duration = .seconds(1), relauncher: AppRelaunching = AppRelauncher())
    func relaunch()
    func resetSystemPermissions(using runner: ProcessRunning) async -> Bool   // tccutil reset All <bundle id>
}
```

Every transition to `.granted` posts `PermissionEvents.didGrant`; `EventKitService` and `CalendarGlance` reset
their `EKEventStore` on it. `AppRelauncher` starts a detached waiter that opens Otto again only after this
process has exited, so two copies never overlap.

**ChatSession** (`Otto/Chat/ChatSession.swift`, additions):

```swift
init(settings: AppSettings, makeClient: @escaping @MainActor () throws -> LLMClient,
     tools: ToolRegistry = ToolRegistry(), executor: ToolExecuting? = nil,
     permissions: PermissionProviding? = nil, isDemo: Bool = LaunchOptions.demo)
private(set) var conversationID: UUID
var onTranscriptChanged: ((TranscriptChange) -> Void)?        // History's single observer
func transcriptSnapshot() -> TranscriptSnapshot
func load(_ conversation: LoadedConversation)
private(set) var phase: ReplyPhase
private(set) var lastFinishedAssistantID: UUID?
weak var usageRecorder: UsageRecording?
var pendingApproval: PendingApproval? { get }
func resolveApproval(_ decision: ApprovalDecision, hardwareConfirmed: Bool, visibleSince: Date?)
private(set) var systemUIToolWait: SystemUIWait?
@discardableResult func regenerate() -> RegenerateOutcome
func showReplyVersion(_ index: Int)
func replaceLastTurn(text: String, attachments: [Attachment])
var onAssistantTextProgress: ((_ assistantID: UUID, _ text: String, _ isFinal: Bool) -> Void)?
```

**Notch** (`Otto/Notch/`): `NotchRoute` (`chat`, `history` shown as "Recents", `shelf`), `NotchOverlay`
(`shortcutSheet`), `NotchPrompt` (approval, permission or card; one at a time), `StayOpenHold`, `ModalHold`,
`CloseReason` (`user`, `pointerExit`, `outsideClick`, `programmatic`, `systemUI`), `NotchKeyCommand`,
`NotchKeyContext`, `SettingsTab`, `SettingsAnchor`. `NotchViewModel(settings:chat:services:)` takes a
`NotchServices` bundle; `nil` means `NotchServices.inert(settings:chat:)`, which uses in-memory stores and
monitors that never start. The view model adds holds, the fold, routes, the dock, approval visibility, the key
dispatcher (`keyContext(…)`, `perform(_:input:)`), editing, pin, tall mode, reading position, voice, context,
insert, drop, history, glance and action entry points. Snapshots seed all of it with
`debugSeed(features: NotchDebugSeed)`.

**The other modules**, by their entry types:

| Module | Entry types |
|---|---|
| Usage | `UsageRecording` (ChatSession records each completed request and partial usage on cancel), `ModelPricing`, `UsageLedger`, `CostFormatter` |
| History | `ConversationStore(.directory(URL) \| .inMemory)`, `HistoryController` (`start()`, `startFreshIfIdle`, `open/continue`, delete with undo, `onDataRemoved: HistoryRemoval`), `RecentsState`, `HistoryRetention` (7, 30, 90 days, forever), `IdleResetInterval` |
| Glance | `ReplyPhase`, `PhaseDebouncer`, `GlanceInputs` → `GlanceResolver.resolve` → `ClosedGlance`, `ClosedNotchLayout.make`, `ReplyPreview`, `ReplyNotificationDecider`, `NotificationPresenter`, `GlanceController` |
| Media | `MediaPlayer` (Music, Spotify), `NowPlayingMonitor`, `MediaScripting` (`LiveMediaScripting`, `DemoMediaScripting`), `MediaCommandOutcome`, `MediaControlTool(monitor:)` |
| Calendar glance | `CalendarEventSource` (`EventKitCalendarSource`, `InertCalendarSource`), `NextEventPicker`, `MeetingLinkDetector`, `CalendarGlance` |
| Shelf | `ShelfItem`, `DropZone`, `DropSession`, `ShelfStore` (directory or in-memory), `ShelfTileInteraction`, `ShelfTileHitArea`, `ShelfController` |
| Context | `AppRef`, `InsertMode`, `ServicesHandling`, `SelectionReading`/`WindowCapturing` (live and inert), `SensitiveApps`, `ContextSuggestions`, `InsertCoordinator` |
| Voice | `VoiceMode`, `VoicePhase`, `MicState`, `SpeechEngine` (`SFSpeechEngine`, `ScriptedSpeechEngine`), `VoiceInterruptionSource`, `SpeechChunker`, `ReplySpeaker`, `VoiceController` |
| Input | `HotKeyCombo`, `HotKeyManager(combo:onPress:onRelease:registrar:)`, `HotKeyRegistering`, `HoldGestureMachine`, `GlobalShortcutRouter`, `NotchNeighborMonitor`, `NotchKeyCommands`, `ReadingRestore` |
| Shared | `AppSupport`, `SecureFile`, `DisplayText`, `ObservationLoop`, `Theme.attention`, `Theme.recording`, `Theme.Motion.dock` |

**Settings storage** (`Otto/App/Settings/`). One `PreferenceStore` over `UserDefaults`; one
`@MainActor @Observable` group class per feature, reached as `settings.notch`, `.shortcuts`, `.voice`,
`.context`, `.shelf`, `.actions`, `.glance`, `.usage` and `.history`. Existing keys keep their names.

| Key | Default | Tab |
|---|---|---|
| `otto.notch.hoverToOpen`, `otto.notch.typeAfterHover` | on, on | Notch |
| `otto.shortcuts.hotKey` | ⌥Space | General |
| `otto.voice.enabled` | off | Voice |
| `otto.voice.holdShortcutToTalk`, `otto.voice.autoSend` | on, on | Voice |
| `otto.voice.locale`, `otto.voice.allowServerRecognition` | system, off | Voice |
| `otto.voice.spokenReplies`, `otto.voice.voiceIdentifier`, `otto.voice.speakingRate` | off, best, 0.5 (0.35…0.65) | Voice |
| `otto.context.offerSelection`, `otto.context.offerWindow`, `otto.context.restoreClipboard` | off, on, on | Context |
| `otto.shelf.enabled`, `otto.shelf.keepAfterDragOut` | on, off | Context |
| `otto.actions.enabled` | off | Actions |
| `otto.actions.groups` | every group except AppleScript | Actions |
| `otto.actions.maxToolRounds` | 10 (3…25) | Actions |
| `otto.actions.logFullScripts` | off | Actions |
| `otto.actions.safetyMode` | `safer` | Actions |
| `otto.glance.replyPreviews` | on | Notch |
| `otto.glance.notificationPolicy`, `otto.glance.notificationPreview` | never, on | Notch |
| `otto.glance.nowPlaying`, `otto.glance.nowPlayingClosed` | off, on | Notch |
| `otto.glance.calendarChip`, `otto.glance.calendarExcluded` | off, none | Notch |
| `otto.usage.showCost` | on | Models |
| `otto.history.enabled`, `otto.history.retention`, `otto.history.idleReset` | on, 30 days, 15 minutes | Privacy |
| `otto.actions.consents`, `otto.actions.rememberedApprovals` | none | Actions |

`otto.actions.safetyMode` picks how often Otto asks. `safer` is the behavior in sections 14 and 15. `fewerPrompts`
lets an "Always allow" shortcut run even after the chat read a web page, drops the web pause and doesn't fold for
tool runs; AppleScript still asks every time in both modes, and switching to it shows a confirmation that
explains prompt injection.

### 11. Open panel layout

Width stays `NotchMetrics.openWidth` (580). Height is at most `vm.openHeightLimit`: 560, or 80 % of the screen
in tall mode (suspended while the notch is folded for system UI). The pure helper `NotchLayout` computes the
conversation and dock heights.

```
HEADER        [orb] Otto [Opus 5 ⌄]  (or [‹] Recents / Shelf)        [pin?] [shelf?] [history] [⋮]
ATTENTION     "Otto needs your OK · View"   (a prompt is waiting and the page isn't Chat)
GLANCE ROW    [Now Playing strip] [● Standup · 12m]                   (Chat only)
PAGE  Chat:   conversation (or the ⌘/ sheet) · DOCK · Continue chip · edit banner · chips · composer · notice
      Recents: search · list · undo bar          Shelf: grid · action bar
```

- The conversation is at least 110 pt tall and at most 340 pt; in tall mode it fills the space.
- The dock is at most `min(300, openHeightLimit − chrome − 110)`; card bodies scroll inside it.
- The calendar chip lives in the glance row, not the header, which has no room next to the pebbles.

### 12. Closed notch

The closed shape stays pure black. `GlanceResolver` picks the first matching row:

| # | Condition | Left ear | Right ear | Below the camera |
|---|---|---|---|---|
| 1 | Voice listening or finishing | recording dot | live waveform | live caption pill |
| 2 | Waiting on system UI (folded) | orb, active | hourglass | "Waiting for System Settings…" and similar |
| 3 | Approval pending | orb, active | amber dot with a ring | "Needs your OK · ‹title›" |
| 4 | Paste flash, 1.4 s | orb | checkmark | |
| 5 | Reply preview, 4 s, pauses on hover | orb | speaking or unread dot | first line of the answer |
| 6 | Reply in progress | orb, active | thinking, searching or writing glyph | |
| 7 | Speaking after the reply | orb | three slow bars | |
| 8 | Unread reply | orb | unread dot | |
| 9 | Media playing, if shown in the closed notch | artwork | equalizer | |
| 10 | Nothing | | | |

`ClosedNotchLayout.make` sizes the shape: each ear adds 34 pt a side, a drop adds 28 pt of height (up to 380 pt
wide), the listening pill is at least 360 pt wide. `NotchGeometry.maximumClosedShapeSize` covers the largest of
these, so hit-testing follows the shape. A drop that grows under a resting pointer never hover-opens the notch.
The calendar chip never appears in the closed notch, and chat always wins over media.

### 13. Routes, the dock and the keyboard

- Opening always lands on Chat, except the Shelf drop and "Add to Otto Shelf" (land on Shelf) and "Recent
  Conversations…" (lands on Recents). `close()` and `newChat()` reset the route to Chat.
- The dock shows one `NotchPrompt`: a tool approval before a permission prompt before the head of the card
  queue. It renders only on Chat; on another page the attention capsule points back to it.
- While an approval is up the composer dims and reads "Waiting for your OK…"; typing still works.

The panel's key monitor applies three rules before mapping a key: any key stops speech; typing while
soft-focused engages the notch (a Return that engages is consumed and sends nothing); typing while listening
moves the transcript to the composer. Then `NotchKeyCommands.command(…)` maps the key, first matching row wins,
and `vm.perform(command, input: InputProvenance.evidence(…))` runs it.

| Key | Condition | Command |
|---|---|---|
| ⌘↩ ⌥⌘↩ ⌘R ⌘N ⌘1–3 ⌘⇧C ⌘. ⌥⌘J ⌘⌫ | soft focus only (not engaged) | give the keyboard back, do nothing else |
| Esc | in order: IME, listening, speaking, ⌘/ sheet, prompt, paste confirmation, editing, not on Chat | cancel voice, stop speech, close the sheet, decline or dismiss, cancel, cancel editing, back to Chat |
| Esc | otherwise | close (also unpins) |
| ↩ | listening · Recents · a non-approval card with an empty composer · a paste confirmation | send voice · open selected · card's primary button · confirm paste |
| ⌘↩ | a prompt is up | primary (an approval only when visible, armed and pressed on hardware) |
| ⌘↩ | Shelf · Chat with an empty composer and an answer to paste | ask about Shelf files · paste the last answer |
| ⌥⌘↩ | Chat, empty composer, an answer to paste | paste as plain text |
| ↑ / ↓ | Recents · Chat with an empty composer and a sent message | move selection · edit your last message |
| ⌘⇧↑ / ⌘⇧↓ | not while the composer has text | tall reading mode on / off |
| ⌘⌫, ⌫ | Recents | delete the conversation (⌫ only with an empty search) |
| ⌘. | | stop the reply, else stop listening, else stop speech |
| ⌘R · ⌘⇧C · ⌘/ · ⌘P | | regenerate · copy last reply · shortcut sheet · pin |
| ⌘1 ⌘2 ⌘3 | | Opus 5 · Sonnet 5 · Haiku 4.5 |
| ⌘Y · ⌘D · ⌘F · ⌘Z | Recents available · Shelf on · on Recents · on Recents after a delete | Recents · Shelf · search · undo the delete |
| ⌘N · ⌘, · ⌘W | | new chat · Settings · close |
| ⌘V | Shelf · Chat with a file on the clipboard | paste onto the Shelf · attach |
| ⌥⌘P ⌥⌘] ⌥⌘[ · ⌥⌘J · ⌥⌘U | Now Playing · a meeting chip · | play/pause, next, previous · join · usage details |

The Shelf grid handles its own arrows, Space (Quick Look), ⌘A, ⌘C, ⌥⌘R (Reveal in Finder), ⌫ and Return. The
global shortcut can never be one of these chords (`HotKeyProblem.conflictsWithOtto`).

### 14. Holds, the fold and approval visibility

```swift
var shouldStayOpen: Bool {   // hover-exit never closes while true
    isEngaged || isMenuPresented || isDropTargeted || pendingAttachmentLoads > 0 || isPinned || !stayOpenHolds.isEmpty
}
var isMenuPresented: Bool {  // outside clicks never close while true
    menuFlag || isPickingFiles || isCapturingScreen || !modalHolds.isEmpty
}
```

Hold sources: a voice session, the reply hold after a spoken question, dragging out of the Shelf, 1.5 s after a
Shelf drop, a paste in progress, a prompt that needs a decision, and the Share and Quick Look windows.

**The fold.** The open notch sits at `mainMenu + 3` and covers the top center of the screen, where System
Settings, macOS permission alerts and dialogs from an approved script open. So while Otto waits on system UI it
started (`systemUIWait`: a permission prompt, System Settings, an Automation prompt, or a script or shortcut that
has run for 1 s), the view model closes the notch with `.systemUI`. The closed notch shows row 2 of section 12.
When the wait ends and the notch is still closed, it reopens without taking the keyboard. Toggles in the Settings
window never fold the notch.

**Approval visibility.** `approvalVisibility` is stamped when the notch is open, not folded, on Chat, not hidden
for a capture, the approval is the current prompt, and its body was reviewed (it fits, or a long script was
scrolled to its end). The arming ring starts from that stamp. The executor accepts `.run` only when the input is
hardware (`InputProvenance.mayApprove`: event source pid 0, not an auto-repeat, pressed after the card armed),
`visibleSince` is set, and its own clock says the arming delay has passed. A ⌘↩ held down from pasting the last
answer can't approve a card that appears under it.

### 15. The tool loop and approvals

**Tools** (all `strict: true` and `eager_input_streaming: true` on the wire; the full schemas validate locally):

| Tool | Group | Asks | Permissions | Arming | Timeout |
|---|---|---|---|---|---|
| `calendar_list_events` | calendar | once ("Read your calendar") | Calendars | | 15 s |
| `calendar_create_event` | calendar | every call | Calendars | 0.35 s | 15 s |
| `reminders_list` | reminders | once ("Read your reminders") | Reminders | | 15 s |
| `reminders_create` | reminders | every call | Reminders | 0.35 s | 15 s |
| `list_shortcuts` | shortcuts | once ("See your shortcut names") | | | 15 s |
| `run_shortcut` | shortcuts | every call; "Always allow" per shortcut UUID | | 0.35 s | 60 s |
| `run_applescript` | appleScript | every call, never remembered | Automation for each running target | 1 s | 10 s |
| `open_url` | links | every call | | 0.35 s | 10 s |
| `media_control` | media | no card | Automation for the player | | 5 s |

**One turn.** `send` stores attachment blocks, then (only when tools are offered) a `<context>` block with the
local time and any undo notes, then the typed text. `beginAssistantTurn` captures a `TurnConfig`: model, effort,
web access, the available tools and their definitions, the system prompt with its Actions section, and the round
limit. Each response that stops with `tool_use` becomes a `ToolExchange`; the executor runs the round; every call
gets exactly one `tool_result`, all in one user message; the loop requests again and streams the final text into
the same assistant message. `max_tokens` and `refusal` never run tools. After the round limit the next request
sends `tool_choice: {"type":"none"}` and the reply ends with a short note.

**Web budget.** Web search and fetch run on Anthropic's side with no card, so each reply gets at most 10
searches and 10 fetches (`max_uses` at most 5 per request, the tool omitted at 0). Once the chat holds private
data and fresh untrusted content, the rest of that reply carries no server tools, and a row says why.

**Executor** (`ToolExecutor.execute(round, store:)`):

1. Assess trust (`TrustLedger`: which untrusted sources are in context, and how fresh) and collect private
   strings (`EchoDetector`).
2. Pre-check each call in model order: unknown tool, turned off, invalid JSON, schema, the tool's own
   `validate`, rate limit, decline fatigue (two declines in earlier rounds), `blockReason`. The first failure
   settles the call with a result.
3. Plan: missing permissions; a consent card the first time; an approval card every call, unless an "Always
   allow" scope may be honored. That needs all of: no fresh medium or high content, no echo of private data, no
   web page or search result anywhere in the chat, and every egress string of the input inside the user's latest
   message.
4. Phase A runs concurrency-safe calls that need no card or permission in parallel. Phase B runs the rest in
   order: permission card, then (for side effects) a fresh approval card, re-check availability, run with a
   timeout, normalize the output.
5. Every call is appended to the `ActionLog`, including blocked, limited and declined ones.

Arming: 0.35 s, or 1 s for scripts; under caution the delay doubles (at least 1 s) and the card shows a banner
("Otto read ‹source› just before asking."). An unanswered card expires after 10 minutes.

**History echo** (`ToolHistory`). Each exchange is split at `contentEnd`, signed thinking is kept verbatim, and
results go in their own user entry. Calls to tools not offered in this turn are downgraded to fenced data:
`<earlier_action_result tool="…" title="…" untrusted="true">…</earlier_action_result>`, with `&`, `<`, `>` and `"`
escaped so the result can't close its fence.

**Results Claude sees** start with a code: `declined:`, `timeout:`, `cancelled:`, `limit:`, `disabled:`,
`permission_denied:`, `invalid_input:`, `unknown_tool:`, `blocked:`. Successes are compact JSON with sorted keys
and a `"status"` field.

**Limits**

| Scope | Limit |
|---|---|
| Rounds per reply | 10 by default, 3…25 in Settings |
| Client tool calls per reply | 25 |
| Per tool, per reply and per rolling hour | `run_applescript` 3 / 20 · `run_shortcut` 5 / 30 · `open_url` 3 / 20 · create event or reminder 5 · reads 10 · `media_control` 6 / 60 |
| Approval wait | 10 minutes |
| Tool output | 16,000 characters, 4 images |
| Server tools per reply | 10 searches and 10 fetches |

**Scripts and links.** `AppleScriptAnalyzer` lexes the source (strings, comments, chevrons, continuations) and
joins concatenated string literals before it matches anything. It blocks administrator privileges, `run`/`load`/
`store script`, raw `«event»` syntax, AppleScriptObjC, `with hidden answer`, browser JavaScript, `sudo`, hidden or
bidi characters, more than 400 lines, lines over 300 characters and runs of hidden whitespace. It labels shell,
UI scripting and screen capture as danger. The card lists what the script inherits from Otto ("Runs with Otto's
access to: … macOS won't ask again"). `URLGuard` allows http and https only, parses numeric hosts the way browsers
do, blocks loopback, private, link-local, CGNAT and ULA ranges and local names, and opens the default browser
explicitly so a universal link can't hand the URL to another app.

**Demo tools.** With `--demo`, `--selftest` and `--snapshot`, `ActionServices.demo` fakes EventKit, Shortcuts,
osascript and the URL opener. `MockLLMClient` calls a tool only for exact phrases: "run my shortcut", "add … to my
calendar", "run a script".

### 16. Settings window

`SettingsPanel` is a non-activating `NSPanel` (`[.moveToActiveSpace, .fullScreenAuxiliary]`, floating) hosting an
`NSTabViewController` with one `SettingsView(settings:tab:services:)` per tab, 560 pt wide. `show(tab:anchor:)`
never activates Otto: it moves the panel to the pointer's screen and Space and scrolls to the anchor.
`openExternal(_:)` drops the panel to normal level before it opens System Settings or Finder, so the panel never
covers the switch it sent the user to.

| Tab | Contents |
|---|---|
| General | Keyboard shortcut recorder, launch at login, menu bar icon, custom instructions |
| Notch | Open on hover, type after hovering, reply previews, notifications, Now Playing, next event and calendars |
| Models | API key, model, response style, web search, cost on replies, usage totals |
| Context | Browser tab, selected text, the window you're using, clipboard restore, Services, Shelf |
| Actions | Master switch, one row per tool group, step limit, how Otto asks, approvals, activity log |
| Voice | Talk to Otto, hold to talk, send when I let go, language, spoken replies, voice and speed |
| Privacy | History, retention, idle reset, delete all, permissions, reset approvals, reset macOS permissions |
| License (paid and licensing-check builds) | License status, key entry, seats, Check Now, deactivation, updates (section 19) |

The General tab ends with `BuildInfoFooter` ("Otto {version} ({build}) · {flavor}") in every flavor, and in the Setapp
build with the Setapp updates section above it.

### 17. Security and privacy rules

- Every side effect is approved per call with an armed button and hardware input, except one named shortcut
  the user marked "Always allow", under the conditions in section 15. Scripts and links are never remembered.
- The card shows exactly what runs; the executor runs the validated input captured before the card appeared.
- Outside content (pages, search results, files, the browser tab, calendar text, tool output) is data. The
  system prompt says so, cards show where Otto read it, and fresh untrusted content raises the arming delay.
- `ProcessRunner` uses absolute paths, no shell, its own process group, a minimal environment without
  `ANTHROPIC_API_KEY`, capped output and a private temp directory.
- Paste-back posts ⌘V only for the user's own ⌘↩ or click, never under secure input, after re-checking the
  frontmost app; it strips control and escape characters, confirms multi-line pastes into terminals, and clears
  (never restores) a clipboard that held a password-manager item.
- Selection reading and window capture skip secure input, password fields and password managers.
- The microphone runs only inside a hold or toggle session, stops on lock, sleep or user switch, and a session
  ended by the watchdog never sends.
- Lock-screen notifications say only "Tap to open Otto."
- The activity log keeps titles, hosts and script fingerprints (first 200 characters and a SHA-256; full scripts
  only by opt-in), follows the History retention, and is cleared with History.

### 18. Tests, self-test and snapshots

Unit tests live in `OttoTests/` and use the fakes in `OttoTests/Support/` (`FakePermissionProvider`,
`FakeToolExecutor`, fake tools, `FakeProcessRunner`, `ScriptedLLMClient`, `ImageDiff`). No test touches the
user's data, TCC, Apple Events, real key events or hot keys, or the network.
`InputProvenanceProbeTests` is interactive and runs only with `OTTO_PROVENANCE_PROBE=1`.

`--selftest <dir>` keeps the eleven v1.0 steps and adds tool approval, deny, stop during approval, arming that
follows visibility, the calendar action with Undo, the fold, routes and the ⌘/ sheet, soft focus, key commands,
regenerate, pinned outside clicks, Settings on the current Space, scripted voice, Services, Shelf drops, drop
zones, a dry-run paste, the permission card, the glance, history, and real probes (signed builds only). The
watchdog is 420 s.

`--snapshot docs/snapshots` renders every scene through `NotchServices.inert` and `debugSeed(features:)` with
animations off. The committed scenes are `closed.png`, `closed-activity.png`, `open-empty.png`,
`open-chips.png`, `conversation.png`, `streaming.png`, `settings.png`, `closed-thinking.png`,
`closed-searching.png`, `closed-writing.png`, `closed-preview.png`, `closed-preview-failed.png`,
`closed-approval.png`, `closed-waiting.png`, `closed-media.png`, `closed-listening.png`, `open-glance.png`,
`open-anchored.png`, `conversation-cost.png`, `approval.png`, `approval-event.png`, `approval-applescript.png`,
`approval-applescript-long.png`, `approval-caution.png`, `permission.png`, `tool-cards.png`,
`open-shortcuts.png`, `open-editing.png`, `open-tall.png`, `open-listening.png`, `open-pinned.png`,
`card-voice.png`, `card-dictation.png`, `card-neighbor.png`, `open-selection.png`, `open-window-chip.png`,
`answer-insert.png`, `drop-zones.png`, `shelf.png`, `shelf-empty.png`, `recents.png`, `recents-search.png`,
`recents-empty.png`, `open-continue.png`, `open-history-notice.png`, and one per Settings tab:
`settings-general.png`, `settings-notch.png`, `settings-models.png`, `settings-context.png`,
`settings-actions.png`, `settings-voice.png`, `settings-privacy.png`. `SnapshotRegressionTests` diffs the scenes named in
`OTTO_SNAPSHOT_BASELINE` against `docs/snapshots` (at most 0.5 % of pixels may differ by more than 8/255).

The checks a person has to run on a signed build are the "v1.1 release gate" in
[`RELEASING.md`](RELEASING.md#v11-release-gate).

### 19. Licensing and updates (paid and Setapp builds)

Otto builds in more than one flavor from this one repository. The source build is what you get from GitHub and
compiles no license or update code. The paid build adds a 14-day trial, license keys and Sparkle updates, and the
Setapp build adds the Setapp Framework instead. The license is a convenience for honest buyers, not copy
protection: the source is MIT and free to build. So the license code never blocks launch, never deletes anything,
never shows a dialog, and never downgrades on an answer that could be an outage.

**Flavors.** These are the only four configurations.

| Flavor | Project (generated from) | Compile conditions | Bundle id | Licensing | Updates | Third-party code |
|---|---|---|---|---|---|---|
| source | `Otto.xcodeproj` (`project.yml`) | none (`DEBUG` in Debug) | `com.jalenedusei.otto` | none | `git pull` and rebuild | none |
| paid | `OttoPaid.xcodeproj` (`project-paid.yml`) | `OTTO_LICENSING OTTO_SPARKLE` | `com.jalenedusei.otto` | 14-day trial, Polar and Gumroad keys | Sparkle 2.10.0 | Sparkle |
| setapp | `OttoSetapp.xcodeproj` (`project-setapp.yml`) | `OTTO_SETAPP` | `com.jalenedusei.otto-setapp` | Setapp's | Setapp | Setapp Framework 5.5.0 |
| licensing check (development and CI only) | `Otto.xcodeproj` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG OTTO_LICENSING'` | `OTTO_LICENSING` | `com.jalenedusei.otto` | as paid | none | none |

- `project-paid.yml` and `project-setapp.yml` include `project.yml` and merge one pinned package, their compile
  conditions, their Info.plist keys and a pre-build check on top. Their Info.plist and entitlements are generated under
  `build/flavors/<flavor>/`, so generating a flavor project never changes a tracked file. `Otto.xcodeproj` never
  contains a package. Pins are exact; a version bump is its own PR.
- Each flavor builds into its own derived data (`build/paid`, `build/setapp`, `build/licensing`,
  `build/release/<flavor>/DerivedData`), so none of them overwrites the source build's `Otto.app`.
- Flavor code sits behind `#if OTTO_LICENSING`, `#if OTTO_SPARKLE`, `#if OTTO_SETAPP`, or `#if OTTO_SPARKLE ||
  OTTO_SETAPP` for the shared updates UI. Every file under `Otto/Licensing/`, `Otto/Updates/` and `Otto/Setapp/` is
  wrapped in its flag as a whole file, and so is every test file that needs a flag, because `project.yml` compiles all
  of `OttoTests/` into every project. `import Sparkle` and `import Setapp` appear only inside their flags.
- `OttoBuild` (`Otto/App/OttoBuild.swift`, compiled everywhere) names the flavor and its footer label and lists
  `allBundleIDs`. It refuses to compile Setapp together with licensing or Sparkle, and Sparkle without licensing.
- The flavor-neutral seams are compiled in every flavor and inert in the source build: `ComposerGate` and
  `ComposerGating`, `NotchServices.sendGate`, `UsageReportThrottle`, `StatusItemController.extraMenuItems` and
  `BuildInfoFooter`.
- The paid build shares the source build's bundle id on purpose: moving to the signed app keeps preferences, history
  and the API key, after one Keychain "Always Allow" prompt.

**Configuration.** `Config/Commercial.xcconfig` holds the paid and Setapp builds' public values (site host, support
email, Polar host, organization, benefit and portal slug, Gumroad product id or `none`, the Sparkle public key); secrets
never go there. `Config/Paid.xcconfig` and `Config/Setapp.xcconfig` include `Signing.xcconfig` and then it. Every value
still to be supplied is a `JALEN_MUST_SET_…` placeholder with a loud outcome, never an empty default:
`scripts/check_commercial_config.sh` runs as the flavor targets' pre-build phase and fails a Release build with one
`error:` line per problem, or warns in Debug. A Debug build with problems still runs: Settings → License shows them in a
banner and license requests are refused as `.misconfigured`, while the local trial keeps working.
`LicenseConfiguration.load(infoDictionary:)` re-validates the Info.plist values at run time with the same rules.
`scripts/audit_flavor.sh --flavor source|paid|setapp <Otto.app>` checks what a product may contain (linked frameworks,
API hosts in its strings, license and updater symbols, Info.plist keys, bundle id, the Setapp key, XPC services,
architectures); CI and `release.sh` call it instead of retyping the checks.

**Files.**

| File | Role |
|---|---|
| `Otto/Notch/ComposerGate.swift` | `ComposerGate` (one line above the composer, with up to two choices), `ComposerGating`, `ComposerGateError` |
| `Otto/App/UsageReportThrottle.swift` | at most one Setapp usage report per 300 s |
| `Otto/Licensing/LicenseContracts.swift` | records, outcomes, `LicenseBackend`, `LicenseHTTPTransport`, `LicenseStoring`, `LicenseScheduling`, configuration, `LicenseStatus`, `LicenseControlling` |
| `Otto/Licensing/LicensePolicy.swift` | pure status, check-outcome and clock rules |
| `Otto/Licensing/LicenseKeyRouter.swift` | key normalization, which store a key's shape belongs to, display keys, random "Mac XXXX" labels |
| `Otto/Licensing/LicenseCopy.swift` | every license string and the gate table, shared by the engine and the pane |
| `Otto/Licensing/StaticLicenseModel.swift` | a `LicenseControlling` for tests, snapshots and the self-test |
| `Otto/Licensing/LicenseConfiguration+Load.swift` | reads and validates the Info.plist values |
| `Otto/Licensing/LicenseController.swift` | the engine: status, scheduling, activation, checks, deactivation, the trial |
| `Otto/Licensing/KeychainLicenseStore.swift`, `InMemoryLicenseStore.swift` | the live store and the one demo, `--license-state` and tests use |
| `Otto/Licensing/URLSessionLicenseTransport.swift`, `TaskLicenseScheduler.swift` | the live HTTP and timer seams |
| `Otto/Licensing/PolarAPI.swift`, `PolarLicenseBackend.swift` | Polar's customer-portal license endpoints |
| `Otto/Licensing/GumroadAPI.swift`, `GumroadLicenseBackend.swift` | Gumroad's `verify` endpoint |
| `Otto/Licensing/LicenseBackends.swift` | builds the enabled backends, Polar first |
| `Otto/Updates/UpdateContracts.swift` | `UpdaterControlling`, `PendingUpdate`, `StaticUpdaterModel` |
| `Otto/Updates/SparkleUpdater.swift` | Sparkle in the paid build |
| `Otto/Updates/SetappUpdater.swift`, `Otto/Setapp/SetappBridge.swift` | Setapp's pending-update API, usage events and release notes |
| `Otto/UI/Chat/ComposerGateLine.swift` | the gate line |
| `Otto/UI/Settings/LicensePane.swift`, `UpdatesSection.swift`, `BuildInfoFooter.swift` | Settings → License, the updates section, the General footer |

**Contracts** (trimmed like section 10):

```swift
@MainActor protocol ComposerGating: AnyObject {        // nil gate = sending allowed; only the paid build installs one
    var composerGate: ComposerGate? { get }
    func handleGateAction(_ id: String)                 // "check-now"
}
enum LicenseStatus {
    case trial(endsAt: Date, daysLeft: Int), trialEnded(endedAt: Date)
    case licensed(LicenseSummary)                                     // last good check ≤ 30 days ago
    case licensedCheckOverdue(LicenseSummary, sendingPausesAt: Date)  // 30 to 44 days
    case licensedCheckRequired(LicenseSummary)                        // more than 44 days
    case unavailable(LicenseStoreError)                               // Keychain unreadable: fail open
    var allowsSending: Bool { get }                                   // false only for trialEnded and licensedCheckRequired
}
protocol LicenseBackend: Sendable {                    // one per merchant: Polar, Gumroad
    func activate(key: String, label: String, existing: LicenseRecord?) async -> Result<LicenseRecord, LicenseActivationError>
    func validate(_ record: LicenseRecord) async -> LicenseCheckOutcome        // .valid, .gone(reason), .unavailable(reason)
    func deactivate(_ record: LicenseRecord) async -> LicenseDeactivationOutcome
}
@MainActor protocol LicenseControlling: ComposerGating {
    var status: LicenseStatus { get }; var activity: LicenseActivity { get }
    var lastMessage: LicenseMessage? { get }; var lastRemoval: LicenseRemoval? { get }
    var configuration: LicenseConfiguration { get }
    func activate(key: String); func checkNow(); func deactivate(); func removeFromThisMac(); func dismissMessage()
}
@MainActor protocol UpdaterControlling: AnyObject {    // SparkleUpdater, SetappUpdater, StaticUpdaterModel
    var source: UpdateSource { get }; var allowsUserSettings: Bool { get }
    var automaticallyChecks: Bool { get set }; var automaticallyDownloads: Bool { get set }
    var canCheckNow: Bool { get }; var lastCheck: Date? { get }; var pendingUpdate: PendingUpdate? { get }
    func start(); func checkNow(); func installPendingUpdate(); func showReleaseNotes()
}
```

`LicenseController(configuration:store:backends:scheduler:now:uptime:randomLabel:notificationCenter:)` takes every
seam, so its tests run on `InMemoryLicenseStore`, fake backends and a manual scheduler with no network, Keychain or
clock. The fakes live in `OttoTests/Support/LicenseFakes.swift`.

**Status.** `LicensePolicy.status` is pure. It uses `e = max(now, trial.lastSeenAt)`, so setting the clock back never
extends anything.

| Keychain records | Status | Sending |
|---|---|---|
| the license can't be read | `.unavailable` | allowed (fail open; Settings says why) |
| a license checked ≤ 30 days ago | `.licensed` | allowed |
| a license checked 30 to 44 days ago | `.licensedCheckOverdue` | allowed, with a quiet line in Settings |
| a license checked more than 44 days ago | `.licensedCheckRequired` | paused until a check succeeds |
| no license, no trial record | `.trial` (the first `start()` writes the record) | allowed |
| no license, trial started less than 14 days ago | `.trial(daysLeft:)` | allowed |
| no license, trial over | `.trialEnded` | paused |
| no license, an unreadable trial item | a trial dated from the item's Keychain creation date | allowed until that date plus 14 days |

A license removed during the trial window returns the Mac to its trial for the days that are left. A trial is created
once, on the first `start()` of a live paid build, and never reset. Nothing is deleted when sending pauses: Settings,
Recents and demo mode keep working.

**Checks.** With a license present, a background check runs 10 s after `start()`, 30 s after a wake and on an hourly
tick, each only when the last attempt is at least 24 h old, so a Mac makes at most one background request a day.
**Check Now** runs at once unless the last attempt was less than 60 s ago. `LicensePolicy.apply` handles the outcome:

- `.valid` sets `lastValidatedAt` and clears any pending revocation.
- `.unavailable` (offline, timeout, rate limit, server error, a refused API version, a misconfigured build, a record that
  doesn't match the build) only records the attempt. It never touches `lastValidatedAt` or a pending revocation.
- `.gone` never acts alone. The first one records a pending revocation; a second at least 20 h later deletes the license
  item and records why in the trial record.

**Activation.** `LicenseKeyRouter.normalize` strips spaces and line breaks (mail clients wrap keys) and keeps case. A
Polar-shaped key (`OTTO-<UUID>` or a bare UUID) goes only to Polar and a Gumroad-shaped key (four groups of 8 hex digits)
only to Gumroad; a key of neither shape tries Polar, then Gumroad. The activation label is "Mac" and 4 random hex
digits, never the Mac's name. A Polar key entered while a Polar license is on this Mac is first tried as a rotated key on
the existing activation, which keeps the seat. Activation also works while a revocation is pending, so a buyer who
rotated a key can enter the new one. Deactivation frees the Polar seat; Gumroad can't free a seat from a client, so it
removes the license locally and points to support.

**Clock.** `trial.lastSeenAt` is a high-water mark of the wall clock. It moves only through
`LicensePolicy.nextLastSeen`, called from the hourly tick and `stop()`, and only when at least 5 minutes of
`CLOCK_MONOTONIC` uptime passed since the previous sample and the wall clock advanced by the same amount within 2
minutes. A wrong boot date that the network clock corrects a few minutes later is never saved.

**Polar.** `POST https://<host>/v1/customer-portal/license-keys/{activate,validate,deactivate}` with a JSON body and
exactly `Content-Type`, `Accept`, `Accept-Language: en`, `Polar-Version: 2026-10` and `User-Agent: Otto/<version>`. The
bodies carry only the key, the organization, the benefit, the activation id and (on activate) the label; customer
fields in the answers are never decoded. Only a 404 that echoes `polar-version` and says `"error":"ResourceNotFound"`
counts as "gone". Any other 404 (a removed API version looks like this) is retried once without the pin, and otherwise
is `.unavailable(.versionRefused)`, so Polar's version rotation can't switch licenses off. A record keeps the host and
IDs it was activated under and every later check sends those. When the build's own IDs differ, a "gone" answer becomes
`.unavailable(.recordMismatch)` with a `.fault` log, so a mistyped ID in a later release can't turn existing licenses
off. `release.sh` probes the pin and validates a canary key with the IDs it is about to build.

**Gumroad.** `POST https://api.gumroad.com/v2/licenses/verify`, form-encoded, always with an explicit
`increment_uses_count` (Gumroad's default is true). Seats are 3 times the purchase quantity; a key counted once on this
Mac (a SHA-256 of product id and key in the `gumroad-counted` item) is never counted again. Refunded, charged-back and
disabled keys read as "gone"; email, name and every other purchase field are never decoded. 1.1.0 ships with
`OTTO_GUMROAD_PRODUCT_ID = none`, which refuses Gumroad keys with a message that names support. Lemon Squeezy, if it's
ever needed, is one more `LicenseBackend` file; a backend is never removed while keys it issued are in use.

**Keychain.** Service `com.jalenedusei.otto` for every flavor, generic passwords in the login keychain like the API key,
values as JSON through `KeychainStore.write(_:account:service:)` and `readResult(account:service:)`. Keychain Access shows
each item as "Otto (<account>)".

| Account (production · every other build) | Holds |
|---|---|
| `license` · `license.sandbox` | `LicenseRecord` |
| `trial` · `trial.sandbox` | `TrialRecord` |
| `gumroad-counted` · `gumroad-counted.sandbox` | the Gumroad keys already counted on this Mac |

Only a build configured for Polar's production API with no problems uses the plain names, so a Debug build, the
licensing-check build and a misconfigured build never read, validate, delete or advance a production record on the same
Mac. Items are never synchronizable, so they never sync through iCloud Keychain. Deleting `Otto.app` leaves them, which
is how the trial survives a reinstall. An unreadable item is never overwritten, and values are never logged.

**App surfaces.**

- **Gate line.** On the Chat page, above the composer, `ComposerGateLine` (30 pt) shows why sending is paused:
  `trial-ended` ("Your 14-day trial has ended."), `license-removed`, `check-required`, and the `checking` and
  `activating` states. While it's up, send, Regenerate, Retry and a voice auto-send return early and keep the draft,
  chips and transcript, and the line pulses once. Insert, copy, Recents, the Shelf, Settings and approvals inside a
  turn that already started are never blocked. `AppComposition` also wraps `makeClient` so a request that starts under
  a gate throws `ComposerGateError`. Nothing else checks the license.
- **Settings → License** is the last tab (`checkmark.seal`) in the paid and licensing-check builds. Top to bottom:
  the problems banner, status, a pending-revocation line, the key field and **Activate**, and for a licensed Mac
  **Check Now**, **Deactivate This Mac…** (Polar) or **Remove from This Mac…** (Gumroad) and **Manage Macs in
  Polar…**. Then come the last message, the Terms, Privacy and Refunds links, and in the paid build the updates
  section. With no license model (demo) the tab says licenses aren't checked.
- **Status menu.** The paid build appends "License…" (or "Enter License…" while sending is paused), "Check for
  Updates…" and, while an update waits, "Install Otto {version}…". The Setapp build appends only the install item.
- **General footer.** `BuildInfoFooter`: "Otto {version} ({build}) · built from source", "signed app" or "Setapp",
  plus " · demo".
- **Graphs.** `--demo`, `.inert()` and snapshot graphs build no license controller and no updater. The self-test uses a
  `StaticLicenseModel`, and step 22 checks the gate. No flavor shows a price in the app.
- **Debug flags** (paid flavor and the licensing-check build): `--license-state
  trial|trial-last-day|ended|removed|licensed|overdue|required|keychain-error` runs the live controller on an
  `InMemoryLicenseStore` seeded for that state, and `--license-clock-offset <hours>` shifts the controller's clock
  without ever advancing `lastSeenAt`.

**Sparkle (paid).** SPM, `exactVersion: 2.10.0`, linked only by `project-paid.yml`. The feed is
`https://<OTTO_SITE_HOST>/appcast.xml`, checked once a day. The archive and the feed are both EdDSA-signed
(`SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`); system profiling and JavaScript are off. `SparkleUpdater`
owns an `SPUStandardUpdaterController`, sets `httpHeaders` to `Accept-Language: en` before it starts, maps the two
Settings toggles to Sparkle's own settings and uses gentle reminders: a background update shows only in Settings →
License and the status menu, never in the closed notch. Requests carry `User-Agent: Otto/<version> Sparkle/2.10.0` and
nothing that identifies the user or the Mac. The paid build isn't sandboxed, so `release.sh` removes Sparkle's XPC
services and signs `Autoupdate`, `Updater.app`, `Sparkle.framework` and then `Otto.app` in Sparkle's documented order.

**Setapp.** SPM, `exactVersion: 5.5.0`, linked only by `project-setapp.yml`; bundle id `com.jalenedusei.otto-setapp`;
`Config/Setapp/setappPublicKey.pem` is copied into the bundle. `SetappBridge.reportInteraction(now:)` reports a usage
event when the notch becomes engaged or a message is sent, at most once per 5 minutes. `SetappUpdater` asks Setapp for a
pending update 30 s after launch, every 6 hours and when Settings → General appears, then offers "Update and
Relaunch…". The Setapp build has no trial, license keys, License tab, Sparkle, "Buy a License" or pricing links. It
keeps the user's own Anthropic key and never routes prompts through Setapp. It shares Otto's data folder and Keychain
service with the direct build but not its preferences, and the launch guard (section 8) allows one Otto of any flavor
at a time.

**Network.** The source build contacts none of these.

| Destination | When | Flavor |
|---|---|---|
| `api.polar.sh` (`sandbox-api.polar.sh` in Debug) | activate, deactivate, at most one background check a day, Check Now | paid |
| `api.gumroad.com` | the same, only for a Gumroad key | paid |
| `<site host>/appcast.xml` | at most once a day, and Check Now | paid |
| the downloads host (Vercel Blob) | when an update downloads | paid |
| Setapp, through the Setapp app | a usage event at most every 5 minutes while in use | setapp |

Every license and update request uses an ephemeral `URLSession` (no cookies, cache or credentials) and pins
`Accept-Language: en`, so none carries the Mac's language list. Logs use the categories `License`, `Updates` and
`Setapp` and carry the backend, operation, outcome name and HTTP status, never a key, activation id, label or email.

**Tests.** The source suite keeps passing with no flag. Flag-only tests (`LicensePolicyTests`, `LicenseControllerTests`,
`PolarLicenseBackendTests` and the rest) run in the licensing-check and paid builds; `SparkleUpdaterTests` and
`UpdatesSectionTests` run only in the paid build. `KeychainLicenseStoreTests` runs only with `OTTO_KEYCHAIN_TESTS=1`,
against a `com.jalenedusei.otto.tests.<UUID>` service, and `PolarSandboxLiveTests` only with
`OTTO_POLAR_SANDBOX_TESTS=1` and sandbox credentials. `scripts/snapshot.sh --licensing` and `--paid` render the license
and updates scenes into `docs/snapshots/licensing/` and `docs/snapshots/paid/`; the Setapp build has no snapshots,
because its framework starts at launch. CONTRIBUTING.md lists the commands.
