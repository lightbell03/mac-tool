import SwiftUI
import WheelSpaceCore

/// 설정 창의 "한영 변환" 영역. 활성화, 방향별 단축키, 변환 후 입력 언어, 테스트 입력.
struct ConversionSettingsPane: View {
    @ObservedObject var coordinator: ConversionCoordinator

    /// 테스트 입력 — 저장하지 않는다.
    @State private var testInput = ""
    @State private var testDirection: ConversionDirection = .englishToHangul

    var body: some View {
        Form {
            introSection
            shortcutSection
            inputSourceSection
            testSection
        }
        .formStyle(.grouped)
    }

    /// 사용법 안내와 활성화 토글.
    private var introSection: some View {
        Section {
            Toggle("한영 변환 사용", isOn: binding(\.isEnabled))
            Picker("단축키 동작", selection: binding(\.triggerMode)) {
                ForEach(ConversionTriggerMode.allCases, id: \.self) { mode in
                    Text(Self.displayName(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            switch coordinator.settings.triggerMode {
            case .replaceSelection:
                Text("잘못 입력한 부분을 선택하고 단축키를 누르면 바로 바뀝니다. 복사해 둔 내용은 그대로 유지됩니다. 터미널에서는 바꾼 결과를 클립보드에만 넣습니다. 번역이 아니라 키 배열만 바꿉니다.")
                if !PermissionService.currentStatus().postEvents {
                    HStack {
                        Label("선택한 글자를 바로 바꾸려면 손쉬운 사용 권한이 필요해요", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("손쉬운 사용 설정 열기") { PermissionService.openSystemSettings(.accessibility) }
                    }
                    .font(.caption)
                }
            case .clipboardOnly:
                Text("잘못 입력한 부분만 복사한 뒤 단축키나 메뉴로 변환하고, 붙여넣어 사용하세요. 번역이 아니라 키 배열만 바꿉니다.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("문장 전체를 변환하면 정상 영어 단어도 바뀝니다.")
                Text("대문자는 Shift·Caps Lock 구분 없이 처리합니다(R→ㄲ, O→ㅒ 등).")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 방향별 단축키 기록·해제와 등록 실패 표시.
    private var shortcutSection: some View {
        Section("단축키") {
            ForEach(ConversionDirection.allCases, id: \.self) { direction in
                LabeledContent(Self.displayName(for: direction)) {
                    ShortcutRecorder(combo: shortcutBinding(direction)) { recording in
                        coordinator.setShortcutsSuspended(recording)
                    }
                }
                if let error = coordinator.shortcutErrors[direction] {
                    Label("\(error) — 메뉴에서는 계속 사용할 수 있어요", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
            Button("기본값으로") {
                var copy = coordinator.settings
                copy.englishToHangulShortcut = ConversionSettings.defaults.englishToHangulShortcut
                copy.hangulToEnglishShortcut = ConversionSettings.defaults.hangulToEnglishShortcut
                coordinator.update(settings: copy)
            }
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 변환 후 입력 언어 맞추기와 방향별 목표 입력기.
    private var inputSourceSection: some View {
        Section("변환 후 입력 언어") {
            Toggle("변환 후 입력 언어 맞추기", isOn: binding(\.switchInputSourceAfterConversion))
            if coordinator.settings.switchInputSourceAfterConversion {
                inputSourcePicker(
                    "한글 결과의 입력기",
                    direction: .englishToHangul,
                    keyPath: \.koreanInputSourceID,
                    emptyMessage: "설치된 한국어 입력기가 없어요"
                )
                inputSourcePicker(
                    "영문 결과의 입력기",
                    direction: .hangulToEnglish,
                    keyPath: \.englishInputSourceID,
                    emptyMessage: "설치된 영문 입력기가 없어요"
                )
                Text("변환에 성공했을 때만 바꾸며, 이미 그 입력기면 그대로 둡니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    @ViewBuilder
    private func inputSourcePicker(
        _ title: String,
        direction: ConversionDirection,
        keyPath: WritableKeyPath<ConversionSettings, String?>,
        emptyMessage: String
    ) -> some View {
        let candidates = coordinator.inputSourceCandidates(for: direction)
        if candidates.isEmpty {
            LabeledContent(title, value: emptyMessage)
        } else {
            Picker(title, selection: binding(keyPath)) {
                Text("\(candidates[0].name) (기본)").tag(String?.none)
                ForEach(candidates) { source in
                    Text(source.name).tag(String?.some(source.id))
                }
            }
            if let saved = coordinator.settings[keyPath: keyPath], !candidates.contains(where: { $0.id == saved }) {
                Label("선택한 입력기를 찾을 수 없어요 — 다시 지정하세요", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }
    }

    /// 클립보드를 건드리지 않는 변환 미리보기.
    private var testSection: some View {
        Section("테스트") {
            Picker("방향", selection: $testDirection) {
                ForEach(ConversionDirection.allCases, id: \.self) { direction in
                    Text(Self.displayName(for: direction)).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            TextField("테스트 입력", text: $testInput, prompt: Text("예: dkssudgktpdy"))
            LabeledContent("결과") {
                Text(coordinator.preview(testInput, direction: testDirection))
                    .textSelection(.enabled)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ConversionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = coordinator.settings
                copy[keyPath: keyPath] = newValue
                coordinator.update(settings: copy)
            }
        )
    }

    private func shortcutBinding(_ direction: ConversionDirection) -> Binding<KeyCombo?> {
        Binding(
            get: { coordinator.settings.shortcut(for: direction) },
            set: { newValue in
                var copy = coordinator.settings
                copy.setShortcut(newValue, for: direction)
                coordinator.update(settings: copy)
            }
        )
    }

    static func displayName(for mode: ConversionTriggerMode) -> String {
        switch mode {
        case .replaceSelection: return "선택한 글자 바로 바꾸기"
        case .clipboardOnly: return "복사한 내용만 변환"
        }
    }

    static func displayName(for direction: ConversionDirection) -> String {
        switch direction {
        case .englishToHangul: return "영문 → 한글"
        case .hangulToEnglish: return "한글 → 영문"
        }
    }
}
