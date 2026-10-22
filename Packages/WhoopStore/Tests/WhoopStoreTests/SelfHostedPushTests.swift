import XCTest
import GRDB
@testable import WhoopStore

/// The Apple sender's wire bytes are pinned to an oracle that the owner's receiver tests accept verbatim
/// (Assistant repo, tests/fixtures/health/swift-oracle-*.ndjson). A change here must change both sides.
final class SelfHostedPushTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private let hrOracle = """
        {"type":"batch","protocolVersion":"1.0","batchId":"5f5b0a45-3264-5753-ba74-f38ee55cbe63","sourceId":"3a3486dd-5030-4e17-a00d-a781399890f9","deviceId":"my-whoop","stream":"hrSample","delivery":"append","recordCount":2,"startCursor":null,"endCursor":{"rowId":42,"keySha256":"34673ab5fd9141252106b332cc54b2bc6f60c04fefac1e2d8cbf99b3d2382fa2"}}
        {"data":{"bpm":61},"key":{"ts":1723939201},"type":"record"}
        {"data":{"bpm":62},"key":{"ts":1723939202},"type":"record"}

        """
    private let dailyOracle = """
        {"type":"batch","protocolVersion":"1.0","batchId":"5cf059ec-8ea8-5106-8686-ac9eeaff3baf","sourceId":"3a3486dd-5030-4e17-a00d-a781399890f9","deviceId":"my-whoop","stream":"dailyMetric","delivery":"replace_window","recordCount":1,"startCursor":null,"endCursor":null,"window":{"replacementId":"24b82888-80e4-5640-9c52-07a35b25bcee","selector":"day","startInclusive":"2026-10-09","endExclusive":"2026-10-23","part":1,"parts":1}}
        {"data":{"totalSleepMin":431.5,"efficiency":null,"deepMin":null,"remMin":null,"lightMin":null,"disturbances":null,"restingHr":52,"avgHrv":null,"recovery":64.5,"strain":9,"exerciseCount":null,"spo2Pct":null,"skinTempDevC":null,"respRateBpm":null,"steps":8123,"activeKcalEst":null,"spo2Red":null,"spo2Ir":null},"key":{"day":"2026-10-21"},"type":"record"}

        """
    private let dailyRow: [String: PushValue] = [
        "day": .text("2026-10-21"), "recovery": .num(64.5), "strain": .num(9), "steps": .int(8123),
        "restingHr": .int(52), "totalSleepMin": .num(431.5),
    ]

    func testAppendBatchBytesMatchTheOracle() throws {
        let stream = try XCTUnwrap(PushProtocol.stream(named: "hrSample"))
        let rows = [PushAppendRow(rowId: 41, values: ["ts": .int(1_723_939_201), "bpm": .int(61)]),
                    PushAppendRow(rowId: 42, values: ["ts": .int(1_723_939_202), "bpm": .int(62)])]
        let batch = try XCTUnwrap(try PushProtocol.appendBatch(stream, sourceId: source, deviceId: "my-whoop", start: nil, rows: rows))
        XCTAssertEqual(String(decoding: batch.body, as: UTF8.self), hrOracle)
        XCTAssertEqual(batch.batchId, "5f5b0a45-3264-5753-ba74-f38ee55cbe63")
        XCTAssertEqual(batch.endCursor, PushCursor(rowId: 42, keySha256: "34673ab5fd9141252106b332cc54b2bc6f60c04fefac1e2d8cbf99b3d2382fa2"))
        XCTAssertEqual(batch.rowsUsed, 2)
        // Rebuilt from the same rows (a retry after a lost acknowledgement), the batch is byte-identical.
        let again = try XCTUnwrap(try PushProtocol.appendBatch(stream, sourceId: source, deviceId: "my-whoop", start: nil, rows: rows))
        XCTAssertEqual(again.body, batch.body)
    }

    func testWindowBatchBytesAndDayHashMatchTheOracle() throws {
        let stream = try XCTUnwrap(PushProtocol.stream(named: "dailyMetric"))
        let parts = try PushProtocol.windowBatches(stream, sourceId: source, deviceId: "my-whoop",
                                                   start: .text("2026-10-09"), end: .text("2026-10-23"), rows: [dailyRow])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), dailyOracle)
        XCTAssertNil(parts[0].endCursor)
        XCTAssertEqual(try PushProtocol.dayHash(stream, rows: [dailyRow]), "84484f5cef1e2506911f7b0f0db766fc12490b363a3a980fc2c56f777e7c48bb")
    }

    func testEmptyWindowIsOneZeroRecordPartAndBigWindowsSplit() throws {
        let stream = try XCTUnwrap(PushProtocol.stream(named: "sleepSession"))
        let empty = try PushProtocol.windowBatches(stream, sourceId: source, deviceId: "my-whoop", start: .int(0), end: .int(86_400), rows: [])
        XCTAssertEqual(empty.map(\.recordCount), [0])
        XCTAssertTrue(String(decoding: empty[0].body, as: UTF8.self).contains("\"startInclusive\":0,\"endExclusive\":86400,\"part\":1,\"parts\":1"))
        let hr = try XCTUnwrap(PushProtocol.stream(named: "hrSample"))
        let rows = (0..<6_000).map { PushAppendRow(rowId: Int64($0 + 1), values: ["ts": .int(Int64($0)), "bpm": .int(60)]) }
        let first = try XCTUnwrap(try PushProtocol.appendBatch(hr, sourceId: source, deviceId: "my-whoop", start: nil, rows: rows))
        XCTAssertEqual(first.recordCount, PushProtocol.maxRecords)
        XCTAssertEqual(first.endCursor?.rowId, 5_000)
    }

    func testJsonEscapingAndNumbers() throws {
        XCTAssertEqual(PushProtocol.jsonString("a\"b\\c\nd\u{1}é"), "\"a\\\"b\\\\c\\nd\\u0001é\"")
        XCTAssertEqual(try PushProtocol.jsonValue(.num(52)), "52")
        XCTAssertEqual(try PushProtocol.jsonValue(.num(0.91)), "0.91")
        XCTAssertEqual(try PushProtocol.jsonValue(.bool(false)), "false")
        XCTAssertThrowsError(try PushProtocol.jsonValue(.num(.nan)))
    }

    func testStoreReadsPagesWindowsAndCursorRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            for (ts, bpm) in [(100, 61), (101, 62), (102, 63)] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', ?, ?)", arguments: [ts, bpm])
            }
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('other', 100, 99)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, recovery, steps) VALUES ('my-whoop', '2026-10-20', 70.5, 9000)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('my-whoop', '2026-10-01', 40)")
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES ('my-whoop', 5000, 9000, 1)")
        }
        let hr = try XCTUnwrap(PushProtocol.stream(named: "hrSample"))
        let page = try await store.pushAppendPage(hr, deviceId: "my-whoop", afterRowId: 0, limit: 2)
        XCTAssertEqual(page.map { $0.values["bpm"] }, [.int(61), .int(62)])
        let rest = try await store.pushAppendPage(hr, deviceId: "my-whoop", afterRowId: page[1].rowId, limit: 10)
        XCTAssertEqual(rest.map { $0.values["ts"] }, [.int(102)])
        let atCursor = try await store.pushRowAt(hr, deviceId: "my-whoop", rowId: page[1].rowId)
        XCTAssertEqual(atCursor?["ts"], .int(101))

        let daily = try XCTUnwrap(PushProtocol.stream(named: "dailyMetric"))
        let window = try await store.pushWindowRows(daily, deviceId: "my-whoop", start: .text("2026-10-09"), end: .text("2026-10-23"), limit: 100)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window[0]["recovery"], .num(70.5))
        XCTAssertEqual(window[0]["steps"], .int(9000))
        XCTAssertEqual(window[0]["spo2Ir"], .null)

        let sleep = try XCTUnwrap(PushProtocol.stream(named: "sleepSession"))
        let nights = try await store.pushWindowRows(sleep, deviceId: "my-whoop", start: .int(0), end: .int(86_400), limit: 100)
        XCTAssertEqual(nights.first?["userEdited"], .bool(true))
        // workout.routePolyline exists only on Android: exported as null rather than dropping the stream.
        let workout = try XCTUnwrap(PushProtocol.stream(named: "workout"))
        let supported = try await store.pushSupports(workout)
        XCTAssertTrue(supported)
    }
}
