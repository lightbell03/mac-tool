import AppKit
import Combine
import WheelSpaceCore

/// 실행 중인 앱 선택: 단축키·메뉴 → 목록 패널 → 선택 → 상태 조회·단계 진행(숨김 해제·복원·다시 열기) → 실제 창 표시 확인.
/// 한 번에 작업 하나만. 사용자가 다른 앱으로 옮기면 뒤늦은 활성화·재시도를 취소한다.
/// 창 제목은 기록하지 않고, 앱 이력은 메모리에만 둔다.
@MainActor
final class AppRevealCoordinator: ObservableObject {
    enum Status: Equatable {
        case paused
        case needsPermission
        case ready
        /// 선택한 앱의 창을 보여 주는 중
        case revealing
    }

    /// 한 작업의 결과 (안내 문구·진단용)
    enum Outcome: Equatable {
        case shown
        case limited(RevealLimit)
        case reopenNoResponse
        case appTerminated
        case cancelled
        case focusFailed
    }

    @Published private(set) var settings: AppRevealSettings
    @Published private(set) var status: Status = .paused
    @Published private(set) var shortcutError: String?
    @Published private(set) var lastResult: String?

    /// 창 표시 확인 대기 (다시 열기 뒤 창이 생기기까지)
    static let revealTimeout: TimeInterval = 2
    /// 숨김 해제·최소화 복원 같은 단계 반복 상한 (AX 객체 무효화 등으로 같은 단계를 무한 반복하지 않게)
    static let maxSteps = 4
    /// 숨김 해제 뒤 창이 다시 나타나기를 기다리는 시간
    private static let unhideSettle: UInt64 = 150_000_000
    /// 다시 열기 뒤 창이 생겼는지 다시 볼 간격
    private static let reopenPoll: UInt64 = 200_000_000

    private let store: SettingsStore
    private let diagnostics: Diagnostics
    private let apps = RunningAppStore()
    private let shortcuts = GlobalShortcutService<AppRevealShortcut>(signature: 0x5753_4152) { _ in 1 } // "WSAR"
    private var shortcutsSuspended = false
    /// 진행 중 작업 번호. 새 작업·취소 때 올라가 이전 작업의 남은 단계를 멈춘다.
    private var operation = 0
    /// 진행 중 작업의 대상 PID (이 앱의 활성화는 사용자 전환으로 보지 않는다)
    private var targetPID: Int32?
    /// 목록을 열기 전 전면 앱 (Esc면 돌아간다)
    private var previousApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    init(store: SettingsStore, diagnostics: Diagnostics) {
        self.store = store
        self.diagnostics = diagnostics
        self.settings = store.loadAppReveal()
    }

    func start() {
        apps.start()
        shortcuts.onTrigger = { [weak self] _ in self?.openPicker() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                // 진행 중에 대상도 WheelSpace도 아닌 앱이 앞으로 오면 사용자가 옮긴 것 — 뒤늦은 단계를 멈춘다
                guard let self, self.status == .revealing, let pid, pid != self.targetPID,
                      pid != ProcessInfo.processInfo.processIdentifier else { return }
                self.cancelOperation(reason: "사용자 앱 전환")
            }
        })
        reconcile()
    }

    func stop() {
        shortcuts.unregisterAll()
        apps.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        AppPickerPanel.close()
        cancelOperation(reason: "종료")
    }

    func update(settings newValue: AppRevealSettings) {
        let value = newValue.validated()
        store.saveAppReveal(value)
        settings = value
        reconcile()
    }

    /// 켜짐·권한(손쉬운 사용)·단축키 등록. 권한이 없어도 목록·앱 활성화는 할 수 있어 단축키는 등록한다.
    func reconcile() {
        guard settings.isEnabled else {
            shortcuts.unregisterAll()
            shortcutError = nil
            status = .paused
            cancelOperation(reason: "꺼짐")
            return
        }
        if shortcutsSuspended {
            shortcuts.unregisterAll()
        } else {
            applyShortcut()
        }
        if status != .revealing {
            status = AXIsProcessTrusted() ? .ready : .needsPermission
        }
    }

    func setShortcutsSuspended(_ suspended: Bool) {
        guard suspended != shortcutsSuspended else { return }
        shortcutsSuspended = suspended
        reconcile()
    }

    /// 단축키·메뉴 진입점: 전면 앱을 기록하고 목록 패널을 연다
    func openPicker() {
        guard settings.isEnabled else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ownPID ? nil : frontmost
        AppPickerPanel.show(
            entries: apps.entries(includedAccessoryApps: settings.includedAccessoryApps),
            onSelect: { [weak self] entry in self?.reveal(entry) },
            onCancel: { [weak self] in
                // 원래 앱으로 돌아간다
                self?.previousApp?.activate(options: [])
            }
        )
        // 키 입력(검색·Return)을 받는 상태가 됐는지 남긴다 — 못 받으면 키가 원래 앱으로 간다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.diagnostics.record(
                "실행 중인 앱 선택: 목록 열림 — 키 창 \(AppPickerPanel.isKey ? "예" : "아니오"), 앱 활성 \(NSApp.isActive ? "예" : "아니오")"
            )
        }
    }

    /// 잠금·잠자기·권한 회수·사용자 전환
    func cancelOperation(reason: String) {
        operation += 1
        targetPID = nil
        if status == .revealing {
            status = AXIsProcessTrusted() ? .ready : .needsPermission
            diagnostics.record("실행 중인 앱 선택 취소: \(reason)")
        }
    }

    /// 선택한 앱의 창을 보여 준다. 단계마다 operation이 바뀌었으면(취소) 멈춘다.
    private func reveal(_ entry: AppPickerEntry) {
        operation += 1
        let current = operation
        let appLabel = entry.bundleID ?? entry.name
        diagnostics.record("실행 중인 앱 선택: \(appLabel) 선택됨")
        guard let app = apps.liveApplication(for: entry) else {
            // 종료된 앱은 새로 실행하지 않는다
            return finish(.appTerminated, app: appLabel)
        }
        status = .revealing
        targetPID = app.processIdentifier
        let pid = app.processIdentifier
        let started = ProcessInfo.processInfo.systemUptime

        Task { [weak self] in
            var alreadyUnhid = false
            var alreadyReopened = false
            var outcome: Outcome = .focusFailed
            var steps: [String] = []

            for _ in 0..<Self.maxSteps {
                guard let self, current == self.operation else { return }
                guard !app.isTerminated else { outcome = .appTerminated; break }
                let isHidden = app.isHidden
                let inspection = await Task.detached(priority: .userInitiated) {
                    AppWindowInspector.inspect(pid: pid, isHidden: isHidden)
                }.value
                guard current == self.operation else { return }

                let step = AppRevealPlanner.nextStep(
                    inspection, settings: self.settings, alreadyUnhid: alreadyUnhid, alreadyReopened: alreadyReopened
                )
                steps.append(Self.label(for: step) + Self.stateNote(inspection))
                switch step {
                case .unhide:
                    alreadyUnhid = true
                    _ = AppRevealActions.unhide(app)
                    try? await Task.sleep(nanoseconds: Self.unhideSettle)
                    continue
                case .focusExisting:
                    let window = await Task.detached { AppWindowInspector.windowToFocus(pid: pid) }.value
                    guard current == self.operation else { return }
                    if let window, await AppRevealActions.focus(window, pid: pid) {
                        outcome = .shown
                    } else {
                        outcome = .focusFailed
                        steps.append(window == nil ? "대상 창 못 찾음" : "포커스 확인 실패")
                    }
                case .restoreMinimized:
                    let window = await Task.detached { AppWindowInspector.minimizedWindow(pid: pid) }.value
                    guard current == self.operation else { return }
                    if let window, await AppRevealActions.restoreMinimized(window, pid: pid) {
                        outcome = .shown
                    } else {
                        outcome = .focusFailed
                    }
                case .reopen:
                    alreadyReopened = true
                    guard await AppRevealActions.reopen(app) else { outcome = .reopenNoResponse; break }
                    // 창이 생길 때까지 기다린다. AX에 보이면 다음 조회에서 기존 창으로 이어서 포커스하고,
                    // 화면에만 보이면(AX 목록에 늦게 나타나는 앱) 앱이 이미 앞에 와 있으니 열린 것으로 본다.
                    let appeared = await self.waitForWindow(pid: pid, operation: current)
                    guard current == self.operation else { return }
                    switch appeared {
                    case .axWindow: continue
                    case .onscreenOnly:
                        steps.append("화면에 창 보임")
                        outcome = .shown
                    case .none:
                        outcome = .reopenNoResponse
                    }
                case .activateOnly(let limit):
                    AppRevealActions.activate(app)
                    outcome = .limited(limit)
                }
                break
            }
            guard let self, current == self.operation else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            // 앱은 번들 ID만, 창 제목은 남기지 않는다
            self.diagnostics.record("실행 중인 앱 선택 \(appLabel): \(outcome) — \(steps.joined(separator: " → ")), \(elapsed)ms")
            self.finish(outcome, app: appLabel)
        }
    }

    private enum Appearance {
        /// AX 창 목록에 일반(또는 최소화) 창이 생김
        case axWindow
        /// AX에는 아직 없지만 화면에 창이 보임
        case onscreenOnly
        case none
    }

    /// 다시 열기 뒤 revealTimeout 동안 창이 생기는지 본다
    private func waitForWindow(pid: Int32, operation current: Int) async -> Appearance {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.revealTimeout
        var seenOnscreen = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: Self.reopenPoll)
            guard current == operation else { return .none }
            let (inspection, onscreen) = await Task.detached {
                (AppWindowInspector.inspect(pid: pid, isHidden: false), AppWindowInspector.hasOnscreenWindow(pid: pid))
            }.value
            if case .inspected(let state) = inspection, state.normalWindowCount + state.minimizedWindowCount > 0 {
                return .axWindow
            }
            seenOnscreen = seenOnscreen || onscreen
        }
        return seenOnscreen ? .onscreenOnly : .none
    }

    private func finish(_ outcome: Outcome, app: String) {
        targetPID = nil
        status = AXIsProcessTrusted() ? .ready : .needsPermission
        let message = Self.message(for: outcome)
        lastResult = message
        switch outcome {
        case .shown, .cancelled:
            break
        case .limited, .reopenNoResponse:
            FeedbackHUD.show(message)
        case .appTerminated, .focusFailed:
            FeedbackHUD.show(message, isError: true)
            diagnostics.record("실행 중인 앱 선택 실패 \(app): \(outcome)")
        }
    }

    private func applyShortcut() {
        var combos: [AppRevealShortcut: KeyCombo] = [:]
        combos[.openPicker] = settings.shortcut
        let failures = shortcuts.register(combos)
        shortcutError = failures[.openPicker].map { _ in "다른 앱이나 다른 기능이 이미 쓰고 있는 조합이에요. 메뉴에서는 열 수 있어요." }
        if failures[.openPicker] != nil {
            diagnostics.record("실행 중인 앱 선택 단축키 등록 실패: \(settings.shortcut?.displayString ?? "")")
        }
    }

    var stateDescription: String {
        switch status {
        case .paused: return "꺼짐"
        case .needsPermission: return "권한 필요 (창 복원 제한)"
        case .ready: return "사용 중"
        case .revealing: return "창 여는 중"
        }
    }

    var diagnosticsLines: [String] {
        let combo = settings.shortcut?.displayString ?? "없음"
        return [
            "실행 중인 앱 선택: \(stateDescription)",
            "  단축키: \(combo) — \(shortcutError == nil ? "정상" : "실패")",
        ]
    }

    /// 진단용 창 상태 요약 (개수·숨김만)
    private static func stateNote(_ inspection: AppWindowInspection) -> String {
        guard case .inspected(let state) = inspection else { return "(조회 실패)" }
        return "(일반 \(state.normalWindowCount)·최소화 \(state.minimizedWindowCount)·다른 데스크탑 \(state.otherSpaceWindowCount)"
            + "\(state.isHidden ? "·숨김" : "")\(state.hasModal ? "·모달" : ""))"
    }

    private static func label(for step: RevealStep) -> String {
        switch step {
        case .unhide: return "숨김 해제"
        case .focusExisting: return "기존 창"
        case .restoreMinimized: return "최소화 복원"
        case .reopen: return "다시 열기"
        case .activateOnly(let limit): return "활성화만(\(limit))"
        }
    }

    static func message(for outcome: Outcome) -> String {
        switch outcome {
        case .shown: return "창을 열었어요"
        case .limited(.inspectionFailed): return "창 상태를 확인하지 못해 앱만 앞으로 가져왔어요"
        case .limited(.windowsOnOtherSpace): return "다른 데스크탑의 창을 확인하세요"
        case .limited(.hiddenAndUnhideDisabled): return "숨긴 앱이에요 (설정에서 숨김 해제를 켤 수 있어요)"
        case .limited(.minimizedAndRestoreDisabled): return "최소화된 창만 있어요"
        case .limited(.noWindowAndReopenUnavailable): return "열린 창이 없어요"
        case .reopenNoResponse: return "앱이 창 다시 열기를 지원하지 않거나 응답하지 않았습니다"
        case .appTerminated: return "앱이 종료됐어요"
        case .focusFailed: return "창으로 포커스를 옮기지 못했어요"
        case .cancelled: return ""
        }
    }
}

/// 이 기능의 전역 단축키 (하나)
enum AppRevealShortcut: Hashable, CaseIterable {
    case openPicker
}
