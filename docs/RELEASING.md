# Releasing Otto

This is the checklist for shipping a new version of Otto. A version has two parts:

- **A source release on GitHub:** a tag and release notes. The source code is free under the MIT license,
  and anyone can build it. No disk image is attached to the GitHub release.
- **The signed app:** a Developer ID signed, notarized disk image, sold as a one-time purchase through
  the storefronts Otto is listed on. It is never uploaded to GitHub.

People who watch the repo's releases on GitHub get notified when a new version is tagged, so tag the
source release after the signed app is live on at least one storefront.

`scripts/release.sh` builds the signed app. It builds the Release configuration, signs it with your
Developer ID, packages it into a disk image, notarizes it with Apple and writes the files you upload to
each storefront.

```
dist/
├── Otto-1.0.0.dmg          versioned disk image
├── Otto.dmg                same file, stable name for storefront uploads
├── Otto-1.0.0.dSYM.zip     debug symbols, for symbolicating crash reports
└── SHA256SUMS.txt          checksums of the above
```

`dist/` is ignored by git. Never commit a build, and never attach one to a GitHub release.

## One-time setup

You need a Mac with Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and a paid Apple Developer Program membership.

### 1. A Developer ID Application certificate

Gatekeeper only runs apps from outside the App Store if they are signed with a **Developer ID Application**
certificate. An "Apple Development" certificate won't work.

1. Open Xcode → **Settings** → **Accounts**, select your team and click **Manage Certificates…**
2. Click **+** and choose **Developer ID Application**. (Usually only the team's Account Holder can create one.)
3. Check that it is in your keychain:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

`release.sh` finds this identity on its own and reads your team ID from its name, so neither goes into
the repository. If you have more than one Developer ID identity, choose one with its SHA-1 hash or part
of its name:

```sh
export OTTO_SIGN_IDENTITY="Developer ID Application: Your Name"   # or the 40-character hash
export OTTO_TEAM_ID=ABCDE12345                                     # only if it can't be read from the name
```

### 2. Notarization credentials

Apple notarizes a build by scanning it for malware and issuing a ticket that Gatekeeper checks on first
launch. `notarytool` needs credentials, which you save once in your login keychain under a profile name.

**Option A: Apple ID with an app-specific password** (the simplest option)

1. Go to [account.apple.com](https://account.apple.com) → **Sign-In and Security** → **App-Specific
   Passwords**, and generate one called "notarytool".
2. Save it as a profile. `notarytool` asks for the password, so it never ends up in your shell history:

   ```sh
   xcrun notarytool store-credentials otto-notary \
     --apple-id "you@example.com" \
     --team-id ABCDE12345
   ```

**Option B: App Store Connect API key** (better for CI or shared machines)

1. In [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** →
   **Team Keys**, create a key with the **Developer** role and download the `.p8` file.
2. Save it as a profile:

   ```sh
   xcrun notarytool store-credentials otto-notary \
     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

Check that the profile works:

```sh
xcrun notarytool history --keychain-profile otto-notary
```

`release.sh` notarizes only when `OTTO_NOTARY_PROFILE` names a profile. If it's not set, the script still
builds and signs everything, but says the build is **not notarized**. You can test an un-notarized build on
your own Mac, but don't publish it. On other Macs, Gatekeeper won't open it.

### 3. Finder automation (for the disk image layout)

The first time you run `release.sh`, macOS asks whether your terminal may control **Finder**. Click
**Allow**. Finder lays out the disk image window: the background, the icon positions and the icon size.
If you decline, or run the script where Finder isn't available (for example over SSH), the script falls
back to a plain disk image with just the app and an Applications shortcut. To change your answer later,
go to System Settings → Privacy & Security → Automation.

## Cutting a release

1. **Pick the version.** Otto uses [Semantic Versioning](https://semver.org). In `project.yml`, set
   `MARKETING_VERSION` (for example `1.1.0`) and increase `CURRENT_PROJECT_VERSION` (the build number,
   which always goes up).

2. **Update the changelog.** Move everything under `[Unreleased]` in `CHANGELOG.md` into a new section
   for this version, with today's date.

3. **Run the tests.**

   ```sh
   xcodegen generate
   xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test
   ```

4. **Build, sign, notarize and package.**

   ```sh
   OTTO_NOTARY_PROFILE=otto-notary scripts/release.sh --smoke-test
   ```

   This takes a few minutes, most of it spent waiting for Apple's notary service. The script notarizes
   twice: first the app, so the app itself carries a stapled ticket after it's copied out of the disk image,
   and then the disk image. `--smoke-test` then mounts the finished DMG, checks the signature of the app
   inside it and launches that app in `--demo` mode for a few seconds.

5. **Check the result.** All three commands should report that the file was accepted and name
   Notarized Developer ID as the source:

   ```sh
   spctl --assess --type open --context context:primary-signature --verbose=2 dist/Otto.dmg
   xcrun stapler validate dist/Otto.dmg
   hdiutil attach -nobrowse -readonly dist/Otto.dmg        # then:
   spctl --assess --type execute --verbose=2 /Volumes/Otto/Otto.app
   hdiutil detach /Volumes/Otto
   ```

   For a real first-run test, copy `dist/Otto.dmg` to another Mac (AirDrop works: it marks the file as
   downloaded, just like a browser would), open it, drag Otto to Applications and launch it.

6. **Upload the signed app to each storefront.** Upload `dist/Otto.dmg` (or the versioned file, if the
   storefront keeps one file per version) as the product file on every storefront where Otto is listed,
   and update the version number and release notes there. Buy a copy in the storefront's test mode and
   check that the download is the new build:

   ```sh
   shasum -a 256 ~/Downloads/Otto.dmg    # must match the line in dist/SHA256SUMS.txt
   ```

   Keep `Otto-<version>.dSYM.zip` somewhere safe (not in the repo). You need it to symbolicate crash
   reports from that build.

7. **Commit, tag and push.**

   ```sh
   git commit -am "Release 1.1.0"
   git tag -a v1.1.0 -m "Otto 1.1.0"
   git push origin main v1.1.0
   ```

8. **Publish the source release on GitHub.** Notes only, from the changelog. Don't attach the disk image.

   ```sh
   gh release create v1.1.0 \
     --title "Otto 1.1.0" \
     --notes-file <(awk '/^## \[1.1.0\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)
   ```

   Publishing it notifies everyone watching the repo's releases, so add a line at the end of the notes
   that says where to buy the signed app.

## `release.sh` reference

| Option | Effect |
| --- | --- |
| `--smoke-test` | After packaging, mounts `dist/Otto.dmg`, verifies the app inside it and launches it with `--demo` for five seconds. It stops only the process it started. |
| `--plain-dmg` | Skips the Finder layout: no background and default icon positions. |
| `--skip-build` | Repackages the last Release build in `build/release/` instead of building again. Useful when you only changed the disk image. |

| Environment variable | Effect |
| --- | --- |
| `OTTO_NOTARY_PROFILE` | `notarytool` keychain profile. If it's set, the script notarizes and staples both the app and the DMG. |
| `OTTO_SIGN_IDENTITY` | Signing identity (a SHA-1 hash or part of the name). Default: the first Developer ID Application identity. |
| `OTTO_TEAM_ID` | Team ID. Default: read from the identity's name. |

What the script checks, and where it stops if a check fails:

- The Release build is signed by the Developer ID identity, has the **hardened runtime** flag
  (`flags=0x10000(runtime)`), carries a **secure timestamp** and has no `get-task-allow` entitlement. The
  notary service rejects builds that miss any of these.
- `codesign --verify --deep --strict` passes for the app, and `codesign --verify --strict` passes for the
  DMG.
- `hdiutil verify` confirms the DMG's checksum.
- The version in the built `Info.plist` matches `MARKETING_VERSION` in `project.yml`.

Signing settings are passed to `xcodebuild` on the command line (`CODE_SIGN_IDENTITY`,
`DEVELOPMENT_TEAM`, `OTHER_CODE_SIGN_FLAGS=--timestamp`, `ENABLE_HARDENED_RUNTIME=YES`). They override
`Config/Signing.xcconfig` and your git-ignored `Config/Local.xcconfig` for this build only. Everyday
Debug builds keep signing as before.

## The disk image

The DMG is a compressed (UDZO), signed HFS+ image named **Otto** that contains:

- `Otto.app`
- an `Applications` shortcut to drag it onto
- a hidden `.background/background.tiff`: a 660×420 pt background with 1× and 2× versions
- a hidden `.VolumeIcon.icns`, so the mounted disk shows Otto's icon

`scripts/make_dmg_background.swift` draws the background in code with Otto's look: the matte near-black
panel with a fine grain, a small notch with the warm orb, the wordmark and tagline, a dotted "drag to
install" arrow, and a caption. Finder always draws icon labels in black (Light Mode) or white (Dark Mode),
whatever the background, so each label sits on a mid-grey pill. Black and white text both have a contrast
ratio of at least 4.5:1 against it. If you change the layout, keep the constants at the top of that file
and the Finder settings in `release.sh` (window size, icon size and positions) the same.

To preview the background on its own:

```sh
swift scripts/make_dmg_background.swift /tmp/otto-dmg && open /tmp/otto-dmg/background@2x.png
```

## Troubleshooting

**"no Developer ID Application identity found"**: the certificate is missing, or its private key isn't in
this Mac's keychain. If you created the certificate on another Mac, export it from Keychain Access there
as a `.p12` file (certificate and key together) and import it here.

**The notary service rejects the build**: the script prints the notary log. The usual causes are a
missing hardened runtime flag, a missing secure timestamp or a debug entitlement, and the script checks
all three before it submits. To check an older submission:
`xcrun notarytool log <submission-id> --keychain-profile otto-notary`.

**Finder layout times out or the DMG window looks wrong**: allow Automation for your terminal (see
[step 3 of the setup](#3-finder-automation-for-the-disk-image-layout)), close any open Finder windows
for an "Otto" volume and run the script again. If you're in a hurry, `--plain-dmg` always works.

**"Otto is damaged and can't be opened"** on another Mac: the build wasn't notarized, or it was changed
after signing. Build it again with `OTTO_NOTARY_PROFILE` set.

## Notes for maintainers

The developer tools in `Otto/Debug/` (`SelfTest`, `SnapshotRenderer` and the promo stage) are wrapped in
`#if DEBUG || OTTO_TOOLS`, so shipping Release builds leave them out and ignore their launch flags
(`--selftest`, `--snapshot`, `--promo`, `--promo-stills`). `scripts/make_media.sh` records footage from a
Release build made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=OTTO_TOOLS`; never ship that build.
`--demo` stays in Release builds on purpose, because the README offers it as a way to try Otto without
an API key.
