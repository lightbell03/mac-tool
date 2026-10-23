import Foundation

/// 키보드 포인터 단축키 프리셋. 조합마다 스크롤 모드 키와 빠른 이동 키가 정해진다.
/// 실제 설정은 PointerShortcut으로 저장하고, 이 값은 설정 화면의 빠른 선택과 이전 버전 저장값 이관에만 쓴다.
public enum PointerModifierPair: String, CaseIterable, Codable, Sendable {
    /// ⌥ + Tab을 누른 채 (스크롤 키 ⌘, 빠르게 ⇧) — 기본값.
    /// Tab은 보조키가 아니라 "누르고 있는 키"로 다룬다. 방향키 등을 쓰지 않고 Tab을 떼면 원래 ⌥Tab을 앱에 다시 보낸다.
    /// ⌃Tab은 쓰지 않는다: Tab은 방향키 이벤트에 표시되지 않아 ⌃→ 등 시스템 단축키(데스크탑 이동·미션 컨트롤)로 처리되고,
    /// 이벤트 탭에서 소비해도 시스템이 따로 실행한다.
    case optionTab
    /// ⌃⇧ (스크롤 키 ⌥, 빠르게 ⌘). ⌘⌥ 계열은 앱 단축키와 자주 겹쳐 피한다
    case controlShift
    /// ⌃⌘ (스크롤 키 ⌥)
    case controlCommand
    /// ⌃⌥ (스크롤 키 ⌘)
    case controlOption
    /// ⌥⌘ (스크롤 키 ⌃)
    case optionCommand

    public var base: ModifierState {
        switch self {
        case .optionTab: return .option
        case .controlShift: return [.control, .shift]
        case .controlCommand: return [.control, .command]
        case .controlOption: return [.control, .option]
        case .optionCommand: return [.option, .command]
        }
    }

    /// 스크롤 모드 키
    public var scrollModifier: ModifierState {
        switch self {
        // ⌃는 피한다: ⌃⌥ + 방향키는 창 포커스 이동 기본 단축키
        case .optionTab: return .command
        case .controlShift: return .option
        // 나머지 조합은 ⌃⌥⌘ 중 고르지 않은 한 키
        case .controlCommand, .controlOption, .optionCommand:
            return ModifierState([.control, .option, .command]).subtracting(base)
        }
    }

    /// 빠른 이동·빠른 스크롤 키
    public var fastModifier: ModifierState {
        // ⌃⇧는 Shift가 필수 특수키라 ⌘를 빠른 키로 쓴다
        self == .controlShift ? .command : .shift
    }

    /// 보조키와 함께 누르고 있어야 하는 일반 키 (⌃Tab의 Tab = 48). 없으면 nil.
    public var heldKeyCode: UInt16? {
        self == .optionTab ? 48 : nil
    }

    /// 이 프리셋의 전체 단축키. 동작 키는 기본값(↩ / R / D / G).
    public var shortcut: PointerShortcut {
        var shortcut = PointerShortcut.defaults
        shortcut.base = base
        shortcut.scrollModifier = scrollModifier
        shortcut.fastModifier = fastModifier
        shortcut.heldKey = heldKeyCode.map { PointerKey(keyCode: $0, keyLabel: "⇥") }
        // 누르고 있는 키가 없는 프리셋은 "두 번 누르기"로 포인터 모드를 켤 수 없다
        // 일반 키 느리게 키(A)는 누르고 있는 키 없이 쓰면 ⌃⇧A 같은 입력을 가린다
        if shortcut.heldKey == nil {
            shortcut.lockToggle = .off
            shortcut.slowKey = nil
        }
        return shortcut
    }

    /// 설정 화면 표시용: 조합(보조키·누르고 있는 키·스크롤·빠르게)이 어느 프리셋과 같은지. 동작 키는 보지 않는다.
    public static func matching(_ shortcut: PointerShortcut) -> PointerModifierPair? {
        allCases.first { $0.applied(to: shortcut) == shortcut }
    }

    /// 동작 키는 그대로 두고 조합만 이 프리셋으로 바꾼다
    public func applied(to shortcut: PointerShortcut) -> PointerShortcut {
        var result = self.shortcut
        for action in PointerAction.allCases {
            result.setKey(shortcut.key(for: action), for: action)
        }
        result.lockToggle = shortcut.lockToggle
        // 프리셋을 바꿔도 느리게 키는 그대로 (누르고 있는 키가 없는 프리셋에서는 일반 키 느리게 키를 뺀다)
        result.slowKey = shortcut.slowKey
        if result.heldKey == nil, case .key = result.slowKey { result.slowKey = nil }
        if result.heldKey == nil, result.lockToggle == .doubleTapHeldKey { result.lockToggle = .off }
        result.insertKey = shortcut.insertKey
        result.exitShortcuts = shortcut.exitShortcuts
        result.appShortcutAction = shortcut.appShortcutAction
        result.stripsHeldModifier = shortcut.stripsHeldModifier
        result.keepShortcuts = shortcut.keepShortcuts
        return result
    }
}

public struct KeyPointerSettings: Equatable, Sendable {
    public static let speedRange: ClosedRange<Double> = 100...1_500
    public static let fastMultiplierRange: ClosedRange<Double> = 1.5...4
    public static let scrollSpeedRange: ClosedRange<Double> = 100...2_000
    public static let scrollFastMultiplierRange: ClosedRange<Double> = 1.5...10
    /// 가속 시간 (초). 0이면 가속 없이 누르는 순간부터 설정 속도
    public static let accelerationTimeRange: ClosedRange<Double> = 0...1.5
    /// 누르는 순간의 속도 = 설정 속도 × 이 비율
    public static let startSpeedRatioRange: ClosedRange<Double> = 0.05...1
    /// 포인터 모드 토스트 배경 불투명도 (글자는 항상 불투명)
    public static let toastOpacityRange: ClosedRange<Double> = 0.1...1
    /// 느리게 키를 누른 동안의 배율 (이동·스크롤 공통)
    public static let slowMultiplierRange: ClosedRange<Double> = 0.1...0.7

    /// 이번 움직임의 속도 배율과 가속 여부. 느리게 키가 빠르게 키보다 우선하고, 느리게·빠르게일 때는 가속하지 않는다.
    public func speedFactor(fastKeyHeld: Bool, slowKeyHeld: Bool, scrolling: Bool) -> (multiplier: Double, accelerates: Bool) {
        if slowKeyHeld { return (slowMultiplier, false) }
        if usesFastSpeed(fastKeyHeld: fastKeyHeld) { return (scrolling ? scrollFastMultiplier : fastMultiplier, false) }
        return (1, true)
    }

    /// 이번 움직임을 빠른 속도로 할지: 빠르게 키 눌림을 invertFastKey면 뒤집는다
    public func usesFastSpeed(fastKeyHeld: Bool) -> Bool {
        fastKeyHeld != invertFastKey
    }

    public static let defaults = KeyPointerSettings(
        isEnabled: false,
        shortcut: .defaults,
        speed: 650,
        fastMultiplier: 2.5,
        scrollSpeed: 600,
        scrollFastMultiplier: 2,
        reverseScroll: false,
        accelerationTime: 0.5,
        startSpeedRatio: 0.15,
        toastOpacity: 0.6,
        slowMultiplier: 0.3,
        exitOnTextInputClick: true,
        exitAfterClick: false,
        moveToFocusOnResume: true,
        moveToFocusOnLock: false,
        invertFastKey: false,
        textInputExitExcludedApps: [],
        textInputExclusionRules: [.devToolsCodeEditor]
    )

    public var isEnabled: Bool
    public var shortcut: PointerShortcut
    /// 키보드 포인터 이동 속도 (pt/초). macOS 마우스·트랙패드 속도와 무관하다.
    public var speed: Double
    /// 빠르게 키(기본 ⇧)를 함께 누를 때 배율
    public var fastMultiplier: Double
    /// 키보드 스크롤 속도 (픽셀 단위/초)
    public var scrollSpeed: Double
    public var scrollFastMultiplier: Double
    /// 합성 스크롤에만 적용
    public var reverseScroll: Bool
    /// 방향키를 누르기 시작해 설정 속도에 이르기까지 걸리는 시간. 짧게 누르면 느리게 조금만 움직여 세밀하게 맞춘다.
    /// 이동·스크롤 모두 적용하고, 빠르게 키를 누른 동안은 가속 없이 바로 빠른 속도다.
    public var accelerationTime: Double
    public var startSpeedRatio: Double
    /// 포인터 모드 토스트 배경 불투명도
    public var toastOpacity: Double
    /// 느리게 키(기본 A)를 누른 동안 배율
    public var slowMultiplier: Double
    /// 포인터 모드에서 클릭(키보드·실제 마우스)한 곳이 글자 입력란이면 포인터 모드를 끈다
    public var exitOnTextInputClick: Bool
    /// 포인터 모드에서 키보드로 클릭(왼쪽·오른쪽·더블클릭·드래그 놓기)하면 포인터 모드를 끈다 — 옮기고 누르고 다시 키보드로
    public var exitAfterClick: Bool
    /// 앱 단축키로 잠깐 해제됐다가 포인터 모드로 돌아올 때 포인터를 포커스된 곳(글자 커서·요소)으로 옮긴다
    public var moveToFocusOnResume: Bool
    /// ⌥⇥ 두 번 등으로 포인터 모드를 켤 때도 옮긴다
    public var moveToFocusOnLock: Bool
    /// 기본을 빠르게, 빠르게 키를 누르는 동안 느리게 (세밀 조절)
    public var invertFastKey: Bool
    /// 입력란을 클릭해도 포인터 모드를 끄지 않을 앱 (번들 ID)
    public var textInputExitExcludedApps: [String]
    /// 입력란으로 보지 않을 영역 (방금 해제된 곳에서 배운 규칙). 기본은 개발자 도구 코드 편집기 하나.
    public var textInputExclusionRules: [TextInputExclusionRule]

    public init(
        isEnabled: Bool,
        shortcut: PointerShortcut,
        speed: Double,
        fastMultiplier: Double,
        scrollSpeed: Double,
        scrollFastMultiplier: Double,
        reverseScroll: Bool,
        accelerationTime: Double,
        startSpeedRatio: Double,
        toastOpacity: Double,
        slowMultiplier: Double = 0.3,
        exitOnTextInputClick: Bool,
        exitAfterClick: Bool = false,
        moveToFocusOnResume: Bool = true,
        moveToFocusOnLock: Bool = false,
        invertFastKey: Bool,
        textInputExitExcludedApps: [String] = [],
        textInputExclusionRules: [TextInputExclusionRule] = [.devToolsCodeEditor]
    ) {
        self.textInputExclusionRules = textInputExclusionRules
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.speed = speed
        self.fastMultiplier = fastMultiplier
        self.scrollSpeed = scrollSpeed
        self.scrollFastMultiplier = scrollFastMultiplier
        self.reverseScroll = reverseScroll
        self.accelerationTime = accelerationTime
        self.startSpeedRatio = startSpeedRatio
        self.toastOpacity = toastOpacity
        self.slowMultiplier = slowMultiplier
        self.exitOnTextInputClick = exitOnTextInputClick
        self.exitAfterClick = exitAfterClick
        self.moveToFocusOnResume = moveToFocusOnResume
        self.moveToFocusOnLock = moveToFocusOnLock
        self.invertFastKey = invertFastKey
        self.textInputExitExcludedApps = textInputExitExcludedApps
    }

    /// 범위 밖 값은 범위 안으로, NaN·무한대는 기본값으로. 적용할 수 없는 단축키 구성은 기본 단축키로.
    public func validated() -> KeyPointerSettings {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        var copy = self
        if !shortcut.isValid { copy.shortcut = Self.defaults.shortcut }
        copy.accelerationTime = clamp(accelerationTime, Self.accelerationTimeRange, fallback: Self.defaults.accelerationTime)
        copy.startSpeedRatio = clamp(startSpeedRatio, Self.startSpeedRatioRange, fallback: Self.defaults.startSpeedRatio)
        copy.slowMultiplier = clamp(slowMultiplier, Self.slowMultiplierRange, fallback: Self.defaults.slowMultiplier)
        copy.toastOpacity = clamp(toastOpacity, Self.toastOpacityRange, fallback: Self.defaults.toastOpacity)
        copy.speed = clamp(speed, Self.speedRange, fallback: Self.defaults.speed)
        copy.fastMultiplier = clamp(fastMultiplier, Self.fastMultiplierRange, fallback: Self.defaults.fastMultiplier)
        copy.scrollSpeed = clamp(scrollSpeed, Self.scrollSpeedRange, fallback: Self.defaults.scrollSpeed)
        copy.scrollFastMultiplier = clamp(
            scrollFastMultiplier, Self.scrollFastMultiplierRange, fallback: Self.defaults.scrollFastMultiplier
        )
        return copy
    }
}
