import CoreGraphics
import Foundation
import WheelSpaceCore

/// 창 목록 전환기의 탭 스레드 쪽: 키·보조키 이벤트를 WindowSwitcherState로 판정하고, 명령을 메인 스레드로 보낸다.
/// 보조키를 떼는 순간을 알려면 flagsChanged를 받아야 해서 Carbon 단축키 대신 이벤트 탭을 쓴다 (입력 모니터링 권한).
/// 상태는 탭 스레드에서만 만진다.
final class WindowSwitcherEngine {
    /// 명령 통지 (메인 스레드)
    var onCommand: ((WindowSwitcherCommand) -> Void)?
    /// 탭 상태 변화 (메인 스레드)
    var onTapEvent: ((EventTapHost.Event) -> Void)? {
        get { host.onEvent }
        set { host.onEvent = newValue }
    }

    private let host: EventTapHost
    /// triggerSnapshot 보호 (메인 → 탭 스레드)
    private let lock = NSLock()
    private var triggerSnapshot: KeyCombo
    private var requiresHeldKeySnapshot: Bool

    // 이하 탭 스레드 전용
    private var state: WindowSwitcherState
    /// 키보드 포인터의 누르고 있는 키(⌥⇥의 Tab)를 누른 채일 때만 연다
    private var requiresHeldKey = false

    // MARK: 다른 키 탭과 공유 (키보드 포인터가 양보하는 데 쓴다)
    // 탭은 앱 안에서도 생성 순서에 따라 누가 먼저 받을지 정해지지 않는다. 키보드 포인터의 포인터 모드가 먼저 받으면
    // ⌥`를 글자로 보고 삼키거나, 목록이 열린 동안 방향키를 포인터 이동으로 써 버리므로 이 상태로 양보받는다.
    private static let sharedLock = NSLock()
    private static var sharedTrigger: KeyCombo?
    private static var sharedIsOpen = false
    private static var sharedRequiresHeldKey = false

    /// 다른 탭 스레드에서: 이 키 이벤트를 전환기가 써야 하는지 (목록이 열려 있거나, 전환기 단축키·⇧ 단축키)
    static func claims(keyCode: UInt16, modifiers: ModifierState) -> Bool {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if sharedIsOpen { return true }
        guard let trigger = sharedTrigger else { return false }
        // "⌥⇥를 누른 채"만 열기: Tab이 안 눌렸으면 ⌥`는 전환기 것이 아니다
        if sharedRequiresHeldKey, !KeyPointerEngine.isHeldKeyDown { return false }
        return keyCode == trigger.keyCode
            && (modifiers == trigger.modifiers || modifiers == trigger.modifiers.union(.shift))
    }

    private static func publish(trigger: KeyCombo?, requiresHeldKey: Bool, isOpen: Bool) {
        sharedLock.lock()
        sharedTrigger = trigger
        sharedRequiresHeldKey = requiresHeldKey
        sharedIsOpen = isOpen
        sharedLock.unlock()
    }

    private static func publish(isOpen: Bool) {
        sharedLock.lock()
        sharedIsOpen = isOpen
        sharedLock.unlock()
    }

    init(trigger: KeyCombo, requiresHeldKey: Bool) {
        self.triggerSnapshot = trigger
        self.requiresHeldKeySnapshot = requiresHeldKey
        self.state = WindowSwitcherState(trigger: trigger)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        self.host = EventTapHost(name: "WheelSpace.WindowSwitcher", mask: mask)

        // weak: 설정을 바꿔 엔진을 새로 만들면 이전 엔진이 먼저 해제되는데, 그 탭 스레드가 아직 마지막 콜백을
        // 부를 수 있다 (unowned면 해제된 객체 접근으로 앱이 종료된다)
        host.onTapThreadStart = { [weak self] in
            guard let self else { return }
            lock.lock()
            let trigger = triggerSnapshot
            let requiresHeldKey = requiresHeldKeySnapshot
            lock.unlock()
            state = WindowSwitcherState(trigger: trigger)
            self.requiresHeldKey = requiresHeldKey
        }
        host.onInterrupted = { [weak self] in
            guard let self else { return }
            send(state.cancel())
        }
        host.handler = { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return handle(type: type, event: event)
        }
    }

    /// 메인 스레드
    func start() {
        lock.lock()
        let trigger = triggerSnapshot
        let requiresHeldKey = requiresHeldKeySnapshot
        lock.unlock()
        Self.publish(trigger: trigger, requiresHeldKey: requiresHeldKey, isOpen: false)
        host.start()
    }

    /// 메인 스레드
    func stop() {
        Self.publish(trigger: nil, requiresHeldKey: false, isOpen: false)
        host.stop()
    }

    /// 메인 스레드: 단축키 변경
    func update(trigger: KeyCombo, requiresHeldKey: Bool) {
        lock.lock()
        triggerSnapshot = trigger
        requiresHeldKeySnapshot = requiresHeldKey
        lock.unlock()
        Self.publish(trigger: trigger, requiresHeldKey: requiresHeldKey, isOpen: false)
        host.perform { [weak self] in
            guard let self else { return }
            self.requiresHeldKey = requiresHeldKey
            send(state.update(trigger: trigger))
        }
    }

    /// 메인 스레드: 목록이 준비됐다 (count = 현재 창 포함)
    func listLoaded(count: Int) {
        host.perform { [weak self] in
            guard let self else { return }
            send(state.listLoaded(count: count))
        }
    }

    /// 메인 스레드: 잠금·설정 창 열기 등으로 취소
    func cancelFromMain() {
        host.perform { [weak self] in
            guard let self else { return }
            send(state.cancel())
        }
    }

    // MARK: - 탭 스레드

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if SyntheticKeyboard.isSynthetic(event) {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown, .keyUp:
            let input = KeyEventInput(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                isDown: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                modifiers: ScrollEventMapper.modifierState(from: event.flags)
            )
            // "⌥⇥를 누른 채"만 열기: 닫혀 있을 때 Tab이 안 눌렸으면 전환기는 이 키를 보지 않는다
            if input.isDown, state.phase == .idle, requiresHeldKey, !KeyPointerEngine.isHeldKeyDown {
                return Unmanaged.passUnretained(event)
            }
            let decision = state.handleKey(input)
            send(decision.commands)
            return decision.consume ? nil : Unmanaged.passUnretained(event)
        case .flagsChanged:
            send(state.handleModifiers(ScrollEventMapper.modifierState(from: event.flags)))
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 상태가 바뀔 수 있는 모든 경로에서 부른다: 열림 여부를 공유하고 명령을 메인 스레드로 보낸다
    private func send(_ commands: [WindowSwitcherCommand]) {
        Self.publish(isOpen: state.phase != .idle)
        guard !commands.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for command in commands {
                self?.onCommand?(command)
            }
        }
    }
}
