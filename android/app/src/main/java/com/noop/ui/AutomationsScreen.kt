package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrZones
import com.noop.ble.PuffinExperiment
import kotlin.math.roundToInt

/**
 * Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live
 * biometrics into on-device actions and haptic coaching. HR-zone coaching, the smart alarm
 * and the illness watch are real + persisted (ViewModel-backed); the remaining toggles
 * (stress nudge, auto-lock) are still local UI placeholders mirroring AutomationsView.swift.
 */
@Composable
fun AutomationsScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()

    var stressNudge by remember { mutableStateOf(false) }
    var autoLockOnWristOff by remember { mutableStateOf(false) }
    // Smart alarm is real + persisted (issue #51): backed by the ViewModel, which arms the strap's
    // firmware alarm. (The toggles above are still preview-only — separate follow-up.)
    val smartAlarm by viewModel.smartAlarmEnabled.collectAsStateWithLifecycle()
    val alarmMinutes by viewModel.smartAlarmMinutes.collectAsStateWithLifecycle()
    // Illness watch is real + persisted (opt-OUT — the watch has always run on Android).
    val illnessWatch by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    // Battery alerts are real + persisted (opt-OUT, default ON; #368, thanks @ujix).
    val batteryAlerts by viewModel.batteryAlertsEnabled.collectAsStateWithLifecycle()
    // The firmware alarm is EXPERIMENTAL: on a WHOOP 5/MG it is ONLY armed when the Experimental
    // probes toggle is on — otherwise enabling the alarm silently arms nothing (#111). Read the flag
    // so the UI can say so instead of promising a wake that never fires.
    val ctx = LocalContext.current
    val experimentalOn = PuffinExperiment.from(ctx).isEnabled

    // HR-zone coaching is real + persisted (zone-based, mirrors macOS): the ViewModel owns the toggle +
    // recovery option and buzzes the strap on entering the top zone (and Zone 1 if recovery is on).
    val profile = remember { ProfileStore.from(ctx.applicationContext) }
    val zoneCoaching by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val zoneCoachRecovery by viewModel.zoneCoachRecovery.collectAsStateWithLifecycle()
    // The Zone 5 entry threshold (≥ 90% of HR-max), from the same HrZones model used everywhere.
    val zone5Bpm = remember(profile.hrMax) {
        HrZones.zones(maxHR = profile.hrMax.toDouble()).zones.firstOrNull { it.number == 5 }?.lower?.roundToInt() ?: 0
    }

    ScreenScaffold(
        title = "Automations",
        subtitle = "Make the strap do things — tap to act, walk away to lock, train by feel.",
    ) {
        // Double-tap.
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Double-tap",
            blurb = "Double-tap the strap to trigger an action on this device. (The strap exposes a single double-tap gesture.)",
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("When I double-tap", style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                StatePill(
                    if (live.bonded) "Strap bonded" else "Not connected",
                    tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning,
                )
            }
            RowDivider()
            Text(
                "Currently mapped to: silence alerts. Bind more actions once the strap is connected.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }

        // Haptic coaching.
        SettingsSection(
            icon = Icons.Filled.Bolt,
            title = "Haptic coaching",
            blurb = "Train by feel — the strap buzzes so you don't have to watch a screen.",
            active = zoneCoaching || stressNudge,
        ) {
            ToggleRow(
                label = "HR-zone coaching",
                help = "A triple-buzz when you climb into your top zone (Zone 5, ≥ $zone5Bpm bpm) — a cue to ease off. Max HR comes from Settings.",
                checked = zoneCoaching,
                onChange = { viewModel.setZoneCoaching(it) },
            )
            if (zoneCoaching) {
                RowDivider()
                ToggleRow(
                    label = "Recovery buzz",
                    help = "Also buzz once when your heart rate drops back to Zone 1 — a cue that you've recovered.",
                    checked = zoneCoachRecovery,
                    onChange = { viewModel.setZoneCoachRecovery(it) },
                )
            }
            RowDivider()
            ToggleRow(
                label = "Resting stress nudge (experimental)",
                help = "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                checked = stressNudge,
                onChange = { stressNudge = it },
            )
        }

        // Wear & presence.
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Wear & presence",
            blurb = "React when the strap comes off or goes on.",
            active = autoLockOnWristOff,
        ) {
            ToggleRow(
                label = "Lock the device when I take the strap off",
                help = "Fires the moment the strap leaves your wrist.",
                checked = autoLockOnWristOff,
                onChange = { autoLockOnWristOff = it },
            )
        }

        // Smart alarm.
        SettingsSection(
            icon = Icons.Filled.Alarm,
            title = "Smart alarm",
            blurb = "Wake to a buzz from the strap's own firmware alarm. Experimental — we haven't yet confirmed the strap reliably fires this wake on our side, so keep a backup alarm and don't rely on it alone.",
            active = smartAlarm,
        ) {
            ToggleRow(
                label = "Enable smart alarm",
                help = "Arms the strap to buzz at your wake time. Experimental — see the note below.",
                checked = smartAlarm,
                onChange = { viewModel.setSmartAlarmEnabled(it) },
            )
            if (smartAlarm) {
                RowDivider()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Wake at", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = alarmMinutes,
                        accessibilityLabel = "Smart alarm wake time",
                        onPicked = { viewModel.setSmartAlarmMinutes(it) },
                    )
                }
                RowDivider()
                // A WHOOP 5/MG only arms when Experimental probes are on; without it the time is saved
                // but the strap is NEVER armed, so call that out in amber rather than promise a wake (#111).
                if (live.whoop5Detected && !experimentalOn) {
                    Text(
                        "Your WHOOP 5/MG won't arm this until Experimental mode is on (Settings → " +
                            "Experimental). Right now your wake time is saved but the strap is NOT armed.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                } else {
                    Text(
                        if (live.bonded)
                            "Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Still experimental — we can't yet guarantee it fires, so keep a backup alarm."
                        else
                            "Connect your strap to arm this — it's set on the strap's own firmware alarm. Still experimental, so keep a backup alarm until you've confirmed it wakes you.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }

        // Illness early-warning (real + persisted; opt-OUT — the watch has always run on Android).
        SettingsSection(
            icon = Icons.Filled.MonitorHeart,
            title = "Illness early-warning",
            blurb = "Watches your resting HR, HRV, skin temperature and respiration against your own 28-day baseline. On-device and approximate — informational only, not a diagnosis.",
            active = illnessWatch,
        ) {
            ToggleRow(
                label = "Watch for early-illness signs",
                help = "Needs at least 14 days of history. When two or more signals drift together you get a banner on Today and a notification — at most once a day.",
                checked = illnessWatch,
                onChange = { viewModel.setIllnessWatchEnabled(it) },
            )
        }

        // Battery alerts (real + persisted; opt-OUT, default ON — #368, thanks @ujix).
        SettingsSection(
            icon = Icons.Filled.BatteryStd,
            title = "Battery alerts",
            blurb = "A heads-up when the strap battery gets low so you can recharge before bed, and a note when it's finished charging.",
            active = batteryAlerts,
        ) {
            ToggleRow(
                label = "Notify on low and full battery",
                help = "Sends a notification when the strap drops to 15% or reaches a full charge — at most once per charge cycle.",
                checked = batteryAlerts,
                onChange = { viewModel.setBatteryAlertsEnabled(it) },
            )
        }
    }
}

// MARK: - Section + rows (mirror the settings idiom from AutomationsView.swift)

@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    active: Boolean = false,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Automation")
                    if (active) Overline("ON", color = Palette.accent)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (active) Palette.accent else Palette.textSecondary,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(vertical = 4.dp)
            .background(Palette.hairline),
    )
}
