# Security Policy

Otto handles your Anthropic API key and whatever you choose to send to Claude, so security reports are
taken seriously. Thank you for helping keep Otto and its users safe.

## Supported versions

Security fixes land on `main` first and ship in the next signed build. Please make sure you can
reproduce an issue on the latest `main` (or, once it ships, the latest signed app) before reporting it.

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Latest signed app, once it ships | Yes |
| Older builds and tags | No |

## Reporting a vulnerability

**Please don't open a public issue for security problems.** Instead, report privately through GitHub:

1. Go to the [Security tab](https://github.com/jke48222/otto/security) of the repository.
2. Click **Report a vulnerability** (or open
   [a new advisory](https://github.com/jke48222/otto/security/advisories/new) directly).
3. Describe the issue, the affected version and macOS version, and steps to reproduce. A proof of
   concept helps a lot.

Never include a real API key in a report. If you think a key was exposed, revoke it in the
[Anthropic Console](https://console.anthropic.com/settings/keys) right away.

What to expect:

- An acknowledgment within **5 business days**.
- An assessment and a plan (or a request for more detail) within **14 days**.
- Credit in the release notes and advisory once a fix ships, unless you'd rather stay anonymous.

Please allow a reasonable time for a fix to ship before disclosing publicly.

## Scope

In scope, for example:

- Anything that exposes the API key outside the Keychain, or to a host other than `api.anthropic.com`.
- Content leaving the Mac without the user pressing send, or going anywhere other than the Anthropic API.
- Browser-tab reading beyond the front tab's title and address, or without the Automation permission.
- Screen capture without the user starting it.
- Crafted files, pasteboard contents, web pages or API responses that crash Otto or run code.
- Weaknesses in how releases are built or packaged.

Out of scope:

- Model behavior itself (for example, what Claude says in a reply). Please send that feedback to Anthropic.
- Attacks that require an already-compromised Mac or user account.
- Findings that only apply to unsupported versions.
- Ad hoc signatures on builds you compile yourself, and the Keychain prompt they cause after each
  rebuild, which are documented.

## How Otto handles your API key

- The key is stored in your **login Keychain** as a generic password (service `com.jalenedusei.otto`,
  account `anthropic-api-key`). Otto never writes it to disk anywhere else, never logs it and never
  puts it in a URL.
- Settings shows only a masked version of the saved key.
- The key is sent in the `x-api-key` header, over HTTPS, to `https://api.anthropic.com` only.
- If there is no key in the Keychain, Otto falls back to the `ANTHROPIC_API_KEY` environment variable
  and doesn't store it.
- Removing the key in Settings deletes the Keychain item.

## What leaves your Mac

Only when you press send, Otto sends your message, the items you attached, your custom instructions and
the current conversation to the Anthropic Messages API. There is no Otto server, account, analytics or
crash reporting. Conversations are kept in memory only. See
[Privacy & permissions](README.md#privacy--permissions) in the README for details.
