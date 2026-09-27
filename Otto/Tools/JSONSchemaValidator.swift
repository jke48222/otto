//
//  JSONSchemaValidator.swift
//  Otto
//
//  Validates tool inputs against the small JSON Schema subset Otto's tools use. Eager input streaming
//  means the API never validates a client tool's input, so the executor checks every input here
//  before a tool can describe, ask about or run it.
//

import Foundation

enum JSONSchemaValidator {
    /// nil when valid; else the first problem as "$.path: message" (≤ 200 chars).
    static func validate(_ value: JSONValue, against schema: JSONValue) -> String? {
        guard let problem = check(value, schema: schema, path: "$") else { return nil }
        let text = "\(problem.path): \(problem.message)"
        guard text.count > maxProblemLength else { return text }
        return String(text.prefix(maxProblemLength - 1)) + "…"
    }

    /// Keywords outside the supported subset, sorted (tests assert every registered tool returns []).
    /// An unsupported `format` value is reported as "format=<value>"; an object-valued
    /// `additionalProperties` as "additionalProperties".
    static func unsupportedKeywords(in schema: JSONValue) -> [String] {
        var found = Set<String>()
        collectUnsupported(in: schema, into: &found)
        return found.sorted()
    }

    // MARK: - Private

    private static let maxProblemLength = 200

    private static let supportedKeywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "enum", "const", "items", "minItems", "maxItems",
        "minLength", "maxLength", "minimum", "maximum", "pattern", "format", "description", "title",
    ]
    private static let supportedFormats: Set<String> = ["date-time", "uri"]
    private static let knownTypes: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]

    private struct Problem {
        let path: String
        let message: String
    }

    private static func check(_ value: JSONValue, schema: JSONValue, path: String) -> Problem? {
        guard let rules = schema.objectValue else { return nil }

        if let typeRule = rules["type"] {
            let allowed = typeNames(typeRule)
            if !allowed.isEmpty, !allowed.contains(where: { matches(value, type: $0) }) {
                return Problem(path: path, message: "expected \(allowed.joined(separator: " or ")), got \(typeName(of: value))")
            }
        }

        if let options = rules["enum"]?.arrayValue, !options.contains(where: { equal($0, value) }) {
            let listed = options.map(describe).joined(separator: ", ")
            return Problem(path: path, message: "must be one of \(listed)")
        }

        if let constant = rules["const"], !equal(constant, value) {
            return Problem(path: path, message: "must be \(describe(constant))")
        }

        switch value {
        case .string(let text):
            return checkString(text, rules: rules, path: path)
        case .int, .double:
            return checkNumber(value, rules: rules, path: path)
        case .array(let items):
            return checkArray(items, rules: rules, path: path)
        case .object(let object):
            return checkObject(object, rules: rules, path: path)
        case .null, .bool:
            return nil
        }
    }

    private static func checkString(_ text: String, rules: [String: JSONValue], path: String) -> Problem? {
        let length = text.count
        if let minimum = rules["minLength"]?.intValue, length < minimum {
            return Problem(path: path, message: "must be at least \(minimum) \(minimum == 1 ? "character" : "characters")")
        }
        if let maximum = rules["maxLength"]?.intValue, length > maximum {
            return Problem(path: path, message: "must be at most \(maximum) \(maximum == 1 ? "character" : "characters")")
        }
        if let pattern = rules["pattern"]?.stringValue {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return Problem(path: path, message: "can't be checked (the schema's pattern is invalid)")
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if expression.firstMatch(in: text, range: range) == nil {
                return Problem(path: path, message: "must match \(pattern)")
            }
        }
        if let format = rules["format"]?.stringValue {
            switch format {
            case "date-time":
                if !isDateTime(text) {
                    return Problem(path: path, message: "must be an ISO 8601 date and time with a UTC offset")
                }
            case "uri":
                if !isURI(text) {
                    return Problem(path: path, message: "must be an absolute URI")
                }
            default:
                break
            }
        }
        return nil
    }

    private static func checkNumber(_ value: JSONValue, rules: [String: JSONValue], path: String) -> Problem? {
        guard let number = value.doubleValue else { return nil }
        if let minimum = rules["minimum"], let bound = minimum.doubleValue, number < bound {
            return Problem(path: path, message: "must be at least \(describe(minimum))")
        }
        if let maximum = rules["maximum"], let bound = maximum.doubleValue, number > bound {
            return Problem(path: path, message: "must be at most \(describe(maximum))")
        }
        return nil
    }

    private static func checkArray(_ items: [JSONValue], rules: [String: JSONValue], path: String) -> Problem? {
        if let minimum = rules["minItems"]?.intValue, items.count < minimum {
            return Problem(path: path, message: "must have at least \(minimum) \(minimum == 1 ? "item" : "items")")
        }
        if let maximum = rules["maxItems"]?.intValue, items.count > maximum {
            return Problem(path: path, message: "must have at most \(maximum) \(maximum == 1 ? "item" : "items")")
        }
        if let itemSchema = rules["items"] {
            for (index, item) in items.enumerated() {
                if let problem = check(item, schema: itemSchema, path: "\(path)[\(index)]") { return problem }
            }
        }
        return nil
    }

    private static func checkObject(_ object: [String: JSONValue], rules: [String: JSONValue], path: String) -> Problem? {
        let properties = rules["properties"]?.objectValue ?? [:]
        for key in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            return Problem(path: childPath(path, key), message: "is required")
        }
        if rules["additionalProperties"] == .bool(false) {
            if let extra = object.keys.sorted().first(where: { properties[$0] == nil }) {
                return Problem(path: childPath(path, extra), message: "is not allowed")
            }
        }
        for key in object.keys.sorted() {
            guard let propertySchema = properties[key], let propertyValue = object[key] else { continue }
            if let problem = check(propertyValue, schema: propertySchema, path: childPath(path, key)) { return problem }
        }
        return nil
    }

    // MARK: Types

    private static func typeNames(_ rule: JSONValue) -> [String] {
        switch rule {
        case .string(let name):
            return [name]
        case .array(let names):
            return names.compactMap(\.stringValue)
        default:
            return []
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null):
            return true
        case ("number", .int), ("number", .double):
            return true
        case ("integer", .int):
            return true
        case ("integer", .double(let number)):
            return number.isFinite && number.rounded(.towardZero) == number
        default:
            // An unknown type name can't be satisfied: fail closed.
            return false
        }
    }

    private static func typeName(of value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// JSON equality where 3 and 3.0 are the same number.
    private static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.int, .double), (.double, .int), (.int, .int), (.double, .double):
            return lhs.doubleValue == rhs.doubleValue
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { equal($0, $1) }
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { key, value in right[key].map { equal(value, $0) } ?? false }
        default:
            return lhs == rhs
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return "\"\(text)\""
        case .int(let number): return String(number)
        case .double(let number):
            return number.rounded(.towardZero) == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default: return value.encodedString()
        }
    }

    private static func childPath(_ path: String, _ key: String) -> String {
        let isIdentifier = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        if isIdentifier { return "\(path).\(key)" }
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(path)[\"\(escaped)\"]"
    }

    // MARK: Formats

    private static func isDateTime(_ text: String) -> Bool {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if plain.date(from: text) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) != nil
    }

    private static func isURI(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), let components = URLComponents(string: text),
              let scheme = components.scheme, !scheme.isEmpty else { return false }
        return true
    }

    // MARK: Unsupported keywords

    private static func collectUnsupported(in schema: JSONValue, into found: inout Set<String>) {
        guard let rules = schema.objectValue else { return }
        for (keyword, value) in rules {
            guard supportedKeywords.contains(keyword) else {
                found.insert(keyword)
                continue
            }
            switch keyword {
            case "properties":
                for property in (value.objectValue ?? [:]).values {
                    collectUnsupported(in: property, into: &found)
                }
            case "items":
                collectUnsupported(in: value, into: &found)
            case "additionalProperties":
                if value.boolValue == nil { found.insert("additionalProperties") }
            case "format":
                if let format = value.stringValue, !supportedFormats.contains(format) {
                    found.insert("format=\(format)")
                }
            case "type":
                if typeNames(value).contains(where: { !knownTypes.contains($0) }) { found.insert("type") }
            default:
                break
            }
        }
    }
}
