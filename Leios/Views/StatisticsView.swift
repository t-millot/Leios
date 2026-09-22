// StatisticsView.swift
// Leios — what the mouse has done: distance scrolled, clicks, gestures, over time.

import SwiftUI
import AppKit
import Charts
import LeiosShared

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats = StatsModel()
    @State private var metric: StatsMetric = .distance

    /// The pane shows counts; the switch that produces them and the button that throws them away
    /// both live in Settings. This is how the empty state gets the user there.
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
    /// user's week. Say why, and go to where the switch is.
    private var collectionIsOff: some View {
        ContentUnavailableView {
            Label("Statistics Are Off", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Leios is not counting anything. Turn it on in Settings and the numbers start from now.")
        } actions: {
            Button("Open Settings") { selection = .settings }
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
                : "Leios needs Device Control and Data Access before it can see your mouse."
        default:
            return "Leios is turned off, so nothing is being counted. Turn it on and the figures will start."
        }
    }

    // MARK: Content

    /// Scrolling first, then what the buttons did, then where it happened: the order a reader
    /// would ask the questions in, and it keeps each chart next to the one it explains.
    @ViewBuilder
    private var content: some View {
        tiles
        mainChart
        if stats.range.hasTimeOfDay, !stats.timeOfDay.isEmpty {
            timeOfDayChart
        }
        directionChart
        if !stats.buttonRows.isEmpty {
            buttonsChart
        }
        if !stats.actionRows.isEmpty {
            actionsChart
        }
        if stats.merged.devices.count > 1 {
            devicesChart
        }
    }

    private var tiles: some View {
        // A hero number is not a chart, and five of them are not five charts. One row when the
        // pane is wide enough to read them all, otherwise three and two — an adaptive grid left
        // the fifth tile alone on a row of its own at the default window size.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tileContents }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                tileContents
            }
        }
    }

    @ViewBuilder
    private var tileContents: some View {
        let counters = stats.summary.counters
        StatTile(title: "Scrolled", value: ScrollDistance.format(points: counters.outPoints),
                 caption: "on screen, about")
        StatTile(title: "Scroll Ticks", value: counters.inTicks.formatted(),
                 caption: "\(counters.scrollSequences.formatted()) flicks")
        StatTile(title: "Clicks", value: counters.clicks.formatted(),
                 caption: "\(counters.doubleClicks.formatted()) double")
        StatTile(title: "Drags", value: counters.dragStarts.formatted(),
                 caption: "\(ScrollDistance.format(points: counters.dragPoints)) moved")
        StatTile(title: "Actions", value: counters.actions.formatted(),
                 caption: "\(counters.holds.formatted()) from holds")
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

    /// A horizontal bar per category. No axis beneath them: every bar carries its own count.
    private static func rowsHeight(_ rows: Int) -> CGFloat { CGFloat(rows) * 30 }

    private var buttonsChart: some View {
        ChartCard(accessibilityTitle: "Clicks by Button", plotHeight: Self.rowsHeight(stats.buttonRows.count)) {
            ChartCardTitle(title: "Clicks by Button", subtitle: overTheRange)
        } chart: {
            Chart(stats.buttonRows) { row in
                BarMark(x: .value("Clicks", row.counts.clicks),
                        y: .value("Button", row.name),
                        height: Self.rowBarHeight)
                    .cornerRadius(4)
                    .foregroundStyle(Self.color(forButton: row.id))
                    .annotation(position: .trailing) { rowCount(row.counts.clicks.formatted()) }
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(row.counts.clicks) clicks")
            }
            .rowChartStyle(peak: Double(stats.buttonRows.map(\.counts.clicks).max() ?? 0))
        }
    }

    /// Rows, like every other chart of categories here. As columns, the two directions nobody
    /// scrolls in were bars of zero height with nothing to say how close to zero they were.
    private var directionChart: some View {
        ChartCard(accessibilityTitle: "Scroll Direction", plotHeight: Self.rowsHeight(stats.directionRows.count)) {
            ChartCardTitle(title: "Scroll Direction", subtitle: overTheRange)
        } chart: {
            Chart(stats.directionRows) { row in
                // One hue for all four: each bar is named on the axis, so colour would be
                // decoration repeating what the label already says.
                BarMark(x: .value("Distance", row.points),
                        y: .value("Direction", row.direction.displayName),
                        height: Self.rowBarHeight)
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .annotation(position: .trailing) { rowCount(ScrollDistance.format(points: row.points)) }
                    .accessibilityLabel(row.direction.displayName)
                    .accessibilityValue(ScrollDistance.format(points: row.points))
            }
            .rowChartStyle(peak: stats.directionRows.map(\.points).max() ?? 0)
        }
    }

    private var actionsChart: some View {
        // Beyond eight, a ninth row would be unreadable and there is no ninth hue for it.
        let top = Array(stats.actionRows.prefix(Self.categoricalHues.count))
        return ChartCard(accessibilityTitle: "Actions", plotHeight: Self.rowsHeight(top.count)) {
            ChartCardTitle(title: "Actions", subtitle: overTheRange)
        } chart: {
            // By position, which is the one chart here where colour does not follow the thing
            // it draws. The rows are the eight most-used actions of however many Leios can fire,
            // so eight hues could never name them — the label does that, and the hue is what
            // keeps one bar from running into the next. Taking them in row order is also what
            // keeps neighbouring bars to the pairs the palette is validated for, which the
            // ranking would otherwise decide.
            Chart(Array(top.enumerated()), id: \.element.id) { index, row in
                BarMark(x: .value("Times", row.count), y: .value("Action", row.name), height: Self.rowBarHeight)
                    .cornerRadius(4)
                    .foregroundStyle(Self.color(slot: index))
                    .annotation(position: .trailing) { rowCount(row.count.formatted()) }
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(row.count) times")
            }
            .rowChartStyle(peak: Double(top.map(\.count).max() ?? 0))
        }
    }

    /// Only when there is more than one, because a chart of a single bar labelled with the name
    /// of the Mac you are sitting at says nothing.
    private var devicesChart: some View {
        ChartCard(accessibilityTitle: "Macs", plotHeight: Self.rowsHeight(stats.merged.devices.count)) {
            ChartCardTitle(title: "Macs", subtitle: "Every Mac signed in to this Apple Account")
        } chart: {
            Chart(stats.merged.devices) { device in
                // By ID, named on the axis: two Macs called "MacBook Pro" plotted by name are one
                // row with both bars stacked in it and only the second one's count at the end.
                BarMark(x: .value("Clicks", device.lifetime.counters.clicks),
                        y: .value("Mac", device.id),
                        height: Self.rowBarHeight)
                    .cornerRadius(4)
                    .foregroundStyle(Self.primary)
                    .annotation(position: .trailing) { rowCount(device.lifetime.counters.clicks.formatted()) }
                    .accessibilityLabel(device.deviceName.isEmpty ? "This Mac" : device.deviceName)
                    .accessibilityValue("\(device.lifetime.counters.clicks) clicks")
            }
            .rowChartStyle(peak: Double(stats.merged.devices.map(\.lifetime.counters.clicks).max() ?? 0)) { id in
                let name = stats.merged.devices.first { $0.id == id }?.deviceName ?? ""
                return name.isEmpty ? "This Mac" : name
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let since = sinceDescription {
                Text(since)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// Whether counts leave this Mac depends on a switch in Settings, so say which case applies
    /// rather than making a claim that is only true half the time. Both switches — collecting at
    /// all, and adding up the other Macs — are in Settings now, so the note names it.
    private var privacyNote: String {
        let settingsNote = "Collecting and resetting are in Settings → Statistics."
        if model.syncEnabled, model.statsSyncEnabled {
            return "Counts from your other Macs are added in; turn that off in Settings → iCloud. \(settingsNote)"
        }
        return "Counts stay on this Mac. \(settingsNote)"
    }

    private var sinceDescription: String? {
        guard !stats.merged.isEmpty else { return nil }
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

    /// The chart hues, in the reference categorical palette's own fixed order, with a
    /// step per appearance — no single hex sits inside both the light and the dark readable band.
    /// Validated as a set against the card's own surfaces (#FFFFFF light, #252525 dark): every
    /// hue in band, worst neighbouring pair ΔE 19.6 light / 19.3 dark to normal vision and 9.1 /
    /// 8.4 to a colour-blind reader.
    ///
    /// Neighbouring, which is why `StatsModel` orders the rows by button number: eight hues
    /// cannot all be told apart from each other — orange and red are ΔE 7.1 — so the guarantee
    /// only holds between rows that actually touch, and it would be worth nothing if the counts
    /// decided which those were. Past the eighth the palette stops rather than inventing a ninth
    /// hue or starting over: a mouse can report up to `LeiosConstants.maxButton`, and those rows
    /// are grey. Every bar is named on the axis and carries its count, so grey costs nothing but
    /// the grouping.
    static let categoricalHues: [Color] = [
        primary,                                   // 1 — the accent every other chart uses
        hue(light: 0xEB6834, dark: 0xD95926),      // 2 — orange
        hue(light: 0x1BAF7A, dark: 0x199E70),      // 3 — aqua
        hue(light: 0xEDA100, dark: 0xC98500),      // 4 — yellow
        hue(light: 0xE87BA4, dark: 0xD55181),      // 5 — magenta
        hue(light: 0x008300, dark: 0x008300),      // 6 — green
        hue(light: 0x4A3AA7, dark: 0x9085E9),      // 7 — violet
        hue(light: 0xE34948, dark: 0xE66767),      // 8 — red
    ]

    /// Colour follows the button, never the bar's position, so the same button is the same colour
    /// in the week and in the year and in a month where it went unused by someone else.
    static func color(forButton button: Int) -> Color {
        // Buttons are numbered from 1, as they are in the config and the engine — button 1 is the
        // left one, which only this chart ever sees.
        guard button >= 1, button <= categoricalHues.count else { return .secondary }
        return categoricalHues[button - 1]
    }

    /// The hue for a row at a given position, for the charts whose rows are not a small dense
    /// set of numbered things the way buttons are.
    static func color(slot: Int) -> Color {
        guard slot >= 0, slot < categoricalHues.count else { return .secondary }
        return categoricalHues[slot]
    }

    /// A colour with a step per appearance, resolved by AppKit the way the system colours are.
    private static func hue(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb(dark) : srgb(light)
        })
    }

    private static func srgb(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
    }

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

    private static let rowBarHeight = MarkDimension.fixed(16)

    /// The figure at the end of a row's bar, which is what stands in for the axis.
    private func rowCount(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func axisDate(_ value: AxisValue) -> some View {
        if let date = value.as(Date.self) {
            Text(stats.range.isMonthly
                ? date.formatted(.dateTime.month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated)))
        }
    }
}
