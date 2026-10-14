//
//  ResponsesRequestBuilder.swift
//  Otto
//
//  Builds the OpenAI Responses request Setapp's AI Gateway takes from a `MessagesRequest` (SPEC §19, "Setapp AI").
//  Otto stores every conversation as Anthropic Messages blocks; this file is the one place they become Responses
//  input items. Blocks only Anthropic can take back (signed thinking, server-tool pairs, fallbacks) are left out,
//  and so are the blocks Otto synthesized from earlier gateway web searches.
//

import Foundation

enum ResponsesRequestBuilder {
    /// Introduces the images of a round's tool results, which travel in the user message after the outputs.
    static let toolResultImagesIntro = "Images from the tool results above:"
    /// A `function_call_output` whose tool returned no text.
    static let emptyToolOutput = "(no output)"
    /// A `function_call_output` whose tool returned only images, which follow in the next user message.
    static let imageOnlyToolOutput = "(images below)"
    /// Marks a failed tool's output: Responses has no `is_error` flag.
    static let toolErrorPrefix = "Error: "
    /// The filename of a PDF that has no title.
    static let untitledDocumentName = "document"

    /// The gateway request for `request`. Pure; unit tested.
    ///
    /// Keys are only present when they carry something, so the gateway (and the SDK's Codable types the body is
    /// decoded into) never sees an empty `tools` or `include` list.
    static func body(for request: MessagesRequest, options: ResponsesRequestOptions) -> JSONValue {
        let model = request.model
        var body: [String: JSONValue] = [
            "model": .string(model.setappAIModelID),
            "input": .array(inputItems(from: request.messages,
                                       replaysReasoning: options.includeReasoning && model.supportsAdaptiveThinking)),
            "max_output_tokens": .int(Int64(request.maxTokens)),
            "stream": true,
            // The gateway keeps nothing between requests; each one carries the whole conversation.
            "store": false,
        ]
        if !request.system.isEmpty {
            body["instructions"] = .string(request.system)
        }

        var include: [JSONValue] = []
        if options.includeReasoning && model.supportsAdaptiveThinking {
            body["reasoning"] = ["effort": .string(request.effort.rawValue), "summary": "auto"]
            // With `store: false` the encrypted reasoning is the only way the next request of a tool round can
            // hand the model its own chain back (as an `otto_responses_reasoning` block).
            include.append("reasoning.encrypted_content")
        }

        // The gateway's built-in search first, then the client tools in the order ToolRegistry sorted them, so the
        // tool list is stable for a given model and settings. Web fetch has no gateway equivalent.
        var tools: [JSONValue] = []
        let webSearchLimit = request.serverToolLimits.webSearch
        if request.webAccess && webSearchLimit > 0 && model.supportsSetappAIWebSearch {
            let contextSize = searchContextSize(limit: webSearchLimit)
            tools.append(["type": "web_search", "search_context_size": .string(contextSize)])
            include.append("web_search_call.action.sources")
            // Caps every built-in tool call in the response, which here means only searches. A gateway that
            // ignores it (LiteLLM does) caps Anthropic's searches by `search_context_size` instead.
            body["max_tool_calls"] = .int(Int64(webSearchLimit))
        }
        tools += request.clientTools.compactMap { functionTool(from: $0, options: options) }
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            // Otto only ever sends {"type": "none"} (the wrap-up request after the action limit).
            if request.toolChoice?["type"]?.stringValue == "none" {
                body["tool_choice"] = "none"
            }
        }
        if !include.isEmpty {
            body["include"] = .array(include)
        }
        return .object(body)
    }

    // MARK: - Tools

    /// The `search_context_size` whose search count stays within `limit`. LiteLLM, which the gateway most likely
    /// runs, ignores `max_tool_calls` and turns this into Anthropic's `max_uses`: "low" 1, "medium" 5, "high" 10.
    static func searchContextSize(limit: Int) -> String {
        limit >= 5 ? "medium" : "low"
    }

    /// `{"type": "function", "name", "description", "parameters", "strict"}` from a ToolRegistry definition, or nil
    /// for a definition without a name. `strict` is always sent: the Responses API treats a missing one as true,
    /// which would hold a non-strict schema to rules it wasn't written for, and the SDK's function tool type
    /// requires the field. `eager_input_streaming` is Anthropic's and has no Responses equivalent.
    private static func functionTool(from definition: JSONValue, options: ResponsesRequestOptions) -> JSONValue? {
        guard let name = definition["name"]?.stringValue, !name.isEmpty else { return nil }
        var tool: [String: JSONValue] = [
            "type": "function",
            "name": .string(name),
            "parameters": definition["input_schema"] ?? ["type": "object", "properties": .object([:])],
            "strict": .bool(options.strictTools && definition["strict"]?.boolValue == true),
        ]
        if let description = definition["description"]?.stringValue {
            tool["description"] = .string(description)
        }
        return .object(tool)
    }

    // MARK: - Input items

    /// `replaysReasoning` is true only when the request itself asks for reasoning: a stored reasoning item sent to a
    /// model running without it (Haiku, or the compatibility retry) would be out of place.
    private static func inputItems(from messages: [JSONValue], replaysReasoning: Bool) -> [JSONValue] {
        messages.flatMap { message -> [JSONValue] in
            switch message["role"]?.stringValue {
            case "user": return userItems(contentBlocks(of: message))
            case "assistant": return assistantItems(contentBlocks(of: message), replaysReasoning: replaysReasoning)
            default: return []
            }
        }
    }

    /// A message's content blocks; the Messages API also takes a bare string as one text block.
    private static func contentBlocks(of message: JSONValue) -> [JSONValue] {
        if let text = message["content"]?.stringValue {
            return [["type": "text", "text": .string(text)]]
        }
        return message["content"]?.arrayValue ?? []
    }

    /// One user turn: a `function_call_output` per `tool_result`, in order, then a single user message with
    /// everything else.
    ///
    /// The outputs come first because the gateway hands the conversation on to Anthropic, which takes a round's
    /// tool results only straight after its tool calls and ahead of any other user content. The outputs carry text,
    /// so the results' images move into that user message, ahead of the user's own content, with a line that says
    /// where they came from.
    private static func userItems(_ blocks: [JSONValue]) -> [JSONValue] {
        var outputs: [JSONValue] = []
        var resultImages: [JSONValue] = []
        var parts: [JSONValue] = []
        for block in blocks {
            if block.typeName == "tool_result" {
                guard let callID = block["tool_use_id"]?.stringValue, !callID.isEmpty else { continue }
                let result = toolResultContent(block)
                outputs.append([
                    "type": "function_call_output",
                    "call_id": .string(callID),
                    "output": .string(outputText(result.texts, hasImages: !result.images.isEmpty,
                                                 isError: block["is_error"]?.boolValue == true)),
                ])
                resultImages += result.images
            } else if let part = userPart(block) {
                parts.append(part)
            }
        }
        if !resultImages.isEmpty {
            parts = [inputText(toolResultImagesIntro)] + resultImages + parts
        }
        guard !parts.isEmpty else { return outputs }
        return outputs + [["type": "message", "role": "user", "content": .array(parts)]]
    }

    /// The non-blank text parts and the images of a `tool_result` (whose `content` may also be a bare string).
    private static func toolResultContent(_ block: JSONValue) -> (texts: [String], images: [JSONValue]) {
        if let text = block["content"]?.stringValue {
            return (isBlank(text) ? [] : [text], [])
        }
        var texts: [String] = []
        var images: [JSONValue] = []
        for part in block["content"]?.arrayValue ?? [] {
            switch part.typeName {
            case "text":
                if let text = part["text"]?.stringValue, !isBlank(text) { texts.append(text) }
            case "image":
                if let image = imagePart(part) { images.append(image) }
            default:
                continue
            }
        }
        return (texts, images)
    }

    /// The text a `function_call_output` carries. An empty one would read as nothing happened, and a failure needs
    /// saying in words because Responses has no `is_error`.
    private static func outputText(_ texts: [String], hasImages: Bool, isError: Bool) -> String {
        var output = texts.joined(separator: "\n\n")
        if output.isEmpty {
            output = hasImages ? imageOnlyToolOutput : emptyToolOutput
        }
        if isError && !output.hasPrefix(toolErrorPrefix) {
            output = toolErrorPrefix + output
        }
        return output
    }

    /// The Responses content part for one user block, or nil for a block the gateway can't take.
    private static func userPart(_ block: JSONValue) -> JSONValue? {
        switch block.typeName {
        case "text":
            guard let text = block["text"]?.stringValue, !isBlank(text) else { return nil }
            return inputText(text)
        case "image":
            return imagePart(block)
        case "document":
            return documentPart(block)
        default:
            return nil
        }
    }

    /// `input_image` from an Anthropic image block with a base64 or URL source.
    private static func imagePart(_ block: JSONValue) -> JSONValue? {
        let source = block["source"]
        let imageURL: String
        switch source?["type"]?.stringValue {
        case "base64":
            guard let mediaType = source?["media_type"]?.stringValue, !mediaType.isEmpty,
                  let data = source?["data"]?.stringValue, !data.isEmpty else { return nil }
            imageURL = "data:\(mediaType);base64,\(data)"
        case "url":
            guard let url = source?["url"]?.stringValue, !url.isEmpty else { return nil }
            imageURL = url
        default:
            return nil
        }
        return ["type": "input_image", "image_url": .string(imageURL), "detail": "auto"]
    }

    /// A base64 PDF becomes an `input_file`; a text document becomes `input_text` wrapped in `<document>`, because
    /// Responses has no plain-text document part and the title would otherwise be lost.
    private static func documentPart(_ block: JSONValue) -> JSONValue? {
        let source = block["source"]
        let title = documentTitle(of: block)
        switch source?["type"]?.stringValue {
        case "base64":
            guard source?["media_type"]?.stringValue == "application/pdf",
                  let data = source?["data"]?.stringValue, !data.isEmpty else { return nil }
            return [
                "type": "input_file",
                "filename": .string(pdfFilename(title: title)),
                "file_data": .string("data:application/pdf;base64,\(data)"),
            ]
        case "text":
            guard let data = source?["data"]?.stringValue else { return nil }
            // The title is escaped the way ToolHistory fences an earlier action result, so it stays one attribute.
            let opening = title.map { "<document title=\"\(ToolHistory.escaped($0))\">" } ?? "<document>"
            return inputText("\(opening)\n\(neutralizingDocumentTags(data))\n</document>")
        default:
            return nil
        }
    }

    /// Every `<document` and `</document` in a file's text, in any case and with any spacing ("</Document >",
    /// "< /document\n>"), as `&lt;…`, so the file can neither close the wrapper early nor open a fake one with a
    /// title of its own.
    static func neutralizingDocumentTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return documentTag.stringByReplacingMatches(in: text, range: range, withTemplate: "&lt;$1")
    }

    private static let documentTag = try! NSRegularExpression(pattern: #"<(\s*/?\s*document)"#,
                                                              options: [.caseInsensitive])

    /// The trimmed title of a document block, nil when it has none.
    private static func documentTitle(of block: JSONValue) -> String? {
        guard let title = block["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// "<title>.pdf", or "document.pdf" without a title. A title that already ends in .pdf (any case) keeps its
    /// single extension, and `/` and `:` become `-` because they are path separators to whatever stores the file.
    private static func pdfFilename(title: String?) -> String {
        let name = (title ?? untitledDocumentName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    /// One assistant turn, block by block.
    ///
    /// Consecutive text blocks (Anthropic splits text around citations) share one assistant message, and each
    /// `function_call` or replayed reasoning item ends the message before it, so the items keep the model's order.
    /// Blocks that are left out don't split a message.
    private static func assistantItems(_ blocks: [JSONValue], replaysReasoning: Bool) -> [JSONValue] {
        var items: [JSONValue] = []
        var texts: [JSONValue] = []

        func closeMessage() {
            guard !texts.isEmpty else { return }
            items.append(["type": "message", "role": "assistant", "content": .array(texts)])
            texts = []
        }

        for block in blocks {
            // Synthesized from an earlier gateway web search: the gateway has no item to take it back as.
            guard block[ProviderBlocks.providerField] == nil else { continue }
            switch block.typeName {
            case "text":
                guard let text = block["text"]?.stringValue, !isBlank(text) else { continue }
                texts.append(["type": "output_text", "text": .string(text)])
            case "tool_use":
                guard let call = functionCall(from: block) else { continue }
                closeMessage()
                items.append(call)
            case ProviderBlocks.responsesReasoningType:
                // Dropped whenever the request sends no `reasoning` (Haiku, or the compatibility retry).
                guard replaysReasoning, let item = block["item"], item.objectValue != nil else { continue }
                closeMessage()
                items.append(item)
            default:
                // thinking and redacted_thinking (Anthropic signatures), server_tool_use and every *_tool_result,
                // fallback, code_execution*: Anthropic-only, and the gateway would reject or misread them.
                continue
            }
        }
        closeMessage()
        return items
    }

    /// `function_call` from a client `tool_use` block, or nil without an id or a name. `arguments` is the input as
    /// JSON text with sorted keys; "{}" when the input is missing or not an object.
    private static func functionCall(from block: JSONValue) -> JSONValue? {
        guard let id = block["id"]?.stringValue, !id.isEmpty,
              let name = block["name"]?.stringValue, !name.isEmpty else { return nil }
        var arguments = "{}"
        if let input = block["input"], input.objectValue != nil {
            arguments = input.encodedString()
        }
        return [
            "type": "function_call",
            "call_id": .string(id),
            "name": .string(name),
            "arguments": .string(arguments),
        ]
    }

    // MARK: - Helpers

    private static func inputText(_ text: String) -> JSONValue {
        ["type": "input_text", "text": .string(text)]
    }

    /// Text with nothing but whitespace counts as empty: the gateway hands it to Anthropic, which rejects
    /// whitespace-only text blocks.
    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
