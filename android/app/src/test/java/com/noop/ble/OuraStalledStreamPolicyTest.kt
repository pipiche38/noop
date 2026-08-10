package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `OuraLiveSource.shouldToggleSubscription` — the stalled-notify-subscription policy.
 *
 * BYTE-PARITY TWIN of `StrandTests/OuraStalledStreamPolicyTests.swift`: same thresholds, same decisions,
 * same cases in the same order. The policy is a pure static so it is testable without a BluetoothGatt.
 *
 * Thresholds come from the 2026-08-10 `…-260810-1556` capture: over 7,493 inter-arrival gaps inside live
 * sessions the p99.9 gap is 4 s and the largest healthy gap is 4 s, while every genuine stall was
 * 893-928 s. Nothing falls between, which is why a 60 s cut is safe.
 */
class OuraStalledStreamPolicyTest {

    // --- It fires on the shape of stall that was actually measured ---

    @Test
    fun firesAfterTheMeasuredStallWindow() {
        assertTrue(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 900_000, msSinceToggle = null, isDraining = false,
            ),
        )
    }

    @Test
    fun doesNotFireOnAHealthyChannel() {
        for (quiet in listOf(0L, 1_000L, 4_000L, 30_000L, 59_900L)) {
            assertFalse(
                "a ${quiet}ms gap is normal traffic and must not trigger a toggle",
                OuraLiveSource.shouldToggleSubscription(
                    msSinceInbound = quiet, msSinceToggle = null, isDraining = false,
                ),
            )
        }
    }

    @Test
    fun firesJustPastTheThreshold() {
        assertFalse(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 60_000, msSinceToggle = null, isDraining = false,
            ),
        )
        assertTrue(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 60_100, msSinceToggle = null, isDraining = false,
            ),
        )
    }

    // --- It cannot loop, and cannot interrupt a working channel ---

    @Test
    fun neverTogglesDuringAHistoryDrain() {
        assertFalse(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 900_000, msSinceToggle = null, isDraining = true,
            ),
        )
    }

    @Test
    fun neverTogglesBeforeAnythingHasEverArrived() {
        assertFalse(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = null, msSinceToggle = null, isDraining = false,
            ),
        )
    }

    @Test
    fun rateLimitedSoASilentRingCannotMakeUsLoop() {
        assertFalse(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 900_000, msSinceToggle = 10_000, isDraining = false,
            ),
        )
        assertFalse(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 900_000, msSinceToggle = 119_000, isDraining = false,
            ),
        )
        assertTrue(
            OuraLiveSource.shouldToggleSubscription(
                msSinceInbound = 900_000, msSinceToggle = 120_000, isDraining = false,
            ),
        )
    }

    @Test
    fun anUnwornRingCostsAtMostOneTogglePerFloor() {
        // A ring off the finger legitimately sends nothing. Walk 10 minutes of 15 s re-engage ticks: the
        // rate limit must hold it to one toggle per 120 s, not one per tick.
        var lastToggle: Long? = null
        var quiet = 61_000L
        var toggles = 0
        repeat(40) {
            if (OuraLiveSource.shouldToggleSubscription(
                    msSinceInbound = quiet, msSinceToggle = lastToggle, isDraining = false,
                )
            ) {
                toggles++
                lastToggle = 0
            }
            quiet += 15_000
            lastToggle = lastToggle?.plus(15_000)
        }
        assertEquals("10 minutes at a 120 s floor is 5 toggles, not 40", 5, toggles)
    }

    // --- Regression: the exact 2026-08-10 sequence ---

    @Test
    fun theMeasuredStallSequenceTogglesOnceEarlyAndNotDuringTheDrain() {
        // Replay of the 13:47:54 -> 14:03:22 gap. The toggle must fire long BEFORE the 300 s history
        // fetch — that is the point of a 60 s cut against a 300 s interval.
        var quiet = 0L
        var lastToggle: Long? = null
        var firstToggleAt: Long? = null
        for (tick in 0 until 20) {
            val t = tick * 15_000L
            if (OuraLiveSource.shouldToggleSubscription(
                    msSinceInbound = quiet, msSinceToggle = lastToggle, isDraining = false,
                )
            ) {
                if (firstToggleAt == null) firstToggleAt = t
                lastToggle = 0
            }
            quiet += 15_000
            lastToggle = lastToggle?.plus(15_000)
        }
        assertEquals(
            "should recover ~75 s in, not wait for the 300 s fetch",
            75_000L, firstToggleAt,
        )
    }
}
