// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 任意 JSON 值。整数和小数分开存，请求 id 原样回传。
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var object: [String: JSON]? { if case let .object(o) = self { return o } else { return nil } }
    public var array: [JSON]? { if case let .array(a) = self { return a } else { return nil } }
    public var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }

    /// 数字（整数或小数）
    public var number: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    // MARK: 编解码

    /// 解析一行；不是合法 JSON 返回 nil
    public static func parse(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: any)
    }

    init?(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let a as [Any]:
            var out: [JSON] = []
            for v in a { guard let j = JSON(any: v) else { return nil }; out.append(j) }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSON] = [:]
            for (k, v) in o { guard let j = JSON(any: v) else { return nil }; out[k] = j }
            self = .object(out)
        default: return nil
        }
    }

    /// 编成一行（键排序，不含换行：字符串里的换行会被转义）
    public var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .double(d):
            if !d.isFinite { out += "null" } else if d == d.rounded(), abs(d) < 1e15 { out += String(Int(d)) } else { out += String(d) }
        case let .string(s): JSON.escape(s, into: &out)
        case let .array(a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(to: &out) }
            out += "]"
        case let .object(o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                JSON.escape(k, into: &out)
                out += ":"
                o[k]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

extension JSON {
    /// 可选值：nil 编成 null
    static func from(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    static func from(_ d: Double?) -> JSON { d.map { .double($0) } ?? .null }
}
