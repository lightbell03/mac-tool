import AppKit
import SwiftUI
import WheelSpaceCore

/// 단축키 기록 버튼. 누르면 다음 키 조합을 기록하고, Esc는 취소, Delete는 해제.
/// 키 감시는 설정 창 안의 로컬 모니터로만 하고 기록이 끝나면 즉시 제거한다.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// 기록 시작·종료 통지 (전역 단축키를 잠시 해제하는 데 쓴다)
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private static let escapeKeyCode: UInt16 = 53
    private static let deleteKeyCodes: Set<UInt16> = [51, 117]

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "키 조합을 누르세요…" : (combo?.displayString ?? "없음"))
                        .monospacedDigit()
                        .frame(minWidth: 120)
                }
                .accessibilityLabel(isRecording ? "단축키 기록 중" : "단축키 \(combo?.displayString ?? "없음"), 눌러서 변경")
                if combo != nil, !isRecording {
                    Button {
                        combo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("단축키 해제")
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        hint = "Esc 취소 · Delete 해제"
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escapeKeyCode {
                stopRecording()
                return nil
            }
            if Self.deleteKeyCodes.contains(event.keyCode) {
                combo = nil
                stopRecording()
                return nil
            }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let candidate = KeyCombo(
                keyCode: event.keyCode,
                modifiers: ScrollEventMapper.modifierState(from: flags),
                keyLabel: Self.label(for: event)
            )
            if candidate.isValidGlobalShortcut {
                combo = candidate
                stopRecording()
            } else {
                hint = "Control·Option·Command 중 하나와 함께 누르세요"
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        let wasRecording = isRecording
        monitor = nil
        isRecording = false
        hint = nil
        if wasRecording {
            onRecordingChange(false)
        }
    }

    private static let specialKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        49: "Space", 36: "↩", 48: "⇥", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// 키 표시 문자. 기능키·화살표 등은 이름 표, 나머지는 charactersIgnoringModifiers 대문자.
    static func label(for event: NSEvent) -> String {
        if let special = specialKeyLabels[event.keyCode] {
            return special
        }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "#\(event.keyCode)" : characters
    }
}
