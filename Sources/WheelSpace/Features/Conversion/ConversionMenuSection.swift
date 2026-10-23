import SwiftUI
import WheelSpaceCore

/// 메뉴 막대의 "한영 변환" 묶음: 양방향 변환, 직전 클립보드 복구.
/// 메뉴 항목 선택은 앱을 활성화하지 않으므로 원래 작업 앱의 포커스가 유지된다.
struct ConversionMenuSection: View {
    @ObservedObject var coordinator: ConversionCoordinator

    var body: some View {
        Text("한영 변환")
            .onAppear { coordinator.refreshRestoreAvailability() }

        if coordinator.settings.isEnabled {
            // 메뉴의 keyboardShortcut은 앱이 활성일 때만 동작해 쓰지 않고, 전역 단축키를 제목에 표시한다.
            Button(title("\(target) 영문 → 한글", .englishToHangul)) {
                coordinator.convert(.englishToHangul)
            }
            .disabled(coordinator.isBusy)

            Button(title("\(target) 한글 → 영문", .hangulToEnglish)) {
                coordinator.convert(.hangulToEnglish)
            }
            .disabled(coordinator.isBusy)

            // 바로 바꾸기에서는 원래 클립보드를 이미 되돌리므로, 터미널에서 클립보드에 넣은 경우에만 복구할 것이 생긴다
            if coordinator.settings.triggerMode == .clipboardOnly || coordinator.canRestore {
                Button("직전 클립보드 복구") {
                    coordinator.restorePrevious()
                }
                .disabled(!coordinator.canRestore)
            }
        } else {
            Text("꺼짐 — 설정에서 켤 수 있어요")
        }
    }

    private var target: String {
        coordinator.settings.triggerMode == .replaceSelection ? "선택한 글자" : "클립보드"
    }

    private func title(_ base: String, _ direction: ConversionDirection) -> String {
        guard let combo = coordinator.settings.shortcut(for: direction) else { return base }
        return "\(base)    \(combo.displayString)"
    }
}
