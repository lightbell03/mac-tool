import AppKit
import SwiftUI

/// 창 목록 전환기 패널: 현재 모니터 가운데에 앱 아이콘·앱 이름·창 제목 목록을 띄우고 선택 줄을 강조한다.
/// 포커스를 가져가지 않고(nonactivating) 마우스 이벤트도 받지 않는다 — 키 입력은 엔진이 이벤트 탭으로 처리한다.
@MainActor
enum WindowSwitcherPanel {
    struct Row: Identifiable {
        let id: Int
        let appName: String
        let appIcon: NSImage?
        let title: String?
        let isCurrent: Bool
    }

    private static var panel: NSPanel?
    /// 화면 높이 중 패널이 차지할 수 있는 최대 비율 (넘치면 스크롤)
    private static let maxHeightRatio: CGFloat = 0.7

    /// 띄우거나(처음) 선택만 옮긴다
    static func show(rows: [Row], selection: Int, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        Self.panel = panel

        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = visible.height * maxHeightRatio
        let hosting = NSHostingView(rootView: SwitcherList(rows: rows, selection: selection, maxHeight: maxHeight))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if rows.indices.contains(selection) {
            let row = rows[selection]
            let message = [row.appName, row.title].compactMap { $0 }.joined(separator: ", ")
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

/// 목록: 줄마다 앱 아이콘 + 앱 이름 + 창 제목(한 줄, 넘치면 …). 선택 줄은 강조색 배경, 현재 창 줄은 "현재" 표시.
private struct SwitcherList: View {
    let rows: [WindowSwitcherPanel.Row]
    let selection: Int
    let maxHeight: CGFloat

    private static let rowHeight: CGFloat = 48
    private static let width: CGFloat = 420

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(8)
            }
            .frame(width: Self.width, height: min(maxHeight, CGFloat(rows.count) * (Self.rowHeight + 2) + 16))
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func rowView(_ row: WindowSwitcherPanel.Row) -> some View {
        let isSelected = row.id == selection
        return HStack(spacing: 10) {
            Group {
                if let icon = row.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit()
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.appName)
                        .font(.callout.weight(.semibold))
                    if row.isCurrent {
                        Text("현재")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let title = row.title {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
