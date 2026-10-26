import AppKit
import Combine
import WheelSpaceCore

enum ServiceState: Equatable {
    case starting
    case needsPermission
    case running
    case paused
    case tapError(String)
}

/// 사용자 활성화 의도(settings.isEnabled)와 권한·이벤트 탭의 실제 상태를 통합한다.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var state: ServiceState = .starting
    @Published private(set) var settings: AppSettings
    @Published private(set) var permissions: PermissionStatus
    @Published private(set) var loginItemEnabled: Bool = false
    @Published private(set) var lastTestResult: String?

    let diagnostics: Diagnostics
    /// 한영 변환 기능. 데스크탑 전환과 독립적으로 켜고 끈다.
    let conversion: ConversionCoordinator
    /// 창 포커스 이동 기능.
    let windowFocus: FocusCoordinator
    /// 키보드 포인터 기능.
    let keyPointer: KeyPointerController
    /// 실행 중인 앱 선택 기능.
    let appReveal: AppRevealCoordinator
    /// Spotlight·⌘Tab 등으로 포커스가 다른 모니터로 넘어갈 때 포인터 따라가기
    private let pointerFollower = PointerFollower()
    private var cancellables: Set<AnyCancellable> = []

    private let store: SettingsStore
    private let switcher = DesktopSwitcher()
    private let tapService: EventTapService
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let diagnostics = Diagnostics()
        self.diagnostics = diagnostics
        self.conversion = ConversionCoordinator(store: store, diagnostics: diagnostics)
        self.windowFocus = FocusCoordinator(store: store, diagnostics: diagnostics)
        self.keyPointer = KeyPointerController(store: store, diagnostics: diagnostics)
        self.appReveal = AppRevealCoordinator(store: store, diagnostics: diagnostics)
        let loaded = store.load()
        self.settings = loaded
        self.permissions = PermissionService.currentStatus()
        self.tapService = EventTapService(switcher: switcher, configuration: PolicyConfiguration(settings: loaded))
    }

    /// 앱 시작 시 1회.
    func start() {
        conversion.start()
        windowFocus.start()
        keyPointer.start()
        appReveal.start()
        windowFocus.$settings
            .map(\.pointerFollow)
            .removeDuplicates()
            .sink { [weak self] mode in self?.pointerFollower.update(mode: mode) }
            .store(in: &cancellables)
        // 포인터 모드가 다른 기능 단축키(⌃⌥← 등)를 앱 단축키로 보고 잠깐 해제·⌘ 빼기를 하지 않게
        Publishers.CombineLatest3(windowFocus.$settings, conversion.$settings, appReveal.$settings)
            .map { focus, conversion, reveal -> [KeyCombo] in
                var combos: [KeyCombo?] = []
                if focus.isEnabled {
                    combos += FocusDirection.allCases.map { focus.shortcut(for: $0) }
                    combos += [focus.switcherShortcut, focus.stackNextShortcut, focus.stackPreviousShortcut]
                    combos += FocusDirection.allCases.map { focus.moveShortcut(for: $0) }
                    combos += SpaceDirection.allCases.map { focus.spaceShortcut(for: $0) }
                    combos.append(focus.createSpaceShortcut)
                }
                if conversion.isEnabled {
                    combos += [conversion.englishToHangulShortcut, conversion.hangulToEnglishShortcut]
                }
                if reveal.isEnabled { combos.append(reveal.shortcut) }
                return combos.compactMap { $0 }
            }
            .removeDuplicates()
            .sink { [weak self] combos in self?.keyPointer.update(ownShortcuts: combos) }
            .store(in: &cancellables)
        tapService.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleTapEvent(event) }
        }
        observeSystemEvents()
        loginItemEnabled = LoginItemService.isEnabled
        diagnostics.record("시작")
        reconcile()
    }

    func shutdown() {
        conversion.stop()
        windowFocus.stop()
        keyPointer.stop()
        appReveal.stop()
        pointerFollower.stop()
        cancellables.removeAll()
        tapService.stop()
        for (center, observer) in systemObservers {
            center.removeObserver(observer)
        }
        systemObservers.removeAll()
    }

    // MARK: - 사용자 조작

    func setEnabled(_ enabled: Bool) {
        var copy = settings
        copy.isEnabled = enabled
        update(settings: copy)
    }

    func update(settings newValue: AppSettings) {
        let value = newValue.validated()
        let enabledChanged = value.isEnabled != settings.isEnabled
        store.save(value)
        settings = value
        tapService.update(configuration: PolicyConfiguration(settings: value))
        if enabledChanged {
            diagnostics.record(value.isEnabled ? "사용 켬" : "사용 끔")
            reconcile()
        }
    }

    func resetSettings() {
        diagnostics.record("설정 초기화")
        update(settings: store.reset())
        // store.reset()이 한영 변환 키도 지우므로 기본값을 다시 적용·저장한다
        conversion.update(settings: .defaults)
        windowFocus.update(settings: .defaults)
        keyPointer.update(settings: .defaults)
        appReveal.update(settings: .defaults)
    }

    func recheckPermissions() {
        let current = PermissionService.currentStatus()
        if current != permissions {
            diagnostics.record("권한 변경: 감지 \(current.listenEvents), 전송 \(current.postEvents), AX \(current.accessibility)")
        }
        permissions = current
        reconcile()
        windowFocus.reconcile()
        keyPointer.reconcile()
        appReveal.reconcile()
    }

    func requestPermissions() {
        PermissionService.requestMissing(current: permissions)
        recheckPermissions()
    }

    func openPermissionSettings(_ pane: PermissionService.SettingsPane) {
        PermissionService.openSystemSettings(pane)
    }

    /// 설정 창 "왼쪽/오른쪽으로 이동" 테스트 버튼. 이동 완료가 아니라 전송 여부만 표시한다.
    func testSwitch(_ direction: SwitchDirection) {
        let name = direction == .left ? "왼쪽" : "오른쪽"
        do {
            try switcher.send(direction)
            lastTestResult = "\(name) 이동 단축키를 보냈습니다. 데스크탑이 바뀌었는지 확인하세요."
            diagnostics.record("테스트 전송: \(name)")
        } catch {
            lastTestResult = "\(name) 이동 단축키를 보내지 못했습니다."
            diagnostics.record("테스트 전송 실패: \(name) \(error)")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
        } catch {
            diagnostics.record("로그인 실행 변경 실패: \(error.localizedDescription)")
        }
        loginItemEnabled = LoginItemService.isEnabled
    }

    func copyDiagnostics() {
        let text = diagnostics.report(
            stateDescription: stateDescription,
            permissions: permissions,
            loginItemEnabled: loginItemEnabled,
            extraLines: conversion.diagnosticsLines + windowFocus.diagnosticsLines + keyPointer.diagnosticsLines
                + appReveal.diagnosticsLines
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 권한 적용에 재실행이 필요한 경우.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.diagnostics.record("재실행 실패: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    var stateDescription: String {
        switch state {
        case .starting: return "시작 중"
        case .needsPermission: return "권한 필요"
        case .running: return "사용 중"
        case .paused: return "일시정지"
        case .tapError: return "입력 감지 오류"
        }
    }

    // MARK: - 내부

    /// 의도 + 권한 → 탭 시작/정지. 권한 회수·사용자 일시정지를 자동 복구로 덮어쓰지 않는다.
    private func reconcile() {
        if !settings.isEnabled {
            tapService.stop()
            state = .paused
        } else if !permissions.isSufficient {
            tapService.stop()
            state = .needsPermission
        } else if case .tapError = state {
            // 오류 상태는 사용자의 재시도(retry)로만 벗어난다.
        } else {
            tapService.start()
        }
    }

    /// 입력 감지 오류 상태에서 사용자가 다시 시도.
    func retry() {
        diagnostics.record("재시도")
        if case .tapError = state {
            state = .starting
        }
        recheckPermissions()
    }

    private func handleTapEvent(_ event: EventTapService.TapEvent) {
        switch event {
        case .started:
            state = .running
            diagnostics.record("이벤트 탭 시작")
        case .stopped:
            break
        case .failed(let failure):
            tapService.stop()
            permissions = PermissionService.currentStatus()
            diagnostics.record("이벤트 탭 실패: \(failure)")
            if !permissions.isSufficient {
                state = .needsPermission
            } else {
                switch failure {
                case .creationFailed: state = .tapError("이벤트 탭을 만들지 못했습니다.")
                case .repeatedlyDisabled: state = .tapError("이벤트 탭이 반복해서 비활성화되었습니다.")
                }
            }
        }
    }

    /// 잠자기·깨우기, 화면 잠금·해제, 빠른 사용자 전환, 앱 활성화(권한 변경 후 복귀) 관찰.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (AppController) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
            }
            systemObservers.append((center, token))
        }

        // 잠자기·잠금·사용자 전환: 입력 누적과 한영 변환의 원본 스냅샷을 버린다
        let suspend: @MainActor (AppController) -> Void = { controller in
            controller.tapService.resetTransientState()
            controller.conversion.discardSnapshot()
            controller.windowFocus.cancelPending(reason: "잠금·잠자기")
            controller.keyPointer.interrupt(reason: "잠자기·화면 잠금·사용자 전환")
        }
        let resume: @MainActor (AppController) -> Void = { controller in
            controller.tapService.resetTransientState()
            controller.recheckPermissions()
        }

        observe(workspace, NSWorkspace.willSleepNotification, suspend)
        observe(workspace, NSWorkspace.screensDidSleepNotification, suspend)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, suspend)
        observe(workspace, NSWorkspace.didWakeNotification, resume)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, resume)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), suspend)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), resume)
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { controller in
            controller.recheckPermissions()
            controller.conversion.refreshRestoreAvailability()
        }
    }
}
