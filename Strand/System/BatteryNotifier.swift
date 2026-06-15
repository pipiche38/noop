import Foundation
import UserNotifications

/// Surfaces the strap battery state as a user notification — a LOW warning when the cell falls to
/// the threshold so the user can top up before tonight's sleep, and a CHARGED note when it reaches
/// 100%. Mirrors `IllnessNotifier`: requestAuthorization() up front when the toggle is enabled,
/// status-only check at fire time, and the persisted gate advances even when delivery is deferred.
/// On-device only; gated behind the user's "Battery alerts" setting (default ON) by the caller (#368).
enum BatteryNotifier {
    private static let lowAlertedKey = "behavior.batteryLowAlerted"
    private static let fullAlertedKey = "behavior.batteryFullAlerted"

    /// Pure crossing-with-hysteresis policy, identical on macOS/iOS and Android (#368). The two
    /// `*Alerted` flags are PERSISTED, so they survive process death — and the 25% re-arm band means
    /// a 14↔15% jitter fires the low alert exactly once per discharge cycle (no in-memory prevPct
    /// crossing that re-fires on every bounce and resets on restart). Full re-arms only below 100.
    enum BatteryAlertPolicy {
        static let lowThreshold = 15
        static let lowRearmAbove = 25
        static let fullThreshold = 100

        /// `charging == nil` means unknown — the low alert still fires (only a confirmed `true`
        /// suppresses it). Returns the fire decisions plus the next persisted flag state.
        static func evaluate(pct: Int,
                             charging: Bool?,
                             lowAlerted: Bool,
                             fullAlerted: Bool)
            -> (fireLow: Bool, fireFull: Bool, newLowAlerted: Bool, newFullAlerted: Bool) {
            var low = lowAlerted
            var full = fullAlerted
            // Re-arm (hysteresis) so jitter near a threshold can't re-fire.
            if charging == true || pct >= lowRearmAbove { low = false }
            if pct < fullThreshold { full = false }
            // Fire at most once per genuine crossing.
            let fireLow = !low && pct <= lowThreshold && charging != true
            let fireFull = !full && pct >= fullThreshold
            if fireLow { low = true }
            if fireFull { full = true }
            return (fireLow, fireFull, low, full)
        }
    }

    /// Ask up front (called when the user enables the alerts) so the system dialog appears at a
    /// predictable moment, not on the first low-battery crossing.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy against a fresh battery reading and post at most one notification per genuine
    /// crossing. No-op when the setting is off. The persisted flags are written back ALWAYS (so the
    /// gate advances even if the user declined notifications or delivery is deferred — mirroring how
    /// `IllnessNotifier` marks the day up front).
    static func onBatteryUpdate(pct: Int, charging: Bool?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryAlertPolicy.evaluate(
            pct: pct,
            charging: charging,
            lowAlerted: d.bool(forKey: lowAlertedKey),
            fullAlerted: d.bool(forKey: fullAlertedKey))
        // Advance the persisted gate up front so the once-per-crossing limit holds regardless of
        // authorization or delivery — the in-app battery surfaces stay the live view either way.
        d.set(result.newLowAlerted, forKey: lowAlertedKey)
        d.set(result.newFullAlerted, forKey: fullAlertedKey)
        if result.fireLow {
            post(identifier: "battery-low",
                 title: "Low battery",
                 body: "Recharge your WHOOP before tonight.")
        }
        if result.fireFull {
            post(identifier: "battery-full",
                 title: "Strap fully charged",
                 body: "Your WHOOP is at 100%.")
        }
    }

    private static func post(identifier: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when alerts are enabled; here
        // we only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: nil))
        }
    }
}
