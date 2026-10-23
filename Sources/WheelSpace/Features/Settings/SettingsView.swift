import AppKit
import SwiftUI
import WheelSpaceCore

/// 설정 창의 기능별 영역. 사이드바 항목 순서 = 선언 순서.
enum SettingsPane: String, CaseIterable, Identifiable {
    case desktop
    case conversion
    case windowFocus
    case keyPointer
    case appReveal
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "데스크탑 전환"
        case .conversion: return "한영 변환"
        case .windowFocus: return "창 포커스 이동"
        case .keyPointer: return "키보드 포인터"
        case .appReveal: return "실행 중인 앱"
        case .general: return "일반"
        }
    }

    var systemImage: String {
        switch self {
        case .desktop: return "rectangle.split.3x1"
        case .conversion: return "character.bubble"
        case .windowFocus: return "macwindow.on.rectangle"
        case .keyPointer: return "cursorarrow.motionlines"
        case .appReveal: return "square.stack.3d.up"
        case .general: return "gearshape"
        }
    }
}

/// 설정 창 선택 상태. 메뉴에서 특정 영역을 바로 열 수 있게 창 밖에서도 바꾼다.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsPane = .desktop
}

/// 설정 창 루트: 왼쪽 사이드바(기능 목록) + 오른쪽 선택한 기능의 설정.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { navigation.selection },
                set: { if let pane = $0 { navigation.selection = pane } }
            )) { pane in
                SidebarRow(
                    pane: pane,
                    controller: controller,
                    conversion: controller.conversion,
                    windowFocus: controller.windowFocus,
                    keyPointer: controller.keyPointer,
                    appReveal: controller.appReveal
                )
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail(for: navigation.selection)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        Group {
            switch pane {
            case .desktop: DesktopSettingsPane(controller: controller)
            case .conversion: ConversionSettingsPane(coordinator: controller.conversion)
            case .windowFocus: WindowFocusSettingsPane(coordinator: controller.windowFocus, controller: controller)
            case .keyPointer: KeyPointerSettingsPane(controller: controller.keyPointer, app: controller)
            case .appReveal: AppRevealSettingsPane(coordinator: controller.appReveal, controller: controller)
            case .general: GeneralSettingsPane(controller: controller)
            }
        }
        .navigationTitle(pane.title)
    }
}

/// 사이드바 한 줄: 기능 이름 + 상태 문구(색이 아닌 문구로 구분).
private struct SidebarRow: View {
    let pane: SettingsPane
    @ObservedObject var controller: AppController
    @ObservedObject var conversion: ConversionCoordinator
    @ObservedObject var windowFocus: FocusCoordinator
    @ObservedObject var keyPointer: KeyPointerController
    @ObservedObject var appReveal: AppRevealCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(pane.title, systemImage: pane.systemImage)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String? {
        switch pane {
        case .desktop: return controller.stateDescription
        case .conversion: return conversion.settings.isEnabled ? "켜짐" : "꺼짐"
        case .windowFocus: return windowFocus.stateDescription
        case .keyPointer: return keyPointer.stateDescription
        case .appReveal: return appReveal.stateDescription
        case .general: return nil
        }
    }
}

/// LSUIElement 앱에서 설정 창을 열고 앞으로 가져온다. 창은 하나만 유지한다.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let navigation = SettingsNavigation()

    /// pane을 주면 해당 영역을 선택한 채로 연다.
    static func show(controller: AppController, pane: SettingsPane? = nil) {
        // 설정 창을 여는 동안 포인터 이동·드래그 중지
        controller.keyPointer.interrupt(reason: "설정 창 열기")
        if let pane {
            navigation.selection = pane
        }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, navigation: navigation))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "WheelSpace 설정"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            newWindow.toolbarStyle = .unified
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 760, height: 600))
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
