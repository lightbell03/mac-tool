import XCTest
@testable import WheelSpaceCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "WheelSpaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyStoreLoadsDefaults() {
        XCTAssertEqual(store.load(), .defaults)
    }

    func testSaveThenLoadRoundTrips() {
        let settings = AppSettings(
            isEnabled: false,
            modifierKey: .control,
            reverseDirection: true,
            sensitivity: .high,
            minimumIntervalMs: 650
        )
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(defaults.integer(forKey: SettingsStore.Key.schemaVersion), AppSettings.currentSchemaVersion)
    }

    func testOutOfRangeIntervalIsClamped() {
        defaults.set(50, forKey: SettingsStore.Key.minimumIntervalMs)
        XCTAssertEqual(store.load().minimumIntervalMs, 200)
        defaults.set(99_999, forKey: SettingsStore.Key.minimumIntervalMs)
        XCTAssertEqual(store.load().minimumIntervalMs, 1_000)
    }

    func testInvalidRawValueFallsBackToDefault() {
        defaults.set("hyper", forKey: SettingsStore.Key.modifierKey)
        defaults.set("extreme", forKey: SettingsStore.Key.sensitivity)
        defaults.set(true, forKey: SettingsStore.Key.reverseDirection)
        let loaded = store.load()
        XCTAssertEqual(loaded.modifierKey, .option)
        XCTAssertEqual(loaded.sensitivity, .normal)
        XCTAssertTrue(loaded.reverseDirection)
    }

    func testWrongTypeFallsBackToDefault() {
        defaults.set("yes", forKey: SettingsStore.Key.isEnabled)
        defaults.set("fast", forKey: SettingsStore.Key.minimumIntervalMs)
        let loaded = store.load()
        XCTAssertEqual(loaded.isEnabled, AppSettings.defaults.isEnabled)
        XCTAssertEqual(loaded.minimumIntervalMs, AppSettings.defaults.minimumIntervalMs)
    }

    func testFutureSchemaVersionLoadsDefaults() {
        store.save(AppSettings(isEnabled: false, modifierKey: .shift, reverseDirection: true, sensitivity: .low, minimumIntervalMs: 800))
        defaults.set(AppSettings.currentSchemaVersion + 1, forKey: SettingsStore.Key.schemaVersion)
        XCTAssertEqual(store.load(), .defaults)
    }

    func testScrollAxisRoundTripsAndMissingKeyDefaultsToVertical() {
        // 이전 버전 저장값: 새 키가 없다
        defaults.set(1, forKey: SettingsStore.Key.schemaVersion)
        defaults.set("control", forKey: SettingsStore.Key.modifierKey)
        let legacy = store.load()
        XCTAssertEqual(legacy.modifierKey, .control)
        XCTAssertEqual(legacy.scrollAxis, .vertical)
        XCTAssertEqual(legacy.mouseButtonMode, .off)

        var settings = legacy
        settings.scrollAxis = .horizontal
        settings.mouseButtonMode = .withModifier
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testInvalidScrollAxisFallsBackToVertical() {
        defaults.set("diagonal", forKey: SettingsStore.Key.scrollAxis)
        defaults.set(3, forKey: SettingsStore.Key.mouseButtonMode)
        let loaded = store.load()
        XCTAssertEqual(loaded.scrollAxis, .vertical)
        XCTAssertEqual(loaded.mouseButtonMode, .off)
    }

    func testResetClearsAllKeys() {
        store.save(AppSettings(isEnabled: false, modifierKey: .shift, reverseDirection: true, sensitivity: .low, minimumIntervalMs: 800))
        XCTAssertEqual(store.reset(), .defaults)
        for key in SettingsStore.Key.all {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(store.load(), .defaults)
    }
}
