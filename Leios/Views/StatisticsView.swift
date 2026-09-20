// StatisticsView.swift
// Leios — what the mouse has done: distance scrolled, clicks, gestures, over time.

import SwiftUI
import Charts
import LeiosShared

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats = StatsModel()
    @State private var metric: StatsMetric = .distance
    @State private var confirmingReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rangePicker
                if !stats.hasLoaded {
                    loading
                } else if !model.config.general.collectStatistics, stats.merged.isEmpty {
                    collectionIsOff
                } else if stats.merged.isEmpty {
                    nothingYet
                } else {
                    content
                }
                footer
            }
            .padding()
        }
        .task {
            // The file first, so something is on screen at once, then the round trip to the
            // helper for whatever it has counted since it last wrote.
            await stats.load()
            await stats.refresh(using: model)
        }
        .confirmationDialog("Reset statistics?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                Task { await stats.reset(using: model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count Leios has kept will be discarded. This cannot be undone.")
        }
    }

    // MARK: Chrome

    private var rangePicker: some View {
        Picker("Range", selection: Binding(get: { stats.range }, set: { stats.range = $0 })) {
            ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var loading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Nothing is being counted, so an empty chart would be a lie rather than a fact about the
    /// user's week. Say why, and offer the switch.
    private var collectionIsOff: some View {
        @Bindable var model = model
        return ContentUnavailableView {
            Label("Statistics Are Off", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Leios is not counting anything. Turn this on and the numbers start from now.")
        } actions: {
            Toggle("Collect usage statistics", isOn: $model.config.general.collectStatistics)
                .toggleStyle(.switch)
        }
        .frame(minHeight: 240)
    }

    private var nothingYet: some View {
        ContentUnavailableView {
            Label("Nothing Counted Yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text(engineHint)
        }
        .frame(minHeight: 240)
    }

    /// Counting only happens while the engine runs, so an empty pane usually has a reason the
    /// user can act on.
    private var engineHint: String {
        switch model.helperState {
        case .running(let accessible):
            return accessible
                ? "Use your mouse for a while and the figures will appear here."
                : "Leios needs Accessibility permission before it can see your mouse."
        default:
            return "Leios is turned off, so nothing is being counted. Turn it on and the figures will start."
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        tiles
        mainChart
        if stats.range.hasTimeOfDay, !stats.timeOfDay.isEmpty {
            timeOfDayChart
        }
        if !stats.buttonRows.isEmpty {
            buttonsChart
        }
        directionChart
        if !stats.actionRows.isEmpty {
            actionsChart
        }
        if stats.merged.devices.count > 1 {
            devicesChart
        }
    }

    private var tiles: some View {
        // A hero number is not a chart, and five of them are not five charts.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            StatTile(title: "Scrolled", value: ScrollDistance.format(points: stats.summary.counters.outPoints),
                     caption: "on screen, about")
            StatTile(title: "Scroll Ticks", value: stats.summary.counters.inTicks.formatted(),
                     caption: "\(stats.summary.counters.scrollSequences.formatted()) flicks")
            StatTile(title: "Clicks", value: stats.summary.counters.clicks.formatted(),
                     caption: "\(stats.summary.counters.doubleClicks.formatted()) double")
            StatTile(title: "Drag Gestures", value: stats.summary.counters.dragStarts.formatted(),
                     caption: ScrollDistance.format(points: stats.summary.counters.dragPoints))
            StatTile(title: "Actions", value: stats.summary.counters.actions.formatted(),
                     caption: "\(stats.summary.counters.holds.formatted()) from holds")
        }
    }

    private var mainChart: some View {
        // The picker *is* the heading. A chart needs its measure named — a single series carries
        // no legend, so the title is the only thing that says what the bars are — and a popup
        // repeating the words above it reads as a mistake.
        ChartCard(accessibilityTitle: metric.title) {
            VStack(alignment: .leading, spacing: 1) {
                Picker("Show", selection: $metric) {
                    ForEach(StatsMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.headline)
                .fixedSize()
                Text(overTheRange).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } chart: {
            Chart(stats.series) { point in
                if metric.hasInputAndOutput {
                    // Two series, one axis: both are points of scroll, so they compare directly.
                    // A legend is present because there are two, and it is the only thing that
                    // says which is which.
                    pairedBar(point, value: metric.secondaryValue(point.counters), name: Self.inputSeries)
                    pairedBar(point, value: metric.value(point.counters), name: Self.outputSeries)
                } else {
                    // One series needs no legend: the card's title names it.
                    soloBar(point, value: metric.value(point.counters))
                }
            }
            .chartForegroundStyleScale([Self.inputSeries: Self.secondary, Self.outputSeries: Self.primary])
            .chartLegend(metric.hasInputAndOutput ? .visible : .hidden)
            .chartYScale(domain: 0...max(1, peak))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if metric == .distance {
                            distanceAxisLabel(value, peak: peak)
                        } else {
                            axisNumber(value)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: stats.range.isMonthly ? .month : .day, count: xStride)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { axisDate(value) }
                }
            }
        }
    }

    private var timeOfDayChart: some View {
        ChartCard(accessibilityTitle: "Time of Day") {
            ChartCardTitle(title: "Time of Day",
                           subtitle: "When the mouse is in your hand, across the \(stats.range == .week ? "week" : "month")")
        } chart: {
            Chart(stats.timeOfDay) { point in
                BarMark(x: .value("Hour", point.date, unit: .hour),
                        y: .value("Clicks and ticks", point.counters.clicks + point.counters.inTicks))
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .accessibilityLabel(point.date.formatted(date: .omitted, time: .shortened))
                    .accessibilityValue("\(point.counters.clicks + point.counters.inTicks)")
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) {
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { axisNumber(value) }
                }
            }
        }
    }

    private var buttonsChart: some View {
        ChartCard(accessibilityTitle: "Clicks by Button") {
            ChartCardTitle(title: "Clicks by Button", subtitle: overTheRange)
        } chart: {
            Chart(stats.buttonRows) { row in
                BarMark(x: .value("Clicks", row.counts.clicks),
                        y: .value("Button", row.name))
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .annotation(position: .trailing) {
                        Text(row.counts.clicks.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(row.counts.clicks) clicks")
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { axisNumber(value) }
                }
            }
            .frame(height: CGFloat(stats.buttonRows.count) * 28 + 24)
        }
    }

    private var directionChart: some View {
        ChartCard(accessibilityTitle: "Scroll Direction") {
            ChartCardTitle(title: "Scroll Direction", subtitle: overTheRange)
        } chart: {
            Chart(stats.directionRows) { row in
                // One hue for all four: each bar is named on the axis, so colour would be
                // decoration repeating what the label already says.
                BarMark(x: .value("Direction", row.direction.displayName),
                        y: .value("Distance", row.points),
                        width: .ratio(0.45))
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .accessibilityLabel(row.direction.displayName)
                    .accessibilityValue(ScrollDistance.format(points: row.points))
            }
            .chartYScale(domain: 0...max(1, directionPeak))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { distanceAxisLabel(value, peak: directionPeak) }
                }
            }
        }
    }

    private var actionsChart: some View {
        // Beyond eight, a ninth hue would be invented and a ninth row would be unreadable.
        let top = Array(stats.actionRows.prefix(8))
        return ChartCard(accessibilityTitle: "Actions") {
            ChartCardTitle(title: "Actions", subtitle: overTheRange)
        } chart: {
            Chart(top) { row in
                BarMark(x: .value("Times", row.count), y: .value("Action", row.name))
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .annotation(position: .trailing) {
                        Text(row.count.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(row.count) times")
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { axisNumber(value) }
                }
            }
            .frame(height: CGFloat(top.count) * 28 + 24)
        }
    }

    /// Only when there is more than one, because a chart of a single bar labelled with the name
    /// of the Mac you are sitting at says nothing.
    private var devicesChart: some View {
        ChartCard(accessibilityTitle: "Macs") {
            ChartCardTitle(title: "Macs", subtitle: "Every Mac signed in to this Apple Account")
        } chart: {
            Chart(stats.merged.devices) { device in
                BarMark(x: .value("Clicks", device.lifetime.counters.clicks),
                        y: .value("Mac", device.deviceName.isEmpty ? "This Mac" : device.deviceName))
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .annotation(position: .trailing) {
                        Text(device.lifetime.counters.clicks.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(device.deviceName)
                    .accessibilityValue("\(device.lifetime.counters.clicks) clicks")
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { axisNumber(value) }
                }
            }
            .frame(height: CGFloat(stats.merged.devices.count) * 28 + 24)
        }
    }

    private var footer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Toggle("Collect usage statistics", isOn: $model.config.general.collectStatistics)
            HStack {
                Text(sinceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Statistics…", role: .destructive) { confirmingReset = true }
                    .disabled(stats.merged.isEmpty)
            }
            Text(privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// Whether counts leave this Mac depends on a switch in Settings, so say which case applies
    /// rather than making a claim that is only true half the time.
    private var privacyNote: String {
        let switchNote = "This switch stays on this Mac, like the kill switches — iCloud does not carry it."
        if model.syncEnabled, model.statsSyncEnabled {
            return "Counts from your other Macs are added in. Turn that off in Settings → iCloud. \(switchNote)"
        }
        return "Counts stay on this Mac. \(switchNote)"
    }

    private var sinceDescription: String {
        guard !stats.merged.isEmpty else { return "" }
        return "Counting since \(stats.merged.startedAt.formatted(date: .abbreviated, time: .omitted))."
    }

    // MARK: Chart details

    /// Validated in both appearances with the dataviz palette checker: systemBlue resolves to
    /// #007AFF light / #0A84FF dark, and the amber is #D2760A in both. Written out rather than
    /// taken from the system palette because these encode data, not chrome — systemOrange is too
    /// light in dark mode to sit in the readable band, and the pair has to survive colour
    /// blindness, which blue and amber do (ΔE 32 protan, 28 tritan).
    private static let primary = Color.blue
    private static let secondary = Color(red: 0xD2 / 255, green: 0x76 / 255, blue: 0x0A / 255)
    private static let inputSeries = "From the wheel"
    private static let outputSeries = "Delivered"

    @ChartContentBuilder
    private func pairedBar(_ point: StatsPoint, value: Double, name: String) -> some ChartContent {
        BarMark(x: .value("Date", point.date, unit: stats.range.isMonthly ? .month : .day),
                y: .value(metric.title, value))
            .cornerRadius(4)
            .position(by: .value("Series", name))
            .foregroundStyle(by: .value("Series", name))
            .accessibilityLabel("\(name), \(accessibilityDate(point.date))")
            .accessibilityValue(describe(value))
    }

    @ChartContentBuilder
    private func soloBar(_ point: StatsPoint, value: Double) -> some ChartContent {
        BarMark(x: .value("Date", point.date, unit: stats.range.isMonthly ? .month : .day),
                y: .value(metric.title, value))
            .cornerRadius(4)
            .foregroundStyle(Self.primary)
            .accessibilityLabel(accessibilityDate(point.date))
            .accessibilityValue(describe(value))
    }

    private var peak: Double {
        let values = stats.series.flatMap {
            metric.hasInputAndOutput
                ? [metric.value($0.counters), metric.secondaryValue($0.counters)]
                : [metric.value($0.counters)]
        }
        return values.max() ?? 1
    }

    /// Enough labels to read, few enough not to collide.
    private var xStride: Int {
        switch stats.range {
        case .week: return 1
        case .month: return 5
        case .year: return 1
        case .all: return max(1, stats.series.count / 8)
        }
    }

    private var overTheRange: String {
        switch stats.range {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last 12 months"
        case .all: return "Since Leios was installed"
        }
    }

    private func describe(_ value: Double) -> String {
        metric == .distance ? ScrollDistance.format(points: value) : Int(value).formatted()
    }

    private func accessibilityDate(_ date: Date) -> String {
        stats.range.isMonthly
            ? date.formatted(.dateTime.month(.wide).year())
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Axis labels are plain views rather than axis-content builders: the label is the only part
    /// that differs between these charts, and a `Chart` whose axes are one long modifier chain is
    /// a known slow-compile hotspot.
    @ViewBuilder
    private func axisNumber(_ value: AxisValue) -> some View {
        if let number = value.as(Double.self) {
            Text(number.formatted(.number.notation(.compactName)))
        } else if let number = value.as(Int.self) {
            Text(number.formatted(.number.notation(.compactName)))
        }
    }

    @ViewBuilder
    private func distanceAxisLabel(_ value: AxisValue, peak: Double) -> some View {
        if let number = value.as(Double.self) {
            Text(ScrollDistance.axisLabel(points: number, peak: peak))
        }
    }

    private var directionPeak: Double { stats.directionRows.map(\.points).max() ?? 1 }

    @ViewBuilder
    private func axisDate(_ value: AxisValue) -> some View {
        if let date = value.as(Date.self) {
            Text(stats.range.isMonthly
                ? date.formatted(.dateTime.month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated)))
        }
    }
}

/// One hero number. A stat tile, deliberately not a chart: a single figure plotted is a figure
/// with decoration around it.
private struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// A titled box around one chart. A `Chart` has no intrinsic height, so every one of these gives
/// it a floor; without that they collapse to nothing inside a scroll view.
private struct ChartCard<Header: View, Plot: View>: View {
    /// What VoiceOver calls the plot. The header may be a control rather than a label, so the
    /// name is passed separately rather than read off it.
    let accessibilityTitle: String
    @ViewBuilder let header: Header
    @ViewBuilder let chart: Plot

    var body: some View {
        GroupBox {
            chart
                .frame(minHeight: 180)
                .padding(.top, 4)
                // Marks are invisible to VoiceOver on their own, and the run-leios skill drives
                // this window entirely over the accessibility API.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityTitle)
        } label: {
            header
        }
    }
}

private struct ChartCardTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
