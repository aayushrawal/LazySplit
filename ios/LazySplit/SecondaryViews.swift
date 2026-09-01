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
    @State private var showingManualAccount = false
    @State private var importAccount: StatementAccount?
    @State private var overview: ConnectionOverview?
    @State private var message: String?
    @State private var isRefreshing = false
    @State private var renamingAccount: ConnectedAccountSummary?
    @State private var accountNickname = ""
    @State private var selectedAccountID: String?

    private var visibleTransactions: [TransactionRecord] {
        transactions.filter { DemoData.shouldDisplay($0, inDemoMode: session.isDemoMode) }
    }

    private var accounts: [AccountPresentation] {
        var values = [String: AccountPresentation]()
        for account in overview?.accounts ?? [] {
            let key = account.id.uuidString
            values[key] = AccountPresentation(id: key, remoteID: account.id, name: account.name, mask: account.mask, currencyCode: account.currencyCode, connected: account.connected, transactions: [])
        }
        for transaction in visibleTransactions {
            let matchingRemoteKey = values.first { _, account in
                account.name == transaction.accountName && account.mask == transaction.accountMask
            }?.key
            let key = transaction.accountID?.uuidString ?? matchingRemoteKey ?? transaction.accountName + "|" + transaction.accountMask
            if var current = values[key] {
                current.transactions.append(transaction); values[key] = current
            } else {
                values[key] = AccountPresentation(id: key, remoteID: transaction.accountID, name: transaction.accountName, mask: transaction.accountMask, currencyCode: transaction.currencyCode, connected: false, transactions: [transaction])
            }
        }
        return values.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedAccount: AccountPresentation? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    var body: some View {
        List {
            Section("Add or refresh") {
                PlaidConnectRow(message: $message) { Task { await refreshConnections() } }
                Button { importAccount = nil; showingImporter = true } label: { Label("Upload statements", systemImage: "doc.badge.plus") }
                Button { showingManualAccount = true } label: { Label("Add account manually", systemImage: "creditcard.badge.plus") }
            }

            if accounts.isEmpty {
                Section { ContentUnavailableView("No accounts yet", systemImage: "creditcard", description: Text("Connect through Plaid or add a statement-only account such as Apple Card.")) }
            } else {
                Section("Choose an account") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(accounts) { account in
                                AccountSelectorCard(account: account, selected: selectedAccount?.id == account.id) {
                                    withAnimation(.snappy) { selectedAccountID = account.id }
                                }
                            }
                        }.padding(.vertical, 2)
                    }.scrollIndicators(.hidden)
                }

                if let account = selectedAccount {
                    Section("Account history") {
                        AccountHistoryCard(account: account) {
                            importAccount = account.remoteID.map { StatementAccount(id: $0, name: account.name, mask: account.mask, currencyCode: account.currencyCode) }
                            showingImporter = true
                        } onSync: {
                            Task { await refreshConnections() }
                        }
                        if let remote = overview?.accounts.first(where: { $0.id == account.remoteID }) {
                            Button {
                                accountNickname = remote.name
                                renamingAccount = remote
                            } label: { Label("Rename this account", systemImage: "pencil") }
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
        .sheet(isPresented: $showingImporter) { NavigationStack { CSVImportView(account: importAccount) } }
        .sheet(isPresented: $showingManualAccount) {
            NavigationStack { ManualAccountView { _ in Task { await refreshConnections() } } }
        }
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
        .onChange(of: accounts.map(\.id)) { _, ids in
            if selectedAccountID == nil || !ids.contains(selectedAccountID!) { selectedAccountID = ids.first }
        }
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
    let id: String
    var remoteID: UUID?
    var name: String
    var mask: String
    var currencyCode: String
    var connected: Bool
    var transactions: [TransactionRecord]
}

private struct AccountSelectorCard: View {
    let account: AccountPresentation
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: account.connected ? "creditcard.fill" : "creditcard")
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) }
                }
                Text(account.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(account.mask.isEmpty ? account.currencyCode : "•••• \(account.mask)")
                    .font(.caption.monospacedDigit()).foregroundStyle(selected ? .white.opacity(0.82) : .secondary)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(12).frame(width: 154, height: 104, alignment: .leading)
            .background(selected ? Color.indigo : Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.indigo : Color.secondary.opacity(0.12)) }
        }.buttonStyle(.plain)
        .accessibilityLabel("View \(account.name)\(account.mask.isEmpty ? "" : ", ending \(account.mask)")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AccountHistoryCard: View {
    let account: AccountPresentation
    let onUpload: () -> Void
    let onSync: () -> Void
    @AppStorage("accounts.historyMonthCount") private var historyMonthCount = 48
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private var purchaseTransactions: [TransactionRecord] { account.transactions.filter { !$0.isCredit && $0.amountMinor > 0 } }
    private var years: [AccountCoverageYear] {
        let calendar = Calendar.current
        let months = AccountHistoryWindow.monthStarts(monthCount: historyMonthCount, endingAt: .now, calendar: calendar).map { date in
            let rows = purchaseTransactions.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
            return AccountCoverageMonth(date: date, hasPlaid: rows.contains { $0.source == .plaid }, hasStatement: rows.contains { $0.source == .csv }, count: rows.count)
        }
        return Dictionary(grouping: months.reversed()) { calendar.component(.year, from: $0.date) }
            .map { AccountCoverageYear(year: $0.key, months: $0.value) }.sorted { $0.year > $1.year }
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
            HStack(spacing: 18) {
                LabeledContent("Purchases", value: "\(purchaseTransactions.count)")
                if let latest = purchaseTransactions.map(\.date).max() {
                    Spacer(); LabeledContent("Latest", value: latest.formatted(date: .abbreviated, time: .omitted))
                }
            }.font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(action: onUpload) { Label("Upload statement", systemImage: "doc.badge.plus") }
                    .buttonStyle(.borderedProminent).tint(.cyan)
                if account.connected {
                    Button(action: onSync) { Label("Sync now", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                }
            }

            Divider()
            HStack {
                Text("Month-by-month history").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Picker("History range", selection: $historyMonthCount) {
                        ForEach(AccountHistoryWindow.options, id: \.self) { count in Text("Last \(count) months").tag(count) }
                    }
                } label: {
                    Label("\(AccountHistoryWindow.normalized(historyMonthCount)) months", systemImage: "calendar")
                        .font(.caption.weight(.medium))
                }.buttonStyle(.borderless)
            }
            Text("Tap any missing month to upload its statement. Plaid months update when you sync.").font(.caption).foregroundStyle(.secondary)
            ForEach(years) { year in
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(year.year)).font(.headline.monospacedDigit())
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(year.months) { month in
                            Button { if month.isMissing { onUpload() } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(month.date.formatted(.dateTime.month(.abbreviated).year()))
                                        .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                    Label(month.status, systemImage: month.symbol)
                                        .font(.caption2).lineLimit(1).minimumScaleFactor(0.72)
                                    if month.count > 0 { Text("\(month.count) purchase\(month.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary) }
                                }
                                .foregroundStyle(month.foreground)
                                .padding(9).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                                .background(month.background, in: .rect(cornerRadius: 11))
                            }.buttonStyle(.plain).allowsHitTesting(month.isMissing)
                            .accessibilityLabel("\(month.date.formatted(.dateTime.month(.wide).year())): \(month.status), \(month.count) purchases")
                        }
                    }
                }
            }
            HStack(spacing: 13) {
                Label("Plaid sync", systemImage: "circle.fill").foregroundStyle(.indigo)
                Label("Uploaded", systemImage: "circle.fill").foregroundStyle(.cyan)
                Label("Missing", systemImage: "circle").foregroundStyle(.secondary)
            }.font(.caption2)
        }.padding(.vertical, 6)
    }
}

enum AccountHistoryWindow {
    static let options = [12, 24, 36, 48]

    static func normalized(_ monthCount: Int) -> Int {
        options.contains(monthCount) ? monthCount : 48
    }

    static func monthStarts(monthCount: Int, endingAt date: Date, calendar: Calendar = .current) -> [Date] {
        let count = normalized(monthCount)
        guard let current = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let first = calendar.date(byAdding: .month, value: -(count - 1), to: current) else { return [] }
        return (0..<count).compactMap { calendar.date(byAdding: .month, value: $0, to: first) }
    }
}

private struct AccountCoverageYear: Identifiable {
    let year: Int
    let months: [AccountCoverageMonth]
    var id: Int { year }
}

private struct AccountCoverageMonth: Identifiable {
    let date: Date
    let hasPlaid: Bool
    let hasStatement: Bool
    let count: Int
    var id: Date { date }
    var isMissing: Bool { !hasPlaid && !hasStatement }
    var status: String { hasPlaid && hasStatement ? "Both" : hasPlaid ? "Synced" : hasStatement ? "Uploaded" : "Missing" }
    var symbol: String { hasPlaid && hasStatement ? "checkmark.circle.fill" : hasPlaid ? "arrow.triangle.2.circlepath.circle.fill" : hasStatement ? "doc.circle.fill" : "plus.circle" }
    var foreground: Color { hasPlaid ? .indigo : hasStatement ? .cyan : .secondary }
    var background: Color { foreground.opacity(isMissing ? 0.07 : 0.12) }
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
        attempts.filter { attempt in
            guard let transaction = transaction(for: attempt) else { return false }
            return transaction.state != .personal && !transaction.isCredit
        }
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
        await session.syncReviewDecisions(in: modelContext)
        for attempt in visibleAttempts.filter({ $0.status == "queued" || $0.status == "failed" }) {
            guard let draft = drafts.first(where: { $0.id == attempt.draftID }), let transaction = visibleTransactions.first(where: { $0.id == draft.transactionID }) else { continue }
            guard transaction.state != .personal, transaction.state != .pending, !transaction.isCredit, !transaction.reviewNeedsSync else { continue }
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
