import CoreGraphics
import Foundation
import WheelSpaceCore

/// 키보드 포인터의 탭 스레드 쪽: 키 이벤트 판정, 120Hz 이동·스크롤 타이머, 드래그 버튼 소유 관리.
/// 상태는 모두 탭 스레드에서만 만진다. 메인 스레드와는 스냅샷·perform으로만 주고받는다.
final class KeyPointerEngine {
    /// 메인 스레드로 알리는 상태 (메뉴 막대 표시용)
    struct Status: Equatable {
        var isDragging: Bool
        var mode: KeyPointerInputState.Mode
        var isLocked: Bool
        /// 앱 단축키로 잠깐 해제된 상태 (isLocked는 false)
        var isSuspended = false
        /// 잠깐 해제가 보조키를 누르는 동안만인지
        var suspendsWhileHeld = false
    }

    /// 메인 스레드에서 호출
    var onStatusChange: ((Status) -> Void)?
    /// 앱이 키보드로 클릭했을 때 (메인 스레드) — 입력란 클릭이면 포인터 모드를 끄는 데 쓴다
    var onKeyboardClick: (() -> Void)?
    /// 포인터 모드가 꺼진 이유 (메인 스레드, 진단 기록용)
    var onUnlocked: ((String) -> Void)?
    /// 잠깐 해제에서 다시 포인터 모드로 돌아옴 (메인 스레드, 진단 기록용)
    var onResumed: ((String) -> Void)?
    /// 탭 스레드 전용: 다음 해제의 이유. 해제 직전에 정하고 .lockChanged(false)에서 알린다.
    private var unlockReason: String?
    /// 탭 상태 변화 (메인 스레드)
    var onTapEvent: ((EventTapHost.Event) -> Void)? {
        get { host.onEvent }
        set { host.onEvent = newValue }
    }

    /// 120Hz — 60Hz보다 한 번에 움직이는 거리가 절반이라 실제 마우스처럼 매끄럽게 보인다
    private static let tickInterval: TimeInterval = 1.0 / 120
    /// 실제 포인터 위치가 앱이 계산한 위치와 이만큼(또는 한 틱 이동량의 3배) 넘게 다르면 사용자가 마우스를 움직인 것으로 본다
    private static let resyncDistance: CGFloat = 40

    private let host: EventTapHost
    /// 포인터 모드 해제 단축키 감시: HID 단계 듣기 전용. ⌘Space(Spotlight)·⌥Space 같은 전역 단축키는
    /// 시스템이 세션 단계 탭보다 먼저 가져가 host가 받지 못하므로, 그 앞 단계에서 보기만 한다 (입력은 건드리지 않는다).
    private let exitWatcher: EventTapHost

    /// settingsSnapshot·displaysSnapshot 보호 (메인 → 탭 스레드)
    private let lock = NSLock()
    private var settingsSnapshot: KeyPointerSettings
    private var displaysSnapshot: [CGRect] = []

    // 이하 탭 스레드 전용
    private var settings: KeyPointerSettings
    private var input: KeyPointerInputState
    private var timer: CFRunLoopTimer?
    private var lastTick: TimeInterval?
    /// 연속 이동·스크롤을 시작한 시각 (가속 계산). 방향키를 모두 떼거나 모드가 바뀌면 타이머와 함께 초기화된다.
    private var motionStartedAt: TimeInterval?
    /// 앱이 누른 왼쪽 버튼 (드래그) — 사용자가 직접 누른 버튼과 구분
    private var ownsLeftButton = false
    /// 스크롤 소수점 누적
    private var scrollRemainder = CGVector.zero
    /// 이동 중 앱이 계산해 둔 포인터 위치. 보낸 이동 이벤트가 반영되기 전에 현재 위치를 다시 읽으면
    /// 옛 위치에서 또 출발해 이동이 사라지므로(누르고 있어도 안 움직이거나 끊기는 원인), 이동 중에는 이 값을 기준으로 쌓는다.
    private var trackedPosition: CGPoint?
    private var displays: [CGRect] = []
    /// 마지막으로 받은 이벤트의 보조키. CGEventSource.flagsState는 탭 위치에 따라 0이거나 한 박자 늦은 값을 돌려줄 수 있어
    /// (HID 단계에서 이동이 첫 틱에 멈추던 원인) 시스템에 묻지 않고 받은 이벤트로 추적한다.
    private var currentModifiers: ModifierState = []
    private var lastStatus = Status(isDragging: false, mode: .idle, isLocked: false)
    /// ⌥Tab 두 번 기다리는 한 번짜리 타이머
    private var pendingTapTimer: CFRunLoopTimer?
    private var resumeTimer: CFRunLoopTimer?
    /// lock으로 보호: 탭 스레드가 새로 시작할 때 다시 넣는다
    private var ownShortcutsSnapshot: [KeyCombo] = []

    // MARK: 다른 키 탭과 공유 (창 목록 전환기의 "⌥⇥를 누른 채 `"에 쓴다)
    // 누르고 있는 키(Tab)는 이 탭이 소비하므로 다른 탭은 직접 알 수 없다 — 이 엔진이 판단한 눌림을 알린다.
    private static let sharedLock = NSLock()
    private static var sharedHeldKeyDown = false

    /// 다른 탭 스레드에서: 키보드 포인터의 누르고 있는 키(Tab)가 지금 눌려 있는지
    static var isHeldKeyDown: Bool {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedHeldKeyDown
    }

    private static func publishHeldKey(_ down: Bool) {
        sharedLock.lock()
        sharedHeldKeyDown = down
        sharedLock.unlock()
    }

    init(settings: KeyPointerSettings) {
        self.settingsSnapshot = settings
        self.settings = settings
        self.input = KeyPointerInputState(shortcut: settings.shortcut)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        // 세션 단계에서 가로챈다. 전역 단축키(⌃⌥ + 방향키 창 포커스 이동 등)는 이 탭보다 먼저 처리된다.
        self.host = EventTapHost(name: "WheelSpace.KeyPointer", mask: mask)
        self.exitWatcher = EventTapHost(
            name: "WheelSpace.KeyPointer.ExitWatcher",
            mask: CGEventMask(1) << CGEventType.keyDown.rawValue,
            location: .cghidEventTap,
            options: .listenOnly
        )

        host.onTapThreadStart = { [unowned self] in
            lock.lock()
            self.settings = settingsSnapshot
            displays = displaysSnapshot
            lock.unlock()
            input = KeyPointerInputState(shortcut: self.settings.shortcut)
            lock.lock()
            input.ownShortcuts = ownShortcutsSnapshot
            lock.unlock()
        }
        host.onInterrupted = { [unowned self] in
            interrupt(reason: "입력 감지가 시스템에 의해 잠시 꺼짐")
        }
        host.handler = { [unowned self] type, event in
            handle(type: type, event: event)
        }
        // 감시 탭 스레드: 설정은 스냅샷으로 보고, 포인터 모드 끄기는 host 탭 스레드에 맡긴다
        exitWatcher.handler = { [unowned self] _, event in
            watchExitShortcut(event)
            return Unmanaged.passUnretained(event)
        }
    }

    /// 감시 탭 스레드: 해제 단축키면 host 탭 스레드에서 포인터 모드를 끈다
    private func watchExitShortcut(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !SyntheticKeyboard.isSynthetic(event) else { return }
        lock.lock()
        let shortcut = settingsSnapshot.shortcut
        lock.unlock()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard shortcut.isExitShortcut(keyCode: keyCode, modifiers: ScrollEventMapper.modifierState(from: event.flags)) else {
            return
        }
        host.perform { [weak self] in
            guard let self, input.isLocked else { return }
            unlockReason = "해제 단축키 (전역 감시)"
            execute(input.setLocked(false))
        }
    }

    /// 메인 스레드
    func start() {
        lock.lock()
        displaysSnapshot = DisplayService.activeDisplayFrames()
        lock.unlock()
        host.start()
        exitWatcher.start()
    }

    /// 메인 스레드 — 탭 스레드에서 드래그 버튼 해제 후 탭 정지
    func stop() {
        exitWatcher.stop()
        host.stop()
    }

    /// 메인 스레드: WheelSpace 다른 기능의 단축키 (앱 단축키로 다루지 않는다)
    func update(ownShortcuts: [KeyCombo]) {
        lock.lock()
        ownShortcutsSnapshot = ownShortcuts
        lock.unlock()
        host.perform { [weak self] in
            self?.input.ownShortcuts = ownShortcuts
        }
    }

    /// 메인 스레드: 설정 반영. 진행 중 동작은 끝내고 다음 입력부터 적용.
    func update(settings newValue: KeyPointerSettings) {
        lock.lock()
        settingsSnapshot = newValue
        lock.unlock()
        host.perform { [weak self] in
            guard let self else { return }
            settings = newValue
            execute(input.update(shortcut: newValue.shortcut))
        }
    }

    /// 메인 스레드: 메뉴·설정 창 열기, 잠금, 모니터 변경 등 — 이동·스크롤·드래그 즉시 중단
    /// 메인 스레드: 포인터 모드만 끈다 (입력란 클릭 등). 진행 중 이동·드래그도 함께 끝난다.
    /// 메인 스레드: 입력란 클릭으로 포인터 모드를 끈다
    func autoUnlockFromMain() {
        host.perform { [weak self] in
            guard let self else { return }
            unlockReason = "입력란 클릭"
            execute(input.setLocked(false))
        }
    }

    /// 메인 스레드: 포인터 모드를 켠다 (방금 해제 취소)
    func lockFromMain() {
        host.perform { [weak self] in
            guard let self else { return }
            execute(input.setLocked(true))
        }
    }

    func unlockFromMain() {
        host.perform { [weak self] in
            guard let self else { return }
            unlockReason = "메뉴"
            execute(input.setLocked(false))
        }
    }

    func interruptFromMain(refreshDisplays: Bool, reason: String) {
        var fresh: [CGRect]?
        if refreshDisplays {
            fresh = DisplayService.activeDisplayFrames()
            lock.lock()
            displaysSnapshot = fresh ?? []
            lock.unlock()
        }
        host.perform { [weak self] in
            guard let self else { return }
            if let fresh { displays = fresh }
            interrupt(reason: reason)
        }
    }

    // MARK: - 탭 스레드

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if SyntheticKeyboard.isSynthetic(event) {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown, .keyUp:
            // 창 목록 전환기의 단축키이거나 목록이 열려 있으면 양보한다 (포인터 모드가 ⌥`·방향키를 가져가지 않게)
            let modifiers = ScrollEventMapper.modifierState(from: event.flags)
            // 양보는 누름에만 한다. 뗌까지 넘기면 Tab을 뗀 것을 놓쳐 계속 눌린 것으로 착각한다.
            if type == .keyDown, WindowSwitcherEngine.claims(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers
            ) {
                // ⌥⇥ + `: Tab을 전환기에 쓴 것이니 뗄 때 ⌥Tab을 다시 보내지 않는다
                input.markHeldKeyUsed()
                return Unmanaged.passUnretained(event)
            }
            let keyInput = KeyEventInput(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                isDown: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                modifiers: ScrollEventMapper.modifierState(from: event.flags),
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            currentModifiers = keyInput.modifiers
            let wasLocked = input.isLocked
            let decision = input.handleKey(keyInput)
            if wasLocked, !input.isLocked, input.isSuspended {
                let kind = input.suspendsWhileHeld ? "보조키 누르는 동안" : "잠깐 해제"
                unlockReason = "앱 단축키 \(PointerShortcut.symbol(for: keyInput.modifiers))\(keyInput.keyCode) (\(kind))"
            } else if wasLocked, !input.isLocked {
                // 키 코드·보조키만 남긴다 (해제에 쓴 키라 입력 내용이 아니다)
                let combo = PointerShortcut.symbol(for: keyInput.modifiers)
                unlockReason = decision.consume
                    ? "키 \(combo)\(keyInput.keyCode) (입력 키·켜기 단축키)"
                    : "키 \(combo)\(keyInput.keyCode) (해제 단축키·앱 단축키)"
            } else if !wasLocked, input.isLocked, keyInput.isDown,
                      KeyPointerInputState.suspendEndKeyCodes.contains(keyInput.keyCode), keyInput.modifiers.isEmpty {
                let reason = keyInput.keyCode == 53 ? "Esc" : "Return"
                DispatchQueue.main.async { [weak self] in self?.onResumed?("\(reason)로 목록을 끝냄") }
            }
            Self.publishHeldKey(input.isHeldKeyDown)
            execute(decision.commands)
            if decision.stripsCommandControl {
                event.flags.remove([.maskCommand, .maskControl])
            }
            return decision.consume ? nil : Unmanaged.passUnretained(event)
        case .flagsChanged:
            let modifiers = ScrollEventMapper.modifierState(from: event.flags)
            currentModifiers = modifiers
            let wasSuspended = input.isSuspended
            let commands = input.handleModifiers(modifiers)
            if commands.contains(.lockChanged(true)) {
                DispatchQueue.main.async { [weak self] in self?.onResumed?("보조키를 뗌") }
            } else if wasSuspended, !input.isSuspended, !input.isLocked {
                DispatchQueue.main.async { [weak self] in self?.onUnlocked?("보조키를 쥔 채 ⇧ 한 번 (완전히 해제)") }
            }
            execute(commands)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// "클릭하면 포인터 모드 해제": 옮기고 누른 뒤 바로 키보드로 돌아간다.
    /// 해제 중 stopAll이 내는 endDrag는 이미 잠금이 풀린 뒤라 다시 걸리지 않는다.
    private func exitAfterClickIfNeeded() {
        guard settings.exitAfterClick, input.isLocked else { return }
        unlockReason = "클릭 후 해제 옵션"
        execute(input.setLocked(false))
    }

    private func execute(_ commands: [KeyPointerCommand]) {
        for command in commands {
            let location = MouseActionService.currentLocation()
            switch command {
            case .click(let button):
                try? MouseActionService.click(button, at: location)
                notifyKeyboardClick()
                exitAfterClickIfNeeded()
            case .doubleClick:
                try? MouseActionService.doubleClick(at: location)
                notifyKeyboardClick()
                exitAfterClickIfNeeded()
            case .beginDrag:
                // 사용자가 실제 왼쪽 버튼을 누르고 있으면 앱 드래그를 시작하지 않는다
                if MouseActionService.isPhysicalLeftButtonDown || (try? MouseActionService.leftButton(down: true, at: location)) == nil {
                    input.dragRejected()
                } else {
                    ownsLeftButton = true
                }
            case .endDrag:
                releaseOwnedButton(at: location)
                exitAfterClickIfNeeded()
            case .replayKey(let keyCode, let modifiers):
                // 자체 표시가 붙어 이 탭을 그냥 통과해 앱에 ⌃Tab 등으로 전달된다
                try? SyntheticKeyboard.press(keyCode: CGKeyCode(keyCode), flags: Self.eventFlags(for: modifiers))
            case .motionChanged:
                if input.activeArrows.isEmpty {
                    stopTimer()
                } else {
                    startTimerIfNeeded()
                }
            case .lockChanged(let locked):
                // 상태 표시는 아래 publishStatus가 isLocked로 전달한다
                if !locked {
                    let reason = unlockReason ?? "알 수 없음"
                    DispatchQueue.main.async { [weak self] in self?.onUnlocked?(reason) }
                }
                unlockReason = nil
            case .schedulePendingTap(let delay):
                cancelPendingTapTimer()
                pendingTapTimer = host.scheduleOneShotTimer(after: delay) { [weak self] in
                    guard let self else { return }
                    pendingTapTimer = nil
                    execute(input.flushPendingTap())
                }
            case .scheduleResumeCheck(let delay):
                if let resumeTimer { CFRunLoopTimerInvalidate(resumeTimer) }
                resumeTimer = host.scheduleOneShotTimer(after: delay) { [weak self] in
                    guard let self else { return }
                    resumeTimer = nil
                    let commands = input.resumeIfIdle(now: ProcessInfo.processInfo.systemUptime)
                    if commands.contains(.lockChanged(true)) {
                        DispatchQueue.main.async { [weak self] in self?.onResumed?("앱 단축키 뒤 입력 없음") }
                    }
                    execute(commands)
                }
            }
        }
        publishStatus()
    }

    /// 포인터 모드에서 키보드로 클릭했으면 메인 스레드에 알린다 (입력란이면 포인터 모드를 끈다)
    private func notifyKeyboardClick() {
        guard input.isLocked else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onKeyboardClick?()
        }
    }

    private func releaseOwnedButton(at location: CGPoint) {
        guard ownsLeftButton else { return }
        ownsLeftButton = false
        try? MouseActionService.leftButton(down: false, at: location)
    }

    private func publishStatus() {
        let status = Status(
            isDragging: ownsLeftButton, mode: input.mode, isLocked: input.isLocked, isSuspended: input.isSuspended,
            suspendsWhileHeld: input.suspendsWhileHeld
        )
        guard status != lastStatus else { return }
        lastStatus = status
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        motionStartedAt = lastTick
        trackedPosition = MouseActionService.currentLocation()
        timer = host.scheduleRepeatingTimer(interval: Self.tickInterval) { [weak self] in
            self?.tick()
        }
    }

    private func cancelPendingTapTimer() {
        if let pendingTapTimer {
            CFRunLoopTimerInvalidate(pendingTapTimer)
        }
        pendingTapTimer = nil
    }

    private func stopTimer() {
        if let timer {
            CFRunLoopTimerInvalidate(timer)
        }
        timer = nil
        lastTick = nil
        motionStartedAt = nil
        scrollRemainder = .zero
        trackedPosition = nil
    }

    /// 120Hz 틱: 경과 시간 기반 이동·스크롤
    private func tick() {
        // 필수 특수키·누르고 있는 키가 아직 눌려 있는지 확인. 시스템 키 상태(CGEventSource.keyState·flagsState)는
        // 소비한 키·탭 위치에 따라 믿을 수 없어 직접 받은 이벤트로 판단한다.
        // 이벤트를 놓치는 경우(탭 비활성화 등)는 interrupt()가 초기화한다.
        // 포인터 모드는 보조키·Tab 없이 동작한다
        let heldKeyDown = settings.shortcut.heldKey == nil || input.isHeldKeyDown
        guard input.isLocked || (heldKeyDown && currentModifiers.isSuperset(of: settings.shortcut.base)) else {
            execute(input.stopAll())
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - (lastTick ?? now)
        lastTick = now

        // 느리게·빠른 속도면 가속 없이 바로 그 속도 (invertFastKey면 빠르게 키를 누르는 동안만 기본 속도)
        let factor = settings.speedFactor(
            fastKeyHeld: input.isFast, slowKeyHeld: input.isSlow, scrolling: input.mode == .scrolling
        )
        let acceleration = !factor.accelerates ? 1 : PointerMotion.accelerationFactor(
            heldFor: now - (motionStartedAt ?? now),
            accelerationTime: settings.accelerationTime,
            startRatio: settings.startSpeedRatio
        )
        switch input.mode {
        case .moving:
            let multiplier = factor.multiplier * acceleration
            let velocity = PointerMotion.velocity(arrows: input.activeArrows, speed: settings.speed, multiplier: multiplier)
            let delta = PointerMotion.displacement(velocity: velocity, elapsed: elapsed)
            let actual = MouseActionService.currentLocation()
            var origin = trackedPosition ?? actual
            // 사용자가 실제 마우스를 움직였으면 그 위치로 다시 맞춘다
            let step = hypot(delta.dx, delta.dy)
            if hypot(actual.x - origin.x, actual.y - origin.y) > max(Self.resyncDistance, step * 3) {
                origin = actual
            }
            let target = DisplayGeometry.move(from: origin, by: delta, displays: displays)
            trackedPosition = target
            MouseActionService.movePointer(to: target, dragging: ownsLeftButton)
        case .scrolling:
            let multiplier = factor.multiplier * acceleration
            let delta = PointerMotion.scrollDelta(
                arrows: input.activeArrows, speed: settings.scrollSpeed, multiplier: multiplier,
                reverse: settings.reverseScroll, elapsed: elapsed
            )
            scrollRemainder.dx += delta.dx
            scrollRemainder.dy += delta.dy
            let dx = scrollRemainder.dx.rounded(.towardZero)
            let dy = scrollRemainder.dy.rounded(.towardZero)
            scrollRemainder.dx -= dx
            scrollRemainder.dy -= dy
            MouseActionService.scroll(dx: Int32(dx), dy: Int32(dy))
        case .idle:
            stopTimer()
        }
    }

    private static func eventFlags(for modifiers: ModifierState) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// 모든 중단 경로 공통: 연속 동작 정지, 앱이 누른 버튼 해제
    private func interrupt(reason: String) {
        currentModifiers = []
        input.releaseHeldKey()
        Self.publishHeldKey(false)
        cancelPendingTapTimer()
        // 메뉴·설정 창을 여는 등 중단되면 포인터 모드도 끈다 (켜 둔 채면 메뉴에서 방향키를 쓸 수 없다)
        unlockReason = reason
        execute(input.setLocked(false))
        execute(input.stopAll())
        releaseOwnedButton(at: MouseActionService.currentLocation())
        stopTimer()
        publishStatus()
    }
}


