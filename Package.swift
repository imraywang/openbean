// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "openbean",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OpenBeanKit", targets: ["OpenBeanKit"]),
        .library(name: "OpenBeanVoice", targets: ["OpenBeanVoice"]),
        .library(name: "OpenBeanLibrary", targets: ["OpenBeanLibrary"]),
        .executable(name: "openbean", targets: ["openbean"]),
        .executable(name: "openbean-mcp", targets: ["openbean-mcp"]),
    ],
    targets: [
        .target(name: "OpenBeanKit"),
        // 只读访问 App 的录音库（index.json、转写、摘要）；只用 Foundation，不碰蓝牙
        .target(name: "OpenBeanLibrary"),
        // 只读 MCP 服务（stdio，手写的 JSON-RPC，不引入依赖）：协议层和工具在 OpenBeanMCP，可执行文件只管收发
        .target(name: "OpenBeanMCP", dependencies: ["OpenBeanLibrary"]),
        .executableTarget(name: "openbean-mcp", dependencies: ["OpenBeanMCP", "OpenBeanLibrary"]),
        // sherpa-onnx 动态库由 Scripts/fetch-deps.sh 放到 Vendor/sherpa-onnx
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .target(
            name: "OpenBeanVoice",
            // OpenBeanLibrary：对话段和日记的数据格式（段摘要、日记合成写的就是它们）
            dependencies: ["OpenBeanKit", "OpenBeanLibrary", "CSherpaOnnx"],
            linkerSettings: [
                // 绝对路径：Xcode 工程（App/）编译这个包时工作目录不是包根目录
                .unsafeFlags(["-L\(Context.packageDirectory)/Vendor/sherpa-onnx/lib",
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
        // 批量离线识别（评测用）：sv-batch [选项] <模型目录> <文件列表> <输出.jsonl>，见 Sources/sv-batch/main.swift
        .executableTarget(
            name: "sv-batch",
            dependencies: ["OpenBeanVoice"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/Vendor/sherpa-onnx/lib"])]
        ),
        .testTarget(name: "OpenBeanKitTests", dependencies: ["OpenBeanKit"]),
        .testTarget(name: "OpenBeanLibraryTests", dependencies: ["OpenBeanLibrary"]),
        // 依赖可执行文件：swift test 会先编好 openbean-mcp，端到端测试直接起进程
        .testTarget(name: "OpenBeanMCPTests", dependencies: ["OpenBeanMCP", "OpenBeanLibrary", "openbean-mcp"]),
        .testTarget(
            name: "OpenBeanVoiceTests",
            dependencies: ["OpenBeanVoice"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Vendor/sherpa-onnx/lib",
                                           "-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/Vendor/sherpa-onnx/lib"])]
        ),
    ]
)
