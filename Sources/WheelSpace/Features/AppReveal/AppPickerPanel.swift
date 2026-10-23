import AppKit
import SwiftUI
import WheelSpaceCore

/// 실행 중인 앱 선택 패널: 검색란 + 앱 목록(아이콘·이름·상태). ↑↓ 이동, Return 확정, Esc 취소.
/// 검색어를 타이핑해야 해서 키 입력을 받는 패널이다 — 열 때 WheelSpace를 잠깐 활성화하고, 닫을 때 확정·취소에 따라 대상을 앞으로 보낸다.
@MainActor
enum AppPickerPanel {
    private static var panel: KeyablePanel?
    private static var state: PickerState?
    /// 패널이 열려 있는 동안만 거는 로컬 키 감시 (↑↓·Return·Esc)
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static var onSelect: ((AppPickerEntry) -> Void)?
    private static var onCancel: (() -> Void)?

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// entries: 정렬된 목록, onSelect: Return, onCancel: Esc·바깥 클릭·포커스 잃음
    static func show(
        entries: [AppPickerEntry],
        onSelect: @escaping (AppPickerEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        Self.onSelect = onSelect
        Self.onCancel = onCancel
        let state = PickerState(model: AppPickerModel(entries: entries))
        Self.state = state

        let panel = panel ?? makePanel()
        Self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let hosting = NSHostingView(rootView: PickerView(state: state, maxHeight: visible.height * 0.6))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        // 가운데보다 조금 위
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // 검색란에 입력하려면 이 앱이 앞에 와서 패널이 키 창이 돼야 한다 (macOS 14+는 새 활성화 API)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === Self.panel else { return event }
            switch event.keyCode {
            case KeyCode.down: Self.state?.model.move(by: 1)
            case KeyCode.up: Self.state?.model.move(by: -1)
            case KeyCode.returnKey, KeyCode.keypadEnter: confirm()
            case KeyCode.escape: cancel()
            default: return event
            }
            return nil
        }
        // 다른 곳을 클릭하는 등 키 창에서 벗어나면 취소
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            Task { @MainActor in cancel() }
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "실행 중인 앱 선택", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// 진단용: 패널이 키 입력을 받는 창인지
    static var isKey: Bool {
        panel?.isKeyWindow ?? false
    }

    static func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        state = nil
        onSelect = nil
        onCancel = nil
    }

    /// 마우스로 줄을 고르면 바로 확정
    fileprivate static func confirm(at index: Int) {
        state?.model.select(index)
        confirm()
    }

    private static func confirm() {
        guard let entry = state?.model.selected, let onSelect else { return }
        close()
        onSelect(entry)
    }

    private static func cancel() {
        guard let onCancel else { return }
        close()
        onCancel()
    }

    private static func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// 제목 없는 패널은 기본으로 키 창이 되지 못한다 — 검색란 입력을 받으려고 허용한다
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 패널과 키 감시가 함께 바꾸는 상태
@MainActor
private final class PickerState: ObservableObject {
    @Published var model: AppPickerModel

    init(model: AppPickerModel) {
        self.model = model
    }
}

/// 검색란 + 목록. 줄: 앱 아이콘 + 이름(+ 구별 표시) + 상태(숨김 등). VoiceOver 레이블은 "앱 이름, 상태".
private struct PickerView: View {
    @ObservedObject var state: PickerState
    let maxHeight: CGFloat
    @FocusState private var searchFocused: Bool

    private static let rowHeight: CGFloat = 40
    private static let width: CGFloat = 460

    var body: some View {
        VStack(spacing: 6) {
            TextField("앱 이름 검색", text: Binding(
                get: { state.model.query },
                set: { state.model.setQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .padding([.horizontal, .top], 10)

            if state.model.visible.isEmpty {
                Text("일치하는 앱이 없어요")
                    .foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            } else {
                list
            }
            Text("↑↓ 고르기 · Return 열기 · Esc 취소")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { searchFocused = true }
    }

    private var list: some View {
        let rows = Array(state.model.visible.enumerated())
        let height = min(maxHeight, CGFloat(rows.count) * (Self.rowHeight + 2) + 8)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.element.pid) { index, entry in
                        row(entry, isSelected: index == state.model.selection)
                            .id(entry.pid)
                            .contentShape(Rectangle())
                            .onTapGesture { AppPickerPanel.confirm(at: index) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: height)
            .onChange(of: state.model.selection) { _ in
                if let selected = state.model.selected {
                    proxy.scrollTo(selected.pid, anchor: .center)
                }
            }
        }
    }

    private func row(_ entry: AppPickerEntry, isSelected: Bool) -> some View {
        let app = NSRunningApplication(processIdentifier: entry.pid)
        return HStack(spacing: 10) {
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app").resizable().scaledToFit()
                }
            }
            .frame(width: 26, height: 26)
            Text(entry.name)
                .font(.callout)
            if let disambiguation = entry.disambiguation {
                Text(disambiguation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isHidden {
                Text("숨김")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isHidden ? "\(entry.name), 숨김" : entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
