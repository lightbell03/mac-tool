import CoreGraphics
import Foundation

/// 방향 선택에 쓰는 후보 창. 좌표만 가진 순수 값.
public struct FocusCandidate: Equatable, Sendable {
    /// 세션 내 안정적인 식별자 (동률 마지막 기준)
    public var id: Int
    /// 창 전체 사각형 중 디스플레이 안에 있는 부분 (중심 계산용)
    public var frame: CGRect
    /// 앞에서 뒤 순서 (0 = 가장 앞)
    public var zIndex: Int

    public init(id: Int, frame: CGRect, zIndex: Int) {
        self.id = id
        self.frame = frame
        self.zIndex = zIndex
    }
}

/// 현재 창 기준으로 방향에 있는 가장 적절한 후보를 고른다. 화면 끝에서 순환하지 않는다.
public enum DirectionalSelector {
    /// 방향 판정 허용 오차(pt). 중심 차이가 이보다 커야 그 방향으로 본다.
    public static let directionTolerance: CGFloat = 1

    public static func select(from current: CGRect, candidates: [FocusCandidate], direction: FocusDirection) -> FocusCandidate? {
        // 네 방향 모두 "오른쪽"으로 회전해 같은 규칙을 쓴다
        let base = rotate(current, for: direction)
        let ahead = candidates
            .map { (candidate: $0, rect: rotate($0.frame, for: direction)) }
            .filter { $0.rect.midX - base.midX > directionTolerance }
        guard !ahead.isEmpty else { return nil }

        let aligned = ahead.filter { min(base.maxY, $0.rect.maxY) - max(base.minY, $0.rect.minY) > 0 }

        func tieBreak(_ entry: (candidate: FocusCandidate, rect: CGRect)) -> [Double] {
            [
                Double(abs(entry.rect.midX - base.midX)),
                Double(abs(entry.rect.midY - base.midY)),
                Double(entry.candidate.zIndex),
                Double(entry.candidate.id),
            ]
        }

        let keyed: [(FocusCandidate, [Double])]
        if !aligned.isEmpty {
            keyed = aligned.map { entry in
                let gap = max(0, entry.rect.minX - base.maxX)
                let orthogonalGap = intervalGap(base.minY, base.maxY, entry.rect.minY, entry.rect.maxY)
                return (entry.candidate, [Double(gap), Double(orthogonalGap),
                                          Double(abs(entry.rect.midY - base.midY)),
                                          Double(abs(entry.rect.midX - base.midX))] + tieBreak(entry))
            }
        } else {
            keyed = ahead.map { entry in
                let dx = intervalGap(base.minX, base.maxX, entry.rect.minX, entry.rect.maxX)
                let dy = intervalGap(base.minY, base.maxY, entry.rect.minY, entry.rect.maxY)
                return (entry.candidate, [Double(dx * dx + dy * dy)] + tieBreak(entry))
            }
        }
        return keyed.min { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// direction을 "오른쪽"으로 바꾸는 좌표 변환. left: x 반전, up: (x, y) → (-y, x) 등 — 길이 관계를 보존한다.
    static func rotate(_ rect: CGRect, for direction: FocusDirection) -> CGRect {
        switch direction {
        case .right:
            return rect
        case .left:
            return CGRect(x: -rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        case .down:
            return CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        case .up:
            return CGRect(x: -rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }

    /// 두 구간 [a0, a1], [b0, b1] 사이 거리 (겹치면 0)
    static func intervalGap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, max(a0, b0) - min(a1, b1))
    }
}
