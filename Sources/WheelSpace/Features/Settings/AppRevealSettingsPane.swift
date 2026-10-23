import SwiftUI
import WheelSpaceCore

/// 설정 창의 "실행 중인 앱" 영역: 사용, 권한, 단축키, 선택 후 동작 옵션, 한계 안내.
struct AppRevealSettingsPane: View {
    @ObservedObject var coordinator: AppRevealCoordinator
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle("실행 중인 앱 선택 사용", isOn: binding(\.isEnabled))
                LabeledContent("현재 상태", value: coordinator.stateDescription)
                if let result = coordinator.lastResult {
                    LabeledContent("마지막 결과", value: result)
                }
                Text("단축키로 실행 중인 앱 목록을 열고, 이름을 검색하거나 ↑↓로 골라 Return을 누르면 그 앱의 창을 보여 줍니다. 숨긴 앱, 최소화된 창만 있는 앱, 창을 모두 닫은 앱도 고를 수 있습니다.")
                    .foregroundStyle(.secondary)
            }

            if coordinator.status == .needsPermission {
                Section("권한") {
                    Label("창 복원과 창 확인에는 손쉬운 사용 권한이 필요합니다. 없으면 앱을 앞으로 가져오기만 합니다.", systemImage: "lock")
                    HStack {
                        Button("권한 요청") { controller.requestPermissions() }
                        Button("손쉬운 사용 설정 열기") { controller.openPermissionSettings(.accessibility) }
                        Button("다시 확인") { controller.recheckPermissions() }
                    }
                }
            }

            Section("단축키") {
                LabeledContent("목록 열기") {
                    ShortcutRecorder(combo: binding(\.shortcut)) { recording in
                        coordinator.setShortcutsSuspended(recording)
                    }
                }
                if let error = coordinator.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                Text("메뉴 막대의 \"실행 중인 앱 선택…\"으로도 열 수 있어요. 처음에는 직전 앱이 선택돼 있어 바로 Return을 누르면 직전 앱으로 갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!coordinator.settings.isEnabled)

            includedAppsSection

            Section("선택한 뒤") {
                Toggle("숨긴 앱(⌘H)이면 숨김 해제", isOn: binding(\.unhideOnSelect))
                Toggle("최소화된 창만 있으면 하나 복원", isOn: binding(\.restoreMinimized))
                Toggle("창이 없으면 다시 열기 요청", isOn: binding(\.reopenWhenNoWindow))
                Text("다시 열기는 Dock 아이콘을 클릭했을 때와 같은 요청이고, 창을 열지는 앱이 정합니다. 반응하지 않는 앱에 다른 명령(⌘N 등)을 보내지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!coordinator.settings.isEnabled)

            Section("알아 둘 점") {
                Text("• 화면에 창이 없으면 Dock 아이콘을 클릭했을 때와 같은 다시 열기를 보냅니다. 창이 다른 데스크탑에 있으면 macOS가 그리로 옮겨 주고, 앱은 새 창을 만들지 않습니다.")
                Text("• 창 상태를 확인하지 못하면 \"창 없음\"으로 보지 않고 앱만 앞으로 가져옵니다.")
                Text("• 닫은 문서·브라우저 탭은 복구되지 않습니다. 기본 창을 보여 주는 것까지만 합니다.")
                Text("• 선택하는 순간 앱이 종료되면 다시 실행하지 않습니다. 다만 다시 열기 요청과 종료가 거의 동시에 일어나면 앱이 새로 실행될 수 있습니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    /// 목록에 함께 보일 메뉴 막대 앱: 목록(아이콘·이름·빼기) + 실행 중인 메뉴 막대 앱에서 추가 + 응용 프로그램에서 고르기
    private var includedAppsSection: some View {
        let included = coordinator.settings.includedAccessoryApps
        return Section("목록에 함께 보일 앱") {
            ForEach(included, id: \.self) { bundleID in
                HStack(spacing: 6) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(KeyPointerSettingsPane.appName(for: bundleID))
                    Spacer()
                    Button {
                        updateIncluded { $0.removeAll { $0 == bundleID } }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(KeyPointerSettingsPane.appName(for: bundleID)) 빼기")
                }
            }
            Menu("앱 추가") {
                ForEach(addableAccessoryApps, id: \.self) { bundleID in
                    Button(KeyPointerSettingsPane.appName(for: bundleID)) {
                        updateIncluded { $0.append(bundleID) }
                    }
                }
                Divider()
                Button("다른 앱 선택…") { chooseIncludedApp() }
            }
            .fixedSize()
            Text("목록에는 Dock에 나오는 앱만 보입니다. Docker Desktop처럼 창을 닫으면 메뉴 막대 앱으로 바뀌는 앱은 여기에 넣으면 목록에 나오고, 고르면 다시 열기 요청으로 창을 엽니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 지금 실행 중인 메뉴 막대 앱 중 아직 목록에 없는 것 (이름순)
    private var addableAccessoryApps: [String] {
        let included = Set(coordinator.settings.includedAccessoryApps)
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .accessory }
            .compactMap(\.bundleIdentifier)
            .filter { !included.contains($0) && $0 != Bundle.main.bundleIdentifier }
        return Array(Set(ids)).sorted {
            KeyPointerSettingsPane.appName(for: $0).localizedStandardCompare(KeyPointerSettingsPane.appName(for: $1)) == .orderedAscending
        }
    }

    private func updateIncluded(_ change: (inout [String]) -> Void) {
        var copy = coordinator.settings
        change(&copy.includedAccessoryApps)
        coordinator.update(settings: copy)
    }

    /// 응용 프로그램 폴더에서 앱 고르기
    private func chooseIncludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "추가"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !coordinator.settings.includedAccessoryApps.contains(bundleID) else { return }
        updateIncluded { $0.append(bundleID) }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppRevealSettings, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = coordinator.settings
                copy[keyPath: keyPath] = newValue
                coordinator.update(settings: copy)
            }
        )
    }
}
