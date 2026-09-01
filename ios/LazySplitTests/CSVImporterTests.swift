import XCTest
import SwiftUI
import SwiftData
import PDFKit
@testable import LazySplit

final class CSVImporterTests: XCTestCase {
    @MainActor func testInboxCountBadgeFitsFourDigitCounts() {
        let controller = UIHostingController(rootView: InboxCountBadge(count: 9_999))
        let size = controller.sizeThatFits(in: CGSize(width: 1_000, height: 100))
        XCTAssertGreaterThan(size.width, 40)
        XCTAssertLessThan(size.height, 32)
    }

    func testStatementPeriodInferenceFromPDFNames() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))

        let named = StatementPeriodInference.infer(filename: "Apple Card - August 2026.pdf", referenceDate: reference)
        XCTAssertEqual(named.kind, .monthly)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: named.endingOn), DateComponents(year: 2026, month: 8, day: 31))

        let numeric = StatementPeriodInference.infer(filename: "Statement_2025-02.pdf", referenceDate: reference)
        XCTAssertEqual(numeric.kind, .monthly)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: numeric.endingOn), DateComponents(year: 2025, month: 2, day: 28))

        let annual = StatementPeriodInference.infer(filename: "Annual Statement 2024.pdf", referenceDate: reference)
        XCTAssertEqual(annual.kind, .yearly)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: annual.endingOn), DateComponents(year: 2024, month: 12, day: 31))

        let missingYear = StatementPeriodInference.infer(filename: "Apple Card August.pdf", referenceDate: reference)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: missingYear.endingOn), DateComponents(year: 2026, month: 8, day: 31))
        XCTAssertTrue(missingYear.message.contains("file date"))

        let cardSuffix = StatementPeriodInference.infer(filename: "Card 1234.pdf", referenceDate: reference)
        XCTAssertEqual(cardSuffix.kind, .monthly)
        XCTAssertTrue(cardSuffix.message.contains("No statement period"))
    }

    func testYearlyPDFParsesMonthNameDates() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let annualEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31)))
        let preview = PDFStatementImporter.parse(pages: ["Jan 2 Coffee Shop 12.34\nDecember 31 Grocery Store 56.78\nFeb 29, 2024 Leap Day Lunch 20.24"])
        XCTAssertEqual(preview.rows.count, 3)
        XCTAssertEqual(preview.rows.compactMap { $0.date(endingOn: annualEnd) }.map { calendar.dateComponents([.year, .month, .day], from: $0) }, [
            DateComponents(year: 2024, month: 1, day: 2),
            DateComponents(year: 2024, month: 12, day: 31),
            DateComponents(year: 2024, month: 2, day: 29)
        ])

        let january = StatementPeriodInference.infer(filename: "Apple Card January 2026.pdf", referenceDate: annualEnd)
        XCTAssertEqual(PDFStatementImporter.date("12/28", endingOn: january.endingOn), calendar.date(from: DateComponents(year: 2025, month: 12, day: 28)))
    }

    func testStatementContentAndCompactChaseFilenameInferPeriod() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let chase = try XCTUnwrap(PDFStatementImporter.statementPeriod(in: ["ACCOUNT SUMMARY\nOpening/Closing Date 12/03/18 - 01/01/19\nCredit Limit $4,000.00"]))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: chase.endingOn), DateComponents(year: 2019, month: 1, day: 1))
        XCTAssertTrue(chase.message.contains("opening/closing"))

        let amex = try XCTUnwrap(PDFStatementImporter.statementPeriod(in: ["American Express Gold Card\nClosing Date 08/25/23\nAccount Ending 51002"]))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: amex.endingOn), DateComponents(year: 2023, month: 8, day: 25))

        let filename = StatementPeriodInference.infer(filename: "20250815-statements-1234.pdf")
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: filename.endingOn), DateComponents(year: 2025, month: 8, day: 31))
        XCTAssertEqual(filename.kind, .monthly)
    }

    @MainActor func testAmexColumnarPDFReconstructsVisualRows() throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black]
            ("American Express Gold Card" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: attributes)
            ("Closing Date 08/25/23" as NSString).draw(at: CGPoint(x: 30, y: 48), withAttributes: attributes)
            ("New Charges" as NSString).draw(at: CGPoint(x: 30, y: 90), withAttributes: attributes)
            for (index, row) in [("07/30/23*", "COFFEE SHOP CHICAGO IL", "$12.34"), ("08/12/23", "GROCERY MARKET AUSTIN TX", "$56.78")].enumerated() {
                let y = CGFloat(120 + index * 24)
                (row.0 as NSString).draw(at: CGPoint(x: 30, y: y), withAttributes: attributes)
                (row.1 as NSString).draw(at: CGPoint(x: 125, y: y), withAttributes: attributes)
                (row.2 as NSString).draw(at: CGPoint(x: 510, y: y), withAttributes: attributes)
            }
        }
        let preview = try PDFStatementImporter.preview(data: data)
        XCTAssertEqual(preview.rows.map(\.merchant), ["COFFEE SHOP CHICAGO IL", "GROCERY MARKET AUSTIN TX"])
        XCTAssertEqual(preview.rows.map(\.amountText), ["12.34", "56.78"])
        XCTAssertEqual(preview.rows.first?.rawDate, "07/30/23*")
        XCTAssertNotNil(preview.statementPeriod)
    }

    func testAmexSectionsExcludePaymentsAndKeepNewCharges() {
        let preview = PDFStatementImporter.parse(pages: ["""
        American Express Gold Card
        Closing Date 03/14/23
        Payments and Credits
        Payments
        02/16/23* ONLINE PAYMENT - THANK YOU -$122.51
        03/01/23* MOBILE PAYMENT RECEIVED -$416.62
        New Charges
        02/11/23 COFFEE SHOP HYATTSVILLE MD $12.34 ♦
        02/22/23 GROCERY MARKET RIVERDALE MD $56.78 †
        Fees
        03/14/23 Late Fee $29.00
        """])
        XCTAssertEqual(preview.rows.map(\.merchant), ["COFFEE SHOP HYATTSVILLE MD", "GROCERY MARKET RIVERDALE MD"])
        XCTAssertEqual(preview.rows.map(\.amountText), ["12.34", "56.78"])
        XCTAssertEqual(preview.rows.map(\.isCredit), [false, false])
        XCTAssertEqual(preview.excludedRows, 3)
    }

    func testStatementBatchRequiresReviewAccountsAndMatchingCurrency() throws {
        let account = StatementAccount(id: UUID(), name: "Apple Card", mask: "1234", currencyCode: "USD")
        var row = PDFStatementRow(rawDate: "08/31/2026", originalLine: "08/31 Coffee 10.00", page: 1, merchant: "Coffee", amountText: "10.00", isCredit: false,
            editedDate: ISO8601DateFormatter().date(from: "2026-08-31T00:00:00Z"))
        var file = StagedStatement(name: "August.pdf", accountID: account.id, rows: [row], reviewed: false)
        XCTAssertThrowsError(try StatementBatch.prepare([file], accounts: [account]))
        file.reviewed = true
        let first = try StatementBatch.prepare([file], accounts: [account])
        XCTAssertEqual(first.values.count, 1)
        XCTAssertEqual(first.values[0].accountID, account.id)
        XCTAssertEqual(first.values[0].amountMinor, 1_000)
        let duplicate = try StatementBatch.prepare([file, file], accounts: [account])
        XCTAssertEqual(duplicate.values.count, 1)
        XCTAssertEqual(duplicate.duplicates, 1)
        row.currencyCode = "EUR"; file.rows = [row]
        XCTAssertThrowsError(try StatementBatch.prepare([file], accounts: [account]))
        file.accountID = UUID(); file.rows[0].currencyCode = nil
        XCTAssertThrowsError(try StatementBatch.prepare([file], accounts: [account]))
    }

    func testPartsSplittingUsesWeightedSharesAndCentSafeRounding() {
        let twoToOne = SplitCalculator.weighted(totalMinor: 10_000, friendParts: [(42, 2)], selfParts: 1)
        XCTAssertEqual(twoToOne.friends[42], 6_667)
        XCTAssertEqual(twoToOne.selfAmount, 3_333)
        let several = SplitCalculator.weighted(totalMinor: 10_001, friendParts: [(1, 2), (2, 1)], selfParts: 2)
        XCTAssertEqual(several.friends[1], 4_001)
        XCTAssertEqual(several.friends[2], 2_000)
        XCTAssertEqual(several.selfAmount, 4_000)
        XCTAssertEqual(several.friends.values.reduce(0, +) + several.selfAmount, 10_001)
        let equal = SplitCalculator.equal(totalMinor: 100, friendIDs: [1, 2])
        XCTAssertEqual(equal.friends, [1: 34, 2: 33])
        XCTAssertEqual(equal.selfAmount, 33)
        XCTAssertEqual(SplitCalculator.exactMinor("66.67"), 6_667)
        XCTAssertNil(SplitCalculator.exactMinor("66.666"))
        XCTAssertNil(SplitCalculator.exactMinor("0"))
    }

    func testPDFRowsCreditsAndUnsupportedBalanceColumns() throws {
        let preview = PDFStatementImporter.parse(pages: ["""
        Statement closing date 01/15/2026
        Previous balance $9,999.00
        12/28 12/29 Coffee Shop $12.34
        01/02/2026 Flight, \"Window Seat\" 1,234.56
        01/03 Returned Shoes 24.00 CR
        01/04 Payment Thank You -100.00
        01/05 Store return (15.20)
        01/06 Groceries 42.30 899.00
        01/07 MISSING AMOUNT
        01/08 Total purchases 1,200.00
        """, "Legal terms and conditions"])
        XCTAssertEqual(preview.rows.count, 5)
        XCTAssertEqual(preview.rows.map(\.isCredit), [false, false, true, true, true])
        XCTAssertEqual(preview.rows[1].amountText, "1234.56")
        XCTAssertEqual(preview.unmatchedDatedLines, 3)
        XCTAssertEqual(preview.pagesWithoutRows, 1)
        let closing = ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")!
        let csv = try PDFStatementImporter.reviewedCSV(rows: preview.rows, endingOn: closing, currency: "USD")
        let mapping = try CSVImporter.preview(data: csv).suggestedMapping
        let (records, duplicates) = try CSVImporter.transactions(data: csv, mapping: mapping, fallbackAccount: "Test card", knownFingerprints: [])
        XCTAssertEqual(records.count, 5); XCTAssertEqual(duplicates, 0)
        XCTAssertEqual(records[1].merchant, "Flight, \"Window Seat\"")
        XCTAssertEqual(records[1].amountMinor, 123456)
        XCTAssertEqual(records.map(\.isCredit), [false, false, true, true, true])
        XCTAssertEqual(records[0].date, ISO8601DateFormatter().date(from: "2025-12-28T00:00:00Z"))
        let repeated = try CSVImporter.transactions(data: csv, mapping: mapping, fallbackAccount: "Test card", knownFingerprints: Set(records.map(\.fingerprint)))
        XCTAssertTrue(repeated.0.isEmpty)
        XCTAssertEqual(repeated.1, 5)
    }

    func testAppleCardPDFUsesChargeNotDailyCashAndExcludesPaymentsAndACMI() throws {
        let preview = PDFStatementImporter.parse(pages: ["""
        Payments Date Description Amount
        04/30/2023 ACH Deposit Internet transfer from account ending in 2992 -$176.14
        Total payments for this period -$176.14
        Transactions Date Description Daily Cash Amount
        04/06/2023 APPLE.COM/BILL ONE APPLE PARK WAY 866-712-7753 95014 CA USA 3% $0.60 $19.99
        04/07/2023 COFFEE SHOP CHICAGO IL USA 2% $0.12 $6.00
        04/20/2023 GNC #006647 12214 Lakewood Boulevard DOWNEY 90242 CA USA 1% $0.71 $70.81
        04/22/2023 RETURNED ITEM CUPERTINO CA USA 3% -$0.30 -$10.00
        Total Daily Cash this month $1.13
        Total charges, credits and returns $86.80
        Apple Card Monthly Installments
        Dates Description Daily Cash Amounts
        12/17/2022 Apple Online Store Cupertino CA $199.00
        TRANSACTION #d536b51c444e
        This month's installment: $8.29
        Final installment: Dec 31, 2024
        Total financed $199.00
        """])
        XCTAssertEqual(preview.rows.map(\.merchant), ["APPLE.COM/BILL ONE APPLE PARK WAY 866-712-7753 95014 CA USA", "COFFEE SHOP CHICAGO IL USA", "GNC #006647 12214 Lakewood Boulevard DOWNEY 90242 CA USA", "RETURNED ITEM CUPERTINO CA USA"])
        XCTAssertEqual(preview.rows.map(\.amountText), ["19.99", "6.00", "70.81", "10.00"])
        XCTAssertEqual(preview.rows.map(\.isCredit), [false, false, false, true])
        XCTAssertEqual(preview.excludedRows, 2) // ACH payment and the dated ACMI purchase.
        XCTAssertFalse(preview.rows.contains { $0.merchant.localizedCaseInsensitiveContains("deposit") || $0.merchant.localizedCaseInsensitiveContains("installment") })
    }

    func testPDFDateAndAmountValidation() throws {
        let closing = ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")!
        XCTAssertNil(PDFStatementImporter.date("02/30/2026", endingOn: closing))
        XCTAssertNil(PDFStatementImporter.date("31/12/2025", endingOn: closing))
        XCTAssertEqual(PDFStatementImporter.date("2025-12-31", endingOn: closing), PDFStatementImporter.date("12/31/25", endingOn: closing))
        XCTAssertEqual(PDFStatementImporter.minorUnits("12.30"), 1230)
        for invalid in ["12.345", "1,23", "-10", "0", "nan", "10abc", "999999999"] { XCTAssertNil(PDFStatementImporter.minorUnits(invalid)) }
        var rows = PDFStatementImporter.parse(pages: ["01/02 Coffee 12.30\n01/03 Shop 20.00"]).rows
        rows[0].included = false
        rows[1].amountText = "bad"
        XCTAssertThrowsError(try PDFStatementImporter.reviewedCSV(rows: rows, endingOn: closing, currency: "USD"))
        rows[1].amountText = "18.25"; rows[1].merchant = "Corrected merchant"
        let csv = try PDFStatementImporter.reviewedCSV(rows: rows, endingOn: closing, currency: "USD")
        let parsed = try CSVImporter.preview(data: csv)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows[0]["Description"], "Corrected merchant")
        XCTAssertEqual(parsed.rows[0]["Amount"], "18.25")
    }

    @MainActor func testPDFExtractionFromDigitalAndScannedStatements() throws {
        // Synthetic fixtures stay in memory; no real statement or account data is used.
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let digital = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("TEST STATEMENT\n12/07 Coffee Shop 12.34\n12/08 Grocery Store 56.78" as NSString)
                .draw(in: bounds.insetBy(dx: 30, dy: 40), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)])
        }
        let extracted = try PDFStatementImporter.preview(data: digital)
        XCTAssertEqual(extracted.rows.count, 2)
        XCTAssertEqual(extracted.scannedPages, 0)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
            UIColor.white.setFill(); context.fill(bounds)
            ("TEST STATEMENT\n12/07 Coffee Shop 12.34" as NSString).draw(in: bounds.insetBy(dx: 30, dy: 40), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular), .foregroundColor: UIColor.black])
        }
        let scanned = PDFDocument(); scanned.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let recognized = try PDFStatementImporter.preview(data: XCTUnwrap(scanned.dataRepresentation()))
        XCTAssertEqual(recognized.scannedPages, 1)
        XCTAssertEqual(recognized.rows.first?.amountText, "12.34")
        XCTAssertThrowsError(try PDFStatementImporter.preview(data: Data("not a pdf".utf8)))
        XCTAssertThrowsError(try PDFStatementImporter.preview(data: Data(count: PDFStatementImporter.maxBytes + 1)))
        let locked = try XCTUnwrap(PDFDocument(data: digital)?.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "test-password", PDFDocumentWriteOption.ownerPasswordOption: "test-owner"]))
        XCTAssertThrowsError(try PDFStatementImporter.preview(data: locked)) { error in
            XCTAssertEqual(error.localizedDescription, PDFStatementError.locked.localizedDescription)
        }
    }

    @MainActor func testPDFImportReviewRendering() async throws {
        let container = try ModelContainer(for: TransactionRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let session = AppSession(); session.isDemoMode = true
        let sample = PDFStatementImporter.parse(pages: ["08/02/2026 Coffee Shop 12.34\n08/03/2026 Grocery Store 56.78\n08/04/2026 Shoe Refund 24.00 CR"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large), ("dark", .dark, .large), ("large-text", .light, .accessibility3)] {
            let file = StagedStatement(name: "August.pdf", accountID: UUID(), rows: sample.rows, pdf: sample)
            let account = StatementAccount(id: file.accountID!, name: "Apple Card", mask: "1234", currencyCode: "USD")
            window.rootViewController = UIHostingController(rootView: NavigationStack { StatementFileReview(file: .constant(file), accounts: [account]) }
                .environment(session).modelContainer(container).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "pdf-import-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(image.size.width, 393)
        }
    }

    @MainActor func testPartsSplitEditorRendering() async throws {
        let container = try ModelContainer(for: TransactionRecord.self, SplitDraft.self, SplitParticipant.self, SuggestionRule.self, ImportBatch.self, ExportAttempt.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let session = AppSession(); session.isDemoMode = true
        session.demoFriends = [SplitwiseFriend(id: 42, firstName: "Alex", lastName: "Friend")]
        let transaction = TransactionRecord(source: .plaid, accountName: "Card", merchant: "Dinner", date: .now, amountMinor: 10_000, isDemo: true)
        container.mainContext.insert(transaction)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.rootViewController = UIHostingController(rootView: NavigationStack { SplitEditorView(transaction: transaction, initialMode: .parts, initialSelected: [42]) }.environment(session).modelContainer(container))
        window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(700)); window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "split-by-parts"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(image.size.width, 393)
    }

    @MainActor func testDemoFriendsStartEmptyAndResetWhenLeavingDemo() {
        let session = AppSession()
        XCTAssertTrue(session.demoFriends.isEmpty)
        session.isDemoMode = true
        session.demoFriends = DemoData.friends
        XCTAssertFalse(session.demoFriends.isEmpty)
        session.completeAuthentication()
        XCTAssertTrue(session.demoFriends.isEmpty)
        XCTAssertFalse(session.isDemoMode)
    }

    func testHistoryGroupingByMonthYearAndAccountKeepsNewSeparate() {
        let august = record(amount: 1000), july = record(amount: 2000), priorYear = record(amount: 3000)
        august.date = InboxMonth.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        july.date = InboxMonth.calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        priorYear.date = InboxMonth.calendar.date(from: DateComponents(year: 2025, month: 8, day: 1))!
        let firstAccount = UUID(), secondAccount = UUID()
        august.accountID = firstAccount; july.accountID = firstAccount; priorYear.accountID = secondAccount
        [august, july, priorYear].forEach { $0.newImportDismissed = true }
        let newArrival = record(), refund = record()
        refund.isCredit = true
        let input = [august, july, priorYear, newArrival, refund]
        let months = InboxHistoryGroup.group(input, by: .month, sort: .newest)
        XCTAssertEqual(months.count, 3)
        XCTAssertEqual(months.first?.transactions.first?.id, august.id)
        let years = InboxHistoryGroup.group(input, by: .year, sort: .newest)
        XCTAssertEqual(years.map(\.title), ["2026", "2025"])
        XCTAssertEqual(years.first?.transactions.count, 2)
        XCTAssertEqual(years.first?.postedTotals.first?.amount, 30)
        XCTAssertEqual(InboxHistoryGroup.group(input, by: .year, sort: .oldest).map(\.title), ["2025", "2026"])
        let cards = InboxHistoryGroup.group(input, by: .account, sort: .largest)
        XCTAssertEqual(cards.count, 2) // Identical labels must not merge distinct server accounts.
        XCTAssertNotEqual(cards[0].id, cards[1].id)
        let firstCard = cards.first { $0.transactions.contains { $0.id == august.id } }!
        XCTAssertEqual(firstCard.transactions.map(\.id), [july.id, august.id])
        august.accountName = "Renamed card"; july.accountName = "Renamed card"
        XCTAssertTrue(InboxHistoryGroup.group(input, by: .account, sort: .newest).contains { $0.id == firstCard.id && $0.title.contains("Renamed card") })
        for mode in InboxGrouping.allCases {
            let ids = InboxHistoryGroup.group(input, by: mode, sort: .newest).flatMap { $0.transactions.map(\.id) }
            XCTAssertEqual(Set(ids), Set([august.id, july.id, priorYear.id]))
            XCTAssertEqual(ids.count, 3)
        }
    }

    func testNewImportsAreSeparateFromMonthlyRegardlessOfPurchaseDate() {
        let historical = record()
        historical.date = Date(timeIntervalSince1970: 1_600_000_000)
        let cached = record()
        cached.inboxReceivedAt = nil
        let seen = record()
        seen.newImportDismissed = true
        let personal = record(state: .personal)
        let pending = record(state: .pending)
        let refund = record()
        refund.isCredit = true
        let filtered = [historical, cached, seen, personal, pending, refund].filter { InboxFilters().matches($0) }
        XCTAssertEqual(InboxArrivalGroups.newTransactions(in: filtered).map(\.id), [historical.id])
        let monthly = InboxArrivalGroups.monthlyTransactions(in: filtered)
        XCTAssertEqual(Set(monthly.map(\.id)), Set([cached.id, seen.id, personal.id, pending.id]))
        XCTAssertEqual(monthly.count + InboxArrivalGroups.newTransactions(in: filtered).count, filtered.count)
        historical.newImportDismissed = true
        XCTAssertFalse(historical.isNewInInbox)
        XCTAssertEqual(historical.state, .needsReview)
        historical.newImportDismissed = false
        historical.state = .sharedDraft
        XCTAssertFalse(historical.isNewInInbox)
        historical.state = .needsReview
        XCTAssertTrue(historical.isNewInInbox)
    }

    @MainActor
    func testSeenFlagSurvivesSavingAndRefreshingMetadata() throws {
        let container = try ModelContainer(for: TransactionRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let record = record()
        container.mainContext.insert(record)
        record.newImportDismissed = true
        try container.mainContext.save()
        let context = ModelContext(container)
        let loaded = try XCTUnwrap(context.fetch(FetchDescriptor<TransactionRecord>()).first)
        XCTAssertNotNil(loaded.inboxReceivedAt)
        XCTAssertTrue(loaded.newImportDismissed)
        loaded.merchant = "Refreshed merchant"
        XCTAssertFalse(loaded.isNewInInbox)
    }

    @MainActor
    func testCompactInboxDimensionsAtStandardTextSize() {
        let transaction = record()
        let summary = UIHostingController(rootView: InboxSummaryCard(transactions: [transaction], filtering: false)
            .environment(\.dynamicTypeSize, .large))
        let summarySize = summary.sizeThatFits(in: CGSize(width: 361, height: 1000))
        // Previous summary measured about 142pt at this width; require at least a 50% reduction.
        XCTAssertLessThanOrEqual(summarySize.height, 71)
        let row = UIHostingController(rootView: TransactionRow(transaction: transaction)
            .environment(\.dynamicTypeSize, .large))
        let rowSize = row.sizeThatFits(in: CGSize(width: 313, height: 1000))
        // Including the new 4pt List insets, keep ordinary rows about 20% below the previous ~92pt.
        XCTAssertLessThanOrEqual(rowSize.height + 4, 75)
    }

    @MainActor
    func testInboxRenderingAcrossAppearanceAndTextSizes() async throws {
        let container = try ModelContainer(for: TransactionRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let session = AppSession()
        session.isAuthenticated = true
        session.isDemoMode = true
        let examples: [(String, Int, ReviewState, String)] = [
            ("Taco Joint", 6840, .needsReview, "FOOD_AND_DRINK"),
            ("United Airlines", 42819, .sharedDraft, "TRAVEL"),
            ("Whole Foods Market", 9732, .personal, "GROCERIES"),
            ("Lyft", 2487, .pending, "TRANSPORTATION")
        ]
        for (index, item) in examples.enumerated() {
            let record = TransactionRecord(source: .plaid, accountName: index.isMultiple(of: 2) ? "Sapphire Preferred" : "Freedom Unlimited",
                accountMask: index.isMultiple(of: 2) ? "4242" : "8811", merchant: item.0,
                date: Date(timeIntervalSince1970: 1788048000 - Double(index * 86_400)), amountMinor: item.1, state: item.2,
                category: item.3, isDemo: true)
            record.city = "Chicago"
            container.mainContext.insert(record)
        }
        let older = TransactionRecord(source: .plaid, accountName: "Sapphire Preferred", accountMask: "4242", merchant: "Mountain Cabin",
            date: Date(timeIntervalSince1970: 1782864000), amountMinor: 61200, isDemo: true)
        older.inboxReceivedAt = nil
        container.mainContext.insert(older)
        try container.mainContext.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let previousGrouping = UserDefaults.standard.string(forKey: "inbox.historyGrouping")
        defer {
            if let previousGrouping { UserDefaults.standard.set(previousGrouping, forKey: "inbox.historyGrouping") }
            else { UserDefaults.standard.removeObject(forKey: "inbox.historyGrouping") }
        }
        for (name, scheme, size, grouping) in [("light", ColorScheme.light, DynamicTypeSize.large, InboxGrouping.month), ("dark", .dark, .large, .month), ("accessibility", .light, .accessibility3, .month), ("year", .light, .large, .year), ("account", .light, .large, .account)] {
            UserDefaults.standard.set(grouping.rawValue, forKey: "inbox.historyGrouping")
            let content = NavigationStack { InboxView() }
                .environment(session).modelContainer(container)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "inbox-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.size.width, 393)
        }
    }

    func testAccountColorsStayStableAcrossFilteringNewCardsAndReloads() throws {
        let first = AccountColors.assignments(for: ["card-b", "card-a"], retaining: [:])
        XCTAssertNotEqual(first["card-a"], first["card-b"])
        XCTAssertEqual(AccountColors.assignments(for: ["card-b"], retaining: first), first)
        let restored = try JSONDecoder().decode([String: Int].self, from: JSONEncoder().encode(first))
        let extended = AccountColors.assignments(for: ["card-c", "card-a", "card-b"], retaining: restored)
        XCTAssertEqual(extended["card-a"], first["card-a"])
        XCTAssertEqual(extended["card-b"], first["card-b"])
        XCTAssertEqual(Set(extended.values).count, 3)
        let many = AccountColors.assignments(for: (0..<30).map { "card-\($0)" }, retaining: extended)
        XCTAssertTrue(many.values.allSatisfy { AccountColors.palette.indices.contains($0) })
    }

    func testAccountColorIdentitySurvivesRenamingAndSeparatesIdenticalLabels() {
        let first = record(), second = record()
        first.accountID = UUID()
        second.accountID = UUID()
        XCTAssertEqual(first.cardLabel, second.cardLabel)
        XCTAssertNotEqual(first.accountColorKey, second.accountColorKey)
        let originalKey = first.accountColorKey
        first.accountName = "My travel card"
        XCTAssertEqual(first.accountColorKey, originalKey)
        let offline = record()
        let oldKey = offline.accountColorKey
        offline.accountMask = "9999"
        XCTAssertNotEqual(offline.accountColorKey, oldKey)
    }

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
        transaction.isCredit = true
        XCTAssertFalse(filters.matches(transaction))
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

    func testInboxAlwaysExcludesCreditsAndGroupsByMonthAndYear() {
        let august = record()
        august.date = Date(timeIntervalSince1970: 1785542400) // August 1, midnight UTC
        let july = record(state: .personal)
        july.date = august.date.addingTimeInterval(-86_400)
        let refund = record()
        refund.isCredit = true
        let lastYear = record()
        lastYear.date = InboxMonth.calendar.date(byAdding: .year, value: -1, to: august.date)!
        var filters = InboxFilters()
        XCTAssertFalse(filters.matches(refund))
        filters = InboxFilters() // Reset must not bring refunds back.
        XCTAssertFalse(filters.matches(refund))
        XCTAssertTrue(filters.matches(july))
        let groups = InboxMonth.group([july, refund, august, lastYear], sort: .newest)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first?.transactions.map(\.id), [august.id])
        XCTAssertEqual(InboxMonth.calendar.component(.month, from: groups[0].id), 8)
        XCTAssertEqual(groups[1].transactions.map(\.id), [july.id])
        XCTAssertEqual(InboxMonth.group([july, august, lastYear], sort: .oldest).first?.transactions.first?.id, lastYear.id)
        XCTAssertFalse(filters.matches(record(amount: 0)))
        XCTAssertFalse(filters.matches(record(amount: -500)))
    }

    func testMonthTotalsSeparateCurrenciesAndExcludePendingAndRefunds() {
        let small = record(amount: 1000), large = record(amount: 2000)
        let euro = record(amount: 800), pending = record(amount: 9000, state: .pending), refund = record(amount: 600)
        euro.currencyCode = "EUR"
        refund.isCredit = true
        let group = InboxMonth.group([small, euro, pending, large, refund], sort: .largest)[0]
        XCTAssertEqual(group.transactions.count, 4)
        XCTAssertEqual(group.transactions.map(\.id), [euro.id, pending.id, large.id, small.id])
        XCTAssertEqual(group.pendingCount, 1)
        XCTAssertEqual(group.reviewCount, 3)
        XCTAssertEqual(group.postedTotals.map(\.currency), ["EUR", "USD"])
        XCTAssertEqual(group.postedTotals.map(\.amount), [8, 30])
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
        XCTAssertEqual(result.0.map(\.isCredit), [false, true])
        XCTAssertEqual(result.0.filter { InboxFilters().matches($0) }.count, 1)
    }

    func testMatchingChargeAndRefundRemainSeparate() throws {
        let data = Data("Date,Description,Debit,Credit\n2026-08-01,Shop,25.00,\n2026-08-01,Shop,,25.00\n".utf8)
        let preview = try CSVImporter.preview(data: data)
        let (records, duplicates) = try CSVImporter.transactions(data: data, mapping: preview.suggestedMapping, fallbackAccount: "Card", knownFingerprints: [])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(duplicates, 0)
        XCTAssertEqual(records.map(\.isCredit), [false, true])
        XCTAssertEqual(records.filter { InboxFilters().matches($0) }.count, 1)
    }

    func testFingerprintNormalizesMerchantPunctuation() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            TransactionFingerprint.make(account: "Card", date: date, amountMinor: 1000, merchant: "CAFÉ NORTH #12"),
            TransactionFingerprint.make(account: "card", date: date, amountMinor: 1000, merchant: "Cafe North 12")
        )
    }
}
