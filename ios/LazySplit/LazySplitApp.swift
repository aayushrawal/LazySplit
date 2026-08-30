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
    var onboardingStep: OnboardingStep = .welcome
    var lastError: String?
    var isRefreshingTransactions = false
    var transactionRefreshError: String?
    let api = APIClient()

    func refreshTransactions(in context: ModelContext) async {
        guard !isDemoMode, isAuthenticated, !isRefreshingTransactions else { return }
        let sessionToken = KeychainStore.read("sessionToken")
        guard sessionToken != nil else { return }
        isRefreshingTransactions = true
        defer { isRefreshingTransactions = false }
        do {
            let remote = try await api.transactions()
            guard !isDemoMode, isAuthenticated, KeychainStore.read("sessionToken") == sessionToken else { return }
            let existing = try context.fetch(FetchDescriptor<TransactionRecord>()).filter { !$0.isDemo }
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for item in remote {
                if let current = byID[item.id] {
                    current.externalID = item.externalID; current.sourceRaw = item.source.rawValue
                    current.accountName = item.accountName; current.accountMask = item.accountMask
                    current.merchant = item.merchant; current.originalDescription = item.originalDescription
                    current.date = item.date; current.amountMinor = item.amountMinor; current.currencyCode = item.currencyCode
                    // Refresh financial fields without discarding offline review decisions or drafts.
                    if current.state == .pending || current.state == .needsReview || item.state == .published {
                        current.state = item.state
                    }
                    current.category = item.category; current.fingerprint = item.fingerprint
                    current.possibleDuplicateID = item.possibleDuplicateID
                } else {
                    let record = TransactionRecord(id: item.id, externalID: item.externalID, source: item.source, accountName: item.accountName, accountMask: item.accountMask, merchant: item.merchant, originalDescription: item.originalDescription, date: item.date, amountMinor: item.amountMinor, currencyCode: item.currencyCode, state: item.state, category: item.category, fingerprint: item.fingerprint)
                    record.possibleDuplicateID = item.possibleDuplicateID
                    context.insert(record); byID[item.id] = record
                }
            }
            try context.save()
            transactionRefreshError = nil
        } catch {
            transactionRefreshError = "Could not refresh transactions: \(error.localizedDescription)"
        }
    }

    func useDemoMode() {
        KeychainStore.delete("sessionToken")
        isDemoMode = true
        isAuthenticated = true
        onboardingStep = .complete
    }

    func completeAuthentication() {
        isDemoMode = false
        isAuthenticated = true
        onboardingStep = .complete
    }

    func signOut() {
        KeychainStore.delete("sessionToken")
        isDemoMode = false
        isAuthenticated = false
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, splitwise, cards, history, complete
}
