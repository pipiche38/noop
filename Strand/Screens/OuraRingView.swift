import SwiftUI
import StrandDesign

// MARK: - Oura Ring — per-source data page
//
// Shows the daily resting HR, SpO₂, and skin-temperature series synced from the ring over BLE
// (written by `OuraBLEImporter`).  The device ID is the first active `.oura` device from the
// registry; multiple paired rings are not expected in Phase 1.
//
// A "Sync now" button calls `model.syncOura()` which fires the SourceCoordinator's Oura source.
// Sync state (lastSyncAt, syncing) comes from `model.sourceCoordinator?.ouraSource`.

struct OuraRingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    @State private var loaded = false
    @State private var series: [String: [(day: String, value: Double)]] = [:]
    @State private var range: RangeKind = .quarter
    @State private var windowCache: [String: [(day: String, value: Double)]] = [:]

    private static let seriesKeys = ["rhr", "spo2", "skin_temp_c"]

    private var ouraDeviceId: String? {
        model.deviceRegistry?.devices.first { $0.sourceKind == .oura && $0.status == .active }?.id
    }

    private var ouraSource: OuraLiveSource? { model.sourceCoordinator?.ouraSource }
    private var syncing: Bool { ouraSource?.syncing ?? false }
    private var lastSyncAt: Date? { ouraSource?.lastSyncAt }

    // MARK: Range

    private enum RangeKind: String, CaseIterable, Identifiable {
        case week = "W", month = "M", quarter = "3M", half = "6M", year = "1Y", all = "ALL"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .week: return 7; case .month: return 30; case .quarter: return 90
            case .half: return 180; case .year: return 365; case .all: return nil
            }
        }
        var caption: String {
            switch self {
            case .week: return "7 DAYS"; case .month: return "30 DAYS"; case .quarter: return "90 DAYS"
            case .half: return "180 DAYS"; case .year: return "365 DAYS"; case .all: return "ALL TIME"
            }
        }
    }

    // MARK: Body

    var body: some View {
        ScreenScaffold(
            title: "Oura Ring",
            subtitle: subtitle,
            onRefresh: { await repo.refresh() },
            lazy: loaded && hasData
        ) {
            if loaded && !hasData {
                ComingSoon(what: "No data yet. Make the Oura ring your active device and bring it near your \(Platform.deviceNoun) — it will sync HR, SpO₂ and skin temperature over Bluetooth automatically.")
            } else if !loaded {
                loadingCard
            } else {
                syncStatusBanner
                rangeControl
                rhrCard
                spo2Card
                tempCard
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .onChangeCompat(of: range) { _ in rebuildCache() }
    }

    // MARK: - Load

    private func load() async {
        guard let id = ouraDeviceId ?? model.deviceRegistry?.devices.first(where: { $0.sourceKind == .oura })?.id else {
            await MainActor.run { loaded = true }
            return
        }
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in Self.seriesKeys {
            fetched[key] = await repo.series(key: key, source: id)
        }
        await MainActor.run {
            series = fetched
            rebuildCache()
            loaded = true
        }
    }

    private var hasData: Bool { series.values.contains { !$0.isEmpty } }

    private func rebuildCache() {
        var cache: [String: [(day: String, value: Double)]] = [:]
        for key in Self.seriesKeys { cache[key] = slice(key) }
        windowCache = cache
    }

    // MARK: - Range helpers

    private var dayParser: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private func date(_ s: String) -> Date? { dayParser.date(from: s) }

    private func slice(_ key: String) -> [(day: String, value: Double)] {
        let all = series[key] ?? []
        guard let n = range.days else { return all }
        guard let last = all.last.flatMap({ date($0.day) }) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return all.filter { row in date(row.day).map { $0 >= cutoff } ?? false }
    }

    private func rows(_ key: String) -> [(day: String, value: Double)] {
        windowCache[key] ?? slice(key)
    }

    // MARK: - Subtitle

    private var subtitle: String? {
        let allDays = series.values.flatMap { $0.map(\.day) }
        guard let first = allDays.min(), let last = allDays.max(),
              let lo = date(first), let hi = date(last) else {
            return "Resting HR, SpO₂ and skin temperature from your Oura ring via BLE."
        }
        let fmt = spanFormatter
        let loS = fmt.string(from: lo); let hiS = fmt.string(from: hi)
        return loS == hiS ? loS : "\(loS) → \(hiS)"
    }

    private var spanFormatter: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy"; return f
    }

    private var relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    // MARK: - Sync status banner

    @ViewBuilder
    private var syncStatusBanner: some View {
        if syncing {
            syncCard(icon: "arrow.trianglehead.2.clockwise", tint: StrandPalette.accent, pulsing: true) {
                "Syncing ring data…"
            }
        } else if let err = ouraSource?.authError {
            syncCard(icon: "exclamationmark.triangle", tint: StrandPalette.statusWarning, pulsing: false) {
                err
            }
        } else {
            HStack(spacing: 12) {
                if let at = lastSyncAt {
                    Text("Last synced \(relativeFormatter.localizedString(for: at, relativeTo: Date()))")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button {
                    model.syncOura()
                } label: {
                    Label("Sync now", systemImage: "arrow.trianglehead.2.clockwise")
                        .font(StrandFont.subhead)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
            }
            .padding(.horizontal, 4)
        }
    }

    private func syncCard(icon: String, tint: Color, pulsing: Bool, label: () -> String) -> some View {
        NoopCard(tint: tint) {
            HStack(spacing: 10) {
                ConnectionDot(tone: .accent, pulsing: pulsing)
                Text(label())
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Range control

    private var rangeControl: some View {
        HStack(spacing: 8) {
            SegmentedPillControl(RangeKind.allCases, selection: $range) { $0.rawValue }
            Spacer()
            Text(range.caption).strandOverline()
        }
    }

    // MARK: - Chart cards

    @ViewBuilder
    private var rhrCard: some View {
        let pts = trendPoints(rows("rhr"))
        let vals = rows("rhr").map(\.value)
        let gradient = Gradient(colors: [StrandPalette.statusWarning, StrandPalette.statusCritical])
        ChartCard(
            title: "Resting heart rate",
            subtitle: "\(vals.count) readings · \(range.caption.lowercased())",
            trailing: vals.last.map { "\(Int($0.rounded())) bpm" },
            chart: {
                chartBody(pts: pts, vals: vals, gradient: gradient, fallback: 40...80,
                          fmt: { "\(Int($0.rounded())) bpm" })
            },
            footer: {
                ChartFooter(footerItems(vals, fmt: { "\(Int($0.rounded()))" }, unit: "bpm"))
            })
    }

    @ViewBuilder
    private var spo2Card: some View {
        let pts = trendPoints(rows("spo2"))
        let vals = rows("spo2").map(\.value)
        let gradient = Gradient(colors: [StrandPalette.metricCyan.opacity(0.55), StrandPalette.metricCyan])
        ChartCard(
            title: "Blood oxygen (SpO₂)",
            subtitle: "\(vals.count) readings · \(range.caption.lowercased())",
            trailing: vals.last.map { String(format: "%.0f%%", $0) },
            chart: {
                chartBody(pts: pts, vals: vals, gradient: gradient, fallback: 90...100,
                          fmt: { String(format: "%.0f%%", $0) })
            },
            footer: {
                ChartFooter(footerItems(vals, fmt: { String(format: "%.1f", $0) }, unit: "%"))
            })
    }

    @ViewBuilder
    private var tempCard: some View {
        let pts = trendPoints(rows("skin_temp_c"))
        let vals = rows("skin_temp_c").map(\.value)
        let gradient = Gradient(colors: [StrandPalette.metricAmber.opacity(0.55), StrandPalette.metricAmber])
        ChartCard(
            title: "Skin temperature",
            subtitle: "\(vals.count) readings · \(range.caption.lowercased())",
            trailing: vals.last.map { String(format: "%.1f °C", $0) },
            chart: {
                chartBody(pts: pts, vals: vals, gradient: gradient, fallback: 33...38,
                          fmt: { String(format: "%.1f °C", $0) })
            },
            footer: {
                ChartFooter(footerItems(vals, fmt: { String(format: "%.2f", $0) }, unit: "°C"))
            })
    }

    @ViewBuilder
    private func chartBody(pts: [TrendPoint], vals: [Double], gradient: Gradient,
                           fallback: ClosedRange<Double>, fmt: @escaping (Double) -> String) -> some View {
        if pts.count >= 2 {
            TrendChart(points: pts, gradient: gradient, valueRange: valueRange(pts, fallback: fallback),
                       showsArea: true, height: NoopMetrics.chartHeight, valueFormat: fmt)
        } else if let only = vals.last {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest reading").strandOverline()
                Text(fmt(only))
                    .font(StrandFont.number(34))
                    .foregroundStyle(StrandPalette.sample(stops: gradient.stops, at: 0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("No readings yet in this window.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var loadingCard: some View {
        NoopCard(tint: StrandPalette.metricAmber) {
            HStack(spacing: 10) {
                ConnectionDot(tone: .accent, pulsing: true)
                Text("Loading Oura ring data…")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Helpers

    private func trendPoints(_ pts: [(day: String, value: Double)]) -> [TrendPoint] {
        pts.compactMap { row in date(row.day).map { TrendPoint(date: $0, value: row.value) } }
    }

    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let v = pts.map(\.value)
        guard let lo = v.min(), let hi = v.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private func footerItems(_ vals: [Double], fmt: (Double) -> String, unit: String) -> [(LocalizedStringKey, String)] {
        guard let avg = vals.isEmpty ? nil : vals.reduce(0,+) / Double(vals.count),
              let lo = vals.min(), let hi = vals.max() else {
            return [("Avg", "—"), ("Min", "—"), ("Max", "—")]
        }
        return [("Avg", "\(fmt(avg)) \(unit)"), ("Min", "\(fmt(lo)) \(unit)"), ("Max", "\(fmt(hi)) \(unit)")]
    }
}
