import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData
import UserNotifications
import UIKit

enum APIError: LocalizedError {
    case notConfigured, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Connect the app to a LazySplit API first."
        case .invalidResponse: "The server returned an invalid response."
        case .server(let message): message
        }
    }
}

actor APIClient {
    private let session: URLSession
    private let baseURL: URL?

    init(session: URLSession = .shared) {
        self.session = session
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        baseURL = raw.flatMap(URL.init(string:))
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Encodable? = nil, idempotencyKey: String? = nil) async throws -> T {
        guard let baseURL else { throw APIError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = KeychainStore.read("sessionToken") { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body { request.httpBody = try JSONEncoder.api.encode(AnyEncodable(body)) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder.api.decode(ServerError.self, from: data).message) ?? "Request failed (\(http.statusCode))."
            throw APIError.server(message)
        }
        return try JSONDecoder.api.decode(T.self, from: data)
    }

    func authenticate(identityToken: String, authorizationCode: String?) async throws {
        let response: SessionResponse = try await request("/v1/auth/apple", method: "POST", body: AppleAuthBody(identityToken: identityToken, authorizationCode: authorizationCode))
        try KeychainStore.write(response.token, key: "sessionToken")
    }

    func createPlaidLinkToken() async throws -> String {
        let response: LinkTokenResponse = try await request("/v1/plaid/link-token", method: "POST")
        return response.linkToken
    }

    func exchangePlaid(publicToken: String) async throws {
        let _: EmptyResponse = try await request("/v1/plaid/exchange", method: "POST", body: ["publicToken": publicToken])
    }

    func friends() async throws -> [SplitwiseFriend] {
        let response: FriendsResponse = try await request("/v1/splitwise/friends")
        return response.friends
    }

    func transactions() async throws -> [RemoteTransaction] {
        let response: TransactionsResponse = try await request("/v1/transactions?limit=500")
        return response.transactions
    }

    func importTransactions(_ values: [ImportedTransaction], idempotencyKey: String) async throws -> ImportResponse {
        return try await request("/v1/transactions/import", method: "POST", body: ImportBody(idempotencyKey: idempotencyKey, transactions: values), idempotencyKey: idempotencyKey)
    }

    func splitwiseConnectURL() async throws -> URL {
        let response: ConnectResponse = try await request("/v1/splitwise/connect")
        guard let url = URL(string: response.url) else { throw APIError.invalidResponse }
        return url
    }

    func registerDevice(token: String, enabled: Bool = true) async throws {
        let _: EmptyResponse = try await request("/v1/devices/current", method: "PUT", body: DeviceBody(token: token, timezone: TimeZone.current.identifier, digestHour: 19, enabled: enabled))
    }

    func publish(_ body: PublishBody) async throws -> Int {
        let response: PublishResponse = try await request("/v1/splitwise/publish", method: "POST", body: body, idempotencyKey: UUID().uuidString)
        return response.expenseID
    }
}

enum KeychainStore {
    static func write(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key] as CFDictionary)
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError.server("Could not securely save the session.") }
    }

    static func read(_ key: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key] as CFDictionary) }
}

struct CSVMapping: Codable, Equatable {
    var dateColumn: String
    var descriptionColumn: String
    var amountColumn: String?
    var debitColumn: String?
    var creditColumn: String?
    var accountColumn: String?
    var currencyColumn: String?
}

struct CSVPreview {
    let headers: [String]
    let rows: [[String: String]]
    let suggestedMapping: CSVMapping
}

enum CSVImportError: LocalizedError {
    case unreadable, missingHeaders, unmappedAmount, invalidRows
    var errorDescription: String? {
        switch self {
        case .unreadable: "The statement is not readable text."
        case .missingHeaders: "The statement needs a header row."
        case .unmappedAmount: "Choose either an amount column or debit/credit columns."
        case .invalidRows: "No valid transactions were found."
        }
    }
}

enum CSVImporter {
    static func preview(data: Data) throws -> CSVPreview {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw CSVImportError.unreadable }
        let matrix = parse(text)
        guard let headers = matrix.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), !headers.isEmpty else { throw CSVImportError.missingHeaders }
        let rows = matrix.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.prefix(20).map { values in
            Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, values.indices.contains($0.offset) ? values[$0.offset] : "") })
        }
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.lowercased(), $0) })
        func match(_ names: [String]) -> String? { names.compactMap { candidate in normalized.first { $0.key.contains(candidate) }?.value }.first }
        let amount = match(["amount", "charge"])
        return CSVPreview(headers: headers, rows: Array(rows), suggestedMapping: CSVMapping(
            dateColumn: match(["transaction date", "posted date", "date"]) ?? headers[0],
            descriptionColumn: match(["merchant", "description", "details", "memo"]) ?? headers[min(1, headers.count - 1)],
            amountColumn: amount, debitColumn: amount == nil ? match(["debit", "withdrawal"]) : nil,
            creditColumn: amount == nil ? match(["credit", "deposit"]) : nil,
            accountColumn: match(["account", "card"]), currencyColumn: match(["currency"])))
    }

    static func transactions(data: Data, mapping: CSVMapping, fallbackAccount: String, knownFingerprints: Set<String>) throws -> ([TransactionRecord], Int) {
        guard mapping.amountColumn != nil || mapping.debitColumn != nil || mapping.creditColumn != nil else { throw CSVImportError.unmappedAmount }
        let preview = try preview(data: data)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)!
        let matrix = parse(text)
        var seen = knownFingerprints
        var duplicates = 0
        let dateParsers = ["MM/dd/yyyy", "MM/dd/yy", "yyyy-MM-dd", "M/d/yyyy"].map { format -> DateFormatter in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format; return f }
        let records = matrix.dropFirst().compactMap { values -> TransactionRecord? in
            let row = Dictionary(uniqueKeysWithValues: preview.headers.enumerated().map { ($0.element, values.indices.contains($0.offset) ? values[$0.offset] : "") })
            guard let rawDate = row[mapping.dateColumn], let date = dateParsers.lazy.compactMap({ $0.date(from: rawDate.trimmingCharacters(in: .whitespaces)) }).first else { return nil }
            let merchant = row[mapping.descriptionColumn]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            let account = mapping.accountColumn.flatMap { row[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackAccount
            let currency = mapping.currencyColumn.flatMap { row[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
            let amountText: String
            if let column = mapping.amountColumn { amountText = row[column] ?? "" }
            else {
                let debit = decimal(row[mapping.debitColumn ?? ""] ?? "") ?? 0
                let credit = decimal(row[mapping.creditColumn ?? ""] ?? "") ?? 0
                amountText = NSDecimalNumber(decimal: debit - credit).stringValue
            }
            guard let amount = decimal(amountText), amount != 0 else { return nil }
            let minor = NSDecimalNumber(decimal: abs(amount) * 100).intValue
            let fingerprint = TransactionFingerprint.make(account: account, date: date, amountMinor: minor, merchant: merchant)
            if seen.contains(fingerprint) { duplicates += 1; return nil }
            seen.insert(fingerprint)
            return TransactionRecord(source: .csv, accountName: account, merchant: merchant, originalDescription: merchant, date: date, amountMinor: minor, currencyCode: currency.uppercased(), fingerprint: fingerprint)
        }
        guard !records.isEmpty else { throw CSVImportError.invalidRows }
        return (records, duplicates)
    }

    static func parse(_ text: String) -> [[String]] {
        var rows = [[String]](), row = [String](), field = "", quoted = false
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if char == ",", !quoted { row.append(field); field = "" }
            else if char == "\n", !quoted { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(char) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func decimal(_ value: String) -> Decimal? {
        let cleaned = value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}

enum NotificationService {
    static func requestAuthorization() async throws -> Bool {
        let approved = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        if approved { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
        return approved
    }
}

private struct AnyEncodable: Encodable {
    let encodeClosure: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeClosure = value.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}
private struct ServerError: Decodable { let message: String }
private struct SessionResponse: Decodable { let token: String }
private struct AppleAuthBody: Encodable { let identityToken: String; let authorizationCode: String? }
private struct LinkTokenResponse: Decodable { let linkToken: String }
private struct EmptyResponse: Decodable {}
private struct FriendsResponse: Decodable { let friends: [SplitwiseFriend] }
struct PublishParticipant: Encodable, Sendable { let userID: Int; let owedMinor: Int; let paidMinor: Int }
struct PublishBody: Encodable, Sendable { let draftID: UUID; let transactionID: UUID; let merchant: String; let date: Date; let amountMinor: Int; let currencyCode: String; let groupID: Int?; let participants: [PublishParticipant] }
private struct PublishResponse: Decodable { let expenseID: Int }
struct RemoteTransaction: Decodable {
    let id: UUID; let externalID: String?; let source: TransactionSource; let accountName: String; let accountMask: String
    let merchant: String; let originalDescription: String; let date: Date; let amountMinor: Int; let currencyCode: String
    let state: ReviewState; let category: String?; let fingerprint: String; let possibleDuplicateID: UUID?
}
private struct TransactionsResponse: Decodable { let transactions: [RemoteTransaction] }
struct ImportedTransaction: Encodable, Sendable { let id: UUID; let accountName: String; let accountMask: String; let merchant: String; let originalDescription: String; let date: Date; let amountMinor: Int; let currencyCode: String; let fingerprint: String }
private struct ImportBody: Encodable, Sendable { let idempotencyKey: String; let transactions: [ImportedTransaction] }
struct ImportResponse: Decodable { let inserted: Int; let duplicates: Int }
private struct ConnectResponse: Decodable { let url: String }
private struct DeviceBody: Encodable { let token: String; let timezone: String; let digestHour: Int; let enabled: Bool }

extension JSONEncoder {
    static var api: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}
extension JSONDecoder {
    static var api: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
