import CoreGraphics
import Foundation
import WheelSpaceCore

/// Control + 왼쪽/오른쪽 화살표를 합성해 macOS의 인접 Space 이동 단축키를 보낸다.
/// 전송 성공은 "이벤트를 보냈다"까지만 의미하며 실제 데스크탑 이동 완료를 뜻하지 않는다.
final class DesktopSwitcher {
    private static let leftArrowKeyCode: CGKeyCode = 0x7B
    private static let rightArrowKeyCode: CGKeyCode = 0x7C
    /// 실제 키보드의 Control+화살표와 같은 플래그. 화살표 키는 Fn·NumericPad 비트를 함께 가진다.
    private static let shortcutFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    /// 전송 직렬 큐. 대기 요청은 최대 1건만 허용한다.
    private let queue = DispatchQueue(label: "WheelSpace.DesktopSwitcher")
    private let lock = NSLock()
    private var isSending = false

    /// 이벤트 탭 스레드에서 호출. 이미 전송 중이면 버리고 false를 돌려준다.
    @discardableResult
    func requestSwitch(_ direction: SwitchDirection) -> Bool {
        lock.lock()
        if isSending {
            lock.unlock()
            return false
        }
        isSending = true
        lock.unlock()

        queue.async { [self] in
            try? send(direction)
            lock.lock()
            isSending = false
            lock.unlock()
        }
        return true
    }

    /// 설정 창 테스트 버튼용 동기 전송.
    func send(_ direction: SwitchDirection) throws {
        let keyCode = direction == .left ? Self.leftArrowKeyCode : Self.rightArrowKeyCode
        try SyntheticKeyboard.press(keyCode: keyCode, flags: Self.shortcutFlags)
    }
}
