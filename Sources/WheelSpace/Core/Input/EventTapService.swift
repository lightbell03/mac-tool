import CoreGraphics
import Foundation
import WheelSpaceCore

/// 데스크탑 전환용 이벤트 탭: 휠·보조키·뒤로/앞으로 버튼을 판정한다.
/// 탭 수명·복구는 EventTapHost가 맡고, ScrollPolicy·ButtonPolicy는 탭 스레드에서만 접근한다.
final class EventTapService {
    typealias TapEvent = EventTapHost.Event
    typealias TapFailure = EventTapHost.Failure

    /// 상태 변화 통지. 메인 스레드에서 호출된다.
    var onEvent: ((TapEvent) -> Void)? {
        get { host.onEvent }
        set { host.onEvent = newValue }
    }

    private let switcher: DesktopSwitcher
    private let host: EventTapHost

    /// configurationSnapshot 보호
    private let lock = NSLock()
    private var configurationSnapshot: PolicyConfiguration

    // 이하 탭 스레드 전용
    private var policy: ScrollPolicy
    private var buttonPolicy: ButtonPolicy

    init(switcher: DesktopSwitcher, configuration: PolicyConfiguration) {
        self.switcher = switcher
        self.configurationSnapshot = configuration
        self.policy = ScrollPolicy(configuration: configuration)
        self.buttonPolicy = ButtonPolicy(configuration: configuration)
        // 버튼 모드가 꺼져 있어도 버튼 이벤트는 구독한다. 설정 변경 때 탭을 다시 만들지 않고 판정에서 통과시킨다.
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        self.host = EventTapHost(name: "WheelSpace.EventTap", mask: mask)

        host.onTapThreadStart = { [unowned self] in
            lock.lock()
            let configuration = configurationSnapshot
            lock.unlock()
            policy = ScrollPolicy(configuration: configuration)
            buttonPolicy = ButtonPolicy(configuration: configuration)
        }
        host.onInterrupted = { [unowned self] in
            policy.reset()
        }
        host.handler = { [unowned self] type, event in
            handle(type: type, event: event)
        }
    }

    var isRunning: Bool { host.isRunning }

    /// 메인 스레드에서 호출. 이미 실행 중이면 아무것도 하지 않는다.
    func start() {
        host.start()
    }

    /// 메인 스레드에서 호출. 탭을 비활성화·제거하고 run loop를 멈춘다.
    func stop() {
        host.stop()
    }

    /// 설정 스냅샷 반영. 탭 스레드에서 policy.update로 누적값까지 초기화한다.
    func update(configuration: PolicyConfiguration) {
        lock.lock()
        configurationSnapshot = configuration
        lock.unlock()

        // 탭이 없으면 다음 start()에서 스냅샷으로 policy를 새로 만든다.
        host.perform { [weak self] in
            self?.policy.update(configuration: configuration)
            self?.buttonPolicy.update(configuration: configuration)
        }
    }

    /// 잠자기·잠금 등에서 누적·대기 입력 제거.
    func resetTransientState() {
        host.perform { [weak self] in
            self?.policy.reset()
        }
    }

    /// 탭 콜백 본체 (탭 스레드). 파일·UI·블로킹 작업 금지.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            policy.modifiersChanged(ScrollEventMapper.physicalModifierState())
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if SyntheticKeyboard.isSynthetic(event) {
                return Unmanaged.passUnretained(event)
            }
            return apply(policy.handle(ScrollEventMapper.scrollInput(from: event), engineReady: true), to: event)
        case .otherMouseDown, .otherMouseUp:
            // 휠 클릭 등 뒤로·앞으로가 아닌 버튼은 그대로 통과
            guard let input = ScrollEventMapper.buttonInput(from: event, isDown: type == .otherMouseDown) else {
                return Unmanaged.passUnretained(event)
            }
            return apply(buttonPolicy.handle(input, engineReady: true), to: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func apply(_ decision: ScrollDecision, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .consumeAndSwitch(let direction):
            switcher.requestSwitch(direction)
            return nil
        }
    }
}
