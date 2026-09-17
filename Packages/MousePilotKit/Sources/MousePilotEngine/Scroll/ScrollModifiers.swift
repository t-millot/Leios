// ScrollModifiers.swift
// MousePilot Engine — maps held keyboard modifiers to scroll modifications (ports Helper/Core/Scroll/ScrollModifiers.swift).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import MousePilotShared

enum ScrollInputModification: Hashable {
    case none, precise, quick
}

enum ScrollEffectModification: Hashable {
    case none, zoom, horizontalScroll
}

struct ScrollModificationResult: Hashable {
    var inputMod: ScrollInputModification = .none
    var effectMod: ScrollEffectModification = .none

    var isEmpty: Bool { inputMod == .none && effectMod == .none }
}

enum ScrollModifiers {

    /// Which modifications the given keyboard flags select under the user's settings.
    static func modifications(forFlags flags: UInt64, settings: ScrollModifierFlags) -> ScrollModificationResult {
        var result = ScrollModificationResult()
        func held(_ mask: UInt64) -> Bool { mask != 0 && (flags & mask) == mask }
        if held(settings.zoom) {
            result.effectMod = .zoom
        } else if held(settings.horizontal) {
            result.effectMod = .horizontalScroll
        }
        if held(settings.quick) {
            result.inputMod = .quick
        } else if held(settings.precise) {
            result.inputMod = .precise
        }
        return result
    }
}
