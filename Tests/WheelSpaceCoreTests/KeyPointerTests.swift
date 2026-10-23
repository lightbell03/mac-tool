import CoreGraphics
import XCTest
@testable import WheelSpaceCore

/// keyboard-move 11절 자동 검증.
final class KeyPointerInputStateTests: XCTestCase {
    private typealias K = KeyPointerInputState.KeyCode
    private let combo: ModifierState = [.control, .command]          // 기본 ⌃⌘
    private let scrollCombo: ModifierState = [.control, .command, .option]

    private func down(_ code: UInt16, _ modifiers: ModifierState, repeat isRepeat: Bool = false) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: true, isRepeat: isRepeat, modifiers: modifiers)
    }

    private func up(_ code: UInt16, _ modifiers: ModifierState) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: false, modifiers: modifiers)
    }

    func testExactComboArrowIsConsumedAndStartsMoving() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        let decision = state.handleKey(down(K.left, combo))
        XCTAssertEqual(decision, KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .moving)
        XCTAssertEqual(state.activeArrows, [.left])
    }

    func testArrowWithoutComboPasses() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        XCTAssertEqual(state.handleKey(down(K.left, [])), .pass)
        XCTAssertEqual(state.handleKey(down(K.left, .command)), .pass)
        XCTAssertEqual(state.handleKey(up(K.left, [])), .pass)
        XCTAssertEqual(state.mode, .idle)
    }

    func testExtraModifierPasses() {
        // ⌃⌥ 조합에서 ⌘는 스크롤 키, ⌥⌘는 조합이 아님
        var state = KeyPointerInputState(modifierPair: .controlOption)
        XCTAssertEqual(state.handleKey(down(K.left, [.option, .command])), .pass)
        XCTAssertEqual(state.handleKey(down(K.left, [.control])), .pass)
    }

    func testRepeatKeyDownDoesNotDuplicate() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.right, combo))
        for _ in 0..<10 {
            XCTAssertEqual(state.handleKey(down(K.right, combo, repeat: true)), KeyPointerDecision(consume: true))
        }
        XCTAssertEqual(state.activeArrows, [.right])
    }

    func testConsumedKeyUpIsConsumedEvenAfterComboReleased() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.up, combo))
        XCTAssertEqual(state.handleModifiers([]), [.motionChanged]) // 특수키 먼저 뗌 → 정지
        XCTAssertEqual(state.handleKey(up(K.up, [])).consume, true)  // 방향키 up도 앱에 보내지 않음
        XCTAssertEqual(state.handleKey(up(K.up, [])), .pass)         // 짝은 한 번뿐
    }

    func testKeyUpOfPassedKeyIsNotSwallowed() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        XCTAssertEqual(state.handleKey(down(K.left, [])), .pass)
        _ = state.handleModifiers(combo)
        XCTAssertEqual(state.handleKey(up(K.left, combo)), .pass)
    }

    func testComboPressedLateStartsOnNextNewPress() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        XCTAssertEqual(state.handleKey(down(K.left, [])), .pass)
        _ = state.handleModifiers(combo)
        // 이미 누르고 있던 키의 자동 반복은 가로채지 않는다
        XCTAssertEqual(state.handleKey(down(K.left, combo, repeat: true)), .pass)
        XCTAssertEqual(state.mode, .idle)
        _ = state.handleKey(up(K.left, combo))
        XCTAssertEqual(state.handleKey(down(K.left, combo)).consume, true)
        XCTAssertEqual(state.mode, .moving)
    }

    func testModifierReleaseStopsMotionAndEndsDrag() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.g, combo))
        _ = state.handleKey(down(K.right, combo))
        XCTAssertEqual(state.handleModifiers([.control]), [.endDrag, .motionChanged])
        XCTAssertFalse(state.isDragging)
        XCTAssertEqual(state.mode, .idle)
    }

    func testShiftTogglesFast() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.right, combo))
        XCTAssertFalse(state.isFast)
        XCTAssertEqual(state.handleModifiers(combo.union(.shift)), [.motionChanged])
        XCTAssertTrue(state.isFast)
        XCTAssertEqual(state.handleModifiers(combo), [.motionChanged])
        XCTAssertFalse(state.isFast)
        // Shift를 누른 채 시작해도 빠르게
        var other = KeyPointerInputState(modifierPair: .controlCommand)
        _ = other.handleKey(down(K.down, combo.union(.shift)))
        XCTAssertTrue(other.isFast)
    }

    func testScrollKeySwitchesModeOnNextPress() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.down, combo))
        XCTAssertEqual(state.mode, .moving)
        // 이동 중 스크롤 키(⌥) 누름 → 정지, 다음 새 누름부터 스크롤
        XCTAssertEqual(state.handleModifiers(scrollCombo), [.motionChanged])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.handleKey(down(K.down, scrollCombo, repeat: true)).consume, true) // 소비 중 키의 반복
        XCTAssertEqual(state.mode, .idle)
        _ = state.handleKey(up(K.down, scrollCombo))
        _ = state.handleKey(down(K.down, scrollCombo))
        XCTAssertEqual(state.mode, .scrolling)
        // 스크롤 중 스크롤 키 뗌 → 정지
        XCTAssertEqual(state.handleModifiers(combo), [.motionChanged])
        XCTAssertEqual(state.mode, .idle)
    }

    func testClickKeysFireOncePerPress() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        XCTAssertEqual(state.handleKey(down(K.returnKey, combo)).commands, [.click(.left)])
        XCTAssertEqual(state.handleKey(down(K.returnKey, combo, repeat: true)).commands, [])
        XCTAssertEqual(state.handleKey(up(K.returnKey, combo)).consume, true)
        XCTAssertEqual(state.handleKey(down(K.r, combo)).commands, [.click(.right)])
        XCTAssertEqual(state.handleKey(down(K.d, combo)).commands, [.doubleClick])
        // Shift가 섞이면 동작 키가 아님
        XCTAssertEqual(state.handleKey(down(K.g, combo.union(.shift))), .pass)
        // Space는 쓰지 않는다 (⌃⌘Space 이모지 창과 충돌)
        XCTAssertEqual(state.handleKey(down(49, combo)), .pass)
    }

    func testDragWhileHeldAndEscape() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        XCTAssertEqual(state.handleKey(down(K.g, combo)).commands, [.beginDrag])
        XCTAssertTrue(state.isDragging)
        // 누르고 있는 동안 자동 반복은 아무 일도 안 하고, 이동은 된다
        XCTAssertEqual(state.handleKey(down(K.g, combo, repeat: true)), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(down(K.right, combo)).commands, [.motionChanged])
        XCTAssertTrue(state.isDragging)
        // 떼면 드래그 끝
        XCTAssertEqual(state.handleKey(up(K.g, combo)), KeyPointerDecision(consume: true, commands: [.endDrag]))
        XCTAssertFalse(state.isDragging)
        _ = state.handleKey(up(K.right, combo))

        _ = state.handleKey(down(K.g, combo))
        // Escape는 특수키 없이도 드래그를 끝낸다
        XCTAssertEqual(state.handleKey(down(K.escape, [])), KeyPointerDecision(consume: true, commands: [.endDrag]))
        XCTAssertEqual(state.handleKey(up(K.escape, [])).consume, true)
        // Escape로 끝낸 뒤의 드래그 키 뗌은 소비만 한다
        XCTAssertEqual(state.handleKey(up(K.g, combo)), KeyPointerDecision(consume: true))
        // 드래그 중이 아니면 Escape는 그대로 앱으로
        XCTAssertEqual(state.handleKey(down(K.escape, [])), .pass)
    }

    func testClicksRejectedButScrollAllowedWhileDragging() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.g, combo))
        XCTAssertEqual(state.handleKey(down(K.returnKey, combo)), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(down(K.r, combo)), KeyPointerDecision(consume: true))
        // 드래그 중 스크롤은 된다 (버튼을 누른 채 휠을 굴리듯)
        XCTAssertEqual(state.handleKey(down(K.up, scrollCombo)).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .scrolling)
        XCTAssertTrue(state.isDragging)
        _ = state.handleKey(up(K.up, scrollCombo))
        // 스크롤 키를 떼면 다음 방향키부터 다시 끌면서 이동
        _ = state.handleModifiers(combo)
        XCTAssertEqual(state.handleKey(down(K.right, combo)).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .moving)
        XCTAssertTrue(state.isDragging)
    }

    func testSettingsChangeStopsAll() {
        var state = KeyPointerInputState(modifierPair: .controlCommand)
        _ = state.handleKey(down(K.g, combo))
        _ = state.handleKey(down(K.left, combo))
        XCTAssertEqual(state.update(shortcut: PointerModifierPair.controlOption.shortcut), [.endDrag, .motionChanged])
        XCTAssertEqual(state.shortcut, PointerModifierPair.controlOption.shortcut)
        // 이전에 소비한 키의 up은 계속 소비
        XCTAssertEqual(state.handleKey(up(K.left, [])).consume, true)
    }
}

final class PointerMotionTests: XCTestCase {
    func testSingleDirectionVelocity() {
        XCTAssertEqual(PointerMotion.velocity(arrows: [.right], speed: 600, multiplier: 1), CGVector(dx: 600, dy: 0))
        XCTAssertEqual(PointerMotion.velocity(arrows: [.up], speed: 600, multiplier: 1), CGVector(dx: 0, dy: -600))
        XCTAssertEqual(PointerMotion.velocity(arrows: [], speed: 600, multiplier: 1), .zero)
    }

    func testDiagonalIsNormalized() {
        let v = PointerMotion.velocity(arrows: [.right, .down], speed: 600, multiplier: 1)
        XCTAssertEqual((v.dx * v.dx + v.dy * v.dy).squareRoot(), 600, accuracy: 0.001)
        XCTAssertEqual(v.dx, v.dy, accuracy: 0.001)
    }

    func testOppositeArrowsCancel() {
        XCTAssertEqual(PointerMotion.velocity(arrows: [.left, .right], speed: 600, multiplier: 1), .zero)
        XCTAssertEqual(PointerMotion.velocity(arrows: [.left, .right, .up], speed: 600, multiplier: 1), CGVector(dx: 0, dy: -600))
    }

    func testFastMultiplier() {
        XCTAssertEqual(PointerMotion.velocity(arrows: [.left], speed: 650, multiplier: 2.5).dx, -1_625, accuracy: 0.001)
    }

    func testFrameIntervalIsCappedAt50ms() {
        let v = CGVector(dx: 1_000, dy: -500)
        XCTAssertEqual(PointerMotion.displacement(velocity: v, elapsed: 0.016).dx, 16, accuracy: 0.001)
        XCTAssertEqual(PointerMotion.displacement(velocity: v, elapsed: 2), CGVector(dx: 50, dy: -25))
        XCTAssertEqual(PointerMotion.displacement(velocity: v, elapsed: -1), .zero)
    }

    func testScrollDeltaSignAndReverse() {
        // 위 화살표 → wheel1 양수(휠을 위로 굴린 것과 같음), 왼쪽 화살표 → wheel2 양수
        let up = PointerMotion.scrollDelta(arrows: [.up], speed: 600, multiplier: 1, reverse: false, elapsed: 0.05)
        XCTAssertEqual(up, CGVector(dx: 0, dy: 30))
        let left = PointerMotion.scrollDelta(arrows: [.left], speed: 600, multiplier: 1, reverse: false, elapsed: 0.05)
        XCTAssertEqual(left, CGVector(dx: 30, dy: 0))
        let reversed = PointerMotion.scrollDelta(arrows: [.up], speed: 600, multiplier: 1, reverse: true, elapsed: 0.05)
        XCTAssertEqual(reversed, CGVector(dx: 0, dy: -30))
    }
}

final class DisplayGeometryTests: XCTestCase {
    // 사용자 배치: D0(0…1920, 0…1080) · D2(1920…3840, 0…1080) · D1(1920…3720, 1080…2249)
    private let d0 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let d2 = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private let d1 = CGRect(x: 1920, y: 1080, width: 1800, height: 1169)
    private var displays: [CGRect] { [d0, d2, d1] }

    private func move(_ x: CGFloat, _ y: CGFloat, by dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        DisplayGeometry.move(from: CGPoint(x: x, y: y), by: CGVector(dx: dx, dy: dy), displays: displays)
    }

    func testMovesWithinDisplay() {
        XCTAssertEqual(move(500, 500, by: 10, -20), CGPoint(x: 510, y: 480))
    }

    func testCrossesTouchingEdge() {
        XCTAssertEqual(move(1915, 500, by: 20, 0), CGPoint(x: 1935, y: 500))   // D0 → D2
        XCTAssertEqual(move(2500, 1075, by: 0, 20), CGPoint(x: 2500, y: 1095)) // D2 → D1
    }

    func testStopsAtEdgeFacingEmptySpace() {
        XCTAssertEqual(move(500, 1075, by: 0, 50), CGPoint(x: 500, y: 1079))     // D0 아래는 빈 공간
        XCTAssertEqual(move(3700, 1500, by: 100, 0), CGPoint(x: 3719, y: 1500))  // D1 오른쪽은 빈 공간
        XCTAssertEqual(move(100, 10, by: 0, -50), CGPoint(x: 100, y: 0))         // 맨 위
    }

    func testOffsetDisplaysPassOnlyOnSharedSegment() {
        // D2 아래쪽 중 x 3720…3840 구간은 D1과 맞닿지 않음
        XCTAssertEqual(move(3800, 1075, by: 0, 30), CGPoint(x: 3800, y: 1079))
        XCTAssertEqual(move(3700, 1075, by: 0, 30), CGPoint(x: 3700, y: 1105))
    }

    func testCornerSlidesAlongAvailableAxis() {
        // D0 오른쪽 아래 근처에서 오른쪽·아래 대각선: 오른쪽은 D2로 이어지고 아래는 막힘
        XCTAssertEqual(move(1910, 1075, by: 20, 20), CGPoint(x: 1930, y: 1095))  // 가로로 D2 진입 후 세로로 D1까지
        XCTAssertEqual(move(500, 1075, by: 20, 20), CGPoint(x: 520, y: 1079))    // 아래가 막혀 가로로만 미끄러짐
    }

    func testLargeStepDoesNotJumpGap() {
        let gapped = [CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: 1100, y: 0, width: 1000, height: 1000)]
        let result = DisplayGeometry.move(from: CGPoint(x: 990, y: 500), by: CGVector(dx: 500, dy: 0), displays: gapped)
        XCTAssertEqual(result, CGPoint(x: 999, y: 500))
    }

    func testNegativeCoordinates() {
        let left = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let result = DisplayGeometry.move(from: CGPoint(x: 10, y: 500), by: CGVector(dx: -40, dy: -600), displays: [left, main])
        // 가로로 왼쪽 화면에 들어간 뒤, 왼쪽 화면은 위로 -300까지 있으므로 세로로 더 올라감
        XCTAssertEqual(result, CGPoint(x: -30, y: -100))
    }

    func testOutsidePointSnapsToNearestDisplay() {
        // 모니터 분리 직후 등: 빈 공간(D1 오른쪽 아래)에 있던 포인터
        XCTAssertEqual(DisplayGeometry.nearestPoint(to: CGPoint(x: 3800, y: 1500), displays: displays), CGPoint(x: 3719, y: 1500))
        XCTAssertEqual(move(3800, 1500, by: 0, 0), CGPoint(x: 3719, y: 1500))
    }
}

final class KeyPointerSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "WheelSpaceKeyPointerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private typealias K = KeyPointerInputState.KeyCode
    private let tab: UInt16 = 48

    private func key(_ code: UInt16, down isDown: Bool, _ modifiers: ModifierState) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: isDown, modifiers: modifiers)
    }

    func testDefaultPairIsOptionTab() {
        XCTAssertEqual(KeyPointerSettings.defaults.shortcut, .defaults)
        XCTAssertEqual(PointerModifierPair.optionTab.shortcut, .defaults)
        XCTAssertEqual(store.loadKeyPointer().shortcut, .defaults)
        XCTAssertEqual(PointerModifierPair.optionTab.base, .option)
        XCTAssertEqual(PointerModifierPair.optionTab.scrollModifier, .command)
        XCTAssertEqual(PointerModifierPair.optionTab.fastModifier, .shift)
        XCTAssertEqual(PointerModifierPair.optionTab.heldKeyCode, tab)
        XCTAssertNil(PointerModifierPair.controlShift.heldKeyCode)
    }

    func testOldControlTabValueFallsBackToDefault() {
        // 시스템 단축키와 겹쳐 뺀 ⌃Tab 저장값
        defaults.set("controlTab", forKey: SettingsStore.Key.pointerModifierPair)
        XCTAssertEqual(store.loadKeyPointer().shortcut, .defaults)
    }

    func testOptionTabHoldThenArrowMoves() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        // Tab은 누르는 순간 앱에 보내지 않고 잡아 둔다
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.option])), KeyPointerDecision(consume: true))
        XCTAssertTrue(state.isHeldKeyDown)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .moving)
        XCTAssertFalse(state.isFast)
        // 이동에 썼으니 Tab을 떼면 정지만 하고 ⌥Tab은 다시 보내지 않는다
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.handleKey(key(K.left, down: false, [.option])).consume, true)
        // Tab을 뗀 뒤의 ⌥ + 방향키는 다시 앱으로
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.option])), .pass)
    }

    func testOptionTabFastAndScroll() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        _ = state.handleKey(key(tab, down: true, [.option]))
        // ⌥⇧ = 빠르게
        _ = state.handleKey(key(K.right, down: true, [.option, .shift]))
        XCTAssertEqual(state.mode, .moving)
        XCTAssertTrue(state.isFast)
        _ = state.handleKey(key(K.right, down: false, [.option, .shift]))
        // ⌥⌘ = 스크롤 (다음 새 누름부터)
        _ = state.handleModifiers([.option, .command])
        XCTAssertEqual(state.handleKey(key(K.up, down: true, [.option, .command])).consume, true)
        XCTAssertEqual(state.mode, .scrolling)
    }

    func testOptionTabTapWithoutArrowReplays() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.option])).consume, true)
        // 기본은 ⌥Tab 두 번이 포인터 모드라, 두 번째 누름을 기다린 뒤 다시 보낸다
        XCTAssertEqual(
            state.handleKey(key(tab, down: false, [.option])),
            KeyPointerDecision(consume: true, commands: [.schedulePendingTap(after: KeyPointerInputState.doubleTapInterval)])
        )
        XCTAssertEqual(state.flushPendingTap(), [.replayKey(keyCode: tab, modifiers: [.option])])
        XCTAssertFalse(state.isHeldKeyDown)
        // 짝은 한 번뿐
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])), .pass)
    }

    func testOptionShiftTabTapReplaysWithShift() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.option, .shift])).consume, true)
        // ⌥를 먼저 떼도 누른 순간의 보조키로 다시 보낸다
        _ = state.handleModifiers([.shift])
        _ = state.handleKey(key(tab, down: false, [.shift]))
        XCTAssertEqual(
            state.flushPendingTap(),
            [.replayKey(keyCode: tab, modifiers: [.option, .shift])]
        )
    }

    func testArrowWithoutTabPassesInOptionTabMode() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        // ⌥ + ← 단어 단위 이동, ⌃⌥ + 방향키는 그대로 앱으로
        XCTAssertEqual(state.handleModifiers([.option]), [])
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.option])), .pass)
        XCTAssertEqual(state.handleKey(key(K.up, down: true, [.option, .control])), .pass)
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [.option])), .pass)
        XCTAssertEqual(state.mode, .idle)
    }

    func testTabReleaseEndsDrag() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        _ = state.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(state.handleKey(key(K.g, down: true, [.option])).commands, [.beginDrag])
        // G를 누른 채 Tab을 먼저 떼도 드래그 끝
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])), KeyPointerDecision(consume: true, commands: [.endDrag]))
        XCTAssertEqual(state.handleKey(key(K.g, down: false, [.option])), KeyPointerDecision(consume: true))
        XCTAssertFalse(state.isDragging)
    }

    func testPlainTabPasses() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        XCTAssertEqual(state.handleKey(key(tab, down: true, [])), .pass)
        XCTAssertEqual(state.handleKey(key(tab, down: false, [])), .pass)
        // ⌘Tab 앱 전환기, ⌃Tab 브라우저 탭 전환도 그대로
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.command])), .pass)
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.command])), .pass)
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.control])), .pass)
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.control])), .pass)
        XCTAssertFalse(state.isHeldKeyDown)
    }

    func testControlShiftPairUsesOptionForScrollAndCommandForFast() {
        XCTAssertEqual(PointerModifierPair.controlShift.base, [.control, .shift])
        XCTAssertEqual(PointerModifierPair.controlShift.scrollModifier, .option)
        XCTAssertEqual(PointerModifierPair.controlShift.fastModifier, .command)
    }

    func testControlShiftComboMovesAndFastWithCommand() {
        var state = KeyPointerInputState(modifierPair: .controlShift)
        XCTAssertEqual(state.handleKey(KeyEventInput(keyCode: K.left, isDown: true, modifiers: [.control, .shift])).consume, true)
        XCTAssertEqual(state.mode, .moving)
        XCTAssertFalse(state.isFast)
        XCTAssertEqual(state.handleModifiers([.control, .shift, .command]), [.motionChanged])
        XCTAssertTrue(state.isFast)
        _ = state.handleKey(KeyEventInput(keyCode: K.left, isDown: false, modifiers: [.control, .shift, .command]))

        // ⌃⌥⇧ = 스크롤
        var scroll = KeyPointerInputState(modifierPair: .controlShift)
        _ = scroll.handleKey(KeyEventInput(keyCode: K.up, isDown: true, modifiers: [.control, .option, .shift]))
        XCTAssertEqual(scroll.mode, .scrolling)

        // ⌃⇧ + ↩ = 클릭, ⌃⇧⌘ + ↩는 동작 키 아님
        var click = KeyPointerInputState(modifierPair: .controlShift)
        XCTAssertEqual(click.handleKey(KeyEventInput(keyCode: K.returnKey, isDown: true, modifiers: [.control, .shift])).commands, [.click(.left)])
        XCTAssertEqual(click.handleKey(KeyEventInput(keyCode: K.d, isDown: true, modifiers: [.control, .shift, .command])), .pass)
        // Shift만, Control만은 조합이 아님 (일반 선택 확장 등은 그대로)
        XCTAssertEqual(click.handleKey(KeyEventInput(keyCode: K.left, isDown: true, modifiers: [.shift])), .pass)
        XCTAssertEqual(click.handleKey(KeyEventInput(keyCode: K.left, isDown: true, modifiers: [.control])), .pass)
    }

    func testModifierPairScrollKeyIsTheRemainingKey() {
        XCTAssertEqual(PointerModifierPair.controlCommand.scrollModifier, .option)
        XCTAssertEqual(PointerModifierPair.controlOption.scrollModifier, .command)
        XCTAssertEqual(PointerModifierPair.optionCommand.scrollModifier, .control)
        for pair in PointerModifierPair.allCases {
            // 필수 특수키·스크롤 키·빠른 키는 서로 겹치지 않는다
            XCTAssertTrue(pair.base.intersection(pair.scrollModifier).isEmpty)
            XCTAssertTrue(pair.base.intersection(pair.fastModifier).isEmpty)
            XCTAssertTrue(pair.scrollModifier.intersection(pair.fastModifier).isEmpty)
        }
    }

    func testValidatedClampsRanges() {
        var settings = KeyPointerSettings.defaults
        settings.speed = 10
        settings.fastMultiplier = 99
        settings.scrollSpeed = .nan
        let validated = settings.validated()
        XCTAssertEqual(validated.speed, 100)
        XCTAssertEqual(validated.fastMultiplier, 4)
        XCTAssertEqual(validated.scrollSpeed, KeyPointerSettings.defaults.scrollSpeed)
    }

    func testDefaultsAndRoundTrip() {
        XCTAssertEqual(store.loadKeyPointer(), .defaults)
        XCTAssertFalse(KeyPointerSettings.defaults.isEnabled)
        let settings = KeyPointerSettings(
            isEnabled: true, shortcut: PointerModifierPair.optionCommand.shortcut, speed: 900, fastMultiplier: 3,
            scrollSpeed: 1_200, scrollFastMultiplier: 2.5, reverseScroll: true,
            accelerationTime: 0.8, startSpeedRatio: 0.3, toastOpacity: 0.4,
            exitOnTextInputClick: false, invertFastKey: true
        )
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer(), settings)
    }

    func testInvalidStoredValuesFallBack() {
        defaults.set("hyper", forKey: SettingsStore.Key.pointerModifierPair)
        defaults.set("fast", forKey: SettingsStore.Key.pointerSpeed)
        defaults.set(5_000, forKey: SettingsStore.Key.pointerScrollSpeed)
        let loaded = store.loadKeyPointer()
        XCTAssertEqual(loaded.shortcut, KeyPointerSettings.defaults.shortcut)
        XCTAssertEqual(loaded.speed, KeyPointerSettings.defaults.speed)
        XCTAssertEqual(loaded.scrollSpeed, 2_000)
        store.reset()
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.pointerScrollSpeed))
    }

    // MARK: - 사용자 지정 단축키

    private func custom(_ change: (inout PointerShortcut) -> Void) -> PointerShortcut {
        var shortcut = PointerShortcut.defaults
        change(&shortcut)
        return shortcut
    }

    func testDefaultShortcutIsValidAndHasNoWarnings() {
        XCTAssertEqual(PointerShortcut.defaults.issues, [])
        XCTAssertEqual(PointerShortcut.defaults.warnings, [])
        for pair in PointerModifierPair.allCases {
            XCTAssertTrue(pair.shortcut.isValid, "\(pair)")
        }
    }

    func testIssuesForInvalidModifiers() {
        XCTAssertEqual(custom { $0.base = [] }.issues, [.emptyBase])
        // 스크롤 키가 필수 보조키와 겹침
        XCTAssertEqual(custom { $0.scrollModifier = .option }.issues, [.invalidScrollModifier])
        // 빠르게 키가 보조키 둘
        XCTAssertEqual(custom { $0.fastModifier = [.shift, .command] }.issues, [.invalidFastModifier])
        XCTAssertEqual(custom { $0.fastModifier = .command }.issues, [.scrollEqualsFast])
    }

    func testIssuesForReservedAndDuplicateKeys() {
        let left = PointerKey(keyCode: 123, keyLabel: "←")
        XCTAssertEqual(custom { $0.leftClickKey = left }.issues, [.reservedKey(left)])
        let escape = PointerKey(keyCode: 53, keyLabel: "Esc")
        XCTAssertEqual(custom { $0.heldKey = escape }.issues, [.reservedKey(escape)])
        // 동작 키끼리, 누르고 있는 키와 동작 키가 겹침 — 한 키당 한 번만
        let r = PointerKey(keyCode: 15, keyLabel: "R")
        XCTAssertEqual(custom { $0.dragKey = r; $0.doubleClickKey = r }.issues, [.duplicateKey(r)])
        let tab = PointerKey(keyCode: 48, keyLabel: "⇥")
        XCTAssertEqual(custom { $0.leftClickKey = tab }.issues, [.duplicateKey(tab)])
    }

    func testWarnings() {
        XCTAssertEqual(custom { $0.base = .control; $0.scrollModifier = .option }.warnings, [.systemShortcutConflict])
        XCTAssertEqual(custom { $0.heldKey = nil; $0.slowKey = nil }.warnings, [.editingShortcutConflict])
        // 일반 키 느리게 키(A)를 누르고 있는 키 없이 쓰면 ⌥A를 가린다
        XCTAssertEqual(custom { $0.heldKey = nil }.warnings, [.editingShortcutConflict, .modeKeyWithoutHeldKey])
        XCTAssertEqual(PointerModifierPair.controlShift.shortcut.warnings, [])
    }

    func testCustomActionKeysAreUsed() {
        let space = PointerKey(keyCode: 49, keyLabel: "Space")
        let shortcut = custom { $0.leftClickKey = space }
        var state = KeyPointerInputState(shortcut: shortcut)
        _ = state.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(state.handleKey(key(49, down: true, [.option])).commands, [.click(.left)])
        _ = state.handleKey(key(49, down: false, [.option]))
        // 원래 키(↩)는 더 이상 동작 키가 아니다
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [.option])), .pass)
        XCTAssertEqual(shortcut.action(forKeyCode: 49), .leftClick)
        XCTAssertNil(shortcut.action(forKeyCode: K.returnKey))
    }

    func testCustomHeldKeyAndModifiers() {
        // ⌃⌘ + Space를 누른 채, 스크롤 ⌥, 빠르게 ⇧
        let shortcut = custom {
            $0.base = [.control, .command]
            $0.heldKey = PointerKey(keyCode: 49, keyLabel: "Space")
            $0.scrollModifier = .option
        }
        XCTAssertTrue(shortcut.isValid)
        XCTAssertEqual(shortcut.comboSymbol(), "⌃⌘Space")
        XCTAssertEqual(shortcut.comboSymbol(adding: .option), "⌃⌥⌘Space")
        var state = KeyPointerInputState(shortcut: shortcut)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.control, .command])), .pass)
        _ = state.handleKey(key(49, down: true, [.control, .command]))
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.control, .command])).commands, [.motionChanged])
        // Tab은 이 구성에서 아무 의미 없음
        XCTAssertEqual(state.handleKey(key(tab, down: true, [.option])), .pass)
    }

    func testPresetMatchingIgnoresActionKeys() {
        let shortcut = custom { $0.dragKey = PointerKey(keyCode: 3, keyLabel: "F") }
        XCTAssertEqual(PointerModifierPair.matching(shortcut), .optionTab)
        let applied = PointerModifierPair.controlCommand.applied(to: shortcut)
        XCTAssertEqual(applied.base, [.control, .command])
        XCTAssertNil(applied.heldKey)
        XCTAssertEqual(applied.dragKey.keyLabel, "F")
        XCTAssertNil(PointerModifierPair.matching(custom { $0.fastModifier = .control }))
    }

    func testCustomShortcutRoundTripAndMigration() {
        var settings = KeyPointerSettings.defaults
        settings.shortcut = custom {
            $0.base = [.control, .shift]
            $0.heldKey = nil
            $0.lockToggle = .off
            $0.scrollModifier = .option
            $0.fastModifier = .command
            $0.rightClickKey = PointerKey(keyCode: 17, keyLabel: "T")
        }
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().shortcut, settings.shortcut)

        // 이전 버전 프리셋 이름만 있는 경우
        let other = SettingsStore(defaults: defaults)
        defaults.removeObject(forKey: SettingsStore.Key.pointerShortcut)
        defaults.set("controlCommand", forKey: SettingsStore.Key.pointerModifierPair)
        XCTAssertEqual(other.loadKeyPointer().shortcut, PointerModifierPair.controlCommand.shortcut)
    }

    func testInvalidStoredShortcutFallsBackToDefault() {
        var broken = PointerShortcut.defaults
        broken.base = []
        defaults.set(try! JSONEncoder().encode(broken), forKey: SettingsStore.Key.pointerShortcut)
        XCTAssertEqual(store.loadKeyPointer().shortcut, .defaults)
        defaults.set(Data("garbage".utf8), forKey: SettingsStore.Key.pointerShortcut)
        XCTAssertEqual(store.loadKeyPointer().shortcut, .defaults)
    }

    func testReleaseHeldKeyAfterInterruption() {
        var state = KeyPointerInputState(modifierPair: .optionTab)
        _ = state.handleKey(key(tab, down: true, [.option]))
        _ = state.handleKey(key(K.left, down: true, [.option]))
        state.releaseHeldKey()
        XCTAssertEqual(state.stopAll(), [.motionChanged])
        XCTAssertFalse(state.isHeldKeyDown)
        // Tab 없이 된 상태라 ⌥ + →는 앱으로
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [.option])), .pass)
        // 늦게 온 Tab 뗌은 소비만 하고 ⌥Tab을 다시 보내지 않는다
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])), KeyPointerDecision(consume: true))
    }

    func testAccelerationFactorCurve() {
        func factor(_ t: Double, time: Double = 0.5) -> Double {
            PointerMotion.accelerationFactor(heldFor: t, accelerationTime: time, startRatio: 0.2)
        }
        XCTAssertEqual(factor(0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(factor(0.25), 0.6, accuracy: 0.0001)   // 곡선 가운데
        XCTAssertEqual(factor(0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(factor(3), 1, accuracy: 0.0001)
        XCTAssertEqual(factor(-1), 0.2, accuracy: 0.0001)
        XCTAssertLessThan(factor(0.1), factor(0.2))
        // 가속 끔
        XCTAssertEqual(factor(0, time: 0), 1)
    }

    func testAccelerationSettingsRoundTripAndClamp() {
        var settings = KeyPointerSettings.defaults
        XCTAssertEqual(settings.accelerationTime, 0.5)
        XCTAssertEqual(settings.startSpeedRatio, 0.15)
        settings.accelerationTime = 1.2
        settings.startSpeedRatio = 0.4
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().accelerationTime, 1.2)
        XCTAssertEqual(store.loadKeyPointer().startSpeedRatio, 0.4)

        settings.accelerationTime = 9
        settings.startSpeedRatio = .nan
        let validated = settings.validated()
        XCTAssertEqual(validated.accelerationTime, 1.5)
        XCTAssertEqual(validated.startSpeedRatio, KeyPointerSettings.defaults.startSpeedRatio)
    }

    func testDefaultScrollIsCommandAndFastIsShift() {
        XCTAssertEqual(PointerShortcut.defaults.scrollModifier, .command)
        XCTAssertEqual(PointerShortcut.defaults.fastModifier, .shift)
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(key(tab, down: true, [.option]))
        // ⌥⌘ = 스크롤 (Tab을 누른 채 새로 누른 방향키부터)
        _ = state.handleModifiers([.option, .command])
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [.option, .command])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .scrolling)
        _ = state.handleKey(key(K.down, down: false, [.option, .command]))
        // ⌥⇧ = 빠르게 이동
        _ = state.handleModifiers([.option, .shift])
        _ = state.handleKey(key(K.right, down: true, [.option, .shift]))
        XCTAssertEqual(state.mode, .moving)
        XCTAssertTrue(state.isFast)
        // ⌥⇧Tab도 빠르게 키를 뺀 나머지가 ⌥라 잡힌다
        var other = KeyPointerInputState(shortcut: .defaults)
        XCTAssertEqual(other.handleKey(key(tab, down: true, [.option, .shift])).consume, true)
    }

    func testConflictsWithFocusShortcuts() {
        let focusLeft = KeyCombo(keyCode: 123, modifiers: [.control, .option], keyLabel: "←")
        let unrelated = KeyCombo(keyCode: 40, modifiers: [.control, .option], keyLabel: "K")
        // 기본 구성은 ⌥ / ⌥⇧ / ⌥⌘ / ⌥⇧⌘ + 방향키라 안 겹침
        XCTAssertEqual(PointerShortcut.defaults.conflicts(with: [focusLeft, unrelated]), [])
        // 예전 기본값(스크롤 ⌃)은 ⌃⌥ + 방향키와 겹침
        let old = custom { $0.scrollModifier = .control }
        XCTAssertEqual(old.conflicts(with: [focusLeft, unrelated]), [focusLeft])
        // 빠르게 조합과도 비교
        let fastConflict = KeyCombo(keyCode: 125, modifiers: [.option, .shift], keyLabel: "↓")
        XCTAssertEqual(PointerShortcut.defaults.conflicts(with: [fastConflict]), [fastConflict])
    }

    // MARK: - 일반 키 스크롤·빠르게

    private let sKey = PointerKey(keyCode: 1, keyLabel: "S")
    private let fKey = PointerKey(keyCode: 3, keyLabel: "F")

    func testRegularScrollKeyHeldSwitchesToScroll() {
        var state = KeyPointerInputState(shortcut: custom { $0.scrollKey = .key(sKey) })
        _ = state.handleKey(key(tab, down: true, [.option]))
        _ = state.handleKey(key(K.down, down: true, [.option]))
        XCTAssertEqual(state.mode, .moving)
        // 방향키를 누른 채 S → 이동 멈춤, 다음 새 방향키부터 스크롤
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: true, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .idle)
        _ = state.handleKey(key(K.down, down: false, [.option]))
        _ = state.handleKey(key(K.down, down: true, [.option]))
        XCTAssertEqual(state.mode, .scrolling)
        // S 자동 반복은 소비만
        XCTAssertEqual(state.handleKey(KeyEventInput(keyCode: sKey.keyCode, isDown: true, isRepeat: true, modifiers: [.option])), KeyPointerDecision(consume: true))
        // S 뗌 → 스크롤 멈춤
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: false, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .idle)
        // 스크롤 키를 누른 동안은 동작 키가 아니다
        _ = state.handleKey(key(K.down, down: false, [.option]))
        _ = state.handleKey(key(sKey.keyCode, down: true, [.option]))
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [.option])), .pass)
        // ⌘(이전 스크롤 보조키)는 이제 조합이 아니다
        var other = KeyPointerInputState(shortcut: custom { $0.scrollKey = .key(sKey) })
        _ = other.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(other.handleKey(key(K.down, down: true, [.option, .command])), .pass)
    }

    func testRegularFastKeyHeld() {
        var state = KeyPointerInputState(shortcut: custom { $0.fastKey = .key(fKey) })
        _ = state.handleKey(key(tab, down: true, [.option]))
        _ = state.handleKey(key(K.right, down: true, [.option]))
        XCTAssertFalse(state.isFast)
        XCTAssertEqual(state.handleKey(key(fKey.keyCode, down: true, [.option])).commands, [.motionChanged])
        XCTAssertTrue(state.isFast)
        // 빠르게 키를 누른 채로도 드래그한다
        XCTAssertEqual(state.handleKey(key(K.g, down: true, [.option])).commands, [.beginDrag])
        XCTAssertEqual(state.handleKey(key(K.g, down: false, [.option])).commands, [.endDrag])
        XCTAssertEqual(state.handleKey(key(fKey.keyCode, down: false, [.option])).commands, [.motionChanged])
        XCTAssertFalse(state.isFast)
        // 빠르게 키를 누른 채 새로 누른 방향키도 빠르게
        _ = state.handleKey(key(fKey.keyCode, down: true, [.option]))
        _ = state.handleKey(key(K.up, down: true, [.option]))
        XCTAssertTrue(state.isFast)
    }

    func testRegularModeKeyPassesWithoutCombo() {
        var state = KeyPointerInputState(shortcut: custom { $0.scrollKey = .key(sKey) })
        // 보조키 없이, ⌥만(Tab 없이) 누른 S는 그냥 입력
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: true, [])), .pass)
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: false, [])), .pass)
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: true, [.option])), .pass)
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: false, [.option])), .pass)
        // 중단(탭 비활성화 등)되면 누름 기록도 풀린다
        _ = state.handleKey(key(tab, down: true, [.option]))
        _ = state.handleKey(key(sKey.keyCode, down: true, [.option]))
        state.releaseHeldKey()
        _ = state.stopAll()
        XCTAssertEqual(state.handleKey(key(sKey.keyCode, down: false, [.option])), KeyPointerDecision(consume: true))
    }

    func testModeKeyIssuesAndWarnings() {
        let scrollS = custom { $0.scrollKey = .key(sKey) }
        XCTAssertTrue(scrollS.isValid)
        XCTAssertEqual(scrollS.comboLabel(scroll: true), "⌥⇥ + S")
        XCTAssertEqual(scrollS.comboLabel(scroll: true, fast: true), "⌥⇧⇥ + S")
        XCTAssertEqual(scrollS.scrollModifier, [])
        // 동작 키·누르고 있는 키와 겹침, 방향키
        let r = PointerKey(keyCode: 15, keyLabel: "R")
        XCTAssertEqual(custom { $0.scrollKey = .key(r) }.issues, [.duplicateKey(r)])
        let down = PointerKey(keyCode: 125, keyLabel: "↓")
        XCTAssertEqual(custom { $0.fastKey = .key(down) }.issues, [.reservedKey(down)])
        // 스크롤·빠르게가 같은 일반 키
        XCTAssertEqual(custom { $0.scrollKey = .key(sKey); $0.fastKey = .key(sKey) }.issues, [.scrollEqualsFast, .duplicateKey(sKey)])
        // 누르고 있는 키 없이 일반 모드 키
        XCTAssertEqual(custom { $0.heldKey = nil; $0.base = [.control, .option]; $0.scrollKey = .key(sKey) }.warnings, [.modeKeyWithoutHeldKey])
    }

    func testLegacyShortcutJSONDecodes() throws {
        // 이전 버전 저장 형식 (scrollModifier·fastModifier 숫자)
        let legacy = #"{"base":4,"heldKey":{"keyCode":48,"keyLabel":"⇥"},"scrollModifier":2,"fastModifier":1,"#
            + #""leftClickKey":{"keyCode":36,"keyLabel":"↩"},"rightClickKey":{"keyCode":15,"keyLabel":"R"},"#
            + #""doubleClickKey":{"keyCode":2,"keyLabel":"D"},"dragKey":{"keyCode":5,"keyLabel":"G"}}"#
        let decoded = try JSONDecoder().decode(PointerShortcut.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.scrollKey, .modifier(.control))
        XCTAssertEqual(decoded.fastKey, .modifier(.shift))
        // 새 형식 왕복 (일반 키 포함)
        let scrollS = custom { $0.scrollKey = .key(sKey) }
        let data = try JSONEncoder().encode(scrollS)
        XCTAssertEqual(try JSONDecoder().decode(PointerShortcut.self, from: data), scrollS)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("scrollModifier"))
        // 저장소 경유
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.Key.pointerShortcut)
        XCTAssertEqual(store.loadKeyPointer().shortcut.scrollKey, .modifier(.control))
    }

    // MARK: - 포인터 모드 (고정 모드)

    private let iKey: UInt16 = 34

    private func timed(_ code: UInt16, down isDown: Bool, _ modifiers: ModifierState, at time: TimeInterval) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: isDown, modifiers: modifiers, timestamp: time)
    }

    /// ⌥Tab 두 번으로 포인터 모드를 켠 상태
    private func lockedState() -> KeyPointerInputState {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(timed(tab, down: true, [.option], at: 1.0))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 1.1))
        _ = state.handleKey(timed(tab, down: true, [.option], at: 1.2))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 1.3))
        _ = state.handleModifiers([])
        XCTAssertTrue(state.isLocked)
        return state
    }

    func testDoubleTapHeldKeyTogglesLock() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(timed(tab, down: true, [.option], at: 1.0))
        // 첫 탭은 바로 다시 보내지 않고 두 번째 누름을 기다린다
        XCTAssertEqual(
            state.handleKey(timed(tab, down: false, [.option], at: 1.1)),
            KeyPointerDecision(consume: true, commands: [.schedulePendingTap(after: KeyPointerInputState.doubleTapInterval)])
        )
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option], at: 1.3)).commands, [.lockChanged(true)])
        XCTAssertTrue(state.isLocked)
        // 두 번째 누름은 뗄 때 다시 보내지 않는다
        XCTAssertEqual(state.handleKey(timed(tab, down: false, [.option], at: 1.4)), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.flushPendingTap(), [])
        // 다시 두 번 → 끔
        _ = state.handleKey(timed(tab, down: true, [.option], at: 3.0))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 3.1))
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option], at: 3.2)).commands, [.lockChanged(false)])
        XCTAssertFalse(state.isLocked)
    }

    func testSingleTapReplaysAfterWait() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(timed(tab, down: true, [.option, .shift], at: 1.0))
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 1.1))
        // 엔진 타이머가 기다림이 끝났다고 부르면 누른 순간의 보조키로 다시 보낸다
        XCTAssertEqual(state.flushPendingTap(), [.replayKey(keyCode: tab, modifiers: [.option, .shift])])
        XCTAssertEqual(state.flushPendingTap(), [])
        // 간격이 지난 두 번째 누름은 두 번 누르기가 아니다 (첫 탭을 먼저 다시 보내고 새로 잡는다)
        _ = state.handleKey(timed(tab, down: false, [.option], at: 2.0)) // 짝 없는 뗌은 무시
        _ = state.handleKey(timed(tab, down: true, [.option], at: 5.0))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 5.1))
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option], at: 6.0)).commands, [.replayKey(keyCode: tab, modifiers: [.option])])
        XCTAssertFalse(state.isLocked)
    }

    func testOtherKeyFlushesPendingTap() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(timed(tab, down: true, [.option], at: 1.0))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 1.1))
        // 기다리는 중 다른 키 → 기다리던 ⌥Tab을 먼저 보내고 그 키는 평소대로
        XCTAssertEqual(
            state.handleKey(timed(40, down: true, [.option], at: 1.2)),
            KeyPointerDecision(consume: false, commands: [.replayKey(keyCode: tab, modifiers: [.option])])
        )
        XCTAssertEqual(state.flushPendingTap(), [])
    }

    func testLockedModeWorksWithoutModifiers() {
        var state = lockedState()
        // 방향키만으로 이동, 보조키·Tab을 다 뗀 상태
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .moving)
        // 보조키 변화로 멈추지 않는다
        XCTAssertEqual(state.handleModifiers([]), [])
        XCTAssertEqual(state.mode, .moving)
        _ = state.handleKey(key(K.right, down: false, []))
        // ⇧ = 빠르게, ⌘ = 스크롤
        _ = state.handleKey(key(K.left, down: true, [.shift]))
        XCTAssertTrue(state.isFast)
        _ = state.handleKey(key(K.left, down: false, [.shift]))
        _ = state.handleModifiers([.command])
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [.command])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .scrolling)
        _ = state.handleKey(key(K.down, down: false, [.command]))
        _ = state.handleModifiers([])
        // 클릭 키 단독
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [])).commands, [.click(.left)])
        // ⌥ + 글자·방향키는 앱의 ⌥ 단축키로 보낸다 (⌥D 더블클릭·⌥← 포인터 이동이 되지 않게)
        XCTAssertEqual(state.handleKey(key(K.r, down: true, [.option])), .pass)
        XCTAssertEqual(state.handleKey(key(K.d, down: true, [.option])), .pass)
        XCTAssertEqual(state.handleKey(key(13, down: true, [.option])), .pass)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.option])), .pass)
        XCTAssertTrue(state.isLocked)
        // ⌥ + Tab을 누른 채면 지금처럼 포인터 조작
        _ = state.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(state.handleKey(key(K.r, down: true, [.option])).commands, [.click(.right)])
    }

    func testOptionHeldRightAfterLockStillMovesPointer() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(timed(tab, down: true, [.option], at: 0))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 0.05))
        _ = state.handleKey(timed(tab, down: true, [.option], at: 0.15))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 0.2))
        XCTAssertTrue(state.isLocked)
        // ⌥를 쥔 채 바로 방향키·R → 포인터
        XCTAssertEqual(state.handleKey(timed(K.right, down: true, [.option], at: 0.5)).commands, [.motionChanged])
        _ = state.handleKey(timed(K.right, down: false, [.option], at: 0.6))
        XCTAssertEqual(state.handleKey(timed(K.r, down: true, [.option], at: 0.7)).commands, [.click(.right)])
        _ = state.handleKey(timed(K.r, down: false, [.option], at: 0.8))
        // ⌥를 한 번 뗀 뒤 다시 누른 ⌥ + 글자·방향키는 앱으로
        _ = state.handleModifiers([])
        _ = state.handleModifiers([.option])
        XCTAssertEqual(state.handleKey(timed(K.d, down: true, [.option], at: 2)), .pass)
        XCTAssertEqual(state.handleKey(timed(K.left, down: true, [.option], at: 2.1)), .pass)
        // 보조키 없이는 그대로 포인터
        _ = state.handleModifiers([])
        XCTAssertEqual(state.handleKey(timed(K.right, down: true, [], at: 3)).commands, [.motionChanged])
    }

    func testLockedModeSwallowsTextAndInsertKeyExits() {
        var state = lockedState()
        // 글자 키·⇧+글자는 앱에 보내지 않는다 (명령 없음, 뗌도 소비)
        XCTAssertEqual(state.handleKey(key(40, down: true, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(key(40, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(key(40, down: true, [.shift])), KeyPointerDecision(consume: true))
        _ = state.handleKey(key(40, down: false, [.shift]))
        // ⌘C 같은 유지할 단축키와 Esc는 그대로
        XCTAssertEqual(state.handleKey(key(8, down: true, [.command])), .pass)
        XCTAssertEqual(state.handleKey(key(K.escape, down: true, [])), .pass)
        // 🌐/Fn, 기능 키, Fn + 방향키(Home·End·Page Up·Page Down)도 그대로
        XCTAssertEqual(state.handleKey(key(179, down: true, [])), .pass)
        XCTAssertEqual(state.handleKey(key(122, down: true, [])), .pass)   // F1
        XCTAssertEqual(state.handleKey(key(115, down: true, [])), .pass)   // Home
        XCTAssertEqual(state.handleKey(key(121, down: true, [.shift])), .pass) // ⇧ Page Down
        // ⇧I는 막고 포인터 모드 유지
        XCTAssertEqual(state.handleKey(key(iKey, down: true, [.shift])), KeyPointerDecision(consume: true))
        _ = state.handleKey(key(iKey, down: false, [.shift]))
        XCTAssertTrue(state.isLocked)
        // I → 입력 모드
        XCTAssertEqual(state.handleKey(key(iKey, down: true, [])), KeyPointerDecision(consume: true, commands: [.lockChanged(false)]))
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.handleKey(key(iKey, down: false, [])), KeyPointerDecision(consume: true))
        // 입력 모드에서는 글자·방향키가 그대로 앱으로
        XCTAssertEqual(state.handleKey(key(40, down: true, [])), .pass)
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [])), .pass)
    }

    func testShortcutLockToggle() {
        let combo = KeyCombo(keyCode: 35, modifiers: [.control, .option, .command], keyLabel: "P")
        var state = KeyPointerInputState(shortcut: custom { $0.lockToggle = .shortcut(combo) })
        XCTAssertEqual(state.handleKey(key(35, down: true, [.control, .option, .command])).commands, [.lockChanged(true)])
        XCTAssertEqual(state.handleKey(key(35, down: false, [.control, .option, .command])).consume, true)
        _ = state.handleModifiers([])
        _ = state.handleKey(key(K.g, down: true, []))
        _ = state.handleKey(key(K.up, down: true, []))
        XCTAssertTrue(state.isDragging)
        // 끌 때 드래그·이동 정지
        XCTAssertEqual(
            state.handleKey(key(35, down: true, [.control, .option, .command])).commands,
            [.endDrag, .motionChanged, .lockChanged(false)]
        )
        // 단축키 방식에서는 ⌥Tab 한 번이 바로 다시 보내진다
        _ = state.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])).commands, [.replayKey(keyCode: tab, modifiers: [.option])])
    }

    func testLockToggleIssueAndCodable() throws {
        XCTAssertEqual(custom { $0.heldKey = nil; $0.base = [.control, .option] }.issues, [.lockToggleNeedsHeldKey])
        XCTAssertEqual(custom { $0.heldKey = nil; $0.base = [.control, .option]; $0.lockToggle = .off }.issues, [])
        // 입력 키도 중복 검사
        let r = PointerKey(keyCode: 15, keyLabel: "R")
        XCTAssertEqual(custom { $0.insertKey = r }.issues, [.duplicateKey(r)])
        XCTAssertEqual(custom { $0.insertKey = r; $0.lockToggle = .off }.issues, [])
        // 이전 저장값에는 없다 → 기본값
        let data = try JSONEncoder().encode(PointerShortcut.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "lockToggle")
        object.removeValue(forKey: "insertKey")
        let legacy = try JSONDecoder().decode(PointerShortcut.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy, .defaults)
        // 왕복
        let combo = custom { $0.lockToggle = .shortcut(KeyCombo(keyCode: 35, modifiers: [.command], keyLabel: "P")) }
        XCTAssertEqual(try JSONDecoder().decode(PointerShortcut.self, from: JSONEncoder().encode(combo)), combo)
    }

    func testToastOpacityRoundTripAndClamp() {
        XCTAssertEqual(KeyPointerSettings.defaults.toastOpacity, 0.6)
        var settings = KeyPointerSettings.defaults
        settings.toastOpacity = 0.35
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().toastOpacity, 0.35)
        settings.toastOpacity = 0
        XCTAssertEqual(settings.validated().toastOpacity, 0.1)
        settings.toastOpacity = .nan
        XCTAssertEqual(settings.validated().toastOpacity, 0.6)
    }

    // MARK: - 포인터 모드 자동 해제

    private let space: UInt16 = 49

    func testExitShortcutUnlocksAndPasses() {
        var state = lockedState()
        _ = state.handleKey(key(K.right, down: true, []))
        // ⌘Space → 포인터 모드 끄고(이동 정지) 단축키는 앱에 그대로
        XCTAssertEqual(
            state.handleKey(key(space, down: true, [.command])),
            KeyPointerDecision(consume: false, commands: [.motionChanged, .lockChanged(false)])
        )
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.handleKey(key(space, down: false, [.command])), .pass)
        // 이후 글자는 그대로 입력
        XCTAssertEqual(state.handleKey(key(40, down: true, [])), .pass)
        // ⌥Space도 기본 목록
        var other = lockedState()
        XCTAssertEqual(other.handleKey(key(space, down: true, [.option])).commands, [.lockChanged(false)])
    }

    func testExitShortcutIgnoredWhenNotLocked() {
        var state = KeyPointerInputState(shortcut: .defaults)
        XCTAssertEqual(state.handleKey(key(space, down: true, [.command])), .pass)
        // 목록에 없는 조합은 해제 단축키가 아니다 (앱 단축키 해제를 끄면 ⌃Space는 통과만)
        var locked = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .ignore })
        _ = locked.setLocked(true)
        XCTAssertEqual(locked.handleKey(key(space, down: true, [.control])), .pass)
        XCTAssertTrue(locked.isLocked)
        // 사용자가 목록을 비우면 ⌘Space도 해제하지 않는다
        XCTAssertFalse(custom { $0.exitShortcuts = [] }.isExitShortcut(keyCode: space, modifiers: .command))
    }

    func testExitSettingsRoundTripAndLegacy() throws {
        XCTAssertEqual(PointerShortcut.defaults.exitShortcuts.map(\.displayString), ["⌘Space", "⌥Space"])
        XCTAssertTrue(KeyPointerSettings.defaults.exitOnTextInputClick)
        // 왕복 (사용자 단축키 추가)
        let custom = KeyCombo(keyCode: 49, modifiers: [.option, .shift], keyLabel: "Space")
        var settings = KeyPointerSettings.defaults
        settings.shortcut.exitShortcuts.append(custom)
        settings.exitOnTextInputClick = false
        store.saveKeyPointer(settings)
        let loaded = store.loadKeyPointer()
        XCTAssertEqual(loaded.shortcut.exitShortcuts.last, custom)
        XCTAssertFalse(loaded.exitOnTextInputClick)
        // 이전 저장값에는 없다 → 기본 목록
        let data = try JSONEncoder().encode(PointerShortcut.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "exitShortcuts")
        let legacy = try JSONDecoder().decode(PointerShortcut.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.exitShortcuts, PointerShortcut.defaultExitShortcuts)
    }

    private let aKey = PointerKey(keyCode: 0, keyLabel: "A")

    func testLockedModeSwallowsNonPointerKeys() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.setLocked(true)
        // Tab·Space·Delete·숫자는 막는다
        for code: UInt16 in [48, 49, 51, 18] {
            XCTAssertEqual(state.handleKey(key(code, down: true, [])), KeyPointerDecision(consume: true))
            XCTAssertEqual(state.handleKey(key(code, down: false, [])), KeyPointerDecision(consume: true))
        }
        // 포인터용 키는 그대로 동작: 방향키, 클릭, 느리게 키
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.handleKey(key(K.right, down: false, [])).commands, [.motionChanged])
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [])).commands, [.click(.left)])
        XCTAssertTrue(state.handleKey(key(K.returnKey, down: false, [])).consume)
        XCTAssertTrue(state.handleKey(key(aKey.keyCode, down: true, [])).consume)
        XCTAssertTrue(state.isLocked)
    }

    func testAppShortcutExitsLockedMode() {
        let bKey: UInt16 = 11
        var state = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .exit })
        _ = state.setLocked(true)
        // 유지: ⌘C, ⌘Tab, ⌘ + 방향키(스크롤), 글자(막힘)
        XCTAssertEqual(state.handleKey(key(8, down: true, [.command])), .pass)
        XCTAssertEqual(state.handleKey(key(48, down: true, [.command])), .pass)
        XCTAssertTrue(state.handleKey(key(K.down, down: true, [.command])).consume)
        _ = state.handleKey(key(K.down, down: false, [.command]))
        XCTAssertEqual(state.handleKey(key(40, down: true, [])), KeyPointerDecision(consume: true))
        // 자동 반복은 해제하지 않는다
        XCTAssertEqual(state.handleKey(KeyEventInput(keyCode: bKey, isDown: true, isRepeat: true, modifiers: .command)), .pass)
        XCTAssertTrue(state.isLocked)
        // ⌘B → 해제 + 앱으로
        XCTAssertEqual(state.handleKey(key(bKey, down: true, [.command])), KeyPointerDecision(consume: false, commands: [.lockChanged(false)]))
        XCTAssertFalse(state.isLocked)
        XCTAssertFalse(state.isSuspended)
        // ⌃⇧O도
        _ = state.setLocked(true)
        XCTAssertEqual(state.handleKey(key(31, down: true, [.control, .shift])).commands, [.lockChanged(false)])

        // 옵션을 끄면 유지, ⌘R은 오른쪽 클릭이 아니라 앱으로
        var off = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .ignore; $0.scrollKey = .key(sKey) })
        _ = off.setLocked(true)
        XCTAssertEqual(off.handleKey(key(bKey, down: true, [.command])), .pass)
        XCTAssertEqual(off.handleKey(key(K.r, down: true, [.command])), .pass)
        XCTAssertTrue(off.isLocked)
        XCTAssertEqual(off.handleKey(key(K.r, down: true, [])).commands, [.click(.right)])
    }

    func testAppShortcutSettingsCodableAndPreset() throws {
        XCTAssertEqual(PointerShortcut.defaults.appShortcutAction, .whileHeld)
        XCTAssertEqual(PointerShortcut.defaults.keepShortcuts, PointerShortcut.defaultKeepShortcuts)
        var settings = KeyPointerSettings.defaults
        let cmdB = KeyCombo(keyCode: 11, modifiers: .command, keyLabel: "B")
        settings.shortcut.appShortcutAction = .exit
        settings.shortcut.keepShortcuts = [cmdB]
        settings.shortcut.exitShortcuts = [cmdB]
        store.saveKeyPointer(settings)
        let loaded = store.loadKeyPointer().shortcut
        XCTAssertEqual(loaded.appShortcutAction, .exit)
        XCTAssertEqual(loaded.keepShortcuts, [cmdB])
        // 이전 저장값 → 기본
        let data = try JSONEncoder().encode(PointerShortcut.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "appShortcutAction")
        object.removeValue(forKey: "keepShortcuts")
        let legacy = try JSONDecoder().decode(PointerShortcut.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.appShortcutAction, .whileHeld)
        // 켜고 끄기만 있던 버전: 꺼짐 → 아무것도 안 함
        object["exitOnAppShortcut"] = false
        let legacyOff = try JSONDecoder().decode(PointerShortcut.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacyOff.appShortcutAction, .ignore)
        XCTAssertEqual(legacy.keepShortcuts, PointerShortcut.defaultKeepShortcuts)
        // 프리셋을 바꿔도 그대로
        let applied = PointerModifierPair.controlShift.applied(to: loaded)
        XCTAssertEqual(applied.exitShortcuts, [cmdB])
        XCTAssertEqual(applied.keepShortcuts, [cmdB])
        XCTAssertEqual(applied.appShortcutAction, .exit)
        XCTAssertTrue(PointerShortcut.defaults.stripsHeldModifier)
        XCTAssertTrue(legacy.stripsHeldModifier)
        var noStrip = KeyPointerSettings.defaults
        noStrip.shortcut.stripsHeldModifier = false
        store.saveKeyPointer(noStrip)
        XCTAssertFalse(store.loadKeyPointer().shortcut.stripsHeldModifier)
        XCTAssertFalse(PointerModifierPair.controlShift.applied(to: noStrip.shortcut).stripsHeldModifier)
    }

    func testAppShortcutWhileHeldResumesOnModifierRelease() {
        let bKey: UInt16 = 11, eKey: UInt16 = 14
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.setLocked(true)
        // ⌘B → 해제 (예약 없음), 단축키는 앱으로
        XCTAssertEqual(state.handleKey(key(bKey, down: true, [.command])), KeyPointerDecision(consume: false, commands: [.lockChanged(false)]))
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.suspendsWhileHeld)
        // ⌘를 누른 채 이어서 쓰는 단축키는 앱으로, 시간이 지나도 그대로
        XCTAssertEqual(state.handleKey(key(bKey, down: false, [.command])), .pass)
        XCTAssertEqual(state.handleKey(key(eKey, down: true, [.command])), .pass)
        // ⌘를 쥔 채 방향키·↩·Esc는 ⌘를 빼고 보낸다 (자동 반복도, ⇧는 남긴다), 뗌은 삼킨다
        let stripped = KeyPointerDecision(consume: false, stripsCommandControl: true)
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [.command])), stripped)
        XCTAssertEqual(state.handleKey(KeyEventInput(keyCode: K.down, isDown: true, isRepeat: true, modifiers: .command)), stripped)
        XCTAssertEqual(state.handleKey(key(K.down, down: false, [.command])), stripped)
        XCTAssertEqual(state.handleKey(key(K.up, down: true, [.command, .shift])), stripped)
        _ = state.handleKey(key(K.up, down: false, [.command, .shift]))
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [.command])), stripped)
        XCTAssertEqual(state.handleKey(key(K.escape, down: true, [.command])), stripped)
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.resumeIfIdle(now: 100), [])
        XCTAssertFalse(state.isLocked)
        // ⇧만 떼도 ⌘가 남아 있으면 그대로
        XCTAssertEqual(state.handleModifiers([.command]), [])
        // ⌘를 떼면 다시 포인터 모드 (↩·Esc 뗌은 포인터 모드가 된 뒤에도 같이 앱으로)
        XCTAssertEqual(state.handleModifiers([]), [.lockChanged(true)])
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isSuspended)
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: false, [])), stripped)
        XCTAssertEqual(state.handleKey(key(K.escape, down: false, [])), stripped)
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [])).commands, [.motionChanged])

        // ⌃ 단축키도 같다
        _ = state.handleKey(key(K.right, down: false, []))
        _ = state.handleKey(key(31, down: true, [.control, .shift]))
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.handleModifiers([.control]), [])
        XCTAssertEqual(state.handleModifiers([]), [.lockChanged(true)])

        // ⌘ 없이 보내기를 끄면 ⌘↓는 원래 단축키로
        var plain = KeyPointerInputState(shortcut: custom { $0.stripsHeldModifier = false })
        _ = plain.setLocked(true)
        _ = plain.handleKey(key(bKey, down: true, [.command]))
        XCTAssertEqual(plain.handleKey(key(K.down, down: true, [.command])), .pass)
        XCTAssertTrue(plain.isSuspended)

        // 해제 단축키(⌘Space)를 누르면 완전히 해제 — ⌘를 떼도 돌아오지 않는다
        _ = state.handleKey(key(bKey, down: true, [.command]))
        XCTAssertEqual(state.handleKey(key(49, down: true, [.command])), .pass)
        XCTAssertFalse(state.isSuspended)
        XCTAssertEqual(state.handleModifiers([]), [])
        XCTAssertFalse(state.isLocked)
    }

    func testCommandArrowIsAppShortcutWhenNotScroll() {
        // 스크롤 키가 S면 ⌘↑는 앱 단축키: 보조키를 누르는 동안 해제, ⌘를 쥔 채 ↓는 ⌘ 빼고, 떼면 돌아온다
        var state = KeyPointerInputState(shortcut: custom { $0.scrollKey = .key(sKey) })
        _ = state.setLocked(true)
        XCTAssertEqual(state.handleKey(key(K.up, down: true, [.command])), KeyPointerDecision(consume: false, commands: [.lockChanged(false)]))
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [.command])), KeyPointerDecision(consume: false, stripsCommandControl: true))
        XCTAssertEqual(state.handleModifiers([]), [.lockChanged(true)])

        // 스크롤 키가 ⌘(기본)면 ⌘↓는 포인터 스크롤 그대로
        var scroll = KeyPointerInputState(shortcut: .defaults)
        _ = scroll.setLocked(true)
        XCTAssertEqual(scroll.handleKey(key(K.down, down: true, [.command])).commands, [.motionChanged])
        XCTAssertEqual(scroll.mode, .scrolling)
        XCTAssertTrue(scroll.isLocked)
    }

    func testOwnShortcutsAreNotAppShortcuts() {
        let focusLeft = KeyCombo(keyCode: K.left, modifiers: [.control, .option], keyLabel: "←")
        var state = KeyPointerInputState(shortcut: custom { $0.scrollKey = .key(sKey) })
        state.ownShortcuts = [focusLeft]
        _ = state.setLocked(true)
        // 창 포커스 이동 ⌃⌥←: 포인터 모드 그대로, 그 기능으로
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.control, .option])), .pass)
        XCTAssertTrue(state.isLocked)
        // ⌘B로 보조키 누르는 동안 해제 중에도 ⌃⌥←는 보조키를 빼지 않는다
        _ = state.handleKey(key(11, down: true, [.command]))
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.control, .option, .command])).stripsCommandControl, true)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [.control, .option])), .pass)
    }

    func testModifierSlowKeyMovesPointer() {
        var state = KeyPointerInputState(shortcut: custom { $0.slowKey = .modifier(.control) })
        _ = state.setLocked(true)
        XCTAssertEqual(state.handleKey(key(K.right, down: true, [.control])).commands, [.motionChanged])
        XCTAssertTrue(state.isSlow)
        XCTAssertEqual(state.mode, .moving)
        XCTAssertTrue(state.isLocked)
    }

    func testShiftTapWhileHeldExitsFully() {
        let bKey: UInt16 = 11, fKeyCode: UInt16 = 3
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.setLocked(true)
        _ = state.handleKey(key(bKey, down: true, [.command]))
        // ⌘⇧F처럼 ⇧와 다른 키를 함께 누르면 해제하지 않는다
        XCTAssertEqual(state.handleModifiers([.command, .shift]), [])
        _ = state.handleKey(key(fKeyCode, down: true, [.command, .shift]))
        XCTAssertEqual(state.handleModifiers([.command]), [])
        XCTAssertTrue(state.isSuspended)
        // ⇧만 눌렀다 떼면 완전히 해제 — ⌘를 떼도 돌아오지 않고, ↓는 그냥 앱으로
        _ = state.handleModifiers([.command, .shift])
        XCTAssertEqual(state.handleModifiers([.command]), [])
        XCTAssertFalse(state.isSuspended)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.handleModifiers([]), [])
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [])), .pass)
    }

    func testAppShortcutSuspendResumesWhenIdle() {
        let bKey: UInt16 = 11
        var state = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .suspend })
        _ = state.setLocked(true)
        // ⌘B → 잠깐 해제, 단축키는 앱으로, 확인 예약
        XCTAssertEqual(
            state.handleKey(timed(bKey, down: true, [.command], at: 10)),
            KeyPointerDecision(consume: false, commands: [.lockChanged(false), .scheduleResumeCheck(after: KeyPointerInputState.suspendIdleResume)])
        )
        XCTAssertFalse(state.isLocked)
        XCTAssertTrue(state.isSuspended)
        // 잠깐 해제 중 방향키는 앱으로
        _ = state.handleKey(timed(bKey, down: false, [.command], at: 10.05))
        // 입력 없이 시간이 지나면 다시 포인터 모드
        XCTAssertEqual(state.resumeIfIdle(now: 10.7), [.lockChanged(true)])
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isSuspended)
    }

    func testAppShortcutSuspendResumesOnReturnOrEscape() {
        let bKey: UInt16 = 11
        var state = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .suspend })
        _ = state.setLocked(true)
        _ = state.handleKey(timed(bKey, down: true, [.command], at: 10))
        // 목록에서 방향키·글자 → 앱으로, 시간이 지나도 돌아오지 않는다
        XCTAssertEqual(state.handleKey(timed(K.down, down: true, [], at: 10.2)), .pass)
        XCTAssertEqual(state.handleKey(timed(K.down, down: false, [], at: 10.3)), .pass)
        XCTAssertEqual(state.handleKey(timed(40, down: true, [], at: 10.4)), .pass)
        XCTAssertEqual(state.resumeIfIdle(now: 11), [])
        XCTAssertTrue(state.isSuspended)
        // ↩ → 앱으로 보내고 다시 포인터 모드, 뗌도 앱으로
        XCTAssertEqual(state.handleKey(timed(K.returnKey, down: true, [], at: 12)), KeyPointerDecision(consume: false, commands: [.lockChanged(true)]))
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.handleKey(timed(K.returnKey, down: false, [], at: 12.1)), .pass)

        // Esc도
        _ = state.handleKey(timed(bKey, down: true, [.command], at: 20))
        _ = state.handleKey(timed(K.up, down: true, [], at: 20.1))
        XCTAssertEqual(state.handleKey(timed(K.escape, down: true, [], at: 21)).commands, [.lockChanged(true)])
    }

    func testAppShortcutSuspendRestartAndCancel() {
        let bKey: UInt16 = 11
        var state = KeyPointerInputState(shortcut: custom { $0.appShortcutAction = .suspend })
        _ = state.setLocked(true)
        _ = state.handleKey(timed(bKey, down: true, [.command], at: 10))
        // 잠깐 해제 중 다른 앱 단축키 → 다시 시작, 처음 예약이 불려도 남은 시간만큼 다시 예약
        XCTAssertEqual(state.handleKey(timed(bKey, down: true, [.command, .option], at: 10.5)).commands,
                       [.scheduleResumeCheck(after: KeyPointerInputState.suspendIdleResume)])
        XCTAssertEqual(state.resumeIfIdle(now: 10.7).count, 1)
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.resumeIfIdle(now: 11.2), [.lockChanged(true)])

        // 해제 단축키(⌘Space) → 완전히 해제, 이후 ↩은 그냥 앱으로
        _ = state.handleKey(timed(bKey, down: true, [.command], at: 20))
        XCTAssertEqual(state.handleKey(timed(49, down: true, [.command], at: 20.1)), .pass)
        XCTAssertFalse(state.isSuspended)
        XCTAssertEqual(state.handleKey(timed(K.returnKey, down: true, [], at: 21)), .pass)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.resumeIfIdle(now: 30), [])

        // 메뉴 열기 등 setLocked(false)도 잠깐 해제를 끝낸다
        _ = state.setLocked(true)
        _ = state.handleKey(timed(bKey, down: true, [.command], at: 40))
        _ = state.setLocked(false)
        XCTAssertFalse(state.isSuspended)
        XCTAssertEqual(state.resumeIfIdle(now: 50), [])
    }

    private typealias L = LeftHandLayout

    /// 사용자 설정과 비슷하게: 스크롤 S·드래그 F (왼손 배치와 겹친다)
    private func leftHandState(enabled: Bool = true, locked: Bool = true) -> KeyPointerInputState {
        var state = KeyPointerInputState(shortcut: custom {
            $0.scrollKey = .key(sKey)
            $0.dragKey = PointerKey(keyCode: 3, keyLabel: "F")
        })
        if locked { _ = state.setLocked(true, leftHand: enabled) }
        return state
    }

    func testLeftHandLayoutMovesAndScrolls() {
        var state = leftHandState()
        // D → 오른쪽, W 함께 → 대각선
        XCTAssertEqual(state.handleKey(key(L.right, down: true, [])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertEqual(state.mode, .moving)
        _ = state.handleKey(key(L.up, down: true, []))
        XCTAssertEqual(state.activeArrows, [.right, .up])
        // 자동 반복은 명령 없이 소비
        XCTAssertEqual(state.handleKey(KeyEventInput(keyCode: L.right, isDown: true, isRepeat: true, modifiers: [])), KeyPointerDecision(consume: true))
        // ⇧ 빠르게
        XCTAssertEqual(state.handleModifiers([.shift]), [.motionChanged])
        XCTAssertTrue(state.isFast)
        _ = state.handleModifiers([])
        // 이동 중 R(스크롤)은 무시
        XCTAssertEqual(state.handleKey(key(L.scrollUp, down: true, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(key(L.scrollUp, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.activeArrows, [.right, .up])
        // 뗌 → 정지
        XCTAssertEqual(state.handleKey(key(L.up, down: false, [])).commands, [.motionChanged])
        XCTAssertEqual(state.handleKey(key(L.right, down: false, [])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .idle)
        // F → 아래로 스크롤 (누른 채 다른 키 없이)
        XCTAssertEqual(state.handleKey(key(L.scrollDown, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .scrolling)
        XCTAssertEqual(state.activeArrows, [.down])
        // 스크롤 중 S(아래 이동)는 무시, 뗌도 스크롤을 멈추지 않는다
        _ = state.handleKey(key(L.down, down: true, []))
        XCTAssertEqual(state.handleKey(key(L.down, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.activeArrows, [.down])
        XCTAssertEqual(state.handleKey(key(L.scrollDown, down: false, [])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .idle)
        // R → 위로 스크롤, T 함께 → 오른쪽 위 대각선 스크롤, E → 왼쪽
        XCTAssertEqual(state.handleKey(key(L.scrollUp, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.activeArrows, [.up])
        XCTAssertEqual(state.handleKey(key(L.scrollRight, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.activeArrows, [.up, .right])
        XCTAssertEqual(state.mode, .scrolling)
        _ = state.handleKey(key(L.scrollUp, down: false, []))
        _ = state.handleKey(key(L.scrollRight, down: false, []))
        XCTAssertEqual(state.handleKey(key(L.scrollLeft, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.activeArrows, [.left])
        _ = state.handleKey(key(L.scrollLeft, down: false, []))
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.handleKey(key(K.left, down: true, [])).commands, [.motionChanged])
        XCTAssertEqual(state.mode, .moving)
    }

    func testLeftHandLayoutClicksAndDrag() {
        var state = leftHandState()
        XCTAssertEqual(state.handleKey(key(L.leftClick, down: true, [])), KeyPointerDecision(consume: true, commands: [.click(.left)]))
        XCTAssertEqual(state.handleKey(key(L.leftClick, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(key(L.rightClick, down: true, [])).commands, [.click(.right)])
        _ = state.handleKey(key(L.rightClick, down: false, []))
        // V 한 번 → 드래그 시작, 떼도 계속, 이동, 다시 V → 놓기
        XCTAssertEqual(state.handleKey(key(L.dragToggle, down: true, [])).commands, [.beginDrag])
        XCTAssertEqual(state.handleKey(key(L.dragToggle, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertTrue(state.isDragging)
        XCTAssertEqual(state.handleKey(key(L.left, down: true, [])).commands, [.motionChanged])
        // 드래그 중 클릭은 하지 않는다
        XCTAssertEqual(state.handleKey(key(L.leftClick, down: true, [])).commands, [])
        _ = state.handleKey(key(L.leftClick, down: false, []))
        _ = state.handleKey(key(L.left, down: false, []))
        XCTAssertEqual(state.handleKey(key(L.dragToggle, down: true, [])).commands, [.endDrag])
        XCTAssertFalse(state.isDragging)
        _ = state.handleKey(key(L.dragToggle, down: false, []))
        // Esc로도 놓는다
        _ = state.handleKey(key(L.dragToggle, down: true, []))
        _ = state.handleKey(key(L.dragToggle, down: false, []))
        XCTAssertEqual(state.handleKey(key(K.escape, down: true, [])).commands, [.endDrag])
        XCTAssertFalse(state.isDragging)
        // ↩ 클릭도 그대로
        XCTAssertEqual(state.handleKey(key(K.returnKey, down: true, [])).commands, [.click(.left)])
    }

    func testLeftHandLayoutOnlyInPointerMode() {
        // 포인터 모드가 아니면 글자는 그대로 앱으로
        var unlocked = leftHandState(locked: false)
        XCTAssertEqual(unlocked.handleKey(key(L.right, down: true, [])), .pass)
        XCTAssertEqual(unlocked.handleKey(key(L.leftClick, down: true, [])), .pass)
        // ⌥⇥ 조합(누르고 있는 방식)에서는 기존 키: F = 드래그, 떼면 드래그 끝
        _ = unlocked.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(unlocked.handleKey(key(3, down: true, [.option])).commands, [.beginDrag])
        XCTAssertEqual(unlocked.handleKey(key(3, down: false, [.option])).commands, [.endDrag])

        // ⌘S·⌥Space는 왼손 배치가 아니다 (앱 단축키·해제 단축키)
        var state = leftHandState()
        XCTAssertNotEqual(state.handleKey(key(L.left, down: true, [.command])).commands, [.motionChanged])
        var exit = leftHandState()
        XCTAssertEqual(exit.handleKey(key(L.leftClick, down: true, [.option])).commands, [.lockChanged(false)])

        // 일반 포인터 모드(⌥⇥ 두 번)에서는 기존 역할: D = 더블클릭, W = 막힘
        var off = leftHandState(enabled: false)
        XCTAssertEqual(off.handleKey(key(L.right, down: true, [])).commands, [.doubleClick])
        XCTAssertEqual(off.handleKey(key(L.up, down: true, [])), KeyPointerDecision(consume: true))

        // 이동 중 포인터 모드가 꺼져도 뗌은 끝까지 소비
        var stopping = leftHandState()
        _ = stopping.handleKey(key(L.right, down: true, []))
        _ = stopping.setLocked(false)
        XCTAssertTrue(stopping.handleKey(key(L.right, down: false, [])).consume)
    }

    func testLeftHandModeEnteredWithShiftDoubleTap() {
        var state = KeyPointerInputState(shortcut: .defaults)
        // ⌥⇧⇥ 두 번 → 왼손 모드
        _ = state.handleKey(timed(tab, down: true, [.option, .shift], at: 0))
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 0.05))
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option, .shift], at: 0.15)).commands, [.lockChanged(true)])
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.isLeftHandMode)
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 0.2))
        _ = state.handleModifiers([])
        XCTAssertEqual(state.handleKey(timed(LeftHandLayout.right, down: true, [], at: 1)).commands, [.motionChanged])
        _ = state.handleKey(timed(LeftHandLayout.right, down: false, [], at: 1.1))
        // 다시 ⌥⇧⇥ 두 번 → 끔
        _ = state.handleKey(timed(tab, down: true, [.option, .shift], at: 2))
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 2.05))
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option, .shift], at: 2.15)).commands, [.lockChanged(false)])
        XCTAssertFalse(state.isLeftHandMode)
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 2.2))
        // ⌥⇥ 두 번 → 일반 포인터 모드 (왼손 키 아님)
        _ = state.handleKey(timed(tab, down: true, [.option], at: 3))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 3.05))
        _ = state.handleKey(timed(tab, down: true, [.option], at: 3.15))
        _ = state.handleKey(timed(tab, down: false, [.option], at: 3.2))
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isLeftHandMode)
        _ = state.handleModifiers([])
        XCTAssertEqual(state.handleKey(timed(LeftHandLayout.up, down: true, [], at: 4)), KeyPointerDecision(consume: true))
    }

    func testSwitchBetweenNormalAndLeftHandMode() {
        let q = LeftHandLayout.switchMode
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.setLocked(true)
        // Q → 왼손 모드 (포인터 모드 유지), 뗌은 소비
        XCTAssertEqual(state.handleKey(key(q, down: true, [])), KeyPointerDecision(consume: true))
        XCTAssertTrue(state.isLeftHandMode)
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.handleKey(key(q, down: false, [])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.handleKey(key(LeftHandLayout.down, down: true, [])).commands, [.motionChanged])
        // 이동 중 Q → 일반 모드, 이동은 멈춘다
        XCTAssertEqual(state.handleKey(key(q, down: true, [])).commands, [.motionChanged])
        XCTAssertFalse(state.isLeftHandMode)
        _ = state.handleKey(key(q, down: false, []))
        _ = state.handleKey(key(LeftHandLayout.down, down: false, []))

        // 일반 포인터 모드에서 ⌥⇧⇥ 두 번 → 끄지 않고 왼손 모드
        _ = state.handleKey(timed(tab, down: true, [.option, .shift], at: 10))
        _ = state.handleKey(timed(tab, down: false, [.option, .shift], at: 10.05))
        XCTAssertEqual(state.handleKey(timed(tab, down: true, [.option, .shift], at: 10.15)).commands, [])
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.isLeftHandMode)

        // Q를 포인터 키로 쓰고 있으면 바꾸지 않는다
        var custom = KeyPointerInputState(shortcut: custom { $0.rightClickKey = PointerKey(keyCode: q, keyLabel: "Q") })
        _ = custom.setLocked(true)
        XCTAssertEqual(custom.handleKey(key(q, down: true, [])).commands, [.click(.right)])
        XCTAssertFalse(custom.isLeftHandMode)
    }

    func testLeftHandSuspensionRemapsWASD() {
        var state = leftHandState()
        _ = state.handleKey(key(11, down: true, [.command]))   // ⌘B
        XCTAssertTrue(state.isSuspended)
        // ⌘를 쥔 채 S → ↓, W → ↑, Space → ↩ (⌘ 빼고), 뗌도 같이
        XCTAssertEqual(state.handleKey(key(L.down, down: true, [.command])),
                       KeyPointerDecision(consume: false, stripsCommandControl: true, remappedKeyCode: 125))
        XCTAssertEqual(state.handleKey(key(L.down, down: false, [.command])),
                       KeyPointerDecision(consume: false, stripsCommandControl: true, remappedKeyCode: 125))
        XCTAssertEqual(state.handleKey(key(L.up, down: true, [.command])).remappedKeyCode, 126)
        _ = state.handleKey(key(L.up, down: false, [.command]))
        XCTAssertEqual(state.handleKey(key(L.leftClick, down: true, [.command])).remappedKeyCode, 36)
        _ = state.handleKey(key(L.leftClick, down: false, [.command]))
        // 진짜 방향키는 바꾸지 않고 ⌘만 뺀다
        XCTAssertEqual(state.handleKey(key(K.down, down: true, [.command])),
                       KeyPointerDecision(consume: false, stripsCommandControl: true))
        _ = state.handleKey(key(K.down, down: false, [.command]))
        // ⌘를 떼면 왼손 모드로
        XCTAssertEqual(state.handleModifiers([]), [.lockChanged(true)])
        XCTAssertTrue(state.isLeftHandMode)

        // 일반 포인터 모드에서 잠깐 해제됐으면 ⌘S는 바꾸지 않는다 (다른 앱 단축키로)
        var normal = leftHandState(enabled: false)
        _ = normal.handleKey(key(11, down: true, [.command]))
        XCTAssertEqual(normal.handleKey(key(L.down, down: true, [.command])), .pass)
    }

    func testLeftHandModeSurvivesAppShortcutSuspension() {
        var state = leftHandState()
        // ⌘B → 보조키 누르는 동안 해제, ⌘를 떼면 왼손 모드로 돌아온다
        _ = state.handleKey(key(11, down: true, [.command]))
        XCTAssertTrue(state.isSuspended)
        XCTAssertFalse(state.isLeftHandMode)
        XCTAssertEqual(state.handleModifiers([]), [.lockChanged(true)])
        XCTAssertTrue(state.isLeftHandMode)
        // 메뉴 열기 등으로 꺼졌다 다시 켜면 일반 포인터 모드
        _ = state.setLocked(false)
        _ = state.setLocked(true)
        XCTAssertFalse(state.isLeftHandMode)
    }

    func testMoveToFocusSettingsRoundTrip() {
        XCTAssertTrue(KeyPointerSettings.defaults.moveToFocusOnResume)
        XCTAssertFalse(KeyPointerSettings.defaults.moveToFocusOnLock)
        XCTAssertTrue(store.loadKeyPointer().moveToFocusOnResume)
        var settings = KeyPointerSettings.defaults
        settings.moveToFocusOnResume = false
        settings.moveToFocusOnLock = true
        store.saveKeyPointer(settings)
        let loaded = store.loadKeyPointer()
        XCTAssertFalse(loaded.moveToFocusOnResume)
        XCTAssertTrue(loaded.moveToFocusOnLock)
    }

    func testExitAfterClickRoundTrip() {
        XCTAssertFalse(KeyPointerSettings.defaults.exitAfterClick)
        XCTAssertFalse(store.loadKeyPointer().exitAfterClick)
        var settings = KeyPointerSettings.defaults
        settings.exitAfterClick = true
        store.saveKeyPointer(settings)
        XCTAssertTrue(store.loadKeyPointer().exitAfterClick)
    }

    func testSlowKeyDefaultsAndCodable() throws {
        XCTAssertEqual(PointerShortcut.defaults.slowKey, .key(aKey))
        XCTAssertEqual(KeyPointerSettings.defaults.slowMultiplier, 0.3)
        // 없앰(nil)도 저장·로드 뒤 그대로
        var settings = KeyPointerSettings.defaults
        settings.shortcut.slowKey = nil
        settings.slowMultiplier = 0.2
        store.saveKeyPointer(settings)
        XCTAssertNil(store.loadKeyPointer().shortcut.slowKey)
        XCTAssertEqual(store.loadKeyPointer().slowMultiplier, 0.2, accuracy: 0.0001)
        settings.shortcut.slowKey = .modifier(.control)
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().shortcut.slowKey, .modifier(.control))
        // 이전 저장값에는 없다 → 기본 A
        let data = try JSONEncoder().encode(PointerShortcut.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "slowKey")
        let legacy = try JSONDecoder().decode(PointerShortcut.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.slowKey, .key(aKey))
        // 프리셋을 바꿔도 느리게 키는 그대로
        let ctrlSlow = custom { $0.slowKey = .modifier(.control) }
        XCTAssertEqual(PointerModifierPair.optionTab.applied(to: custom { $0.slowKey = nil }).slowKey, nil)
        XCTAssertEqual(PointerModifierPair.optionTab.applied(to: ctrlSlow).slowKey, .modifier(.control))
        // 누르고 있는 키가 없는 프리셋은 일반 키 느리게 키를 뺀다
        XCTAssertNil(PointerModifierPair.controlShift.shortcut.slowKey)
        XCTAssertNil(PointerModifierPair.controlShift.applied(to: .defaults).slowKey)
        // 범위 밖 배율
        settings.slowMultiplier = 5
        XCTAssertEqual(settings.validated().slowMultiplier, KeyPointerSettings.slowMultiplierRange.upperBound)
    }

    func testSlowKeyValidation() {
        XCTAssertEqual(custom { $0.slowKey = .modifier(.control) }.issues, [])
        XCTAssertEqual(custom { $0.slowKey = .modifier(.option) }.issues, [.invalidSlowModifier])
        XCTAssertEqual(custom { $0.slowKey = .modifier([.control, .shift]) }.issues, [.invalidSlowModifier])
        XCTAssertEqual(custom { $0.slowKey = .modifier(.shift) }.issues, [.slowEqualsOtherModeKey])
        XCTAssertEqual(custom { $0.slowKey = .modifier(.command) }.issues, [.slowEqualsOtherModeKey])
        let r = PointerKey(keyCode: 15, keyLabel: "R")
        XCTAssertEqual(custom { $0.slowKey = .key(r) }.issues, [.duplicateKey(r)])
        XCTAssertEqual(custom { $0.slowKey = nil }.issues, [])
        XCTAssertEqual(PointerShortcut.defaults.comboLabel(slow: true), "⌥⇥ + A")
    }

    func testSlowKeyHeldWhileMoving() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(key(tab, down: true, [.option]))
        _ = state.handleKey(key(K.right, down: true, [.option]))
        XCTAssertFalse(state.isSlow)
        XCTAssertEqual(state.handleKey(key(aKey.keyCode, down: true, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertTrue(state.isSlow)
        // 느리게 키를 누른 채로도 클릭한다
        XCTAssertEqual(state.handleKey(key(K.d, down: true, [.option])).commands, [.doubleClick])
        _ = state.handleKey(key(K.d, down: false, [.option]))
        XCTAssertEqual(state.handleKey(key(aKey.keyCode, down: false, [.option])), KeyPointerDecision(consume: true, commands: [.motionChanged]))
        XCTAssertFalse(state.isSlow)

        // 포인터 모드: 보조키 없이 A + 방향키
        var locked = KeyPointerInputState(shortcut: .defaults)
        _ = locked.setLocked(true)
        XCTAssertTrue(locked.handleKey(key(aKey.keyCode, down: true, [])).consume)
        _ = locked.handleKey(key(K.up, down: true, []))
        XCTAssertTrue(locked.isSlow)

        // 보조키 느리게 키 (⌃)
        var modifierSlow = KeyPointerInputState(shortcut: custom { $0.slowKey = .modifier(.control) })
        _ = modifierSlow.handleKey(key(tab, down: true, [.option]))
        _ = modifierSlow.handleKey(key(K.left, down: true, [.option]))
        XCTAssertEqual(modifierSlow.handleModifiers([.option, .control]), [.motionChanged])
        XCTAssertTrue(modifierSlow.isSlow)

        // 느리게 키가 없으면 A는 평소대로
        var none = KeyPointerInputState(shortcut: custom { $0.slowKey = nil })
        _ = none.handleKey(key(tab, down: true, [.option]))
        XCTAssertEqual(none.handleKey(key(aKey.keyCode, down: true, [.option])), .pass)
        XCTAssertFalse(none.isSlow)
    }

    func testSpeedFactor() {
        var settings = KeyPointerSettings.defaults
        func factor(fast: Bool, slow: Bool, scrolling: Bool = false) -> (Double, Bool) {
            let result = settings.speedFactor(fastKeyHeld: fast, slowKeyHeld: slow, scrolling: scrolling)
            return (result.multiplier, result.accelerates)
        }
        XCTAssertTrue(factor(fast: false, slow: false) == (1, true))
        XCTAssertTrue(factor(fast: true, slow: false) == (settings.fastMultiplier, false))
        XCTAssertTrue(factor(fast: true, slow: false, scrolling: true) == (settings.scrollFastMultiplier, false))
        // 느리게가 빠르게보다 우선, 가속 없음
        XCTAssertTrue(factor(fast: true, slow: true) == (0.3, false))
        XCTAssertTrue(factor(fast: false, slow: true, scrolling: true) == (0.3, false))
        // 기본을 빠르게: 빠르게 키는 기본 속도(가속), 느리게 키는 여전히 느리게
        settings.invertFastKey = true
        XCTAssertTrue(factor(fast: false, slow: false) == (settings.fastMultiplier, false))
        XCTAssertTrue(factor(fast: true, slow: false) == (1, true))
        XCTAssertTrue(factor(fast: false, slow: true) == (0.3, false))
    }

    func testInvertFastKey() {
        var settings = KeyPointerSettings.defaults
        XCTAssertFalse(settings.invertFastKey)
        XCTAssertFalse(settings.usesFastSpeed(fastKeyHeld: false))
        XCTAssertTrue(settings.usesFastSpeed(fastKeyHeld: true))
        // 반전: 기본이 빠르고, 빠르게 키를 누르는 동안 느리게
        settings.invertFastKey = true
        XCTAssertTrue(settings.usesFastSpeed(fastKeyHeld: false))
        XCTAssertFalse(settings.usesFastSpeed(fastKeyHeld: true))
        store.saveKeyPointer(settings)
        XCTAssertTrue(store.loadKeyPointer().invertFastKey)
    }

    func testTextInputExitExcludedAppsRoundTrip() {
        XCTAssertEqual(KeyPointerSettings.defaults.textInputExitExcludedApps, [])
        var settings = KeyPointerSettings.defaults
        settings.textInputExitExcludedApps = ["com.googlecode.iterm2", "com.microsoft.VSCode"]
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().textInputExitExcludedApps, ["com.googlecode.iterm2", "com.microsoft.VSCode"])
    }

    func testHeldKeyUsedByOtherFeatureIsNotReplayed() {
        var state = KeyPointerInputState(shortcut: .defaults)
        _ = state.handleKey(key(tab, down: true, [.option]))
        // 창 목록 전환기가 ⌥`를 가져감
        state.markHeldKeyUsed()
        XCTAssertEqual(state.handleKey(key(tab, down: false, [.option])), KeyPointerDecision(consume: true))
        XCTAssertEqual(state.flushPendingTap(), [])
    }

    private func signature(
        _ bundleID: String? = "com.google.Chrome", role: String = "AXTextArea",
        scheme: String? = "devtools", host: String? = "devtools", classes: [String] = ["cm-content", "cm-lineWrapping"]
    ) -> FocusSignature {
        FocusSignature(bundleID: bundleID, role: role, urlScheme: scheme, urlHost: host, domClasses: classes)
    }

    func testExclusionRuleMatching() {
        let devTools = TextInputExclusionRule.devToolsCodeEditor
        // 앱을 비운 규칙은 어느 브라우저에서나, 호스트를 비운 규칙은 어느 호스트나, 클래스는 부분집합이면 맞는다
        XCTAssertTrue(devTools.matches(signature()))
        XCTAssertTrue(devTools.matches(signature("com.microsoft.edgemac", host: "other")))
        XCTAssertTrue(devTools.matches(signature(scheme: "DevTools")))
        XCTAssertFalse(devTools.matches(signature(role: "AXTextField")))
        XCTAssertFalse(devTools.matches(signature(scheme: "https")))
        XCTAssertFalse(devTools.matches(signature(scheme: nil, host: nil)))
        XCTAssertFalse(devTools.matches(signature(classes: ["cm-lineWrapping"])))

        // 앱을 정한 규칙은 그 앱에서만, 호스트를 정한 규칙은 그 호스트에서만
        let rule = TextInputExclusionRule(
            bundleID: "com.google.Chrome", role: "AXTextArea", urlScheme: "https", urlHost: "Example.com", domClasses: []
        )
        XCTAssertTrue(rule.matches(signature(scheme: "https", host: "example.com", classes: [])))
        XCTAssertFalse(rule.matches(signature("com.apple.Safari", scheme: "https", host: "example.com")))
        XCTAssertFalse(rule.matches(signature(scheme: "https", host: "other.com")))
        XCTAssertFalse(rule.matches(signature(scheme: "https", host: nil)))
    }

    func testLearnedRuleScopes() {
        let web = signature(scheme: "https", host: "example.com", classes: ["editor"])
        let thisApp = TextInputExclusionRule.learned(from: web, allBrowsers: false)
        XCTAssertEqual(thisApp.bundleID, "com.google.Chrome")
        XCTAssertEqual(thisApp.urlHost, "example.com")
        XCTAssertEqual(thisApp.domClasses, ["editor"])
        XCTAssertTrue(thisApp.matches(web))
        XCTAssertFalse(thisApp.isBroad)

        let allBrowsers = TextInputExclusionRule.learned(from: web, allBrowsers: true)
        XCTAssertNil(allBrowsers.bundleID)
        XCTAssertTrue(allBrowsers.matches(signature("com.apple.Safari", scheme: "https", host: "example.com", classes: ["editor", "x"])))

        // 웹이 아니면 "모든 브라우저"를 골라도 앱은 남긴다 — 앱 + 역할만이면 넓은 규칙
        let native = signature("com.apple.TextEdit", scheme: nil, host: nil, classes: [])
        let nativeRule = TextInputExclusionRule.learned(from: native, allBrowsers: true)
        XCTAssertEqual(nativeRule.bundleID, "com.apple.TextEdit")
        XCTAssertTrue(nativeRule.isBroad)
        XCTAssertFalse(native.isWebContent)
    }

    func testExclusionRulesRoundTripAndDefault() {
        XCTAssertEqual(KeyPointerSettings.defaults.textInputExclusionRules, [.devToolsCodeEditor])
        XCTAssertEqual(store.loadKeyPointer().textInputExclusionRules, [.devToolsCodeEditor])

        var settings = KeyPointerSettings.defaults
        let learned = TextInputExclusionRule.learned(from: signature(scheme: "https", host: "example.com"), allBrowsers: true)
        settings.textInputExclusionRules = [learned]
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().textInputExclusionRules, [learned])

        // 모두 뺀 상태도 그대로 저장된다 (기본 규칙이 되살아나지 않는다)
        settings.textInputExclusionRules = []
        store.saveKeyPointer(settings)
        XCTAssertEqual(store.loadKeyPointer().textInputExclusionRules, [])

        // 깨진 값이면 기본
        defaults.set(Data("not json".utf8), forKey: "pointer.textInputExclusionRules")
        XCTAssertEqual(store.loadKeyPointer().textInputExclusionRules, [.devToolsCodeEditor])
    }
}
