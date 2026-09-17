// RollingAverage.swift
// MousePilot Engine — rolling average over a circular buffer (ports RollingAverage.swift + CircularBuffer.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation

protocol Smoother {
    func smooth(value: Double) -> Double
    func reset()
}

struct CircularBuffer<T> {
    private var buffer: [T?]
    private(set) var filled = 0
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        buffer = [T?](repeating: nil, count: capacity)
    }

    mutating func reset() { filled = 0 }

    mutating func add(_ value: T) {
        buffer[head] = value
        head = movedIndex(head, by: 1)
        if filled < capacity { filled += 1 }
    }

    /// Oldest → newest.
    func content() -> [T] {
        if filled == 0 { return [] }
        var result: [T] = []
        result.reserveCapacity(filled)
        var i = movedIndex(head, by: -filled)
        while true {
            result.append(buffer[i]!)
            i = movedIndex(i, by: 1)
            if i == head { break }
        }
        return result
    }

    private func movedIndex(_ index: Int, by i: Int) -> Int {
        var r = (index + i) % capacity
        if r < 0 { r += capacity }
        return r
    }
}

final class RollingAverage: Smoother {

    private var circularBuffer: CircularBuffer<Double>
    private let initialValues: [Double]
    var filled: Int { circularBuffer.filled }

    convenience init(capacity: Int) {
        self.init(capacity: capacity, initialValues: [])
    }

    init(capacity: Int, initialValues: [Double]) {
        assert(initialValues.count <= capacity)
        circularBuffer = CircularBuffer(capacity: capacity)
        self.initialValues = initialValues
        applyInitialValues()
    }

    func reset() {
        circularBuffer.reset()
        applyInitialValues()
    }

    func smooth(value: Double) -> Double {
        circularBuffer.add(value)
        let stored = circularBuffer.content()
        var sum = 0.0
        for v in stored { sum += v }
        return sum / Double(stored.count)
    }

    private func applyInitialValues() {
        for v in initialValues { _ = smooth(value: v) }
    }
}
