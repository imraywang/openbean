// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 录音库在哪：正式版 `~/Library/Application Support/openbean/Library`，
/// 开发版（OpenBean Dev，应用标识以 .dev 结尾）`…/openbean-dev/Library`，或者任意指定的目录（测试用）。
public struct LibraryLocation: Sendable, Equatable {
    public enum Flavor: String, Sendable {
        case release, dev, custom
    }

    /// Library 文件夹
    public var folder: URL
    public var flavor: Flavor

    public init(folder: URL, flavor: Flavor) {
        self.folder = folder
        self.flavor = flavor
    }

    /// 环境变量：指向数据目录或 Library 文件夹
    public static let environmentKey = "OPENBEAN_LIBRARY"

    /// 「打开录音」链接的前缀：开发版的录音给开发版的链接，免得交给正式版去打开
    public var linkScheme: String { flavor == .dev ? "openbean-dev" : "openbean" }

    /// 按优先级选：--library 路径 > 环境变量 > --dev > 可执行文件所在 .app 的应用标识 > 正式版
    /// - Parameters:
    ///   - support: 用户的 Application Support 目录（测试时换成临时目录）
    ///   - executable: 本程序的路径；在 .app 包里时按包的应用标识选正式版或开发版
    public static func resolve(path: String?, dev: Bool, environment: [String: String],
                               executable: URL?, support: URL? = nil) -> LibraryLocation {
        if let p = path ?? environment[environmentKey], !p.isEmpty {
            return LibraryLocation(folder: libraryFolder(for: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)),
                                   flavor: .custom)
        }
        let isDev = dev || (executable.flatMap(enclosingBundleIdentifier)?.hasSuffix(".dev") ?? false)
        let base = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryLocation(folder: base.appendingPathComponent(isDev ? "openbean-dev" : "openbean")
            .appendingPathComponent("Library"), flavor: isDev ? .dev : .release)
    }

    /// 给的可能是数据目录，也可能直接是 Library 文件夹
    static func libraryFolder(for url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("index.json").path) { return url }
        if fm.fileExists(atPath: url.appendingPathComponent("Library").path) { return url.appendingPathComponent("Library") }
        return url.lastPathComponent == "Library" ? url : url.appendingPathComponent("Library")
    }

    /// 可执行文件在某个 .app 里（如 OpenBean.app/Contents/Helpers/openbean-mcp）时，那个包的应用标识
    public static func enclosingBundleIdentifier(_ executable: URL) -> String? {
        enclosingBundle(executable).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// 可执行文件所在的 .app（顺着上级目录找）
    public static func enclosingBundle(_ executable: URL) -> URL? {
        var u = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while u.path != "/" && !u.path.isEmpty {
            if u.pathExtension == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }
}
