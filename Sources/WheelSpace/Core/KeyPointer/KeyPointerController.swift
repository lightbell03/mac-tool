import AppKit
import Combine
import WheelSpaceCore

/// 키보드 포인터 기능의 메인 스레드 쪽: 설정·상태·권한·수명.
@MainActor
final class KeyPointerController: ObservableObject {
    enum Status: Equatable {
        case paused
        case needsPermission
        case running
        case tapError
    }

    @Published private(set) var settings: KeyPointerSettings
    @Published private(set) var status: Status = .paused
    @Published private(set) var isDragging = false
    /// 고정 모드 (메뉴 막대 아이콘이 바뀐다)
    @Published private(set) var isLocked = false
    /// 앱 단축키로 잠깐 해제된 상태 (메뉴 막대 아이콘은 포인터 모드 그대로)
    @Published private(set) var isSuspended = false
    /// 왼손 모드 (⌥⇧⇥ 두 번으로 켠 포인터 모드)
    @Published private(set) var isLeftHandMode = false
    /// 마지막으로 입력란 클릭 때문에 해제된 요소 (메뉴의 "방금 해제 취소하고 제외"에 쓴다)
    @Published private(set) var lastAutoUnlock: FocusSignature?

    private let store: SettingsStore
    private let diagnostics: Diagnostics
    private let engine: KeyPointerEngine
    private var observers: [NSObjectProtocol] = []
    /// 포인터 모드인 동안만 거는 실제 마우스 클릭 감시 (NSEvent 전역 모니터)
    private var mouseClickMonitor: Any?

    init(store: SettingsStore, diagnostics: Diagnostics) {
        self.store = store
        self.diagnostics = diagnostics
        let loaded = store.loadKeyPointer()
        self.settings = loaded
        self.engine = KeyPointerEngine(settings: loaded)
    }

    func start() {
        engine.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                // 왼손 모드에서 드래그(V 토글)를 켜고 끄면 토스트에 상태를 보여 준다
                if status.isDragging != self.isDragging, status.isLocked, status.isLeftHandMode,
                   status.isLocked == self.isLocked, status.isLeftHandMode == self.isLeftHandMode {
                    PointerModeIndicator.show(
                        insertKeyLabel: self.settings.shortcut.insertKey.keyLabel, opacity: self.settings.toastOpacity,
                        leftHand: true, dragging: status.isDragging
                    )
                }
                self.isDragging = status.isDragging
                guard status.isLocked != self.isLocked || status.isSuspended != self.isSuspended
                    || status.isLeftHandMode != self.isLeftHandMode else { return }
                // 잠깐 해제에서 돌아옴인지, 새로 켬인지 (포인터를 포커스된 곳으로 옮길지 정한다)
                let wasSuspended = self.isSuspended
                if status.isLocked, !self.isLocked {
                    let moves = wasSuspended ? self.settings.moveToFocusOnResume : self.settings.moveToFocusOnLock
                    if moves { self.movePointerToFocus(resumed: wasSuspended) }
                }
                self.isLocked = status.isLocked
                self.isSuspended = status.isSuspended
                self.isLeftHandMode = status.isLeftHandMode
                self.updateClickMonitor()
                if status.isLocked {
                    PointerModeIndicator.show(
                        insertKeyLabel: self.settings.shortcut.insertKey.keyLabel, opacity: self.settings.toastOpacity,
                        leftHand: status.isLeftHandMode
                    )
                } else if status.isSuspended {
                    PointerModeIndicator.showSuspended(
                        detail: status.suspendsWhileHeld ? "보조키를 떼면 돌아옴" : "↩·Esc로 돌아옴",
                        opacity: self.settings.toastOpacity
                    )
                } else {
                    PointerModeIndicator.hide()
                }
            }
        }
        engine.onUnlocked = { [weak self] reason in
            self?.diagnostics.record("포인터 모드 해제 — \(reason)")
        }
        engine.onResumed = { [weak self] reason in
            self?.diagnostics.record("포인터 모드 다시 켬 — \(reason)")
        }
        engine.onKeyboardClick = { [weak self] in
            Task { @MainActor in self?.handleClick() }
        }
        engine.onTapEvent = { [weak self] event in
            Task { @MainActor in self?.handleTapEvent(event) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine.interruptFromMain(refreshDisplays: true, reason: "디스플레이 구성 변경") }
        })
        reconcile()
    }

    /// 포인터 모드가 켜지고 꺼질 때: 실제 마우스 클릭 감시를 걸거나 뗀다
    private func updateClickMonitor() {
        if isLocked, settings.exitOnTextInputClick {
            guard mouseClickMonitor == nil else { return }
            mouseClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                Task { @MainActor in self?.handleClick() }
            }
        } else if let monitor = mouseClickMonitor {
            NSEvent.removeMonitor(monitor)
            mouseClickMonitor = nil
        }
    }

    /// 클릭 직후(키보드·실제 마우스 공통): 포커스가 옮겨 갈 시간을 두고 입력란인지 확인해 포인터 모드를 끈다
    private func handleClick() {
        guard isLocked, settings.exitOnTextInputClick else { return }
        // 클릭한 자리 (포커스가 자리를 잡기 전에 읽는다)
        let clickPoint = MouseActionService.currentLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay) { [weak self] in
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
            TextInputFocusProbe.check(frontmostPID: frontmost.processIdentifier, clickPoint: clickPoint) { result in
                Task { @MainActor in
                    guard let self, self.isLocked else { return }
                    let bundleID = frontmost.bundleIdentifier
                    // 판정 근거를 남긴다 (역할 이름·앱 번들 ID만). 버튼·탭 등 관계없는 클릭은 남기지 않는다.
                    if result.isWorthRecording { self.diagnostics.record(
                        "입력란 확인 \(bundleID ?? "알 수 없는 앱"): \(result.isTextInput ? "입력란" : "아님") — \(result.summary)"
                    ) }
                    guard result.isTextInput else { return }
                    // 제외 앱(클릭 뒤 앞에 있는 앱)이면 포인터 모드를 유지한다
                    if let bundleID, self.settings.textInputExitExcludedApps.contains(bundleID) { return }
                    // 사용자가 제외한 영역(배운 규칙)이면 유지한다
                    if let signature = result.signature,
                       self.settings.textInputExclusionRules.contains(where: { $0.matches(signature) }) {
                        self.diagnostics.record("입력란이지만 제외 규칙에 걸려 포인터 모드 유지")
                        return
                    }
                    self.diagnostics.record("입력란 클릭으로 포인터 모드 해제")
                    self.lastAutoUnlock = result.signature
                    self.engine.autoUnlockFromMain()
                }
            }
        }
    }

    /// 포인터 모드로 돌아오거나 켤 때: 포커스된 곳(글자 커서 옆, 없으면 요소 가운데)으로 포인터를 옮긴다.
    /// ⌘B처럼 이동하는 단축키는 포커스가 자리를 잡을 때까지 조금 기다린다.
    private func movePointerToFocus(resumed: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay) { [weak self] in
            guard let self, self.isLocked, let frontmost = NSWorkspace.shared.frontmostApplication else { return }
            FocusLocator.locate(frontmostPID: frontmost.processIdentifier) { result in
                Task { @MainActor in
                    // 그 사이 포인터 모드가 꺼졌거나 드래그 중이면 옮기지 않는다
                    guard self.isLocked, !self.isDragging else { return }
                    if let point = result.point {
                        MouseActionService.movePointer(to: point, dragging: false)
                    }
                    self.diagnostics.record(
                        "포인터를 포커스로 (\(resumed ? "돌아옴" : "켬"), \(frontmost.bundleIdentifier ?? "알 수 없는 앱")): \(result.summary)"
                    )
                }
            }
        }
    }

    /// 클릭 뒤 포커스가 입력란으로 옮겨 가기를 기다리는 시간
    private static let focusSettleDelay: TimeInterval = 0.12

    /// 메뉴·빠른 다시 켜기: 방금 해제된 영역을 규칙으로 저장하고 포인터 모드를 다시 켠다
    func excludeLastAutoUnlock(allBrowsers: Bool) {
        guard let signature = lastAutoUnlock else { return }
        let rule = TextInputExclusionRule.learned(from: signature, allBrowsers: allBrowsers)
        if !settings.textInputExclusionRules.contains(rule) {
            var copy = settings
            copy.textInputExclusionRules.append(rule)
            update(settings: copy)
        }
        // 빠른 다시 켜기면 이미 켜져 있다 (setLocked는 같은 값이면 아무것도 하지 않는다)
        engine.lockFromMain()
        FeedbackHUD.show(rule.isBroad ? "이 앱의 모든 텍스트 영역에서 해제하지 않아요" : "이 영역은 앞으로 해제하지 않아요")
        lastAutoUnlock = nil
        let page = rule.urlScheme.map { "\($0)://\(rule.urlHost ?? "*")" } ?? "-"
        diagnostics.record(
            "제외 규칙 추가: \(rule.bundleID ?? "모든 브라우저") \(rule.role) 페이지=\(page) 클래스=\(rule.domClasses.count)개"
        )
    }

    func stop() {
        engine.stop()
        // 키보드 포인터를 끄면 포인터 모드 표시도 바로 사라진다 (탭 스레드 통지를 기다리지 않는다)
        isLocked = false
        isSuspended = false
        updateClickMonitor()
        PointerModeIndicator.hide()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 창 포커스 이동·한영 변환 등 WheelSpace 다른 기능 단축키 — 포인터 모드에서 앱 단축키로 다루지 않는다
    func update(ownShortcuts: [KeyCombo]) {
        engine.update(ownShortcuts: ownShortcuts)
    }

    func update(settings newValue: KeyPointerSettings) {
        let value = newValue.validated()
        store.saveKeyPointer(value)
        settings = value
        engine.update(settings: value)
        updateClickMonitor()
        reconcile()
    }

    /// 권한 변경 시 AppController가 호출. 입력 모니터링(키 감지) + 손쉬운 사용(이벤트 전송) 둘 다 필요.
    func reconcile() {
        if !settings.isEnabled {
            engine.stop()
            status = .paused
        } else if !PermissionService.currentStatus().isSufficient {
            engine.stop()
            status = .needsPermission
        } else if status == .tapError {
            // 사용자의 재시도 전까지 유지
        } else {
            engine.start()
        }
    }

    func retry() {
        diagnostics.record("키보드 포인터 재시도")
        if status == .tapError { status = .paused }
        reconcile()
    }

    /// 메뉴·설정 창 열기, 잠금·잠자기 — 진행 중 이동·드래그 중단
    func interrupt(reason: String) {
        engine.interruptFromMain(refreshDisplays: false, reason: reason)
    }

    var stateDescription: String {
        switch status {
        case .paused: return "꺼짐"
        case .needsPermission: return "권한 필요"
        case .running: return isDragging ? "드래그 중" : "사용 중"
        case .tapError: return "입력 감지 오류"
        }
    }

    var diagnosticsLines: [String] {
        let shortcut = settings.shortcut
        let actionKeys = PointerAction.allCases.map { shortcut.key(for: $0).keyLabel }.joined(separator: " ")
        let combo = "\(shortcut.comboSymbol()) · 스크롤 \(shortcut.scrollKey.label)"
            + " · 빠르게 \(shortcut.fastKey.label) · \(actionKeys)"
        return [
            "키보드 포인터: \(stateDescription)",
            "  조합: \(combo), 속도 \(Int(settings.speed))pt/초 ×\(settings.fastMultiplier), 스크롤 \(Int(settings.scrollSpeed))",
        ]
    }

    private func handleTapEvent(_ event: EventTapHost.Event) {
        switch event {
        case .started:
            if settings.isEnabled { status = .running }
            diagnostics.record("키보드 포인터 이벤트 탭 시작")
        case .stopped:
            break
        case .failed(let failure):
            engine.stop()
            diagnostics.record("키보드 포인터 이벤트 탭 실패: \(failure)")
            status = PermissionService.currentStatus().isSufficient ? .tapError : .needsPermission
        }
    }
}
