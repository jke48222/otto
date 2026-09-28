# jke48222/homebrew-tap

My Homebrew tap. It has one cask: **Otto**, the AI assistant that lives in your MacBook's notch.

## Install

```sh
brew install --cask jke48222/tap/otto
```

This installs the signed, notarized Otto app. It starts as a 14-day trial with every feature on and no card
needed. After day 14, sending a message needs a license; Settings, Recents and demo mode keep working, and
nothing is deleted.

Otto needs macOS 14 Sonoma or later and your own Anthropic API key.

## Buy a license

Open **Settings → License → Buy a License…** in Otto, or the Buy link on Otto's site (`brew home --cask otto`
opens it). A license is a one-time purchase for up to 3 Macs and includes every 1.x update.

## Updates

Otto updates itself through Sparkle, so the cask sets `auto_updates true` and `brew upgrade` leaves Otto alone.
To have Homebrew install a newer version anyway:

```sh
brew upgrade --cask --greedy otto
```

## Uninstall

```sh
brew uninstall --cask otto          # removes Otto.app
brew uninstall --zap --cask otto    # also removes Otto's settings, history and caches
```

Neither command touches the Keychain. Otto keeps its license and trial dates there, in items that Keychain
Access lists as "Otto (license)", "Otto (trial)" and so on, next to the item that holds your API key. Delete
them in Keychain Access if you want them gone too. While they stay, reinstalling Otto keeps your license
and your trial count.

## Why a personal tap

Homebrew's official cask list takes apps once they meet its notability rules. Otto will move there when it
does. Until then, this tap is where the cask lives. It points at the same disk image the site offers, and the
tests in `.github/workflows/tests.yml` run `brew style` and `brew audit --cask --online` on every push.

## Source

Otto is open source under the MIT license: [github.com/jke48222/otto](https://github.com/jke48222/otto).
Building it from source is free and needs no license. Issues about the app go there; issues about the cask go
here.
