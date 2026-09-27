## What does this change?

<!-- A short summary of the change and why it's needed. -->

Closes #

## How was it tested?

<!-- Unit tests, --selftest, manual steps on which Mac/display setup, --demo vs real API, etc. -->

## Screenshots

<!-- For UI changes, add before/after images (scripts/snapshot.sh renders them into docs/snapshots/). -->

## Checklist

- [ ] `scripts/build.sh` succeeds with no new warnings.
- [ ] Unit tests pass (`xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build test`), and new behavior has tests.
- [ ] UI changes include before/after snapshots.
- [ ] Notch interaction changes were checked with `--selftest` or by hand.
- [ ] No third-party dependencies, force-unwraps, `print` calls or placeholder code.
- [ ] No secrets, team IDs or personal data.
- [ ] `README.md`, `docs/SPEC.md` and `CHANGELOG.md` (under **Unreleased**) are updated where relevant.
- [ ] I've read [CONTRIBUTING.md](https://github.com/jke48222/otto/blob/main/CONTRIBUTING.md) and agree to the [Code of Conduct](https://github.com/jke48222/otto/blob/main/CODE_OF_CONDUCT.md).
