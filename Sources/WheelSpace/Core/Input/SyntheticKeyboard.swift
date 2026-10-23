import CoreGraphics
import Foundation

/// 합성 키 입력 공통 처리. 실제 키보드 보조키 상태와 분리(privateState)하고 자체 표시를 붙인다.
/// DesktopSwitcher(⌃←/⌃→)와 SelectionReplacer(⌘C/⌘V)가 함께 쓴다.
enum SyntheticKeyboard {
    enum PostError: Error {
        case eventSourceUnavailable
        case eventCreationFailed
    }

    /// 자체 합성 이벤트 식별값 (kCGEventSourceUserData). 이벤트 탭 재처리 방지용.
    static let marker: Int64 = 0x5753_5043 // "WSPC"

    /// key-down·key-up 한 쌍을 만든 뒤에만 보낸다. 중간 실패로 key-up이 빠지는 경로가 없다.
    static func press(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        // privateState: 사용자가 실제로 누르고 있는 보조키가 합성 이벤트에 섞이지 않게 한다.
        guard let source = CGEventSource(stateID: .privateState) else {
            throw PostError.eventSourceUnavailable
        }
        guard let keyDown = makeKeyEvent(source: source, keyCode: keyCode, keyDown: true, flags: flags),
              let keyUp = makeKeyEvent(source: source, keyCode: keyCode, keyDown: false, flags: flags) else {
            throw PostError.eventCreationFailed
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    private static func makeKeyEvent(source: CGEventSource, keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return nil
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
