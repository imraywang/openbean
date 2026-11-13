// SPDX-License-Identifier: Apache-2.0
// bin/ui-shots 的小帮手（bin/ui-shots 用 swiftc 编译到 .build/ui-shots-helper）：
//   preflight        有没有屏幕录制权限（没有时截出来的窗口是空白），没有返回 1
//   request          弹系统的屏幕录制授权请求
//   menu <pid>       这个进程打开着的菜单窗口号（层级 ≥ 101），按面积从大到小，每行一个
//   windows <pid>    列出这个进程的所有窗口（调试用）
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst()

func windows(of pid: Int32) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
}

func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}

switch args.first {
case "preflight":
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
case "request":
    exit(CGRequestScreenCaptureAccess() ? 0 : 1)
case "menu":
    guard let pid = args.dropFirst().first.flatMap({ Int32($0) }) else { exit(2) }
    for w in windows(of: pid).filter({ ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101 }).sorted(by: { area($0) > area($1) }) {
        print(w[kCGWindowNumber as String] as? Int ?? 0)
    }
case "windows":
    guard let pid = args.dropFirst().first.flatMap({ Int32($0) }) else { exit(2) }
    for w in windows(of: pid) {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(w[kCGWindowNumber as String] ?? 0, "layer", w[kCGWindowLayer as String] ?? 0,
              "\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))", w[kCGWindowName as String] ?? "")
    }
default:
    print("usage: ui-shots-helper preflight|request|menu <pid>|windows <pid>")
    exit(2)
}
