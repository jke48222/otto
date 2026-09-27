//
//  ToolSchema.swift
//  Otto
//
//  Turns a tool's full validation schema into the schema sent on the wire. Strict mode accepts only a
//  small JSON Schema subset, so the keywords it rejects are stripped (local validation still enforces
//  them), and `isStrictSafe` checks the result against the rules strict mode needs.
//

import Foundation

enum ToolSchema {
    /// Keywords the API's strict mode does not support; stripped from the wire schema when strict.
    static let strictUnsupportedKeywords: Set<String> =
        ["pattern", "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
         "multipleOf", "minItems", "maxItems", "uniqueItems", "format"]

    /// strict → deep copy without the unsupported keywords (descriptions keep the human-readable format).
    /// Property names are never touched: a property called "format" survives, only the keyword goes.
    static func wireSchema(_ schema: JSONValue, strict: Bool) -> JSONValue {
        guard strict else { return schema }
        return strippingUnsupported(schema)
    }

    /// Every object has "additionalProperties": false and a "required" array whose keys all exist in
    /// "properties"; only type/properties/required/additionalProperties/enum/const/items/description/title.
    static func isStrictSafe(_ wireSchema: JSONValue) -> Bool {
        guard isObjectSchema(wireSchema) else { return false }
        return isStrictSafeNode(wireSchema)
    }

    static let namePattern = "^[a-zA-Z0-9_-]{1,64}$"
    static let reservedNames: Set<String> = ["web_search", "web_fetch", "code_execution"]

    /// A name a client tool may register under: matches `namePattern` and is not one of `reservedNames`.
    static func isValidToolName(_ name: String) -> Bool {
        guard !reservedNames.contains(name) else { return false }
        return name.range(of: namePattern, options: .regularExpression) != nil
    }

    // MARK: - Private

    private static let strictAllowedKeywords: Set<String> =
        ["type", "properties", "required", "additionalProperties", "enum", "const", "items", "description", "title"]

    /// Keywords whose value is a single subschema.
    private static let subschemaKeywords: Set<String> = ["items", "additionalProperties", "not", "contains"]
    /// Keywords whose value is an array of subschemas.
    private static let subschemaListKeywords: Set<String> = ["anyOf", "allOf", "oneOf", "prefixItems"]
    /// Keywords whose value maps names to subschemas.
    private static let subschemaMapKeywords: Set<String> = ["properties", "$defs", "definitions", "patternProperties"]

    private static func strippingUnsupported(_ schema: JSONValue) -> JSONValue {
        guard case .object(let object) = schema else { return schema }
        var result: [String: JSONValue] = [:]
        for (key, value) in object where !strictUnsupportedKeywords.contains(key) {
            if subschemaKeywords.contains(key) {
                result[key] = strippingUnsupported(value)
            } else if subschemaListKeywords.contains(key), case .array(let list) = value {
                result[key] = .array(list.map(strippingUnsupported))
            } else if subschemaMapKeywords.contains(key), case .object(let map) = value {
                result[key] = .object(map.mapValues(strippingUnsupported))
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }

    private static func isObjectSchema(_ schema: JSONValue) -> Bool {
        guard let object = schema.objectValue else { return false }
        if object["properties"] != nil { return true }
        switch object["type"] {
        case .string(let type)?:
            return type == "object"
        case .array(let types)?:
            return types.contains(.string("object"))
        default:
            return false
        }
    }

    private static func isStrictSafeNode(_ schema: JSONValue) -> Bool {
        guard let object = schema.objectValue else { return false }
        guard object.keys.allSatisfy(strictAllowedKeywords.contains) else { return false }

        if let description = object["description"], description.stringValue == nil { return false }
        if let title = object["title"], title.stringValue == nil { return false }

        if isObjectSchema(schema) {
            guard object["additionalProperties"] == .bool(false) else { return false }
            let properties = object["properties"]?.objectValue ?? [:]
            if object["properties"] != nil, object["properties"]?.objectValue == nil { return false }
            guard let required = object["required"]?.arrayValue else { return false }
            for key in required {
                guard let name = key.stringValue, properties[name] != nil else { return false }
            }
            guard properties.values.allSatisfy(isStrictSafeNode) else { return false }
        } else if object["additionalProperties"] != nil || object["required"] != nil {
            return false
        }

        if let items = object["items"] {
            guard isStrictSafeNode(items) else { return false }
        }
        return true
    }
}
