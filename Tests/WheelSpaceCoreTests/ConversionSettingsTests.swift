import XCTest
@testable import WheelSpaceCore

final class ConversionSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "WheelSpaceConversionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let commandShiftJ = KeyCombo(keyCode: 0x26, modifiers: [.command, .shift], keyLabel: "J")

    func testDisplayStringOrder() {
        let combo = KeyCombo(keyCode: 0x28, modifiers: [.command, .shift, .option, .control], keyLabel: "K")
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘K")
    }

    func testShortcutWithoutModifierIsInvalid() {
        XCTAssertFalse(KeyCombo(keyCode: 0x28, modifiers: [], keyLabel: "K").isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 0x28, modifiers: .shift, keyLabel: "K").isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: 0x28, modifiers: .option, keyLabel: "K").isValidGlobalShortcut)

        var settings = ConversionSettings.defaults
        settings.englishToHangulShortcut = KeyCombo(keyCode: 0x28, modifiers: .shift, keyLabel: "K")
        XCTAssertNil(settings.validated().englishToHangulShortcut)
    }

    func testValidatedClearsDuplicateShortcut() {
        var settings = ConversionSettings.defaults
        settings.hangulToEnglishShortcut = KeyCombo(keyCode: 0x28, modifiers: [.option, .control], keyLabel: "k")
        let validated = settings.validated()
        XCTAssertEqual(validated.englishToHangulShortcut, ConversionSettings.defaults.englishToHangulShortcut)
        XCTAssertNil(validated.hangulToEnglishShortcut)
    }

    func testEmptyStoreLoadsDefaults() {
        XCTAssertEqual(store.loadConversion(), .defaults)
    }

    func testSaveThenLoadRoundTrips() {
        let settings = ConversionSettings(
            isEnabled: false,
            englishToHangulShortcut: commandShiftJ,
            hangulToEnglishShortcut: nil,
            switchInputSourceAfterConversion: true,
            koreanInputSourceID: "com.apple.inputmethod.Korean.2SetKorean",
            englishInputSourceID: "com.apple.keylayout.ABC"
        )
        store.saveConversion(settings)
        XCTAssertEqual(store.loadConversion(), settings)
    }

    func testClearedShortcutStaysCleared() {
        var settings = ConversionSettings.defaults
        settings.englishToHangulShortcut = nil
        store.saveConversion(settings)
        XCTAssertNil(store.loadConversion().englishToHangulShortcut)
        XCTAssertEqual(store.loadConversion().hangulToEnglishShortcut, ConversionSettings.defaults.hangulToEnglishShortcut)
    }

    func testCorruptShortcutFallsBackToDefault() {
        defaults.set(Data("not json".utf8), forKey: SettingsStore.Key.englishToHangulShortcut)
        defaults.set("wrong type", forKey: SettingsStore.Key.hangulToEnglishShortcut)
        defaults.set(5, forKey: SettingsStore.Key.koreanInputSourceID)
        let loaded = store.loadConversion()
        XCTAssertEqual(loaded.englishToHangulShortcut, ConversionSettings.defaults.englishToHangulShortcut)
        XCTAssertEqual(loaded.hangulToEnglishShortcut, ConversionSettings.defaults.hangulToEnglishShortcut)
        XCTAssertNil(loaded.koreanInputSourceID)
    }

    func testTriggerModeDefaultsToReplaceSelection() {
        XCTAssertEqual(store.loadConversion().triggerMode, .replaceSelection)
        // 이전 버전 저장값: triggerMode 키 없음
        defaults.set(false, forKey: SettingsStore.Key.conversionEnabled)
        XCTAssertEqual(store.loadConversion().triggerMode, .replaceSelection)
    }

    func testTriggerModeRoundTripsAndInvalidFallsBack() {
        var settings = ConversionSettings.defaults
        settings.triggerMode = .clipboardOnly
        store.saveConversion(settings)
        XCTAssertEqual(store.loadConversion().triggerMode, .clipboardOnly)

        defaults.set("auto", forKey: SettingsStore.Key.triggerMode)
        XCTAssertEqual(store.loadConversion().triggerMode, .replaceSelection)
    }

    func testResetClearsConversionKeys() {
        var settings = ConversionSettings.defaults
        settings.isEnabled = false
        settings.englishToHangulShortcut = commandShiftJ
        store.saveConversion(settings)
        store.reset()
        XCTAssertEqual(store.loadConversion(), .defaults)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.englishToHangulShortcut))
    }
}
