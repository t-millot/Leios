// PointerDeviceTests.swift
// Covers the pure half of the Info tab: how IOKit properties become a described device.
// DeviceCatalog itself is not tested — it only reads hardware and hands the results to this layer.

import XCTest
import MousePilotShared
@testable import MousePilot

final class PointerDeviceTests: XCTestCase {

    // MARK: Kind

    func testTrackpadIsRecognisedByItsDigitizerUsage() {
        let pairs = [HIDUsagePair(page: 0x01, usage: 0x02), HIDUsagePair(page: 0x0D, usage: 0x05)]
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: pairs, product: "Magic Mouse",
                                                  supportsGestureScrolling: nil), .trackpad)
    }

    func testTrackpadIsRecognisedWhenOnlyTheDriverSaysSo() {
        // The built-in trackpad reports Mouse (1:2) like any mouse; only the driver hints otherwise.
        let pairs = [HIDUsagePair(page: 0x01, usage: 0x02), HIDUsagePair(page: 0x01, usage: 0x01)]
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: pairs, product: "Apple Internal Keyboard / Trackpad",
                                                  supportsGestureScrolling: nil), .trackpad)
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: pairs, product: "Some Surface",
                                                  supportsGestureScrolling: true), .trackpad)
    }

    func testTabletAndTrackballAndMouseAndFallback() {
        let tablet = [HIDUsagePair(page: 0x0D, usage: 0x02)]
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: tablet, product: "Intuos",
                                                  supportsGestureScrolling: nil), .tablet)
        let mouse = [HIDUsagePair(page: 0x01, usage: 0x02)]
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: mouse, product: "Kensington Trackball",
                                                  supportsGestureScrolling: nil), .trackball)
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: mouse, product: "MX Master 3S",
                                                  supportsGestureScrolling: nil), .mouse)
        let pointerOnly = [HIDUsagePair(page: 0x01, usage: 0x01)]
        XCTAssertEqual(PointerDeviceKind.classify(usagePairs: pointerOnly, product: nil,
                                                  supportsGestureScrolling: nil), .pointer)
    }

    // MARK: Elements

    func testButtonUsagesAreCountedOnceEachAcrossCollections() {
        let elements = [HIDUsagePair(page: 0x09, usage: 1), HIDUsagePair(page: 0x09, usage: 2),
                        HIDUsagePair(page: 0x09, usage: 3), HIDUsagePair(page: 0x09, usage: 3),
                        HIDUsagePair(page: 0x09, usage: 4), HIDUsagePair(page: 0x09, usage: 5)]
        let summary = HIDElementSummary(elements: elements)
        XCTAssertEqual(summary.buttonCount, 5)
        XCTAssertEqual(summary.highestButton, 5)
    }

    func testScrollCapabilitiesComeFromTheirOwnUsages() {
        let none = HIDElementSummary(elements: [HIDUsagePair(page: 0x09, usage: 1)])
        XCTAssertFalse(none.hasWheel)
        XCTAssertFalse(none.hasHorizontalScroll)
        XCTAssertFalse(none.hasResolutionMultiplier)

        let full = HIDElementSummary(elements: [HIDUsagePair(page: 0x01, usage: 0x38),
                                                HIDUsagePair(page: 0x0C, usage: 0x0238),
                                                HIDUsagePair(page: 0x01, usage: 0x48)])
        XCTAssertTrue(full.hasWheel)
        XCTAssertTrue(full.hasHorizontalScroll)
        XCTAssertTrue(full.hasResolutionMultiplier)
        XCTAssertEqual(full.buttonCount, 0)
    }

    // MARK: Transport

    func testTransportParsing() {
        XCTAssertEqual(DeviceTransport.parse("USB"), .usb)
        XCTAssertEqual(DeviceTransport.parse("Bluetooth"), .bluetooth)
        XCTAssertEqual(DeviceTransport.parse("BTLE"), .bluetoothLowEnergy)
        XCTAssertEqual(DeviceTransport.parse("SPI"), .internalBus("SPI"))
        XCTAssertEqual(DeviceTransport.parse("Wizardry"), .other("Wizardry"))
        XCTAssertEqual(DeviceTransport.parse(nil), .unknown)
        XCTAssertEqual(DeviceTransport.parse(""), .unknown)
    }

    // MARK: Engine handling

    func testEngineHandlingFollowsTheControlsTheEngineActsOn() {
        let fiveButtonWheel = HIDElementSummary(elements: buttons(1...5) + [HIDUsagePair(page: 0x01, usage: 0x38)])
        XCTAssertEqual(EngineHandling.forDevice(kind: .mouse, elements: fiveButtonWheel),
                       .buttonsAndScroll(highestButton: 5))

        let twoButtonWheel = HIDElementSummary(elements: buttons(1...2) + [HIDUsagePair(page: 0x01, usage: 0x38)])
        XCTAssertEqual(EngineHandling.forDevice(kind: .mouse, elements: twoButtonWheel), .scrollOnly)

        // The measured built-in trackpad: three buttons, no wheel. ScrollController passes
        // continuous scrolls straight through, so only its buttons can be reached.
        let trackpad = HIDElementSummary(elements: buttons(1...3))
        XCTAssertEqual(EngineHandling.forDevice(kind: .trackpad, elements: trackpad),
                       .buttonsOnly(highestButton: 3))

        XCTAssertEqual(EngineHandling.forDevice(kind: .pointer, elements: HIDElementSummary(elements: buttons(1...2))),
                       .notAffected)
        XCTAssertFalse(EngineHandling.notAffected.isAffected)
    }

    func testATrackpadsWheelIsNotTreatedAsAScrollTheEngineReshapes() {
        let wheelish = HIDElementSummary(elements: buttons(1...2) + [HIDUsagePair(page: 0x01, usage: 0x38)])
        XCTAssertEqual(EngineHandling.forDevice(kind: .trackpad, elements: wheelish), .notAffected)
    }

    // MARK: Formatting

    func testFixedPointAndResolution() {
        XCTAssertEqual(DeviceValueFormat.fixedPoint(0x0640_0000), 1600.0, accuracy: 0.0001)
        XCTAssertEqual(DeviceValueFormat.resolution(0x0009_0000, unit: "lines per rotation"), "9 lines per rotation")
        XCTAssertNil(DeviceValueFormat.resolution(0, unit: "lines per rotation"))
        XCTAssertNil(DeviceValueFormat.resolution(nil, unit: "lines per rotation"))
    }

    func testIdentifiersAreHexUppercaseWithTheDecimalKept() {
        XCTAssertEqual(DeviceValueFormat.identifier(0x046D), "0x046D (1133)")
        XCTAssertEqual(DeviceValueFormat.hex(4_294_970_371), "0x100000C03")
        XCTAssertEqual(DeviceValueFormat.version(0x0352), "3.52")
        XCTAssertNil(DeviceValueFormat.version(0))
    }

    func testReportRateNeverDividesByZero() {
        XCTAssertEqual(DeviceValueFormat.reportRate(microseconds: 1000), "1000 Hz (1000 µs interval)")
        XCTAssertNil(DeviceValueFormat.reportRate(microseconds: 0))
        XCTAssertNil(DeviceValueFormat.reportRate(microseconds: -5))
    }

    func testYesNo() {
        XCTAssertEqual(DeviceValueFormat.yesNo(true), "Yes")
        XCTAssertEqual(DeviceValueFormat.yesNo(false), "No")
        XCTAssertNil(DeviceValueFormat.yesNo(nil))
    }

    // MARK: Device

    func testADeviceThatReportsNothingStillBuilds() {
        let device = PointerDevice(properties: PointerDeviceProperties(),
                                   elements: HIDElementSummary(elements: []),
                                   entryID: 42,
                                   candidateEntryIDs: [])
        XCTAssertEqual(device.name, "Unknown Device")
        XCTAssertEqual(device.engineHandling, .notAffected)
        // An empty candidate set still has to identify the device itself.
        XCTAssertEqual(device.candidateEntryIDs, [42])
        XCTAssertFalse(device.groups.isEmpty)
        for group in device.groups {
            XCTAssertFalse(group.rows.isEmpty, "\(group.id) should have been dropped rather than left empty")
            for row in group.rows {
                XCTAssertFalse(row.value.isEmpty)
            }
        }
    }

    func testEveryRowIdIsUniqueAcrossGroups() {
        let device = PointerDevice(properties: fullProperties(),
                                   elements: HIDElementSummary(elements: buttons(1...5)),
                                   entryID: 7,
                                   candidateEntryIDs: [7, 8])
        for group in device.groups {
            let ids = group.rows.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate row ids in \(group.id) break ForEach identity")
        }
        let groupIDs = device.groups.map(\.id)
        XCTAssertEqual(Set(groupIDs).count, groupIDs.count)
    }

    func testSubtitleSkipsAManufacturerAlreadyInTheName() {
        var properties = fullProperties()
        properties.product = "Logitech MX Master 3S"
        properties.manufacturer = "Logitech"
        let device = PointerDevice(properties: properties,
                                   elements: HIDElementSummary(elements: buttons(1...5)),
                                   entryID: 1, candidateEntryIDs: [1])
        XCTAssertEqual(device.subtitle, "USB · 5 buttons")
    }

    func testPaddedDescriptorStringsAreTrimmed() {
        // Real descriptors pad these: this mouse reports "Keychron Link " and "Keychron ".
        var properties = fullProperties()
        properties.product = "Keychron Link "
        properties.manufacturer = "Keychron "
        let device = PointerDevice(properties: properties,
                                   elements: HIDElementSummary(elements: buttons(1...5)),
                                   entryID: 1, candidateEntryIDs: [1])
        XCTAssertEqual(device.name, "Keychron Link")
        XCTAssertEqual(device.subtitle, "USB · 5 buttons")
        let product = device.groups.flatMap(\.rows).first { $0.id == "product" }
        XCTAssertEqual(product?.value, "Keychron Link")
    }

    func testANameThatIsOnlyWhitespaceFallsBackRatherThanShowingBlank() {
        var properties = PointerDeviceProperties()
        properties.product = "   "
        properties.modelNumber = "  M-1  "
        let device = PointerDevice(properties: properties, elements: HIDElementSummary(elements: []),
                                   entryID: 1, candidateEntryIDs: [1])
        XCTAssertEqual(device.name, "M-1")
    }

    // MARK: List

    func testNormalizeIsStableRegardlessOfTheOrderIOKitReturns() {
        let devices = [device(id: 3, product: "MX Master", builtIn: false),
                       device(id: 1, product: "Apple Internal Keyboard / Trackpad", builtIn: true),
                       device(id: 2, product: "MX Master", builtIn: false)]
        let expected = PointerDeviceList.normalize(devices).map(\.id)
        XCTAssertEqual(PointerDeviceList.normalize(devices.reversed()).map(\.id), expected)
        XCTAssertEqual(PointerDeviceList.normalize([devices[1], devices[2], devices[0]]).map(\.id), expected)
        // External first, then the built-in trackpad; same name breaks the tie on entry id.
        XCTAssertEqual(expected, [2, 3, 1])
    }

    func testNormalizeCollapsesTheDuplicatesIOKitReturnsPerUsagePair() {
        let one = device(id: 5, product: "MX Master", builtIn: false)
        XCTAssertEqual(PointerDeviceList.normalize([one, one, one]).count, 1)
    }

    func testSenderIDMatchesTheDeviceOrOneOfItsRegistryDescendants() {
        let devices = [device(id: 10, product: "A", builtIn: false, candidates: [10, 11, 12]),
                       device(id: 20, product: "B", builtIn: false, candidates: [20])]
        XCTAssertEqual(PointerDeviceList.device(forSenderID: 10, in: devices)?.id, 10)
        XCTAssertEqual(PointerDeviceList.device(forSenderID: 12, in: devices)?.id, 10)
        XCTAssertEqual(PointerDeviceList.device(forSenderID: 20, in: devices)?.id, 20)
        XCTAssertNil(PointerDeviceList.device(forSenderID: 99, in: devices))
        // Synthesized events, including MousePilot's own, report 0 and identify nothing.
        XCTAssertNil(PointerDeviceList.device(forSenderID: 0, in: devices))
    }

    // MARK: Fixtures

    private func buttons(_ range: ClosedRange<Int>) -> [HIDUsagePair] {
        range.map { HIDUsagePair(page: 0x09, usage: $0) }
    }

    private func fullProperties() -> PointerDeviceProperties {
        var properties = PointerDeviceProperties()
        properties.product = "MX Master 3S"
        properties.manufacturer = "Logitech"
        properties.serialNumber = "ABC123"
        properties.vendorID = 0x046D
        properties.productID = 0xB034
        properties.versionNumber = 0x0352
        properties.transport = "USB"
        properties.locationID = 0x1430_0000
        properties.isBuiltIn = false
        properties.primaryUsagePage = 0x01
        properties.primaryUsage = 0x02
        properties.usagePairs = [HIDUsagePair(page: 0x01, usage: 0x02)]
        properties.reportIntervalMicroseconds = 1000
        properties.maxInputReportSize = 8
        properties.scrollResolutionFixed = 0x0009_0000
        return properties
    }

    private func device(id: UInt64, product: String, builtIn: Bool, candidates: Set<UInt64>? = nil) -> PointerDevice {
        var properties = fullProperties()
        properties.product = product
        properties.isBuiltIn = builtIn
        return PointerDevice(properties: properties,
                             elements: HIDElementSummary(elements: buttons(1...5)),
                             entryID: id,
                             candidateEntryIDs: candidates ?? [id])
    }
}
