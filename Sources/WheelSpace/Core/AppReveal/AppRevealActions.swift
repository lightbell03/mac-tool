import AppKit
import ApplicationServices
import WheelSpaceCore

/// 창을 보이게 하는 동작들: 숨김 해제, 최소화 복원, 기존 창 활성화, 다시 열기 요청.
/// 창을 닫거나 크기·위치를 바꾸지 않는다. ⌘N 같은 키를 합성하거나 메뉴를 임의로 실행하지 않는다.
@MainActor
enum AppRevealActions {
    /// 숨김 해제 (NSRunningApplication.unhide)
    static func unhide(_ app: NSRunningApplication) -> Bool {
        app.unhide()
    }

    /// 최소화된 창 하나 복원 후 그 창으로 포커스 (WindowActivator로 확인)
    static func restoreMinimized(_ window: AXUIElement, pid: Int32) async -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return await focus(window, pid: pid)
    }

    /// 기존 창을 앞으로 가져와 포커스 확인 (창 포커스 이동과 같은 WindowActivator)
    static func focus(_ window: AXUIElement, pid: Int32) async -> Bool {
        if case .success = await WindowActivator.focus(window, pid: pid) { return true }
        return false
    }

    /// 앱만 활성화 (창을 보여 줄 수 없을 때)
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [])
    }

    /// 다시 열기 요청: 실행 중인 앱의 번들로 NSWorkspace.openApplication — Dock 아이콘 클릭과 같은 "다시 열기"가 간다.
    /// 기본 창을 열지는 앱이 정한다. 요청 직전에 살아 있는지 다시 확인하고, 종료됐으면 보내지 않는다(자동 재실행 방지).
    /// 한계: 확인 직후 앱이 종료되면 이 요청이 앱을 새로 실행할 수 있다 (공개 API로는 막을 수 없음, 문서화).
    static func reopen(_ app: NSRunningApplication) async -> Bool {
        guard !app.isTerminated, let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
