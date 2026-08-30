import Foundation
import SwiftData

enum ReviewState: String, Codable, CaseIterable, Identifiable {
    case pending, needsReview, personal, sharedDraft, queued, published, failed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "Pending"
        case .needsReview: "Needs review"
        case .personal: "Personal"
        case .sharedDraft: "Shared"
        case .queued: "Queued"
        case .published: "Published"
        case .failed: "Failed"
        }
    }
}

enum TransactionSource: String, Codable { case plaid, csv }

@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID
    var externalID: String?
    var sourceRaw: String
    var accountName: String
    var accountMask: String
    var merchant: String
    var originalDescription: String
    var date: Date
    var amountMinor: Int
    var currencyCode: String
    var stateRaw: String
    var category: String?
    var fingerprint: String
    var possibleDuplicateID: UUID?
    var updatedAt: Date
    var isDemo: Bool = false
    var categoryDetail: String?
    var city: String?
    var region: String?
    var country: String?
    var paymentChannel: String?
    var isCredit: Bool = false
    var reviewNeedsSync: Bool = false
    var reviewHasSynced: Bool = false

    var canClassify: Bool { [.needsReview, .sharedDraft, .personal].contains(state) }
    var canSplit: Bool { !isCredit && [.needsReview, .sharedDraft].contains(state) }
    var locationLabel: String {
        let parts = [city, region, country].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown location" : parts.joined(separator: ", ")
    }
    var cardLabel: String { accountMask.isEmpty ? accountName : "\(accountName) • \(accountMask)" }

    var source: TransactionSource { TransactionSource(rawValue: sourceRaw) ?? .csv }
    var state: ReviewState {
        get { ReviewState(rawValue: stateRaw) ?? .needsReview }
        set { stateRaw = newValue.rawValue; updatedAt = .now }
    }
    var amount: Decimal { Decimal(amountMinor) / 100 }

    init(id: UUID = UUID(), externalID: String? = nil, source: TransactionSource, accountName: String, accountMask: String = "", merchant: String, originalDescription: String = "", date: Date, amountMinor: Int, currencyCode: String = "USD", state: ReviewState = .needsReview, category: String? = nil, fingerprint: String? = nil, isDemo: Bool = false) {
        self.id = id
        self.externalID = externalID
        self.sourceRaw = source.rawValue
        self.accountName = accountName
        self.accountMask = accountMask
        self.merchant = merchant
        self.originalDescription = originalDescription
        self.date = date
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.stateRaw = state.rawValue
        self.category = category
        self.fingerprint = fingerprint ?? TransactionFingerprint.make(account: accountName + accountMask, date: date, amountMinor: amountMinor, merchant: merchant)
        self.updatedAt = .now
        self.isDemo = isDemo
    }
}

@Model
final class SplitDraft {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var splitwiseGroupID: Int?
    var splitKind: String
    var createdAt: Date
    var approvedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \SplitParticipant.draft) var participants: [SplitParticipant]

    init(transactionID: UUID, splitwiseGroupID: Int? = nil, splitKind: String = "equal", participants: [SplitParticipant] = []) {
        id = UUID(); self.transactionID = transactionID; self.splitwiseGroupID = splitwiseGroupID
        self.splitKind = splitKind; self.createdAt = .now; self.participants = participants
    }
}

@Model
final class SplitParticipant {
    @Attribute(.unique) var id: UUID
    var splitwiseUserID: Int
    var displayName: String
    var owedMinor: Int
    var paidMinor: Int
    var draft: SplitDraft?

    init(splitwiseUserID: Int, displayName: String, owedMinor: Int, paidMinor: Int = 0) {
        id = UUID(); self.splitwiseUserID = splitwiseUserID; self.displayName = displayName
        self.owedMinor = owedMinor; self.paidMinor = paidMinor
    }
}

@Model
final class SuggestionRule {
    @Attribute(.unique) var id: UUID
    var normalizedMerchant: String
    var participantIDsJSON: String
    var participantNamesJSON: String
    var splitKind: String
    var confirmations: Int
    var updatedAt: Date

    init(merchant: String, participantIDs: [Int], participantNames: [String], splitKind: String = "equal") {
        id = UUID(); normalizedMerchant = TransactionFingerprint.normalize(merchant)
        participantIDsJSON = (try? String(data: JSONEncoder().encode(participantIDs), encoding: .utf8)) ?? "[]"
        participantNamesJSON = (try? String(data: JSONEncoder().encode(participantNames), encoding: .utf8)) ?? "[]"
        self.splitKind = splitKind; confirmations = 1; updatedAt = .now
    }
}

@Model
final class ImportBatch {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var importedAt: Date
    var rowCount: Int
    var duplicateCount: Int
    var issuerKey: String

    init(fileName: String, rowCount: Int, duplicateCount: Int, issuerKey: String) {
        id = UUID(); self.fileName = fileName; importedAt = .now; self.rowCount = rowCount
        self.duplicateCount = duplicateCount; self.issuerKey = issuerKey
    }
}

@Model
final class ExportAttempt {
    @Attribute(.unique) var id: UUID
    var draftID: UUID
    var idempotencyKey: String
    var status: String
    var splitwiseExpenseID: Int?
    var errorMessage: String?
    var attemptedAt: Date

    init(draftID: UUID) {
        id = UUID(); self.draftID = draftID; idempotencyKey = UUID().uuidString
        status = "queued"; attemptedAt = .now
    }
}

enum TransactionFingerprint {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression)
            .lowercased()
    }

    static func make(account: String, date: Date, amountMinor: Int, merchant: String) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .gmt, formatOptions: [.withFullDate])
        return [normalize(account), day, String(amountMinor), normalize(merchant)].joined(separator: "|")
    }
}

struct SplitwiseFriend: Identifiable, Codable, Hashable {
    let id: Int
    let firstName: String
    let lastName: String?
    let alias: String?
    let sortOrder: Int?
    let interactionCount: Int
    var originalName: String { [firstName, lastName].compactMap { $0 }.joined(separator: " ") }
    var displayName: String { alias ?? originalName }

    init(id: Int, firstName: String, lastName: String?, alias: String? = nil, sortOrder: Int? = nil, interactionCount: Int = 0) {
        self.id = id; self.firstName = firstName; self.lastName = lastName; self.alias = alias
        self.sortOrder = sortOrder; self.interactionCount = interactionCount
    }
}

struct FriendGroup: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let friendIDs: [Int]
    let createdAt: Date
}

struct CoverageMonth: Identifiable {
    let date: Date
    let source: TransactionSource?
    var id: Date { date }
}
