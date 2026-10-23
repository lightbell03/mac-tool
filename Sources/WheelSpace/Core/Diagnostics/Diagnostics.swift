import Foundation

/// 입력 내용을 제외한 상태·오류만 기록한다. 메모리 링 버퍼, 디스크 저장 없음.
final class Diagnostics {
    struct Entry {
        let date: Date
        let message: String
    }

    private static let capacity = 50
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(date: Date(), message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// "상태 진단 정보 복사"용 텍스트.
    func report(
        stateDescription: String,
        permissions: PermissionStatus,
        loginItemEnabled: Bool,
        extraLines: [String] = []
    ) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let formatter = ISO8601DateFormatter()
        var lines = [
            "WheelSpace \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "데스크탑 전환: \(stateDescription)",
            "손쉬운 사용: \(permissions.accessibility ? "허용" : "없음")",
            "입력 모니터링: \(permissions.listenEvents ? "허용" : "없음")",
            "이벤트 전송: \(permissions.postEvents ? "허용" : "없음")",
            "로그인 시 실행: \(loginItemEnabled ? "켜짐" : "꺼짐")",
        ] + extraLines + [
            "",
            "최근 기록:",
        ]
        if snapshot.isEmpty {
            lines.append("(없음)")
        } else {
            lines += snapshot.map { "\(formatter.string(from: $0.date)) \($0.message)" }
        }
        return lines.joined(separator: "\n")
    }
}
