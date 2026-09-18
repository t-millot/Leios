// AnimatorTypes.swift
// Leios Engine — animator phase enums (ports Shared/Animation/AnimatorDeclarations.h).

import Foundation
import CPrivateShim

enum AnimationCallbackPhase {
    case start
    case `continue`
    /// Deltas are always zero for this phase.
    case end
    /// Passed after cancel() is called on the animator. Deltas are zero.
    case canceled
    case none
}

/// Suggests to the animator's client when to send momentum-scroll events instead of gesture-scroll events.
enum MomentumHint {
    case none
    case gesture
    case momentum
}

/// IOHIDEventPhaseBits values.
enum IOHIDPhase: Int64 {
    case undefined = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

extension AnimationCallbackPhase {
    /// `canceled` maps to `ended` — a real trackpad never sends `cancelled` for scrolls.
    var iohidPhase: IOHIDPhase {
        switch self {
        case .start: return .began
        case .continue: return .changed
        case .end: return .ended
        case .canceled: return .ended
        case .none: return .undefined
        }
    }
}
