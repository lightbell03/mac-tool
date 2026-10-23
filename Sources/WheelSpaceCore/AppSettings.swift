import Foundation

public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case option
    case control
    case command
    case shift
}

public enum Sensitivity: String, CaseIterable, Codable, Sendable {
    case low
    case normal
    case high
}

/// 전환에 쓰는 휠 축. 가로 = 좌우 틸트·사이드 휠.
public enum ScrollAxis: String, CaseIterable, Codable, Sendable {
    case vertical
    case horizontal
    /// 이벤트마다 변화량이 큰 축 하나를 쓴다.
    case both
}

/// 마우스 뒤로가기/앞으로가기 버튼으로 전환하는 방식.
public enum MouseButtonMode: String, CaseIterable, Codable, Sendable {
    case off
    /// 지정한 보조키를 누른 채 버튼
    case withModifier
    /// 보조키 없이 버튼만 (앱의 뒤로·앞으로 기능 대신 전환)
    case withoutModifier
}

public struct AppSettings: Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumIntervalRange: ClosedRange<Int> = 200...1_000

    public static let defaults = AppSettings(
        isEnabled: true,
        modifierKey: .option,
        reverseDirection: false,
        sensitivity: .normal,
        minimumIntervalMs: 400,
        scrollAxis: .vertical,
        mouseButtonMode: .off
    )

    /// 사용자의 실행 의도. 실제 작동 여부는 권한·이벤트 탭 상태로 따로 결정한다.
    public var isEnabled: Bool
    public var modifierKey: ModifierKey
    public var reverseDirection: Bool
    public var sensitivity: Sensitivity
    public var minimumIntervalMs: Int
    public var scrollAxis: ScrollAxis
    public var mouseButtonMode: MouseButtonMode

    public init(
        isEnabled: Bool,
        modifierKey: ModifierKey,
        reverseDirection: Bool,
        sensitivity: Sensitivity,
        minimumIntervalMs: Int,
        scrollAxis: ScrollAxis = .vertical,
        mouseButtonMode: MouseButtonMode = .off
    ) {
        self.mouseButtonMode = mouseButtonMode
        self.isEnabled = isEnabled
        self.modifierKey = modifierKey
        self.reverseDirection = reverseDirection
        self.sensitivity = sensitivity
        self.minimumIntervalMs = minimumIntervalMs
        self.scrollAxis = scrollAxis
    }

    /// 허용 범위를 벗어난 값을 보정한 사본을 돌려준다.
    public func validated() -> AppSettings {
        var copy = self
        copy.minimumIntervalMs = min(
            max(minimumIntervalMs, Self.minimumIntervalRange.lowerBound),
            Self.minimumIntervalRange.upperBound
        )
        return copy
    }
}
