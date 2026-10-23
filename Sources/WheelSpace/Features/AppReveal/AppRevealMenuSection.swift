import SwiftUI
import WheelSpaceCore

/// 메뉴 막대의 "실행 중인 앱 선택" 묶음: 목록 열기(단축키 등록 실패 우회), 상태, 켜기·끄기.
struct AppRevealMenuSection: View {
    @ObservedObject var coordinator: AppRevealCoordinator

    var body: some View {
        Text("실행 중인 앱 선택")
        Text(statusLine)

        Button("실행 중인 앱 선택…") {
            // 메뉴가 닫힌 뒤에 패널을 띄워야 키 입력을 받는다
            DispatchQueue.main.async { coordinator.openPicker() }
        }
        .disabled(!coordinator.settings.isEnabled)

        Toggle("실행 중인 앱 선택 사용", isOn: Binding(
            get: { coordinator.settings.isEnabled },
            set: { enabled in
                var copy = coordinator.settings
                copy.isEnabled = enabled
                coordinator.update(settings: copy)
            }
        ))
    }

    private var statusLine: String {
        guard coordinator.status != .paused, let combo = coordinator.settings.shortcut else {
            return "상태: \(coordinator.stateDescription)"
        }
        return "상태: \(coordinator.stateDescription) — \(combo.displayString)"
    }
}
