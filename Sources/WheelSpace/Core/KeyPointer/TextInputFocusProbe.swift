import AppKit
import ApplicationServices
import WheelSpaceCore

/// 지금 키보드 포커스가 글자 입력란인지 손쉬운 사용(AX) API로 확인한다.
/// AX 호출은 대상 앱이 응답하지 않으면 오래 걸릴 수 있어 전용 큐에서 하고, 결과만 메인 스레드로 돌려준다.
enum TextInputFocusProbe {
    private static let queue = DispatchQueue(label: "WheelSpace.TextInputFocusProbe", qos: .userInitiated)
    /// 대상 앱이 멈춰 있어도 이 이상 기다리지 않는다
    private static let messagingTimeout: Float = 0.3
    /// 페이지 주소를 찾으려고 위로 올라가는 최대 단계 (코드 편집기에서 웹 영역까지)
    private static let maxAncestorDepth = 40
    /// 클릭 위치가 입력란 경계에서 이만큼 벗어나도 안으로 본다 (테두리·여백 클릭)
    private static let clickTolerance: CGFloat = 6
    /// 웹 내용 AX를 처음 켠 직후 트리가 만들어지기를 기다리는 시간
    private static let webAccessibilityWarmup: TimeInterval = 0.2
    static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, "AXSearchField",
    ]
    /// 값을 바꿀 수 있어도 입력란이 아닌 역할: 콤보 상자(선택 목록 — 고르는 동안 포인터 모드를 유지한다)와
    /// 체크박스·라디오·버튼·슬라이더 등 컨트롤. 웹 컨트롤은 값을 바꿀 수 있고 선택 범위도 알려 줄 때가 있어
    /// 아래 편집 영역(contenteditable) 판정에 걸리므로 먼저 걸러 낸다.
    private static let excludedRoles: Set<String> = [
        kAXComboBoxRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXButtonRole as String,
        kAXPopUpButtonRole as String, kAXMenuButtonRole as String, kAXSliderRole as String, kAXIncrementorRole as String,
        kAXDisclosureTriangleRole as String, kAXColorWellRole as String, kAXTabGroupRole as String,
    ]
    /// 웹 내용 AX를 켜 달라고 요청한 앱 (큐에서만 읽고 쓴다)
    private static var webAccessibilityRequested: Set<pid_t> = []
    /// AXEnhancedUserInterface를 켠 앱 (큐에서만 읽고 쓴다)
    private static var enhancedInterfaceRequested: Set<pid_t> = []

    /// 진단용 판정 근거 (역할 이름·오류 코드만, 입력·페이지 내용 없음)
    struct Result {
        var isTextInput = false
        var role: String?
        var subrole: String?
        /// 값을 바꿀 수 있는지 (읽기 전용·비활성 입력란은 아니오)
        var isEditable: Bool?
        /// 입력란으로 판단한 요소의 특징 (제외 규칙 비교·학습용). 입력란이 아니면 nil.
        var signature: FocusSignature?

        /// 기록할 만한 판정인지: 입력란이거나, 텍스트 계열 역할인데 아님으로 본 경우·조회 실패만 (버튼·탭·글자 클릭으로 기록이 묻히지 않게)
        var isWorthRecording: Bool {
            isTextInput || focusError != nil || role.map { TextInputFocusProbe.textRoles.contains($0) || $0 == "AXComboBox" } == true
        }
        var focusError: Int32?
        /// 이번에 웹 내용 AX를 켜 달라고 요청했으면 그 결과 코드 (0 = 성공)
        var webAccessibilityRequest: Int32?
        /// 이번에 AXEnhancedUserInterface를 켰으면 그 결과 코드
        var enhancedInterfaceRequest: Int32?
        /// 포커스된 입력란이 클릭한 자리에 없음 (Chrome 탭을 누르면 그 탭의 주소창·입력란으로 포커스가 돌아가는 경우)
        var isOutsideClick = false

        var summary: String {
            var parts = ["역할 \(role ?? "없음")"]
            if let subrole { parts.append("서브역할 \(subrole)") }
            if let isEditable { parts.append("편집 가능 \(isEditable ? "예" : "아니오")") }
            if isOutsideClick { parts.append("클릭한 자리 밖이라 해제 안 함") }
            if let signature {
                if let scheme = signature.urlScheme { parts.append("페이지 \(scheme)://\(signature.urlHost ?? "")") }
                if !signature.domClasses.isEmpty { parts.append("클래스 \(signature.domClasses.prefix(4).joined(separator: " "))") }
            }
            if let focusError { parts.append("포커스 조회 오류 \(focusError)") }
            if let webAccessibilityRequest { parts.append("웹 AX 요청 \(webAccessibilityRequest)") }
            if let enhancedInterfaceRequest { parts.append("강화 AX 요청 \(enhancedInterfaceRequest)") }
            return parts.joined(separator: ", ")
        }
    }

    /// frontmostPID: 메인 스레드에서 읽은 전면 앱. 결과는 메인 스레드에서 completion으로 받는다.
    /// clickPoint: 클릭한 화면 위치 (CG 좌표). 포커스된 입력란이 이 자리에 없으면 입력란 클릭으로 보지 않는다.
    static func check(frontmostPID: pid_t, clickPoint: CGPoint, completion: @escaping (Result) -> Void) {
        queue.async {
            let result = inspectFocus(pid: frontmostPID, clickPoint: clickPoint)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 시스템 전체 요소(AXFocusedUIElement)로 물으면 Chrome 등에서 -25212(값 없음)로 실패해, 전면 앱에 직접 묻는다
    /// (창 포커스 이동의 WindowInventory.focusedWindow와 같은 이유)
    private static func inspectFocus(pid: pid_t, clickPoint: CGPoint) -> Result {
        var result = Result()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        // Chrome·Electron 등 Chromium 계열은 요청하기 전까지 웹 페이지 내용의 AX 정보를 만들지 않아,
        // 페이지 안 입력란을 눌러도 포커스가 "웹 영역"으로만 보인다. 처음이면 켜 달라고 하고 잠깐 기다린다.
        if let requestResult = requestWebAccessibilityIfNeeded(app) {
            result.webAccessibilityRequest = requestResult.rawValue
            if requestResult == .success { Thread.sleep(forTimeInterval: webAccessibilityWarmup) }
        }
        var focused: CFTypeRef?
        var focusError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        // Chrome은 AXManualAccessibility를 지원하지 않아(-25205) AX 정보가 꺼진 채 포커스가 "값 없음"으로 나온다.
        // 이런 앱에만, 앱마다 한 번 AXEnhancedUserInterface(VoiceOver가 켜는 것과 같은 요청)로 켜고 다시 묻는다.
        // 부작용: 다른 창 정리 앱이 그 앱 창 크기를 바꿀 때 애니메이션이 생길 수 있고, 앱의 메모리·CPU가 조금 는다.
        if focusError == .noValue, let enhanced = requestEnhancedInterfaceIfNeeded(app) {
            result.enhancedInterfaceRequest = enhanced.rawValue
            if enhanced == .success {
                Thread.sleep(forTimeInterval: webAccessibilityWarmup)
                focused = nil
                focusError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            }
        }
        guard focusError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            result.focusError = focusError.rawValue
            return result
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        result.role = role as? String
        result.subrole = subrole as? String
        if let role = result.role, excludedRoles.contains(role) {
            return result
        }
        // 값을 바꿀 수 있어야 입력란이다: 개발자 도구 Response 같은 읽기 전용 텍스트 영역·비활성 입력란은 역할이
        // 텍스트 영역이어도 해제하지 않는다
        var settable: DarwinBoolean = false
        let editable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        result.isEditable = editable
        guard editable else { return result }
        if let role = result.role, textRoles.contains(role) {
            result.isTextInput = true
        } else {
            // 웹 페이지의 편집 영역(contenteditable) 등: 값을 바꿀 수 있고 선택 범위(커서)가 있으면 입력란으로 본다
            var range: CFTypeRef?
            result.isTextInput = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        }
        // 클릭한 곳이 아니라 클릭 뒤 포커스를 보므로, 탭·버튼을 눌러 포커스가 다른 입력란으로 돌아간 경우를 거른다.
        // 위치를 알려 주지 않으면 확인하지 않는다.
        if result.isTextInput, let frame = frame(of: element),
           !frame.insetBy(dx: -clickTolerance, dy: -clickTolerance).contains(clickPoint) {
            result.isTextInput = false
            result.isOutsideClick = true
            return result
        }
        // 입력란이면 특징을 모은다 — 읽기 전용인데 편집 가능으로 보고되는 영역(개발자 도구 Response 등)은
        // 사용자가 배운 제외 규칙과 이 특징으로 걸러 낸다 (KeyPointerController)
        if result.isTextInput {
            result.signature = signature(of: element, role: result.role ?? "", pid: pid)
        }
        return result
    }

    /// 요소의 특징: 앱 번들 ID, 역할, (웹이면) 위로 올라가 찾은 페이지 주소의 scheme·호스트, AXDOMClassList
    private static func signature(of element: AXUIElement, role: String, pid: pid_t) -> FocusSignature {
        var classes: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes)
        var url: URL?
        var current: AXUIElement? = element
        for _ in 0..<maxAncestorDepth {
            guard let node = current else { break }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &value) == .success {
                url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return FocusSignature(
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            role: role,
            urlScheme: url?.scheme,
            urlHost: url?.host,
            domClasses: classes as? [String] ?? []
        )
    }

    /// AXEnhancedUserInterface를 켠다 (앱마다 한 번). 이번에 요청했으면 그 결과, 이미 요청했으면 nil.
    private static func requestEnhancedInterfaceIfNeeded(_ app: AXUIElement) -> AXError? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, !enhancedInterfaceRequested.contains(pid) else { return nil }
        enhancedInterfaceRequested.insert(pid)
        return AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Chromium 계열이 지원하는 AXManualAccessibility를 켠다 (앱마다 한 번). 이번에 요청했으면 그 결과, 이미 요청했으면 nil.
    /// 부작용이 없는 이 방법을 먼저 쓰고, 지원하지 않는 앱(Chrome)만 위의 AXEnhancedUserInterface로 넘어간다.
    private static func requestWebAccessibilityIfNeeded(_ app: AXUIElement) -> AXError? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, !webAccessibilityRequested.contains(pid) else { return nil }
        webAccessibilityRequested.insert(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
