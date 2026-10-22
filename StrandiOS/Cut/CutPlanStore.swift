import Foundation
import Combine

/// Personal weight-loss plan: goal, daily deficit, a per-day food log and weigh-ins.
/// Everything lives in UserDefaults on this device, like `ProfileStore`.
@MainActor
final class CutPlanStore: ObservableObject {
    static let shared = CutPlanStore()

    struct FoodEntry: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var kcal: Int
        var at: Date
        /// Grams of protein; nil when not entered (entries from before protein tracking decode as nil).
        var protein: Double?
    }

    struct WeighIn: Codable, Identifiable, Equatable {
        var id = UUID()
        var kg: Double
        var at: Date
    }

    @Published var configured: Bool { didSet { d.set(configured, forKey: K.configured) } }
    @Published var startKg: Double { didSet { d.set(startKg, forKey: K.startKg) } }
    /// Local day key the plan (and `startKg`) started on; expected weight counts from here.
    @Published var startDay: String { didSet { d.set(startDay, forKey: K.startDay) } }
    @Published var goalKg: Double { didSet { d.set(goalKg, forKey: K.goalKg) } }
    /// The date the goal weight should be reached. The daily deficit is derived from it (and the current
    /// weight), so the allowance re-plans itself every day.
    @Published var targetDate: Date { didSet { d.set(targetDate, forKey: K.targetDate) } }
    /// Share of the daily deficit planned as workout burn; the rest comes off the food allowance.
    @Published var workoutShare: Double { didSet { d.set(workoutShare, forKey: K.workoutShare) } }
    /// Share of workout calories BEYOND the day's workout target added back to the allowance.
    /// Heart-rate estimates run high, so only half is eaten back by default.
    @Published var workoutEatBack: Double { didSet { d.set(workoutEatBack, forKey: K.eatBack) } }
    /// Under-logging allowance: every logged kcal counts this much extra (0.10 = +10%) in the budget,
    /// the fat math and expected weight. Logged entries themselves are stored as typed.
    @Published var logBuffer: Double { didSet { d.set(logBuffer, forKey: K.logBuffer) } }
    /// Daily protein target in grams per kg of GOAL weight (2.0 = 150 g at 75 kg).
    @Published var proteinPerKg: Double { didSet { d.set(proteinPerKg, forKey: K.proteinPerKg) } }
    /// Food log keyed by local day key (`yyyy-MM-dd`).
    @Published private(set) var food: [String: [FoodEntry]] { didSet { save(food, K.food) } }
    @Published private(set) var weighIns: [WeighIn] { didSet { save(weighIns, K.weighIns) } }
    /// Strap-measured workout (active) kcal per local day. Past days are computed once from the
    /// full day's heart rate; today is refreshed as the day goes on.
    @Published private(set) var activeByDay: [String: Double] { didSet { save(activeByDay, K.active) } }

    private let d = UserDefaults.standard
    private enum K {
        static let configured = "cut.configured", startKg = "cut.startKg", goalKg = "cut.goalKg"
        static let startDay = "cut.startDay", logBuffer = "cut.logBuffer", proteinPerKg = "cut.proteinPerKg"
        static let deficit = "cut.dailyDeficit", targetDate = "cut.targetDate", workoutShare = "cut.workoutShare", eatBack = "cut.workoutEatBack"
        static let food = "cut.food", weighIns = "cut.weighIns", active = "cut.activeByDay"
    }

    private init() {
        configured = d.bool(forKey: K.configured)
        startKg = d.object(forKey: K.startKg) as? Double ?? 83.3
        goalKg = d.object(forKey: K.goalKg) as? Double ?? 75
        // A saved date wins; otherwise the date the stored pace (default 500 kcal/day) reaches the goal.
        let pace = Double(d.object(forKey: K.deficit) as? Int ?? 500)
        let seedDays = max((d.object(forKey: K.startKg) as? Double ?? 83.3) - (d.object(forKey: K.goalKg) as? Double ?? 75), 0)
            * Self.kcalPerKgFat / max(pace, 1)
        targetDate = d.object(forKey: K.targetDate) as? Date
            ?? Calendar.current.date(byAdding: .day, value: Int(seedDays.rounded(.up)), to: Date()) ?? Date()
        workoutShare = d.object(forKey: K.workoutShare) as? Double ?? 0.3
        workoutEatBack = d.object(forKey: K.eatBack) as? Double ?? 0.5
        logBuffer = d.object(forKey: K.logBuffer) as? Double ?? 0.10
        proteinPerKg = d.object(forKey: K.proteinPerKg) as? Double ?? 2.0
        let loadedFood: [String: [FoodEntry]] = Self.load(d, K.food) ?? [:]
        food = loadedFood
        weighIns = Self.load(d, K.weighIns) ?? []
        activeByDay = Self.load(d, K.active) ?? [:]
        // Installs from before start days: the first day with food logged, else today.
        let today = Repository.localDayKey(Date())
        startDay = d.string(forKey: K.startDay)
            ?? loadedFood.filter { !$0.value.isEmpty }.keys.min() ?? today
        if d.string(forKey: K.startDay) == nil { d.set(startDay, forKey: K.startDay) }
        // didSet does not fire in init; pin a derived date so it doesn't slide forward each launch.
        if d.object(forKey: K.targetDate) == nil { d.set(targetDate, forKey: K.targetDate) }
    }

    func setActive(_ kcal: Double, day: String) {
        if activeByDay[day] != kcal { activeByDay[day] = kcal }
    }

    /// Days that have at least one food entry, i.e. days a deficit can honestly be computed for.
    var loggedDays: [String] { food.keys.filter { !(food[$0]?.isEmpty ?? true) }.sorted() }

    // MARK: Food

    func entries(day: String) -> [FoodEntry] { (food[day] ?? []).sorted { $0.at < $1.at } }
    /// Calories as typed.
    func logged(day: String) -> Int { (food[day] ?? []).reduce(0) { $0 + $1.kcal } }
    /// Calories as counted everywhere: logged plus the under-logging buffer.
    func eaten(day: String) -> Double { Double(logged(day: day)) * (1 + logBuffer) }

    func addFood(name: String, kcal: Int, protein: Double? = nil, day: String) {
        guard kcal > 0 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        food[day, default: []].append(FoodEntry(name: trimmed.isEmpty ? "Food" : trimmed, kcal: kcal, at: Date(),
                                                protein: protein.flatMap { $0 > 0 ? $0 : nil }))
    }

    /// Protein logged for the day, grams (as typed; the calorie buffer does not apply).
    func protein(day: String) -> Double { (food[day] ?? []).reduce(0) { $0 + ($1.protein ?? 0) } }

    /// Daily protein target, grams.
    var proteinTarget: Double { goalKg * proteinPerKg }

    func removeFood(_ id: UUID, day: String) {
        food[day]?.removeAll { $0.id == id }
        if food[day]?.isEmpty == true { food[day] = nil }
    }

    /// Distinct recent foods (newest first) for one-tap re-adding.
    func recentFoods(limit: Int = 6) -> [FoodEntry] {
        var seen = Set<String>()
        return food.values.flatMap { $0 }.sorted { $0.at > $1.at }.filter {
            seen.insert("\($0.name.lowercased())|\($0.kcal)|\($0.protein ?? 0)").inserted
        }.prefix(limit).map { $0 }
    }

    // MARK: Weight

    func logWeight(_ kg: Double) {
        guard kg > 0 else { return }
        weighIns.append(WeighIn(kg: kg, at: Date()))
    }

    // MARK: Math (Mifflin–St Jeor)

    struct Budget: Equatable {
        let bmr: Double
        let maintenance: Double      // sedentary maintenance, before workouts
        let requiredDeficit: Double  // kcal/day needed to reach the goal weight by the target date
        let floorHit: Bool           // food would go below the safe floor; the rest moved to workouts
        let foodCut: Double          // part of the deficit taken off food
        let workoutTarget: Double    // part of the deficit to burn in workouts
        let workoutDone: Double      // strap-measured active kcal so far today
        let workoutBonus: Double     // eaten back from workouts beyond the target
        let allowance: Double
        let eaten: Double
        var remaining: Double { allowance - eaten }
        var kgPerWeek: Double { requiredDeficit * 7 / CutPlanStore.kcalPerKgFat }
    }

    static func bmr(weightKg: Double, heightCm: Double, age: Int, male: Bool) -> Double {
        10 * weightKg + 6.25 * heightCm - 5 * Double(age) + (male ? 5 : -161)
    }

    func budget(weightKg: Double, heightCm: Double, age: Int, male: Bool,
                activeKcal: Double, eaten: Double, goalKg goalOverride: Double? = nil,
                targetDate dateOverride: Date? = nil, workoutShare shareOverride: Double? = nil) -> Budget {
        let bmr = Self.bmr(weightKg: weightKg, heightCm: heightCm, age: age, male: male)
        let maintenance = bmr * 1.2
        let deficit = Self.requiredDeficit(weightKg: weightKg, goalKg: goalOverride ?? goalKg,
                                           by: dateOverride ?? targetDate)
        let share = min(max(shareOverride ?? workoutShare, 0), 1)
        // Never plan food below a safe floor; whatever the floor blocks moves onto the workout target.
        let floor: Double = male ? 1500 : 1200
        let wantedCut = deficit * (1 - share)
        let foodCut = max(0, min(wantedCut, maintenance - floor))
        let workoutTarget = deficit - foodCut
        let active = max(0, activeKcal)
        let bonus = max(0, active - workoutTarget) * workoutEatBack
        return Budget(bmr: bmr, maintenance: maintenance, requiredDeficit: deficit, floorHit: wantedCut > foodCut + 0.5, foodCut: foodCut,
                      workoutTarget: workoutTarget, workoutDone: active, workoutBonus: bonus,
                      allowance: maintenance - foodCut + bonus, eaten: eaten)
    }

    /// Estimated weight at the START of `today`, for someone without a scale. Anchored on the latest
    /// weigh-in if there is one (from that day on), else `startKg` from `startDay`. Walks each logged day
    /// in order, recomputing maintenance at the weight reached so far, so the burn falls as weight does.
    /// Days with no food logged are skipped (no deficit assumed). Returns the kg and the days counted.
    func estimatedKg(beforeDay today: String, heightCm: Double, age: Int, male: Bool) -> (kg: Double, days: Int) {
        var kg = startKg, from = startDay
        if let last = weighIns.max(by: { $0.at < $1.at }) {
            let day = Repository.localDayKey(last.at)
            if day >= startDay { kg = last.kg; from = day }
        }
        var n = 0
        for k in loggedDays where k >= from && k < today {
            let maintenance = Self.bmr(weightKg: kg, heightCm: heightCm, age: age, male: male) * 1.2
            kg -= (dayBurn(maintenance: maintenance, activeKcal: activeByDay[k] ?? 0) - eaten(day: k)) / Self.kcalPerKgFat
            n += 1
        }
        return (kg, n)
    }

    /// Daily deficit to go from `weightKg` to `goalKg` by `date` (0 once the goal is reached).
    static func requiredDeficit(weightKg: Double, goalKg: Double, by date: Date, now: Date = Date()) -> Double {
        let cal = Calendar.current
        let days = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                             to: cal.startOfDay(for: date)).day ?? 1)
        return max(0, weightKg - goalKg) * kcalPerKgFat / Double(days)
    }

    /// Predicted date the goal is reached if the average daily deficit continues. nil when not losing.
    func projectedGoalDate(currentKg: Double, avgDailyDeficit: Double, from now: Date = Date()) -> Date? {
        let toLose = currentKg - goalKg
        guard toLose > 0, avgDailyDeficit > 0 else { return nil }
        let days = toLose * Self.kcalPerKgFat / avgDailyDeficit
        return Calendar.current.date(byAdding: .day, value: Int(days.rounded(.up)), to: now)
    }

    /// Energy in one kilogram of body fat (the common ~7,700 kcal rule of thumb).
    static let kcalPerKgFat: Double = 7700

    /// Full-day burn estimate: sedentary maintenance plus ALL strap-measured workout energy.
    func dayBurn(maintenance: Double, activeKcal: Double) -> Double { maintenance + max(0, activeKcal) }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
