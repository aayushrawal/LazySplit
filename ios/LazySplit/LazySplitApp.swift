import SwiftUI
import SwiftData
import UIKit
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct LazySplitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .onOpenURL { url in
                    #if canImport(GoogleSignIn)
                    GIDSignIn.sharedInstance.handle(url)
                    #endif
                }
        }
        .modelContainer(for: [TransactionRecord.self, SplitDraft.self, SplitParticipant.self, SuggestionRule.self, ImportBatch.self, ExportAttempt.self])
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        NotificationCenter.default.post(name: .didReceiveAPNSToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .didFailAPNSRegistration, object: error.localizedDescription)
    }
}

extension Notification.Name {
    static let didReceiveAPNSToken = Notification.Name("LazySplit.didReceiveAPNSToken")
    static let didFailAPNSRegistration = Notification.Name("LazySplit.didFailAPNSRegistration")
}

@MainActor
@Observable
final class AppSession {
    var isAuthenticated = KeychainStore.read("sessionToken") != nil
    var isDemoMode = false
    var demoFriends: [SplitwiseFriend] = []
    var demoAccounts: [StatementAccount] = []
    var onboardingStep: OnboardingStep = .welcome
    var lastError: String?
    var isRefreshingTransactions = false
    var transactionRefreshError: String?
    var reviewSyncError: String?
    private var isSyncingReviews = false
    private var scheduledReviewPersistence: Task<Void, Never>?
    private var scheduledReviewSync: Task<Void, Never>?
    private var lastRefreshFinishedAt: Date?
    private static let transactionSyncKey = "transactions.lastSuccessfulSyncAt"
    let api = APIClient()

    func refreshTransactions(in context: ModelContext, force: Bool = false) async {
        guard !isDemoMode, isAuthenticated, !isRefreshingTransactions else { return }
        if !force, let lastRefreshFinishedAt, Date.now.timeIntervalSince(lastRefreshFinishedAt) < 30 { return }
        let sessionToken = KeychainStore.read("sessionToken")
        guard sessionToken != nil else { return }
        isRefreshingTransactions = true
        defer { isRefreshingTransactions = false }
        do {
            await syncReviewDecisions(in: context)
            // A swipe or Undo may finish syncing while this read is in flight.
            let existing = try context.fetch(FetchDescriptor<TransactionRecord>()).filter { !$0.isDemo }
            let reviewVersions = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, ($0.updatedAt, $0.reviewNeedsSync)) })
            let storedTimestamp = UserDefaults.standard.object(forKey: Self.transactionSyncKey) as? Date
            let result = try await api.transactions(updatedAfter: storedTimestamp)
            guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == sessionToken else { return }
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let deletedIDs = Set(result.transactions.lazy.filter(\.deleted).map(\.id))
            var retainedRemovedIDs = Set<UUID>()
            if !deletedIDs.isEmpty {
                let drafts = try context.fetch(FetchDescriptor<SplitDraft>()).filter { deletedIDs.contains($0.transactionID) }
                let draftIDs = Set(drafts.map(\.id))
                retainedRemovedIDs = Set(drafts.map(\.transactionID))
                if !draftIDs.isEmpty {
                    for attempt in try context.fetch(FetchDescriptor<ExportAttempt>()) where draftIDs.contains(attempt.draftID) && attempt.status != "published" {
                        attempt.status = "removed"
                        attempt.errorMessage = "The source transaction was removed by the financial institution and cannot be published."
                    }
                }
            }
            let receivedAt = Date.now
            for item in result.transactions {
                if item.deleted {
                    if let current = byID.removeValue(forKey: item.id) {
                        if retainedRemovedIDs.contains(item.id) { current.isRemovedFromSource = true }
                        else { context.delete(current) }
                    }
                    continue
                }
                if let current = byID[item.id] {
                    if current.isRemovedFromSource { current.isRemovedFromSource = false }
                    if current.externalID != item.externalID { current.externalID = item.externalID }
                    if current.sourceRaw != item.source.rawValue { current.sourceRaw = item.source.rawValue }
                    if current.accountName != item.accountName { current.accountName = item.accountName }
                    if current.accountMask != item.accountMask { current.accountMask = item.accountMask }
                    if current.merchant != item.merchant { current.merchant = item.merchant }
                    if current.originalDescription != item.originalDescription { current.originalDescription = item.originalDescription }
                    if current.date != item.date { current.date = item.date }
                    if current.amountMinor != item.amountMinor { current.amountMinor = item.amountMinor }
                    if current.currencyCode != item.currencyCode { current.currencyCode = item.currencyCode }
                    // Refresh financial fields without discarding offline review decisions or drafts.
                    let unchanged = reviewVersions[current.id].map { $0.0 == current.updatedAt && !$0.1 } ?? false
                    if unchanged && !current.reviewNeedsSync && current.state != item.state && ([.pending, .needsReview, .personal, .sharedDraft].contains(current.state) || item.state == .published) {
                        if current.state == .pending && item.state == .needsReview { current.inboxReceivedAt = receivedAt }
                        current.state = item.state
                    }
                    if current.category != item.category { current.category = item.category }
                    if current.fingerprint != item.fingerprint { current.fingerprint = item.fingerprint }
                    if current.possibleDuplicateID != item.possibleDuplicateID { current.possibleDuplicateID = item.possibleDuplicateID }
                } else {
                    let record = TransactionRecord(id: item.id, externalID: item.externalID, source: item.source, accountName: item.accountName, accountMask: item.accountMask, merchant: item.merchant, originalDescription: item.originalDescription, date: item.date, amountMinor: item.amountMinor, currencyCode: item.currencyCode, state: item.state, category: item.category, fingerprint: item.fingerprint)
                    record.possibleDuplicateID = item.possibleDuplicateID
                    record.reviewHasSynced = true
                    record.inboxReceivedAt = receivedAt
                    context.insert(record); byID[item.id] = record
                }
                if let current = byID[item.id] {
                    if current.accountID != item.accountID { current.accountID = item.accountID }
                    if current.categoryDetail != item.categoryDetail { current.categoryDetail = item.categoryDetail }
                    if current.city != item.city { current.city = item.city }
                    if current.region != item.region { current.region = item.region }
                    if current.country != item.country { current.country = item.country }
                    if current.paymentChannel != item.paymentChannel { current.paymentChannel = item.paymentChannel }
                    if current.isCredit != (item.isCredit ?? false) { current.isCredit = item.isCredit ?? false }
                }
            }
            try context.save()
            UserDefaults.standard.set(result.syncTimestamp, forKey: Self.transactionSyncKey)
            lastRefreshFinishedAt = .now
            transactionRefreshError = nil
        } catch {
            transactionRefreshError = "Could not refresh transactions: \(error.localizedDescription)"
        }
    }

    func syncReviewDecisions(in context: ModelContext) async {
        guard !isDemoMode, isAuthenticated, !isSyncingReviews else { return }
        isSyncingReviews = true
        defer { isSyncingReviews = false }
        let token = KeychainStore.read("sessionToken")
        do {
            // Preserve personal/shared decisions made in versions that only saved them locally.
            for record in try context.fetch(FetchDescriptor<TransactionRecord>()) where !record.isDemo && !record.reviewHasSynced && [.personal, .sharedDraft].contains(record.state) {
                record.reviewNeedsSync = true
            }
            try context.save()
            // Send bounded batches instead of issuing one network request and one SwiftData fetch per swipe.
            let pending = try context.fetch(FetchDescriptor<TransactionRecord>()).filter { !$0.isDemo && $0.reviewNeedsSync }
            for batchStart in stride(from: 0, to: pending.count, by: 500) {
                guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == token else { return }
                let batch = Array(pending[batchStart..<min(batchStart + 500, pending.count)])
                let versions = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.state) })
                try await api.setReviews(batch.map { ReviewUpdate(id: $0.id, state: $0.state) })
                guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == token else { return }
                for record in batch where record.state == versions[record.id] {
                    record.reviewNeedsSync = false; record.reviewHasSynced = true
                }
                try context.save()
            }
            reviewSyncError = nil
        } catch {
            reviewSyncError = "Review changes are saved on this phone and will retry on refresh: \(error.localizedDescription)"
        }
    }

    func scheduleReviewSync(in context: ModelContext) {
        scheduledReviewSync?.cancel()
        scheduledReviewSync = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.syncReviewDecisions(in: context)
        }
    }

    func scheduleReviewPersistence(in context: ModelContext) {
        scheduledReviewPersistence?.cancel()
        scheduledReviewPersistence = Task { [weak self] in
            // Let SwiftUI present the new classification before doing disk I/O.
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            do {
                try context.save()
                self.scheduleReviewSync(in: context)
            } catch {
                self.reviewSyncError = "Could not save review changes: \(error.localizedDescription)"
            }
        }
    }

    func useDemoMode() {
        demoAccounts = []
        demoFriends = []
        KeychainStore.delete("sessionToken")
        UserDefaults.standard.removeObject(forKey: Self.transactionSyncKey)
        lastRefreshFinishedAt = nil
        isDemoMode = true
        isAuthenticated = true
        onboardingStep = .complete
    }

    func completeAuthentication() {
        demoAccounts = []
        demoFriends = []
        isDemoMode = false
        isAuthenticated = true
        UserDefaults.standard.removeObject(forKey: Self.transactionSyncKey)
        lastRefreshFinishedAt = nil
        onboardingStep = .complete
    }

    func signOut() {
        demoAccounts = []
        demoFriends = []
        KeychainStore.delete("sessionToken")
        UserDefaults.standard.removeObject(forKey: Self.transactionSyncKey)
        lastRefreshFinishedAt = nil
        isDemoMode = false
        isAuthenticated = false
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, splitwise, cards, history, complete
}
