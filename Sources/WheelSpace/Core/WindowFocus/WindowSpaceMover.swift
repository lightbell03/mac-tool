import AppKit
import ApplicationServices
import WheelSpaceCore

/// 지금 창을 같은 모니터의 옆 데스크탑으로 보낸다. 공개 API가 없어 사람이 하듯 창 제목 줄을 마우스로 쥔 채
/// Mission Control을 열고 그 데스크탑 썸네일에 놓은 뒤, 그 썸네일을 눌러 화면도 그 데스크탑으로 넘어간다.
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
        /// 데스크탑 목록을 읽지 못해 있는지 모른 채 넘겨 봄
        case movedWithoutSpaceInfo
        /// note: 진단용 (찾은 버튼 수·위치한 모니터)
        case createFailed(note: String)
        /// 실제 마우스 버튼이 눌려 있어 잡지 않음
        case mouseBusy
        /// 데스크탑은 넘어갔지만 창이 따라오지 않음 (넣지 못함, note: 단계별 진단)
        case notCarried(note: String)
        /// 데스크탑이 목표로 넘어가지 않음 (note: 단계별 진단)
        case notSwitched(note: String)
        /// Mission Control에서 넣을 데스크탑 썸네일을 찾지 못함 (note: 진단용)
        case thumbnailNotFound(note: String)
    }

    /// 잡은 뒤 데스크탑을 넘기기 전 기다림 (앱이 창을 집었다고 알아차리게)
    private static let grabDelay: TimeInterval = 0.08
    /// 창 끌기로 알아보게 나눠 끄는 횟수·거리·간격
    private static let dragSteps = 4
    private static let dragStepDistance: CGFloat = 3
    private static let dragStepInterval: TimeInterval = 0.02
    /// 쥔 창을 from에서 to까지 나눠 끈다 (끝나면 from이 to가 된다)
    private static func drag(from point: inout CGPoint, to target: CGPoint) {
        let start = point
        for step in 1...dropSteps {
            let t = CGFloat(step) / CGFloat(dropSteps)
            point = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
            MouseActionService.movePointer(to: point, dragging: true)
            Thread.sleep(forTimeInterval: dropStepInterval)
        }
    }

    /// 데스크탑 막대를 펼치려고 끌어 올리는 자리(모니터 맨 위에서 아래로)와 펼쳐지기를 기다리는 시간
    private static let expandEdgeOffset: CGFloat = 4
    private static let expandDelay: TimeInterval = 0.4
    /// 펼치기를 다시 하는 최대 횟수와, 다시 할 때마다 옆으로 옮기는 거리
    private static let maxExpandTries = 3
    private static let expandNudge: CGFloat = 24
    /// Mission Control이 열린 뒤 썸네일이 안 보이면 막대를 펼치기까지 기다리는 횟수 (× 찾는 간격)
    private static let expandAfterAttempts = 6

    /// Mission Control이 열리고 창 썸네일이 보일 때까지 찾는 횟수 (× 찾는 간격), 열린 뒤 애니메이션이 끝나기를 기다리는 시간
    private static let openWaitAttempts = 30
    private static let openSettleDelay: TimeInterval = 0.35
    /// Mission Control 썸네일을 다시 찾는 횟수·간격
    private static let thumbnailLookupAttempts = 30
    private static let thumbnailLookupInterval: TimeInterval = 0.05
    /// 썸네일까지 끄는 단계 수·간격, 썸네일 위에서 머무는 시간 (넣을 곳으로 알아차리게), 놓은 뒤 기다림
    private static let dropSteps = 12
    private static let dropStepInterval: TimeInterval = 0.015
    private static let hoverDelay: TimeInterval = 0.25
    private static let collapsedHoverDelay: TimeInterval = 0.6
    private static let afterDropDelay: TimeInterval = 0.3
    /// 넘긴 뒤 창이 따라왔는지 보기 전 기다림
    private static let verifyDelay: TimeInterval = 0.15

    /// 지금 화면에 보이는 창 번호들
    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } })
    }

    /// AX 창과 같은 앱·같은 영역의 화면 창 번호 (확인용 — 못 찾으면 확인하지 않는다)
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

    /// prepareSpace 결과에서 "데스크탑 목록을 읽지 못함"을 나타내는 메모
    private static let unknownSpacesMarker = "\u{0}unknown"

    /// 그 모니터에서 direction 쪽 데스크탑을 준비한다: 있으면 그대로, 오른쪽 끝이면(만들기 켬) 만들고 정말 생겼는지 확인.
    /// 성공 값은 만들었을 때의 진단 메모(만들지 않았으면 nil, 목록을 못 읽었으면 unknownSpacesMarker).
    private static func prepareSpace(
        direction: SpaceDirection, at center: CGPoint, createIfMissing: Bool, screens: [(frame: CGRect, visible: CGRect)]
    ) -> Result<String?, OutcomeError> {
        // 그 방향에 데스크탑이 있는지 (읽지 못하면 있는지 모른 채 넘겨 본다 — 만들지는 않는다)
        guard let spaces = SpaceService.spaces(onDisplayContaining: center) else { return .success(unknownSpacesMarker) }
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
        let dockPID = MissionControl.dockPID()
        return await Task.detached(priority: .userInitiated) {
            moveFocusedWindow(
                direction: direction, pid: frontmostPID, createIfMissing: createIfMissing, screens: screens, dockPID: dockPID
            )
        }.value
    }

    private static func moveFocusedWindow(
        direction: SpaceDirection, pid: pid_t, createIfMissing: Bool, screens: [(frame: CGRect, visible: CGRect)],
        dockPID: pid_t?
    ) -> Outcome {
        guard case .success(let window) = WindowInventory.focusedWindow(pid: pid),
              let frame = WindowInventory.frame(of: window) else { return .noFocusedWindow }
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true {
            return .fullScreen
        }
        if MouseActionService.isPhysicalLeftButtonDown { return .mouseBusy }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let prepared = prepareSpace(direction: direction, at: center, createIfMissing: createIfMissing, screens: screens)
        guard case .success(let createNote) = prepared else {
            if case .failure(let error) = prepared { return error.outcome }
            return .noFocusedWindow
        }
        let spacesKnown = createNote != unknownSpacesMarker

        // 넣을 데스크탑 순서 (만들었으면 만든 뒤의 목록 기준)
        guard let spaces = SpaceService.spaces(onDisplayContaining: center),
              let display = screens.map(\.frame).first(where: { $0.contains(center) }) else {
            return .movedWithoutSpaceInfo
        }
        let targetIndex = spaces.currentIndex + (direction == .left ? -1 : 1)
        let windowID = onScreenWindowID(pid: pid, frame: frame)
        // Mission Control에서 이 창을 알아보는 데만 쓴다 (기록하지 않는다)
        let windowTitle = MissionControl.string(window, kAXTitleAttribute)
        guard let dockPID else { return .thumbnailNotFound(note: "Dock 없음") }
        let dock = MissionControl.dockElement(pid: dockPID)
        let original = MouseActionService.currentLocation()

        // 사람이 Mission Control에서 하는 순서 그대로: 열고 → 창 썸네일을 잡아 위로 끌어 데스크탑 막대를 펼치고
        // → 옆 데스크탑 썸네일에 놓고 → 그 데스크탑을 눌러 넘어간다.
        // (창을 먼저 잡고 Mission Control을 열면 열리는 동안 잡은 게 풀려 아무것도 끌리지 않았다)
        MissionControl.open()
        var windowFrameInMC: CGRect?
        var windowCount = 0
        for _ in 0..<openWaitAttempts {
            Thread.sleep(forTimeInterval: thumbnailLookupInterval)
            guard let group = MissionControl.displayGroup(in: dock, for: display) else { continue }
            let buttons = MissionControl.windowThumbnails(in: group)
            windowCount = buttons.count
            let titled = windowTitle.flatMap { title in
                title.isEmpty ? nil : buttons.first { MissionControl.string($0, kAXTitleAttribute) == title }
            }
            guard let match = titled ?? (buttons.count == 1 ? buttons.first : nil),
                  let found = WindowInventory.frame(of: match),
                  display.contains(CGPoint(x: found.midX, y: found.midY)) else { continue }
            windowFrameInMC = found
            break
        }
        guard let windowFrameInMC else {
            let structure = MissionControl.displayGroup(in: dock, for: display)
                .map { MissionControl.structureSummary(of: $0) } ?? "모니터 묶음 없음"
            MissionControl.close()
            return .thumbnailNotFound(note: "창 썸네일 \(windowCount)개 중 이 창을 못 찾음, 구조 \(structure)")
        }
        // 열리는 애니메이션이 끝나기를 기다린다 (그 전에 끌면 무시된다)
        Thread.sleep(forTimeInterval: openSettleDelay)

        // 창 썸네일을 잡고 몇 번 나눠 끌어 잡힌 상태로 만든다
        var point = CGPoint(x: windowFrameInMC.midX, y: windowFrameInMC.midY)
        PointerMover.move(to: point)
        guard (try? MouseActionService.leftButton(down: true, at: point)) != nil else {
            MissionControl.close()
            PointerMover.move(to: original)
            return .noFocusedWindow
        }
        for _ in 0..<dragSteps {
            point.x += dragStepDistance
            MouseActionService.movePointer(to: point, dragging: true)
            Thread.sleep(forTimeInterval: dragStepInterval)
        }
        // 위쪽 끝으로 끌어 올려 데스크탑 막대를 펼친다
        drag(from: &point, to: CGPoint(x: point.x, y: display.minY + expandEdgeOffset))
        Thread.sleep(forTimeInterval: expandDelay)

        // 펼쳐진 막대에서 옆 데스크탑 썸네일 찾기 (아직 화면 밖이면 위쪽 끝에서 조금씩 옮겨 다시 펼친다)
        var thumbnail: AXUIElement?
        var thumbnailFrame: CGRect?
        var thumbnailPlaces: [String] = []
        var expandTries = 1
        /// 막대가 끝내 안 펼쳐졌을 때 쓸 자리: 접힌 데스크탑 이름(화면 위 바깥으로 나온다)과 화면 안 막대 영역
        var collapsedThumbnail: AXUIElement?
        var collapsedFrame: CGRect?
        for _ in 0..<thumbnailLookupAttempts {
            Thread.sleep(forTimeInterval: thumbnailLookupInterval)
            guard let group = MissionControl.displayGroup(in: dock, for: display) else { continue }
            let thumbnails = MissionControl.spaceThumbnails(in: group)
            thumbnailPlaces = thumbnails.map { element in
                WindowInventory.frame(of: element).map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-"
            }
            guard thumbnails.indices.contains(targetIndex),
                  let found = WindowInventory.frame(of: thumbnails[targetIndex]) else { continue }
            if display.contains(CGPoint(x: found.midX, y: found.midY)) {
                thumbnail = thumbnails[targetIndex]
                thumbnailFrame = found
                break
            }
            collapsedThumbnail = thumbnails[targetIndex]
            collapsedFrame = found
            if expandTries < maxExpandTries {
                let x = min(max(found.midX + CGFloat(expandTries) * expandNudge, display.minX + 10), display.maxX - 10)
                expandTries += 1
                drag(from: &point, to: CGPoint(x: x, y: display.minY + expandEdgeOffset))
                Thread.sleep(forTimeInterval: expandDelay)
            }
        }
        // 끝내 안 펼쳐졌으면: 화면 안에 있는 데스크탑 막대(mc.spaces) 영역 중 그 데스크탑 이름의 x 자리에 놓는다
        var dropOnCollapsedBar = false
        if thumbnail == nil, let collapsedThumbnail, let collapsedFrame,
           let group = MissionControl.displayGroup(in: dock, for: display),
           let bar = MissionControl.descendants(of: group, identifier: "mc.spaces").first.flatMap({ WindowInventory.frame(of: $0) }),
           display.contains(CGPoint(x: collapsedFrame.midX, y: bar.midY)) {
            thumbnail = collapsedThumbnail
            thumbnailFrame = CGRect(x: collapsedFrame.minX, y: bar.minY, width: collapsedFrame.width, height: bar.height)
            dropOnCollapsedBar = true
        }
        guard let thumbnail, let thumbnailFrame else {
            let structure = MissionControl.displayGroup(in: dock, for: display)
                .map { MissionControl.structureSummary(of: $0) } ?? "모니터 묶음 없음"
            try? MouseActionService.leftButton(down: false, at: point)
            MissionControl.close()
            PointerMover.move(to: original)
            return .thumbnailNotFound(
                note: "데스크탑 썸네일 [\(thumbnailPlaces.joined(separator: " "))], 넣을 순서 \(targetIndex), "
                    + "펼침 \(expandTries)번, 구조 \(structure)"
            )
        }

        // 그 데스크탑 썸네일까지 끌고 가서 잠깐 머문 뒤 놓는다
        drag(from: &point, to: CGPoint(x: thumbnailFrame.midX, y: thumbnailFrame.midY))
        // 접힌 막대에 놓을 때는 그 자리에 더 오래 머문다 (막대가 펼쳐지거나 넣을 곳으로 알아차리게)
        Thread.sleep(forTimeInterval: dropOnCollapsedBar ? collapsedHoverDelay : hoverDelay)
        try? MouseActionService.leftButton(down: false, at: point)
        Thread.sleep(forTimeInterval: afterDropDelay)
        // 그 데스크탑으로 넘어간다 (썸네일을 누르면 Mission Control도 닫힌다). 안 되면 닫기만.
        let pressed = AXUIElementPerformAction(thumbnail, kAXPressAction as CFString) == .success
        if !pressed { MissionControl.close() }
        PointerMover.move(to: original)

        // 단계별 확인: 데스크탑이 목표로 넘어갔는지, 창이 그 화면에 있는지
        Thread.sleep(forTimeInterval: verifyDelay)
        let after = SpaceService.spaces(onDisplayContaining: center)
        let switched = after?.currentIndex == targetIndex
        let carried = windowID.map { onScreenWindowIDs().contains($0) } ?? true
        let steps = "썸네일 \(Int(thumbnailFrame.midX)),\(Int(thumbnailFrame.midY)) (펼침 \(expandTries)번"
            + (dropOnCollapsedBar ? ", 접힌 막대에 놓음), " : "), ")
            + ""
            + "누르기 \(pressed ? "됨" : "안 됨"), 데스크탑 \(spaces.currentIndex)→\(after?.currentIndex ?? -1) (목표 \(targetIndex))"
        if !switched { return .notSwitched(note: steps) }
        if !carried { return .notCarried(note: steps) }

        if !spacesKnown { return .movedWithoutSpaceInfo }
        return createNote.map { .createdAndMoved(note: $0) } ?? .moved
    }
}
