import CoreGraphics
import XCTest
@testable import WheelSpaceCore

/// move-monitor 2절 기준 배치 (좌표 예시 — 실제 모니터 좌표가 아님)
///          모니터 A (0..1920)             모니터 B (2000..3920, 사이 80pt 빈 공간)
///   ┌──── A1 ────┬──── A2 ────┐    ┌──────── B1 ────────┐
///                   모니터 C (아래, 500..2420)
///            ┌──── C1 ────┬──── C2 ────┐
private enum Layout {
    static let a1 = FocusCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080), zIndex: 0)
    static let a2 = FocusCandidate(id: 2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080), zIndex: 1)
    static let b1 = FocusCandidate(id: 3, frame: CGRect(x: 2000, y: 0, width: 1920, height: 1080), zIndex: 2)
    static let c1 = FocusCandidate(id: 4, frame: CGRect(x: 500, y: 1200, width: 960, height: 1080), zIndex: 3)
    static let c2 = FocusCandidate(id: 5, frame: CGRect(x: 1460, y: 1200, width: 960, height: 1080), zIndex: 4)
    static let all = [a1, a2, b1, c1, c2]

    /// 현재 창 자신을 뺀 후보로 선택
    static func select(from current: FocusCandidate, _ direction: FocusDirection) -> Int? {
        DirectionalSelector.select(
            from: current.frame,
            candidates: all.filter { $0.id != current.id },
            direction: direction
        )?.id
    }
}

final class DirectionalSelectorTests: XCTestCase {
    func testLeftFromB1ThenA2ReachesA1() {
        XCTAssertEqual(Layout.select(from: Layout.b1, .left), Layout.a2.id)
        XCTAssertEqual(Layout.select(from: Layout.a2, .left), Layout.a1.id)
    }

    func testRightFromA1ThenA2ReachesB1() {
        XCTAssertEqual(Layout.select(from: Layout.a1, .right), Layout.a2.id)
        XCTAssertEqual(Layout.select(from: Layout.a2, .right), Layout.b1.id)
    }

    func testRightFromC1ReachesC2() {
        XCTAssertEqual(Layout.select(from: Layout.c1, .right), Layout.c2.id)
    }

    func testDownFromTopRowReachesBottomRowByCoordinates() {
        // A1(0..960)과 가로로 겹치는 건 C1(500..1460)뿐
        XCTAssertEqual(Layout.select(from: Layout.a1, .down), Layout.c1.id)
        // A2(960..1920)는 C1·C2 모두 겹침 → 간격 같음 → 중심 가로 차가 작은 C2(1940) vs C1(980): A2 중심 1440 → C1 차 460, C2 차 500
        XCTAssertEqual(Layout.select(from: Layout.a2, .down), Layout.c1.id)
        // B1(2000..3920)과 겹치는 건 C2(..2420)
        XCTAssertEqual(Layout.select(from: Layout.b1, .down), Layout.c2.id)
    }

    func testUpFromBottomRow() {
        XCTAssertEqual(Layout.select(from: Layout.c2, .up), Layout.a2.id) // C2(1460..2420) ∩ A2·B1, 중심 1940: A2 1440(500) / B1 2960(1020)
        XCTAssertEqual(Layout.select(from: Layout.c1, .up), Layout.a2.id) // C1 중심 980: A1 480(500) / A2 1440(460)
    }

    func testNoCandidateReturnsNil() {
        XCTAssertNil(Layout.select(from: Layout.a1, .left))
        XCTAssertNil(Layout.select(from: Layout.b1, .right))
        XCTAssertNil(Layout.select(from: Layout.a1, .up))
        XCTAssertNil(Layout.select(from: Layout.c1, .down))
    }

    func testSameAppWindowsAreSeparateCandidates() {
        // 같은 앱의 두 창도 서로 다른 id로 각각 후보가 된다 (앱 단위가 아님)
        let left = FocusCandidate(id: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), zIndex: 0)
        let right = FocusCandidate(id: 11, frame: CGRect(x: 800, y: 0, width: 800, height: 600), zIndex: 1)
        XCTAssertEqual(DirectionalSelector.select(from: left.frame, candidates: [right], direction: .right)?.id, 11)
        XCTAssertEqual(DirectionalSelector.select(from: right.frame, candidates: [left], direction: .left)?.id, 10)
    }

    func testNegativeCoordinatesAndGapBetweenDisplays() {
        let leftMonitor = FocusCandidate(id: 1, frame: CGRect(x: -2560, y: -200, width: 1280, height: 1440), zIndex: 0)
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(DirectionalSelector.select(from: main, candidates: [leftMonitor], direction: .left)?.id, 1)
        let above = FocusCandidate(id: 2, frame: CGRect(x: 100, y: -1080, width: 1920, height: 1000), zIndex: 1)
        XCTAssertEqual(DirectionalSelector.select(from: main, candidates: [leftMonitor, above], direction: .up)?.id, 2)
    }

    func testAlignedFarCandidateBeatsCloseDiagonal() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 500)
        let farAligned = FocusCandidate(id: 1, frame: CGRect(x: 3000, y: 100, width: 500, height: 300), zIndex: 0)
        let nearDiagonal = FocusCandidate(id: 2, frame: CGRect(x: 520, y: 600, width: 500, height: 500), zIndex: 1)
        XCTAssertEqual(DirectionalSelector.select(from: current, candidates: [nearDiagonal, farAligned], direction: .right)?.id, 1)
    }

    func testDiagonalFallbackUsesRectDistance() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 500)
        let near = FocusCandidate(id: 1, frame: CGRect(x: 600, y: 600, width: 300, height: 300), zIndex: 1)
        let far = FocusCandidate(id: 2, frame: CGRect(x: 600, y: 2000, width: 300, height: 300), zIndex: 0)
        XCTAssertEqual(DirectionalSelector.select(from: current, candidates: [far, near], direction: .right)?.id, 1)
    }

    func testTiesBreakDeterministically() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frame = CGRect(x: 600, y: 0, width: 500, height: 500)
        let back = FocusCandidate(id: 1, frame: frame, zIndex: 5)
        let front = FocusCandidate(id: 2, frame: frame, zIndex: 2)
        XCTAssertEqual(DirectionalSelector.select(from: current, candidates: [back, front], direction: .right)?.id, 2)
        let sameZ = FocusCandidate(id: 0, frame: frame, zIndex: 2)
        XCTAssertEqual(DirectionalSelector.select(from: current, candidates: [front, sameZ], direction: .right)?.id, 0)
    }

    func testSameCenterIsNotSelected() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 500)
        let overlapping = FocusCandidate(id: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 300), zIndex: 0)
        for direction in FocusDirection.allCases {
            XCTAssertNil(DirectionalSelector.select(from: current, candidates: [overlapping], direction: direction))
        }
    }
}

final class VisibilityCalculatorTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func area(_ regions: [CGRect]) -> CGFloat {
        regions.reduce(0) { $0 + $1.width * $1.height }
    }

    func testUncoveredWindowIsExposed() {
        let regions = VisibilityCalculator.visibleRegions(of: window, displays: [display], occluders: [])!
        XCTAssertEqual(regions, [window])
        XCTAssertTrue(VisibilityCalculator.isExposed(regions))
    }

    func testSingleWindowFullyCovers() {
        let regions = VisibilityCalculator.visibleRegions(of: window, displays: [display], occluders: [display])!
        XCTAssertTrue(regions.isEmpty)
        XCTAssertFalse(VisibilityCalculator.isExposed(regions))
    }

    func testMultipleWindowsTogetherCover() {
        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 1080)
        let rightHalf = CGRect(x: 500, y: 0, width: 1420, height: 1080)
        let regions = VisibilityCalculator.visibleRegions(of: window, displays: [display], occluders: [leftHalf, rightHalf])!
        XCTAssertTrue(regions.isEmpty)
    }

    func testPartiallyCoveredWindowStaysCandidate() {
        let cover = CGRect(x: 0, y: 0, width: 500, height: 1080) // 왼쪽 절반 가림
        let regions = VisibilityCalculator.visibleRegions(of: window, displays: [display], occluders: [cover])!
        XCTAssertEqual(area(regions), 400 * 600)
        XCTAssertTrue(VisibilityCalculator.isExposed(regions))
    }

    func testExposureThresholdBeforeAtAfter() {
        XCTAssertFalse(VisibilityCalculator.isExposed([CGRect(x: 0, y: 0, width: 64, height: 15.9)]))  // 면적 충분, 한 변 부족
        XCTAssertFalse(VisibilityCalculator.isExposed([CGRect(x: 0, y: 0, width: 31.9, height: 32)]))  // 면적 1,020.8
        XCTAssertTrue(VisibilityCalculator.isExposed([CGRect(x: 0, y: 0, width: 32, height: 32)]))     // 정확히 1,024
        XCTAssertTrue(VisibilityCalculator.isExposed([CGRect(x: 0, y: 0, width: 64, height: 16)]))
        XCTAssertTrue(VisibilityCalculator.isExposed([
            CGRect(x: 0, y: 0, width: 16, height: 16), CGRect(x: 100, y: 0, width: 300, height: 3),
        ]))
    }

    func testOutsideDisplaysIsClipped() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: 1100, y: 0, width: 1000, height: 1000)]
        let spanning = CGRect(x: 900, y: 0, width: 300, height: 100) // 900..1200, 사이 1000..1100 빈 공간
        let regions = VisibilityCalculator.visibleRegions(of: spanning, displays: displays, occluders: [])!
        XCTAssertEqual(area(regions), 200 * 100)
        let offscreen = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertEqual(VisibilityCalculator.visibleRegions(of: offscreen, displays: displays, occluders: []), [])
    }

    func testSubtractProducesNonOverlappingPieces() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pieces = VisibilityCalculator.subtract(rect, minus: CGRect(x: 25, y: 25, width: 50, height: 50))
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(area(pieces), 10_000 - 2_500)
        for (i, a) in pieces.enumerated() {
            for b in pieces[(i + 1)...] {
                let overlap = a.intersection(b)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0)
            }
        }
        XCTAssertEqual(VisibilityCalculator.subtract(rect, minus: CGRect(x: 100, y: 0, width: 10, height: 10)), [rect])
    }

    func testBudgetExceededReturnsNil() {
        // 촘촘한 작은 구멍들로 조각 수를 폭증시킨다
        let holes = (0..<40).flatMap { x in (0..<40).map { y in CGRect(x: x * 20 + 5, y: y * 15 + 5, width: 5, height: 5) } }
        XCTAssertNil(VisibilityCalculator.visibleRegions(of: window.offsetBy(dx: -100, dy: -100), displays: [display], occluders: holes))
    }
}

final class WindowMatcherTests: XCTestCase {
    private let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

    func testUniqueFrameMatches() {
        let cg = [CGWindowRecord(windowID: 100, pid: 1, frame: frame)]
        let ax = [AXWindowRecord(index: 0, pid: 1, frame: frame.offsetBy(dx: 1, dy: -1))]
        XCTAssertEqual(WindowMatcher.match(cg: cg, ax: ax), [100: 0])
    }

    func testDifferentPIDDoesNotMatch() {
        let cg = [CGWindowRecord(windowID: 100, pid: 1, frame: frame)]
        let ax = [AXWindowRecord(index: 0, pid: 2, frame: frame)]
        XCTAssertEqual(WindowMatcher.match(cg: cg, ax: ax), [:])
    }

    func testSameFrameWindowsArePairedByOrder() {
        let other = CGRect(x: 900, y: 20, width: 400, height: 300)
        let cg = [
            CGWindowRecord(windowID: 100, pid: 1, frame: frame),
            CGWindowRecord(windowID: 101, pid: 1, frame: frame),
            CGWindowRecord(windowID: 102, pid: 1, frame: other),
        ]
        let ax = [
            AXWindowRecord(index: 0, pid: 1, frame: frame),
            AXWindowRecord(index: 1, pid: 1, frame: frame),
            AXWindowRecord(index: 2, pid: 1, frame: other),
        ]
        // 최대화한 같은 앱 창 둘: 앞→뒤 순서대로 짝짓는다
        XCTAssertEqual(WindowMatcher.match(cg: cg, ax: ax), [100: 0, 101: 1, 102: 2])

        // 양쪽 개수가 다르면 모호하므로 그 묶음은 연결하지 않는다
        let oneCG = [CGWindowRecord(windowID: 100, pid: 1, frame: frame)]
        XCTAssertEqual(WindowMatcher.match(cg: oneCG, ax: Array(ax.prefix(2))), [:])
    }

    func testToleranceBoundary() {
        let cg = [CGWindowRecord(windowID: 100, pid: 1, frame: frame)]
        XCTAssertEqual(WindowMatcher.match(cg: cg, ax: [AXWindowRecord(index: 0, pid: 1, frame: frame.offsetBy(dx: 2, dy: 0))]), [100: 0])
        XCTAssertEqual(WindowMatcher.match(cg: cg, ax: [AXWindowRecord(index: 0, pid: 1, frame: frame.offsetBy(dx: 2.5, dy: 0))]), [:])
    }
}

final class FocusCommandQueueTests: XCTestCase {
    func testKeepsOrderUpToCapacity() {
        var queue = FocusCommandQueue()
        XCTAssertTrue(queue.enqueue(.left, at: 10))
        XCTAssertTrue(queue.enqueue(.left, at: 10.01))
        XCTAssertTrue(queue.enqueue(.down, at: 10.02))
        XCTAssertTrue(queue.enqueue(.right, at: 10.03))
        XCTAssertEqual(queue.next(now: 10.1), .left)
        XCTAssertEqual(queue.next(now: 10.1), .left)
        XCTAssertEqual(queue.next(now: 10.1), .down)
        XCTAssertEqual(queue.next(now: 10.1), .right)
        XCTAssertNil(queue.next(now: 10.1))
    }

    func testOverflowIsDropped() {
        var queue = FocusCommandQueue()
        for i in 0..<4 { XCTAssertTrue(queue.enqueue(.left, at: 10 + Double(i) * 0.01)) }
        XCTAssertFalse(queue.enqueue(.right, at: 10.05))
        var drained: [FocusDirection] = []
        while let next = queue.next(now: 10.1) { drained.append(next) }
        XCTAssertEqual(drained, [.left, .left, .left, .left])
    }

    func testExpiredCommandsAreSkipped() {
        var queue = FocusCommandQueue()
        queue.enqueue(.left, at: 10)
        queue.enqueue(.right, at: 10.3)
        XCTAssertEqual(queue.next(now: 10.6), .right) // .left는 600ms 지나 만료, .right는 300ms
        queue.enqueue(.up, at: 11)
        XCTAssertEqual(queue.next(now: 11.5), .up)   // 정확히 500ms는 유효
        XCTAssertTrue(queue.isEmpty)
    }

    func testRemoveAll() {
        var queue = FocusCommandQueue()
        queue.enqueue(.left, at: 10)
        queue.removeAll()
        XCTAssertNil(queue.next(now: 10))
    }
}

final class FocusSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "WheelSpaceFocusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAndRoundTrip() {
        XCTAssertEqual(store.loadFocus(), .defaults)
        var settings = FocusSettings.defaults
        settings.isEnabled = false
        settings.upShortcut = KeyCombo(keyCode: 0x7E, modifiers: [.command, .option], keyLabel: "↑")
        store.saveFocus(settings)
        XCTAssertEqual(store.loadFocus(), settings)
    }

    func testDuplicateShortcutClearsLaterDirection() {
        var settings = FocusSettings.defaults
        settings.downShortcut = settings.leftShortcut
        settings.upShortcut = KeyCombo(keyCode: 0x7E, modifiers: .shift, keyLabel: "↑") // 보조키 부족
        let validated = settings.validated()
        XCTAssertEqual(validated.leftShortcut, FocusSettings.defaults.leftShortcut)
        XCTAssertNil(validated.downShortcut)
        XCTAssertNil(validated.upShortcut)
    }

    func testClearedShortcutStaysCleared() {
        var settings = FocusSettings.defaults
        settings.rightShortcut = nil
        store.saveFocus(settings)
        XCTAssertNil(store.loadFocus().rightShortcut)
        XCTAssertEqual(store.loadFocus().leftShortcut, FocusSettings.defaults.leftShortcut)
    }

    func testPointerFollowDefaultsOffAndRoundTrips() {
        XCTAssertEqual(store.loadFocus().pointerFollow, .off)
        var settings = FocusSettings.defaults
        settings.pointerFollow = .allFocusChanges
        store.saveFocus(settings)
        XCTAssertEqual(store.loadFocus().pointerFollow, .allFocusChanges)
    }

    func testLegacyMovePointerTrueMigratesToFocusMoves() {
        defaults.set(true, forKey: SettingsStore.Key.focusMovePointer)
        let loaded = store.loadFocus()
        XCTAssertEqual(loaded.pointerFollow, .focusMoves)
        store.saveFocus(loaded)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.focusMovePointer))
        XCTAssertEqual(store.loadFocus().pointerFollow, .focusMoves)

        defaults.set(false, forKey: SettingsStore.Key.focusMovePointer)
        defaults.removeObject(forKey: SettingsStore.Key.focusPointerFollow)
        XCTAssertEqual(store.loadFocus().pointerFollow, .off)
    }

    func testInvalidPointerFollowFallsBackToOff() {
        defaults.set("sometimes", forKey: SettingsStore.Key.focusPointerFollow)
        XCTAssertEqual(store.loadFocus().pointerFollow, .off)
    }

    func testResetClearsFocusKeys() {
        var settings = FocusSettings.defaults
        settings.isEnabled = false
        store.saveFocus(settings)
        store.reset()
        XCTAssertEqual(store.loadFocus(), .defaults)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.focusEnabled))
    }
}

final class WindowSwitcherStateTests: XCTestCase {
    private let backtick: UInt16 = 50
    private let trigger = KeyCombo(keyCode: 50, modifiers: .option, keyLabel: "`")
    private typealias K = WindowSwitcherState.KeyCode

    private func down(_ code: UInt16, _ modifiers: ModifierState, repeat isRepeat: Bool = false) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: true, isRepeat: isRepeat, modifiers: modifiers)
    }

    private func up(_ code: UInt16, _ modifiers: ModifierState) -> KeyEventInput {
        KeyEventInput(keyCode: code, isDown: false, modifiers: modifiers)
    }

    /// ⌥` 로 열고 창 count개 목록을 받은 상태
    private func shown(count: Int) -> WindowSwitcherState {
        var state = WindowSwitcherState(trigger: trigger)
        _ = state.handleKey(down(backtick, .option))
        _ = state.listLoaded(count: count)
        return state
    }

    func testTriggerOpensAndLoadsList() {
        var state = WindowSwitcherState(trigger: trigger)
        XCTAssertEqual(state.handleKey(down(backtick, .option)), WindowSwitcherDecision(consume: true, commands: [.loadList]))
        XCTAssertEqual(state.listLoaded(count: 3), [.show(selection: 1)])
        XCTAssertEqual(state.phase, .showing(count: 3, selection: 1))
        // 보조키 없는 `, 다른 보조키는 열지 않는다
        var other = WindowSwitcherState(trigger: trigger)
        XCTAssertEqual(other.handleKey(down(backtick, [])), .pass)
        XCTAssertEqual(other.handleKey(down(backtick, .command)), .pass)
        XCTAssertEqual(other.phase, .idle)
    }

    func testStepsBeforeListAreApplied() {
        var state = WindowSwitcherState(trigger: trigger)
        _ = state.handleKey(down(backtick, .option))
        // 목록 오기 전 두 번 더 (자동 반복 포함)
        XCTAssertEqual(state.handleKey(down(backtick, .option, repeat: true)), WindowSwitcherDecision(consume: true))
        _ = state.handleKey(down(backtick, .option))
        XCTAssertEqual(state.listLoaded(count: 4), [.show(selection: 3)])
        // 목록이 칸 수보다 적으면 순환
        var wrapped = WindowSwitcherState(trigger: trigger)
        for _ in 0..<3 { _ = wrapped.handleKey(down(backtick, .option)) }
        XCTAssertEqual(wrapped.listLoaded(count: 2), [.show(selection: 1)])
    }

    func testShiftAndArrowsMoveBackward() {
        var state = shown(count: 3)
        XCTAssertEqual(state.handleKey(down(backtick, [.option, .shift])).commands, [.show(selection: 0)])
        XCTAssertEqual(state.handleKey(down(K.left, .option)).commands, [.show(selection: 2)])   // 처음에서 끝으로
        XCTAssertEqual(state.handleKey(down(K.up, .option)).commands, [.show(selection: 1)])
        XCTAssertEqual(state.handleKey(down(K.right, .option)).commands, [.show(selection: 2)])
        XCTAssertEqual(state.handleKey(down(K.down, .option)).commands, [.show(selection: 0)])   // 끝에서 처음으로
        // ⇧⌥`로 처음 열면 맨 끝 창
        var backward = WindowSwitcherState(trigger: trigger)
        _ = backward.handleKey(down(backtick, [.option, .shift]))
        XCTAssertEqual(backward.listLoaded(count: 4), [.show(selection: 3)])
    }

    func testReleasingModifierConfirms() {
        var state = shown(count: 3)
        _ = state.handleKey(down(backtick, .option))
        XCTAssertEqual(state.handleModifiers([.option]), [])
        XCTAssertEqual(state.handleModifiers([]), [.confirm(index: 2)])
        XCTAssertEqual(state.phase, .idle)
        // 뗌 짝은 소비
        XCTAssertEqual(state.handleKey(up(backtick, [])), WindowSwitcherDecision(consume: true))
        // 목록 오기 전에 떼면 목록이 오는 대로 패널 없이 확정 (⌘Tab 빠른 전환)
        var quick = WindowSwitcherState(trigger: trigger)
        _ = quick.handleKey(down(backtick, .option))
        XCTAssertEqual(quick.handleModifiers([]), [])
        XCTAssertEqual(quick.listLoaded(count: 3), [.confirm(index: 1)])
        // ↩로도 확정
        var enter = shown(count: 3)
        XCTAssertEqual(enter.handleKey(down(K.returnKey, .option)), WindowSwitcherDecision(consume: true, commands: [.confirm(index: 1)]))
    }

    func testEscapeCancelsAndOtherKeyPasses() {
        var state = shown(count: 3)
        XCTAssertEqual(state.handleKey(down(K.escape, .option)), WindowSwitcherDecision(consume: true, commands: [.cancel]))
        XCTAssertEqual(state.handleKey(up(K.escape, .option)), WindowSwitcherDecision(consume: true))
        // 취소 뒤 보조키를 떼도 확정하지 않는다
        XCTAssertEqual(state.handleModifiers([]), [])
        // 다른 키: 취소하고 그 키는 앱으로
        var other = shown(count: 3)
        XCTAssertEqual(other.handleKey(down(40, .option)), WindowSwitcherDecision(consume: false, commands: [.cancel]))
        XCTAssertEqual(other.handleKey(up(40, .option)), .pass)
        // 취소 뒤 늦게 온 목록은 무시
        var late = WindowSwitcherState(trigger: trigger)
        _ = late.handleKey(down(backtick, .option))
        _ = late.cancel()
        XCTAssertEqual(late.listLoaded(count: 3), [])
    }

    func testTooFewWindowsCancels() {
        var state = WindowSwitcherState(trigger: trigger)
        _ = state.handleKey(down(backtick, .option))
        XCTAssertEqual(state.listLoaded(count: 1), [.cancel])
        XCTAssertEqual(state.phase, .idle)
        _ = state.handleKey(down(backtick, .option))
        XCTAssertEqual(state.listLoaded(count: 0), [.cancel])
    }

    func testSwitcherShortcutSettings() {
        XCTAssertEqual(FocusSettings.defaults.switcherShortcut?.displayString, "⌥`")
        // 보조키가 없거나(⇧만) 방향 단축키와 같으면 해제
        var settings = FocusSettings.defaults
        settings.switcherShortcut = KeyCombo(keyCode: 50, modifiers: .shift, keyLabel: "`")
        XCTAssertNil(settings.validated().switcherShortcut)
        settings.switcherShortcut = KeyCombo(keyCode: 0x7B, modifiers: [.control, .option], keyLabel: "←")
        XCTAssertNil(settings.validated().switcherShortcut)
        // 저장·로드
        let suite = "WheelSpaceSwitcherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadFocus().switcherShortcut, FocusSettings.defaults.switcherShortcut)
        settings.switcherShortcut = KeyCombo(keyCode: 48, modifiers: [.control, .command], keyLabel: "⇥")
        store.saveFocus(settings)
        XCTAssertEqual(store.loadFocus().switcherShortcut?.displayString, "⌃⌘⇥")
        settings.switcherShortcut = nil
        store.saveFocus(settings)
        XCTAssertNil(store.loadFocus().switcherShortcut)
        // ⌥⇥를 누른 채일 때만 (기본 꺼짐)
        XCTAssertFalse(store.loadFocus().switcherRequiresHeldKey)
        settings.switcherRequiresHeldKey = true
        store.saveFocus(settings)
        XCTAssertTrue(store.loadFocus().switcherRequiresHeldKey)
    }
}

final class StackCycleTests: XCTestCase {
    func testOverlappingFirstThenRestByZOrder() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 500)
        let candidates = [
            StackCandidate(id: 1, frame: CGRect(x: 600, y: 0, width: 300, height: 300), zIndex: 1), // 겹치지 않음, 앞
            StackCandidate(id: 2, frame: CGRect(x: 100, y: 100, width: 300, height: 300), zIndex: 4), // 겹침, 뒤
            StackCandidate(id: 3, frame: CGRect(x: 0, y: 0, width: 500, height: 500), zIndex: 2),   // 완전히 겹침(가려짐), 앞
            StackCandidate(id: 4, frame: CGRect(x: 500, y: 0, width: 100, height: 100), zIndex: 0),  // 변만 닿음 = 겹침 아님
        ]
        XCTAssertEqual(StackOrder.order(current: current, candidates: candidates), [3, 2, 4, 1])
    }

    func testSessionCyclesAndReturns() {
        var session = StackCycleSession(count: 3, startedAt: 10)!
        XCTAssertEqual(session.step(.next, now: 10.1), 1)
        XCTAssertEqual(session.step(.next, now: 10.2), 2)
        XCTAssertEqual(session.step(.next, now: 10.3), 0)   // 끝에서 처음으로
        XCTAssertEqual(session.step(.previous, now: 10.4), 2)
        XCTAssertEqual(session.step(.previous, now: 10.5), 1)
    }

    func testSessionTimeoutAndTooFewWindows() {
        var session = StackCycleSession(count: 2, startedAt: 10)!
        XCTAssertTrue(session.isActive(now: 11.4))
        _ = session.step(.next, now: 11.4)
        XCTAssertTrue(session.isActive(now: 12.8))           // 마지막 입력 기준
        XCTAssertFalse(session.isActive(now: 13.0))
        XCTAssertNil(StackCycleSession(count: 1, startedAt: 0))
    }

    func testStackShortcutSettings() {
        XCTAssertEqual(FocusSettings.defaults.stackNextShortcut?.displayString, "⌃⌥]")
        XCTAssertEqual(FocusSettings.defaults.stackPreviousShortcut?.displayString, "⌃⌥[")
        // 방향 단축키와 같으면 해제
        var settings = FocusSettings.defaults
        settings.stackNextShortcut = settings.leftShortcut
        XCTAssertNil(settings.validated().stackNextShortcut)
        let suite = "WheelSpaceStackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        settings = FocusSettings.defaults
        settings.stackPreviousShortcut = nil
        store.saveFocus(settings)
        XCTAssertNil(store.loadFocus().stackPreviousShortcut)
        XCTAssertEqual(store.loadFocus().stackNextShortcut?.displayString, "⌃⌥]")
    }
}
