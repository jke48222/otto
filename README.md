# Otto

**Hides in your notch. Shows up when you need it.**

Otto is a native macOS assistant that lives in the MacBook notch. Hover the notch (or press
<kbd>⌥</kbd><kbd>Space</kbd>) and it springs open into a dark, finely textured panel with a composer and
context chips for files, images, screenshots and the browser tab you are looking at. Messages go to Claude
through the Anthropic Messages API, and the reply streams straight into the notch. Close it and Otto
folds back into the camera housing, with a small glow on the notch while a reply is still coming in.

On Macs without a notch (or on an external display) Otto draws a virtual notch at the top center of
the screen.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- Xcode 16 or later, with the command line tools selected (`xcode-select -p`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Anthropic API key, unless you only want to try demo mode

There are no third-party dependencies. The app uses only Apple frameworks.

## Build and run

```sh
scripts/build.sh            # xcodegen generate + xcodebuild (Debug) → build/Build/Products/Debug/Otto.app
scripts/run.sh              # build, stop any running Otto, launch the new build
scripts/run.sh --demo       # canned replies, no API key or network needed
scripts/run.sh --demo --open
scripts/snapshot.sh         # build, then render UI snapshots into docs/snapshots/
```

`Otto.xcodeproj` is generated from `project.yml` and is not checked in. To work in Xcode, run
`xcodegen generate` and open the project. The build signs with your "Apple Development" identity. If
there is none (or you set `OTTO_ADHOC_SIGNING=1`), `build.sh` signs ad hoc instead.

### Launch options

| Flag | Effect |
| --- | --- |
| `--demo` | Uses the built-in mock client: a scripted, streamed reply with thinking, a web search and sources. |
| `--open` | Opens the notch, focused, right after launch. |
| `--snapshot <dir>` | Renders PNG snapshots of the UI in fixed states into `<dir>`, then quits. |
| `--selftest <dir>` | Drives the real notch on screen through a scripted demo session (open, type, send, stream, close mid-reply, reopen, attach files) and checks the pointer logic against the live notch geometry. Writes `report.json` and PNG captures into `<dir>`, then quits with status 0 only if every step passed. Keyboard-focus checks are reported as skipped while the screen is locked. |

Pass launch options with `scripts/run.sh <flags>` or `open Otto.app --args <flags>`.

## API key

Open **Settings** from the ⋮ button in the notch, from the menu bar icon, or with <kbd>⌘</kbd><kbd>,</kbd>
while the notch is focused. Paste your key from
[console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) and click **Save**.
Otto stores the key in your login Keychain (service `com.jalenedusei.otto`) and never writes it to
disk anywhere else. If you have not added a key yet, Settings opens automatically the first time Otto
launches.

If there is no key in the Keychain, Otto falls back to the `ANTHROPIC_API_KEY` environment variable.
Apps started from Finder or `open` do not inherit your shell's environment, so to use the variable you
need to run the binary directly:

```sh
ANTHROPIC_API_KEY=sk-ant-… build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto
```

Settings also has the model picker (Claude Opus 5, Sonnet 5, Haiku 4.5), response style, web search and
fetch, browser-tab suggestions, the global shortcut, the menu bar icon, launch at login and custom
instructions.

## Using Otto

- **Open:** rest the pointer on the notch for a moment, click it, press <kbd>⌥</kbd><kbd>Space</kbd>, or choose
  **Open Otto** from the menu bar icon. A notch opened by hovering closes again when the pointer leaves.
  Once you click into it or type, it stays open until you dismiss it.
- **Attach context:** drag files, images or links onto the notch (dragging onto the closed notch opens
  it). You can also use the **+** menu (Attach Files…, Capture Screen Region, Paste from Clipboard), or
  paste with <kbd>⌘</kbd><kbd>V</kbd>. When you are in Safari or a Chromium-based browser, Otto offers
  the current tab as a dashed chip. Click it to attach the tab.
- **Send:** type and press <kbd>Return</kbd>, or click the ↑ button. While a reply streams, the same
  button stops it.
- **Dismiss:** <kbd>Esc</kbd>, click anywhere outside the panel, or <kbd>⌥</kbd><kbd>Space</kbd>.

### Shortcuts

| Shortcut | Where | Action |
| --- | --- | --- |
| <kbd>⌥</kbd><kbd>Space</kbd> | anywhere | Open and focus Otto, or close it when it is already focused |
| <kbd>Return</kbd> | composer | Send |
| <kbd>Esc</kbd> | notch | Close |
| <kbd>⌘</kbd><kbd>N</kbd> | notch | New chat |
| <kbd>⌘</kbd><kbd>V</kbd> | notch | Paste. Files and images become chips; text goes into the composer. |
| <kbd>⌘</kbd><kbd>,</kbd> | notch | Settings |
| <kbd>⌘</kbd><kbd>W</kbd> | notch | Close |

You can turn off <kbd>⌥</kbd><kbd>Space</kbd> in Settings. Otto registers the shortcut exclusively: if
another app already holds <kbd>⌥</kbd><kbd>Space</kbd> exclusively, Settings shows a message, and apps
that try to take it after Otto cannot. macOS cannot detect an app that registered the same shortcut
*non-exclusively* before Otto started (some launchers do this). If <kbd>⌥</kbd><kbd>Space</kbd> opens
the other app instead of Otto, change the shortcut in that app, or turn Otto's shortcut off in
Settings and open Otto from the notch or the menu bar icon.

## Permissions

Otto asks only for what a feature needs, and only when you first use that feature:

- **Automation (Apple Events), per browser:** Otto asks the first time you open it by click or shortcut
  (or click into a notch that opened on hover) while Safari, Chrome, Arc, Brave, Edge, Vivaldi or Opera is
  frontmost. The notch stays open while the dialog is up. It reads only the front tab's title and address.
  If you decline, Otto skips tab suggestions. You can change this later in
  System Settings → Privacy & Security → Automation. With **Attach tab automatically** on, only tabs the
  browser reports as being in a normal (non-private) window are attached on their own; Safari can't report
  that, so Safari tabs are always offered as a suggestion you tap instead.
- **Screen Recording:** only for **Capture Screen Region**, which uses the system `screencapture` tool. If it
  isn't allowed yet, Otto asks macOS to show the request and tells you where to turn it on
  (Privacy & Security → Screen & System Audio Recording); reopen Otto afterwards.
- **No Accessibility permission** is needed. The global shortcut uses the Carbon hot-key API, and the notch
  only watches mouse movement to decide when to open.

Otto is a menu bar–style accessory app. It has no Dock icon, and you quit it from the menu bar icon or the
⋮ menu.

## Architecture

The full build spec, including every module interface, is in [`docs/SPEC.md`](docs/SPEC.md).
The shared contract types (`JSONValue`, `Attachment`, `ChatMessage`, `StreamEvent`, `LLMClient`,
`NotchMetrics`…) live in `Otto/Chat/Models.swift`.

```
Otto/
├── App/        entry point, AppDelegate, launch options, ⌥Space hot key, menu bar item,
│               Settings window, AppSettings (UserDefaults + Keychain)
├── Notch/      NotchPanel (borderless non-activating panel), NotchWindowController (event monitors,
│               keyboard, focus), NotchPointerMachine (pure hover/click-through/drag state machine),
│               NotchGeometry, NotchViewModel (notch state)
├── Chat/       Models (shared contract), ChatSession (conversation + streaming), SystemPrompt
├── API/        AnthropicClient (HTTPS + SSE), SSEParser, StreamAccumulator, MockLLMClient, KeychainStore
├── Context/    AttachmentLoader (files, images, PDFs, pasteboard, drops), BrowserContext, ScreenCapture
├── UI/         SwiftUI views: notch shape, clay theme, chips, composer, conversation, Markdown, Settings
└── Debug/      SnapshotRenderer (--snapshot), SelfTest (--selftest)
```

How a message flows through the app:

1. **Shell.** `AppDelegate` builds the object graph. `NotchWindowController` places a fixed-size,
   transparent panel over the notch and toggles `ignoresMouseEvents` as the pointer moves, so the panel
   takes clicks only over the drawn shape. Everywhere else, clicks go through to the menu bar and apps.
2. **State.** `NotchViewModel` owns what the notch shows: whether it is open, the composer text, the
   attachments and the suggested tab. `ChatSession` owns the conversation. It builds each
   `MessagesRequest`, consumes `StreamEvent`s and handles refusals, `pause_turn` and fallbacks.
3. **API.** `AnthropicClient` streams `POST /v1/messages` over `URLSession.bytes`. `SSEParser` and
   `StreamAccumulator` fold the server-sent events into text, thinking, tool activity and sources.
4. **UI.** `NotchRootView` renders the notch and animates between its closed and open states.

Tests live in `OttoTests/` and run with
`xcodebuild -project Otto.xcodeproj -scheme Otto -derivedDataPath build test`.

## App icon

`Otto/Assets.xcassets/AppIcon.appiconset` is generated. To change the icon, edit
`scripts/make_icon.swift` and regenerate every size and `Contents.json`:

```sh
swift scripts/make_icon.swift
```
