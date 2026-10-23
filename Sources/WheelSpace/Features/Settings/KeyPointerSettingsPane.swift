import SwiftUI
import WheelSpaceCore

/// 설정 창의 "키보드 포인터" 영역.
struct KeyPointerSettingsPane: View {
    @ObservedObject var controller: KeyPointerController
    @ObservedObject var app: AppController
    /// 단축키 편집본. 적용 전까지 저장·엔진에 반영하지 않는다 (중간 상태가 잘못된 조합일 수 있다)
    @State private var draft: PointerShortcut?
    /// 해제 단축키 목록에 새 줄을 추가하는 중 (빈 단축키 입력란 표시)
    @State private var isAddingExitShortcut = false
    @State private var isAddingKeepShortcut = false

    private static let presets: [(name: String, speed: Double)] = [("느리게", 350), ("보통", 650), ("빠르게", 1_100)]

    var body: some View {
        Form {
            introSection
            if controller.status == .needsPermission {
                permissionSection
            }
            comboSection
            speedSection
            scrollSection
            keysSection
            leftHandSection
        }
        .formStyle(.grouped)
        .onAppear { controller.interrupt(reason: "키보드 포인터 설정 열기") }
    }

    private var introSection: some View {
        Section {
            Toggle("키보드 포인터 사용", isOn: binding(\.isEnabled))
            LabeledContent("현재 상태", value: controller.stateDescription)
            if controller.status == .tapError {
                Button("입력 감지 다시 시도") { controller.retry() }
            }
            Text("특수키를 누른 채 방향키로 마우스 포인터를 움직입니다. 특수키를 놓으면 평소처럼 방향키를 씁니다.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionSection: some View {
        Section("권한") {
            Label("키 입력을 감지하고 마우스 이벤트를 보내려면 입력 모니터링과 손쉬운 사용 권한이 필요합니다.", systemImage: "lock")
            HStack {
                Button("권한 요청") { app.requestPermissions() }
                Button("입력 모니터링 설정 열기") { app.openPermissionSettings(.inputMonitoring) }
                Button("손쉬운 사용 설정 열기") { app.openPermissionSettings(.accessibility) }
            }
            Button("다시 확인") { app.recheckPermissions() }
        }
    }

    private var comboSection: some View {
        let shortcut = editingShortcut
        return Section("단축키 설정") {
            Picker("프리셋", selection: Binding(
                get: { PointerModifierPair.matching(shortcut) },
                set: { preset in
                    if let preset { draft = preset.applied(to: shortcut) }
                }
            )) {
                ForEach(PointerModifierPair.allCases, id: \.self) { pair in
                    Text(Self.displayName(for: pair)).tag(Optional(pair))
                }
                if PointerModifierPair.matching(shortcut) == nil {
                    Text("사용자 지정").tag(PointerModifierPair?.none)
                }
            }

            LabeledContent("필수 보조키") {
                HStack {
                    ForEach(Self.modifierChoices, id: \.symbol) { choice in
                        Toggle(choice.symbol, isOn: Binding(
                            get: { shortcut.base.contains(choice.modifier) },
                            set: { on in
                                edit {
                                    if on { $0.base.insert(choice.modifier) } else { $0.base.remove(choice.modifier) }
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .accessibilityLabel(choice.name)
                    }
                }
            }
            LabeledContent("함께 누르고 있을 키") {
                HStack {
                    if shortcut.heldKey != nil {
                        Button("없애기") { edit { $0.heldKey = nil } }
                            .buttonStyle(.borderless)
                    }
                    KeyRecorderField(key: shortcut.heldKey) { key in edit { $0.heldKey = key } }
                }
            }
            modeKeyRow("스크롤 키", selection: \.scrollKey)
            modeKeyRow("빠르게 키", selection: \.fastKey)
            slowKeyRow
            lockToggleRow

            ForEach(PointerAction.allCases, id: \.self) { action in
                LabeledContent(Self.displayName(for: action)) {
                    KeyRecorderField(key: shortcut.key(for: action)) { key in
                        edit { $0.setKey(key, for: action) }
                    }
                }
            }

            ForEach(Array(shortcut.issues.enumerated()), id: \.offset) { _, issue in
                Label(Self.message(for: issue), systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            conflictWarnings(for: shortcut)
            ForEach(Array(shortcut.warnings.enumerated()), id: \.offset) { _, warning in
                Label(Self.message(for: warning), systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }

            HStack {
                Button("기본값으로") { draft = .defaults }
                    .disabled(shortcut == .defaults)
                Spacer()
                Button("되돌리기") { draft = nil }
                    .disabled(draft == nil)
                Button("적용") { applyDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || !shortcut.isValid)
            }
            Text("Tab처럼 보조키가 아닌 키를 \"함께 누르고 있을 키\"로 정하면, 그 키를 방향키 등에 쓰지 않고 떼었을 때 원래 입력을 앱에 다시 보냅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!controller.settings.isEnabled)
    }

    /// 가속 시간·시작 속도 슬라이더 (이동 속도 영역)
    @ViewBuilder
    private var accelerationRows: some View {
        let settings = controller.settings
        LabeledContent("가속 시간") {
            HStack {
                Slider(value: binding(\.accelerationTime), in: KeyPointerSettings.accelerationTimeRange, step: 0.1)
                Text(settings.accelerationTime == 0 ? "끔" : String(format: "%.1f초", settings.accelerationTime))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        LabeledContent("시작 속도") {
            HStack {
                Slider(value: binding(\.startSpeedRatio), in: KeyPointerSettings.startSpeedRatioRange, step: 0.05)
                Text("\(Int((settings.startSpeedRatio * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .disabled(settings.accelerationTime == 0)
        Text("짧게 누르면 시작 속도로 조금만 움직여 세밀하게 맞추고, 길게 누르면 가속 시간 동안 설정 속도까지 빨라집니다. 스크롤에도 적용되고, 빠른 속도일 때는 가속 없이 바로 움직입니다. \(settings.invertFastKey ? "지금은 기본이 빠른 속도이고, \(settings.shortcut.fastKey.label)를 누르는 동안 이 가속이 적용된 느린 속도가 됩니다." : "\(settings.shortcut.fastKey.label)를 누른 동안이 빠른 속도입니다.")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 창 포커스 이동·한영 변환 단축키와 겹치는 방향키 조합 경고
    @ViewBuilder
    private func conflictWarnings(for shortcut: PointerShortcut) -> some View {
        let focus = app.windowFocus.settings
        let conversion = app.conversion.settings
        let named: [(name: String, combo: KeyCombo?)] =
            (focus.isEnabled ? FocusDirection.allCases.map { ("창 포커스 이동", focus.shortcut(for: $0)) } : [])
            + (conversion.isEnabled
                ? [("한영 변환", conversion.englishToHangulShortcut), ("한영 변환", conversion.hangulToEnglishShortcut)]
                : [])
        let conflicts = shortcut.conflicts(with: named.compactMap(\.combo))
        ForEach(conflicts, id: \.self) { combo in
            let name = named.first { $0.combo == combo }?.name ?? "다른"
            Label(
                "\(combo.displayString)는 \(name) 단축키가 먼저 실행되어, 이 조합의 포인터 이동·스크롤이 동작하지 않습니다.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
        }
    }

    /// 편집 중이면 편집본, 아니면 저장된 단축키
    private var editingShortcut: PointerShortcut {
        draft ?? controller.settings.shortcut
    }

    private func edit(_ change: (inout PointerShortcut) -> Void) {
        var copy = editingShortcut
        change(&copy)
        draft = copy == controller.settings.shortcut ? nil : copy
    }

    private func applyDraft() {
        guard let draft, draft.isValid else { return }
        var copy = controller.settings
        copy.shortcut = draft
        controller.update(settings: copy)
        self.draft = nil
    }

    /// 고정 모드 켜고 끄기: "필수 보조키 + 누르고 있는 키 두 번" / 단축키 / 끔
    @ViewBuilder
    private var lockToggleRow: some View {
        let shortcut = editingShortcut
        LabeledContent("포인터 모드 켜기") {
            HStack {
                Picker("포인터 모드 켜기", selection: Binding(
                    get: { LockToggleChoice(shortcut.lockToggle) },
                    set: { choice in
                        edit {
                            switch choice {
                            case .doubleTap: $0.lockToggle = .doubleTapHeldKey
                            case .off: $0.lockToggle = .off
                            case .shortcut:
                                if case .shortcut = $0.lockToggle { return }
                                $0.lockToggle = .shortcut(Self.defaultLockShortcut)
                            }
                        }
                    }
                )) {
                    Text("\(shortcut.comboSymbol()) 두 번").tag(LockToggleChoice.doubleTap)
                    Text("단축키").tag(LockToggleChoice.shortcut)
                    Text("사용 안 함").tag(LockToggleChoice.off)
                }
                .labelsHidden()
                .fixedSize()
                if case .shortcut(let combo) = shortcut.lockToggle {
                    ShortcutRecorder(combo: Binding(
                        get: { combo },
                        set: { newCombo in edit { $0.lockToggle = newCombo.map { .shortcut($0) } ?? .off } }
                    ))
                }
            }
        }
        if shortcut.lockToggle != .off {
            LabeledContent("입력 모드로 돌아가는 키") {
                KeyRecorderField(key: shortcut.insertKey) { key in edit { $0.insertKey = key } }
            }
            toastOpacityRow
            Toggle("앱 단축키 뒤 돌아올 때 포인터를 포커스된 곳으로", isOn: binding(\.moveToFocusOnResume))
            Toggle("포인터 모드를 켤 때도 포커스된 곳으로", isOn: binding(\.moveToFocusOnLock))
            Text("글자 커서가 있으면 커서 옆으로, 없으면 포커스된 항목 가운데로 옮깁니다. 앱이 위치를 알려 주지 않거나 편집기 전체처럼 너무 크면 옮기지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            exitRows
            Text("포인터 모드에서는 \(shortcut.comboSymbol()) 없이 방향키·클릭·드래그 키·스크롤·빠르게·느리게 키로 조작합니다. 다른 글자·숫자·Space·Tab은 입력되지 않고, \(shortcut.insertKey.keyLabel)를 누르면 평소대로 입력합니다. ⌘·⌃ 단축키·Esc·Fn·기능 키는 앱에 그대로 갑니다. 메뉴나 설정 창을 열면 꺼집니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 왼손 모드: 켜는 방법과 키 표. 켜는 키가 "누르고 있는 키 두 번"일 때만 쓸 수 있다.
    @ViewBuilder
    private var leftHandSection: some View {
        let shortcut = controller.settings.shortcut
        if shortcut.lockToggle == .doubleTapHeldKey {
            let rows: [(String, String)] = [
                ("\(shortcut.comboSymbol(adding: .shift)) 두 번", "왼손 모드 켜기·끄기 (일반 포인터 모드에서는 왼손 모드로 바꾸기)"),
                ("Q", "포인터 모드에서 일반 ↔ 왼손 모드 바꾸기"),
                ("W A S D", "위·왼쪽·아래·오른쪽 이동 (두 키 함께 누르면 대각선)"),
                ("R / F", "위 / 아래로 스크롤"),
                ("E / T", "왼쪽 / 오른쪽으로 스크롤"),
                ("\(shortcut.fastKey.label) + WASD·RFET", "빠르게 이동·스크롤"),
                ("Space", "왼쪽 클릭 (두 번 = 더블클릭)"),
                ("C", "오른쪽 클릭"),
                ("V", "드래그 시작 → 다시 누르면 놓기 (Esc도 놓기)"),
            ]
            Section("왼손 모드") {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.1) {
                        Text(row.0).monospaced()
                    }
                }
                Text("오른손이 마우스에 있을 때 왼손만으로 쓰는 포인터 모드입니다. ⌘B 같은 앱 단축키 뒤 ⌘를 쥔 채 누른 WASD는 방향키, Space는 ↩로 전달됩니다. 방향키·↩도 함께 쓸 수 있고, 화면 위에 \"왼손 포인터 모드\"가 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.settings.isEnabled)
        }
    }

    /// 포인터 모드 자동 해제: 해제 단축키 목록(추가·삭제), 입력란 클릭 시 해제
    @ViewBuilder
    private var exitRows: some View {
        Toggle("키보드로 클릭하면 포인터 모드 해제", isOn: binding(\.exitAfterClick))
        Text("옮기고 클릭(더블클릭·드래그 놓기 포함)하면 바로 키보드로 돌아갑니다. 마우스를 잠깐 쓰듯 한 번씩 쓸 때 편합니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("입력란을 클릭하면 포인터 모드 해제", isOn: binding(\.exitOnTextInputClick))
        if controller.settings.exitOnTextInputClick {
            excludedAppRows
            exclusionRuleRows
        }
        shortcutListRows("해제 단축키", \.exitShortcuts, isAdding: $isAddingExitShortcut)
        Text("Spotlight(⌘Space)·ChatGPT(⌥Space)처럼 바로 글자를 입력하는 창을 여는 단축키를 넣어 두면, 누를 때 포인터 모드가 꺼지고 단축키는 그대로 동작합니다. 단축키 목록은 \"적용\"을 눌러야 반영됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Picker("⌘·⌃ 앱 단축키를 누르면", selection: Binding(
            get: { editingShortcut.appShortcutAction },
            set: { action in edit { $0.appShortcutAction = action } }
        )) {
            Text("보조키를 누르는 동안만 해제").tag(AppShortcutAction.whileHeld)
            Text("잠깐 해제 후 돌아오기 (0.7초·↩·Esc)").tag(AppShortcutAction.suspend)
            Text("포인터 모드 해제").tag(AppShortcutAction.exit)
            Text("아무것도 안 함").tag(AppShortcutAction.ignore)
        }
        if editingShortcut.appShortcutAction == .whileHeld {
            Toggle("⌘를 쥔 채 누른 방향키·↩·Esc는 ⌘ 없이 보내기", isOn: Binding(
                get: { editingShortcut.stripsHeldModifier },
                set: { on in edit { $0.stripsHeldModifier = on } }
            ))
        }
        if editingShortcut.appShortcutAction != .ignore {
            shortcutListRows("유지할 단축키", \.keepShortcuts, isAdding: $isAddingKeepShortcut)
        }
        Text("단축키는 항상 앱에 그대로 갑니다. 보조키를 누르는 동안만 해제하면 ⌘를 누른 채 이어서 쓰는 단축키가 모두 앱으로 가고, ⌘를 떼면 바로 포인터 모드로 돌아옵니다. \"⌘ 없이 보내기\"를 켜 두면 ⌘B로 연 목록을 ⌘를 떼지 않고 ↓↓↩로 고를 수 있고, 끄면 ⌘↓ 같은 원래 단축키가 그대로 갑니다. 잠깐 해제는 단축키 뒤 0.7초 동안 아무 키도 안 누르거나, 목록에서 ↩·Esc를 누르면 다시 포인터 모드가 됩니다. 유지할 단축키(복사·붙여넣기 등)는 포인터 모드를 유지합니다. ⌘↑ 같은 방향키 단축키도 앱 단축키이고, 스크롤·느리게 키로 쓰는 보조키 + 방향키만 포인터가 씁니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 단축키 목록 편집: 항목마다 바꾸기·지우기(X), 끝에 추가 버튼. 목록은 "적용"을 눌러야 반영된다.
    @ViewBuilder
    private func shortcutListRows(
        _ title: String, _ keyPath: WritableKeyPath<PointerShortcut, [KeyCombo]>, isAdding: Binding<Bool>
    ) -> some View {
        let combos = editingShortcut[keyPath: keyPath]
        ForEach(Array(combos.enumerated()), id: \.offset) { index, combo in
            LabeledContent(index == 0 ? title : "") {
                // 해제(X)하면 목록에서 뺀다
                ShortcutRecorder(combo: Binding(
                    get: { combo },
                    set: { newCombo in
                        edit {
                            if let newCombo {
                                $0[keyPath: keyPath][index] = newCombo
                            } else {
                                $0[keyPath: keyPath].remove(at: index)
                            }
                        }
                    }
                ))
            }
        }
        if isAdding.wrappedValue {
            LabeledContent(combos.isEmpty ? title : "") {
                ShortcutRecorder(combo: Binding(
                    get: { nil },
                    set: { newCombo in
                        if let newCombo, !combos.contains(newCombo) {
                            edit { $0[keyPath: keyPath].append(newCombo) }
                        }
                        isAdding.wrappedValue = false
                    }
                ))
            }
        }
        Button("\(title) 추가") { isAdding.wrappedValue = true }
            .disabled(isAdding.wrappedValue)
    }

    /// 해제하지 않을 영역(배운 규칙): 규칙 요약 + 빼기, 사용법 안내
    @ViewBuilder
    private var exclusionRuleRows: some View {
        let rules = controller.settings.textInputExclusionRules
        ForEach(rules, id: \.self) { rule in
            LabeledContent(rule == rules.first ? "해제하지 않을 영역" : "") {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(rule.bundleID.map(Self.appName(for:)) ?? "모든 브라우저")
                        Text(Self.ruleDetail(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        var copy = controller.settings
                        copy.textInputExclusionRules.removeAll { $0 == rule }
                        controller.update(settings: copy)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("규칙 빼기")
                }
            }
        }
        Text("원치 않는 곳에서 포인터 모드가 풀리면 메뉴 막대의 \"방금 해제 취소하고 이 영역 제외\"(웹 페이지면 \"모든 브라우저에서 제외\")로 그 영역을 여기에 추가합니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 규칙 요약 한 줄: 페이지 · 역할 · 클래스
    private static func ruleDetail(_ rule: TextInputExclusionRule) -> String {
        var parts: [String] = []
        if let scheme = rule.urlScheme { parts.append("\(scheme)://\(rule.urlHost ?? "*")") }
        parts.append(rule.role.replacingOccurrences(of: "AX", with: ""))
        if !rule.domClasses.isEmpty { parts.append(rule.domClasses.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    /// 입력란 클릭 해제에서 뺄 앱: 목록(아이콘·이름·빼기) + 실행 중인 앱에서 추가 + 응용 프로그램에서 고르기
    @ViewBuilder
    private var excludedAppRows: some View {
        let excluded = controller.settings.textInputExitExcludedApps
        ForEach(excluded, id: \.self) { bundleID in
            LabeledContent(bundleID == excluded.first ? "해제하지 않을 앱" : "") {
                HStack(spacing: 6) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(Self.appName(for: bundleID))
                    Button {
                        updateExcludedApps { $0.removeAll { $0 == bundleID } }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(Self.appName(for: bundleID)) 빼기")
                }
            }
        }
        LabeledContent(excluded.isEmpty ? "해제하지 않을 앱" : "") {
            Menu("앱 추가") {
                ForEach(addableRunningApps, id: \.self) { bundleID in
                    Button(Self.appName(for: bundleID)) {
                        updateExcludedApps { $0.append(bundleID) }
                    }
                }
                Divider()
                Button("다른 앱 선택…") { chooseExcludedApp() }
            }
            .fixedSize()
        }
        Text("이 앱들에서는 입력란을 클릭해도 포인터 모드를 유지합니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 실행 중인 일반 앱 중 아직 목록에 없는 것 (이름순)
    private var addableRunningApps: [String] {
        let excluded = Set(controller.settings.textInputExitExcludedApps)
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !excluded.contains($0) && $0 != Bundle.main.bundleIdentifier }
        return Array(Set(ids)).sorted { Self.appName(for: $0).localizedStandardCompare(Self.appName(for: $1)) == .orderedAscending }
    }

    private func updateExcludedApps(_ change: (inout [String]) -> Void) {
        var copy = controller.settings
        change(&copy.textInputExitExcludedApps)
        controller.update(settings: copy)
    }

    /// 응용 프로그램 폴더에서 앱 고르기
    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "추가"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !controller.settings.textInputExitExcludedApps.contains(bundleID) else { return }
        updateExcludedApps { $0.append(bundleID) }
    }

    /// 번들 ID → 앱 이름 (설치된 앱의 표시 이름, 못 찾으면 번들 ID)
    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// 포인터 모드 토스트 배경 불투명도 슬라이더. 움직이면 미리보기를 띄운다.
    @ViewBuilder
    private var toastOpacityRow: some View {
        let opacity = controller.settings.toastOpacity
        LabeledContent("표시 불투명도") {
            HStack {
                Slider(value: binding(\.toastOpacity), in: KeyPointerSettings.toastOpacityRange, step: 0.05)
                    .accessibilityValue("\(Int((opacity * 100).rounded()))퍼센트")
                Text("\(Int((opacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        // 설정 창을 열면 포인터 모드가 꺼지므로, 움직일 때 미리보기로 보여 준다
        .onChange(of: opacity) { value in
            PointerModeIndicator.preview(insertKeyLabel: editingShortcut.insertKey.keyLabel, opacity: value)
        }
    }

    /// 느리게 키: 스크롤·빠르게 키와 같은 선택 + "없음"
    private var slowKeyRow: some View {
        modeKeyRow("느리게 키", current: editingShortcut.slowKey, allowsNone: true) { $0.slowKey = $1 }
    }

    /// 스크롤·빠르게 키 고르기: 보조키 4개 중 하나, 또는 "일반 키"를 고르고 키 입력란에서 직접 누른다
    private func modeKeyRow(_ title: String, selection keyPath: WritableKeyPath<PointerShortcut, PointerModeKey>) -> some View {
        modeKeyRow(title, current: editingShortcut[keyPath: keyPath], allowsNone: false) { shortcut, value in
            if let value { shortcut[keyPath: keyPath] = value }
        }
    }

    /// 모드 키 Picker 항목
    private enum ModeKeyChoice: Hashable {
        case none
        case modifier(ModifierState)
        case key
    }

    private func modeKeyRow(
        _ title: String, current: PointerModeKey?, allowsNone: Bool,
        set: @escaping (inout PointerShortcut, PointerModeKey?) -> Void
    ) -> some View {
        let selected: ModeKeyChoice = {
            switch current {
            case nil: return .none
            case .modifier(let modifier): return .modifier(modifier)
            case .key: return .key
            }
        }()
        return LabeledContent(title) {
            HStack {
                Picker(title, selection: Binding(
                    get: { selected },
                    set: { choice in
                        edit {
                            switch choice {
                            case .none: set(&$0, nil)
                            case .modifier(let modifier): set(&$0, .modifier(modifier))
                            case .key:
                                // 처음 일반 키를 고르면 임시로 S. 바로 옆 입력란에서 바꾼다.
                                if case .key = current { return }
                                set(&$0, .key(Self.defaultModeKey))
                            }
                        }
                    }
                )) {
                    if allowsNone { Text("없음").tag(ModeKeyChoice.none) }
                    ForEach(Self.modifierChoices, id: \.symbol) { choice in
                        Text("\(choice.symbol) \(choice.name)").tag(ModeKeyChoice.modifier(choice.modifier))
                    }
                    Text("일반 키").tag(ModeKeyChoice.key)
                }
                .labelsHidden()
                .fixedSize()
                if case .key(let key) = current {
                    KeyRecorderField(key: key) { newKey in edit { set(&$0, .key(newKey)) } }
                }
            }
        }
    }

    private var speedSection: some View {
        Section("이동 속도") {
            LabeledContent("키보드 포인터 이동 속도") {
                HStack {
                    Slider(value: binding(\.speed), in: KeyPointerSettings.speedRange, step: 50)
                        .accessibilityValue("초당 \(Int(controller.settings.speed))포인트")
                    Text("\(Int(controller.settings.speed))pt/초")
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
            HStack {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) {
                        var copy = controller.settings
                        copy.speed = preset.speed
                        controller.update(settings: copy)
                    }
                }
            }
            Toggle("기본을 빠르게 (\(controller.settings.shortcut.fastKey.label)를 누르는 동안 느리게)", isOn: binding(\.invertFastKey))
            LabeledContent(controller.settings.invertFastKey
                ? "빠른 이동 배율 (기본)"
                : "빠른 이동 배율 (\(controller.settings.shortcut.fastKey.label))") {
                HStack {
                    Slider(value: binding(\.fastMultiplier), in: KeyPointerSettings.fastMultiplierRange, step: 0.5)
                    Text(String(format: "%.1f배", controller.settings.fastMultiplier))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
            if let slowKey = controller.settings.shortcut.slowKey {
                LabeledContent("느린 이동·스크롤 배율 (\(slowKey.label))") {
                    HStack {
                        Slider(value: binding(\.slowMultiplier), in: KeyPointerSettings.slowMultiplierRange, step: 0.05)
                        Text(String(format: "%.2f배", controller.settings.slowMultiplier))
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
            accelerationRows
            Text("키보드로 이동할 때만 적용됩니다. 마우스와 트랙패드 속도는 macOS 설정을 따릅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!controller.settings.isEnabled)
    }

    private var scrollSection: some View {
        Section("스크롤") {
            LabeledContent("키보드 스크롤 속도") {
                HStack {
                    Text("느리게").font(.caption)
                    Slider(value: binding(\.scrollSpeed), in: KeyPointerSettings.scrollSpeedRange, step: 100)
                    Text("빠르게").font(.caption)
                }
            }
            LabeledContent("빠른 스크롤 배율 (\(controller.settings.shortcut.fastKey.label))") {
                HStack {
                    Slider(value: binding(\.scrollFastMultiplier), in: KeyPointerSettings.scrollFastMultiplierRange, step: 0.5)
                    Text(String(format: "%.1f배", controller.settings.scrollFastMultiplier))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
            Toggle("스크롤 방향 반전", isOn: binding(\.reverseScroll))
            Text("키보드 스크롤에만 적용됩니다. 마우스 휠과 자연스러운 스크롤 설정은 바꾸지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!controller.settings.isEnabled)
    }

    private var keysSection: some View {
        let shortcut = controller.settings.shortcut
        let base = shortcut.comboSymbol()
        let slowRow = shortcut.slowKey.map { _ in
            [("\(shortcut.comboLabel(slow: true)) + ←→↑↓", "느리게 이동·스크롤 (세밀 조절)")]
        } ?? []
        let rows: [(String, String)] = [
            ("\(base) + ←→↑↓", "포인터 이동 (두 키 함께 누르면 대각선)"),
            ("\(shortcut.comboLabel(fast: true)) + ←→↑↓", "빠르게 이동"),
        ] + slowRow + [
            ("\(shortcut.comboLabel(scroll: true)) + ←→↑↓", "세로·가로 스크롤"),
            ("\(base) + \(shortcut.leftClickKey.keyLabel)", "왼쪽 클릭"),
            ("\(base) + \(shortcut.rightClickKey.keyLabel)", "오른쪽 클릭"),
            ("\(base) + \(shortcut.doubleClickKey.keyLabel)", "더블클릭"),
            ("\(base) + \(shortcut.dragKey.keyLabel)", "누르고 있는 동안 드래그 (떼면 놓기)"),
            ("Esc", "드래그 취소"),
        ]
        return Section("단축키") {
            ForEach(rows, id: \.0) { row in
                LabeledContent(row.1) {
                    Text(row.0).monospaced()
                }
            }
            Text(shortcut.heldKey.map { held in
                "길게 눌러도 클릭은 한 번만 합니다. \(PointerShortcut.symbol(for: shortcut.base))나 \(held.keyLabel)을 놓으면 이동과 드래그가 바로 멈춥니다. 방향키 없이 \(shortcut.comboSymbol())만 눌렀다 떼면 원래 입력이 앱에 그대로 전달됩니다."
            } ?? "길게 눌러도 클릭은 한 번만 합니다. 특수키를 놓으면 이동과 드래그가 바로 멈춥니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<KeyPointerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = controller.settings
                copy[keyPath: keyPath] = newValue
                controller.update(settings: copy)
            }
        )
    }

    static func displayName(for pair: PointerModifierPair) -> String {
        switch pair {
        case .optionTab: return "⌥⇥ (Option + Tab)"
        case .controlShift: return "⌃⇧ (Control + Shift)"
        case .controlCommand: return "⌃⌘ (Control + Command)"
        case .controlOption: return "⌃⌥ (Control + Option)"
        case .optionCommand: return "⌥⌘ (Option + Command)"
        }
    }

    private static let modifierChoices: [(symbol: String, name: String, modifier: ModifierState)] = [
        ("⌃", "Control", .control), ("⌥", "Option", .option), ("⇧", "Shift", .shift), ("⌘", "Command", .command),
    ]
    /// 스크롤·빠르게 키로 "일반 키"를 처음 골랐을 때의 임시 키 (Tab 옆이라 왼손으로 함께 누르기 쉽다)
    private static let defaultModeKey = PointerKey(keyCode: 1, keyLabel: "S")
    /// 포인터 모드 켜기를 "단축키"로 처음 골랐을 때의 임시 단축키
    private static let defaultLockShortcut = KeyCombo(keyCode: 35, modifiers: [.control, .option, .command], keyLabel: "P")

    /// 포인터 모드 켜기 Picker 항목 (단축키 값은 따로 기록)
    private enum LockToggleChoice: Hashable {
        case doubleTap
        case shortcut
        case off

        init(_ toggle: PointerLockToggle) {
            switch toggle {
            case .doubleTapHeldKey: self = .doubleTap
            case .shortcut: self = .shortcut
            case .off: self = .off
            }
        }
    }

    static func displayName(for action: PointerAction) -> String {
        switch action {
        case .leftClick: return "왼쪽 클릭 키"
        case .rightClick: return "오른쪽 클릭 키"
        case .doubleClick: return "더블클릭 키"
        case .drag: return "드래그 키"
        }
    }

    static func message(for issue: PointerShortcut.Issue) -> String {
        switch issue {
        case .emptyBase: return "필수 보조키를 하나 이상 고르세요."
        case .invalidScrollModifier: return "스크롤 키는 필수 보조키에 없는 키여야 합니다."
        case .invalidFastModifier: return "빠르게 키는 필수 보조키에 없는 키여야 합니다."
        case .scrollEqualsFast: return "스크롤 키와 빠르게 키는 서로 달라야 합니다."
        case .invalidSlowModifier: return "느리게 키는 필수 보조키에 없는 키여야 합니다."
        case .slowEqualsOtherModeKey: return "느리게 키는 스크롤·빠르게 키와 달라야 합니다."
        case .reservedKey(let key): return "\(key.keyLabel)는 포인터 조작에 쓰는 키라 지정할 수 없습니다."
        case .duplicateKey(let key): return "\(key.keyLabel)를 두 곳에 지정했습니다."
        case .lockToggleNeedsHeldKey:
            return "포인터 모드를 두 번 눌러 켜려면 함께 누르고 있을 키가 있어야 합니다. 단축키로 바꾸거나 사용 안 함으로 두세요."
        }
    }

    static func message(for warning: PointerShortcut.Warning) -> String {
        switch warning {
        case .systemShortcutConflict:
            return "⌃ + 방향키는 macOS의 데스크탑 이동·미션 컨트롤이 먼저 실행됩니다. 포인터와 함께 데스크탑도 움직일 수 있습니다."
        case .editingShortcutConflict:
            return "함께 누르고 있을 키 없이 쓰면 글자 선택(⇧ + 방향키)이나 단어 이동(⌥ + 방향키)이 가려집니다."
        case .modeKeyWithoutHeldKey:
            return "함께 누르고 있을 키 없이 일반 키를 스크롤·빠르게 키로 쓰면, 필수 보조키와 그 키를 함께 누른 입력(⌥S 등)이 가려집니다."
        }
    }
}
