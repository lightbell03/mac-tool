import AppKit
import ApplicationServices

/// 맨 앞 앱에서 포커스된 곳의 화면 위치: 글자 커서(캐럿)가 있으면 그 옆, 없으면 포커스된 요소의 가운데.
/// 포인터 모드로 돌아올 때 포인터를 그곳으로 옮기는 데 쓴다. 내용·제목은 읽지 않고 위치만 묻는다.
enum FocusLocator {
    enum Result {
        /// 글자 커서 옆
        case caret(CGPoint)
        /// 포커스된 요소의 가운데
        case element(CGPoint)
        /// 찾지 못함 (진단용 이유)
        case notFound(String)

        var point: CGPoint? {
            switch self {
            case .caret(let point), .element(let point): return point
            case .notFound: return nil
            }
        }

        /// 진단 기록용 (위치 좌표는 남기지 않는다)
        var summary: String {
            switch self {
            case .caret: return "커서 위치로"
            case .element: return "포커스된 요소 가운데로"
            case .notFound(let reason): return "옮기지 않음 — \(reason)"
            }
        }
    }

    private static let queue = DispatchQueue(label: "WheelSpace.FocusLocator", qos: .userInitiated)
    private static let messagingTimeout: Float = 0.3
    /// 요소가 화면의 이 비율보다 크면(편집기 전체·창 전체 등) 가운데로 옮겨도 의미가 없어 옮기지 않는다
    private static let maxElementScreenRatio: CGFloat = 0.5
    /// 커서 바로 위에 포인터가 겹쳐 글자를 가리지 않게 오른쪽으로 조금 비킨다
    private static let caretOffset: CGFloat = 4

    /// 완료는 메인 스레드에서 부른다
    static func locate(frontmostPID: pid_t, completion: @escaping (Result) -> Void) {
        queue.async {
            let result = find(pid: frontmostPID)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func find(pid: pid_t) -> Result {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .notFound("포커스 조회 오류 \(error.rawValue)")
        }
        let element = focused as! AXUIElement
        let displays = DisplayService.activeDisplayFrames()
        func onScreen(_ point: CGPoint) -> Bool {
            displays.contains { $0.contains(point) }
        }

        if let caret = caretRect(of: element) {
            let point = CGPoint(x: caret.maxX + caretOffset, y: caret.midY)
            if onScreen(point) { return .caret(point) }
        }
        guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else {
            return .notFound("요소 위치 없음")
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = displays.first(where: { $0.contains(center) }) else {
            return .notFound("화면 밖")
        }
        guard frame.width * frame.height <= display.width * display.height * maxElementScreenRatio else {
            return .notFound("커서 위치를 알려 주지 않고 요소가 너무 큼")
        }
        return .element(center)
    }

    /// 선택 범위(커서)의 화면 사각형. 앱이 AXBoundsForRange를 지원하지 않거나 높이가 없으면 nil.
    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
        ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
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
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
