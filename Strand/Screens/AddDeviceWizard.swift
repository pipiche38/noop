import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Add a device — guided, branching wizard
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → BLEManager's present-scan (`scanForWhoops`), targeted at the
//     chosen WHOOP family via `model.presentWhoopScan(model:)`. Lists nearby straps from
//     `ble.discoveredWhoops` (a present-only mode that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN
//     isolated `StandardHRSource` scanning the standard 0x180D HR service. Lists from `discovered`.
//
// Registration goes through `model.registerDevice(_:makeActive:)` → DeviceRegistry; the
// SourceCoordinator reacts to the active-device change and connects. The wizard never touches
// BLEManager directly — only the AppModel pass-throughs. WHOOP-FIRST: WHOOP is the primary band; the
// type list shows it first and a footer reiterates it. Renders cleanly with nothing nearby (the type
// picker, every prep step, and the searching/empty pick state all need no hardware).

struct AddDeviceWizard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let onClose: () -> Void

    // MARK: Flow

    /// What the user is adding. Drives the prep copy AND which scan/register path runs.
    enum DeviceType: Identifiable, Hashable {
        case whoop5mg
        case whoop4
        case hrStrap
        case gymEquipment
        // EXPERIMENTAL tier — best-effort, clean-room, can't be hardware-verified here. Each fails to an
        // honest message and never fabricates data.
        case amazfit       // Amazfit / Zepp incl. Helio (Huami custom or standard HR)
        case miBand        // Xiaomi Mi Band (Huami; no-auth live HR path, honest message if auth needed)
        case garmin        // Garmin watch (standard Broadcast HR path + an enable hint)
        case oura          // Oura Ring Gen 3/4/5 — live BLE sync via open_oura (AES-128/ECB, factory-reset pair)
        var id: Self { self }

        var isWhoop: Bool { self == .whoop4 || self == .whoop5mg }
        var whoopModel: WhoopModel? {
            switch self {
            case .whoop4:   return .whoop4
            case .whoop5mg: return .whoop5mg
            default:        return nil
            }
        }

        /// True for the EXPERIMENTAL tier (shown under a clearly-labelled "Experimental" heading).
        var isExperimental: Bool {
            switch self {
            case .amazfit, .miBand, .garmin, .oura: return true
            default:                                return false
            }
        }
    }

    enum Step { case type, prep, pick, confirm }

    @State private var step: Step = .type
    @State private var type: DeviceType?

    // The chosen strap, in whichever shape its path produces.
    /// A WHOOP picked from `discoveredWhoops` (uuid / advertised name / rssi).
    @State private var pickedWhoop: (uuid: String, name: String, rssi: Int)?
    /// A generic HR strap picked from the StandardHRSource scan.
    @State private var pickedStrap: StandardHRSource.DiscoveredStrap?
    /// An FTMS gym machine picked from the FTMSSource scan.
    @State private var pickedMachine: FTMSSource.DiscoveredMachine?
    /// An EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band) picked from the HuamiHRSource scan.
    @State private var pickedHuami: HuamiHRSource.DiscoveredDevice?

    @State private var nameDraft = ""
    /// After registering, ask whether to make the new device active.
    @State private var askMakeActive = false

    /// Discovery-only HR source for the strap path. Never persists (no-op closure) and is never asked
    /// to `connect` — we only read its `@Published discovered` / `scanning` while scanning. Built once.
    @StateObject private var hrScanner: StandardHRSource
    /// Discovery-only FTMS source for the gym-equipment path. `feedsLive: false` so it never writes
    /// LiveState; we only read its `discovered` / `scanning` while scanning. Built once.
    @StateObject private var ftmsScanner: FTMSSource
    /// Discovery-only EXPERIMENTAL Huami scanner (Amazfit / Zepp / Mi Band). `feedsLive: false`, never
    /// persists; the wizard only reads its `discovered` / `scanning`. Built once.
    @StateObject private var huamiScanner: HuamiHRSource
    /// Discovery + pairing scanner for the Oura Ring wizard. `feedsLive: false` — wizard mode, no
    /// LiveState writes. Device ID starts as a placeholder; the wizard sets it to the final
    /// `"oura-{uuid}"` value just before `connect(_:)` is called.
    @StateObject private var ouraScanner: OuraLiveSource
    /// The ring the user tapped "Pair" on in the Oura scan list. Populated by `OuraWizardFlow`.
    @State private var pickedOuraRing: OuraLiveSource.DiscoveredRing? = nil

    init(live: LiveState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Route each throwaway scanner's diagnostics into the SAME exported strap log the active source
        // path uses (issue #421 parity), so a tester's wizard scan — including the Oura pairing sequence
        // — is captured in a shared debug bundle. The sources already self-prefix their lines
        // ("HR-strap: " / "FTMS: " / "Huami: " / "Oura: "); we add the same
        // "[HH:mm:ss]" stamp AppModel's `straplog` uses so wizard lines read identically. Each source is
        // @MainActor and only calls this from the main actor, so the forward into @MainActor LiveState is
        // safe. Privacy-safe: statuses / service UUIDs / counts only, never a device address.
        let wizardLog: (String) -> Void = { line in
            MainActor.assumeIsolated {
                live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            }
        }
        _hrScanner = StateObject(wrappedValue: StandardHRSource(
            live: live, deviceId: "scan-preview", persist: { _ in }, log: wizardLog))
        _ftmsScanner = StateObject(wrappedValue: FTMSSource(live: live, log: wizardLog, feedsLive: false))
        _huamiScanner = StateObject(wrappedValue: HuamiHRSource(
            live: live, deviceId: "scan-preview", log: wizardLog, feedsLive: false))
        _ouraScanner = StateObject(wrappedValue: OuraLiveSource(
            live: live, deviceId: "oura-wizard-scan",
            log: wizardLog, feedsLive: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    switch step {
                    case .type:    typeStep
                    case .prep:    prepStep
                    case .pick:    pickStep
                    case .confirm: confirmStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
        // Stop whichever scan is live whenever the sheet goes away (belt-and-braces alongside the
        // per-transition stops below) so neither central keeps scanning after dismiss.
        .onDisappear { stopAllScans() }
        // After adding, offer to make the new device active.
        .alert("Make this your active device?",
               isPresented: $askMakeActive) {
            Button("Not now", role: .cancel) { finishAdd(makeActive: false) }
            Button("Make active") { finishAdd(makeActive: true) }
        } message: {
            Text("Make \(confirmName) your active device now? It will provide your live data. You can change this any time.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if step != .type {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let sub = headerSubtitle {
                    Text(sub).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button(action: { stopAllScans(); onClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var headerTitle: LocalizedStringKey {
        switch step {
        case .type:    return "Add a device"
        case .prep:    return LocalizedStringKey(type.map(typeTitle) ?? "Add a device")
        case .pick:    return "Pick your device"
        case .confirm: return "Name & confirm"
        }
    }

    private var headerSubtitle: LocalizedStringKey? {
        switch step {
        case .type:    return "What are you adding?"
        case .prep:    return "Get it ready, then scan."
        case .pick:    return "Tap the one that's yours."
        case .confirm: return nil
        }
    }

    // MARK: Step 1 — type picker

    @ViewBuilder private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            typeRow(.whoop5mg, icon: "applewatch.side.right",
                    title: "WHOOP 5.0 / MG",
                    subtitle: "Newer WHOOP band — experimental in NOOP")
            typeRow(.whoop4, icon: "applewatch.side.right",
                    title: "WHOOP 4.0",
                    subtitle: "NOOP's primary, fully-supported band")
            typeRow(.hrStrap, icon: "heart.circle",
                    title: "Heart-rate strap",
                    subtitle: "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast")
            typeRow(.gymEquipment, icon: "figure.run.treadmill",
                    title: "Gym equipment",
                    subtitle: "Treadmill, indoor bike, rower or cross-trainer (Bluetooth FTMS)")

            // EXPERIMENTAL tier — clearly labelled, opt-in, best-effort. Each is honest about what it can
            // actually read; none fabricates data.
            Text("Experimental").strandOverline().padding(.top, 8)
            experimentalTierNote
            typeRow(.amazfit, icon: "waveform.path.ecg.rectangle",
                    title: "Amazfit / Zepp",
                    subtitle: "Incl. Helio. Live heart rate where the band exposes it. Help us test.")
            typeRow(.miBand, icon: "waveform.path.ecg",
                    title: "Xiaomi Mi Band",
                    subtitle: "Live heart rate on bands that don't need pairing. Help us test.")
            typeRow(.garmin, icon: "applewatch",
                    title: "Garmin watch",
                    subtitle: "Uses the watch's Broadcast Heart Rate. We'll show you how.")
            typeRow(.oura, icon: "circle.circle",
                    title: "Oura ring",
                    subtitle: "Live isn't available. We'll check, then point you to file import.")

            whoopFirstNote
        }
    }

    private func typeRow(_ t: DeviceType, icon: String, title: String, subtitle: String) -> some View {
        Button {
            type = t
            step = .prep
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: Step 2 — type-specific prep + guidance

    @ViewBuilder private var prepStep: some View {
        if let type {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: typeIcon(type))
                        .font(.system(size: 30))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(typeTitle(type)).font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }

                if type == .whoop5mg {
                    experimentalNote
                } else if type.isExperimental {
                    experimentalTierNote
                }

                // A6 , the one-phone-at-a-time WHOOP warning, surfaced as an amber card BEFORE the user
                // scans so the most common pairing failure (the official app still holding the link) is
                // pre-empted, not discovered after a failed scan. WHOOP-only: the single-link constraint
                // is specific to the WHOOP band's bonding, not the generic HR / FTMS paths.
                if type.isWhoop {
                    singleConnectionWarning
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(prepInstructions(type).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCardSurface(cornerRadius: 14)

                Button {
                    startScan(for: type)
                    step = .pick
                } label: {
                    Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Scan for \(typeTitle(type))")
            }
        }
    }

    /// Type-specific "get it ready" guidance — the point of the branching wizard.
    private func prepInstructions(_ t: DeviceType) -> [String] {
        switch t {
        case .whoop4:
            return [
                "Put your WHOOP 4.0 on your wrist and make sure it's awake.",
                "Make sure it's NOT connected to the official WHOOP app right now.",
                "NOOP will look for it nearby.",
            ]
        case .whoop5mg:
            return [
                "WHOOP 5.0 / MG bonds to one device at a time — unpair it from the official WHOOP app first.",
                "Put the band into pairing mode, on your wrist and awake.",
                "NOOP will look for it nearby.",
            ]
        case .hrStrap:
            return [
                "Wake your strap — put it on, or dampen the contacts.",
                "Make sure it isn't connected to another app (a bike computer, the brand's own app…).",
                "NOOP will look for it nearby.",
            ]
        case .gymEquipment:
            return [
                "Wake the machine — start pedalling, walking or rowing so it powers on its Bluetooth.",
                "Make sure it isn't already connected to another app (Zwift, the gym's app, a bike computer…).",
                "NOOP looks for machines that broadcast the standard Bluetooth Fitness Machine service.",
            ]
        case .amazfit:
            return [
                "Wake your Amazfit / Zepp band and make sure it isn't connected to the Zepp app right now.",
                "NOOP reads live heart rate when the band exposes it. Some bands need a pairing we can't do yet — if so, we'll say so honestly.",
                "Experimental: this is best-effort. If live doesn't work, you can export from Zepp and import the file.",
            ]
        case .miBand:
            return [
                "Wake your Mi Band and make sure it isn't connected to the Mi Fitness / Zepp Life app right now.",
                "NOOP reads live heart rate on bands that don't require pairing. Newer bands need an auth handshake we can't do yet.",
                "Experimental: if your band needs pairing, we'll tell you honestly rather than show a fake reading.",
            ]
        case .garmin:
            return GarminBroadcast.broadcastHint
        case .oura:
            return [
                "Open the Oura app and go to Settings → My Devices → your ring → Factory Reset. This removes the Oura app's pairing so NOOP can install its own auth key.",
                "After the reset the ring LED will flash white. Keep the ring near your phone.",
                "NOOP will scan for the ring, install its key, and start syncing HR, SpO2 and skin temperature. Your Oura account-export import still works — it uses separate data.",
            ]
        }
    }

    /// SF Symbol for a device type — used on the prep step header.
    private func typeIcon(_ t: DeviceType) -> String {
        switch t {
        case .whoop4, .whoop5mg: return "applewatch.side.right"
        case .hrStrap:           return "heart.circle"
        case .gymEquipment:      return "figure.run.treadmill"
        case .amazfit:           return "waveform.path.ecg.rectangle"
        case .miBand:            return "waveform.path.ecg"
        case .garmin:            return "applewatch"
        case .oura:              return "circle.circle"
        }
    }

    // MARK: Step 3 — pick from the live scan

    @ViewBuilder private var pickStep: some View {
        if let type {
            if type.isWhoop {
                // Observe BLEManager directly so the list updates as `discoveredWhoops` grows. The
                // subview holds the @ObservedObject; the wizard owns selection + scan lifecycle.
                WhoopPickList(ble: model.ble) { strap in
                    pickedWhoop = strap
                    pickedStrap = nil
                    pickedMachine = nil
                    pickedHuami = nil
                    nameDraft = strap.name.isEmpty ? typeTitle(type) : strap.name
                    model.stopWhoopScan()
                    step = .confirm
                } onRescan: {
                    model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
                }
            } else if type == .gymEquipment {
                FTMSPickList(scanner: ftmsScanner) { machine in
                    pickedMachine = machine
                    clearOtherPicks(except: .gymEquipment)
                    nameDraft = machine.name
                    ftmsScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    ftmsScanner.scan()
                }
            } else if type == .amazfit || type == .miBand {
                // EXPERIMENTAL Huami pick list (Amazfit / Zepp / Mi Band).
                HuamiPickList(scanner: huamiScanner) { dev in
                    pickedHuami = dev
                    clearOtherPicks(except: type)
                    nameDraft = dev.name
                    huamiScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    huamiScanner.scan()
                }
            } else if type == .oura {
                // EXPERIMENTAL Oura Ring pairing — factory-reset pair, key install, event drain.
                OuraWizardFlow(scanner: ouraScanner) { ring in
                    pickedOuraRing = ring
                    nameDraft = ring.name
                    finishAdd(makeActive: true)
                } onRescan: {
                    ouraScanner.scan()
                }
            } else {
                // Heart-rate strap AND Garmin (Broadcast HR is the standard 0x180D path).
                HRPickList(scanner: hrScanner) { strap in
                    pickedStrap = strap
                    clearOtherPicks(except: type ?? .hrStrap)
                    nameDraft = strap.name
                    hrScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    hrScanner.scan()
                }
            }
        }
    }

    /// Clear every "picked" selection except the one for `keep`'s path, so re-entering the pick step or
    /// switching device types never leaves a stale pick of another shape.
    private func clearOtherPicks(except keep: DeviceType) {
        if keep.isWhoop == false { pickedWhoop = nil }
        if keep != .oura { pickedOuraRing = nil }
        switch keep {
        case .hrStrap, .garmin:    pickedHuami = nil; pickedMachine = nil
        case .gymEquipment:        pickedStrap = nil; pickedHuami = nil
        case .amazfit, .miBand:    pickedStrap = nil; pickedMachine = nil
        default:                   pickedStrap = nil; pickedMachine = nil; pickedHuami = nil
        }
    }

    // MARK: Step 4 — name + confirm

    @ViewBuilder private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SignalBars(rssi: confirmRSSI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmAdvertisedName).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(confirmBrand).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)

            Text("Name").strandOverline()
            TextField("Device name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(12)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Device name")

            Button("Add") { askMakeActive = true }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .frame(maxWidth: .infinity)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 4)
        }
    }

    // MARK: Confirm-step derived values

    private var confirmName: String {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? confirmAdvertisedName : n
    }
    private var confirmAdvertisedName: String {
        if let pickedWhoop { return pickedWhoop.name.isEmpty ? (type.map(typeTitle) ?? "Device") : pickedWhoop.name }
        if let pickedStrap { return pickedStrap.name }
        if let pickedMachine { return pickedMachine.name }
        if let pickedHuami { return pickedHuami.name }
        if let pickedOuraRing { return pickedOuraRing.name }
        return type.map(typeTitle) ?? "Device"
    }
    private var confirmBrand: String {
        if type?.isWhoop == true { return "WHOOP" }
        if type == .gymEquipment { return "Gym equipment" }
        if type == .amazfit { return "Amazfit" }
        if type == .miBand { return "Mi Band" }
        if type == .garmin { return "Garmin" }
        if let pickedStrap { return brandGuess(from: pickedStrap.name) }
        return "Heart-rate strap"
    }
    private var confirmRSSI: Int {
        pickedWhoop?.rssi ?? pickedStrap?.rssi ?? pickedMachine?.rssi ?? pickedHuami?.rssi ?? -70
    }

    // MARK: Actions

    private func goBack() {
        switch step {
        case .type:    break
        case .prep:    step = .type
        case .pick:    stopAllScans(); step = .prep
        case .confirm:
            // Re-enter the pick step and restart its scan so the user can choose a different device.
            if let type { startScan(for: type) }
            pickedWhoop = nil; pickedStrap = nil; pickedMachine = nil; pickedHuami = nil
            step = .pick
        }
    }

    private func startScan(for type: DeviceType) {
        switch type {
        case .whoop4, .whoop5mg: model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
        case .gymEquipment:      ftmsScanner.scan()
        case .amazfit, .miBand:  huamiScanner.scan()
        case .oura:              ouraScanner.scan()
        // Heart-rate strap AND Garmin both use the standard 0x180D scanner (Garmin Broadcast HR).
        case .hrStrap, .garmin:  hrScanner.scan()
        }
    }

    private func stopAllScans() {
        model.stopWhoopScan()
        hrScanner.stopScan()
        ftmsScanner.stopScan()
        huamiScanner.stopScan()
        ouraScanner.stop()
    }

    /// Build the right `PairedDevice` for the chosen path, register it, optionally activate, then close.
    private func finishAdd(makeActive: Bool) {
        stopAllScans()
        let now = Int(Date().timeIntervalSince1970)
        let name = confirmName
        let device: PairedDevice

        if let pickedWhoop, let type, let wm = type.whoopModel {
            // WHOOP: full capability set; id namespaced by uuid; model "4.0" / "5.0 MG".
            let modelLabel = (wm == .whoop4) ? "4.0" : "5.0 MG"
            device = PairedDevice(
                id: "whoop-\(pickedWhoop.uuid)",
                brand: "WHOOP",
                model: modelLabel,
                nickname: name,
                peripheralId: pickedWhoop.uuid,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedStrap {
            // Generic HR strap OR a Garmin broadcasting standard HR. Garmin is registered as a `.liveBLE`
            // device (its live HR IS the standard 0x180D path) but branded "Garmin"; both are HR + HRV.
            let isGarmin = type == .garmin
            device = PairedDevice(
                id: "\(isGarmin ? "garmin" : "strap")-\(pickedStrap.id.uuidString)",
                brand: isGarmin ? "Garmin" : brandGuess(from: pickedStrap.name),
                model: pickedStrap.name,
                nickname: name == pickedStrap.name ? nil : name,
                peripheralId: pickedStrap.id.uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedHuami {
            // EXPERIMENTAL Amazfit / Zepp / Mi Band. sourceKind `.huami` routes the SourceCoordinator to
            // the HuamiHRSource. HR only (the Huami custom characteristic carries no R-R).
            let brand = (type == .miBand) ? "Mi Band" : "Amazfit"
            device = PairedDevice(
                id: "huami-\(pickedHuami.id.uuidString)",
                brand: brand,
                model: pickedHuami.name,
                nickname: name == pickedHuami.name ? nil : name,
                peripheralId: pickedHuami.id.uuidString,
                sourceKind: .huami,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedMachine {
            // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
            // live-workout path. sourceKind `.ftms` routes the SourceCoordinator to the FTMSSource.
            device = PairedDevice(
                id: "ftms-\(pickedMachine.id.uuidString)",
                brand: "Gym equipment",
                model: pickedMachine.name,
                nickname: name == pickedMachine.name ? nil : name,
                peripheralId: pickedMachine.id.uuidString,
                sourceKind: .ftms,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedOuraRing {
            // Oura Ring Gen 3/4/5 — live BLE sync via open_oura (factory-reset pair).
            // The wizard's scanner already installed the auth key under "oura-{uuid}" in Keychain.
            device = PairedDevice(
                id: "oura-\(pickedOuraRing.id.uuidString)",
                brand: "Oura",
                model: pickedOuraRing.name,
                nickname: name == pickedOuraRing.name ? nil : name,
                peripheralId: pickedOuraRing.id.uuidString,
                sourceKind: .oura,
                capabilities: [.hr, .spo2, .skinTemp],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else {
            onClose(); return
        }

        model.registerDevice(device, makeActive: makeActive)
        onClose()
    }

    // MARK: Copy / helpers

    private func typeTitle(_ t: DeviceType) -> String {
        switch t {
        case .whoop5mg:     return "WHOOP 5.0 / MG"
        case .whoop4:       return "WHOOP 4.0"
        case .hrStrap:      return "Heart-rate strap"
        case .gymEquipment: return "Gym equipment"
        case .amazfit:      return "Amazfit / Zepp"
        case .miBand:       return "Xiaomi Mi Band"
        case .garmin:       return "Garmin watch"
        case .oura:         return "Oura ring"
        }
    }

    /// A shared "this tier is experimental" note shown on the type list heading and every experimental
    /// prep step. Honest, US-neutral, no em-dashes.
    private var experimentalTierNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("Experimental, best-effort support. We're still testing these, so they might not connect on every device. They never make up data, and they'll tell you honestly when live isn't possible.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var experimentalNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("WHOOP 5.0 / MG support is newer and still experimental in NOOP.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A6 , the amber "one phone at a time" warning shown before a WHOOP scan. A failed pairing is most
    /// often the official WHOOP app still holding the band's single BLE link; saying so up front (with the
    /// concrete fix) is the honest, frustration-saving move. Amber `statusWarning` matches the existing
    /// experimental-note treatment so it reads as "heads-up", not "error".
    private var singleConnectionWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your WHOOP only talks to one phone at a time.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Force-quit the official WHOOP app first, or pairing may fail.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heads-up. Your WHOOP only talks to one phone at a time. Force-quit the official WHOOP app first, or pairing may fail.")
    }

    private var whoopFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    /// Best-effort brand from the advertised name; neutral fallback for unknown straps.
    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        if lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") { return "Amazfit" }
        return "Heart-rate strap"
    }
}

// MARK: - WHOOP pick list (observes BLEManager's present-scan)

/// The WHOOP family pick step. Holds `@ObservedObject ble` so the list re-renders as the present-scan
/// surfaces straps in `discoveredWhoops`. Pure UI — selection + scan lifecycle live in the wizard.
private struct WhoopPickList: View {
    @ObservedObject var ble: BLEManager
    let onSelect: ((uuid: String, name: String, rssi: Int)) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: true, onRescan: onRescan)
            let found = ble.discoveredWhoops.sorted { $0.rssi > $1.rssi }
            if found.isEmpty {
                SearchingCard(whoopHint: true)
            } else {
                ForEach(found, id: \.uuid) { strap in
                    DiscoveredRow(name: strap.name.isEmpty ? "WHOOP" : strap.name,
                                  subtitle: "WHOOP",
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }
}

// MARK: - HR strap pick list (observes its own StandardHRSource)

private struct HRPickList: View {
    @ObservedObject var scanner: StandardHRSource
    let onSelect: (StandardHRSource.DiscoveredStrap) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { strap in
                    DiscoveredRow(name: strap.name,
                                  subtitle: brandGuess(from: strap.name),
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }

    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        if lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") { return "Amazfit" }
        return "Heart-rate strap"
    }
}

// MARK: - FTMS gym-equipment pick list (observes its own FTMSSource)

private struct FTMSPickList: View {
    @ObservedObject var scanner: FTMSSource
    let onSelect: (FTMSSource.DiscoveredMachine) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { machine in
                    DiscoveredRow(name: machine.name,
                                  subtitle: "Gym equipment",
                                  rssi: machine.rssi) {
                        onSelect(machine)
                    }
                }
            }
        }
    }
}

// MARK: - Huami experimental pick list (Amazfit / Zepp / Mi Band)

private struct HuamiPickList: View {
    @ObservedObject var scanner: HuamiHRSource
    let onSelect: (HuamiHRSource.DiscoveredDevice) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { dev in
                    DiscoveredRow(name: dev.name, subtitle: "Experimental", rssi: dev.rssi) {
                        onSelect(dev)
                    }
                }
            }
        }
    }
}

// MARK: - Oura Ring pairing wizard flow (factory-reset pair + key install)

private struct OuraWizardFlow: View {
    @ObservedObject var scanner: OuraLiveSource
    /// Called with the paired ring once `pairingSucceeded` fires. The parent registers the device
    /// and closes the wizard.
    let onPaired: (OuraLiveSource.DiscoveredRing) -> Void
    let onRescan: () -> Void

    @State private var pairingRing: OuraLiveSource.DiscoveredRing? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if let ring = pairingRing {
                // Pairing phase — connect is in progress or failed.
                if let error = scanner.authError {
                    ouraErrorCard(error) {
                        pairingRing = nil
                        onRescan()
                    }
                } else {
                    ouraPairingCard(ring)
                }
            } else {
                // Scanning phase — show discovered rings.
                ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
                if scanner.discovered.isEmpty {
                    SearchingCard()
                } else {
                    ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { ring in
                        DiscoveredRow(name: ring.name, subtitle: "Tap to pair", rssi: ring.rssi) {
                            scanner.stopScan()
                            scanner.setDeviceId("oura-\(ring.id.uuidString)")
                            pairingRing = ring
                            scanner.connect(ring.id)
                        }
                    }
                }
            }
        }
        .onChange(of: scanner.pairingSucceeded) { _, succeeded in
            if succeeded, let ring = pairingRing {
                onPaired(ring)
            }
        }
    }

    private func ouraPairingCard(_ ring: OuraLiveSource.DiscoveredRing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView().tint(StrandPalette.accent)
                Text("Pairing with \(ring.name)…")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text("Installing auth key on the ring. This takes a few seconds.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .frostedCardSurface(cornerRadius: 14)
    }

    private func ouraErrorCard(_ message: String, onRetry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("If the ring was not factory-reset, open the Oura app → Settings → My Devices → Factory Reset, then try again.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Rescan") { onRetry() }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface(cornerRadius: 14)
    }
}

// MARK: - Shared pick-step pieces

private struct ScanStatusBar: View {
    let searching: Bool
    let onRescan: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            StatePill(searching ? "Searching…" : "Idle",
                      tone: searching ? .accent : .neutral,
                      pulsing: searching)
            Spacer()
            Button("Rescan", action: onRescan)
                .font(StrandFont.subhead)
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
        }
    }
}

private struct SearchingCard: View {
    /// A6 , honest phase copy. WHOOP scans add the single-link reminder under the generic line, since a
    /// stuck scan there is almost always the official app still holding the band. Defaults off so the HR /
    /// FTMS / Huami / Oura pick lists keep their existing copy unchanged.
    var whoopHint: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(StrandPalette.accent)
            Text("Searching…")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Make sure it's awake and not connected elsewhere.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if whoopHint {
                Text("Not showing up? The official WHOOP app may still be holding it. Force-quit that app, then tap Rescan.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .frostedCardSurface(cornerRadius: 14)
    }
}

private struct DiscoveredRow: View {
    let name: String
    let subtitle: String
    let rssi: Int
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SignalBars(rssi: rssi)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), signal \(SignalBars.level(for: rssi)) of 4")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Add device wizard") {
    let model = AppModel()
    return AddDeviceWizard(live: model.live, onClose: {})
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
