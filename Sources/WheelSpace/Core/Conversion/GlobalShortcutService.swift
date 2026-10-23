import Carbon
import WheelSpaceCore

/// 단축키 등록 실패 사유 (모든 기능 공통)
enum ShortcutRegistrationError: Error, Equatable {
    /// 같은 기능 안의 다른 동작과 같은 조합
    case duplicate
    /// 시스템이 거부 (다른 앱이나 이 앱의 다른 기능이 이미 사용하는 등)
    case systemRejected(OSStatus)
}

/// C 핸들러가 제네릭 서비스를 부르기 위한 비제네릭 입구.
@MainActor
private protocol HotKeyReceiver: AnyObject {
    /// 내 단축키면 처리하고 true. 아니면 false — 다음 핸들러(다른 기능의 서비스)로 넘긴다.
    func receiveHotKey(_ hotKeyID: EventHotKeyID, isPressed: Bool) -> Bool
}

/// Carbon RegisterEventHotKey로 지정 조합만 등록한다. 타이핑 전체를 보지 않으며 별도 권한이 필요 없다.
/// 누르고 있는 동안 반복 통지가 와도 뗄 때까지 한 번만 통지한다.
/// 기능마다 서로 다른 signature로 인스턴스를 하나씩 만든다.
@MainActor
final class GlobalShortcutService<Action: Hashable & CaseIterable>: HotKeyReceiver {
    /// 단축키 눌림 통지. 메인 스레드에서 호출된다.
    var onTrigger: ((Action) -> Void)?

    private let signature: OSType
    private let hotKeyID: (Action) -> UInt32
    private var hotKeys: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// 눌린 채인 단축키와 마지막 눌림 신호 시각. 자동 반복을 무시하는 데 쓴다.
    /// 앱 전환 등으로 뗌 신호가 빠져도 다음 입력이 막히지 않게, 신호가 repeatWindow보다 오래 끊기면 새 입력으로 본다.
    private var pressed: [Action: TimeInterval] = [:]
    /// 키 자동 반복 간격(보통 30~80ms)보다 넉넉하고 사람이 다시 누르는 간격보다 짧은 값
    private static var repeatWindow: TimeInterval { 0.4 }

    /// signature: 기능별 고유 4글자 코드, hotKeyID: 동작별 고유 번호(1부터)
    init(signature: OSType, hotKeyID: @escaping (Action) -> UInt32) {
        self.signature = signature
        self.hotKeyID = hotKeyID
    }

    /// 기존 등록을 모두 해제하고 새로 등록한다. 실패한 동작만 돌려준다.
    func register(_ combos: [Action: KeyCombo]) -> [Action: ShortcutRegistrationError] {
        unregisterAll()
        installHandlerIfNeeded()

        var failures: [Action: ShortcutRegistrationError] = [:]
        var used: Set<KeyCombo> = []
        for action in Action.allCases {
            guard let combo = combos[action] else { continue }
            let key = KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers, keyLabel: "")
            guard used.insert(key).inserted else {
                failures[action] = .duplicate
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode),
                Self.carbonModifiers(combo.modifiers),
                EventHotKeyID(signature: signature, id: hotKeyID(action)),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeys[action] = ref
            } else {
                failures[action] = .systemRejected(status)
            }
        }
        return failures
    }

    func unregisterAll() {
        for ref in hotKeys.values {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        pressed.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            specs.count,
            &specs,
            Unmanaged.passUnretained(self as AnyObject).toOpaque(),
            &eventHandler
        )
    }

    fileprivate func receiveHotKey(_ id: EventHotKeyID, isPressed: Bool) -> Bool {
        guard id.signature == signature,
              let action = Action.allCases.first(where: { hotKeyID($0) == id.id }) else {
            return false
        }
        if isPressed {
            let now = ProcessInfo.processInfo.systemUptime
            let isRepeat = pressed[action].map { now - $0 < Self.repeatWindow } ?? false
            pressed[action] = now
            if !isRepeat {
                onTrigger?(action)
            }
        } else {
            pressed[action] = nil
        }
        return true
    }

    private static func carbonModifiers(_ modifiers: ModifierState) -> UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }
}

/// EventHandlerUPP용 C 함수. 이벤트에서 EventHotKeyID를 꺼내 서비스로 넘긴다.
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let object = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    // 애플리케이션 이벤트 대상의 핸들러는 메인 스레드에서 호출된다.
    let handled = MainActor.assumeIsolated {
        (object as? HotKeyReceiver)?.receiveHotKey(hotKeyID, isPressed: isPressed) ?? false
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
