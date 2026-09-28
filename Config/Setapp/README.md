# Setapp public key

The Setapp build (`project-setapp.yml`) copies `setappPublicKey.pem` from this folder into the app bundle, where the
Setapp Framework looks for it under that default name.

Where it comes from: the Setapp developer account, Apps, Add new version, Download public key. It is a public key,
so it is committed here once Jalen has it (open item J14 in SPEC-v2 §14.20).

Until then the file doesn't exist. A Debug Setapp build warns about it, and a Release Setapp build stops in its
"Check commercial configuration" phase (`scripts/check_commercial_config.sh`). CI copies
`scripts/tests/fixtures/commercial/setappPublicKey.pem` here for its fixture Release build only while the real key
is absent, and deletes it afterwards.
