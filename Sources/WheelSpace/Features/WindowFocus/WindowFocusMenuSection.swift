import SwiftUI
import WheelSpaceCore

/// 메뉴 막대의 "창 포커스 이동" 묶음: 상태와 켜기·끄기.
/// 방향 이동은 단축키로만 쓴다(메뉴를 여는 순간 포커스 기준이 메뉴로 바뀌기 때문).
struct WindowFocusMenuSection: View {
    @ObservedObject var coordinator: FocusCoordinator

    var body: some View {
        Text("창 포커스 이동")
        Text(statusLine)

        Toggle("창 포커스 이동 사용", isOn: Binding(
            get: { coordinator.settings.isEnabled },
            set: { enabled in
                var copy = coordinator.settings
                copy.isEnabled = enabled
                coordinator.update(settings: copy)
            }
        ))
    }

    private var statusLine: String {
        guard coordinator.status == .ready || coordinator.status == .moving else {
            return "상태: \(coordinator.stateDescription)"
        }
        let keys = FocusDirection.allCases.compactMap { coordinator.settings.shortcut(for: $0)?.displayString }
        return keys.isEmpty ? "상태: 사용 중 (단축키 없음)" : "상태: 사용 중 — \(keys.joined(separator: " "))"
    }
}
