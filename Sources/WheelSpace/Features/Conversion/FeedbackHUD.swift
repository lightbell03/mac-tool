import AppKit
import SwiftUI

/// 변환 결과를 화면 위쪽에 잠깐 보여주는 패널. 포커스를 가져가지 않는다(nonactivating).
@MainActor
enum FeedbackHUD {
    private static var panel: NSPanel?
    private static var hideWorkItem: DispatchWorkItem?
    private static let displayDuration: TimeInterval = 1.8

    /// centeredOn: 이 화면의 가운데에 띄운다 (창 목록 전환기 안내 등). nil이면 포인터가 있는 화면 위쪽.
    static func show(_ message: String, isError: Bool = false, centeredOn centerScreen: NSScreen? = nil) {
        let panel = panel ?? makePanel()
        Self.panel = panel

        let hosting = NSHostingView(rootView: HUDContent(message: message, isError: isError))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let visible = centerScreen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 48)
                panel.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }
        panel.orderFrontRegardless()

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { panel.orderOut(nil) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: work)
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

private struct HUDContent: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(message)
                .font(.callout)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
