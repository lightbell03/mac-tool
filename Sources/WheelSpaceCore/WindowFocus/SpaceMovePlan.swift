import CoreGraphics

/// 창을 옮길 데스크탑 방향 (같은 모니터의 왼쪽·오른쪽 데스크탑)
public enum SpaceDirection: String, CaseIterable, Codable, Sendable {
    case left
    case right

    /// 데스크탑 이동 단축키(⌃← / ⌃→) 방향
    public var switchDirection: SwitchDirection {
        self == .left ? .left : .right
    }
}

/// 창을 옆 데스크탑으로 보낼 때 할 일
public enum SpaceMoveStep: Equatable, Sendable {
    /// 그 방향에 데스크탑이 있다 — 창을 옮기고 넘긴다
    case move
    /// 오른쪽 끝이다 — 데스크탑을 만든 뒤 넘긴다 (Mission Control은 새 데스크탑을 맨 끝에 만든다)
    case createThenMove
    /// 그 방향에 데스크탑이 없고 만들지 않는다 (만들기 꺼짐, 또는 왼쪽 끝 — 맨 앞에는 만들 수 없다)
    case noSpace
}

/// 창을 옆 데스크탑으로 보내기의 순수 판단: 할 일.
public enum SpaceMovePlan {
    /// currentIndex: 그 모니터에서 지금 데스크탑의 순서(0부터), spaceCount: 그 모니터의 데스크탑 수 (전체 화면 앱 공간 제외)
    public static func step(currentIndex: Int, spaceCount: Int, direction: SpaceDirection, createIfMissing: Bool) -> SpaceMoveStep {
        switch direction {
        case .left:
            return currentIndex > 0 ? .move : .noSpace
        case .right:
            if currentIndex < spaceCount - 1 { return .move }
            return createIfMissing ? .createThenMove : .noSpace
        }
    }
}
