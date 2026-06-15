package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [BatteryAlertPolicy], the pure once-per-crossing gate behind the strap low/full
 * battery notifications (#368). The two `*Alerted` flags are PERSISTED, so the policy must be a
 * deterministic function of (pct, charging, lowAlerted, fullAlerted) with no hidden state — that's
 * what lets a battery hovering near a threshold fire exactly once per discharge cycle even across
 * a process restart. Mirrors the macOS BatteryAlertPolicy tests byte-for-byte.
 */
class BatteryAlertPolicyTest {

    /** 1. Cross down to ≤15% fires low once; a further reading below 15% with the flag set does not.
     *  (16% is still above the 15% threshold, so nothing fires there — the genuine crossing is ≤15.) */
    @Test
    fun crossDownFiresLowThenDoesNotRefire() {
        // 16% — above the threshold, no alert yet, flag stays clear.
        val above = BatteryAlertPolicy.evaluate(pct = 16, charging = null, lowAlerted = false, fullAlerted = false)
        assertFalse(above.fireLow)
        assertFalse(above.fireFull)
        assertFalse(above.newLowAlerted)

        // 14% — first reading at/under the threshold → fires once and latches the flag.
        val crossed = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = above.newLowAlerted, fullAlerted = false)
        assertTrue(crossed.fireLow)
        assertTrue(crossed.newLowAlerted)

        // 14% again with the flag persisted true → no re-fire.
        val again = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = crossed.newLowAlerted, fullAlerted = false)
        assertFalse(again.fireLow)
        assertTrue(again.newLowAlerted)
    }

    /** 2. Jitter (15→14→15→14) fires low only once; it re-arms only once pct ≥ 25. */
    @Test
    fun jitterNearThresholdFiresOnce() {
        var low = false
        // 15 ≤ 15 threshold → fires.
        val a = BatteryAlertPolicy.evaluate(pct = 15, charging = null, lowAlerted = low, fullAlerted = false)
        assertTrue(a.fireLow); low = a.newLowAlerted
        // 14 — already alerted, no re-fire.
        val b = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(b.fireLow); low = b.newLowAlerted
        // bounce back to 15 — still under the 25% re-arm band, stays armed-off.
        val c = BatteryAlertPolicy.evaluate(pct = 15, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(c.fireLow); low = c.newLowAlerted
        // 14 again — still no re-fire.
        val d = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(d.fireLow); low = d.newLowAlerted
        assertTrue(low)
    }

    /** 3. Recharge to ≥25 re-arms the low flag, then dropping back to ≤15 fires again. */
    @Test
    fun rechargeAbove25RearmsThenFiresAgain() {
        // Fire once.
        val fired = BatteryAlertPolicy.evaluate(pct = 12, charging = null, lowAlerted = false, fullAlerted = false)
        assertTrue(fired.fireLow)
        // Climb to 25% — re-arms (newLowAlerted false), nothing fires.
        val rearmed = BatteryAlertPolicy.evaluate(pct = 25, charging = null, lowAlerted = fired.newLowAlerted, fullAlerted = false)
        assertFalse(rearmed.fireLow)
        assertFalse(rearmed.newLowAlerted)
        // Drop to 10% — fires again now the flag is clear.
        val refired = BatteryAlertPolicy.evaluate(pct = 10, charging = null, lowAlerted = rearmed.newLowAlerted, fullAlerted = false)
        assertTrue(refired.fireLow)
    }

    /** 4. charging == true suppresses the low alert even at 10%, and re-arms the low flag. */
    @Test
    fun chargingSuppressesLowAndRearms() {
        val r = BatteryAlertPolicy.evaluate(pct = 10, charging = true, lowAlerted = true, fullAlerted = false)
        assertFalse(r.fireLow)
        // charging re-arms so once it's unplugged and drains again the alert can fire.
        assertFalse(r.newLowAlerted)
    }

    /** 5. Full fires once at 100; stays armed until pct drops below 100, then 100 again re-fires. */
    @Test
    fun fullFiresOncePerChargeCycle() {
        val first = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = false)
        assertTrue(first.fireFull)
        assertTrue(first.newFullAlerted)
        // Still 100 with the flag set → no re-fire.
        val again = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = true)
        assertFalse(again.fireFull)
        assertTrue(again.newFullAlerted)
        // Drop below 100 → re-arms.
        val dropped = BatteryAlertPolicy.evaluate(pct = 97, charging = null, lowAlerted = false, fullAlerted = true)
        assertFalse(dropped.fireFull)
        assertFalse(dropped.newFullAlerted)
        // Back to 100 → fires again.
        val refired = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = dropped.newFullAlerted)
        assertTrue(refired.fireFull)
    }
}
