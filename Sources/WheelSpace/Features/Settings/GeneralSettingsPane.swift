import SwiftUI

/// 설정 창의 "일반" 영역. 로그인 시 실행, 전체 설정 초기화, 진단 정보 복사.
struct GeneralSettingsPane: View {
    @ObservedObject var controller: AppController
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section("실행") {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { controller.loginItemEnabled },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }
            Section("관리") {
                HStack {
                    Button("설정 초기화…") { isConfirmingReset = true }
                    Button("상태 진단 정보 복사") { controller.copyDiagnostics() }
                }
                Text("진단 정보에는 앱·OS 버전, 권한, 기능 상태만 들어갑니다. 입력·클립보드 내용은 포함하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("모든 설정을 초기화할까요?", isPresented: $isConfirmingReset) {
            Button("초기화", role: .destructive) { controller.resetSettings() }
        } message: {
            Text("데스크탑 전환과 한영 변환의 설정·단축키가 모두 기본값으로 돌아갑니다. 로그인 시 실행은 그대로 둡니다.")
        }
    }
}
