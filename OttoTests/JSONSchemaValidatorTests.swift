//
//  JSONSchemaValidatorTests.swift
//  OttoTests
//
//  The input validator's keyword subset: types (integer vs number), required, additionalProperties,
//  enum, const, bounds, lengths, pattern, formats, nested items, path messages and the unsupported
//  keyword report.
//

import XCTest
@testable import Otto

final class JSONSchemaValidatorTests: XCTestCase {
    private let eventSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "minLength": 1, "maxLength": 10, "description": "Title"],
            "start": ["type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"],
            "count": ["type": "integer", "minimum": 1, "maximum": 5],
            "ratio": ["type": "number", "minimum": 0.5],
            "kind": ["type": "string", "enum": ["meeting", "call"]],
            "version": ["const": 2],
            "notes": ["type": ["string", "null"]],
            "tags": ["type": "array", "minItems": 1, "maxItems": 2, "items": ["type": "string", "maxLength": 3]],
            "window": [
                "type": "object",
                "properties": ["minutes": ["type": "integer"]],
                "required": ["minutes"],
                "additionalProperties": false,
            ],
        ],
        "required": ["title"],
        "additionalProperties": false,
    ]

    private func validate(_ value: JSONValue) -> String? {
        JSONSchemaValidator.validate(value, against: eventSchema)
    }

    func testValidInputPasses() {
        XCTAssertNil(validate([
            "title": "Dentist", "start": "2026-09-29", "count": 3, "ratio": 0.75, "kind": "call", "version": 2,
            "notes": .null, "tags": ["a", "bc"], "window": ["minutes": 30],
        ]))
    }

    func testTypeMismatchNamesThePath() {
        XCTAssertEqual(validate(["title": 5]), "$.title: expected string, got integer")
        XCTAssertEqual(JSONSchemaValidator.validate("text", against: eventSchema), "$: expected object, got string")
    }

    func testIntegerAcceptsWholeDoublesOnly() {
        XCTAssertNil(validate(["title": "a", "count": .double(3.0)]))
        XCTAssertEqual(validate(["title": "a", "count": .double(2.5)]), "$.count: expected integer, got number")
        XCTAssertNil(validate(["title": "a", "ratio": 1]), "an integer is a number")
    }

    func testTypeArrayAllowsEitherType() {
        XCTAssertNil(validate(["title": "a", "notes": "text"]))
        XCTAssertNil(validate(["title": "a", "notes": .null]))
        XCTAssertEqual(validate(["title": "a", "notes": true]), "$.notes: expected string or null, got boolean")
    }

    func testRequiredAndAdditionalProperties() {
        XCTAssertEqual(validate([:]), "$.title: is required")
        XCTAssertEqual(validate(["title": "a", "extra": 1]), "$.extra: is not allowed")
        XCTAssertEqual(validate(["title": "a", "window": [:]]), "$.window.minutes: is required")
        XCTAssertEqual(validate(["title": "a", "window": ["minutes": 1, "hours": 2]]), "$.window.hours: is not allowed")
    }

    func testEnumAndConst() {
        XCTAssertEqual(validate(["title": "a", "kind": "party"]), "$.kind: must be one of \"meeting\", \"call\"")
        XCTAssertNil(validate(["title": "a", "version": .double(2.0)]), "2.0 equals the const 2")
        XCTAssertEqual(validate(["title": "a", "version": 3]), "$.version: must be 2")
    }

    func testNumericBounds() {
        XCTAssertEqual(validate(["title": "a", "count": 0]), "$.count: must be at least 1")
        XCTAssertEqual(validate(["title": "a", "count": 6]), "$.count: must be at most 5")
        XCTAssertEqual(validate(["title": "a", "ratio": 0.25]), "$.ratio: must be at least 0.5")
    }

    func testLengthsCountCharacters() {
        XCTAssertEqual(validate(["title": ""]), "$.title: must be at least 1 character")
        XCTAssertEqual(validate(["title": "abcdefghijk"]), "$.title: must be at most 10 characters")
        // Ten characters, many more UTF-16 units and bytes.
        XCTAssertNil(validate(["title": "👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦"]))
    }

    func testPatternIsAnchoredAsWritten() {
        XCTAssertNil(validate(["title": "a", "start": "2026-09-29"]))
        XCTAssertEqual(validate(["title": "a", "start": "2026-09-29T10:00"]),
                       "$.start: must match ^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        let unanchored: JSONValue = ["type": "string", "pattern": "[0-9]+"]
        XCTAssertNil(JSONSchemaValidator.validate("abc123", against: unanchored), "no anchors: a match anywhere passes")
        XCTAssertNotNil(JSONSchemaValidator.validate("abc", against: unanchored))
    }

    func testInvalidPatternFailsClosed() {
        let broken: JSONValue = ["type": "string", "pattern": "([a-z"]
        XCTAssertEqual(JSONSchemaValidator.validate("abc", against: broken),
                       "$: can't be checked (the schema's pattern is invalid)")
    }

    func testArrayItemsAndCounts() {
        XCTAssertEqual(validate(["title": "a", "tags": []]), "$.tags: must have at least 1 item")
        XCTAssertEqual(validate(["title": "a", "tags": ["a", "b", "c"]]), "$.tags: must have at most 2 items")
        XCTAssertEqual(validate(["title": "a", "tags": ["a", "long"]]), "$.tags[1]: must be at most 3 characters")
        XCTAssertEqual(validate(["title": "a", "tags": ["a", 1]]), "$.tags[1]: expected string, got integer")
    }

    func testDateTimeFormatNeedsAnOffset() {
        let schema: JSONValue = ["type": "string", "format": "date-time"]
        XCTAssertNil(JSONSchemaValidator.validate("2026-09-29T15:00:00Z", against: schema))
        XCTAssertNil(JSONSchemaValidator.validate("2026-09-29T15:00:00-07:00", against: schema))
        XCTAssertNil(JSONSchemaValidator.validate("2026-09-29T15:00:00.250+02:00", against: schema))
        XCTAssertEqual(JSONSchemaValidator.validate("2026-09-29T15:00:00", against: schema),
                       "$: must be an ISO 8601 date and time with a UTC offset")
        XCTAssertNotNil(JSONSchemaValidator.validate("tomorrow", against: schema))
    }

    func testURIFormat() {
        let schema: JSONValue = ["type": "string", "format": "uri"]
        XCTAssertNil(JSONSchemaValidator.validate("https://example.com/a?b=c", against: schema))
        XCTAssertNotNil(JSONSchemaValidator.validate("example.com", against: schema))
        XCTAssertNotNil(JSONSchemaValidator.validate("https://exa mple.com", against: schema))
    }

    func testOddPropertyNamesUseBracketPaths() {
        let schema: JSONValue = [
            "type": "object", "properties": ["due date": ["type": "string"]], "additionalProperties": false,
        ]
        XCTAssertEqual(JSONSchemaValidator.validate(["due date": 1], against: schema),
                       "$[\"due date\"]: expected string, got integer")
    }

    func testProblemIsCappedAt200Characters() {
        let options = (0..<60).map { JSONValue.string("option-\($0)") }
        let schema: JSONValue = ["type": "string", "enum": .array(options)]
        let problem = JSONSchemaValidator.validate("nope", against: schema)
        XCTAssertEqual(problem?.count, 200)
        XCTAssertEqual(problem?.hasSuffix("…"), true)
        XCTAssertEqual(problem?.hasPrefix("$: must be one of"), true)
    }

    func testUnknownKeywordsAreIgnoredAtRuntime() {
        let schema: JSONValue = ["type": "string", "uniqueItems": true, "multipleOf": 3]
        XCTAssertNil(JSONSchemaValidator.validate("fine", against: schema))
    }

    func testUnsupportedKeywordsReport() {
        XCTAssertEqual(JSONSchemaValidator.unsupportedKeywords(in: eventSchema), [])
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "a": ["type": "string", "format": "email"],
                "b": ["anyOf": [["type": "string"]]],
                "c": ["type": "array", "items": ["type": "integer", "multipleOf": 2]],
                "d": ["type": "object", "additionalProperties": ["type": "string"]],
                "e": ["type": "date"],
            ],
            "$defs": [:],
        ]
        XCTAssertEqual(JSONSchemaValidator.unsupportedKeywords(in: schema),
                       ["$defs", "additionalProperties", "anyOf", "format=email", "multipleOf", "type"])
    }
}
