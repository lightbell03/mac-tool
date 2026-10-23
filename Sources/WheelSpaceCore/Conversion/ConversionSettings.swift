import Foundation

/// 한영 복원 방향. 자동 판별 없이 사용자가 고른다.
public enum ConversionDirection: String, CaseIterable, Codable, Sendable {
    /// 영문 키 문자열 → 두벌식 한글 (dkssud → 안녕)
    case englishToHangul
    /// 한글 → 영문 키 문자열 (안녕 → dkssud)
    case hangulToEnglish
}

/// 단축키·메뉴를 실행했을 때 무엇을 변환하는가.
public enum ConversionTriggerMode: String, CaseIterable, Codable, Sendable {
    /// 앞 앱에서 선택한 글자를 ⌘C → 변환 → ⌘V로 바로 바꾸고 원래 클립보드를 되돌린다 (손쉬운 사용 권한 필요)
    case replaceSelection
    /// 이미 복사한 클립보드 내용만 변환한다 (사용자가 직접 ⌘C·⌘V)
    case clipboardOnly
}

extension ModifierState: Codable, Hashable {}

/// 전역 단축키 조합. keyCode는 macOS 가상 키 코드(kVK_*).
public struct KeyCombo: Equatable, Hashable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierState
    /// 기록 시점의 키 표시 문자 ("K", "F5" 등). 키 코드→문자 변환을 표시 때마다 하지 않으려고 저장한다.
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: ModifierState, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// "⌃⌥K" 형태. 표시 순서는 macOS 관례(⌃⌥⇧⌘).
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    /// 보조키 없는 단축키는 일반 타이핑을 가로채므로 허용하지 않는다.
    public var isValidGlobalShortcut: Bool {
        !modifiers.subtracting(.shift).isEmpty
    }
}

public struct ConversionSettings: Equatable, Sendable {
    public static let defaults = ConversionSettings(
        isEnabled: true,
        englishToHangulShortcut: KeyCombo(keyCode: 0x28, modifiers: [.control, .option], keyLabel: "K"),
        hangulToEnglishShortcut: KeyCombo(keyCode: 0x0E, modifiers: [.control, .option], keyLabel: "E"),
        switchInputSourceAfterConversion: false,
        koreanInputSourceID: nil,
        englishInputSourceID: nil,
        triggerMode: .replaceSelection
    )

    public var isEnabled: Bool
    public var triggerMode: ConversionTriggerMode
    /// nil = 단축키 해제 (메뉴 명령은 계속 사용 가능)
    public var englishToHangulShortcut: KeyCombo?
    public var hangulToEnglishShortcut: KeyCombo?
    public var switchInputSourceAfterConversion: Bool
    /// TIS 입력 소스 ID. nil = 아직 지정 안 함 (설치된 후보 중 첫 항목을 기본 후보로 안내)
    public var koreanInputSourceID: String?
    public var englishInputSourceID: String?

    public init(
        isEnabled: Bool,
        englishToHangulShortcut: KeyCombo?,
        hangulToEnglishShortcut: KeyCombo?,
        switchInputSourceAfterConversion: Bool,
        koreanInputSourceID: String?,
        englishInputSourceID: String?,
        triggerMode: ConversionTriggerMode = .replaceSelection
    ) {
        self.isEnabled = isEnabled
        self.triggerMode = triggerMode
        self.englishToHangulShortcut = englishToHangulShortcut
        self.hangulToEnglishShortcut = hangulToEnglishShortcut
        self.switchInputSourceAfterConversion = switchInputSourceAfterConversion
        self.koreanInputSourceID = koreanInputSourceID
        self.englishInputSourceID = englishInputSourceID
    }

    public func shortcut(for direction: ConversionDirection) -> KeyCombo? {
        switch direction {
        case .englishToHangul: return englishToHangulShortcut
        case .hangulToEnglish: return hangulToEnglishShortcut
        }
    }

    public mutating func setShortcut(_ combo: KeyCombo?, for direction: ConversionDirection) {
        switch direction {
        case .englishToHangul: englishToHangulShortcut = combo
        case .hangulToEnglish: hangulToEnglishShortcut = combo
        }
    }

    public func inputSourceID(for direction: ConversionDirection) -> String? {
        switch direction {
        case .englishToHangul: return koreanInputSourceID
        case .hangulToEnglish: return englishInputSourceID
        }
    }

    /// 보조키 없는 단축키는 해제, 두 방향이 같은 조합이면 한글→영문 쪽을 해제(앱 안 중복 방지).
    public func validated() -> ConversionSettings {
        var copy = self
        if copy.englishToHangulShortcut?.isValidGlobalShortcut == false { copy.englishToHangulShortcut = nil }
        if copy.hangulToEnglishShortcut?.isValidGlobalShortcut == false { copy.hangulToEnglishShortcut = nil }
        if let combo = copy.englishToHangulShortcut, combo.keyCode == copy.hangulToEnglishShortcut?.keyCode,
           combo.modifiers == copy.hangulToEnglishShortcut?.modifiers {
            copy.hangulToEnglishShortcut = nil
        }
        return copy
    }
}
