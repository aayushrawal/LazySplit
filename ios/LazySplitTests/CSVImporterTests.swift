import XCTest
@testable import LazySplit

final class CSVImporterTests: XCTestCase {
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
