import AppKit
import ApplicationServices
import WheelSpaceCore

/// 지금 포커스된 창을 다른 모니터로 보낸다: 방향의 모니터를 고르고 WindowMovePlanner로 자리·크기를 정한다
/// (가장자리에 붙은 창은 비율대로, 떠 있는 창은 크기 그대로).
/// 창 제목은 읽지 않는다.
enum WindowMover {
    enum Outcome: Equatable {
        /// before: 옮기기 전 창, planned: 계산한 자리, result: 옮긴 뒤 실제 창
        case moved(before: CGRect, planned: CGRect, result: CGRect)
        case noFocusedWindow
        case fullScreen
        case noDisplay
        /// 앱이 위치 바꾸기를 거부함
        case notMovable
    }

    /// 메인 스레드에서 부른다 (모니터 영역은 메인 스레드에서 읽고, AX 호출은 뒤에서 한다)
    @MainActor
    static func move(direction: FocusDirection, frontmostPID: pid_t) async -> Outcome {
        let screens = DisplayService.screenAreas()
        return await Task.detached(priority: .userInitiated) {
            moveFocusedWindow(direction: direction, pid: frontmostPID, screens: screens)
        }.value
    }

    private static func moveFocusedWindow(
        direction: FocusDirection, pid: pid_t, screens: [(frame: CGRect, visible: CGRect)]
    ) -> Outcome {
        guard case .success(let window) = WindowInventory.focusedWindow(pid: pid),
              let frame = WindowInventory.frame(of: window) else { return .noFocusedWindow }
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true {
            return .fullScreen
        }
        guard let source = PointerMover.displayIndex(of: frame, in: screens.map(\.frame)),
              let target = WindowMovePlanner.targetDisplay(from: source, direction: direction, in: screens.map(\.frame)) else {
            return .noDisplay
        }
        let moved = WindowMovePlanner.movedFrame(frame, from: screens[source].visible, to: screens[target].visible)

        // AXEnhancedUserInterface가 켜진 앱(Chrome 등 — 입력란 확인 때 켠다)은 창 크기·위치를 바꾸면 애니메이션이 끼어
        // 크기가 어긋난다. 옮기는 동안만 끄고 되돌린다.
        let app = AXUIElementCreateApplication(pid)
        var enhanced: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
            && (enhanced as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }

        var resizable: DarwinBoolean = false
        let canResize = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success
            && resizable.boolValue
        // 크기 → 위치 → 크기: macOS는 창 크기를 지금 있는 모니터 안으로 제한한다. 작은 모니터에서 큰 모니터로 갈 때
        // 옮기기 전에 키우면 잘리므로, 옮긴 뒤 한 번 더 맞춘다 (줄일 때는 먼저 줄여야 새 모니터 밖으로 삐져나가지 않는다)
        if canResize { setSize(window, moved.size) }
        guard setPosition(window, moved.origin) else { return .notMovable }
        if canResize { setSize(window, moved.size) }
        // Chrome 등은 위치 변경을 늦게 반영해, 크기를 바꿀 때 아직 원래 모니터에 있어 잘릴 수 있다 — 잠깐 뒤 한 번 더
        for _ in 0..<Self.settleRetries {
            guard canResize, let current = WindowInventory.frame(of: window), !Self.matches(current, moved) else { break }
            Thread.sleep(forTimeInterval: Self.settleDelay)
            setPosition(window, moved.origin)
            setSize(window, moved.size)
        }
        return .moved(before: frame, planned: moved, result: WindowInventory.frame(of: window) ?? moved)
    }

    /// 앱이 위치를 늦게 반영할 때 다시 맞추는 횟수와 간격
    private static let settleRetries = 3
    private static let settleDelay: TimeInterval = 0.05

    /// 계획한 자리·크기와 같은지 (반올림 오차 허용)
    private static func matches(_ frame: CGRect, _ planned: CGRect) -> Bool {
        abs(frame.minX - planned.minX) <= 2 && abs(frame.minY - planned.minY) <= 2
            && abs(frame.width - planned.width) <= 2 && abs(frame.height - planned.height) <= 2
    }

    @discardableResult
    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
}
