import AuthenticationServices
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            if session.isAuthenticated { MainTabView() }
            else { OnboardingView() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } })) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: { Text(session.lastError ?? "") }
    }
}

struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @State private var isWorking = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.indigo.opacity(0.85), Color.blue.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Spacer()
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 64)).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Catch up without the spreadsheet.").font(.largeTitle.bold())
                    Text("Bring in card history, review shared charges, then send only what you approve to Splitwise.").font(.title3).foregroundStyle(.white.opacity(0.82))
                }.foregroundStyle(.white)
                Spacer()
                #if DEBUG
                Button {
                    session.useDemoMode()
                } label: {
                    Label("Continue on this device", systemImage: "iphone")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.indigo)
                .clipShape(.rect(cornerRadius: 14))
                Text("This Debug build skips cloud sign-in so it can run with a personal development profile.")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                #else
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    guard case .success(let authorization) = result,
                          let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let identityData = credential.identityToken,
                          let identityToken = String(data: identityData, encoding: .utf8) else {
                        session.lastError = "Apple sign-in did not return an identity token."
                        return
                    }
                    let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                    isWorking = true
                    Task {
                        do { try await session.api.authenticate(identityToken: identityToken, authorizationCode: code); session.isAuthenticated = true }
                        catch { session.lastError = error.localizedDescription }
                        isWorking = false
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52).clipShape(.rect(cornerRadius: 14))
                #endif
                Button("Explore with demo data") { session.useDemoMode() }
                    .frame(maxWidth: .infinity).foregroundStyle(.white).padding(.bottom, 12)
            }.padding(28)
            if isWorking { ProgressView().tint(.white) }
        }
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query private var transactions: [TransactionRecord]
    @AppStorage("didSeedDemo") private var didSeedDemo = false

    var body: some View {
        TabView {
            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "tray.full") }
            NavigationStack { CoverageView() }
                .tabItem { Label("Coverage", systemImage: "calendar.badge.checkmark") }
            NavigationStack { OutboxView() }
                .tabItem { Label("Outbox", systemImage: "paperplane") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .task {
            if transactions.isEmpty && !didSeedDemo {
                DemoData.transactions.forEach(modelContext.insert)
                try? modelContext.save(); didSeedDemo = true
            }
            guard KeychainStore.read("sessionToken") != nil else { return }
            if let deviceToken = UserDefaults.standard.string(forKey: "apnsDeviceToken") { try? await session.api.registerDevice(token: deviceToken) }
            if let remote = try? await session.api.transactions() {
                for item in remote {
                    if let current = transactions.first(where: { $0.id == item.id || $0.externalID == item.externalID || $0.fingerprint == item.fingerprint }) {
                        current.externalID = item.externalID; current.sourceRaw = item.source.rawValue; current.accountName = item.accountName
                        current.accountMask = item.accountMask; current.merchant = item.merchant; current.originalDescription = item.originalDescription
                        current.date = item.date; current.amountMinor = item.amountMinor; current.currencyCode = item.currencyCode
                        current.state = item.state; current.category = item.category; current.fingerprint = item.fingerprint
                        current.possibleDuplicateID = item.possibleDuplicateID
                    } else {
                        let record = TransactionRecord(id: item.id, externalID: item.externalID, source: item.source, accountName: item.accountName, accountMask: item.accountMask, merchant: item.merchant, originalDescription: item.originalDescription, date: item.date, amountMinor: item.amountMinor, currencyCode: item.currencyCode, state: item.state, category: item.category, fingerprint: item.fingerprint)
                        record.possibleDuplicateID = item.possibleDuplicateID; modelContext.insert(record)
                    }
                }
                try? modelContext.save()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveAPNSToken)) { notification in
            guard let token = notification.object as? String, KeychainStore.read("sessionToken") != nil else { return }
            Task { try? await session.api.registerDevice(token: token) }
        }
    }
}

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransactionRecord.date, order: .reverse) private var allTransactions: [TransactionRecord]
    @State private var stateFilter: ReviewState? = .needsReview
    @State private var search = ""
    @State private var accountFilter: String?
    @State private var selected = Set<UUID>()
    @State private var undoAction: (UUID, ReviewState)?

    private var filtered: [TransactionRecord] {
        allTransactions.filter { transaction in
            (stateFilter == nil || transaction.state == stateFilter) &&
            (accountFilter == nil || transaction.accountName == accountFilter) &&
            (search.isEmpty || transaction.merchant.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List(selection: $selected) {
            if filtered.isEmpty {
                ContentUnavailableView("You’re caught up", systemImage: "checkmark.circle", description: Text("Choose another filter or wait for the next card sync."))
                    .listRowBackground(Color.clear)
            }
            ForEach(filtered) { transaction in
                NavigationLink { SplitEditorView(transaction: transaction) } label: { TransactionRow(transaction: transaction) }
                    .tag(transaction.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { set(transaction, to: .sharedDraft) } label: { Label("Shared", systemImage: "person.2.fill") }.tint(.indigo)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { set(transaction, to: .personal) } label: { Label("Personal", systemImage: "person.fill") }.tint(.gray)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Review")
        .searchable(text: $search, prompt: "Merchant")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("All statuses") { stateFilter = nil }
                    ForEach(ReviewState.allCases) { state in Button(state.title) { stateFilter = state } }
                    Divider()
                    Button("All cards") { accountFilter = nil }
                    ForEach(Array(Set(allTransactions.map(\.accountName))).sorted(), id: \.self) { account in Button(account) { accountFilter = account } }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            if !selected.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Personal") { bulkSet(.personal) }
                    Spacer()
                    Button("Shared") { bulkSet(.sharedDraft) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let undoAction {
                HStack { Text("Marked \(ReviewState(rawValue: undoAction.1.rawValue)?.title.lowercased() ?? "")"); Spacer(); Button("Undo") { undo() } }
                    .padding().background(.regularMaterial).clipShape(.rect(cornerRadius: 14)).padding()
            }
        }
    }

    private func set(_ transaction: TransactionRecord, to state: ReviewState) {
        undoAction = (transaction.id, transaction.state); transaction.state = state; try? modelContext.save()
    }
    private func undo() {
        guard let undoAction, let transaction = allTransactions.first(where: { $0.id == undoAction.0 }) else { return }
        transaction.state = undoAction.1; self.undoAction = nil; try? modelContext.save()
    }
    private func bulkSet(_ state: ReviewState) {
        allTransactions.filter { selected.contains($0.id) }.forEach { $0.state = state }
        selected.removeAll(); try? modelContext.save()
    }
}

struct TransactionRow: View {
    let transaction: TransactionRecord
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 42, height: 42).background(Color.indigo.opacity(0.1), in: .circle).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).font(.headline).lineLimit(1)
                Text("\(transaction.accountName) • \(transaction.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.amount, format: .currency(code: transaction.currencyCode)).font(.headline.monospacedDigit())
                Text(transaction.state.title).font(.caption2).foregroundStyle(transaction.state == .failed ? .red : .secondary)
            }
        }.padding(.vertical, 5)
    }
    private var icon: String {
        switch transaction.category?.lowercased() {
        case "food": "fork.knife"
        case "travel": "airplane"
        case "transportation": "car.fill"
        default: "creditcard.fill"
        }
    }
}

struct SplitEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    let transaction: TransactionRecord
    @Query private var rules: [SuggestionRule]
    @State private var friends: [SplitwiseFriend] = DemoData.friends
    @State private var selected = Set<Int>()
    @State private var exactAmounts = [Int: String]()
    @State private var exactMode = false
    @State private var isLoading = false

    private var amountIsValid: Bool {
        !exactMode || selected.reduce(0) { $0 + (Decimal(string: exactAmounts[$1] ?? "") ?? 0) } == transaction.amount
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Merchant", value: transaction.merchant)
                LabeledContent("Total") { Text(transaction.amount, format: .currency(code: transaction.currencyCode)).fontWeight(.semibold) }
                LabeledContent("Date", value: transaction.date.formatted(date: .long, time: .omitted))
            }
            Section {
                Picker("Split", selection: $exactMode) {
                    Text("Equally").tag(false); Text("Exact amounts").tag(true)
                }.pickerStyle(.segmented)
                ForEach(friends) { friend in
                    HStack {
                        Button { toggle(friend.id) } label: {
                            Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.indigo)
                            Text(friend.displayName).foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                        Spacer()
                        if exactMode && selected.contains(friend.id) {
                            TextField("0.00", text: Binding(get: { exactAmounts[friend.id] ?? "" }, set: { exactAmounts[friend.id] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                        }
                    }
                }
            } header: { Text("Who shared it?") } footer: {
                if exactMode && !amountIsValid { Text("Exact amounts must add up to the transaction total.").foregroundStyle(.red) }
            }
            Section {
                Button("Approve and add to outbox") { approve() }
                    .frame(maxWidth: .infinity).disabled(selected.isEmpty || !amountIsValid || transaction.state == .pending)
            }
        }
        .navigationTitle("Split expense").navigationBarTitleDisplayMode(.inline)
        .task {
            applySuggestion()
            do { let live = try await session.api.friends(); if !live.isEmpty { friends = live } } catch { }
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id); exactAmounts.removeValue(forKey: id) }
        else { selected.insert(id) }
    }
    private func applySuggestion() {
        guard let rule = rules.first(where: { $0.normalizedMerchant == TransactionFingerprint.normalize(transaction.merchant) }),
              let data = rule.participantIDsJSON.data(using: .utf8), let ids = try? JSONDecoder().decode([Int].self, from: data) else { return }
        selected = Set(ids)
    }
    private func approve() {
        let ids = selected.sorted()
        let owed: [Int]
        if exactMode { owed = ids.map { NSDecimalNumber(decimal: Decimal(string: exactAmounts[$0] ?? "") ?? 0).multiplying(byPowerOf10: 2).intValue } }
        else {
            let count = ids.count + 1
            let base = transaction.amountMinor / count, remainder = transaction.amountMinor % count
            owed = ids.enumerated().map { base + ($0.offset < remainder ? 1 : 0) }
        }
        let participants = zip(ids, owed).map { id, amount in SplitParticipant(splitwiseUserID: id, displayName: friends.first(where: { $0.id == id })?.displayName ?? "Friend", owedMinor: amount) }
        let draft = SplitDraft(transactionID: transaction.id, splitKind: exactMode ? "exact" : "equal", participants: participants)
        modelContext.insert(draft); modelContext.insert(ExportAttempt(draftID: draft.id)); transaction.state = .queued
        if let existing = rules.first(where: { $0.normalizedMerchant == TransactionFingerprint.normalize(transaction.merchant) }) { existing.confirmations += 1; existing.updatedAt = .now }
        else { modelContext.insert(SuggestionRule(merchant: transaction.merchant, participantIDs: ids, participantNames: participants.map(\.displayName), splitKind: draft.splitKind)) }
        try? modelContext.save()
    }
}
