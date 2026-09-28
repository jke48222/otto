//
//  PolarAPI.swift
//  Otto
//
//  Polar's customer-portal license endpoints (§14.6): the request builder with the exact headers and sorted JSON
//  bodies, the pure classification of an answer (only a versioned 404 ResourceNotFound is definitive), and a
//  tolerant decoder that reads only the listed fields. No I/O; PolarLicenseBackend sends and interprets.
//

#if OTTO_LICENSING
import Foundation

enum PolarAPI {
    enum Operation: String, CaseIterable, Sendable {
        case activate, validate, deactivate
    }

    /// One answer, classified by `classify(status:headers:body:)`.
    enum Answer: Equatable, Sendable {
        /// 200 or 204; the body is decoded by the caller.
        case success(Data)
        /// A 404 that echoes `polar-version` and carries `"error":"ResourceNotFound"`: the key, activation or
        /// benefit really isn't there.
        case notFound
        /// Any other 404 (a refused API version or a routing layer): retry once without `Polar-Version`.
        case unversionedNotFound
        /// 403 with `"error":"NotPermitted"` (activate only).
        case notPermitted
        /// 422: Polar rejected the request's shape.
        case requestRejected
        /// 429, 5xx and every other status.
        case unavailable(LicenseUnavailableReason)
    }

    /// The fields read from a 200 answer to `activate`. Everything else, including `customer`, is never decoded.
    struct Activation: Equatable, Sendable {
        let activationID: String
        let licenseKeyID: String?
        let benefitID: String
        let status: String
        let displayKey: String?
        let limitActivations: Int?
    }

    /// The fields read from a 200 answer to `validate`.
    struct Validation: Equatable, Sendable {
        let licenseKeyID: String?
        let benefitID: String
        let status: String
        let displayKey: String?
        let limitActivations: Int?
        let activationID: String?
    }

    static let grantedStatus = "granted"

    // MARK: - Requests

    /// `POST https://<host>/v1/customer-portal/license-keys/<operation>` with the headers of §14.6 and `fields` as a
    /// JSON object with sorted keys. `pinned: false` leaves out `Polar-Version` (the single retry after a bare 404).
    static func request(_ operation: Operation, host: String, fields: [String: String], userAgent: String,
                        pinned: Bool = true) -> LicenseHTTPRequest? {
        guard let url = endpoint(operation, host: host), let body = jsonBody(fields) else { return nil }
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Accept-Language": "en",
            "User-Agent": userAgent,
        ]
        if pinned { headers["Polar-Version"] = PolarConfiguration.apiVersion }
        return LicenseHTTPRequest(url: url, method: "POST", headers: headers, body: body)
    }

    /// `{"key", "label", "organization_id"}`: no conditions, no meta.
    static func activateFields(key: String, label: String, organizationID: String) -> [String: String] {
        ["key": key, "label": label, "organization_id": organizationID]
    }

    /// `{"activation_id", "benefit_id", "key", "organization_id"}`, or without `activation_id` right after an
    /// activate 403. No increment_usage, conditions or customer_id.
    static func validateFields(key: String, activationID: String?, organizationID: String,
                               benefitID: String) -> [String: String] {
        var fields = ["key": key, "organization_id": organizationID, "benefit_id": benefitID]
        if let activationID { fields["activation_id"] = activationID }
        return fields
    }

    /// `{"activation_id", "key", "organization_id"}`.
    static func deactivateFields(key: String, activationID: String, organizationID: String) -> [String: String] {
        ["activation_id": activationID, "key": key, "organization_id": organizationID]
    }

    static func endpoint(_ operation: Operation, host: String) -> URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v1/customer-portal/license-keys/\(operation.rawValue)"
        return components.url
    }

    private static func jsonBody(_ fields: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(fields)
    }

    // MARK: - Classification

    static func classify(status: Int, headers: [String: String], body: Data) -> Answer {
        switch status {
        case 200, 204:
            return .success(body)
        case 404:
            let echoesVersion = !(header("polar-version", in: headers) ?? "").isEmpty
            return echoesVersion && errorCode(in: body) == "ResourceNotFound" ? .notFound : .unversionedNotFound
        case 403 where errorCode(in: body) == "NotPermitted":
            return .notPermitted
        case 422:
            return .requestRejected
        case 429:
            return .unavailable(.rateLimited(retryAfter: LicenseBackends.retryAfter(in: headers)))
        case 500...599:
            return .unavailable(.server(status: status))
        default:
            return .unavailable(.unexpectedResponse(status: status))
        }
    }

    /// Whether the answer echoed `polar-version` (logged as a public fact next to the status).
    static func echoedVersion(_ headers: [String: String]) -> Bool {
        !(header("polar-version", in: headers) ?? "").isEmpty
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        if let value = headers[name] { return value }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func errorCode(in body: Data) -> String? {
        struct ErrorBody: Decodable { let error: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
    }

    // MARK: - Decoding (only the listed fields)

    /// nil when a required field is missing or has the wrong type (the caller reports unexpectedResponse(200)).
    static func decodeActivation(_ body: Data) -> Activation? {
        guard let wire = try? JSONDecoder().decode(ActivationWire.self, from: body),
              let id = wire.id, let licenseKey = wire.licenseKey,
              let benefitID = licenseKey.benefitID, let status = licenseKey.status else { return nil }
        return Activation(activationID: id, licenseKeyID: wire.licenseKeyID, benefitID: benefitID, status: status,
                          displayKey: licenseKey.displayKey, limitActivations: licenseKey.limitActivations)
    }

    static func decodeValidation(_ body: Data) -> Validation? {
        guard let wire = try? JSONDecoder().decode(ValidationWire.self, from: body),
              let benefitID = wire.benefitID, let status = wire.status else { return nil }
        return Validation(licenseKeyID: wire.id, benefitID: benefitID, status: status, displayKey: wire.displayKey,
                          limitActivations: wire.limitActivations, activationID: wire.activation?.id)
    }

    // Wire shapes: exactly the fields §14.6 lists, all optional so an extra or missing field elsewhere never fails
    // the decode. Nothing personal (customer, customer_id, meta, usage, validations) is declared, so none of it is
    // ever read.
    private struct KeyWire: Decodable {
        let benefitID: String?
        let status: String?
        let displayKey: String?
        let limitActivations: Int?

        enum CodingKeys: String, CodingKey {
            case benefitID = "benefit_id", status, displayKey = "display_key", limitActivations = "limit_activations"
        }
    }

    private struct ActivationWire: Decodable {
        let id: String?
        let licenseKeyID: String?
        let licenseKey: KeyWire?

        enum CodingKeys: String, CodingKey {
            case id, licenseKeyID = "license_key_id", licenseKey = "license_key"
        }
    }

    private struct ValidationWire: Decodable {
        struct ActivationReference: Decodable { let id: String? }

        let id: String?
        let benefitID: String?
        let status: String?
        let displayKey: String?
        let limitActivations: Int?
        let activation: ActivationReference?

        enum CodingKeys: String, CodingKey {
            case id, benefitID = "benefit_id", status, displayKey = "display_key",
                 limitActivations = "limit_activations", activation
        }
    }
}
#endif
