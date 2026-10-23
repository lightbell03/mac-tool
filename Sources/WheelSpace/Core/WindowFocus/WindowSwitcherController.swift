import AppKit
import WheelSpaceCore

/// 창 목록 전환기의 메인 스레드 쪽: 엔진 명령 → 목록 만들기(백그라운드) → 패널 표시 → 선택한 창 활성화.
/// 창 제목은 패널 표시에만 쓰고 기록·저장하지 않는다. FocusCoordinator가 켜고 끈다.
@MainActor
final class WindowSwitcherController {
    /// 목록 한 줄 (패널 표시 + 활성화 대상)
    struct Item {
        let pid: Int32
        let window: AXUIElement
        let appName: String
        let appIcon: NSImage?
        /// 창 제목 (없으면 nil — 패널은 앱 이름만 보인다)
        let title: String?
        /// 지금 포커스 창 (0번)
        let isCurrent: Bool
    }

    private let diagnostics: Diagnostics
    private var engine: WindowSwitcherEngine?
    /// 마지막으로 만든 목록 (0번 = 현재 창, 이후 같은 모니터의 창 앞에서 뒤 순서)
    private var items: [Item] = []
    /// 현재 창 위치 (CG 좌표) — 패널을 띄울 화면을 고른다. 메인 스레드에서 AX를 부르지 않으려고 목록과 함께 받아 둔다.
    private var currentFrame: CGRect?
    /// 목록 요청 세대. 늦게 온 이전 목록을 버리는 데 쓴다.
    private var loadGeneration = 0
    /// 이 전환기가 일으킨 앱 활성화를 사용자 전환으로 오인하지 않게 알려 주는 통로 (FocusCoordinator의 ownActivations)
    var onOwnActivation: ((Int32) -> Void)?

    init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    /// trigger가 nil이면 끈다. 권한·켜짐 판단은 FocusCoordinator가 한다.
    func apply(trigger: KeyCombo?, requiresHeldKey: Bool) {
        guard let trigger else {
            stop()
            return
        }
        if let engine {
            engine.update(trigger: trigger, requiresHeldKey: requiresHeldKey)
            return
        }
        let engine = WindowSwitcherEngine(trigger: trigger, requiresHeldKey: requiresHeldKey)
        engine.onCommand = { [weak self] command in
            Task { @MainActor in self?.handle(command) }
        }
        engine.onTapEvent = { [weak self] event in
            if case .failed(let failure) = event {
                Task { @MainActor in self?.diagnostics.record("창 목록 전환기 이벤트 탭 실패: \(failure)") }
            }
        }
        self.engine = engine
        engine.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
        WindowSwitcherPanel.hide()
        items = []
    }

    /// 잠금·모니터 변경·설정 창 열기 등
    func cancel() {
        engine?.cancelFromMain()
    }

    private func handle(_ command: WindowSwitcherCommand) {
        switch command {
        case .loadList:
            loadList()
        case .show(let selection):
            guard items.indices.contains(selection) else { return }
            WindowSwitcherPanel.show(rows: rows(), selection: selection, on: screen(containing: currentFrame))
        case .confirm(let index):
            WindowSwitcherPanel.hide()
            // 0번 = 지금 창이면 그대로
            guard items.indices.contains(index), !items[index].isCurrent else { return }
            activate(items[index])
        case .cancel:
            WindowSwitcherPanel.hide()
        }
    }

    private func rows() -> [WindowSwitcherPanel.Row] {
        items.enumerated().map { index, item in
            WindowSwitcherPanel.Row(
                id: index, appName: item.appName, appIcon: item.appIcon, title: item.title, isCurrent: item.isCurrent
            )
        }
    }

    /// 현재 창이 있는 화면 (NSScreen). 못 찾으면 포인터가 있는 화면.
    private func screen(containing frame: CGRect?) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let fallback = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame, let primary = NSScreen.screens.first else { return fallback }
        // CG 좌표(왼쪽 위 원점) → Cocoa 좌표(주 화면 왼쪽 아래 원점)
        let cocoa = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let best = NSScreen.screens.max { a, b in
            area(a.frame.intersection(cocoa)) < area(b.frame.intersection(cocoa))
        }
        return best.flatMap { area($0.frame.intersection(cocoa)) > 0 ? $0 : nil } ?? fallback
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// 백그라운드에서 스냅샷(가려진 창 포함) → 현재 창의 모니터에 있는 창만, 앞에서 뒤 순서 → 제목·아이콘 → 엔진에 개수 알림
    private func loadList() {
        loadGeneration += 1
        let generation = loadGeneration
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            items = []
            FeedbackHUD.show("현재 창을 찾지 못했어요", isError: true, centeredOn: screen(containing: nil))
            engine?.listLoaded(count: 0)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        Task { [weak self] in
            // AX 호출(스냅샷·제목)은 메인 스레드 밖에서
            let loaded = await Task.detached(priority: .userInitiated) { () -> (entries: [(pid: Int32, window: AXUIElement, title: String?)], focusedFrame: CGRect)? in
                guard case .success(let snapshot) = WindowInventory.snapshot(
                    excludingPID: ownPID, frontmostPID: frontmostPID, includeHidden: true
                ), let focused = snapshot.focused, let focusedWindow = focused.axWindow else {
                    return nil
                }
                // 현재 창의 모니터에 있는 창만, 앞에서 뒤 순서
                let display = PointerMover.displayIndex(of: focused.visibleFrame, in: snapshot.displays)
                let others = snapshot.candidates
                    .filter { PointerMover.displayIndex(of: $0.visibleFrame, in: snapshot.displays) == display }
                    .sorted { $0.zIndex < $1.zIndex }
                    .compactMap { entry in entry.axWindow.map { (entry.record.pid, $0) } }
                let entries = ([(focused.record.pid, focusedWindow)] + others).map {
                    (pid: $0.0, window: $0.1, title: WindowInventory.title(of: $0.1))
                }
                return (entries, focused.visibleFrame)
            }.value

            guard let self, generation == loadGeneration else { return }
            currentFrame = loaded?.focusedFrame
            items = (loaded?.entries ?? []).enumerated().map { index, entry in
                let app = NSRunningApplication(processIdentifier: entry.pid)
                return Item(
                    pid: entry.pid, window: entry.window,
                    appName: app?.localizedName ?? "알 수 없는 앱", appIcon: app?.icon,
                    title: entry.title, isCurrent: index == 0
                )
            }
            // 고를 창이 없으면 짧게 알린다 (엔진은 목록 2개 미만이면 취소한다). 창 제목 없이 개수만 기록.
            if loaded == nil {
                diagnostics.record("창 목록 전환기: 현재 창을 찾지 못함")
                FeedbackHUD.show("현재 창을 찾지 못했어요", isError: true, centeredOn: screen(containing: currentFrame))
            } else if items.count < 2 {
                // 목록 패널이 뜰 자리(현재 창의 모니터 가운데)에 띄운다
                FeedbackHUD.show("이 모니터에 다른 창이 없어요", centeredOn: screen(containing: currentFrame))
            }
            engine?.listLoaded(count: items.count)
        }
    }

    private func activate(_ item: Item) {
        onOwnActivation?(item.pid)
        Task { [weak self] in
            let result = await WindowActivator.focus(item.window, pid: item.pid)
            guard case .failure(let failure) = result else { return }
            self?.diagnostics.record("창 목록 전환기 활성화 실패: \(failure)")
            FeedbackHUD.show("이 창으로 포커스를 옮기지 못했어요", isError: true)
        }
    }
}
