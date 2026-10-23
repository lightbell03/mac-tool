import CoreGraphics

/// 마우스 포인터를 지정 위치로 옮긴다. 클릭·드래그는 하지 않는다.
/// 좌표는 CG 전역 좌표(왼쪽 위 원점, +Y 아래)로 창 목록·디스플레이와 같다.
enum PointerMover {
    static func move(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // 이동 직후 실제 마우스 입력이 잠깐 무시되는 현상 방지
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// 창이 속한 디스플레이 = 교차 면적이 가장 큰 디스플레이의 인덱스. 어느 디스플레이와도 안 겹치면 nil.
    static func displayIndex(of frame: CGRect, in displays: [CGRect]) -> Int? {
        let areas = displays.map { display -> CGFloat in
            let overlap = frame.intersection(display)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    /// 포인터를 둘 위치: 창 가운데가 다른 창에 가려져 있으면 보이는 조각 중 가장 큰 것의 가운데.
    static func target(in frame: CGRect, exposed regions: [CGRect]) -> CGPoint {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard !regions.isEmpty, !regions.contains(where: { $0.contains(center) }) else { return center }
        let largest = regions.max { $0.width * $0.height < $1.width * $1.height }!
        return CGPoint(x: largest.midX, y: largest.midY)
    }
}
