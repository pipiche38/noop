# Oura historical backfill — implementation plan

Status: **planned, not yet implemented**. Written 2026-06-30 after a user report that only live
HR/HRV streams from a connected Oura ring; sleep/HR/HRV/SpO2/temperature recorded by the ring
while NOT connected (overnight, out of range, etc.) never backfills, unlike WHOOP.

## Context

Two research passes confirmed the root cause precisely:

- `Packages/OuraProtocol/Sources/OuraProtocol/OuraDriver.swift` already implements the §5.3
  cursor-based "GetEvents" history-fetch state machine (`startHistoryFetch(cursor:)` /
  `historyCursorAdvanced(cursor:moreData:)`, `.fetchingHistory` phase) — fully unit-tested
  (`OuraDriverTests.testHistoryFetchFlushesThenFetchesThenAcks`) — but **`Strand/BLE/OuraLiveSource.swift`
  never calls it.** It only ever drives the live-HR enable path and then idles in `.streaming`.
- The ring's `0x11` GetEvents-response (`OURA_PROTOCOL.md` §5.2: `11 08 <status> <sub_status>
  <last_ring_timestamp:4 LE> <pad:2>`) has **no decoder anywhere in the package**, and today it
  would be silently misparsed as a stray TLV record by `OuraLiveSource`'s fallthrough.
- There is **no ring-time→UTC anchor** (§5.5) anywhere — `.timeSync`/`.rtcBeacon` events are
  decoded but then dropped (`OuraLiveSource.ingest`'s `default: break`, and
  `OuraStreamMapping`'s explicit `continue` for those cases). Without an anchor, a backfilled
  historical record has no correct way to get a real timestamp anyway.
- There is **no persisted per-device fetch cursor** — `OuraKeyStore` only holds the auth key.

This is a genuine, multi-piece gap, not a one-line fix. The plan below wires the missing pieces
while reusing WHOOP's already-built, generic backfill infrastructure wherever it fits, so Oura
ends up with the same "syncs its history automatically" behavior WHOOP already has — including
the existing "Syncing strap history…" UI for free.

## Design

### A. `Packages/OuraProtocol` (pure, headless-testable — mirrors the existing decoder style)

1. **`OuraEvents.swift`**: add `extension OuraEvent { public var ringTimestamp: UInt32 }` (a
   switch over every case) so the transport can read a representative ring-time off any decoded
   event without re-deriving it per type. Also add a small
   `public struct OuraGetEventsResponse { public let status: UInt8; public let lastRingTimestamp: UInt32; public var moreData: Bool { status != 0x00 } }`.
2. **`Decoders.swift`**: add `OuraDecoders.decodeGetEventsResponse(_ body: [UInt8]) -> OuraGetEventsResponse?`
   parsing the 8-byte `0x11` response body (`status, sub_status, last_ring_timestamp:4 LE, pad:2`)
   per §5.2 — nil on a short/malformed body (honest-data invariant, same as every other decoder
   here).
3. **New `ClockAnchor.swift`**: `public struct OuraClockAnchor` holding one `(ringTime: UInt32,
   utcMs: Int64)` pair (set from a `0x42` time-sync event, or — only when no anchor exists yet —
   a `0x85` RTC beacon as the documented secondary/coarser source) plus
   `func utcMs(forRingTime: UInt32) -> Int64` implementing §5.5's
   `utc_ms = anchor.utc_ms + factor × (target_rt − anchor.ring_time)` (factor fixed at the
   documented default 100 ms/tick — burst-mode 1ms/tick isn't selectable from any decoded field
   today, so it's out of scope, same Tier-A-only discipline already used elsewhere in this
   package). Do the arithmetic in `Int64` to avoid `UInt32` wraparound on a ring-time regression.
4. Add unit tests for both in `Packages/OuraProtocol/Tests/OuraProtocolTests/`, matching the
   existing `OuraDriverTests.swift` style (byte-exact response decode, anchor math at a couple of
   offsets).

### B. `Strand/BLE/OuraLiveSource.swift` (the transport — mirrors `BLEManager`'s backfill wiring)

1. **Route the `0x11` response**: in `didUpdateValueFor` (~line 706), special-case
   `frame.op == Self.getEventsRespOp (0x11)` BEFORE the TLV fallthrough, exactly like the existing
   `0x25` SetAuthKey-ack special case just above it — decode via `OuraDecoders.decodeGetEventsResponse`
   and call `advance(.historyCursorAdvanced(cursor:moreData:))`.
2. **Clock anchor**: add `private var clockAnchor: OuraClockAnchor?`. In `ingest(_ events:)`,
   handle `.timeSync`/`.rtcBeacon` (currently dropped via `default: break`) by updating it.
3. **Use the anchor for buffered timestamps**: in `enqueue(_:)`, replace the unconditional
   `Int(Date().timeIntervalSince1970)` stamp with: if `clockAnchor` exists, convert the batch's
   representative ring time (`events.last?.ringTimestamp`); else fall back to `Date()` exactly as
   today. This covers the brief pre-anchor window at connect, and leaves live-data timestamps
   unchanged in practice (anchor-converted "now" ≈ wall-clock arrival) while making backfilled
   historical batches get their real time instead of "now".
4. **Drive the fetch loop**: a `requestHistoryFetch(trigger: BackfillTrigger)` entry point that:
   - Gates via the **existing, already-generic** `BackfillPolicy.shouldRun(trigger:now:lastBackfillAt:emptyStreak:)`
     (`Strand/BLE/BackfillPolicy.swift` — no WHOOP-specific assumptions, reusable as-is), reading
     a per-device rate-limit timestamp from `UserDefaults` (`"ouraBackfillLastAt:<deviceId>"`,
     mirroring WHOOP's own `backfillLastAt` key).
   - On a go: `live.backfilling = true`, send `OuraCommands.syncTime(unixSeconds:)`, then start a
     **round**: `advance(.startHistoryFetch(cursor: historyCursor))`.
   - **Multi-round draining within one connection**: the driver's own ack-chain (`historyCursorAdvanced`
     with `moreData: true` → another max-0 ack-fetch) only advances through ONE 255-record window
     per `startHistoryFetch` call before returning to `.streaming`. To drain a deep overnight
     backlog without waiting for the next 15-minute periodic tick, track the cursor at the start of
     each round; when a round ends back at `.streaming`, if the cursor advanced this round AND a
     safety cap (`maxHistoryRoundsPerConnection = 200`, ~51k records) hasn't been hit, immediately
     start another round at the new cursor (mirrors WHOOP's `.autoContinue`). If the cursor did NOT
     advance (truly caught up — the round's first response already said `moreData == false`), stop:
     `live.backfilling = false`, `live.lastSyncedAt = Date()`, persist the final cursor.
   - Triggers: once ~2s after first reaching `.streaming` (`.connect`, mirrors `BLEManager`'s 1.5s
     post-handshake kick), and every 15 min while streaming via a new `backfillTimer`
     (`Timer.scheduledTimer`, same idiom as the existing `reengageTimer` in this file).
5. **Cursor persistence**: reuse the existing generic `WhoopStore.setCursor`/`cursor`
   (`Packages/WhoopStore/Sources/WhoopStore/Cursors.swift`) rather than inventing a new store.
   Inject two closures into `OuraLiveSource`'s initializer, the same way `persist`/`onBattery`
   already are: `readCursor: (@escaping (Int?) -> Void) -> Void` (called once after `didConnect`
   to seed the in-memory `historyCursor`) and `writeCursor: (Int) -> Void` (fire-and-forget,
   called after each `historyCursorAdvanced`), keyed `"oura_history:<deviceId>"`.
6. Log lines matching the existing style: `"Oura: requesting history from cursor <c>"`,
   `"Oura: history page received (moreData=<b>, cursor=<c>)"`, `"Oura: history sync complete"`.

### C. `Strand/BLE/SourceCoordinator.swift`

Wire `readCursor`/`writeCursor` in `startOuraSource` (lines 339-364) exactly like `persist` is
wired today: `Task { if let store = await storeHandle() { try? await store.setCursor("oura_history:\(id)", value) } }`,
and the read side resolving `try? await store.cursor("oura_history:\(id)")` into the completion
closure.

### D. UI — no new code

`LiveState.backfilling` / `lastSyncedAt` are already-published fields with existing renderers
(`SyncingHistoryNote` pill in `ScreenScaffold.swift`, consumed by `TodayView`/`SleepView`/
`IntelligenceView`/`LiveView`). Setting them from the Oura path makes those surfaces accurate
for an Oura session for free, with zero UI changes.

## Explicitly out of scope (flagged, not silently dropped)

- **`HealthView.swift`'s "Sync now" button stays WHOOP-only.** Its `canSync` gate checks
  `live.bonded`, which carries WHOOP encrypted-bond semantics and is never set by
  `OuraLiveSource` — wiring it in would mean redesigning that gate, a separate and riskier change.
  Automatic on-connect + periodic fetch covers the reported complaint without touching it.
- **Ring-reboot mid-gap anchor invalidation** (§5.5's "`0x41` rt regression → invalidate anchor"):
  `OuraDriver.ingest` currently drops `0x41`/ring-start entirely (no `OuraEvent` case carries it),
  so detecting a regression needs a driver-level change too. Worst case on a reboot between
  sessions: a few historical samples land at a stale-anchor timestamp until the next `0x42`
  re-anchors — low-stakes, flagged as a follow-up rather than blocking this fix.
- Tier-B sleep/activity summaries remain dropped (`allowTierB` stays `false`) — unaffected,
  matches the existing honest-data invariant.

## Open question to revisit before/while implementing

The driver's ack-chain (`historyCursorAdvanced` → max-0 ack-fetch while `moreData == true`) is an
**unverified "optional path"** per the existing code comments — it was never exercised against a
real device capture. It's not certain whether a max=0 ack-fetch genuinely makes the ring deliver
the NEXT 255-record window, or only formally advances the cursor without re-streaming. The
round-loop design above (re-issuing a fresh `startHistoryFetch` per round rather than trusting an
unbounded inner ack-chain) is deliberately robust to either interpretation: each round is capped at
one real 255-record fetch, and forward progress is judged by cursor movement, not by record count —
so even in the worst case it still drains a deep backlog over multiple rounds/sessions rather than
silently skipping data. Worth confirming against a real ring capture if/when one is available.

## Files to touch

- `Packages/OuraProtocol/Sources/OuraProtocol/OuraEvents.swift` — `ringTimestamp` accessor + `OuraGetEventsResponse`.
- `Packages/OuraProtocol/Sources/OuraProtocol/Decoders.swift` — `decodeGetEventsResponse`.
- `Packages/OuraProtocol/Sources/OuraProtocol/ClockAnchor.swift` (new) — `OuraClockAnchor`.
- `Packages/OuraProtocol/Tests/OuraProtocolTests/` — new decoder + anchor unit tests.
- `Strand/BLE/OuraLiveSource.swift` — fetch-loop wiring described in B.
- `Strand/BLE/SourceCoordinator.swift` — inject `readCursor`/`writeCursor` in `startOuraSource`.

## Verification (once implemented)

- `swift test` in `Packages/OuraProtocol` for the new decoder/anchor unit tests.
- `xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug -destination 'platform=macOS' build`
  to confirm the app target compiles.
- Manual: with an Oura ring that's been disconnected for a while (or after toggling the ring's
  Bluetooth off/on), reconnect and watch the strap log for `Oura: -> sync_time`, the new
  `Oura: requesting history from cursor …` / `history page received` / `history sync complete`
  lines, and the "Syncing strap history…" pill on Today/Sleep; then confirm Sleep/Trends show data
  for the gap that was previously missing.
