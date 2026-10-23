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

extension DisplayService {
    /// 모니터마다 전체 영역과 메뉴 막대·Dock을 뺀 보이는 영역 (둘 다 CG 전역 좌표). 메인 스레드에서 부른다 (NSScreen).
    @MainActor
    static func screenAreas() -> [(frame: CGRect, visible: CGRect)] {
        // NSScreen은 왼쪽 아래 원점(+Y 위)이라 주 모니터 높이를 기준으로 뒤집는다
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        func flipped(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { (flipped($0.frame), flipped($0.visibleFrame)) }
    }
}
