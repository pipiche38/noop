package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent

/**
 * Pure battery-alert decision logic so it's JVM-testable (IllnessAlertPolicy idiom). The two
 * `*Alerted` flags are PERSISTED state (NoopPrefs), so the decision survives process death — no
 * in-memory previous-pct crossing, which would re-fire on every 15↔14 jitter and reset on restart.
 *
 * A 25% re-arm band (hysteresis) means a battery hovering near 15% fires the low alert exactly once
 * per discharge cycle; the full alert re-arms only after the cell drops back below 100%.
 */
internal object BatteryAlertPolicy {
    const val LOW_THRESHOLD = 15
    const val LOW_REARM_ABOVE = 25
    const val FULL_THRESHOLD = 100

    data class Decision(
        val fireLow: Boolean,
        val fireFull: Boolean,
        val newLowAlerted: Boolean,
        val newFullAlerted: Boolean,
    )

    /**
     * @param pct          current strap battery percentage (rounded to Int)
     * @param charging     charging state (null = unknown)
     * @param lowAlerted   persisted: has the low alert already fired this discharge cycle?
     * @param fullAlerted  persisted: has the full alert already fired since the last drop below 100?
     */
    fun evaluate(pct: Int, charging: Boolean?, lowAlerted: Boolean, fullAlerted: Boolean): Decision {
        var low = lowAlerted
        var full = fullAlerted
        // Re-arm (hysteresis) so jitter near a threshold can't re-fire.
        if (charging == true || pct >= LOW_REARM_ABOVE) low = false
        if (pct < FULL_THRESHOLD) full = false
        // Fire at most once per genuine crossing.
        val fireLow = !low && pct <= LOW_THRESHOLD && charging != true
        val fireFull = !full && pct >= FULL_THRESHOLD
        if (fireLow) low = true
        if (fireFull) full = true
        return Decision(fireLow, fireFull, low, full)
    }
}

/**
 * Posts battery-state alerts — low battery (≤15%) and charge-complete (100%) — as real system
 * notifications. Mirrors [IllnessAlertNotifier]'s pattern: called from WhoopConnectionService on
 * every live-state update, gated behind a user setting and the OS notification permission. The
 * once-per-crossing dedupe lives in [BatteryAlertPolicy] over two persisted NoopPrefs flags.
 *
 * With thanks to @ujix (#368) for the original notification copy and channel.
 */
object BatteryAlertNotifier {
    private const val CHANNEL_ID = "noop_battery_alert"
    private const val NOTIF_ID_LOW = 4203
    private const val NOTIF_ID_FULL = 4204

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onBatteryUpdate(context: Context, currPct: Int?, charging: Boolean?) {
        if (currPct == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        // Defensive: never let a notify() throw (revoked POST_NOTIFICATIONS, OEM quirk) crash a collector.
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val decision = BatteryAlertPolicy.evaluate(
                pct = currPct,
                charging = charging,
                lowAlerted = NoopPrefs.batteryLowAlerted(context),
                fullAlerted = NoopPrefs.batteryFullAlerted(context),
            )
            if (decision.fireLow) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle("Low battery")
                    .setContentText("Recharge your WHOOP before tonight.")
                    .setContentIntent(openAppIntent(context))
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
                NotificationManagerCompat.from(context).notify(NOTIF_ID_LOW, n)
            }
            if (decision.fireFull) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle("Strap fully charged")
                    .setContentText("Your WHOOP is at 100%.")
                    .setContentIntent(openAppIntent(context))
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()
                NotificationManagerCompat.from(context).notify(NOTIF_ID_FULL, n)
            }
            // ALWAYS persist the updated flags — re-arming must stick even when nothing fired.
            NoopPrefs.setBatteryLowAlerted(context, decision.newLowAlerted)
            NoopPrefs.setBatteryFullAlerted(context, decision.newFullAlerted)
        }
    }

    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context, 3,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Battery alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Alerts when the strap battery is low or fully charged."
                },
            )
        }
    }
}
