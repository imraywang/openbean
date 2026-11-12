// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "openbean",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OpenBeanKit", targets: ["OpenBeanKit"]),
        .library(name: "OpenBeanVoice", targets: ["OpenBeanVoice"]),
        .executable(name: "openbean", targets: ["openbean"]),
    ],
    targets: [
        .target(name: "OpenBeanKit"),
        // sherpa-onnx 动态库由 Scripts/fetch-deps.sh 放到 Vendor/sherpa-onnx
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .target(
            name: "OpenBeanVoice",
            dependencies: ["OpenBeanKit", "CSherpaOnnx"],
            linkerSettings: [
                .unsafeFlags(["-LVendor/sherpa-onnx/lib",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
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
        .testTarget(
            name: "OpenBeanVoiceTests",
            dependencies: ["OpenBeanVoice"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Vendor/sherpa-onnx/lib",
                                           "-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/Vendor/sherpa-onnx/lib"])]
        ),
    ]
)
