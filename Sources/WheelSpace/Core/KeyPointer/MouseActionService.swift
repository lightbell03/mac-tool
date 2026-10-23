import AppKit
import CoreGraphics
import Foundation
import WheelSpaceCore

/// 합성 마우스 이벤트 전송. 모든 이벤트는 privateState 소스로 만들고 보조키 플래그를 비워,
/// 사용자가 누르고 있는 ⌃⌘ 등이 클릭에 섞여 보조키 클릭이 되지 않게 한다.
/// 자체 표시(SyntheticKeyboard.marker)를 붙여 이벤트 탭이 다시 처리하지 않게 한다.
enum MouseActionService {
    enum PostError: Error {
        case eventSourceUnavailable
        case eventCreationFailed
    }

    /// 현재 포인터 위치 (CG 전역 좌표)
    static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// 실제(물리) 왼쪽 버튼이 눌려 있는지 — 눌려 있으면 앱 드래그를 시작하지 않는다
    static var isPhysicalLeftButtonDown: Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    /// 포인터 이동. 드래그 중이면 leftMouseDragged, 아니면 mouseMoved 이벤트를 위치와 함께 보낸다(호버 갱신).
    static func movePointer(to point: CGPoint, dragging: Bool) {
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        mouseEvent(type, at: point, button: .left)?.post(tap: .cghidEventTap)
    }

    /// down/up 한 쌍. 둘 다 만든 뒤에만 보낸다.
    /// 더블클릭 간격 안에 같은 자리를 다시 누르면 클릭 횟수를 올려 보낸다 (Enter 두 번 = 더블클릭).
    static func click(_ button: PointerButton, at point: CGPoint) throws {
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)
        guard let down = mouseEvent(downType, at: point, button: cgButton),
              let up = mouseEvent(upType, at: point, button: cgButton) else {
            throw PostError.eventCreationFailed
        }
        let clickState = nextClickState(cgButton, at: point)
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 더블클릭: clickState 1 쌍 → clickState 2 쌍. 간격은 OS 더블클릭 시간보다 충분히 짧게.
    static func doubleClick(at point: CGPoint) throws {
        let types: [(CGEventType, Int64)] = [(.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)]
        let events = types.compactMap { type, clickState -> CGEvent? in
            let event = mouseEvent(type, at: point, button: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            return event
        }
        guard events.count == types.count else { throw PostError.eventCreationFailed }
        let gap = useconds_t(min(NSEvent.doubleClickInterval / 4, 0.03) * 1_000_000)
        for (index, event) in events.enumerated() {
            event.post(tap: .cghidEventTap)
            if index == 1 { usleep(gap) }
        }
        // 바로 이어 Enter를 누르면 세 번 클릭(줄 선택 등)으로 이어지게
        lastClick = LastClick(button: .left, location: point, time: ProcessInfo.processInfo.systemUptime, count: 2)
    }

    /// 드래그 시작·종료용 왼쪽 버튼 down / up. down은 클릭 횟수를 매기고(클릭 직후 드래그 = 더블클릭 드래그),
    /// up은 그 down과 같은 횟수로 보낸다.
    static func leftButton(down: Bool, at point: CGPoint) throws {
        guard let event = mouseEvent(down ? .leftMouseDown : .leftMouseUp, at: point, button: .left) else {
            throw PostError.eventCreationFailed
        }
        let clickState = down ? nextClickState(.left, at: point) : (lastClick?.count ?? 1)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    private struct LastClick {
        var button: CGMouseButton
        var location: CGPoint
        var time: TimeInterval
        var count: Int64
    }

    /// 직전 클릭 (탭 스레드에서만 읽고 쓴다)
    private static var lastClick: LastClick?
    /// 같은 자리로 보는 거리. 실제 마우스의 더블클릭 허용 범위와 비슷하게.
    private static let clickSlop: CGFloat = 4

    /// 합성 이벤트는 macOS가 클릭 횟수를 매겨 주지 않아 직접 센다: 같은 버튼으로 더블클릭 간격 안에 같은 자리면 +1
    private static func nextClickState(_ button: CGMouseButton, at point: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if let last = lastClick, last.button == button, now - last.time <= NSEvent.doubleClickInterval,
           hypot(last.location.x - point.x, last.location.y - point.y) <= clickSlop {
            count = last.count + 1
        }
        lastClick = LastClick(button: button, location: point, time: now, count: count)
        return count
    }

    /// 픽셀 단위 연속 스크롤 (dx = 가로 wheel2, dy = 세로 wheel1). 실제 휠 이벤트는 건드리지 않는다.
    static func scroll(dx: Int32, dy: Int32) {
        guard dx != 0 || dy != 0,
              let source = makeSource(),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeyboard.marker)
        event.post(tap: .cghidEventTap)
    }

    /// 합성 이벤트를 보낸 직후 macOS가 실제 입력을 잠깐(기본 0.25초) 무시하는 동작을 끈다.
    /// 켜 두면 이동 중 실제 키보드·마우스 입력이 끊겨 보인다.
    private static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private static func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) -> CGEvent? {
        guard let source = makeSource(),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return nil
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeyboard.marker)
        return event
    }
}
