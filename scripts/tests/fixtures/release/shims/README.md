# Command shims for the release script tests

`scripts/tests/release_script_test.sh` puts `shims/` first on `PATH` and points `SPARKLE_BIN` at `sparkle-bin/`, so
`release.sh` and `publish.sh` never reach the network, the Keychain, Xcode or Vercel. Every shim appends one line per
call to `$SHIM_LOG` (`<tool> <arguments>`), and `curl` also logs the request body it reads from stdin
(`curl-body <body>`). The test sets the answers through `SHIM_*` variables; each shim's header lists the ones it reads.
