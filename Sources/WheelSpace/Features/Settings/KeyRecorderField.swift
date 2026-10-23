import AppKit
import SwiftUI
import WheelSpaceCore

/// 보조키 없이 키 하나를 기록하는 버튼 (키보드 포인터의 누르고 있는 키·동작 키).
/// ShortcutRecorder와 같이 설정 창 안의 로컬 모니터로만 감시하고 기록이 끝나면 즉시 제거한다. Esc는 취소.
struct KeyRecorderField: View {
    let key: PointerKey?
    var onRecord: (PointerKey) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private static let escapeKeyCode: UInt16 = 53

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "키를 누르세요…" : (key?.keyLabel ?? "없음"))
                    .monospaced()
                    .frame(minWidth: 80)
            }
            .accessibilityLabel(isRecording ? "키 기록 중" : "키 \(key?.keyLabel ?? "없음"), 눌러서 변경")
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
        hint = "Esc 취소"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escapeKeyCode {
                stopRecording()
                return nil
            }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            guard ScrollEventMapper.modifierState(from: flags).isEmpty else {
                hint = "보조키 없이 키 하나만 누르세요"
                return nil
            }
            onRecord(PointerKey(keyCode: event.keyCode, keyLabel: ShortcutRecorder.label(for: event)))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        hint = nil
    }
}
