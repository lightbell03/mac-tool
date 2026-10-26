import AppKit
import ApplicationServices
import WheelSpaceCore

/// 지금 창을 같은 모니터의 옆 데스크탑으로 보낸다. 공개 API가 없어 비공개 SkyLight 연산(SkyLightBridge)으로 창을 옮기고,
/// macOS 데스크탑 이동 단축키(⌃← / ⌃→)로 화면도 그 데스크탑으로 넘긴다. 새 데스크탑 만들기도 여기서 한다.
enum WindowSpaceMover {
    enum Outcome: Equatable {
        case moved
        /// 새 데스크탑만 만듦 (만들기 단축키)
        case created(note: String)
        /// 새 데스크탑을 만든 뒤 옮김
        case createdAndMoved(note: String)
        case noFocusedWindow
        case fullScreen
        /// 그 방향에 데스크탑이 없음 (만들기 꺼짐)
        case noSpace
        /// 왼쪽 끝 — 맨 앞에는 만들 수 없다
        case noSpaceAtStart
        /// 옆이 전체 화면 앱 공간이라 넣을 수 없음
        case targetIsFullScreen
        /// 데스크탑 목록을 읽지 못함
        case spacesUnavailable
        /// note: 진단용 (찾은 버튼 수·위치한 모니터)
        case createFailed(note: String)
        /// 이 macOS에 창 이동 연산이 없음
        case bridgeUnavailable
        /// 창이 그 데스크탑으로 옮겨지지 않음 (note: 단계별 진단)
        case notMoved(note: String)
        /// 창은 옮겼지만 화면이 그 데스크탑으로 넘어가지 않음 (note: 단계별 진단)
        case notSwitched(note: String)
    }

    /// 창이 그 데스크탑으로 옮겨졌는지·화면이 넘어갔는지 다시 보는 횟수와 간격
    private static let confirmAttempts = 30
    private static let confirmInterval: TimeInterval = 0.05

    /// AX 창과 같은 앱·같은 영역의 화면 창 번호 (옮길 창 — 못 찾으면 옮기지 않는다)
    private static func onScreenWindowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  abs(bounds.minX - frame.minX) <= 2, abs(bounds.minY - frame.minY) <= 2,
                  abs(bounds.width - frame.width) <= 2, abs(bounds.height - frame.height) <= 2,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return CGWindowID(number.uint32Value)
        }
        return nil
    }

    /// 그 모니터에서 direction 쪽 데스크탑을 준비한다: 있으면 그대로, 오른쪽 끝이면(만들기 켬) 만들고 정말 생겼는지 확인.
    /// 성공 값은 만들었을 때의 진단 메모(만들지 않았으면 nil).
    private static func prepareSpace(
        direction: SpaceDirection, at center: CGPoint, createIfMissing: Bool, screens: [(frame: CGRect, visible: CGRect)]
    ) -> Result<String?, OutcomeError> {
        // 그 방향에 데스크탑이 있는지 (옮길 데스크탑 ID가 필요해 목록을 못 읽으면 옮기지 않는다)
        guard let spaces = SpaceService.spaces(onDisplayContaining: center) else { return .failure(OutcomeError(.spacesUnavailable)) }
        switch SpaceMovePlan.step(
            currentIndex: spaces.currentIndex, spaceCount: spaces.count, direction: direction, createIfMissing: createIfMissing
        ) {
        case .move:
            return .success(nil)
        case .noSpace:
            return .failure(OutcomeError(direction == .left ? .noSpaceAtStart : .noSpace))
        case .createThenMove:
            let displays = screens.map(\.frame)
            let display = displays.first { $0.contains(center) } ?? CGRect(origin: center, size: .zero)
            let result = SpaceCreator.createSpace(on: display, displays: displays)
            guard result.created else { return .failure(OutcomeError(.createFailed(note: result.note))) }
            // 실제로 그 모니터에 생겼는지 확인 — 다른 모니터에 생겼으면 넘기지 않는다 (넘길 곳이 없다)
            Thread.sleep(forTimeInterval: afterCreateDelay)
            let after = SpaceService.spaces(onDisplayContaining: center)
            guard let after, after.count > spaces.count else {
                let note = "다른 모니터에 생김 (대상 모니터 \(spaces.count)→\(after?.count ?? -1)개) · " + result.note
                return .failure(OutcomeError(.createFailed(note: note)))
            }
            return .success(result.note)
        }
    }

    /// Result의 실패 자리에 Outcome을 넣기 위한 감싸기
    private struct OutcomeError: Error {
        let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }
    }

    /// 지금 창(없으면 포인터)이 있는 모니터에 새 데스크탑을 만든다 (맨 끝에, 넘어가지는 않는다)
    @MainActor
    static func createSpace(frontmostPID: pid_t?) async -> Outcome {
        let screens = DisplayService.screenAreas()
        return await Task.detached(priority: .userInitiated) {
            createSpaceOnFocusedDisplay(pid: frontmostPID, screens: screens)
        }.value
    }

    private static func createSpaceOnFocusedDisplay(pid: pid_t?, screens: [(frame: CGRect, visible: CGRect)]) -> Outcome {
        var center = MouseActionService.currentLocation()
        if let pid, case .success(let window) = WindowInventory.focusedWindow(pid: pid),
           let frame = WindowInventory.frame(of: window) {
            center = CGPoint(x: frame.midX, y: frame.midY)
        }
        let displays = screens.map(\.frame)
        guard let display = displays.first(where: { $0.contains(center) }) else { return .noFocusedWindow }
        let before = SpaceService.spaces(onDisplayContaining: center)
        let result = SpaceCreator.createSpace(on: display, displays: displays)
        guard result.created else { return .createFailed(note: result.note) }
        // 실제로 그 모니터에 생겼는지 (목록을 못 읽으면 확인 없이 성공으로 본다)
        if let before {
            Thread.sleep(forTimeInterval: afterCreateDelay)
            let after = SpaceService.spaces(onDisplayContaining: center)
            guard let after, after.count > before.count else {
                return .createFailed(note: "다른 모니터에 생김 (대상 모니터 \(before.count)→\(after?.count ?? -1)개) · " + result.note)
            }
        }
        return .created(note: result.note)
    }

    /// 새 데스크탑을 만든 뒤 Mission Control이 닫히기를 기다리는 시간
    private static let afterCreateDelay: TimeInterval = 0.4

    @MainActor
    static func move(direction: SpaceDirection, frontmostPID: pid_t, createIfMissing: Bool) async -> Outcome {
        let screens = DisplayService.screenAreas()
        return await Task.detached(priority: .userInitiated) {
            moveFocusedWindow(direction: direction, pid: frontmostPID, createIfMissing: createIfMissing, screens: screens)
        }.value
    }

    private static func moveFocusedWindow(
        direction: SpaceDirection, pid: pid_t, createIfMissing: Bool, screens: [(frame: CGRect, visible: CGRect)]
    ) -> Outcome {
        guard SkyLightBridge.isAvailable else { return .bridgeUnavailable }
        guard case .success(let window) = WindowInventory.focusedWindow(pid: pid),
              let frame = WindowInventory.frame(of: window) else { return .noFocusedWindow }
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true {
            return .fullScreen
        }
        guard let windowID = onScreenWindowID(pid: pid, frame: frame) else { return .noFocusedWindow }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let prepared = prepareSpace(direction: direction, at: center, createIfMissing: createIfMissing, screens: screens)
        guard case .success(let createNote) = prepared else {
            if case .failure(let error) = prepared { return error.outcome }
            return .noFocusedWindow
        }

        // 넣을 데스크탑 (만들었으면 만든 뒤의 목록 기준)
        guard let spaces = SpaceService.spaces(onDisplayContaining: center) else { return .spacesUnavailable }
        let targetIndex = spaces.currentIndex + (direction == .left ? -1 : 1)
        guard spaces.ids.indices.contains(targetIndex) else { return direction == .left ? .noSpaceAtStart : .noSpace }
        if spaces.isFullScreen[targetIndex] { return .targetIsFullScreen }
        let target = spaces.ids[targetIndex]

        // 1) 창을 그 데스크탑으로 옮기고, 정말 옮겨졌는지 창의 데스크탑을 다시 읽어 확인한다 (연산이 비동기다)
        guard SkyLightBridge.moveWindows([windowID], toSpace: target) else {
            return .notMoved(note: "이동 연산을 만들지 못함")
        }
        let movedAfter = waitUntil { SkyLightBridge.spaceIDs(ofWindow: windowID) == [target] }
        guard let movedAfter else {
            let now = SkyLightBridge.spaceIDs(ofWindow: windowID).map { "\($0.count)곳" } ?? "읽지 못함"
            return .notMoved(note: "창의 데스크탑이 바뀌지 않음 (지금 \(now), 목표 순서 \(targetIndex))")
        }

        // 2) 화면도 그 데스크탑으로 넘기고, 넘어간 뒤 그 창을 앞으로 가져온다
        try? DesktopSwitcher().send(direction.switchDirection)
        let switchedAfter = waitUntil { SpaceService.spaces(onDisplayContaining: center)?.currentIndex == targetIndex }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard switchedAfter != nil else {
            let now = SpaceService.spaces(onDisplayContaining: center)?.currentIndex ?? -1
            return .notSwitched(note: "창 옮김 \(movedAfter)ms, 데스크탑 \(spaces.currentIndex)→\(now) (목표 \(targetIndex))")
        }
        return createNote.map { .createdAndMoved(note: $0) } ?? .moved
    }

    /// condition이 참이 될 때까지 기다린다. 참이 되면 걸린 시간(ms), 끝내 아니면 nil.
    private static func waitUntil(_ condition: () -> Bool) -> Int? {
        for attempt in 1...confirmAttempts {
            Thread.sleep(forTimeInterval: confirmInterval)
            if condition() { return Int(Double(attempt) * confirmInterval * 1_000) }
        }
        return nil
    }
}
