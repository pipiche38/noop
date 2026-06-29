import Foundation
import Combine
import CoreBluetooth
import Security
import OuraProtocol

/// BLE driver for the Oura Ring Gen 3/4/5.
///
/// SOURCE OF TRUTH: Th0rgal/open_oura reverse-engineering (clean-room — no GPL/AGPL code copied;
/// only the documented protocol facts are used). EXPERIMENTAL: ships behind the experimental
/// add-device tier until hardware-verified on a production ring.
///
/// LIFECYCLE:
///   scan()       — discover rings; updates `discovered`
///   connect(id:) — run the 11-step auth + event-drain sequence on the chosen ring
///   sync()       — re-run the event drain on an already-connected, already-authed ring
///   stop()       — disconnect + clear all transient state
///
/// DATA:
///   The ring sends historical events in a drain loop (tag 0x10 batches). For Phase 1 NOOP decodes
///   HR/IBI, SpO2, and skin temperature. Decoded events are handed to the injected `onSyncComplete`
///   closure which the SourceCoordinator wires to `OuraBLEImporter`.
///
/// KEYCHAIN:
///   Each paired ring stores its 16-byte AES auth key in the keychain under the service
///   "noop.oura.authkey" at account == deviceId. A "fresh pair" ring (factory-reset before pairing)
///   gets a NOOP-generated key installed via `reqSetAuthKey`. A "key import" ring gets the user's
///   existing Oura key stored by the wizard (Phase B).
///
/// WHOOP-FIRST ISOLATION: owns its own `CBCentralManager`, never touches `BLEManager`, shares only
///   `LiveState` (for live HR updates) and the injected closures.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// A ring discovered during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var connected: Bool = false
    @Published public private(set) var syncing: Bool = false
    @Published public private(set) var lastSyncAt: Date? = nil
    @Published public private(set) var liveHR: Int? = nil
    /// Non-nil when the sync sequence encounters an unrecoverable auth failure.
    @Published public private(set) var authError: String? = nil
    /// Becomes true once auth succeeds and the ring setup commands have been written (i.e. the key is
    /// installed and the session is ready to drain).  The add-device wizard watches this to know when
    /// pairing is complete so it can register the device without waiting for the full drain.
    @Published public private(set) var pairingSucceeded: Bool = false

    // MARK: - GATT UUIDs (CoreBluetooth)

    private static let ouraService    = CBUUID(string: OuraGATT.serviceUUID)
    private static let writeChar      = CBUUID(string: OuraGATT.writeCharUUID)
    private static let notifyChar     = CBUUID(string: OuraGATT.notifyCharUUID)
    private static let chargerService = CBUUID(string: OuraGATT.chargerDockServiceUUID)

    // MARK: - Dependencies (injected)

    private let live: LiveState
    /// The device-ID partition key for keychain and cursor storage.  Mutable so the wizard can set
    /// it to the final `"oura-{uuid}"` value BEFORE calling `connect(_:)` — after which it must not
    /// change for the lifetime of the sync cycle.
    public private(set) var deviceId: String
    private let log: (String) -> Void
    /// Called once per successful sync with all events decoded in that session.
    /// The `Date` argument is the Unix time at which `reqSyncTime` was sent — used by the importer
    /// to calibrate the ring's decisecond epoch to real-world timestamps.
    private let onSyncComplete: ([OuraEvent], Date) -> Void
    /// When false (the wizard's discovery-only scanner) this source never writes LiveState.
    private let feedsLive: Bool

    // MARK: - CoreBluetooth (OWN central)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    // MARK: - Sync state machine

    private enum SyncState {
        case idle
        case discovering              // service / char discovery in progress
        case awaitingNonce            // sent reqAuthNonce, waiting for [0x2F][0x2C]…
        case awaitingAuth             // sent reqAuthenticate, waiting for [0x2F][0x2E]…
        case draining(cursor: UInt32) // event drain loop; sends reqGetEvent repeatedly
        case done                     // drain complete for this session
    }

    private var state: SyncState = .idle
    private var reassembler = OuraReassembler()
    private var pendingEvents: [OuraEvent] = []

    // MARK: - Init

    /// - Parameters:
    ///   - live: shared `LiveState` (live HR updates land here when `feedsLive` is true).
    ///   - deviceId: partition key for cursor persistence and Keychain ("oura-<uuid>").
    ///   - log: diagnostic sink (same exported strap log as other sources).
    ///   - onSyncComplete: called with all decoded events at the end of a successful drain.
    ///   - feedsLive: false in the wizard's discovery-only mode (no LiveState writes).
    public init(live: LiveState,
                deviceId: String,
                log: @escaping (String) -> Void = { _ in },
                onSyncComplete: @escaping ([OuraEvent], Date) -> Void = { _, _ in },
                feedsLive: Bool = true) {
        self.live = live
        self.deviceId = deviceId
        self.log = log
        self.onSyncComplete = onSyncComplete
        self.feedsLive = feedsLive
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Update the device ID before connecting. Call this BEFORE `connect(_:)` when the caller only
    /// learns the ring UUID at pick time (e.g. the add-device wizard).  Must not be called mid-sync.
    public func setDeviceId(_ newId: String) {
        deviceId = newId
    }

    /// Scan for Oura rings. Filters by the Oura GATT service so the charger dock is excluded.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        authError = nil
        pairingSucceeded = false
        log("Oura: scanning for Oura Ring (service \(OuraGATT.serviceUUID))…")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on — scan deferred")
            return
        }
        central.scanForPeripherals(withServices: [Self.ouraService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connect + sync sequence

    /// Connect to `id` (a ring from `discovered`) and run the full auth + event-drain sequence.
    public func connect(_ id: UUID) {
        stopScan()
        authError = nil
        pairingSucceeded = false
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            pendingConnectID = id
            log("Oura: ring \(id) not in cache — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on — connect to \(id) deferred")
            return
        }
        log("Oura: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Re-run the event drain on an already-connected, authenticated ring.
    /// If not connected, falls back to a full connect + auth + drain.
    public func sync() {
        guard let p = peripheral else {
            if let (id, _) = seenPeripherals.first {
                connect(id)
            } else {
                scan()
            }
            return
        }
        let cursor = loadCursor()
        log("Oura: re-draining events from cursor \(cursor)")
        state = .draining(cursor: cursor)
        syncing = true
        pendingEvents.removeAll()
        writeCommand(reqGetEvent(startDeciseconds: cursor), to: p)
    }

    public func stop() {
        stopScan()
        pendingConnectID = nil
        state = .idle
        reassembler.reset()
        pendingEvents.removeAll()
        syncing = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        if feedsLive { live.connected = false; live.heartRate = 0 }
        liveHR = nil
    }

    // MARK: - Auth key (Keychain)

    /// Install a freshly-generated auth key onto a factory-reset ring.
    /// The key is persisted in Keychain before the write (so it survives if the app is killed mid-write).
    func installFreshKey(to p: CBPeripheral) {
        let key = generateOuraAuthKey()
        saveKey(key)
        log("Oura: installing fresh auth key (factory-reset mode)")
        writeCommand(reqSetAuthKey(key: key), to: p)
    }

    private func loadKey() -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "noop.oura.authkey",
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return Array(data)
    }

    private func saveKey(_ key: [UInt8]) {
        let data = Data(key)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "noop.oura.authkey",
            kSecAttrAccount as String: deviceId
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Event cursor (UserDefaults)

    private func loadCursor() -> UInt32 {
        UInt32(max(0, UserDefaults.standard.integer(forKey: "oura.cursor.\(deviceId)")))
    }

    private func saveCursor(_ cursor: UInt32) {
        UserDefaults.standard.set(Int(cursor), forKey: "oura.cursor.\(deviceId)")
    }

    // MARK: - BLE write helper

    private func writeCommand(_ data: Data, to p: CBPeripheral) {
        guard let ch = writeCharacteristic else {
            log("Oura: WARNING — write characteristic not yet discovered, dropping command")
            return
        }
        p.writeValue(data, for: ch, type: .withResponse)
    }

    // MARK: - Sync sequence steps

    private func stepRequestNonce(_ p: CBPeripheral) {
        log("Oura: requesting auth nonce")
        state = .awaitingNonce
        writeCommand(reqAuthNonce(), to: p)
    }

    private func stepAuthenticate(nonce: [UInt8], p: CBPeripheral) {
        guard let key = loadKey() else {
            log("Oura: ERROR — no auth key in Keychain for device \(deviceId). " +
                "Re-pair the ring via NOOP's Add Device flow.")
            authError = "No auth key found. Add the ring again from the Devices screen."
            state = .idle
            return
        }
        guard let encrypted = encryptOuraNonce(nonce, key: key) else {
            log("Oura: ERROR — AES encryption failed (key length \(key.count))")
            state = .idle
            return
        }
        log("Oura: authenticating")
        state = .awaitingAuth
        writeCommand(reqAuthenticate(encrypted: encrypted), to: p)
    }

    private func stepPostAuthSetup(_ p: CBPeripheral) {
        pairingSucceeded = true   // signal the add-device wizard before starting the drain
        let now = UInt64(Date().timeIntervalSince1970)
        // Timezone offset in 30-minute half-hours (positive = east of UTC).
        let tz = Int(TimeZone.current.secondsFromGMT()) / 1800
        let tzByte = UInt8(bitPattern: Int8(clamping: tz))
        log("Oura: syncing time (unix=\(now), tz_half_hours=\(tz))")
        writeCommand(reqSyncTime(unixSecs: now, tzHalfHours: tzByte), to: p)
        // Enable the features we read (automatic background collection).
        writeCommand(reqSetFeatureMode(feature: .daytimeHR, mode: .automatic), to: p)
        writeCommand(reqSetFeatureMode(feature: .spo2, mode: .automatic), to: p)
        writeCommand(reqSetFeatureMode(feature: .restingHR, mode: .automatic), to: p)
    }

    private func stepStartDrain(_ p: CBPeripheral) {
        let cursor = loadCursor()
        log("Oura: starting event drain from cursor \(cursor) deciseconds")
        state = .draining(cursor: cursor)
        syncing = true
        pendingEvents.removeAll()
        writeCommand(reqGetEvent(startDeciseconds: cursor), to: p)
    }

    // MARK: - Notification dispatcher

    /// Route a fully-reassembled TLV packet to the right handler based on current state.
    private func handlePacket(_ packet: Data, from p: CBPeripheral) {
        guard !packet.isEmpty else { return }
        let tag = packet[0]

        switch state {
        case .awaitingNonce:
            if let nonce = parseNonce(packet) {
                log("Oura: nonce received (\(nonce.count) bytes)")
                stepAuthenticate(nonce: nonce, p: p)
            }

        case .awaitingAuth:
            if let result = parseAuthResult(packet) {
                switch result {
                case .success:
                    log("Oura: auth OK — setting up features")
                    stepPostAuthSetup(p)
                    stepStartDrain(p)
                case .inFactoryReset:
                    log("Oura: ring is in factory-reset mode — installing key")
                    installFreshKey(to: p)
                    // After key install the ring requires a new nonce/auth cycle.
                    stepRequestNonce(p)
                case .authenticationError:
                    let msg = "Oura authentication failed — wrong key. Re-pair the ring from the Devices screen."
                    log("Oura: ERROR — \(msg)")
                    authError = msg
                    state = .idle
                case .notOriginalOnboardedDevice:
                    let msg = "Oura auth rejected: this ring was originally paired to a different device."
                    log("Oura: ERROR — \(msg)")
                    authError = msg
                    state = .idle
                case .unknown:
                    log("Oura: WARNING — unknown auth result byte 0x\(String(packet[3], radix: 16))")
                }
            }

        case .draining(let cursor):
            guard tag == 0x10 else { return }  // event-batch response tag

            // Collect events from the batch body (after the batch summary header).
            if packet.count > 7 {
                let batchBody = packet.dropFirst(7)  // skip [tag][len][events_count][bytes_left u32]
                let events = OuraEvent.parseAll(from: Data(batchBody))
                pendingEvents.append(contentsOf: events)

                // Update live HR from any IBI event in this batch.
                for ev in events where ev.tag == OuraEventTag.greenIBIQuality.rawValue {
                    if let bpm = decodeHRFromGreenIBI(ev.body), feedsLive {
                        live.heartRate = bpm
                        liveHR = bpm
                    }
                }
            }

            if let summary = OuraEventBatchSummary(packet: packet) {
                let newCursor = summary.eventsInBatch > 0 ? cursor + UInt32(summary.eventsInBatch) : cursor
                if summary.bytesLeft > 0 {
                    // More events available — advance cursor and fetch next batch.
                    state = .draining(cursor: newCursor)
                    writeCommand(reqGetEvent(startDeciseconds: newCursor), to: p)
                } else {
                    // Drain complete.
                    saveCursor(newCursor)
                    finishDrain()
                }
            } else {
                // Couldn't parse batch summary — treat as drain complete to avoid infinite loop.
                log("Oura: WARNING — could not parse batch summary; ending drain")
                finishDrain()
            }

        default:
            break
        }
    }

    private func finishDrain() {
        log("Oura: sync complete — \(pendingEvents.count) events decoded")
        state = .done
        syncing = false
        let syncedAt = Date()
        lastSyncAt = syncedAt
        if feedsLive { live.connected = true }
        let events = pendingEvents
        pendingEvents.removeAll()
        onSyncComplete(events, syncedAt)
    }
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.ouraService],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            if feedsLive { live.connected = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // Exclude the charger dock (different service UUID, but scan might see it on a broad scan).
        // Since we scan WITH the Oura service filter this should only fire for genuine rings.
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(Self.chargerService) { return }

        // Optional: filter by manufacturer ID 0x02B2 if the manufacturer data is present.
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfgData.count >= 2 {
            let mfgID = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            if mfgID != OuraGATT.manufacturerID { return }
        }

        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Oura Ring"
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id, name: name.isEmpty ? "Oura Ring" : name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected — discovering Oura service")
        connected = true
        state = .discovering
        reassembler.reset()
        peripheral.delegate = self
        peripheral.discoverServices([Self.ouraService])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Oura: WARNING — connection failed: \(error?.localizedDescription ?? "unknown")")
        if feedsLive { live.connected = false }
        connected = false
        state = .idle
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Oura: disconnected\(error.map { " — \($0.localizedDescription)" } ?? " (clean)")")
        connected = false
        syncing = false
        state = .idle
        reassembler.reset()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        liveHR = nil
        if feedsLive { live.connected = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Oura: WARNING — service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services,
              let ouraSvc = services.first(where: { $0.uuid == Self.ouraService }) else {
            log("Oura: Oura service not found after discovery (unexpected)")
            return
        }
        peripheral.discoverCharacteristics([Self.writeChar, Self.notifyChar], for: ouraSvc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Oura: WARNING — characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.uuid == Self.notifyChar {
                notifyCharacteristic = ch
                peripheral.setNotifyValue(true, for: ch)
                log("Oura: subscribed to notify char")
            } else if ch.uuid == Self.writeChar {
                writeCharacteristic = ch
            }
        }
        // Begin the auth sequence once both characteristics are ready.
        if writeCharacteristic != nil, notifyCharacteristic != nil {
            stepRequestNonce(peripheral)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Oura: WARNING — notify subscription failed: \(error.localizedDescription)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Oura: WARNING — write failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyChar,
              error == nil,
              let value = characteristic.value else { return }
        reassembler.feed(value)
        for packet in reassembler.consume() {
            handlePacket(packet, from: peripheral)
        }
    }
}
