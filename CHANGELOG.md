# Changelog

All notable changes to Otto are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-09-30

The first tagged source release, and the build the signed app ships from. It includes everything in the
1.0.0 notes below, which were prepared but never tagged. Otto's source code is MIT licensed; the signed,
notarized app is a one-time purchase.

### Added

- **Actions.** With **Settings → Actions** on, Claude can read and add calendar events and reminders, list
  and run your Shortcuts, play, pause and skip in Music and Spotify, and open web links. AppleScript is a
  separate opt-in. Every change shows a card with exactly what will run (the full script, the event, the
  link) and runs only after you press <kbd>⌘</kbd><kbd>↩</kbd> on this Mac's keyboard or click, once the
  card has been on screen long enough to read. Reads ask once. Added events and reminders have Undo for 10
  minutes. "Always allow" is offered for a named shortcut only. A **How Otto asks** setting chooses between
  **Safer** (the default) and **Fewer prompts**.
- **Activity log** of every action Otto ran, blocked or skipped, with titles and hosts but no inputs or
  outputs, in **Settings → Actions → Activity Log…**.
- **Permissions in one place.** Otto explains each macOS permission in the notch before macOS asks, folds
  the notch out of the way while a macOS dialog or System Settings is open, and comes back when you're done.
  **Settings → Privacy** lists every permission with its status.
- **Ask about your selection** through **Services → Send Selection to Otto**, or an optional chip that offers
  the text you've selected when you open the notch. **Send Files to Otto** and **Add to Otto Shelf** are in
  the Services menu too.
- **Paste the answer back.** <kbd>⌘</kbd><kbd>↩</kbd> pastes the last answer into the app you came from, or
  replaces the text you asked about; <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↩</kbd> pastes plain text. Otto asks
  before a multi-line paste into a terminal and puts your clipboard back afterwards.
- **Window chip.** Otto offers a picture of the window you were working in; nothing is captured until you
  click it.
- **File Shelf.** Drop files on the left half of the notch to keep them, then drag them out, share them,
  Quick Look them or ask about them. <kbd>⌘</kbd><kbd>D</kbd>.
- **History.** Conversations are saved on your Mac (30 days by default), with Recents
  (<kbd>⌘</kbd><kbd>Y</kbd>), search, delete with undo, a Continue chip after an idle fresh start, and your
  reading position kept when you come back.
- **Voice.** Hold your shortcut or the mic button to talk, or click to start and stop. Speech is turned into
  text on your Mac; replies can be read aloud.
- **Glanceable closed notch.** Ears show whether Otto is thinking, searching or writing, waiting for your OK,
  or waiting on System Settings, and a finished reply drops a one-line preview under the camera. Hover the
  preview to keep it on screen, or click it to open that answer. Notifications for replies and approvals are
  optional.
- **Now Playing** strip and closed-notch artwork for Music and Spotify, with play, pause and skip.
- **Next-meeting chip** with the time until it starts and <kbd>⌥</kbd><kbd>⌘</kbd><kbd>J</kbd> to join.
- **Cost and usage.** Each reply's estimated cost on hover, and totals by day, month and model in
  **Settings → Models**.
- **Keyboard essentials.** <kbd>⌘</kbd><kbd>.</kbd> stops, <kbd>⌘</kbd><kbd>R</kbd> regenerates (with
  versions to flip between), <kbd>↑</kbd> edits and resends your last message,
  <kbd>⌘</kbd><kbd>⇧</kbd><kbd>C</kbd> copies the last reply, <kbd>⌘</kbd><kbd>1</kbd> to
  <kbd>⌘</kbd><kbd>3</kbd> switch models, and <kbd>⌘</kbd><kbd>/</kbd> lists every shortcut.
- **Type after hovering.** Rest the pointer on the open notch and type; move away and the keyboard goes back
  to your app.
- **Pin open** (<kbd>⌘</kbd><kbd>P</kbd>) and **tall reading mode**
  (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>↑</kbd>).
- **Custom global shortcut**, a switch to turn off hover-to-open, and a one-time note when another notch
  app is running.
- **The signed app:** a 14-day trial, license keys from Polar and Gumroad, Settings → License, and updates
  through Sparkle.
- **A build for Setapp.**
- License checks and Sparkle compile only into those builds. The source build is unchanged and still uses
  only Apple frameworks.

### Changed

- **Settings** is a tabbed window (General, Notch, Models, Context, Actions, Voice, Privacy) that opens on
  the Space you're on, over full-screen apps, without switching Spaces.
- The header shows a model menu, and the ⋮ menu adds Recent Conversations, Shelf, Regenerate, Pin Open, Tall
  Reading Mode, Keyboard Shortcuts and a usage summary for today and this month. The menu bar icon adds
  **Recent Conversations…** and **Shelf…**.
- Accessibility is still never needed to open Otto or chat. It's asked for only when you first paste an
  answer into another app or turn on **Offer selected text**.
- Only one copy of Otto runs at a time. A second copy hands over to the one already running.

### Security

- Approval cards accept only hardware input pressed after the card armed, counted from when the card was
  actually on screen. Input posted by other apps, auto-repeat and a key held down from an earlier action are
  ignored.
- AppleScript is read with a real lexer. Scripts that ask for administrator privileges, build code at run
  time, use raw Apple event codes or AppleScriptObjC, ask for hidden text, run browser JavaScript or hide
  content with invisible characters or long lines are blocked. The card lists the access a script inherits
  from Otto.
- Links open only over http and https in your default browser, and never to local network addresses,
  however the address is written.
- Web search and page reading are capped at 10 each per reply, and pause for the rest of a reply once the
  chat holds both private data and fresh web content.
- Otto's data folder refuses symlinks and folders it doesn't own, is readable only by you, keeps Spotlight
  out with `.noindex` folder names, and is excluded from Time Machine. Files are written with mode 0600.
- Notifications on the lock screen say only "Tap to open Otto." A password copied from a password manager is
  cleared after a paste instead of being put back. Browser tab titles can no longer close the block that
  wraps them in the prompt.

### Release gate

Results of the [v1.1 release gate](docs/RELEASING.md#v11-release-gate) are recorded here before `v1.1.0` is
tagged: one line per check, pass or fail, with the macOS version and build number it ran on.

Automated checks, macOS 27.0 (26A5378j), Otto 1.1.0 (2):

- Full test suite: 1,873 tests, 0 failures, 2 opt-in tests skipped. Pass.
- Self-test while signed in at the Mac: 33 of 33 steps, no checks skipped. Pass.
- Gate H1, input provenance (Debug build, 2026-09-27): hardware click and ⌘↩ carry pid 0, the System
  Events ⌘↩ doesn't. Pass.
- Signed paid build: notarized and stapled, Gatekeeper reports "Notarized Developer ID", and the disk
  image smoke test launches the app. Pass.
- Polar production and sandbox license API with real keys: activate, validate, deactivate, activate
  again, a fourth Mac refused, a wrong benefit refused. Pass.
- The app's Polar sandbox round trip (`OTTO_POLAR_SANDBOX_TESTS=1`): activate, validate, deactivate.
  Pass.

## 1.0.0 (prepared, never tagged)

### Added

- **Notch panel.** Rest the pointer on the notch, click it, or press <kbd>⌥</kbd><kbd>Space</kbd>
  and Otto springs open into a dark, finely textured panel. A notch opened by hovering tucks itself
  away when the pointer leaves, and stays open once you click in or type. Clicks outside the drawn shape
  pass straight through to your apps and the menu bar.
- **Virtual notch** at the top center of the screen on Macs and displays without a notch. Otto follows
  display changes automatically.
- **Chat with Claude** through the Anthropic Messages API, with replies streaming into the notch. Stop a
  reply at any time, retry a failed or stopped one, copy any reply, and start fresh with
  <kbd>⌘</kbd><kbd>N</kbd>.
- **Model choice:** Claude Opus 5 (default), Claude Sonnet 5 and Claude Haiku 4.5, plus a response style
  (Quick, Balanced, Thorough) for Opus and Sonnet. Opus 5 can finish a reply on a fallback model if it's
  overloaded.
- **Web search and page reading** with source pills you can click to open, and a live activity row
  while Claude searches.
- **Visible thinking:** a "Thinking…" indicator while Claude reasons, then a collapsible "Thought
  process" (Opus 5 and Sonnet 5).
- **Rich Markdown** with headings, nested lists, quotes, links, selectable text and fenced code blocks
  with a language label and copy button. Incomplete Markdown renders cleanly mid-stream.
- **Context chips** for files, images, PDFs, text and source code, RTF and Word documents, HTML and web
  archives: drag them onto the notch (even when it's closed), paste them with <kbd>⌘</kbd><kbd>V</kbd>,
  or use the **+** menu. Up to 10 items per message; large images are downscaled automatically.
- **Capture Screen Region** from the **+** menu to attach a screenshot.
- **Current browser tab suggestion** for Safari and Chromium-based browsers (Chrome, Arc, Brave, Edge,
  Vivaldi, Opera): a dashed chip you click to attach the page's title and address. Optionally attach it
  automatically for tabs in normal (non-private) windows.
- **Activity glow:** close Otto mid-reply and the notch grows small ears, a breathing orb and a live
  equalizer, then a warm dot when an unread reply is ready.
- **Settings:** API key (stored in the Keychain), model, response style, web search & fetch, browser-tab
  suggestions, the <kbd>⌥</kbd><kbd>Space</kbd> shortcut, menu bar icon, launch at login and custom
  instructions.
- **Menu bar icon** with Open Otto, New Chat, Settings… and Quit Otto.
- **Privacy:** nothing leaves the Mac until you press send, and then only to the Anthropic
  API. No account, no telemetry, no Otto server. Permissions (Automation per browser, Screen Recording)
  are requested only when a feature first needs them. No Accessibility permission required.
- **Demo mode** (`--demo`) with a scripted, streamed reply, so you can try Otto without an API key.
- **Developer tools:** `--open`, `--snapshot <dir>` UI renders and an on-screen `--selftest <dir>`
  that verifies the live notch, plus unit tests for the API client, stream parsing, chat session,
  attachments, Markdown, geometry and pointer handling.

[Unreleased]: https://github.com/jke48222/otto/commits/main
