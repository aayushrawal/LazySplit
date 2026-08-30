import AuthenticationServices
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(LinkKit)
import LinkKit
#endif

struct CardsAccountsView: View {
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(AppSession.self) private var session
    @SwiftUI.Environment(\.openURL) private var openURL
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TransactionRecord.date) private var transactions: [TransactionRecord]
    @State private var showingImporter = false
    @State private var overview: ConnectionOverview?
    @State private var message: String?
    @State private var isRefreshing = false
    @State private var renamingAccount: ConnectedAccountSummary?
    @State private var accountNickname = ""

    private var visibleTransactions: [TransactionRecord] {
        transactions.filter { DemoData.shouldDisplay($0, inDemoMode: session.isDemoMode) }
    }

    private var accounts: [AccountPresentation] {
        var values = [String: AccountPresentation]()
        for account in overview?.accounts ?? [] {
            let key = account.name + "|" + account.mask
            values[key] = AccountPresentation(name: account.name, mask: account.mask, currencyCode: account.currencyCode, connected: account.connected, transactions: [])
        }
        for transaction in visibleTransactions {
            let key = transaction.accountName + "|" + transaction.accountMask
            if var current = values[key] {
                current.transactions.append(transaction); values[key] = current
            } else {
                values[key] = AccountPresentation(name: transaction.accountName, mask: transaction.accountMask, currencyCode: transaction.currencyCode, connected: false, transactions: [transaction])
            }
        }
        return values.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "creditcard.and.123").font(.title2).foregroundStyle(.indigo)
                        .frame(width: 48, height: 48).background(Color.indigo.opacity(0.12), in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accounts.isEmpty ? "Connect your first account" : "\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                            .font(.headline)
                        Text("Cards, transaction history, and coverage in one place.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }

            Section("Cards & bank accounts") {
                PlaidConnectRow(message: $message) { Task { await refreshConnections() } }
                Button { showingImporter = true } label: { Label("Import an older statement", systemImage: "doc.badge.plus") }
                if accounts.isEmpty {
                    ContentUnavailableView("No accounts yet", systemImage: "creditcard", description: Text("Connect through Plaid to bring in current cards and bank accounts."))
                } else {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading) {
                            AccountHistoryCard(account: account)
                            if let remote = overview?.accounts.first(where: { $0.name == account.name && $0.mask == account.mask }) {
                                Button {
                                    accountNickname = remote.name
                                    renamingAccount = remote
                                } label: { Label("Rename card", systemImage: "pencil") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section("Splitwise") {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill").foregroundStyle(.teal)
                        .frame(width: 38, height: 38).background(Color.teal.opacity(0.12), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overview?.splitwiseConnected == true ? "Connected" : "Not connected").font(.headline)
                        Text("Friends and groups used when you approve a shared charge.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(overview?.splitwiseConnected == true ? Color.green : Color.secondary.opacity(0.3)).frame(width: 9, height: 9)
                }
                Button {
                    Task {
                        do { openURL(try await session.api.splitwiseConnectURL()) }
                        catch { message = error.localizedDescription }
                    }
                } label: {
                    Label(overview?.splitwiseConnected == true ? "Reconnect Splitwise" : "Connect Splitwise", systemImage: "arrow.up.right.square")
                }.disabled(session.isDemoMode)
            }

            if session.isDemoMode {
                Section { Text("Live account connections are disabled in demo mode.").font(.caption).foregroundStyle(.secondary) }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if session.isRefreshingTransactions { ProgressView("Loading transactions…") }
            if let error = session.transactionRefreshError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Cards & Accounts")
        .refreshable { await refreshConnections() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await refreshConnections() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(isRefreshing || session.isDemoMode) } }
        .sheet(isPresented: $showingImporter) { NavigationStack { CSVImportView() } }
        .alert("Rename card", isPresented: Binding(get: { renamingAccount != nil }, set: { if !$0 { renamingAccount = nil } })) {
            TextField("Card product or nickname", text: $accountNickname)
            Button("Save") {
                if let account = renamingAccount {
                    let nickname = accountNickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        do {
                            try await session.api.renameAccount(id: account.id, nickname: nickname)
                            await refreshConnections()
                        } catch { message = error.localizedDescription }
                    }
                }
            }.disabled(accountNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountNickname.count > 80)
            Button("Cancel", role: .cancel) { renamingAccount = nil }
        } message: {
            Text("Your bank supplied “\(renamingAccount?.providerName ?? renamingAccount?.name ?? "Account")”. Set the product name you prefer; this only changes LazySplit.")
        }
        .task { await refreshConnections() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshConnections() } } }
    }

    @MainActor private func refreshConnections() async {
        guard !session.isDemoMode else { overview = nil; return }
        isRefreshing = true; defer { isRefreshing = false }
        do { overview = try await session.api.connections() }
        catch { message = error.localizedDescription }
        await session.refreshTransactions(in: modelContext)
    }
}

private struct AccountPresentation: Identifiable {
    var name: String
    var mask: String
    var currencyCode: String
    var connected: Bool
    var transactions: [TransactionRecord]
    var id: String { name + "|" + mask }
}

private struct AccountHistoryCard: View {
    let account: AccountPresentation
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 12)
    private var months: [CoverageMonth] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .month, value: -35, to: calendar.date(from: calendar.dateComponents([.year, .month], from: .now))!)!
        return (0..<36).map { offset in
            let date = calendar.date(byAdding: .month, value: offset, to: start)!
            let inMonth = account.transactions.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
            let source: TransactionSource? = inMonth.contains(where: { $0.source == .csv }) ? .csv : inMonth.first?.source
            return CoverageMonth(date: date, source: source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard.fill").foregroundStyle(.indigo).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.headline)
                    Text(account.mask.isEmpty ? account.currencyCode : "•••• \(account.mask) · \(account.currencyCode)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(account.connected ? "Connected" : "History", systemImage: account.connected ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(account.connected ? .green : .secondary)
            }
            HStack {
                LabeledContent("Charges", value: "\(account.transactions.count)")
                if let latest = account.transactions.map(\.date).max() {
                    Spacer(); LabeledContent("Latest", value: latest.formatted(date: .abbreviated, time: .omitted))
                }
            }.font(.caption).foregroundStyle(.secondary)
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
        }.padding(.vertical, 8)
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

    private var visibleTransactions: [TransactionRecord] {
        transactions.filter { DemoData.shouldDisplay($0, inDemoMode: session.isDemoMode) }
    }
    private var visibleAttempts: [ExportAttempt] {
        attempts.filter { transaction(for: $0) != nil }
    }

    var body: some View {
        List {
            if visibleAttempts.isEmpty { ContentUnavailableView("Outbox is empty", systemImage: "paperplane", description: Text("Approved splits appear here before publishing.")) }
            ForEach(visibleAttempts) { attempt in
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
                Button("Publish all") { Task { await publishAll() } }.disabled(publishing || !visibleAttempts.contains(where: { $0.status == "queued" || $0.status == "failed" }))
            }
        }
        .overlay { if publishing { ProgressView("Publishing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
    }

    private func transaction(for attempt: ExportAttempt) -> TransactionRecord? {
        guard let draft = drafts.first(where: { $0.id == attempt.draftID }) else { return nil }
        return visibleTransactions.first { $0.id == draft.transactionID }
    }
    private func publishAll() async {
        publishing = true; defer { publishing = false }
        for attempt in visibleAttempts.filter({ $0.status == "queued" || $0.status == "failed" }) {
            guard let draft = drafts.first(where: { $0.id == attempt.draftID }), let transaction = visibleTransactions.first(where: { $0.id == draft.transactionID }) else { continue }
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
    var onConnected: @MainActor () -> Void = {}
    @State private var linkToken: String?
    @State private var loading = false
    @State private var hostedAuthSession: ASWebAuthenticationSession?
    @State private var hostedLink: HostedPlaidLink?
    @State private var showingHostedConnection = false
    @State private var activeHostedSessionID: UUID?
    @State private var hostedPresentationContext = PlaidHostedLinkPresentationContext()
    #if canImport(LinkKit)
    @State private var linkSession: PlaidLinkSession?
    @State private var showingLink = false
    #endif

    var body: some View {
        Button { Task { await connect() } } label: { Label(loading ? "Preparing secure connection…" : "Connect cards with Plaid", systemImage: "building.columns") }
            .disabled(loading || session.isDemoMode || showingHostedConnection)
            .sheet(isPresented: $showingHostedConnection, onDismiss: closeHostedConnection) {
                NavigationStack {
                    VStack(spacing: 20) {
                        Image(systemName: "building.columns").font(.largeTitle).foregroundStyle(.teal)
                        Text("Connect your account").font(.title2.bold())
                        Text("Complete the secure Plaid page. Use Cancel on that page, or close this panel, to return to LazySplit.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Back to LazySplit") { closeHostedConnection() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .navigationTitle("Connect account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { closeHostedConnection() } label: {
                                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Close account connection")
                        }
                    }
                    .task {
                        if let hostedLink, activeHostedSessionID == nil { startHostedLink(hostedLink) }
                    }
                }
            }
        #if canImport(LinkKit)
            .sheet(isPresented: $showingLink, onDismiss: { linkSession = nil }) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Connect account").font(.headline)
                        Spacer()
                        Button {
                            showingLink = false
                            message = "Connection page closed."
                        } label: {
                            Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Close account connection")
                    }
                    .padding(.horizontal)
                    Divider()
                    if let linkSession { linkSession.sheet() }
                    else { Spacer(); Text("Connection page unavailable.").foregroundStyle(.secondary); Spacer() }
                }
            }
        #endif
    }

    @MainActor private func connect() async {
        loading = true; defer { loading = false }
        do {
            #if DEBUG
            hostedLink = try await session.api.createPlaidHostedLink()
            showingHostedConnection = true
            #else
            let token = try await session.api.createPlaidLinkToken(); linkToken = token
            #if canImport(LinkKit)
            let configuration = LinkTokenConfiguration(token: token, onSuccess: { success in
                Task { @MainActor in
                    showingLink = false
                    do {
                        try await session.api.exchangePlaid(publicToken: success.publicToken)
                        message = "Account connected. Historical sync has started."
                        onConnected()
                    }
                    catch { message = error.localizedDescription }
                }
            }, onExit: { exit in
                Task { @MainActor in
                    showingLink = false
                    if let error = exit.error { message = error.localizedDescription }
                }
            }, onEvent: nil, onLoad: nil)
            linkSession = try Plaid.createPlaidLinkSession(configuration: configuration); showingLink = true
            #else
            message = "Plaid LinkKit is unavailable in this build."
            #endif
            #endif
        } catch { message = error.localizedDescription }
    }

    @MainActor private func startHostedLink(_ hostedLink: HostedPlaidLink) {
        activeHostedSessionID = hostedLink.sessionID
        let authSession = ASWebAuthenticationSession(url: hostedLink.url, callbackURLScheme: "lazysplit") { callbackURL, error in
            Task { @MainActor in
                guard activeHostedSessionID == hostedLink.sessionID else { return }
                activeHostedSessionID = nil
                hostedAuthSession = nil
                showingHostedConnection = false
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    await checkClosedHostedConnection(sessionID: hostedLink.sessionID)
                    return
                }
                guard error == nil, callbackURL?.scheme == "lazysplit" else {
                    message = error?.localizedDescription ?? "Plaid did not return a valid completion response."
                    return
                }
                await finishHostedLink(sessionID: hostedLink.sessionID)
            }
        }
        authSession.presentationContextProvider = hostedPresentationContext
        hostedAuthSession = authSession
        if !authSession.start() {
            activeHostedSessionID = nil
            hostedAuthSession = nil
            showingHostedConnection = false
            message = "Could not open Plaid's secure connection page."
        }
    }

    @MainActor private func closeHostedConnection() {
        let sessionID = activeHostedSessionID
        activeHostedSessionID = nil
        hostedAuthSession?.cancel()
        hostedAuthSession = nil
        showingHostedConnection = false
        hostedLink = nil
        if let sessionID {
            Task { await checkClosedHostedConnection(sessionID: sessionID) }
        }
    }

    @MainActor private func checkClosedHostedConnection(sessionID: UUID) async {
        message = "Connection page closed. Checking whether Plaid finished…"
        do {
            let status = try await session.api.completePlaidHostedLink(sessionID: sessionID)
            if status.state == "connected" {
                message = "Bank connection completed. Historical sync has started."
                onConnected()
            } else {
                message = "Connection page closed. If you completed Plaid, refresh Accounts shortly to check the result."
            }
        } catch {
            message = "Connection page closed. Could not check its status; refresh Accounts when you’re online."
        }
    }

    @MainActor private func finishHostedLink(sessionID: UUID) async {
        loading = true; defer { loading = false }
        do {
            for _ in 0..<20 {
                let status = try await session.api.completePlaidHostedLink(sessionID: sessionID)
                switch status.state {
                case "connected":
                    message = status.connectedCount == 1 ? "Bank connection completed. Historical sync has started." : "\(status.connectedCount) bank connections completed. Historical sync has started."
                    onConnected()
                    return
                case "exited":
                    message = status.message ?? "Plaid connection was not completed."
                    return
                case "failed":
                    message = status.message ?? "Plaid could not finish this connection."
                    return
                default:
                    try await Task.sleep(for: .seconds(1))
                }
            }
            message = "Plaid is still finishing the connection. Refresh Cards & Accounts in a moment."
        } catch { message = error.localizedDescription }
    }
}

@MainActor
private final class PlaidHostedLinkPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

enum DemoData {
    static let friends = [
        SplitwiseFriend(id: 101, firstName: "Maya", lastName: "Chen", sortOrder: 0, interactionCount: 12),
        SplitwiseFriend(id: 102, firstName: "Jordan", lastName: "Lee", sortOrder: 1, interactionCount: 7),
        SplitwiseFriend(id: 103, firstName: "Sam", lastName: "Patel", sortOrder: 2, interactionCount: 3)
    ]
    private static let legacyAccountNames: Set<String> = ["Sapphire • 4242", "Freedom • 8811"]

    static func isLegacyDemo(_ transaction: TransactionRecord) -> Bool {
        legacyAccountNames.contains(transaction.accountName)
    }

    static func shouldDisplay(_ transaction: TransactionRecord, inDemoMode: Bool) -> Bool {
        let demo = transaction.isDemo || isLegacyDemo(transaction)
        return inDemoMode ? demo : !demo
    }

    static var transactions: [TransactionRecord] {
        [
            TransactionRecord(source: .plaid, accountName: "Sapphire • 4242", merchant: "Taco Joint", date: .now.addingTimeInterval(-86_400), amountMinor: 6840, category: "Food", isDemo: true),
            TransactionRecord(source: .plaid, accountName: "Sapphire • 4242", merchant: "United Airlines", date: .now.addingTimeInterval(-172_800), amountMinor: 42819, category: "Travel", isDemo: true),
            TransactionRecord(source: .plaid, accountName: "Freedom • 8811", merchant: "City Market", date: .now.addingTimeInterval(-250_000), amountMinor: 9732, category: "Food", isDemo: true),
            TransactionRecord(source: .plaid, accountName: "Freedom • 8811", merchant: "Lyft", date: .now.addingTimeInterval(-340_000), amountMinor: 2487, state: .pending, category: "Transportation", isDemo: true),
            TransactionRecord(source: .csv, accountName: "Sapphire • 4242", merchant: "Mountain Cabin", date: Calendar.current.date(byAdding: .year, value: -2, to: .now)!, amountMinor: 61200, category: "Travel", isDemo: true)
        ]
    }
}
