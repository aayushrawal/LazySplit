import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(LinkKit)
import LinkKit
#endif

struct CoverageView: View {
    @Query(sort: \TransactionRecord.date) private var transactions: [TransactionRecord]
    @State private var showingImporter = false

    private var accounts: [String] { Array(Set(transactions.map(\.accountName))).sorted() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Plaid can return up to 24 months. Import statements to fill older or institution-specific gaps.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                ForEach(accounts, id: \.self) { account in CoverageCard(account: account, transactions: transactions.filter { $0.accountName == account }) }
                if accounts.isEmpty { ContentUnavailableView("No card history", systemImage: "creditcard", description: Text("Connect a card or import a statement.")) }
            }.padding(.vertical)
        }
        .navigationTitle("Coverage")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") } } }
        .sheet(isPresented: $showingImporter) { NavigationStack { CSVImportView() } }
    }
}

private struct CoverageCard: View {
    let account: String
    let transactions: [TransactionRecord]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 12)
    private var months: [CoverageMonth] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .month, value: -35, to: calendar.date(from: calendar.dateComponents([.year, .month], from: .now))!)!
        return (0..<36).map { offset in
            let date = calendar.date(byAdding: .month, value: offset, to: start)!
            let inMonth = transactions.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
            let source: TransactionSource? = inMonth.contains(where: { $0.source == .csv }) ? .csv : inMonth.first?.source
            return CoverageMonth(date: date, source: source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "creditcard.fill").foregroundStyle(.indigo); Text(account).font(.headline); Spacer(); Text("\(transactions.count) charges").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(months) { month in
                    RoundedRectangle(cornerRadius: 3).fill(color(month.source)).frame(height: 24).accessibilityLabel("\(month.date.formatted(.dateTime.month().year())): \(month.source?.rawValue ?? "missing")")
                }
            }
            HStack(spacing: 14) {
                Label("Plaid", systemImage: "square.fill").foregroundStyle(.indigo)
                Label("Statement", systemImage: "square.fill").foregroundStyle(.cyan)
                Label("Gap", systemImage: "square.fill").foregroundStyle(.gray.opacity(0.3))
            }.font(.caption)
        }.padding().background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18)).padding(.horizontal)
    }
    private func color(_ source: TransactionSource?) -> Color { source == .plaid ? .indigo : source == .csv ? .cyan : .gray.opacity(0.18) }
}

struct CSVImportView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(AppSession.self) private var session
    @Query private var existing: [TransactionRecord]
    @State private var showingPicker = false
    @State private var fileName = ""
    @State private var data: Data?
    @State private var preview: CSVPreview?
    @State private var mapping: CSVMapping?
    @State private var fallbackAccount = "Imported card"
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button { showingPicker = true } label: { Label(fileName.isEmpty ? "Choose CSV statement" : fileName, systemImage: "doc.text") }
            }
            if let preview, let mapping {
                Section("Column mapping") {
                    Picker("Date", selection: binding(\.dateColumn, mapping)) { ForEach(preview.headers, id: \.self) { Text($0).tag($0) } }
                    Picker("Description", selection: binding(\.descriptionColumn, mapping)) { ForEach(preview.headers, id: \.self) { Text($0).tag($0) } }
                    Picker("Amount", selection: bindingOptional(\.amountColumn, mapping)) { Text("Use debit / credit").tag(String?.none); ForEach(preview.headers, id: \.self) { Text($0).tag(String?.some($0)) } }
                    TextField("Account name", text: $fallbackAccount)
                }
                Section("Preview") {
                    ForEach(Array(preview.rows.prefix(4).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading) { Text(row[mapping.descriptionColumn] ?? "—"); Text(row[mapping.dateColumn] ?? "—").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Button("Import transactions") { importRows() }.frame(maxWidth: .infinity)
                }
            }
            if let message { Section { Text(message) } }
        }
        .navigationTitle("Import statement").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get(); guard url.startAccessingSecurityScopedResource() else { throw CSVImportError.unreadable }
                defer { url.stopAccessingSecurityScopedResource() }
                let loaded = try Data(contentsOf: url); let parsed = try CSVImporter.preview(data: loaded)
                data = loaded; preview = parsed; mapping = parsed.suggestedMapping; fileName = url.lastPathComponent; message = nil
            } catch { message = error.localizedDescription }
        }
    }

    private func binding(_ path: WritableKeyPath<CSVMapping, String>, _ fallback: CSVMapping) -> Binding<String> {
        Binding(get: { mapping?[keyPath: path] ?? fallback[keyPath: path] }, set: { mapping?[keyPath: path] = $0 })
    }
    private func bindingOptional(_ path: WritableKeyPath<CSVMapping, String?>, _ fallback: CSVMapping) -> Binding<String?> {
        Binding(get: { mapping?[keyPath: path] ?? fallback[keyPath: path] }, set: { mapping?[keyPath: path] = $0 })
    }
    private func importRows() {
        guard let data, let mapping else { return }
        do {
            let (records, duplicates) = try CSVImporter.transactions(data: data, mapping: mapping, fallbackAccount: fallbackAccount, knownFingerprints: Set(existing.map(\.fingerprint)))
            records.forEach(modelContext.insert)
            let key = UUID().uuidString
            modelContext.insert(ImportBatch(fileName: fileName, rowCount: records.count, duplicateCount: duplicates, issuerKey: fallbackAccount))
            try modelContext.save(); message = "Imported \(records.count) transactions and skipped \(duplicates) duplicates."
            if KeychainStore.read("sessionToken") != nil {
                let values = records.map { ImportedTransaction(id: $0.id, accountName: $0.accountName, accountMask: $0.accountMask, merchant: $0.merchant, originalDescription: $0.originalDescription, date: $0.date, amountMinor: $0.amountMinor, currencyCode: $0.currencyCode, fingerprint: $0.fingerprint) }
                Task {
                    do { let result = try await session.api.importTransactions(values, idempotencyKey: key); message = "Imported \(result.inserted) transactions and skipped \(duplicates + result.duplicates) duplicates." }
                    catch { message = "Saved on this iPhone. Server sync will retry later: \(error.localizedDescription)" }
                }
            }
        } catch { message = error.localizedDescription }
    }
}

struct OutboxView: View {
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(AppSession.self) private var session
    @Query(sort: \ExportAttempt.attemptedAt, order: .reverse) private var attempts: [ExportAttempt]
    @Query private var drafts: [SplitDraft]
    @Query private var transactions: [TransactionRecord]
    @State private var publishing = false

    var body: some View {
        List {
            if attempts.isEmpty { ContentUnavailableView("Outbox is empty", systemImage: "paperplane", description: Text("Approved splits appear here before publishing.")) }
            ForEach(attempts) { attempt in
                let transaction = transaction(for: attempt)
                HStack {
                    Image(systemName: symbol(attempt.status)).foregroundStyle(color(attempt.status))
                    VStack(alignment: .leading) { Text(transaction?.merchant ?? "Expense"); Text(attempt.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let transaction { Text(transaction.amount, format: .currency(code: transaction.currencyCode)).monospacedDigit() }
                }
            }
        }
        .navigationTitle("Outbox")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Publish all") { Task { await publishAll() } }.disabled(publishing || !attempts.contains(where: { $0.status == "queued" || $0.status == "failed" }))
            }
        }
        .overlay { if publishing { ProgressView("Publishing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
    }

    private func transaction(for attempt: ExportAttempt) -> TransactionRecord? {
        guard let draft = drafts.first(where: { $0.id == attempt.draftID }) else { return nil }
        return transactions.first { $0.id == draft.transactionID }
    }
    private func publishAll() async {
        publishing = true; defer { publishing = false }
        for attempt in attempts.filter({ $0.status == "queued" || $0.status == "failed" }) {
            guard let draft = drafts.first(where: { $0.id == attempt.draftID }), let transaction = transactions.first(where: { $0.id == draft.transactionID }) else { continue }
            let body = PublishBody(draftID: draft.id, transactionID: transaction.id, merchant: transaction.merchant, date: transaction.date, amountMinor: transaction.amountMinor, currencyCode: transaction.currencyCode, groupID: draft.splitwiseGroupID, participants: draft.participants.map { PublishParticipant(userID: $0.splitwiseUserID, owedMinor: $0.owedMinor, paidMinor: $0.paidMinor) })
            attempt.status = "publishing"; try? modelContext.save()
            do {
                attempt.splitwiseExpenseID = try await session.api.publish(body)
                attempt.status = "published"; attempt.errorMessage = nil; transaction.state = .published
            } catch {
                attempt.status = "failed"; attempt.errorMessage = error.localizedDescription; transaction.state = .failed
            }
            attempt.attemptedAt = .now; try? modelContext.save()
        }
    }
    private func symbol(_ status: String) -> String { status == "published" ? "checkmark.circle.fill" : status == "failed" ? "exclamationmark.circle.fill" : "clock.fill" }
    private func color(_ status: String) -> Color { status == "published" ? .green : status == "failed" ? .red : .orange }
}

struct SettingsView: View {
    @SwiftUI.Environment(AppSession.self) private var session
    @State private var digestEnabled = true
    @State private var plaidMessage: String?
    @State private var confirmation: DestructiveAction?
    @SwiftUI.Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Connections") {
                PlaidConnectRow(message: $plaidMessage)
                Button { Task { do { openURL(try await session.api.splitwiseConnectURL()) } catch { plaidMessage = error.localizedDescription } } } label: { Label("Connect Splitwise", systemImage: "person.2") }
                    .disabled(session.isDemoMode)
                Button("Disconnect all cards", role: .destructive) { confirmation = .plaid }
                    .disabled(session.isDemoMode)
                Button("Disconnect Splitwise", role: .destructive) { confirmation = .splitwise }
                    .disabled(session.isDemoMode)
                if session.isDemoMode { Text("Sign in with Google or a development code to use live connections.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Review") {
                Toggle("Daily review digest", isOn: $digestEnabled).onChange(of: digestEnabled) { _, enabled in if enabled { Task { _ = try? await NotificationService.requestAuthorization() } } }
                Text("Notifications are sent only when posted charges are waiting for review.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Bank credentials are handled by Plaid. Provider tokens stay encrypted on the LazySplit server.")
                Button("Sign out", role: .destructive) { session.signOut() }
                Button("Delete account and data", role: .destructive) { confirmation = .account }
            }
            if let plaidMessage { Section { Text(plaidMessage) } }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Are you sure?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(confirmation?.buttonTitle ?? "Continue", role: .destructive) { performConfirmedAction() }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private func performConfirmedAction() {
        guard let action = confirmation else { return }
        confirmation = nil
        Task {
            do {
                switch action {
                case .plaid: try await session.api.disconnectPlaid(); plaidMessage = "Cards disconnected. Imported transaction history remains available."
                case .splitwise: try await session.api.disconnectSplitwise(); plaidMessage = "Splitwise disconnected."
                case .account: try await session.api.deleteAccount(); session.isAuthenticated = false
                }
            } catch { plaidMessage = error.localizedDescription }
        }
    }

    private enum DestructiveAction: Equatable {
        case plaid, splitwise, account
        var buttonTitle: String { self == .account ? "Delete account" : "Disconnect" }
        var message: String {
            switch self {
            case .plaid: "LazySplit will revoke all Plaid connections. Existing imported transactions remain until you delete your account."
            case .splitwise: "LazySplit will delete its stored Splitwise token and cached friends and groups."
            case .account: "This permanently deletes all LazySplit sessions, connections, transactions, drafts, and settings."
            }
        }
    }
}

private struct PlaidConnectRow: View {
    @SwiftUI.Environment(AppSession.self) private var session
    @Binding var message: String?
    @State private var linkToken: String?
    @State private var loading = false
    #if canImport(LinkKit)
    @State private var linkSession: PlaidLinkSession?
    @State private var showingLink = false
    #endif

    var body: some View {
        Button { Task { await connect() } } label: { Label(loading ? "Preparing secure connection…" : "Connect cards with Plaid", systemImage: "building.columns") }
            .disabled(loading || session.isDemoMode)
        #if canImport(LinkKit)
            .sheet(isPresented: $showingLink) { linkSession?.sheet() }
        #endif
    }

    @MainActor private func connect() async {
        loading = true; defer { loading = false }
        do {
            let token = try await session.api.createPlaidLinkToken(); linkToken = token
            #if canImport(LinkKit)
            let configuration = LinkTokenConfiguration(token: token, onSuccess: { success in
                showingLink = false
                Task {
                    do { try await session.api.exchangePlaid(publicToken: success.publicToken); message = "Card connected. Historical sync has started." }
                    catch { message = error.localizedDescription }
                }
            }, onExit: { exit in
                showingLink = false
                if let error = exit.error { message = error.localizedDescription }
            }, onEvent: nil, onLoad: nil)
            linkSession = try Plaid.createPlaidLinkSession(configuration: configuration); showingLink = true
            #else
            message = "Plaid LinkKit is unavailable in this build."
            #endif
        } catch { message = error.localizedDescription }
    }
}

enum DemoData {
    static let friends = [SplitwiseFriend(id: 101, firstName: "Maya", lastName: "Chen"), SplitwiseFriend(id: 102, firstName: "Jordan", lastName: "Lee"), SplitwiseFriend(id: 103, firstName: "Sam", lastName: "Patel")]
    static var transactions: [TransactionRecord] {
        [
            TransactionRecord(source: .plaid, accountName: "Sapphire • 4242", merchant: "Taco Joint", date: .now.addingTimeInterval(-86_400), amountMinor: 6840, category: "Food"),
            TransactionRecord(source: .plaid, accountName: "Sapphire • 4242", merchant: "United Airlines", date: .now.addingTimeInterval(-172_800), amountMinor: 42819, category: "Travel"),
            TransactionRecord(source: .plaid, accountName: "Freedom • 8811", merchant: "City Market", date: .now.addingTimeInterval(-250_000), amountMinor: 9732, category: "Food"),
            TransactionRecord(source: .plaid, accountName: "Freedom • 8811", merchant: "Lyft", date: .now.addingTimeInterval(-340_000), amountMinor: 2487, state: .pending, category: "Transportation"),
            TransactionRecord(source: .csv, accountName: "Sapphire • 4242", merchant: "Mountain Cabin", date: Calendar.current.date(byAdding: .year, value: -2, to: .now)!, amountMinor: 61200, category: "Travel")
        ]
    }
}
