import Foundation

/// 마우스 뒤로가기/앞으로가기 버튼. CGEvent의 버튼 번호 3 / 4.
public enum MouseSideButton: Hashable, Sendable {
    case back
    case forward

    public init?(buttonNumber: Int64) {
        switch buttonNumber {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

public struct ButtonInput: Equatable, Sendable {
    public var button: MouseSideButton
    public var isDown: Bool
    public var modifiers: ModifierState
    /// 단조 증가 시각(초). 테스트에서 외부 주입.
    public var timestamp: TimeInterval

    public init(button: MouseSideButton, isDown: Bool, modifiers: ModifierState, timestamp: TimeInterval) {
        self.button = button
        self.isDown = isDown
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// 사이드 버튼으로 통과/차단/전환을 판정하는 순수 로직. 이벤트 탭 스레드에서만 호출한다.
/// 결과 타입은 ScrollDecision을 함께 쓴다.
public struct ButtonPolicy {
    public private(set) var configuration: PolicyConfiguration

    /// down을 차단한 버튼. 짝이 되는 up도 차단해서 앱에 짝 없는 up이 가지 않게 한다.
    private var consumedButtons: Set<MouseSideButton> = []
    private var lastSwitchTime: TimeInterval?

    public init(configuration: PolicyConfiguration) {
        self.configuration = configuration
    }

    /// 설정 변경. 이미 차단 중인 버튼의 up은 계속 차단해야 하므로 consumedButtons는 유지한다.
    public mutating func update(configuration: PolicyConfiguration) {
        self.configuration = configuration
    }

    public mutating func handle(_ input: ButtonInput, engineReady: Bool) -> ScrollDecision {
        if !input.isDown {
            return consumedButtons.remove(input.button) != nil ? .consume : .pass
        }

        guard engineReady else { return .pass }
        switch configuration.buttonMode {
        case .off:
            return .pass
        case .withModifier:
            guard input.modifiers == ModifierState(configuration.modifier) else { return .pass }
        case .withoutModifier:
            // Option+뒤로가기 등 다른 조합은 앱에 맡긴다.
            guard input.modifiers.isEmpty else { return .pass }
        }

        consumedButtons.insert(input.button)
        let direction: SwitchDirection = input.button == .back ? .left : .right

        if let lastSwitch = lastSwitchTime, input.timestamp - lastSwitch < configuration.minimumInterval {
            return .consume
        }
        lastSwitchTime = input.timestamp
        return .consumeAndSwitch(direction)
    }
}
