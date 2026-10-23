import Foundation

/// 목록의 앱 한 줄 (OS 객체 없는 순수 값)
public struct AppPickerEntry: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var isHidden: Bool
    /// 같은 이름의 앱이 여러 개 실행 중이면 구별용 표시 (번들 ID 또는 PID)
    public var disambiguation: String?

    public init(pid: Int32, name: String, bundleID: String?, isHidden: Bool, disambiguation: String? = nil) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isHidden = isHidden
        self.disambiguation = disambiguation
    }
}

/// 최근 활성화 순서 (실행 중 메모리에만). 앞이 가장 최근.
public struct RecentAppOrder: Equatable, Sendable {
    public private(set) var pids: [Int32] = []

    public init() {}

    public mutating func activated(_ pid: Int32) {
        pids.removeAll { $0 == pid }
        pids.insert(pid, at: 0)
    }

    public mutating func terminated(_ pid: Int32) {
        pids.removeAll { $0 == pid }
    }

    /// 최근 순서대로, 이력이 없는 앱은 뒤에 이름순
    public func sorted(_ entries: [AppPickerEntry]) -> [AppPickerEntry] {
        let rank = Dictionary(uniqueKeysWithValues: pids.enumerated().map { ($1, $0) })
        return entries.sorted { a, b in
            switch (rank[a.pid], rank[b.pid]) {
            case let (ra?, rb?): return ra < rb
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.pid < b.pid : order == .orderedAscending
            }
        }
    }
}

/// 선택 목록의 검색·선택 상태. 패널이 화면에 그리는 값.
public struct AppPickerModel: Equatable, Sendable {
    /// 정렬된 전체 목록
    public private(set) var all: [AppPickerEntry]
    public private(set) var query: String = ""
    /// 검색 결과
    public private(set) var visible: [AppPickerEntry]
    public private(set) var selection: Int

    /// 처음 열 때는 두 번째 줄(직전 앱)을 선택한다. ⌘Tab처럼 바로 Return이면 직전 앱으로 간다.
    public init(entries: [AppPickerEntry]) {
        all = entries
        visible = entries
        selection = entries.count > 1 ? 1 : 0
    }

    /// 검색어 바꾸기: 이름·번들 ID에 대소문자 무시 포함 검색, 이름이 검색어로 시작하는 앱을 앞으로. 선택은 첫 줄.
    public mutating func setQuery(_ text: String) {
        query = text
        let needle = text.trimmingCharacters(in: .whitespaces)
        selection = 0
        guard !needle.isEmpty else {
            visible = all
            selection = all.count > 1 ? 1 : 0
            return
        }
        func matches(_ value: String?) -> Bool {
            value?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let found = all.filter { matches($0.name) || matches($0.bundleID) }
        // 이름이 검색어로 시작하는 앱을 앞으로 (그 안에서는 원래 순서 유지)
        let prefix = found.filter { $0.name.range(of: needle, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil }
        visible = prefix + found.filter { candidate in !prefix.contains(candidate) }
    }

    /// 줄 직접 고르기 (마우스 클릭)
    public mutating func select(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        selection = index
    }

    /// 위·아래 이동 (끝에서 멈춘다)
    public mutating func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        selection = min(max(selection + delta, 0), visible.count - 1)
    }

    public var selected: AppPickerEntry? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// 같은 이름이 여럿이면 disambiguation을 채운다 (번들 ID가 다르면 번들 ID, 같으면 "PID n")
    public static func disambiguated(_ entries: [AppPickerEntry]) -> [AppPickerEntry] {
        let groups = Dictionary(grouping: entries, by: \.name)
        return entries.map { entry in
            guard let same = groups[entry.name], same.count > 1 else { return entry }
            var copy = entry
            let sameBundle = same.filter { $0.bundleID == entry.bundleID }.count > 1
            copy.disambiguation = sameBundle || entry.bundleID == nil ? "PID \(entry.pid)" : entry.bundleID
            return copy
        }
    }
}
