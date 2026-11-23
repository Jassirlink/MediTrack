import SwiftUI
import UIKit
import UserNotifications

@main
@MainActor
struct MediTrackApp: App {
    @UIApplicationDelegateAdaptor(MediTrackAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            switch AppComposition.shared.model {
            case .success(let model):
                TodayView(model: model)
            case .failure:
                ContentUnavailableView(
                    "MediTrack couldn’t open",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Close and reopen the app to try loading your saved medications again.")
                )
            }
        }
    }
}

@MainActor
final class MediTrackAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppComposition.shared.configureNotifications()
        return true
    }
}

@MainActor
private final class AppComposition {
    static let shared = AppComposition()

    let model: Result<MediTrackModel, Error>
    private let reminders = LocalReminders(center: .current())
    private lazy var notificationDelegate = DoseNotificationDelegate { [weak self] action, payload in
        guard let self, case .success(let model) = self.model else { return }
        await model.handleReminder(action, payload: payload)
    }

    private init() {
        let reminders = reminders
        model = Result {
            guard let fixtureURL = Bundle.main.url(forResource: "medications", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let fixture = try Data(contentsOf: fixtureURL)
            let store = SwiftDataMedicationStore(container: try SwiftDataMedicationStore.makeContainer())
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let demo = arguments.contains("-demo-controls")
            let alwaysSucceed = demo && arguments.contains("-demo-success")
            let offline = demo && arguments.contains("-demo-offline")
            #else
            let demo = false
            let alwaysSucceed = false
            let offline = false
            #endif
            let transport = ClinicMockTransport(fixture: fixture) { alwaysSucceed || Int.random(in: 0..<10) < 7 }
            let api = APIClient(baseURL: URL(string: "https://clinic.example")!, transport: transport)
            return try MediTrackModel(
                store: store, api: api, connectivity: NetworkConnectivity(), reminders: reminders,
                showsDemoControls: demo, demoOffline: offline
            )
        }
    }

    func configureNotifications() {
        reminders.configure(delegate: notificationDelegate)
    }
}
