import Foundation

/// 실행 중인 앱 선택(AppReveal) 설정.
public struct AppRevealSettings: Equatable, Sendable {
    /// 기본 단축키 ⌃⌥⇥. ⌘⇥(시스템 앱 전환기)는 가로채지 않는다.
    public static let defaults = AppRevealSettings(
        isEnabled: true,
        shortcut: KeyCombo(keyCode: 48, modifiers: [.control, .option], keyLabel: "⇥"),
        unhideOnSelect: true,
        restoreMinimized: true,
        reopenWhenNoWindow: true,
        includedAccessoryApps: []
    )

    public var isEnabled: Bool
    /// 목록 열기 (nil = 해제 — 메뉴에서는 계속 열 수 있다)
    public var shortcut: KeyCombo?
    /// 선택 시 숨긴(⌘H) 앱의 숨김을 해제한다. 꺼도 목록에는 남고, 선택하면 활성화만 한다.
    public var unhideOnSelect: Bool
    /// 보이는 창이 없고 최소화된 창만 있으면 그중 하나를 복원한다
    public var restoreMinimized: Bool
    /// 일반 창이 없음이 확인된 경우에만 앱에 다시 열기를 요청한다 (Dock 아이콘 클릭과 같은 요청)
    public var reopenWhenNoWindow: Bool
    /// 목록에 함께 보일 메뉴 막대 앱 (번들 ID). 기본 목록은 Dock에 나오는 일반 앱만이라,
    /// 창을 닫으면 메뉴 막대 앱이 되는 앱(Docker Desktop 등)은 여기에 넣어야 보인다.
    public var includedAccessoryApps: [String]

    public init(
        isEnabled: Bool, shortcut: KeyCombo?, unhideOnSelect: Bool, restoreMinimized: Bool, reopenWhenNoWindow: Bool,
        includedAccessoryApps: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.unhideOnSelect = unhideOnSelect
        self.restoreMinimized = restoreMinimized
        self.reopenWhenNoWindow = reopenWhenNoWindow
        self.includedAccessoryApps = includedAccessoryApps
    }

    /// 보조키 없는 단축키는 해제
    public func validated() -> AppRevealSettings {
        var copy = self
        if let shortcut, !shortcut.isValidGlobalShortcut { copy.shortcut = nil }
        return copy
    }
}
