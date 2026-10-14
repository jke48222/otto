//
//  SetappAICheck.swift
//  Otto
//
//  `--setapp-ai-check <dir>` (Debug, Setapp build): the Setapp AI adapter check (SPEC §19 "Setapp AI"), offline,
//  against the pinned SDK's own Codable types. Every request body Otto sends must come out of the SDK's encoder
//  unchanged; every gateway event must come out of `SetappSDKEventMapper` as `ResponsesStreamAccumulator` reads it;
//  the transport, its error mapping and `LiveSetappAIAccount` must follow their rules on scripted SDK calls. Writes
//  `report.json` (pass/fail per step, with notes on what the SDK does) into <dir> and exits 0 when every step
//  passed, 1 otherwise, 3 if it wedged. Nothing reaches the network or the screen.
//
//  It runs from main.swift before `NSApplication.run()`, not from XCTest: the Setapp Framework starts itself on
//  `NSApplicationWillFinishLaunchingNotification` and, in a build Setapp doesn't know (no registered bundle, no
//  Setapp sign-in, no public key yet), puts up a modal activation dialog that blocks the main queue, which wedges
//  a test host and covers the screen. Before `run()` the framework never starts.
//
//  The bodies and events are hand-written in OpenAI's documented Responses format (synthesized, not captured: the
//  live gateway needs J22), all in `SetappAdapterSamples`, so ResponsesRequestBuilder output and ResponsesFixtures
//  can replace them. A few are in the shapes LiteLLM's Responses bridge sends instead (read from its source, also
//  synthesized), since the gateway most likely runs it.
//

#if DEBUG && OTTO_SETAPP
import Foundation
import SetappAI

// MARK: - Samples

enum SetappAdapterSamples {
    static let calendarTool: JSONValue = [
        "type": "function",
        "name": "calendar_list_events",
        "description": "List the events on the user's calendars between two dates.",
        "parameters": [
            "type": "object",
            "properties": [
                "startDate": ["type": "string", "format": "date-time"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
                "offset": ["type": "integer", "minimum": 0],
                "includeAllDay": ["type": "boolean", "default": false],
                "calendars": ["type": "array", "items": ["type": "string"], "maxItems": 1],
            ],
            "required": ["startDate"],
            "additionalProperties": false,
        ],
        "strict": true,
    ]

    static let musicTool: JSONValue = [
        "type": "function",
        "name": "music_control",
        "description": "Play, pause or skip in Music or Spotify.",
        "parameters": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["play", "pause", "next"]],
                "volume": ["type": "number", "minimum": 0, "maximum": 1, "multipleOf": 0.5],
            ],
            "required": ["action"],
        ],
        "strict": false,
    ]

    static func user(_ parts: JSONValue...) -> JSONValue {
        ["type": "message", "role": "user", "content": .array(parts)]
    }

    static func text(_ text: String) -> JSONValue { ["type": "input_text", "text": .string(text)] }

    static let pngDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    static let jpegDataURL = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
    static let pdfDataURL = "data:application/pdf;base64,JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSPj4Kc3RyZWFtCg=="

    /// Request bodies in the shape ResponsesRequestBuilder sends (SPEC §3).
    static let bodies: [(name: String, body: JSONValue)] = [
        ("text", [
            "model": "anthropic/claude-opus-5",
            "instructions": "You are Otto, an assistant in the Mac's notch.",
            "input": [user(text("What's the weather like on Mars?"))],
            "max_output_tokens": 64000,
            "stream": true,
            "store": false,
        ]),
        ("attachments", [
            "model": "anthropic/claude-sonnet-5",
            "input": [user(
                ["type": "input_image", "image_url": .string(pngDataURL), "detail": "auto"],
                ["type": "input_image", "image_url": "https://example.com/chart.png", "detail": "auto"],
                ["type": "input_file", "filename": "Quarterly report.pdf", "file_data": .string(pdfDataURL)],
                text("<document title=\"Notes &quot;draft&quot;\">\nBuy milk.\n</document>"),
                text("<document>\nUntitled text\n</document>"),
                text("Summarize these.")
            )],
            "max_output_tokens": 64000,
            "stream": true,
            "store": false,
        ]),
        ("tools", [
            "model": "anthropic/claude-opus-5",
            "instructions": "You are Otto.",
            "input": [user(text("What's on today?"))],
            "reasoning": ["effort": "high", "summary": "auto"],
            "include": ["reasoning.encrypted_content"],
            "tools": [calendarTool, musicTool],
            "tool_choice": "none",
            "max_output_tokens": 64000,
            "stream": true,
            "store": false,
        ]),
        ("webSearch", [
            "model": "anthropic/claude-sonnet-5",
            "input": [user(text("What happened at WWDC this year?"))],
            "reasoning": ["effort": "medium", "summary": "auto"],
            "include": ["reasoning.encrypted_content", "web_search_call.action.sources"],
            "tools": [["type": "web_search", "search_context_size": "medium"], musicTool],
            "max_tool_calls": 5,
            "max_output_tokens": 64000,
            "stream": true,
            "store": false,
        ]),
        ("toolRound", [
            "model": "anthropic/claude-opus-5",
            "instructions": "You are Otto.",
            "input": [
                user(text("What's on my calendar today, and play some music?")),
                [
                    "type": "reasoning",
                    "id": "rs_68f0a1c2",
                    "summary": [
                        ["type": "summary_text", "text": "The user wants two things."],
                        ["type": "summary_text", "text": "I'll call both tools."],
                    ],
                    "encrypted_content": "gAAAAABo8KExampleEncryptedReasoningContent0123456789==",
                ],
                ["type": "message", "role": "assistant", "content": [
                    ["type": "output_text", "text": "Let me check."],
                    ["type": "output_text", "text": " One moment."],
                ]],
                ["type": "function_call", "call_id": "call_cal_1", "name": "calendar_list_events",
                 "arguments": "{\"limit\":1,\"startDate\":\"2026-10-13T00:00:00Z\"}"],
                ["type": "function_call", "call_id": "call_music_1", "name": "music_control", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_cal_1",
                 "output": "Standup at 9:30.\n\nLunch with Sam at 12:00."],
                ["type": "function_call_output", "call_id": "call_music_1", "output": "Error: Music isn't running."],
                user(
                    text("Images from the tool results above:"),
                    ["type": "input_image", "image_url": .string(jpegDataURL), "detail": "auto"]
                ),
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]],
                ["type": "function_call", "call_id": "call_music_2", "name": "music_control",
                 "arguments": "{\"action\":\"play\",\"volume\":0.5}"],
                ["type": "function_call_output", "call_id": "call_music_2", "output": "(no output)"],
            ],
            "reasoning": ["effort": "high", "summary": "auto"],
            "include": ["reasoning.encrypted_content"],
            "tools": [calendarTool, musicTool],
            "max_output_tokens": 32000,
            "stream": true,
            "store": false,
        ]),
        ("compatible", [
            "model": "anthropic/claude-haiku-4-5",
            "input": [user(text("Hi"))],
            "tools": [musicTool],
            "max_output_tokens": 32000,
            "stream": true,
            "store": false,
        ]),
        // Not something the builder sends (it always writes `strict`): proof that a tool goes as built.
        ("toolWithoutStrict", [
            "model": "anthropic/claude-sonnet-5",
            "input": [user(text("Pause the music."))],
            "tools": [["type": "function", "name": "music_control", "description": "Play or pause.",
                       "parameters": ["type": "object", "properties": [:]]]],
            "max_output_tokens": 64000,
            "stream": true,
            "store": false,
        ]),
    ]

    /// What the SDK's typed Codable alone does to each body (no Otto workaround), checked so the transport's notes
    /// stay true. Nil: it throws.
    static let typedDecodeFindings: [String: [String]?] = [
        "text": [],
        "attachments": nil,
        "tools": [],
        "webSearch": [],
        "toolRound": ["DROPPED input[7].content[1].image_url"],
        "compatible": [],
        "toolWithoutStrict": nil,
    ]

    /// Streams in OpenAI's documented Responses event format (synthesized). Every line decodes in the SDK.
    static let streams: [(name: String, lines: [String])] = [
        ("reasoningThenText", lines(#"""
        {"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"in_progress","model":"anthropic/claude-opus-5","output":[],"parallel_tool_calls":true,"tool_choice":"auto","tools":[]}}
        {"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"in_progress","model":"anthropic/claude-opus-5","output":[],"parallel_tool_calls":true}}
        {"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}
        {"type":"response.reasoning_summary_part.added","sequence_number":3,"item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}
        {"type":"response.reasoning_summary_text.delta","sequence_number":4,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Mars is cold"}
        {"type":"response.reasoning_summary_text.delta","sequence_number":5,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":" and dusty."}
        {"type":"response.reasoning_summary_text.done","sequence_number":6,"item_id":"rs_1","output_index":0,"summary_index":0,"text":"Mars is cold and dusty."}
        {"type":"response.reasoning_summary_part.done","sequence_number":7,"item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":"Mars is cold and dusty."}}
        {"type":"response.reasoning_summary_part.added","sequence_number":8,"item_id":"rs_1","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""}}
        {"type":"response.reasoning_summary_text.delta","sequence_number":9,"item_id":"rs_1","output_index":0,"summary_index":1,"delta":"Answer briefly."}
        {"type":"response.output_item.done","sequence_number":10,"output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Mars is cold and dusty."},{"type":"summary_text","text":"Answer briefly."}],"encrypted_content":"gAAAAABencryptedMars=="}}
        {"type":"response.output_item.added","sequence_number":11,"output_index":1,"item":{"type":"message","id":"msg_1","status":"in_progress","role":"assistant","content":[]}}
        {"type":"response.content_part.added","sequence_number":12,"item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
        {"type":"response.output_text.delta","sequence_number":13,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"About -60","logprobs":[]}
        {"type":"response.output_text.delta","sequence_number":14,"item_id":"msg_1","output_index":1,"content_index":0,"delta":" °C on average.","logprobs":[]}
        {"type":"response.output_text.done","sequence_number":15,"item_id":"msg_1","output_index":1,"content_index":0,"text":"About -60 °C on average.","logprobs":[]}
        {"type":"response.content_part.done","sequence_number":16,"item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":"About -60 °C on average.","annotations":[]}}
        {"type":"response.output_item.done","sequence_number":17,"output_index":1,"item":{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"About -60 °C on average.","annotations":[]}]}}
        {"type":"response.completed","sequence_number":18,"response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Mars is cold and dusty."},{"type":"summary_text","text":"Answer briefly."}],"encrypted_content":"gAAAAABencryptedMars=="},{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"About -60 °C on average.","annotations":[]}]}],"usage":{"input_tokens":1200,"input_tokens_details":{"cached_tokens":800},"output_tokens":90,"output_tokens_details":{"reasoning_tokens":40},"total_tokens":1290}}}
        """#)),
        ("functionCall", lines(#"""
        {"type":"response.created","sequence_number":0,"response":{"id":"resp_2","object":"response","created_at":1760400000,"status":"in_progress","model":"claude-opus-5","output":[],"parallel_tool_calls":true}}
        {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_cal_1","name":"calendar_list_events","arguments":"","status":"in_progress"}}
        {"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"fc_1","output_index":0,"delta":"{\"startDate\":"}
        {"type":"response.function_call_arguments.delta","sequence_number":3,"item_id":"fc_1","output_index":0,"delta":"\"2026-10-13T00:00:00Z\",\"limit\":1}"}
        {"type":"response.function_call_arguments.done","sequence_number":4,"item_id":"fc_1","output_index":0,"arguments":"{\"startDate\":\"2026-10-13T00:00:00Z\",\"limit\":1}"}
        {"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_cal_1","name":"calendar_list_events","arguments":"{\"startDate\":\"2026-10-13T00:00:00Z\",\"limit\":1}","status":"completed"}}
        {"type":"response.output_item.added","sequence_number":6,"output_index":1,"item":{"type":"function_call","id":"fc_2","call_id":"call_music_1","name":"music_control","arguments":"","status":"in_progress"}}
        {"type":"response.output_item.done","sequence_number":7,"output_index":1,"item":{"type":"function_call","id":"fc_2","call_id":"call_music_1","name":"music_control","arguments":"{\"action\":\"play\"}","status":"completed"}}
        {"type":"response.completed","sequence_number":8,"response":{"id":"resp_2","object":"response","created_at":1760400000,"status":"completed","model":"claude-opus-5","parallel_tool_calls":true,"output":[{"type":"function_call","id":"fc_1","call_id":"call_cal_1","name":"calendar_list_events","arguments":"{\"startDate\":\"2026-10-13T00:00:00Z\",\"limit\":1}","status":"completed"},{"type":"function_call","id":"fc_2","call_id":"call_music_1","name":"music_control","arguments":"{\"action\":\"play\"}","status":"completed"}],"usage":{"input_tokens":900,"output_tokens":60,"total_tokens":960}}}
        """#)),
        ("webSearchUncited", lines(#"""
        {"type":"response.created","sequence_number":0,"response":{"id":"resp_3","object":"response","created_at":1760400000,"status":"in_progress","model":"anthropic/claude-sonnet-5","output":[],"parallel_tool_calls":true}}
        {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"in_progress"}}
        {"type":"response.web_search_call.in_progress","sequence_number":2,"output_index":0,"item_id":"ws_1"}
        {"type":"response.web_search_call.searching","sequence_number":3,"output_index":0,"item_id":"ws_1"}
        {"type":"response.web_search_call.completed","sequence_number":4,"output_index":0,"item_id":"ws_1"}
        {"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"WWDC 2026 announcements","sources":[{"type":"url","url":"https://www.apple.com/newsroom/"},{"type":"url","url":"https://developer.apple.com/wwdc26/"}]}}}
        {"type":"response.output_item.added","sequence_number":6,"output_index":1,"item":{"type":"web_search_call","id":"ws_2","status":"in_progress"}}
        {"type":"response.output_item.done","sequence_number":7,"output_index":1,"item":{"type":"web_search_call","id":"ws_2","status":"completed","action":{"type":"open_page","url":"https://developer.apple.com/wwdc26/"}}}
        {"type":"response.output_item.added","sequence_number":8,"output_index":2,"item":{"type":"message","id":"msg_3","status":"in_progress","role":"assistant","content":[]}}
        {"type":"response.output_text.delta","sequence_number":9,"item_id":"msg_3","output_index":2,"content_index":0,"delta":"Apple showed new Macs."}
        {"type":"response.output_item.done","sequence_number":10,"output_index":2,"item":{"type":"message","id":"msg_3","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Apple showed new Macs.","annotations":[]}]}}
        {"type":"response.completed","sequence_number":11,"response":{"id":"resp_3","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-sonnet-5","parallel_tool_calls":true,"output":[{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"WWDC 2026 announcements","sources":[{"type":"url","url":"https://www.apple.com/newsroom/"},{"type":"url","url":"https://developer.apple.com/wwdc26/"}]}},{"type":"web_search_call","id":"ws_2","status":"completed","action":{"type":"open_page","url":"https://developer.apple.com/wwdc26/"}},{"type":"message","id":"msg_3","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Apple showed new Macs.","annotations":[]}]}],"usage":{"input_tokens":5000,"output_tokens":120,"total_tokens":5120}}}
        """#)),
        ("terminals", lines(#"""
        {"type":"response.queued","sequence_number":0,"response":{"id":"resp_4","object":"response","created_at":1760400000,"status":"queued","model":"anthropic/claude-opus-5","output":[],"parallel_tool_calls":true}}
        {"type":"response.incomplete","sequence_number":5,"response":{"id":"resp_5","object":"response","created_at":1760400000,"status":"incomplete","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","id":"msg_5","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The first part","annotations":[]}]}],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}
        {"type":"response.completed","sequence_number":6,"response":{"id":"resp_6","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[{"type":"message","id":"msg_6","status":"completed","role":"assistant","content":[{"type":"refusal","refusal":"I can't help with that."}]}],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}
        {"type":"response.failed","sequence_number":3,"response":{"id":"resp_7","object":"response","created_at":1760400000,"status":"failed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[],"error":{"code":"context_length_exceeded","message":"prompt is too long: 250000 tokens > 200000 maximum"}}}
        {"type":"response.failed","sequence_number":3,"response":{"id":"resp_8","object":"response","created_at":1760400000,"status":"failed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[],"error":{"code":"insufficient_credits","message":"Not enough credits."}}}
        {"type":"error","sequence_number":2,"code":"insufficient_credits","message":"Not enough credits.","param":"model"}
        {"type":"response.output_text.done","item_id":"msg_9","text":"Hi"}
        {"type":"response.custom_event","flag":true,"one":1,"zero":0,"pi":3.5,"nested":{"list":[true,1,"x",{"deep_key":false}]}}
        """#)),
    ]

    /// Events the SDK's typed decoding refuses, each with the reason, verified below. The connector throws on them,
    /// which ends the stream.
    static let undecodable: [(name: String, line: String, reason: String)] = [
        ("completed with a url_citation", #"{"type":"response.completed","sequence_number":11,"response":{"id":"resp_3","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-sonnet-5","parallel_tool_calls":true,"output":[{"type":"message","id":"msg_3","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Apple showed new Macs.","annotations":[{"type":"url_citation","url":"https://www.apple.com/newsroom/","title":"Newsroom","start_index":0,"end_index":22}]}]}]}}"#, "starIndex"),
        ("output_text part without annotations", #"{"type":"response.completed","response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}]}}"#, "annotations"),
        ("usage without total_tokens", #"{"type":"response.completed","response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[],"usage":{"input_tokens":1,"output_tokens":2}}}"#, "totalTokens"),
        ("response without parallel_tool_calls", #"{"type":"response.completed","response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","output":[]}}"#, "parallelToolCalls"),
        ("response without model", #"{"type":"response.created","response":{"id":"resp_1","object":"response","status":"in_progress","output":[]}}"#, "model"),
        ("error with param null", #"{"type":"error","sequence_number":2,"code":"insufficient_credits","message":"Not enough credits.","param":null}"#, "param"),
        ("error without param", #"{"type":"error","sequence_number":2,"code":"rate_limit_exceeded","message":"Slow down."}"#, "param"),
        ("error without sequence_number", #"{"type":"error","code":"server_error","message":"Boom.","param":"x"}"#, "sequenceNumber"),
        ("output_text.delta without item_id", #"{"type":"response.output_text.delta","delta":"Hi"}"#, "itemId"),
        // LiteLLM's terminal reasoning item: `content` instead of `summary` (the reviewer's probe line, as LiteLLM
        // builds it).
        ("LiteLLM's final reasoning item", litellmReasoningTerminal, "summary"),
        // LiteLLM's mid-stream failure: an error object with no `type` around it.
        ("an error frame without a type", litellmErrorFrame, "type"),
    ]

    static let litellmReasoningTerminal = #"{"type":"response.completed","sequence_number":20,"response":{"id":"resp_1","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"output":[{"type":"reasoning","id":"rs_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Thinking about it.","annotations":[]}],"encrypted_content":"W3sidHlwZSI6InRoaW5raW5nIn1d"},{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi","annotations":[]}]}],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":2}}}}"#

    static let litellmErrorFrame = #"{"error":{"message":"litellm.InternalServerError: AnthropicException - Overloaded","type":"internal_server_error","param":null,"code":"529"}}"#

    /// A web search answer with a citation, in OpenAI's format (synthesized): its terminal event carries the
    /// `url_citation` the SDK can't decode, so the transport stands in for it with the finished items.
    static let webSearchCited: [String] = lines(#"""
    {"type":"response.created","sequence_number":0,"response":{"id":"resp_10","object":"response","created_at":1760400000,"status":"in_progress","model":"anthropic/claude-sonnet-5","output":[],"parallel_tool_calls":true}}
    {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"web_search_call","id":"ws_10","status":"in_progress"}}
    {"type":"response.output_item.done","sequence_number":2,"output_index":0,"item":{"type":"web_search_call","id":"ws_10","status":"completed","action":{"type":"search","query":"Apple newsroom","sources":[{"type":"url","url":"https://www.apple.com/newsroom/"}]}}}
    {"type":"response.output_item.added","sequence_number":3,"output_index":1,"item":{"type":"message","id":"msg_10","status":"in_progress","role":"assistant","content":[]}}
    {"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_10","output_index":1,"content_index":0,"delta":"Apple showed new Macs."}
    {"type":"response.output_text.annotation.added","sequence_number":5,"item_id":"msg_10","output_index":1,"content_index":0,"annotation_index":0,"annotation":{"type":"url_citation","url":"https://www.apple.com/newsroom/","title":"Newsroom","start_index":0,"end_index":22}}
    {"type":"response.output_text.done","sequence_number":6,"item_id":"msg_10","output_index":1,"content_index":0,"text":"Apple showed new Macs."}
    {"type":"response.output_item.done","sequence_number":7,"output_index":1,"item":{"type":"message","id":"msg_10","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Apple showed new Macs.","annotations":[{"type":"url_citation","url":"https://www.apple.com/newsroom/","title":"Newsroom","start_index":0,"end_index":22}]}]}}
    {"type":"response.completed","sequence_number":8,"response":{"id":"resp_10","object":"response","created_at":1760400000,"status":"completed","model":"anthropic/claude-sonnet-5","parallel_tool_calls":true,"output":[{"type":"web_search_call","id":"ws_10","status":"completed","action":{"type":"search","query":"Apple newsroom","sources":[{"type":"url","url":"https://www.apple.com/newsroom/"}]}},{"type":"message","id":"msg_10","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Apple showed new Macs.","annotations":[{"type":"url_citation","url":"https://www.apple.com/newsroom/","title":"Newsroom","start_index":0,"end_index":22}]}]}],"usage":{"input_tokens":5000,"output_tokens":40,"total_tokens":5040}}}
    """#)

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let typedEventTypes: Set<String> = [
        "response.created", "response.in_progress", "response.queued", "response.completed", "response.incomplete",
        "response.failed", "response.output_text.delta", "response.output_text.done", "error",
    ]
}

// MARK: - JSON comparison

enum SetappAdapterJSON {
    /// Nulls removed (the SDK drops them) and integral doubles read as integers, so 1.0 and 1 compare equal.
    static func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.filter { $0.value != .null }.mapValues(normalized))
        case .array(let array):
            return .array(array.filter { $0 != .null }.map(normalized))
        case .double(let double) where double.rounded() == double && abs(double) < 9.0e15:
            return .int(Int64(double))
        default:
            return value
        }
    }

    /// Path-by-path differences between `expected` and `actual`, both normalized.
    static func differences(_ expected: JSONValue, _ actual: JSONValue, path: String = "") -> [String] {
        switch (expected, actual) {
        case (.object(let lhs), .object(let rhs)):
            return Set(lhs.keys).union(rhs.keys).sorted().flatMap { key -> [String] in
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (lhs[key], rhs[key]) {
                case (let left?, let right?): return differences(left, right, path: child)
                case (_?, nil): return ["DROPPED \(child)"]
                case (nil, _?): return ["ADDED \(child)"]
                default: return []
                }
            }
        case (.array(let lhs), .array(let rhs)):
            var found = lhs.count == rhs.count ? [] : ["COUNT \(path): \(lhs.count) -> \(rhs.count)"]
            for index in 0..<min(lhs.count, rhs.count) {
                found += differences(lhs[index], rhs[index], path: "\(path)[\(index)]")
            }
            return found
        default:
            return expected == actual ? [] : ["CHANGED \(path): \(expected.encodedString().prefix(80)) -> \(actual.encodedString().prefix(80))"]
        }
    }

    /// Whether `value` holds a JSON null anywhere.
    static func containsNull(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .object(let object): return object.values.contains(where: containsNull)
        case .array(let array): return array.contains(where: containsNull)
        default: return false
        }
    }

    /// How many objects in `value`, at any depth, satisfy `matches`.
    static func count(in value: JSONValue, where matches: (JSONValue) -> Bool) -> Int {
        switch value {
        case .object(let object):
            return (matches(value) ? 1 : 0) + object.values.reduce(0) { $0 + count(in: $1, where: matches) }
        case .array(let array):
            return array.reduce(0) { $0 + count(in: $1, where: matches) }
        default:
            return 0
        }
    }

    static func decode(_ line: String) -> JSONValue {
        (try? JSONValue.decode(line)) ?? .null
    }

    /// The fields of an event that `ResponsesStreamAccumulator` reads (SPEC §4).
    static func accumulatorView(_ event: JSONValue) -> JSONValue {
        guard let type = event.typeName else { return event }
        var view: [String: JSONValue] = ["type": .string(type)]
        for key in ["item_id", "output_index", "content_index", "delta", "text", "code", "message"] {
            if let value = event[key] { view[key] = value }
        }
        if let response = event["response"] {
            var picked: [String: JSONValue] = [:]
            for key in ["id", "model", "status", "output", "incomplete_details", "error"] {
                if let value = response[key] { picked[key] = value }
            }
            if let usage = response["usage"] {
                picked["usage"] = [
                    "input_tokens": usage["input_tokens"] ?? .null,
                    "output_tokens": usage["output_tokens"] ?? .null,
                    "cached_tokens": usage["input_tokens_details"]?["cached_tokens"] ?? .null,
                    "reasoning_tokens": usage["output_tokens_details"]?["reasoning_tokens"] ?? .null,
                ]
            }
            if let error = response["error"] {
                picked["error"] = ["code": error["code"] ?? .null, "message": error["message"] ?? .null]
            }
            view["response"] = .object(picked)
        }
        return .object(view)
    }
}

// MARK: - Scripted SDK

/// Stands in for `ai.responses.createStream(parameters:)`: decodes each line the way the SDK's connector does and
/// ends the stream with the decoding error when one doesn't decode; a typed `error` event is thrown, as the
/// connector does ("Stream returned an Error object").
final class ScriptedSetappSDK: @unchecked Sendable {
    private let lock = NSLock()
    private var parameters: [SetappAIAPI.Responses.CreateRequestParameters] = []
    private var cancelled = 0
    let lines: [String]
    let finalError: Error?
    let wrapsErrors: Bool
    let holdsOpen: Bool
    /// Fail an undecodable line the way the connector's binary does: `SetappAIError(.general)` over its parsing
    /// error, whose text ends with ", line: <the event>".
    let failsLikeTheConnector: Bool

    init(lines: [String], finalError: Error? = nil, wrapsErrors: Bool = false, holdsOpen: Bool = false,
         failsLikeTheConnector: Bool = false) {
        self.lines = lines
        self.finalError = finalError
        self.wrapsErrors = wrapsErrors
        self.holdsOpen = holdsOpen
        self.failsLikeTheConnector = failsLikeTheConnector
    }

    var receivedParameters: [SetappAIAPI.Responses.CreateRequestParameters] { lock.withLock { parameters } }
    var cancelCount: Int { lock.withLock { cancelled } }

    func transport(configured: Bool = true) -> SetappSDKTransport {
        SetappSDKTransport(isConfigured: { configured }, makeStream: { [self] parameters in
            makeStream(parameters)
        })
    }

    private func makeStream(_ parameters: SetappAIAPI.Responses.CreateRequestParameters)
        -> CancellableAsyncStream<SetappAIAPI.StreamingEvent> {
        lock.withLock { self.parameters.append(parameters) }
        let stream = AsyncThrowingStream<SetappAIAPI.StreamingEvent, Error> { continuation in
            for line in lines {
                do {
                    let event = try SetappSDKCoding.decoder().decode(SetappAIAPI.StreamingEvent.self, from: Data(line.utf8))
                    if case .response(.error(let error)) = event {
                        continuation.finish(throwing: wrap(error))
                        return
                    }
                    continuation.yield(event)
                } catch {
                    if failsLikeTheConnector {
                        let parse = FakeWebServiceError.parsingError(
                            message: "[ModelWebService] Failed to parse SSE event: \(error), line: \(line)")
                        continuation.finish(throwing: SetappAIError(code: .general, underlyingError: parse, recoveryURL: nil))
                    } else {
                        continuation.finish(throwing: wrap(error))
                    }
                    return
                }
            }
            if let finalError {
                continuation.finish(throwing: wrap(finalError))
            } else if !holdsOpen {
                continuation.finish()
            }
        }
        return CancellableAsyncStream(stream: stream, onCancel: { [self] in lock.withLock { cancelled += 1 } })
    }

    private func wrap(_ error: Error) -> Error {
        wrapsErrors ? SetappAIError(code: .general, underlyingError: error, recoveryURL: nil) : error
    }
}


/// The connector's private HTTP error, as far as reflection sees it.
private enum FakeWebServiceError: Error {
    case httpError(statusCode: Int, errorBody: Data?)
    case parsingError(message: String)
    case decodedBody(statusCode: Int, body: FakeGatewayBody)
}

private struct FakeGatewayBody {
    let statusCode: Int
    let message: String
    let code: String
}

// MARK: - Check

@MainActor
final class SetappAICheck {
    // MARK: Entry point

    /// How long the whole run may take before the watchdog ends the process.
    nonisolated private static let watchdogSeconds: Double = 120

    /// `--setapp-ai-check <dir>` or `--setapp-ai-check=<dir>`.
    nonisolated static func directory(in arguments: [String]) -> URL? {
        var path: String?
        for (index, argument) in arguments.enumerated() {
            if argument == "--setapp-ai-check", arguments.indices.contains(index + 1) {
                path = arguments[index + 1]
            } else if argument.hasPrefix("--setapp-ai-check=") {
                path = String(argument.dropFirst("--setapp-ai-check=".count))
            }
        }
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: base).standardizedFileURL
    }

    /// Runs the check on the main queue and exits: 0 when every step passed, 1 otherwise, 3 if it wedged. Called
    /// from main.swift before `NSApplication.run()`, so the Setapp Framework, which starts on
    /// `NSApplicationWillFinishLaunchingNotification`, never begins activation or shows its dialogs.
    nonisolated static func runAndExit(reportingTo directory: URL) -> Never {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdogSeconds) {
            FileHandle.standardError.write(Data("Setapp AI check timed out.\n".utf8))
            exit(3)
        }
        Task { @MainActor in
            let check = SetappAICheck(directory: directory)
            exit(await check.run() ? 0 : 1)
        }
        dispatchMain()
    }

    // MARK: Report

    private struct StepReport: Encodable {
        var name: String
        var passed: Bool
        var failures: [String]
        var notes: [String]
        var durationMs: Int
    }

    private struct Report: Encodable {
        var startedAt: String
        var sdk: String
        var passed: Int
        var failed: Int
        var steps: [StepReport]
    }

    private let directory: URL
    private var steps: [StepReport] = []
    private var current: StepReport?

    private init(directory: URL) {
        self.directory = directory
    }

    private func run() async -> Bool {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        await step("request bodies round-trip through the SDK", requestRoundTrip)
        await step("Otto's tool schemas reach the SDK without nulls", catalogTools)
        await step("typed decoding alone (no workaround)", typedDecodingAlone)
        await step("top-level fields decode typed", topLevelFields)
        await step("bodies that aren't objects fail", nonObjectBodies)
        await step("events decode and map", eventsDecodeAndMap)
        await step("events the SDK refuses", undecodableEvents)
        await step("unsupported event values keep booleans and numbers apart", unsupportedValues)
        await step("raw JSON conversions match the SDK encoder", rawJSONConversions)
        await step("transport sends the body and streams mapped events", transportStreams)
        await step("not configured throws before any work", notConfigured)
        await step("a body the SDK can't take is a bad request", badBody)
        await step("cancelling the consumer cancels the SDK stream", cancellation)
        await step("an undecodable terminal event is rebuilt from the finished items", rebuiltTerminal)
        await step("a stream cut mid-item still fails", cutMidItem)
        await step("a stream that ends without a terminal event gets none", endsWithoutTerminal)
        await step("a stand-in for a cut-off reply is response.incomplete", incompleteStandIn)
        await step("finished items at one output index are all kept", sameIndexItems)
        await step("LiteLLM's final reasoning item through the transport and client", litellmReasoningTerminal)
        await step("an error frame without a type becomes an error event", typelessErrorFrame)
        await step("a thrown error event becomes an error event", thrownErrorEvent)
        await step("an error event with a null param", nullParamErrorEvent)
        await step("SetappAIError codes map", setappAIErrorCodes)
        await step("HTTP statuses under .general map by the gateway table", httpStatuses)
        await step("network failures and cancellation", networkAndCancellation)
        await step("OAuth client rules", oauthRules)
        await step("this build's Info.plist and configuration", infoPlist)
        await step("account: refresh loads the balance", accountLoads)
        await step("account: a loaded balance stays while refreshing; refreshes don't stack", accountKeepsLoaded)
        await step("account: a stalled Setapp times out", accountTimesOut)
        await step("account: failures and unknown units", accountFailures)
        await step("account: a real zero is loaded and a failure can be retried", accountZeroAndRetry)
        await step("account: state mapping", accountStateMapping)
        await step("account: an unconfigured build asks nothing", accountUnconfigured)
        await step("account: purchase page uses the SDK link or falls back", accountPurchase)
        await step("ResponsesRequestBuilder bodies round-trip through the SDK", builderBodies)
        await step("every fixture stream ends the same through the SDK, the transport and the client", fixturesEndToEnd)

        let report = Report(startedAt: startedAt, sdk: "Setapp Framework 5.5.0 (SetappAI)",
                            passed: steps.filter(\.passed).count, failed: steps.filter { !$0.passed }.count,
                            steps: steps)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Couldn't write the report: \(error.localizedDescription)\n".utf8))
            return false
        }
        for step in steps {
            print("\(step.passed ? "PASS" : "FAIL") \(step.name)")
            step.failures.forEach { print("     failure: \($0)") }
            step.notes.forEach { print("     \($0)") }
        }
        print("\(report.passed) passed, \(report.failed) failed → \(directory.appendingPathComponent("report.json").path)")
        return report.failed == 0
    }

    private func step(_ name: String, _ body: () async throws -> Void) async {
        let start = ContinuousClock.now
        current = StepReport(name: name, passed: true, failures: [], notes: [], durationMs: 0)
        do {
            try await body()
        } catch {
            fail("threw: \(error)")
        }
        guard var finished = current else { return }
        let elapsed = ContinuousClock.now - start
        finished.durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        finished.passed = finished.failures.isEmpty
        steps.append(finished)
        current = nil
    }

    private func fail(_ message: String) {
        current?.failures.append(message)
    }

    private func note(_ message: String) {
        current?.notes.append(message)
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String) {
        if actual != expected { fail("\(message()): got \(actual), expected \(expected)") }
    }

    private struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Missing(description: message) }
        return value
    }

    private func collect(_ stream: AsyncThrowingStream<JSONValue, Error>) async -> (events: [JSONValue], error: Error?) {
        var events: [JSONValue] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private static func body(_ name: String) -> JSONValue {
        SetappAdapterSamples.bodies.first { $0.name == name }!.body
    }

    private static func stream(_ name: String) -> [String] {
        SetappAdapterSamples.streams.first { $0.name == name }!.lines
    }

    // MARK: Request round trip

    private func requestRoundTrip() async throws {
        for (name, body) in SetappAdapterSamples.bodies {
            let parameters = try SetappSDKRequest.parameters(from: body)
            let wire = try SetappSDKRequest.wireBody(parameters)
            let intended = SetappSDKRequest.intendedBody(body)
            let differences = SetappAdapterJSON.differences(SetappAdapterJSON.normalized(intended),
                                                            SetappAdapterJSON.normalized(wire))
            expectEqual(differences, [], "\(name) round-trips through the SDK")
            let rewrites = SetappAdapterJSON.differences(SetappAdapterJSON.normalized(body), SetappAdapterJSON.normalized(intended))
            note("\(name): \(differences.isEmpty ? "every field round-trips" : differences.joined(separator: "; "))"
                 + (rewrites.isEmpty ? "" : " (rewritten first: \(rewrites.joined(separator: "; ")))"))
        }
    }

    /// Otto's real tool definitions (the catalog on demo services), mapped as ResponsesRequestBuilder maps them.
    private func catalogTools() async throws {
        let suite = "com.jalenedusei.otto.setapp-ai-check.\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a throwaway defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        let monitor = NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting())
        let registry = ToolCatalog.makeRegistry(settings: settings, services: .demo,
                                                extraTools: [MediaControlTool(monitor: monitor)])
        for strictTools in [true, false] {
            let tools: [JSONValue] = registry.allTools.map { tool in
                let definition = tool.definition()
                return [
                    "type": "function",
                    "name": definition["name"] ?? "",
                    "description": definition["description"] ?? "",
                    "parameters": definition["input_schema"] ?? [:],
                    "strict": .bool(strictTools && definition["strict"]?.boolValue == true),
                ]
            }
            let body: JSONValue = ["model": "anthropic/claude-opus-5", "input": [SetappAdapterSamples.user(
                SetappAdapterSamples.text("Hi"))], "tools": .array(tools), "stream": true, "store": false]
            let wire = try SetappSDKRequest.wireBody(SetappSDKRequest.parameters(from: body))
            let intended = SetappSDKRequest.intendedBody(body)
            expectEqual(SetappAdapterJSON.differences(SetappAdapterJSON.normalized(intended), SetappAdapterJSON.normalized(wire)),
                        [], "the catalog's tools round-trip (strict \(strictTools))")
            let nullable = SetappAdapterJSON.count(in: body) { $0["enum"]?.arrayValue?.contains(.null) == true }
            let rewritten = SetappAdapterJSON.count(in: wire) { node in
                node["anyOf"]?.arrayValue?.contains(["type": "null"]) == true
            }
            expect(!SetappAdapterJSON.containsNull(wire), "no null reaches the SDK")
            expectEqual(rewritten, nullable, "every nullable enum arrives as anyOf with a null type")
            if strictTools {
                expect(nullable > 0, "the strict schemas have nullable enums to rewrite")
                note("\(tools.count) tools; \(nullable) nullable enum(s) (null in enum) sent as anyOf [enum, {type: null}]")
            }
        }
    }

    private func typedDecodingAlone() async throws {
        for (name, body) in SetappAdapterSamples.bodies {
            let expected = SetappAdapterSamples.typedDecodeFindings[name] ?? []
            do {
                let parameters = try SetappSDKCoding.decoder().decode(
                    SetappAIAPI.Responses.CreateRequestParameters.self, from: body.encodedData())
                let wire = try SetappSDKRequest.wireBody(parameters)
                let differences = SetappAdapterJSON.differences(SetappAdapterJSON.normalized(body), SetappAdapterJSON.normalized(wire))
                expectEqual(differences, expected ?? ["(throws)"], "the SDK's typed Codable on \(name)")
                note("\(name): \(differences.isEmpty ? "round-trips" : differences.joined(separator: "; "))")
            } catch {
                expect(expected == nil, "\(name) decodes typed: \(error)")
                note("\(name): decode throws: \(error)")
            }
        }
    }

    private func topLevelFields() async throws {
        let parameters = try SetappSDKRequest.parameters(from: Self.body("webSearch"))
        expectEqual(parameters.model.id, "anthropic/claude-sonnet-5", "model")
        expectEqual(parameters.maxOutputTokens, 64000, "max_output_tokens")
        expectEqual(parameters.maxToolCalls, 5, "max_tool_calls")
        expectEqual(parameters.store, false, "store")
        expectEqual(parameters.stream, true, "stream")
        expectEqual(parameters.include?.map(\.rawValue), ["reasoning.encrypted_content", "web_search_call.action.sources"],
                    "include")
        expectEqual(parameters.reasoning, SetappAIAPI.Responses.Reasoning(effort: .medium, summary: .auto), "reasoning")
        expectEqual(parameters.tools?.map(\.type.rawValue), ["web_search", "function"], "tools")
        expectEqual(try SetappSDKRequest.wireBody(parameters)["tools"]?[0]?["search_context_size"], "medium",
                    "search_context_size, which LiteLLM turns into Anthropic's max_uses")
        expectEqual(parameters.input.count, 1, "input count")
        expectEqual(parameters.input.first?.type.rawValue, "message", "input type")
        let tools = try SetappSDKRequest.parameters(from: Self.body("tools"))
        expectEqual(tools.toolChoice.map { (try? SetappSDKCoding.json($0)) ?? .null }, "none", "tool_choice")
    }

    private func nonObjectBodies() async throws {
        expect((try? SetappSDKRequest.parameters(from: "hello")) == nil, "a string body fails")
        expect((try? SetappSDKRequest.parameters(from: ["model": "anthropic/claude-opus-5", "input": ["x"]])) == nil,
               "an input item that isn't an object fails")
        expect((try? SetappSDKRequest.parameters(from: ["input": []])) == nil, "the SDK needs a model")
        expect((try? SetappSDKRequest.parameters(from: ["model": "anthropic/claude-opus-5", "input": [],
                                                        "tools": [["name": "untyped"]]])) == nil,
               "a tool without a type fails")
        let nullable: JSONValue = ["type": "object", "properties": [
            "kind": ["description": "Which.", "enum": ["a", "b", nil]],
            "only": ["const": nil],
            "fixed": ["const": "x", "default": nil],
        ]]
        expectEqual(SetappSDKRequest.withoutNulls(nullable), ["type": "object", "properties": [
            "kind": ["description": "Which.", "anyOf": [["enum": ["a", "b"]], ["type": "null"]]],
            "only": ["type": "null"],
            "fixed": ["const": "x"],
        ]], "withoutNulls")
    }

    // MARK: Events

    private func eventsDecodeAndMap() async throws {
        var typed: Set<String> = []
        var unsupported: Set<String> = []
        for (name, lines) in SetappAdapterSamples.streams {
            for line in lines {
                let input = SetappAdapterJSON.decode(line)
                let type = try unwrap(input.typeName, "\(name): a line without a type")
                let event = try SetappSDKCoding.decoder().decode(SetappAIAPI.StreamingEvent.self, from: Data(line.utf8))
                let mapped = try unwrap(SetappSDKEventMapper.json(for: event), "\(name) \(type) maps")
                if case .unsupported = event {
                    unsupported.insert(type)
                    expect(!SetappAdapterSamples.typedEventTypes.contains(type), "\(type) should be typed")
                    expectEqual(SetappAdapterJSON.differences(SetappAdapterJSON.normalized(input), mapped), [],
                                "\(name) \(type) comes back verbatim")
                } else {
                    typed.insert(type)
                    expect(SetappAdapterSamples.typedEventTypes.contains(type), "\(type) arrived typed")
                    let differences = SetappAdapterJSON.differences(
                        SetappAdapterJSON.normalized(SetappAdapterJSON.accumulatorView(input)),
                        SetappAdapterJSON.normalized(SetappAdapterJSON.accumulatorView(mapped)))
                    expectEqual(differences, [], "\(name) \(type) keeps what the accumulator reads")
                    let others = SetappAdapterJSON.differences(SetappAdapterJSON.normalized(input), SetappAdapterJSON.normalized(mapped))
                    if !others.isEmpty { note("typed \(name) \(type) also changes: \(others.joined(separator: "; "))") }
                }
            }
        }
        note("typed: \(typed.sorted().joined(separator: ", "))")
        note("unsupported (verbatim): \(unsupported.sorted().joined(separator: ", "))")
        expect(unsupported.isSuperset(of: [
            "response.output_item.added", "response.output_item.done", "response.reasoning_summary_text.delta",
            "response.reasoning_summary_part.added", "response.function_call_arguments.delta",
            "response.web_search_call.searching", "response.content_part.added",
        ]), "the untyped events arrive as .unsupported")
    }

    private func undecodableEvents() async throws {
        for (name, line, reason) in SetappAdapterSamples.undecodable {
            do {
                _ = try SetappSDKCoding.decoder().decode(SetappAIAPI.StreamingEvent.self, from: Data(line.utf8))
                fail("\(name) decoded")
            } catch {
                expect(String(describing: error).contains(reason), "\(name): \(error)")
                note("\(name): needs \(reason)")
            }
        }
    }

    private func unsupportedValues() async throws {
        let line = #"{"type":"response.custom_event","flag":true,"off":false,"one":1,"zero":0,"pi":3.5,"whole":2.0,"big":9007199254740993,"nested":{"list":[true,1,0,"x",{"deep_key":false}]}}"#
        let event = try SetappSDKCoding.decoder().decode(SetappAIAPI.StreamingEvent.self, from: Data(line.utf8))
        let mapped = try unwrap(SetappSDKEventMapper.json(for: event), "maps")
        expectEqual(mapped["flag"], .bool(true), "flag")
        expectEqual(mapped["off"], .bool(false), "off")
        expectEqual(mapped["one"], .int(1), "one")
        expectEqual(mapped["zero"], .int(0), "zero")
        expectEqual(mapped["pi"], .double(3.5), "pi")
        expectEqual(mapped["whole"]?.doubleValue, 2, "whole")
        expectEqual(mapped["big"], .int(9_007_199_254_740_993), "big")
        expectEqual(mapped["nested"]?["list"], [true, 1, 0, "x", ["deep_key": false]], "nested")
    }

    private func rawJSONConversions() async throws {
        let value: JSONValue = ["type": "x", "t": true, "f": false, "one": 1, "zero": 0, "half": 0.5, "whole": 1.0,
                                "list": [1, 0, true, "s", ["k": [false]]], "gone": nil, "empty": [:], "none": []]
        let object = try unwrap(SendableJSON.object(value), "an object")
        let encoded = try SetappSDKCoding.json(SetappAIAPI.Responses.Input.unsupported(
            SetappAIAPI.UnsupportedObject(type: .unsupported("x"), object: object)))
        expectEqual(SetappAdapterJSON.differences(SetappAdapterJSON.normalized(value), SetappAdapterJSON.normalized(encoded)), [],
                    "Swift values survive the SDK encoder")
        expectEqual(encoded["one"], .int(1), "a Swift Int 1 stays a number")

        // The trap SendableJSON avoids: the SDK's encoder reads a non-boolean NSNumber 1 as true.
        let serialized = try JSONSerialization.jsonObject(with: Data(#"{"one":1}"#.utf8)) as? [String: Any] ?? [:]
        let trap = try SetappSDKCoding.json(SetappAIAPI.Responses.Input.unsupported(
            SetappAIAPI.UnsupportedObject(type: .unsupported("x"), object: ["one": serialized["one"] as! NSNumber])))
        expectEqual(trap["one"], .bool(true), "an NSNumber 1 through the SDK encoder")
        note("the SDK's raw-JSON encoder turns a non-boolean NSNumber 1 into true; Otto never hands it one")
        expectEqual(SendableJSON.value(serialized), ["one": 1], "SendableJSON reads it as a number")
        expectEqual(SendableJSON.value(NSNull()), .null, "NSNull")
        expectEqual(SendableJSON.value([true, 3, 2.5, "s"] as [Any]), [true, 3, 2.5, "s"], "Swift values")
    }

    // MARK: End to end

    /// Bodies built by the real `ResponsesRequestBuilder` from Otto's own content blocks, so the round trip covers
    /// what ships rather than hand-written samples.
    private func builderBodies() async throws {
        let pngData = String(SetappAdapterSamples.pngDataURL.dropFirst("data:image/png;base64,".count))
        let png: [JSONValue] = [["type": "image",
                                 "source": ["type": "base64", "media_type": "image/png", "data": .string(pngData)]]]
        let pdf: JSONValue = ["type": "document", "title": "Lease",
                              "source": ["type": "base64", "media_type": "application/pdf", "data": "JVBERi0xLjQK"]]
        let notes: JSONValue = ["type": "document", "title": "notes.txt",
                                "source": ["type": "text", "media_type": "text/plain", "data": "Buy milk"]]
        let reasoning: JSONValue = ["id": "rs_1", "type": "reasoning", "encrypted_content": "gAAAAB",
                                    "summary": [["type": "summary_text", "text": "Checking the calendar."]]]
        let toolRound: [JSONValue] = [
            ["role": "user", "content": .array(png + [pdf, notes, ["type": "text", "text": "Add the dentist on Friday."]])],
            ["role": "assistant", "content": [
                ["type": "otto_responses_reasoning", "item": reasoning],
                ["type": "tool_use", "id": "call_1", "name": "calendar_add_event", "input": ["title": "Dentist"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call_1", "content": [["type": "text", "text": "Added."]]],
            ]],
        ]
        // An Anthropic-format definition, as ToolRegistry.definitions hands it to every client.
        let calendar = SetappAdapterSamples.calendarTool
        let tools: [JSONValue] = [[
            "name": calendar["name"] ?? "", "description": calendar["description"] ?? "",
            "input_schema": calendar["parameters"] ?? [:], "eager_input_streaming": true, "strict": true,
        ]]
        let requests: [(String, MessagesRequest)] = [
            ("plain", MessagesRequest(model: .opus5, system: "You are Otto.", messages: [
                ["role": "user", "content": [["type": "text", "text": "Hi"]]]], maxTokens: 64_000, effort: .medium,
                webAccess: true)),
            ("tool round", MessagesRequest(model: .sonnet5, system: "You are Otto.", messages: toolRound,
                maxTokens: 64_000, effort: .high, webAccess: true, clientTools: tools)),
            ("haiku wrap-up", MessagesRequest(model: .haiku45, system: "", messages: toolRound, maxTokens: 32_000,
                effort: .low, webAccess: false, clientTools: tools, toolChoice: ["type": "none"])),
        ]
        for (name, request) in requests {
            for options in [ResponsesRequestOptions.standard, .compatible] {
                let body = ResponsesRequestBuilder.body(for: request, options: options)
                let wire = try SetappSDKRequest.wireBody(SetappSDKRequest.parameters(from: body))
                let intended = SetappSDKRequest.intendedBody(body)
                let label = "\(name) (\(options == .standard ? "standard" : "compatible"))"
                expectEqual(SetappAdapterJSON.differences(SetappAdapterJSON.normalized(intended),
                                                          SetappAdapterJSON.normalized(wire)), [],
                            "\(label) round-trips through the SDK")
            }
        }
        note("\(requests.count) requests × standard and compatible options")
    }

    /// Each shared fixture, played through the scripted SDK (decoded the way its connector decodes), the transport and
    /// `ResponsesClient`, must end the way the accumulator ends when it reads the raw events itself.
    private func fixturesEndToEnd() async throws {
        let request = MessagesRequest(model: .opus5, system: "You are Otto.",
                                      messages: [["role": "user", "content": [["type": "text", "text": "Hi"]]]],
                                      maxTokens: 64_000, effort: .medium, webAccess: true)
        for (name, lines) in ResponsesFixtures.all {
            for (index, line) in lines.enumerated() {
                do {
                    _ = try SetappSDKCoding.decoder().decode(SetappAIAPI.StreamingEvent.self, from: Data(line.utf8))
                } catch {
                    note("\(name) line \(index) (\(SetappAdapterJSON.decode(line).typeName ?? "?")) doesn't decode: \(error)")
                }
            }
            var expected = ResponsesStreamAccumulator(requestedModel: .opus5)
            var expectedText = ""
            var expectedError: LLMError?
            do {
                for line in lines {
                    for event in try expected.handle(SetappAdapterJSON.decode(line)) {
                        if case .textDelta(let text) = event { expectedText += text }
                    }
                }
            } catch {
                expectedError = error as? LLMError
            }

            let client = ResponsesClient(transport: ScriptedSetappSDK(lines: lines, failsLikeTheConnector: true).transport(),
                                         retryDelays: [])
            var text = ""
            var result: StreamResult?
            var thrown: Error?
            do {
                for try await event in client.stream(request) {
                    switch event {
                    case .textDelta(let delta): text += delta
                    case .completed(let completed): result = completed
                    default: break
                    }
                }
            } catch {
                thrown = error
            }

            if let expectedError {
                expectEqual(thrown as? LLMError, expectedError, "\(name) fails the same way")
                continue
            }
            expect(thrown == nil, "\(name) finishes: \(String(describing: thrown))")
            guard let result, expected.isComplete else {
                fail("\(name) has no result")
                continue
            }
            let reference = expected.result()
            expectEqual(text, expectedText, "\(name) streams the same text")
            expectEqual(result.content, reference.content, "\(name) stores the same blocks")
            expectEqual(result.stopReason, reference.stopReason, "\(name) stops the same way")
            expectEqual(result.model, reference.model, "\(name) names the same model")
            if result.usage != reference.usage {
                note("\(name): usage differs through the SDK (\(result.usage?.encodedString() ?? "none") vs \(reference.usage?.encodedString() ?? "none"))")
            }
        }
        note("\(ResponsesFixtures.all.count) fixture streams")
    }

    // MARK: Transport

    private func transportStreams() async throws {
        let body = Self.body("toolRound")
        let lines = Self.stream("reasoningThenText")
        let sdk = ScriptedSetappSDK(lines: lines)
        let (events, error) = await collect(sdk.transport().events(for: body))
        expect(error == nil, "no error: \(String(describing: error))")
        let parameters = try unwrap(sdk.receivedParameters.first, "the SDK got the parameters")
        expectEqual(SetappAdapterJSON.differences(SetappAdapterJSON.normalized(body),
                                            SetappAdapterJSON.normalized(try SetappSDKRequest.wireBody(parameters))), [],
                    "the SDK sends the body Otto built")
        expectEqual(events.map(\.typeName), lines.map { SetappAdapterJSON.decode($0).typeName }, "every event, in order")
        expectEqual(events.last?["response"]?["usage"]?["input_tokens_details"]?["cached_tokens"], 800, "cached tokens")
        expectEqual(events.last?["response"]?["output"]?[0]?["encrypted_content"], "gAAAAABencryptedMars==",
                    "the reasoning item keeps its encrypted content")
    }

    private func notConfigured() async throws {
        let sdk = ScriptedSetappSDK(lines: [])
        let (events, error) = await collect(sdk.transport(configured: false).events(for: "not even a body"))
        expectEqual(events, [], "no events")
        expectEqual(error as? ResponsesTransportError, .notConfigured, "notConfigured")
        expect(sdk.receivedParameters.isEmpty, "the SDK is never asked")
    }

    private func badBody() async throws {
        let sdk = ScriptedSetappSDK(lines: [])
        let (_, error) = await collect(sdk.transport().events(for: ["input": []]))
        expectEqual(error as? ResponsesTransportError,
                    .badRequest(status: 400, message: SetappSDKRequest.unpreparedMessage), "badRequest")
        expect(sdk.receivedParameters.isEmpty, "the SDK is never asked")
    }

    private func cancellation() async throws {
        let sdk = ScriptedSetappSDK(lines: Array(Self.stream("reasoningThenText").prefix(3)), holdsOpen: true)
        let stream = sdk.transport().events(for: Self.body("text"))
        let consumer = Task { () -> Int in
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        for _ in 0..<200 where sdk.receivedParameters.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<200 where sdk.cancelCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        expect(sdk.cancelCount >= 1, "onTermination cancels the SDK stream")
        note("the SDK stream's onCancel ran \(sdk.cancelCount) time(s)")
    }

    private func rebuiltTerminal() async throws {
        for wrapsErrors in [false, true] {
            let sdk = ScriptedSetappSDK(lines: SetappAdapterSamples.webSearchCited, wrapsErrors: wrapsErrors)
            let (events, error) = await collect(sdk.transport().events(for: Self.body("webSearch")))
            expect(error == nil, "wrapped \(wrapsErrors): no error: \(String(describing: error))")
            let terminal = try unwrap(events.last, "a last event")
            expectEqual(terminal.typeName, "response.completed", "a terminal event")
            expectEqual(terminal["response"]?["id"], "resp_10", "its id")
            expectEqual(terminal["response"]?["model"], "anthropic/claude-sonnet-5", "its model")
            let gatewayTerminal = SetappAdapterJSON.decode(SetappAdapterSamples.webSearchCited.last!)
            expectEqual(terminal["response"]?["output"], gatewayTerminal["response"]?["output"],
                        "the stand-in carries the gateway's items, citations included")
            expect(terminal["response"]?["usage"] == nil, "no usage: it went with the lost event")
            expectEqual(events.count, SetappAdapterSamples.webSearchCited.count, "every event")
        }
        note("a terminal event with a url_citation (start_index) can't decode; rebuilt from output_item.done, without usage")
    }

    private func cutMidItem() async throws {
        let cut = Array(SetappAdapterSamples.webSearchCited.prefix(5)) + [SetappAdapterSamples.undecodable[0].line]
        let (_, error) = await collect(ScriptedSetappSDK(lines: cut).transport().events(for: Self.body("webSearch")))
        expectEqual(error as? ResponsesTransportError,
                    .server(status: 0, message: SetappSDKEventMapper.unreadableMessage), "an open item fails")
    }

    /// Only a terminal event the SDK couldn't decode is ever stood in for: a stream that simply ends early, with its
    /// items finished or not, ends without one, and ResponsesClient reports the early end.
    private func endsWithoutTerminal() async throws {
        let finished = Array(SetappAdapterSamples.webSearchCited.dropLast())
        let open = Array(SetappAdapterSamples.webSearchCited.prefix(5))
        for (name, lines) in [("every item finished", finished), ("an item still open", open)] {
            let (events, error) = await collect(ScriptedSetappSDK(lines: lines).transport().events(for: Self.body("webSearch")))
            expect(error == nil, "\(name): no error")
            expectEqual(events.count, lines.count, "\(name): every event, nothing added")
            expect(!events.contains { SetappSDKEventMapper.terminalTypes.contains($0.typeName ?? "") },
                   "\(name): no stand-in terminal event")
            let thrown = await clientError(lines: lines)
            expectEqual(thrown as? LLMError, .network(ResponsesClient.prematureEOFMessage), "\(name): the early end")
        }
    }

    /// The error ResponsesClient ends a request with when the scripted SDK plays `lines`; nil when it finished.
    private func clientError(lines: [String], failsLikeTheConnector: Bool = false) async -> Error? {
        let sdk = ScriptedSetappSDK(lines: lines, failsLikeTheConnector: failsLikeTheConnector)
        let client = ResponsesClient(transport: sdk.transport(), retryDelays: [])
        do {
            for try await _ in client.stream(Self.checkRequest) {}
            return nil
        } catch {
            return error
        }
    }

    private static let checkRequest = MessagesRequest(
        model: .opus5, system: "You are Otto.", messages: [["role": "user", "content": [["type": "text", "text": "Hi"]]]],
        maxTokens: 64_000, effort: .medium, webAccess: true)

    /// The result ResponsesClient finishes with when the scripted SDK plays `lines`.
    private func clientResult(lines: [String], failsLikeTheConnector: Bool = false) async throws -> StreamResult {
        let sdk = ScriptedSetappSDK(lines: lines, failsLikeTheConnector: failsLikeTheConnector)
        let client = ResponsesClient(transport: sdk.transport(), retryDelays: [])
        var result: StreamResult?
        for try await event in client.stream(Self.checkRequest) {
            if case .completed(let completed) = event { result = completed }
        }
        return try unwrap(result, "a result")
    }

    private func incompleteStandIn() async throws {
        let lines = [
            #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_20","object":"response","created_at":1760400000,"status":"in_progress","model":"anthropic/claude-opus-5","output":[],"parallel_tool_calls":true}}"#,
            #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"function_call","id":"fc_20","call_id":"call_20","name":"music_control","arguments":"","status":"in_progress"}}"#,
            #"{"type":"response.output_item.done","sequence_number":2,"output_index":0,"item":{"type":"function_call","id":"fc_20","call_id":"call_20","name":"music_control","arguments":"{\"action\":\"pl","status":"incomplete"}}"#,
            #"{"type":"response.incomplete","sequence_number":3,"response":{"id":"resp_20","object":"response","created_at":1760400000,"status":"incomplete","model":"anthropic/claude-opus-5","parallel_tool_calls":true,"incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"reasoning","id":"rs_20","content":[{"type":"output_text","text":"x","annotations":[]}]},{"type":"function_call","id":"fc_20","call_id":"call_20","name":"music_control","arguments":"{\"action\":\"pl","status":"incomplete"}],"usage":{"input_tokens":10,"output_tokens":64000,"total_tokens":64010}}}"#,
        ]
        let (events, error) = await collect(ScriptedSetappSDK(lines: lines).transport().events(for: Self.body("tools")))
        expect(error == nil, "no error: \(String(describing: error))")
        let terminal = try unwrap(events.last, "a last event")
        expectEqual(terminal.typeName, "response.incomplete", "an incomplete item makes an incomplete response")
        expectEqual(terminal["response"]?["status"], "incomplete", "its status")
        expectEqual(terminal["response"]?["incomplete_details"], ["reason": "max_output_tokens"], "its reason")
        let result = try await clientResult(lines: lines)
        expectEqual(result.stopReason, "max_tokens", "the cut-off call isn't run")

        let complete = Array(SetappAdapterSamples.webSearchCited.dropLast()) + [SetappAdapterSamples.undecodable[0].line]
        let (completeEvents, _) = await collect(ScriptedSetappSDK(lines: complete).transport().events(for: Self.body("webSearch")))
        expectEqual(completeEvents.last?.typeName, "response.completed", "finished items make a completed response")
        note("a stand-in is response.incomplete (max_output_tokens) when a finished item says incomplete")
    }

    /// Older LiteLLM puts every item at output index 0: the stand-in keeps each finished item, in the order they
    /// finished, instead of the last one.
    private func sameIndexItems() async throws {
        let lines = ResponsesFixtures.litellmReasoning
        let (events, error) = await collect(ScriptedSetappSDK(lines: lines).transport().events(for: Self.body("text")))
        expect(error == nil, "no error: \(String(describing: error))")
        let output = try unwrap(events.last?["response"]?["output"]?.arrayValue, "a stand-in with an output")
        expectEqual(output.map { $0["id"]?.stringValue ?? "?" }, ["rs_5f1d8e2a-0c4b-4f7e-9a61-3b2c7d9e0f12", "msg_12think"],
                    "both items at output index 0")
        let result = try await clientResult(lines: lines)
        expectEqual(result.content.compactMap(\.typeName), ["thinking", "otto_responses_reasoning", "text"], "blocks")
        expectEqual(result.content.first?["thinking"], "The user asks for the time in Tokyo. Tokyo is UTC+9.", "thinking")
        expectEqual(result.stopReason, "end_turn", "stop reason")
    }

    private func litellmReasoningTerminal() async throws {
        let line = SetappAdapterSamples.litellmReasoningTerminal
        let raw = SetappAdapterJSON.decode(line)
        // Its text survives (the connector's parse error carries it): yielded as the gateway sent it.
        let (events, error) = await collect(ScriptedSetappSDK(lines: [line], failsLikeTheConnector: true).transport()
            .events(for: Self.body("text")))
        expect(error == nil, "no error: \(String(describing: error))")
        expectEqual(events, [raw], "the raw terminal event")
        let result = try await clientResult(lines: [line], failsLikeTheConnector: true)
        expectEqual(result.content, [
            ["type": "thinking", "thinking": "Thinking about it.", "signature": ""],
            ["type": "otto_responses_reasoning", "item": raw["response"]?["output"]?[0] ?? .null],
            ["type": "text", "text": "Hi"],
        ], "the reasoning summary comes from its content")
        // Its text lost, nothing finished before it: no stand-in, so the reply fails instead of ending empty.
        let (_, lost) = await collect(ScriptedSetappSDK(lines: [line]).transport().events(for: Self.body("text")))
        expectEqual(lost as? ResponsesTransportError, .server(status: 0, message: SetappSDKEventMapper.unreadableMessage),
                    "unreadable")
    }

    private func typelessErrorFrame() async throws {
        let line = SetappAdapterSamples.litellmErrorFrame
        let expected: JSONValue = ["type": "error", "code": "529",
                                   "message": "litellm.InternalServerError: AnthropicException - Overloaded"]
        let (events, error) = await collect(ScriptedSetappSDK(lines: [line], failsLikeTheConnector: true).transport()
            .events(for: Self.body("text")))
        expect(error == nil, "no error: \(String(describing: error))")
        expectEqual(events, [expected], "the error event it means")
        expectEqual(await clientError(lines: [line], failsLikeTheConnector: true) as? LLMError, .overloaded,
                    "ResponsesClient reads it as an overload")
        let rejected = #"{"error":{"message":"messages.0: Could not process image","type":"invalid_request_error","param":null,"code":null}}"#
        expectEqual(await clientError(lines: [rejected], failsLikeTheConnector: true) as? LLMError,
                    .http(status: 400, type: "invalid_request_error", message: "messages.0: Could not process image"),
                    "the type stands in for a missing code")
        // As an `.unsupported` event (a later SDK might pass it on), the mapper converts it the same way.
        var mapper = SetappSDKEventMapper()
        let unsupported = SetappAIAPI.StreamingEvent.unsupported(SetappAIAPI.UnsupportedObject(
            type: .unsupported(""), object: try unwrap(SendableJSON.object(SetappAdapterJSON.decode(line)), "an object")))
        expectEqual(mapper.map(unsupported), [expected], "an unsupported frame")
        expect(mapper.isFinished, "it ends the stream")
        // Its text lost: unreadable.
        let (_, lost) = await collect(ScriptedSetappSDK(lines: [line]).transport().events(for: Self.body("text")))
        expectEqual(lost as? ResponsesTransportError, .server(status: 0, message: SetappSDKEventMapper.unreadableMessage),
                    "unreadable without its text")
    }

    private func thrownErrorEvent() async throws {
        let line = #"{"type":"error","sequence_number":2,"code":"insufficient_credits","message":"Not enough credits.","param":"model"}"#
        let (events, error) = await collect(ScriptedSetappSDK(lines: [line]).transport().events(for: Self.body("text")))
        expect(error == nil, "no error")
        expectEqual(events, [["type": "error", "code": "insufficient_credits", "message": "Not enough credits.",
                              "param": "model", "sequence_number": 2]], "the error event")
    }

    private func nullParamErrorEvent() async throws {
        let line = SetappAdapterSamples.undecodable.first { $0.name == "error with param null" }!.line
        let (_, error) = await collect(ScriptedSetappSDK(lines: [line]).transport().events(for: Self.body("text")))
        expectEqual(error as? ResponsesTransportError,
                    .server(status: 0, message: SetappSDKEventMapper.unreadableMessage), "unreadable")

        let parse = FakeWebServiceError.parsingError(
            message: "[ModelWebService] Failed to parse SSE event: keyNotFound, line: \(line)")
        let wrapped = SetappAIError(code: .general, underlyingError: parse, recoveryURL: nil)
        let (events, recovered) = await collect(
            ScriptedSetappSDK(lines: [], finalError: wrapped).transport().events(for: Self.body("text")))
        expect(recovered == nil, "no error once the text survives")
        expectEqual(events.first?["code"], "insufficient_credits", "the gateway's own error event")
        note("an OpenAI error event has param: null, which the SDK refuses; Otto uses it only if the connector's text reaches it")
    }

    // MARK: Errors

    private func setappAIErrorCodes() async throws {
        expectEqual(SetappSDKErrors.transportError(for: SetappAIError(code: .insufficientCredits)), .insufficientCredits,
                    "insufficientCredits")
        expectEqual(SetappSDKErrors.transportError(for: SetappAIError(code: .modelNotAllowed)), .modelNotAllowed,
                    "modelNotAllowed")
        expectEqual(SetappSDKErrors.transportError(for: SetappAIError(code: .rateLimit)), .rateLimited(retryAfter: nil),
                    "rateLimit")
        if case .unavailable = SetappSDKErrors.transportError(for: SetappAIError(code: .general)) {} else {
            fail("general with nothing underneath is unavailable")
        }
    }

    private func httpStatuses() async throws {
        func general(_ status: Int, _ body: String?) -> ResponsesTransportError {
            SetappSDKErrors.transportError(for: SetappAIError(
                code: .general,
                underlyingError: FakeWebServiceError.httpError(statusCode: status, errorBody: body.map { Data($0.utf8) }),
                recoveryURL: nil))
        }
        let overflow = #"{"error":{"message":"prompt is too long: 250000 tokens > 200000 maximum","type":"invalid_request_error","code":"context_length_exceeded","param":null}}"#
        expectEqual(general(400, overflow),
                    .badRequest(status: 400, message: "prompt is too long: 250000 tokens > 200000 maximum"), "400")
        expectEqual(general(401, #"{"statusCode":401,"message":"Token expired","code":"UNAUTHORIZED"}"#), .unauthorized, "401")
        expectEqual(general(402, #"{"statusCode":402,"message":"Not enough credits","code":"INSUFFICIENT_CREDITS"}"#),
                    .insufficientCredits, "402")
        expectEqual(general(403, #"{"error":{"message":"team not allowed to access model","type":"auth_error","code":"403"}}"#),
                    .modelNotAllowed, "403")
        expectEqual(general(422, #"{"statusCode":422,"message":"max_tokens must be positive","code":"VALIDATION","errors":[]}"#),
                    .badRequest(status: 422, message: "max_tokens must be positive"), "422")
        expectEqual(general(429, nil), .rateLimited(retryAfter: nil), "429")
        expectEqual(general(500, #"{"statusCode":500,"message":"Upstream failed","code":"INTERNAL_SERVER_ERROR","request_id":"r1"}"#),
                    .server(status: 500, message: "Upstream failed"), "500")
        expectEqual(general(529, #"{"error":{"message":"Overloaded","type":"overloaded_error"}}"#),
                    .server(status: 529, message: "Overloaded"), "529")
        expectEqual(general(413, nil), .badRequest(status: 413, message: ""), "413")
        let decoded = FakeWebServiceError.decodedBody(
            statusCode: 402, body: FakeGatewayBody(statusCode: 402, message: "Top up", code: "INSUFFICIENT_CREDITS"))
        expectEqual(SetappSDKErrors.transportError(for: SetappAIError(code: .general, underlyingError: decoded, recoveryURL: nil)),
                    .insufficientCredits, "a decoded gateway body")
    }

    private func networkAndCancellation() async throws {
        expectEqual(SetappSDKErrors.transportError(for: SetappAIError(
                        code: .general, underlyingError: URLError(.notConnectedToInternet), recoveryURL: nil)),
                    .network("You're offline. Check your internet connection and try again."), "offline")
        expectEqual(SetappSDKErrors.transportError(for: URLError(.timedOut)), .network("The request to Setapp AI timed out."),
                    "timed out")
        expectEqual(SetappSDKErrors.transportError(for: URLError(.cannotFindHost)), .network(""), "other network failures")
        expect(SetappSDKErrors.isCancellation(CancellationError()), "CancellationError")
        expect(SetappSDKErrors.isCancellation(URLError(.cancelled)), "URLError.cancelled")
        expect(SetappSDKErrors.isCancellation(SetappAIError(code: .general, underlyingError: CancellationError(), recoveryURL: nil)),
               "a wrapped CancellationError")
        expect(!SetappSDKErrors.isCancellation(SetappAIError(code: .general)), "a plain general error")
    }

    // MARK: Configuration

    private func oauthRules() async throws {
        let id = SetappSDKTransport.clientIDKey
        let secret = SetappSDKTransport.clientSecretKey
        expectEqual(SetappAIOAuthClient.load(infoDictionary: [id: " abc123 ", secret: "s3cr3t"]),
                    SetappAIOAuthClient(clientID: "abc123", secret: "s3cr3t"), "usable values, trimmed")
        for bad in ["", "   ", "$(OTTO_SETAPP_AI_CLIENT_ID)", "JALEN_MUST_SET_SETAPP_AI_CLIENT_ID", "two words",
                    "your-oauth-client-id", "YOUR_CLIENT_ID_HERE"] {
            expect(SetappAIOAuthClient.load(infoDictionary: [id: bad, secret: "s3cr3t"]) == nil, "client id '\(bad)'")
            expect(SetappAIOAuthClient.load(infoDictionary: [id: "abc123", secret: bad]) == nil, "secret '\(bad)'")
        }
        expect(SetappAIOAuthClient.load(infoDictionary: [id: "abc123"]) == nil, "a missing secret")
        expect(SetappAIOAuthClient.load(infoDictionary: [id: 42, secret: "s3cr3t"]) == nil, "a number")
    }

    private func infoPlist() async throws {
        let info = Bundle.main.infoDictionary ?? [:]
        expect(info[SetappSDKTransport.clientIDKey] is String, "Info.plist has OttoSetappAIClientID")
        expect(info[SetappSDKTransport.clientSecretKey] is String, "Info.plist has OttoSetappAIClientSecret")
        let expected = SetappAIOAuthClient.load(infoDictionary: info) != nil
        expectEqual(SetappSDKTransport.configureIfNeeded(), expected, "configureIfNeeded")
        expectEqual(SetappSDKTransport.configureIfNeeded(), expected, "configureIfNeeded again")
        note("this build: \(expected ? "configured" : "not configured (no OAuth client, J22)")")
    }

    // MARK: Account

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var forces: [Bool] = []
        var all: [Bool] { lock.withLock { forces } }
        func record(_ force: Bool) { lock.withLock { forces.append(force) } }
    }

    nonisolated private static func balances(_ available: Decimal, of granted: Decimal,
                                             currency: SetappAIAPI.Credits.Amount.Currency = .macpawCredits)
        -> SetappAIAPI.Credits.Balances {
        SetappAIAPI.Credits.Balances(balances: [],
                                     totalAvailable: .init(amount: available, currency: currency),
                                     totalInitialAmount: .init(amount: granted, currency: currency))
    }

    /// A call that ignores cancellation, like an XPC round trip to a stalled Setapp.
    nonisolated private static func stall(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private func account(
        configured: Bool = true,
        balance: @escaping LiveSetappAIAccount.BalanceFetcher,
        link: @escaping LiveSetappAIAccount.PurchaseLinkFetcher = { nil },
        timeout: Duration = .seconds(2)
    ) -> LiveSetappAIAccount {
        LiveSetappAIAccount(isConfigured: configured, fetchBalances: balance, fetchPurchaseLink: link,
                            balanceTimeout: timeout, purchaseLinkTimeout: .milliseconds(300))
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        expect(condition(), "timed out waiting for \(what)")
    }

    private func accountLoads() async throws {
        let calls = Calls()
        let account = account(balance: { force in calls.record(force); return Self.balances(1234, of: 6000) })
        expect(account.isConfigured, "configured")
        expectEqual(account.creditState, .idle, "starts idle")
        account.refreshCredits(force: true)
        expectEqual(account.creditState, .loading, "loading from idle")
        await waitUntil("the balance") { account.creditState != .loading }
        expectEqual(account.creditState, .loaded(SetappCreditBalance(available: 1234, granted: 6000)), "loaded")
        expectEqual(calls.all, [true], "force passed through")
    }

    private func accountKeepsLoaded() async throws {
        let calls = Calls()
        let account = account(balance: { force in
            calls.record(force)
            if calls.all.count > 1 { await Self.stall(seconds: 0.3) }
            return Self.balances(calls.all.count == 1 ? 10 : 9, of: 10)
        })
        account.refreshCredits(force: false)
        await waitUntil("the first balance") { account.creditState == .loaded(SetappCreditBalance(available: 10, granted: 10)) }
        account.refreshCredits(force: true)
        account.refreshCredits(force: true)
        account.refreshCredits(force: false)
        expectEqual(account.creditState, .loaded(SetappCreditBalance(available: 10, granted: 10)), "no flash of loading")
        await waitUntil("the second balance") { account.creditState == .loaded(SetappCreditBalance(available: 9, granted: 10)) }
        expectEqual(calls.all, [false, true], "the calls during the refresh were ignored")
    }

    private func accountTimesOut() async throws {
        let account = account(balance: { _ in await Self.stall(seconds: 3); return Self.balances(1, of: 1) },
                              timeout: .milliseconds(200))
        let start = ContinuousClock.now
        account.refreshCredits(force: true)
        await waitUntil("the timeout") { account.creditState != .loading }
        expectEqual(account.creditState, .failed(LiveSetappAIAccount.loadFailedCopy), "failed")
        expect(ContinuousClock.now - start < .seconds(2), "the deadline doesn't wait for the call")
    }

    private func accountFailures() async throws {
        struct Boom: Error {}
        let failing = account(balance: { _ in throw Boom() })
        failing.refreshCredits(force: false)
        await waitUntil("the failure") { failing.creditState != .loading }
        expectEqual(failing.creditState, .failed(LiveSetappAIAccount.loadFailedCopy), "an error")

        let odd = account(balance: { _ in Self.balances(5, of: 5, currency: .unsupported("usd")) })
        odd.refreshCredits(force: false)
        await waitUntil("the odd unit") { odd.creditState != .loading }
        expectEqual(odd.creditState, .failed(LiveSetappAIAccount.unknownUnitCopy), "an unknown unit")
    }

    private func accountZeroAndRetry() async throws {
        let calls = Calls()
        let account = account(balance: { force in
            calls.record(force)
            if calls.all.count == 1 { throw URLError(.timedOut) }
            return Self.balances(0, of: 6000)
        })
        account.refreshCredits(force: false)
        await waitUntil("the failure") { account.creditState != .loading }
        expectEqual(account.creditState, .failed(LiveSetappAIAccount.loadFailedCopy), "failed")
        account.refreshCredits(force: true)
        expectEqual(account.creditState, .loading, "Try Again shows progress")
        await waitUntil("the retry") { account.creditState != .loading }
        expectEqual(account.creditState, .loaded(SetappCreditBalance(available: 0, granted: 6000)), "a real zero")
    }

    private func accountStateMapping() async throws {
        expectEqual(LiveSetappAIAccount.state(for: .success(Self.balances(1999.6, of: 6000))),
                    .loaded(SetappCreditBalance(available: 1999.6, granted: 6000)), "credits")
        let mixed = SetappAIAPI.Credits.Balances(balances: [],
                                                 totalAvailable: .init(amount: 40, currency: .macpawCredits),
                                                 totalInitialAmount: .init(amount: 99, currency: .unsupported("x")))
        expectEqual(LiveSetappAIAccount.state(for: .success(mixed)),
                    .loaded(SetappCreditBalance(available: 40, granted: 0)), "an unknown grant reads as no grant")
    }

    private func accountUnconfigured() async throws {
        let calls = Calls()
        let account = account(configured: false, balance: { force in calls.record(force); return Self.balances(1, of: 1) })
        account.refreshCredits(force: true)
        try await Task.sleep(for: .milliseconds(50))
        expectEqual(account.creditState, .idle, "stays idle")
        expectEqual(calls.all, [], "no SDK call")
    }

    private func accountPurchase() async throws {
        let fallback = SetappCreditFormatter.fallbackPurchaseURL
        let sdkLink = URL(string: "https://store.setapp.com/ai/credits?app=otto")!
        let cases: [(String, LiveSetappAIAccount.PurchaseLinkFetcher, URL)] = [
            ("the SDK's link", { sdkLink }, sdkLink),
            ("no link", { nil }, fallback),
            ("an error", { throw URLError(.notConnectedToInternet) }, fallback),
            ("a stall", { await Self.stall(seconds: 2); return URL(string: "https://late.example.com") }, fallback),
            ("not a web page", { URL(string: "file:///etc/hosts") }, fallback),
            ("plain http", { URL(string: "http://store.setapp.com/ai/credits") }, fallback),
        ]
        for (name, link, expected) in cases {
            let account = account(balance: { _ in Self.balances(1, of: 1) }, link: link)
            let start = ContinuousClock.now
            expectEqual(await account.purchaseURL(), expected, name)
            expect(ContinuousClock.now - start < .seconds(1), "\(name): the deadline doesn't wait for the call")
        }
    }
}
#endif
