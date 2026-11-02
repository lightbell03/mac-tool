import CoreGraphics
import Foundation
import WheelSpaceCore

/// 겹친 창 넘기기의 마우스 쪽: 단축키 보조키(기본 ⌃⌥)를 누른 채 뒤로가기·앞으로가기 버튼을 누르면 넘긴다.
/// 버튼은 두 가지 모양으로 온다: 일반 마우스 버튼 3·4, 또는 Logi Options+처럼 버튼을 트랙패드 넘기기 제스처로 바꿔 보내는 경우.
/// 데스크탑 전환 탭(EventTapService)은 그 기능을 끄면 멈추므로 따로 탭을 둔다. 넘기기로 쓴 입력은 앱에 보내지 않는다.
final class StackMouseButtonTap {
    /// 넘기기 요청 (메인 스레드)
    var onTrigger: ((StackDirection) -> Void)?
    /// 진단용: 보조키와 함께 누른 사이드 버튼과 판정 (메인 스레드). 버튼·보조키만 넘긴다.
    var onButton: ((MouseSideButton, ModifierState, StackDirection?) -> Void)?
    /// 탭 상태 변화 (메인 스레드)
    var onTapEvent: ((EventTapHost.Event) -> Void)? {
        get { host.onEvent }
        set { host.onEvent = newValue }
    }

    /// 비공개 제스처 이벤트(NSEventTypeGesture)와 그 필드 — macOS 26.3 실측
    private static let gestureEventType: UInt32 = 29
    private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private static let swipeDirectionField = CGEventField(rawValue: 115)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    /// IOHIDEventType 넘기기(Swipe)
    private static let swipeHIDType: Int64 = 16
    private static let phaseBegan: Int64 = 1
    private static let phaseEnded: Int64 = 4

    private let host: EventTapHost
    /// 단축키 스냅샷 보호 (메인 → 탭 스레드)
    private let lock = NSLock()
    private var nextShortcut: KeyCombo?
    private var previousShortcut: KeyCombo?

    // 이하 탭 스레드 전용
    /// down을 삼킨 버튼. 짝이 되는 up도 삼켜 앱에 짝 없는 up이 가지 않게 한다.
    private var consumedButtons: Set<MouseSideButton> = []
    /// 넘기기 제스처의 시작을 삼켰다 — 끝날 때까지 이어지는 제스처 이벤트도 삼킨다
    private var swallowingSwipe = false

    init() {
        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            | (CGEventMask(1) << Self.gestureEventType)
        self.host = EventTapHost(name: "WheelSpace.StackMouseButtons", mask: mask)
        host.handler = { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return handle(type: type, event: event)
        }
        host.onInterrupted = { [weak self] in
            self?.consumedButtons.removeAll()
            self?.swallowingSwipe = false
        }
    }

    var isRunning: Bool { host.isRunning }

    /// 메인 스레드. 이미 실행 중이면 아무것도 하지 않는다.
    func start() {
        host.start()
    }

    /// 메인 스레드
    func stop() {
        host.stop()
    }

    /// 메인 스레드: 지금 단축키 (보조키를 여기서 가져온다)
    func update(next: KeyCombo?, previous: KeyCombo?) {
        lock.lock()
        nextShortcut = next
        previousShortcut = previous
        lock.unlock()
    }

    // MARK: - 탭 스레드

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == Self.gestureEventType {
            return handleGesture(event)
        }
        guard let input = ScrollEventMapper.buttonInput(from: event, isDown: type == .otherMouseDown) else {
            return Unmanaged.passUnretained(event)
        }
        if !input.isDown {
            return consumedButtons.remove(input.button) != nil ? nil : Unmanaged.passUnretained(event)
        }
        // 보조키 없는 뒤로가기 등은 앱·데스크탑 전환 탭 몫
        guard let direction = decide(input.button, modifiers: input.modifiers) else {
            return Unmanaged.passUnretained(event)
        }
        consumedButtons.insert(input.button)
        trigger(direction)
        return nil
    }

    /// 버튼을 넘기기 제스처로 보내는 마우스: 시작(방향 없음) → 끝(방향 있음) 두 이벤트가 온다.
    /// 시작 때 보조키가 맞으면 끝까지 삼키고, 끝의 방향으로 넘긴다. 그 밖의 제스처(트랙패드 확대 등)는 그대로 통과.
    private func handleGesture(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(Self.gestureHIDTypeField) == Self.swipeHIDType else {
            return Unmanaged.passUnretained(event)
        }
        let phase = event.getIntegerValueField(Self.gesturePhaseField)
        let modifiers = ScrollEventMapper.physicalModifierState()
        if !swallowingSwipe {
            if phase == Self.phaseBegan {
                guard claimsModifiers(modifiers) else { return Unmanaged.passUnretained(event) }
                swallowingSwipe = true
                return nil
            }
            // 시작을 놓친 끝은 그 자리에서 판정한다
            guard phase == Self.phaseEnded else { return Unmanaged.passUnretained(event) }
        }
        guard phase == Self.phaseEnded else { return nil }
        let wasSwallowing = swallowingSwipe
        swallowingSwipe = false
        guard let button = StackMouseBinding.button(forSwipeDirection: event.getIntegerValueField(Self.swipeDirectionField)),
              let direction = decide(button, modifiers: modifiers) else {
            return wasSwallowing ? nil : Unmanaged.passUnretained(event)
        }
        trigger(direction)
        return nil
    }

    /// 지금 보조키가 어느 쪽이든 넘기기 단축키의 보조키인지 (방향을 아직 모르는 제스처 시작용)
    private func claimsModifiers(_ modifiers: ModifierState) -> Bool {
        lock.lock()
        let next = nextShortcut
        let previous = previousShortcut
        lock.unlock()
        return StackMouseBinding.direction(for: .back, modifiers: modifiers, next: next, previous: previous) != nil
            || StackMouseBinding.direction(for: .forward, modifiers: modifiers, next: next, previous: previous) != nil
    }

    private func decide(_ button: MouseSideButton, modifiers: ModifierState) -> StackDirection? {
        lock.lock()
        let next = nextShortcut
        let previous = previousShortcut
        lock.unlock()
        let direction = StackMouseBinding.direction(for: button, modifiers: modifiers, next: next, previous: previous)
        if !modifiers.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onButton?(button, modifiers, direction) }
        }
        return direction
    }

    private func trigger(_ direction: StackDirection) {
        DispatchQueue.main.async { [weak self] in self?.onTrigger?(direction) }
    }
}
