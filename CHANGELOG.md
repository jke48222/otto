# Changelog

All notable changes to Otto are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned as 1.0.0: the first tagged source release, and the build the signed app will ship from. Otto's
source code is MIT licensed; the signed, notarized app will be a one-time purchase.

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
