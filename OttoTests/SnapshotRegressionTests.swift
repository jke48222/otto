//
//  SnapshotRegressionTests.swift
//  OttoTests
//
//  Renders the real snapshot scenes and compares the ones named in OTTO_SNAPSHOT_BASELINE (comma
//  separated, e.g. "closed,open-empty") with the committed PNGs in docs/snapshots. A scene passes when at
//  most 0.5 % of its pixels differ by more than 8/255 in any channel. Skipped when the variable is unset;
//  pass it through xcodebuild as TEST_RUNNER_OTTO_SNAPSHOT_BASELINE.
//

import XCTest
@testable import Otto

@MainActor
final class SnapshotRegressionTests: XCTestCase {
    private static let environmentKey = "OTTO_SNAPSHOT_BASELINE"
    private static let maxDifferingFraction = 0.005
    private static let channelTolerance = 8

    /// docs/snapshots in the source tree this test was compiled from.
    private static var baselineDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/snapshots", isDirectory: true)
    }

    func testRenderedScenesMatchTheCommittedBaseline() async throws {
        let requested = ProcessInfo.processInfo.environment[Self.environmentKey] ?? ""
        let scenes = requested
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !scenes.isEmpty else {
            throw XCTSkip("Set \(Self.environmentKey) (TEST_RUNNER_\(Self.environmentKey) for xcodebuild) to compare snapshots.")
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-snapshots-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }

        await SnapshotRenderer.renderAll(to: output)

        for scene in scenes {
            let name = scene.hasSuffix(".png") ? scene : scene + ".png"
            let baseline = Self.baselineDirectory.appendingPathComponent(name)
            let rendered = output.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: baseline.path) else {
                XCTFail("No baseline for \(name) in \(Self.baselineDirectory.path)")
                continue
            }
            guard FileManager.default.fileExists(atPath: rendered.path) else {
                XCTFail("SnapshotRenderer did not write \(name)")
                continue
            }
            do {
                let result = try ImageDiff.compare(baseline, rendered, tolerance: Self.channelTolerance)
                let percent = String(format: "%.3f", result.differingFraction * 100)
                XCTAssertLessThanOrEqual(
                    result.differingFraction, Self.maxDifferingFraction,
                    "\(name): \(percent)% of pixels differ by more than \(Self.channelTolerance)/255 "
                        + "(\(result.differingPixels) of \(result.totalPixels), max delta \(result.maxChannelDelta))"
                )
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
    }
}
