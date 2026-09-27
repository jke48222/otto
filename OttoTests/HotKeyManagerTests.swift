//
//  HotKeyManagerTests.swift
//  Otto
//

import Carbon.HIToolbox
import XCTest
@testable import Otto

/// Records registrations instead of calling Carbon, so no test ever owns a real hot key.
@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    /// Status to return per combo; missing entries succeed.
    var statuses: [HotKeyCombo: OSStatus] = [:]
    private(set) var registered: HotKeyCombo?
    private(set) var registerCalls: [HotKeyCombo] = []
    private(set) var unregisterCalls = 0
    private var handler: (@MainActor (HotKeyEventKind) -> Void)?

    func register(_ combo: HotKeyCombo, handler: @escaping @MainActor (HotKeyEventKind) -> Void) -> OSStatus {
        registerCalls.append(combo)
        let status = statuses[combo] ?? noErr
        if status == noErr {
            registered = combo
            self.handler = handler
        }
        return status
    }

    func unregister() {
        unregisterCalls += 1
        registered = nil
        handler = nil
    }

    /// What Carbon would deliver for the registered combo.
    func deliver(_ kind: HotKeyEventKind) {
        handler?(kind)
    }
}

/// Counts what the manager dispatches.
@MainActor
private final class HotKeyCallbackCounter {
    var presses = 0
    var releases = 0
}

@MainActor
final class HotKeyManagerTests: XCTestCase {
    private let commandK = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey | optionKey))
    private let controlJ = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey))

    private func makeManager(
        combo: HotKeyCombo = .optionSpace
    ) -> (HotKeyManager, FakeHotKeyRegistrar, HotKeyCallbackCounter) {
        let registrar = FakeHotKeyRegistrar()
        let counter = HotKeyCallbackCounter()
        let manager = HotKeyManager(combo: combo, onPress: { counter.presses += 1 },
                                    onRelease: { counter.releases += 1 }, registrar: registrar)
        return (manager, registrar, counter)
    }

    private func assertSuccess(_ result: Result<Void, HotKeyManager.RegistrationError>,
                               file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result { XCTFail("expected success, got \(error)", file: file, line: line) }
    }

    private func assertFailure(_ result: Result<Void, HotKeyManager.RegistrationError>,
                               _ expected: HotKeyManager.RegistrationError,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("expected \(expected), got success", file: file, line: line)
        case .failure(let error): XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Initializer

    func testTrailingClosureInitializerStillCompilesAndBindsToPress() {
        var pressed = false
        let manager = HotKeyManager { pressed = true }
        XCTAssertEqual(manager.combo, .optionSpace)
        XCTAssertFalse(manager.isRegistered, "creating the manager registers nothing")
        manager.handle(.pressed)
        XCTAssertTrue(pressed)
        manager.handle(.released)
    }

    // MARK: - Press and release

    func testPressAndReleaseDispatchThroughTheRegistrar() {
        let (manager, registrar, counter) = makeManager()
        XCTAssertTrue(manager.register())
        XCTAssertEqual(registrar.registered, .optionSpace)

        registrar.deliver(.pressed)
        XCTAssertEqual(counter.presses, 1)
        XCTAssertEqual(counter.releases, 0)
        registrar.deliver(.released)
        XCTAssertEqual(counter.releases, 1)
    }

    func testHandleIgnoresRepeatedPressAndUnmatchedRelease() {
        let (manager, _, counter) = makeManager()
        manager.handle(.released)
        XCTAssertEqual(counter.releases, 0, "a release without a press is dropped")
        manager.handle(.pressed)
        manager.handle(.pressed)
        XCTAssertEqual(counter.presses, 1)
        manager.handle(.released)
        manager.handle(.released)
        XCTAssertEqual(counter.releases, 1)
        manager.handle(.pressed)
        XCTAssertEqual(counter.presses, 2)
    }

    func testUnregisterWhileHeldDeliversTheRelease() {
        let (manager, registrar, counter) = makeManager()
        manager.register()
        registrar.deliver(.pressed)
        manager.unregister()
        XCTAssertEqual(counter.releases, 1)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertNil(registrar.registered)
        registrar.deliver(.released)
        XCTAssertEqual(counter.releases, 1, "the registrar's handler is gone")
    }

    // MARK: - Registration

    func testRegisterIsIdempotent() {
        let (manager, registrar, _) = makeManager()
        XCTAssertTrue(manager.register())
        XCTAssertTrue(manager.register())
        XCTAssertEqual(registrar.registerCalls, [.optionSpace])
        XCTAssertTrue(manager.isRegistered)
        XCTAssertNil(manager.lastRegistrationError)
    }

    func testRegisterFailureMapsStatus() {
        let (manager, registrar, _) = makeManager()
        registrar.statuses[.optionSpace] = OSStatus(eventHotKeyExistsErr)
        XCTAssertFalse(manager.register())
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.lastRegistrationError, .alreadyInUse)

        registrar.statuses[.optionSpace] = OSStatus(eventInternalErr)
        XCTAssertFalse(manager.register())
        XCTAssertEqual(manager.lastRegistrationError, .failed(OSStatus(eventInternalErr)))

        registrar.statuses[.optionSpace] = nil
        XCTAssertTrue(manager.register())
        XCTAssertNil(manager.lastRegistrationError)
    }

    func testUnregisterClearsStateAndIsIdempotent() {
        let (manager, registrar, _) = makeManager()
        manager.register()
        manager.unregister()
        manager.unregister()
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(registrar.unregisterCalls, 1)
        XCTAssertNil(manager.lastRegistrationError)
    }

    // MARK: - update(to:)

    func testUpdateSwapsTheRegistration() {
        let (manager, registrar, counter) = makeManager()
        manager.register()
        assertSuccess(manager.update(to: commandK))
        XCTAssertEqual(manager.combo, commandK)
        XCTAssertEqual(registrar.registered, commandK)
        XCTAssertEqual(registrar.registerCalls, [.optionSpace, commandK])
        XCTAssertTrue(manager.isRegistered)

        registrar.deliver(.pressed)
        XCTAssertEqual(counter.presses, 1, "the new registration dispatches to the same callbacks")
    }

    func testUpdateFailureReRegistersThePreviousCombo() {
        let (manager, registrar, counter) = makeManager()
        registrar.statuses[commandK] = OSStatus(eventHotKeyExistsErr)
        manager.register()

        assertFailure(manager.update(to: commandK), .alreadyInUse)
        XCTAssertEqual(manager.combo, .optionSpace, "combo only changes on success")
        XCTAssertEqual(registrar.registered, .optionSpace)
        XCTAssertEqual(registrar.registerCalls, [.optionSpace, commandK, .optionSpace])
        XCTAssertTrue(manager.isRegistered)

        registrar.deliver(.pressed)
        XCTAssertEqual(counter.presses, 1, "the restored registration still works")
    }

    func testUpdateFailureWhileUnregisteredLeavesItUnregistered() {
        let (manager, registrar, _) = makeManager()
        registrar.statuses[commandK] = OSStatus(eventInternalErr)

        assertFailure(manager.update(to: commandK), .failed(OSStatus(eventInternalErr)))
        XCTAssertEqual(manager.combo, .optionSpace)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(registrar.registerCalls, [commandK], "nothing to restore")
    }

    func testUpdateWhileUnregisteredRegistersTheNewCombo() {
        let (manager, registrar, _) = makeManager()
        assertSuccess(manager.update(to: controlJ))
        XCTAssertEqual(manager.combo, controlJ)
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(registrar.registered, controlJ)
    }

    func testUpdateToTheRegisteredComboIsANoOp() {
        let (manager, registrar, _) = makeManager()
        manager.register()
        assertSuccess(manager.update(to: .optionSpace))
        XCTAssertEqual(registrar.registerCalls, [.optionSpace])
        XCTAssertEqual(registrar.unregisterCalls, 0)
    }
}
