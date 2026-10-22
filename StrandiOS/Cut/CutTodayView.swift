import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

/// The weight-loss Today screen: calorie budget, battery, live heart rate, calories burned, steps,
/// a food log and progress toward the goal weight. Nothing else.
struct CutTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var router: NavRouter
    @ObservedObject private var plan = CutPlanStore.shared

    @State private var burned: Calories.DayEnergyEstimate?
    @State private var steps: Double?
    @State private var showAddFood = false
    @State private var showWeight = false
    @State private var showPlan = false
    @State private var showGoal = false
    @State private var showSettings = false
    @State private var showHealth = false

    private var dayKey: String { Repository.localDayKey(Date()) }
    private var male: Bool { profile.sex != "female" }

    /// Today's burn: the full day's everyday burn plus workouts the strap has measured so far. The one
    /// figure the Burned tile, the fat card, today's bar and today's expected weight all use.
    private var burnedSoFar: Double {
        plan.dayBurn(maintenance: budget.maintenance, activeKcal: burned?.activeKcal ?? 0)
    }

    private var budget: CutPlanStore.Budget {
        plan.budget(weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age, male: male,
                    activeKcal: burned?.activeKcal ?? 0, eaten: plan.eaten(day: dayKey))
    }

    var body: some View {
        ScreenScaffold(title: "Today", subtitle: LocalizedStringKey(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))),
                       onRefresh: { ble.syncNow(); await load() }, lazy: false, topBackground: nil,
                       trailing: { gearMenu }) {
            VStack(spacing: NoopMetrics.sectionGap) {
                budgetCard
                fatCard
                LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                    GridItem(.flexible(), spacing: NoopMetrics.gap)],
                          spacing: NoopMetrics.gap) {
                    tile("Heart rate", icon: "heart.fill", value: hrText, unit: hrText == "–" ? "" : "bpm",
                         caption: live.connected ? "Live" : "Strap not connected", tint: StrandPalette.liquidHeart)
                    tile("Battery", icon: batteryIcon, value: batteryText, unit: "",
                         caption: live.charging == true ? "Charging" : (live.connected ? "Strap" : "Offline"),
                         tint: StrandPalette.chargeColor)
                    tile("Burned", icon: "flame.fill", value: format(burnedSoFar), unit: "kcal",
                         caption: (burned?.activeKcal ?? 0) >= 1
                            ? "\(format(burned?.activeKcal ?? 0)) from workouts" : "No workout yet",
                         tint: StrandPalette.metricAmber)
                    tile("Steps", icon: "figure.walk", value: steps.map { format($0) } ?? "–", unit: "",
                         caption: "Goal 10,000", tint: StrandPalette.metricCyan)
                }
                foodCard
                goalCard
            }
        }
        .task {
            seedPlanIfNeeded()
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
        .sheet(isPresented: $showAddFood) { AddFoodSheet(day: dayKey) }
        .sheet(isPresented: $showWeight) { LogWeightSheet() }
        .sheet(isPresented: $showPlan) { CutPlanSheet() }
        .sheet(isPresented: $showGoal) { GoalSheet(currentKg: estimate.kg) }
        .sheet(isPresented: $showHealth, onDismiss: { Task { await load() } }) {
            NavigationStack {
                AppleHealthView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showHealth = false }.foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
    }

    /// With the More tab gone, Devices (pairing) and Settings are reached from here.
    private var gearMenu: some View {
        Menu {
            Button { router.requestedDestination = .devices } label: {
                Label("Devices", systemImage: "sensor.tag.radiowaves.forward")
            }
            Button { showHealth = true } label: {
                Label("Apple Health", systemImage: "heart.text.square")
            }
            Button { showPlan = true } label: {
                Label("Plan settings", systemImage: "slider.horizontal.3")
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: NoopMetrics.compactControlSize, height: NoopMetrics.compactControlSize)
        }
        .accessibilityLabel("Settings")
    }

    // MARK: Cards

    private var good: Color { StrandPalette.chargeColor }
    private var bad: Color { StrandPalette.statusCritical }

    private var budgetCard: some View {
        let b = budget
        let over = b.remaining < 0
        let tint = over ? bad : good
        return NoopCard(tint: tint) {
            VStack(spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space5) {
                    ZStack {
                        Circle().stroke(StrandPalette.hairline, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: min(b.eaten / max(b.allowance, 1), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.5), value: b.eaten)
                        VStack(spacing: 0) {
                            Text(format(abs(b.remaining)))
                                .font(StrandFont.number(32, weight: .bold))
                                .foregroundStyle(over ? bad : StrandPalette.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(over ? "over" : "kcal left")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(NoopMetrics.space4)
                    }
                    .frame(width: 140, height: 140)

                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        iconStat("fork.knife", StrandPalette.metricAmber, format(b.eaten),
                                 plan.logBuffer > 0 ? "eaten · +\(Int((plan.logBuffer * 100).rounded()))%" : "eaten")
                        iconStat("flame.fill", StrandPalette.metricRose,
                                 "\(format(b.workoutDone)) / \(format(b.workoutTarget))",
                                 b.workoutBonus > 0 ? "workout · +\(format(b.workoutBonus)) food" : "workout burn")
                        iconStat("target", StrandPalette.accent, format(b.allowance), "allowed")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                proteinBar
                Button { showAddFood = true } label: {
                    Label("Add food", systemImage: "plus")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NoopMetrics.space2)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(StrandPalette.accent)
            }
        }
    }

    private var proteinBar: some View {
        let got = plan.protein(day: dayKey)
        let target = max(plan.proteinTarget, 1)
        let tint = StrandPalette.metricPurple
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Label("Protein", systemImage: "fish.fill")
                    .font(StrandFont.subhead).foregroundStyle(tint)
                Spacer()
                Text("\(Int(got.rounded())) / \(Int(target.rounded())) g")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(got >= target ? tint : StrandPalette.textPrimary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: got > 0 ? max(8, g.size.width * min(got / target, 1)) : 0)
                }
            }
            .frame(height: 8)
        }
    }

    /// Calories → fat: today's burn − food as an equation, the resulting grams of fat, and a
    /// seven-day bar strip of daily deficits. Uses 1 kg fat ≈ 7,700 kcal.
    private var fatCard: some View {
        let b = budget
        let burn = burnedSoFar
        let deficit = burn - b.eaten
        let days = weekDays(maintenance: b.maintenance)
        let weekKcal = days.compactMap(\.deficit).reduce(0, +)
        let tint = deficit >= 0 ? good : bad
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack {
                    Text("FAT").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    chip("1 kg = 7,700 kcal")
                }

                HStack(spacing: NoopMetrics.space2) {
                    eqTile("flame.fill", StrandPalette.metricRose, format(burn), "burned")
                    op("−")
                    eqTile("fork.knife", StrandPalette.metricAmber, format(b.eaten), "eaten")
                    op("=")
                    eqTile(deficit >= 0 ? "arrow.down" : "arrow.up", tint, format(abs(deficit)),
                           deficit >= 0 ? "deficit" : "surplus")
                }

                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: "drop.fill").foregroundStyle(tint)
                    Text(fatText(deficit)).font(StrandFont.number(40, weight: .bold)).foregroundStyle(tint)
                    Text(deficit >= 0 ? "fat burned today" : "fat stored today")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }

                weekBars(days, totalKcal: weekKcal)
            }
        }
    }

    private struct DayBar: Identifiable {
        let id: String
        let letter: String
        let deficit: Double?   // nil = no food logged that day
        let isToday: Bool
    }

    private func weekBars(_ days: [DayBar], totalKcal: Double) -> some View {
        let peak = max(days.compactMap { $0.deficit.map(abs) }.max() ?? 1, 1)
        let logged = days.contains { $0.deficit != nil }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("7 days").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if logged {
                    Text(String(format: "%@%.2f kg", totalKcal >= 0 ? "−" : "+", abs(totalKcal) / CutPlanStore.kcalPerKgFat))
                        .font(StrandFont.bodyNumber).foregroundStyle(totalKcal >= 0 ? good : bad)
                }
            }
            HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                ForEach(days) { d in
                    VStack(spacing: NoopMetrics.space1) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(StrandPalette.hairline).frame(height: 56)
                            if let v = d.deficit {
                                Capsule()
                                    .fill(v >= 0 ? good : bad)
                                    .frame(height: max(6, 56 * abs(v) / peak))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Text(d.letter)
                            .font(StrandFont.caption)
                            .foregroundStyle(d.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func iconStat(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(StrandFont.number(17, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func eqTile(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(StrandFont.number(17, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.12)))
    }

    private func op(_ s: String) -> some View {
        Text(s).font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(Capsule().fill(StrandPalette.hairline))
    }

    /// Grams (under 1 kg) or kilograms of fat for a kcal deficit; sign dropped (the label carries it).
    private func fatText(_ kcal: Double) -> String {
        let g = abs(kcal) / CutPlanStore.kcalPerKgFat * 1000
        return g < 1000 ? "\(Int(g.rounded())) g" : String(format: "%.2f kg", g / 1000)
    }

    /// The last seven calendar days, oldest first. A day with nothing logged has no deficit rather than
    /// being counted as a full fast.
    private func weekDays(maintenance: Double) -> [DayBar] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { back -> DayBar? in
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let k = Repository.localDayKey(date)
            var deficit: Double?
            if !plan.entries(day: k).isEmpty {
                let burn = k == dayKey ? burnedSoFar
                    : plan.dayBurn(maintenance: maintenance, activeKcal: plan.activeByDay[k] ?? 0)
                deficit = burn - plan.eaten(day: k)
            }
            return DayBar(id: k, letter: String(date.formatted(.dateTime.weekday(.narrow))),
                          deficit: deficit, isToday: back == 0)
        }
    }

    /// The pace the goal date is predicted from: the average burn − food over the last 7 COMPLETE logged
    /// days (today is still in progress, so excluded). Under two such days, the planned deficit stands in.
    private var pace: (kcal: Double, days: Int, fromPlan: Bool) {
        let maintenance = budget.maintenance
        let recent = plan.loggedDays.filter { $0 < dayKey && $0 >= plan.startDay }.suffix(7)
        guard recent.count >= 2 else { return (budget.requiredDeficit, 0, true) }
        let total = recent.reduce(0.0) { sum, k in
            sum + plan.dayBurn(maintenance: maintenance, activeKcal: plan.activeByDay[k] ?? 0) - plan.eaten(day: k)
        }
        return (total / Double(recent.count), recent.count, false)
    }

    /// Estimated weight right now: the start-of-day estimate minus today's deficit so far.
    private var estimate: (kg: Double, days: Int) {
        let base = plan.estimatedKg(beforeDay: dayKey, heightCm: profile.heightCm, age: profile.age, male: male)
        let todayLogged = !plan.entries(day: dayKey).isEmpty
        let today = todayLogged ? (burnedSoFar - plan.eaten(day: dayKey)) / CutPlanStore.kcalPerKgFat : 0
        return (base.kg - today, base.days + (todayLogged ? 1 : 0))
    }

    private var foodCard: some View {
        let entries = plan.entries(day: dayKey)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("FOOD TODAY").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                if entries.isEmpty {
                    Text("Nothing logged yet.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(entries) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text(e.at.formatted(date: .omitted, time: .shortened))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(e.kcal) kcal").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                            if let p = e.protein {
                                Text("\(Int(p.rounded())) g protein").font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.metricPurple)
                            }
                        }
                        Button { plan.removeFood(e.id, day: dayKey) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(e.name)")
                    }
                }
            }
        }
    }

    /// The goal in three plain parts: what you're aiming for, how you're doing, and what today needs.
    private var goalCard: some View {
        let current = estimate.kg
        let toLose = max(current - plan.goalKg, 0)
        let reached = current <= plan.goalKg
        let b = budget
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack {
                    Text("GOAL").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button { showGoal = true } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(StrandFont.caption)
                            .padding(.horizontal, NoopMetrics.space2)
                            .padding(.vertical, NoopMetrics.space1)
                            .background(Capsule().fill(StrandPalette.accent.opacity(0.15)))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }

                // 1. What you're aiming for.
                Text(reached ? "Goal reached: \(String(format: "%.1f", plan.goalKg)) kg"
                     : "Lose \(String(format: "%.1f", toLose)) kg → \(String(format: "%.1f", plan.goalKg)) kg by \(plan.targetDate.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(StrandFont.number(20, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                weightBar(current: current)

                // 2. How you're doing.
                statusLine(current: current)

                if !reached {
                    Divider().overlay(StrandPalette.hairline)
                    // 3. What today needs. The same numbers the calories card above uses.
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("TODAY'S PLAN").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                        planLine("fork.knife", StrandPalette.metricAmber, "Eat up to **\(format(b.allowance)) kcal**")
                        if b.workoutTarget >= 1 {
                            planLine("flame.fill", StrandPalette.metricRose, "Burn **\(format(b.workoutTarget)) kcal** in workouts")
                        }
                    }
                }

                Button { showWeight = true } label: {
                    Label("Set weight", systemImage: "scalemass")
                        .font(StrandFont.subhead).frame(maxWidth: .infinity).padding(.vertical, NoopMetrics.space1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StrandPalette.accent)
            }
        }
    }

    /// Start weight on the left, goal on the right, a dot where the estimate is now.
    private func weightBar(current: Double) -> some View {
        let span = max(plan.startKg - plan.goalKg, 0.1)
        let done = min(max((plan.startKg - current) / span, 0), 1)
        return VStack(spacing: NoopMetrics.space1) {
            HStack {
                Text(String(format: "%.1f", plan.startKg))
                Spacer()
                Text(String(format: "%.1f", plan.goalKg))
            }
            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            GeometryReader { g in
                let x = g.size.width * done
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline).frame(height: 8)
                    Capsule().fill(good).frame(width: max(8, x), height: 8)
                    Circle().fill(StrandPalette.textPrimary).frame(width: 16, height: 16)
                        .offset(x: min(max(x - 8, 0), g.size.width - 16))
                }
                .frame(height: 16)
                Text(String(format: "%.1f now", current))
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
                    .position(x: min(max(x, 28), g.size.width - 28), y: 28)
            }
            .frame(height: 38)
        }
    }

    private func statusLine(current: Double) -> some View {
        let p = pace
        let eta = plan.projectedGoalDate(currentKg: current, avgDailyDeficit: p.kcal)
        let cal = Calendar.current
        let late = eta.map { cal.dateComponents([.day], from: cal.startOfDay(for: plan.targetDate),
                                                to: cal.startOfDay(for: $0)).day ?? 0 }
        let when = eta.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? ""
        let (text, tint): (String, Color) = {
            if current <= plan.goalKg { return ("Done. Set a new goal any time.", good) }
            if p.fromPlan { return ("Log 2 full days to see if you're on track", StrandPalette.textTertiary) }
            guard let late else { return ("Not losing lately: eat less or move more", bad) }
            if late <= 0 { return ("On track: you'll get there \(when)", good) }
            return ("\(late) day\(late == 1 ? "" : "s") behind: you'll get there \(when)", StrandPalette.statusWarning)
        }()
        return HStack(spacing: NoopMetrics.space2) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(text).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func planLine(_ icon: String, _ tint: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.15)))
            Text(text).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: Pieces

    private func tile(_ title: String, icon: String, value: String, unit: String, caption: String, tint: Color) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label(title, systemImage: icon)
                    .font(StrandFont.subhead).foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                    Text(value).font(StrandFont.number(28, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if !unit.isEmpty {
                        Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var hrText: String {
        guard live.connected, let hr = live.heartRate, hr > 0 else { return "–" }
        return "\(hr)"
    }

    private var batteryText: String {
        guard live.activeIsWhoop, let pct = live.batteryPct else { return "–" }
        return "\(Int(pct.rounded()))%"
    }

    private var batteryIcon: String {
        if live.charging == true { return "battery.100.bolt" }
        guard let pct = live.batteryPct else { return "battery.0" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func format(_ v: Double) -> String { Int(v.rounded()).formatted() }

    // MARK: Data

    /// First launch: write the owner's stated numbers into the profile once, so every estimate
    /// (calories, HR zones) uses them. Editable afterwards under Edit plan.
    private func seedPlanIfNeeded() {
        guard !plan.configured else { return }
        profile.weightKg = 83.3
        profile.heightCm = 180
        profile.sex = "male"
        profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: 24)
        plan.startKg = 83.3
        plan.startDay = dayKey
        plan.goalKg = 75
        plan.configured = true
    }

    private func load() async {
        // No scale: the start-of-day estimate IS the weight every calculation uses (BMR, allowance,
        // strap calorie estimates). Rounded to 0.1 kg so it doesn't churn.
        let base = plan.estimatedKg(beforeDay: dayKey, heightCm: profile.heightCm, age: profile.age, male: male)
        let rounded = (base.kg * 10).rounded() / 10
        if abs(profile.weightKg - rounded) >= 0.05 { profile.weightKg = rounded }
        let start = Calendar.current.startOfDay(for: Date())
        let from = Int(start.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        if hr.isEmpty {
            burned = nil
        } else {
            let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                 age: Double(profile.age), sex: profile.sex)
            burned = Calories.estimateDayEnergy(hr, profile: up, hrmax: Double(profile.hrMax),
                                                restingHR: repo.today?.restingHr.map(Double.init))
        }
        await backfillActive()

        let key = dayKey
        let apple = await repo.appleDailyRows(days: 3).filter { $0.day == key }.compactMap { $0.steps }.max()
        let est = await repo.exploreSeries(key: "steps_est", source: "my-whoop", days: 3).last { $0.day == key }?.value
        let measured = repo.today?.day == key ? repo.today?.steps : nil
        steps = measured.map(Double.init) ?? apple.map(Double.init) ?? est

    }

    /// Workout kcal for past logged days since the plan started (up to 120 days back) that have no
    /// stored value, computed once from each whole day's heart rate so the fat totals count them.
    private func backfillActive() async {
        let cal = Calendar.current
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        for offset in 1..<120 {
            guard let start = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            let key = Repository.localDayKey(start)
            if key < plan.startDay { break }
            guard plan.activeByDay[key] == nil, !plan.entries(day: key).isEmpty else { continue }
            let hr = await repo.hrSamples(from: Int(start.timeIntervalSince1970),
                                          to: Int(end.timeIntervalSince1970) - 1, limit: 200_000)
            let resting = repo.days.last(where: { $0.day == key })?.restingHr.map(Double.init)
            let e = Calories.estimateDayEnergy(hr, profile: up, hrmax: Double(profile.hrMax), restingHR: resting)
            plan.setActive(e.activeKcal, day: key)
        }
    }
}

// MARK: - Sheets

private struct AddFoodSheet: View {
    let day: String
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal = ""
    @State private var protein = ""
    @FocusState private var kcalFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you eat? (optional)", text: $name)
                    TextField("Calories", text: $kcal)
                        .keyboardType(.numberPad)
                        .focused($kcalFocused)
                    TextField("Protein, g (optional)", text: $protein)
                        .keyboardType(.decimalPad)
                }
                let recent = plan.recentFoods()
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { f in
                            Button {
                                plan.addFood(name: f.name, kcal: f.kcal, protein: f.protein, day: day)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(f.name).foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text(f.protein.map { "\(f.kcal) kcal · \(Int($0.rounded())) g P" } ?? "\(f.kcal) kcal")
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        plan.addFood(name: name, kcal: Int(kcal) ?? 0,
                                     protein: Double(protein.replacingOccurrences(of: ",", with: ".")), day: day)
                        dismiss()
                    }
                    .disabled((Int(kcal) ?? 0) <= 0)
                }
            }
            .onAppear { kcalFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct LogWeightSheet: View {
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Weight (kg)", text: $kg).keyboardType(.decimalPad)
                } footer: {
                    Text("Optional. If you weigh yourself somewhere, enter it here and the estimate restarts from it.")
                }
                if !plan.weighIns.isEmpty {
                    Section("History") {
                        ForEach(plan.weighIns.reversed().prefix(14)) { w in
                            HStack {
                                Text(w.at.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(String(format: "%.1f kg", w.kg)).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Set weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = parsed {
                            plan.logWeight(v)
                            profile.weightKg = v
                        }
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
            .onAppear { kg = String(format: "%.1f", profile.weightKg) }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsed: Double? {
        Double(kg.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 20 && $0 < 400 ? $0 : nil }
    }
}

private struct CutPlanSheet: View {
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                        row("Height", String(format: "%.0f cm", profile.heightCm))
                    }
                    Stepper(value: ageBinding, in: 14...100) { row("Age", "\(profile.age)") }
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                    }
                }
                Section("Goal") {
                    Stepper(value: $plan.startKg, in: 40...250, step: 0.1) {
                        row("Starting weight", String(format: "%.1f kg", plan.startKg))
                    }
                    Picker("Deficit from", selection: $plan.workoutShare) {
                        ForEach([0.0, 0.2, 0.3, 0.4, 0.5], id: \.self) { s in
                            Text(s == 0 ? "Food only"
                                 : "\(Int(((1 - s) * 100).rounded()))% food · \(Int((s * 100).rounded()))% workout").tag(s)
                        }
                    }
                    Picker("Protein target", selection: $plan.proteinPerKg) {
                        ForEach([1.6, 2.0, 2.2], id: \.self) { v in
                            Text(String(format: "%.1f g/kg · %.0f g", v, v * plan.goalKg)).tag(v)
                        }
                    }
                    Picker("Logging buffer", selection: $plan.logBuffer) {
                        Text("Off").tag(0.0)
                        Text("+10%").tag(0.10)
                        Text("+20%").tag(0.20)
                        Text("+30%").tag(0.30)
                    }
                    Picker("Eat back extra workout", selection: $plan.workoutEatBack) {
                        Text("None").tag(0.0)
                        Text("Half").tag(0.5)
                        Text("All").tag(1.0)
                    }
                }
                Section {
                    let b = plan.budget(weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age,
                                        male: profile.sex != "female", activeKcal: 0, eaten: 0)
                    row("BMR", "\(Int(b.bmr.rounded())) kcal")
                    row("Maintenance (no workouts)", "\(Int(b.maintenance.rounded())) kcal")
                    row("Daily deficit", "\(Int(b.requiredDeficit.rounded())) kcal · \(String(format: "%.2f", b.kgPerWeek)) kg/week")
                    row("Food allowance", "\(Int(b.allowance.rounded())) kcal")
                    row("Workout burn target", "\(Int(b.workoutTarget.rounded())) kcal")
                } header: {
                    Text("Your numbers")
                } footer: {
                    Text("BMR uses Mifflin–St Jeor; maintenance assumes a desk day (×1.2).")
                }
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(get: { profile.age }, set: { profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: $0) })
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Set the goal (weight + date) and see what it means per day before saving: how much to eat and burn,
/// the deficit and weekly pace, with warnings when it is unsafe or hits the food floor.
struct GoalSheet: View {
    let currentKg: Double
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var goalKg = 75.0
    @State private var date = Date()
    @State private var share = 0.3

    private static var earliest: Date { Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date() }

    var body: some View {
        let male = profile.sex != "female"
        let b = plan.budget(weightKg: currentKg, heightCm: profile.heightCm, age: profile.age, male: male,
                            activeKcal: 0, eaten: 0, goalKg: goalKg, targetDate: date, workoutShare: share)
        let now = plan.budget(weightKg: currentKg, heightCm: profile.heightCm, age: profile.age, male: male,
                              activeKcal: 0, eaten: 0)
        // More than ~1% of body weight a week costs muscle and is hard to sustain.
        let tooFast = b.kgPerWeek > currentKg * 0.01
        return NavigationStack {
            ScrollView {
                VStack(spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("GOAL WEIGHT").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                            HStack {
                                Text(String(format: "%.1f kg", goalKg)).font(StrandFont.number(28, weight: .bold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Stepper("", value: $goalKg, in: 40...max(40, currentKg - 0.5), step: 0.5).labelsHidden()
                            }
                            Text(String(format: "%.1f kg to lose from %.1f kg", max(currentKg - goalKg, 0), currentKg))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    NoopCard {
                        DatePicker("By", selection: $date, in: Self.earliest..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(StrandPalette.accent)
                    }
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("DEFICIT FROM").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                            Picker("Split", selection: $share) {
                                Text("Food").tag(0.0)
                                Text("80/20").tag(0.2)
                                Text("70/30").tag(0.3)
                                Text("60/40").tag(0.4)
                                Text("50/50").tag(0.5)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                        GridItem(.flexible(), spacing: NoopMetrics.gap)], spacing: NoopMetrics.gap) {
                        stat("fork.knife", StrandPalette.metricAmber, n(b.allowance), "eat / day", delta: b.allowance - now.allowance)
                        stat("flame.fill", StrandPalette.metricRose, n(b.workoutTarget), "workout burn / day",
                             delta: b.workoutTarget - now.workoutTarget)
                        stat("arrow.down", StrandPalette.chargeColor, n(b.requiredDeficit), "deficit / day", delta: nil)
                        stat("scalemass", tooFast ? StrandPalette.statusCritical : StrandPalette.chargeColor,
                             String(format: "%.2f kg", b.kgPerWeek), "per week", delta: nil)
                    }
                    if tooFast {
                        Label("Faster than 1% of body weight a week", systemImage: "exclamationmark.triangle.fill")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusCritical)
                    }
                    if b.floorHit {
                        Label("Food is at the 1,500 kcal floor; the rest moved to workouts", systemImage: "info.circle.fill")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        plan.goalKg = goalKg
                        plan.targetDate = date
                        plan.workoutShare = share
                        dismiss()
                    }
                }
            }
            .onAppear {
                goalKg = plan.goalKg
                date = max(plan.targetDate, Self.earliest)
                share = [0.0, 0.2, 0.3, 0.4, 0.5].contains(plan.workoutShare) ? plan.workoutShare : 0.3
            }
        }
    }

    private func n(_ v: Double) -> String { Int(v.rounded()).formatted() }

    /// A preview tile; `delta` shows the change against the current plan so the effect is obvious.
    private func stat(_ icon: String, _ tint: Color, _ value: String, _ label: String, delta: Double?) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(value).font(StrandFont.number(24, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                if let delta, abs(delta) >= 1 {
                    Text((delta > 0 ? "+" : "−") + n(abs(delta)) + " vs now")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
