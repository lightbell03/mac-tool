import Foundation

/// 창 목록 전환기가 엔진·화면에 시키는 일
public enum WindowSwitcherCommand: Equatable, Sendable {
    /// 현재 모니터의 창 목록을 만들어 listLoaded(count:)로 알려 달라 (AX 호출이 있어 비동기)
    case loadList
    /// 목록 패널을 띄우거나 선택을 옮긴다
    case show(selection: Int)
    /// 이 자리의 창을 앞으로 가져온다 (패널 닫기 포함)
    case confirm(index: Int)
    /// 아무것도 하지 않고 패널을 닫는다
    case cancel
}

public struct WindowSwitcherDecision: Equatable, Sendable {
    /// true면 원래 키 이벤트를 앱에 전달하지 않는다
    public var consume: Bool
    public var commands: [WindowSwitcherCommand]

    public init(consume: Bool, commands: [WindowSwitcherCommand] = []) {
        self.consume = consume
        self.commands = commands
    }

    public static let pass = WindowSwitcherDecision(consume: false)
}

/// ⌘Tab 같은 창 목록 전환기의 입력 판정. 순수 상태 기계 — 이벤트 탭 스레드에서만 부른다.
/// 보조키를 누른 채 전환 키 → 목록 열기·다음, ⇧를 더하면 이전, 방향키로 이동, 보조키를 떼거나 ↩ → 확정, Esc → 취소.
/// 목록은 비동기로 오므로, 그 전에 들어온 이동·확정은 모아 두었다가 목록이 오면 적용한다.
/// 0번 자리는 현재 창이라, 처음 열 때 선택은 1번(바로 뒤 창)이다.
public struct WindowSwitcherState {
    public enum Phase: Equatable, Sendable {
        case idle
        /// 목록을 기다리는 중: 그동안 누른 이동 칸 수(첫 누름 포함), 보조키를 이미 뗐는지
        case loading(steps: Int, confirmWhenLoaded: Bool)
        /// 패널 표시 중
        case showing(count: Int, selection: Int)
    }

    public enum KeyCode {
        public static let escape: UInt16 = 53
        public static let returnKey: UInt16 = 36
        public static let left: UInt16 = 123
        public static let right: UInt16 = 124
        public static let down: UInt16 = 125
        public static let up: UInt16 = 126
    }

    public private(set) var trigger: KeyCombo
    public private(set) var phase: Phase = .idle
    /// key-down을 소비한 키 — 같은 키의 key-up도 소비한다
    private var consumedKeys: Set<UInt16> = []

    public init(trigger: KeyCombo) {
        self.trigger = trigger
    }

    /// 설정 변경: 열려 있으면 취소한다
    public mutating func update(trigger: KeyCombo) -> [WindowSwitcherCommand] {
        self.trigger = trigger
        return cancel()
    }

    public mutating func handleKey(_ input: KeyEventInput) -> WindowSwitcherDecision {
        let code = input.keyCode
        if !input.isDown {
            return consumedKeys.remove(code) != nil ? WindowSwitcherDecision(consume: true) : .pass
        }

        // 보조키는 trigger 그대로이거나 ⇧를 더한 것 (⇧ = 이전)
        let isTriggerKey = code == trigger.keyCode
            && (input.modifiers == trigger.modifiers || input.modifiers == trigger.modifiers.union(.shift))
        let backward = input.modifiers.contains(.shift) && !trigger.modifiers.contains(.shift)

        if phase == .idle {
            guard isTriggerKey, !input.isRepeat else { return .pass }
            consumedKeys.insert(code)
            phase = .loading(steps: backward ? -1 : 1, confirmWhenLoaded: false)
            return WindowSwitcherDecision(consume: true, commands: [.loadList])
        }

        // 열려 있는 동안
        let step: Int
        switch code {
        case _ where isTriggerKey: step = backward ? -1 : 1
        case KeyCode.left, KeyCode.up: step = -1
        case KeyCode.right, KeyCode.down: step = 1
        case KeyCode.returnKey:
            consumedKeys.insert(code)
            return WindowSwitcherDecision(consume: true, commands: confirmNow())
        case KeyCode.escape:
            consumedKeys.insert(code)
            return WindowSwitcherDecision(consume: true, commands: cancel())
        default:
            // 그 밖의 키: 취소하고 그 키는 앱으로
            return WindowSwitcherDecision(consume: false, commands: cancel())
        }
        consumedKeys.insert(code)
        switch phase {
        case .loading(let steps, let confirmWhenLoaded):
            phase = .loading(steps: steps + step, confirmWhenLoaded: confirmWhenLoaded)
            return WindowSwitcherDecision(consume: true)
        case .showing(let count, let selection):
            let next = Self.wrap(selection + step, count: count)
            phase = .showing(count: count, selection: next)
            return WindowSwitcherDecision(consume: true, commands: [.show(selection: next)])
        case .idle:
            return WindowSwitcherDecision(consume: true)
        }
    }

    /// flagsChanged: trigger의 보조키가 하나라도 빠지면 확정 (⌘Tab처럼 떼는 순간 고른다)
    public mutating func handleModifiers(_ modifiers: ModifierState) -> [WindowSwitcherCommand] {
        guard phase != .idle, !modifiers.isSuperset(of: trigger.modifiers) else { return [] }
        if case .loading(let steps, _) = phase {
            phase = .loading(steps: steps, confirmWhenLoaded: true)
            return []
        }
        return confirmNow()
    }

    /// 목록이 왔다: count = 현재 창 포함 창 수
    public mutating func listLoaded(count: Int) -> [WindowSwitcherCommand] {
        guard case .loading(let steps, let confirmWhenLoaded) = phase else { return [] }
        // 옮겨 갈 창이 없음
        guard count >= 2 else {
            phase = .idle
            return [.cancel]
        }
        // 첫 누름 +1 → 1번(바로 뒤 창), ⇧ 첫 누름 −1 → 맨 끝
        let selection = Self.wrap(steps, count: count)
        if confirmWhenLoaded {
            phase = .idle
            return [.confirm(index: selection)]
        }
        phase = .showing(count: count, selection: selection)
        return [.show(selection: selection)]
    }

    /// 탭 중단·잠금 등: 열려 있으면 취소
    public mutating func cancel() -> [WindowSwitcherCommand] {
        guard phase != .idle else { return [] }
        phase = .idle
        return [.cancel]
    }

    /// 지금 선택으로 확정. 목록을 아직 기다리면 오는 대로 확정한다.
    private mutating func confirmNow() -> [WindowSwitcherCommand] {
        switch phase {
        case .idle:
            return []
        case .loading(let steps, _):
            phase = .loading(steps: steps, confirmWhenLoaded: true)
            return []
        case .showing(_, let selection):
            phase = .idle
            return [.confirm(index: selection)]
        }
    }

    /// 0..<count 안으로 순환
    static func wrap(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}
