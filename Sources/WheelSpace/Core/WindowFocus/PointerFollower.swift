import AppKit
import ApplicationServices
import WheelSpaceCore

/// "포커스가 다른 모니터로 바뀔 때마다" 모드: Spotlight·⌘Tab·Dock 등으로 다른 모니터의 창이 포커스를 받으면
/// 마우스 포인터를 그 창으로 옮긴다. 창 포커스 이동(⌃⌥방향키)의 포인터 이동은 FocusCoordinator가 따로 처리한다.
@MainActor
final class PointerFollower {
    /// 앱이 활성화된 뒤 그 앱의 포커스 창이 정해질 때까지 기다리는 시간 (설계값)
    static let settleDelay: TimeInterval = 0.15

    /// 데스크탑(Space)이 바뀐 뒤 이 시간 동안은 따라가지 않는다 — macOS가 새 데스크탑에 맞춰 다른 모니터의 앱을
    /// 앞으로 가져오는 것은 사용자가 포커스를 옮긴 게 아니다 (데스크탑을 넘길 때 포인터가 엉뚱한 모니터로 튀지 않게)
    static let spaceChangeQuietPeriod: TimeInterval = 0.8

    private var mode: PointerFollowMode = .off
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var lastSpaceChange: TimeInterval = -.infinity
    /// 같은 앱 안에서 다른 모니터의 창으로 포커스가 바뀌는 경우(⌘` 등)를 보는 AX 관찰자
    private var axObserver: AXObserver?
    private var observedApp: AXUIElement?
    private var pendingWork: DispatchWorkItem?

    func update(mode newMode: PointerFollowMode) {
        mode = newMode
        if newMode == .allFocusChanges {
            startObserving()
        } else {
            stopObserving()
        }
    }

    func stop() {
        stopObserving()
    }

    private func startObserving() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            MainActor.assumeIsolated {
                self?.attachFocusObserver(pid: pid)
                self?.scheduleFollow(pid: pid)
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastSpaceChange = ProcessInfo.processInfo.systemUptime
                // 데스크탑 전환과 함께 예약된 따라가기는 버린다
                self?.pendingWork?.cancel()
                self?.pendingWork = nil
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            attachFocusObserver(pid: pid)
        }
    }

    private func stopObserving() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        detachFocusObserver()
        pendingWork?.cancel()
        pendingWork = nil
    }

    /// 전면 앱의 kAXFocusedWindowChangedNotification 구독 (앱이 바뀔 때마다 갈아 끼운다)
    private func attachFocusObserver(pid: pid_t) {
        detachFocusObserver()
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, pointerFollowerCallback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedApp = app
    }

    private func detachFocusObserver() {
        if let axObserver, let observedApp {
            AXObserverRemoveNotification(axObserver, observedApp, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedApp = nil
    }

    fileprivate func focusedWindowChanged() {
        guard let observedApp else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(observedApp, &pid)
        scheduleFollow(pid: pid)
    }

    /// 짧게 기다렸다가(포커스 창이 확정되도록) followNow 실행. 연속 알림은 마지막 것만.
    private func scheduleFollow(pid: pid_t) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.followNow(pid: pid) }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func followNow(pid: pid_t) {
        guard mode == .allFocusChanges,
              ProcessInfo.processInfo.systemUptime - lastSpaceChange > Self.spaceChangeQuietPeriod,
              pid != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              case .success(let window) = WindowInventory.focusedWindow(pid: pid),
              let frame = WindowInventory.frame(of: window) else {
            return
        }
        let displays = DisplayService.activeDisplayFrames()
        guard let windowDisplay = PointerMover.displayIndex(of: frame, in: displays) else { return }
        let pointer = MouseActionService.currentLocation()
        // 포인터가 이미 그 모니터에 있으면 그대로 둔다 — 마우스로 클릭해 바꾼 경우, 창 포커스 이동이 이미 옮긴 경우
        guard displays.firstIndex(where: { $0.contains(pointer) }) != windowDisplay else { return }
        let visible = frame.intersection(displays[windowDisplay])
        PointerMover.move(to: CGPoint(x: visible.midX, y: visible.midY))
    }
}

/// AXObserverCallback용 C 함수. 메인 run loop에 붙였으므로 메인 스레드에서 불린다.
private func pointerFollowerCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let follower = Unmanaged<PointerFollower>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        follower.focusedWindowChanged()
    }
}
