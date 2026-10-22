import Foundation

/// Personal build: the weight-loss log for the owner's receiver. NOOP's push protocol has no stream for it, so
/// SelfHostedPushCenter posts this JSON to the receiver's /api/health/cut after each delivery (only when it changed).
extension CutPlanStore {
    private struct Snapshot: Encodable {
        struct Plan: Encodable {
            let configured: Bool, startKg: Double, startDay: String, goalKg: Double, targetDay: String
            let workoutShare: Double, workoutEatBack: Double, logBuffer: Double, proteinPerKg: Double
        }
        struct Food: Encodable { let id: String, day: String, name: String, kcal: Int, protein: Double?, at: Int }
        struct Weigh: Encodable { let id: String, kg: Double, at: Int }
        let version = 1
        /// Food rows are authoritative from this local day on; older rows on the receiver are left alone.
        let fromDay: String
        let plan: Plan
        let food: [Food]
        let weighIns: [Weigh]
    }

    /// The last 60 days of food, every weigh-in and the plan; nil when nothing was ever set up or logged.
    func pushSnapshot(now: Date = Date()) -> Data? {
        guard configured || !food.isEmpty || !weighIns.isEmpty else { return nil }
        let fromDay = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -59, to: now) ?? now)
        let foods = food.filter { $0.key >= fromDay }.flatMap { day, entries in
            entries.map { Snapshot.Food(id: $0.id.uuidString.lowercased(), day: day, name: $0.name, kcal: $0.kcal, protein: $0.protein,
                                        at: Int($0.at.timeIntervalSince1970)) }
        }.sorted { ($0.day, $0.at, $0.id) < ($1.day, $1.at, $1.id) }
        let snapshot = Snapshot(fromDay: fromDay,
                                plan: .init(configured: configured, startKg: startKg, startDay: startDay, goalKg: goalKg,
                                            targetDay: Repository.localDayKey(targetDate), workoutShare: workoutShare,
                                            workoutEatBack: workoutEatBack, logBuffer: logBuffer, proteinPerKg: proteinPerKg),
                                food: foods,
                                weighIns: weighIns.map { .init(id: $0.id.uuidString.lowercased(), kg: $0.kg, at: Int($0.at.timeIntervalSince1970)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }
}
