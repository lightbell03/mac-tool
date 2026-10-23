import AppKit
import ApplicationServices
import WheelSpaceCore

/// 앱의 창 상태 조회 (읽기만). AX 호출이 있으므로 메인 스레드 밖에서 부른다.
/// 화면 목록(onscreen)만으로 "창 없음"을 정하지 않고, AX 창 목록 + 최소화 + CG 전체 목록(다른 데스크탑)을 함께 본다.
/// 창 제목은 읽지 않는다.
enum AppWindowInspector {
    /// AX 개별 호출 제한 (창 포커스 이동과 같은 값)
    static let messagingTimeout: Float = 0.3
    /// 다른 데스크탑 창으로 셀 최소 크기 — 툴팁·보조 창 같은 작은 창은 뺀다
    private static let minimumWindowSide: CGFloat = 100

    private struct AXWindow {
        let element: AXUIElement
        let isMinimized: Bool
        let isModal: Bool
        let isMain: Bool
    }

    /// isHidden은 메인 스레드에서 읽은 값(NSRunningApplication.isHidden)을 넘긴다
    static func inspect(pid: Int32, isHidden: Bool) -> AppWindowInspection {
        // 빈 배열은 실패가 아니라 "AX 창 0개", 호출 실패(권한·시간 초과)만 조회 실패
        guard AXIsProcessTrusted(), let windows = axWindows(pid: pid) else { return .failed }
        let normal = windows.filter { !$0.isMinimized }
        return .inspected(AppWindowState(
            isHidden: isHidden,
            normalWindowCount: normal.count,
            minimizedWindowCount: windows.count - normal.count,
            hasModal: windows.contains { $0.isModal },
            // 다른 데스크탑의 창은 AX 목록에 안 나올 수 있어, AX 창이 없을 때만 CG 전체 목록으로 확인한다
            otherSpaceWindowCount: windows.isEmpty ? otherSpaceWindowCount(pid: pid) : 0
        ))
    }

    /// 대상 창: 앞으로 가져올 일반 창 (모달 우선 → 주 창 → 최소화 안 된 첫 일반 창)
    static func windowToFocus(pid: Int32) -> AXUIElement? {
        guard let windows = axWindows(pid: pid) else { return nil }
        let normal = windows.filter { !$0.isMinimized }
        return (normal.first { $0.isModal } ?? normal.first { $0.isMain } ?? normal.first)?.element
    }

    /// 복원할 최소화 창 하나 (주 창 우선, 없으면 첫 최소화 창)
    static func minimizedWindow(pid: Int32) -> AXUIElement? {
        guard let windows = axWindows(pid: pid) else { return nil }
        let minimized = windows.filter(\.isMinimized)
        return (minimized.first { $0.isMain } ?? minimized.first)?.element
    }

    /// 앱의 일반 창 (역할 AXWindow, 서브역할 AXStandardWindow 또는 모달). 호출 실패면 nil.
    private static func axWindows(pid: Int32) -> [AXWindow]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // 창이 하나도 없는 앱은 noValue를 줄 수 있다 — 실패가 아니라 0개
        if error == .noValue { return [] }
        guard error == .success else { return nil }
        guard let elements = value as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let isModal = WindowInventory.isModalOrHasSheet(element)
            guard string(element, kAXRoleAttribute) == kAXWindowRole as String,
                  string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String || isModal else {
                return nil
            }
            return AXWindow(
                element: element,
                isMinimized: bool(element, kAXMinimizedAttribute) == true,
                isModal: isModal,
                isMain: bool(element, kAXMainAttribute) == true
            )
        }
    }

    /// 이 PID의 일반 레이어 창이 지금 화면에 하나라도 보이는지 (CG). AX 창 목록에 늦게 나타나는 앱(Teams 등)도
    /// 다시 열기 뒤 창이 열렸다고 판단하는 데 쓴다.
    static func hasOnscreenWindow(pid: Int32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            guard info[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
                return false
            }
            return bounds.width >= minimumWindowSide && bounds.height >= minimumWindowSide
        }
    }

    /// CG 전체 창 목록(.optionAll)에서 이 PID의 일반 레이어 창 중 지금 화면에 없는 것 수 — 다른 데스크탑의 창 또는 닫혀 숨긴 창
    private static func otherSpaceWindowCount(pid: Int32) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return 0
        }
        return list.filter { info in
            guard info[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool ?? false) == false,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
                return false
            }
            return bounds.width >= minimumWindowSide && bounds.height >= minimumWindowSide
        }.count
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
