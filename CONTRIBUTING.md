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

**Signing.** Builds are ad hoc signed by default. macOS ties Keychain access and the Accessibility and
Screen Recording grants to the app's code signature, and an ad hoc signature changes with every build. So
an ad hoc build asks for Keychain access again after each rebuild and silently loses Accessibility (paste,
selection) and Screen Recording (window chip, screen capture), even though the switches in System Settings
still look on. If you work on any of those features, sign with a stable identity by creating
`Config/Local.xcconfig` (git-ignored):

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = ABCDE12345
```

If a grant still looks stuck after switching identities, remove Otto from the list in **System Settings →
Privacy & Security** and add it again, or use **Settings → Privacy → Reset macOS Permissions for Otto…**.
On macOS 15 and later, ScreenCaptureKit may also ask you to confirm window access again from time to time;
that is macOS, not a bug in Otto.

Never commit `Config/Local.xcconfig` or anything containing a team ID, certificate or API key.

**Services.** Otto adds three items to the Services menu (**Send Selection to Otto**, **Send Files to Otto**,
**Add to Otto Shelf**). macOS only picks up a new or changed Services entry after it rescans. For a build that
isn't in /Applications, run:

```sh
/System/Library/CoreServices/pbs -update
```

Launching a copy from /Applications also works. The self-test calls the Services provider directly, so it
doesn't depend on this.

**One Otto at a time.** A second copy of Otto waits up to 3 s for the first to quit. If it doesn't, a normal
launch asks the running copy to open its notch and then quits; a `--demo` launch keeps running but doesn't
register the global shortcut (its data lives apart, in `~/Library/Application Support/Otto/Demo`).
`scripts/run.sh` stops any running Otto first, including one in /Applications. If you start a build some
other way, quit your everyday Otto first if you want the build you're testing to own the shortcut.

## Project layout

```
Otto/
├── App/          entry point, AppDelegate, AppComposition (builds every object), launch options,
│                 hot key and shortcut router, menu bar item, Settings window, AppSettings and its
│                 per-feature groups in Settings/, AppSupport (the data folder), Services provider
├── Notch/        NotchPanel, NotchWindowController (event monitors, keyboard, focus),
│                 NotchPointerMachine (pure hover/click-through/drag state machine), NotchGeometry,
│                 NotchKeyCommands (the key map), NotchViewModel and its feature extensions
├── Chat/         Models (shared contract types), ChatSession (conversation, streaming, tool loop), SystemPrompt
├── API/          AnthropicClient (HTTPS + SSE), SSEParser, StreamAccumulator, MockLLMClient, KeychainStore
├── Tools/        OttoTool, ToolRegistry, ToolExecutor, approvals, trust and echo checks, rate limits,
│                 ActionLog, ProcessRunner, ToolCatalog
├── Actions/      Calendar/ (EventKit tools) and Scripting/ (Shortcuts, AppleScript, URLGuard)
├── Permissions/  PermissionsCenter: the only code that checks or requests macOS permissions
├── Context/      attachments, browser tab, screen capture, selection, window capture, paste-back
├── Voice/        speech engine, level meter, chunker, spoken replies, VoiceController
├── History/      conversation store, titles, search, HistoryController, Recents
├── Glance/       phase debounce, closed-notch resolver, reply preview, notifications, calendar chip
├── Media/        Now Playing monitor and the media_control tool
├── Shelf/        File Shelf store, ingest, thumbnails, drag, sharing, Quick Look
├── Usage/        pricing, usage ledger, cost formatting
├── Licensing/    paid build only: trial, Polar and Gumroad license keys, Keychain records, LicenseController
├── Updates/      the updater seam, SparkleUpdater (paid build) and SetappUpdater (Setapp build)
├── Setapp/       Setapp build only: SetappBridge (usage events, release notes)
├── UI/           SwiftUI views: notch shape, clay theme, dock cards, pages, chat, glance, voice,
│                 Settings panes, composer, conversation, Markdown
└── Debug/        Debug-build-only tools: SnapshotRenderer (--snapshot), SelfTest (--selftest),
                  the promo stage and stills (--promo, --promo-stills) behind the launch media
OttoTests/        XCTest unit tests; shared fakes in OttoTests/Support/
scripts/          build.sh, run.sh, snapshot.sh, make_icon.swift, release.sh, publish.sh, make_media.sh
                  (+ video tools), audit_flavor.sh, check_commercial_config.sh; their tests in scripts/tests/
Config/           Signing.xcconfig (+ your git-ignored Local.xcconfig); Commercial.xcconfig, Paid.xcconfig
                  and Setapp.xcconfig for the paid and Setapp builds
project*.yml      project.yml (Otto.xcodeproj); project-paid.yml and project-setapp.yml add one package each
docs/             SPEC.md (architecture & design spec), RELEASING.md, snapshots/, media/
```

[`docs/SPEC.md`](docs/SPEC.md) describes every module's interface and behavior, plus the visual
language. Read the section for the area you're changing before you start. The shared contract types
(`JSONValue`, `Attachment`, `ChatMessage`, `StreamEvent`, `LLMClient`, `NotchMetrics`, …) live in
`Otto/Chat/Models.swift`. Change them carefully; many modules depend on them. The 1.1 modules
(sections 6 to 19 of the spec) keep their shared types in one contracts file each, such as
`Otto/Tools/ToolContracts.swift` and `Otto/Notch/NotchContracts.swift`.

## Coding conventions

- **Swift 5 language mode** with `SWIFT_STRICT_CONCURRENCY=minimal`. Mark UI and state classes
  `@MainActor`.
- **Observation, not Combine.** State objects use `@Observable`; views take them as `@Bindable var` or
  `let`.
- **Apple frameworks only in shared code.** No new third-party dependencies. The only packages are Sparkle
  (paid build) and the Setapp Framework (Setapp build), and code that uses them stays behind
  `#if OTTO_SPARKLE` or `#if OTTO_SETAPP`.
- **No force-unwraps** on anything that can fail at runtime.
- **Log with `os.Logger`** (subsystem `com.jalenedusei.otto`, a category named after the module, such as
  `Tools`, `Voice` or `History`, plus `License`, `Updates` and `Setapp` in those builds), never `print`. Never
  log API keys, license keys, activation IDs, license labels or email addresses. Anything the user wrote or
  Otto read (prompts, replies, tool inputs and outputs, file paths, selections, event titles) is logged only
  with `privacy: .private`; ids, counts, statuses and error codes can be `.public`.
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
  requested only when the user first uses the feature that needs them. Check and request permissions only
  through `PermissionsCenter`, write files only through `SecureFile` into an `AppSupport` directory, and pass
  any text from outside Otto that you display through `DisplayText.sanitized(_:maxLength:)`.
- **Ask before side effects.** Anything Claude can do that changes something goes through `ToolExecutor`
  and an approval card that shows exactly what will run. Don't add a path that skips it.
- **Keep seams testable.** New system access goes behind a protocol with a default live implementation and
  an inert or fake one, so no test touches TCC, Apple Events, real hot keys, the network or the user's
  data.
- **Match the look.** New UI follows the clay theme in `Otto/UI/Theme.swift` and the look & feel section of
  the spec.
- **Keep copy honest.** User-facing text and docs describe only what the app actually does today.

## Tests and tools

Run the unit tests:

```sh
xcodegen generate
xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test
```

Add or update tests in `OttoTests/` for any behavior you change. Every module has focused tests to
extend, and `OttoTests/Support/` has shared fakes: a permission provider, a tool executor, sample tools, a
process runner and a scripted LLM client. Use `UserDefaults(suiteName:)` and a temporary directory; a test
must never touch your real settings, history, permissions or apps.

Two tests are skipped unless you ask for them:

- `InputProvenanceProbeTests` is interactive. It shows a small window and asks you to click, press
  <kbd>⌘</kbd><kbd>↩</kbd>, and run an `osascript` line, then records which input came from hardware. Run it
  on a real Mac with `TEST_RUNNER_OTTO_PROVENANCE_PROBE=1 xcodebuild … test
  -only-testing:OttoTests/InputProvenanceProbeTests`.
- `SnapshotRegressionTests` renders the snapshot scenes and compares the ones you name with the PNGs in
  `docs/snapshots/`: `TEST_RUNNER_OTTO_SNAPSHOT_BASELINE=closed,approval xcodebuild … test
  -only-testing:OttoTests/SnapshotRegressionTests`.

Two built-in tools help with UI work. Like everything in `Otto/Debug/`, they're compiled into Debug builds
only, so run them from `scripts/build.sh` output:

- **Snapshots.** `scripts/snapshot.sh` builds the app and renders the notch in fixed states into
  `docs/snapshots/`. They cover the closed notch in each glance state, the open notch with chips, a
  conversation, streaming, approval and permission cards, voice, Recents, the Shelf, and every Settings tab
  (the full list is in section 18 of [`docs/SPEC.md`](docs/SPEC.md)). Run it before and after a visual change and
  compare the PNGs. Include before/after images in your PR. It renders into a temporary folder and copies
  into `docs/snapshots/` only after a clean run, so a failed run leaves the old pictures as they were. If the
  renderer crashes or times out, the script tries again in a fresh process, three runs in all
  (`OTTO_SNAPSHOT_ATTEMPTS` changes that). To skip the build, point `OTTO_SNAPSHOT_BINARY` at a Debug
  `Otto` binary you already built.
- **Self-test.** `build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto --selftest <dir>` drives the
  real notch on screen through a scripted session (open, type, send, stream, close mid-reply, reopen,
  attach files, then approvals, the fold, voice, Recents, the Shelf and more) and checks the pointer logic
  against the live notch geometry. It runs on demo services and temporary stores, writes `report.json`
  and PNG captures into `<dir>` and exits `0` only if every step passed. It never moves your pointer or
  touches other apps. Keyboard-focus checks are skipped while the screen is locked, and the real-probe step
  reports "skipped" on an ad hoc signed build.

When you're done, make sure no Otto process is left running (`pkill -x Otto`).

**Testing licensing.** The trial, license keys and updaters compile only into the paid and Setapp builds, so
the test run above skips them. Run these when you change anything under `Otto/Licensing/`, `Otto/Updates/` or
`Otto/Setapp/`, or any code behind `OTTO_LICENSING`, `OTTO_SPARKLE` or `OTTO_SETAPP`:

```sh
# The licensing-check build: Otto.xcodeproj with the license code compiled in and no packages
xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/licensing \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG OTTO_LICENSING' test

# The paid build with Sparkle, then the Setapp build with the Setapp Framework
xcodegen generate --spec project-paid.yml
xcodebuild -project OttoPaid.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/paid test
xcodegen generate --spec project-setapp.yml
xcodebuild -project OttoSetapp.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/setapp build
```

Each flavor builds into its own folder under `build/`, so none of them replaces the source build's `Otto.app`.
The first flavor build downloads its one pinned package. If the paid test host refuses to load an ad hoc
signed `Sparkle.framework`, add `ENABLE_HARDENED_RUNTIME=NO` to that command, as CI does. A Debug flavor build
prints a warning for every `JALEN_MUST_SET` placeholder in `Config/Commercial.xcconfig`, and a Release build
with one fails. Both are on purpose, so never replace a placeholder with a made-up value. A Debug paid build
checks keys against the Polar sandbox, and every build that isn't fully configured for Polar's production API
keeps its license and trial in separate `.sandbox` Keychain items, so a development build never touches a real
license on the same Mac. `--license-state` shows any license state without the Keychain at all. Two tests are opt-in: the Keychain
store test runs with `TEST_RUNNER_OTTO_KEYCHAIN_TESTS=1`, and the live Polar sandbox test with
`TEST_RUNNER_OTTO_POLAR_SANDBOX_TESTS=1` plus the sandbox IDs and key named in its header. If you change the
flavor specs, `Config/` or the release scripts, also run the script tests
(`for t in scripts/tests/*_test.sh; do bash "$t"; done`) and `scripts/audit_flavor.sh --flavor source` on a
source Release build.

The license code is public on purpose. Please don't open issues or pull requests that make it harder to get
around: the source is free to build.

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
- [ ] New permissions, tools or data on disk are covered in the README's privacy section and, if a
      person has to check them on a real Mac, in the release gate in `docs/RELEASING.md`.
- [ ] No new third-party dependencies, force-unwraps, `print` calls or placeholder code were added.
- [ ] No secrets, team IDs or personal data are included.
- [ ] `README.md`, `docs/SPEC.md` and `CHANGELOG.md` (under **Unreleased**) are updated where relevant.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE). The signed Otto app that will be sold as a one-time purchase is built from this
same repository, so a merged contribution can ship in it.
