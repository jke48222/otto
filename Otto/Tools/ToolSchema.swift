//
//  ToolSchema.swift
//  Otto
//
//  Turns a tool's full validation schema into the schema sent on the wire. Strict mode accepts only a
//  small JSON Schema subset, so the keywords it rejects are stripped (local validation still enforces
//  them), and every property is listed as required, an optional one as nullable: with optional keys
//  left out of "required", Claude never sends them in strict mode and repeats the call instead.
//  `isStrictSafe` checks the result against the rules strict mode needs, and
//  `removingNullOptionals` turns the nulls Claude sends for unused optional keys back into absent keys.
//

import Foundation

enum ToolSchema {
    /// Keywords the API's strict mode does not support; stripped from the wire schema when strict.
    static let strictUnsupportedKeywords: Set<String> =
        ["pattern", "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
         "multipleOf", "minItems", "maxItems", "uniqueItems", "format"]

    /// strict → deep copy without the unsupported keywords (descriptions keep the human-readable format), in
    /// which every object lists all its properties in "required": the originally required ones first, in their
    /// order, then the optional ones by name, each made nullable (`"type": [T, "null"]`, or, for an `enum`, no
    /// `type` and `null` added to the enum; a `const` becomes `enum: [value, null]`). Property names are never
    /// touched: a property called "format" survives, only the keyword goes.
    static func wireSchema(_ schema: JSONValue, strict: Bool) -> JSONValue {
        guard strict else { return schema }
        return requiringEveryProperty(strippingUnsupported(schema))
    }

    /// Every object has "additionalProperties": false and a "required" array that lists exactly the keys of
    /// "properties"; only type/properties/required/additionalProperties/enum/const/items/description/title.
    static func isStrictSafe(_ wireSchema: JSONValue) -> Bool {
        guard isObjectSchema(wireSchema) else { return false }
        return isStrictSafeNode(wireSchema)
    }

    /// `input` without the `null` values of properties `schema` does not require, at every depth (objects in
    /// properties and in array items), so a tool sees an unused optional key as absent. A `null` for a required
    /// key is kept, and fails validation. Anything that isn't an object with properties is returned unchanged.
    static func removingNullOptionals(_ input: JSONValue, schema: JSONValue) -> JSONValue {
        switch input {
        case .object(var object):
            guard let properties = schema["properties"]?.objectValue else { return input }
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for (key, value) in object {
                guard let propertySchema = properties[key] else { continue }
                if value == .null {
                    if !required.contains(key) { object.removeValue(forKey: key) }
                } else {
                    object[key] = removingNullOptionals(value, schema: propertySchema)
                }
            }
            return .object(object)
        case .array(let items):
            guard let itemSchema = schema["items"] else { return input }
            return .array(items.map { removingNullOptionals($0, schema: itemSchema) })
        default:
            return input
        }
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

    /// Lists every property of every object as required, making the optional ones nullable (see `wireSchema`).
    private static func requiringEveryProperty(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else { return schema }
        if case .object(let properties)? = object["properties"] {
            let listed = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let required = Set(listed)
            var updated: [String: JSONValue] = [:]
            for (name, property) in properties {
                let inner = requiringEveryProperty(property)
                updated[name] = required.contains(name) ? inner : nullable(inner)
            }
            object["properties"] = .object(updated)
            let optional = properties.keys.filter { !required.contains($0) }.sorted()
            let kept = listed.filter { properties[$0] != nil }
            object["required"] = .array((kept + optional).map(JSONValue.string))
        }
        if let items = object["items"] {
            object["items"] = requiringEveryProperty(items)
        }
        return .object(object)
    }

    /// The property schema that also accepts `null`. A property with an `enum` (or a `const`, which becomes one)
    /// loses its `type` and takes `null` as one more enum value: the API rejects an enum whose values don't all
    /// match a declared type array, so `{"type": ["string", "null"], "enum": ["a", null]}` fails with HTTP 400.
    private static func nullable(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else { return schema }
        if let constant = object.removeValue(forKey: "const") {
            object.removeValue(forKey: "type")
            object["enum"] = constant == .null ? [.null] : [constant, .null]
            return .object(object)
        }
        if case .array(let values)? = object["enum"] {
            object.removeValue(forKey: "type")
            if !values.contains(.null) { object["enum"] = .array(values + [.null]) }
            return .object(object)
        }
        switch object["type"] {
        case .string(let type)? where type != "null":
            object["type"] = [.string(type), "null"]
        case .array(let types)? where !types.contains("null"):
            object["type"] = .array(types + ["null"])
        default:
            break
        }
        return .object(object)
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
        // An enum next to a type array (the nullable shape) is rejected by the API unless every value matches
        // every declared type, which never holds once `null` is one of the values.
        if object["enum"] != nil || object["const"] != nil, case .array? = object["type"] { return false }
        if let title = object["title"], title.stringValue == nil { return false }

        if isObjectSchema(schema) {
            guard object["additionalProperties"] == .bool(false) else { return false }
            let properties = object["properties"]?.objectValue ?? [:]
            if object["properties"] != nil, object["properties"]?.objectValue == nil { return false }
            guard let required = object["required"]?.arrayValue else { return false }
            let names = required.compactMap(\.stringValue)
            // Strict mode only reliably fills keys that are required: optional ones must be nullable instead.
            guard names.count == required.count, names.count == Set(names).count,
                  Set(names) == Set(properties.keys) else { return false }
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
