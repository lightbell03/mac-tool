import Foundation

/// 키보드 포인터 단축키에 쓰는 일반 키 하나 (보조키 없이).
public struct PointerKey: Equatable, Hashable, Codable, Sendable {
    public var keyCode: UInt16
    /// 기록 시점의 표시 문자 ("R", "↩", "⇥"). 키 코드→문자 변환을 표시 때마다 하지 않으려고 저장한다.
    public var keyLabel: String

    public init(keyCode: UInt16, keyLabel: String) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }
}

/// 키보드 포인터가 필수 조합 + 동작 키로 실행하는 일
public enum PointerAction: String, CaseIterable, Codable, Sendable {
    case leftClick
    case rightClick
    case doubleClick
    case drag
}

/// 스크롤·빠르게처럼 "더 누르면 동작이 바뀌는" 키: 보조키 하나, 또는 누르고 있는 일반 키 하나.
/// 일반 키는 방향키 이벤트에 표시되지 않아 입력 판정이 누름·뗌을 직접 추적한다 (누르고 있는 키 Tab과 같은 방식).
public enum PointerModeKey: Equatable, Hashable, Codable, Sendable {
    case modifier(ModifierState)
    case key(PointerKey)

    /// 표시 문자: 보조키는 기호("⌘"), 일반 키는 키 이름("S")
    public var label: String {
        switch self {
        case .modifier(let modifier): return PointerShortcut.symbol(for: modifier)
        case .key(let key): return key.keyLabel
        }
    }
}

/// 포인터 모드(고정 모드) 켜는 방법. vi의 일반 모드처럼, 포인터 모드에서는 필수 보조키·누르고 있는 키 없이
/// 방향키·동작 키·스크롤·빠르게 키가 동작하고 그 밖의 글자 키는 앱에 보내지 않는다. 입력 키(i)를 누르면 평소(입력 모드)로 돌아간다.
public enum PointerLockToggle: Equatable, Codable, Sendable {
    case off
    /// 필수 보조키를 누른 채 누르고 있는 키(Tab)를 빠르게 두 번 (⌥Tab 두 번)
    case doubleTapHeldKey
    /// 일반 단축키 (보조키 + 키)
    case shortcut(KeyCombo)
}

/// 왼손 모드 배치 (고정, 한 손으로 방향과 동작을 함께 다루게 단순하게): WASD 이동, R·F·E·T 위·아래·왼쪽·오른쪽 스크롤
/// (R을 가운데 둔 십자),
/// Space 클릭(두 번 = 더블클릭), C 오른쪽 클릭, V 드래그 시작·놓기(토글). 누른 채 쓰는 키는 빠르게 키(기본 ⇧)뿐이다.
/// 왼손 모드는 ⌥⇧⇥ 두 번(누르고 있는 키 두 번에 ⇧를 더해)으로 들어가거나, 포인터 모드에서 Q로 바꾼다.
/// 방향키·↩도 함께 동작한다.
public enum LeftHandLayout {
    public static let up: UInt16 = 13        // W
    public static let left: UInt16 = 0       // A
    public static let down: UInt16 = 1       // S
    public static let right: UInt16 = 2      // D
    public static let scrollUp: UInt16 = 15  // R
    public static let scrollDown: UInt16 = 3 // F
    public static let scrollLeft: UInt16 = 14 // E
    public static let scrollRight: UInt16 = 17 // T
    public static let leftClick: UInt16 = 49 // Space
    public static let rightClick: UInt16 = 8 // C
    public static let dragToggle: UInt16 = 9 // V
    /// 포인터 모드에서 일반 ↔ 왼손 모드 바꾸기
    public static let switchMode: UInt16 = 12 // Q

    /// 이동 키의 방향
    public static func arrow(for keyCode: UInt16) -> ArrowKey? {
        switch keyCode {
        case up: return .up
        case left: return .left
        case down: return .down
        case right: return .right
        default: return nil
        }
    }

    /// 스크롤 키의 방향
    public static func scrollArrow(for keyCode: UInt16) -> ArrowKey? {
        switch keyCode {
        case scrollUp: return .up
        case scrollDown: return .down
        case scrollLeft: return .left
        case scrollRight: return .right
        default: return nil
        }
    }

    /// 왼손 모드에서 앱 단축키로 잠깐 해제된 동안(⌘를 쥔 채) 바꿔 보낼 키: WASD → 방향키, Space → ↩
    public static let suspendedRemap: [UInt16: UInt16] = [
        up: 126, left: 123, down: 125, right: 124, leftClick: 36,
    ]

    /// 왼손 배치가 쓰는 모든 키 (왼손 모드에서 이 키들은 왼손 배치로 판정)
    public static let keyCodes: Set<UInt16> = [
        up, left, down, right, scrollUp, scrollDown, scrollLeft, scrollRight, leftClick, rightClick, dragToggle,
    ]
}

/// 포인터 모드에서 ⌘·⌃ 앱 단축키(⌘B 등)를 눌렀을 때
public enum AppShortcutAction: String, Codable, CaseIterable, Sendable {
    /// 보조키(⌘·⌃)를 누르고 있는 동안만 해제: ⌘B·⌘E처럼 이어서 쓰는 단축키는 모두 앱으로, ⌘를 떼면 다시 포인터 모드
    case whileHeld
    /// 잠깐 해제: 단축키 뒤 입력이 없거나, 팝업·목록을 ↩·Esc로 끝내면 다시 포인터 모드
    case suspend
    /// 완전히 해제
    case exit
    /// 아무것도 하지 않음 (포인터 모드 유지)
    case ignore
}

/// 키보드 포인터의 전체 단축키 구성. 프리셋(PointerModifierPair)에서 만들거나 사용자가 하나씩 바꾼다.
public struct PointerShortcut: Equatable, Codable, Sendable {
    /// 저장·적용할 수 없는 구성
    public enum Issue: Equatable, Sendable {
        /// 필수 보조키가 하나도 없음 (일반 타이핑을 가로챈다)
        case emptyBase
        /// 스크롤 키가 보조키라면 정확히 하나가 아니거나 필수 보조키와 겹침 (일반 키는 reservedKey·duplicateKey로 검사)
        case invalidScrollModifier
        /// 빠르게 키가 보조키라면 정확히 하나가 아니거나 필수 보조키와 겹침
        case invalidFastModifier
        case scrollEqualsFast
        /// 느리게 키가 보조키라면 정확히 하나가 아니거나 필수 보조키와 겹침
        case invalidSlowModifier
        /// 느리게 키가 스크롤 키나 빠르게 키와 같음
        case slowEqualsOtherModeKey
        /// 방향키·Esc는 동작 키·누르고 있는 키로 쓸 수 없다
        case reservedKey(PointerKey)
        /// 같은 키를 두 곳(동작 키끼리, 동작 키와 누르고 있는 키)에 지정
        case duplicateKey(PointerKey)
        /// 고정 모드를 "누르고 있는 키 두 번"으로 켜는데 누르고 있는 키가 없음
        case lockToggleNeedsHeldKey
    }

    /// 적용은 되지만 다른 동작을 가리는 구성
    public enum Warning: Equatable, Sendable {
        /// 필수 보조키가 ⌃ 하나: ⌃ + 방향키는 데스크탑 이동·미션 컨트롤이 이벤트 탭과 무관하게 먼저 실행된다
        case systemShortcutConflict
        /// 누르고 있는 키 없이 ⇧ 또는 ⌥ 하나: 선택 영역 확장·단어 이동을 가린다
        case editingShortcutConflict
        /// 누르고 있는 키 없이 스크롤·빠르게 키가 일반 키: 필수 보조키 + 그 키 입력(⌥S 등)을 가린다
        case modeKeyWithoutHeldKey
    }

    /// 기본값: ⌥ + Tab을 누른 채, 스크롤 ⌘, 빠르게 ⇧, ↩ / R / D / G.
    /// 스크롤을 ⌃로 두면 ⌃⌥ + 방향키가 창 포커스 이동 기본 단축키(Carbon 전역 단축키라 이벤트 탭보다 먼저 받는다)와 겹친다.
    public static let defaults = PointerShortcut(
        base: .option,
        heldKey: PointerKey(keyCode: 48, keyLabel: "⇥"),
        scrollKey: .modifier(.command),
        fastKey: .modifier(.shift),
        slowKey: .key(PointerKey(keyCode: 0, keyLabel: "A")),
        leftClickKey: PointerKey(keyCode: 36, keyLabel: "↩"),
        rightClickKey: PointerKey(keyCode: 15, keyLabel: "R"),
        doubleClickKey: PointerKey(keyCode: 2, keyLabel: "D"),
        dragKey: PointerKey(keyCode: 5, keyLabel: "G"),
        lockToggle: .doubleTapHeldKey,
        insertKey: PointerKey(keyCode: 34, keyLabel: "I"),
        exitShortcuts: PointerShortcut.defaultExitShortcuts,
        appShortcutAction: .whileHeld,
        stripsHeldModifier: true,
        keepShortcuts: PointerShortcut.defaultKeepShortcuts
    )

    /// 포인터 모드에서 누르면 포인터 모드를 끄고 그대로 앱에 전달하는 단축키 기본값:
    /// ⌘Space(Spotlight), ⌥Space(ChatGPT 빠른 입력) — 누르자마자 글자를 입력해야 하는 창들
    public static let defaultExitShortcuts = [
        KeyCombo(keyCode: 49, modifiers: .command, keyLabel: "Space"),
        KeyCombo(keyCode: 49, modifiers: .option, keyLabel: "Space"),
    ]

    /// 앱 단축키로 포인터 모드를 꺼도 유지할 단축키 기본값: 편집(⌘C·⌘V·⌘X·⌘Z·⌘⇧Z·⌘A)과 앱 전환(⌘Tab)
    /// — 포인터로 고른 뒤 복사·붙여넣기하거나 다른 앱으로 넘어가 계속 포인터를 쓰는 경우
    public static let defaultKeepShortcuts: [KeyCombo] = [
        KeyCombo(keyCode: 8, modifiers: .command, keyLabel: "C"),
        KeyCombo(keyCode: 9, modifiers: .command, keyLabel: "V"),
        KeyCombo(keyCode: 7, modifiers: .command, keyLabel: "X"),
        KeyCombo(keyCode: 6, modifiers: .command, keyLabel: "Z"),
        KeyCombo(keyCode: 6, modifiers: [.command, .shift], keyLabel: "Z"),
        KeyCombo(keyCode: 0, modifiers: .command, keyLabel: "A"),
        KeyCombo(keyCode: 48, modifiers: .command, keyLabel: "Tab"),
    ]

    /// 방향키·동작 키와 함께 눌러야 하는 보조키
    public var base: ModifierState
    /// 보조키와 함께 누르고 있어야 하는 일반 키 (⌥Tab의 Tab). 없으면 보조키만으로 조합.
    public var heldKey: PointerKey?
    /// 더 누르고 있으면 스크롤 모드가 되는 키
    public var scrollKey: PointerModeKey
    /// 더 누르고 있으면 빠르게 이동·스크롤하는 키
    public var fastKey: PointerModeKey
    /// 더 누르고 있으면 느리게(가속 없이 일정한 느린 속도) 이동·스크롤하는 키. nil이면 쓰지 않는다.
    public var slowKey: PointerModeKey?
    public var leftClickKey: PointerKey
    public var rightClickKey: PointerKey
    public var doubleClickKey: PointerKey
    public var dragKey: PointerKey
    public var lockToggle: PointerLockToggle
    /// 포인터 모드에서 누르면 입력 모드(평소)로 돌아가는 키 (vi의 i)
    public var insertKey: PointerKey
    /// 포인터 모드에서 누르면 포인터 모드를 끄고 단축키는 그대로 앱에 전달 (Spotlight·빠른 입력창 등)
    public var exitShortcuts: [KeyCombo]
    /// 포인터 모드에서 ⌘·⌃ 앱 단축키(⌘B 등)를 누르면 (단축키는 항상 앱에 그대로 간다)
    /// — 단축키가 띄운 팝업·목록을 바로 방향키·↩로 고를 수 있게 잠깐·완전히 해제한다
    public var appShortcutAction: AppShortcutAction
    /// 보조키를 누르는 동안만 해제일 때, ⌘·⌃를 쥔 채 누른 방향키·↩·Esc를 ⌘·⌃ 없이 보낸다 (⌘B 목록을 ↓↓↩로 고르기).
    /// 끄면 ⌘↓ 등 원래 단축키로 간다.
    public var stripsHeldModifier: Bool
    /// 앱 단축키여도 포인터 모드를 유지할 단축키
    public var keepShortcuts: [KeyCombo]

    public init(
        base: ModifierState,
        heldKey: PointerKey?,
        scrollKey: PointerModeKey,
        fastKey: PointerModeKey,
        slowKey: PointerModeKey? = nil,
        leftClickKey: PointerKey,
        rightClickKey: PointerKey,
        doubleClickKey: PointerKey,
        dragKey: PointerKey,
        lockToggle: PointerLockToggle,
        insertKey: PointerKey,
        exitShortcuts: [KeyCombo],
        appShortcutAction: AppShortcutAction = .whileHeld,
        stripsHeldModifier: Bool = true,
        keepShortcuts: [KeyCombo] = PointerShortcut.defaultKeepShortcuts
    ) {
        self.base = base
        self.heldKey = heldKey
        self.scrollKey = scrollKey
        self.fastKey = fastKey
        self.slowKey = slowKey
        self.leftClickKey = leftClickKey
        self.rightClickKey = rightClickKey
        self.doubleClickKey = doubleClickKey
        self.dragKey = dragKey
        self.lockToggle = lockToggle
        self.insertKey = insertKey
        self.exitShortcuts = exitShortcuts
        self.appShortcutAction = appShortcutAction
        self.stripsHeldModifier = stripsHeldModifier
        self.keepShortcuts = keepShortcuts
    }

    /// 스크롤 키가 보조키면 그 보조키, 일반 키면 빈 값. 대입하면 보조키 스크롤 키가 된다.
    public var scrollModifier: ModifierState {
        get { Self.modifier(of: scrollKey) }
        set { scrollKey = .modifier(newValue) }
    }

    /// 빠르게 키가 보조키면 그 보조키, 일반 키면 빈 값. 대입하면 보조키 빠르게 키가 된다.
    public var fastModifier: ModifierState {
        get { Self.modifier(of: fastKey) }
        set { fastKey = .modifier(newValue) }
    }

    /// 느리게 키가 보조키면 그 보조키, 일반 키이거나 없으면 빈 값
    public var slowModifier: ModifierState {
        slowKey.map(Self.modifier(of:)) ?? []
    }

    /// 스크롤 키가 일반 키면 그 키
    public var scrollHeldKey: PointerKey? {
        Self.key(of: scrollKey)
    }

    /// 빠르게 키가 일반 키면 그 키
    public var fastHeldKey: PointerKey? {
        Self.key(of: fastKey)
    }

    /// 느리게 키가 일반 키면 그 키
    public var slowHeldKey: PointerKey? {
        slowKey.flatMap(Self.key(of:))
    }

    private static func modifier(of modeKey: PointerModeKey) -> ModifierState {
        if case .modifier(let modifier) = modeKey { return modifier }
        return []
    }

    private static func key(of modeKey: PointerModeKey) -> PointerKey? {
        if case .key(let key) = modeKey { return key }
        return nil
    }

    // MARK: Codable — 이전 버전 저장값(scrollModifier·fastModifier 숫자)도 읽는다

    private enum CodingKeys: String, CodingKey {
        case base, heldKey, scrollKey, fastKey, slowKey, leftClickKey, rightClickKey, doubleClickKey, dragKey, lockToggle, insertKey, exitShortcuts
        case appShortcutAction, stripsHeldModifier, keepShortcuts
        // 이전 버전
        case exitOnAppShortcut
        case scrollModifier, fastModifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func modeKey(_ key: CodingKeys, legacy: CodingKeys) throws -> PointerModeKey {
            if let value = try container.decodeIfPresent(PointerModeKey.self, forKey: key) { return value }
            // 둘 다 없으면 DecodingError → 저장소가 기본값으로
            return .modifier(try container.decode(ModifierState.self, forKey: legacy))
        }
        base = try container.decode(ModifierState.self, forKey: .base)
        heldKey = try container.decodeIfPresent(PointerKey.self, forKey: .heldKey)
        scrollKey = try modeKey(.scrollKey, legacy: .scrollModifier)
        fastKey = try modeKey(.fastKey, legacy: .fastModifier)
        // null이면 사용자가 없앤 것, 키 자체가 없으면 이전 버전 저장값이라 기본값
        slowKey = container.contains(.slowKey)
            ? try container.decodeIfPresent(PointerModeKey.self, forKey: .slowKey)
            : Self.defaults.slowKey
        leftClickKey = try container.decode(PointerKey.self, forKey: .leftClickKey)
        rightClickKey = try container.decode(PointerKey.self, forKey: .rightClickKey)
        doubleClickKey = try container.decode(PointerKey.self, forKey: .doubleClickKey)
        dragKey = try container.decode(PointerKey.self, forKey: .dragKey)
        // 이전 버전 저장값에는 없다
        lockToggle = try container.decodeIfPresent(PointerLockToggle.self, forKey: .lockToggle) ?? .doubleTapHeldKey
        insertKey = try container.decodeIfPresent(PointerKey.self, forKey: .insertKey) ?? PointerKey(keyCode: 34, keyLabel: "I")
        exitShortcuts = try container.decodeIfPresent([KeyCombo].self, forKey: .exitShortcuts) ?? Self.defaultExitShortcuts
        // 이전 버전은 켜고 끄기만 있었다 (꺼짐 → 아무것도 안 함)
        let legacyExit = try container.decodeIfPresent(Bool.self, forKey: .exitOnAppShortcut)
        appShortcutAction = try container.decodeIfPresent(AppShortcutAction.self, forKey: .appShortcutAction)
            ?? (legacyExit == false ? .ignore : .whileHeld)
        stripsHeldModifier = try container.decodeIfPresent(Bool.self, forKey: .stripsHeldModifier) ?? true
        keepShortcuts = try container.decodeIfPresent([KeyCombo].self, forKey: .keepShortcuts) ?? Self.defaultKeepShortcuts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base, forKey: .base)
        try container.encodeIfPresent(heldKey, forKey: .heldKey)
        try container.encode(scrollKey, forKey: .scrollKey)
        try container.encode(fastKey, forKey: .fastKey)
        // nil도 null로 저장해 "없앰"과 "이전 버전"을 구분한다
        if let slowKey {
            try container.encode(slowKey, forKey: .slowKey)
        } else {
            try container.encodeNil(forKey: .slowKey)
        }
        try container.encode(leftClickKey, forKey: .leftClickKey)
        try container.encode(rightClickKey, forKey: .rightClickKey)
        try container.encode(doubleClickKey, forKey: .doubleClickKey)
        try container.encode(dragKey, forKey: .dragKey)
        try container.encode(lockToggle, forKey: .lockToggle)
        try container.encode(insertKey, forKey: .insertKey)
        try container.encode(exitShortcuts, forKey: .exitShortcuts)
        try container.encode(appShortcutAction, forKey: .appShortcutAction)
        try container.encode(stripsHeldModifier, forKey: .stripsHeldModifier)
        try container.encode(keepShortcuts, forKey: .keepShortcuts)
    }

    /// 방향키·Esc — 포인터 조작 자체에 쓰므로 다른 역할로 지정할 수 없다
    static let reservedKeyCodes: Set<UInt16> = [123, 124, 125, 126, 53]
    private static let singleModifiers: [ModifierState] = [.control, .option, .shift, .command]

    public var issues: [Issue] {
        var result: [Issue] = []
        if base.isEmpty { result.append(.emptyBase) }
        func isValidExtra(_ modifier: ModifierState) -> Bool {
            Self.singleModifiers.contains(modifier) && base.intersection(modifier).isEmpty
        }
        // 일반 키인 스크롤·빠르게 키는 아래 예약 키·중복 검사에서 본다
        if scrollHeldKey == nil, !isValidExtra(scrollModifier) { result.append(.invalidScrollModifier) }
        if fastHeldKey == nil, !isValidExtra(fastModifier) { result.append(.invalidFastModifier) }
        if scrollKey == fastKey { result.append(.scrollEqualsFast) }
        if case .modifier(let modifier) = slowKey, !isValidExtra(modifier) { result.append(.invalidSlowModifier) }
        if let slowKey, slowKey == scrollKey || slowKey == fastKey { result.append(.slowEqualsOtherModeKey) }

        if lockToggle == .doubleTapHeldKey, heldKey == nil { result.append(.lockToggleNeedsHeldKey) }
        let modeKeys = [heldKey, scrollHeldKey, fastHeldKey, slowHeldKey, lockToggle == .off ? nil : insertKey]
        let keys = modeKeys.compactMap { $0 } + PointerAction.allCases.map { key(for: $0) }
        var seen: Set<UInt16> = []
        var reported: Set<UInt16> = []
        for key in keys {
            if Self.reservedKeyCodes.contains(key.keyCode) {
                if reported.insert(key.keyCode).inserted { result.append(.reservedKey(key)) }
            } else if !seen.insert(key.keyCode).inserted, reported.insert(key.keyCode).inserted {
                result.append(.duplicateKey(key))
            }
        }
        return result
    }

    public var isValid: Bool {
        issues.isEmpty
    }

    public var warnings: [Warning] {
        var result: [Warning] = []
        // 누르고 있는 키가 있어도 해당된다: 방향키 이벤트에는 보조키만 표시된다
        if base == .control { result.append(.systemShortcutConflict) }
        if heldKey == nil, base == .shift || base == .option { result.append(.editingShortcutConflict) }
        if heldKey == nil, scrollHeldKey != nil || fastHeldKey != nil || slowHeldKey != nil { result.append(.modeKeyWithoutHeldKey) }
        return result
    }

    public func key(for action: PointerAction) -> PointerKey {
        switch action {
        case .leftClick: return leftClickKey
        case .rightClick: return rightClickKey
        case .doubleClick: return doubleClickKey
        case .drag: return dragKey
        }
    }

    public mutating func setKey(_ key: PointerKey, for action: PointerAction) {
        switch action {
        case .leftClick: leftClickKey = key
        case .rightClick: rightClickKey = key
        case .doubleClick: doubleClickKey = key
        case .drag: dragKey = key
        }
    }

    /// 포인터 모드 해제 단축키인지 (키 코드·보조키 정확히 일치)
    public func isExitShortcut(keyCode: UInt16, modifiers: ModifierState) -> Bool {
        exitShortcuts.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// 포인터 모드에서 앱 단축키로 보고 appShortcutAction을 적용할지: 아무것도 안 함이 아니고 ⌘·⌃가 들어 있고
    /// 유지할 단축키가 아니면. ⌘↑ 같은 방향키 단축키도 포함한다 — 포인터 스크롤·느리게 키로 쓰는 ⌘·⌃ + 방향키는
    /// 입력 판정에서 먼저 포인터가 가져가 여기까지 오지 않는다.
    public func isAppShortcut(keyCode: UInt16, modifiers: ModifierState) -> Bool {
        guard appShortcutAction != .ignore, modifiers.contains(.command) || modifiers.contains(.control) else { return false }
        return !keepShortcuts.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// 입력 판정: 이 키 코드가 동작 키면 그 동작
    public func action(forKeyCode keyCode: UInt16) -> PointerAction? {
        PointerAction.allCases.first { key(for: $0).keyCode == keyCode }
    }

    /// 다른 전역 단축키(창 포커스 이동·한영 변환) 중 이 구성의 방향키 조합과 같은 것.
    /// 전역 단축키가 먼저 키를 가져가 그 조합의 이동·스크롤·빠르게가 동작하지 않는다.
    public func conflicts(with combos: [KeyCombo]) -> [KeyCombo] {
        // 누르고 있는 키는 방향키 이벤트에 표시되지 않으므로 보조키만 비교한다
        let arrowModifiers: [ModifierState] = [
            base, base.union(fastModifier), base.union(scrollModifier), base.union(scrollModifier).union(fastModifier),
        ]
        return combos.filter { (123...126).contains($0.keyCode) && arrowModifiers.contains($0.modifiers) }
    }

    /// 화면 표시용 조합 기호: base ∪ extra를 ⌃⌥⇧⌘ 순서로 + 누르고 있는 키 ("⌥⇥", "⌃⌥⇥")
    public func comboSymbol(adding extra: ModifierState = []) -> String {
        Self.symbol(for: base.union(extra)) + (heldKey?.keyLabel ?? "")
    }

    /// 단축키 표 표시용: 이동 조합에 스크롤·빠르게 키를 더한 조합 ("⌥⌘⇥", "⌥⇥ + S", "⌥⇧⇥ + S")
    public func comboLabel(scroll: Bool = false, fast: Bool = false, slow: Bool = false) -> String {
        var modifiers: ModifierState = []
        var keys: [PointerKey] = []
        let modeKeys: [(Bool, PointerModeKey?)] = [(scroll, scrollKey), (fast, fastKey), (slow, slowKey)]
        for (included, modeKey) in modeKeys where included {
            guard let modeKey else { continue }
            switch modeKey {
            case .modifier(let modifier): modifiers.formUnion(modifier)
            case .key(let key): keys.append(key)
            }
        }
        return ([comboSymbol(adding: modifiers)] + keys.map(\.keyLabel)).joined(separator: " + ")
    }

    /// 보조키 기호. 표시 순서는 macOS 관례(⌃⌥⇧⌘).
    public static func symbol(for modifiers: ModifierState) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }
}
