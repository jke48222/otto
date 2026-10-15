# Setapp configuration

Two things the Setapp build (`project-setapp.yml`) needs from Jalen's Setapp developer account: open items J14 and
J22.

## Public key (J14)

The Setapp build copies `setappPublicKey.pem` from this folder into the app bundle, where the Setapp Framework
looks for it under that default name.

Where it comes from: the Setapp developer account, Apps, Add new version, Download public key. It is a public key,
so it is committed here once Jalen has it.

Until then the file doesn't exist. A Debug Setapp build warns about it, and a Release Setapp build stops in its
"Check commercial configuration" phase (`scripts/check_commercial_config.sh`). CI copies
`scripts/tests/fixtures/commercial/setappPublicKey.pem` here for its fixture Release build only while the real key
is absent, and deletes it afterwards.

## Setapp AI OAuth client (J22)

Setapp AI reaches Setapp's AI Gateway through the Setapp Framework's SetappAI module, which needs an OAuth client
of Otto's own: a client id and a secret. Where they come from: the Setapp developer account, Apps, OAuth Clients,
Add new (one client for Otto's Setapp build, since Setapp counts usage per client), then View.

Both go in `Config/Local.xcconfig`, which git ignores and `Config/Signing.xcconfig` already includes:

    OTTO_SETAPP_AI_CLIENT_ID = <client id>
    OTTO_SETAPP_AI_CLIENT_SECRET = <secret>

xcconfig reads `//` as a comment, so write `//` inside a value as `/$()/`. `project-setapp.yml` puts the values in
Info.plist as `OttoSetappAIClientID` and `OttoSetappAIClientSecret`, and `SetappSDKTransport.configureIfNeeded()`
hands them to the SDK the first time Otto needs Setapp AI. Otto never logs the secret, and the build's check phase
runs with `showEnvVars: false`, so Xcode doesn't print build settings into the log. Other tools that dump build
settings (`xcodebuild -showBuildSettings`) will show it, so don't paste those.

The secret ships inside the app. That is Setapp's design for macOS: the SDK pairs the client with an authorization
code from the member's Setapp app to get a token with scope `ai.openai`, so the secret alone reaches no one's
credits. Keeping it out of git keeps it out of the public repository, not out of the app.

Until the values exist, a Debug Setapp build warns and Setapp AI reports itself not set up, so Settings offers the
member's own Anthropic key instead. A Release Setapp build stops in its "Check commercial configuration" phase, and
`release.sh` stops in preflight (it reads `Config/Local.xcconfig` next to `Config/Commercial.xcconfig`).
`scripts/audit_flavor.sh --flavor setapp` checks that a Release app carries both values. CI's fixture Release build
uses the fake client in `scripts/tests/fixtures/commercial/valid.xcconfig`.
