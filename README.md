<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="Otto app icon">
</p>

<h1 align="center">Otto</h1>

<p align="center">
  <strong>The AI assistant that lives in your notch.</strong><br>
  Hover the notch, ask anything, get back to work.
</p>

<p align="center">
  <a href="https://github.com/jke48222/otto/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/jke48222/otto/ci.yml?branch=main&label=tests&color=ECEAE6&labelColor=0C0C0D" alt="Build and test status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-ECEAE6?labelColor=0C0C0D" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-5-ECEAE6?labelColor=0C0C0D" alt="Swift 5">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/jke48222/otto?color=ECEAE6&labelColor=0C0C0D" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#build-from-source"><strong>Build from source (free)</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/jke48222/otto/subscription"><strong>Signed app coming soon: watch releases</strong></a>
  &nbsp;·&nbsp;
  <a href="docs/media/otto-promo.mp4">Watch the film</a>
</p>

<p align="center">
  <sub>Source code free under the MIT license · signed app coming soon as a one-time purchase · macOS 14 Sonoma or later · uses the Claude API (bring your own Anthropic key)</sub>
</p>

<p align="center">
  <a href="docs/media/otto-promo.mp4">
    <img src="docs/media/otto-hero.gif" width="880" alt="Otto opening from the MacBook notch, answering a question with web sources, then tucking itself away">
  </a>
  <br>
  <sub>Click the loop to watch the full promo video.</sub>
</p>

<p align="center"><a href="#get-started">Get started</a> · <a href="#everyday-use">Everyday use</a> · <a href="#privacy--permissions">Privacy</a> · <a href="#limits-and-known-issues">Limits</a> · <a href="#faq">FAQ</a> · <a href="#build-from-source">Build from source</a></p>

---

## What is Otto?

Otto turns the black notch at the top of your MacBook into a place to ask Claude things. Rest your
pointer on the notch and it opens with a composer, the file you just dropped in, and the page you're
reading. Get your answer, move the pointer away, and it tucks back into the camera housing.

It's a native Mac app written in Swift with SwiftUI and AppKit and no third-party dependencies. It talks
to the Anthropic API directly with your own key.

## Why I built it

I kept leaving what I was doing to ask Claude a quick question, and the notch was the one part of the
screen I never used. The hard part was making it open when you mean it and not when you're heading
for a menu. The hover, click and drag logic became a small state machine with its own 24 unit tests,
and a hover only counts once the pointer rests for 90 ms.

## Highlights

### One glance away

Hover the notch or press <kbd>⌥</kbd><kbd>Space</kbd> from any app. Otto opens right where you're
already looking and folds away when you're done.

<p align="center">
  <img src="docs/media/screens/ask.png" width="820" alt="Otto open under the notch: the browser tab On Calm Software attached as a chip and “Summarize this in 3 bullets” typed into the composer">
</p>

### Knows what you're looking at

Drop in files, images, PDFs and screenshots, or paste them with <kbd>⌘</kbd><kbd>V</kbd>. Reading
something in your browser? Otto offers the current tab as a chip: one click and Claude can read the
page with you.

<p align="center">
  <img src="docs/media/screens/context.png" width="820" alt="Context chips for a browser tab, an image, a PDF and a text file above the composer">
</p>

### Answers that stream in

Replies arrive as they're written, right in the notch. Claude can search the web and cite its sources,
you can open its thought process, and replies render as Markdown with a copy button on every code
block.

<p align="center">
  <img src="docs/media/screens/answer.png" width="820" alt="Otto’s answer to “Summarize this in 3 bullets”: the page read and web search it ran, three bullets, and source pills for each site it used">
</p>

### Keeps working while you do

Close Otto mid-answer and the reply keeps coming. The notch grows two small ears: a breathing orb and
a live equalizer while Claude writes, then a warm dot when your answer is ready.

<p align="center">
  <img src="docs/media/screens/glance.png" width="820" alt="The closed notch while Otto keeps writing: a breathing orb on the left and three equalizer bars on the right, shown magnified below">
</p>

### Your key, your Mac

Your API key lives in the macOS Keychain. Nothing leaves your Mac until you press send, and then it
goes straight to Anthropic. There's no account, no Otto server and no telemetry.

<p align="center">
  <img src="docs/media/screens/settings.png" width="560" alt="Otto Settings: the Anthropic API key saved in Keychain, the Claude model picker and the response style">
</p>

## Get started

Today you build Otto from source. It's free and takes a few minutes.

1. **Install** Xcode 16 or later from the App Store, then open it once.
2. **Install** XcodeGen: `brew install xcodegen`.
3. **Build and open** Otto with the commands in [Build from source](#build-from-source).
4. **Add your API key.** Settings opens on first launch. Create a key at
   [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys), paste it in and
   click **Save**.
5. **Hover the notch** and ask.

A signed and notarized build is coming soon as a one-time purchase, so you won't need Xcode. To hear
when it ships, open the repo's [notification settings](https://github.com/jke48222/otto/subscription),
choose **Custom**, check **Releases** and click **Apply**.

> [!TIP]
> Otto has no Dock icon. It lives in the notch, with a small menu bar icon as a second way in.

## Everyday use

| To… | Do this |
| --- | --- |
| **Open Otto** | Rest the pointer on the notch for a beat, click it, or press <kbd>⌥</kbd><kbd>Space</kbd>. You can also pick **Open Otto** from the menu bar icon. |
| **Keep it open** | Click into it or start typing. A notch opened by hovering closes when your pointer leaves; once you engage, it stays until you dismiss it. |
| **Add context** | Drag files, images or links onto the notch (dragging onto the closed notch opens it), or paste with <kbd>⌘</kbd><kbd>V</kbd>. |
| **Use the + menu** | **Attach Files…**, **Capture Screen Region**, **Paste from Clipboard**, and **Attach Current Tab** when you're in a browser. |
| **Ask about a web page** | In Safari or a Chromium-based browser, Otto shows the current tab as a dashed chip. Click it to attach the page. |
| **Send / stop** | Press <kbd>Return</kbd> or click ↑. While a reply streams, the same button stops it. |
| **Copy or retry** | Hover a reply for **Copy** and, if something went wrong, **Retry**. The ⋮ menu has **Copy Last Response**. |
| **Start over** | <kbd>⌘</kbd><kbd>N</kbd>, or **New Chat** in the ⋮ menu. |
| **Dismiss** | <kbd>Esc</kbd>, click anywhere outside Otto, or press <kbd>⌥</kbd><kbd>Space</kbd> again. |

Otto reads images (PNG, JPEG, GIF, WebP, HEIC, TIFF and more), PDFs, plain text and source code, CSV,
JSON, RTF and Word documents, HTML files and web archives. You can attach up to 10 items per message,
and large images are downscaled before they're sent.

### Keyboard shortcuts

| Shortcut | Where | Action |
| --- | --- | --- |
| <kbd>⌥</kbd><kbd>Space</kbd> | Anywhere | Open Otto and focus the composer, or close it |
| <kbd>Return</kbd> | Composer | Send |
| <kbd>Esc</kbd> | Otto | Close |
| <kbd>⌘</kbd><kbd>W</kbd> | Otto | Close |
| <kbd>⌘</kbd><kbd>N</kbd> | Otto | New chat |
| <kbd>⌘</kbd><kbd>V</kbd> | Otto | Paste: files and images become chips, text goes into the composer |
| <kbd>⌘</kbd><kbd>,</kbd> | Otto | Settings |

You can turn <kbd>⌥</kbd><kbd>Space</kbd> off in Settings. If another app already uses it, see the
[FAQ](#faq).

## Privacy & permissions

Otto asks only for what a feature needs, and only when you first use that feature. It never needs
Accessibility access.

| Permission | Why | When you'll see it |
| --- | --- | --- |
| **Automation** (per browser) | Reads the **title and address** of your front browser tab, so Otto can offer it as a chip. Nothing else. | The first time you open Otto by click or shortcut while Safari, Chrome, Arc, Brave, Edge, Vivaldi or Opera is in front. Decline and Otto skips tab suggestions. |
| **Screen Recording** | Lets **Capture Screen Region** take the screenshot you select. | Only when you use Capture Screen Region. Allow it in **Privacy & Security → Screen & System Audio Recording**, then reopen Otto. |

**What leaves your Mac, and when.** Only when you press send, Otto sends your message, the items you
attached, your custom instructions and the current conversation directly to `api.anthropic.com` over
HTTPS. A suggested browser tab isn't sent unless you attach it, and then only its title and address.
When web search or fetch is on, Claude runs those searches on Anthropic's side.

**What stays.** Your API key is stored in your login Keychain and nowhere else. Conversations live in
memory and are gone when you start a new chat or quit. Otto has no analytics, no crash reporting, no
account and no server of its own. How Anthropic handles API data is covered by
[Anthropic's privacy policy](https://www.anthropic.com/legal/privacy).

## Choosing a model

Pick a model in **Settings → Model**. You can switch at any time; the next message uses the new
choice.

| Model | Best for | Notes |
| --- | --- | --- |
| **Claude Opus 5** (default) | The hardest questions | Shows its thought process. If it's overloaded, Anthropic can finish your reply on a fallback model. |
| **Claude Sonnet 5** | Everyday questions, faster | Shows its thought process. |
| **Claude Haiku 4.5** | Quick lookups at the lowest cost | Web search only (no page fetch); no thinking or response style. |

**Response style** (Quick, Balanced, Thorough) sets how much effort Claude puts in. Quick is faster
and uses fewer tokens; Thorough takes longer and thinks harder.

**What it costs to run.** Claude usage is billed to your Anthropic account at
[Anthropic's API rates](https://www.anthropic.com/pricing), per token, and web searches add a per-search
fee. Haiku and the Quick style cost the least, and Otto uses prompt caching so follow-up questions in the
same chat cost less. You can set spend limits in the [Anthropic Console](https://console.anthropic.com).

## Limits and known issues

- **No signed download yet.** For now you build Otto from source with Xcode. The signed, notarized app
  is coming soon as a one-time purchase.
- **Keychain prompts after rebuilds.** Source builds are ad hoc signed, so macOS asks again whether Otto
  may read its Keychain item after each rebuild. Click **Always Allow**, or sign with your own identity
  (see [Build from source](#build-from-source)).
- **No saved history.** Conversations stay in memory and are gone when you quit or start a new chat.
- **The shortcut is fixed.** <kbd>⌥</kbd><kbd>Space</kbd> can be turned off but not changed yet, and some
  launchers hold it in a way Otto can't detect.
- **Browser tabs:** Safari and Chromium-based browsers (Chrome, Arc, Brave, Edge, Vivaldi, Opera) only.
  Firefox isn't supported.
- **Haiku 4.5** can search the web but can't fetch pages, and doesn't show a thought process.
- **Needs an Anthropic API key with credit.** A Claude.ai subscription is separate from API access and
  doesn't work here.
- **macOS 14 Sonoma or later** only.

## FAQ

<details>
<summary><strong>My Mac doesn't have a notch. Can I still use Otto?</strong></summary>

Yes. On Macs without a notch, Otto draws a slim virtual notch at the top center of your main display.
It works the same way.
</details>

<details>
<summary><strong>What about external displays?</strong></summary>

If your MacBook's built-in display is on, Otto lives in its notch. With the lid closed, or on a Mac with
only external displays, Otto places a virtual notch at the top center of the display with the menu bar.
It follows along when you plug displays in or out.
</details>

<details>
<summary><strong>How much does it cost?</strong></summary>

The source code is free under the MIT license, and building it yourself costs nothing. The signed app
will be a one-time purchase when it ships. Either way, you pay Anthropic for what you use, per token, on
your own API account. Set a monthly spend limit in the Anthropic Console if you want a hard cap.
</details>

<details>
<summary><strong>If the code is open source, what does the paid app add?</strong></summary>

A build that's signed with a Developer ID and notarized by Apple, so it opens like any other Mac app and
you don't need Xcode. The code is the same code that's in this repository.
</details>

<details>
<summary><strong>Why isn't Otto on the Mac App Store?</strong></summary>

Mac App Store apps must run in Apple's App Sandbox, and Otto's notch panel, global shortcut and browser
tab reading are built to run outside it. The signed app will be sold directly instead.
</details>

<details>
<summary><strong>What happens to my data?</strong></summary>

Nothing is sent anywhere until you press send, and then it goes straight to Anthropic's API. Otto keeps
no history on disk and has no telemetry. See [Privacy & permissions](#privacy--permissions).
</details>

<details>
<summary><strong>Why do I need my own API key?</strong></summary>

There's no middleman server relaying your messages, and you pay Anthropic only for what you use. Keys
take a minute to create at [console.anthropic.com](https://console.anthropic.com/settings/keys).
</details>

<details>
<summary><strong>Can I try Otto without a key?</strong></summary>

Yes. Demo mode plays a scripted, streamed reply (with thinking, a web search and sources) without
touching the network. From your clone, run:

```sh
scripts/run.sh --demo --open
```
</details>

<details>
<summary><strong>macOS asks whether Otto may use its Keychain item.</strong></summary>

That's Otto reading the API key you saved. Click **Always Allow**. Ad hoc signed source builds ask again
after each rebuild; see [Limits and known issues](#limits-and-known-issues).
</details>

<details>
<summary><strong><kbd>⌥</kbd><kbd>Space</kbd> opens a different app.</strong></summary>

Otto registers the shortcut exclusively, and Settings tells you if another app already holds it. Some
launchers register it in a way macOS can't detect. If that happens, change the shortcut in the other
app, or turn Otto's shortcut off in Settings and open Otto from the notch or menu bar icon. A custom
shortcut is on the [roadmap](#roadmap).
</details>

<details>
<summary><strong>How do I uninstall Otto?</strong></summary>

1. In Settings, turn off **Launch at login**, then choose **Quit Otto** from the ⋮ menu or menu bar icon.
2. Delete `Otto.app` (from Applications, or the `build/` folder of your clone).
3. Optional clean-up: in **Keychain Access**, delete the item named `com.jalenedusei.otto` (your API
   key), and run `defaults delete com.jalenedusei.otto` to remove preferences.
</details>

## Build from source

You'll need macOS 14 or later, Xcode 16 or later (with its command line tools selected) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/jke48222/otto.git
cd otto
scripts/run.sh --open     # build, then launch with the notch open
```

The app lands in `build/Build/Products/Debug/Otto.app`. Drag it to Applications if you want to keep it
there. It was built on your Mac, so Gatekeeper opens it without a warning.

| Script | What it does |
| --- | --- |
| `scripts/build.sh` | Generates `Otto.xcodeproj` and builds Debug into `build/Build/Products/Debug/Otto.app` |
| `scripts/run.sh [flags]` | Builds, stops any running Otto, and launches the fresh build with your flags |
| `scripts/snapshot.sh` | Builds, then renders UI snapshots into `docs/snapshots/` |
| `swift scripts/make_icon.swift` | Regenerates every size of the app icon |
| `scripts/make_media.sh` | Re-renders the stills in `docs/media/` and records raw promo footage from the real UI |
| `scripts/make_video.sh` | Cuts the promo film, its poster and the README loop from that footage (needs `ffmpeg`) |
| `scripts/build_site.sh` | Assembles the website from `site/` and `docs/media/` into `_site/` |
| `scripts/release.sh` | Builds, signs and packages `dist/Otto.dmg` (see [docs/RELEASING.md](docs/RELEASING.md)) |

Run the tests with:

```sh
xcodegen generate
xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test
```

`Otto.xcodeproj` is generated from `project.yml` and isn't checked in. Run `xcodegen generate` and open it
to work in Xcode.

**Signing.** Builds are ad hoc signed by default, so no Apple Developer account is needed. To sign with
your own identity (which stops Keychain prompts after every rebuild), create `Config/Local.xcconfig`,
which is git-ignored:

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = ABCDE12345
```

Set `OTTO_ADHOC_SIGNING=1` to force an ad hoc signature for a single build.

**Launch flags.** Pass them with `scripts/run.sh <flags>` or `open Otto.app --args <flags>`.

| Flag | Effect |
| --- | --- |
| `--demo` | Uses the built-in mock client: a scripted, streamed reply with thinking, a web search and sources. No key or network needed. |
| `--open` | Opens the notch, focused, right after launch. |
| `--snapshot <dir>` | Debug builds only. Renders PNG snapshots of the UI in fixed states into `<dir>`, then quits. |
| `--selftest <dir>` | Debug builds only. Drives the real notch on screen through a scripted session (open, type, send, stream, close mid-reply, reopen, attach files) and checks the pointer logic against the live notch geometry. Writes `report.json` and PNG captures, then exits `0` only if every step passed. |

**API key from the environment.** With no key in the Keychain, Otto falls back to `ANTHROPIC_API_KEY`.
Apps opened from Finder don't inherit your shell's environment, so run the binary directly:

```sh
ANTHROPIC_API_KEY=sk-ant-… build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto
```

## How it works

Otto is an accessory app (no Dock icon) built with AppKit for the window and event plumbing and SwiftUI
for everything you see. It uses only Apple frameworks.

```
Otto/
├── App/      entry point, launch options, ⌥Space hot key, menu bar item, Settings window, AppSettings
├── Notch/    borderless panel over the notch, pointer state machine, geometry, NotchViewModel
├── Chat/     shared model types, ChatSession (conversation + streaming), system prompt
├── API/      AnthropicClient (HTTPS + server-sent events), stream accumulator, mock client, Keychain
├── Context/  attachment loading (files, images, PDFs, clipboard, drops), browser tab, screen capture
├── UI/       SwiftUI views: notch shape, clay theme, chips, composer, conversation, Markdown, Settings
└── Debug/    Debug-build tools: snapshot renderer, on-screen self-test, promo stage for the launch media
```

A transparent, non-activating panel sits over the notch and only accepts clicks inside the shape it
draws, so everything else passes through to your apps and the menu bar. <kbd>⌥</kbd><kbd>Space</kbd>
uses the Carbon hot-key API, which is why Otto doesn't need Accessibility access. `ChatSession` builds
each request and streams `POST /v1/messages`; the stream is folded into text, thinking, tool activity
and sources as it arrives. Request bodies are encoded with sorted keys so the prompt prefix stays
byte-stable for prompt caching. The suite has 212 unit tests, and the full design spec, with every
module interface, is in [`docs/SPEC.md`](docs/SPEC.md).

## Roadmap

Coming soon, in no fixed order:

- **The signed app:** a notarized build sold as a one-time purchase.
- **Conversation history:** pick up where you left off, across launches.
- **Ask about your selection:** highlight text in any app and ask Otto about it.
- **Insert answers anywhere:** drop a reply straight into the app you're working in.
- **Voice mode:** ask out loud and hear Otto answer.
- **Calendar & reminders:** ask what's next, or have Otto add a reminder for you.
- **Media controls:** see what's playing and control it from the notch.
- **Shortcuts & AppleScript actions:** let Claude run the automations you approve.
- **File shelf:** park files in the notch and drag them out wherever you need them.
- **Custom shortcut:** choose your own key combination instead of <kbd>⌥</kbd><kbd>Space</kbd>.

Have an idea? [Open a feature request](https://github.com/jke48222/otto/issues/new?template=feature_request.yml).

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for
setup, project layout, conventions and the PR checklist. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

Otto's source code is released under the [MIT License](LICENSE). © 2026 Jalen Edusei.

## Acknowledgments

- The [Claude API](https://www.anthropic.com/api) from Anthropic, which writes the answers.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which keeps the Xcode project out of version control.
- [Shields.io](https://shields.io) for the badges, and the
  [Contributor Covenant](https://www.contributor-covenant.org) for the code of conduct.

<sub>Otto is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic.
Claude and Anthropic are trademarks of Anthropic, PBC. Mac, MacBook and macOS are trademarks of Apple
Inc.</sub>
