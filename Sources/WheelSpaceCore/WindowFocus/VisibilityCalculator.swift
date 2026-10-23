import CoreGraphics
import Foundation

/// 사각형 합집합 차감으로 창의 노출 영역을 근사한다. 좌표는 전역 논리 포인트(오른쪽 +X, 아래쪽 +Y).
/// 반투명·비정형·둥근 모서리 창은 사각형으로 취급하는 근사 판정이다.
public enum VisibilityCalculator {
    /// 노출로 인정하는 최소 면적(pt²)과, 남은 조각 하나가 가져야 할 최소 폭·높이(pt). 설계값.
    public static let minimumArea: CGFloat = 1_024
    public static let minimumSide: CGFloat = 16
    /// 한 창의 남은 조각 수 상한. 넘으면 계산 예산 초과로 본다.
    public static let maximumFragments = 256

    /// frame에서 디스플레이 밖과 occluders(앞에 있는 창들)를 뺀 남은 사각형들. 예산 초과면 nil.
    public static func visibleRegions(of frame: CGRect, displays: [CGRect], occluders: [CGRect]) -> [CGRect]? {
        // 디스플레이 사이 빈 공간은 빠진다 (디스플레이끼리 겹치지 않는다고 가정)
        var pieces = displays.compactMap { display -> CGRect? in
            let piece = frame.intersection(display)
            return piece.isNull || piece.width <= 0 || piece.height <= 0 ? nil : piece
        }
        for occluder in occluders {
            pieces = pieces.flatMap { subtract($0, minus: occluder) }
            if pieces.count > maximumFragments { return nil }
            if pieces.isEmpty { break }
        }
        return pieces
    }

    /// 노출 판정: 면적 합 >= minimumArea 이고, 폭·높이 모두 minimumSide 이상인 조각이 하나 이상.
    public static func isExposed(_ regions: [CGRect]) -> Bool {
        let area = regions.reduce(0) { $0 + $1.width * $1.height }
        return area >= minimumArea && regions.contains { $0.width >= minimumSide && $0.height >= minimumSide }
    }

    /// rect에서 hole을 뺀 나머지를 최대 4개의 겹치지 않는 사각형으로.
    static func subtract(_ rect: CGRect, minus hole: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        let pieces = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
        ]
        return pieces.filter { $0.width > 0 && $0.height > 0 }
    }
}
