import Foundation

/// Clips are transcribed in parallel but must land in the order they were spoken: a quick "okay, send"
/// can't overtake the longer sentence said just before it. Results wait here until every earlier clip is in.
public struct ClipSequencer<Result> {
    /// The next clip to hand out; everything below it has been handed out.
    public private(set) var next = 1
    private var finished: [Int: Result] = [:]

    public init() {}

    /// Records a finished clip and returns every result that's now in order, oldest first.
    public mutating func finish(_ id: Int, _ result: Result) -> [Result] {
        guard id >= next else { return [] }
        finished[id] = result
        var ready: [Result] = []
        while let result = finished.removeValue(forKey: next) {
            ready.append(result)
            next += 1
        }
        return ready
    }

    /// Whether this clip and everything before it has been handed out.
    public func hasHandedOut(through id: Int) -> Bool {
        id < next
    }

    public mutating func reset() {
        next = 1
        finished.removeAll()
    }
}
