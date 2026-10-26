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
    /// 그 방향에 데스크탑이 있다 — 창을 쥔 채 넘긴다
    case move
    /// 오른쪽 끝이다 — 데스크탑을 만든 뒤 넘긴다 (Mission Control은 새 데스크탑을 맨 끝에 만든다)
    case createThenMove
    /// 그 방향에 데스크탑이 없고 만들지 않는다 (만들기 꺼짐, 또는 왼쪽 끝 — 맨 앞에는 만들 수 없다)
    case noSpace
}

/// 창을 옆 데스크탑으로 보내기의 순수 판단: 할 일, 창을 잡을 자리.
public enum SpaceMovePlan {
    /// 제목 요소를 제목 줄로 믿는 창 위쪽 범위
    private static let titleBandHeight: CGFloat = 50

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

    /// 창을 잡을 자리 (CG 전역 좌표). 제목 줄 요소를 알면 그 가운데, 모르면 창 맨 위 띠의 빈 곳.
    /// 왼쪽 위 신호등 버튼과 Chrome 같은 탭 줄을 피하려고, 제목 요소가 없으면 창 위쪽 가장자리 바로 아래·오른쪽 끝 근처를 잡는다.
    public static func grabPoint(windowFrame: CGRect, titleFrame: CGRect?) -> CGPoint {
        if let titleFrame, titleFrame.width > 0, titleFrame.height > 0,
           titleFrame.minY - windowFrame.minY <= titleBandHeight, windowFrame.contains(CGPoint(x: titleFrame.midX, y: titleFrame.midY)) {
            return CGPoint(x: titleFrame.midX, y: titleFrame.midY)
        }
        // 가장자리 크기 조절 영역(몇 pt)을 피해 위쪽 띠 안쪽을 잡는다
        return CGPoint(x: windowFrame.maxX - min(windowFrame.width * 0.15, 120), y: windowFrame.minY + 12)
    }
}
