// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MihomoBar",
    platforms: [.macOS(.v13)],
    targets: [
        // 应用与特权助手共用的协议定义，避免两边的字段拼写漂移
        .target(
            name: "HelperProtocol",
            path: "Sources/HelperProtocol"
        ),
        // 菜单栏 GUI，以当前用户身份运行
        .executableTarget(
            name: "MihomoBar",
            dependencies: ["HelperProtocol"],
            path: "Sources/MihomoBar"
        ),
        // 特权助手，以 root 身份常驻运行
        .executableTarget(
            name: "MihomoBarHelper",
            dependencies: ["HelperProtocol"],
            path: "Sources/MihomoBarHelper"
        ),
    ]
)
