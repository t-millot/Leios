// StatisticsCards.swift
// Leios — the boxes the Statistics pane is built from: stat tiles, chart cards, and the shared
// look of its charts of labelled rows.

import SwiftUI
import Charts

/// One hero number. A stat tile, deliberately not a chart: a single figure plotted is a figure
/// with decoration around it.
struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        // The chart cards' own box, so the tiles read as the same family — and it is the surface
        // the chart hues were validated against.
        GroupBox {
            figures
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
        .accessibilityElement(children: .combine)
    }

    private var figures: some View {
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
    }
}

/// A titled box around one chart. A `Chart` has no intrinsic height, so every one of these gives
/// it a floor; without that they collapse to nothing inside a scroll view.
struct ChartCard<Header: View, Plot: View>: View {
    /// What VoiceOver calls the plot. The header may be a control rather than a label, so the
    /// name is passed separately rather than read off it.
    let accessibilityTitle: String
    /// How tall the plot is drawn. The default is the floor a time-series chart needs — Swift
    /// Charts collapses one to nothing without it. A chart that is a list of rows knows its own
    /// height and passes it, because the floor would otherwise centre a short list in 180 points
    /// and surround it with empty card.
    var plotHeight: CGFloat = 180
    @ViewBuilder let header: Header
    @ViewBuilder let chart: Plot

    var body: some View {
        // The header goes inside the box rather than in the GroupBox label, which macOS draws
        // above and outside it — a title floating over an untitled box reads as two things.
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header
                chart
                    .frame(height: plotHeight)
                    // Marks are invisible to VoiceOver on their own, and the run-leios skill drives
                    // this window entirely over the accessibility API.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityTitle)
            }
            .padding(6)
        }
    }
}

struct ChartCardTitle: View {
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

extension View {
    /// Shared by every chart of labelled rows: the names down the leading edge, and no value axis
    /// or grid, because each bar ends in its own count. The headroom keeps that count from being
    /// clipped at the trailing edge when its bar is the longest one.
    /// `name` turns a row's plotted value into the label shown for it, for rows plotted by ID.
    func rowChartStyle(peak: Double, name: @escaping (String) -> String = { $0 }) -> some View {
        self
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...max(1, peak) * 1.2)
            .chartYAxis {
                // Extended, so the names sit in a column of their own beside the bars. The
                // default draws each one inset over the top of its own bar.
                AxisMarks(preset: .extended, position: .leading) { value in
                    AxisValueLabel(horizontalSpacing: 8) {
                        Text(name(value.as(String.self) ?? ""))
                    }
                }
            }
    }
}
