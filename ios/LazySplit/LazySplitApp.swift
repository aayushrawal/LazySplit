import SwiftUI
import SwiftData
import UIKit

@main
struct LazySplitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
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
    var onboardingStep: OnboardingStep = .welcome
    var lastError: String?
    let api = APIClient()

    func useDemoMode() {
        isAuthenticated = true
        onboardingStep = .complete
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, splitwise, cards, history, complete
}
