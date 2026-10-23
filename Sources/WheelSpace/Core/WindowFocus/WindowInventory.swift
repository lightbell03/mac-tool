import AppKit
import ApplicationServices
import WheelSpaceCore

/// AX 조회 실패 코드 (AXError는 Swift Error가 아니라 감싸서 쓴다)
struct AXLookupError: Error {
    let code: AXError
}

/// 한 번의 명령에 쓰는 창 스냅샷. 창 제목은 담지 않는다.
struct WindowSnapshot {
    struct Entry {
        let record: CGWindowRecord
        /// 앞에서 뒤 순서 (0 = 가장 앞)
        let zIndex: Int
        /// 이동 후보 자격이 있는 창만 AX 객체를 가진다 (매칭 성공·일반 창·모달 아님)
        let axWindow: AXUIElement?
        /// 디스플레이 안 부분 (중심 계산용)
        let visibleFrame: CGRect
        /// 다른 창에 가려지지 않은 조각들 (후보만, 포인터 위치 계산용)
        var exposedRegions: [CGRect] = []
    }

    let displays: [CGRect]
    /// 가림 계산용 전체 목록 (Dock·메뉴 막대 등 비후보 포함, 앞에서 뒤 순서)
    let occluders: [Entry]
    /// 이동 후보 (노출 판정 통과)
    let candidates: [Entry]
    /// 현재 포커스 창 (기준점) — 후보 판정 임계값으로 제거하지 않는다
    let focused: Entry?
    /// 전면 앱에 포커스 창이 없어(앱을 닫거나 새로 연 직후 등) 화면 맨 앞 창을 기준으로 삼았다 — 실제로 포커스된 창이 아니다
    var focusIsFallback = false
    /// 진단용 단계별 시간 (창 제목 없음)
    var timing = Timing()

    struct Timing {
        /// 창 정보를 물어본 앱 수
        var appCount = 0
        /// 앱별 창 조회(AX) 합계 (ms)
        var appQueryMs = 0
        /// 가장 느리게 답한 앱과 그 시간
        var slowestPID: Int32?
        var slowestMs = 0
        /// 현재 포커스 창 조회 (ms)
        var focusedLookupMs = 0
    }
}

/// CG 창 목록 + AX 창 객체로 스냅샷을 만든다. 느린 AX 호출이 있으므로 메인 스레드 밖에서 부른다.
enum WindowInventory {
    /// AX 개별 호출 제한 시간 (설계값). Chromium·Electron 계열은 첫 AX 요청 응답이 느려 0.1초로는 자주 실패했다.
    static let axMessagingTimeout: Float = 0.3
    /// 현재 포커스 창 조회는 기준점이라 조금 더 기다린다
    static let focusLookupTimeout: Float = 0.5

    enum Failure: Error, Equatable {
        /// axError: 마지막 AX 오류 코드 (진단용)
        case noFocusedWindow(axError: Int32)
        /// 현재 창에 모달 시트·대화상자가 떠 있음
        case focusedWindowIsModal
        /// 가림 계산 예산 초과
        case budgetExceeded
    }

    private struct RawWindow {
        let record: CGWindowRecord
        let zIndex: Int
        let layer: Int
    }

    /// frontmostPID: 메인 스레드에서 읽은 전면 앱 PID (NSWorkspace)
    /// includeHidden: 완전히 가려진 창도 후보에 넣는다 (창 목록 전환기). 방향 이동은 넣지 않는다.
    /// assumedFocus: 연속 입력에서 직전에 앞으로 가져온 창 (포커스 확인 전) — 있으면 현재 포커스 조회 대신 기준으로 쓴다
    static func snapshot(
        excludingPID ownPID: Int32,
        frontmostPID: Int32,
        includeHidden: Bool = false,
        assumedFocus: AXUIElement? = nil
    ) -> Result<WindowSnapshot, Failure> {
        let displays = DisplayService.activeDisplayFrames()
        let raw = onScreenWindows()

        // 가림 계산용: 투명 창과, 디스플레이 하나를 통째로 덮는 비일반 레이어 오버레이(클릭이 통과하는 도구 창 등)는 뺀다
        let occluderWindows = raw.filter { window in
            window.layer == 0 || !displays.contains { window.record.frame.contains($0) }
        }

        // 후보 1차: 일반 레이어, 다른 앱, Dock에 나오는 일반 앱(보안 에이전트 같은 보조 앱은 AX 조회가 느리고
        // 포커스를 옮길 대상이 아니다), 숨기지 않음, 디스플레이와 교차
        let firstPass = raw.filter { window in
            guard window.layer == 0, window.record.pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: window.record.pid),
                  app.activationPolicy == .regular, !app.isHidden else {
                return false
            }
            return displays.contains { $0.intersects(window.record.frame) }
        }

        // PID별 AX 창 수집 → CG 창과 일대일 매칭
        var axElements: [AXUIElement] = []
        var axRecords: [AXWindowRecord] = []
        var modalPIDs: Set<Int32> = []
        var timing = WindowSnapshot.Timing()
        // 앱별 조회는 동시에 한다 — 차례로 하면 앱 수만큼 쌓이고, 동시에 하면 가장 느린 앱만큼만 걸린다
        let pids = Array(Set(firstPass.map(\.record.pid)))
        var perApp = [(windows: [(element: AXUIElement, frame: CGRect, isModal: Bool)], ms: Int)](
            repeating: ([], 0), count: pids.count
        )
        let queryStarted = ProcessInfo.processInfo.systemUptime
        perApp.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: pids.count) { index in
                let started = ProcessInfo.processInfo.systemUptime
                let windows = axWindows(pid: pids[index])
                results[index] = (windows, milliseconds(since: started))
            }
        }
        timing.appCount = pids.count
        timing.appQueryMs = milliseconds(since: queryStarted)
        for (index, pid) in pids.enumerated() {
            let (windows, queryMs) = perApp[index]
            if queryMs > timing.slowestMs {
                timing.slowestMs = queryMs
                timing.slowestPID = pid
            }
            for window in windows {
                if window.isModal { modalPIDs.insert(pid) }
                axRecords.append(AXWindowRecord(index: axElements.count, pid: pid, frame: window.frame))
                axElements.append(window.element)
            }
        }
        let matches = WindowMatcher.match(cg: firstPass.map(\.record), ax: axRecords)

        // 현재 포커스 창
        var focusedElement: AXUIElement
        var focusIsFallback = false
        let focusedStarted = ProcessInfo.processInfo.systemUptime
        // 연속 입력이면 확인 전이라도 직전에 가져온 창을 기준으로 한다
        let focusedResult = assumedFocus.map { Result<AXUIElement, AXLookupError>.success($0) }
            ?? focusedWindow(pid: frontmostPID)
        timing.focusedLookupMs = milliseconds(since: focusedStarted)
        switch focusedResult {
        case .success(let element): focusedElement = element
        case .failure(let error):
            // 앱을 닫거나 새로 연 직후처럼 전면 앱에 창이 없으면 화면 맨 앞의 일반 창을 기준으로 삼는다
            guard let top = frontmostCandidate(firstPass, matches: matches, modalPIDs: modalPIDs) else {
                return .failure(.noFocusedWindow(axError: error.code.rawValue))
            }
            focusedElement = axElements[top]
            focusIsFallback = true
        }
        guard let focusedFrame = frame(of: focusedElement) else {
            return .failure(.noFocusedWindow(axError: AXError.noValue.rawValue))
        }
        if isModalOrHasSheet(focusedElement) {
            return .failure(.focusedWindowIsModal)
        }
        var focusedPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &focusedPID)

        var candidates: [WindowSnapshot.Entry] = []
        for window in firstPass {
            guard let index = matches[window.record.windowID], !modalPIDs.contains(window.record.pid) else { continue }
            let element = axElements[index]
            if CFEqual(element, focusedElement) { continue }

            let front = occluderWindows.filter { $0.zIndex < window.zIndex }.map(\.record.frame)
            guard let regions = VisibilityCalculator.visibleRegions(of: window.record.frame, displays: displays, occluders: front) else {
                return .failure(.budgetExceeded)
            }
            guard includeHidden || VisibilityCalculator.isExposed(regions) else { continue }
            candidates.append(WindowSnapshot.Entry(
                record: window.record,
                zIndex: window.zIndex,
                axWindow: element,
                visibleFrame: clipped(window.record.frame, to: displays),
                exposedRegions: regions
            ))
        }

        let focused = WindowSnapshot.Entry(
            record: CGWindowRecord(windowID: 0, pid: focusedPID, frame: focusedFrame),
            zIndex: -1,
            axWindow: focusedElement,
            visibleFrame: clipped(focusedFrame, to: displays)
        )
        let occluders = occluderWindows.map {
            WindowSnapshot.Entry(record: $0.record, zIndex: $0.zIndex, axWindow: nil, visibleFrame: $0.record.frame)
        }
        var snapshot = WindowSnapshot(displays: displays, occluders: occluders, candidates: candidates, focused: focused)
        snapshot.timing = timing
        snapshot.focusIsFallback = focusIsFallback
        return .success(snapshot)
    }

    /// 화면 맨 앞(z 순서)의 후보 창 — AX 창과 짝이 맞고 대화상자가 없는 앱의 창. 반환값은 axElements 색인.
    private static func frontmostCandidate(
        _ windows: [RawWindow], matches: [CGWindowID: Int], modalPIDs: Set<Int32>
    ) -> Int? {
        windows
            .filter { matches[$0.record.windowID] != nil && !modalPIDs.contains($0.record.pid) }
            .min { $0.zIndex < $1.zIndex }
            .flatMap { matches[$0.record.windowID] }
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    /// 전면 앱의 현재 포커스 창. 시스템 전체 요소(AXFocusedApplication)를 거치면 -25204(응답 불가)가 잦아
    /// 전면 앱 PID에 직접 묻는다. 포커스 창 → 주 창 → 첫 일반 창 순으로 찾는다.
    static func focusedWindow(pid: Int32) -> Result<AXUIElement, AXLookupError> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, focusLookupTimeout)
        var lastError = AXLookupError(code: .noValue)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            switch copyElement(app, attribute) {
            case .success(let window): return .success(window)
            case .failure(let error): lastError = error
            }
        }
        if let first = axWindows(pid: pid).first(where: { !$0.isModal })?.element {
            return .success(first)
        }
        return .failure(lastError)
    }

    /// 앱의 일반 창들: 역할 AXWindow, 서브역할 AXStandardWindow, 최소화 아님. (요소, 전역 frame)
    static func axWindows(pid: Int32) -> [(element: AXUIElement, frame: CGRect, isModal: Bool)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows.compactMap { window in
            AXUIElementSetMessagingTimeout(window, axMessagingTimeout)
            let isModal = isModalOrHasSheet(window)
            guard string(window, kAXRoleAttribute) == kAXWindowRole as String,
                  string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String || isModal,
                  bool(window, kAXMinimizedAttribute) != true,
                  let frame = frame(of: window) else {
                return nil
            }
            return (window, frame, isModal)
        }
    }

    /// 창 자체가 모달(AXModal)이거나 시트(AXSheet) 자식이 있으면 true.
    static func isModalOrHasSheet(_ window: AXUIElement) -> Bool {
        if bool(window, kAXModalAttribute) == true { return true }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else {
            return false
        }
        return children.contains { string($0, kAXRoleAttribute) == kAXSheetRole as String }
    }

    /// 창 제목 (AXTitle). 목록 표시에만 쓰고 기록·저장하지 않는다. 메인 스레드 밖에서 부른다.
    static func title(of window: AXUIElement) -> String? {
        guard let title = string(window, kAXTitleAttribute), !title.isEmpty else { return nil }
        return title
    }

    // MARK: - 내부

    /// CG 창 목록 (앞에서 뒤 순서). 창 제목은 읽지 않는다.
    private static func onScreenWindows() -> [RawWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        var result: [RawWindow] = []
        for (order, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
                continue
            }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0, bounds.width > 0, bounds.height > 0 else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            result.append(RawWindow(
                record: CGWindowRecord(windowID: UInt32(number), pid: Int32(pid), frame: bounds),
                zIndex: order,
                layer: layer
            ))
        }
        return result
    }

    /// 디스플레이 안에 있는 부분들을 감싸는 사각형. 밖에 있으면 원래 사각형.
    private static func clipped(_ frame: CGRect, to displays: [CGRect]) -> CGRect {
        let pieces = displays.map { frame.intersection($0) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let first = pieces.first else { return frame }
        return pieces.dropFirst().reduce(first) { $0.union($1) }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> Result<AXUIElement, AXLookupError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, attribute as CFString, &value)
        guard error == .success else { return .failure(AXLookupError(code: error)) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(AXLookupError(code: .noValue)) }
        return .success(value as! AXUIElement)
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
