// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "openbean",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OpenBeanKit", targets: ["OpenBeanKit"]),
        .executable(name: "openbean", targets: ["openbean"]),
    ],
    targets: [
        .target(name: "OpenBeanKit"),
        .executableTarget(
            name: "openbean",
            dependencies: ["OpenBeanKit"],
            linkerSettings: [
                // 命令行程序没有 bundle，macOS 要求声明蓝牙用途，否则访问 CoreBluetooth 会被系统终止
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"]),
            ]
        ),
        .testTarget(name: "OpenBeanKitTests", dependencies: ["OpenBeanKit"]),
    ]
)
