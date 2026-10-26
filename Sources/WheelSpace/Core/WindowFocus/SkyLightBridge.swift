import AppKit
import CoreGraphics

/// 창을 다른 데스크탑(Space)으로 옮기는 비공개 SkyLight 연산. 공개 API가 없고 예전 함수(CGSMoveWindowsToManagedSpace)는
/// SIP 없이 막혔지만, "bridged" 연산(SLSBridgedMoveWindowsToManagedSpaceOperation)은 SIP를 켠 채로 동작한다
/// (macOS 26.3 실측). 실행 중에 찾아 쓰고, 없으면 isAvailable이 false — macOS가 바꾸면 기능만 꺼진다.
/// 앱에 AppKit이 올라와 있어야 한다 (없으면 WindowServer가 아무 오류 없이 무시한다는 보고가 있다).
enum SkyLightBridge {
    private static let moveOperationClass = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    private static let allocSelector = NSSelectorFromString("alloc")
    private static let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
    private static let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    // init은 alloc한 객체를 소비하고 새 객체를 +1로 돌려주므로 ARC가 끼어들지 않게 포인터로 주고받는다
    private typealias AllocFunction = @convention(c) (AnyClass, Selector) -> OpaquePointer?
    private typealias InitFunction = @convention(c) (OpaquePointer, Selector, NSArray, UInt64) -> OpaquePointer?
    private typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Void
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFunction = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// RTLD_DEFAULT: 이미 올라온 모든 라이브러리(CoreGraphics·SkyLight)에서 찾는다
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    /// SLSCopySpacesForWindows 마스크: 지금 보이는·안 보이는 데스크탑 모두
    private static let allSpacesMask: Int32 = 0x7

    private static func symbol<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(defaultHandle, name) { return unsafeBitCast(pointer, to: type) }
        }
        return nil
    }

    private static var moveClass: AnyClass? {
        guard let cls = NSClassFromString(moveOperationClass),
              class_getInstanceMethod(cls, initSelector) != nil,
              class_getInstanceMethod(cls, performSelector) != nil,
              class_getClassMethod(cls, allocSelector) != nil else { return nil }
        return cls
    }

    /// 이 macOS에 이동 연산과 창의 데스크탑 조회 함수가 있는지
    static var isAvailable: Bool {
        moveClass != nil
            && symbol(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFunction.self) != nil
            && symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFunction.self) != nil
    }

    /// 창들을 그 데스크탑으로 옮겨 달라고 보낸다 (비동기 — 실제로 옮겨졌는지는 spaceIDs(ofWindow:)로 확인한다).
    /// 연산을 만들지 못하면 false.
    static func moveWindows(_ windowIDs: [CGWindowID], toSpace spaceID: UInt64) -> Bool {
        guard let cls = moveClass,
              let allocMethod = class_getClassMethod(cls, allocSelector),
              let initIMP = class_getMethodImplementation(cls, initSelector),
              let performIMP = class_getMethodImplementation(cls, performSelector) else { return false }
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFunction.self)
        let initialize = unsafeBitCast(initIMP, to: InitFunction.self)
        let perform = unsafeBitCast(performIMP, to: PerformFunction.self)

        guard let allocated = alloc(cls, allocSelector),
              let created = initialize(allocated, initSelector, windowIDs.map { NSNumber(value: $0) } as NSArray, spaceID)
        else { return false }
        let operation = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(created)).takeRetainedValue()
        perform(operation, performSelector)
        return true
    }

    /// 창이 속한 데스크탑 ID들 (SLSCopySpacesForWindows). 읽지 못하면 nil.
    static func spaceIDs(ofWindow windowID: CGWindowID) -> [UInt64]? {
        guard let mainConnection = symbol(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFunction.self),
              let copySpaces = symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFunction.self)
        else { return nil }
        // 창 번호는 SInt32 CFNumber로 넘긴다 (WindowServer의 창 번호 형식)
        var value = Int32(bitPattern: windowID)
        guard let number = CFNumberCreate(nil, .sInt32Type, &value),
              let result = copySpaces(mainConnection(), allSpacesMask, [number] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return result.map(\.uint64Value)
    }
}
