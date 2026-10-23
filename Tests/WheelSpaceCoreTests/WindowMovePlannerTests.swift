import CoreGraphics
import XCTest
@testable import WheelSpaceCore

final class WindowMovePlannerTests: XCTestCase {
    // 가운데 1920×1080, 왼쪽 2560×1440(아래쪽 맞춤), 오른쪽 세로 1080×1920, 가운데 위 1920×1080
    private let center = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let left = CGRect(x: -2560, y: -360, width: 2560, height: 1440)
    private let right = CGRect(x: 1920, y: -420, width: 1080, height: 1920)
    private let top = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

    func testTargetDisplayByDirection() {
        let displays = [center, left, right, top]
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 0, direction: .left, in: displays), 1)
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 0, direction: .right, in: displays), 2)
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 0, direction: .up, in: displays), 3)
        XCTAssertNil(WindowMovePlanner.targetDisplay(from: 0, direction: .down, in: displays))
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 1, direction: .right, in: displays), 0)
        XCTAssertNil(WindowMovePlanner.targetDisplay(from: 1, direction: .left, in: displays))
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 3, direction: .down, in: displays), 0)
        XCTAssertNil(WindowMovePlanner.targetDisplay(from: 9, direction: .left, in: displays))
        XCTAssertNil(WindowMovePlanner.targetDisplay(from: 0, direction: .right, in: [center]))
    }

    func testTargetDisplayPrefersSideOverlapThenNearest() {
        // 오른쪽에 두 대: 높이가 겹치는 쪽을, 둘 다 겹치면 가까운 쪽을
        let nearButBelow = CGRect(x: 1920, y: 1200, width: 1920, height: 1080)
        let overlapping = CGRect(x: 2200, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 0, direction: .right, in: [center, nearButBelow, overlapping]), 2)
        let farther = CGRect(x: 4200, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WindowMovePlanner.targetDisplay(from: 0, direction: .right, in: [center, farther, overlapping]), 2)
    }

    func testSnappedWindowKeepsLayout() {
        // 왼쪽 절반(가장자리에 붙음) → 새 모니터의 왼쪽 절반
        let halfLeft = CGRect(x: 0, y: 0, width: 960, height: 1080)
        XCTAssertEqual(WindowMovePlanner.movedFrame(halfLeft, from: center, to: left), CGRect(x: -2560, y: -360, width: 1280, height: 1440))
        // 꽉 채운 창 → 새 모니터를 꽉 채움
        XCTAssertEqual(WindowMovePlanner.movedFrame(center, from: center, to: right), right)
    }

    func testFloatingWindowKeepsSize() {
        // 떠 있는 창: 크기 그대로, 가운데를 같은 비율 자리로 (모니터 모양이 달라도 찌그러지지 않는다)
        let small = CGRect(x: 480, y: 270, width: 960, height: 540)
        XCTAssertEqual(WindowMovePlanner.movedFrame(small, from: center, to: right), CGRect(x: 1980, y: 270, width: 960, height: 540))
        // 실제 배치: 외장(메뉴 막대 뺀 1920×1050) → 내장(1800×1131)
        let external = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let builtIn = CGRect(x: 1920, y: 1118, width: 1800, height: 1131)
        let window = CGRect(x: 300, y: 200, width: 1200, height: 700)
        let moved = WindowMovePlanner.movedFrame(window, from: external, to: builtIn)
        XCTAssertEqual(moved.size, window.size)
        XCTAssertTrue(builtIn.contains(moved))
        // 왼쪽 끝에 닿았을 뿐인 보통 창(화면의 62%)은 크기 그대로
        let touching = CGRect(x: 0, y: 200, width: 1200, height: 700)
        XCTAssertEqual(WindowMovePlanner.movedFrame(touching, from: external, to: builtIn).size, touching.size)
        // 높이만 꽉 채운 창 → 높이는 새 모니터에 맞추고 너비는 그대로
        let tall = CGRect(x: 500, y: 30, width: 800, height: 1050)
        let movedTall = WindowMovePlanner.movedFrame(tall, from: external, to: builtIn)
        XCTAssertEqual(movedTall.width, 800)
        XCTAssertEqual(movedTall.height, 1131)
    }

    func testMovedFrameStaysInsideTarget() {
        // 원래 모니터를 벗어나 있던 창도 새 모니터 안으로
        let overflowing = CGRect(x: 1500, y: 800, width: 800, height: 600)
        let moved = WindowMovePlanner.movedFrame(overflowing, from: center, to: top)
        XCTAssertTrue(top.contains(moved))
        XCTAssertEqual(moved.size, CGSize(width: 800, height: 600))
        // 크기가 0인 원래 영역은 그대로
        XCTAssertEqual(WindowMovePlanner.movedFrame(overflowing, from: .zero, to: top), overflowing)
    }

    func testMoveShortcutsDefaultsAndRoundTrip() {
        let suite = "WheelSpaceMoveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(FocusSettings.defaults.moveShortcut(for: .left)?.displayString, "⌃⌥⌘←")
        XCTAssertEqual(store.loadFocus().moveShortcut(for: .down)?.displayString, "⌃⌥⌘↓")
        var settings = FocusSettings.defaults
        settings.setMoveShortcut(nil, for: .up)
        // 포커스 이동과 같은 조합은 해제된다
        settings.setMoveShortcut(settings.shortcut(for: .left), for: .right)
        store.saveFocus(settings)
        let loaded = store.loadFocus()
        XCTAssertNil(loaded.moveShortcut(for: .up))
        XCTAssertNil(loaded.moveShortcut(for: .right))
        XCTAssertEqual(loaded.moveShortcut(for: .left)?.displayString, "⌃⌥⌘←")
    }
}
