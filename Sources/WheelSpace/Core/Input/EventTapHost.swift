import CoreGraphics
import Foundation

/// 전용 스레드에서 도는 전역 이벤트 탭 하나의 수명 관리 (생성·활성화·해제·제한적 복구).
/// 데스크탑 전환(EventTapService)과 키보드 포인터(KeyPointerEngine)가 각자 하나씩 쓴다.
/// 이벤트 처리 콜백과 perform 블록은 모두 탭 스레드에서 실행된다.
final class EventTapHost {
    enum Event {
        case started
        case stopped
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        case creationFailed
        case repeatedlyDisabled
    }

    /// 탭 스레드 한 번의 실행. stop()이 탭 생성보다 먼저 와도 스레드가 스스로 정리하도록 취소 표시를 둔다.
    private final class Session {
        var runLoop: CFRunLoop?
        var tap: CFMachPort?
        var isCancelled = false
    }

    /// 상태 변화 통지 (메인 스레드)
    var onEvent: ((Event) -> Void)?
    /// 탭 스레드: 이벤트 처리. nil 반환 = 소비
    var handler: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    /// 탭 스레드: 탭을 켜기 직전 (설정 스냅샷으로 상태를 새로 만드는 등)
    var onTapThreadStart: (() -> Void)?
    /// 탭 스레드: 탭이 시스템에 의해 꺼졌거나 정지될 때 상태 초기화 (눌린 버튼 해제 등)
    var onInterrupted: (() -> Void)?

    private let name: String
    private let mask: CGEventMask
    /// 받는 단계와 방식. 기본은 세션 단계에서 가로채기(소비 가능).
    /// 전역 단축키(⌘Space 등)보다 먼저 보기만 하려면 HID 단계 + 듣기 전용.
    private let location: CGEventTapLocation
    private let options: CGEventTapOptions

    /// session 보호
    private let lock = NSLock()
    /// 메인 스레드가 소유하는 현재 실행
    private var session: Session?

    // 이하 탭 스레드 전용
    private var activeSession: Session?
    /// 탭 비활성화 복구 기록 (짧은 시간 반복 실패 판정)
    private var recentReenableTimes: [TimeInterval] = []
    private static let reenableWindow: TimeInterval = 10
    private static let maxReenablesInWindow = 3

    init(name: String, mask: CGEventMask, location: CGEventTapLocation = .cgSessionEventTap, options: CGEventTapOptions = .defaultTap) {
        self.name = name
        self.mask = mask
        self.location = location
        self.options = options
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let tap = session?.tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// 메인 스레드. 이미 실행 중이면 무시.
    func start() {
        guard session == nil else { return }
        let newSession = Session()
        lock.lock()
        session = newSession
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.runTapLoop(newSession)
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 메인 스레드. 탭 스레드에서 onInterrupted 호출 후 정리하고 run loop를 멈춘다.
    func stop() {
        lock.lock()
        guard let current = session else {
            lock.unlock()
            return
        }
        session = nil
        current.isCancelled = true
        let runLoop = current.runLoop
        lock.unlock()

        if let runLoop {
            // 정리는 탭 스레드가 CFRunLoopRun에서 빠져나온 뒤 runTapLoop 끝에서 한다.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
        onEvent?(.stopped)
    }

    /// 탭 스레드에서 블록 실행 (설정 스냅샷 반영·초기화 등). 탭이 없으면 실행하지 않는다.
    func perform(_ block: @escaping () -> Void) {
        lock.lock()
        let runLoop = session?.runLoop
        lock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// 탭 스레드 run loop에 반복 타이머를 건다. 탭 스레드에서 호출.
    func scheduleRepeatingTimer(interval: TimeInterval, _ tick: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, { _ in tick() }
        ) else {
            return nil
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        return timer
    }

    /// 탭 스레드 run loop에 한 번만 도는 타이머를 건다. 탭 스레드에서 호출.
    func scheduleOneShotTimer(after delay: TimeInterval, _ fire: @escaping () -> Void) -> CFRunLoopTimer? {
        // interval 0 = 반복하지 않음
        guard let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0, { _ in fire() }
        ) else {
            return nil
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        return timer
    }

    // MARK: - 탭 스레드

    private func runTapLoop(_ session: Session) {
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: eventTapHostCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            notifyMain(session, .failed(.creationFailed))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()

        lock.lock()
        if session.isCancelled {
            lock.unlock()
            CFMachPortInvalidate(tap)
            return
        }
        session.tap = tap
        session.runLoop = runLoop
        lock.unlock()

        activeSession = session
        recentReenableTimes.removeAll()
        onTapThreadStart?()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        notifyMain(session, .started)

        CFRunLoopRun()

        onInterrupted?()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        activeSession = nil
    }

    /// 취소되지 않은 실행에서 온 통지만 메인 스레드로 전달한다.
    private func notifyMain(_ session: Session, _ event: Event) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.session === session
            self.lock.unlock()
            guard isCurrent else { return }
            self.onEvent?(event)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleTapDisabled(type)
            return Unmanaged.passUnretained(event)
        default:
            // `handler?(…) ?? pass`로 쓰면 handler의 nil(소비)과 handler 없음이 구분되지 않아 소비한 이벤트가 그대로 통과한다
            guard let handler else { return Unmanaged.passUnretained(event) }
            return handler(type, event)
        }
    }

    private func handleTapDisabled(_ type: CGEventType) {
        onInterrupted?()
        guard let session = activeSession, let tap = session.tap else { return }

        // 보안 입력 등 시스템이 의도적으로 끈 경우는 횟수 제한 없이 다시 켠다.
        if type == .tapDisabledByUserInput {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        recentReenableTimes.removeAll { now - $0 > Self.reenableWindow }
        if recentReenableTimes.count < Self.maxReenablesInWindow {
            recentReenableTimes.append(now)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            CGEvent.tapEnable(tap: tap, enable: false)
            notifyMain(session, .failed(.repeatedlyDisabled))
        }
    }
}

/// CGEventTapCallBack용 C 함수. userInfo에서 EventTapHost를 꺼내 위임한다.
private func eventTapHostCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let host = Unmanaged<EventTapHost>.fromOpaque(userInfo).takeUnretainedValue()
    return host.handle(type: type, event: event)
}
