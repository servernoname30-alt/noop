import Foundation
import Security
import WhoopStore
#if os(iOS)
import UIKit
#endif

// Self-hosted push (personal build): after a strap offload, send what was banked to an HTTPS endpoint the owner
// runs, per docs/PUSH_PROTOCOL.md (protocol 1.0, the same contract as Android's Experimental client). One way only:
// the receiver can answer with its capability document and acknowledgements, nothing else is ever read back.
// Default off; with no endpoint or token it never touches the network. Delivery never blocks strap sync: it runs
// after the offload, within a bounded time budget, and every unacknowledged batch is simply rebuilt next time.

enum SelfHostedPushSettings {
    static let enabledKey = "selfHostedPush.enabled"
    static let endpointKey = "selfHostedPush.endpoint"
    private static let sourceIdKey = "selfHostedPush.sourceId"
    private static let service = "com.noop.selfHostedPush"
    private static let account = "bearer-token"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var endpointText: String { UserDefaults.standard.string(forKey: endpointKey) ?? "" }

    /// HTTPS only (the owner's receiver sits behind `tailscale serve`), with no credentials, query or fragment.
    static func endpoint(from text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// A random id for this installation (not an account), created on first use.
    static var sourceId: String {
        if let id = UserDefaults.standard.string(forKey: sourceIdKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: sourceIdKey)
        return id
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The bearer token lives in the Keychain, readable after first unlock so a background offload can send.
    static var token: String? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var attrs = query
        attrs[kSecValueData as String] = Data(trimmed.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}

/// Local delivery progress for ONE destination namespace (source, endpoint, version, receiver state). A changed
/// namespace starts over with a full baseline; rotating only the token keeps it.
struct SelfHostedPushProgress: Codable {
    var namespace = ""
    var cursors: [String: PushCursor] = [:]
    var dayHashes: [String: [String: String]] = [:]

    private static let key = "selfHostedPush.progress"
    static func load() -> SelfHostedPushProgress {
        guard let data = UserDefaults.standard.data(forKey: key),
              let progress = try? JSONDecoder().decode(SelfHostedPushProgress.self, from: data) else { return SelfHostedPushProgress() }
        return progress
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
    static func scope(_ deviceId: String, _ stream: String) -> String { "\(deviceId)\n\(stream)" }
}

enum SelfHostedPushFailure: Error, Equatable {
    case notConfigured
    case storeUnavailable
    case transport(String)
    case http(Int, String?)
    case invalidCapabilities
    case invalidAcknowledgement
    case local(String)

    /// Short, safe text for the settings screen: never a response body, URL or token.
    var label: String {
        switch self {
        case .notConfigured: return "Не указан адрес (https://…) или токен"
        case .storeUnavailable: return "База NOOP недоступна (телефон заблокирован?)"
        case .transport(let what): return "Сеть: \(what)"
        case .http(let status, let code): return "Приёмник ответил \(status)" + (code.map { " (\($0))" } ?? "")
        case .invalidCapabilities: return "Приёмник прислал неверный ответ о возможностях"
        case .invalidAcknowledgement: return "Приёмник прислал неверное подтверждение"
        case .local(let what): return "Локальная ошибка: \(what)"
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirects are never followed, so the bearer token never reaches another URL.
        completionHandler(nil)
    }
}

private let pushSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 45
    config.httpCookieStorage = nil
    config.urlCache = nil
    return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
}()

/// The HTTP half of the protocol: capability GET and batch POST with exact acknowledgement checks. No store access.
struct SelfHostedPushClient: Sendable {
    let endpoint: URL
    let token: String

    private static let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private static let errorCode = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{0,63}$")
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await pushSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SelfHostedPushFailure.transport("нет HTTP-ответа") }
            return (data, http.statusCode)
        } catch let error as URLError {
            throw SelfHostedPushFailure.transport("код \(error.code.rawValue)")
        }
    }

    private func receiverCode(_ data: Data) -> String? {
        guard data.count <= 4096, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String, Self.matches(Self.errorCode, code) else { return nil }
        return code
    }

    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The authenticated capability document: receiver state id and the advertised subset of the v1 registry.
    func capabilities() async throws -> (stateId: String, streams: [String]) {
        var get = request("GET")
        get.setValue(PushProtocol.version, forHTTPHeaderField: "NOOP-Push-Accept-Version")
        let (data, status) = try await send(get)
        guard status == 200 else { throw SelfHostedPushFailure.http(status, receiverCode(data)) }
        guard data.count <= 16 * 1024, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "capabilities", json["protocolVersion"] as? String == PushProtocol.version,
              let stateId = json["receiverStateId"] as? String, Self.matches(Self.uuid, stateId),
              let streams = json["streams"] as? [String], Set(streams).count == streams.count,
              streams.allSatisfy({ PushProtocol.stream(named: $0) != nil }) else { throw SelfHostedPushFailure.invalidCapabilities }
        return (stateId, streams)
    }

    /// A plain JSON document to a sibling path on the same receiver (the weight-loss log, outside the protocol).
    func postJSON(path: String, body: Data) async throws {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw SelfHostedPushFailure.notConfigured }
        components.path = path
        guard let url = components.url else { throw SelfHostedPushFailure.notConfigured }
        var post = request("POST")
        post.url = url
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = body
        let (data, status) = try await send(post)
        guard (200..<300).contains(status) else { throw SelfHostedPushFailure.http(status, receiverCode(data)) }
    }

    func post(_ batch: PushBatch) async throws {
        var post = request("POST")
        post.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        post.httpBody = batch.body
        let (data, status) = try await send(post)
        guard (200..<300).contains(status) else { throw SelfHostedPushFailure.http(status, receiverCode(data)) }
        guard data.count <= 16 * 1024, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["protocolVersion"] as? String == PushProtocol.version, json["batchId"] as? String == batch.batchId,
              json["stream"] as? String == batch.stream, json["deviceId"] as? String == batch.deviceId,
              json["status"] as? String == "accepted", (json["acceptedRows"] as? NSNumber)?.intValue == batch.recordCount
        else { throw SelfHostedPushFailure.invalidAcknowledgement }
        // The acknowledgement must echo the end cursor exactly (null for replace-window parts).
        if let expected = batch.endCursor {
            guard let cursor = json["endCursor"] as? [String: Any], (cursor["rowId"] as? NSNumber)?.int64Value == expected.rowId,
                  cursor["keySha256"] as? String == expected.keySha256 else { throw SelfHostedPushFailure.invalidAcknowledgement }
        } else if !(json["endCursor"] is NSNull) {
            throw SelfHostedPushFailure.invalidAcknowledgement
        }
    }
}

/// One delivery attempt: capability check, then every advertised stream within the time and request budget.
struct SelfHostedPushEngine: Sendable {
    let client: SelfHostedPushClient
    let sourceId: String
    let deviceId: String
    let store: WhoopStore
    let deadline: Date
    let maxRequests: Int

    struct Outcome: Sendable { var batches = 0; var rows = 0; var finished = true; var newDestination = false }

    private func hasBudget(_ outcome: Outcome, adding requests: Int = 1) -> Bool {
        Date() < deadline && outcome.batches + requests <= maxRequests
    }

    func run() async throws -> Outcome {
        let (stateId, streams) = try await client.capabilities()
        var progress = SelfHostedPushProgress.load()
        let namespace = [sourceId, client.endpoint.absoluteString.lowercased(), PushProtocol.version, stateId].joined(separator: "\n")
        var outcome = Outcome()
        if progress.namespace != namespace {
            progress = SelfHostedPushProgress(namespace: namespace)
            progress.save()
            outcome.newDestination = true
        }
        let advertised = Set(streams)
        for stream in PushProtocol.registry where advertised.contains(stream.name) {
            guard try await store.pushSupports(stream) else { continue }
            do {
                if stream.delivery == .append { try await drain(stream, &progress, &outcome) }
                else { try await replace(stream, &progress, &outcome) }
            } catch let error as PushProtocolError {
                throw SelfHostedPushFailure.local("\(stream.name): \(error)")
            }
        }
        return outcome
    }

    /// Append stream: everything inserted after the saved cursor, in rowid order, one acknowledged page at a time.
    private func drain(_ stream: PushProtocol.Stream, _ progress: inout SelfHostedPushProgress, _ outcome: inout Outcome) async throws {
        let scope = SelfHostedPushProgress.scope(deviceId, stream.name)
        var cursor = progress.cursors[scope]
        if let saved = cursor {
            // A restore, prune or rowid rewrite invalidates insertion positions: replay from the start then;
            // the receiver's upserts make the replay harmless.
            let row = try await store.pushRowAt(stream, deviceId: deviceId, rowId: saved.rowId)
            let check = try row.map { try PushProtocol.keySha256(stream, deviceId: deviceId, row: $0) }
            if check != saved.keySha256 {
                cursor = nil
                progress.cursors[scope] = nil
                progress.save()
            }
        }
        while true {
            guard hasBudget(outcome) else { outcome.finished = false; return }
            let rows = try await store.pushAppendPage(stream, deviceId: deviceId, afterRowId: cursor?.rowId ?? 0, limit: PushProtocol.maxRecords)
            guard let batch = try PushProtocol.appendBatch(stream, sourceId: sourceId, deviceId: deviceId, start: cursor, rows: rows) else { return }
            try await client.post(batch)
            cursor = batch.endCursor
            progress.cursors[scope] = cursor
            progress.save()
            outcome.batches += 1
            outcome.rows += batch.recordCount
            if rows.count < PushProtocol.maxRecords && batch.rowsUsed == rows.count { return }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Mutable stream: hash each local day of the 14-day horizon, send the smallest contiguous window covering the
    /// changed days as one authoritative replacement, and remember the hashes only once every part is acknowledged.
    private func replace(_ stream: PushProtocol.Stream, _ progress: inout SelfHostedPushProgress, _ outcome: inout Outcome) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<PushProtocol.horizonDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let horizonStart = days.first, let horizonEnd = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        let key = { (date: Date) in Self.dayFormatter.string(from: date) }
        let bound = { (date: Date) -> PushValue in
            stream.selector == "day" ? .text(key(date)) : .int(Int64(date.timeIntervalSince1970))
        }
        let dayOf = { (row: [String: PushValue]) -> String? in
            switch row[stream.selector ?? ""] {
            case .text(let day)?: return day
            case .int(let ts)?: return key(Date(timeIntervalSince1970: TimeInterval(ts)))
            default: return nil
            }
        }

        let rows = try await store.pushWindowRows(stream, deviceId: deviceId, start: bound(horizonStart), end: bound(horizonEnd),
                                                  limit: PushProtocol.maxSnapshotRecords)
        guard rows.count <= PushProtocol.maxSnapshotRecords else { throw SelfHostedPushFailure.local("\(stream.name): окно больше 1000 строк") }
        var byDay: [String: [[String: PushValue]]] = [:]
        for row in rows { if let day = dayOf(row) { byDay[day, default: []].append(row) } }
        var hashes: [String: String] = [:]
        for day in days.map(key) { hashes[day] = try PushProtocol.dayHash(stream, rows: byDay[day] ?? []) }

        let scope = SelfHostedPushProgress.scope(deviceId, stream.name)
        let stored = progress.dayHashes[scope]
        let empty = try PushProtocol.dayHash(stream, rows: [])
        let changed = stored == nil ? days : days.filter { (stored?[key($0)] ?? empty) != hashes[key($0)] }
        guard let first = changed.first, let last = changed.last, let windowEnd = calendar.date(byAdding: .day, value: 1, to: last) else { return }

        let windowDays = Set(days.filter { $0 >= first && $0 <= last }.map(key))
        let windowRows = rows.filter { dayOf($0).map(windowDays.contains) ?? false }
        let parts = try PushProtocol.windowBatches(stream, sourceId: sourceId, deviceId: deviceId,
                                                   start: bound(first), end: bound(windowEnd), rows: windowRows)
        guard hasBudget(outcome, adding: parts.count) else { outcome.finished = false; return }
        for part in parts {
            try await client.post(part)
            outcome.batches += 1
            outcome.rows += part.recordCount
        }
        progress.dayHashes[scope] = hashes
        progress.save()
    }
}

/// Holds an iOS execution assertion for one delivery so a background offload's push is not suspended halfway.
private final class PushAssertion: @unchecked Sendable {
    #if os(iOS)
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid
    func store(_ newID: UIBackgroundTaskIdentifier) { lock.lock(); id = newID; lock.unlock() }
    @MainActor func end() {
        lock.lock(); let current = id; id = .invalid; lock.unlock()
        if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
    }
    #endif
}

/// The app-facing side: settings screen state and the post-offload trigger. Runs coalesce — a trigger that
/// arrives during a delivery runs once more after it.
@MainActor
final class SelfHostedPushCenter: ObservableObject {
    static let shared = SelfHostedPushCenter()

    @Published private(set) var running = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastFailure: String?
    @Published private(set) var lastRows = 0

    /// Set on iOS by the app: the weight-loss log (CutPlanStore) as JSON, sent after a delivery when it changed.
    var cutSnapshot: (@MainActor () -> Data?)?

    private var rerun = false
    private let cutHashKey = "selfHostedPush.cutHash"
    private let successKey = "selfHostedPush.lastSuccess"
    private let failureKey = "selfHostedPush.lastFailure"
    private let rowsKey = "selfHostedPush.lastRows"

    private init() {
        let defaults = UserDefaults.standard
        lastSuccess = defaults.object(forKey: successKey) as? Date
        lastFailure = defaults.string(forKey: failureKey)
        lastRows = defaults.integer(forKey: rowsKey)
    }

    /// After a completed offload or a deferred re-score. A no-op unless the owner turned the push on.
    func runAfterNewData(repo: Repository, deviceId: String) async {
        guard SelfHostedPushSettings.enabled else { return }
        await run(repo: repo, deviceId: deviceId, seconds: 25)
    }

    /// «Отправить сейчас»: the same delivery with a longer budget, for a first baseline from the foreground.
    func sendNow(repo: Repository, deviceId: String) async {
        await run(repo: repo, deviceId: deviceId, seconds: 120)
    }

    /// Capability GET only: no health data is read or sent.
    func testConnection() async -> String {
        guard let endpoint = SelfHostedPushSettings.endpoint(from: SelfHostedPushSettings.endpointText),
              let token = SelfHostedPushSettings.token, !token.isEmpty else { return SelfHostedPushFailure.notConfigured.label }
        do {
            let caps = try await SelfHostedPushClient(endpoint: endpoint, token: token).capabilities()
            return "Связь есть. Приёмник принимает: \(caps.streams.joined(separator: ", "))"
        } catch let failure as SelfHostedPushFailure {
            return failure.label
        } catch {
            return SelfHostedPushFailure.local("\(error)").label
        }
    }

    private func run(repo: Repository, deviceId: String, seconds: TimeInterval) async {
        if running { rerun = true; return }
        guard let endpoint = SelfHostedPushSettings.endpoint(from: SelfHostedPushSettings.endpointText),
              let token = SelfHostedPushSettings.token, !token.isEmpty else { record(.failure(.notConfigured)); return }
        guard let store = await repo.storeHandle() else { record(.failure(.storeUnavailable)); return }
        running = true
        let assertion = PushAssertion()
        #if os(iOS)
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "noop.selfHostedPush") {
            MainActor.assumeIsolated { assertion.end() }
        }
        assertion.store(taskID)
        #endif
        repeat {
            rerun = false
            let engine = SelfHostedPushEngine(client: SelfHostedPushClient(endpoint: endpoint, token: token), sourceId: SelfHostedPushSettings.sourceId,
                                              deviceId: deviceId, store: store, deadline: Date().addingTimeInterval(seconds), maxRequests: 60)
            do {
                let outcome = try await Task.detached { try await engine.run() }.value
                // A new receiver (or a reset one) has never seen the weight-loss log either.
                if outcome.newDestination { UserDefaults.standard.removeObject(forKey: cutHashKey) }
                try await sendCutIfChanged(engine.client)
                record(.success(outcome))
            } catch let failure as SelfHostedPushFailure {
                record(.failure(failure))
                break
            } catch {
                record(.failure(.local("\(error)")))
                break
            }
        } while rerun
        running = false
        #if os(iOS)
        assertion.end()
        #endif
    }

    private func sendCutIfChanged(_ client: SelfHostedPushClient) async throws {
        guard let body = cutSnapshot?() else { return }
        let hash = PushProtocol.sha256Hex(Data(SelfHostedPushSettings.sourceId.utf8) + body)
        guard hash != UserDefaults.standard.string(forKey: cutHashKey) else { return }
        // Wrapped with the installation id, so the receiver keeps one log per phone install.
        var wrapped = Data("{\"sourceId\":\"\(SelfHostedPushSettings.sourceId)\",\"snapshot\":".utf8)
        wrapped.append(body)
        wrapped.append(Data("}".utf8))
        try await client.postJSON(path: "/api/health/cut", body: wrapped)
        UserDefaults.standard.set(hash, forKey: cutHashKey)
    }

    private func record(_ result: Result<SelfHostedPushEngine.Outcome, SelfHostedPushFailure>) {
        let defaults = UserDefaults.standard
        switch result {
        case .success(let outcome):
            lastSuccess = Date()
            lastFailure = nil
            lastRows = outcome.rows
            defaults.set(lastSuccess, forKey: successKey)
            defaults.removeObject(forKey: failureKey)
            defaults.set(outcome.rows, forKey: rowsKey)
        case .failure(let failure):
            lastFailure = failure.label
            defaults.set(failure.label, forKey: failureKey)
        }
    }
}
