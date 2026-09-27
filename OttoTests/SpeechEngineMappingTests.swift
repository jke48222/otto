//
//  SpeechEngineMappingTests.swift
//  OttoTests
//
//  SFSpeechEngine's pure rules: which Speech errors become which VoiceError (Dictation off, assets missing,
//  permission denied, no speech), and when an audio route change restarts the microphone or stops.
//

import XCTest
@testable import Otto

final class SpeechEngineMappingTests: XCTestCase {
    private func map(_ domain: String, _ code: Int, _ description: String = "Something failed") -> VoiceError? {
        SFSpeechEngine.voiceError(domain: domain, code: code, description: description, localeName: "English (India)")
    }

    // MARK: - voiceError

    func testDictationDisabledMapsToItsOwnCase() {
        XCTAssertEqual(map("kLSRErrorDomain", 201, "Siri and Dictation are disabled"), .dictationDisabled)
    }

    func testMissingOnDeviceAssetsMapToOnDeviceUnavailable() {
        XCTAssertEqual(map("kLSRErrorDomain", 102), .onDeviceUnavailable(localeName: "English (India)"))
    }

    func testDeniedRecognitionMapsToSpeechDenied() {
        XCTAssertEqual(map("kAFAssistantErrorDomain", 1700), .speechDenied)
    }

    func testNoSpeechAndCancelledRequestsAreNotErrors() {
        XCTAssertNil(map("kAFAssistantErrorDomain", 1110, "No speech detected"))
        XCTAssertNil(map("kLSRErrorDomain", 301, "Recognition request was canceled"))
    }

    func testEverythingElseIsARecognitionErrorWithItsDescription() {
        XCTAssertEqual(map("kAFAssistantErrorDomain", 1101, "Connection lost"), .recognition("Connection lost"))
        XCTAssertEqual(map("kLSRErrorDomain", 300, "Failed to initialize"), .recognition("Failed to initialize"))
        XCTAssertEqual(map(NSURLErrorDomain, 201, "Offline"), .recognition("Offline"))
        // The same codes in another domain are not the Speech ones.
        XCTAssertEqual(map("kAFAssistantErrorDomain", 201, "Other"), .recognition("Other"))
        XCTAssertEqual(map("kLSRErrorDomain", 1700, "Other"), .recognition("Other"))
        XCTAssertEqual(map("kLSRErrorDomain", 1110, "Other"), .recognition("Other"))
    }

    func testDictationDisabledCopyPointsToKeyboardSettings() {
        XCTAssertEqual(
            VoiceError.dictationDisabled.errorDescription,
            "Dictation is off. Turn on Dictation in System Settings → Keyboard to talk to Otto.")
    }

    // MARK: - routeChangeAction

    func testRouteChangeWithInputRestarts() {
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 16_000, channelCount: 1, restartsSoFar: 0), .restart)
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 48_000, channelCount: 2, restartsSoFar: 2), .restart)
    }

    func testRouteChangeStopsAfterTheRestartCap() {
        XCTAssertEqual(VoiceMetrics.maxEngineRestarts, 3)
        XCTAssertEqual(
            SFSpeechEngine.routeChangeAction(
                sampleRate: 48_000, channelCount: 1, restartsSoFar: VoiceMetrics.maxEngineRestarts),
            .stop)
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 48_000, channelCount: 1, restartsSoFar: 7), .stop)
    }

    func testRouteChangeWithoutInputStops() {
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 0, channelCount: 1, restartsSoFar: 0), .stop)
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 44_100, channelCount: 0, restartsSoFar: 0), .stop)
        XCTAssertEqual(SFSpeechEngine.routeChangeAction(sampleRate: 0, channelCount: 0, restartsSoFar: 0), .stop)
    }
}
