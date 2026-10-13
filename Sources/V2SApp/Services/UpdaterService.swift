import AppKit
import Combine
import Foundation
import ServiceManagement
import os.log
import Sparkle

/// Whether this build has somewhere to get updates from.
enum UpdateFeed {
    static func isConfigured(in infoDictionary: [String: Any]?) -> Bool {
        guard let feed = infoDictionary?["SUFeedURL"] as? String else {
            return false
        }

        return feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    /// False when the build has no update feed. Sparkle is then never created, so
    /// nothing checks for updates, and Settings shows no update controls.
    let isAvailable: Bool
    private let updaterController: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private(set) var isStarted = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isStarted,
                  let updater = updaterController?.updater,
                  automaticallyChecksForUpdates != updater.automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init(isAvailable: Bool = UpdateFeed.isConfigured(in: Bundle.main.infoDictionary)) {
        self.isAvailable = isAvailable
        self.updaterController = isAvailable
            ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        self.automaticallyChecksForUpdates = false
        start()
    }

    func checkForUpdates() {
        guard isStarted else { return }
        updaterController?.checkForUpdates(nil)
    }

    private func start() {
        guard let updater = updaterController?.updater else {
            Logger.updater.info("No update feed in this build: the updater stays off")
            return
        }

        do {
            try updater.start()
            isStarted = true
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            observation = updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newValue in
                    guard let self, self.automaticallyChecksForUpdates != newValue else { return }
                    self.automaticallyChecksForUpdates = newValue
                }
        } catch {
            Logger.updater.warning("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    private let appService = SMAppService.mainApp
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var launchesAtLogin = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var updateErrorMessage: String?

    init(notificationCenter: NotificationCenter = .default) {
        refreshStatus()

        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
            }
            .store(in: &cancellables)
    }

    func setLaunchesAtLogin(_ shouldLaunchAtLogin: Bool) {
        updateErrorMessage = nil

        do {
            if shouldLaunchAtLogin {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            Logger.launchAtLogin.error(
                "Failed to update launch-at-login setting: \(error.localizedDescription, privacy: .public)"
            )
            updateErrorMessage = error.localizedDescription
        }

        refreshStatus()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshStatus() {
        switch appService.status {
        case .enabled:
            launchesAtLogin = true
            requiresApproval = false
            updateErrorMessage = nil
        case .requiresApproval:
            launchesAtLogin = true
            requiresApproval = true
            updateErrorMessage = nil
        case .notRegistered:
            launchesAtLogin = false
            requiresApproval = false
        case .notFound:
            launchesAtLogin = false
            requiresApproval = false
        @unknown default:
            launchesAtLogin = false
            requiresApproval = false
        }
    }
}

private extension Logger {
    static let updater = Logger(subsystem: "com.franklioxygen.v2s", category: "updater")
    static let launchAtLogin = Logger(subsystem: "com.franklioxygen.v2s", category: "launchAtLogin")
}
