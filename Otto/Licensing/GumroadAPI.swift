//
//  GumroadAPI.swift
//  Otto
//
//  Gumroad's license verify endpoint (§14.7): the form-encoded request with increment_uses_count always explicit
//  (Gumroad's default is true), the pure classification of an answer, and a decoder that reads the use count and
//  the purchase's refund, dispute and quantity fields only. Buyer details are never decoded.
//

#if OTTO_LICENSING
import Foundation

enum GumroadAPI {
    static let host = "api.gumroad.com"

    /// The fields read from a 200 `success: true` answer.
    struct Verification: Equatable, Sendable {
        let uses: Int
        let quantity: Int
        let refunded: Bool
        let chargebacked: Bool
        let disputed: Bool
        let disputeWon: Bool

        /// What the purchase flags say, before any record/configuration comparison.
        var goneReason: LicenseGoneReason? {
            if refunded { return .refunded }
            if chargebacked || (disputed && !disputeWon) { return .chargedBack }
            return nil
        }

        /// 3 × quantity (a missing or zero quantity counts as one license).
        var seatLimit: Int { LicensePolicy.seatsPerLicense * max(quantity, 1) }
    }

    enum Answer: Equatable, Sendable {
        case verified(Verification)
        /// 404 JSON `success: false`: an unknown, disabled or revoked key, or a wrong product id.
        case notFound
        /// 400, or 500 JSON `success: false` (Gumroad's answer to a missing product_id, which Otto never sends).
        case productRejected
        case unavailable(LicenseUnavailableReason)
    }

    static let productRejectedDetail = "Gumroad rejected the product id"

    // MARK: - Request

    /// `POST https://api.gumroad.com/v2/licenses/verify`, body
    /// `increment_uses_count=<true|false>&license_key=<key>&product_id=<id>` (sorted, percent-encoded).
    static func verifyRequest(key: String, productID: String, incrementUsesCount: Bool,
                              userAgent: String) -> LicenseHTTPRequest? {
        guard let url = URL(string: GumroadConfiguration.verifyEndpoint) else { return nil }
        let fields = [
            ("increment_uses_count", incrementUsesCount ? "true" : "false"),
            ("license_key", key),
            ("product_id", productID),
        ]
        let body = fields.sorted { $0.0 < $1.0 }
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
        let headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "Accept-Language": "en",
            "User-Agent": userAgent,
        ]
        return LicenseHTTPRequest(url: url, method: "POST", headers: headers, body: Data(body.utf8))
    }

    /// RFC 3986 unreserved characters stay; everything else (including "=", "+", "/" and spaces) is escaped.
    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Classification

    static func classify(status: Int, headers: [String: String], body: Data) -> Answer {
        switch status {
        case 200:
            guard let wire = try? JSONDecoder().decode(VerifyWire.self, from: body), wire.success == true,
                  let uses = wire.uses, let purchase = wire.purchase else {
                return .unavailable(.unexpectedResponse(status: 200))
            }
            return .verified(Verification(uses: uses, quantity: purchase.quantity ?? 1,
                                          refunded: purchase.refunded ?? false,
                                          chargebacked: purchase.chargebacked ?? false,
                                          disputed: purchase.disputed ?? false,
                                          disputeWon: purchase.disputeWon ?? false))
        case 404:
            return isFailureJSON(body) ? .notFound : .unavailable(.unexpectedResponse(status: 404))
        case 400:
            return .productRejected
        case 429:
            return .unavailable(.rateLimited(retryAfter: LicenseBackends.retryAfter(in: headers)))
        case 500 where isFailureJSON(body):
            return .productRejected
        case 500...599:
            return .unavailable(.server(status: status))
        default:
            return .unavailable(.unexpectedResponse(status: status))
        }
    }

    /// `{"success": false, …}`; the message text is never relied on.
    private static func isFailureJSON(_ body: Data) -> Bool {
        (try? JSONDecoder().decode(VerifyWire.self, from: body))?.success == false
    }

    // Wire shape: only the fields §14.7 lists. email, full_name, purchaser_id, ip_country, card, sale_id, price and
    // custom fields are not declared, so they are never read.
    private struct VerifyWire: Decodable {
        struct Purchase: Decodable {
            let refunded: Bool?
            let chargebacked: Bool?
            let disputed: Bool?
            let disputeWon: Bool?
            let quantity: Int?

            enum CodingKeys: String, CodingKey {
                case refunded, chargebacked, disputed, disputeWon = "dispute_won", quantity
            }
        }

        let success: Bool?
        let uses: Int?
        let purchase: Purchase?
    }
}
#endif
