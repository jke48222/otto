//
//  LaunchOptions.swift
//  Otto
//
//  Command-line switches understood by the app:
//    --demo              use MockLLMClient instead of the Anthropic API
//    --open              open the notch (focused) right after launch
//    --snapshot <dir>    render UI snapshots into <dir> and exit (also accepts --snapshot=<dir>)
//    --selftest <dir>    drive the real notch through a scripted session, write a JSON report and
//                        PNG captures into <dir>, and exit (0 = every step passed)
//    --promo <dir>       show the off-screen promo stage for one scene and play it when
//                        scripts/record_promo.swift says go (handshake files live in <dir>)
//    --promo-scene <n>   which promo scene to play (default: hero)
//    --promo-stills <dir> render the marketing stills (docs/media) into <dir> and exit
//
//  --snapshot, --selftest and the --promo flags drive developer tooling in Otto/Debug, which is
//  compiled only into Debug builds (or Release with OTTO_TOOLS); a shipping build ignores them.
//

import Foundation

enum LaunchOptions {
    static let arguments: [String] = CommandLine.arguments

    /// `--demo` → MockLLMClient instead of AnthropicClient.
    static var demo: Bool { arguments.contains("--demo") }

    /// `--open` → open the notch at launch (focused).
    static var startOpen: Bool { arguments.contains("--open") }

    /// `--snapshot <dir>` (or `--snapshot=<dir>`). Relative paths resolve against the current directory
    /// and `~` is expanded.
    static var snapshotDirectory: URL? {
        directory(for: "--snapshot")
    }

    /// `--selftest <dir>` (or `--selftest=<dir>`), resolved like `snapshotDirectory`.
    static var selfTestDirectory: URL? {
        directory(for: "--selftest")
    }

    private static func directory(for option: String) -> URL? {
        guard let rawPath = value(for: option) else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: base).standardizedFileURL
    }

    /// `--promo <dir>`: the promo stage's handshake directory (see `PromoStage`).
    static var promoDirectory: URL? {
        directory(for: "--promo")
    }

    /// `--promo-scene <name>`: the scene the promo stage plays.
    static var promoScene: String {
        value(for: "--promo-scene") ?? "hero"
    }

    /// `--promo-stills <dir>`: where the marketing stills are written.
    static var promoStillsDirectory: URL? {
        directory(for: "--promo-stills")
    }

    /// True when the app is hosting an XCTest bundle.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Value of `--name value` or `--name=value`; nil when missing or empty.
    private static func value(for option: String) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == option {
                let next = index + 1
                guard arguments.indices.contains(next) else { return nil }
                let candidate = arguments[next]
                // A following flag means the value was omitted.
                guard !candidate.isEmpty, !candidate.hasPrefix("--") else { return nil }
                return candidate
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                let candidate = String(argument.dropFirst(prefix.count))
                return candidate.isEmpty ? nil : candidate
            }
        }
        return nil
    }
}
