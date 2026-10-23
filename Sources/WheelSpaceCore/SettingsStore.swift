import Foundation

/// UserDefaults 기반 설정 저장소. 잘못된 저장값은 읽을 때 기본값 또는 허용 범위로 보정한다.
public final class SettingsStore {
    enum Key {
        static let schemaVersion = "schemaVersion"
        static let isEnabled = "isEnabled"
        static let modifierKey = "modifierKey"
        static let reverseDirection = "reverseDirection"
        static let sensitivity = "sensitivity"
        static let minimumIntervalMs = "minimumIntervalMs"
        static let scrollAxis = "scrollAxis"
        static let mouseButtonMode = "mouseButtonMode"

        // 한영 복원 — 단축키는 KeyCombo JSON(Data), nil이면 "해제"를 뜻하는 빈 Data로 저장해 "기본값"과 구분한다.
        static let conversionEnabled = "conversion.isEnabled"
        static let englishToHangulShortcut = "conversion.englishToHangulShortcut"
        static let hangulToEnglishShortcut = "conversion.hangulToEnglishShortcut"
        static let switchInputSource = "conversion.switchInputSourceAfterConversion"
        static let koreanInputSourceID = "conversion.koreanInputSourceID"
        static let englishInputSourceID = "conversion.englishInputSourceID"
        static let triggerMode = "conversion.triggerMode"

        // 창 포커스 이동 — 단축키 저장 규칙은 한영 변환과 같다 (빈 Data = 해제)
        static let focusEnabled = "focus.isEnabled"
        static let focusLeftShortcut = "focus.leftShortcut"
        static let focusRightShortcut = "focus.rightShortcut"
        static let focusUpShortcut = "focus.upShortcut"
        static let focusDownShortcut = "focus.downShortcut"
        /// 이전 버전의 Bool 키 (읽기 전용 이관: true → .focusMoves)
        static let focusMovePointer = "focus.movePointerWithFocus"
        static let focusPointerFollow = "focus.pointerFollow"
        /// 창 목록 전환기 단축키 (빈 Data = 해제)
        static let focusSwitcherShortcut = "focus.switcherShortcut"
        static let focusSwitcherRequiresHeldKey = "focus.switcherRequiresHeldKey"
        static let focusStackNextShortcut = "focus.stackNextShortcut"
        static let focusStackPreviousShortcut = "focus.stackPreviousShortcut"

        // 키보드 포인터
        static let pointerEnabled = "pointer.isEnabled"
        /// 이전 버전의 프리셋 이름 (읽기 전용 이관: pointer.shortcut이 없을 때 그 프리셋의 단축키로)
        static let pointerModifierPair = "pointer.modifierPair"
        /// PointerShortcut JSON(Data)
        static let pointerShortcut = "pointer.shortcut"
        static let pointerSpeed = "pointer.speed"
        static let pointerFastMultiplier = "pointer.fastMultiplier"
        static let pointerSlowMultiplier = "pointer.slowMultiplier"
        static let pointerScrollSpeed = "pointer.scrollSpeed"
        static let pointerScrollFastMultiplier = "pointer.scrollFastMultiplier"
        static let pointerReverseScroll = "pointer.reverseScroll"
        static let pointerAccelerationTime = "pointer.accelerationTime"
        static let pointerStartSpeedRatio = "pointer.startSpeedRatio"
        static let pointerToastOpacity = "pointer.toastOpacity"
        static let pointerExitOnTextInputClick = "pointer.exitOnTextInputClick"
        static let pointerExitAfterClick = "pointer.exitAfterClick"
        static let pointerMoveToFocusOnResume = "pointer.moveToFocusOnResume"
        static let pointerMoveToFocusOnLock = "pointer.moveToFocusOnLock"
        static let pointerInvertFastKey = "pointer.invertFastKey"
        static let pointerTextInputExitExcludedApps = "pointer.textInputExitExcludedApps"
        /// [TextInputExclusionRule] JSON(Data). 없으면 기본 규칙
        static let pointerTextInputExclusionRules = "pointer.textInputExclusionRules"

        // 실행 중인 앱 선택 — 단축키 저장 규칙은 한영 변환과 같다 (빈 Data = 해제)
        static let revealEnabled = "reveal.isEnabled"
        static let revealShortcut = "reveal.shortcut"
        static let revealUnhideOnSelect = "reveal.unhideOnSelect"
        static let revealRestoreMinimized = "reveal.restoreMinimized"
        static let revealReopenWhenNoWindow = "reveal.reopenWhenNoWindow"
        static let revealIncludedAccessoryApps = "reveal.includedAccessoryApps"

        static let all = [
            schemaVersion, isEnabled, modifierKey, reverseDirection, sensitivity, minimumIntervalMs,
            scrollAxis, mouseButtonMode,
            conversionEnabled, englishToHangulShortcut, hangulToEnglishShortcut, switchInputSource,
            koreanInputSourceID, englishInputSourceID, triggerMode,
            focusEnabled, focusLeftShortcut, focusRightShortcut, focusUpShortcut, focusDownShortcut,
            focusMovePointer, focusPointerFollow, focusSwitcherShortcut, focusSwitcherRequiresHeldKey,
            focusStackNextShortcut, focusStackPreviousShortcut,
            pointerEnabled, pointerModifierPair, pointerShortcut, pointerSpeed, pointerFastMultiplier,
            pointerScrollSpeed, pointerScrollFastMultiplier, pointerReverseScroll,
            pointerAccelerationTime, pointerStartSpeedRatio, pointerToastOpacity,
            pointerExitOnTextInputClick, pointerInvertFastKey, pointerTextInputExitExcludedApps,
            pointerTextInputExclusionRules,
            revealEnabled, revealShortcut, revealUnhideOnSelect, revealRestoreMinimized, revealReopenWhenNoWindow,
            revealIncludedAccessoryApps,
        ]
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        if let version = defaults.object(forKey: Key.schemaVersion) as? Int,
           version > AppSettings.currentSchemaVersion {
            return .defaults
        }

        var settings = AppSettings.defaults
        if let value = defaults.object(forKey: Key.isEnabled) as? Bool {
            settings.isEnabled = value
        }
        if let raw = defaults.object(forKey: Key.modifierKey) as? String,
           let value = ModifierKey(rawValue: raw) {
            settings.modifierKey = value
        }
        if let value = defaults.object(forKey: Key.reverseDirection) as? Bool {
            settings.reverseDirection = value
        }
        if let raw = defaults.object(forKey: Key.sensitivity) as? String,
           let value = Sensitivity(rawValue: raw) {
            settings.sensitivity = value
        }
        if let value = defaults.object(forKey: Key.minimumIntervalMs) as? Int {
            settings.minimumIntervalMs = value
        }
        // 키 추가만이라 schemaVersion은 1 유지: 이전 저장값에는 키가 없어 기본값으로 읽힌다.
        if let raw = defaults.object(forKey: Key.scrollAxis) as? String,
           let value = ScrollAxis(rawValue: raw) {
            settings.scrollAxis = value
        }
        if let raw = defaults.object(forKey: Key.mouseButtonMode) as? String,
           let value = MouseButtonMode(rawValue: raw) {
            settings.mouseButtonMode = value
        }
        return settings.validated()
    }

    public func save(_ settings: AppSettings) {
        let value = settings.validated()
        defaults.set(value.isEnabled, forKey: Key.isEnabled)
        defaults.set(value.modifierKey.rawValue, forKey: Key.modifierKey)
        defaults.set(value.reverseDirection, forKey: Key.reverseDirection)
        defaults.set(value.sensitivity.rawValue, forKey: Key.sensitivity)
        defaults.set(value.minimumIntervalMs, forKey: Key.minimumIntervalMs)
        defaults.set(value.scrollAxis.rawValue, forKey: Key.scrollAxis)
        defaults.set(value.mouseButtonMode.rawValue, forKey: Key.mouseButtonMode)
        defaults.set(AppSettings.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    public func loadConversion() -> ConversionSettings {
        if let version = defaults.object(forKey: Key.schemaVersion) as? Int,
           version > AppSettings.currentSchemaVersion {
            return .defaults
        }

        var settings = ConversionSettings.defaults
        if let value = defaults.object(forKey: Key.conversionEnabled) as? Bool {
            settings.isEnabled = value
        }
        settings.englishToHangulShortcut = loadShortcut(
            forKey: Key.englishToHangulShortcut, fallback: settings.englishToHangulShortcut
        )
        settings.hangulToEnglishShortcut = loadShortcut(
            forKey: Key.hangulToEnglishShortcut, fallback: settings.hangulToEnglishShortcut
        )
        if let value = defaults.object(forKey: Key.switchInputSource) as? Bool {
            settings.switchInputSourceAfterConversion = value
        }
        if let value = defaults.object(forKey: Key.koreanInputSourceID) as? String {
            settings.koreanInputSourceID = value
        }
        if let value = defaults.object(forKey: Key.englishInputSourceID) as? String {
            settings.englishInputSourceID = value
        }
        if let raw = defaults.object(forKey: Key.triggerMode) as? String,
           let value = ConversionTriggerMode(rawValue: raw) {
            settings.triggerMode = value
        }
        return settings.validated()
    }

    public func saveConversion(_ settings: ConversionSettings) {
        let value = settings.validated()
        defaults.set(value.isEnabled, forKey: Key.conversionEnabled)
        saveShortcut(value.englishToHangulShortcut, forKey: Key.englishToHangulShortcut)
        saveShortcut(value.hangulToEnglishShortcut, forKey: Key.hangulToEnglishShortcut)
        defaults.set(value.switchInputSourceAfterConversion, forKey: Key.switchInputSource)
        setOrRemove(value.koreanInputSourceID, forKey: Key.koreanInputSourceID)
        setOrRemove(value.englishInputSourceID, forKey: Key.englishInputSourceID)
        defaults.set(value.triggerMode.rawValue, forKey: Key.triggerMode)
        defaults.set(AppSettings.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    public func loadFocus() -> FocusSettings {
        if let version = defaults.object(forKey: Key.schemaVersion) as? Int,
           version > AppSettings.currentSchemaVersion {
            return .defaults
        }
        var settings = FocusSettings.defaults
        if let value = defaults.object(forKey: Key.focusEnabled) as? Bool {
            settings.isEnabled = value
        }
        for direction in FocusDirection.allCases {
            let combo = loadShortcut(forKey: Self.focusKey(for: direction), fallback: settings.shortcut(for: direction))
            settings.setShortcut(combo, for: direction)
        }
        if let raw = defaults.object(forKey: Key.focusPointerFollow) as? String,
           let mode = PointerFollowMode(rawValue: raw) {
            settings.pointerFollow = mode
        } else if defaults.object(forKey: Key.focusMovePointer) as? Bool == true {
            // 이전 버전의 "포인터도 같이 이동" 켜짐
            settings.pointerFollow = .focusMoves
        }
        settings.switcherShortcut = loadShortcut(forKey: Key.focusSwitcherShortcut, fallback: settings.switcherShortcut)
        if let value = defaults.object(forKey: Key.focusSwitcherRequiresHeldKey) as? Bool {
            settings.switcherRequiresHeldKey = value
        }
        settings.stackNextShortcut = loadShortcut(forKey: Key.focusStackNextShortcut, fallback: settings.stackNextShortcut)
        settings.stackPreviousShortcut = loadShortcut(forKey: Key.focusStackPreviousShortcut, fallback: settings.stackPreviousShortcut)
        return settings.validated()
    }

    public func saveFocus(_ settings: FocusSettings) {
        let value = settings.validated()
        defaults.set(value.isEnabled, forKey: Key.focusEnabled)
        for direction in FocusDirection.allCases {
            saveShortcut(value.shortcut(for: direction), forKey: Self.focusKey(for: direction))
        }
        defaults.set(value.pointerFollow.rawValue, forKey: Key.focusPointerFollow)
        saveShortcut(value.switcherShortcut, forKey: Key.focusSwitcherShortcut)
        defaults.set(value.switcherRequiresHeldKey, forKey: Key.focusSwitcherRequiresHeldKey)
        saveShortcut(value.stackNextShortcut, forKey: Key.focusStackNextShortcut)
        saveShortcut(value.stackPreviousShortcut, forKey: Key.focusStackPreviousShortcut)
        defaults.removeObject(forKey: Key.focusMovePointer)
        defaults.set(AppSettings.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    private static func focusKey(for direction: FocusDirection) -> String {
        switch direction {
        case .left: return Key.focusLeftShortcut
        case .right: return Key.focusRightShortcut
        case .up: return Key.focusUpShortcut
        case .down: return Key.focusDownShortcut
        }
    }

    public func loadKeyPointer() -> KeyPointerSettings {
        if let version = defaults.object(forKey: Key.schemaVersion) as? Int,
           version > AppSettings.currentSchemaVersion {
            return .defaults
        }
        var settings = KeyPointerSettings.defaults
        if let value = defaults.object(forKey: Key.pointerEnabled) as? Bool {
            settings.isEnabled = value
        }
        // 적용할 수 없는 구성은 아래 validated()가 기본 단축키로 되돌린다
        if let data = defaults.object(forKey: Key.pointerShortcut) as? Data {
            if let value = try? JSONDecoder().decode(PointerShortcut.self, from: data) {
                settings.shortcut = value
            }
        } else if let raw = defaults.object(forKey: Key.pointerModifierPair) as? String,
                  let preset = PointerModifierPair(rawValue: raw) {
            // 이전 버전 프리셋 이름 이관 (알 수 없는 값·옛 controlTab은 기본값)
            settings.shortcut = preset.shortcut
        }
        func double(_ key: String) -> Double? {
            (defaults.object(forKey: key) as? NSNumber)?.doubleValue
        }
        if let value = double(Key.pointerSpeed) { settings.speed = value }
        if let value = double(Key.pointerFastMultiplier) { settings.fastMultiplier = value }
        if let value = double(Key.pointerSlowMultiplier) { settings.slowMultiplier = value }
        if let value = double(Key.pointerScrollSpeed) { settings.scrollSpeed = value }
        if let value = double(Key.pointerScrollFastMultiplier) { settings.scrollFastMultiplier = value }
        if let value = defaults.object(forKey: Key.pointerReverseScroll) as? Bool {
            settings.reverseScroll = value
        }
        if let value = double(Key.pointerAccelerationTime) { settings.accelerationTime = value }
        if let value = double(Key.pointerStartSpeedRatio) { settings.startSpeedRatio = value }
        if let value = double(Key.pointerToastOpacity) { settings.toastOpacity = value }
        if let value = defaults.object(forKey: Key.pointerExitOnTextInputClick) as? Bool {
            settings.exitOnTextInputClick = value
        }
        if let value = defaults.object(forKey: Key.pointerExitAfterClick) as? Bool {
            settings.exitAfterClick = value
        }
        if let value = defaults.object(forKey: Key.pointerMoveToFocusOnResume) as? Bool {
            settings.moveToFocusOnResume = value
        }
        if let value = defaults.object(forKey: Key.pointerMoveToFocusOnLock) as? Bool {
            settings.moveToFocusOnLock = value
        }
        if let value = defaults.object(forKey: Key.pointerInvertFastKey) as? Bool {
            settings.invertFastKey = value
        }
        if let value = defaults.object(forKey: Key.pointerTextInputExitExcludedApps) as? [String] {
            settings.textInputExitExcludedApps = value
        }
        if let data = defaults.object(forKey: Key.pointerTextInputExclusionRules) as? Data,
           let rules = try? JSONDecoder().decode([TextInputExclusionRule].self, from: data) {
            settings.textInputExclusionRules = rules
        }
        return settings.validated()
    }

    public func loadAppReveal() -> AppRevealSettings {
        if let version = defaults.object(forKey: Key.schemaVersion) as? Int,
           version > AppSettings.currentSchemaVersion {
            return .defaults
        }
        var settings = AppRevealSettings.defaults
        func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
        if let value = bool(Key.revealEnabled) { settings.isEnabled = value }
        settings.shortcut = loadShortcut(forKey: Key.revealShortcut, fallback: settings.shortcut)
        if let value = bool(Key.revealUnhideOnSelect) { settings.unhideOnSelect = value }
        if let value = bool(Key.revealRestoreMinimized) { settings.restoreMinimized = value }
        if let value = bool(Key.revealReopenWhenNoWindow) { settings.reopenWhenNoWindow = value }
        if let value = defaults.object(forKey: Key.revealIncludedAccessoryApps) as? [String] {
            settings.includedAccessoryApps = value
        }
        return settings.validated()
    }

    public func saveAppReveal(_ settings: AppRevealSettings) {
        let value = settings.validated()
        defaults.set(value.isEnabled, forKey: Key.revealEnabled)
        saveShortcut(value.shortcut, forKey: Key.revealShortcut)
        defaults.set(value.unhideOnSelect, forKey: Key.revealUnhideOnSelect)
        defaults.set(value.restoreMinimized, forKey: Key.revealRestoreMinimized)
        defaults.set(value.reopenWhenNoWindow, forKey: Key.revealReopenWhenNoWindow)
        defaults.set(value.includedAccessoryApps, forKey: Key.revealIncludedAccessoryApps)
        defaults.set(AppSettings.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    public func saveKeyPointer(_ settings: KeyPointerSettings) {
        let value = settings.validated()
        defaults.set(value.isEnabled, forKey: Key.pointerEnabled)
        if let data = try? JSONEncoder().encode(value.shortcut) {
            defaults.set(data, forKey: Key.pointerShortcut)
        }
        defaults.set(value.speed, forKey: Key.pointerSpeed)
        defaults.set(value.fastMultiplier, forKey: Key.pointerFastMultiplier)
        defaults.set(value.slowMultiplier, forKey: Key.pointerSlowMultiplier)
        defaults.set(value.scrollSpeed, forKey: Key.pointerScrollSpeed)
        defaults.set(value.scrollFastMultiplier, forKey: Key.pointerScrollFastMultiplier)
        defaults.set(value.reverseScroll, forKey: Key.pointerReverseScroll)
        defaults.set(value.accelerationTime, forKey: Key.pointerAccelerationTime)
        defaults.set(value.startSpeedRatio, forKey: Key.pointerStartSpeedRatio)
        defaults.set(value.toastOpacity, forKey: Key.pointerToastOpacity)
        defaults.set(value.exitOnTextInputClick, forKey: Key.pointerExitOnTextInputClick)
        defaults.set(value.exitAfterClick, forKey: Key.pointerExitAfterClick)
        defaults.set(value.moveToFocusOnResume, forKey: Key.pointerMoveToFocusOnResume)
        defaults.set(value.moveToFocusOnLock, forKey: Key.pointerMoveToFocusOnLock)
        defaults.set(value.invertFastKey, forKey: Key.pointerInvertFastKey)
        defaults.set(value.textInputExitExcludedApps, forKey: Key.pointerTextInputExitExcludedApps)
        if let data = try? JSONEncoder().encode(value.textInputExclusionRules) {
            defaults.set(data, forKey: Key.pointerTextInputExclusionRules)
        }
        defaults.set(AppSettings.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    /// 키 없음 → fallback(기본값), 빈 Data → nil(사용자가 해제), 디코딩 실패 → fallback
    private func loadShortcut(forKey key: String, fallback: KeyCombo?) -> KeyCombo? {
        guard let data = defaults.object(forKey: key) as? Data else { return fallback }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? fallback
    }

    private func saveShortcut(_ combo: KeyCombo?, forKey key: String) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// 모든 키를 지우고 기본값을 돌려준다.
    @discardableResult
    public func reset() -> AppSettings {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        return .defaults
    }
}
