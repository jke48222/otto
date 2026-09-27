# Contributing to Otto

Thanks for helping make Otto better. Bug reports, ideas, docs fixes and code are all welcome. This guide
gets you from a fresh clone to a merged pull request.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Please report security
issues privately, as described in [SECURITY.md](SECURITY.md), not in public issues.

## Before you start

- **Found a bug?** Search [existing issues](https://github.com/jke48222/otto/issues) first, then
  [file a bug report](https://github.com/jke48222/otto/issues/new?template=bug_report.yml).
- **Have an idea?** [Open a feature request](https://github.com/jke48222/otto/issues/new?template=feature_request.yml)
  before writing a large change, so we can agree on the approach. Small fixes can go straight to a PR.
- **Check the roadmap** in the [README](README.md#roadmap) to see what's already planned.

## Set up

You need macOS 14 or later, Xcode 16 or later (with its command line tools selected:
`xcode-select -p`) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/jke48222/otto.git
cd otto
scripts/run.sh --demo --open
```

`--demo` swaps in a scripted mock client, so you can work on almost everything without an API key or a
network connection. To use the real API, add your key in Settings or set `ANTHROPIC_API_KEY` (see the
README).

`Otto.xcodeproj` is generated from `project.yml` and is not checked in. To work in Xcode, run
`xcodegen generate` and open the project. Re-run it whenever you add, move or delete files.

**Signing.** Builds are ad hoc signed by default. To sign with your own identity, which stops the
Keychain access prompt after every rebuild, create `Config/Local.xcconfig` (git-ignored):

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = ABCDE12345
```

Never commit `Config/Local.xcconfig` or anything containing a team ID, certificate or API key.

## Project layout

```
Otto/
├── App/        entry point, AppDelegate, launch options, ⌥Space hot key, menu bar item,
│               Settings window, AppSettings (UserDefaults + Keychain)
├── Notch/      NotchPanel, NotchWindowController (event monitors, keyboard, focus),
│               NotchPointerMachine (pure hover/click-through/drag state machine),
│               NotchGeometry, NotchViewModel
├── Chat/       Models (shared contract types), ChatSession (conversation + streaming), SystemPrompt
├── API/        AnthropicClient (HTTPS + SSE), SSEParser, StreamAccumulator, MockLLMClient, KeychainStore
├── Context/    AttachmentLoader, AttachmentBudget, HTMLText, BrowserContext, ScreenCapture
├── UI/         SwiftUI views: notch shape, clay theme, chips, composer, conversation, Markdown, Settings
└── Debug/      Debug-build-only tools: SnapshotRenderer (--snapshot), SelfTest (--selftest),
                the promo stage and stills (--promo, --promo-stills) behind the launch media
OttoTests/      XCTest unit tests
scripts/        build.sh, run.sh, snapshot.sh, make_icon.swift, release.sh, make_media.sh (+ video tools)
Config/         Signing.xcconfig (+ your git-ignored Local.xcconfig)
docs/           SPEC.md (architecture & design spec), snapshots/, media/
```

[`docs/SPEC.md`](docs/SPEC.md) describes every module's interface and behavior, plus the visual
language. Read the section for the area you're changing before you start. The shared contract types
(`JSONValue`, `Attachment`, `ChatMessage`, `StreamEvent`, `LLMClient`, `NotchMetrics`, …) live in
`Otto/Chat/Models.swift`. Change them carefully; many modules depend on them.

## Coding conventions

- **Swift 5 language mode** with `SWIFT_STRICT_CONCURRENCY=minimal`. Mark UI and state classes
  `@MainActor`.
- **Observation, not Combine.** State objects use `@Observable`; views take them as `@Bindable var` or
  `let`.
- **Apple frameworks only.** No third-party dependencies (AppKit, SwiftUI, Observation, Carbon, PDFKit,
  UniformTypeIdentifiers, ServiceManagement, Security, ImageIO, CoreImage and friends).
- **No force-unwraps** on anything that can fail at runtime.
- **Log with `os.Logger`** (subsystem `com.jalenedusei.otto`), never `print`. Never log API keys, message
  contents or attachment data.
- **File headers.** Every Swift file starts with the standard header comment:
  ```swift
  //
  //  FileName.swift
  //  Otto
  //
  ```
- **Finished code only.** No placeholder stubs or `TODO`s. Comment the non-obvious *why*, not the
  obvious *what*.
- **Keep the main thread free.** File loading, AppleScript and networking run off the main actor.
- **Privacy by default.** Nothing leaves the Mac until the user presses send, and new permissions are
  requested only when the user first uses the feature that needs them.
- **Match the look.** New UI follows the clay theme in `Otto/UI/Theme.swift` and the look & feel section of
  the spec.
- **Keep copy honest.** User-facing text and docs describe only what the app actually does today.

## Tests and tools

Run the unit tests:

```sh
xcodegen generate
xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test
```

Add or update tests in `OttoTests/` for any behavior you change. The request builder, stream parser,
chat session, attachment loading, Markdown parser, notch geometry and pointer state machine all have
focused tests to extend.

Two built-in tools help with UI work. Like everything in `Otto/Debug/`, they're compiled into Debug builds
only, so run them from `scripts/build.sh` output:

- **Snapshots.** `scripts/snapshot.sh` builds the app and renders the notch in fixed states (closed,
  activity, open, chips, conversation, streaming, Settings) into `docs/snapshots/`. Run it before and after
  a visual change and compare the PNGs. Include before/after images in your PR.
- **Self-test.** `build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto --selftest <dir>` drives the
  real notch on screen through a scripted session (open, type, send, stream, close mid-reply, reopen,
  attach files) and checks the pointer logic against the live notch geometry. It writes `report.json`
  and PNG captures into `<dir>` and exits `0` only if every step passed. It never moves your pointer or
  touches other apps. Keyboard-focus checks are skipped while the screen is locked.

When you're done, make sure no Otto process is left running (`pkill -x Otto`).

Maintainers build release disk images with `scripts/release.sh`; see the header of that script for its
options. Contributors don't need it.

## Pull requests

1. Fork the repo and create a branch from `main` (for example `fix/hover-close-delay`).
2. Keep each PR focused on one change. Separate refactors from behavior changes.
3. Write clear commit messages in the imperative mood ("Fix hover close on external displays").
4. Open the PR and fill in the template.

### PR checklist

- [ ] `scripts/build.sh` succeeds with no new warnings.
- [ ] The unit tests pass, and new behavior has tests.
- [ ] UI changes include before/after snapshots (`scripts/snapshot.sh`).
- [ ] Notch interaction changes were checked with `--selftest` or by hand on a notched display
      and, if possible, a display without a notch.
- [ ] No third-party dependencies, force-unwraps, `print` calls or placeholder code were added.
- [ ] No secrets, team IDs or personal data are included.
- [ ] `README.md`, `docs/SPEC.md` and `CHANGELOG.md` (under **Unreleased**) are updated where relevant.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE). The signed Otto app that will be sold as a one-time purchase is built from this
same repository, so a merged contribution can ship in it.
