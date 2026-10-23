import CoreGraphics

/// 창을 다른 모니터로 보내기: 보낼 모니터 고르기와 옮긴 뒤 창 위치·크기 계산 (순수 계산).
/// 좌표는 CG 전역 좌표(왼쪽 위 원점, +Y 아래)이고, 모니터 영역은 메뉴 막대·Dock을 뺀 보이는 영역이다.
public enum WindowMovePlanner {
    /// source 모니터에서 direction 쪽에 있는 모니터. 그 방향에 모니터가 없으면 nil.
    /// 그 방향으로 가운데가 넘어간 모니터 중, 옆으로(수직 방향) 겹치는 모니터를 먼저, 그다음 가까운 모니터를 고른다.
    public static func targetDisplay(from source: Int, direction: FocusDirection, in displays: [CGRect]) -> Int? {
        guard displays.indices.contains(source) else { return nil }
        let origin = displays[source]
        let candidates = displays.indices.filter { index in
            guard index != source else { return false }
            let display = displays[index]
            switch direction {
            case .left: return display.midX < origin.minX + 1 || display.maxX <= origin.midX
            case .right: return display.midX > origin.maxX - 1 || display.minX >= origin.midX
            case .up: return display.midY < origin.minY + 1 || display.maxY <= origin.midY
            case .down: return display.midY > origin.maxY - 1 || display.minY >= origin.midY
            }
        }
        return candidates.min { score(displays[$0], from: origin, direction) < score(displays[$1], from: origin, direction) }
    }

    /// 정렬 기준: (수직 방향으로 안 겹침, 진행 방향 간격, 수직 방향 가운데 거리)
    private static func score(_ display: CGRect, from origin: CGRect, _ direction: FocusDirection) -> (Int, CGFloat, CGFloat) {
        let horizontal = direction == .left || direction == .right
        let overlap = horizontal
            ? min(display.maxY, origin.maxY) - max(display.minY, origin.minY)
            : min(display.maxX, origin.maxX) - max(display.minX, origin.minX)
        let gap: CGFloat
        switch direction {
        case .left: gap = max(0, origin.minX - display.maxX)
        case .right: gap = max(0, display.minX - origin.maxX)
        case .up: gap = max(0, origin.minY - display.maxY)
        case .down: gap = max(0, display.minY - origin.maxY)
        }
        let sideDistance = horizontal ? abs(display.midY - origin.midY) : abs(display.midX - origin.midX)
        return (overlap > 0 ? 0 : 1, gap, sideDistance)
    }

    /// 화면 가장자리에 붙은 것으로 보는 거리 (창 그림자·반올림 오차)
    private static let edgeTolerance: CGFloat = 8
    /// 정렬 배치로 보는 화면 비율 (절반·3분의 1·3분의 2·꽉 채움)과 허용 오차
    private static let tiledFractions: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]
    private static let fractionTolerance: CGFloat = 0.03

    /// 새 모니터로 옮긴 창 영역. 축(가로·세로)마다 따로 정한다:
    /// - 정렬 배치된 축(가장자리에 붙어 있고 길이가 화면의 절반·3분의 1·3분의 2·전부)은 원래 모니터에서의
    ///   위치·비율 그대로 늘리거나 줄인다
    ///   (왼쪽 절반에 있던 창은 새 모니터의 왼쪽 절반으로)
    /// - 떠 있던 축은 크기를 그대로 두고, 창 가운데를 같은 비율 자리로 옮긴다 (모니터 모양이 달라도 찌그러지지 않게)
    /// 어느 쪽이든 새 모니터를 벗어나지 않게 맞춘다.
    public static func movedFrame(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let (x, width) = mapAxis(
            min: frame.minX, length: frame.width, sourceMin: source.minX, sourceLength: source.width,
            targetMin: target.minX, targetLength: target.width
        )
        let (y, height) = mapAxis(
            min: frame.minY, length: frame.height, sourceMin: source.minY, sourceLength: source.height,
            targetMin: target.minY, targetLength: target.height
        )
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(.down), height: height.rounded(.down))
    }

    private static func mapAxis(
        min frameMin: CGFloat, length: CGFloat, sourceMin: CGFloat, sourceLength: CGFloat,
        targetMin: CGFloat, targetLength: CGFloat
    ) -> (origin: CGFloat, length: CGFloat) {
        let scale = targetLength / sourceLength
        let frameMax = frameMin + length
        let sourceMax = sourceMin + sourceLength
        // 가장자리에 우연히 닿았을 뿐인 창(외장 모니터 왼쪽 끝에 둔 보통 창 등)은 크기를 그대로 둔다
        let touchesEdge = abs(frameMin - sourceMin) <= edgeTolerance || abs(frameMax - sourceMax) <= edgeTolerance
        let fraction = length / sourceLength
        let snapped = touchesEdge && tiledFractions.contains { abs(fraction - $0) <= fractionTolerance }
        var newLength: CGFloat
        var origin: CGFloat
        if snapped {
            newLength = length * scale
            origin = targetMin + (frameMin - sourceMin) * scale
        } else {
            newLength = length
            let center = targetMin + (frameMin + length / 2 - sourceMin) * scale
            origin = center - newLength / 2
        }
        newLength = Swift.max(1, Swift.min(newLength, targetLength))
        origin = Swift.min(Swift.max(origin, targetMin), targetMin + targetLength - newLength)
        return (origin, newLength)
    }
}
