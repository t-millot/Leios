// PointerDevice.swift
// MousePilot — one connected pointing device, as the Info tab describes it.

import Foundation

/// The IOKit properties `DeviceCatalog` reads off a device, in one typed value so everything
/// downstream is pure. All optional: a HID device publishes whatever its descriptor and its driver
/// happen to provide, and a missing key is normal rather than an error.
struct PointerDeviceProperties: Equatable {
    var product: String?
    var manufacturer: String?
    var serialNumber: String?
    var modelNumber: String?
    var vendorID: Int?
    var productID: Int?
    var versionNumber: Int?
    var countryCode: Int?
    var transport: String?
    var locationID: Int?
    var isBuiltIn: Bool?
    var primaryUsagePage: Int?
    var primaryUsage: Int?
    var usagePairs: [HIDUsagePair] = []
    var reportIntervalMicroseconds: Int?
    var maxInputReportSize: Int?
    var maxOutputReportSize: Int?
    var maxFeatureReportSize: Int?
    /// 16.16 fixed point lines per rotation.
    var scrollResolutionFixed: Int?
    var pointerReportRate: Int?
    var pointerAccelerationType: String?
    var scrollAccelerationType: String?
    var supportsGestureScrolling: Bool?
    var batteryPercent: Int?
    var requiresTCCAuthorization: Bool?
}

/// A pointing device, summarised for a row and described in full for the disclosure below it.
struct PointerDevice: Identifiable, Equatable {

    /// IORegistry entry id of the device's service. Stable for as long as the device stays connected.
    let id: UInt64
    /// This service plus its descendants. A CGEvent's sender id names one node of that stack, and
    /// which one is not fixed, so identification matches against the whole set.
    let candidateEntryIDs: Set<UInt64>

    let name: String
    let manufacturer: String?
    let kind: PointerDeviceKind
    let transport: DeviceTransport
    let isBuiltIn: Bool
    let batteryPercent: Int?
    let elements: HIDElementSummary
    let engineHandling: EngineHandling

    let properties: PointerDeviceProperties
    let groups: [DeviceDetailGroup]

    init(properties: PointerDeviceProperties,
         elements: HIDElementSummary,
         entryID: UInt64,
         candidateEntryIDs: Set<UInt64>) {
        id = entryID
        self.candidateEntryIDs = candidateEntryIDs.isEmpty ? [entryID] : candidateEntryIDs
        self.properties = properties
        self.elements = elements

        name = Self.name(from: properties)
        manufacturer = Self.trimmed(properties.manufacturer)
        kind = PointerDeviceKind.classify(usagePairs: properties.usagePairs,
                                          product: properties.product,
                                          supportsGestureScrolling: properties.supportsGestureScrolling)
        transport = DeviceTransport.parse(properties.transport)
        isBuiltIn = properties.isBuiltIn ?? false
        batteryPercent = properties.batteryPercent
        engineHandling = EngineHandling.forDevice(kind: kind, elements: elements)
        groups = DeviceDetailGroup.groups(entryID: entryID,
                                          candidateEntryIDs: self.candidateEntryIDs,
                                          properties: properties,
                                          elements: elements,
                                          kind: kind,
                                          transport: transport,
                                          engineHandling: engineHandling)
    }

    /// The line under the name: who made it, how it connects, how many buttons it has.
    var subtitle: String {
        var parts: [String] = []
        if let manufacturer, !manufacturer.isEmpty, !name.localizedCaseInsensitiveContains(manufacturer) {
            parts.append(manufacturer)
        }
        parts.append(transport.displayName)
        if elements.buttonCount > 0 {
            parts.append(elements.buttonCount == 1 ? "1 button" : "\(elements.buttonCount) buttons")
        }
        return parts.joined(separator: " · ")
    }

    private static func name(from properties: PointerDeviceProperties) -> String {
        for candidate in [properties.product, properties.modelNumber] {
            if let trimmed = trimmed(candidate) { return trimmed }
        }
        return "Unknown Device"
    }

    /// Product and manufacturer strings come straight off the descriptor and are routinely padded
    /// ("Keychron Link "), which shows up as a stray gap before the separator in the subtitle.
    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PointerDeviceList {

    /// Collapses the duplicates IOKit returns — matching is per usage pair, so one physical device
    /// comes back once per pair it matches — and puts the list in a fully ordered sequence so rows
    /// never swap places between two polls of the same unchanged hardware.
    static func normalize(_ devices: [PointerDevice]) -> [PointerDevice] {
        var unique: [UInt64: PointerDevice] = [:]
        for device in devices { unique[device.id] = device }
        return unique.values.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return !a.isBuiltIn }
            if a.kind.sortRank != b.kind.sortRank { return a.kind.sortRank < b.kind.sortRank }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
    }

    /// The device an event came from. Sender id 0 means a synthesized event — including the ones
    /// MousePilot's own engine posts — so it never identifies anything.
    static func device(forSenderID senderID: UInt64, in devices: [PointerDevice]) -> PointerDevice? {
        guard senderID != 0 else { return nil }
        return devices.first { $0.candidateEntryIDs.contains(senderID) }
    }
}
