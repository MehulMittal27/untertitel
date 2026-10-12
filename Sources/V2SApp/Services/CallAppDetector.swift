import Foundation

/// What an app is doing with audio right now, as macOS reports it per process.
enum AppAudioActivity: Int, Comparable, Sendable {
    case idle = 0
    /// Playing sound.
    case playing = 1
    /// Using the microphone and playing sound at the same time: a call.
    case inCall = 2

    static func < (lhs: AppAudioActivity, rhs: AppAudioActivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(isRunningInput: Bool, isRunningOutput: Bool) {
        if isRunningOutput {
            self = isRunningInput ? .inCall : .playing
        } else {
            self = .idle
        }
    }
}

/// The apps calls usually happen in, in the order they are preferred when nothing
/// else tells two of them apart.
enum CallAppCatalog {
    /// Safari first: Meet and Teams in the browser are where the calls are. Then the
    /// dedicated call apps, then the other browsers.
    static let bundleIDs: [String] = [
        "com.apple.Safari",
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "net.whatsapp.WhatsApp",
        "org.whispersystems.signal-desktop",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
    ]

    static func isCallApp(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Lower is preferred. Apps that are not in the list come after all that are.
    static func priority(ofBundleID bundleID: String) -> Int {
        bundleIDs.firstIndex(of: bundleID) ?? bundleIDs.count
    }
}

struct CallAppCandidate: Equatable, Sendable {
    let sourceID: String
    let bundleID: String
    var activity: AppAudioActivity
    /// The user has chosen this app before, or run a session on it.
    var isApproved: Bool
    var lastActivatedAt: Date?
}

struct CallAppDetection: Equatable, Sendable {
    /// The approved app to listen to. Nil when none is running, or when an app the user
    /// has not approved looks like the call instead.
    var pick: String?
    /// A call app the user has not approved, to offer in the popover. Never started.
    var suggestion: String?
    var suggestionActivity: AppAudioActivity = .idle
}

/// Chooses what to listen to. It only ever picks an app the user has approved: an
/// unapproved one is offered, never started.
enum CallAppDetector {
    static func detect(_ candidates: [CallAppCandidate]) -> CallAppDetection {
        let bestApproved = candidates.filter(\.isApproved).min(by: isPreferred)

        let unapprovedCallApps = candidates.filter {
            $0.isApproved == false && CallAppCatalog.isCallApp(bundleID: $0.bundleID)
        }
        // Offered when it looks like a call. A call app that is merely playing is only
        // offered when there is nothing approved to listen to, so the user is not
        // nagged about music in another browser.
        var suggestion = unapprovedCallApps.filter { $0.activity == .inCall }.min(by: isPreferred)
        if suggestion == nil, bestApproved == nil {
            suggestion = unapprovedCallApps.filter { $0.activity == .playing }.min(by: isPreferred)
        }

        var pick = bestApproved
        // The call is evidently somewhere else. Starting on the approved app would
        // show nothing, and in cloud mode could bill for whatever plays in it later.
        if let suggestion, let approved = bestApproved, suggestion.activity > approved.activity {
            pick = nil
        }

        return CallAppDetection(
            pick: pick?.sourceID,
            suggestion: suggestion?.sourceID,
            suggestionActivity: suggestion?.activity ?? .idle
        )
    }

    /// In a call beats playing beats running; then the catalog order; then whichever
    /// app the user was in most recently.
    static func isPreferred(_ lhs: CallAppCandidate, over rhs: CallAppCandidate) -> Bool {
        if lhs.activity != rhs.activity {
            return lhs.activity > rhs.activity
        }

        let lhsPriority = CallAppCatalog.priority(ofBundleID: lhs.bundleID)
        let rhsPriority = CallAppCatalog.priority(ofBundleID: rhs.bundleID)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsActivated = lhs.lastActivatedAt ?? .distantPast
        let rhsActivated = rhs.lastActivatedAt ?? .distantPast
        if lhsActivated != rhsActivated {
            return lhsActivated > rhsActivated
        }

        return lhs.sourceID < rhs.sourceID
    }
}
