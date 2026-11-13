// SPDX-License-Identifier: Apache-2.0

import CoreBluetooth
import Foundation

public enum LinkError: Error, CustomStringConvertible {
    case bluetooth(String)
    case timeout(String)
    case disconnected
    case missing(String)

    public var description: String {
        switch self {
        case let .bluetooth(s): return "蓝牙不可用：\(s)"
        case let .timeout(s): return "超时：\(s)"
        case .disconnected: return "连接断开"
        case let .missing(s): return "没找到 \(s)"
        }
    }
}

public struct Discovered {
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int
    public let mac: String?
    public let bound: Bool?
    public let serviceMatch: Bool
    public let manufacturer: [UInt8]
}

public enum UUIDs {
    public static let service = CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB")
    public static let write = CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB")
    public static let notify = CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB")
}

/// CoreBluetooth 薄封装。所有状态只在 `q` 上读写。
public final class Link: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let q = DispatchQueue(label: "d3200.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var assembler = FrameAssembler()
    /// 完整连上（通知已打开）之后才为 true；连接过程中失败/超时导致的断开不算「掉线」
    private var established = false

    private var poweredOn: CheckedContinuation<Void, Error>?
    private var connecting: CheckedContinuation<Void, Error>?
    private var found: [UUID: Discovered] = [:]
    private var waiters: [(id: Int, match: (Packet) -> Bool, cont: CheckedContinuation<Packet, Error>)] = []
    private var nextWaiter = 0
    /// 先登记、后等的帧（见 latch）
    private var latches: [(match: (Packet) -> Bool, latch: Latch)] = []

    /// 每收到一帧都会在 BLE 队列上回调（用于收文件分片这类连续数据）。
    public var onPacket: ((Packet) -> Void)?
    /// 常驻：每一帧都会回调（按键、充电这类设备主动发的事件从这里拿），与传输用的 onPacket 互不影响
    public var onEvent: ((Packet) -> Void)?
    /// 连接断开（BLE 队列上回调）
    public var onDisconnect: (() -> Void)?
    public var verbose = false
    public private(set) var rxBytes = 0

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: q)
    }

    // MARK: 准备

    public func waitPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async {
                if self.central.state == .poweredOn { c.resume(); return }
                self.poweredOn = c
                // 偶发：系统蓝牙服务十几秒才回报状态
                self.q.asyncAfter(deadline: .now() + 20) {
                    guard let p = self.poweredOn else { return }
                    self.poweredOn = nil
                    p.resume(throwing: LinkError.bluetooth(self.stateName))
                }
            }
        }
    }

    private var stateName: String {
        switch central.state {
        case .unauthorized: return "没有蓝牙权限（系统设置 → 隐私与安全性 → 蓝牙，给运行这个命令的 App 打开）"
        case .poweredOff: return "蓝牙已关闭"
        case .unsupported: return "不支持"
        default: return "状态 \(central.state.rawValue)"
        }
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard let p = poweredOn else { return }
        if c.state == .poweredOn { poweredOn = nil; p.resume() }
        else if c.state == .unauthorized || c.state == .unsupported || c.state == .poweredOff {
            poweredOn = nil; p.resume(throwing: LinkError.bluetooth(stateName))
        }
    }

    // MARK: 扫描

    /// 扫描 `seconds` 秒。`all` 为 true 时也返回不像 D3200 的有名设备，便于排查。
    public func scan(seconds: Double, all: Bool = false) async -> [Discovered] {
        q.sync { found = [:]; central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        return q.sync {
            central.stopScan()
            return found.values.filter { all || $0.serviceMatch || $0.name.lowercased().contains("soundcore") }
                .sorted { $0.rssi > $1.rssi }
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData ad: [String: Any], rssi: NSNumber) {
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            + Array((ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).keys)
        let match = services.contains { $0 == UUIDs.service || $0.uuidString.uppercased().contains("F5DA") }
        let mfr = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map { Array($0) } ?? []
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard match || !name.isEmpty else { return }
        var mac: String?
        var bound: Bool?
        if match, mfr.count >= 7 {
            mac = mfr[0..<6].map { String(format: "%02X", $0) }.joined(separator: ":")
            bound = (mfr[6] & 0x80) != 0
        }
        found[p.identifier] = Discovered(peripheral: p, name: name, rssi: rssi.intValue, mac: mac,
                                         bound: bound, serviceMatch: match, manufacturer: mfr)
    }

    /// 之前连过的设备，直接用系统记住的 identifier 取回来。
    public func retrieve(_ id: UUID) -> CBPeripheral? {
        q.sync { central.retrievePeripherals(withIdentifiers: [id]).first }
    }

    // MARK: 连接

    public func connect(_ p: CBPeripheral, timeout: Double = 25) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async {
                self.peripheral = p
                self.writeChar = nil
                self.assembler = FrameAssembler()
                p.delegate = self
                self.connecting = c
                self.central.connect(p)
                self.q.asyncAfter(deadline: .now() + timeout) {
                    guard let c = self.connecting else { return }
                    self.connecting = nil
                    self.central.cancelPeripheralConnection(p)
                    c.resume(throwing: LinkError.timeout("连接 / 发现服务"))
                }
            }
        }
    }

    private func finishConnect(_ r: Result<Void, Error>) {
        guard let c = connecting else { return }
        connecting = nil
        if case .success = r { established = true }
        c.resume(with: r)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("GATT 已连接，发现服务…")
        p.discoverServices(nil)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finishConnect(.failure(error ?? LinkError.disconnected))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("断开：\(error?.localizedDescription ?? "正常")")
        finishConnect(.failure(LinkError.disconnected))
        if p.identifier == peripheral?.identifier, established {
            established = false
            onDisconnect?()
        }
        let w = waiters
        waiters = []
        w.forEach { $0.cont.resume(throwing: LinkError.disconnected) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        log("服务：" + services.map(\.uuid.uuidString).joined(separator: ", "))
        // D3200 服务排前面
        for s in services.sorted(by: { a, _ in a.uuid == UUIDs.service }) {
            p.discoverCharacteristics(nil, for: s)
        }
        if services.isEmpty { finishConnect(.failure(LinkError.missing("GATT 服务"))) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if verbose { log("  \(s.uuid) / \(ch.uuid) props=\(ch.properties.rawValue)") }
            if ch.uuid == UUIDs.write, writeChar == nil { writeChar = ch }
            if ch.uuid == UUIDs.notify, ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { finishConnect(.failure(error)); return }
        guard ch.uuid == UUIDs.notify, ch.isNotifying else { return }
        if writeChar == nil { finishConnect(.failure(LinkError.missing("写特征 …7777…"))); return }
        log("通知已打开，MTU 写入上限 \(p.maximumWriteValueLength(for: .withoutResponse)) 字节")
        finishConnect(.success(()))
    }

    // MARK: 收发

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == UUIDs.notify, let v = ch.value else { return }
        rxBytes += v.count
        for pkt in assembler.feed(Array(v)) {
            if verbose, !(Rx.isTransport(pkt) && (pkt.id == Rx.fileSlice || pkt.id == Rx.fileSliceMark)) {
                log("\(pkt)  \(pkt.raw.prefix(48).hex)\(pkt.raw.count > 48 ? " …" : "")")
            }
            onPacket?(pkt)
            onEvent?(pkt)
            for l in latches where l.latch.packet == nil && l.match(pkt) { l.latch.packet = pkt }
            if let idx = waiters.firstIndex(where: { $0.match(pkt) }) {
                waiters.remove(at: idx).cont.resume(returning: pkt)
            }
        }
    }

    public func send(_ frame: [UInt8]) throws {
        try q.sync { try sendOnQueue(frame) }
    }

    /// 发一条命令并等第一条满足 `match` 的回包。
    public func request(_ frame: [UInt8], timeout: Double = 6, label: String,
                        match: @escaping (Packet) -> Bool) async throws -> Packet {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Packet, Error>) in
            q.async {
                let id = self.nextWaiter
                self.nextWaiter += 1
                self.waiters.append((id, match, c))
                do { try self.sendOnQueue(frame) } catch {
                    self.waiters.removeAll { $0.id == id }
                    c.resume(throwing: error)
                    return
                }
                self.q.asyncAfter(deadline: .now() + timeout) {
                    guard let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: i).cont.resume(throwing: LinkError.timeout(label))
                }
            }
        }
    }

    /// 只等不发。
    public func wait(timeout: Double, label: String, match: @escaping (Packet) -> Bool) async throws -> Packet {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Packet, Error>) in
            q.async {
                let id = self.nextWaiter
                self.nextWaiter += 1
                self.waiters.append((id, match, c))
                self.q.asyncAfter(deadline: .now() + timeout) {
                    guard let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: i).cont.resume(throwing: LinkError.timeout(label))
                }
            }
        }
    }

    /// 一个登记好的等待：登记之后到的第一条匹配帧会被记住
    public final class Latch: @unchecked Sendable {
        fileprivate var packet: Packet?
    }

    /// 先登记、后等：发命令之前登记，命令的后续帧（比如结束录音回包之后紧跟的 1A/0A）来得再快也不会错过。
    /// 登记之后要用 `value(of:timeout:)` 取，取完就注销。
    public func latch(match: @escaping (Packet) -> Bool) -> Latch {
        q.sync {
            let l = Latch()
            latches.append((match, l))
            return l
        }
    }

    /// 等登记过的帧，最多 `timeout` 秒：到了返回这一帧，超时返回 nil。之后不再记录。
    public func value(of l: Latch, timeout: Double) async -> Packet? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            let p = q.sync { l.packet }
            if p != nil || Date() >= end {
                q.sync { latches.removeAll { $0.latch === l } }
                return p
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func sendOnQueue(_ frame: [UInt8]) throws {
        guard let p = peripheral, let ch = writeChar, p.state == .connected else { throw LinkError.disconnected }
        if verbose { log("TX \(frame.hex)") }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let chunk = max(20, p.maximumWriteValueLength(for: type))
        for start in stride(from: 0, to: frame.count, by: chunk) {
            p.writeValue(Data(frame[start..<min(start + chunk, frame.count)]), for: ch, type: type)
        }
    }

    /// 在 BLE 队列上执行一段代码（给 onPacket 回调之外的状态读写用）。
    public func sync<T>(_ body: () throws -> T) rethrows -> T { try q.sync(execute: body) }

    public func disconnect() {
        q.sync { if let p = peripheral { central.cancelPeripheralConnection(p) } }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("  · \(s)\n".utf8))
    }
}
