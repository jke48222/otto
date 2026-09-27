//
//  ScriptingToolsTests.swift
//  OttoTests
//
//  The four scripting tools with fake services: policies, result JSON, error codes and copy, approval
//  card bodies (capability chips included), what-you-see-is-what-runs, availability, and the demo
//  services that never reach Shortcuts, osascript or NSWorkspace.
//

import XCTest
@testable import Otto

final class ScriptingToolsTests: XCTestCase {
    private let logWater = ScriptShortcut(name: "Log Water", identifier: "4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91")
    private let resize = ScriptShortcut(name: "Resize Images", identifier: "C8B4A2E6-3F1D-4E9A-B7C5-2A4E6C8B0D37")

    private func context(dialogs: DialogRecorder? = nil) -> ToolRunContext {
        ToolRunContext(callID: "toolu_1", model: .opus5, options: ApprovalOptions(), reportProgress: { _ in },
                       reportSystemDialog: { dialogs?.record($0) })
    }

    private func text(_ result: ToolRunResult) -> String {
        result.output.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
    }

    private func assertThrows(_ code: ToolError.Code, _ expectedText: String? = nil, file: StaticString = #filePath,
                              line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as ToolError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            if let expectedText { XCTAssertEqual(error.toolResultText, expectedText, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Policies

    func testToolPolicies() {
        let shortcuts = FakeShortcuts()
        let list = ScriptListShortcutsTool(shortcuts: shortcuts)
        let run = ScriptRunShortcutTool(shortcuts: shortcuts)
        let script = ScriptRunAppleScriptTool(scripts: FakeScripts())
        let open = ScriptOpenURLTool(opener: FakeOpener())

        XCTAssertEqual([list.name, run.name, script.name, open.name],
                       ["list_shortcuts", "run_shortcut", "run_applescript", "open_url"])
        XCTAssertEqual([list.group, run.group, script.group, open.group], [.shortcuts, .shortcuts, .appleScript, .links])

        XCTAssertTrue(list.isConcurrencySafe)
        XCTAssertFalse(run.isConcurrencySafe || script.isConcurrencySafe || open.isConcurrencySafe)
        XCTAssertEqual(list.approvalRequirement(for: [:]),
                       .consentOnce(ConsentKey(rawValue: "shortcuts.list", label: "See your shortcut names")))
        XCTAssertEqual(script.approvalRequirement(for: script.sampleInput), .everyCall(rememberScope: nil))
        XCTAssertEqual(open.approvalRequirement(for: open.sampleInput), .everyCall(rememberScope: nil))

        XCTAssertFalse(list.producesUntrustedOutput)
        XCTAssertTrue(run.producesUntrustedOutput)
        XCTAssertTrue(script.producesUntrustedOutput)
        XCTAssertFalse(open.producesUntrustedOutput)
        XCTAssertNil(list.privateDataSource)
        XCTAssertEqual(run.privateDataSource, "a shortcut's output")
        XCTAssertEqual(script.privateDataSource, "your Mac")
        XCTAssertNil(open.privateDataSource)

        XCTAssertEqual([list.timeout, run.timeout, script.timeout, open.timeout],
                       [.seconds(15), .seconds(60), .seconds(10), .seconds(10)])
        XCTAssertEqual(list.rateLimit, ToolRateLimit(perTurn: 10, perHour: nil))
        XCTAssertEqual(run.rateLimit, ToolRateLimit(perTurn: 5, perHour: 30))
        XCTAssertEqual(script.rateLimit, ToolRateLimit(perTurn: 3, perHour: 20))
        XCTAssertEqual(open.rateLimit, ToolRateLimit(perTurn: 3, perHour: 20))
        XCTAssertEqual(script.minimumArmingDelay, .seconds(1))
        XCTAssertEqual(run.minimumArmingDelay, .milliseconds(350))
        XCTAssertEqual(open.minimumArmingDelay, .milliseconds(350))

        XCTAssertEqual([list.mayPresentUI, run.mayPresentUI, script.mayPresentUI, open.mayPresentUI],
                       [false, true, true, false])
        XCTAssertEqual([list.inheritsOttoPermissions, run.inheritsOttoPermissions, script.inheritsOttoPermissions,
                        open.inheritsOttoPermissions], [false, false, true, false])
    }

    func testApprovalLabels() {
        let shortcuts = FakeShortcuts()
        XCTAssertTrue(ScriptListShortcutsTool(shortcuts: shortcuts).approvalLabels(for: [:]) == ("Allow", "Not now"))
        XCTAssertTrue(ScriptRunShortcutTool(shortcuts: shortcuts).approvalLabels(for: [:]) == ("Run Shortcut", "Don't run"))
        XCTAssertTrue(ScriptRunAppleScriptTool(scripts: FakeScripts()).approvalLabels(for: [:]) == ("Run Script", "Don't run"))
        XCTAssertTrue(ScriptOpenURLTool(opener: FakeOpener()).approvalLabels(for: [:]) == ("Open", "Cancel"))
    }

    func testEgressStrings() {
        let run = ScriptRunShortcutTool(shortcuts: FakeShortcuts())
        XCTAssertEqual(run.egressStrings(in: ["name": "Log Water", "input": "500 ml"]), ["500 ml"])
        XCTAssertEqual(run.egressStrings(in: ["name": "Log Water"]), [])
        XCTAssertEqual(run.egressStrings(in: ["name": "Log Water", "input": ""]), [])
        let script = ScriptRunAppleScriptTool(scripts: FakeScripts())
        XCTAssertEqual(script.egressStrings(in: ["script": "beep", "purpose": "Beep."]), ["beep"])
        let open = ScriptOpenURLTool(opener: FakeOpener())
        XCTAssertEqual(open.egressStrings(in: ["url": "https://example.com/?q=1"]), ["https://example.com/?q=1"])
    }

    // MARK: - list_shortcuts

    func testListShortcutsResult() async throws {
        let shortcuts = FakeShortcuts()
        shortcuts.all = [resize, logWater, ScriptShortcut(name: "archive", identifier: "X")]
        let tool = ScriptListShortcutsTool(shortcuts: shortcuts)
        let result = try await tool.run([:], context: context())
        XCTAssertEqual(text(result),
                       #"{"count":3,"shortcuts":["archive","Log Water","Resize Images"],"status":"ok","truncated":false}"#)
        XCTAssertEqual(result.doneTitle, "Found 3 shortcuts")
        XCTAssertFalse(result.output.isError)

        let folderResult = try await tool.run(["folder": "Home"], context: context())
        XCTAssertEqual(shortcuts.listedFolders.last, "Home")
        XCTAssertEqual(folderResult.doneTitle, "Found 3 shortcuts")
    }

    func testListShortcutsCapsAt300Names() {
        let names = (1...420).map { String(format: "Shortcut %03d", $0) }
        let json = ScriptListShortcutsTool.resultJSON(names: names)
        guard case .object(let object)? = try? JSONValue.decode(json) else { return XCTFail("not JSON") }
        XCTAssertEqual(object["count"], .int(420))
        XCTAssertEqual(object["truncated"], .bool(true))
        XCTAssertEqual(object["shortcuts"]?.arrayValue?.count, 300)
        XCTAssertLessThanOrEqual(json.count, ToolOutput.maxTextCharacters)

        let longNames = (1...300).map { String(repeating: "n", count: 90) + "\($0)" }
        let capped = ScriptListShortcutsTool.resultJSON(names: longNames)
        XCTAssertLessThanOrEqual(capped.count, ToolOutput.maxTextCharacters)
        XCTAssertTrue(capped.contains(#""truncated":true"#))
    }

    func testListShortcutsErrorsPassThrough() async {
        let shortcuts = FakeShortcuts()
        shortcuts.listError = ToolError(code: .notFound, modelMessage: "There's no Shortcuts folder named “Work”.",
                                        userMessage: "No folder named “Work”")
        let tool = ScriptListShortcutsTool(shortcuts: shortcuts)
        await assertThrows(.notFound, "not_found: There's no Shortcuts folder named “Work”.") {
            _ = try await tool.run(["folder": "Work"], context: self.context())
        }
    }

    func testListShortcutsConsentCard() async {
        let tool = ScriptListShortcutsTool(shortcuts: FakeShortcuts())
        guard case .consent(let preview) = await tool.approvalBody(for: [:]) else { return XCTFail("consent body") }
        XCTAssertEqual(preview.title, "See your shortcut names")
        XCTAssertEqual(preview.symbol, "square.stack.3d.up")
        XCTAssertTrue(preview.body.contains("names of your shortcuts"))
        XCTAssertEqual(tool.describe(["folder": "Home"]).detail, "Folder “Home”")
    }

    // MARK: - run_shortcut

    func testRunShortcutOffersAnIdentifierScopeOnlyWhenTheNameResolves() {
        let shortcuts = FakeShortcuts()
        let tool = ScriptRunShortcutTool(shortcuts: shortcuts)
        XCTAssertEqual(tool.approvalRequirement(for: ["name": "Log Water"]), .everyCall(rememberScope: nil),
                       "no fresh listing yet")

        shortcuts.all = [logWater, resize]
        shortcuts.cacheIsFresh = true
        let expected = ApprovalScope(toolName: "run_shortcut", key: "shortcut:4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91",
                                     label: "“Log Water”")
        XCTAssertEqual(tool.approvalRequirement(for: ["name": "log water"]), .everyCall(rememberScope: expected))
        XCTAssertEqual(tool.approvalRequirement(for: ["name": "Tetris"]), .everyCall(rememberScope: nil))
    }

    func testRunShortcutValidationUsesTheFreshListing() {
        let shortcuts = FakeShortcuts()
        shortcuts.all = [logWater, resize]
        let tool = ScriptRunShortcutTool(shortcuts: shortcuts)
        XCTAssertNil(tool.validate(["name": "Tetris"]), "unknown until listed")

        shortcuts.cacheIsFresh = true
        let error = tool.validate(["name": "Log"])
        XCTAssertEqual(error?.code, .notFound)
        XCTAssertEqual(error?.modelMessage, "There's no shortcut named “Log”. Similar names: “Log Water”.")
        XCTAssertNil(tool.validate(["name": "Log Water", "input": "500 ml"]))
    }

    func testRunShortcutResultShapes() async throws {
        let shortcuts = FakeShortcuts()
        shortcuts.all = [logWater]
        let tool = ScriptRunShortcutTool(shortcuts: shortcuts)

        shortcuts.runResult = ScriptShortcutRunResult(output: "Logged 500 ml", outputWasNonText: false,
                                                      duration: .milliseconds(900))
        let result = try await tool.run(["name": "Log Water", "input": "500 ml"], context: context())
        XCTAssertEqual(text(result), #"{"output":"Logged 500 ml","status":"ok"}"#)
        XCTAssertEqual(result.doneTitle, "Ran “Log Water”")
        XCTAssertEqual(shortcuts.runs.first?.shortcut, logWater)
        XCTAssertEqual(shortcuts.runs.first?.input, "500 ml")
        XCTAssertEqual(shortcuts.runs.first?.timeout, .seconds(60))

        shortcuts.runResult = ScriptShortcutRunResult(output: nil, outputWasNonText: false, duration: .seconds(1))
        let empty = try await tool.run(["name": "Log Water"], context: context())
        XCTAssertEqual(text(empty), #"{"output":null,"status":"ok"}"#)
        XCTAssertNil(shortcuts.runs.last?.input)

        shortcuts.runResult = ScriptShortcutRunResult(output: nil, outputWasNonText: true, duration: .seconds(1))
        let file = try await tool.run(["name": "Log Water"], context: context())
        XCTAssertEqual(text(file),
                       #"{"note":"The shortcut produced a file, which Otto doesn't read.","output":null,"status":"ok"}"#)
    }

    func testRunShortcutLongOutputStaysInsideTheCap() {
        let json = ScriptRunShortcutTool.resultJSON(ScriptShortcutRunResult(
            output: String(repeating: "\"line\"\n", count: 5_000), outputWasNonText: false, duration: .seconds(1)))
        XCTAssertLessThanOrEqual(json.count, ToolOutput.maxTextCharacters)
        guard case .object(let object)? = try? JSONValue.decode(json) else { return XCTFail("not JSON") }
        XCTAssertEqual(object["truncated"], .bool(true))
        XCTAssertTrue(object["output"]?.stringValue?.hasSuffix("…(truncated)") ?? false)
    }

    func testRunShortcutErrors() async {
        let shortcuts = FakeShortcuts()
        shortcuts.all = [logWater]
        let tool = ScriptRunShortcutTool(shortcuts: shortcuts)
        await assertThrows(.notFound) { _ = try await tool.run(["name": "Tetris"], context: self.context()) }

        shortcuts.runError = ToolError(code: .timeout,
                                       modelMessage: "The shortcut didn't finish within 60 seconds and was stopped.",
                                       userMessage: "Stopped after 60 s")
        await assertThrows(.timeout, "timeout: The shortcut didn't finish within 60 seconds and was stopped.") {
            _ = try await tool.run(["name": "Log Water"], context: self.context())
        }
    }

    func testRunShortcutPresentationAndCard() async {
        let tool = ScriptRunShortcutTool(shortcuts: FakeShortcuts())
        let input: JSONValue = ["name": "Log Water", "input": "500 ml\nwith lemon"]
        let presentation = tool.describe(input)
        XCTAssertEqual(presentation.title, "Run “Log Water”")
        XCTAssertEqual(presentation.activeTitle, "Running “Log Water”…")
        XCTAssertEqual(presentation.doneTitle, "Ran “Log Water”")
        XCTAssertEqual(presentation.detail, "Input: 500 ml with lemon")
        XCTAssertEqual(presentation.disclosure, ToolDisclosure(label: "Input", text: "500 ml\nwith lemon", language: nil))

        let body = await tool.approvalBody(for: input)
        XCTAssertEqual(body, .shortcut(ShortcutPreview(name: "Log Water", input: "500 ml\nwith lemon")))
        let noInput = await tool.approvalBody(for: ["name": "Log Water"])
        XCTAssertEqual(noInput, .shortcut(ShortcutPreview(name: "Log Water", input: nil)))
    }

    @MainActor func testRunShortcutPrefetchesWhenAvailable() {
        let shortcuts = FakeShortcuts()
        let tool = ScriptRunShortcutTool(shortcuts: shortcuts)
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.actions.enabled = true
        XCTAssertTrue(tool.isAvailable(in: environment(settings)))
        XCTAssertEqual(shortcuts.prefetchCount, 1)

        settings.actions.groups.remove(.shortcuts)
        XCTAssertFalse(tool.isAvailable(in: environment(settings)))
        XCTAssertEqual(shortcuts.prefetchCount, 1)
    }

    // MARK: - run_applescript

    func testAppleScriptCardShowsPurposeSourceTargetsAndCapabilityChips() async {
        let tool = ScriptRunAppleScriptTool(scripts: FakeScripts())
        let script = """
        tell application "Finder" to set names to name of every file of desktop
        do shell script "curl -s https://example.com/upload"
        """
        let body = await tool.approvalBody(for: ["script": .string(script), "purpose": "Upload your desktop file names."])
        guard case .appleScript(let preview) = body else { return XCTFail("AppleScript body") }
        XCTAssertEqual(preview.purpose, "Upload your desktop file names.")
        XCTAssertEqual(preview.source, script)
        XCTAssertEqual(preview.targets, [ScriptChip(label: "Finder", isDanger: false, bundleID: "com.apple.finder")])
        XCTAssertEqual(preview.capabilities, [
            ScriptChip(label: "Runs shell commands", isDanger: true, bundleID: nil),
            ScriptChip(label: "Uses the network", isDanger: true, bundleID: nil),
        ])
        XCTAssertEqual(preview.lineCount, 2)
        XCTAssertEqual(preview.inheritedAccess, [], "the executor fills inherited access")
    }

    func testAppleScriptBlocksBeforeAsking() {
        let tool = ScriptRunAppleScriptTool(scripts: FakeScripts())
        XCTAssertEqual(tool.blockReason(for: ["script": "do shell script \"x\" with administrator privileges",
                                              "purpose": "x"]),
                       AppleScriptAnalyzer.BlockReason.administrator)
        XCTAssertNil(tool.blockReason(for: tool.sampleInput))
    }

    func testAppleScriptRequiresAutomationOnlyForRunningTargets() {
        let scripts = FakeScripts()
        scripts.running = ["Finder": ScriptRunningApp(name: "Finder", bundleID: "com.apple.finder")]
        let tool = ScriptRunAppleScriptTool(scripts: scripts)
        let input: JSONValue = [
            "script": "tell application \"Finder\" to beep\ntell application \"Music\" to pause\ntell application \"Finder\" to beep",
            "purpose": "Beep.",
        ]
        XCTAssertEqual(tool.requiredPermissions(for: input), [.automation(bundleID: "com.apple.finder", appName: "Finder")])
        XCTAssertEqual(tool.requiredPermissions(for: ["script": "beep", "purpose": "Beep."]), [])
    }

    func testAppleScriptResultShapes() async throws {
        let scripts = FakeScripts()
        let tool = ScriptRunAppleScriptTool(scripts: scripts)
        scripts.result = ScriptRunResult(output: "Macintosh HD, Backup", duration: .milliseconds(400))
        let result = try await tool.run(tool.sampleInput, context: context())
        XCTAssertEqual(text(result), #"{"output":"Macintosh HD, Backup","status":"ok"}"#)
        XCTAssertEqual(scripts.sources, ["tell application \"Finder\" to get name of every disk"])
        XCTAssertEqual(scripts.timeouts, [.seconds(10)])

        scripts.result = ScriptRunResult(output: "", duration: .milliseconds(10))
        let empty = try await tool.run(["script": "beep", "purpose": "Beep."], context: context())
        XCTAssertEqual(text(empty), #"{"output":"(no output)","status":"ok"}"#)
    }

    func testAppleScriptErrorsPassThrough() async {
        let scripts = FakeScripts()
        scripts.error = AppleScriptRunner.mapError(
            stderr: "0:44: execution error: Not authorized to send Apple events to Finder. (-1743)", exitCode: 1)
        let tool = ScriptRunAppleScriptTool(scripts: scripts)
        do {
            _ = try await tool.run(tool.sampleInput, context: context())
            XCTFail("expected permission_denied")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertEqual(error.recovery, .openSystemSettings(.automation(bundleID: "com.apple.finder", appName: "Finder")))
        } catch {
            XCTFail("unexpected \(error)")
        }

        let ranBefore = scripts.sources.count
        await assertThrows(.blocked) {
            _ = try await tool.run(["script": "run script \"beep\"", "purpose": "x"], context: self.context())
        }
        XCTAssertEqual(scripts.sources.count, ranBefore, "a blocked script never reaches osascript")
    }

    func testAppleScriptReportsTheAutomationPromptOfAnAppItLaunched() async throws {
        let scripts = FakeScripts()
        scripts.runDelay = .milliseconds(300)
        scripts.launchDuringRun = ScriptRunningApp(name: "Music", bundleID: "com.apple.Music")
        scripts.consentPendingUntil = Date().addingTimeInterval(0.15)
        let dialogs = DialogRecorder()
        let tool = ScriptRunAppleScriptTool(scripts: scripts, consentPollInterval: .milliseconds(20))
        _ = try await tool.run(["script": "tell application \"Music\" to play", "purpose": "Play music."],
                               context: context(dialogs: dialogs))
        XCTAssertEqual(dialogs.values.first, "Music")
        XCTAssertEqual(dialogs.values.last, .some(nil))
        XCTAssertEqual(dialogs.values.compactMap { $0 }.count, 1, "reported once while pending")
    }

    func testAppleScriptPresentation() {
        let tool = ScriptRunAppleScriptTool(scripts: FakeScripts())
        let presentation = tool.describe(tool.sampleInput)
        XCTAssertEqual(presentation.symbol, "applescript")
        XCTAssertEqual(presentation.title, "Run a script in Finder")
        XCTAssertEqual(presentation.activeTitle, "Running script…")
        XCTAssertEqual(presentation.doneTitle, "Ran script")
        XCTAssertEqual(presentation.detail, "List your disks.")
        XCTAssertEqual(presentation.disclosure?.language, "AppleScript")
        XCTAssertEqual(presentation.disclosure?.text, "tell application \"Finder\" to get name of every disk")
        XCTAssertEqual(tool.describe(["script": "beep", "purpose": "Beep."]).title, "Run a script")
    }

    // MARK: - open_url

    func testOpenURLValidationBlocksAndResult() async throws {
        let opener = FakeOpener()
        let tool = ScriptOpenURLTool(opener: opener)
        XCTAssertEqual(tool.validate(["url": "https://exa mple.com"])?.code, .invalidInput)
        XCTAssertNil(tool.blockReason(for: ["url": "https://exa mple.com"]))
        XCTAssertEqual(tool.blockReason(for: ["url": "http://127.1/"]), "Otto doesn't open local network addresses")
        XCTAssertNil(tool.validate(["url": "http://127.1/"]))
        XCTAssertEqual(tool.blockReason(for: ["url": "https://intranet/"]), "Otto doesn't open local network addresses")

        let result = try await tool.run(["url": "https://Example.com/docs?q=1"], context: context())
        XCTAssertEqual(text(result), #"{"host":"example.com","status":"opened"}"#)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs?q=1"])

        opener.succeeds = false
        await assertThrows(.failed, "failed: macOS couldn't open the link.") {
            _ = try await tool.run(["url": "https://example.com/"], context: self.context())
        }
        await assertThrows(.blocked) {
            _ = try await tool.run(["url": "http://192.168.1.1/"], context: self.context())
        }
        XCTAssertEqual(opener.opened.count, 2, "a blocked address never reaches the opener")
    }

    func testOpenURLCardAndPresentation() async {
        let tool = ScriptOpenURLTool(opener: FakeOpener())
        let body = await tool.approvalBody(for: ["url": "http://bücher.de/?q=1"])
        XCTAssertEqual(body, .url(URLPreview(url: "http://bücher.de/?q=1", displayHost: "bücher.de",
                                             punycodeHost: "xn--bcher-kva.de",
                                             warnings: ["Not secure (http)", "Unusual characters in address"])))
        let presentation = tool.describe(["url": "https://example.com/a"])
        XCTAssertEqual(presentation.title, "Open example.com")
        XCTAssertEqual(presentation.doneTitle, "Opened example.com")
        XCTAssertEqual(presentation.disclosure, ToolDisclosure(label: "Address", text: "https://example.com/a", language: nil))
    }

    // MARK: - WYSIWYG

    func testEveryInputStringIsShownVerbatimOnTheCard() async {
        let shortcuts = FakeShortcuts()
        let tools: [any OttoTool] = [
            ScriptListShortcutsTool(shortcuts: shortcuts),
            ScriptRunShortcutTool(shortcuts: shortcuts),
            ScriptRunAppleScriptTool(scripts: FakeScripts()),
            ScriptOpenURLTool(opener: FakeOpener()),
        ]
        let extraInputs: [String: [JSONValue]] = [
            "run_shortcut": [["name": "Log Water", "input": "line one\n\tline two  with  spaces"]],
            "run_applescript": [[
                "script": "tell application \"Finder\"\n\tset x to name of every disk\nend tell\n",
                "purpose": "Read the names of your disks, then stop.",
            ]],
            "open_url": [["url": "https://example.com/path?utm=%20x#frag"]],
        ]
        for tool in tools {
            for input in [tool.sampleInput] + (extraInputs[tool.name] ?? []) {
                XCTAssertNil(tool.validate(input), "\(tool.name) sample must be valid")
                let shown = await tool.approvalBody(for: input).displayedStrings
                guard case .object(let fields) = input else { continue }
                for (key, value) in fields where !tool.formattedFields.contains(key) {
                    guard let string = value.stringValue, !string.isEmpty else { continue }
                    XCTAssertTrue(shown.contains { $0.contains(string) }, "\(tool.name).\(key) is not shown verbatim")
                }
            }
        }
    }

    // MARK: - Availability

    @MainActor func testAvailabilityFollowsSettingsAndDemo() {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let shortcuts = FakeShortcuts()
        let tools: [any OttoTool] = [
            ScriptListShortcutsTool(shortcuts: shortcuts), ScriptRunShortcutTool(shortcuts: shortcuts),
            ScriptRunAppleScriptTool(scripts: FakeScripts()), ScriptOpenURLTool(opener: FakeOpener()),
        ]
        XCTAssertEqual(tools.map { $0.isAvailable(in: environment(settings)) }, [false, false, false, false],
                       "Actions are off by default")

        settings.actions.enabled = true
        XCTAssertEqual(tools.map { $0.isAvailable(in: environment(settings)) }, [true, true, false, true],
                       "AppleScript is its own opt-in")
        settings.actions.groups.insert(.appleScript)
        settings.actions.groups.remove(.links)
        XCTAssertEqual(tools.map { $0.isAvailable(in: environment(settings)) }, [true, true, true, false])

        let demoSettings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        XCTAssertEqual(tools.map { $0.isAvailable(in: environment(demoSettings, demo: true)) }, [true, true, false, true],
                       "demo counts every group but AppleScript as on")
    }

    // MARK: - Demo services

    func testDemoServicesAnswerFromFixedData() async throws {
        let shortcuts = DemoShortcutsService(delay: .milliseconds(1))
        let all = try await shortcuts.list(folder: nil)
        XCTAssertTrue(all.contains { $0.name == "Resize Images" })
        let photos = try await shortcuts.list(folder: "photos")
        XCTAssertEqual(photos.map(\.name), ["Resize Images"])
        XCTAssertEqual(shortcuts.cachedLookup("resize images"), .found(DemoShortcutsService.shortcuts[3]))

        let run = ScriptRunShortcutTool(shortcuts: shortcuts)
        let result = try await run.run(["name": "Resize Images", "input": "~/Desktop/Screenshots"], context: context())
        XCTAssertEqual(text(result),
                       #"{"output":"Resized 12 images to 1600 px (saved to ~/Desktop/Screenshots/Resized).","status":"ok"}"#)
        XCTAssertEqual(shortcuts.runs.map { $0.input }, ["~/Desktop/Screenshots"])

        let scripts = DemoAppleScriptRunner(delay: .milliseconds(1))
        let scriptTool = ScriptRunAppleScriptTool(scripts: scripts)
        let scriptResult = try await scriptTool.run(scriptTool.sampleInput, context: context())
        XCTAssertEqual(text(scriptResult), #"{"output":"Macintosh HD, Backup","status":"ok"}"#)
        // Finder is always running; the demo runner doesn't look.
        XCTAssertNil(scripts.runningApp(for: ScriptTarget(name: "Finder", bundleID: "com.apple.finder")))
        XCTAssertEqual(scriptTool.requiredPermissions(for: scriptTool.sampleInput), [])

        let opener = DemoURLOpener()
        let openTool = ScriptOpenURLTool(opener: opener)
        _ = try await openTool.run(["url": "https://www.apple.com/macos/"], context: context())
        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["https://www.apple.com/macos/"])
    }

    func testDemoShortcutErrorsMatchTheLiveCopy() async {
        let shortcuts = DemoShortcutsService(delay: .milliseconds(1))
        await assertThrows(.notFound, "not_found: There's no Shortcuts folder named “Work”.") {
            _ = try await shortcuts.list(folder: "Work")
        }
        await assertThrows(.notFound) { _ = try await shortcuts.resolve("Tetris") }
    }

    // MARK: - Helpers

    @MainActor private func environment(_ settings: AppSettings, demo: Bool = false) -> ToolEnvironment {
        ToolEnvironment(settings: settings, permissions: nil, model: .opus5, isDemo: demo)
    }
}

// MARK: - Fakes

private final class FakeShortcuts: ShortcutsProviding, @unchecked Sendable {
    struct Run: Equatable {
        let shortcut: ScriptShortcut
        let input: String?
        let timeout: Duration
    }

    private let lock = NSLock()
    private var state = (all: [ScriptShortcut](), cacheIsFresh: false, runs: [Run](), folders: [String?](),
                         prefetches: 0, listError: ToolError?.none, runError: ToolError?.none,
                         runResult: ScriptShortcutRunResult(output: "Done.", outputWasNonText: false, duration: .seconds(1)))

    var all: [ScriptShortcut] {
        get { lock.withLock { state.all } }
        set { lock.withLock { state.all = newValue } }
    }
    var cacheIsFresh: Bool {
        get { lock.withLock { state.cacheIsFresh } }
        set { lock.withLock { state.cacheIsFresh = newValue } }
    }
    var listError: ToolError? {
        get { lock.withLock { state.listError } }
        set { lock.withLock { state.listError = newValue } }
    }
    var runError: ToolError? {
        get { lock.withLock { state.runError } }
        set { lock.withLock { state.runError = newValue } }
    }
    var runResult: ScriptShortcutRunResult {
        get { lock.withLock { state.runResult } }
        set { lock.withLock { state.runResult = newValue } }
    }
    var runs: [Run] { lock.withLock { state.runs } }
    var listedFolders: [String?] { lock.withLock { state.folders } }
    var prefetchCount: Int { lock.withLock { state.prefetches } }

    func list(folder: String?) async throws -> [ScriptShortcut] {
        let (shortcuts, error) = lock.withLock { () -> ([ScriptShortcut], ToolError?) in
            state.folders.append(folder)
            return (state.all, state.listError)
        }
        if let error { throw error }
        return shortcuts
    }

    func resolve(_ name: String) async throws -> ScriptShortcut {
        let lookup = ScriptShortcutMatching.lookup(name, in: all)
        if case .found(let shortcut) = lookup { return shortcut }
        throw ScriptShortcutMatching.error(for: lookup, name: name)
            ?? ToolError(code: .failed, modelMessage: "lookup failed", userMessage: "lookup failed")
    }

    func run(_ shortcut: ScriptShortcut, input: String?, timeout: Duration) async throws -> ScriptShortcutRunResult {
        let (result, error) = lock.withLock { () -> (ScriptShortcutRunResult, ToolError?) in
            state.runs.append(Run(shortcut: shortcut, input: input, timeout: timeout))
            return (state.runResult, state.runError)
        }
        if let error { throw error }
        return result
    }

    func cachedLookup(_ name: String) -> ScriptShortcutLookup {
        let (fresh, shortcuts) = lock.withLock { (state.cacheIsFresh, state.all) }
        return fresh ? ScriptShortcutMatching.lookup(name, in: shortcuts) : .unknown
    }

    func prefetch() {
        lock.withLock { state.prefetches += 1 }
    }
}

private final class FakeScripts: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSources: [String] = []
    private var recordedTimeouts: [Duration] = []
    private var launched = false

    var result = ScriptRunResult(output: "ok", duration: .milliseconds(10))
    var error: ToolError?
    var running: [String: ScriptRunningApp] = [:]
    var runDelay: Duration = .zero
    /// Becomes running once a run starts.
    var launchDuringRun: ScriptRunningApp?
    /// Consent stays pending for the launched app until this moment.
    var consentPendingUntil: Date?

    var sources: [String] { lock.withLock { recordedSources } }
    var timeouts: [Duration] { lock.withLock { recordedTimeouts } }

    func run(_ source: String, timeout: Duration) async throws -> ScriptRunResult {
        lock.withLock {
            recordedSources.append(source)
            recordedTimeouts.append(timeout)
            launched = true
        }
        if runDelay > .zero { try await Task.sleep(for: runDelay) }
        if let error { throw error }
        return result
    }

    func runningApp(for target: ScriptTarget) -> ScriptRunningApp? {
        if let app = running[target.name] { return app }
        guard let launch = launchDuringRun, lock.withLock({ launched }),
              launch.name.caseInsensitiveCompare(target.name) == .orderedSame else { return nil }
        return launch
    }

    func automationConsentPending(bundleID: String) -> Bool {
        guard let until = consentPendingUntil else { return false }
        return Date() < until
    }
}

private final class FakeOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var shouldSucceed = true

    var opened: [URL] { lock.withLock { urls } }
    var succeeds: Bool {
        get { lock.withLock { shouldSucceed } }
        set { lock.withLock { shouldSucceed = newValue } }
    }

    func open(_ url: URL) async -> Bool {
        lock.withLock {
            urls.append(url)
            return shouldSucceed
        }
    }
}

private final class DialogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String?] = []

    var values: [String?] { lock.withLock { recorded } }

    func record(_ value: String?) {
        lock.withLock { recorded.append(value) }
    }
}
