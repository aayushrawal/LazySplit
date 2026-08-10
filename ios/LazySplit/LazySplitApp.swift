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
    let api = APIClient()

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
