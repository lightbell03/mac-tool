import AppKit
import CoreGraphics
import Foundation
import WheelSpaceCore

/// CGEvent ↔ WheelSpaceCore 값 변환. 입력 내용은 저장하지 않는다.
enum ScrollEventMapper {
    static func scrollInput(from event: CGEvent) -> ScrollInput {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var deltaY: Double
        var deltaX: Double
        if isContinuous {
            deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        } else {
            deltaY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            deltaX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
        // 자연스러운 스크롤이 켜져 있으면 변화량 부호가 뒤집혀 들어온다. 물리적 휠 방향으로 되돌린다.
        if NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true {
            deltaY = -deltaY
            deltaX = -deltaX
        }

        return ScrollInput(
            deltaY: deltaY,
            deltaX: deltaX,
            isContinuous: isContinuous,
            isMomentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0,
            modifiers: physicalModifierState(),
            // CGEvent.timestamp 단위가 하드웨어마다 달라 단조 시계를 직접 쓴다.
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    /// otherMouseDown/Up → ButtonInput. 뒤로가기·앞으로가기(버튼 3·4)가 아니면 nil.
    static func buttonInput(from event: CGEvent, isDown: Bool) -> ButtonInput? {
        guard let button = MouseSideButton(buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber)) else {
            return nil
        }
        return ButtonInput(
            button: button,
            isDown: isDown,
            modifiers: physicalModifierState(),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    /// 실제 키보드에서 눌려 있는 보조키. 이벤트의 flags는 합성한 ⌃←/⌃→ 이후 세션 보조키 상태가
    /// Control로 덮여 Option이 빠진 채 들어올 수 있어서, 하드웨어 상태를 기준으로 판정한다.
    static func physicalModifierState() -> ModifierState {
        modifierState(from: CGEventSource.flagsState(.hidSystemState))
    }

    /// Caps Lock·Fn·NumericPad 비트는 무시하고 4개 보조키만 추린다.
    static func modifierState(from flags: CGEventFlags) -> ModifierState {
        var state: ModifierState = []
        if flags.contains(.maskShift) { state.insert(.shift) }
        if flags.contains(.maskControl) { state.insert(.control) }
        if flags.contains(.maskAlternate) { state.insert(.option) }
        if flags.contains(.maskCommand) { state.insert(.command) }
        return state
    }
}
