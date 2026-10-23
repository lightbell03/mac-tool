import AppKit
import ApplicationServices

/// 대상 창을 앞으로 가져오고 실제 키보드 포커스가 옮겨졌는지 확인한다.
/// 창 위치·크기를 바꾸지 않고, 포인터 이동·클릭을 하지 않는다.
enum WindowActivator {
    /// 포커스 확인 제한 (설계값)
    static let verificationTimeout: TimeInterval = 0.3
    /// 확인 간격 5ms — 20ms면 확인이 그만큼 늦어 연속 입력이 밀렸다
    private static let pollInterval: UInt64 = 5_000_000

    enum Failure: Error, Equatable {
        /// 대상 창이 실행 직전에 사라짐
        case targetGone
        /// 앱 활성화 또는 raise 실패
        case activationFailed
        /// 제한 시간 안에 포커스가 대상으로 바뀌지 않음
        case notVerified
    }

    /// 앞으로 가져오기만 (확인 없이). 연속 입력에서 다음 이동을 바로 계산하려고 활성화와 확인을 나눈다. 메인 스레드.
    @MainActor
    static func activate(_ window: AXUIElement, pid: Int32) -> Result<Void, Failure> {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .failure(.targetGone)
        }

        // 백그라운드 앱의 activate()는 최근 macOS에서 거절될 수 있어, AX로 앱을 앞으로 보내는 것을 먼저 시도한다
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, WindowInventory.axMessagingTimeout)
        let frontmost = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let activated = app.activate(options: [])
        guard frontmost == .success || main == .success || raise == .success || activated else {
            return .failure(.activationFailed)
        }
        return .success(())
    }

    /// 활성화 뒤 실제 포커스가 대상으로 옮겨졌는지 verificationTimeout 동안 확인 (중간에 한 번 더 raise)
    @MainActor
    static func verify(_ window: AXUIElement, pid: Int32) async -> Result<Void, Failure> {
        let deadline = ProcessInfo.processInfo.systemUptime + verificationTimeout
        var raisedAgain = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .success(let focused) = WindowInventory.focusedWindow(pid: pid), CFEqual(focused, window),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return .success(())
            }
            // 앱 활성화가 그 앱의 다른 창을 앞으로 가져온 경우를 위해 한 번 더 올린다
            if !raisedAgain, ProcessInfo.processInfo.systemUptime > deadline - verificationTimeout / 2 {
                raisedAgain = true
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return .failure(.notVerified)
    }

    /// activate + verify (창 목록 전환기·실행 중인 앱 선택이 그대로 쓴다)
    @MainActor
    static func focus(_ window: AXUIElement, pid: Int32) async -> Result<Void, Failure> {
        if case .failure(let failure) = activate(window, pid: pid) { return .failure(failure) }
        return await verify(window, pid: pid)
    }
}
