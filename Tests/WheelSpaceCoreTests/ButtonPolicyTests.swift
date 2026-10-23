import XCTest
@testable import WheelSpaceCore

final class ButtonPolicyTests: XCTestCase {
    private func makeConfiguration(_ mode: MouseButtonMode, interval: TimeInterval = 0.4) -> PolicyConfiguration {
        PolicyConfiguration(
            modifier: .option,
            reverseDirection: false,
            sensitivity: .normal,
            minimumInterval: interval,
            buttonMode: mode
        )
    }

    private func makePolicy(_ mode: MouseButtonMode, interval: TimeInterval = 0.4) -> ButtonPolicy {
        ButtonPolicy(configuration: makeConfiguration(mode, interval: interval))
    }

    private func press(
        _ button: MouseSideButton,
        down: Bool = true,
        at time: TimeInterval,
        modifiers: ModifierState = .option
    ) -> ButtonInput {
        ButtonInput(button: button, isDown: down, modifiers: modifiers, timestamp: time)
    }

    func testOffModePassesEverything() {
        var policy = makePolicy(.off)
        XCTAssertEqual(policy.handle(press(.back, at: 10), engineReady: true), .pass)
        XCTAssertEqual(policy.handle(press(.back, down: false, at: 10.05), engineReady: true), .pass)
        XCTAssertEqual(policy.handle(press(.forward, at: 11, modifiers: []), engineReady: true), .pass)
    }

    func testWithModifierBackSwitchesLeftAndForwardSwitchesRight() {
        var policy = makePolicy(.withModifier)
        XCTAssertEqual(policy.handle(press(.back, at: 10), engineReady: true), .consumeAndSwitch(.left))
        XCTAssertEqual(policy.handle(press(.forward, at: 11), engineReady: true), .consumeAndSwitch(.right))
    }

    func testWithModifierPassesWithoutModifier() {
        var policy = makePolicy(.withModifier)
        XCTAssertEqual(policy.handle(press(.back, at: 10, modifiers: []), engineReady: true), .pass)
        XCTAssertEqual(policy.handle(press(.back, at: 11, modifiers: [.option, .shift]), engineReady: true), .pass)
    }

    func testWithoutModifierSwitchesOnPlainClick() {
        var policy = makePolicy(.withoutModifier)
        XCTAssertEqual(policy.handle(press(.forward, at: 10, modifiers: []), engineReady: true), .consumeAndSwitch(.right))
    }

    func testWithoutModifierPassesWhenAnyModifierHeld() {
        var policy = makePolicy(.withoutModifier)
        XCTAssertEqual(policy.handle(press(.back, at: 10, modifiers: .option), engineReady: true), .pass)
        XCTAssertEqual(policy.handle(press(.back, at: 11, modifiers: .command), engineReady: true), .pass)
    }

    func testMatchingUpIsConsumedAfterConsumedDown() {
        var policy = makePolicy(.withModifier)
        _ = policy.handle(press(.back, at: 10), engineReady: true)
        // Option을 먼저 떼고 버튼을 떼도 짝이 되는 up은 차단
        XCTAssertEqual(policy.handle(press(.back, down: false, at: 10.1, modifiers: []), engineReady: true), .consume)
        // 두 번째 up은 짝이 없으므로 통과
        XCTAssertEqual(policy.handle(press(.back, down: false, at: 10.2), engineReady: true), .pass)
    }

    func testUpWithoutConsumedDownPasses() {
        var policy = makePolicy(.withModifier)
        _ = policy.handle(press(.back, at: 10), engineReady: true)
        XCTAssertEqual(policy.handle(press(.forward, down: false, at: 10.1), engineReady: true), .pass)
    }

    func testUpStillConsumedAfterModeTurnedOff() {
        var policy = makePolicy(.withModifier)
        _ = policy.handle(press(.back, at: 10), engineReady: true)
        policy.update(configuration: makeConfiguration(.off))
        XCTAssertEqual(policy.handle(press(.back, down: false, at: 10.1), engineReady: true), .consume)
    }

    func testClicksWithinMinimumIntervalAreConsumedWithoutSwitch() {
        var policy = makePolicy(.withModifier)
        XCTAssertEqual(policy.handle(press(.forward, at: 10), engineReady: true), .consumeAndSwitch(.right))
        XCTAssertEqual(policy.handle(press(.forward, down: false, at: 10.05), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(press(.forward, at: 10.2), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(press(.forward, down: false, at: 10.25), engineReady: true), .consume)
        XCTAssertEqual(policy.handle(press(.forward, at: 10.4), engineReady: true), .consumeAndSwitch(.right))
    }

    func testEngineNotReadyPassesDown() {
        var policy = makePolicy(.withModifier)
        XCTAssertEqual(policy.handle(press(.back, at: 10), engineReady: false), .pass)
    }

    func testUnknownButtonNumberIsNil() {
        XCTAssertEqual(MouseSideButton(buttonNumber: 3), .back)
        XCTAssertEqual(MouseSideButton(buttonNumber: 4), .forward)
        XCTAssertNil(MouseSideButton(buttonNumber: 2)) // 휠 클릭
        XCTAssertNil(MouseSideButton(buttonNumber: 5))
    }
}
