import AppKit
import SwiftUI

/// 키보드 포인터 포인터 모드(고정 모드) 토스트. 켜져 있는 동안 화면 위쪽에 계속 떠 있고,
/// 꺼지면 "해제" 문구로 바뀌었다가 잠시 뒤 사라진다.
/// 포커스를 가져가지 않고(nonactivating) 마우스 이벤트도 받지 않는다. FeedbackHUD와 같은 패널 설정.
@MainActor
enum PointerModeIndicator {
    private static var panel: NSPanel?
    /// "해제" 문구를 보여 준 뒤 사라지기까지 (다시 켜면 취소)
    private static var hideWorkItem: DispatchWorkItem?
    private static let releasedDuration: TimeInterval = 1.2
    private static let fadeDuration: TimeInterval = 0.25

    /// 배경 불투명도 (마지막으로 show·preview에 받은 값을 해제 문구에도 쓴다)
    private static var opacity: Double = 0.6
    /// 실제 포인터 모드 토스트가 떠 있는지 (미리보기가 덮어쓰지 않게)
    private static var isShowingLocked = false
    private static let previewDuration: TimeInterval = 1.0
    /// 사라지기 예약 세대. 다시 띄우면(show·preview·새 예약) 올라가, 이전 예약의 마무리(orderOut)를 무효로 만든다.
    private static var fadeGeneration = 0

    /// 표시 (이미 떠 있으면 문구만 바꾼다). insertKeyLabel: 입력 모드로 돌아가는 키 ("I")
    static func show(insertKeyLabel: String, opacity: Double) {
        Self.opacity = opacity
        isShowingLocked = true
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeGeneration += 1
        present(ToastContent(phase: .locked, insertKeyLabel: insertKeyLabel, opacity: opacity))
        announce("포인터 모드")
    }

    /// 앱 단축키로 잠깐 해제: 다시 돌아올 때까지 "잠깐 해제" 문구로 떠 있다 (완전히 꺼지면 hide가 해제 문구로 바꾼다)
    static func showSuspended(detail: String, opacity: Double) {
        Self.opacity = opacity
        isShowingLocked = true
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeGeneration += 1
        present(ToastContent(phase: .suspended, insertKeyLabel: detail, opacity: opacity))
    }

    /// "포인터 모드 해제"로 바꾸고 잠시 뒤 사라진다. 떠 있지 않으면 아무것도 하지 않는다.
    static func hide() {
        guard isShowingLocked, panel?.isVisible == true else { return }
        isShowingLocked = false
        present(ToastContent(phase: .released, insertKeyLabel: "", opacity: opacity))
        announce("포인터 모드 해제")
        fadeOut(after: releasedDuration)
    }

    /// 설정 화면 미리보기: 켜짐 모양을 잠깐 띄웠다가 해제 문구 없이 사라진다 (슬라이더를 움직일 때)
    static func preview(insertKeyLabel: String, opacity: Double) {
        // 실제 포인터 모드 토스트는 건드리지 않는다 (설정 창을 열면 꺼지므로 보통은 해당 없음)
        guard !isShowingLocked else { return }
        Self.opacity = opacity
        present(ToastContent(phase: .locked, insertKeyLabel: insertKeyLabel, opacity: opacity))
        fadeOut(after: previewDuration)
    }

    /// delay 뒤 서서히 사라진다. 그 사이 다시 띄우면(show·preview) 이전 예약은 취소된다.
    private static func fadeOut(after delay: TimeInterval) {
        guard let panel else { return }
        hideWorkItem?.cancel()
        fadeGeneration += 1
        let generation = fadeGeneration
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // 사라지는 중에 다시 띄웠으면 그대로 둔다
                Task { @MainActor in
                    guard generation == fadeGeneration else { return }
                    panel.orderOut(nil)
                    hideWorkItem = nil
                }
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 포인터가 있는 화면의 위쪽 가운데에 내용을 놓고 띄운다
    private static func present(_ content: ToastContent) {
        let panel = panel ?? makePanel()
        Self.panel = panel

        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 48)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
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

/// 켜짐: "포인터 모드 · I 입력", 잠깐 해제: "포인터 모드 잠깐 해제 · 보조키를 떼면 돌아옴", 꺼짐: "포인터 모드 해제"
private struct ToastContent: View {
    enum Phase {
        case locked
        case suspended
        case released
    }

    let phase: Phase
    let insertKeyLabel: String
    /// 배경 불투명도 (글자는 항상 불투명)
    let opacity: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase == .released ? "keyboard" : "cursorarrow.motionlines")
            Text(title)
                .font(.callout)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            // 창 배경색에 색을 섞은 단색을 불투명도대로 칠한다 (켜짐은 강조색, 해제는 회색).
            // 흐림(material)은 거의 불투명하게 보여 투명도가 드러나지 않아 쓰지 않는다.
            let shape = RoundedRectangle(cornerRadius: 10)
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                shape.fill(tint.opacity(0.35))
            }
            .compositingGroup()
            .opacity(opacity)
            shape.strokeBorder(tint.opacity(min(1, opacity + 0.2)), lineWidth: 1)
        }
    }

    private var title: String {
        switch phase {
        case .locked: return "포인터 모드"
        case .suspended: return "포인터 모드 잠깐 해제"
        case .released: return "포인터 모드 해제"
        }
    }

    private var detail: String? {
        switch phase {
        case .locked: return "\(insertKeyLabel) 입력"
        // 잠깐 해제는 돌아오는 방법을 insertKeyLabel 자리에 받는다
        case .suspended: return insertKeyLabel
        case .released: return nil
        }
    }

    private var tint: Color {
        switch phase {
        case .locked: return .accentColor
        case .suspended: return .orange
        case .released: return .gray
        }
    }
}
