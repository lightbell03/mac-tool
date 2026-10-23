import AppKit
import CoreGraphics

/// 앞 앱의 선택 영역을 ⌘C로 가져오고, 변환 결과를 ⌘V로 붙여넣은 뒤 원래 클립보드를 되돌린다.
/// 선택 영역을 직접 수정하지 않고 앱의 복사·붙여넣기 동작에 맡긴다(실행 취소는 그 앱의 ⌘Z).
@MainActor
final class SelectionReplacer {
    enum Failure: Error, Equatable {
        /// 손쉬운 사용 권한이 없어 키를 보낼 수 없음
        case accessibilityDenied
        /// ⌘C 뒤에도 클립보드가 바뀌지 않음 = 선택된 글자 없음(또는 복사를 지원하지 않는 곳)
        case noSelection
        /// 단축키의 보조키(⌃⌥ 등)를 떼지 않아 ⌘C가 다른 조합으로 들어갈 위험
        case modifiersStillHeld
        /// 복사된 내용에 평문이 없음
        case noPlainText
        /// 원래 클립보드를 보관할 수 없음 — 되돌릴 수 없으므로 진행하지 않음
        case snapshotUnavailable
    }

    struct Copied {
        let text: String
        /// ⌘C 전에 있던 사용자 클립보드
        let original: ClipboardSnapshot
    }

    /// ⌘V 후 원래 클립보드를 되돌리기까지 기다리는 시간. 앱이 붙여넣기 내용을 읽을 시간을 준다.
    static let restoreDelay: TimeInterval = 0.4
    private static let copyTimeout: TimeInterval = 0.5
    private static let modifierReleaseTimeout: TimeInterval = 1.0
    private static let cKeyCode: CGKeyCode = 0x08
    private static let vKeyCode: CGKeyCode = 0x09

    /// 붙여넣어도 선택 영역이 바뀌지 않는(커서 위치에 덧붙는) 앱 — 터미널류
    static let appendOnlyBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "com.mitchellh.ghostty",
    ]

    private let clipboard: ClipboardService

    init(clipboard: ClipboardService) {
        self.clipboard = clipboard
    }

    /// 지금 앞 앱에서 바로 교체가 가능한지 (터미널류는 클립보드 방식으로 대신한다)
    static func canReplaceInFrontmostApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return !appendOnlyBundleIDs.contains(bundleID)
    }

    /// 앞 앱의 선택 영역을 복사해 온다. 원래 클립보드는 먼저 스냅샷으로 보관한다.
    func copySelection() async -> Result<Copied, Failure> {
        guard CGPreflightPostEventAccess() else { return .failure(.accessibilityDenied) }
        guard await waitForModifierRelease() else { return .failure(.modifiersStillHeld) }
        guard let original = clipboard.snapshot() else { return .failure(.snapshotUnavailable) }

        let start = clipboard.changeCount
        do {
            try SyntheticKeyboard.press(keyCode: Self.cKeyCode, flags: .maskCommand)
        } catch {
            return .failure(.accessibilityDenied)
        }
        // 바뀌지 않았으면 클립보드는 원래 그대로다
        guard await waitForChange(from: start) != nil else { return .failure(.noSelection) }

        guard case .text(let text, _) = clipboard.readPlainText() else {
            restore(original)
            return .failure(.noPlainText)
        }
        return .success(Copied(text: text, original: original))
    }

    /// 결과를 붙여넣고 restoreDelay 뒤 원래 클립보드를 되돌린다.
    func paste(_ text: String, thenRestore original: ClipboardSnapshot) async -> Bool {
        guard case .written(let written) = clipboard.write(text, ifChangeCountIs: clipboard.changeCount) else {
            restore(original)
            return false
        }
        do {
            try SyntheticKeyboard.press(keyCode: Self.vKeyCode, flags: .maskCommand)
        } catch {
            restore(original)
            return false
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelay * 1_000_000_000))
        // 그사이 사용자가 새로 복사했으면 건드리지 않는다
        if clipboard.changeCount == written {
            restore(original)
        }
        return true
    }

    /// 변환 결과가 같을 때 등: 붙여넣지 않고 원래 클립보드만 되돌린다.
    func restore(_ original: ClipboardSnapshot) {
        _ = clipboard.restore(original)
    }

    /// 단축키로 실행된 경우 사용자가 ⌃⌥ 등을 뗄 때까지 짧게 기다린다 (물리 키 상태 기준).
    private func waitForModifierRelease() async -> Bool {
        await poll(timeout: Self.modifierReleaseTimeout) {
            ScrollEventMapper.physicalModifierState().isEmpty ? true : nil
        } ?? false
    }

    /// 클립보드 changeCount가 바뀔 때까지 기다린다. 바뀐 값 또는 nil(시간 초과).
    private func waitForChange(from start: Int) async -> Int? {
        await poll(timeout: Self.copyTimeout) { [clipboard] in
            clipboard.changeCount != start ? clipboard.changeCount : nil
        }
    }

    /// 10ms 간격으로 조건을 확인한다. 값이 나오면 그 값, 시간 초과면 nil.
    private func poll<T>(timeout: TimeInterval, _ check: () -> T?) async -> T? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if let value = check() { return value }
            if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
