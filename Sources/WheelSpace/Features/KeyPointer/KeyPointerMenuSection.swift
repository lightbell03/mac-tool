import SwiftUI
import WheelSpaceCore

/// 메뉴 막대의 "키보드 포인터" 묶음: 상태(드래그 중 구분), 켜기·끄기.
struct KeyPointerMenuSection: View {
    @ObservedObject var controller: KeyPointerController

    var body: some View {
        Text("키보드 포인터")
            // 메뉴를 연 동안 포인터가 움직이지 않게
            .onAppear { controller.interrupt(reason: "메뉴 막대 메뉴 열기") }
        Text(statusLine)

        Toggle("키보드 포인터 사용", isOn: Binding(
            get: { controller.settings.isEnabled },
            set: { enabled in
                var copy = controller.settings
                copy.isEnabled = enabled
                controller.update(settings: copy)
            }
        ))

        // 입력란 클릭으로 원치 않게 풀렸을 때: 다시 켜고 그 영역을 앞으로 제외
        if let unlocked = controller.lastAutoUnlock {
            Button("방금 해제 취소하고 이 영역 제외") { controller.excludeLastAutoUnlock(allBrowsers: false) }
            if unlocked.isWebContent {
                Button("방금 해제 취소하고 모든 브라우저에서 제외") { controller.excludeLastAutoUnlock(allBrowsers: true) }
            }
        }
        if controller.status == .tapError {
            Button("입력 감지 다시 시도") { controller.retry() }
        }
    }

    private var statusLine: String {
        if controller.isDragging {
            return "상태: 드래그 중 — \(controller.settings.shortcut.dragKey.keyLabel)를 떼거나 Esc로 놓기"
        }
        guard controller.status == .running else { return "상태: \(controller.stateDescription)" }
        let base = controller.settings.shortcut.comboSymbol()
        return "상태: 사용 중 — \(base) + 방향키"
    }
}
