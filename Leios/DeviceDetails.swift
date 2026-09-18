// DeviceDetails.swift
// Leios — turning a device's properties into the rows the Info tab lists.

import Foundation
import LeiosShared

/// One label / value line. Rows are built as data rather than as view code so the detail pane is a
/// plain ForEach, and so a row can simply be left out when the device doesn't report it.
struct DeviceDetail: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    /// Serial numbers, IDs and usage numbers: shown monospaced and worth selecting.
    var isIdentifier = false
}

struct DeviceDetailGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [DeviceDetail]
}

extension String {
    /// Descriptor strings are routinely padded; a trailing space reads as a layout bug.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Accumulates rows, dropping the ones with nothing to say. Keeps each group builder short enough
/// to read in one go.
private struct RowCollector {
    private(set) var rows: [DeviceDetail] = []

    mutating func add(_ id: String, _ label: String, _ value: String?, identifier: Bool = false) {
        guard let value, !value.isEmpty else { return }
        rows.append(DeviceDetail(id: id, label: label, value: value, isIdentifier: identifier))
    }
}

extension DeviceDetailGroup {

    /// The four groups, ordered by what a Leios user is most likely to be looking for rather
    /// than by the order IOKit publishes the keys in.
    static func groups(entryID: UInt64,
                       candidateEntryIDs: Set<UInt64>,
                       properties: PointerDeviceProperties,
                       elements: HIDElementSummary,
                       kind: PointerDeviceKind,
                       transport: DeviceTransport,
                       engineHandling: EngineHandling) -> [DeviceDetailGroup] {
        [DeviceDetailGroup(id: "leios", title: "What Leios Does",
                           rows: leiosRows(entryID: entryID, elements: elements, engineHandling: engineHandling)),
         DeviceDetailGroup(id: "identification", title: "Identification",
                           rows: identificationRows(properties: properties, kind: kind)),
         DeviceDetailGroup(id: "connection", title: "Connection",
                           rows: connectionRows(properties: properties, transport: transport)),
         DeviceDetailGroup(id: "hid", title: "HID Details",
                           rows: hidRows(properties: properties, candidateEntryIDs: candidateEntryIDs))]
            .filter { !$0.rows.isEmpty }
    }

    private static func leiosRows(entryID: UInt64,
                                  elements: HIDElementSummary,
                                  engineHandling: EngineHandling) -> [DeviceDetail] {
        var collector = RowCollector()
        collector.add("handling", "Affected by Leios", engineHandling.summary)
        collector.add("buttons", "Buttons", buttonSummary(elements))
        collector.add("wheel", "Scroll wheel", wheelSummary(elements))
        collector.add("highRes", "High-resolution scrolling",
                      elements.hasWheel ? (elements.hasResolutionMultiplier ? "Supported" : "Not reported") : nil)
        // The engine tells one mouse's clicks from another's by this id; see ClickCycle.State.device.
        collector.add("entryID", "Device ID", "\(entryID) (\(DeviceValueFormat.hex(entryID)))", identifier: true)
        return collector.rows
    }

    private static func identificationRows(properties: PointerDeviceProperties,
                                           kind: PointerDeviceKind) -> [DeviceDetail] {
        var collector = RowCollector()
        collector.add("kind", "Kind", kind.displayName)
        collector.add("product", "Product", properties.product?.trimmed)
        collector.add("manufacturer", "Manufacturer", properties.manufacturer?.trimmed)
        collector.add("model", "Model", properties.modelNumber?.trimmed)
        collector.add("serial", "Serial number", properties.serialNumber, identifier: true)
        collector.add("vendorID", "Vendor ID", DeviceValueFormat.identifier(properties.vendorID), identifier: true)
        collector.add("productID", "Product ID", DeviceValueFormat.identifier(properties.productID), identifier: true)
        collector.add("version", "Firmware version", DeviceValueFormat.version(properties.versionNumber))
        collector.add("country", "Country code", properties.countryCode.map(String.init))
        return collector.rows
    }

    private static func connectionRows(properties: PointerDeviceProperties,
                                       transport: DeviceTransport) -> [DeviceDetail] {
        var collector = RowCollector()
        collector.add("transport", "Connection", transport.displayName)
        collector.add("builtIn", "Built in", DeviceValueFormat.yesNo(properties.isBuiltIn))
        collector.add("location", "Location ID", DeviceValueFormat.identifier(properties.locationID, digits: 8),
                      identifier: true)
        collector.add("battery", "Battery", properties.batteryPercent.map { "\($0)%" })
        collector.add("tcc", "Needs Input Monitoring", DeviceValueFormat.yesNo(properties.requiresTCCAuthorization))
        return collector.rows
    }

    private static func hidRows(properties: PointerDeviceProperties,
                                candidateEntryIDs: Set<UInt64>) -> [DeviceDetail] {
        var collector = RowCollector()
        collector.add("primaryUsage", "Primary usage", primaryUsage(properties), identifier: true)
        collector.add("usagePairs", "Usage pairs",
                      properties.usagePairs.isEmpty ? nil
                          : properties.usagePairs.map(HIDUsageNaming.name).joined(separator: ", "),
                      identifier: true)
        collector.add("reportRate", "Report rate", reportRate(properties))
        collector.add("scrollResolution", "Scroll resolution",
                      DeviceValueFormat.resolution(properties.scrollResolutionFixed, unit: "lines per rotation"))
        collector.add("pointerAccel", "Pointer acceleration", properties.pointerAccelerationType)
        collector.add("scrollAccel", "Scroll acceleration", properties.scrollAccelerationType)
        collector.add("gestureScroll", "Gesture scrolling", DeviceValueFormat.yesNo(properties.supportsGestureScrolling))
        collector.add("reportSizes", "Max report size", reportSizes(properties))
        collector.add("candidates", "Registry entry IDs",
                      candidateEntryIDs.sorted().map(String.init).joined(separator: ", "), identifier: true)
        return collector.rows
    }

    private static func buttonSummary(_ elements: HIDElementSummary) -> String? {
        guard elements.buttonCount > 0 else { return nil }
        guard elements.highestButton >= LeiosConstants.minButton else {
            return "\(elements.buttonCount) — left and right only, nothing to remap"
        }
        return "\(elements.buttonCount), up to \(MouseButtonNaming.name(elements.highestButton))"
    }

    private static func wheelSummary(_ elements: HIDElementSummary) -> String {
        switch (elements.hasWheel, elements.hasHorizontalScroll) {
        case (true, true): return "Vertical and horizontal"
        case (true, false): return "Vertical"
        case (false, true): return "Horizontal only"
        case (false, false): return "None reported"
        }
    }

    private static func primaryUsage(_ properties: PointerDeviceProperties) -> String? {
        guard let page = properties.primaryUsagePage, let usage = properties.primaryUsage else { return nil }
        return HIDUsageNaming.name(HIDUsagePair(page: page, usage: usage))
    }

    private static func reportRate(_ properties: PointerDeviceProperties) -> String? {
        if let rate = properties.pointerReportRate, rate > 0 {
            return "\(rate) Hz"
        }
        guard let interval = properties.reportIntervalMicroseconds else { return nil }
        return DeviceValueFormat.reportRate(microseconds: interval)
    }

    private static func reportSizes(_ properties: PointerDeviceProperties) -> String? {
        let sizes = [("input", properties.maxInputReportSize),
                     ("output", properties.maxOutputReportSize),
                     ("feature", properties.maxFeatureReportSize)]
        let parts = sizes.compactMap { label, value in value.map { "\($0) \($0 == 1 ? "byte" : "bytes") \(label)" } }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum DeviceValueFormat {

    /// IOKit reports resolutions as 16.16 fixed point.
    static func fixedPoint(_ raw: Int) -> Double { Double(raw) / 65536.0 }

    static func resolution(_ raw: Int?, unit: String) -> String? {
        guard let raw, raw > 0 else { return nil }
        let value = fixedPoint(raw)
        let rounded = value.rounded()
        let text = abs(value - rounded) < 0.01 ? String(Int(rounded)) : String(format: "%.2f", value)
        return "\(text) \(unit)"
    }

    static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }

    /// Vendor and product IDs read as hex everywhere else (lsusb, ioreg), with the decimal kept
    /// because that is what IOKit hands back and what a search turns up.
    static func identifier(_ value: Int?, digits: Int = 4) -> String? {
        guard let value, value >= 0 else { return nil }
        return String(format: "0x%0\(digits)X (%d)", value, value)
    }

    /// bcdDevice: 0x0352 is firmware 3.52.
    static func version(_ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%X.%02X", value >> 8, value & 0xFF)
    }

    static func reportRate(microseconds: Int) -> String? {
        guard microseconds > 0 else { return nil }
        let hz = Int((1_000_000.0 / Double(microseconds)).rounded())
        return "\(hz) Hz (\(microseconds) µs interval)"
    }

    static func yesNo(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return value ? "Yes" : "No"
    }
}
