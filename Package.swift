// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WheelSpace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WheelSpace", targets: ["WheelSpace"]),
    ],
    targets: [
        // macOS UI·이벤트 API에 의존하지 않는 순수 로직 (ScrollPolicy, 설정 모델·저장)
        .target(name: "WheelSpaceCore"),
        // 메뉴 막대 앱 본체 (SwiftUI + AppKit + CoreGraphics 이벤트 탭)
        .executableTarget(
            name: "WheelSpace",
            dependencies: ["WheelSpaceCore"]
        ),
        .testTarget(
            name: "WheelSpaceCoreTests",
            dependencies: ["WheelSpaceCore"]
        ),
    ]
)
