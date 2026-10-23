import AppKit
import CoreGraphics

/// 연결된 디스플레이 영역. CGDisplayBounds는 이미 전역 논리 포인트·왼쪽 위 원점(+Y 아래)이라
/// CG 창 목록·AX 좌표와 같은 좌표계다. 음수 좌표(주 모니터 왼쪽·위)도 그대로 쓴다.
enum DisplayService {
    static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            // 미러링하는 쪽 디스플레이는 원본과 같은 영역이라 제외한다
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { CGDisplayBounds($0) }
    }
}
