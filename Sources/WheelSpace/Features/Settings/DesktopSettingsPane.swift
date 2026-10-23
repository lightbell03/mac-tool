import AppKit
import SwiftUI
import WheelSpaceCore

/// 설정 창의 "데스크탑 전환" 영역. 시작 안내·권한·이동 테스트·동작 설정.
struct DesktopSettingsPane: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            introSection
            permissionSection
            testSection
            behaviorSection
        }
        .formStyle(.grouped)
    }

    /// "Option을 누른 채 휠을 굴려 데스크탑을 이동하세요." (선택된 보조키 이름 반영)
    private var introSection: some View {
        Section {
            Text("\(Self.shortName(for: controller.settings.modifierKey))을 누른 채 \(Self.gesturePhrase(for: controller.settings.scrollAxis)) 데스크탑을 이동하세요.")
                .font(.headline)
            LabeledContent("현재 상태", value: controller.stateDescription)
            if controller.state == .paused {
                Text("일시정지 중 — 마우스는 평소대로 동작합니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 권한 상태 3종과 누락 권한만 안내. 요청·시스템 설정 열기·다시 확인·재실행 버튼.
    private var permissionSection: some View {
        Section("권한") {
            if !controller.permissions.isSufficient {
                Text("휠 입력을 감지하고 데스크탑 이동 단축키를 보내려면 권한이 필요합니다.")
            }
            permissionRow("입력 모니터링", granted: controller.permissions.listenEvents)
            permissionRow("손쉬운 사용 (이벤트 전송)", granted: controller.permissions.postEvents)
            permissionRow("손쉬운 사용 (접근성 API)", granted: controller.permissions.accessibility)

            if case .tapError(let message) = controller.state {
                VStack(alignment: .leading, spacing: 4) {
                    Label("현재 환경에서 입력 감지를 시작하지 못했습니다. 권한을 확인한 뒤 다시 시도하세요.",
                          systemImage: "exclamationmark.triangle")
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("입력 감지 다시 시도") { controller.retry() }
            }

            HStack {
                if !controller.permissions.isSufficient {
                    Button("권한 요청") { controller.requestPermissions() }
                }
                Button("입력 모니터링 설정 열기") { controller.openPermissionSettings(.inputMonitoring) }
                Button("손쉬운 사용 설정 열기") { controller.openPermissionSettings(.accessibility) }
            }
            HStack {
                Button("다시 확인") { controller.recheckPermissions() }
                Button("앱 다시 실행") { controller.relaunch() }
                    .help("권한을 허용했는데도 반영되지 않으면 앱을 다시 실행하세요.")
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        LabeledContent(title) {
            Label(granted ? "허용됨" : "필요", systemImage: granted ? "checkmark.circle" : "xmark.circle")
        }
        .accessibilityElement(children: .combine)
    }

    /// 왼쪽/오른쪽 이동 테스트 버튼과 결과, Mission Control 단축키 안내.
    private var testSection: some View {
        Section("이동 테스트") {
            HStack {
                Button("← 왼쪽으로 이동") { controller.testSwitch(.left) }
                Button("오른쪽으로 이동 →") { controller.testSwitch(.right) }
            }
            if let result = controller.lastTestResult {
                Text(result).foregroundStyle(.secondary)
            }
            Text("데스크탑이 두 개 이상인지 확인하세요. macOS 키보드 단축키의 Mission Control에서 왼쪽·오른쪽 Spaces 이동을 켜 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 보조키·방향 반전·최소 간격·감도.
    private var behaviorSection: some View {
        Section("동작") {
            Toggle("전환 기능 사용", isOn: binding(\.isEnabled))

            Picker("보조키", selection: binding(\.modifierKey)) {
                ForEach(ModifierKey.allCases, id: \.self) { key in
                    Text(Self.displayName(for: key)).tag(key)
                }
            }
            if controller.settings.modifierKey != .option {
                Text("Command·Control·Shift + 휠은 다른 앱의 확대·가로 스크롤 등과 겹칠 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("전환에 쓸 휠", selection: binding(\.scrollAxis)) {
                ForEach(ScrollAxis.allCases, id: \.self) { axis in
                    Text(Self.displayName(for: axis)).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            if controller.settings.scrollAxis != .vertical {
                Text("휠 왼쪽 = 왼쪽 데스크탑, 오른쪽 = 오른쪽. 보조키를 누르지 않은 좌우 스크롤은 그대로 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("방향 반전", isOn: binding(\.reverseDirection))

            Picker("뒤로·앞으로 버튼", selection: binding(\.mouseButtonMode)) {
                ForEach(MouseButtonMode.allCases, id: \.self) { mode in
                    Text(Self.displayName(for: mode)).tag(mode)
                }
            }
            if controller.settings.mouseButtonMode != .off {
                Text("뒤로 = 왼쪽 데스크탑, 앞으로 = 오른쪽 데스크탑.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if controller.settings.mouseButtonMode == .withoutModifier {
                Label("브라우저·Finder의 뒤로·앞으로 기능 대신 데스크탑을 이동합니다.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }

            LabeledContent("전환 최소 간격") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(controller.settings.minimumIntervalMs) },
                            set: { newValue in
                                var copy = controller.settings
                                copy.minimumIntervalMs = Int(newValue.rounded())
                                controller.update(settings: copy)
                            }
                        ),
                        in: Double(AppSettings.minimumIntervalRange.lowerBound)...Double(AppSettings.minimumIntervalRange.upperBound),
                        step: 50
                    )
                    .accessibilityValue("\(controller.settings.minimumIntervalMs)밀리초")
                    Text("\(controller.settings.minimumIntervalMs)ms")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }

            Picker("휠 감도", selection: binding(\.sensitivity)) {
                ForEach(Sensitivity.allCases, id: \.self) { value in
                    Text(Self.displayName(for: value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// AppSettings 필드별 Binding. set 시 controller.update(settings:)로 저장·반영.
    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = controller.settings
                copy[keyPath: keyPath] = newValue
                controller.update(settings: copy)
            }
        )
    }

    static func displayName(for key: ModifierKey) -> String {
        switch key {
        case .option: return "Option (⌥)"
        case .control: return "Control (⌃)"
        case .command: return "Command (⌘)"
        case .shift: return "Shift (⇧)"
        }
    }

    private static func gesturePhrase(for axis: ScrollAxis) -> String {
        switch axis {
        case .vertical: return "휠을 굴려"
        case .horizontal: return "휠을 좌우로 밀어"
        case .both: return "휠을 굴리거나 좌우로 밀어"
        }
    }

    private static func shortName(for key: ModifierKey) -> String {
        switch key {
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }

    static func displayName(for axis: ScrollAxis) -> String {
        switch axis {
        case .vertical: return "세로 휠"
        case .horizontal: return "좌우 휠"
        case .both: return "둘 다"
        }
    }

    static func displayName(for mode: MouseButtonMode) -> String {
        switch mode {
        case .off: return "끔"
        case .withModifier: return "보조키와 함께"
        case .withoutModifier: return "보조키 없이"
        }
    }

    static func displayName(for sensitivity: Sensitivity) -> String {
        switch sensitivity {
        case .low: return "낮음"
        case .normal: return "보통"
        case .high: return "높음"
        }
    }
}
