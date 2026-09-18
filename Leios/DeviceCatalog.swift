// DeviceCatalog.swift
// Leios — reading the connected pointing devices out of the IORegistry for the Info tab.

import Foundation
import IOKit
import IOKit.hid

/// Enumerates HID pointing devices.
///
/// This reads the IORegistry directly rather than going through `IOHIDManager`. The HID client API
/// asks for Input Monitoring the moment it touches a device that declares
/// `RequiresTCCAuthorization` — the built-in keyboard/trackpad does — and a settings screen has no
/// business raising that prompt. `IOServiceGetMatchingServices` plus
/// `IORegistryEntryCreateCFProperties` returns the same properties and the same element tree with
/// no permission at all, and one registry node per physical device instead of one per usage pair.
enum DeviceCatalog {

    /// Guards against a pathological descriptor: no real pointing device comes close to either.
    private static let maxElements = 2048
    private static let maxWalkDepth = 4
    private static let maxCandidates = 64

    /// Keyed by registry entry id. Neither the HID descriptor nor the registry stack changes while
    /// a device stays connected, so both are read once.
    private static var elementCache: [UInt64: HIDElementSummary] = [:]
    private static var candidateCache: [UInt64: Set<UInt64>] = [:]

    /// Drops the memo. Called when the Info tab appears.
    static func refresh() {
        elementCache.removeAll()
        candidateCache.removeAll()
    }

    static func connectedDevices() -> [PointerDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey),
                                           &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [PointerDevice] = []
        var live: Set<UInt64> = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let entryID = registryEntryID(of: service), let device = device(service, entryID: entryID) else {
                continue
            }
            live.insert(entryID)
            devices.append(device)
        }

        elementCache = elementCache.filter { live.contains($0.key) }
        candidateCache = candidateCache.filter { live.contains($0.key) }
        return PointerDeviceList.normalize(devices)
    }

    private static func device(_ service: io_service_t, entryID: UInt64) -> PointerDevice? {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = raw?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let reader = DevicePropertyReader(dict: dict, service: service)
        let properties = properties(reader)
        guard isPointingDevice(properties) else { return nil }
        return PointerDevice(properties: properties,
                             elements: elements(dict, entryID: entryID),
                             entryID: entryID,
                             candidateEntryIDs: candidates(service, entryID: entryID))
    }

    /// A device counts when any of its usage pairs is a pointer or a mouse — a composite device
    /// declares its keyboard and its mouse as separate pairs on the one node.
    private static func isPointingDevice(_ properties: PointerDeviceProperties) -> Bool {
        if properties.usagePairs.contains(where: { HIDUsage.pointingDevicePairs.contains($0) }) { return true }
        guard let page = properties.primaryUsagePage, let usage = properties.primaryUsage else { return false }
        return HIDUsage.pointingDevicePairs.contains(HIDUsagePair(page: page, usage: usage))
    }

    // MARK: Properties

    private static func properties(_ reader: DevicePropertyReader) -> PointerDeviceProperties {
        var properties = PointerDeviceProperties()
        readIdentification(reader, into: &properties)
        readConnection(reader, into: &properties)
        readCapabilities(reader, into: &properties)
        return properties
    }

    private static func readIdentification(_ reader: DevicePropertyReader,
                                           into properties: inout PointerDeviceProperties) {
        properties.product = reader.string(kIOHIDProductKey)
        properties.manufacturer = reader.string(kIOHIDManufacturerKey)
        properties.serialNumber = reader.serialNumber()
        properties.modelNumber = reader.string("ModelNumber")
        properties.vendorID = reader.int(kIOHIDVendorIDKey)
        properties.productID = reader.int(kIOHIDProductIDKey)
        properties.versionNumber = reader.int(kIOHIDVersionNumberKey)
        properties.countryCode = reader.int(kIOHIDCountryCodeKey)
    }

    private static func readConnection(_ reader: DevicePropertyReader,
                                       into properties: inout PointerDeviceProperties) {
        properties.transport = reader.string(kIOHIDTransportKey)
        properties.locationID = reader.int(kIOHIDLocationIDKey)
        properties.isBuiltIn = reader.bool(kIOHIDBuiltInKey)
        properties.batteryPercent = reader.searchedInt("BatteryPercent")
        properties.requiresTCCAuthorization = reader.bool("RequiresTCCAuthorization")
    }

    private static func readCapabilities(_ reader: DevicePropertyReader,
                                         into properties: inout PointerDeviceProperties) {
        properties.primaryUsagePage = reader.int(kIOHIDPrimaryUsagePageKey)
        properties.primaryUsage = reader.int(kIOHIDPrimaryUsageKey)
        properties.usagePairs = reader.usagePairs()
        properties.reportIntervalMicroseconds = reader.int(kIOHIDReportIntervalKey)
        properties.maxInputReportSize = reader.int(kIOHIDMaxInputReportSizeKey)
        properties.maxOutputReportSize = reader.int(kIOHIDMaxOutputReportSizeKey)
        properties.maxFeatureReportSize = reader.int(kIOHIDMaxFeatureReportSizeKey)
        // These belong to the event service below the device, not to the device node itself.
        // HIDPointerResolution is deliberately not read: macOS reports the driver's default
        // (400) rather than the mouse's real CPI, which reads as a wrong number, not a system one.
        properties.scrollResolutionFixed = reader.searchedInt("HIDScrollResolution")
        properties.pointerReportRate = reader.searchedInt("HIDPointerReportRate")
        properties.pointerAccelerationType = reader.searchedString("HIDPointerAccelerationType")
        properties.scrollAccelerationType = reader.searchedString("HIDScrollAccelerationType")
        properties.supportsGestureScrolling = reader.searchedBool("SupportsGestureScrolling")
    }

    // MARK: Elements

    private static func elements(_ dict: [String: Any], entryID: UInt64) -> HIDElementSummary {
        if let cached = elementCache[entryID] { return cached }
        let summary = HIDElementSummary(elements: elementUsages(dict))
        elementCache[entryID] = summary
        return summary
    }

    /// Flattens the descriptor's element tree. One pass answers the button count, the wheel,
    /// horizontal scrolling and the resolution multiplier.
    private static func elementUsages(_ dict: [String: Any]) -> [HIDUsagePair] {
        var stack = (dict[kIOHIDElementKey] as? [[String: Any]]) ?? []
        var pairs: [HIDUsagePair] = []
        while let element = stack.popLast(), pairs.count < maxElements {
            if let page = element[kIOHIDElementUsagePageKey] as? Int,
               let usage = element[kIOHIDElementUsageKey] as? Int {
                pairs.append(HIDUsagePair(page: page, usage: usage))
            }
            if let children = element[kIOHIDElementKey] as? [[String: Any]] {
                stack.append(contentsOf: children)
            }
        }
        return pairs
    }

    // MARK: Registry

    private static func candidates(_ service: io_service_t, entryID: UInt64) -> Set<UInt64> {
        if let cached = candidateCache[entryID] { return cached }
        var ids: Set<UInt64> = []
        collectEntryIDs(from: service, depth: 0, into: &ids)
        candidateCache[entryID] = ids
        return ids
    }

    /// The device's own entry id plus its descendants'. CGEvent field 87 is the entry id of the
    /// sending device, but which node of the HID stack that names — the device, its interface, the
    /// event service below it — is not fixed, so collect them all and match against the set.
    private static func collectEntryIDs(from service: io_service_t, depth: Int, into ids: inout Set<UInt64>) {
        if let entryID = registryEntryID(of: service) { ids.insert(entryID) }
        guard depth < maxWalkDepth, ids.count < maxCandidates else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            collectEntryIDs(from: child, depth: depth + 1, into: &ids)
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
    }

    private static func registryEntryID(of service: io_service_t) -> UInt64? {
        guard service != 0 else { return nil }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        return entryID
    }
}

/// One device's properties. Most live on the device node; the ones the event service below it
/// publishes instead are found by searching the subtree, which is why that is a separate call
/// rather than an automatic fallback on every key.
private struct DevicePropertyReader {
    let dict: [String: Any]
    let service: io_service_t

    func string(_ key: String) -> String? { dict[key] as? String }
    func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { (dict[key] as? NSNumber)?.boolValue }

    func searchedString(_ key: String) -> String? { string(key) ?? searched(key) as? String }
    func searchedInt(_ key: String) -> Int? { int(key) ?? (searched(key) as? NSNumber)?.intValue }
    func searchedBool(_ key: String) -> Bool? { bool(key) ?? (searched(key) as? NSNumber)?.boolValue }

    /// The serial number is published by the transport node above the device rather than by the
    /// device itself, so it has to be looked for upwards. Only a couple of levels, and only on a
    /// node that agrees about the vendor and product: further up a USB tree sits the hub, whose
    /// own serial number would otherwise be reported as the mouse's.
    func serialNumber() -> String? {
        if let own = string(kIOHIDSerialNumberKey) { return own }
        let vendorID = int(kIOHIDVendorIDKey)
        let productID = int(kIOHIDProductIDKey)
        var node = service
        var owned: io_registry_entry_t = 0
        defer { if owned != 0 { IOObjectRelease(owned) } }
        for _ in 0..<2 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            if owned != 0 { IOObjectRelease(owned) }
            owned = parent
            node = parent
            let properties = Self.properties(of: parent)
            if let serial = properties[kIOHIDSerialNumberKey] as? String,
               Self.agrees(properties, kIOHIDVendorIDKey, vendorID),
               Self.agrees(properties, kIOHIDProductIDKey, productID) {
                return serial
            }
        }
        return nil
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return raw?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// A node that doesn't declare the id at all is still this device's own transport; one that
    /// declares a different id is something else, and its serial number is not ours to show.
    private static func agrees(_ properties: [String: Any], _ key: String, _ expected: Int?) -> Bool {
        guard let actual = (properties[key] as? NSNumber)?.intValue, let expected else { return true }
        return actual == expected
    }

    func usagePairs() -> [HIDUsagePair] {
        guard let raw = dict[kIOHIDDeviceUsagePairsKey] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let page = (entry[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                  let usage = (entry[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
            else { return nil }
            return HIDUsagePair(page: page, usage: usage)
        }
    }

    private func searched(_ key: String) -> Any? {
        guard service != 0 else { return nil }
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                               IOOptionBits(kIORegistryIterateRecursively))
    }
}
