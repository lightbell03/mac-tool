import CoreGraphics
import Foundation

/// 눌린 방향키 → 속도 벡터, 경과 시간 → 이동량. 누른 시간에 따른 가속 배율.
/// 좌표계: 오른쪽 +X, 아래쪽 +Y.
public enum PointerMotion {
    /// 한 프레임 경과 시간 상한 — 지연된 틱에서 포인터가 튀지 않게
    public static let maxFrameInterval: TimeInterval = 0.05

    /// 반대 방향은 상쇄, 대각선은 정규화해 수평·수직보다 빨라지지 않게 한다. 방향이 없으면 .zero.
    public static func velocity(arrows: Set<ArrowKey>, speed: Double, multiplier: Double) -> CGVector {
        let dx = (arrows.contains(.right) ? 1.0 : 0) - (arrows.contains(.left) ? 1.0 : 0)
        let dy = (arrows.contains(.down) ? 1.0 : 0) - (arrows.contains(.up) ? 1.0 : 0)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return .zero }
        let scale = speed * multiplier / length
        return CGVector(dx: dx * scale, dy: dy * scale)
    }

    /// 누른 시간에 따른 속도 배율: startRatio에서 시작해 accelerationTime에 1이 된다.
    /// 처음엔 천천히 오르고 끝에서 부드럽게 멈추는 곡선(smoothstep). accelerationTime이 0 이하면 항상 1.
    public static func accelerationFactor(heldFor: TimeInterval, accelerationTime: TimeInterval, startRatio: Double) -> Double {
        guard accelerationTime > 0 else { return 1 }
        let t = min(max(heldFor / accelerationTime, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return startRatio + (1 - startRatio) * eased
    }

    /// 속도 × min(경과 시간, maxFrameInterval)
    public static func displacement(velocity: CGVector, elapsed: TimeInterval) -> CGVector {
        let dt = max(0, min(elapsed, maxFrameInterval))
        return CGVector(dx: velocity.dx * dt, dy: velocity.dy * dt)
    }

    /// 키보드 스크롤 변화량 (픽셀). 위쪽 화살표 = 문서의 위쪽을 보는 방향(휠을 위로 굴린 것과 같음),
    /// reverse면 부호 반전. 실제 앱에서 부호를 검증한다.
    public static func scrollDelta(arrows: Set<ArrowKey>, speed: Double, multiplier: Double, reverse: Bool, elapsed: TimeInterval) -> CGVector {
        let v = velocity(arrows: arrows, speed: speed, multiplier: multiplier)
        // 스크롤 이벤트 부호: 위 화살표(-dy) → +wheel1, 왼쪽 화살표(-dx) → +wheel2. 반환값 dx = wheel2, dy = wheel1
        let sign: CGFloat = reverse ? 1 : -1
        return displacement(velocity: CGVector(dx: v.dx * sign, dy: v.dy * sign), elapsed: elapsed)
    }
}
