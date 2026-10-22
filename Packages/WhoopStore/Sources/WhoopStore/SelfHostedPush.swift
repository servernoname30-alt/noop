import Foundation
import GRDB
#if canImport(CryptoKit)
import CryptoKit
#endif

// Self-hosted push, protocol 1.0 (docs/PUSH_PROTOCOL.md): the Apple sender's half that touches the store — the
// fixed v1 registry, byte-stable NDJSON encoding, content-derived ids, and the bounded reads a batch is built from.
// The HTTP side, settings and progress live in the app (Strand/Data/SelfHostedPush.swift). Android's client
// (com.noop.push) is the reference; the wire format is the contract, not either implementation.

/// One exported cell. Integers stay integers on the wire; booleans are JSON booleans; SQL NULL is `null`.
public enum PushValue: Equatable, Sendable {
    case null
    case int(Int64)
    case num(Double)
    case text(String)
    case bool(Bool)
}

public struct PushCursor: Codable, Equatable, Sendable {
    public var rowId: Int64
    public var keySha256: String
    public init(rowId: Int64, keySha256: String) { self.rowId = rowId; self.keySha256 = keySha256 }
}

/// A row read for an append stream: its SQLite insertion position plus the registry columns.
public struct PushAppendRow: Sendable {
    public let rowId: Int64
    public let values: [String: PushValue]
}

/// One request entity ready to POST, with what its acknowledgement must echo.
public struct PushBatch: Sendable {
    public let batchId: String
    public let stream: String
    public let deviceId: String
    public let recordCount: Int
    public let endCursor: PushCursor?
    public let body: Data
    /// Append batches: how many of the offered rows this batch carries (a page can split on the 4 MiB bound).
    public let rowsUsed: Int
}

public enum PushProtocolError: Error, Equatable {
    case recordTooLarge
    case nonFinite
}

public enum PushProtocol {
    public static let version = "1.0"
    public static let maxRecords = 5000
    public static let maxBodyBytes = 4 * 1024 * 1024
    /// One mutable snapshot per stream per run, as on Android: larger windows fail visibly instead of truncating.
    public static let maxSnapshotRecords = 1000
    /// The rolling mutable horizon: the current local day plus the 13 before it.
    public static let horizonDays = 14

    public enum Kind: Sendable { case int, num, text, bool, day }
    public enum Delivery: String, Sendable { case append, replaceWindow = "replace_window" }

    public struct Column: Sendable {
        public let name: String
        public let kind: Kind
        public let nullable: Bool
    }

    public struct Stream: Sendable {
        /// Wire name; on Apple it is also the GRDB table name.
        public let name: String
        public let delivery: Delivery
        public let key: [Column]
        public let data: [Column]
        /// replace_window only: the key column the window selects on ("day" or "startTs").
        public let selector: String?
        public var columns: [Column] { key + data }
    }

    private static func c(_ name: String, _ kind: Kind) -> Column { Column(name: name, kind: kind, nullable: false) }
    private static func n(_ name: String, _ kind: Kind) -> Column { Column(name: name, kind: kind, nullable: true) }

    /// The v1 registry, in the protocol's order. A table in the database is not implicitly part of it.
    public static let registry: [Stream] = [
        Stream(name: "hrSample", delivery: .append, key: [c("ts", .int)], data: [c("bpm", .int)], selector: nil),
        Stream(name: "rrInterval", delivery: .append, key: [c("ts", .int), c("rrMs", .int), c("seq", .int)],
               data: [n("ord", .int), n("srcChannel", .int), n("tsSuspect", .int)], selector: nil),
        Stream(name: "event", delivery: .append, key: [c("ts", .int), c("kind", .text)], data: [c("payloadJSON", .text)], selector: nil),
        Stream(name: "battery", delivery: .append, key: [c("ts", .int)], data: [n("soc", .num), n("mv", .int), n("charging", .bool)], selector: nil),
        Stream(name: "spo2Sample", delivery: .append, key: [c("ts", .int)], data: [c("red", .int), c("ir", .int)], selector: nil),
        Stream(name: "skinTempSample", delivery: .append, key: [c("ts", .int)], data: [c("raw", .int), n("aux1Raw", .int), n("aux2Raw", .int)], selector: nil),
        Stream(name: "respSample", delivery: .append, key: [c("ts", .int)], data: [c("raw", .int)], selector: nil),
        Stream(name: "gravitySample", delivery: .append, key: [c("ts", .int)],
               data: [c("x", .num), c("y", .num), c("z", .num), n("dynAccel", .num)], selector: nil),
        Stream(name: "dailyMetric", delivery: .replaceWindow, key: [c("day", .day)], data: [
            n("totalSleepMin", .num), n("efficiency", .num), n("deepMin", .num), n("remMin", .num), n("lightMin", .num),
            n("disturbances", .int), n("restingHr", .int), n("avgHrv", .num), n("recovery", .num), n("strain", .num),
            n("exerciseCount", .int), n("spo2Pct", .num), n("skinTempDevC", .num), n("respRateBpm", .num), n("steps", .int),
            n("activeKcalEst", .num), n("spo2Red", .int), n("spo2Ir", .int),
        ], selector: "day"),
        Stream(name: "sleepSession", delivery: .replaceWindow, key: [c("startTs", .int)], data: [
            c("endTs", .int), n("efficiency", .num), n("restingHr", .int), n("avgHrv", .num), n("stagesJSON", .text),
            c("userEdited", .bool), n("startTsAdjusted", .int), n("motionJSON", .text), n("sleepStateJSON", .text),
            n("stagingSparse", .bool),
        ], selector: "startTs"),
        Stream(name: "workout", delivery: .replaceWindow, key: [c("startTs", .int), c("sport", .text)], data: [
            c("endTs", .int), c("source", .text), n("durationS", .num), n("energyKcal", .num), n("avgHr", .int), n("maxHr", .int),
            n("strain", .num), n("distanceM", .num), n("zonesJSON", .text), n("notes", .text), n("routePolyline", .text), n("steps", .int),
        ], selector: "startTs"),
        Stream(name: "journal", delivery: .replaceWindow, key: [c("day", .day), c("question", .text)],
               data: [c("answeredYes", .bool), n("notes", .text), n("numericValue", .num)], selector: "day"),
    ]

    public static func stream(named name: String) -> Stream? { registry.first { $0.name == name } }

    // MARK: - JSON

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func jsonValue(_ value: PushValue) throws -> String {
        switch value {
        case .null: return "null"
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .text(let s): return jsonString(s)
        case .num(let d):
            guard d.isFinite else { throw PushProtocolError.nonFinite }
            // An integral double prints as an integer: the receiver only needs a finite JSON number.
            if d == d.rounded(), abs(d) < 9.0e15 { return String(Int64(d)) }
            return "\(d)"
        }
    }

    /// Compact object with members in the given order (registry order for key/data).
    static func object(_ members: [(String, String)]) -> String {
        "{" + members.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func columnsJSON(_ columns: [Column], _ row: [String: PushValue]) throws -> String {
        try object(columns.map { ($0.name, try jsonValue(row[$0.name] ?? .null)) })
    }

    /// The compact natural-key object, members in registry order — the input of a cursor fingerprint.
    public static func keyJSON(_ stream: Stream, _ row: [String: PushValue]) throws -> String {
        try columnsJSON(stream.key, row)
    }

    /// One record line, LF-terminated: `{"data":{…},"key":{…},"type":"record"}`.
    public static func recordLine(_ stream: Stream, _ row: [String: PushValue]) throws -> Data {
        let line = object([("data", try columnsJSON(stream.data, row)), ("key", try keyJSON(stream, row)), ("type", jsonString("record"))])
        return Data((line + "\n").utf8)
    }

    // MARK: - Hashes and ids

    static func sha256Bytes(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: data))
        #else
        return SoftSHA256.digest(data)
        #endif
    }

    public static func sha256Hex(_ data: Data) -> String {
        sha256Bytes(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase SHA-256 of `stream LF deviceId LF compactKey`: the saved-cursor check of the protocol.
    public static func keySha256(_ stream: Stream, deviceId: String, row: [String: PushValue]) throws -> String {
        sha256Hex(Data("\(stream.name)\n\(deviceId)\n\(try keyJSON(stream, row))".utf8))
    }

    /// A content-derived UUID (Android's form: SHA-256 → 16 bytes, version 5, RFC 4122 variant), so a retry
    /// rebuilt from the same rows carries the same id.
    static func stableUUID(_ identity: String, _ lines: [Data]) -> String {
        var data = Data(identity.utf8)
        data.append(0x0a)
        for line in lines { data.append(line) }
        var bytes = Array(sha256Bytes(data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        let i = { (a: Int, b: Int) in String(h[h.index(h.startIndex, offsetBy: a)..<h.index(h.startIndex, offsetBy: b)]) }
        return "\(i(0, 8))-\(i(8, 12))-\(i(12, 16))-\(i(16, 20))-\(i(20, 32))"
    }

    /// Local progress only (never sent): the canonical content of one stream's rows for one local day.
    public static func dayHash(_ stream: Stream, rows: [[String: PushValue]]) throws -> String {
        var data = Data("noop-push-day-hash\n\(version)\n\(stream.name)\n".utf8)
        let lines = try rows.map { try recordLine(stream, $0) }.sorted { $0.lexicographicallyPrecedes($1) }
        for line in lines { data.append(line) }
        return sha256Hex(data)
    }

    // MARK: - Batches

    private static func cursorJSON(_ cursor: PushCursor?) -> String {
        guard let cursor else { return "null" }
        return object([("rowId", String(cursor.rowId)), ("keySha256", jsonString(cursor.keySha256))])
    }

    private static func appendHeader(_ stream: Stream, sourceId: String, deviceId: String, batchId: String, count: Int,
                                     start: PushCursor?, end: PushCursor) -> Data {
        Data((object([
            ("type", jsonString("batch")), ("protocolVersion", jsonString(version)), ("batchId", jsonString(batchId)),
            ("sourceId", jsonString(sourceId)), ("deviceId", jsonString(deviceId)), ("stream", jsonString(stream.name)),
            ("delivery", jsonString(Delivery.append.rawValue)), ("recordCount", String(count)),
            ("startCursor", cursorJSON(start)), ("endCursor", cursorJSON(end)),
        ]) + "\n").utf8)
    }

    /// The next append batch from `rows` (ordered by rowid, all after `start`): as many as fit 5,000 records and
    /// 4 MiB. Nil when `rows` is empty.
    public static func appendBatch(_ stream: Stream, sourceId: String, deviceId: String, start: PushCursor?,
                                   rows: [PushAppendRow]) throws -> PushBatch? {
        guard !rows.isEmpty else { return nil }
        let headerAllowance = 1024 + deviceId.utf8.count * 6
        var lines: [Data] = [], bytes = 0
        for row in rows.prefix(maxRecords) {
            let line = try recordLine(stream, row.values)
            if headerAllowance + bytes + line.count > maxBodyBytes {
                if lines.isEmpty { throw PushProtocolError.recordTooLarge }
                break
            }
            lines.append(line); bytes += line.count
        }
        let last = rows[lines.count - 1]
        let end = PushCursor(rowId: last.rowId, keySha256: try keySha256(stream, deviceId: deviceId, row: last.values))
        let identity = "append\n\(version)\n\(sourceId)\n\(deviceId)\n\(stream.name)\n\(cursorJSON(start))\n\(cursorJSON(end))"
        let batchId = stableUUID(identity, lines)
        var body = appendHeader(stream, sourceId: sourceId, deviceId: deviceId, batchId: batchId, count: lines.count, start: start, end: end)
        for line in lines { body.append(line) }
        return PushBatch(batchId: batchId, stream: stream.name, deviceId: deviceId, recordCount: lines.count,
                         endCursor: end, body: body, rowsUsed: lines.count)
    }

    /// Every bounded part of one authoritative replacement of `[start, end)` (day strings or Unix seconds).
    /// `rows` must already be the complete window content; an empty window is one zero-record part.
    public static func windowBatches(_ stream: Stream, sourceId: String, deviceId: String,
                                     start: PushValue, end: PushValue, rows: [[String: PushValue]]) throws -> [PushBatch] {
        let lines = try rows.map { try recordLine(stream, $0) }
        let selector = stream.selector ?? ""
        let bounds = "\(selector)\n\(try jsonValue(start))\n\(try jsonValue(end))"
        let replacementId = stableUUID("replace_window\n\(version)\n\(sourceId)\n\(deviceId)\n\(stream.name)\n\(bounds)", lines)
        let headerAllowance = 1024 + deviceId.utf8.count * 6
        var chunks: [[Data]] = [], current: [Data] = [], bytes = 0
        for line in lines {
            if headerAllowance + line.count > maxBodyBytes { throw PushProtocolError.recordTooLarge }
            if current.count == maxRecords || headerAllowance + bytes + line.count > maxBodyBytes {
                chunks.append(current); current = []; bytes = 0
            }
            current.append(line); bytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
        return try chunks.enumerated().map { index, part in
            let partNo = index + 1
            let window = object([
                ("replacementId", jsonString(replacementId)), ("selector", jsonString(selector)),
                ("startInclusive", try jsonValue(start)), ("endExclusive", try jsonValue(end)),
                ("part", String(partNo)), ("parts", String(chunks.count)),
            ])
            let batchId = stableUUID("\(replacementId)\n\(partNo)\n\(chunks.count)", part)
            var body = Data((object([
                ("type", jsonString("batch")), ("protocolVersion", jsonString(version)), ("batchId", jsonString(batchId)),
                ("sourceId", jsonString(sourceId)), ("deviceId", jsonString(deviceId)), ("stream", jsonString(stream.name)),
                ("delivery", jsonString(Delivery.replaceWindow.rawValue)), ("recordCount", String(part.count)),
                ("startCursor", "null"), ("endCursor", "null"), ("window", window),
            ]) + "\n").utf8)
            for line in part { body.append(line) }
            return PushBatch(batchId: batchId, stream: stream.name, deviceId: deviceId, recordCount: part.count,
                             endCursor: nil, body: body, rowsUsed: part.count)
        }
    }
}

// MARK: - Store reads

extension WhoopStore {
    /// The registry columns this database has for `stream` (missing nullable ones read as NULL), or nil when the
    /// table or a required column is absent on this platform — such a stream is simply not exported.
    private static func pushSelectList(_ db: Database, _ stream: PushProtocol.Stream) throws -> String? {
        guard try db.tableExists(stream.name) else { return nil }
        let present = Set(try db.columns(in: stream.name).map(\.name))
        guard present.contains("deviceId") else { return nil }
        var parts: [String] = []
        for column in stream.columns {
            if present.contains(column.name) { parts.append("\"\(column.name)\"") }
            else if column.nullable { parts.append("NULL AS \"\(column.name)\"") }
            else { return nil }
        }
        return parts.joined(separator: ", ")
    }

    private static func pushValue(_ value: DatabaseValue, _ column: PushProtocol.Column) -> PushValue {
        switch value.storage {
        case .null, .blob: return .null
        case .int64(let i):
            switch column.kind {
            case .bool: return .bool(i != 0)
            case .text, .day: return .text(String(i))
            case .int, .num: return .int(i)
            }
        case .double(let d):
            guard d.isFinite else { return .null }
            switch column.kind {
            case .bool: return .bool(d != 0)
            case .text, .day: return .text("\(d)")
            case .int: return d == d.rounded() ? .int(Int64(d)) : .num(d)
            case .num: return .num(d)
            }
        case .string(let s):
            switch column.kind {
            case .text, .day: return .text(s)
            case .bool: return .bool(s == "1" || s.lowercased() == "true")
            case .int: return Int64(s).map(PushValue.int) ?? .null
            case .num: return Double(s).map(PushValue.num) ?? .null
            }
        }
    }

    private static func pushRow(_ row: Row, _ stream: PushProtocol.Stream) -> [String: PushValue] {
        var values: [String: PushValue] = [:]
        for column in stream.columns { values[column.name] = pushValue(row[column.name] as DatabaseValue, column) }
        return values
    }

    /// Whether this database can export `stream` at all.
    public func pushSupports(_ stream: PushProtocol.Stream) throws -> Bool {
        try syncRead { db in try Self.pushSelectList(db, stream) != nil }
    }

    /// Up to `limit` rows of an append stream inserted after `afterRowId`, in insertion order.
    public func pushAppendPage(_ stream: PushProtocol.Stream, deviceId: String, afterRowId: Int64, limit: Int) throws -> [PushAppendRow] {
        try syncRead { db in
            guard let select = try Self.pushSelectList(db, stream) else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS "_pushRowId", \(select) FROM "\(stream.name)"
                WHERE "deviceId" = ? AND rowid > ? ORDER BY rowid LIMIT ?
                """, arguments: [deviceId, afterRowId, limit])
            return rows.map { PushAppendRow(rowId: $0["_pushRowId"], values: Self.pushRow($0, stream)) }
        }
    }

    /// The row at a saved cursor's insertion position, to re-check its key fingerprint before trusting it.
    public func pushRowAt(_ stream: PushProtocol.Stream, deviceId: String, rowId: Int64) throws -> [String: PushValue]? {
        try syncRead { db in
            guard let select = try Self.pushSelectList(db, stream) else { return nil }
            return try Row.fetchOne(db, sql: "SELECT \(select) FROM \"\(stream.name)\" WHERE rowid = ? AND \"deviceId\" = ?",
                                    arguments: [rowId, deviceId]).map { Self.pushRow($0, stream) }
        }
    }

    /// The complete content of a replace_window stream for `start <= selector < end`, ordered by natural key.
    /// Reads at most `limit + 1` rows so an oversized window is detected without loading it.
    public func pushWindowRows(_ stream: PushProtocol.Stream, deviceId: String, start: PushValue, end: PushValue,
                               limit: Int) throws -> [[String: PushValue]] {
        try syncRead { db in
            guard let select = try Self.pushSelectList(db, stream), let selector = stream.selector else { return [] }
            let bound = { (value: PushValue) -> DatabaseValueConvertible? in
                switch value { case .int(let i): return i; case .text(let s): return s; default: return nil }
            }
            let order = stream.key.map { "\"\($0.name)\"" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(select) FROM "\(stream.name)"
                WHERE "deviceId" = ? AND "\(selector)" >= ? AND "\(selector)" < ? ORDER BY \(order) LIMIT ?
                """, arguments: [deviceId, bound(start), bound(end), limit + 1])
            return rows.map { Self.pushRow($0, stream) }
        }
    }
}

#if !canImport(CryptoKit)
/// SHA-256 for platforms without CryptoKit (the Linux package build). Apple platforms use CryptoKit.
enum SoftSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let t1 = hh &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h = [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d, h[4] &+ e, h[5] &+ f, h[6] &+ g, h[7] &+ hh]
        }
        return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }
}
#endif
