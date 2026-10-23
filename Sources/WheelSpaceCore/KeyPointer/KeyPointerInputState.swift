import Foundation

public enum ArrowKey: Hashable, CaseIterable, Sendable {
    case left
    case right
    case up
    case down
}

public enum PointerButton: Equatable, Sendable {
    case left
    case right
}

/// 판정에 필요한 키 이벤트 한 건. 문자는 담지 않고 키 코드와 보조키만.
public struct KeyEventInput: Equatable, Sendable {
    public var keyCode: UInt16
    public var isDown: Bool
    /// 시스템 자동 반복 key-down
    public var isRepeat: Bool
    /// ⌃⌥⇧⌘ 4개 보조키, Caps Lock·Fn 제외
    public var modifiers: ModifierState
    /// 이벤트 시각 (시스템 가동 시간, 초). ⌥Tab 두 번 판정에 쓴다.
    public var timestamp: TimeInterval

    public init(keyCode: UInt16, isDown: Bool, isRepeat: Bool = false, modifiers: ModifierState, timestamp: TimeInterval = 0) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// 입력 판정 결과로 엔진이 실행할 일.
public enum KeyPointerCommand: Equatable, Sendable {
    case click(PointerButton)
    case doubleClick
    /// 드래그 시작 (왼쪽 버튼 down)
    case beginDrag
    /// 드래그 종료 (왼쪽 버튼 up) — 사용자 종료·Escape·특수키 해제·초기화 모두
    case endDrag
    /// 눌린 방향키·모드·빠른 이동이 바뀜 → 연속 이동/스크롤 갱신 (빈 방향이면 정지)
    case motionChanged
    /// 누르고 있는 키(⌃Tab의 Tab)를 아무 동작 없이 뗐을 때: 원래 입력을 앱에 다시 보낸다 (브라우저 탭 전환 등)
    case replayKey(keyCode: UInt16, modifiers: ModifierState)
    /// 고정 모드가 켜지거나 꺼짐 (메뉴 막대 아이콘·화면 안내)
    case lockChanged(Bool)
    /// ⌥Tab을 한 번 눌렀다 뗌: 두 번째 누름을 이만큼 기다린 뒤 flushPendingTap()을 불러 달라 (안 오면 ⌥Tab을 다시 보낸다)
    case schedulePendingTap(after: TimeInterval)
    /// 앱 단축키로 잠깐 해제됨: 이만큼 뒤 resumeIfIdle(now:)를 불러 달라 (그 사이 입력이 없으면 다시 포인터 모드)
    case scheduleResumeCheck(after: TimeInterval)
}

public struct KeyPointerDecision: Equatable, Sendable {
    /// true면 원래 키 이벤트를 앱에 전달하지 않는다
    public var consume: Bool
    public var commands: [KeyPointerCommand]
    /// true면 원래 이벤트에서 ⌘·⌃를 빼고 앱에 보낸다 (보조키를 누르는 동안 해제 중 ⌘↓ → ↓).
    /// 새 이벤트를 만들지 않고 고쳐 보내 자동 반복·Fn·키패드 표시가 그대로 남는다.
    public var stripsCommandControl: Bool
    /// 값이 있으면 원래 이벤트의 키 코드를 이 키로 바꿔 보낸다 (왼손 모드에서 ⌘를 쥔 채 W → ↑ 등)
    public var remappedKeyCode: UInt16?

    public init(
        consume: Bool, commands: [KeyPointerCommand] = [], stripsCommandControl: Bool = false, remappedKeyCode: UInt16? = nil
    ) {
        self.consume = consume
        self.commands = commands
        self.stripsCommandControl = stripsCommandControl
        self.remappedKeyCode = remappedKeyCode
    }

    public static let pass = KeyPointerDecision(consume: false)
}

/// 키 입력 → 소비 여부·명령 판정을 하는 순수 상태 머신. 이벤트 탭 스레드에서만 호출한다.
/// 소비한 key-down의 key-up도 반드시 소비해 앱에 짝 없는 입력이 가지 않게 한다.
public struct KeyPointerInputState {
    public enum Mode: Equatable, Sendable {
        case idle
        case moving
        case scrolling
    }

    public enum KeyCode {
        public static let left: UInt16 = 123
        public static let right: UInt16 = 124
        public static let down: UInt16 = 125
        public static let up: UInt16 = 126
        /// 왼쪽 클릭. Space는 ⌃⌘Space(이모지·기호 창)와 겹쳐 Return을 쓴다.
        public static let returnKey: UInt16 = 36
        public static let r: UInt16 = 15
        public static let d: UInt16 = 2
        public static let g: UInt16 = 5
        public static let escape: UInt16 = 53
    }

    public private(set) var shortcut: PointerShortcut
    public private(set) var mode: Mode = .idle
    /// 현재 모드에서 눌려 있는 방향 (자동 반복과 무관)
    public private(set) var activeArrows: Set<ArrowKey> = []
    public private(set) var isFast = false
    /// 느리게 키가 눌려 있는지 (빠르게보다 우선)
    public private(set) var isSlow = false
    public private(set) var isDragging = false

    /// key-down을 소비한 키 — 같은 키의 key-up을 소비하는 데 쓴다
    private var consumedKeys: Set<UInt16> = []
    /// 누르고 있는 키(Tab)가 지금 눌려 있는지와, 누르는 동안 이동·클릭 등에 쓰였는지
    public private(set) var isHeldKeyDown = false
    private var heldKeyUsed = false
    /// Tab을 누른 순간의 보조키 (다시 보낼 때 그대로 쓴다: ⌃Tab / ⌃⇧Tab)
    private var heldKeyModifiers: ModifierState = []
    /// 누르고 있는 일반 스크롤·빠르게 키의 키 코드. 방향키 이벤트에 표시되지 않아 누름·뗌으로 추적한다.
    private var heldModeKeys: Set<UInt16> = []
    /// 포인터 모드를 켤 때 쥐고 있던 필수 보조키(⌥)를 아직 떼지 않았다 — 그동안의 ⌥ 조합은 포인터 조작으로 본다
    /// (⌥⇥ 두 번 직후 ⌥를 쥔 채 바로 방향키로 움직이게). 한 번 떼면 ⌥ + 글자는 앱 단축키로 간다.
    private var baseHeldSinceLock = false
    /// 왼손 모드: 포인터 모드 중 ⌥⇧⇥ 두 번으로 들어온 경우. ESDF·A·W·Space·R·G가 왼손 배치로 동작한다.
    public private(set) var isLeftHandMode = false
    /// 포인터 모드가 마지막으로 꺼질 때 왼손 모드였는지 — 앱 단축키 잠깐 해제에서 돌아올 때 되살린다
    private var suspendedLeftHand = false
    /// 왼손 모드에서 누르고 있는 이동·스크롤 키와 그 방향 (뗄 때 그 키가 넣은 방향만 뺀다)
    private var leftHandArrows: [UInt16: ArrowKey] = [:]
    /// 왼손 모드에서 누른 키 — 뗌을 왼손 배치로 처리한다 (일반 포인터 모드의 F 드래그 등과 섞이지 않게)
    private var leftHandPressedKeys: Set<UInt16> = []
    /// 마지막으로 받은 보조키. 일반 스크롤·빠르게 키를 누르거나 뗄 때 모드·속도를 다시 계산하는 데 쓴다.
    private var lastModifiers: ModifierState = []

    /// 고정 모드: 필수 보조키·누르고 있는 키 없이 방향키·동작 키·스크롤·빠르게 키가 동작한다
    public private(set) var isLocked = false
    /// ⌥Tab을 한 번 눌렀다 뗀 시각. 두 번째 누름을 기다리는 동안만 값이 있다.
    private var pendingTapAt: TimeInterval?
    /// 누르고 있는 키를 두 번 누른 것으로 보는 간격
    public static let doubleTapInterval: TimeInterval = 0.35

    /// 앱 단축키로 잠깐 해제된 상태 (포인터 모드는 꺼져 있다). ↩·Esc를 누르거나 단축키 뒤 입력이 없으면 다시 켠다.
    public private(set) var isSuspended = false
    /// 잠깐 해제가 "보조키를 누르는 동안만"인지 (아니면 입력 없음·↩·Esc로 돌아온다)
    public private(set) var suspendsWhileHeld = false
    /// 보조키를 누르는 동안 해제 중 ⇧를 눌렀고 아직 다른 키를 안 눌렀다 — 그대로 떼면 완전히 해제
    private var shiftTapPending = false
    /// WheelSpace의 다른 기능 단축키(창 포커스 이동 ⌃⌥←, 겹친 창 넘기기 등). 앱 단축키로 보지 않고
    /// 잠깐 해제·⌘ 빼기도 하지 않아 그대로 그 기능에 간다. 엔진이 넣어 준다.
    public var ownShortcuts: [KeyCombo] = []
    /// ⌘·⌃를 빼고 보낸 누름의 키 — 뗌도 같이 빼서 보낸다 (그 사이 ⌘를 떼도)
    /// 값은 바꿔 보낸 키 코드 (바꾸지 않았으면 nil)
    private var strippedKeys: [UInt16: UInt16?] = [:]
    private var suspendedAt: TimeInterval = 0
    /// 잠깐 해제 뒤 다른 키를 눌렀는지 (팝업·목록·검색창을 쓰는 중)
    private var suspendInteracted = false
    /// 잠깐 해제 뒤 이 시간 동안 아무 키도 안 누르면 단축키가 바로 끝난 것으로 보고 다시 켠다
    public static let suspendIdleResume: TimeInterval = 0.7
    /// 보조키를 누르는 동안만 해제일 때 ⌘·⌃를 빼고 보내는 키: 방향키, ↩, 키패드 Enter, Esc
    static let strippedKeyCodes: Set<UInt16> = [123, 124, 125, 126, 36, 76, 53]
    /// 잠깐 해제에서 팝업·목록을 끝내는 키: ↩, 키패드 Enter, Esc
    public static let suspendEndKeyCodes: Set<UInt16> = [36, 76, 53]

    public init(shortcut: PointerShortcut) {
        self.shortcut = shortcut
    }

    /// 프리셋으로 시작 (테스트·이전 호출부 편의)
    public init(modifierPair: PointerModifierPair) {
        self.init(shortcut: modifierPair.shortcut)
    }

    /// 설정 변경: 진행 중인 이동·드래그를 끝낸다. 소비 중인 키 기록은 유지(그 키들의 key-up은 계속 소비).
    public mutating func update(shortcut: PointerShortcut) -> [KeyPointerCommand] {
        self.shortcut = shortcut
        return stopAll()
    }

    public mutating func handleKey(_ input: KeyEventInput) -> KeyPointerDecision {
        // 두 번째 누름을 기다리던 ⌥Tab: 누르고 있는 키가 아닌 다른 키가 오면 기다리던 입력을 먼저 다시 보낸다
        var flushed: [KeyPointerCommand] = []
        if input.isDown, pendingTapAt != nil, input.keyCode != shortcut.heldKey?.keyCode {
            flushed = flushPendingTap()
        }
        var decision = decide(input)
        decision.commands = flushed + decision.commands
        return decision
    }

    private mutating func decide(_ input: KeyEventInput) -> KeyPointerDecision {
        let code = input.keyCode
        let heldKey = shortcut.heldKey?.keyCode
        lastModifiers = input.modifiers

        if !input.isDown, let remapped = strippedKeys.removeValue(forKey: code) {
            return KeyPointerDecision(consume: false, stripsCommandControl: true, remappedKeyCode: remapped)
        }

        if let decision = decideLeftHand(input) {
            return decision
        }

        // 포인터 모드에서 Q: 일반 ↔ 왼손 모드 (Q를 다른 역할에 쓰고 있으면 하지 않는다)
        if isLocked, input.isDown, !input.isRepeat, code == LeftHandLayout.switchMode, input.modifiers.isEmpty,
           !consumedKeys.contains(code), !isPointerKey(code) {
            consumedKeys.insert(code)
            return KeyPointerDecision(consume: true, commands: switchLeftHandMode())
        }

        if isSuspended, input.isDown, let decision = decideWhileSuspended(input) {
            return decision
        }

        // 포인터 모드 해제 단축키 (⌘Space 등): 포인터 모드를 끄고 단축키는 그대로 앱에 전달한다
        if isLocked, input.isDown, !input.isRepeat, shortcut.isExitShortcut(keyCode: code, modifiers: input.modifiers) {
            return KeyPointerDecision(consume: false, commands: setLocked(false))
        }

        // 포인터 모드 켜고 끄는 단축키
        if case .shortcut(let combo) = shortcut.lockToggle, input.isDown, !input.isRepeat,
           code == combo.keyCode, input.modifiers == combo.modifiers {
            consumedKeys.insert(code)
            return KeyPointerDecision(consume: true, commands: setLocked(!isLocked))
        }

        // 스크롤·빠르게 보조키를 뺀 나머지가 필수 보조키와 같아야 조합이다 (일반 키인 모드 키는 보조키에 없다).
        // 포인터 모드에서는 필수 보조키·누르고 있는 키 없이도 조합이다.
        // 느리게 키가 보조키(⌃ 등)여도 같다
        let coreModifiers = input.modifiers.subtracting(shortcut.fastModifier).subtracting(shortcut.scrollModifier)
            .subtracting(shortcut.slowModifier)
        // 포인터 모드에서는 보조키 없이 조작한다. 필수 보조키(⌥) 조합은 누르고 있는 키(Tab)를 함께 누를 때만
        // 포인터 조작으로 본다 — ⌥D·⌥W 같은 앱의 ⌥ 단축키를 가리지 않게
        let baseComboAllowed = !isLocked || heldKey == nil || isHeldKeyDown || baseHeldSinceLock
        let coreMatches = (coreModifiers == shortcut.base && baseComboAllowed) || (isLocked && coreModifiers.isEmpty)
        let holdSatisfied = heldKey == nil || isHeldKeyDown || isLocked

        // 누르고 있는 키(⌃Tab의 Tab): 누르는 순간 잡아 두고, 아무 데도 안 쓰고 떼면 원래 입력을 다시 보낸다
        if let heldKey, code == heldKey {
            if !input.isDown, isHeldKeyDown, consumedKeys.remove(code) != nil {
                isHeldKeyDown = false
                var commands = stopAll()
                if !heldKeyUsed {
                    if shortcut.lockToggle == .doubleTapHeldKey {
                        // 두 번째 누름이 오는지 기다린다. 안 오면 엔진 타이머가 flushPendingTap()으로 다시 보낸다.
                        pendingTapAt = input.timestamp
                        commands.append(.schedulePendingTap(after: Self.doubleTapInterval))
                    } else {
                        commands.append(.replayKey(keyCode: code, modifiers: heldKeyModifiers))
                    }
                }
                return KeyPointerDecision(consume: true, commands: commands)
            }
            if input.isDown, !input.isRepeat, !consumedKeys.contains(code), coreModifiers == shortcut.base {
                isHeldKeyDown = true
                heldKeyUsed = false
                heldKeyModifiers = input.modifiers
                consumedKeys.insert(code)
                if let tappedAt = pendingTapAt {
                    if input.timestamp - tappedAt <= Self.doubleTapInterval {
                        // ⌥Tab 두 번: 포인터 모드 켜기·끄기. ⇧를 더하면(⌥⇧⇥ 두 번) 왼손 모드로 켠다.
                        // 이번 누름은 뗄 때 다시 보내지 않는다.
                        pendingTapAt = nil
                        heldKeyUsed = true
                        let leftHand = input.modifiers.contains(.shift)
                        // 일반 포인터 모드에서 ⌥⇧⇥ 두 번은 끄지 않고 왼손 모드로 바꾼다
                        if isLocked, leftHand, !isLeftHandMode {
                            return KeyPointerDecision(consume: true, commands: switchLeftHandMode())
                        }
                        return KeyPointerDecision(consume: true, commands: setLocked(!isLocked, leftHand: leftHand))
                    }
                    // 간격이 지난 누름: 기다리던 첫 ⌥Tab을 먼저 보내고 새로 잡는다
                    return KeyPointerDecision(consume: true, commands: flushPendingTap())
                }
                return KeyPointerDecision(consume: true)
            }
        } else if input.isDown, isHeldKeyDown {
            // Tab을 누른 동안 다른 키를 썼으면 뗄 때 ⌃Tab을 다시 보내지 않는다
            heldKeyUsed = true
        }

        // 일반 스크롤·빠르게 키: 조합이 활성일 때 누르면 잡아 두고, 누르고 있는 동안만 스크롤·빠르게
        if code == shortcut.scrollHeldKey?.keyCode || code == shortcut.fastHeldKey?.keyCode
            || code == shortcut.slowHeldKey?.keyCode {
            if !input.isDown, heldModeKeys.remove(code) != nil {
                consumedKeys.remove(code)
                return KeyPointerDecision(consume: true, commands: updateModes())
            }
            if input.isDown, !input.isRepeat, !consumedKeys.contains(code), holdSatisfied, coreMatches {
                heldModeKeys.insert(code)
                consumedKeys.insert(code)
                return KeyPointerDecision(consume: true, commands: updateModes())
            }
        }

        if !input.isDown {
            // 이동 전 앱에 전달했던 키의 key-up은 삼키지 않는다
            guard consumedKeys.remove(code) != nil else { return .pass }
            if let arrow = Self.arrow(for: code), activeArrows.remove(arrow) != nil {
                if activeArrows.isEmpty { mode = .idle }
                return KeyPointerDecision(consume: true, commands: [.motionChanged])
            }
            // 드래그 키를 떼면 드래그 끝 (누르고 있는 동안만 왼쪽 버튼이 눌린 상태)
            if code == shortcut.dragKey.keyCode, isDragging {
                isDragging = false
                return KeyPointerDecision(consume: true, commands: [.endDrag])
            }
            return KeyPointerDecision(consume: true)
        }

        // 이미 소비 중인 키의 자동 반복 — 반복 횟수에 이동량이 묶이지 않게 명령 없이 소비
        if consumedKeys.contains(code) { return KeyPointerDecision(consume: true) }
        // 조합 전부터 누르고 있던 키의 자동 반복은 가로채지 않는다 (다음 새 누름부터)
        if input.isRepeat { return .pass }

        if code == KeyCode.escape, isDragging {
            isDragging = false
            consumedKeys.insert(code)
            return KeyPointerDecision(consume: true, commands: [.endDrag])
        }

        // 누르고 있는 키가 필요한 조합은 그 키가 눌려 있을 때만
        guard holdSatisfied, coreMatches else { return passOrSwallowWhileLocked(input) }
        let isScrollCombo = isScrollActive(input.modifiers)
        let isFastHeld = isFastActive(input.modifiers)

        if let arrow = Self.arrow(for: code) {
            consumedKeys.insert(code)
            isFast = isFastHeld
            isSlow = isSlowActive(input.modifiers)
            if !isScrollCombo {
                // 모드는 특수키가 바뀔 때만 전환한다
                guard mode != .scrolling else { return KeyPointerDecision(consume: true) }
                mode = .moving
            } else {
                // 드래그 중에도 스크롤한다 (버튼을 누른 채 휠을 굴리듯 선택 확장·긴 목록으로 끌어 넣기)
                guard mode != .moving else { return KeyPointerDecision(consume: true) }
                mode = .scrolling
            }
            activeArrows.insert(arrow)
            return KeyPointerDecision(consume: true, commands: [.motionChanged])
        }

        // 동작 키는 스크롤 조합이 아닐 때만. 빠르게·느리게 키를 누른 채로도 클릭·드래그한다
        // (빠르게 옮기다 바로 드래그를 시작하거나, 느리게 맞춘 자리에서 클릭). 단 누르고 있는 키(Tab) 없는 조합은
        // ⌃⇧⌘D 같은 앱 단축키와 겹치므로 포인터 모드가 아니면 빠르게·느리게와 함께 쓰지 않는다
        let speedKeyHeld = isFastHeld || isSlowActive(input.modifiers)
        guard !isScrollCombo, !speedKeyHeld || shortcut.heldKey != nil || isLocked else {
            return passOrSwallowWhileLocked(input)
        }
        // 포인터 모드의 ⌘R·⌃D 등은 동작 키가 아니라 앱 단축키다
        let isAppShortcut = isLocked && (input.modifiers.contains(.command) || input.modifiers.contains(.control))
        guard !isAppShortcut, let action = shortcut.action(forKeyCode: code) else { return passOrSwallowWhileLocked(input) }
        let command: KeyPointerCommand?
        switch action {
        case .leftClick: command = isDragging ? nil : .click(.left)
        case .rightClick: command = isDragging ? nil : .click(.right)
        case .doubleClick: command = isDragging ? nil : .doubleClick
        case .drag:
            // 누르면 시작, 떼면 끝 (key-up 처리). 이미 드래그 중이면 무시
            command = isDragging ? nil : .beginDrag
            isDragging = true
        }
        consumedKeys.insert(code)
        return KeyPointerDecision(consume: true, commands: command.map { [$0] } ?? [])
    }

    /// flagsChanged. 필수 특수키가 빠지면 이동·드래그를 끝낸다. 스크롤 키나 Shift가 바뀌면 모드·속도를 갱신.
    public mutating func handleModifiers(_ modifiers: ModifierState) -> [KeyPointerCommand] {
        let previous = lastModifiers
        lastModifiers = modifiers
        if !modifiers.isSuperset(of: shortcut.base) { baseHeldSinceLock = false }
        if isSuspended, suspendsWhileHeld {
            // ⌘·⌃를 모두 떼면 다시 포인터 모드
            if !modifiers.contains(.command), !modifiers.contains(.control) {
                return setLocked(true) + updateModes()
            }
            // ⌘를 쥔 채 ⇧만 눌렀다 떼면 완전히 해제 (목록·입력창을 평소 키보드로 쓰기). ⌘⇧F처럼 다른 키를 함께 누르면 해당 없음
            if modifiers.contains(.shift), !previous.contains(.shift) {
                shiftTapPending = true
            } else if !modifiers.contains(.shift), previous.contains(.shift), shiftTapPending {
                shiftTapPending = false
                isSuspended = false
                suspendsWhileHeld = false
            }
            return []
        }
        // 포인터 모드는 필수 보조키·누르고 있는 키 없이 동작한다
        if isLocked { return updateModes() }
        guard modifiers.isSuperset(of: shortcut.base) else { return stopAll() }
        // 누르고 있는 키가 필요한 조합에서 그 키가 아직 안 눌렸으면 보조키만 눌린 대기 상태
        if shortcut.heldKey != nil, !isHeldKeyDown { return [] }
        return updateModes()
    }

    /// 고정 모드 켜기·끄기. 끌 때는 진행 중 이동·드래그도 끝낸다. 상태가 바뀌면 .lockChanged를 덧붙인다.
    /// leftHand: 켤 때 왼손 모드인지. nil이면 잠깐 해제에서 돌아올 때는 그 전 모드, 그 밖에는 일반 포인터 모드.
    public mutating func setLocked(_ locked: Bool, leftHand: Bool? = nil) -> [KeyPointerCommand] {
        if locked, !isLocked {
            isLeftHandMode = leftHand ?? (isSuspended ? suspendedLeftHand : false)
            // 켜는 순간 필수 보조키를 쥐고 있으면(⌥⇥ 두 번) 뗄 때까지 포인터 조작용
            baseHeldSinceLock = !shortcut.base.isEmpty && lastModifiers.isSuperset(of: shortcut.base)
        } else if !locked, isLocked {
            suspendedLeftHand = isLeftHandMode
            isLeftHandMode = false
        }
        // 직접 켜고 끄면 잠깐 해제도 끝난다
        isSuspended = false
        suspendsWhileHeld = false
        shiftTapPending = false
        guard locked != isLocked else { return [] }
        isLocked = locked
        let commands = locked ? [] : stopAll()
        return commands + [.lockChanged(locked)]
    }

    /// 두 번째 누름을 기다리던 ⌥Tab: 기다림이 끝났거나(엔진 타이머) 다른 키가 와서 더 기다리지 않을 때 원래 입력을 다시 보낸다
    public mutating func flushPendingTap() -> [KeyPointerCommand] {
        guard pendingTapAt != nil, let heldKey = shortcut.heldKey else { return [] }
        pendingTapAt = nil
        return [.replayKey(keyCode: heldKey.keyCode, modifiers: heldKeyModifiers)]
    }

    /// 포인터 모드의 나머지 키: ⌘·⌃ 단축키는 앱으로(앱 단축키면 설정대로 잠깐·완전히 해제), Esc·Fn·기능 키도 앱으로,
    /// 입력 키(i)는 입력 모드로 돌아가고, 그 밖의 글자·숫자·Space·Tab 등은 앱에 보내지 않는다 (vi 일반 모드처럼).
    /// 포인터 모드가 아니면 그대로 통과.
    private mutating func passOrSwallowWhileLocked(_ input: KeyEventInput) -> KeyPointerDecision {
        guard isLocked else { return .pass }
        // ⌘B 같은 앱 단축키: 잠깐·완전히 해제하고 단축키는 앱에 그대로 (띄운 팝업을 바로 방향키·↩로 고르게)
        if input.isDown, !input.isRepeat, isAppShortcut(input) {
            let commands: [KeyPointerCommand]
            switch shortcut.appShortcutAction {
            case .whileHeld:
                commands = setLocked(false)
                isSuspended = true
                suspendsWhileHeld = true
            case .suspend: commands = suspend(at: input.timestamp)
            case .exit, .ignore: commands = setLocked(false)
            }
            return KeyPointerDecision(consume: false, commands: commands)
        }
        // ⌥ 단축키(⌥↩ 등)도 앱으로 — 포인터 모드는 보조키 없이 누른 글자만 막는다
        if input.modifiers.contains(.command) || input.modifiers.contains(.control) || input.modifiers.contains(.option)
            || input.keyCode == KeyCode.escape
            || Self.lockedPassThroughKeyCodes.contains(input.keyCode) {
            return .pass
        }
        consumedKeys.insert(input.keyCode)
        if input.keyCode == shortcut.insertKey.keyCode, input.modifiers.isEmpty {
            return KeyPointerDecision(consume: true, commands: setLocked(false))
        }
        return KeyPointerDecision(consume: true)
    }

    /// 포인터 모드에서도 앱·시스템에 보내는 글자 아닌 키: 🌐/Fn(입력 소스 전환·이모지), F1~F20,
    /// Fn + 방향키·Delete가 만드는 Home·End·Page Up·Page Down·앞으로 지우기, Help.
    /// 막으면 Fn 동작과 기능 키가 포인터 모드 동안 듣지 않는다.
    static let lockedPassThroughKeyCodes: Set<UInt16> = [
        179, 63,                                                // 🌐/Fn
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1~F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13~F20
        114, 115, 116, 117, 119, 121,                           // Help, Home, Page Up, 앞으로 지우기, End, Page Down
    ]

    private func isOwnShortcut(_ input: KeyEventInput) -> Bool {
        ownShortcuts.contains { $0.keyCode == input.keyCode && $0.modifiers == input.modifiers }
    }

    /// 앱 단축키 (유지할 단축키·WheelSpace 기능 단축키 제외)
    private func isAppShortcut(_ input: KeyEventInput) -> Bool {
        shortcut.isAppShortcut(keyCode: input.keyCode, modifiers: input.modifiers) && !isOwnShortcut(input)
    }

    /// 잠깐 해제: 포인터 모드를 끄고 입력이 없는지 확인을 예약한다
    private mutating func suspend(at time: TimeInterval) -> [KeyPointerCommand] {
        let commands = setLocked(false)
        isSuspended = true
        suspendedAt = time
        suspendInteracted = false
        return commands + [.scheduleResumeCheck(after: Self.suspendIdleResume)]
    }

    /// 잠깐 해제 중 키 누름. nil이면 평소대로 판정한다 (잠깐 해제 중에도 ⌥⇥ 조합·⌥⇥ 두 번은 그대로 쓴다).
    private mutating func decideWhileSuspended(_ input: KeyEventInput) -> KeyPointerDecision? {
        // ⇧와 함께 다른 키를 눌렀으면 ⇧ 한 번 누르기가 아니다
        shiftTapPending = false
        // 보조키를 누르는 동안: ⌘·⌃를 누른 채 누른 방향키·↩·Esc는 ⌘·⌃를 빼고 보낸다 (자동 반복 포함)
        // — ⌘B로 연 목록을 ⌘를 쥔 채 ↓↓↩로 고르고, ⌘를 떼면 포인터 모드로 돌아온다
        let hasCommandControl = input.modifiers.contains(.command) || input.modifiers.contains(.control)
        if suspendsWhileHeld, shortcut.stripsHeldModifier, hasCommandControl, !isOwnShortcut(input) {
            // 왼손 모드에서 잠깐 해제됐으면 WASD = 방향키, Space = ↩ 로 바꿔 보낸다 (손을 옮기지 않고 목록 고르기)
            let remapped = suspendedLeftHand ? LeftHandLayout.suspendedRemap[input.keyCode] : nil
            if remapped != nil || Self.strippedKeyCodes.contains(input.keyCode) {
                strippedKeys[input.keyCode] = remapped
                return KeyPointerDecision(consume: false, stripsCommandControl: true, remappedKeyCode: remapped)
            }
        }
        guard !input.isRepeat else { return nil }
        // 해제 단축키(⌘Space 등): 완전히 해제
        if shortcut.isExitShortcut(keyCode: input.keyCode, modifiers: input.modifiers) {
            isSuspended = false
            return .pass
        }
        // 보조키를 누르는 동안: 다른 키도 모두 앱으로 (⌘를 떼면 handleModifiers가 다시 켠다)
        if suspendsWhileHeld { return nil }
        // 다른 앱 단축키: 잠깐 해제를 새로 시작 (⌘B 뒤 바로 ⌘⌥B 등)
        if isAppShortcut(input) {
            suspendedAt = input.timestamp
            suspendInteracted = false
            return KeyPointerDecision(consume: false, commands: [.scheduleResumeCheck(after: Self.suspendIdleResume)])
        }
        // ↩·Esc: 팝업·목록을 끝냈다 — 키는 앱에 보내고 다시 포인터 모드 (key-up은 소비 기록이 없어 그대로 간다)
        if input.modifiers.isEmpty, Self.suspendEndKeyCodes.contains(input.keyCode) {
            return KeyPointerDecision(consume: false, commands: setLocked(true))
        }
        suspendInteracted = true
        return nil
    }

    /// 엔진 타이머: 잠깐 해제 뒤 입력이 없었으면 다시 포인터 모드. 단축키를 다시 눌러 시작 시각이 바뀌었으면 남은 시간만큼 다시 예약.
    public mutating func resumeIfIdle(now: TimeInterval) -> [KeyPointerCommand] {
        guard isSuspended, !suspendsWhileHeld, !suspendInteracted else { return [] }
        let remaining = Self.suspendIdleResume - (now - suspendedAt)
        // 타이머 오차로 조금 일찍 불릴 수 있다
        guard remaining <= 0.01 else { return [.scheduleResumeCheck(after: remaining)] }
        return setLocked(true)
    }

    /// 포인터 모드 중 일반 ↔ 왼손 모드 바꾸기. 진행 중 이동·드래그는 끝낸다 (상태 표시는 엔진이 알린다).
    private mutating func switchLeftHandMode() -> [KeyPointerCommand] {
        let commands = stopAll()
        isLeftHandMode.toggle()
        leftHandArrows.removeAll()
        return commands
    }

    /// 사용자가 지정한 포인터 키(동작·입력·누르고 있는·일반 모드 키)인지
    private func isPointerKey(_ code: UInt16) -> Bool {
        shortcut.action(forKeyCode: code) != nil || code == shortcut.insertKey.keyCode || code == shortcut.heldKey?.keyCode
            || [shortcut.scrollHeldKey, shortcut.fastHeldKey, shortcut.slowHeldKey].contains { $0?.keyCode == code }
    }

    /// 왼손 모드 배치. 해당 없으면 nil (평소 판정으로).
    private mutating func decideLeftHand(_ input: KeyEventInput) -> KeyPointerDecision? {
        let code = input.keyCode
        guard LeftHandLayout.keyCodes.contains(code) else { return nil }

        // 뗌: 포인터 모드가 그 사이 꺼졌어도 왼손 모드에서 누른 키면 끝까지 처리한다
        if !input.isDown {
            guard leftHandPressedKeys.remove(code) != nil else { return nil }
            consumedKeys.remove(code)
            guard let arrow = leftHandArrows.removeValue(forKey: code) else { return KeyPointerDecision(consume: true) }
            // 같은 방향을 다른 키가 아직 누르고 있으면 그대로 (예: W와 R)
            guard !leftHandArrows.values.contains(arrow), activeArrows.remove(arrow) != nil else {
                return KeyPointerDecision(consume: true)
            }
            if activeArrows.isEmpty { mode = .idle }
            return KeyPointerDecision(consume: true, commands: [.motionChanged])
        }

        // 빠르게·느리게·스크롤 키로 정한 보조키만 함께 쓸 수 있다 (⌥Space 해제 단축키 등은 평소대로).
        // ⌘·⌃는 모드 키여도 빼서 ⌘S·⌘D 같은 앱 단축키를 가리지 않는다.
        let modeModifiers = shortcut.fastModifier.union(shortcut.scrollModifier).union(shortcut.slowModifier)
            .subtracting([.command, .control])
        guard isLocked, isLeftHandMode, input.modifiers.subtracting(modeModifiers).isEmpty else { return nil }
        // 이미 누르고 있는 키의 자동 반복 — 이동량이 반복 횟수에 묶이지 않게 명령 없이 소비
        if consumedKeys.contains(code) { return KeyPointerDecision(consume: true) }
        consumedKeys.insert(code)
        leftHandPressedKeys.insert(code)

        switch code {
        case LeftHandLayout.leftClick:
            return KeyPointerDecision(consume: true, commands: isDragging ? [] : [.click(.left)])
        case LeftHandLayout.rightClick:
            return KeyPointerDecision(consume: true, commands: isDragging ? [] : [.click(.right)])
        case LeftHandLayout.dragToggle:
            // 한 번 누르면 드래그 시작, 다시 누르면 놓기 (누른 채 이동하지 않아도 된다)
            isDragging.toggle()
            return KeyPointerDecision(consume: true, commands: [isDragging ? .beginDrag : .endDrag])
        default:
            break
        }

        // 이동(WASD)과 스크롤(R·F)은 따로 누른다: 하나를 누르는 동안 다른 쪽은 무시한다
        let scrollArrow = LeftHandLayout.scrollArrow(for: code)
        guard let arrow = scrollArrow ?? LeftHandLayout.arrow(for: code) else { return KeyPointerDecision(consume: true) }
        let newMode: Mode = scrollArrow != nil ? .scrolling : .moving
        guard mode == .idle || mode == newMode else { return KeyPointerDecision(consume: true) }
        isFast = isFastActive(input.modifiers)
        isSlow = isSlowActive(input.modifiers)
        mode = newMode
        leftHandArrows[code] = arrow
        activeArrows.insert(arrow)
        return KeyPointerDecision(consume: true, commands: [.motionChanged])
    }

    /// 스크롤 키가 눌려 있는지: 보조키면 modifiers에 포함, 일반 키면 heldModeKeys에 포함
    private func isScrollActive(_ modifiers: ModifierState) -> Bool {
        return isActive(shortcut.scrollKey, modifiers)
    }

    /// 빠르게 키가 눌려 있는지 (isScrollActive와 같은 규칙)
    private func isFastActive(_ modifiers: ModifierState) -> Bool {
        isActive(shortcut.fastKey, modifiers)
    }

    /// 느리게 키가 눌려 있는지 (없으면 false)
    private func isSlowActive(_ modifiers: ModifierState) -> Bool {
        guard let slowKey = shortcut.slowKey else { return false }
        return isActive(slowKey, modifiers)
    }

    private func isActive(_ modeKey: PointerModeKey, _ modifiers: ModifierState) -> Bool {
        switch modeKey {
        case .modifier(let modifier): return modifiers.isSuperset(of: modifier)
        case .key(let key): return heldModeKeys.contains(key.keyCode)
        }
    }

    /// 보조키 변화·일반 모드 키 누름·뗌 공통: 이동↔스크롤 전환(다음 새 방향키부터), 빠르게 갱신
    private mutating func updateModes() -> [KeyPointerCommand] {
        var commands: [KeyPointerCommand] = []
        let scrollHeld = isScrollActive(lastModifiers)
        if (mode == .moving && scrollHeld) || (mode == .scrolling && !scrollHeld) {
            // 다음 새 방향키 누름부터 새 모드로 시작한다
            activeArrows.removeAll()
            mode = .idle
            commands.append(.motionChanged)
        }
        let fast = isFastActive(lastModifiers)
        if fast != isFast {
            isFast = fast
            if !activeArrows.isEmpty { commands.append(.motionChanged) }
        }
        let slow = isSlowActive(lastModifiers)
        if slow != isSlow {
            isSlow = slow
            if !activeArrows.isEmpty, !commands.contains(.motionChanged) { commands.append(.motionChanged) }
        }
        return commands
    }

    /// 일시정지·잠금·권한 회수·설정 창 열기 등: 연속 동작과 드래그를 즉시 끝낸다.
    public mutating func stopAll() -> [KeyPointerCommand] {
        var commands: [KeyPointerCommand] = []
        if isDragging {
            isDragging = false
            commands.append(.endDrag)
        }
        if mode != .idle || !activeArrows.isEmpty {
            activeArrows.removeAll()
            mode = .idle
            commands.append(.motionChanged)
        }
        // consumedKeys는 유지: 아직 안 뗀 키의 key-up을 소비해야 한다
        return commands
    }

    /// 누르고 있는 키(Tab)를 누른 동안 다른 기능(창 목록 전환기)이 키를 가져갔을 때: 뗄 때 원래 입력을 다시 보내거나
    /// 두 번 누르기의 첫 번째로 세지 않는다
    public mutating func markHeldKeyUsed() {
        if isHeldKeyDown { heldKeyUsed = true }
    }

    /// 탭 중단 등으로 누르고 있는 키의 뗌을 놓쳤을 수 있을 때: 눌림 상태를 풀고, 나중에 뗌이 와도 원래 입력을 다시 보내지 않는다.
    /// consumedKeys는 유지해 그 키의 key-up은 계속 소비한다.
    public mutating func releaseHeldKey() {
        isHeldKeyDown = false
        heldKeyUsed = true
        // 일반 스크롤·빠르게 키의 뗌도 놓쳤을 수 있다
        heldModeKeys.removeAll()
        leftHandArrows.removeAll()
        // 중단 중에 기다리던 ⌥Tab은 버린다
        pendingTapAt = nil
    }

    /// 엔진이 드래그 시작을 거절했을 때 (실제 마우스 왼쪽 버튼이 이미 눌려 있는 등)
    public mutating func dragRejected() {
        isDragging = false
    }

    static func arrow(for keyCode: UInt16) -> ArrowKey? {
        switch keyCode {
        case KeyCode.left: return .left
        case KeyCode.right: return .right
        case KeyCode.down: return .down
        case KeyCode.up: return .up
        default: return nil
        }
    }
}
