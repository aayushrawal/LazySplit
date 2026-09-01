import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CryptoKit

struct StatementAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var mask: String
    var currencyCode: String
    var label: String { mask.isEmpty ? name : "\(name) • \(mask)" }
    static let currencies = ["USD", "CAD", "EUR", "GBP", "AUD", "INR", "SGD", "CHF"]
}

enum StatementPeriodKind: String, CaseIterable, Identifiable, Sendable {
    case monthly, yearly
    var id: Self { self }
    var title: String { self == .monthly ? "Monthly" : "Yearly" }
}

struct StatementPeriodInference: Sendable, Equatable {
    let kind: StatementPeriodKind
    let endingOn: Date
    let message: String

    static func infer(filename: String, referenceDate: Date = .now) -> Self {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let base = (filename as NSString).deletingPathExtension
        let currentYear = calendar.component(.year, from: referenceDate)
        // The filename is authoritative when it contains a period; modification dates can be stale after downloads or restores.
        let validYears = 2000...2100
        let monthPattern = #"(?i)\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b(?:[\s._-]+(20\d{2}))?"#
        if let regex = try? NSRegularExpression(pattern: monthPattern), let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let monthRange = Range(match.range(at: 1), in: base) {
            let names = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
            let monthText = String(base[monthRange]); let month = names[monthText.prefix(3).lowercased()]!
            var year = currentYear; var yearWasInName = false
            if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: base), let parsed = Int(base[range]), validYears.contains(parsed) { year = parsed; yearWasInName = true }
            let end = endOfMonth(year: year, month: month, calendar: calendar)
            let label = monthLabel(end)
            return Self(kind: .monthly, endingOn: end, message: yearWasInName ? "Inferred \(label) from the filename. Confirm it before importing." : "Inferred \(monthText) from the filename and used \(year) from the file date. Confirm the year before importing.")
        }
        let numericMonthPattern = #"(?<!\d)(20\d{2})[._-](0?[1-9]|1[0-2])(?!\d)"#
        if let match = firstMatch(numericMonthPattern, in: base), let year = capturedInt(1, match: match, in: base), let month = capturedInt(2, match: match, in: base), validYears.contains(year) {
            let end = endOfMonth(year: year, month: month, calendar: calendar)
            let label = monthLabel(end)
            return Self(kind: .monthly, endingOn: end, message: "Inferred \(label) from the filename. Confirm it before importing.")
        }
        let reverseMonthPattern = #"(?<!\d)(0?[1-9]|1[0-2])[._-](20\d{2})(?!\d)"#
        if let match = firstMatch(reverseMonthPattern, in: base), let month = capturedInt(1, match: match, in: base), let year = capturedInt(2, match: match, in: base), validYears.contains(year) {
            let end = endOfMonth(year: year, month: month, calendar: calendar)
            let label = monthLabel(end)
            return Self(kind: .monthly, endingOn: end, message: "Inferred \(label) from the filename. Confirm it before importing.")
        }
        let annualPattern = #"(?i)(?:\b(?:annual|yearly|year)\b.*?\b(20\d{2})\b|\b(20\d{2})\b.*?\b(?:annual|yearly|year)\b)"#
        if let match = firstMatch(annualPattern, in: base), let year = capturedInt(match.range(at: 1).location == NSNotFound ? 2 : 1, match: match, in: base), validYears.contains(year) {
            return Self(kind: .yearly, endingOn: date(year: year, month: 12, day: 31, calendar: calendar), message: "Inferred annual statement for \(year) from the filename. Confirm it before importing.")
        }
        if let match = firstMatch(#"^\s*(20\d{2})\s*$"#, in: base), let year = capturedInt(1, match: match, in: base), validYears.contains(year) {
            return Self(kind: .yearly, endingOn: date(year: year, month: 12, day: 31, calendar: calendar), message: "Inferred annual statement for \(year) from the filename. Confirm it before importing.")
        }
        return Self(kind: .monthly, endingOn: referenceDate, message: "No statement period was found in the filename. Choose the month or switch to Yearly before importing.")
    }

    static func normalized(_ date: Date, for kind: StatementPeriodKind) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let year = calendar.component(.year, from: date)
        return kind == .yearly ? self.date(year: year, month: 12, day: 31, calendar: calendar) : endOfMonth(year: year, month: calendar.component(.month, from: date), calendar: calendar)
    }

    private static func firstMatch(_ pattern: String, in value: String) -> NSTextCheckingResult? { try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) }
    private static func capturedInt(_ index: Int, match: NSTextCheckingResult, in value: String) -> Int? { Range(match.range(at: index), in: value).flatMap { Int(value[$0]) } }
    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    private static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    private static func endOfMonth(year: Int, month: Int, calendar: Calendar) -> Date {
        let start = date(year: year, month: month, day: 1, calendar: calendar)
        return calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
    }
}

struct StagedStatement: Identifiable {
    let id = UUID()
    var name: String
    var accountID: UUID?
    var endingOn = Date.now
    var periodKind: StatementPeriodKind = .monthly
    var periodInference = "Choose the statement month before importing."
    var rows: [PDFStatementRow] = []
    var pdf: PDFStatementPreview?
    var csvData: Data?
    var csvPreview: CSVPreview?
    var mapping: CSVMapping?
    var warning: String?
    var error: String?
    var reviewed = false
    var byteCount = 0

    @MainActor mutating func previewCSV() {
        reviewed = false; rows = []; error = nil
        guard let csvData, var mapping else { return }
        // The account is selected explicitly, never taken from an arbitrary statement column.
        mapping.accountColumn = nil
        do {
            let (records, duplicates) = try CSVImporter.transactions(data: csvData, mapping: mapping, fallbackAccount: "Preview", knownFingerprints: [])
            rows = records.map { record in
                PDFStatementRow(rawDate: record.date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, timeZone: .gmt)), originalLine: record.originalDescription, page: 1, merchant: record.merchant,
                    amountText: NSDecimalNumber(decimal: record.amount).stringValue, isCredit: record.isCredit, editedDate: record.date,
                    currencyCode: mapping.currencyColumn == nil ? nil : record.currencyCode)
            }
            let text = String(data: csvData, encoding: .utf8) ?? String(data: csvData, encoding: .isoLatin1) ?? ""
            let count = CSVImporter.parse(text).dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.count
            warning = "\(records.count) transactions recognized; \(duplicates) exact duplicate rows skipped; \(max(0, count - records.count - duplicates)) rows could not be read. Check the mapping and compare the full preview with your statement."
        } catch { self.error = error.localizedDescription }
    }
}

enum StatementBatch {
    static func fingerprint(account: UUID, date: Date, minor: Int, merchant: String) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .gmt, formatOptions: [.withFullDate])
        let normalized = merchant.decomposedStringWithCompatibilityMapping.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression).lowercased()
        return SHA256.hash(data: Data("\(account.uuidString.lowercased())|\(day)|\(minor)|\(normalized)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(_ files: [StagedStatement], accounts: [StatementAccount]) throws -> (values: [ImportedTransaction], duplicates: Int) {
        guard !files.isEmpty, files.count <= 20 else { throw StatementUploadError.invalidBatch }
        var values: [ImportedTransaction] = [], seen = Set<String>(), duplicates = 0
        for file in files {
            guard file.reviewed, file.error == nil, let account = accounts.first(where: { $0.id == file.accountID }), !file.rows.filter(\.included).isEmpty else { throw StatementUploadError.reviewRequired }
            for row in file.rows where row.included {
                guard let date = row.date(endingOn: file.endingOn), let minor = PDFStatementImporter.minorUnits(row.amountText), !row.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFStatementError.invalidSelection }
                guard row.currencyCode == nil || row.currencyCode == account.currencyCode else { throw StatementUploadError.currencyMismatch }
                let fingerprint = fingerprint(account: account.id, date: date, minor: minor, merchant: row.merchant)
                let key = fingerprint + (row.isCredit ? ":credit" : ":charge")
                guard seen.insert(key).inserted else { duplicates += 1; continue }
                values.append(ImportedTransaction(id: row.id, accountName: account.name, accountMask: account.mask, merchant: row.merchant, originalDescription: row.merchant, date: date,
                    amountMinor: minor, currencyCode: account.currencyCode, fingerprint: fingerprint, isCredit: row.isCredit, accountID: account.id))
            }
        }
        guard !values.isEmpty, values.count <= 1000 else { throw StatementUploadError.invalidBatch }
        return (values, duplicates)
    }
}

enum StatementUploadError: LocalizedError {
    case invalidBatch, reviewRequired, currencyMismatch, batchTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidBatch: "Choose up to 20 files and 1,000 transactions per batch."
        case .reviewRequired: "Open and review every statement, choose its account, and fix or remove failed files before importing."
        case .currencyMismatch: "A transaction currency differs from its account. Choose an account with the matching currency or exclude that transaction."
        case .batchTooLarge: "A batch can contain up to 50 MB of statements. Start another upload for the remaining files."
        }
    }
}

// Retains the existing entry-point name; CSV and PDF now share one staged review workflow.
struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @State private var accounts: [StatementAccount] = []
    @State private var defaultAccountID: UUID?
    @State private var files: [StagedStatement] = []
    @State private var picker = false
    @State private var bulk = false
    @State private var manualAccount = false
    @State private var loading = false
    @State private var progress = ""
    @State private var message: String?
    @State private var confirming = false
    @State private var importing = false
    @State private var pending: PendingStatementUpload?
    let initialAccount: StatementAccount?

    init(account: StatementAccount? = nil, pdf: PDFStatementPreview? = nil) {
        initialAccount = account
        _defaultAccountID = State(initialValue: account?.id)
        if let pdf { _files = State(initialValue: [StagedStatement(name: "PDF statement", accountID: account?.id, rows: pdf.rows, pdf: pdf)]) }
    }

    private var prepared: (values: [ImportedTransaction], duplicates: Int)? { try? StatementBatch.prepare(files, accounts: accounts) }

    var body: some View {
        List {
            Group {
                Section {
                    Picker("Default account for new files", selection: $defaultAccountID) {
                        Text("Choose an account").tag(UUID?.none)
                        ForEach(accounts) { Text("\($0.label) · \($0.currencyCode)").tag(Optional($0.id)) }
                    }
                    Button { manualAccount = true } label: { Label("Add account manually", systemImage: "creditcard.badge.plus") }
                } header: { Text("Destination account") } footer: { Text("For Apple Card or another card without a bank connection, add a manual account. You can change the destination for each statement in its preview.") }
                Section {
                    Button { bulk = false; picker = true } label: { Label("Upload one statement", systemImage: "doc.badge.plus") }
                    Button { bulk = true; picker = true } label: { Label("Bulk upload statements", systemImage: "doc.on.doc") }
                    if loading { ProgressView(progress) }
                } header: { Text("Upload statements") } footer: { Text("CSV and PDF • up to 20 files / 50 MB per batch. Files are read on-device; nothing is added until you approve the batch.") }
                if !files.isEmpty {
                    Section {
                        ForEach($files) { $file in
                            NavigationLink {
                                StatementFileReview(file: $file, accounts: accounts)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name).lineLimit(2)
                                    Text(accounts.first { $0.id == file.accountID }?.label ?? "Choose an account").font(.caption).foregroundStyle(.secondary)
                                    Label(file.error != nil ? "Needs attention" : file.reviewed ? "Reviewed · \(file.rows.filter(\.included).count) selected" : "Tap to preview \(file.rows.count) transactions", systemImage: file.error != nil ? "exclamationmark.triangle" : file.reviewed ? "checkmark.circle.fill" : "eye")
                                        .font(.caption).foregroundStyle(file.error != nil ? .orange : file.reviewed ? .green : .secondary)
                                }
                            }
                        }.onDelete { files.remove(atOffsets: $0) }
                    } header: { Text("Preview before adding") } footer: { Text("Open every file to check dates, amounts, payments/refunds, and currency. Swipe to remove a file from this batch. This does not delete your original file.") }
                }
            }.disabled(loading || importing || pending != nil)
            if !files.isEmpty {
                Section {
                    if let prepared {
                        Text("\(prepared.values.count) transactions ready · \(prepared.duplicates) duplicate rows within this batch skipped")
                    }
                    if pending != nil {
                        Button("Retry approved upload") { Task { await submit() } }.disabled(importing)
                    } else {
                        Button("Add reviewed transactions") { confirming = true }.disabled(prepared == nil || loading || importing)
                    }
                    if importing { ProgressView("Adding reviewed transactions…") }
                } footer: { Text("This adds transactions to LazySplit only. Publishing to Splitwise is a separate approval.") }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Upload statements").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(importing) } }
        .interactiveDismissDisabled(importing)
        .confirmationDialog("Add \(prepared?.values.count ?? 0) reviewed transactions to LazySplit?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Add transactions") {
                guard let prepared else { return }
                pending = PendingStatementUpload(key: UUID().uuidString, values: prepared.values, duplicates: prepared.duplicates)
                Task { await submit() }
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.commaSeparatedText, .plainText, .pdf], allowsMultipleSelection: bulk) { result in
            switch result {
            case .success(let urls): Task { await load(urls) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .sheet(isPresented: $manualAccount) {
            NavigationStack { ManualAccountView { account in
                if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
                defaultAccountID = account.id
            } }
        }
        .task {
            if session.isDemoMode { accounts = session.demoAccounts }
            else {
                do { accounts = try await session.api.connections().accounts.map { StatementAccount(id: $0.id, name: $0.name, mask: $0.mask, currencyCode: $0.currencyCode) } }
                catch { message = error.localizedDescription }
            }
            if let initialAccount, !accounts.contains(where: { $0.id == initialAccount.id }) { accounts.append(initialAccount) }
        }
    }

    @MainActor private func load(_ urls: [URL]) async {
        guard files.count + urls.count <= 20 else { message = StatementUploadError.invalidBatch.localizedDescription; return }
        loading = true; message = nil; defer { loading = false }
        for (index, url) in urls.enumerated() {
            progress = "Reading file \(index + 1) of \(urls.count)…"
            var file = StagedStatement(name: url.lastPathComponent, accountID: defaultAccountID)
            do {
                let remaining = 50 * 1024 * 1024 - files.reduce(0) { $0 + $1.byteCount }
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let bytes = values.fileSize ?? 0
                    guard bytes <= PDFStatementImporter.maxBytes else { throw PDFStatementError.tooLarge }
                    guard bytes <= remaining else { throw StatementUploadError.batchTooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= remaining, data.count <= PDFStatementImporter.maxBytes else { throw StatementUploadError.batchTooLarge }
                    if url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF-".utf8)) {
                        return LoadedStatement(bytes: data.count, modifiedAt: values.contentModificationDate, pdf: try PDFStatementImporter.preview(data: data), csv: nil)
                    }
                    return LoadedStatement(bytes: data.count, modifiedAt: values.contentModificationDate, pdf: nil, csv: data)
                }.value
                file.byteCount = loaded.bytes
                if let pdf = loaded.pdf {
                    let inference = StatementPeriodInference.infer(filename: file.name, referenceDate: loaded.modifiedAt ?? .now)
                    file.periodKind = inference.kind; file.endingOn = inference.endingOn; file.periodInference = inference.message
                    file.pdf = pdf; file.rows = pdf.rows
                }
                else if let csv = loaded.csv {
                    file.csvData = csv
                    file.csvPreview = try CSVImporter.preview(data: csv)
                    file.mapping = file.csvPreview?.suggestedMapping
                    file.previewCSV()
                }
            } catch { file.error = error.localizedDescription }
            files.append(file)
        }
    }

    @MainActor private func submit() async {
        guard let pending, !importing else { return }
        importing = true; defer { importing = false }
        do {
            let result: ImportResponse
            if session.isDemoMode {
                let existing = try modelContext.fetch(FetchDescriptor<TransactionRecord>()).filter(\.isDemo)
                var seen = Set(existing.map { $0.fingerprint + ($0.isCredit ? ":credit" : ":charge") })
                var inserted = 0
                for item in pending.values where seen.insert(item.fingerprint + (item.isCredit ? ":credit" : ":charge")).inserted {
                    let record = TransactionRecord(id: item.id, source: .csv, accountName: item.accountName, accountMask: item.accountMask, merchant: item.merchant, date: item.date, amountMinor: item.amountMinor, currencyCode: item.currencyCode, fingerprint: item.fingerprint, isDemo: true)
                    record.accountID = item.accountID; record.isCredit = item.isCredit; modelContext.insert(record); inserted += 1
                }
                try modelContext.save()
                result = ImportResponse(inserted: inserted, duplicates: pending.values.count - inserted)
            } else {
                // Server-first: a preview/cancel/failure never creates orphaned local transactions.
                result = try await session.api.importTransactions(pending.values, idempotencyKey: pending.key)
                await session.refreshTransactions(in: modelContext)
            }
            message = "Added \(result.inserted) transactions; skipped \(result.duplicates + pending.duplicates) exact duplicates."
            if let error = session.transactionRefreshError { message! += " \(error) Refresh the inbox to download the saved transactions." }
            files = []; self.pending = nil
        } catch { message = "Upload did not confirm completion: \(error.localizedDescription) Retry uses the same approved batch to prevent duplicates." }
    }
}

private struct LoadedStatement: Sendable { let bytes: Int; let modifiedAt: Date?; let pdf: PDFStatementPreview?; let csv: Data? }
private struct PendingStatementUpload { let key: String; let values: [ImportedTransaction]; let duplicates: Int }

struct StatementFileReview: View {
    @Binding var file: StagedStatement
    let accounts: [StatementAccount]
    var body: some View {
        Form {
            Section("Statement") {
                Text(file.name)
                Picker("Account", selection: $file.accountID) {
                    Text("Choose account").tag(UUID?.none)
                    ForEach(accounts) { Text("\($0.label) · \($0.currencyCode)").tag(Optional($0.id)) }
                }
                if file.pdf != nil {
                    Picker("Statement type", selection: $file.periodKind) { ForEach(StatementPeriodKind.allCases) { Text($0.title).tag($0) } }
                    if file.periodKind == .monthly {
                        DatePicker("Statement month", selection: $file.endingOn, displayedComponents: .date).environment(\.timeZone, .gmt)
                    } else {
                        Picker("Statement year", selection: statementYear) { ForEach(statementYears, id: \.self) { Text(String($0)).tag($0) } }
                    }
                    Text(file.periodInference).font(.caption).foregroundStyle(.secondary)
                    Text("The confirmed period supplies missing years in transaction dates. Numeric dates use month/day order.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let preview = file.csvPreview, file.mapping != nil {
                Section("CSV column mapping") {
                    Picker("Date", selection: map(\.dateColumn)) { ForEach(preview.headers, id: \.self) { Text($0).tag($0) } }
                    Picker("Description", selection: map(\.descriptionColumn)) { ForEach(preview.headers, id: \.self) { Text($0).tag($0) } }
                    Picker("Amount", selection: optionalMap(\.amountColumn)) { Text("Debit / credit columns").tag(String?.none); ForEach(preview.headers, id: \.self) { Text($0).tag(Optional($0)) } }
                    if file.mapping?.amountColumn == nil {
                        Picker("Debit", selection: optionalMap(\.debitColumn)) { Text("None").tag(String?.none); ForEach(preview.headers, id: \.self) { Text($0).tag(Optional($0)) } }
                        Picker("Credit", selection: optionalMap(\.creditColumn)) { Text("None").tag(String?.none); ForEach(preview.headers, id: \.self) { Text($0).tag(Optional($0)) } }
                    }
                    Picker("Currency", selection: optionalMap(\.currencyColumn)) { Text("Use account currency").tag(String?.none); ForEach(preview.headers, id: \.self) { Text($0).tag(Optional($0)) } }
                    Button("Apply mapping and rebuild preview") { file.previewCSV() }
                }
            }
            if let error = file.error { Section { Text(error).foregroundStyle(.red) } }
            if let warning = file.warning { Section { Text(warning).font(.caption).foregroundStyle(.secondary) } }
            if let pdf = file.pdf {
                Section {
                    Text("\(pdf.rows.count) rows found on \(pdf.pageCount) pages. \(pdf.scannedPages) pages used text recognition. Compare against your PDF; extraction may miss transactions or misread amounts.")
                    if pdf.excludedRows > 0 { Text("Excluded \(pdf.excludedRows) payment, deposit, or installment row(s). These are not purchase transactions.").foregroundStyle(.secondary) }
                    if pdf.unmatchedDatedLines > 0 || pdf.pagesWithoutRows > 0 { Text("\(pdf.unmatchedDatedLines) dated lines could not be parsed. \(pdf.pagesWithoutRows) pages had no recognized transactions. Use CSV for unsupported layouts.").foregroundStyle(.orange) }
                }.font(.caption)
            }
            Section("All transactions · \(file.rows.count)") {
                ForEach($file.rows) { $row in
                    DisclosureGroup {
                        TextField("Description", text: $row.merchant)
                        DatePicker("Date", selection: Binding(get: { row.date(endingOn: file.endingOn) ?? file.endingOn }, set: { row.editedDate = $0 }), displayedComponents: .date).environment(\.timeZone, .gmt)
                        TextField("Positive amount", text: $row.amountText).keyboardType(.decimalPad)
                        Toggle("Payment, refund, or credit", isOn: $row.isCredit)
                        Toggle("Include in import", isOn: $row.included)
                        if row.date(endingOn: file.endingOn) == nil { Text("Choose a valid date.").foregroundStyle(.red) }
                        if let currency = row.currencyCode { Text("Statement currency: \(currency)").font(.caption) }
                        if file.pdf != nil { Text("Page \(row.page): \(row.originalLine)").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.merchant)
                            Text("\(row.date(endingOn: file.endingOn).map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)) } ?? row.rawDate) · \(row.amountText)\(row.isCredit ? " credit" : "")\(row.included ? "" : " · excluded")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Toggle("I checked the account, dates, currency, amounts, and credits", isOn: $file.reviewed)
                    .disabled(file.error != nil || file.accountID == nil || file.rows.filter(\.included).isEmpty)
                if file.reviewed {
                    if let error = validationError { Text(error).foregroundStyle(.red) }
                    else { Label("Ready. Go back to approve the batch.", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
            } footer: { Text("Nothing on this screen is saved as a transaction until you approve the batch on the previous screen.") }
        }
        .navigationTitle("Preview transactions").navigationBarTitleDisplayMode(.inline)
        .onChange(of: file.accountID) { _, _ in file.reviewed = false }
        .onChange(of: file.periodKind) { _, kind in file.endingOn = StatementPeriodInference.normalized(file.endingOn, for: kind); file.reviewed = false }
        .onChange(of: file.endingOn) { _, _ in file.reviewed = false }
        .onChange(of: file.rows) { _, _ in file.reviewed = false }
        .onChange(of: file.mapping) { _, _ in file.reviewed = false; file.rows = []; file.error = "Apply the new mapping to preview transactions." }
    }
    private var validationError: String? {
        do { _ = try StatementBatch.prepare([file], accounts: accounts); return nil } catch { return error.localizedDescription }
    }
    private var statementYears: [Int] { let current = Calendar(identifier: .gregorian).component(.year, from: .now); return Array(stride(from: current + 1, through: 2000, by: -1)) }
    private var statementYear: Binding<Int> {
        Binding(get: { Calendar(identifier: .gregorian).component(.year, from: file.endingOn) }, set: { year in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
            file.endingOn = calendar.date(from: DateComponents(year: year, month: 12, day: 31))!
        })
    }
    private func map(_ key: WritableKeyPath<CSVMapping, String>) -> Binding<String> { Binding(get: { file.mapping?[keyPath: key] ?? "" }, set: { file.mapping?[keyPath: key] = $0 }) }
    private func optionalMap(_ key: WritableKeyPath<CSVMapping, String?>) -> Binding<String?> { Binding(get: { file.mapping?[keyPath: key] }, set: { file.mapping?[keyPath: key] = $0 }) }
}

struct ManualAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    let onCreated: (StatementAccount) -> Void
    @State private var name = ""
    @State private var mask = ""
    @State private var currency = "USD"
    @State private var saving = false
    @State private var message: String?
    @State private var accountID = UUID()
    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Apple Card", text: $name)
                TextField("Last four digits (optional)", text: $mask).keyboardType(.numberPad)
                Picker("Currency", selection: $currency) { ForEach(StatementAccount.currencies, id: \.self) { Text($0).tag($0) } }
            } header: { Text("Card or account") } footer: { Text("This creates a statement-only account, without Plaid. Upload PDFs or CSVs to add its history. Do not enter your full card number.") }
            if let message { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("Add manual account").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || (!mask.isEmpty && (mask.count != 4 || mask.range(of: "^[0-9]{4}$", options: .regularExpression) == nil)))
            }
        }.interactiveDismissDisabled(saving)
    }
    @MainActor private func save() async {
        saving = true; defer { saving = false }
        let proposed = StatementAccount(id: accountID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), mask: mask, currencyCode: currency)
        do {
            let account: StatementAccount
            if session.isDemoMode {
                account = session.demoAccounts.first { $0.name == proposed.name && $0.mask == proposed.mask && $0.currencyCode == proposed.currencyCode } ?? proposed
                if !session.demoAccounts.contains(where: { $0.id == account.id }) { session.demoAccounts.append(account) }
            } else { account = try await session.api.createManualAccount(proposed) }
            onCreated(account); dismiss()
        } catch { message = error.localizedDescription }
    }
}
