import AppKit
import CoreGraphics

/// 모니터별 데스크탑(Space) 목록 읽기. 공개 API가 없어 읽기 전용 비공개 함수(CGSCopyManagedDisplaySpaces)를
/// 실행 중에 찾아 쓴다 (dlsym — 없으면 nil을 돌려주고 기능은 "알 수 없음"으로 처리). 창을 옮기거나 바꾸지는 않는다.
enum SpaceService {
    /// 한 모니터의 데스크탑 상태. 전체 화면 앱 공간도 데스크탑 이동 단축키가 거쳐 가므로 순서에 포함한다.
    struct DisplaySpaces: Equatable {
        /// 지금 보이는 공간의 순서 (0부터)
        let currentIndex: Int
        /// 그 모니터의 공간 수
        let count: Int
    }

    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias CopySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// RTLD_DEFAULT: 이미 올라온 모든 라이브러리(CoreGraphics·SkyLight)에서 찾는다
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(defaultHandle, name) { return unsafeBitCast(pointer, to: type) }
        }
        return nil
    }

    /// point가 있는 모니터의 데스크탑 상태. 읽지 못하면 nil.
    static func spaces(onDisplayContaining point: CGPoint) -> DisplaySpaces? {
        var displayID: CGDirectDisplayID = 0
        var found: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &found) == .success, found > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid) as String?,
              let mainConnection = symbol(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFunction.self),
              let copySpaces = symbol(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopySpacesFunction.self),
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        // 모니터마다 따로 Space를 쓰지 않으면 "Main" 하나뿐이다
        let entry = displays.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuidString) == .orderedSame }
            ?? (displays.count == 1 ? displays.first : nil)
        guard let entry,
              let spaces = entry["Spaces"] as? [[String: Any]],
              let current = entry["Current Space"] as? [String: Any],
              let currentID = spaceID(current),
              let index = spaces.firstIndex(where: { spaceID($0) == currentID }) else {
            return nil
        }
        return DisplaySpaces(currentIndex: index, count: spaces.count)
    }

    private static func spaceID(_ space: [String: Any]) -> Int? {
        (space["ManagedSpaceID"] as? Int) ?? (space["id64"] as? Int)
    }
}
