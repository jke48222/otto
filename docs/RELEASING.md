# Releasing Otto

This is the checklist for shipping a new version of Otto. The same code ships four ways, and only two of
them are built by this checklist:

| Flavor | Built from | What it is | Where it goes |
| --- | --- | --- | --- |
| **paid** | `project-paid.yml` → `OttoPaid.xcodeproj` | The signed app: a 14-day trial, license keys from Polar and Gumroad, updates through Sparkle | A disk image on Otto's site (Vercel Blob), the same file on Gumroad and behind the Homebrew cask |
| **setapp** | `project-setapp.yml` → `OttoSetapp.xcodeproj` | A separate build with the Setapp Framework, bundle id `com.jalenedusei.otto-setapp`, no license or updater of Otto's own | A zip you upload in the Setapp developer account |
| source | `project.yml` → `Otto.xcodeproj` | Free under the MIT license, no packages, no license code | GitHub: a tag, release notes and source archives |
| licensing check | `Otto.xcodeproj` with `OTTO_LICENSING` on the command line | Development and CI only | Nowhere |

There is no signed source-flavor release: a free signed download would undercut the paid one. A GitHub
release carries notes only, never a disk image, and it goes out only once the site's `/buy` page is live.

`scripts/release.sh` builds a paid or Setapp release. It checks everything it can before it builds, then
builds the Release configuration, signs it with your Developer ID, notarizes it with Apple and writes the
files you publish. `scripts/publish.sh` then uploads a paid release, writes the signed update feed and
renders the Homebrew cask.

```
dist/
├── paid/
│   ├── Otto-1.1.0.dmg               the trial and paid download, Sparkle's update, Gumroad's file, the cask's target
│   ├── Otto-1.1.0.dSYM.zip          debug symbols, for symbolicating crash reports
│   └── SHA256SUMS.txt
└── setapp/
    ├── Otto-1.1.0-setapp.zip        uploaded by hand in the Setapp developer account
    ├── Otto-1.1.0-setapp.dSYM.zip
    └── SHA256SUMS.txt
```

With `--no-notarize`, every name ends in `-UNNOTARIZED` before the extension (`Otto-1.1.0-UNNOTARIZED.dmg`),
and `publish.sh` refuses those files. `dist/` is ignored by git. Never commit a build, and never attach one
to a GitHub release.

## Open items

Every value only you can supply is a named placeholder, and every script and build that needs one stops
with its number. `Config/Commercial.xcconfig` and `site/commerce.json` hold the public values; secrets
(the Sparkle private key, the notary profile, the canary keys) stay in your login Keychain.

| Item | What you do | Where the value goes |
| --- | --- | --- |
| J1 | Polar production account and organization; note the organization ID and slug | `OTTO_POLAR_ORGANIZATION_ID`, `OTTO_POLAR_PORTAL_SLUG`; `commerce.json` `polar.portalURL` |
| J2 | Product "Otto for Mac", one-time $19, visibility **private**, with a License Keys benefit: prefix `OTTO`, no expiry, activation limit 3, "Enable user to deactivate instances via Polar" on | `OTTO_POLAR_BENEFIT_ID` |
| J3 | The same organization, product and benefit in the Polar sandbox, plus one sandbox test key | the `[config=Debug]` values |
| J4 | Checkout links (regular, and launch week with a preset discount), a 30% student code and a 100% code for your own orders; success URL `https://<site>/thanks`, return URL `https://<site>/buy`. Created at HM1, committed at HM3 | `commerce.json` `polar.checkoutURL`, `launch.checkoutURL` |
| J5 | Polar payouts (Stripe Connect); the account review is submitted at HM3 | the Polar dashboard |
| J6 | Sparkle keys, and a backup of the private key in your password manager | `OTTO_SPARKLE_PUBLIC_ED_KEY` |
| J7 | The notary profile `otto-notary` and a current Apple Developer Program membership | `OTTO_NOTARY_PROFILE` in your shell |
| J8 | The permanent site host (a custom domain is strongly recommended: every shipped copy asks it for updates) | `OTTO_SITE_HOST`; `commerce.json` `siteHost` |
| J9 | The public Vercel Blob store `otto-downloads` and the `vercel` CLI logged in | `commerce.json` `downloadsHost` |
| J10 | Vercel Pro for the team that owns the `otto` project and the store | the Vercel team |
| J11 | Seller legal name, a public support email, the governing-law state | `OTTO_SUPPORT_EMAIL`; `commerce.json` `seller.*` |
| J12 | Approve the Terms, Privacy and Refund drafts | `commerce.json` `legal.*` |
| J13 | `none` for 1.1.0; the Gumroad product id at HM7, once J21 exists | `OTTO_GUMROAD_PRODUCT_ID` |
| J14 | The Setapp developer account; register `com.jalenedusei.otto-setapp` (permanent) and download the public key | `Config/Setapp/setappPublicKey.pem` |
| J15 | Create the public repo `jke48222/homebrew-tap` and push the first cask | `../homebrew-tap` |
| J16 | A GitHub Sponsors profile | GitHub |
| J17 | A USPTO search for "Otto" in class 9 before the first sale | the Terms, the README |
| J18 | Cookie-free Vercel Web Analytics: on since 2026-09-30 (enabled in the Vercel project; every page loads `/_vercel/insights/script.js`) | the site and its privacy page |
| J19 | The launch window: start, end (the Polar discount's own end) and the time zone the site prints | `commerce.json` `launch.*` |
| J20 | The Polar canary key (below) | your login Keychain |
| J21 | The Gumroad canary key (below) | your login Keychain |

`scripts/check_commercial_config.sh --flavor paid --configuration Release --xcconfig Config/Commercial.xcconfig`
lists every setting that is still a placeholder or malformed. A Release build of either flavor stops with
the same lines before it compiles anything; a Debug build warns and still builds.

## One-time setup

You need a Mac with Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), Node (`brew install node`), the Vercel CLI (`npm i -g vercel`) and a paid Apple
Developer Program membership.

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

### 2. Notarization credentials (J7)

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

Check that the profile works, then export its name in the shell you release from:

```sh
xcrun notarytool history --keychain-profile otto-notary
export OTTO_NOTARY_PROFILE=otto-notary
```

`release.sh` refuses to start without `OTTO_NOTARY_PROFILE` unless you pass `--no-notarize`. An unnotarized
build is fine for testing on your own Mac, but Gatekeeper on other Macs won't open it, so its files carry
`-UNNOTARIZED` in their names and `publish.sh` won't touch them.

### 3. Sparkle keys (J6)

Sparkle checks every update against a public key built into the app. The matching private key signs each
update and the feed itself. **If you lose the private key, no copy that has already shipped can ever update
again**, so the backup is part of the setup, not an extra.

1. Resolve the paid build's packages once, so Sparkle's tools are on disk, and find them:

   ```sh
   xcodegen generate --spec project-paid.yml
   xcodebuild -resolvePackageDependencies -project OttoPaid.xcodeproj -scheme Otto \
     -derivedDataPath build/release/paid/DerivedData
   SPARKLE_TOOLS="$(dirname "$(bash scripts/lib/sparkle_tools.sh generate_keys)")"
   ```

2. Create the key pair. `generate_keys` stores the private key in your login Keychain (account `ed25519`)
   and prints the public key:

   ```sh
   "$SPARKLE_TOOLS/generate_keys"
   ```

3. Back up the private key to a file, put that file in your password manager, then delete the file:

   ```sh
   "$SPARKLE_TOOLS/generate_keys" -x otto-sparkle-private-key.txt
   ```

   On a new Mac, `generate_keys -f otto-sparkle-private-key.txt` imports it. Never generate a second key
   for a shipped app.

4. Put the public key in `Config/Commercial.xcconfig` as `OTTO_SPARKLE_PUBLIC_ED_KEY`. xcconfig files read
   `//` as the start of a comment, so if the key contains `//`, write it as `/$()/`. The config check
   catches a key that lost its tail.

`generate_keys -p` prints the public key of the private key in the Keychain; `release.sh` compares it with
`OTTO_SPARKLE_PUBLIC_ED_KEY` before every paid build.

### 4. Downloads and the site (J8, J9)

The disk images live in a public Vercel Blob store, and the site links to them. The update feed,
`site/appcast.xml`, is committed and served by the site itself.

```sh
vercel login
vercel link                     # in the repository, if it isn't linked to the otto project yet
vercel blob create-store otto-downloads --access public --yes
```

Put the store's public host (`<store-id>.public.blob.vercel-storage.com`, shown on the store's page in the
Vercel dashboard) in `site/commerce.json` as `downloadsHost`, and the permanent site host in both
`OTTO_SITE_HOST` and `siteHost`. `release.sh` checks that `site/commerce.json` and
`Config/Commercial.xcconfig` agree on the site host and the support address.

### 5. The license canaries (J20, J21)

Before every paid build, `release.sh` validates a real license key against the organization and benefit
IDs it is about to ship. A wrong or drifted ID then stops the release on your Mac instead of reaching
buyers' copies.

- **Polar canary (J20).** Place one order through the regular checkout link with your 100% discount code.
  Never activate, refund or revoke that key. Save it:

  ```sh
  security add-generic-password -s otto-release -a polar-canary -w 'OTTO-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
  ```

- **Gumroad canary (J21)**, only once Gumroad keys are switched on (gate HM7): buy the published product once
  with a 100% offer code and save that key the same way, with `-a gumroad-canary`.

Each release adds one validation to the canary's count at Polar. The Gumroad check sends
`increment_uses_count=false`, so it never uses a seat.

### 6. Finder automation (for the disk image layout)

The first time you run `release.sh --flavor paid`, macOS asks whether your terminal may control **Finder**.
Click **Allow**. Finder lays out the disk image window: the background, the icon positions and the icon
size. If you decline, or run the script where Finder isn't available (for example over SSH), the script
falls back to a plain disk image with just the app and an Applications shortcut. To change your answer
later, go to System Settings → Privacy & Security → Automation.

## Release prep: the one `project.yml` edit

The version lives in `project.yml`, and a release changes exactly two lines there and nothing else:

```yaml
    MARKETING_VERSION: "1.1.0"      # Semantic Versioning
    CURRENT_PROJECT_VERSION: "2"    # the build number: always goes up
```

Commit them as "Set version 1.1.0". Sparkle offers an update only when its build number is higher than the
running copy's, so `release.sh` refuses a `CURRENT_PROJECT_VERSION` that isn't above every
`sparkle:version` in `site/appcast.xml`. (A missing `appcast.xml` counts as no items: the first release
starts the feed.)

For 1.1.0, the release prep follows the tag `v1.1.0-rc2`: the version commit, then the standard checks
below. If the General tab's new version text moves `docs/snapshots/settings.png` or
`docs/snapshots/settings-general.png` past the snapshot threshold, regenerate exactly those two in the same
commit. Gates H2, HM4 and HM3 all use builds of this commit, so the build that passes H2 is the build that
ships.

## Cutting a release

1. **Update the changelog.** Move everything under `[Unreleased]` in `CHANGELOG.md` into a new section,
   `## [1.1.0] - YYYY-MM-DD`. `publish.sh` turns that section into the release notes Sparkle shows.

2. **Run the tests**, for the source build and each flavor:

   ```sh
   xcodegen generate
   xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test
   xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/licensing \
     'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG OTTO_LICENSING' test
   xcodegen generate --spec project-paid.yml
   xcodebuild -project OttoPaid.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/paid test
   xcodegen generate --spec project-setapp.yml
   xcodebuild -project OttoSetapp.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/setapp build
   for t in scripts/tests/*_test.sh; do bash "$t" || break; done
   node --test scripts/tests/*.test.mjs
   ```

3. **Run the preflight on its own** (it takes under a minute and builds nothing):

   ```sh
   scripts/release.sh --flavor paid --preflight-only
   ```

   It runs in three stages, and each stage runs only when the one before it passed:

   1. **Local checks**, all of them, every failure listed at once: the tools, the Developer ID identity,
      `OTTO_NOTARY_PROFILE`, `scripts/check_commercial_config.sh` on `Config/Commercial.xcconfig`, the
      version and build number in `project.yml`, and for the paid build the build number against
      `site/appcast.xml` and `site/commerce.json` against the xcconfig. A Mac with no accounts and no
      network gets the whole list here and never reaches stage 2.
   2. **Polar and Gumroad** (paid): the Polar version probe and the canaries.
      - The probe sends a random key to `api.polar.sh` with the pinned `Polar-Version: 2026-10` and requires
        Polar's versioned "not found" answer (`404`, a `polar-version: 2026-10` header and
        `"error":"ResourceNotFound"`). Anything else means Polar stopped serving that version: read Polar's
        changelog, bump `PolarConfiguration.apiVersion` and re-run the Polar fixtures before you ship.
      - The Polar canary (J20) must validate with exactly this build's organization and benefit: `200`,
        `status` "granted", the benefit ID of `OTTO_POLAR_BENEFIT_ID` and `limit_activations` 3.
      - With `OTTO_GUMROAD_PRODUCT_ID` other than `none`, the Gumroad canary (J21) must verify with
        `success: true` and no refund, chargeback or open dispute.
   3. **Packages and the Sparkle key** (paid): Swift package resolution for `OttoPaid.xcodeproj`, then
      `generate_keys -p` must print `OTTO_SPARKLE_PUBLIC_ED_KEY`, so an update can never be signed with a key
      the shipped app doesn't trust.

   The Setapp build runs stage 1 only; it has no canary and no Sparkle key.

4. **Build, sign, notarize and package the paid build.**

   ```sh
   scripts/release.sh --flavor paid --smoke-test
   ```

   After the preflight, the script generates `OttoPaid.xcodeproj`, builds it into
   `build/release/paid/DerivedData` with the Developer ID signing settings, then:

   - removes Sparkle's XPC services (`Sparkle.framework/Versions/B/XPCServices` and the top-level
     `XPCServices` link). Otto isn't sandboxed, so Sparkle never uses them;
   - signs Sparkle's nested code from the inside out, without `--deep`: `Autoupdate`, `Updater.app`, then
     `Sparkle.framework`, and then `Otto.app` again with `build/flavors/paid/Otto.entitlements`, each with
     the hardened runtime and a secure timestamp;
   - verifies the signature, checks that the app is universal (`arm64` and `x86_64`), runs
     `scripts/audit_flavor.sh --flavor paid --expect-wired --distribution`, and checks that every Info.plist
     value is expanded and that the feed URL, public key, hosts and IDs are the ones the preflight checked;
   - notarizes and staples the app, packages the disk image, signs it, notarizes and staples it.

   `--smoke-test` then mounts the finished DMG, checks the app inside and launches it in `--demo` mode for a
   few seconds. The whole run takes a few minutes, most of it waiting for Apple's notary service.

5. **Check the result.** All three commands should report that the file was accepted and name Notarized
   Developer ID as the source:

   ```sh
   spctl --assess --type open --context context:primary-signature --verbose=2 dist/paid/Otto-1.1.0.dmg
   xcrun stapler validate dist/paid/Otto-1.1.0.dmg
   hdiutil attach -nobrowse -readonly dist/paid/Otto-1.1.0.dmg        # then:
   spctl --assess --type execute --verbose=2 /Volumes/Otto/Otto.app
   hdiutil detach /Volumes/Otto
   ```

   For a real first-run test, copy the DMG to another Mac (AirDrop works: it marks the file as downloaded,
   just like a browser would), open it, drag Otto to Applications and launch it. Settings → License should
   say "Free trial: 14 days left".

   Keep `Otto-<version>.dSYM.zip` somewhere safe (not in the repo). You need it to symbolicate crash
   reports from that build.

6. **Build the Setapp release** when you ship to Setapp (see [Setapp](#setapp)):

   ```sh
   scripts/release.sh --flavor setapp
   ```

   Same build, signing, verification and notarization, without Sparkle's steps, then
   `dist/setapp/Otto-<version>-setapp.zip` made with `ditto` from the stapled app.

## Publishing a paid release

Before every publish, check that the Vercel team is still on Pro. The site sells Otto, and Hobby is for
non-commercial use:

```sh
npx vercel@latest api /v2/teams/team_Lb46kbdmLsqf63e0oz88WdoP     # "billing": {"plan": "pro"}
```

(The Vercel MCP's `get_team` leaves billing out, so it can't answer this.) Then:

```sh
scripts/publish.sh --version 1.1.0 --dry-run     # everything but the upload; outputs in build/publish/1.1.0/
scripts/publish.sh --version 1.1.0
```

The first publish, at gate HM3, passes `--no-tap`, because the tap repository only exists from gate HM5
on. The preflight checks that `dist/paid/Otto-<v>.dmg` exists, is stapled and passes Gatekeeper, and holds
Otto `<v>`; that `vercel whoami` works and the Blob store answers; that `node scripts/release_tools.mjs hosts
site/commerce.json` prints real hosts; that Sparkle's tools are on disk; and, unless `--no-tap`, that
`../homebrew-tap` (or `--tap-dir`) is a clean checkout of `jke48222/homebrew-tap`. Then:

1. The changelog section becomes `build/publish/<v>/archives/Otto-<v>.html`.
2. The DMG and those notes are staged. The committed `site/appcast.xml` is copied to
   `build/publish/<v>/appcast.xml`, so `generate_appcast` adds to the feed instead of starting a new one.
   With no `appcast.xml` yet (the first release), the previous item count is 0.
3. `generate_appcast` signs the new item and the feed with the key in your login Keychain. It keeps every
   older item and makes no deltas.
4. `xmllint` checks the new item: build number, version, `minimumSystemVersion` 14.0, the download URL, the
   DMG's length, the EdDSA signature, the feed's signature comment, and one more item than before.
5. The DMG goes to the Blob store as `releases/Otto-<v>.dmg`, never overwriting a file that is there, and
   the script downloads it back and compares its SHA-256 with `SHA256SUMS.txt`.
6. `site/appcast.xml` (a byte copy: the signature covers the exact bytes) and `site/release.json` are
   written.
7. Unless `--no-tap`, `Casks/otto.rb` is rendered into the tap and checked with `brew style --cask`.
8. The script prints what to run next:
   - commit and push `site/appcast.xml` and `site/release.json` as "Publish Otto <v>". Vercel deploys on
     push, and `/appcast.xml` is served as soon as it is committed, whatever `SITE_COMMERCIAL` says;
   - commit and push the tap (unless `--no-tap`);
   - `gh release create v<v>` with notes only and a last line "Get the signed app at https://<site>/buy.",
     but only when `https://<site>/buy` answers 200. Until then it tells you to create the GitHub release
     after `SITE_COMMERCIAL=1` is live, so a release never points at a page that isn't there.

The appcast rules: build numbers only go up, there are no delta updates in 1.x, the DMG is also the update
archive, and a DMG stays in the Blob store for as long as any appcast item points at it.

### Homebrew

The cask points at the same DMG. Gate HM5 renders the first one by hand, after you create the tap:

```sh
node scripts/release_tools.mjs cask site/release.json site/commerce.json > ../homebrew-tap/Casks/otto.rb
brew style --cask ../homebrew-tap/Casks/otto.rb
```

The tap's own files come from `packaging/homebrew/`: copy `tap/README.md` and
`tap/.github/workflows/tests.yml` into the new repository once. Every later release renders the cask
through `publish.sh`.

### Gumroad

When Gumroad keys are on (gate HM7), replace the product file on Gumroad with `dist/paid/Otto-<v>.dmg`
after each publish. A release that accepts Gumroad keys needs the Gumroad canary (J21), and 1.1.0 ships
with `OTTO_GUMROAD_PRODUCT_ID = none`.

### GitHub

Tag, notes and source archives only. No disk image, ever.

```sh
git tag -a v1.1.0 -m "Otto 1.1.0"
git push origin v1.1.0
```

Then run the `gh release create` line `publish.sh` printed, once `/buy` answers 200. People who watch the
repo's releases get notified, which is why it waits for the page they'll be sent to.

## Setapp

The Setapp build is uploaded by hand at developer.setapp.com → Otto → **Add new version**: the zip from
`dist/setapp/` and the release notes from the changelog. Before the first upload (gate HM7), put the
Setapp build through Setapp's test flow ("Testing your apps" in Setapp's docs) and check:

- it launches, with no License tab and no Buy or Sponsor text anywhere;
- Settings → General shows the Setapp update row;
- your usage shows in Setapp's dashboard;
- `lipo -archs` on `Otto.app/Contents/MacOS/Otto` prints `x86_64 arm64`;
- it works on the latest macOS;
- with the direct Otto running, launching the Setapp Otto quits itself and opens the direct one's notch.

## Support

### Refunds

Refunds are full, within 30 days, no questions. Refund the order in the Polar dashboard and keep **Revoke
benefits** checked. It is on by default but can be unticked, and an unticked refund leaves the key
validating, which makes the Refunds page's "A refund turns the license off" false.

Polar may also refund an order on its own, within 60 days of purchase, to prevent a chargeback. When that
email arrives, open the order and check that its license key shows as revoked; revoke it in the dashboard
if it doesn't.

Otto turns a license off only after two "not found" answers from Polar at least 20 hours apart, so a
refunded copy keeps working until the second one. The rule keeps an outage or a proxy's stray 404 from
turning off paid copies.

### Moving Gumroad seats

Buyers move Polar seats themselves (Settings → License → **Deactivate This Mac…**, or **Manage Macs in
Polar…**).
Gumroad has no such API for buyers, so a Gumroad seat stays counted until you free it from your own Mac
with your seller token, which never goes into the app, the repository or your shell history:

```sh
read -rs GUMROAD_TOKEN      # paste the token, then Return
curl -sS -X PUT https://api.gumroad.com/v2/licenses/decrement_uses_count \
  --data-urlencode "access_token=$GUMROAD_TOKEN" \
  --data-urlencode "product_id=<OTTO_GUMROAD_PRODUCT_ID>" \
  --data-urlencode "license_key=<the buyer's key>"
unset GUMROAD_TOKEN
```

Each call frees one seat.

## `release.sh` reference

```
scripts/release.sh --flavor paid|setapp [--smoke-test] [--plain-dmg] [--skip-build] [--no-notarize] [--preflight-only]
```

| Option | Effect |
| --- | --- |
| `--flavor paid\|setapp` | Required. Chooses `project-paid.yml` or `project-setapp.yml`, `build/release/<flavor>/DerivedData` and `dist/<flavor>/`. |
| `--preflight-only` | Runs the three preflight stages and stops with exit 0 or 1. Nothing is built. |
| `--no-notarize` | Skips notarization; every output name ends in `-UNNOTARIZED`. |
| `--smoke-test` | Paid: mounts the finished DMG, verifies the app inside it and launches it with `--demo` for five seconds. It stops only the process it started. |
| `--plain-dmg` | Paid: skips the Finder layout (no background, default icon positions). |
| `--skip-build` | Repackages the last Release build of that flavor instead of building again. |

| Environment variable | Effect |
| --- | --- |
| `OTTO_NOTARY_PROFILE` | `notarytool` keychain profile (J7). Required unless `--no-notarize`. |
| `OTTO_SIGN_IDENTITY` | Signing identity (a SHA-1 hash or part of the name). Default: the first Developer ID Application identity. |
| `OTTO_TEAM_ID` | Team ID. Default: read from the identity's name. |
| `OTTO_SITE_DIR` | Where `commerce.json` and `appcast.xml` are read (default `site`). The script tests point it at fixtures. |
| `SPARKLE_BIN` | A directory with Sparkle's tools, used instead of the paid build's packages. For the script tests. |

The build uses the flavor's generated project and `Config/Commercial.xcconfig` alone. It never passes
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` or `-xcconfig`: the compile conditions come from the flavor's
project spec. The signing settings (`CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`,
`OTHER_CODE_SIGN_FLAGS=--timestamp`, `ENABLE_HARDENED_RUNTIME=YES`) go on the command line and override
`Config/Signing.xcconfig` and your git-ignored `Config/Local.xcconfig` for this build only. `release.sh`
still checks the built Info.plist against the preflight values, so a `Local.xcconfig` override can't slip
another ID past the canaries.

What the script checks after the build, and where it stops if a check fails:

- The app is signed by the Developer ID identity, has the **hardened runtime** flag
  (`flags=0x10000(runtime)`), carries a **secure timestamp** and has no `get-task-allow` entitlement. The
  notary service rejects builds that miss any of these.
- `codesign --verify --deep --strict` passes for the app, and `codesign --verify --strict` for the DMG.
- The app is universal, and `scripts/audit_flavor.sh --expect-wired --distribution` passes: the flavor
  contains exactly what it may (for paid: Sparkle and nothing of Setapp's, no `.xpc` left in the app).
- The version and build number in the built Info.plist match `project.yml`.
- `hdiutil verify` confirms the DMG's checksum.

The script tests run without a Developer ID, a notary profile, a network or a build:

```sh
bash scripts/tests/release_script_test.sh
node --test scripts/tests/release_tools.test.mjs
```

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

**"no Developer ID Application identity in your keychains"**: the certificate is missing, or its private
key isn't in this Mac's keychain. If you created the certificate on another Mac, export it from Keychain
Access there as a `.p12` file (certificate and key together) and import it here.

**"is still a placeholder (J…)"**: fill in that value (see [Open items](#open-items)) and run the preflight
again. The line names the file and the setting.

**"Polar no longer serves API version 2026-10"**: Polar retired the pinned API version. Shipped copies keep
working through their unpinned retry, but don't ship until `PolarConfiguration.apiVersion` is bumped and the
Polar fixtures pass again.

**"the Polar canary didn't validate"**: an organization or benefit ID in `Config/Commercial.xcconfig` is
wrong, or the canary order was refunded or revoked. Fix the ID; a new canary needs a new 100% order.

**"the Sparkle key in this Mac's login Keychain … isn't OTTO_SPARKLE_PUBLIC_ED_KEY"**: import the backup
with `generate_keys -f`. Never ship with a new key.

**The notary service rejects the build**: the script prints the notary log. The usual causes are a
missing hardened runtime flag, a missing secure timestamp or a debug entitlement, and the script checks
all three before it submits. To check an older submission:
`xcrun notarytool log <submission-id> --keychain-profile otto-notary`.

**Finder layout times out or the DMG window looks wrong**: allow Automation for your terminal (see
[step 6 of the setup](#6-finder-automation-for-the-disk-image-layout)), close any open Finder windows
for an "Otto" volume and run the script again. If you're in a hurry, `--plain-dmg` always works.

**"Otto is damaged and can't be opened"** on another Mac: the build wasn't notarized, or it was changed
after signing. Build it again with `OTTO_NOTARY_PROFILE` set.

**`publish.sh` stops at "the feed has N item(s), expected M"**: `generate_appcast` dropped or duplicated an
item. Nothing was uploaded; check `build/publish/<v>/appcast.xml` against `site/appcast.xml`.

## Notes for maintainers

The developer tools in `Otto/Debug/` (`SelfTest`, `SnapshotRenderer` and the promo stage) are wrapped in
`#if DEBUG || OTTO_TOOLS`, so shipping Release builds leave them out and ignore their launch flags
(`--selftest`, `--snapshot`, `--promo`, `--promo-stills`). `scripts/make_media.sh` records footage from a
Release build made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=OTTO_TOOLS`; never ship that build.
`--demo` stays in Release builds on purpose, because the README offers it as a way to try Otto without
an API key.

## v1.1 release gate

Some of Otto 1.1 can only be checked by a person on a real Mac: macOS permission dialogs, System Settings,
real keyboards and trackpads, AirPods, and other people's apps. Run every check below before you tag
`v1.1.0`, on the build you're about to ship, and record each result in `CHANGELOG.md` under **Release
gate**.

**Before you start**

- Use a signed build with real permission grants: the Release build from `scripts/release.sh`, or a Debug
  build signed with your own identity through `Config/Local.xcconfig`. Ad hoc builds lose Accessibility and
  Screen Recording on every rebuild, so their results don't count.
- Use a MacBook with a notch, and have an Anthropic API key with credit.
- Start from a clean slate: quit Otto, run `tccutil reset All com.jalenedusei.otto`, and check that
  `pgrep -x Otto` prints nothing.
- Note the macOS version and build number for the results: `sw_vers -productVersion` and
  `sw_vers -buildVersion`.

Mark each line **pass** or **fail** and write the macOS build number next to it. A check that fails blocks
the release until it's fixed and run again.

### Provenance

This was first run at gate H1 after the engines were built. Run it again on the release build.

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| `TEST_RUNNER_OTTO_PROVENANCE_PROBE=1 xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test -only-testing:OttoTests/InputProvenanceProbeTests`: a trackpad click and a <kbd>⌘</kbd><kbd>↩</kbd> on the keyboard both log `eventSourceUnixProcessID=0` and `isHardware=true`, and the <kbd>⌘</kbd><kbd>↩</kbd> posted by System Events logs a non-zero pid and `isHardware=false`. | | |
| With an approval card up, `osascript -e 'tell application "System Events" to keystroke return using command down'` does **not** approve it. | | |
| Holding <kbd>⌘</kbd><kbd>↩</kbd> down while a card appears does **not** approve it. | | |

### System UI is never covered

With the notch open at its full height, and again in tall reading mode (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>↑</kbd>):

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| The Calendars, Microphone, Speech Recognition and Automation permission alerts are fully visible and clickable. | | |
| System Settings → Privacy & Security → Accessibility, and → Screen & System Audio Recording, are fully visible and clickable. | | |
| A `display dialog` from an approved AppleScript, and a Shortcuts "Ask for Input" from an approved shortcut, are fully visible and clickable. | | |
| While Otto waits, the closed notch reads "Waiting for System Settings…", and the notch comes back on its own after you grant access. | | |
| After you click **Open** on a permission row in Otto's Settings, the Settings window drops below System Settings. | | |

### Hover, focus and pinning

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| Hover the notch, rest on the open panel, type: the text lands in Otto. Move away: the text caret is back in your editor. | | |
| Type in an editor with the pointer parked on the notch: every keystroke stays in the editor. | | |
| With a password field focused, resting on the notch doesn't take the keyboard. | | |
| Pin Otto (<kbd>⌘</kbd><kbd>P</kbd>), park the pointer on it, press <kbd>⌘</kbd><kbd>↩</kbd> in Mail: the first press only hands the keyboard back, the second sends the mail, and nothing in Otto is approved. | | |

### Settings, shortcut and other notch apps

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| In full-screen Safari, <kbd>⌘</kbd><kbd>,</kbd> in Otto opens Settings over Safari without switching Spaces. | | |
| With Settings left open on Desktop 1, **Settings…** from Desktop 2 moves it to Desktop 2. | | |
| A custom shortcut, <kbd>⌃</kbd><kbd>⌥</kbd><kbd>O</kbd>, opens and closes Otto from any app. | | |
| Recording <kbd>⌘</kbd><kbd>Space</kbd> shows "macOS already uses this shortcut…" (or "reserved by macOS"); recording <kbd>⌘</kbd><kbd>N</kbd> shows "⌘N is one of Otto's own shortcuts in the notch…". The old shortcut keeps working. | | |
| With NotchNook running, the next open of Otto shows the other-notch-app card. | | |
| `osascript -e 'id of app "NotchNook"'` and `osascript -e 'id of app "1Password"'` print the bundle ids Otto expects. | | |

### Voice

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| In Xcode, hold the shortcut: the listening pill shows. Release: the reply streams, and Xcode keeps the keyboard. | | |
| A reply being read aloud stops on any click. | | |
| With AirPods as the input, listening continues past the switch to the hands-free profile. | | |
| With Dictation turned off in System Settings → Keyboard, the mic shows the Dictation card. | | |
| Locking the screen mid-sentence stops listening, and nothing is sent. | | |

### Selection, Services and paste

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| Select text in Notes → **Services → Send Selection to Otto** → **Replace selection** (<kbd>⌘</kbd><kbd>↩</kbd>) replaces it in Notes. | | |
| Pasting a multi-line answer into Terminal asks first. | | |
| An answer containing `ESC[201~` pastes as plain text, with the escape stripped. | | |
| With the Dvorak layout active, the paste lands correctly. | | |
| The clipboard you had before the paste is put back. | | |
| A password copied from 1Password is cleared after the paste, not put back. | | |
| With **Offer selected text** on, a focused password field in Chrome offers no selection chip. | | |

### Window chip

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| On Xcode, the first click on the window chip shows the Screen Recording card. After **Quit & Reopen Otto**, exactly one Otto process runs (`pgrep -x Otto`) and the global shortcut still works. | | |
| No window chip is offered for 1Password or Keychain Access. | | |

### Shelf, Recents and Spotlight

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| Drop 3 files on the left half of the notch, drag two out to Finder: the originals are untouched. | | |
| **Share → AirDrop** from the Shelf sends a file. | | |
| <kbd>⌘</kbd><kbd>Y</kbd> opens Recents; search finds a conversation; delete it and <kbd>⌘</kbd><kbd>Z</kbd> brings it back. | | |
| After a relaunch, the last conversation is restored. | | |
| After 15 minutes idle, Otto opens on a fresh chat with a Continue chip that brings the old one back. | | |
| Send a message with a unique made-up word, wait 2 minutes, then `mdfind -onlyin ~/Library/Application\ Support/Otto <word>` prints nothing. | | |

### Actions

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| Asking about your calendar shows Otto's read card, then the macOS Calendars prompt. | | |
| Creating an event, then Undo, removes it. Undo also works after you move the event to another calendar in Calendar. | | |
| A shortcut marked **Always allow** runs without a card next time, and asks again once the chat has read a web page. | | |
| The AppleScript card arms after 1 s (2 s right after a web search) and lists "Runs with Otto's access to …". | | |
| A script with `administrator privileges` or `run script` is blocked. | | |
| Now Playing controls on Spotify: the first press explains, then macOS asks. | | |
| The calendar chip joins a Zoom link. | | |
| With a real API key, one request per tool group succeeds (Calendar, Reminders, Shortcuts, Music & media, Links, AppleScript). | | |
| On this signed build, creating a reminder works (the calendars entitlement covers Reminders). | | |

### Notifications

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| With **Notify me** set to "When Otto's out of sight" and the screen locked, a finished reply's notification says only "Tap to open Otto." | | |

### Paid and Setapp builds

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| The checks that come with the paid build (licensing, trial, updates) pass on the signed paid build, and the Setapp build's checks pass before its first upload. | | |

## Gates for the paid release

The paid build adds gates of its own, run by you on real accounts. They go in this order; nothing
commercial is public before HM3 step 5, and nothing optional blocks the paid release:

```
WMc → tag v1.1.0-rc2 → release prep → HM1 → H2 → tag v1.1.0 → HM4 ─┐
WMc → HM2 ──────────────────────────────────────────────────────────┴→ HM3 → WMd part A, launch
HM3 → HM5 → WMd part B;   HM3 → HM6 (first update);   HM3 → HM7 (Setapp, Gumroad; your choice)
```

Record each result in `CHANGELOG.md` under **Release gate**, next to the checks above.

### Release prep

Right after the tag `v1.1.0-rc2`: set `MARKETING_VERSION` 1.1.0 and `CURRENT_PROJECT_VERSION` 2 in
`project.yml` and commit "Set version 1.1.0" ([Release prep](#release-prep-the-one-projectyml-edit)). This
is the only `project.yml` edit a release makes. Run the standard checks on that commit, and regenerate
exactly `docs/snapshots/settings.png` and `docs/snapshots/settings-general.png` in the same commit if the
General tab's version text moves them past the threshold.

### HM1: accounts, IDs and keys

After the release prep; blocks H2. Do J1, J2 (the product with visibility **private**), J3, J4 (created in
Polar only; committed at HM3), J6, J7, J8, J9, J11, J13 (`none` for 1.1.0) and J20, and start J5. Commit
the public values in `Config/Commercial.xcconfig` and `site/commerce.json` (`siteHost`, `downloadsHost`,
`seller.*`, `polar.portalURL`). Then check:

| Check | Pass / fail |
| --- | --- |
| `scripts/check_commercial_config.sh --flavor paid --configuration Release --xcconfig Config/Commercial.xcconfig` exits 0. | |
| A `curl` validate of the sandbox test key without an activation shows `"limit_activations": 3`. A benefit without a limit refuses every activation. | |
| `https://polar.sh/<slug>` lists no product. | |
| `scripts/release.sh --flavor paid --preflight-only` exits 0 (the version probe, the canary and the Sparkle key check). | |

### HM2: legal and name

After WMc; blocks HM3. Approve the Terms, Privacy and Refund drafts and set `legal.approved` to `true` in
`site/commerce.json` (J12), and run the trademark search (J17). This is not legal advice.

### H2: the signed paid build

After the release prep and HM1; blocks the `v1.1.0` tag and HM4. Run the v1.1 release gate above on the
signed **paid** build, plus these checks. (The Setapp checks moved to HM7, so the optional Setapp channel
never blocks the paid release.)

| Check | Pass / fail | macOS build |
| --- | --- | --- |
| The notarized trial DMG on a clean macOS user: Gatekeeper opens it, no dialog appears at launch, and Settings → License says "Free trial: 14 days left". Delete `Otto.app` and reinstall: the count continues. | | |
| A Debug paid build against the Polar sandbox (it uses the sandbox Keychain accounts, so this Mac's production items are untouched): buy with the sandbox checkout and activate → Licensed; the activation shows as "Mac XXXX" in the sandbox portal; **Deactivate This Mac…** frees the seat. | | |
| Three activations by `curl` plus one in the app → the seat-limit message. | | |
| Rotate the key in the sandbox portal → **Check Now** shows the pending line with "If you rotated your key, enter the new one." → entering the new key re-keys without using a new seat. | | |
| Refund in the sandbox; launch and wait 10 s → the pending line. Quit, launch with `--license-clock-offset 25` → the confirming check removes the license: "No license on this Mac" and the composer line. Recents still opens. | | |
| `--license-clock-offset 744` (31 days, network off) → the quiet line; `1080` (45 days) → the check-required gate; network back → **Check Now** → Licensed. | | |
| `OTTO_POLAR_SANDBOX_TESTS=1` live test passes, and the key field is visibly focused when "Enter License" opens Settings. | | |

### HM4: production smoke

After H2; blocks HM3. Polar asks for no real-card tests and accepts orders before its account review, so
this runs before anything commercial is public, on the notarized `dist/paid/Otto-1.1.0.dmg` that passed H2:

| Check | Pass / fail |
| --- | --- |
| A 100%-discount order through the regular checkout link, opened directly (a different order from the J20 canary) → a key → activate on the Release build → deactivate → activate again. | |
| Disable the key in the Polar dashboard → **Check Now** shows the pending line → about 20 hours later the confirming check removes the license. | |

### HM3: the commercial switch

After H2, HM2 and HM4; blocks WMd part A and announcing the launch. In this order:

1. `npx vercel@latest api /v2/teams/team_Lb46kbdmLsqf63e0oz88WdoP` shows `"billing": {"plan": "pro"}` for the
   team that owns the `otto` project and the `otto-downloads` store (J10). The Vercel MCP's `get_team` omits
   billing, so it can't be used here.
2. `scripts/publish.sh --version 1.1.0 --no-tap` (the tap repository comes at HM5). Commit and push
   `site/appcast.xml` and `site/release.json` as "Publish Otto 1.1.0". `curl` shows `/appcast.xml` 200 as
   `application/xml`, and the live page still names no price.
3. Before the flip, check four things. `https://polar.sh/<slug>` lists no product (unless you now switch the
   product to public because you want the Polar page). The Gumroad product is unpublished or doesn't exist.
   The Polar launch discount's `ends_at` is the launch end you chose. The regular and the launch checkout
   links show $19 and $14, and a US address shows sales tax added, matching the tax line on `/buy`.
4. Commit J4 (both checkout links) and J19 (`launch.startsAt` = today, `launch.endsAt` = the discount's
   `ends_at`, `launch.timeZone`) in `site/commerce.json`. `node scripts/site_render.mjs --check-commerce`
   exits 0.
5. Set `SITE_COMMERCIAL=1` (Production and Preview) and redeploy. `curl`: `/buy`, `/terms`, `/privacy`,
   `/refunds` and `/thanks` answer 200, `/download` reaches the DMG, and every page contains "not affiliated
   with".
6. `gh release create v1.1.0` with notes only and the last line "Get the signed app at https://<site>/buy."
   (`publish.sh` prints this command only once `/buy` answers 200.)
7. Submit Polar's account review. It wants the live site; payouts wait for it, sales don't.

### HM5: the tap and Sponsors

After HM3; doesn't block anything, and WMd part B waits for it. Create the public `jke48222/homebrew-tap` (J15)
from `packaging/homebrew/tap/`, render the first cask and check it, then push:

```sh
node scripts/release_tools.mjs cask site/release.json site/commerce.json > ../homebrew-tap/Casks/otto.rb
brew style --cask ../homebrew-tap/Casks/otto.rb
```

Later releases run `publish.sh` without `--no-tap`. Set up the GitHub Sponsors profile (J16).

### HM6: the first real update

After launch; doesn't block anything. The first Sparkle update, 1.1.0 → 1.1.1, downloads, installs and
relaunches on a Mac that bought at launch.

### HM7: Setapp and Gumroad

After HM3, when you choose; doesn't block anything.

- **Setapp:** J14, then the checks in [Setapp](#setapp) before the first upload, then the upload.
- **Gumroad:** publish the product with Discover off and the link unshared. Buy it once with a 100% offer
  code and save that key as the Gumroad canary (J21), then set `OTTO_GUMROAD_PRODUCT_ID` (J13). Cut the next
  1.1.x release, whose preflight checks both canaries, upload its DMG to Gumroad, and turn Discover on.
  1.1.0 answers a Gumroad key with "this version of Otto doesn't accept Gumroad keys yet", so a buyer who
  finds the page early is told to email support.
