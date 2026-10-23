import CoreGraphics
import Foundation

/// 포인터 이동을 실제 화면 영역 안으로 제한한다. 화면 사이 빈 공간을 건너뛰지 않고,
/// 맞닿은 경계에서만 다른 화면으로 넘어가며, 모서리에서는 가능한 축으로 미끄러진다.
/// 좌표: CG 전역(왼쪽 위 원점, +Y 아래). 디스플레이 사각형의 max 경계는 포함하지 않는다.
public enum DisplayGeometry {
    /// 화면 안쪽으로 남기는 여유 (max 경계 바로 안)
    public static let edgeInset: CGFloat = 1

    /// 축을 나눠(가로 먼저, 다음 세로) 이동한다. 각 축은 그 줄에서 끊김 없이 이어진 화면 구간 안으로 자른다.
    public static func move(from point: CGPoint, by delta: CGVector, displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty else { return point }
        let start = displays.contains { $0.contains(point) } ? point : nearestPoint(to: point, displays: displays)

        var x = start.x
        if let span = coveredSpan(alongXAt: start.y, containing: start.x, displays: displays) {
            x = min(max(start.x + delta.dx, span.lowerBound), span.upperBound)
        }
        var y = start.y
        if let span = coveredSpan(alongYAt: x, containing: start.y, displays: displays) {
            y = min(max(start.y + delta.dy, span.lowerBound), span.upperBound)
        }
        return CGPoint(x: x, y: y)
    }

    /// y 높이의 가로줄에서 x를 포함하고 끊김 없이 이어진 화면 구간 [min, max - edgeInset]. x가 화면 밖이면 nil.
    static func coveredSpan(alongXAt y: CGFloat, containing x: CGFloat, displays: [CGRect]) -> ClosedRange<CGFloat>? {
        let spans = displays.filter { $0.minY <= y && y < $0.maxY }.map { ($0.minX, $0.maxX) }
        return mergedSpan(spans, containing: x)
    }

    /// x 위치의 세로줄 기준 — coveredSpan(alongXAt:)의 축 교환판
    static func coveredSpan(alongYAt x: CGFloat, containing y: CGFloat, displays: [CGRect]) -> ClosedRange<CGFloat>? {
        let spans = displays.filter { $0.minX <= x && x < $0.maxX }.map { ($0.minY, $0.maxY) }
        return mergedSpan(spans, containing: y)
    }

    /// 반열린 구간 [a, b)들을 정렬해 맞닿거나 겹치는 것끼리 합치고, value를 포함하는 구간을 [a, b - inset]으로.
    private static func mergedSpan(_ spans: [(CGFloat, CGFloat)], containing value: CGFloat) -> ClosedRange<CGFloat>? {
        var merged: [(CGFloat, CGFloat)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        guard let hit = merged.first(where: { $0.0 <= value && value < $0.1 }) else { return nil }
        return hit.0...max(hit.0, hit.1 - edgeInset)
    }

    /// 화면 밖 점(모니터 분리 직후 등)을 가장 가까운 화면 안 점으로.
    public static func nearestPoint(to point: CGPoint, displays: [CGRect]) -> CGPoint {
        let clamped = displays.map { display in
            CGPoint(
                x: min(max(point.x, display.minX), display.maxX - edgeInset),
                y: min(max(point.y, display.minY), display.maxY - edgeInset)
            )
        }
        return clamped.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        } ?? point
    }
}
