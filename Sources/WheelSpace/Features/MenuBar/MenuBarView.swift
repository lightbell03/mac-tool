import SwiftUI

/// 메뉴 막대 드롭다운. 상태 문구, 켜기·끄기, 설정, 권한 확인, 종료.
struct MenuBarView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Text("데스크탑 전환")
        Text(statusLine)

        Toggle("데스크탑 전환 사용", isOn: Binding(
            get: { controller.settings.isEnabled },
            set: { controller.setEnabled($0) }
        ))

        if case .tapError = controller.state {
            Button("입력 감지 다시 시도") { controller.retry() }
        }

        Divider()

        ConversionMenuSection(coordinator: controller.conversion)

        Divider()

        WindowFocusMenuSection(coordinator: controller.windowFocus)

        Divider()

        KeyPointerMenuSection(controller: controller.keyPointer)

        Divider()

        AppRevealMenuSection(coordinator: controller.appReveal)

        Divider()

        Button("설정…") {
            SettingsWindow.show(controller: controller)
        }
        .keyboardShortcut(",")

        Button("권한 및 동작 확인") {
            controller.recheckPermissions()
            SettingsWindow.show(controller: controller, pane: .desktop)
        }

        Divider()

        Button("WheelSpace 종료") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.state {
        case .paused: return "일시정지 중 — 마우스는 평소대로 동작합니다."
        default: return "상태: \(controller.stateDescription)"
        }
    }

    /// 메뉴 막대 아이콘. 상태별로 모양이 다르다.
    static func iconName(for state: ServiceState) -> String {
        switch state {
        case .running: return "rectangle.split.3x1"
        case .paused: return "pause.rectangle"
        case .needsPermission: return "lock.rectangle"
        case .tapError: return "exclamationmark.triangle"
        case .starting: return "ellipsis.rectangle"
        }
    }
}

/// 메뉴 막대 아이콘. 상태 변화를 반영하려고 별도 뷰로 controller를 관찰한다.
struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    /// 고정 모드 표시 (AppController와 별도로 바뀐다)
    @ObservedObject var keyPointer: KeyPointerController

    var body: some View {
        // 앱 단축키로 잠깐 해제된 동안도 포인터 모드 아이콘 그대로
        if keyPointer.isLocked || keyPointer.isSuspended {
            Image(systemName: "cursorarrow.motionlines")
                .accessibilityLabel("WheelSpace: 키보드 포인터 포인터 모드")
        } else {
            Image(systemName: MenuBarView.iconName(for: controller.state))
                .accessibilityLabel("WheelSpace: \(controller.stateDescription)")
        }
    }
}
