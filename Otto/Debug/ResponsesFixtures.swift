//
//  ResponsesFixtures.swift
//  Otto
//
//  Gateway event streams for the Setapp AI client's tests and the Setapp SDK adapter check: one scenario per
//  `static let`, one JSON event per element, in the order the gateway sends them.
//
//  Every stream here is synthesized, not recorded: Setapp AI can't be called without Setapp's OAuth client (J22).
//  Each one follows OpenAI's documented Responses streaming events (event and field names as in
//  developers.openai.com/api/reference/resources/responses/streaming-events, checked 2026-10-13); ids, text,
//  token counts and encrypted content are made up, and every web address is a reserved `.example` name.
//

// Debug tooling: compiled only into Debug builds.
#if DEBUG

import Foundation

enum ResponsesFixtures {
    /// Opus 5 answers in two text deltas. 1,840 input tokens, 1,536 of them cached.
    static let text: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_01text","object":"response","created_at":1791849600,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[],"usage":null}}"#,
        #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_01text","object":"response","created_at":1791849600,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"msg_01text","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":3,"item_id":"msg_01text","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_01text","output_index":0,"content_index":0,"delta":"Swift 6.2 makes concurrency ","logprobs":[]}"#,
        #"{"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_01text","output_index":0,"content_index":0,"delta":"easier to adopt: app code runs on the main actor by default.","logprobs":[]}"#,
        #"{"type":"response.output_text.done","sequence_number":6,"item_id":"msg_01text","output_index":0,"content_index":0,"text":"Swift 6.2 makes concurrency easier to adopt: app code runs on the main actor by default.","logprobs":[]}"#,
        #"{"type":"response.content_part.done","sequence_number":7,"item_id":"msg_01text","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Swift 6.2 makes concurrency easier to adopt: app code runs on the main actor by default.","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_item.done","sequence_number":8,"output_index":0,"item":{"id":"msg_01text","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Swift 6.2 makes concurrency easier to adopt: app code runs on the main actor by default.","annotations":[],"logprobs":[]}]}}"#,
        #"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_01text","object":"response","created_at":1791849600,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[{"id":"msg_01text","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Swift 6.2 makes concurrency easier to adopt: app code runs on the main actor by default.","annotations":[],"logprobs":[]}]}],"usage":{"input_tokens":1840,"input_tokens_details":{"cached_tokens":1536},"output_tokens":22,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":1862}}}"#,
    ]

    /// Sonnet 5 streams a two-part reasoning summary, then the answer. The gateway reports the bare model id
    /// ("claude-sonnet-5", no "anthropic/").
    static let reasoningThenText: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_02reason","object":"response","created_at":1791849660,"status":"in_progress","error":null,"incomplete_details":null,"model":"claude-sonnet-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"rs_02reason","type":"reasoning","summary":[]}}"#,
        #"{"type":"response.reasoning_summary_part.added","sequence_number":2,"item_id":"rs_02reason","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#,
        #"{"type":"response.reasoning_summary_text.delta","sequence_number":3,"item_id":"rs_02reason","output_index":0,"summary_index":0,"delta":"**Checking the meeting time**\n\n"}"#,
        #"{"type":"response.reasoning_summary_text.delta","sequence_number":4,"item_id":"rs_02reason","output_index":0,"summary_index":0,"delta":"The invite says 3 PM Pacific."}"#,
        #"{"type":"response.reasoning_summary_text.done","sequence_number":5,"item_id":"rs_02reason","output_index":0,"summary_index":0,"text":"**Checking the meeting time**\n\nThe invite says 3 PM Pacific."}"#,
        #"{"type":"response.reasoning_summary_part.done","sequence_number":6,"item_id":"rs_02reason","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":"**Checking the meeting time**\n\nThe invite says 3 PM Pacific."}}"#,
        #"{"type":"response.reasoning_summary_part.added","sequence_number":7,"item_id":"rs_02reason","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""}}"#,
        #"{"type":"response.reasoning_summary_text.delta","sequence_number":8,"item_id":"rs_02reason","output_index":0,"summary_index":1,"delta":"That is 6 PM in New York."}"#,
        #"{"type":"response.reasoning_summary_text.done","sequence_number":9,"item_id":"rs_02reason","output_index":0,"summary_index":1,"text":"That is 6 PM in New York."}"#,
        #"{"type":"response.reasoning_summary_part.done","sequence_number":10,"item_id":"rs_02reason","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":"That is 6 PM in New York."}}"#,
        #"{"type":"response.output_item.done","sequence_number":11,"output_index":0,"item":{"id":"rs_02reason","type":"reasoning","summary":[{"type":"summary_text","text":"**Checking the meeting time**\n\nThe invite says 3 PM Pacific."},{"type":"summary_text","text":"That is 6 PM in New York."}],"encrypted_content":"gAAAAABsynthetic-encrypted-reasoning-02"}}"#,
        #"{"type":"response.output_item.added","sequence_number":12,"output_index":1,"item":{"id":"msg_02reason","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":13,"item_id":"msg_02reason","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_text.delta","sequence_number":14,"item_id":"msg_02reason","output_index":1,"content_index":0,"delta":"The meeting starts at 6 PM ","logprobs":[]}"#,
        #"{"type":"response.output_text.delta","sequence_number":15,"item_id":"msg_02reason","output_index":1,"content_index":0,"delta":"in New York.","logprobs":[]}"#,
        #"{"type":"response.output_text.done","sequence_number":16,"item_id":"msg_02reason","output_index":1,"content_index":0,"text":"The meeting starts at 6 PM in New York.","logprobs":[]}"#,
        #"{"type":"response.content_part.done","sequence_number":17,"item_id":"msg_02reason","output_index":1,"content_index":0,"part":{"type":"output_text","text":"The meeting starts at 6 PM in New York.","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_item.done","sequence_number":18,"output_index":1,"item":{"id":"msg_02reason","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"The meeting starts at 6 PM in New York.","annotations":[],"logprobs":[]}]}}"#,
        #"{"type":"response.completed","sequence_number":19,"response":{"id":"resp_02reason","object":"response","created_at":1791849660,"status":"completed","error":null,"incomplete_details":null,"model":"claude-sonnet-5","output":[{"id":"rs_02reason","type":"reasoning","summary":[{"type":"summary_text","text":"**Checking the meeting time**\n\nThe invite says 3 PM Pacific."},{"type":"summary_text","text":"That is 6 PM in New York."}],"encrypted_content":"gAAAAABsynthetic-encrypted-reasoning-02"},{"id":"msg_02reason","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"The meeting starts at 6 PM in New York.","annotations":[],"logprobs":[]}]}],"usage":{"input_tokens":920,"input_tokens_details":{"cached_tokens":0},"output_tokens":140,"output_tokens_details":{"reasoning_tokens":96},"total_tokens":1060}}}"#,
    ]

    /// Opus 5 searches (two sources), opens one of the pages, then answers with two `url_citation`s: one for the
    /// opened page and one for a page neither the search nor the open listed.
    static let webSearch: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_03web","object":"response","created_at":1791849720,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"ws_03search","type":"web_search_call","status":"in_progress"}}"#,
        #"{"type":"response.web_search_call.in_progress","sequence_number":2,"output_index":0,"item_id":"ws_03search"}"#,
        #"{"type":"response.web_search_call.searching","sequence_number":3,"output_index":0,"item_id":"ws_03search"}"#,
        #"{"type":"response.web_search_call.completed","sequence_number":4,"output_index":0,"item_id":"ws_03search"}"#,
        #"{"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":{"id":"ws_03search","type":"web_search_call","status":"completed","action":{"type":"search","query":"Swift 6.2 release notes","sources":[{"type":"url","url":"https://www.swift.example/blog/swift-6-2-released/"},{"type":"url","url":"https://news.example/swift-6-2"}]}}}"#,
        #"{"type":"response.output_item.added","sequence_number":6,"output_index":1,"item":{"id":"ws_03page","type":"web_search_call","status":"in_progress"}}"#,
        #"{"type":"response.web_search_call.in_progress","sequence_number":7,"output_index":1,"item_id":"ws_03page"}"#,
        #"{"type":"response.web_search_call.completed","sequence_number":8,"output_index":1,"item_id":"ws_03page"}"#,
        #"{"type":"response.output_item.done","sequence_number":9,"output_index":1,"item":{"id":"ws_03page","type":"web_search_call","status":"completed","action":{"type":"open_page","url":"https://www.swift.example/blog/swift-6-2-released/"}}}"#,
        #"{"type":"response.output_item.added","sequence_number":10,"output_index":2,"item":{"id":"msg_03web","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":11,"item_id":"msg_03web","output_index":2,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_text.delta","sequence_number":12,"item_id":"msg_03web","output_index":2,"content_index":0,"delta":"Swift 6.2 focuses on approachable concurrency.","logprobs":[]}"#,
        #"{"type":"response.output_text.annotation.added","sequence_number":13,"item_id":"msg_03web","output_index":2,"content_index":0,"annotation_index":0,"annotation":{"type":"url_citation","url":"https://www.swift.example/blog/swift-6-2-released/","title":"Swift 6.2 Released","start_index":0,"end_index":46}}"#,
        #"{"type":"response.output_text.delta","sequence_number":14,"item_id":"msg_03web","output_index":2,"content_index":0,"delta":" The forums cover the migration.","logprobs":[]}"#,
        #"{"type":"response.output_text.annotation.added","sequence_number":15,"item_id":"msg_03web","output_index":2,"content_index":0,"annotation_index":1,"annotation":{"type":"url_citation","url":"https://forums.swift.example/t/migrating-to-swift-6-2","title":"Migrating to  Swift 6.2","start_index":47,"end_index":78}}"#,
        #"{"type":"response.output_text.done","sequence_number":16,"item_id":"msg_03web","output_index":2,"content_index":0,"text":"Swift 6.2 focuses on approachable concurrency. The forums cover the migration.","logprobs":[]}"#,
        #"{"type":"response.content_part.done","sequence_number":17,"item_id":"msg_03web","output_index":2,"content_index":0,"part":{"type":"output_text","text":"Swift 6.2 focuses on approachable concurrency. The forums cover the migration.","annotations":[{"type":"url_citation","url":"https://www.swift.example/blog/swift-6-2-released/","title":"Swift 6.2 Released","start_index":0,"end_index":46},{"type":"url_citation","url":"https://forums.swift.example/t/migrating-to-swift-6-2","title":"Migrating to  Swift 6.2","start_index":47,"end_index":78}],"logprobs":[]}}"#,
        #"{"type":"response.output_item.done","sequence_number":18,"output_index":2,"item":{"id":"msg_03web","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Swift 6.2 focuses on approachable concurrency. The forums cover the migration.","annotations":[{"type":"url_citation","url":"https://www.swift.example/blog/swift-6-2-released/","title":"Swift 6.2 Released","start_index":0,"end_index":46},{"type":"url_citation","url":"https://forums.swift.example/t/migrating-to-swift-6-2","title":"Migrating to  Swift 6.2","start_index":47,"end_index":78}],"logprobs":[]}]}}"#,
        #"{"type":"response.completed","sequence_number":19,"response":{"id":"resp_03web","object":"response","created_at":1791849720,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[{"id":"ws_03search","type":"web_search_call","status":"completed","action":{"type":"search","query":"Swift 6.2 release notes","sources":[{"type":"url","url":"https://www.swift.example/blog/swift-6-2-released/"},{"type":"url","url":"https://news.example/swift-6-2"}]}},{"id":"ws_03page","type":"web_search_call","status":"completed","action":{"type":"open_page","url":"https://www.swift.example/blog/swift-6-2-released/"}},{"id":"msg_03web","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Swift 6.2 focuses on approachable concurrency. The forums cover the migration.","annotations":[{"type":"url_citation","url":"https://www.swift.example/blog/swift-6-2-released/","title":"Swift 6.2 Released","start_index":0,"end_index":46},{"type":"url_citation","url":"https://forums.swift.example/t/migrating-to-swift-6-2","title":"Migrating to  Swift 6.2","start_index":47,"end_index":78}],"logprobs":[]}]}],"usage":{"input_tokens":5210,"input_tokens_details":{"cached_tokens":0},"output_tokens":184,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":5394}}}"#,
    ]

    /// Opus 5 says what it will do, then calls `calendar_create_event`, its arguments streamed in two deltas.
    static let functionCall: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_04call","object":"response","created_at":1791849780,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg_04call","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_04call","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_04call","output_index":0,"content_index":0,"delta":"I'll add the dentist appointment to your calendar.","logprobs":[]}"#,
        #"{"type":"response.output_text.done","sequence_number":4,"item_id":"msg_04call","output_index":0,"content_index":0,"text":"I'll add the dentist appointment to your calendar.","logprobs":[]}"#,
        #"{"type":"response.content_part.done","sequence_number":5,"item_id":"msg_04call","output_index":0,"content_index":0,"part":{"type":"output_text","text":"I'll add the dentist appointment to your calendar.","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"id":"msg_04call","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"I'll add the dentist appointment to your calendar.","annotations":[],"logprobs":[]}]}}"#,
        #"{"type":"response.output_item.added","sequence_number":7,"output_index":1,"item":{"id":"fc_04call","type":"function_call","status":"in_progress","call_id":"call_04event","name":"calendar_create_event","arguments":""}}"#,
        #"{"type":"response.function_call_arguments.delta","sequence_number":8,"item_id":"fc_04call","output_index":1,"delta":"{\"title\":\"Dentist\","}"#,
        #"{"type":"response.function_call_arguments.delta","sequence_number":9,"item_id":"fc_04call","output_index":1,"delta":"\"start\":\"2026-10-15T09:00\",\"end\":\"2026-10-15T10:00\"}"}"#,
        #"{"type":"response.function_call_arguments.done","sequence_number":10,"item_id":"fc_04call","output_index":1,"arguments":"{\"title\":\"Dentist\",\"start\":\"2026-10-15T09:00\",\"end\":\"2026-10-15T10:00\"}"}"#,
        #"{"type":"response.output_item.done","sequence_number":11,"output_index":1,"item":{"id":"fc_04call","type":"function_call","status":"completed","call_id":"call_04event","name":"calendar_create_event","arguments":"{\"title\":\"Dentist\",\"start\":\"2026-10-15T09:00\",\"end\":\"2026-10-15T10:00\"}"}}"#,
        #"{"type":"response.completed","sequence_number":12,"response":{"id":"resp_04call","object":"response","created_at":1791849780,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[{"id":"msg_04call","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"I'll add the dentist appointment to your calendar.","annotations":[],"logprobs":[]}]},{"id":"fc_04call","type":"function_call","status":"completed","call_id":"call_04event","name":"calendar_create_event","arguments":"{\"title\":\"Dentist\",\"start\":\"2026-10-15T09:00\",\"end\":\"2026-10-15T10:00\"}"}],"usage":{"input_tokens":3020,"input_tokens_details":{"cached_tokens":2048},"output_tokens":61,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":3081}}}"#,
    ]

    /// The same call as `functionCall`, delivered the way the Setapp SDK may: only the typed events (text deltas
    /// and `response.completed`), so the call exists only in the terminal output.
    static let functionCallCompletedOnly: [String] = [
        #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_04call","output_index":0,"content_index":0,"delta":"I'll add the dentist ","logprobs":[]}"#,
        #"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_04call","output_index":0,"content_index":0,"delta":"appointment to your calendar.","logprobs":[]}"#,
        #"{"type":"response.completed","sequence_number":12,"response":{"id":"resp_04call","object":"response","created_at":1791849780,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[{"id":"msg_04call","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"I'll add the dentist appointment to your calendar.","annotations":[],"logprobs":[]}]},{"id":"fc_04call","type":"function_call","status":"completed","call_id":"call_04event","name":"calendar_create_event","arguments":"{\"title\":\"Dentist\",\"start\":\"2026-10-15T09:00\",\"end\":\"2026-10-15T10:00\"}"}],"usage":{"input_tokens":3020,"input_tokens_details":{"cached_tokens":2048},"output_tokens":61,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":3081}}}"#,
    ]

    /// Sonnet 5 calls `calendar_list_events` and `reminders_list` (no parameters) in one response, no text.
    static let parallelFunctionCalls: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_05pair","object":"response","created_at":1791849840,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-sonnet-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"fc_05events","type":"function_call","status":"in_progress","call_id":"call_05events","name":"calendar_list_events","arguments":""}}"#,
        #"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"fc_05events","output_index":0,"delta":"{\"start\":\"2026-10-14\","}"#,
        #"{"type":"response.function_call_arguments.delta","sequence_number":3,"item_id":"fc_05events","output_index":0,"delta":"\"end\":\"2026-10-15\"}"}"#,
        #"{"type":"response.function_call_arguments.done","sequence_number":4,"item_id":"fc_05events","output_index":0,"arguments":"{\"start\":\"2026-10-14\",\"end\":\"2026-10-15\"}"}"#,
        #"{"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":{"id":"fc_05events","type":"function_call","status":"completed","call_id":"call_05events","name":"calendar_list_events","arguments":"{\"start\":\"2026-10-14\",\"end\":\"2026-10-15\"}"}}"#,
        #"{"type":"response.output_item.added","sequence_number":6,"output_index":1,"item":{"id":"fc_05reminders","type":"function_call","status":"in_progress","call_id":"call_05reminders","name":"reminders_list","arguments":""}}"#,
        #"{"type":"response.function_call_arguments.delta","sequence_number":7,"item_id":"fc_05reminders","output_index":1,"delta":"{}"}"#,
        #"{"type":"response.function_call_arguments.done","sequence_number":8,"item_id":"fc_05reminders","output_index":1,"arguments":"{}"}"#,
        #"{"type":"response.output_item.done","sequence_number":9,"output_index":1,"item":{"id":"fc_05reminders","type":"function_call","status":"completed","call_id":"call_05reminders","name":"reminders_list","arguments":"{}"}}"#,
        #"{"type":"response.completed","sequence_number":10,"response":{"id":"resp_05pair","object":"response","created_at":1791849840,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-sonnet-5","output":[{"id":"fc_05events","type":"function_call","status":"completed","call_id":"call_05events","name":"calendar_list_events","arguments":"{\"start\":\"2026-10-14\",\"end\":\"2026-10-15\"}"},{"id":"fc_05reminders","type":"function_call","status":"completed","call_id":"call_05reminders","name":"reminders_list","arguments":"{}"}],"usage":{"input_tokens":2890,"input_tokens_details":{"cached_tokens":0},"output_tokens":48,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":2938}}}"#,
    ]

    /// Haiku 4.5 runs into `max_output_tokens` mid-sentence.
    static let incompleteMaxTokens: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_06long","object":"response","created_at":1791849900,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-haiku-4-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg_06long","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_06long","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]}}"#,
        #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_06long","output_index":0,"content_index":0,"delta":"Here is the full history, starting in 1984 when","logprobs":[]}"#,
        #"{"type":"response.incomplete","sequence_number":4,"response":{"id":"resp_06long","object":"response","created_at":1791849900,"status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"model":"anthropic/claude-haiku-4-5","output":[{"id":"msg_06long","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"Here is the full history, starting in 1984 when","annotations":[],"logprobs":[]}]}],"usage":{"input_tokens":410,"input_tokens_details":{"cached_tokens":0},"output_tokens":32000,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":32410}}}"#,
    ]

    /// Opus 5 declines: the message holds only a `refusal` part.
    static let refusal: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_07no","object":"response","created_at":1791849960,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[],"usage":null}}"#,
        #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg_07no","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_07no","output_index":0,"content_index":0,"part":{"type":"refusal","refusal":""}}"#,
        #"{"type":"response.refusal.delta","sequence_number":3,"item_id":"msg_07no","output_index":0,"content_index":0,"delta":"I can't help with that."}"#,
        #"{"type":"response.refusal.done","sequence_number":4,"item_id":"msg_07no","output_index":0,"content_index":0,"refusal":"I can't help with that."}"#,
        #"{"type":"response.content_part.done","sequence_number":5,"item_id":"msg_07no","output_index":0,"content_index":0,"part":{"type":"refusal","refusal":"I can't help with that."}}"#,
        #"{"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"id":"msg_07no","type":"message","status":"completed","role":"assistant","content":[{"type":"refusal","refusal":"I can't help with that."}]}}"#,
        #"{"type":"response.completed","sequence_number":7,"response":{"id":"resp_07no","object":"response","created_at":1791849960,"status":"completed","error":null,"incomplete_details":null,"model":"anthropic/claude-opus-5","output":[{"id":"msg_07no","type":"message","status":"completed","role":"assistant","content":[{"type":"refusal","refusal":"I can't help with that."}]}],"usage":{"input_tokens":650,"input_tokens_details":{"cached_tokens":0},"output_tokens":9,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":659}}}"#,
    ]

    /// The request is longer than the model's context window; the gateway accepts it, then fails the response.
    static let failedOverflow: [String] = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_08long","object":"response","created_at":1791850020,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-sonnet-5","output":[],"usage":null}}"#,
        #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_08long","object":"response","created_at":1791850020,"status":"in_progress","error":null,"incomplete_details":null,"model":"anthropic/claude-sonnet-5","output":[],"usage":null}}"#,
        #"{"type":"response.failed","sequence_number":2,"response":{"id":"resp_08long","object":"response","created_at":1791850020,"status":"failed","error":{"code":"context_length_exceeded","message":"This model's maximum context length is 200000 tokens. However, your messages resulted in 214318 tokens."},"incomplete_details":null,"model":"anthropic/claude-sonnet-5","output":[],"usage":null}}"#,
    ]

    /// The member's credits ran out: the stream's only event is an `error`.
    static let failedCredits: [String] = [
        #"{"type":"error","sequence_number":0,"code":"insufficient_credits","message":"Not enough Setapp AI credits to complete this request.","param":null}"#,
    ]

    /// Every scenario by name, for checks that run all of them.
    static let all: [(name: String, events: [String])] = [
        ("text", text),
        ("reasoningThenText", reasoningThenText),
        ("webSearch", webSearch),
        ("functionCall", functionCall),
        ("functionCallCompletedOnly", functionCallCompletedOnly),
        ("parallelFunctionCalls", parallelFunctionCalls),
        ("incompleteMaxTokens", incompleteMaxTokens),
        ("refusal", refusal),
        ("failedOverflow", failedOverflow),
        ("failedCredits", failedCredits),
    ]
}

#endif
