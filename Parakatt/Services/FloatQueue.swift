import Foundation

/// FIFO storage with an advancing read index. The owner provides synchronization.
struct FloatQueue: RandomAccessCollection {
    typealias Index = Int
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(index: Int) -> Float { storage[head + index] }
    mutating func removeFirst(_ amount: Int) { head += Swift.min(Swift.max(amount, 0), count); compact() }
    private mutating func compact() {
        if head == storage.count { removeAll() }
        else if head > 16_000 && head * 2 >= storage.count { storage = Array(storage[head...]); head = 0 }
    }
    private var storage: [Float] = []
    private var head = 0
    var count: Int { storage.count - head }
    mutating func append(contentsOf samples: [Float]) { storage.append(contentsOf: samples) }
    mutating func take(_ requested: Int) -> [Float] {
        let amount = Swift.min(requested, count)
        let result = Array(storage[head..<(head + amount)])
        head += amount
        if head == storage.count { removeAll() }
        else if head > 16_000 && head * 2 >= storage.count {
            storage = Array(storage[head...])
            head = 0
        }
        return result
    }
    mutating func removeAll() { storage.removeAll(keepingCapacity: true); head = 0 }
}
