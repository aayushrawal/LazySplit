import SwiftUI

enum AccountColors {
    static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo, .brown, .cyan, .red]

    // Persist assignments rather than using Swift's per-process randomized hash or filtered row order.
    static func assignments(for keys: [String], retaining existing: [String: Int]) -> [String: Int] {
        var result = existing.filter { palette.indices.contains($0.value) }
        for key in Set(keys).sorted() where result[key] == nil {
            let used = Set(result.values)
            let index = palette.indices.first { !used.contains($0) } ?? result.count % palette.count
            result[key] = index
        }
        return result
    }

    static func color(for key: String, in assignments: [String: Int]) -> Color {
        guard let index = assignments[key], palette.indices.contains(index) else { return .indigo }
        return palette[index]
    }
}

enum TransactionClassification {
    static func category(for transaction: TransactionRecord) -> (name: String, inferred: Bool) {
        let raw = transaction.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty && !["OTHER", "GENERAL", "UNKNOWN"].contains(raw.uppercased()) {
            return (title(raw), false)
        }
        let merchant = transaction.merchant.lowercased()
        let rules: [(String, [String])] = [
            ("Groceries", ["grocery", "groceries", "supermarket", "whole foods", "trader joe", "aldi", "kroger"]),
            ("Food And Drink", ["restaurant", "cafe", "café", "coffee", "pizza", "taco", "starbucks", "doordash", "uber eats"]),
            ("Transportation", ["uber", "lyft", "parking", "transit", "toll"]),
            ("Travel", ["airlines", "airways", "hotel", "airbnb", "marriott", "hilton"]),
            ("Entertainment", ["cinema", "theatre", "theater", "netflix", "spotify"]),
            ("Medical", ["pharmacy", "dental", "hospital", "clinic"])
        ]
        if let match = rules.first(where: { $0.1.contains(where: merchant.contains) }) { return (match.0, true) }
        return ("Uncategorized", false)
    }

    static func title(_ raw: String) -> String { raw.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum InboxSort: String, CaseIterable, Identifiable {
    case newest = "Newest first", oldest = "Oldest first", largest = "Largest amount", smallest = "Smallest amount"
    var id: String { rawValue }
}

struct InboxFilters: Equatable {
    var state: ReviewState? = nil
    var excludePersonal = false
    var account: String?
    var category: String?
    var location: String?
    var merchant: String?
    var currency: String?
    var channel: String?
    var source: String?
    var onlyPossibleDuplicates = false
    var minimum = ""
    var maximum = ""
    var useDates = false
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    var endDate = Date.now
    var sort: InboxSort = .newest

    static func amount(_ value: String) -> Decimal? {
        let normalized = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    var validationError: String? {
        if (!minimum.isEmpty && Self.amount(minimum) == nil) || (!maximum.isEmpty && Self.amount(maximum) == nil) {
            return "Enter a positive amount with up to two decimal places (no thousands separators)."
        }
        if let min = Self.amount(minimum), let max = Self.amount(maximum), min > max { return "Minimum amount must not exceed maximum." }
        if useDates && Calendar.current.startOfDay(for: startDate) > Calendar.current.startOfDay(for: endDate) { return "Start date must not be after end date." }
        return nil
    }

    var activeCount: Int {
        [state != nil, excludePersonal, account != nil, category != nil, location != nil, merchant != nil,
         currency != nil, channel != nil, source != nil, onlyPossibleDuplicates,
         !minimum.isEmpty || !maximum.isEmpty, useDates].filter { $0 }.count
    }

    func matches(_ transaction: TransactionRecord, search: String = "") -> Bool {
        guard validationError == nil, !transaction.isCredit, transaction.amountMinor > 0 else { return false }
        if excludePersonal && transaction.state == .personal { return false }
        if let state, transaction.state != state { return false }
        if let account, transaction.cardLabel != account { return false }
        if let category, TransactionClassification.category(for: transaction).name != category { return false }
        if let location, transaction.locationLabel != location { return false }
        if let merchant, transaction.merchant != merchant { return false }
        if let currency, transaction.currencyCode != currency { return false }
        if let channel, (transaction.paymentChannel ?? "unknown") != channel { return false }
        if let source, transaction.source.rawValue != source { return false }
        if onlyPossibleDuplicates && transaction.possibleDuplicateID == nil { return false }
        if let min = Self.amount(minimum), transaction.amount < min { return false }
        if let max = Self.amount(maximum), transaction.amount > max { return false }
        if useDates {
            let day = Calendar.current.startOfDay(for: transaction.date)
            if day < Calendar.current.startOfDay(for: startDate) || day > Calendar.current.startOfDay(for: endDate) { return false }
        }
        let text = [transaction.merchant, transaction.originalDescription, transaction.locationLabel,
                    TransactionClassification.category(for: transaction).name, transaction.categoryDetail ?? ""].joined(separator: " ")
        return search.isEmpty || text.localizedStandardContains(search)
    }

    func ordered(_ records: [TransactionRecord]) -> [TransactionRecord] {
        records.sorted {
            switch sort {
            case .newest: return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
            case .oldest: return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            case .largest, .smallest:
                if $0.currencyCode != $1.currencyCode { return $0.currencyCode < $1.currencyCode }
                if $0.amountMinor == $1.amountMinor { return $0.id.uuidString < $1.id.uuidString }
                return sort == .largest ? $0.amountMinor > $1.amountMinor : $0.amountMinor < $1.amountMinor
            }
        }
    }
}

struct InboxFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: InboxFilters
    let transactions: [TransactionRecord]

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    Picker("Status", selection: $filters.state) {
                        Text("All statuses").tag(ReviewState?.none)
                        ForEach(ReviewState.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    .onChange(of: filters.state) { _, state in if state == .personal { filters.excludePersonal = false } }
                    Toggle("Hide personal transactions", isOn: $filters.excludePersonal)
                        .onChange(of: filters.excludePersonal) { _, hide in if hide && filters.state == .personal { filters.state = nil } }
                    Toggle("Possible duplicates only", isOn: $filters.onlyPossibleDuplicates)
                }
                Section {
                    optionPicker("Currency", selection: $filters.currency, values: transactions.map(\.currencyCode))
                    TextField("Minimum amount", text: $filters.minimum).keyboardType(.decimalPad)
                    TextField("Maximum amount", text: $filters.maximum).keyboardType(.decimalPad)
                } header: { Text("Amount") } footer: {
                    Text("Inbox shows charges only; credits and refunds are excluded. Amounts stay in their original currency with no conversion.")
                }
                Section("Dates") {
                    Toggle("Limit date range", isOn: $filters.useDates)
                    if filters.useDates {
                        DatePicker("From", selection: $filters.startDate, displayedComponents: .date)
                        DatePicker("Through", selection: $filters.endDate, displayedComponents: .date)
                        Button("Last 30 days") {
                            filters.startDate = Calendar.current.date(byAdding: .day, value: -29, to: .now)!
                            filters.endDate = .now
                        }
                        Button("This year") {
                            filters.startDate = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: .now))!
                            filters.endDate = .now
                        }
                    }
                }
                Section {
                    optionPicker("Card / account", selection: $filters.account, values: transactions.map(\.cardLabel))
                    optionPicker("Merchant", selection: $filters.merchant, values: transactions.map(\.merchant))
                    optionPicker("Category", selection: $filters.category, values: transactions.map { TransactionClassification.category(for: $0).name })
                    optionPicker("Location", selection: $filters.location, values: transactions.map(\.locationLabel))
                    optionPicker("Payment channel", selection: $filters.channel, values: transactions.map { $0.paymentChannel ?? "unknown" })
                    optionPicker("Source", selection: $filters.source, values: transactions.map { $0.source.rawValue })
                } header: { Text("Classification") } footer: {
                    Text("Categories prefer Plaid’s classification, with labeled name-based suggestions when missing. Locations come from the bank, not your phone’s GPS. Unknown means no location was supplied.")
                }
                Section {
                    Picker("Sort", selection: $filters.sort) { ForEach(InboxSort.allCases) { Text($0.rawValue).tag($0) } }
                } footer: { Text("Choose month, year, or card grouping under View. Sorting applies within each history group, with currencies kept separate. New stays ordered by arrival.") }
                if let error = filters.validationError { Text(error).foregroundStyle(.red) }
                Button("Reset filters") { filters = InboxFilters() }
            }
            .navigationTitle("Inbox filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(filters.validationError != nil) } }
        }
    }

    private func optionPicker(_ title: String, selection: Binding<String?>, values: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("All").tag(String?.none)
            ForEach(Array(Set(values)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
        }
    }
}
