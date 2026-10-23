import AppKit

/// 변환 전 클립보드 원본 (메모리에만 한 단계 보관). 항목별 타입 → 데이터.
struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let byteCount: Int
}

/// 일반 클립보드 읽기·스냅샷·조건부 쓰기·복구. 명령을 실행할 때만 접근하고 폴링하지 않는다.
@MainActor
final class ClipboardService {
    enum ReadResult: Equatable {
        case text(String, changeCount: Int)
        /// 비었거나 이미지·파일만 있어 평문이 없음
        case noPlainText
        case tooLarge
    }

    enum WriteResult: Equatable {
        case written(changeCount: Int)
        /// 계산하는 사이 사용자가 다른 내용을 복사함
        case changedSinceRead
        case failed
    }

    static let maxTextBytes = 1 << 20
    static let maxSnapshotBytes = 8 << 20

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func readPlainText() -> ReadResult {
        let count = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return .noPlainText
        }
        guard text.utf8.count <= Self.maxTextBytes else { return .tooLarge }
        return .text(text, changeCount: count)
    }

    /// 현재 항목·타입 데이터를 복사해 둔다. 일부를 읽을 수 없거나 상한을 넘으면 nil (그 경우 변환하지 않는다).
    func snapshot() -> ClipboardSnapshot? {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= Self.maxSnapshotBytes else { return nil }
                entry[type] = data
            }
            items.append(entry)
        }
        return ClipboardSnapshot(items: items, byteCount: total)
    }

    /// 읽은 시점 이후 클립보드가 바뀌지 않았을 때만 평문으로 쓴다.
    func write(_ text: String, ifChangeCountIs expected: Int) -> WriteResult {
        guard pasteboard.changeCount == expected else { return .changedSinceRead }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return .failed }
        return .written(changeCount: pasteboard.changeCount)
    }

    /// 스냅샷 복원. 성공하면 새 changeCount, 실패면 nil.
    func restore(_ snapshot: ClipboardSnapshot) -> Int? {
        pasteboard.clearContents()
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        // 원본이 빈 클립보드였으면 비운 것으로 복구 완료
        guard !items.isEmpty else { return pasteboard.changeCount }
        return pasteboard.writeObjects(items) ? pasteboard.changeCount : nil
    }
}
