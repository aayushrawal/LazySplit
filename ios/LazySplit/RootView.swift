import AuthenticationServices
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

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
    @State private var developmentAccessCode = ""

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
                SecureField("Development access code", text: $developmentAccessCode)
                    .textContentType(.password)
                    .padding().background(.white.opacity(0.14), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
                Button {
                    isWorking = true
                    Task {
                        do {
                            try await session.api.authenticateForDevelopment(accessCode: developmentAccessCode)
                            session.completeAuthentication()
                        } catch { session.lastError = error.localizedDescription }
                        isWorking = false
                    }
                } label: {
                    Label("Connect to LazySplit", systemImage: "server.rack")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.indigo)
                .clipShape(.rect(cornerRadius: 14))
                .disabled(developmentAccessCode.isEmpty || isWorking)
                Text("The development code is stored only on your Mac and creates a real backend session for Plaid and Splitwise testing.")
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
                        do { try await session.api.authenticate(identityToken: identityToken, authorizationCode: code); session.completeAuthentication() }
                        catch { session.lastError = error.localizedDescription }
                        isWorking = false
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52).clipShape(.rect(cornerRadius: 14))
                #endif
                Button {
                    Task { await signInWithGoogle() }
                } label: {
                    Label("Continue with Google", systemImage: "g.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.bordered).tint(.white).foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 14))
                .disabled(isWorking)
                Button("Preview demo data (connections disabled)") { session.useDemoMode() }
                    .frame(maxWidth: .infinity).foregroundStyle(.white).padding(.bottom, 12)
            }.padding(28)
            if isWorking { ProgressView().tint(.white) }
        }
    }

    @MainActor private func signInWithGoogle() async {
        #if canImport(GoogleSignIn)
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              let serverClientID = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String,
              !clientID.isEmpty, !serverClientID.isEmpty,
              let presenting = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            session.lastError = "Google Sign-In is not configured in this build."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
            guard let identityToken = result.user.idToken?.tokenString else { throw APIError.invalidResponse }
            try await session.api.authenticateWithGoogle(identityToken: identityToken)
            session.completeAuthentication()
        } catch { session.lastError = error.localizedDescription }
        #else
        session.lastError = "Google Sign-In is unavailable in this build."
        #endif
    }
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query private var transactions: [TransactionRecord]
    @Query private var drafts: [SplitDraft]
    @Query private var exportAttempts: [ExportAttempt]

    var body: some View {
        TabView {
            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "tray.full") }
            NavigationStack { CardsAccountsView() }
                .tabItem { Label("Accounts", systemImage: "creditcard.and.123") }
            NavigationStack { FriendsManagementView() }
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
            NavigationStack { OutboxView() }
                .tabItem { Label("Outbox", systemImage: "paperplane") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .task(id: session.isDemoMode) {
            prepareLocalDataForCurrentSession()
            guard !session.isDemoMode, KeychainStore.read("sessionToken") != nil else { return }
            if let deviceToken = UserDefaults.standard.string(forKey: "apnsDeviceToken") { try? await session.api.registerDevice(token: deviceToken) }
            await session.refreshTransactions(in: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.refreshTransactions(in: modelContext) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveAPNSToken)) { notification in
            guard let token = notification.object as? String, KeychainStore.read("sessionToken") != nil else { return }
            Task { try? await session.api.registerDevice(token: token) }
        }
    }

    private func prepareLocalDataForCurrentSession() {
        if session.isDemoMode {
            guard !transactions.contains(where: \.isDemo) else { return }
            DemoData.transactions.forEach(modelContext.insert)
            try? modelContext.save()
            return
        }

        let demoIDs = Set(transactions.filter { $0.isDemo || DemoData.isLegacyDemo($0) }.map(\.id))
        guard !demoIDs.isEmpty else { return }
        drafts.filter { demoIDs.contains($0.transactionID) }.forEach { draft in
            exportAttempts.filter { $0.draftID == draft.id }.forEach(modelContext.delete)
            modelContext.delete(draft)
        }
        transactions.filter { demoIDs.contains($0.id) }.forEach(modelContext.delete)
        try? modelContext.save()
    }
}

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query(sort: \TransactionRecord.date, order: .reverse) private var allTransactions: [TransactionRecord]
    @State private var filters = InboxFilters()
    @State private var showingFilters = false
    @State private var search = ""
    @State private var selected = Set<UUID>()
    @State private var undoActions: [(UUID, ReviewState)] = []
    @State private var lastAction = ""
    @State private var collapsedGroups = Set<String>()
    @AppStorage("inbox.historyGrouping") private var historyGrouping: InboxGrouping = .month
    @State private var newExpanded = true
    @AppStorage("inbox.colorCodeByAccount") private var colorCodeByAccount = false
    @AppStorage("inbox.accountColors") private var savedAccountColors = Data()

    private var accountKeys: [String] { Array(Set(visibleTransactions.map(\.accountColorKey))).sorted() }
    private var accountColors: [String: Int] {
        AccountColors.assignments(for: accountKeys, retaining: (try? JSONDecoder().decode([String: Int].self, from: savedAccountColors)) ?? [:])
    }
    private var accountLegend: [TransactionRecord] {
        var seen = Set<String>()
        return visibleTransactions.filter { seen.insert($0.accountColorKey).inserted }
            .sorted { $0.cardLabel == $1.cardLabel ? $0.accountColorKey < $1.accountColorKey : $0.cardLabel < $1.cardLabel }
    }

    private var filtered: [TransactionRecord] {
        filters.ordered(visibleTransactions.filter { filters.matches($0, search: search) })
    }

    private var visibleTransactions: [TransactionRecord] {
        allTransactions.filter { DemoData.shouldDisplay($0, inDemoMode: session.isDemoMode) && !$0.isCredit && $0.amountMinor > 0 }
    }

    private var newTransactions: [TransactionRecord] { InboxArrivalGroups.newTransactions(in: filtered) }
    private var historyGroups: [InboxHistoryGroup] { InboxHistoryGroup.group(filtered, by: historyGrouping, sort: filters.sort) }

    var body: some View {
        let colors = accountColors
        let groups = historyGroups
        let arrivals = newTransactions
        List(selection: $selected) {
            Section {
                HStack {
                    Button { showingFilters = true } label: {
                        Label(filters.activeCount == 0 ? "Filters" : "Filters · \(filters.activeCount)", systemImage: "line.3.horizontal.decrease")
                            .font(.subheadline.weight(.semibold))
                    }.buttonStyle(.bordered).clipShape(.capsule)
                    Spacer()
                    Menu {
                        Picker("Group by", selection: $historyGrouping) {
                            ForEach(InboxGrouping.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Toggle("Color by card / account", isOn: $colorCodeByAccount)
                        Toggle("Hide personal transactions", isOn: $filters.excludePersonal)
                        Divider()
                        Button("Expand all groups", systemImage: "rectangle.expand.vertical") { collapsedGroups.removeAll() }
                        Button("Collapse all groups", systemImage: "rectangle.compress.vertical") {
                            collapsedGroups = Set(groups.map(\.id)); selected.removeAll()
                        }
                    } label: { Label("View", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold)) }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                if session.isRefreshingTransactions { ProgressView("Updating charges…") }
                if let error = filters.validationError { Text(error).foregroundStyle(.red) }
                if let error = session.reviewSyncError { Text(error).foregroundStyle(.orange) }
                if let error = session.transactionRefreshError { Text(error).foregroundStyle(.red) }
            }.listRowSeparator(.hidden)
            Section {
                HStack(spacing: 12) {
                    Button {
                        newExpanded.toggle()
                        if !newExpanded { selected.subtract(arrivals.map(\.id)) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle").foregroundStyle(.indigo)
                            Text("New").font(.headline)
                            Text(arrivals.count.formatted()).font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.indigo.opacity(0.1), in: .capsule)
                            Image(systemName: newExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New, \(arrivals.count) newly imported charges")
                    .accessibilityValue(newExpanded ? "Expanded" : "Collapsed")
                    Spacer(minLength: 4)
                    if !arrivals.isEmpty {
                        Button("Mark seen") { markNewSeen(arrivals) }
                            .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                            .accessibilityHint("Moves the \(arrivals.count) matching new charges into the grouped history without changing their review status.")
                    }
                }
                .listRowSeparator(.hidden)
                if newExpanded {
                    if arrivals.isEmpty {
                        Text(filters.activeCount > 0 || !search.isEmpty ? "No new charges match these filters." : "Newly imported charges will appear here.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(arrivals) { transaction in transactionLink(transaction, colors: colors) }
                    }
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView("No matching charges", systemImage: "tray", description: Text("Try different filters or pull to refresh. Credits and refunds are not shown in Inbox."))
                    .listRowBackground(Color.clear)
            }
            if !groups.isEmpty {
                Text(historyGrouping.sectionTitle).font(.headline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(groups) { group in
                Section {
                    InboxGroupHeader(group: group, expanded: !collapsedGroups.contains(group.id)) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if collapsedGroups.contains(group.id) { collapsedGroups.remove(group.id) }
                            else {
                                collapsedGroups.insert(group.id)
                                selected.subtract(group.transactions.map(\.id))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.transactions) { transaction in
                            transactionLink(transaction, colors: colors)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                InboxSummaryCard(transactions: filtered, filtering: filters.activeCount > 0 || !search.isEmpty)
                InboxAccountLegend(accounts: accountLegend, colors: colors)
            }.background(.regularMaterial)
        }
        .refreshable { await session.refreshTransactions(in: modelContext) }
        .task { await session.refreshTransactions(in: modelContext) }
        .onChange(of: accountKeys, initial: true) { _, _ in
            if let data = try? JSONEncoder().encode(accountColors) { savedAccountColors = data }
        }
        .onChange(of: search) { _, _ in collapsedGroups.removeAll(); newExpanded = true; selected.removeAll() }
        .onChange(of: filters) { _, _ in collapsedGroups.removeAll(); newExpanded = true; selected.removeAll() }
        .onChange(of: historyGrouping) { _, _ in collapsedGroups.removeAll(); selected.removeAll() }
        .onChange(of: arrivals.map(\.id)) { old, new in
            if !Set(new).subtracting(old).isEmpty { newExpanded = true }
        }
        .onChange(of: filters.excludePersonal) { _, hide in if hide && filters.state == .personal { filters.state = nil } }
        .searchable(text: $search, prompt: "Search charges")
        .sheet(isPresented: $showingFilters) { InboxFilterSheet(filters: $filters, transactions: visibleTransactions) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            if !selected.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Personal") { bulkSet(.personal) }
                    Spacer()
                    Button("Return to review") { bulkSet(.needsReview) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !undoActions.isEmpty {
                HStack { Text(lastAction); Spacer(); Button("Undo") { undo() } }
                    .padding().background(.regularMaterial).clipShape(.rect(cornerRadius: 14)).padding()
            }
        }
    }

    private func transactionLink(_ transaction: TransactionRecord, colors: [String: Int]) -> some View {
        NavigationLink { SplitEditorView(transaction: transaction) } label: {
            TransactionRow(transaction: transaction, accountColor: colorCodeByAccount ? AccountColors.color(for: transaction.accountColorKey, in: colors) : nil)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 14))
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        .tag(transaction.id)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if transaction.canClassify {
                Button { set(transaction, to: transaction.state == .personal ? .needsReview : .sharedDraft) } label: {
                    Label(transaction.state == .personal ? "Return to review" : "Shared", systemImage: "person.2.fill")
                }.tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if transaction.canClassify && transaction.state != .personal {
                Button { set(transaction, to: .personal) } label: { Label("Personal", systemImage: "person.fill") }.tint(.gray)
            }
        }
    }

    private func markNewSeen(_ records: [TransactionRecord]) {
        records.forEach { $0.newImportDismissed = true }
        selected.subtract(records.map(\.id))
        // Reveal the destination groups; "seen" never changes review or approval state.
        collapsedGroups.removeAll()
        do { try modelContext.save() }
        catch {
            records.forEach { $0.newImportDismissed = false }
            session.reviewSyncError = "Could not mark charges seen: \(error.localizedDescription)"
        }
    }

    private func set(_ transaction: TransactionRecord, to state: ReviewState) {
        apply([transaction], state: state)
    }
    private func undo() {
        for (id, state) in undoActions {
            if let transaction = allTransactions.first(where: { $0.id == id }), transaction.canClassify {
                transaction.state = state; transaction.reviewNeedsSync = !session.isDemoMode
            }
        }
        undoActions = []; persistReviews()
    }
    private func bulkSet(_ state: ReviewState) {
        apply(filtered.filter { selected.contains($0.id) }, state: state)
        selected.removeAll()
    }
    private func apply(_ records: [TransactionRecord], state: ReviewState) {
        let editable = records.filter { $0.canClassify && $0.state != state }
        guard !editable.isEmpty else { return }
        undoActions = editable.map { ($0.id, $0.state) }
        editable.forEach { $0.state = state; $0.reviewNeedsSync = !session.isDemoMode }
        lastAction = "\(editable.count) marked \(state.title.lowercased())"
        persistReviews()
    }
    private func persistReviews() {
        do {
            try modelContext.save()
            Task { await session.syncReviewDecisions(in: modelContext) }
        } catch { session.reviewSyncError = error.localizedDescription }
    }
}

struct SplitEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    let transaction: TransactionRecord
    @Query private var rules: [SuggestionRule]
    @State private var friends: [SplitwiseFriend] = []
    @State private var groups: [FriendGroup] = []
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
                LabeledContent("Category", value: TransactionClassification.category(for: transaction).name)
                if TransactionClassification.category(for: transaction).inferred { Text("Suggested from the merchant name.").font(.caption).foregroundStyle(.secondary) }
                if let detail = transaction.categoryDetail { LabeledContent("Detail", value: TransactionClassification.title(detail)) }
                LabeledContent("Location", value: transaction.locationLabel)
                LabeledContent("Channel", value: transaction.paymentChannel ?? "Unknown")
            }
            Section {
                if transaction.canClassify {
                    Button(transaction.state == .personal ? "Return to splitting review" : "Mark as personal — exclude from splitting") {
                        transaction.state = transaction.state == .personal ? .needsReview : .personal
                        transaction.reviewNeedsSync = !session.isDemoMode
                        do { try modelContext.save(); Task { await session.syncReviewDecisions(in: modelContext) } }
                        catch { session.reviewSyncError = error.localizedDescription }
                    }
                }
                if transaction.state == .personal { Text("Personal transaction. It cannot be approved or published unless you return it to review.") }
                if transaction.isCredit { Text("Credit or refund. This is not a splittable charge.") }
                if let error = session.reviewSyncError { Text(error).foregroundStyle(.orange) }
            }
            Section {
                Picker("Split", selection: $exactMode) {
                    Text("Equally").tag(false); Text("Exact amounts").tag(true)
                }.pickerStyle(.segmented)
                if friends.isEmpty {
                    Label("Connect Splitwise from Cards & Accounts to load friends and groups.", systemImage: "person.2.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
            if !groups.isEmpty {
                Section("Quick groups") {
                    ForEach(groups) { group in
                        Button {
                            selected = Set(group.friendIDs.filter { id in friends.contains(where: { $0.id == id }) })
                        } label: {
                            HStack { Label(group.name, systemImage: "person.3.fill"); Spacer(); Text("\(group.friendIDs.count)").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                Button("Approve and add to outbox") { approve() }
                    .frame(maxWidth: .infinity).disabled(selected.isEmpty || !amountIsValid || !transaction.canSplit)
            }
        }
        .navigationTitle("Split expense").navigationBarTitleDisplayMode(.inline)
        .task {
            applySuggestion()
            if session.isDemoMode { friends = DemoData.friends; return }
            do {
                async let liveFriends = session.api.friends()
                async let liveGroups = session.api.friendGroups()
                friends = try await liveFriends
                groups = try await liveGroups
            } catch { }
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
        guard transaction.canSplit, !selected.isEmpty, amountIsValid else { return }
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
