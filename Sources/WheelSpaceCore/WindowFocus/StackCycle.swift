import CoreGraphics
import Foundation

/// 같은 모니터에 겹친 창 넘기기 방향
public enum StackDirection: String, CaseIterable, Codable, Sendable {
    /// 뒤로: 지금 창 밑에 깔린 다음 창을 앞으로 (지금 창은 한 칸 뒤로)
    case next
    /// 앞으로: 넘기던 순서에서 직전 창으로 되돌리기
    case previous
}

/// 순서를 정하는 데 쓰는 후보 창. 좌표만 가진 순수 값.
public struct StackCandidate: Equatable, Sendable {
    public var id: Int
    public var frame: CGRect
    /// 앞에서 뒤 순서 (0 = 가장 앞)
    public var zIndex: Int

    public init(id: Int, frame: CGRect, zIndex: Int) {
        self.id = id
        self.frame = frame
        self.zIndex = zIndex
    }
}

/// 넘기는 순서: 지금 창과 실제로 겹친 창(앞에서 뒤), 그다음 같은 모니터의 겹치지 않은 창(앞에서 뒤).
/// 같은 모니터 판정은 호출하는 쪽이 끝낸 후보만 받는다 (완전히 가려진 창 포함).
public enum StackOrder {
    /// 반환: 후보 id 순서 (지금 창은 넣지 않는다 — 세션이 0번 자리에 둔다)
    public static func order(current: CGRect, candidates: [StackCandidate]) -> [Int] {
        let sorted = candidates.sorted { ($0.zIndex, $0.id) < ($1.zIndex, $1.id) }
        let overlapping = sorted.filter {
            let overlap = $0.frame.intersection(current)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        let overlappingIDs = Set(overlapping.map(\.id))
        return overlapping.map(\.id) + sorted.filter { !overlappingIDs.contains($0.id) }.map(\.id)
    }
}

/// 겹친 창 넘기기 세션. 첫 입력 때 순서를 고정해 두고, 이어진 입력(timeout 이내)은 고정된 순서에서 다음 칸으로 간다.
/// 창을 앞으로 가져오면 겹침 순서가 바뀌므로, 매번 새로 줄을 세우면 맨 앞 두 창만 오가게 되는 것을 막는다.
/// 0번 자리는 시작할 때의 지금 창이다. 시각은 외부에서 주입한다.
public struct StackCycleSession: Equatable, Sendable {
    public static let timeout: TimeInterval = 1.5

    /// 순환할 자리 수 (지금 창 포함)
    public let count: Int
    /// 지금 앞에 있는 자리
    public private(set) var index = 0
    private var lastInputAt: TimeInterval

    /// count: 지금 창 + 후보 수. 후보가 없으면(1 이하) 넘길 창이 없다.
    public init?(count: Int, startedAt: TimeInterval) {
        guard count >= 2 else { return nil }
        self.count = count
        self.lastInputAt = startedAt
    }

    /// 마지막 입력 후 timeout이 지나지 않았는지
    public func isActive(now: TimeInterval) -> Bool {
        now - lastInputAt <= Self.timeout
    }

    /// 한 칸 이동하고 새 자리를 돌려준다. 끝에서 처음으로(앞으로면 처음에서 끝으로) 순환한다.
    public mutating func step(_ direction: StackDirection, now: TimeInterval) -> Int {
        let delta = direction == .next ? 1 : -1
        index = ((index + delta) % count + count) % count
        lastInputAt = now
        return index
    }
}
