import Foundation

public enum SwitchDirection: Equatable, Sendable {
    case left
    case right

    var reversed: SwitchDirection {
        self == .left ? .right : .left
    }
}

/// 매칭에 쓰는 보조키 집합. Caps Lock·Fn 등은 포함하지 않는다.
public struct ModifierState: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = ModifierState(rawValue: 1 << 0)
    public static let control = ModifierState(rawValue: 1 << 1)
    public static let option = ModifierState(rawValue: 1 << 2)
    public static let command = ModifierState(rawValue: 1 << 3)

    public init(_ key: ModifierKey) {
        switch key {
        case .shift: self = .shift
        case .control: self = .control
        case .option: self = .option
        case .command: self = .command
        }
    }
}

/// CGEvent에서 뽑아낸, 플랫폼 독립적인 스크롤 입력 한 건.
public struct ScrollInput: Equatable, Sendable {
    /// 세로 변화량. 양수 = 휠 위. 일반 휠은 줄 단위, 연속 입력은 포인트 단위.
    public var deltaY: Double
    /// 가로 변화량. 양수 = 휠 왼쪽(틸트 왼쪽). 단위 규칙은 deltaY와 같다.
    public var deltaX: Double
    /// 고해상도·트랙패드 등 연속 입력 여부 (kCGScrollWheelEventIsContinuous)
    public var isContinuous: Bool
    /// 관성(momentum) 단계 입력 여부
    public var isMomentum: Bool
    public var modifiers: ModifierState
    /// 단조 증가 시각(초). 테스트에서 외부 주입.
    public var timestamp: TimeInterval

    public init(
        deltaY: Double,
        deltaX: Double = 0,
        isContinuous: Bool = false,
        isMomentum: Bool = false,
        modifiers: ModifierState,
        timestamp: TimeInterval
    ) {
        self.deltaY = deltaY
        self.deltaX = deltaX
        self.isContinuous = isContinuous
        self.isMomentum = isMomentum
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

public enum ScrollDecision: Equatable, Sendable {
    /// 원래 이벤트를 그대로 전달
    case pass
    /// 원래 이벤트를 차단하고 전환은 하지 않음 (누적 중·최소 간격 중)
    case consume
    /// 원래 이벤트를 차단하고 해당 방향으로 전환 요청 1건
    case consumeAndSwitch(SwitchDirection)
}

public struct PolicyConfiguration: Equatable, Sendable {
    public var modifier: ModifierKey
    public var reverseDirection: Bool
    public var sensitivity: Sensitivity
    public var minimumInterval: TimeInterval
    /// 마지막 이벤트 이후 이 시간이 지나면 누적값을 버린다.
    public var accumulationTimeout: TimeInterval
    public var axis: ScrollAxis
    public var buttonMode: MouseButtonMode

    public init(
        modifier: ModifierKey,
        reverseDirection: Bool,
        sensitivity: Sensitivity,
        minimumInterval: TimeInterval,
        accumulationTimeout: TimeInterval = 0.2,
        axis: ScrollAxis = .vertical,
        buttonMode: MouseButtonMode = .off
    ) {
        self.buttonMode = buttonMode
        self.modifier = modifier
        self.reverseDirection = reverseDirection
        self.sensitivity = sensitivity
        self.minimumInterval = minimumInterval
        self.accumulationTimeout = accumulationTimeout
        self.axis = axis
    }

    public init(settings: AppSettings) {
        let value = settings.validated()
        self.init(
            modifier: value.modifierKey,
            reverseDirection: value.reverseDirection,
            sensitivity: value.sensitivity,
            minimumInterval: TimeInterval(value.minimumIntervalMs) / 1_000,
            axis: value.scrollAxis,
            buttonMode: value.mouseButtonMode
        )
    }
}

/// 보조키 매칭·방향·누적·최소 간격으로 통과/차단/전환을 판정하는 순수 로직.
/// 한 직렬 실행 문맥(이벤트 탭 스레드)에서만 호출한다.
public struct ScrollPolicy {
    public private(set) var configuration: PolicyConfiguration

    private var accumulated: Double = 0
    private var accumulatedDirection: SwitchDirection?
    private var lastEventTime: TimeInterval?
    private var lastSwitchTime: TimeInterval?

    public init(configuration: PolicyConfiguration) {
        self.configuration = configuration
    }

    /// 설정 변경. 진행 중인 누적 묶음은 버린다.
    public mutating func update(configuration: PolicyConfiguration) {
        self.configuration = configuration
        reset()
    }

    /// 누적값·마지막 이벤트 시각 초기화 (보조키 해제·일시정지·잠금 등).
    /// lastSwitchTime은 유지해서 재개 직후에도 최소 간격을 지킨다.
    public mutating func reset() {
        accumulated = 0
        accumulatedDirection = nil
        lastEventTime = nil
    }

    /// 보조키 상태가 바뀌었을 때(flagsChanged). 지정 보조키가 빠지면 누적 초기화.
    public mutating func modifiersChanged(_ modifiers: ModifierState) {
        if modifiers != ModifierState(configuration.modifier) {
            reset()
        }
    }

    public mutating func handle(_ input: ScrollInput, engineReady: Bool) -> ScrollDecision {
        guard engineReady else { return .pass }
        guard input.modifiers == ModifierState(configuration.modifier) else {
            reset()
            return .pass
        }
        // 선택하지 않은 축만 움직인 입력은 원래대로 전달한다.
        let delta = Self.switchDelta(for: input, axis: configuration.axis)
        guard delta != 0 else { return .pass }

        // 여기부터 처리 대상 — 원래 휠은 차단한다.
        if let last = lastEventTime, input.timestamp - last > configuration.accumulationTimeout {
            accumulated = 0
            accumulatedDirection = nil
        }
        lastEventTime = input.timestamp

        var direction: SwitchDirection = delta > 0 ? .left : .right
        if configuration.reverseDirection {
            direction = direction.reversed
        }

        if input.isMomentum { return .consume }

        if direction != accumulatedDirection {
            accumulated = 0
            accumulatedDirection = direction
        }

        accumulated += input.isContinuous ? abs(delta) : 1
        let threshold = Self.threshold(for: configuration.sensitivity, isContinuous: input.isContinuous)
        guard accumulated >= threshold else { return .consume }

        if let lastSwitch = lastSwitchTime, input.timestamp - lastSwitch < configuration.minimumInterval {
            // 간격 중에는 누적을 임계값에 묶어 둔다. 휠이 멈추면 누적 타임아웃으로 사라진다.
            accumulated = threshold
            return .consume
        }

        accumulated = 0
        lastSwitchTime = input.timestamp
        return .consumeAndSwitch(direction)
    }

    /// 전환 판정에 쓸 변화량. 양수 = 왼쪽 데스크탑 방향(휠 위 / 휠 왼쪽).
    static func switchDelta(for input: ScrollInput, axis: ScrollAxis) -> Double {
        switch axis {
        case .vertical:
            return input.deltaY
        case .horizontal:
            return input.deltaX
        case .both:
            // 대각선 입력은 큰 축 하나만 쓴다.
            return abs(input.deltaY) >= abs(input.deltaX) ? input.deltaY : input.deltaX
        }
    }

    /// 감도·입력 유형별 누적 임계값. 연속 입력 값은 초기값이며 실제 장비 검증 후 조정한다.
    static func threshold(for sensitivity: Sensitivity, isContinuous: Bool) -> Double {
        switch (sensitivity, isContinuous) {
        case (.low, false): return 2
        case (.normal, false), (.high, false): return 1
        case (.low, true): return 60
        case (.normal, true): return 30
        case (.high, true): return 15
        }
    }
}
