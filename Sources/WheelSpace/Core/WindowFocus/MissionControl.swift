import AppKit
import ApplicationServices

/// Mission Control 화면을 손쉬운 사용 API로 다루는 공통 도구 (Dock 프로세스의 AX 트리).
/// 구조: mc → 모니터마다 mc.display → mc.spaces(데스크탑 막대) → mc.spaces.list(데스크탑 썸네일들)·데스크탑 추가 버튼.
/// macOS가 구조를 바꾸면 못 찾고 nil을 돌려준다.
enum MissionControl {
    private static let app = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    /// 찾을 깊이 (Dock → mc → 모니터 → 데스크탑 막대 → 목록 → 썸네일)
    private static let maxDepth = 7

    /// Dock 프로세스 번호. 메인 스레드에서 읽는다 (뒤 스레드에서는 실행 중인 앱 목록이 비어 나올 때가 있다).
    @MainActor
    static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    static func dockElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    static func open() {
        NSWorkspace.shared.open(app)
    }

    /// 닫기 (Esc)
    static func close() {
        try? SyntheticKeyboard.press(keyCode: 53, flags: [])
    }

    /// display 영역 가운데를 품은 모니터 묶음(mc.display)
    static func displayGroup(in dock: AXUIElement, for display: CGRect) -> AXUIElement? {
        let center = CGPoint(x: display.midX, y: display.midY)
        return descendants(of: dock, identifier: "mc.display").first {
            WindowInventory.frame(of: $0)?.contains(center) ?? false
        }
    }

    /// 그 모니터 묶음의 데스크탑 썸네일들 (왼쪽부터 = 데스크탑 순서, 전체 화면 앱 공간 포함)
    static func spaceThumbnails(in group: AXUIElement) -> [AXUIElement] {
        guard let list = descendants(of: group, identifier: "mc.spaces.list").first else { return [] }
        return children(of: list).sorted {
            (WindowInventory.frame(of: $0)?.minX ?? 0) < (WindowInventory.frame(of: $1)?.minX ?? 0)
        }
    }

    /// 진단용: element 아래 요소들의 역할#식별자@가운데 좌표 (depth 단계까지, 많으면 앞부분만). 내용·제목 없음.
    static func structureSummary(of element: AXUIElement, depth maxLevel: Int = 4, limit: Int = 30) -> String {
        var parts: [String] = []
        func walk(_ node: AXUIElement, _ level: Int) {
            guard level <= maxLevel, parts.count < limit else { return }
            let role = (string(node, kAXRoleAttribute) ?? "?").replacingOccurrences(of: "AX", with: "")
            let identifier = string(node, kAXIdentifierAttribute) ?? "-"
            let place = WindowInventory.frame(of: node).map { "\(Int($0.midX)),\(Int($0.midY)) \(Int($0.width))×\(Int($0.height))" } ?? "?"
            parts.append("\(String(repeating: ">", count: level))\(role)#\(identifier)@\(place)")
            for child in children(of: node) { walk(child, level + 1) }
        }
        walk(element, 0)
        return parts.joined(separator: " | ")
    }

    /// 그 모니터 묶음에 보이는 창 썸네일들 (mc.windows 아래 버튼)
    static func windowThumbnails(in group: AXUIElement) -> [AXUIElement] {
        descendants(of: group, identifier: "mc.windows").flatMap { children(of: $0) }
    }

    static func descendants(of element: AXUIElement, identifier: String, depth: Int = 0) -> [AXUIElement] {
        guard depth <= maxDepth else { return [] }
        var result: [AXUIElement] = []
        if string(element, kAXIdentifierAttribute) == identifier { result.append(element) }
        for child in children(of: element) {
            result += descendants(of: child, identifier: identifier, depth: depth + 1)
        }
        return result
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
