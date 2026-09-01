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
    let api = APIClient()

    func refreshTransactions(in context: ModelContext) async {
        guard !isDemoMode, isAuthenticated, !isRefreshingTransactions else { return }
        let sessionToken = KeychainStore.read("sessionToken")
        guard sessionToken != nil else { return }
        isRefreshingTransactions = true
        defer { isRefreshingTransactions = false }
        do {
            await syncReviewDecisions(in: context)
            // A swipe or Undo may finish syncing while this read is in flight.
            let snapshots = try context.fetch(FetchDescriptor<TransactionRecord>()).filter { !$0.isDemo }
            let reviewVersions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, ($0.updatedAt, $0.reviewNeedsSync)) })
            let remote = try await api.transactions()
            guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == sessionToken else { return }
            let existing = try context.fetch(FetchDescriptor<TransactionRecord>()).filter { !$0.isDemo }
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let receivedAt = Date.now
            for item in remote {
                if let current = byID[item.id] {
                    current.externalID = item.externalID; current.sourceRaw = item.source.rawValue
                    current.accountName = item.accountName; current.accountMask = item.accountMask
                    current.merchant = item.merchant; current.originalDescription = item.originalDescription
                    current.date = item.date; current.amountMinor = item.amountMinor; current.currencyCode = item.currencyCode
                    // Refresh financial fields without discarding offline review decisions or drafts.
                    let unchanged = reviewVersions[current.id].map { $0.0 == current.updatedAt && !$0.1 } ?? false
                    if unchanged && !current.reviewNeedsSync && ([.pending, .needsReview, .personal, .sharedDraft].contains(current.state) || item.state == .published) {
                        if current.state == .pending && item.state == .needsReview { current.inboxReceivedAt = receivedAt }
                        current.state = item.state
                    }
                    current.category = item.category; current.fingerprint = item.fingerprint
                    current.possibleDuplicateID = item.possibleDuplicateID
                } else {
                    let record = TransactionRecord(id: item.id, externalID: item.externalID, source: item.source, accountName: item.accountName, accountMask: item.accountMask, merchant: item.merchant, originalDescription: item.originalDescription, date: item.date, amountMinor: item.amountMinor, currencyCode: item.currencyCode, state: item.state, category: item.category, fingerprint: item.fingerprint)
                    record.possibleDuplicateID = item.possibleDuplicateID
                    record.reviewHasSynced = true
                    record.inboxReceivedAt = receivedAt
                    context.insert(record); byID[item.id] = record
                }
                if let current = byID[item.id] {
                    current.accountID = item.accountID
                    current.categoryDetail = item.categoryDetail; current.city = item.city; current.region = item.region
                    current.country = item.country; current.paymentChannel = item.paymentChannel; current.isCredit = item.isCredit ?? false
                }
            }
            try context.save()
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
            // Serialize changes; if Undo runs during a request, send its newer decision next.
            while let record = try context.fetch(FetchDescriptor<TransactionRecord>()).first(where: { !$0.isDemo && $0.reviewNeedsSync }) {
                guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == token else { return }
                let state = record.state
                try await api.setReview(id: record.id, state: state)
                guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == token else { return }
                if record.state == state { record.reviewNeedsSync = false; record.reviewHasSynced = true }
                try context.save()
            }
            reviewSyncError = nil
        } catch {
            reviewSyncError = "Review changes are saved on this phone and will retry on refresh: \(error.localizedDescription)"
        }
    }

    func useDemoMode() {
        demoAccounts = []
        demoFriends = []
        KeychainStore.delete("sessionToken")
        isDemoMode = true
        isAuthenticated = true
        onboardingStep = .complete
    }

    func completeAuthentication() {
        demoAccounts = []
        demoFriends = []
        isDemoMode = false
        isAuthenticated = true
        onboardingStep = .complete
    }

    func signOut() {
        demoAccounts = []
        demoFriends = []
        KeychainStore.delete("sessionToken")
        isDemoMode = false
        isAuthenticated = false
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, splitwise, cards, history, complete
}
