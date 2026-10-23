import XCTest
@testable import WheelSpaceCore

final class AppRevealPlannerTests: XCTestCase {
    private func state(
        hidden: Bool = false, normal: Int = 0, minimized: Int = 0, modal: Bool = false, otherSpace: Int = 0
    ) -> AppWindowInspection {
        .inspected(AppWindowState(
            isHidden: hidden, normalWindowCount: normal, minimizedWindowCount: minimized,
            hasModal: modal, otherSpaceWindowCount: otherSpace
        ))
    }

    private func step(
        _ inspection: AppWindowInspection,
        settings: AppRevealSettings = .defaults,
        unhid: Bool = false,
        reopened: Bool = false
    ) -> RevealStep {
        AppRevealPlanner.nextStep(inspection, settings: settings, alreadyUnhid: unhid, alreadyReopened: reopened)
    }

    func testVisibleWindowFocusesExisting() {
        XCTAssertEqual(step(state(normal: 1)), .focusExisting)
        // 보이는 창이 있으면 최소화 창은 복원하지 않는다
        XCTAssertEqual(step(state(normal: 1, minimized: 2)), .focusExisting)
    }

    func testHiddenUnhidesThenReinspects() {
        XCTAssertEqual(step(state(hidden: true, normal: 1)), .unhide)
        // 해제 후 다시 조회했을 때 아직 숨김으로 보여도 또 해제하지 않고 창으로 간다
        XCTAssertEqual(step(state(hidden: true, normal: 1), unhid: true), .focusExisting)
        var settings = AppRevealSettings.defaults
        settings.unhideOnSelect = false
        XCTAssertEqual(step(state(hidden: true, normal: 1), settings: settings), .activateOnly(.hiddenAndUnhideDisabled))
    }

    func testOnlyMinimizedRestoresOne() {
        XCTAssertEqual(step(state(minimized: 3)), .restoreMinimized)
        var settings = AppRevealSettings.defaults
        settings.restoreMinimized = false
        XCTAssertEqual(step(state(minimized: 3), settings: settings), .activateOnly(.minimizedAndRestoreDisabled))
    }

    func testNoWindowReopensOnce() {
        XCTAssertEqual(step(state()), .reopen)
        XCTAssertEqual(step(state(), reopened: true), .activateOnly(.noWindowAndReopenUnavailable))
        var settings = AppRevealSettings.defaults
        settings.reopenWhenNoWindow = false
        XCTAssertEqual(step(state(), settings: settings), .activateOnly(.noWindowAndReopenUnavailable))
    }

    func testInspectionFailureIsNotNoWindow() {
        XCTAssertEqual(step(.failed), .activateOnly(.inspectionFailed))
    }

    func testOffscreenWindowsReopenLikeDock() {
        // 다른 데스크탑의 창인지 닫혀 숨긴 창인지 모르므로 Dock 클릭과 같은 다시 열기 (한 번만)
        XCTAssertEqual(step(state(otherSpace: 2)), .reopen)
        XCTAssertEqual(step(state(otherSpace: 2), reopened: true), .activateOnly(.windowsOnOtherSpace))
        var settings = AppRevealSettings.defaults
        settings.reopenWhenNoWindow = false
        XCTAssertEqual(step(state(otherSpace: 2), settings: settings), .activateOnly(.windowsOnOtherSpace))
    }

    func testModalTakesPriority() {
        XCTAssertEqual(step(state(minimized: 1, modal: true)), .focusExisting)
    }
}

final class AppPickerModelTests: XCTestCase {
    private func entry(_ pid: Int32, _ name: String, _ bundle: String? = nil, hidden: Bool = false) -> AppPickerEntry {
        AppPickerEntry(pid: pid, name: name, bundleID: bundle ?? "com.example.\(name.lowercased())", isHidden: hidden)
    }

    func testRecentOrderThenName() {
        var recent = RecentAppOrder()
        recent.activated(3)
        recent.activated(1)
        let sorted = recent.sorted([entry(1, "Safari"), entry(2, "Zed"), entry(3, "Chrome"), entry(4, "Arc")])
        XCTAssertEqual(sorted.map(\.pid), [1, 3, 4, 2])
        recent.terminated(1)
        XCTAssertEqual(recent.pids, [3])
        recent.activated(3)
        XCTAssertEqual(recent.pids, [3])
    }

    func testInitialSelectionIsPreviousApp() {
        XCTAssertEqual(AppPickerModel(entries: [entry(1, "A"), entry(2, "B")]).selected?.pid, 2)
        XCTAssertEqual(AppPickerModel(entries: [entry(1, "A")]).selected?.pid, 1)
        XCTAssertNil(AppPickerModel(entries: []).selected)
    }

    func testSearchFiltersAndPrefersPrefix() {
        var model = AppPickerModel(entries: [
            entry(1, "Visual Studio Code", "com.microsoft.VSCode"), entry(2, "Code Runner"), entry(3, "Safari", "com.apple.Safari"),
        ])
        model.setQuery("code")
        // 이름이 검색어로 시작하는 앱이 앞, 선택은 첫 줄
        XCTAssertEqual(model.visible.map(\.pid), [2, 1])
        XCTAssertEqual(model.selected?.pid, 2)
        // 번들 ID로도 찾는다
        model.setQuery("apple")
        XCTAssertEqual(model.visible.map(\.pid), [3])
        // 지우면 전체, 선택은 다시 두 번째 줄
        model.setQuery("")
        XCTAssertEqual(model.visible.count, 3)
        XCTAssertEqual(model.selection, 1)
    }

    func testMoveStopsAtEdges() {
        var model = AppPickerModel(entries: [entry(1, "A"), entry(2, "B"), entry(3, "C")])
        model.move(by: 5)
        XCTAssertEqual(model.selected?.pid, 3)
        model.move(by: -9)
        XCTAssertEqual(model.selected?.pid, 1)
        model.setQuery("없는앱")
        model.move(by: 1)
        XCTAssertNil(model.selected)
    }

    func testDuplicateNamesAreDisambiguated() {
        let result = AppPickerModel.disambiguated([
            entry(1, "Chrome", "com.google.Chrome"), entry(2, "Chrome", "com.google.Chrome.canary"),
            entry(3, "Code", "com.example.code"), entry(4, "Code", "com.example.code"), entry(5, "Safari"),
        ])
        XCTAssertEqual(result.map(\.disambiguation), ["com.google.Chrome", "com.google.Chrome.canary", "PID 3", "PID 4", nil])
    }

    func testSettingsRoundTrip() {
        XCTAssertEqual(AppRevealSettings.defaults.shortcut?.displayString, "⌃⌥⇥")
        let suite = "WheelSpaceRevealTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadAppReveal(), .defaults)
        var settings = AppRevealSettings.defaults
        settings.reopenWhenNoWindow = false
        settings.shortcut = KeyCombo(keyCode: 46, modifiers: [.control, .command], keyLabel: "M")
        store.saveAppReveal(settings)
        XCTAssertEqual(store.loadAppReveal(), settings)
        // 함께 보일 메뉴 막대 앱 (기본 없음)
        XCTAssertEqual(AppRevealSettings.defaults.includedAccessoryApps, [])
        settings.includedAccessoryApps = ["com.electron.dockerdesktop"]
        store.saveAppReveal(settings)
        XCTAssertEqual(store.loadAppReveal().includedAccessoryApps, ["com.electron.dockerdesktop"])
                // 보조키 없는 단축키는 해제
        settings.shortcut = KeyCombo(keyCode: 46, modifiers: .shift, keyLabel: "M")
        XCTAssertNil(settings.validated().shortcut)
    }
}
