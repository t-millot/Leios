// Vector.swift
// MousePilot Engine — 2D vector helpers and direction/axis enums (ports Shared/Math/VectorUtility.m, MathObjc.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics

typealias Vector = CGPoint

enum MFAxis {
    case none, horizontal, vertical
}

enum MFDirection {
    case none, up, down, left, right
}

@inline(__always) func mfsign(_ x: Double) -> Int {
    x > 0 ? 1 : (x < 0 ? -1 : 0)
}

func signedFloor(_ num: Double) -> Double {
    if num == 0 { return 0 }
    return num > 0 ? floor(num) : ceil(num)
}

func signedCeil(_ num: Double) -> Double {
    if num == 0 { return 0 }
    return num > 0 ? ceil(num) : floor(num)
}

func approxEqual(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

func greaterEqual(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
    approxEqual(a, b, tolerance: tolerance) || a > b
}

@inline(__always) func clip(_ x: Double, _ low: Double, _ high: Double) -> Double {
    min(max(x, low), high)
}

// MARK: Vector functions

func magnitude(_ v: Vector) -> Double {
    if v.x == 0 { return abs(v.y) }
    if v.y == 0 { return abs(v.x) }
    return (v.x * v.x + v.y * v.y).squareRoot()
}

func unitVector(_ v: Vector) -> Vector {
    let mag = magnitude(v)
    if mag == 0 { return .zero }
    return scaled(v, 1.0 / mag)
}

@inline(__always) func scaled(_ v: Vector, _ scalar: Double) -> Vector {
    Vector(x: v.x * scalar, y: v.y * scalar)
}

@inline(__always) func added(_ a: Vector, _ b: Vector) -> Vector {
    Vector(x: a.x + b.x, y: a.y + b.y)
}

@inline(__always) func subtracted(_ a: Vector, _ b: Vector) -> Vector {
    Vector(x: a.x - b.x, y: a.y - b.y)
}

@inline(__always) func isZeroVector(_ v: Vector) -> Bool {
    v.x == 0 && v.y == 0
}

@inline(__always) func vectorHasNaN(_ v: Vector) -> Bool {
    v.x.isNaN || v.y.isNaN
}

func vectorByApplying(_ v: Vector, _ f: (Double) -> Double) -> Vector {
    Vector(x: f(v.x), y: f(v.y))
}

func vectorFromDeltaAndDirection(_ delta: Double, _ direction: MFDirection) -> Vector {
    assert(delta > 0)
    switch direction {
    case .up, .down: return Vector(x: 0, y: delta)
    case .left, .right: return Vector(x: delta, y: 0)
    case .none: return .zero
    }
}

func vectorFromDeltaAndDirectionVector(_ delta: Double, _ direction: Vector) -> Vector {
    assert(delta >= 0)
    return scaled(unitVector(direction), delta)
}
