// InfoSettingsView.swift
// MousePilot — what is connected: every pointing device this Mac can see, described.

import SwiftUI

struct InfoSettingsView: View {
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var monitor = DeviceMonitor()
    @State private var expanded: Set<UInt64> = []

    var body: some View {
        VStack(spacing: 8) {
            Form {
                ForEach(monitor.devices) { device in
                    Section {
                        DisclosureGroup(isExpanded: expansion(device.id)) {
                            details(device)
                        } label: {
                            DeviceSummaryRow(device: device, isActive: monitor.activeDeviceID == device.id)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .overlay { emptyState }
            Text("MousePilot's settings apply to every mouse at once; each device shows what reaches it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
        .onAppear {
            DeviceCatalog.refresh()
            monitor.start()
        }
        .onDisappear { monitor.stop() }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { monitor.start() } else { monitor.stop() }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var emptyState: some View {
        if monitor.devices.isEmpty {
            ContentUnavailableView("No Pointing Devices", systemImage: "computermouse",
                                   description: Text("No mouse, trackpad or tablet is reporting to macOS."))
        }
    }

    private func details(_ device: PointerDevice) -> some View {
        ForEach(device.groups) { group in
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // A bare Text in a Form row centres itself; these are headings for what follows.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            ForEach(group.rows) { row in
                LabeledContent(row.label) {
                    Text(row.value)
                        .font(row.isIdentifier ? .system(.body, design: .monospaced) : .body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func expansion(_ id: UInt64) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { isExpanded in
                    if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
                })
    }
}

private struct DeviceSummaryRow: View {
    let device: PointerDevice
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.kind.symbolName)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(device.engineHandling.isAffected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .help(device.kind.displayName)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let battery = device.batteryPercent {
                badge("\(battery)%", systemImage: "battery.50percent")
            }
            if isActive {
                badge("In use", systemImage: "hand.point.up.left.fill")
            }
        }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }
}
