import CoreGraphics
import Foundation

/// CG 창 목록 한 항목 (앞에서 뒤 순서). 제목은 쓰지 않는다.
public struct CGWindowRecord: Equatable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var frame: CGRect

    public init(windowID: UInt32, pid: Int32, frame: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
    }
}

/// AX 창 한 항목. index는 호출 쪽이 들고 있는 AXUIElement 배열의 위치.
public struct AXWindowRecord: Equatable, Sendable {
    public var index: Int
    public var pid: Int32
    public var frame: CGRect

    public init(index: Int, pid: Int32, frame: CGRect) {
        self.index = index
        self.pid = pid
        self.frame = frame
    }
}

/// PID + 위치·크기로 CG 창과 AX 창을 일대일 연결한다.
/// 같은 앱에 위치·크기가 같은 창이 여럿이면(최대화한 창 등) 양쪽 목록의 앞→뒤 순서로 짝짓는다.
/// 양쪽 개수가 다르면 모호하므로 연결하지 않는다.
public enum WindowMatcher {
    /// 위치·크기 비교 허용 오차(pt)
    public static let frameTolerance: CGFloat = 2

    /// windowID → AX index.
    /// - cg: 앞에서 뒤 순서 (CGWindowListCopyWindowInfo 순서)
    /// - ax: 앱마다 kAXWindowsAttribute 순서(앞에서 뒤)대로 index가 증가해야 한다
    public static func match(cg: [CGWindowRecord], ax: [AXWindowRecord]) -> [UInt32: Int] {
        let axByPID = Dictionary(grouping: ax.sorted { $0.index < $1.index }, by: \.pid)
        let cgByPID = Dictionary(grouping: cg, by: \.pid)
        var result: [UInt32: Int] = [:]
        for window in cg {
            let axMatches = (axByPID[window.pid] ?? []).filter { framesMatch($0.frame, window.frame) }
            guard let firstAX = axMatches.first else { continue }
            let cgMatches = (cgByPID[window.pid] ?? []).filter { framesMatch($0.frame, firstAX.frame) }
            // 같은 크기 창 묶음이 양쪽에서 같은 개수일 때만 순서로 짝짓는다
            guard cgMatches.count == axMatches.count,
                  let rank = cgMatches.firstIndex(where: { $0.windowID == window.windowID }) else { continue }
            result[window.windowID] = axMatches[rank].index
        }
        return result
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
}
