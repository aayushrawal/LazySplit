import XCTest
@testable import LazySplit

final class CSVImporterTests: XCTestCase {
    private func record(amount: Int = 2450, state: ReviewState = .needsReview) -> TransactionRecord {
        TransactionRecord(source: .plaid, accountName: "Card", accountMask: "1234", merchant: "North Cafe",
                          date: Date(timeIntervalSince1970: 1788048000), amountMinor: amount, state: state)
    }

    func testPersonalIsVisibleByDefaultButCannotSplit() {
        let personal = record(state: .personal)
        var filters = InboxFilters()
        XCTAssertTrue(filters.matches(personal))
        XCTAssertEqual(filters.activeCount, 0)
        XCTAssertFalse(personal.canSplit)
        filters.excludePersonal = true
        XCTAssertFalse(filters.matches(personal))
        XCTAssertTrue(filters.matches(record()))
        filters = InboxFilters()
        filters.state = .personal
        XCTAssertTrue(filters.matches(personal))
        personal.state = .needsReview
        XCTAssertTrue(personal.canSplit)
        personal.isCredit = true
        XCTAssertFalse(personal.canSplit)
    }

    func testAmountFiltersAreInclusiveAndValidateInput() {
        var filters = InboxFilters()
        filters.minimum = "24.50"
        filters.maximum = "25,00"
        XCTAssertNil(filters.validationError)
        XCTAssertTrue(filters.matches(record(amount: 2450)))
        XCTAssertTrue(filters.matches(record(amount: 2500)))
        XCTAssertFalse(filters.matches(record(amount: 2449)))
        XCTAssertFalse(filters.matches(record(amount: 2501)))
        filters.currency = "EUR"
        XCTAssertFalse(filters.matches(record()))
        filters.minimum = "26"
        XCTAssertNotNil(filters.validationError)
        filters.minimum = "1,000.00"
        XCTAssertNotNil(filters.validationError)
        filters.minimum = "-1"
        XCTAssertNotNil(filters.validationError)
    }

    func testClassificationPrefersBankAndDoesNotInventLocations() {
        let transaction = record()
        XCTAssertEqual(transaction.locationLabel, "Unknown location")
        XCTAssertTrue(TransactionClassification.category(for: transaction).inferred)
        transaction.category = "TRAVEL"
        XCTAssertEqual(TransactionClassification.category(for: transaction).name, "Travel")
        XCTAssertFalse(TransactionClassification.category(for: transaction).inferred)
        transaction.city = "Chicago"
        transaction.region = "IL"
        XCTAssertEqual(transaction.locationLabel, "Chicago, IL")
        var filters = InboxFilters()
        XCTAssertTrue(filters.matches(transaction, search: "chicago"))
        filters.location = "Chicago, IL"
        XCTAssertTrue(filters.matches(transaction))
        filters.category = "Groceries"
        XCTAssertFalse(filters.matches(transaction))
    }

    func testDateAccountRefundAndAmountSortingFilters() {
        let transaction = record()
        var filters = InboxFilters()
        filters.useDates = true
        filters.startDate = transaction.date
        filters.endDate = transaction.date
        XCTAssertTrue(filters.matches(transaction))
        filters.account = "Card • 9999"
        XCTAssertFalse(filters.matches(transaction))
        filters.account = transaction.cardLabel
        XCTAssertTrue(filters.matches(transaction))
        filters.kind = "Credits / refunds"
        XCTAssertFalse(filters.matches(transaction))
        transaction.isCredit = true
        XCTAssertTrue(filters.matches(transaction))
        let larger = record(amount: 5000)
        let euro = record(amount: 100)
        euro.currencyCode = "EUR"
        filters.sort = .largest
        XCTAssertEqual(filters.ordered([transaction, larger, euro]).map(\.id), [euro.id, larger.id, transaction.id])
    }

    func testAPIDatesAcceptPostgresAndISOFormats() throws {
        struct Payload: Decodable { let date: Date }
        for value in ["2026-08-30", "2026-08-30T00:00:00Z", "2026-08-30T00:00:00.000Z"] {
            let decoded = try JSONDecoder.api.decode(Payload.self, from: Data("{\"date\":\"\(value)\"}".utf8))
            XCTAssertEqual(decoded.date.timeIntervalSince1970, 1788048000)
        }
    }

    func testQuotedMerchantAndDuplicateDetection() throws {
        let csv = "Transaction Date,Description,Amount,Card\n08/01/2026,\"Cafe, North\",24.50,4242\n08/01/2026,\"Cafe, North\",24.50,4242\n"
        let data = Data(csv.utf8)
        let preview = try CSVImporter.preview(data: data)
        let result = try CSVImporter.transactions(data: data, mapping: preview.suggestedMapping, fallbackAccount: "Card", knownFingerprints: [])
        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(result.1, 1)
        XCTAssertEqual(result.0.first?.merchant, "Cafe, North")
        XCTAssertEqual(result.0.first?.amountMinor, 2450)
    }

    func testDebitCreditStatements() throws {
        let csv = "Date,Description,Debit,Credit\n2026-08-01,Dinner,90.15,\n2026-08-02,Refund,,12.20\n"
        let data = Data(csv.utf8)
        let preview = try CSVImporter.preview(data: data)
        let result = try CSVImporter.transactions(data: data, mapping: preview.suggestedMapping, fallbackAccount: "Card", knownFingerprints: [])
        XCTAssertEqual(result.0.map(\.amountMinor), [9015, 1220])
    }

    func testFingerprintNormalizesMerchantPunctuation() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            TransactionFingerprint.make(account: "Card", date: date, amountMinor: 1000, merchant: "CAFÉ NORTH #12"),
            TransactionFingerprint.make(account: "card", date: date, amountMinor: 1000, merchant: "Cafe North 12")
        )
    }
}
