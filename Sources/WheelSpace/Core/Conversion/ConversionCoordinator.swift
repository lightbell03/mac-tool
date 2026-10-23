import AppKit
import Combine
import WheelSpaceCore

/// 한영 복원 작업 관리: 중복 실행 방지, 클립보드 읽기·변환·조건부 쓰기, 한 단계 원본 복구, 입력기 전환.
/// 원문·변환문·스냅샷은 메모리에만 두고 로그·디스크에 남기지 않는다.
@MainActor
final class ConversionCoordinator: ObservableObject {
    enum Outcome: Equatable {
        /// 선택 영역을 바로 바꿈 (replaceSelection)
        case replaced(ConversionDirection)
        /// 선택된 글자가 없음 (replaceSelection)
        case noSelection
        /// 손쉬운 사용 권한 없음 (replaceSelection)
        case needsAccessibility
        /// 단축키 보조키를 떼지 않아 진행하지 않음 (replaceSelection)
        case modifiersStillHeld
        /// 터미널 등 선택 교체가 안 되는 앱이라 클립보드에만 넣음
        case convertedToClipboardInTerminal(ConversionDirection)
        /// 처리 중 앞 앱이 바뀌어 붙여넣지 않음
        case cancelledByAppSwitch
        case converted(ConversionDirection)
        case nothingToConvert
        case unchanged
        case cancelledByNewCopy
        case tooLarge
        case snapshotUnavailable
        case writeFailed(restored: Bool)
        case restored
        case restoreUnavailable
        case restoreFailed
    }

    enum InputSourceOutcome: Equatable {
        case notRequested
        case alreadyTarget
        case switched
        /// 처리 중 전면 앱·입력기가 바뀌어 건드리지 않음
        case skipped
        /// 목표 입력기 없음·비활성·선택 실패
        case failed
    }

    @Published private(set) var settings: ConversionSettings
    /// 방향별 단축키 등록 실패 문구 (설정 창 표시용)
    @Published private(set) var shortcutErrors: [ConversionDirection: String] = [:]
    @Published private(set) var canRestore = false
    @Published private(set) var isBusy = false

    private let store: SettingsStore
    private let diagnostics: Diagnostics
    private let clipboard = ClipboardService()
    private let shortcuts = GlobalShortcutService<ConversionDirection>(signature: 0x5753_5043) { direction in // "WSPC"
        switch direction {
        case .englishToHangul: return 1
        case .hangulToEnglish: return 2
        }
    }
    private lazy var replacer = SelectionReplacer(clipboard: clipboard)
    private var shortcutsSuspended = false

    /// 한 단계 복구 기록: 원본, 앱이 쓴 결과의 changeCount, 만료 타이머
    private var snapshot: ClipboardSnapshot?
    private var resultChangeCount: Int?
    private var expiryTimer: Timer?
    private static let snapshotLifetime: TimeInterval = 5 * 60

    init(store: SettingsStore, diagnostics: Diagnostics) {
        self.store = store
        self.diagnostics = diagnostics
        self.settings = store.loadConversion()
    }

    func start() {
        shortcuts.onTrigger = { [weak self] direction in
            self?.convert(direction)
        }
        applyShortcuts()
    }

    func stop() {
        shortcuts.unregisterAll()
        discardSnapshot()
    }

    func update(settings newValue: ConversionSettings) {
        let value = newValue.validated()
        let shortcutsChanged = value.isEnabled != settings.isEnabled
            || value.englishToHangulShortcut != settings.englishToHangulShortcut
            || value.hangulToEnglishShortcut != settings.hangulToEnglishShortcut
        store.saveConversion(value)
        settings = value
        if shortcutsChanged {
            applyShortcuts()
        }
        if !value.isEnabled {
            discardSnapshot()
        }
    }

    /// 단축키 기록 중에는 전역 단축키를 잠시 해제해 기록 창이 키를 받을 수 있게 한다.
    func setShortcutsSuspended(_ suspended: Bool) {
        guard suspended != shortcutsSuspended else { return }
        shortcutsSuspended = suspended
        applyShortcuts()
    }

    /// 메뉴·단축키 공통 진입점. 실행 중이면 무시(큐에 쌓지 않음).
    func convert(_ direction: ConversionDirection) {
        if settings.triggerMode == .replaceSelection {
            replaceSelection(direction)
            return
        }
        guard settings.isEnabled, !isBusy else { return }
        isBusy = true

        let startApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let startSourceID = InputSourceService.currentSourceID()

        let text: String
        let readCount: Int
        switch clipboard.readPlainText() {
        case .noPlainText:
            finish(.nothingToConvert)
            return
        case .tooLarge:
            finish(.tooLarge)
            return
        case .text(let value, let changeCount):
            text = value
            readCount = changeCount
        }

        let computation = Task.detached(priority: .userInitiated) {
            KeyboardLayoutConverter.convert(text, direction: direction)
        }
        Task { [weak self] in
            let result = await computation.value
            self?.complete(
                direction: direction,
                original: text,
                result: result,
                readCount: readCount,
                startApp: startApp,
                startSourceID: startSourceID
            )
        }
    }

    private func complete(
        direction: ConversionDirection,
        original: String,
        result: String,
        readCount: Int,
        startApp: pid_t?,
        startSourceID: String?
    ) {
        guard result != original else {
            finish(.unchanged)
            return
        }
        guard clipboard.changeCount == readCount else {
            finish(.cancelledByNewCopy)
            return
        }
        guard let newSnapshot = clipboard.snapshot() else {
            finish(.snapshotUnavailable)
            return
        }

        switch clipboard.write(result, ifChangeCountIs: readCount) {
        case .written(let changeCount):
            storeSnapshot(newSnapshot, resultChangeCount: changeCount)
            let inputSource = switchInputSource(for: direction, startApp: startApp, startSourceID: startSourceID)
            finish(.converted(direction), inputSource: inputSource)
        case .changedSinceRead:
            finish(.cancelledByNewCopy)
        case .failed:
            let restored = clipboard.restore(newSnapshot) != nil
            finish(.writeFailed(restored: restored))
        }
    }

    /// 선택 영역 바로 교체: ⌘C → 변환 → ⌘V → 원래 클립보드 복원.
    private func replaceSelection(_ direction: ConversionDirection) {
        guard settings.isEnabled, !isBusy else { return }
        isBusy = true
        let startApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let startSourceID = InputSourceService.currentSourceID()
        let canReplace = SelectionReplacer.canReplaceInFrontmostApp()

        Task { [weak self] in
            guard let self else { return }
            let copied: SelectionReplacer.Copied
            switch await replacer.copySelection() {
            case .failure(.accessibilityDenied): return finish(.needsAccessibility)
            case .failure(.noSelection): return finish(.noSelection)
            case .failure(.modifiersStillHeld): return finish(.modifiersStillHeld)
            case .failure(.noPlainText): return finish(.nothingToConvert)
            case .failure(.snapshotUnavailable): return finish(.snapshotUnavailable)
            case .success(let value): copied = value
            }

            guard copied.text.utf8.count <= ClipboardService.maxTextBytes else {
                replacer.restore(copied.original)
                return finish(.tooLarge)
            }
            let text = copied.text
            let result = await Task.detached(priority: .userInitiated) {
                KeyboardLayoutConverter.convert(text, direction: direction)
            }.value

            guard result != text else {
                replacer.restore(copied.original)
                return finish(.unchanged)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == startApp else {
                replacer.restore(copied.original)
                return finish(.cancelledByAppSwitch)
            }

            if !canReplace {
                // 터미널류: 붙여넣으면 덧붙기만 하므로 클립보드에만 넣고, 원래 클립보드는 "직전 클립보드 복구"로 되살릴 수 있게 둔다
                guard case .written(let changeCount) = clipboard.write(result, ifChangeCountIs: clipboard.changeCount) else {
                    replacer.restore(copied.original)
                    return finish(.writeFailed(restored: true))
                }
                storeSnapshot(copied.original, resultChangeCount: changeCount)
                let inputSource = switchInputSource(for: direction, startApp: startApp, startSourceID: startSourceID)
                return finish(.convertedToClipboardInTerminal(direction), inputSource: inputSource)
            }

            guard await replacer.paste(result, thenRestore: copied.original) else {
                return finish(.writeFailed(restored: true))
            }
            let inputSource = switchInputSource(for: direction, startApp: startApp, startSourceID: startSourceID)
            finish(.replaced(direction), inputSource: inputSource)
        }
    }

    /// 직전 원본 복구. 현재 클립보드가 이 앱이 쓴 결과 그대로일 때만. 입력기는 되돌리지 않는다.
    func restorePrevious() {
        guard let saved = snapshot, let expected = resultChangeCount, clipboard.changeCount == expected else {
            discardSnapshot()
            finish(.restoreUnavailable)
            return
        }
        let restored = clipboard.restore(saved) != nil
        discardSnapshot()
        finish(restored ? .restored : .restoreFailed)
    }

    /// 새 복사 감지·잠금·종료·만료 시 호출.
    func discardSnapshot() {
        snapshot = nil
        resultChangeCount = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        canRestore = false
    }

    /// 앱이 활성화되거나 메뉴가 열릴 때: 사용자가 새로 복사했으면 스냅샷 폐기.
    func refreshRestoreAvailability() {
        if let expected = resultChangeCount, clipboard.changeCount != expected {
            discardSnapshot()
        }
    }

    /// 설정 창 테스트 입력용. 클립보드를 건드리지 않고 저장하지 않는다.
    func preview(_ text: String, direction: ConversionDirection) -> String {
        KeyboardLayoutConverter.convert(text, direction: direction)
    }

    /// 설정 창에서 쓰는 설치된 입력기 후보.
    func inputSourceCandidates(for direction: ConversionDirection) -> [InputSourceInfo] {
        switch direction {
        case .englishToHangul: return InputSourceService.koreanSources()
        case .hangulToEnglish: return InputSourceService.englishSources()
        }
    }

    /// 진단 정보용 요약 (조합·상태만, 내용 없음).
    var diagnosticsLines: [String] {
        var lines = ["한영 변환: \(settings.isEnabled ? "켜짐" : "꺼짐")"]
        for direction in ConversionDirection.allCases {
            let combo = settings.shortcut(for: direction)?.displayString ?? "없음"
            let status = shortcutErrors[direction].map { "실패(\($0))" } ?? "정상"
            lines.append("  \(direction.rawValue) 단축키: \(combo) — \(status)")
        }
        lines.append("  변환 후 입력 언어 맞추기: \(settings.switchInputSourceAfterConversion ? "켜짐" : "꺼짐")")
        return lines
    }

    // MARK: - 내부

    private func storeSnapshot(_ newSnapshot: ClipboardSnapshot, resultChangeCount changeCount: Int) {
        discardSnapshot()
        snapshot = newSnapshot
        resultChangeCount = changeCount
        expiryTimer = Timer.scheduledTimer(withTimeInterval: Self.snapshotLifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.discardSnapshot() }
        }
    }

    private func applyShortcuts() {
        guard settings.isEnabled, !shortcutsSuspended else {
            shortcuts.unregisterAll()
            if !settings.isEnabled { shortcutErrors = [:] }
            return
        }
        var combos: [ConversionDirection: KeyCombo] = [:]
        for direction in ConversionDirection.allCases {
            combos[direction] = settings.shortcut(for: direction)
        }
        let failures = shortcuts.register(combos)
        shortcutErrors = failures.mapValues { error in
            switch error {
            case .duplicate: return "다른 방향과 같은 조합이에요"
            case .systemRejected: return "다른 앱이 이미 쓰고 있거나 등록할 수 없는 조합이에요"
            }
        }
        for (direction, error) in failures {
            diagnostics.record("단축키 등록 실패: \(direction.rawValue) \(combos[direction]?.displayString ?? "") \(error)")
        }
    }

    /// 변환 성공 후 결과 언어의 입력기 선택. 쓰기 성공 이후에만 호출한다.
    private func switchInputSource(for direction: ConversionDirection, startApp: pid_t?, startSourceID: String?) -> InputSourceOutcome {
        guard settings.switchInputSourceAfterConversion else { return .notRequested }
        let currentApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentSourceID = InputSourceService.currentSourceID()
        guard currentApp == startApp, currentSourceID == startSourceID else { return .skipped }

        guard let targetID = settings.inputSourceID(for: direction) ?? inputSourceCandidates(for: direction).first?.id else {
            return .failed
        }
        if currentSourceID == targetID { return .alreadyTarget }
        return InputSourceService.select(id: targetID) ? .switched : .failed
    }

    private func finish(_ outcome: Outcome, inputSource: InputSourceOutcome = .notRequested) {
        isBusy = false
        canRestore = snapshot != nil
        FeedbackHUD.show(Self.message(for: outcome, inputSource: inputSource), isError: Self.isError(outcome, inputSource))
        diagnostics.record("한영 변환 결과: \(outcome), 입력기: \(inputSource)")
    }

    private static func isError(_ outcome: Outcome, _ inputSource: InputSourceOutcome) -> Bool {
        switch outcome {
        case .converted, .replaced, .convertedToClipboardInTerminal: return inputSource == .failed
        case .restored: return false
        default: return true
        }
    }

    static func message(for outcome: Outcome, inputSource: InputSourceOutcome) -> String {
        switch outcome {
        case .converted(let direction):
            if inputSource == .failed { return "텍스트는 변환했지만 입력 언어를 바꾸지 못했어요" }
            switch direction {
            case .englishToHangul: return "한글로 변환했어요. 붙여넣어 사용하세요."
            case .hangulToEnglish: return "영문으로 변환했어요. 붙여넣어 사용하세요."
            }
        case .nothingToConvert: return "변환할 내용이 없어요"
        case .unchanged: return "이미 같은 결과예요"
        case .cancelledByNewCopy: return "다른 내용이 복사돼 취소했어요"
        case .tooLarge: return "내용이 너무 커요 (1MB 이하)"
        case .snapshotUnavailable: return "원본을 보관할 수 없어 변환하지 않았어요. 설정의 테스트 입력을 사용하세요."
        case .writeFailed(let restored):
            return restored ? "클립보드에 쓰지 못해 원래 내용으로 되돌렸어요" : "클립보드에 쓰지 못했고 원래 내용도 되돌리지 못했어요"
        case .restored: return "원래 클립보드로 되돌렸어요"
        case .restoreUnavailable: return "되돌릴 내용이 없어요"
        case .restoreFailed: return "되돌리지 못했어요"
        case .replaced(let direction):
            if inputSource == .failed { return "글자는 바꿨지만 입력 언어를 바꾸지 못했어요" }
            return direction == .englishToHangul ? "한글로 바꿨어요" : "영문으로 바꿨어요"
        case .convertedToClipboardInTerminal:
            return "터미널에서는 바로 바꿀 수 없어 클립보드에 넣었어요. ⌃U로 줄을 지우고 ⌘V 하세요"
        case .noSelection: return "선택된 글자가 없어요"
        case .needsAccessibility: return "손쉬운 사용 권한이 필요해요 — 설정 > 데스크탑 전환에서 허용하세요"
        case .modifiersStillHeld: return "단축키를 뗀 뒤 다시 시도하세요"
        case .cancelledByAppSwitch: return "다른 앱으로 바뀌어 취소했어요"
        }
    }
}
