import AppKit
import Combine
import WheelSpaceCore

/// 창 포커스 이동: 단축키 → 직렬 명령 처리 → 스냅샷 → 방향 선택 → 활성화·확인.
/// 창 제목·앱 목록은 메모리에서만 쓰고 기록하지 않는다.
@MainActor
final class FocusCoordinator: ObservableObject {
    enum Status: Equatable {
        case needsPermission
        case ready
        case paused
        case moving
    }

    /// 한 명령의 결과 (진단·짧은 안내용)
    enum Outcome: Equatable {
        case moved
        case noCandidate
        case noFocusedWindow
        case focusedWindowIsModal
        case budgetExceeded
        case targetGone
        case activationFailed
        case notVerified
    }

    @Published private(set) var settings: FocusSettings
    @Published private(set) var status: Status = .paused
    @Published private(set) var shortcutErrors: [FocusDirection: String] = [:]
    /// 마지막 결과 문구 (설정 창 표시용)
    @Published private(set) var lastResult: String?

    private let store: SettingsStore
    private let diagnostics: Diagnostics
    private let shortcuts = GlobalShortcutService<FocusDirection>(signature: 0x5753_4643) { direction in // "WSFC"
        switch direction {
        case .left: return 1
        case .right: return 2
        case .up: return 3
        case .down: return 4
        }
    }
    private var shortcutsSuspended = false
    private var queue = FocusCommandQueue()
    private var isProcessing = false
    /// 연속 입력의 기준 창: 직전에 앞으로 가져온 창 (포커스 확인 전이라도 다음 이동의 출발점)
    /// 확인이 끝나고 대기 명령이 없으면 비운다 — 새로 누를 때는 실제 포커스에서 출발한다.
    private var chainedFocus: (window: AXUIElement, pid: Int32)?
    /// 확인을 기다리는 활성화 수 (확인 실패 시 남은 연속 입력을 버리는 데 쓴다)
    private var pendingVerifications = 0
    /// 이 앱이 일으킨 앱 활성화(PID → 시각). 활성화 알림이 늦게 와도 사용자 전환으로 오인하지 않게 1초간 기억한다.
    private var ownActivations: [Int32: TimeInterval] = [:]
    private static let ownActivationMemory: TimeInterval = 1
    private var observers: [NSObjectProtocol] = []
    /// 창 목록 전환기 (창 포커스 이동이 켜져 있고 권한이 있을 때만 동작)
    private lazy var switcher = WindowSwitcherController(diagnostics: diagnostics)

    // MARK: 창을 다른 모니터로 보내기
    private let moveShortcuts = GlobalShortcutService<FocusDirection>(signature: 0x5753_4D56) { direction in // "WSMV"
        switch direction {
        case .left: return 1
        case .right: return 2
        case .up: return 3
        case .down: return 4
        }
    }
    @Published private(set) var moveShortcutErrors: [FocusDirection: String] = [:]
    /// 옮기는 중 (그 사이 누른 입력은 버린다 — 창 하나를 여러 모니터로 연달아 보내는 일은 드물다)
    private var isMovingWindow = false

    // MARK: 창을 옆 데스크탑으로 보내기
    private let spaceShortcuts = GlobalShortcutService<SpaceDirection>(signature: 0x5753_5350) { direction in // "WSSP"
        direction == .left ? 1 : 2
    }
    @Published private(set) var spaceShortcutErrors: [SpaceDirection: String] = [:]
    private var isMovingToSpace = false
    /// 새 데스크탑 만들기 (지금 창의 모니터)
    private let createSpaceShortcuts = GlobalShortcutService<CreateSpaceCommand>(signature: 0x5753_4E53) { _ in 1 } // "WSNS"
    @Published private(set) var createSpaceShortcutError: String?

    // MARK: 겹친 창 넘기기
    private let stackShortcuts = GlobalShortcutService<StackDirection>(signature: 0x5753_5354) { direction in // "WSST"
        direction == .next ? 1 : 2
    }
    @Published private(set) var stackShortcutErrors: [StackDirection: String] = [:]
    /// 고정한 넘기기 순서와 지금 자리 (0번 = 시작할 때의 지금 창)
    private var stackSession: StackCycleSession?
    private var stackEntries: [(window: AXUIElement, pid: Int32)] = []
    /// 순서를 만드는 중 (그동안 들어온 입력은 모았다가 한꺼번에 적용)
    private var stackBuilding = false
    private var pendingStackSteps: [StackDirection] = []

    init(store: SettingsStore, diagnostics: Diagnostics) {
        self.store = store
        self.diagnostics = diagnostics
        self.settings = store.loadFocus()
    }

    func start() {
        shortcuts.onTrigger = { [weak self] direction in
            self?.request(direction)
        }
        stackShortcuts.onTrigger = { [weak self] direction in
            self?.requestStack(direction)
        }
        moveShortcuts.onTrigger = { [weak self] direction in
            self?.requestMoveWindow(direction)
        }
        spaceShortcuts.onTrigger = { [weak self] direction in
            self?.requestMoveToSpace(direction)
        }
        createSpaceShortcuts.onTrigger = { [weak self] _ in
            self?.requestCreateSpace()
        }
        // 전환기가 일으킨 앱 활성화도 사용자 전환으로 오인하지 않게
        switcher.onOwnActivation = { [weak self] pid in
            self?.ownActivations[pid] = ProcessInfo.processInfo.systemUptime
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, let pid, !self.isOwnActivation(pid) else { return }
                self.cancelPending(reason: "사용자 앱 전환")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelPending(reason: "모니터 변경") }
        })
        reconcile()
    }

    func stop() {
        shortcuts.unregisterAll()
        stackShortcuts.unregisterAll()
        moveShortcuts.unregisterAll()
        spaceShortcuts.unregisterAll()
        createSpaceShortcuts.unregisterAll()
        switcher.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        cancelPending(reason: "종료")
    }

    func update(settings newValue: FocusSettings) {
        let value = newValue.validated()
        store.saveFocus(value)
        settings = value
        reconcile()
    }

    /// 권한 변경·잠금 해제 등에서 AppController가 호출.
    func reconcile() {
        if !settings.isEnabled {
            switcher.stop()
            shortcuts.unregisterAll()
            stackShortcuts.unregisterAll()
            moveShortcuts.unregisterAll()
            spaceShortcuts.unregisterAll()
            createSpaceShortcuts.unregisterAll()
            shortcutErrors = [:]
            status = .paused
            cancelPending(reason: "꺼짐")
        } else if !AXIsProcessTrusted() {
            switcher.stop()
            shortcuts.unregisterAll()
            stackShortcuts.unregisterAll()
            moveShortcuts.unregisterAll()
            spaceShortcuts.unregisterAll()
            createSpaceShortcuts.unregisterAll()
            status = .needsPermission
            cancelPending(reason: "권한 없음")
        } else {
            if shortcutsSuspended {
                // 단축키를 기록하는 동안에는 전환기도 키를 가로채지 않는다
                switcher.stop()
                shortcuts.unregisterAll()
                stackShortcuts.unregisterAll()
                moveShortcuts.unregisterAll()
                spaceShortcuts.unregisterAll()
                createSpaceShortcuts.unregisterAll()
            } else {
                switcher.apply(trigger: settings.switcherShortcut, requiresHeldKey: settings.switcherRequiresHeldKey)
                applyShortcuts()
                applyStackShortcuts()
                applyMoveShortcuts()
                applySpaceShortcuts()
                applyCreateSpaceShortcut()
            }
            if status != .moving { status = .ready }
        }
    }

    func setShortcutsSuspended(_ suspended: Bool) {
        guard suspended != shortcutsSuspended else { return }
        shortcutsSuspended = suspended
        reconcile()
    }

    /// 잠금·잠자기·권한 회수·모니터 변경 시 대기 명령 폐기.
    func cancelPending(reason: String) {
        // 사용자 앱 전환·모니터 변경·잠금 뒤에는 실제 포커스에서 다시 출발한다
        chainedFocus = nil
        endStackSession()
        // 잠금·모니터 변경·사용자 앱 전환 때 열린 목록도 닫는다
        switcher.cancel()
        guard !queue.isEmpty else { return }
        queue.removeAll()
        diagnostics.record("창 포커스 대기 명령 폐기: \(reason)")
    }

    /// 단축키 진입점. 처리 중이면 큐(최대 4개·500ms)에 넣는다.
    func request(_ direction: FocusDirection) {
        guard status == .ready || status == .moving else { return }
        if isProcessing {
            queue.enqueue(direction, at: ProcessInfo.processInfo.systemUptime)
            return
        }
        process(direction)
    }

    private func process(_ direction: FocusDirection) {
        // 방향 이동으로 포커스가 바뀌면 겹친 창 넘기기 순서는 처음부터
        endStackSession()
        isProcessing = true
        status = .moving
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let started = ProcessInfo.processInfo.systemUptime
        let frontmost = NSWorkspace.shared.frontmostApplication
        // 연속 입력이면 확인 전이라도 직전에 가져온 창이 출발점 (전면 앱 정보가 아직 바뀌지 않았을 수 있다)
        let assumed = chainedFocus
        guard let frontmostPID = assumed?.pid ?? frontmost?.processIdentifier else {
            return finish(.noFocusedWindow)
        }
        let frontmostName = frontmost?.bundleIdentifier ?? "알 수 없음"

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                WindowInventory.snapshot(excludingPID: ownPID, frontmostPID: frontmostPID, assumedFocus: assumed?.window)
            }.value
            guard let self else { return }
            let snapshotMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)

            let snapshot: WindowSnapshot
            switch result {
            case .failure(.noFocusedWindow(let axError)):
                // 창 제목·내용 없이 앱 식별자와 AX 오류 코드만 남긴다
                diagnostics.record("창 포커스: 현재 창 조회 실패 — 앱 \(frontmostName), AX 오류 \(axError)")
                return finish(.noFocusedWindow)
            case .failure(.focusedWindowIsModal): return finish(.focusedWindowIsModal)
            case .failure(.budgetExceeded): return finish(.budgetExceeded)
            case .success(let value): snapshot = value
            }
            guard let focused = snapshot.focused else { return finish(.noFocusedWindow) }

            let byID = Dictionary(uniqueKeysWithValues: snapshot.candidates.map { (Int($0.record.windowID), $0) })
            let candidates = snapshot.candidates.map {
                FocusCandidate(id: Int($0.record.windowID), frame: $0.visibleFrame, zIndex: $0.zIndex)
            }
            let fromDisplay = PointerMover.displayIndex(of: focused.visibleFrame, in: snapshot.displays)
            if snapshot.focusIsFallback {
                diagnostics.record("창 포커스: 전면 앱(\(frontmostName))에 창이 없어 화면 맨 앞 창을 기준으로 이동")
            }
            let chosenTarget = DirectionalSelector.select(from: focused.visibleFrame, candidates: candidates, direction: direction)
                .flatMap { byID[$0.id] }
            // 기준이 맨 앞 창(실제 포커스 아님)인데 그 방향에 창이 없으면 기준 창 자체에 포커스를 준다
            guard let target = chosenTarget ?? (snapshot.focusIsFallback ? focused : nil), let window = target.axWindow else {
                // 창 제목 없이 개수만: 후보가 아예 없는지, 다른 모니터 후보가 있는데 방향에서 빠졌는지 구분용
                let otherDisplay = snapshot.candidates.filter {
                    PointerMover.displayIndex(of: $0.visibleFrame, in: snapshot.displays) != fromDisplay
                }.count
                diagnostics.record("창 포커스 \(direction.rawValue): 후보 없음 — 전체 \(candidates.count)개, 다른 모니터 \(otherDisplay)개, 모니터 \(snapshot.displays.count)대")
                return finish(.noCandidate)
            }
            let toDisplay = PointerMover.displayIndex(of: target.visibleFrame, in: snapshot.displays)
            let overlapsCurrent = target.visibleFrame.intersects(focused.visibleFrame)

            ownActivations[target.record.pid] = ProcessInfo.processInfo.systemUptime
            let activationStarted = ProcessInfo.processInfo.systemUptime
            let outcome: Outcome
            // 앞으로 가져오기만 하고 확인은 따로 한다 — 연속 입력이 확인(수십 ms)을 기다리지 않게
            switch WindowActivator.activate(window, pid: target.record.pid) {
            case .success:
                outcome = .moved
                chainedFocus = (window, target.record.pid)
                verifyInBackground(
                    window: window, pid: target.record.pid, direction: direction,
                    // 포인터는 포커스 확인에 성공했고 다른 모니터로 옮겼을 때만 옮긴다
                    pointerTarget: settings.pointerFollow != .off && fromDisplay != toDisplay
                        ? PointerMover.target(in: target.visibleFrame, exposed: target.exposedRegions) : nil
                )
            case .failure(.targetGone): outcome = .targetGone
            case .failure(.activationFailed): outcome = .activationFailed
            case .failure(.notVerified): outcome = .notVerified
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = Int((now - started) * 1_000)
            let activationMs = Int((now - activationStarted) * 1_000)
            let displayNote = fromDisplay == toDisplay ? "같은 모니터" : "다른 모니터"
            // 단계별 시간: 수집(앱 수·가장 느린 앱·현재 창 조회) / 활성화·확인. 앱은 번들 ID만, 창 제목은 남기지 않는다.
            let timing = snapshot.timing
            let slowest = timing.slowestPID.map { pid in
                "\(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)") \(timing.slowestMs)ms"
            } ?? "없음"
            diagnostics.record(
                "창 포커스 \(direction.rawValue): \(outcome), 후보 \(candidates.count)개, \(displayNote)\(overlapsCurrent ? "·현재 창과 겹침" : ""), \(elapsed)ms"
                    + " [수집 \(snapshotMs)ms: 앱 \(timing.appCount)개 \(timing.appQueryMs)ms, 가장 느린 앱 \(slowest), 현재 창 \(timing.focusedLookupMs)ms"
                    + " / 활성화 \(activationMs)ms\(assumed == nil ? "" : ", 연속")]"
            )
            finish(outcome)
        }
    }

    /// 활성화한 창의 포커스를 뒤에서 확인한다. 실패하면 남은 연속 입력을 버리고 알린다.
    private func verifyInBackground(window: AXUIElement, pid: Int32, direction: FocusDirection, pointerTarget: CGPoint?) {
        pendingVerifications += 1
        let started = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let result = await WindowActivator.verify(window, pid: pid)
            guard let self else { return }
            pendingVerifications -= 1
            switch result {
            case .success:
                if let pointerTarget { PointerMover.move(to: pointerTarget) }
            case .failure(let failure):
                let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                diagnostics.record("창 포커스 \(direction.rawValue): 확인 실패(\(failure)), \(ms)ms — 남은 연속 입력 \(queue.isEmpty ? "없음" : "버림")")
                queue.removeAll()
                chainedFocus = nil
                lastResult = Self.message(for: .notVerified)
                FeedbackHUD.show(Self.message(for: .notVerified), isError: true)
            }
            // 확인이 다 끝났고 이어질 입력이 없으면, 다음 입력은 실제 포커스에서 출발한다
            if pendingVerifications == 0, queue.isEmpty, !isProcessing {
                chainedFocus = nil
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        isProcessing = false
        if status == .moving { status = .ready }
        lastResult = Self.message(for: outcome)
        if outcome != .moved && outcome != .noCandidate {
            diagnostics.record("창 포커스 이동 실패: \(outcome)")
        }

        guard outcome == .moved else {
            // 실패 뒤 오래된 명령을 이어서 실행하지 않는다. 후보 없음은 포커스를 유지하고 짧게 알린다.
            queue.removeAll()
            if pendingVerifications == 0 { chainedFocus = nil }
            FeedbackHUD.show(Self.message(for: outcome), isError: outcome != .noCandidate)
            return
        }
        // 다음 명령은 방금 가져온 창(chainedFocus)을 기준으로 새 스냅샷을 찍어 계산한다 — 확인을 기다리지 않는다
        if status == .ready, let next = queue.next(now: ProcessInfo.processInfo.systemUptime) {
            process(next)
        } else if pendingVerifications == 0 {
            chainedFocus = nil
        }
    }

    private func isOwnActivation(_ pid: Int32) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        ownActivations = ownActivations.filter { now - $0.value <= Self.ownActivationMemory }
        return ownActivations[pid] != nil
    }

    // MARK: - 창을 다른 모니터로 보내기

    /// 단축키 진입점: 지금 창을 그 방향의 모니터로 (위치·비율 그대로)
    func requestMoveWindow(_ direction: FocusDirection) {
        guard status == .ready || status == .moving, !isMovingWindow,
              let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        isMovingWindow = true
        // 창이 바뀌면 겹친 창 넘기기 순서는 처음부터
        endStackSession()
        let started = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let outcome = await WindowMover.move(direction: direction, frontmostPID: frontmost.processIdentifier)
            guard let self else { return }
            isMovingWindow = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            // 앱 번들 ID와 결과만 (창 제목 없음)
            diagnostics.record(
                "다른 모니터로 보내기 \(direction.rawValue) (\(frontmost.bundleIdentifier ?? "알 수 없는 앱")): \(outcome.diagnosticName), \(elapsed)ms"
            )
            switch outcome {
            case .moved(_, _, let frame):
                // 포인터 따라가기를 켜 두었으면 포인터도 그 창으로
                if settings.pointerFollow != .off {
                    PointerMover.move(to: CGPoint(x: frame.midX, y: frame.midY))
                }
            case .noFocusedWindow: FeedbackHUD.show("현재 창을 찾지 못했어요", isError: true)
            case .fullScreen: FeedbackHUD.show("전체 화면 창은 옮길 수 없어요", isError: true)
            case .noDisplay: FeedbackHUD.show("그 방향에 모니터가 없어요")
            case .notMovable: FeedbackHUD.show("이 창은 옮길 수 없어요", isError: true)
            }
        }
    }

    private func applyMoveShortcuts() {
        var combos: [FocusDirection: KeyCombo] = [:]
        for direction in FocusDirection.allCases {
            combos[direction] = settings.moveShortcut(for: direction)
        }
        let failures = moveShortcuts.register(combos)
        moveShortcutErrors = failures.mapValues { error in
            switch error {
            case .duplicate: return "다른 방향과 같은 조합이에요"
            case .systemRejected: return "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요"
            }
        }
        for (direction, error) in failures {
            diagnostics.record("다른 모니터로 보내기 단축키 등록 실패: \(direction.rawValue) \(combos[direction]?.displayString ?? "") \(error)")
        }
    }

    // MARK: - 창을 옆 데스크탑으로 보내기

    /// 단축키 진입점: 지금 창을 같은 모니터의 왼쪽·오른쪽 데스크탑으로 (화면도 함께 넘어간다)
    func requestMoveToSpace(_ direction: SpaceDirection) {
        guard status == .ready || status == .moving, !isMovingToSpace,
              let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        isMovingToSpace = true
        // 창이 다른 데스크탑으로 가면 겹친 창 넘기기 순서는 처음부터
        endStackSession()
        let started = ProcessInfo.processInfo.systemUptime
        let createIfMissing = settings.createSpaceIfMissing
        Task { [weak self] in
            let outcome = await WindowSpaceMover.move(
                direction: direction, frontmostPID: frontmost.processIdentifier, createIfMissing: createIfMissing
            )
            guard let self else { return }
            isMovingToSpace = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            diagnostics.record(
                "옆 데스크탑으로 보내기 \(direction.rawValue) (\(frontmost.bundleIdentifier ?? "알 수 없는 앱")): \(outcome), \(elapsed)ms"
            )
            showSpaceFailure(outcome)
        }
    }

    /// 단축키 진입점: 지금 창이 있는 모니터에 새 데스크탑을 만든다 (넘어가지는 않는다)
    func requestCreateSpace() {
        guard status == .ready || status == .moving, !isMovingToSpace else {
            diagnostics.record("새 데스크탑 만들기: 건너뜀 — 상태 \(status), 진행 중 \(isMovingToSpace)")
            return
        }
        isMovingToSpace = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        let started = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let outcome = await WindowSpaceMover.createSpace(frontmostPID: frontmost?.processIdentifier)
            guard let self else { return }
            isMovingToSpace = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            diagnostics.record("새 데스크탑 만들기: \(outcome), \(elapsed)ms")
            if case .created = outcome {
                FeedbackHUD.show("새 데스크탑을 만들었어요")
            } else {
                showSpaceFailure(outcome)
            }
        }
    }

    /// 데스크탑 보내기·넘기기 실패 안내 (성공이면 아무것도 하지 않는다)
    private func showSpaceFailure(_ outcome: WindowSpaceMover.Outcome) {
        switch outcome {
        case .moved, .created, .createdAndMoved: break
        case .noFocusedWindow: FeedbackHUD.show("현재 창을 찾지 못했어요", isError: true)
        case .fullScreen: FeedbackHUD.show("전체 화면 창은 옮길 수 없어요", isError: true)
        case .noSpace: FeedbackHUD.show("그쪽에 데스크탑이 없어요")
        case .noSpaceAtStart: FeedbackHUD.show("맨 앞에는 데스크탑을 만들 수 없어요")
        case .targetIsFullScreen: FeedbackHUD.show("전체 화면 앱 쪽으로는 옮길 수 없어요")
        case .spacesUnavailable: FeedbackHUD.show("데스크탑 목록을 읽지 못했어요", isError: true)
        case .createFailed: FeedbackHUD.show("데스크탑을 만들지 못했어요", isError: true)
        case .bridgeUnavailable: FeedbackHUD.show("이 macOS에서는 창을 데스크탑으로 옮길 수 없어요", isError: true)
        case .notMoved: FeedbackHUD.show("창을 옆 데스크탑으로 옮기지 못했어요", isError: true)
        case .notSwitched: FeedbackHUD.show("창은 옮겼지만 화면이 넘어가지 않았어요", isError: true)
        }
    }

    private func applyCreateSpaceShortcut() {
        var combos: [CreateSpaceCommand: KeyCombo] = [:]
        combos[.create] = settings.createSpaceShortcut
        let failures = createSpaceShortcuts.register(combos)
        createSpaceShortcutError = failures[.create].map { _ in "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요" }
        if let error = failures[.create] {
            diagnostics.record("새 데스크탑 만들기 단축키 등록 실패: \(settings.createSpaceShortcut?.displayString ?? "") \(error)")
        }
    }

    private func applySpaceShortcuts() {
        var combos: [SpaceDirection: KeyCombo] = [:]
        for direction in SpaceDirection.allCases {
            combos[direction] = settings.spaceShortcut(for: direction)
        }
        let failures = spaceShortcuts.register(combos)
        spaceShortcutErrors = failures.mapValues { error in
            switch error {
            case .duplicate: return "다른 방향과 같은 조합이에요"
            case .systemRejected: return "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요"
            }
        }
        for (direction, error) in failures {
            diagnostics.record("옆 데스크탑으로 보내기 단축키 등록 실패: \(direction.rawValue) \(combos[direction]?.displayString ?? "") \(error)")
        }
    }

    // MARK: - 겹친 창 넘기기

    /// 단축키 진입점: 이어진 입력(1.5초 이내)은 고정한 순서에서 한 칸, 아니면 지금 모니터의 순서를 새로 만든다
    func requestStack(_ direction: StackDirection) {
        guard status == .ready || status == .moving else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let session = stackSession, session.isActive(now: now) {
            return stepStack([direction], now: now)
        }
        pendingStackSteps.append(direction)
        guard !stackBuilding else { return }
        buildStackSession()
    }

    /// 지금 창의 모니터에 있는 창(가려진 창 포함)으로 순서를 만든다: 지금 창과 겹친 창 먼저, 그다음 나머지 (앞에서 뒤)
    private func buildStackSession() {
        endStackSession()
        stackBuilding = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return failStackBuild("현재 창을 찾지 못했어요", isError: true)
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                WindowInventory.snapshot(excludingPID: ownPID, frontmostPID: frontmostPID, includeHidden: true)
            }.value
            guard let self else { return }
            guard case .success(let snapshot) = result, let focused = snapshot.focused, let focusedWindow = focused.axWindow else {
                return failStackBuild("현재 창을 찾지 못했어요", isError: true)
            }
            let display = PointerMover.displayIndex(of: focused.visibleFrame, in: snapshot.displays)
            let sameDisplay = snapshot.candidates.filter {
                $0.axWindow != nil && PointerMover.displayIndex(of: $0.visibleFrame, in: snapshot.displays) == display
            }
            let byID = Dictionary(uniqueKeysWithValues: sameDisplay.map { (Int($0.record.windowID), $0) })
            let order = StackOrder.order(
                current: focused.visibleFrame,
                candidates: sameDisplay.map { StackCandidate(id: Int($0.record.windowID), frame: $0.visibleFrame, zIndex: $0.zIndex) }
            )
            let entries = [(focusedWindow, focused.record.pid)] + order.compactMap { id in
                byID[id].flatMap { entry in entry.axWindow.map { ($0, entry.record.pid) } }
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard let session = StackCycleSession(count: entries.count, startedAt: now) else {
                return failStackBuild("이 모니터에 겹친 다른 창이 없어요", isError: false)
            }
            stackEntries = entries
            stackSession = session
            stackBuilding = false
            let steps = pendingStackSteps
            pendingStackSteps = []
            // 창 제목 없이 개수만
            let overlapping = sameDisplay.filter { $0.visibleFrame.intersects(focused.visibleFrame) }.count
            diagnostics.record("겹친 창 넘기기: 창 \(entries.count)개 (지금 창과 겹침 \(overlapping)개)")
            stepStack(steps, now: now)
        }
    }

    private func failStackBuild(_ message: String, isError: Bool) {
        stackBuilding = false
        pendingStackSteps = []
        FeedbackHUD.show(message, isError: isError)
    }

    /// 칸을 옮기고 마지막 자리의 창만 앞으로 가져온다 (모아 둔 입력은 한꺼번에)
    private func stepStack(_ steps: [StackDirection], now: TimeInterval) {
        guard var session = stackSession, !steps.isEmpty else { return }
        var index = session.index
        for step in steps { index = session.step(step, now: now) }
        stackSession = session
        let entry = stackEntries[index]
        ownActivations[entry.pid] = now
        guard case .success = WindowActivator.activate(entry.window, pid: entry.pid) else {
            endStackSession()
            FeedbackHUD.show(Self.message(for: .activationFailed), isError: true)
            return
        }
        // 포커스 확인은 뒤에서. 실패하면 이 순서는 버린다 (창이 닫혔거나 앱이 거부)
        Task { [weak self] in
            guard case .failure(let failure) = await WindowActivator.verify(entry.window, pid: entry.pid) else { return }
            guard let self else { return }
            diagnostics.record("겹친 창 넘기기 확인 실패: \(failure)")
            endStackSession()
            FeedbackHUD.show(Self.message(for: .notVerified), isError: true)
        }
    }

    private func endStackSession() {
        stackSession = nil
        stackEntries = []
    }

    private func applyStackShortcuts() {
        var combos: [StackDirection: KeyCombo] = [:]
        combos[.next] = settings.stackNextShortcut
        combos[.previous] = settings.stackPreviousShortcut
        let failures = stackShortcuts.register(combos)
        stackShortcutErrors = failures.mapValues { error in
            switch error {
            case .duplicate: return "뒤로·앞으로가 같은 조합이에요"
            case .systemRejected: return "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요"
            }
        }
        for (direction, error) in failures {
            diagnostics.record("겹친 창 넘기기 단축키 등록 실패: \(direction.rawValue) \(combos[direction]?.displayString ?? "") \(error)")
        }
    }

    private func applyShortcuts() {
        var combos: [FocusDirection: KeyCombo] = [:]
        for direction in FocusDirection.allCases {
            combos[direction] = settings.shortcut(for: direction)
        }
        let failures = shortcuts.register(combos)
        shortcutErrors = failures.mapValues { error in
            switch error {
            case .duplicate: return "다른 방향과 같은 조합이에요"
            case .systemRejected: return "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요"
            }
        }
        for (direction, error) in failures {
            diagnostics.record("창 포커스 단축키 등록 실패: \(direction.rawValue) \(combos[direction]?.displayString ?? "") \(error)")
        }
    }

    var stateDescription: String {
        switch status {
        case .needsPermission: return "권한 필요"
        case .ready: return "사용 중"
        case .paused: return "꺼짐"
        case .moving: return "이동 중"
        }
    }

    var diagnosticsLines: [String] {
        var lines = ["창 포커스 이동: \(stateDescription)"]
        for direction in FocusDirection.allCases {
            let combo = settings.shortcut(for: direction)?.displayString ?? "없음"
            let status = shortcutErrors[direction].map { "실패(\($0))" } ?? "정상"
            lines.append("  \(direction.rawValue) 단축키: \(combo) — \(status)")
        }
        for direction in FocusDirection.allCases {
            let combo = settings.moveShortcut(for: direction)?.displayString ?? "없음"
            let status = moveShortcutErrors[direction].map { "실패(\($0))" } ?? "정상"
            lines.append("  다른 모니터로 \(direction.rawValue) 단축키: \(combo) — \(status)")
        }
        for direction in SpaceDirection.allCases {
            let combo = settings.spaceShortcut(for: direction)?.displayString ?? "없음"
            let status = spaceShortcutErrors[direction].map { "실패(\($0))" } ?? "정상"
            lines.append("  옆 데스크탑으로 \(direction.rawValue) 단축키: \(combo) — \(status)")
        }
        lines.append(
            "  새 데스크탑 만들기 단축키: \(settings.createSpaceShortcut?.displayString ?? "없음") — "
                + (createSpaceShortcutError.map { "실패(\($0))" } ?? "정상")
        )
        lines.append("  데스크탑이 없으면 만들기: \(settings.createSpaceIfMissing ? "켜짐" : "꺼짐")")
        for direction in StackDirection.allCases {
            let combo = (direction == .next ? settings.stackNextShortcut : settings.stackPreviousShortcut)?.displayString ?? "없음"
            let status = stackShortcutErrors[direction].map { "실패(\($0))" } ?? "정상"
            lines.append("  겹친 창 \(direction == .next ? "뒤로" : "앞으로") 단축키: \(combo) — \(status)")
        }
        return lines
    }

    static func message(for outcome: Outcome) -> String {
        switch outcome {
        case .moved: return "이동했어요"
        case .noCandidate: return "그 방향에 창이 없어요"
        case .noFocusedWindow: return "현재 창을 찾지 못했어요"
        case .focusedWindowIsModal: return "대화상자가 떠 있어 이동하지 않았어요"
        case .budgetExceeded: return "창이 너무 많아 계산을 멈췄어요"
        case .targetGone: return "대상 창이 닫혔어요"
        case .activationFailed, .notVerified: return "이 창으로 포커스를 옮기지 못했어요"
        }
    }
}

private extension WindowMover.Outcome {
    /// 진단 기록용 (좌표 없이)
    var diagnosticName: String {
        switch self {
        // 크기만 남긴다 (자리 좌표·창 제목 없음) — 계획과 결과가 다르면 앱이 크기를 제한한 것
        case .moved(let before, let planned, let result):
            func size(_ rect: CGRect) -> String { "\(Int(rect.width))×\(Int(rect.height))" }
            return "옮김 (크기 \(size(before)) → 계획 \(size(planned)) → 결과 \(size(result)))"
        case .noFocusedWindow: return "현재 창 없음"
        case .fullScreen: return "전체 화면"
        case .noDisplay: return "그 방향에 모니터 없음"
        case .notMovable: return "위치 바꾸기 거부"
        }
    }
}

/// 새 데스크탑 만들기 단축키 (하나뿐이지만 GlobalShortcutService가 동작 종류를 키로 쓴다)
enum CreateSpaceCommand: Hashable, CaseIterable {
    case create
}
