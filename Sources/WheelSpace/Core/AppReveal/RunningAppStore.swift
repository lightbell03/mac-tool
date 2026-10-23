import AppKit
import WheelSpaceCore

/// 실행 중인 일반 GUI 앱 목록과 최근 활성화 순서 (메모리에만). 실행·종료·활성화 알림을 받는다.
/// Dock·메뉴 막대 보조 앱·백그라운드 에이전트(activationPolicy가 regular가 아닌 앱)와 WheelSpace 자신은 뺀다.
@MainActor
final class RunningAppStore {
    private var recent = RecentAppOrder()
    private var observers: [NSObjectProtocol] = []

    func start() {
        let workspace = NSWorkspace.shared
        if let frontmost = workspace.frontmostApplication {
            recent.activated(frontmost.processIdentifier)
        }
        let center = workspace.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            Task { @MainActor in self?.recent.activated(pid) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            Task { @MainActor in self?.recent.terminated(pid) }
        })
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 목록용 앱 (최근 순서, 이력 없으면 이름순, 같은 이름 구별 표시)
    /// includedAccessoryApps: 함께 보일 메뉴 막대 앱 번들 ID (창을 닫으면 메뉴 막대 앱이 되는 Docker Desktop 등)
    func entries(includedAccessoryApps: [String] = []) -> [AppPickerEntry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let included = Set(includedAccessoryApps)
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.processIdentifier != ownPID else { return false }
            switch app.activationPolicy {
            case .regular: return true
            case .accessory: return app.bundleIdentifier.map(included.contains) ?? false
            default: return false
            }
        }
        let entries = apps.map { app in
            AppPickerEntry(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)",
                bundleID: app.bundleIdentifier,
                isHidden: app.isHidden
            )
        }
        return AppPickerModel.disambiguated(recent.sorted(entries))
    }

    /// 선택 시 재확인: 같은 PID가 아직 같은 앱으로 살아 있는지 (PID 재사용 대비 번들 ID까지 비교)
    func liveApplication(for entry: AppPickerEntry) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated,
              app.bundleIdentifier == entry.bundleID else {
            return nil
        }
        return app
    }
}
