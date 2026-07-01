import Foundation
import Combine
import CoreBluetooth
import Security
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen 3/4/5), driven by the clean-room
/// `OuraProtocol.OuraDriver`.
///
/// This is a real transport (it replaced an earlier honest dead-end probe): it decodes the ring's OWN
/// raw signals + open event tags (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery), persists them
/// under the ring's `deviceId`, and lets NOOP compute its own Charge/Rest from those streams exactly like
/// a WHOOP day. It NEVER reads or surfaces Oura's encrypted readiness/sleep scores (honest-data
/// invariant), and when a signal can't be read it stays at "-", never a fabricated value (Huami precedent).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource` / `HuamiHRSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager` / `WhoopBleClient`. The
/// WHOOP path cannot regress. The only shared surfaces are `LiveState` and the injected closures
/// (`persist`, `log`, `onBattery`). All BLE specifics live here; all protocol specifics live in the pure,
/// headless-testable `OuraDriver` (no CoreBluetooth in that package).
///
/// Honest about the handshake, step by step:
///   1. Scan for the Oura GATT service and filter discoveries by `OuraRingGen.recognise`.
///   2. Connect, discover the write/notify characteristics, enable notifications on ...0003.
///   3. Run the application auth challenge through `OuraDriver` (GetAuthNonce -> compute proof ->
///      Authenticate). The 16-byte install key is injected via `authKey`; when it is nil (or auth fails
///      because the ring is in factory reset / wrong key) we surface an HONEST `needsPairing` message and
///      stream NO data rather than faking one.
///   3a. ADOPT (factory-reset ring + explicit consent only): when the ring is in factory reset (auth status
///      `inFactoryReset` / no key) AND `adoptIntent == true`, the transport PROVISIONS a fresh 16-byte key:
///      it writes the dangerous `0x24` install, awaits the `0x25` OK ack, persists the key to `OuraKeyStore`,
///      then re-runs auth with the new key (s3.2). Without `adoptIntent` the dangerous opcode is NEVER sent;
///      we announce needs-pairing instead. A failed install is honest (Failed), never a fake success.
///   4. On auth success, run the gen-appropriate live-HR enable triplet; HR/IBI then streams as 0x2F
///      sub-op 0x28 pushes which the driver decodes.
///   5. Decoded events map onto `Streams` via `OuraStreamMapping` and persist in 30/30s batches; live HR
///      also feeds `LiveState`; battery feeds `onBattery`.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// Best-effort generation guess from the advertised name (confirmed by the model the user picks).
        public let detectedGen: OuraRingGen?
    }

    /// The coarse adopt outcome the wizard observes while it is in its "Taking over your ring" state, so it
    /// can drive Adopting -> success (on `.streaming`/connected) and Adopting -> an honest Failed (on
    /// `.failed`). It is ONLY meaningful for an adopt-intent connection; a read-only connect stays `.idle`
    /// until it streams (or surfaces `needsPairing`). PARITY: the Android twin exposes the same coarse
    /// adopt outcome the Compose wizard observes to leave its Adopting step.
    public enum AdoptPhase: Equatable, Sendable {
        case idle            // no adopt in flight (the default; a read-only connect never leaves this until streaming)
        case installingKey   // the dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running)
        case streaming       // auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete
        case failed          // an honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Set to an HONEST explanation string when the ring needs a pairing/key handshake NOOP can't complete
    /// (no install key, or the ring is in factory reset, or the key was rejected). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil
    /// The live adopt outcome (see `AdoptPhase`). The wizard observes this to leave its Adopting step. Reset
    /// to `.idle` on every connect/stop/disconnect so a stale outcome never drives a transition.
    @Published public private(set) var adoptPhase: AdoptPhase = .idle

    // MARK: - BLE UUIDs (from the platform-pure OuraGatt facts)

    /// The Oura base service (gen3/4/5). `OuraGatt` keeps the raw strings so the package stays
    /// CoreBluetooth-free; the app turns them into `CBUUID` here.
    private static let service = CBUUID(string: OuraGatt.serviceUUID)
    private static let writeChar = CBUUID(string: OuraGatt.writeCharacteristicUUID)
    private static let notifyChar = CBUUID(string: OuraGatt.notifyCharacteristicUUID)

    /// The `0x25` SetAuthKey-response outer opcode (`25 01 <status>`, status `0x00` = OK). Per
    /// OURA_PROTOCOL.md s3.2. This is the install-ack the adopt key-install awaits.
    private static let setAuthKeyRespOp: UInt8 = 0x25
    /// The `0x11` GetEvents-response outer opcode (`11 08 <status> <sub_status> <last_ring_timestamp:4 LE>
    /// <pad:2>`). Per OURA_PROTOCOL.md s5.2. This is the ack a history-fetch round awaits.
    private static let getEventsRespOp: UInt8 = 0x11

    // MARK: - Dependencies (injected - no BLEManager / WhoopBleClient reference)

    private let live: LiveState
    private let deviceId: String
    private let persist: (Streams) -> Void
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// Reads the persisted per-device history-fetch cursor (nil if never fetched before). Called once
    /// right after construction to seed `historyCursor`. Wired by `SourceCoordinator` to
    /// `WhoopStore.cursor("oura_history:<deviceId>")`. Defaults to "never fetched" so tests/previews
    /// that don't inject it behave like a fresh device.
    private let readCursor: (@escaping (Int?) -> Void) -> Void
    /// Persists the history-fetch cursor after each round advances it. Fire-and-forget, mirrors `persist`.
    /// Wired by `SourceCoordinator` to `WhoopStore.setCursor("oura_history:<deviceId>", _:)`.
    private let writeCursor: (Int) -> Void
    /// The ring generation (carried on `PairedDevice.model`, recovered via `OuraRingGen.from(model:)`).
    /// Selects the MTU clamp, which characteristics to discover, and the live-HR command set.
    private let ringGen: OuraRingGen
    /// Supplies the 16-byte application install key (from the Keychain) for this ring, or nil. A nil key
    /// drives the honest `needsPairing` path: the driver answers `.needsKeyInstall` and we never fake data.
    private let authKey: () -> Data?
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState` or persists.
    private let feedsLive: Bool
    /// EXPLICIT, USER-GRANTED adopt consent for THIS connection. Default FALSE. The dangerous installKey
    /// opcode (`0x24`) may be sent ONLY when this is true: it is what gates the post-factory-reset key
    /// provisioning (s3.2). It is set true by the adopt flow AFTER the wizard's irreversible-consent gate
    /// (the consent tick AND the "Take over this ring?" confirm), and it gates the driver's `allowKeyInstall`
    /// so a read-only / Advanced-key connection can NEVER install a key. Set once at construction (the
    /// coordinator builds a fresh source per connection, so a new value just means a new source).
    private let adoptIntent: Bool

    // MARK: - Protocol state machine (pure - holds NO BLE handle)

    /// The transport-agnostic driver. Re-created on each connect so a fresh session re-runs auth (the
    /// app key is session-scoped). nil until a connection begins.
    private var driver: OuraDriver?
    /// Reassembles notification fragments into complete TLV inner records across feeds.
    private let reassembler = OuraReassembler()

    /// Logs the FIRST live HR sample of a connection only (never every push); reset on stop/disconnect.
    private var loggedFirstHR = false
    /// True once the live-HR stream has been requested, so the disconnect handler can tell "we never got
    /// authenticated/streaming" (-> honest note) from "the link just dropped".
    private var reachedStreaming = false
    /// The freshly-generated 16-byte key written to the ring during an adopt key install. Held in memory
    /// ONLY between writing the `0x24` install and receiving the `0x25` ack: it is persisted to the keystore
    /// ONLY on an OK ack (so a failed/absent ack never leaves a key the next session would wrongly trust).
    /// Cleared on stop/disconnect/failure.
    private var pendingInstallKey: Data?

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection (exact
    /// StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern).
    private var seenPeripherals: [UUID: CBPeripheral] = [:]
    /// True only while a USER-initiated `stop()` is tearing the link down — guards the auto-reconnect
    /// in `didDisconnectPeripheral`/`didFailToConnect` so a deliberate teardown (e.g. switching the
    /// active device away from this ring) never relaunches a connect. Cleared at the top of `connect()`,
    /// mirroring `BLEManager.intentionalDisconnect`.
    private var intentionalDisconnect = false
    /// Capped exponential backoff counter for `didFailToConnect` (mirrors `BLEManager`'s 3,6,12,24,48,60s
    /// ramp), so a ring that's genuinely out of range doesn't get hammered. Reset on a successful connect.
    private var failedConnectAttempts = 0

    // MARK: - Sample buffer

    /// Buffered decoded events, flushed to `persist` in batches to keep the write path off the
    /// per-notification hot loop. Each entry carries the arrival wall-clock `ts` (the events themselves
    /// only carry a ring-clock value, so the transport stamps wall-clock, exactly as the Standard path).
    private var buffer: [(events: [OuraEvent], ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Live-HR re-engagement

    /// Daytime-HR auto-reverts after ~20 s (OURA_PROTOCOL.md s5.7), so while a live session is open we
    /// re-send the enable+subscribe every ~15 s. nil when no session is streaming.
    private var reengageTimer: Timer?
    private let reengageInterval: TimeInterval = 15

    // MARK: - History fetch (backfill of data banked while disconnected)

    /// Ring-time -> UTC anchor, set from a `0x42` time-sync event (primary, OURA_PROTOCOL.md s5.5) or -
    /// only when no anchor exists yet - a `0x85` RTC beacon (secondary, coarser). nil until the first one
    /// arrives after a fresh connect, during which buffered batches fall back to arrival wall-clock
    /// (unchanged live behaviour).
    private var clockAnchor: OuraClockAnchor?
    /// The persisted per-device fetch cursor (the ring's own `last_ring_timestamp`, already
    /// acknowledged). Seeded once from `readCursor` at construction; advanced + persisted via
    /// `writeCursor` as rounds complete. 0 = never fetched before (full dump).
    private var historyCursor: UInt32 = 0
    /// True while one history-fetch round (flush_buffer + get_events(max:255) + its internal ack-chain)
    /// is in flight, so `didUpdateValueFor` only routes a `0x11` response into the driver while one is
    /// actually expected, and `advance`'s generic `.streaming` case can tell "auth just completed" from
    /// "a history round just finished".
    private var historyFetchInFlight = false
    /// How many decoded events landed during the CURRENT round (diagnostic only, logged when the round
    /// finishes, so a strap-log export can prove whether a history fetch actually delivered anything
    /// rather than just exchanging the meta 0x11 acks).
    private var historyEventsThisRound = 0
    /// Per-type breakdown of decoded events during the CURRENT round (diagnostic only), so a strap-log
    /// export can show WHICH signals a round actually delivered — a huge total with almost no
    /// `sleepPhase` entries proves the fetched window covers mostly-awake stretches (the ring only emits
    /// sleep-phase codes once it has classified the wearer as asleep) rather than pointing at a bug in
    /// the sleep pipeline itself.
    private var historyEventTypeCountsThisRound: [String: Int] = [:]
    /// Min/max computed `ts` (unix seconds) actually stamped on a buffered batch during the CURRENT
    /// round (diagnostic only) — lets a strap-log export show the REAL calendar date range a round's
    /// events landed under, so a clock-anchor mis-projection (e.g. a wrong assumed tick rate placing
    /// events years off) is immediately visible instead of silently landing outside every scored day.
    private var historyTsRangeThisRound: (min: Int, max: Int)?
    /// Same as `historyTsRangeThisRound` but ONLY for batches containing a `sleepPhase` event
    /// (diagnostic only) — the whole-round range mixes every event type, so it can't say whether the
    /// ring's OWN sleep-phase codes specifically landed in a plausible recent night or somewhere else
    /// entirely; this isolates just that signal.
    private var historySleepPhaseTsRangeThisRound: (min: Int, max: Int)?
    /// `historyCursor`'s value when the CURRENT round started, so a round's end can tell "this round
    /// found more data" (cursor moved, in EITHER direction — a real capture showed it isn't always
    /// forward) from "genuinely nothing left" (cursor unchanged).
    private var historyCursorAtRoundStart: UInt32 = 0
    /// How many rounds have auto-continued within the CURRENT trigger (reset at the start of every
    /// `requestHistoryFetch`). Capped by `maxHistoryRoundsPerTrigger` so a single connect/periodic tick
    /// can walk further back through the ring's buffer (each round only covers roughly an hour of real
    /// time in practice) without needing many separate reconnects — while still bounded, since the
    /// cursor's real semantics remain only partially understood (OURA_PROTOCOL.md s5.3 is an admittedly
    /// unverified "optional path").
    private var historyRoundsThisTrigger = 0
    private let maxHistoryRoundsPerTrigger = 10
    /// Re-checks for newly-banked history while connected (mirrors WHOOP's periodic backfill timer).
    private var backfillTimer: Timer?
    private let backfillIntervalSeconds: TimeInterval = 900   // 15 min, matches BackfillPolicy's floor

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - ringGen: the ring generation (selects MTU clamp + command set).
    ///   - authKey: supplies the 16-byte install key from the Keychain, or nil to drive `needsPairing`.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Every line is prefixed "Oura: ". Defaults to a no-op.
    ///   - onBattery: fired with the ring's battery percent (0-100). Default no-op.
    ///   - feedsLive: when false (the discovery-only wizard scanner) this source never touches LiveState
    ///     or persists. Default true.
    ///   - adoptIntent: EXPLICIT user-granted adopt consent for this connection. Default FALSE. Only when
    ///     true may the dangerous `0x24` installKey opcode ever be sent (the post-factory-reset provisioning,
    ///     s3.2). The standard live path leaves it false (read-only / Advanced-key), so a key is NEVER
    ///     installed outside the wizard's irreversible-consent adopt flow.
    public init(live: LiveState,
                deviceId: String,
                ringGen: OuraRingGen,
                authKey: @escaping () -> Data?,
                persist: @escaping (Streams) -> Void = { _ in },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true,
                adoptIntent: Bool = false,
                readCursor: @escaping (@escaping (Int?) -> Void) -> Void = { $0(nil) },
                writeCursor: @escaping (Int) -> Void = { _ in }) {
        self.live = live
        self.deviceId = deviceId
        self.ringGen = ringGen
        self.authKey = authKey
        self.persist = persist
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        self.adoptIntent = adoptIntent
        self.readCursor = readCursor
        self.writeCursor = writeCursor
        super.init()
        // Dedicated queue-less central -> callbacks arrive on the main queue, matching @MainActor.
        self.central = CBCentralManager(delegate: self, queue: nil)
        // Seed the in-memory history cursor once from durable storage (a fresh device / never-fetched
        // ring resolves to 0 == full dump). Loaded eagerly (no BLE needed) so the first connect-triggered
        // fetch already knows where to resume.
        self.readCursor { [weak self] cursor in
            guard let self, let cursor else { return }
            self.historyCursor = UInt32(clamping: cursor)
        }
    }

    // MARK: - Scanning

    /// Scan for Oura rings advertising the Oura GATT service, keeping only ones the ring-gen recogniser
    /// accepts as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        log("Oura: scanning for an Oura ring (service \(OuraGatt.serviceUUID))")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen ring and start the auth -> enable -> stream flow. Mirrors the
    /// StandardHRSource cached-by-identifier-first, else scan-then-connect pattern.
    public func connect(_ id: UUID) {
        intentionalDisconnect = false
        stopScan()
        needsPairing = nil
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet -> remember it and scan; didDiscover connects on sight.
            pendingConnectID = id
            log("Oura: ring \(id) not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on - connect to \(id) deferred until ready")
            return
        }
        log("Oura: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection, stop scanning, flush, clear all transient state. Idempotent.
    public func stop() {
        intentionalDisconnect = true
        stopScan()
        pendingConnectID = nil
        stopReengageTimer()
        stopBackfillTimer()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        driver?.stop()
        driver = nil
        reassembler.reset()
        loggedFirstHR = false
        reachedStreaming = false
        pendingInstallKey = nil
        adoptPhase = .idle
        batteryPct = nil
        needsPairing = nil
        clockAnchor = nil
        historyFetchInFlight = false
        historyRoundsThisTrigger = 0
        flush()                       // persist anything still buffered
        if feedsLive { live.connected = false; live.streamingLiveHR = false; live.backfilling = false }
    }

    // MARK: - Driver wiring

    /// Write the bytes for each command the driver returned, logging the label only (never an address).
    private func write(_ commands: [OuraCommand]) {
        guard let peripheral, let writeCharacteristic else { return }
        let mtuPayload = ringGen.maxWritePayload   // gen-appropriate clamp (gen3=200, gen4/5=244)
        for cmd in commands {
            guard cmd.bytes.count <= mtuPayload else {
                log("Oura: skipping \(cmd.label) - \(cmd.bytes.count)B exceeds the \(mtuPayload)B write window")
                continue
            }
            log("Oura: -> \(cmd.label)")
            peripheral.writeValue(Data(cmd.bytes), for: writeCharacteristic, type: .withoutResponse)
        }
    }

    /// Advance the driver with a transition and write whatever it asks for next.
    private func advance(_ transition: OuraTransition) {
        guard let driver else { return }
        let commands = driver.nextStep(after: transition)
        write(commands)
        // Surface the driver's coarse phase honestly into the UI state.
        switch driver.phase {
        case .needsKeyInstall:
            // A factory-reset ring (auth status inFactoryReset) or no key available. The dangerous key
            // install is the ONLY thing that recovers it, and ONLY with explicit adopt consent: provision
            // when `adoptIntent`, otherwise stay honest (never loop the dangerous command).
            if adoptIntent {
                provisionKeyInstall()
            } else {
                announceNeedsPairing(reason: .factoryResetOrNoKey)
            }
        case .authFailed(let status):
            announceNeedsPairing(reason: .authFailed(status))
        case .streaming:
            if !reachedStreaming {
                reachedStreaming = true
                adoptPhase = .streaming   // re-auth after an install (or a normal auth) reached the stream: adoption complete
                pendingInstallKey = nil   // an OK ack already persisted the key; nothing left in flight
                if feedsLive { live.streamingLiveHR = true }   // drive the green menu-bar STREAMING pill (no WHOOP bond)
                log("Oura: live-HR enabled - streaming HR / IBI")
                startReengageTimer()
                startBackfillTimer()
                // Give live-HR a moment to settle before pulling history (mirrors BLEManager's 1.5s
                // post-handshake backfill kick), so the very first connect also catches up on whatever
                // banked while the ring was disconnected (sleep, HR/HRV/SpO2/temp).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.requestHistoryFetch(trigger: .connect)
                }
            }
        default:
            break
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /// PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from `advance`
    /// when `driver.phase == .needsKeyInstall` AND `adoptIntent == true`. Steps: (1) generate a fresh
    /// cryptographically-random 16-byte key; (2) ask the driver for the dangerous `24 10 <key>` install
    /// command (the driver's own `allowKeyInstall`/phase gate is the second guard) and write it; (3) hold the
    /// key in memory and mark `.installingKey` (an install IS now running). The key is NOT persisted yet: it
    /// is written to the keystore only once the ring acks OK (`handleKeyInstallAck`), so a failed install
    /// never leaves a key the next session would wrongly trust. On any build/RNG failure we stay honest.
    private func provisionKeyInstall() {
        guard adoptIntent else { return }                 // belt-and-braces: never provision without consent
        guard pendingInstallKey == nil else { return }    // an install is already in flight; don't double-send
        guard let driver else { return }
        guard let key = Self.randomInstallKey() else {
            announceNeedsPairing(reason: .installFailed("could not generate a key"))
            return
        }
        guard let cmd = driver.beginKeyInstall(key: [UInt8](key)) else {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            announceNeedsPairing(reason: .installFailed("the install command could not be prepared"))
            return
        }
        pendingInstallKey = key
        adoptPhase = .installingKey
        log("Oura: installing NOOP's key on the reset ring")
        write([cmd])
    }

    /// Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
    /// On OK: persist the freshly-provisioned key under this `deviceId` (so every future session authenticates
    /// with it), then drive the driver's `keyInstallAcknowledged()` to re-run the auth handshake (GetAuthNonce
    /// then Authenticate) with the NEW key. On a non-OK status (or a missing pending key) announce an honest
    /// failure and do NOT retry the dangerous command.
    private func handleKeyInstallAck(status: UInt8) {
        guard let driver, let key = pendingInstallKey else { return }
        guard status == 0x00 else {
            announceNeedsPairing(reason: .installFailed("the ring did not accept the key (status \(status))"))
            return
        }
        // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
        guard OuraKeyStore.save(key, deviceId: deviceId) else {
            announceNeedsPairing(reason: .installFailed("the installed key could not be stored"))
            return
        }
        log("Oura: key installed and stored - re-running auth with the new key")
        pendingInstallKey = nil
        // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the nonce
        // response then flows through the normal handleSecure -> advance path to streaming.
        write(driver.keyInstallAcknowledged())
    }

    /// A fresh 16-byte application key for the adopt install, from the system CSPRNG. Per OURA_PROTOCOL.md
    /// s3 the key is exactly 16 bytes; `SecRandomCopyBytes` is the same CSPRNG the rest of the app relies on.
    /// Returns nil if the RNG fails (then the caller stays honest rather than installing a weak key).
    private static func randomInstallKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: OuraKeyStore.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    /// Short diagnostic label per decoded event case, for the history-round type-breakdown log line only
    /// (never persisted, never affects scoring).
    private static func eventTypeLabel(_ e: OuraEvent) -> String {
        switch e {
        case .hr: return "hr"
        case .ibi: return "ibi"
        case .hrv: return "hrv"
        case .spo2: return "spo2"
        case .temp: return "temp"
        case .battery: return "battery"
        case .sleepPhase: return "sleepPhase"
        case .motion: return "motion"
        case .state: return "state"
        case .timeSync: return "timeSync"
        case .rtcBeacon: return "rtcBeacon"
        case .debugText: return "debugText"
        case .tierB: return "tierB"
        }
    }

    /// The MEDIAN ring-timestamp across a batch's events, so ONE corrupted value (a decode/reassembly
    /// glitch) can't single-handedly poison the batch's stamped time the way picking the last one could
    /// — a real capture showed exactly that: an occasional wild outlier landing last and projecting an
    /// otherwise-normal batch years into the future via the clock anchor. Requires the MAJORITY of a
    /// batch's ring-timestamps to be corrupted before the median itself would be wrong.
    private static func medianRingTimestamp(_ events: [OuraEvent]) -> UInt32? {
        let sorted = events.compactMap(\.ringTimestamp).sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    // MARK: - Buffer / persistence

    /// The bulk of ring-timestamps a batch should plausibly carry, relative to the current anchor: the
    /// ring only buffers a matter of days (a Gen3 holds ~7), so anything beyond a generous 30-day tick
    /// span either side of the anchor is a decode/reassembly glitch (observed on a real device: an
    /// occasional corrupted ring-timestamp — `debugText` is the leading suspect, an exotic tag with
    /// thinner framing guarantees — projected a batch years into the future via the SAME anchor that
    /// correctly placed every other batch in the actual recent past).
    private static let maxPlausibleTickDelta: Int64 = 30 * 24 * 60 * 60 * 10   // 30 days at 100 ms/tick

    private func enqueue(_ events: [OuraEvent]) {
        guard !events.isEmpty else { return }
        // Stamp this batch at the CORRECT time: once a clock anchor exists, convert the batch's own
        // representative ring-time (the record events carry, s5.5) rather than "now". For a batch that
        // just arrived live this lands within a second or so of arrival wall-clock (unchanged in
        // practice); for a backfilled historical batch it's the difference between the real overnight
        // time and "now" (wrong). Before the first time-sync/RTC-beacon of a session, fall back to
        // arrival wall-clock exactly as before (there is nothing else to anchor to yet).
        let ts: Int
        if let anchor = clockAnchor, let rt = Self.medianRingTimestamp(events) {
            // Reject an implausible outlier rather than propagate it: fall back to the anchor's OWN
            // instant (still real data, just coarser-dated) instead of a wild multi-year jump.
            let delta = abs(Int64(rt) - Int64(anchor.ringTime))
            ts = delta <= Self.maxPlausibleTickDelta
                ? anchor.utcSeconds(forRingTime: rt)
                : anchor.utcSeconds(forRingTime: anchor.ringTime)
        } else {
            ts = Int(Date().timeIntervalSince1970)
        }
        buffer.append((events: events, ts: ts))
        if historyFetchInFlight {
            let range = historyTsRangeThisRound
            historyTsRangeThisRound = (min: min(range?.min ?? ts, ts), max: max(range?.max ?? ts, ts))
            if events.contains(where: { if case .sleepPhase = $0 { return true }; return false }) {
                let spRange = historySleepPhaseTsRangeThisRound
                historySleepPhaseTsRangeThisRound = (min: min(spRange?.min ?? ts, ts), max: max(spRange?.max ?? ts, ts))
            }
        }
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        for entry in buffer {
            // Pure, unit-tested mapping (events -> Streams) keyed by arrival wall-clock ts. A signal that
            // could not be decoded never reaches here, so a missing stream stays empty, never faked.
            persist(OuraStreamMapping.streams(from: entry.events, at: entry.ts))
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    // MARK: - Live ingest

    /// Fold decoded events into live state (HR / R-R) + the persist buffer. Battery is surfaced
    /// immediately (it is a status, not a sample row). Out-of-range HR is dropped, never shown.
    private func ingest(_ events: [OuraEvent]) {
        guard !events.isEmpty else { return }
        if historyFetchInFlight {
            historyEventsThisRound += events.count
            for e in events { historyEventTypeCountsThisRound[Self.eventTypeLabel(e), default: 0] += 1 }
        }
        for e in events {
            switch e {
            case .hr(let hr):
                guard hr.bpm >= 30, hr.bpm <= 220 else { continue }   // physiological gate
                if !loggedFirstHR {
                    loggedFirstHR = true
                    log("Oura: receiving live data - first HR \(hr.bpm) bpm")
                }
                if feedsLive {
                    live.heartRate = hr.bpm
                    live.connected = true
                }
            case .ibi(let ibi):
                if feedsLive { live.setRRIntervals([ibi.ibiMs]) }
            case .battery(let bat):
                batteryPct = bat.percent
                onBattery(bat.percent)
                log("Oura: battery \(bat.percent)%")
            case .timeSync(let sync):
                // Primary anchor (OURA_PROTOCOL.md s5.5): always wins over whatever's current, since a
                // fresh time-sync is the ring's own most-authoritative UTC correlation.
                clockAnchor = OuraClockAnchor(ringTime: sync.ringTimestamp, utcMs: sync.epochMs)
                // Diagnostic only: the ring's OWN claimed date for this anchor. If this looks wrong
                // (not roughly "now"), the anchor itself — not the tick-rate math applied to it — is the
                // problem; if this looks RIGHT but backfilled events still land on the wrong day, the
                // 100ms/tick assumption applied to ring-time deltas away from this point is the suspect.
                let anchorDate = Date(timeIntervalSince1970: Double(sync.epochMs) / 1000)
                log("Oura: time-sync anchor ringTime=\(sync.ringTimestamp) -> \(anchorDate)")
            case .rtcBeacon(let beacon):
                // Secondary, coarser (1s granularity) source - only fills a gap, never overrides a
                // real time-sync anchor.
                if clockAnchor == nil {
                    clockAnchor = OuraClockAnchor(ringTime: beacon.ringTimestamp,
                                                   utcMs: Int64(beacon.unixSeconds) * 1000)
                }
            default:
                break   // HRV / SpO2 / temp / sleep-phase persist via the buffer, not live state
            }
        }
        // Everything decoded (incl. HR/IBI) also persists so the day scores like a WHOOP day.
        enqueue(events)
    }

    // MARK: - Re-engagement timer (daytime-HR auto-reverts ~20s)

    private func startReengageTimer() {
        stopReengageTimer()
        let t = Timer.scheduledTimer(withTimeInterval: reengageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reengageLiveHR() }
        }
        reengageTimer = t
    }

    private func stopReengageTimer() {
        reengageTimer?.invalidate()
        reengageTimer = nil
    }

    /// Re-send the live-HR enable+subscribe so the ~20 s auto-revert never silently stops the stream.
    private func reengageLiveHR() {
        guard let driver, reachedStreaming else { return }
        write(driver.reengageLiveHRCommands())
    }

    // MARK: - History fetch (backfill of sleep / HR / HRV / SpO2 / temp banked while disconnected)

    private func startBackfillTimer() {
        stopBackfillTimer()
        let t = Timer.scheduledTimer(withTimeInterval: backfillIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestHistoryFetch(trigger: .periodic) }
        }
        backfillTimer = t
    }

    private func stopBackfillTimer() {
        backfillTimer?.invalidate()
        backfillTimer = nil
    }

    /// Kick a history-fetch pass, gated by the SAME rate-limiter WHOOP's backfill uses
    /// (`BackfillPolicy` - no WHOOP-specific assumptions, reused as-is) so an automatic trigger
    /// (`.connect` / `.periodic`) can't hammer the ring; a future manual trigger would bypass it exactly
    /// like WHOOP's `.manual` does. No-op while discovery-only (`!feedsLive`), not yet streaming, or a
    /// round is already in flight.
    private func requestHistoryFetch(trigger: BackfillTrigger) {
        guard feedsLive, reachedStreaming, !historyFetchInFlight else { return }
        let now = Date().timeIntervalSince1970
        let rateLimitKey = "ouraBackfillLastAt:\(deviceId)"
        let last = UserDefaults.standard.object(forKey: rateLimitKey) as? TimeInterval
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else { return }
        UserDefaults.standard.set(now, forKey: rateLimitKey)
        live.backfilling = true
        live.syncChunksThisSession = 0
        historyRoundsThisTrigger = 0
        write([OuraCommands.syncTime(unixSeconds: Int(now))])
        startHistoryRound()
    }

    /// Begin a round: flush the ring's flash buffer and fetch from `historyCursor`.
    /// `historyFetchInFlight` gates `didUpdateValueFor` so the `0x11` response it triggers is actually
    /// routed here rather than falling through to the TLV decoder.
    private func startHistoryRound() {
        guard driver != nil else { return }
        historyFetchInFlight = true
        historyRoundsThisTrigger += 1
        historyCursorAtRoundStart = historyCursor
        historyEventsThisRound = 0
        historyEventTypeCountsThisRound = [:]
        historyTsRangeThisRound = nil
        historySleepPhaseTsRangeThisRound = nil
        log("Oura: requesting history from cursor \(historyCursor) (round \(historyRoundsThisTrigger)/\(maxHistoryRoundsPerTrigger))")
        advance(.startHistoryFetch(cursor: historyCursor))
    }

    /// Handle the ring's `0x11` GetEvents-response (OURA_PROTOCOL.md s5.2), reached only while
    /// `historyFetchInFlight`. Feeds the driver's own ack-chain (it may return another max-0 ack-fetch
    /// while `moreData` stays true); once the driver reports back to `.streaming` this round is done and
    /// `finishHistoryRound` decides whether to drain another round or stop.
    private func handleGetEventsResponse(_ body: [UInt8]) {
        guard let resp = OuraDecoders.decodeGetEventsResponse(body) else { return }
        log("Oura: history page received (moreData=\(resp.moreData), cursor=\(resp.lastRingTimestamp))")
        live.syncChunksThisSession += 1
        // Only trust the reported cursor while it's carrying real progress. Observed on a real ring: the
        // TERMINAL "no more data" response can come back with cursor=0 instead of echoing the last real
        // position it actually reached - blindly persisting THAT would silently roll the durable cursor
        // back to 0 and discard real progress, re-fetching everything from scratch next time. A response
        // that still says "more data follows" always carries the meaningful new cursor, so only advance
        // (and persist) on those; a terminal response's cursor field is not trusted.
        if resp.moreData {
            historyCursor = resp.lastRingTimestamp
            writeCursor(Int(historyCursor))
        }
        advance(.historyCursorAdvanced(cursor: resp.lastRingTimestamp, moreData: resp.moreData))
        guard driver?.phase == .streaming else { return }   // the driver's own ack-chain isn't done yet
        finishHistoryRound()
    }

    /// One round just drained back to `.streaming`. Auto-continues into another round when the cursor
    /// actually moved this round (in EITHER direction — a real capture showed it isn't always forward)
    /// AND the per-trigger cap hasn't tripped, so one connect/periodic tick can walk further back
    /// through the ring's buffer instead of needing a separate reconnect per ~hour of real backfill data.
    /// Bounded at `maxHistoryRoundsPerTrigger`: the cursor/max_events semantics this was built against
    /// (OURA_PROTOCOL.md s5.3, an "optional path" the docs already flagged as unverified) are still only
    /// partially understood, so this stays a capped burst, never an unbounded loop — the next burst
    /// happens on the next periodic tick or reconnect.
    private func finishHistoryRound() {
        historyFetchInFlight = false
        log("Oura: history round decoded \(historyEventsThisRound) event(s) (cursor now \(historyCursor))")
        // Per-type breakdown, biggest first: proves WHICH signals a round actually delivered, so a huge
        // total with near-zero sleepPhase entries reads as "this window is mostly awake data" rather than
        // a silent, unexplained gap in the sleep pipeline.
        let breakdown = historyEventTypeCountsThisRound.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log("Oura: history round event types: \(breakdown)")
        // Diagnostic only: the REAL calendar-date range this round's events were stamped under, after
        // clock-anchor conversion. If this doesn't look like a plausible recent range, the anchor/tick-
        // rate math (not the sleep pipeline) is placing events outside every day IntelligenceEngine scores.
        if let range = historyTsRangeThisRound {
            let minDate = Date(timeIntervalSince1970: Double(range.min))
            let maxDate = Date(timeIntervalSince1970: Double(range.max))
            log("Oura: history round ts range: \(minDate) to \(maxDate)")
        }
        // Isolates JUST the sleepPhase signal's own date range (the whole-round range above mixes every
        // event type, so it can't say whether the ring's OWN sleep-phase codes landed in a plausible
        // recent night or somewhere else — this settles it directly).
        if let range = historySleepPhaseTsRangeThisRound {
            let minDate = Date(timeIntervalSince1970: Double(range.min))
            let maxDate = Date(timeIntervalSince1970: Double(range.max))
            log("Oura: history round sleepPhase ts range: \(minDate) to \(maxDate)")
        }
        let progressed = historyCursor != historyCursorAtRoundStart
        if progressed, historyRoundsThisTrigger < maxHistoryRoundsPerTrigger {
            log("Oura: continuing to next round (\(historyRoundsThisTrigger)/\(maxHistoryRoundsPerTrigger) so far)")
            startHistoryRound()
        } else {
            let reason = progressed ? "round cap reached" : "no further progress"
            live.backfilling = false
            live.lastSyncedAt = Date().timeIntervalSince1970
            log("Oura: history sync complete (\(reason); cursor=\(historyCursor), \(historyRoundsThisTrigger) round(s) this trigger)")
        }
    }

    // MARK: - Honest needs-pairing fallback (Huami precedent)

    private enum NeedsPairingReason {
        case factoryResetOrNoKey
        case authFailed(OuraAuthStatus)
        case installFailed(String)
    }

    /// Record + log the honest "this ring needs a pairing handshake NOOP can't complete" outcome (once),
    /// and drop the link so no half-authenticated session lingers. We never fabricate a reading. Also marks
    /// `adoptPhase = .failed` so an in-flight adopt's Adopting step lands on a REACHABLE honest Failed state
    /// (file-import + Advanced-key fallbacks), and clears any in-flight install key WITHOUT persisting it (a
    /// failed install must never leave a wrongly-trusted key). RECOVERY-HONEST: a factory-reset ring is NOT
    /// bricked; re-pairing it in the Oura app brings it back. We never claim a key was installed here.
    private func announceNeedsPairing(reason: NeedsPairingReason) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = nil
        adoptPhase = .failed
        guard needsPairing == nil else { return }
        let detail: String
        switch reason {
        case .factoryResetOrNoKey:
            detail = "NOOP needs the ring's install key to read it live, and that pairing handshake isn't set up yet."
        case .authFailed(let status):
            detail = "The ring rejected the pairing handshake (status \(status.rawValue))."
        case .installFailed(let why):
            detail = "NOOP couldn't take over this ring (\(why))."
        }
        let recovery = " The ring isn't bricked: re-pair it in the Oura app to recover it."
        let msg = detail + " Live data isn't available - export from the Oura app and import the file instead." + recovery
        needsPairing = msg
        log("Oura: \(msg)")
        stopReengageTimer()
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central delivers
    // them on the main thread, so MainActor isolation is sound; @preconcurrency lets this @MainActor type
    // satisfy the nonisolated CoreBluetooth requirements (same pattern as StandardHRSource / BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.service],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting -> the link is not live.
            if feedsLive { live.connected = false; live.streamingLiveHR = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The scan already filters on the Oura service, but re-check the name through the gen recogniser
        // so a coincidental service match without an Oura-shaped name is dropped (best-effort).
        let detectedGen = OuraRingGen.recognise(advertisedName: name)
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name.isEmpty ? "Oura ring" : name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id,
                                  name: name.isEmpty ? "Oura" : name,
                                  rssi: RSSI.intValue,
                                  detectedGen: detectedGen)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        // If we were scanning specifically to reach this ring (a not-yet-cached active ring), connect now.
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected - discovering services")
        failedConnectAttempts = 0   // a successful connect clears the reconnect backoff
        peripheral.delegate = self
        // Fresh driver per connection so a new session re-runs auth (the app key is session-scoped). The
        // driver's `allowKeyInstall` is gated on this connection's adopt consent ONLY: with no consent the
        // dangerous `0x24` installKey can never be sequenced, so a read-only / Advanced-key connect stays
        // honest (it announces needs-pairing instead of provisioning). Per OURA_PROTOCOL.md s3.2.
        driver = OuraDriver(ringGen: ringGen,
                            authKey: authKey().map { [UInt8]($0) },
                            allowKeyInstall: adoptIntent)
        reachedStreaming = false
        loggedFirstHR = false
        pendingInstallKey = nil
        adoptPhase = .idle
        reassembler.reset()
        clockAnchor = nil                  // re-acquire a fresh anchor from this session's own time-sync
        historyFetchInFlight = false
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Oura: WARNING failed to connect - \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        // A failed CB-level connect (e.g. a weak-signal handshake timeout at the edge of range) otherwise
        // dead-ends here with no recovery until the user manually reconnects. Reschedule with a capped
        // exponential backoff (3, 6, 12, 24, 48, 60s...) so a ring that's genuinely out of range doesn't
        // get hammered. Mirrors BLEManager's WHOOP didFailToConnect handling.
        guard !intentionalDisconnect else { return }
        failedConnectAttempts += 1
        let delay = min(60.0, 3.0 * pow(2.0, Double(failedConnectAttempts - 1)))
        log("Oura: reconnecting in \(Int(delay))s (attempt \(failedConnectAttempts))")
        let id = peripheral.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("Oura: disconnected - \(error.localizedDescription)")
        } else {
            log("Oura: disconnected (clean)")
        }
        stopReengageTimer()
        stopBackfillTimer()
        driver?.stop()
        driver = nil
        reassembler.reset()
        writeCharacteristic = nil
        loggedFirstHR = false
        reachedStreaming = false
        pendingInstallKey = nil
        // A disconnect MID-install is an honest failure (no ack came); a disconnect after streaming leaves
        // the completed `.streaming` outcome intact so the wizard's success transition isn't undone.
        if adoptPhase == .installingKey { adoptPhase = .failed }
        batteryPct = nil
        clockAnchor = nil
        // A disconnect mid-round leaves historyCursor at wherever the LAST completed round persisted it
        // (never advanced past an unacknowledged round), so the next fetch safely resumes from there.
        historyFetchInFlight = false
        historyRoundsThisTrigger = 0
        flush()
        if feedsLive { live.connected = false; live.streamingLiveHR = false; live.backfilling = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // An involuntary drop (ring went out of range, link timed out) otherwise dead-ends here with no
        // recovery until the user manually reconnects (#- the ring just sits disconnected). Reschedule a
        // flat 3s rescan, mirroring BLEManager's WHOOP disconnect handling. `needsPairing == nil` is the
        // important guard: `announceNeedsPairing` sets it and itself cancels the connection, which fires
        // this same callback — without the guard a ring with a bad/missing key would get hammered with
        // reconnect attempts forever instead of staying in its honest needs-pairing state.
        if !intentionalDisconnect, needsPairing == nil {
            log("Oura: rescanning in 3s")
            let id = peripheral.identifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                self.connect(id)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Oura: WARNING service discovery failed - \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("Oura: services discovered but the list was empty")
            return
        }
        guard let svc = services.first(where: { $0.uuid == Self.service }) else {
            log("Oura: Oura service NOT FOUND - this ring may not expose the expected GATT layout")
            return
        }
        log("Oura: Oura service found - discovering characteristics")
        // Discover the write + notify chars (gen5 also advertises ...0004/5/6, which v1 discovers but
        // never writes to). RingGen drives which to discover.
        let charUUIDs = OuraGatt.characteristicUUIDs(for: ringGen).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(charUUIDs, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Oura: WARNING characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("Oura: characteristics discovered but the list was empty")
            return
        }
        if let wc = chars.first(where: { $0.uuid == Self.writeChar }) {
            writeCharacteristic = wc
            log("Oura: write characteristic found")
        } else {
            log("Oura: write characteristic NOT FOUND - cannot drive the ring")
        }
        if let nc = chars.first(where: { $0.uuid == Self.notifyChar }) {
            log("Oura: notify characteristic found - enabling notifications")
            peripheral.setNotifyValue(true, for: nc)
        } else {
            log("Oura: notify characteristic NOT FOUND - cannot read the ring")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.notifyChar else { return }
        if let error = error {
            log("Oura: WARNING enabling notifications FAILED - \(error.localizedDescription) - ring will send no data")
            return
        }
        log("Oura: notifications enabled (isNotifying=\(characteristic.isNotifying)) - beginning auth")
        // Notifications are live: tell the driver we're ready. It returns the auth-nonce request (or, with
        // no key, drives the honest needs-pairing path).
        advance(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, characteristic.uuid == Self.notifyChar else { return }
        let bytes = [UInt8](value)
        // The notify char carries TWO framings on the same channel (OURA_PROTOCOL.md s2):
        //   - 0x2F secure-session sub-frames (auth nonce/status, enable ACKs, live-HR pushes)
        //   - inner TLV event records (IBI / HRV / SpO2 / temp / sleep-phase / battery)
        // Split the notification into outer frames; route 0x2F ones through the driver's secure handler,
        // and feed the remainder to the reassembler as TLV records.
        guard let driver else { return }
        let frames = OuraFraming.parseOuterFrames(bytes)
        // The `0x25` SetAuthKey-response is an OUTER frame (NOT a 0x2F secure sub-frame): `25 01 <status>`,
        // status `0x00` = OK (OURA_PROTOCOL.md s3.2). It only ever arrives during an adopt install we
        // initiated, so handle it ONLY while a key install is pending; otherwise it is ignored (never fed to
        // the TLV decoder, where its op byte would be misread as a record type). Per OURA_PROTOCOL.md s3.2.
        if pendingInstallKey != nil,
           let ackFrame = frames.first(where: { $0.op == Self.setAuthKeyRespOp }) {
            handleKeyInstallAck(status: ackFrame.body.first ?? 0xFF)
            return
        }
        // The `0x11` GetEvents-response is ALSO an outer frame (NOT a TLV record, despite riding the
        // same channel a history fetch's actual event records use): `11 08 <status> <sub_status>
        // <last_ring_timestamp:4 LE> <pad:2>`. It only ever arrives while a history-fetch round is in
        // flight, so handle it ONLY then; otherwise it is ignored (never fed to the TLV decoder, where
        // its op byte would be misread as a record type). Per OURA_PROTOCOL.md s5.2.
        if historyFetchInFlight,
           let eventsFrame = frames.first(where: { $0.op == Self.getEventsRespOp }) {
            handleGetEventsResponse(eventsFrame.body)
            return
        }
        if frames.contains(where: { $0.op == OuraFraming.secureSessionOp }) {
            for frame in frames where frame.op == OuraFraming.secureSessionOp {
                guard let secure = OuraFraming.parseSecureFrame(frame) else { continue }
                handleSecure(driver.handleSecureFrame(secure))
            }
            // Any non-secure outer frames in the same notification are TLV records; fall through to decode.
            // The 0x25 ack (if any) is consumed above, so it never reaches here.
            let tlvBytes = frames.filter { $0.op != OuraFraming.secureSessionOp && $0.op != Self.setAuthKeyRespOp }
                                 .flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
            if !tlvBytes.isEmpty {
                ingest(driver.ingest(notification: tlvBytes, reassembler: reassembler))
            }
            return
        }
        // No secure frame in this notification: treat the whole value as TLV record bytes.
        ingest(driver.ingest(notification: bytes, reassembler: reassembler))
    }

    /// Act on what the driver resolved a 0x2F secure sub-frame to.
    private func handleSecure(_ routing: OuraDriver.SecureRouting) {
        switch routing {
        case .nonce(let nonce):
            log("Oura: auth nonce received - submitting proof")
            advance(.nonceReceived(nonce))
        case .authStatus(let status):
            if status.isSuccess {
                log("Oura: auth OK - enabling live HR")
            } else {
                log("Oura: WARNING auth status \(status.rawValue)")
            }
            advance(.authCompleted(status))
        case .enableAck:
            advance(.enableAckReceived)
        case .liveHRPush(let body):
            guard let driver else { return }
            ingest(driver.ingestLiveHRPush(body: body))
        case .unhandled:
            break
        }
    }
}

// MARK: - Oura install-key Keychain accessor

/// Keychain Services wrapper for the per-ring 16-byte Oura application install key. Mirrors the
/// `AIKeyStore` generic-password pattern (`Strand/AI/AICoach.swift`) so the key never lands in
/// UserDefaults, a plist, or on disk in the clear. The key is scoped per `deviceId` (the `account`), so
/// each registered ring has its own item. The install key is written here from exactly two places: the
/// adopt key-install handshake (on an OK `0x25` ack, `OuraLiveSource.handleKeyInstallAck`) and the wizard's
/// Advanced "I already have my ring's key" path. This accessor only stores/reads/clears it.
public enum OuraKeyStore {
    private static let service = "com.noop.oura.installkey"
    /// The fixed key length per OURA_PROTOCOL.md s3 (16-byte application auth key).
    public static let keyLength = 16

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte install key for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        var attrs = baseQuery(deviceId: deviceId)
        attrs[kSecValueData as String] = key
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored 16-byte install key for `deviceId`, or nil if none is set (or the stored item is
    /// the wrong length, which is treated as absent so the honest needs-pairing path runs).
    public static func read(deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == keyLength else { return nil }
        return data
    }

    /// Remove the stored install key for `deviceId`.
    public static func clear(deviceId: String) {
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}
