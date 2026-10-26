import SwiftUI
import WheelSpaceCore

/// 설정 창의 "창 포커스 이동" 영역. 활성화, 권한, 방향별 단축키, 배치 예시.
struct WindowFocusSettingsPane: View {
    @ObservedObject var coordinator: FocusCoordinator
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            introSection
            if coordinator.status == .needsPermission {
                permissionSection
            }
            shortcutSection
            switcherSection
            stackSection
            moveWindowSection
            moveToSpaceSection
            exampleSection
        }
        .formStyle(.grouped)
    }

    private var introSection: some View {
        Section {
            Toggle("창 포커스 이동 사용", isOn: binding(\.isEnabled))
            LabeledContent("현재 상태", value: coordinator.stateDescription)
            if let result = coordinator.lastResult {
                LabeledContent("마지막 이동", value: result)
            }
            Text("단축키로 현재 창의 왼쪽·오른쪽·위·아래에 있는 창으로 키보드 포커스를 옮깁니다. 창 위치와 크기는 바꾸지 않습니다.")
                .foregroundStyle(.secondary)
            Picker("마우스 포인터 따라가기", selection: binding(\.pointerFollow)) {
                ForEach(PointerFollowMode.allCases, id: \.self) { mode in
                    Text(Self.displayName(for: mode)).tag(mode)
                }
            }
            Text(Self.explanation(for: coordinator.settings.pointerFollow))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionSection: some View {
        Section("권한") {
            Label("다른 앱의 창을 찾고 포커스를 옮기려면 손쉬운 사용 권한이 필요합니다.", systemImage: "lock")
            HStack {
                Button("권한 요청") { controller.requestPermissions() }
                Button("손쉬운 사용 설정 열기") { controller.openPermissionSettings(.accessibility) }
                Button("다시 확인") { controller.recheckPermissions() }
            }
        }
    }

    private var shortcutSection: some View {
        Section("단축키") {
            ForEach(FocusDirection.allCases, id: \.self) { direction in
                LabeledContent(Self.displayName(for: direction)) {
                    ShortcutRecorder(combo: shortcutBinding(direction)) { recording in
                        coordinator.setShortcutsSuspended(recording)
                    }
                }
                if let error = coordinator.shortcutErrors[direction] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
            Button("기본값으로") {
                var copy = coordinator.settings
                for direction in FocusDirection.allCases {
                    copy.setShortcut(FocusSettings.defaults.shortcut(for: direction), for: direction)
                }
                coordinator.update(settings: copy)
            }
            Text("⌃⌥ 조합은 VoiceOver와 겹칠 수 있어요. 길게 눌러도 한 번만 이동합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 겹친 창 넘기기 단축키·설명
    private var stackSection: some View {
        Section("겹친 창 넘기기") {
            LabeledContent("뒤로 (밑에 깔린 창을 앞으로)") {
                ShortcutRecorder(combo: binding(\.stackNextShortcut)) { recording in
                    coordinator.setShortcutsSuspended(recording)
                }
            }
            if let error = coordinator.stackShortcutErrors[.next] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
            }
            LabeledContent("앞으로 (직전 창으로)") {
                ShortcutRecorder(combo: binding(\.stackPreviousShortcut)) { recording in
                    coordinator.setShortcutsSuspended(recording)
                }
            }
            if let error = coordinator.stackShortcutErrors[.previous] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
            }
            Text("지금 모니터에 겹쳐 있는 창을 한 장씩 넘깁니다. 지금 창과 겹친 창을 먼저, 그다음 같은 모니터의 나머지 창을 앞에서 뒤 순서로 돌고, 끝에서 처음으로 돌아옵니다. 1.5초 안에 이어 누르면 처음 순서를 그대로 쓰고, 그보다 오래 쉬거나 다른 창을 고르면 그때의 순서로 새로 시작합니다. 완전히 가려진 창도 포함합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("macOS는 창을 맨 뒤로 내리는 기능을 공개하지 않아, \"뒤로\"는 밑에 깔린 창을 앞으로 가져오는 방식입니다. 지금 창은 한 칸 뒤로 갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 창을 다른 모니터로 보내기 단축키·설명
    private var moveWindowSection: some View {
        Section("창을 다른 모니터로 보내기") {
            ForEach(FocusDirection.allCases, id: \.self) { direction in
                LabeledContent(Self.displayName(for: direction).replacingOccurrences(of: "창", with: "모니터")) {
                    ShortcutRecorder(combo: Binding(
                        get: { coordinator.settings.moveShortcut(for: direction) },
                        set: { combo in
                            var copy = coordinator.settings
                            copy.setMoveShortcut(combo, for: direction)
                            coordinator.update(settings: copy)
                        }
                    )) { recording in
                        coordinator.setShortcutsSuspended(recording)
                    }
                }
                if let error = coordinator.moveShortcutErrors[direction] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Text("지금 창을 그 방향에 있는 모니터로 옮깁니다. 보통 창은 크기 그대로 같은 비율의 자리로 옮기고, 화면 가장자리에 붙여 둔 창(왼쪽 절반·꽉 채움 등)은 새 모니터에서도 같은 배치가 되게 크기를 맞춥니다. 전체 화면 창은 옮길 수 없고, 크기를 바꿀 수 없는 창은 위치만 옮깁니다. 포인터 따라가기를 켜 두면 포인터도 그 창으로 갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 창을 옆 데스크탑으로 보내기: 단축키 2개, 데스크탑이 없으면 만들기, 설명
    private var moveToSpaceSection: some View {
        Section("데스크탑") {
            ForEach(SpaceDirection.allCases, id: \.self) { direction in
                LabeledContent(direction == .left ? "창을 들고 왼쪽 데스크탑으로" : "창을 들고 오른쪽 데스크탑으로") {
                    ShortcutRecorder(combo: Binding(
                        get: { coordinator.settings.spaceShortcut(for: direction) },
                        set: { combo in
                            var copy = coordinator.settings
                            copy.setSpaceShortcut(combo, for: direction)
                            coordinator.update(settings: copy)
                        }
                    )) { recording in
                        coordinator.setShortcutsSuspended(recording)
                    }
                }
                if let error = coordinator.spaceShortcutErrors[direction] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            LabeledContent("새 데스크탑 만들기") {
                ShortcutRecorder(combo: binding(\.createSpaceShortcut)) { recording in
                    coordinator.setShortcutsSuspended(recording)
                }
            }
            if let error = coordinator.createSpaceShortcutError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
            }
            Toggle("창을 들고 갈 때 오른쪽에 데스크탑이 없으면 만들기", isOn: binding(\.createSpaceIfMissing))
            Text("새 데스크탑 만들기는 지금 창이 있는 모니터의 맨 끝에 데스크탑을 만들고, 화면은 그대로 둡니다. 화면만 넘기기는 macOS의 ⌃← / ⌃→를 쓰세요. 창을 들고 가기는 지금 창을 같은 모니터의 옆 데스크탑으로 옮기고 화면도 함께 넘어갑니다. macOS가 공개하지 않은 기능을 써서, macOS 업데이트 뒤 동작하지 않으면 알려 드립니다. 새 데스크탑은 Mission Control을 잠깐 열어 만들고, 맨 끝(오른쪽)에만 만들 수 있습니다. 시스템 설정의 Mission Control 단축키(⌃← / ⌃→)가 켜져 있어야 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    /// 창 목록 전환기 단축키·설명
    private var switcherSection: some View {
        Section("창 목록 전환기") {
            LabeledContent("목록 열기") {
                ShortcutRecorder(combo: binding(\.switcherShortcut)) { recording in
                    coordinator.setShortcutsSuspended(recording)
                }
            }
            Toggle("⌥⇥를 누른 채일 때만 열기 (⌥⇥ + `)", isOn: binding(\.switcherRequiresHeldKey))
            Text("켜면 키보드 포인터처럼 ⌥ + Tab을 누르고 있는 동안에만 목록이 열리고, Tab 없이 누른 단축키는 앱에 그대로 갑니다. 키보드 포인터가 켜져 있고 함께 누르고 있을 키가 Tab일 때 동작합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("보조키를 누른 채 누르면 지금 모니터의 창 목록이 뜹니다. 다시 누르면 다음 창, ⇧를 더하면 이전 창이고 방향키로도 고릅니다. 보조키를 떼면 그 창으로 가고, Esc는 취소입니다. 다른 창에 완전히 가려진 창도 목록에 나옵니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!coordinator.settings.isEnabled)
    }

    private var exampleSection: some View {
        Section("이동 예시") {
            Text("""
                     모니터 A               모니터 B
                ┌──────┬──────┐    ┌─────────────┐
                │  A1  │  A2  │    │     B1      │
                └──────┴──────┘    └─────────────┘
                         모니터 C
                     ┌──────┬──────┐
                     │  C1  │  C2  │
                     └──────┴──────┘
                """)
                .font(.system(.caption, design: .monospaced))
                .accessibilityLabel("모니터 A에 A1, A2 창, 오른쪽 모니터 B에 B1 창, 아래 모니터 C에 C1, C2 창이 있는 배치 예시")
            Text("B1에서 왼쪽 → A2, 한 번 더 → A1. 위·아래는 모니터 이름이 아니라 실제 창 위치로 정합니다.")
            Text("최소화·숨김·다른 데스크탑·완전히 가려진 창, 대화상자가 떠 있는 앱은 건너뜁니다. 그 방향에 창이 없으면 그대로 둡니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FocusSettings, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = coordinator.settings
                copy[keyPath: keyPath] = newValue
                coordinator.update(settings: copy)
            }
        )
    }

    private func shortcutBinding(_ direction: FocusDirection) -> Binding<KeyCombo?> {
        Binding(
            get: { coordinator.settings.shortcut(for: direction) },
            set: { newValue in
                var copy = coordinator.settings
                copy.setShortcut(newValue, for: direction)
                coordinator.update(settings: copy)
            }
        )
    }

    static func displayName(for mode: PointerFollowMode) -> String {
        switch mode {
        case .off: return "끔"
        case .focusMoves: return "창 포커스 이동으로 다른 모니터에 갈 때"
        case .allFocusChanges: return "포커스가 다른 모니터로 바뀔 때마다"
        }
    }

    static func explanation(for mode: PointerFollowMode) -> String {
        switch mode {
        case .off:
            return "포인터는 그대로 둡니다."
        case .focusMoves:
            return "단축키로 다른 모니터의 창으로 옮기면 그 창 가운데로 포인터를 옮깁니다(클릭하지 않음). 같은 모니터 안에서는 그대로 둡니다."
        case .allFocusChanges:
            return "단축키뿐 아니라 Spotlight·⌘Tab·Dock 등으로 다른 모니터의 창이 포커스를 받아도 포인터를 그 창으로 옮깁니다. 포인터가 이미 그 모니터에 있으면 그대로 둡니다. 알림 등으로 다른 앱이 스스로 앞에 나와도 따라갑니다."
        }
    }

    static func displayName(for direction: FocusDirection) -> String {
        switch direction {
        case .left: return "왼쪽 창"
        case .right: return "오른쪽 창"
        case .up: return "위쪽 창"
        case .down: return "아래쪽 창"
        }
    }
}
