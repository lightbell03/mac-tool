import AppKit
import ApplicationServices

/// 새 데스크탑 만들기: 공개 API가 없어 Mission Control을 잠깐 열고 그 모니터의 "데스크탑 추가(+)" 버튼을
/// 손쉬운 사용 API로 누른 뒤 닫는다. macOS가 버튼 구조를 바꾸면 실패하고 false를 돌려준다.
enum SpaceCreator {
    /// 만들기 결과와 진단용 메모 (버튼 수·각 버튼이 있던 모니터 — 좌표·제목 없음)
    struct Result {
        let created: Bool
        let note: String
    }

    private static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    /// Mission Control이 열리는 애니메이션 동안 버튼을 다시 찾는 횟수·간격
    private static let lookupAttempts = 20
    private static let lookupInterval: TimeInterval = 0.05
    /// 데스크탑 추가 뒤 Mission Control을 닫기 전 기다림
    private static let afterPressDelay: TimeInterval = 0.3
    /// Dock의 Mission Control 트리를 찾을 깊이 (Dock → mc → 모니터 → 데스크탑 막대 → 버튼)
    private static let maxDepth = 6

    /// display: 데스크탑을 만들 모니터 영역, displays: 모든 모니터 영역 (진단용, CG 전역 좌표).
    /// 뒤 스레드에서 부른다 (기다림이 있다).
    static func createSpace(on display: CGRect, displays: [CGRect]) -> Result {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return Result(created: false, note: "Dock 없음")
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.5)
        // Mission Control은 포인터가 있는 모니터를 기준으로 열린다 — 그 모니터 위쪽으로 옮겨 두었다가 되돌린다
        let original = MouseActionService.currentLocation()
        PointerMover.move(to: CGPoint(x: display.midX, y: display.minY + display.height * 0.3))
        defer { PointerMover.move(to: original) }
        NSWorkspace.shared.open(missionControl)
        defer { close() }

        var found: [(element: AXUIElement, frame: CGRect?)] = []
        var target: AXUIElement?
        for _ in 0..<lookupAttempts {
            Thread.sleep(forTimeInterval: lookupInterval)
            // 버튼이 속한 모니터 = 위쪽 "mc.display" 묶음의 영역. 버튼 자체는 숨어 있어 자기 모니터 오른쪽 바깥(+24pt)에
            // 있다고 알려 주므로(왼쪽 모니터의 버튼이 가운데 모니터 안으로 보인다) 버튼 위치로 고르면 안 된다.
            found = addButtons(in: dockElement, depth: 0).map { ($0, displayGroupFrame(of: $0)) }
            // 그 모니터의 버튼만 누른다 — 못 찾으면 엉뚱한 모니터에 만들지 않는다
            target = found.first { $0.frame.map { display.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }?.element
            if target != nil { break }
        }
        // 버튼마다: 위치(어느 모니터·좌표)와 위쪽 요소들의 식별자 — 모니터와 버튼을 짝짓는 단서 (내용·제목 없음)
        let places = found.map { entry -> String in
            guard let frame = entry.frame else { return "모니터 묶음 없음 {\(ancestorSummary(entry.element))}" }
            let index = displays.firstIndex { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            return index.map { "모니터 \($0)" } ?? "모니터 밖 {\(ancestorSummary(entry.element))}"
        }
        let targetIndex = displays.firstIndex(of: display).map(String.init) ?? "?"
        let note = "버튼 \(found.count)개 [\(places.joined(separator: ", "))], 대상 모니터 \(targetIndex)"
        guard let target, AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
            return Result(created: false, note: note)
        }
        Thread.sleep(forTimeInterval: afterPressDelay)
        return Result(created: true, note: note)
    }

    /// 버튼이 속한 모니터 묶음(식별자 mc.display)의 영역. 없으면 nil.
    private static func displayGroupFrame(of element: AXUIElement) -> CGRect? {
        var current = element
        for _ in 0..<maxDepth {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            if string(current, kAXIdentifierAttribute) == "mc.display" { return WindowInventory.frame(of: current) }
        }
        return nil
    }

    /// 위쪽 요소 3단계의 역할·식별자 (진단용)
    private static func ancestorSummary(_ element: AXUIElement) -> String {
        var parts: [String] = []
        var current = element
        for _ in 0..<3 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
            let role = string(current, kAXRoleAttribute) ?? "?"
            let identifier = string(current, kAXIdentifierAttribute) ?? "-"
            let frame = WindowInventory.frame(of: current).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"
            parts.append("\(role)#\(identifier)[\(frame)]")
        }
        return parts.joined(separator: " < ")
    }

    /// Mission Control 닫기 (Esc)
    private static func close() {
        try? SyntheticKeyboard.press(keyCode: 53, flags: [])
    }

    /// "데스크탑 추가" 버튼: 식별자 mc.spaces.add, 없으면 설명에 "add desktop"·"데스크탑 추가"가 들어간 버튼
    private static func addButtons(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth <= maxDepth else { return [] }
        var result: [AXUIElement] = []
        if string(element, kAXRoleAttribute) == kAXButtonRole as String {
            let identifier = string(element, kAXIdentifierAttribute) ?? ""
            let description = (string(element, kAXDescriptionAttribute) ?? "").lowercased()
            if identifier == "mc.spaces.add" || description.contains("add desktop") || description.contains("데스크탑 추가") {
                result.append(element)
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return result }
        for child in list {
            result += addButtons(in: child, depth: depth + 1)
        }
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
