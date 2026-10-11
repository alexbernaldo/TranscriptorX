import AppKit
import EventKit

enum MeetingState {
    case none
    case detected(app: String, suggestedTitle: String?)

    var currentSuggestedTitle: String? {
        if case .detected(_, let title) = self { return title }
        return nil
    }
}

/// Detects when a meeting app (Zoom, Teams, Discord, FaceTime, Slack huddle)
/// comes to the front and publishes a suggested calendar-event title.
/// v1 never records automatically — it only posts `.meetingDetected`.
final class MeetingWatcherService: ObservableObject {
    static let shared = MeetingWatcherService()

    @Published var meetingState: MeetingState = .none {
        didSet {
            guard case .detected(let app, _) = meetingState else { return }
            let shouldNotify: Bool
            if case .detected(let oldApp, _) = oldValue {
                shouldNotify = oldApp != app
            } else {
                shouldNotify = true
            }
            guard shouldNotify else { return }
            var userInfo: [String: Any] = ["app": app]
            if let title = meetingState.currentSuggestedTitle {
                userInfo["suggestedTitle"] = title
            }
            NotificationCenter.default.post(name: .meetingDetected, object: nil, userInfo: userInfo)
        }
    }

    private var timer: Timer?
    private var lastBundleId: String?
    private let meetingBundleIds: Set<String> = [
        "com.zoom.xos", "us.zoom.xos", "com.microsoft.teams2",
        "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime", "com.discordapp.Discord"
    ]

    private init() {}

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }

    func start(enabled: Bool) {
        guard enabled else {
            stop()
            return
        }
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
        AppLogger.shared.log("MeetingWatcher started", category: .app)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastBundleId = nil
        if case .detected = meetingState {
            meetingState = .none
        }
        AppLogger.shared.log("MeetingWatcher stopped", category: .app)
    }

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return }
        if meetingBundleIds.contains(bid) {
            guard lastBundleId != bid else { return }
            lastBundleId = bid
            let name = app.localizedName ?? bid
            Task { [weak self] in
                await self?.detectTitle(appName: name, bundleId: bid)
            }
        } else if lastBundleId != nil {
            lastBundleId = nil
            meetingState = .none
        }
    }

    private func detectTitle(appName: String, bundleId: String) async {
        let store = EKEventStore()
        // Calendar access is requested only when the user turns on «Detectar reuniones» (spec 8.5);
        // here it is only read if already granted.
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = status == .fullAccess
        } else {
            granted = status == .authorized
        }

        var eventTitle: String?
        if granted {
            let now = Date()
            let pred = store.predicateForEvents(
                withStart: now.addingTimeInterval(-300),
                end: now.addingTimeInterval(300),
                calendars: nil
            )
            let events = store.events(matching: pred)
            eventTitle = events.first(where: { $0.startDate <= now && $0.endDate >= now })?.title
                ?? events.first?.title
        } else {
            AppLogger.shared.log(
                "Calendar access denied — using fallback meeting title",
                category: .app
            )
        }

        let suggested = eventTitle ?? String(
            format: localized("Reunión en %@", "Meeting in %@"),
            appName
        )
        await MainActor.run { [weak self] in
            self?.meetingState = .detected(app: appName, suggestedTitle: suggested)
        }
    }
}
