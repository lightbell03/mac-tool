import Foundation

/// 창 포커스 이동 방향.
public enum FocusDirection: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case up
    case down
}

/// 키보드 포커스가 다른 모니터의 창으로 넘어갔을 때 마우스 포인터를 따라 옮길지.
public enum PointerFollowMode: String, CaseIterable, Codable, Sendable {
    case off
    /// 창 포커스 이동(⌃⌥방향키)으로 다른 모니터의 창에 갔을 때만 (이전 "포인터도 같이 이동" 켜짐과 같음)
    case focusMoves
    /// 위에 더해 Spotlight·⌘Tab·Dock·알림 클릭 등 어떤 방법으로든 포커스가 다른 모니터의 창으로 넘어가면
    case allFocusChanges
}

public struct FocusSettings: Equatable, Sendable {
    /// 기본 단축키: ⌃⌥ + 방향키. VoiceOver(⌃⌥ = VO 키)와 겹칠 수 있어 재지정을 제공한다.
    public static let defaults = FocusSettings(
        isEnabled: true,
        leftShortcut: KeyCombo(keyCode: 0x7B, modifiers: [.control, .option], keyLabel: "←"),
        rightShortcut: KeyCombo(keyCode: 0x7C, modifiers: [.control, .option], keyLabel: "→"),
        upShortcut: KeyCombo(keyCode: 0x7E, modifiers: [.control, .option], keyLabel: "↑"),
        downShortcut: KeyCombo(keyCode: 0x7D, modifiers: [.control, .option], keyLabel: "↓"),
        pointerFollow: .off,
        // ⌥` — ⌘`(같은 앱 창 순환)와 같은 자리. ⌥⇥는 키보드 포인터가 쓴다.
        switcherShortcut: KeyCombo(keyCode: 50, modifiers: .option, keyLabel: "`"),
        // ⌃⌥] 뒤로 / ⌃⌥[ 앞으로 — ⌘`(같은 앱 창 순환)는 macOS 기본이라 쓰지 않는다
        stackNextShortcut: KeyCombo(keyCode: 30, modifiers: [.control, .option], keyLabel: "]"),
        stackPreviousShortcut: KeyCombo(keyCode: 33, modifiers: [.control, .option], keyLabel: "["),
        // 창을 다른 모니터로 보내기: 포커스 이동(⌃⌥ + 방향키)에 ⌘를 더한 조합
        moveLeftShortcut: KeyCombo(keyCode: 0x7B, modifiers: [.control, .option, .command], keyLabel: "←"),
        moveRightShortcut: KeyCombo(keyCode: 0x7C, modifiers: [.control, .option, .command], keyLabel: "→"),
        moveUpShortcut: KeyCombo(keyCode: 0x7E, modifiers: [.control, .option, .command], keyLabel: "↑"),
        moveDownShortcut: KeyCombo(keyCode: 0x7D, modifiers: [.control, .option, .command], keyLabel: "↓"),
        // 데스크탑은 [ ]: 창을 들고 옆 데스크탑으로 ⌃⌥⇧[ ], 새 데스크탑 만들기 ⌃⌥⌘] (겹친 창 넘기기 ⌃⌥[ ]와 같은 키).
        // 화면만 넘기기는 macOS 기본 ⌃← / ⌃→를 쓴다.
        spaceLeftShortcut: KeyCombo(keyCode: 33, modifiers: [.control, .option, .shift], keyLabel: "["),
        spaceRightShortcut: KeyCombo(keyCode: 30, modifiers: [.control, .option, .shift], keyLabel: "]"),
        createSpaceShortcut: KeyCombo(keyCode: 30, modifiers: [.control, .option, .command], keyLabel: "]"),
        createSpaceIfMissing: true
    )

    public var isEnabled: Bool
    /// nil = 해제
    public var leftShortcut: KeyCombo?
    public var rightShortcut: KeyCombo?
    public var upShortcut: KeyCombo?
    public var downShortcut: KeyCombo?
    /// 포커스가 다른 모니터의 창으로 옮겨지면 마우스 포인터도 그 창으로 옮긴다 (클릭은 하지 않음)
    public var pointerFollow: PointerFollowMode
    /// 창 목록 전환기: 보조키를 누른 채 이 키 → 현재 모니터의 창 목록, 보조키를 떼면 선택한 창으로 (nil = 해제)
    public var switcherShortcut: KeyCombo?
    /// 키보드 포인터의 함께 누르고 있을 키(⌥⇥의 Tab)를 누른 채일 때만 전환기를 연다 (⌥⇥ + `). 그 밖의 ⌥`는 앱으로.
    public var switcherRequiresHeldKey: Bool
    /// 겹친 창 넘기기: 뒤로(밑에 깔린 창을 앞으로) / 앞으로(직전 창으로) (nil = 해제)
    public var stackNextShortcut: KeyCombo?
    public var stackPreviousShortcut: KeyCombo?
    /// 창을 다른 모니터로 보내기: 지금 창을 그 방향의 모니터로, 위치·비율 그대로 (nil = 해제)
    public var moveLeftShortcut: KeyCombo?
    public var moveRightShortcut: KeyCombo?
    public var moveUpShortcut: KeyCombo?
    public var moveDownShortcut: KeyCombo?
    /// 창을 같은 모니터의 옆 데스크탑으로 보내기 (nil = 해제)
    public var spaceLeftShortcut: KeyCombo?
    public var spaceRightShortcut: KeyCombo?
    /// 지금 창이 있는 모니터에 새 데스크탑 만들기 (맨 끝에, 넘어가지는 않는다. nil = 해제)
    public var createSpaceShortcut: KeyCombo?
    /// 오른쪽에 데스크탑이 없으면 만들어서 보낸다·넘긴다
    public var createSpaceIfMissing: Bool

    public init(
        isEnabled: Bool,
        leftShortcut: KeyCombo?,
        rightShortcut: KeyCombo?,
        upShortcut: KeyCombo?,
        downShortcut: KeyCombo?,
        pointerFollow: PointerFollowMode = .off,
        switcherShortcut: KeyCombo? = nil,
        switcherRequiresHeldKey: Bool = false,
        stackNextShortcut: KeyCombo? = nil,
        stackPreviousShortcut: KeyCombo? = nil,
        moveLeftShortcut: KeyCombo? = nil,
        moveRightShortcut: KeyCombo? = nil,
        moveUpShortcut: KeyCombo? = nil,
        moveDownShortcut: KeyCombo? = nil,
        spaceLeftShortcut: KeyCombo? = nil,
        spaceRightShortcut: KeyCombo? = nil,
        createSpaceShortcut: KeyCombo? = nil,
        createSpaceIfMissing: Bool = true
    ) {
        self.createSpaceShortcut = createSpaceShortcut
        self.spaceLeftShortcut = spaceLeftShortcut
        self.spaceRightShortcut = spaceRightShortcut
        self.createSpaceIfMissing = createSpaceIfMissing
        self.moveLeftShortcut = moveLeftShortcut
        self.moveRightShortcut = moveRightShortcut
        self.moveUpShortcut = moveUpShortcut
        self.moveDownShortcut = moveDownShortcut
        self.stackNextShortcut = stackNextShortcut
        self.stackPreviousShortcut = stackPreviousShortcut
        self.switcherRequiresHeldKey = switcherRequiresHeldKey
        self.pointerFollow = pointerFollow
        self.switcherShortcut = switcherShortcut
        self.isEnabled = isEnabled
        self.leftShortcut = leftShortcut
        self.rightShortcut = rightShortcut
        self.upShortcut = upShortcut
        self.downShortcut = downShortcut
    }

    public func shortcut(for direction: FocusDirection) -> KeyCombo? {
        switch direction {
        case .left: return leftShortcut
        case .right: return rightShortcut
        case .up: return upShortcut
        case .down: return downShortcut
        }
    }

    public mutating func setShortcut(_ combo: KeyCombo?, for direction: FocusDirection) {
        switch direction {
        case .left: leftShortcut = combo
        case .right: rightShortcut = combo
        case .up: upShortcut = combo
        case .down: downShortcut = combo
        }
    }

    public func moveShortcut(for direction: FocusDirection) -> KeyCombo? {
        switch direction {
        case .left: return moveLeftShortcut
        case .right: return moveRightShortcut
        case .up: return moveUpShortcut
        case .down: return moveDownShortcut
        }
    }

    public mutating func setMoveShortcut(_ combo: KeyCombo?, for direction: FocusDirection) {
        switch direction {
        case .left: moveLeftShortcut = combo
        case .right: moveRightShortcut = combo
        case .up: moveUpShortcut = combo
        case .down: moveDownShortcut = combo
        }
    }

    public func spaceShortcut(for direction: SpaceDirection) -> KeyCombo? {
        direction == .left ? spaceLeftShortcut : spaceRightShortcut
    }

    public mutating func setSpaceShortcut(_ combo: KeyCombo?, for direction: SpaceDirection) {
        switch direction {
        case .left: spaceLeftShortcut = combo
        case .right: spaceRightShortcut = combo
        }
    }

    /// 보조키 없는 조합은 해제, 방향끼리 같은 조합은 뒤 방향(선언 순서 기준)을 해제.
    /// 전환기·겹친 창 넘기기·다른 모니터로 보내기 단축키도 보조키가 없거나 앞의 단축키와 같으면 해제한다.
    public func validated() -> FocusSettings {
        var copy = self
        var used: Set<KeyCombo> = []
        for direction in FocusDirection.allCases {
            guard let combo = copy.shortcut(for: direction) else { continue }
            let key = KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers, keyLabel: "")
            if !combo.isValidGlobalShortcut || !used.insert(key).inserted {
                copy.setShortcut(nil, for: direction)
            }
        }
        for keyPath in [
            \FocusSettings.switcherShortcut, \.stackNextShortcut, \.stackPreviousShortcut,
            \.moveLeftShortcut, \.moveRightShortcut, \.moveUpShortcut, \.moveDownShortcut,
            \.spaceLeftShortcut, \.spaceRightShortcut, \.createSpaceShortcut,
        ] {
            guard let combo = copy[keyPath: keyPath] else { continue }
            let key = KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers, keyLabel: "")
            if !combo.isValidGlobalShortcut || !used.insert(key).inserted {
                copy[keyPath: keyPath] = nil
            }
        }
        return copy
    }
}
