//
//  ToolCatalogTests.swift
//  OttoTests
//
//  The tool catalog: exactly the eight action tools plus the extra tools the app passes, every schema safe
//  for the API's strict mode and fully checked by Otto's own validator, the demo services being the in-memory
//  stand-ins, and the live services reaching Shortcuts and osascript only through the injected process runner.
//

import XCTest
@testable import Otto

@MainActor
final class ToolCatalogTests: XCTestCase {
    private static let actionToolGroups: [String: ToolGroup] = [
        "calendar_create_event": .calendar,
        "calendar_list_events": .calendar,
        "list_shortcuts": .shortcuts,
        "open_url": .links,
        "reminders_create": .reminders,
        "reminders_list": .reminders,
        "run_applescript": .appleScript,
        "run_shortcut": .shortcuts,
    ]

    private var settings: AppSettings!

    override func setUp() async throws {
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
    }

    // MARK: - Contents

    func testRegistryHoldsExactlyTheEightActionTools() {
        let registry = ToolCatalog.makeRegistry(settings: settings, services: .demo)

        XCTAssertEqual(registry.allTools.map(\.name), Self.actionToolGroups.keys.sorted())
        for tool in registry.allTools {
            XCTAssertEqual(tool.group, Self.actionToolGroups[tool.name], tool.name)
        }
    }

    func testExtraToolsAreRegisteredAlongsideTheActionTools() {
        let monitor = NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting())
        let registry = ToolCatalog.makeRegistry(settings: settings, services: .demo,
                                                extraTools: [MediaControlTool(monitor: monitor)])

        let expected = (Self.actionToolGroups.keys + ["media_control"]).sorted()
        XCTAssertEqual(registry.allTools.map(\.name), expected)
        XCTAssertEqual(registry.tool(named: "media_control")?.group, .media)
    }

    func testEveryToolIsRegisteredWhateverTheActionSettings() {
        settings.actions.enabled = false
        settings.actions.groups = []
        let registry = ToolCatalog.makeRegistry(settings: settings, services: .demo)

        XCTAssertEqual(registry.allTools.count, Self.actionToolGroups.count)
        let environment = ToolEnvironment(settings: settings, permissions: nil, model: .opus5, isDemo: false)
        XCTAssertTrue(registry.availableTools(in: environment).isEmpty, "availability is each tool's own check")
    }

    // MARK: - Schemas

    func testEveryWireSchemaIsStrictSafe() {
        let registry = catalogWithMedia()
        for tool in registry.allTools {
            XCTAssertTrue(tool.isStrict, "\(tool.name) is sent strict")
            let wire = ToolSchema.wireSchema(tool.inputSchema, strict: tool.isStrict)
            XCTAssertTrue(ToolSchema.isStrictSafe(wire), "\(tool.name)'s wire schema is strict-safe")
        }
    }

    func testDefinitionsAreStrictWithEagerInputStreaming() {
        let registry = catalogWithMedia()
        let definitions = registry.definitions(for: registry.allTools)
        XCTAssertEqual(definitions.count, registry.allTools.count)
        for (tool, definition) in zip(registry.allTools, definitions) {
            guard case .object(let object) = definition else {
                XCTFail("\(tool.name): the definition is an object")
                continue
            }
            XCTAssertEqual(object["name"], .string(tool.name))
            XCTAssertEqual(object["strict"], .bool(true), tool.name)
            XCTAssertEqual(object["eager_input_streaming"], .bool(true), tool.name)
            XCTAssertEqual(object["input_schema"], ToolSchema.wireSchema(tool.inputSchema, strict: true), tool.name)
        }
    }

    func testNoSchemaUsesAKeywordTheValidatorCannotCheck() {
        for tool in catalogWithMedia().allTools {
            XCTAssertEqual(JSONSchemaValidator.unsupportedKeywords(in: tool.inputSchema), [], tool.name)
        }
    }

    func testEverySampleInputPassesItsOwnSchema() {
        for tool in catalogWithMedia().allTools {
            XCTAssertNil(JSONSchemaValidator.validate(tool.sampleInput, against: tool.inputSchema), tool.name)
        }
    }

    // MARK: - Services

    func testDemoServicesAreTheInMemoryStandIns() {
        let demo = ActionServices.demo
        XCTAssertTrue(demo.eventKit is DemoEventKitService, "no EventKit")
        XCTAssertTrue(demo.shortcuts is DemoShortcutsService, "no /usr/bin/shortcuts")
        XCTAssertTrue(demo.scripts is DemoAppleScriptRunner, "no osascript")
        XCTAssertTrue(demo.urlOpener is DemoURLOpener, "no NSWorkspace")
    }

    func testDemoToolsAnswerFromFixedData() async throws {
        let registry = ToolCatalog.makeRegistry(settings: settings, services: .demo)

        let listing = try await run("list_shortcuts", input: [:], in: registry)
        XCTAssertFalse(listing.isError)
        for shortcut in DemoShortcutsService.shortcuts {
            XCTAssertTrue(listing.previewText.contains(shortcut.name), shortcut.name)
        }

        let url = "https://example.com/otto-\(UUID().uuidString.lowercased())"
        let opened = try await run("open_url", input: ["url": .string(url)], in: registry)
        XCTAssertFalse(opened.isError)
        let opener = try XCTUnwrap(ActionServices.demo.urlOpener as? DemoURLOpener)
        XCTAssertTrue(opener.openedURLs.map(\.absoluteString).contains(url), "the demo opener only records the link")
    }

    func testLiveServicesReachShortcutsAndOsascriptOnlyThroughTheRunner() async throws {
        let runner = FakeProcessRunner()
        runner.setOutput(ProcessOutput(stdout: "Log Water (4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91)\n", stderr: "",
                                       exitCode: 0, timedOut: false, duration: .milliseconds(3)),
                         for: "/usr/bin/shortcuts")
        runner.setOutput(ProcessOutput(stdout: "1\n", stderr: "", exitCode: 0, timedOut: false,
                                       duration: .milliseconds(3)),
                         for: "/usr/bin/osascript")
        let live = ActionServices.live(processRunner: runner)

        XCTAssertTrue(live.eventKit is EventKitService)
        XCTAssertTrue(live.shortcuts is ShortcutsService)
        XCTAssertTrue(live.scripts is AppleScriptRunner)
        XCTAssertTrue(live.urlOpener is DefaultBrowserOpener)

        let shortcuts = try await live.shortcuts.list(folder: nil)
        XCTAssertEqual(shortcuts.map(\.name), ["Log Water"])
        let script = try await live.scripts.run("return 1", timeout: .seconds(5))
        XCTAssertEqual(script.output, "1")

        XCTAssertEqual(runner.invocations.map(\.executable.path), ["/usr/bin/shortcuts", "/usr/bin/osascript"])
        XCTAssertEqual(runner.invocations.last?.stdin, Data("return 1".utf8), "the script goes in on stdin")
    }

    // MARK: - Helpers

    private func catalogWithMedia() -> ToolRegistry {
        let monitor = NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting())
        return ToolCatalog.makeRegistry(settings: settings, services: .demo,
                                        extraTools: [MediaControlTool(monitor: monitor)])
    }

    private func run(_ name: String, input: JSONValue, in registry: ToolRegistry) async throws -> ToolOutput {
        let tool = try XCTUnwrap(registry.tool(named: name))
        XCTAssertNil(tool.validate(input), name)
        let context = ToolRunContext(callID: "toolu_\(name)", model: .opus5, options: ApprovalOptions(),
                                     reportProgress: { _ in }, reportSystemDialog: { _ in })
        return try await tool.run(input, context: context).output
    }
}
