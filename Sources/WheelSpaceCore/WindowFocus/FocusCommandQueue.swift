import Foundation

/// 이동 중 들어온 명령을 순서대로 최대 4개, 각 500ms까지 보관한다. 시각은 외부에서 주입한다.
public struct FocusCommandQueue {
    public static let capacity = 4
    public static let lifetime: TimeInterval = 0.5

    private var items: [(direction: FocusDirection, enqueuedAt: TimeInterval)] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// 가득 차면 새 명령을 버리고 false.
    @discardableResult
    public mutating func enqueue(_ direction: FocusDirection, at time: TimeInterval) -> Bool {
        expire(now: time)
        guard items.count < Self.capacity else { return false }
        items.append((direction, time))
        return true
    }

    /// 만료되지 않은 가장 오래된 명령을 꺼낸다.
    public mutating func next(now: TimeInterval) -> FocusDirection? {
        expire(now: now)
        return items.isEmpty ? nil : items.removeFirst().direction
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    private mutating func expire(now: TimeInterval) {
        items.removeAll { now - $0.enqueuedAt > Self.lifetime }
    }
}
