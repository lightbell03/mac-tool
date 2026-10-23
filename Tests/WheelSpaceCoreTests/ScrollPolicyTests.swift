import XCTest
@testable import WheelSpaceCore

final class ScrollPolicyTests: XCTestCase {
    private func makePolicy(
        modifier: ModifierKey = .option,
        reverse: Bool = false,
        sensitivity: Sensitivity = .normal,
        interval: TimeInterval = 0.4
    ) -> ScrollPolicy {
        ScrollPolicy(configuration: PolicyConfiguration(
            modifier: modifier,
            reverseDirection: reverse,
            sensitivity: sensitivity,
            minimumInterval: interval
        ))
    }

    private func wheel(
        _ deltaY: Double,
        at time: TimeInterval,
        modifiers: ModifierState = .option,
        deltaX: Double = 0,
        continuous: Bool = false,
        momentum: Bool = false
    ) -> ScrollInput {
        ScrollInput(
            deltaY: deltaY,
            deltaX: deltaX,
            isContinuous: continuous,
            isMomentum: momentum,
            modifiers: modifiers,
            timestamp: time
        )
    }

    func testNoModifierPasses() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(1, at: 10, modifiers: []), engineReady: true), .pass)
    }

    func testOtherModifierPasses() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(1, at: 10, modifiers: .command), engineReady: true), .pass)
    }

    func testExactModifierWheelUpSwitchesLeft() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consumeAndSwitch(.left))
    }

    func testExactModifierWheelDownSwitchesRight() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(-3, at: 10), engineReady: true), .consumeAndSwitch(.right))
    }

    func testReverseDirectionFlips() {
        var policy = makePolicy(reverse: true)
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consumeAndSwitch(.right))
    }

    func testExtraModifierPasses() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(1, at: 10, modifiers: [.option, .shift]), engineReady: true), .pass)
    }

    func testZeroDeltaAndHorizontalOnlyPass() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(0, at: 10), engineReady: true), .pass)
        XCTAssertEqual(policy.handle(wheel(0, at: 10.01, deltaX: 5), engineReady: true), .pass)
    }

    func testIntervalBoundaryJustBeforeExactlyAndAfter() {
        // 경계 규칙: 마지막 전환 이후 경과 시간 >= minimumInterval 이면 전환 허용
        var before = makePolicy()
        XCTAssertEqual(before.handle(wheel(1, at: 10), engineReady: true), .consumeAndSwitch(.left))
        XCTAssertEqual(before.handle(wheel(1, at: 10.399), engineReady: true), .consume)

        var exact = makePolicy(interval: 0.5)
        XCTAssertEqual(exact.handle(wheel(1, at: 10), engineReady: true), .consumeAndSwitch(.left))
        XCTAssertEqual(exact.handle(wheel(1, at: 10.5), engineReady: true), .consumeAndSwitch(.left))

        var after = makePolicy()
        XCTAssertEqual(after.handle(wheel(1, at: 10), engineReady: true), .consumeAndSwitch(.left))
        XCTAssertEqual(after.handle(wheel(1, at: 10.401), engineReady: true), .consumeAndSwitch(.left))
    }

    func testBurstOfEventsYieldsAtMostOneSwitchPerInterval() {
        var policy = makePolicy()
        var switches: [TimeInterval] = []
        // 1초 동안 10ms마다 휠 이벤트
        for step in 0..<100 {
            let time = 10 + Double(step) * 0.01
            if case .consumeAndSwitch = policy.handle(wheel(1, at: time), engineReady: true) {
                switches.append(time)
            }
        }
        XCTAssertEqual(switches.count, 3) // 10.0, 10.4, 10.8
        for (a, b) in zip(switches, switches.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.4 - 1e-9)
        }
        // 휠이 멈춘 뒤에는 이벤트 없이 전환이 생기지 않는다 — 다음 이벤트가 와도 누적 타임아웃 후 새로 시작
        XCTAssertEqual(policy.handle(wheel(1, at: 20), engineReady: true), .consumeAndSwitch(.left))
    }

    func testEventsDuringIntervalAreConsumed() {
        var policy = makePolicy()
        _ = policy.handle(wheel(1, at: 10), engineReady: true)
        XCTAssertEqual(policy.handle(wheel(1, at: 10.1), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(-1, at: 10.2), engineReady: true), .consume)
    }

    func testDirectionChangeResetsAccumulation() {
        var policy = makePolicy(sensitivity: .low) // 일반 휠 2단계 필요
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(-1, at: 10.05), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(-1, at: 10.1), engineReady: true), .consumeAndSwitch(.right))
    }

    func testAccumulationTimeoutDiscardsOldDelta() {
        var policy = makePolicy(sensitivity: .low)
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(1, at: 10.3), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(1, at: 10.35), engineReady: true), .consumeAndSwitch(.left))
    }

    func testContinuousInputAccumulatesToThreshold() {
        var policy = makePolicy() // 연속 입력 보통 = 30pt
        XCTAssertEqual(policy.handle(wheel(10, at: 10, continuous: true), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(10, at: 10.01, continuous: true), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(10, at: 10.02, continuous: true), engineReady: true), .consumeAndSwitch(.left))
    }

    func testMomentumNeverStartsSwitch() {
        var policy = makePolicy()
        for step in 0..<10 {
            let input = wheel(50, at: 10 + Double(step) * 0.01, continuous: true, momentum: true)
            XCTAssertEqual(policy.handle(input, engineReady: true), .consume)
        }
    }

    func testModifierReleaseResetsAccumulation() {
        var policy = makePolicy(sensitivity: .low)
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consume)
        policy.modifiersChanged([])
        XCTAssertEqual(policy.handle(wheel(1, at: 10.05), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(wheel(1, at: 10.1), engineReady: true), .consumeAndSwitch(.left))
    }

    func testConfigurationUpdateResetsAccumulation() {
        var policy = makePolicy(sensitivity: .low)
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: true), .consume)
        policy.update(configuration: PolicyConfiguration(
            modifier: .option, reverseDirection: false, sensitivity: .low, minimumInterval: 0.4
        ))
        XCTAssertEqual(policy.handle(wheel(1, at: 10.05), engineReady: true), .consume)
    }

    func testEngineNotReadyPasses() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(wheel(1, at: 10), engineReady: false), .pass)
    }

    // MARK: - 좌우 휠

    private func makePolicy(axis: ScrollAxis, reverse: Bool = false) -> ScrollPolicy {
        ScrollPolicy(configuration: PolicyConfiguration(
            modifier: .option,
            reverseDirection: reverse,
            sensitivity: .normal,
            minimumInterval: 0.4,
            axis: axis
        ))
    }

    func testHorizontalAxisTiltLeftSwitchesLeft() {
        var policy = makePolicy(axis: .horizontal)
        XCTAssertEqual(policy.handle(wheel(0, at: 10, deltaX: 1), engineReady: true), .consumeAndSwitch(.left))
    }

    func testHorizontalAxisTiltRightSwitchesRight() {
        var policy = makePolicy(axis: .horizontal)
        XCTAssertEqual(policy.handle(wheel(0, at: 10, deltaX: -1), engineReady: true), .consumeAndSwitch(.right))
    }

    func testHorizontalAxisPassesVerticalScroll() {
        var policy = makePolicy(axis: .horizontal)
        XCTAssertEqual(policy.handle(wheel(3, at: 10), engineReady: true), .pass)
    }

    func testVerticalAxisPassesHorizontalScroll() {
        var policy = makePolicy(axis: .vertical)
        XCTAssertEqual(policy.handle(wheel(0, at: 10, deltaX: 3), engineReady: true), .pass)
    }

    func testBothAxesUseDominantAxis() {
        var vertical = makePolicy(axis: .both)
        XCTAssertEqual(vertical.handle(wheel(-3, at: 10, deltaX: 1), engineReady: true), .consumeAndSwitch(.right))

        var horizontal = makePolicy(axis: .both)
        XCTAssertEqual(horizontal.handle(wheel(-1, at: 10, deltaX: 3), engineReady: true), .consumeAndSwitch(.left))
    }

    func testHorizontalAxisWithoutModifierPasses() {
        var policy = makePolicy(axis: .horizontal)
        XCTAssertEqual(policy.handle(wheel(0, at: 10, modifiers: [], deltaX: 1), engineReady: true), .pass)
    }

    func testReverseDirectionAppliesToHorizontal() {
        var policy = makePolicy(axis: .horizontal, reverse: true)
        XCTAssertEqual(policy.handle(wheel(0, at: 10, deltaX: 1), engineReady: true), .consumeAndSwitch(.right))
    }

    func testConfigurationFromSettingsCarriesAxisAndButtonMode() {
        var settings = AppSettings.defaults
        settings.scrollAxis = .both
        settings.mouseButtonMode = .withoutModifier
        let configuration = PolicyConfiguration(settings: settings)
        XCTAssertEqual(configuration.axis, .both)
        XCTAssertEqual(configuration.buttonMode, .withoutModifier)
    }

    func testConfigurationFromSettingsConvertsMilliseconds() {
        var settings = AppSettings.defaults
        settings.minimumIntervalMs = 5_000
        XCTAssertEqual(PolicyConfiguration(settings: settings).minimumInterval, 1.0, accuracy: 1e-9)
    }
}
