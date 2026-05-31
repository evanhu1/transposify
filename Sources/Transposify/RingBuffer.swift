import Synchronization

/// Lock-free single-producer / single-consumer float ring buffer.
///
/// The Core Audio IOProc thread is the sole producer (`write`); the
/// AVAudioEngine render thread is the sole consumer (`read`). Indices are
/// monotonic counters into a power-of-two backing store, so wrap-around is a
/// cheap mask and the two threads never contend on a lock.
final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let writeIdx = Atomic<Int>(0)
    private let readIdx = Atomic<Int>(0)

    init(capacityFloats: Int) {
        var cap = 1
        while cap < max(capacityFloats, 2) { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit { storage.deallocate() }

    var availableToRead: Int {
        writeIdx.load(ordering: .acquiring) &- readIdx.load(ordering: .relaxed)
    }

    /// Producer side. Drops samples that don't fit rather than blocking.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = writeIdx.load(ordering: .relaxed)
        let r = readIdx.load(ordering: .acquiring)
        let free = capacity - (w &- r)
        let n = min(count, free)
        var i = 0
        while i < n {
            storage[(w &+ i) & mask] = src[i]
            i &+= 1
        }
        writeIdx.store(w &+ n, ordering: .releasing)
    }

    /// Consumer side. Returns the number of floats actually read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIdx.load(ordering: .relaxed)
        let w = writeIdx.load(ordering: .acquiring)
        let n = min(count, w &- r)
        var i = 0
        while i < n {
            dst[i] = storage[(r &+ i) & mask]
            i &+= 1
        }
        readIdx.store(r &+ n, ordering: .releasing)
        return n
    }
}
