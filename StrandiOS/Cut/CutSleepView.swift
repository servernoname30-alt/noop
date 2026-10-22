import SwiftUI
import StrandDesign
import WhoopStore

/// The simple Sleep tab: last night, the past seven nights against the need, and weekly averages.
struct CutSleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var ble: BLEManager

    /// Main (longest) sleep block per local wake day, newest last.
    @State private var nights: [String: CachedSleepSession] = [:]
    @State private var lastNight: CachedSleepSession?

    private var need: Double { SleepModel.debtNeedMin(days: repo.days) }

    private struct Night: Identifiable {
        let id: String
        let letter: String
        let asleepMin: Double?
        let isToday: Bool
    }

    private var week: [Night] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return (0..<7).reversed().compactMap { back in
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let k = Repository.localDayKey(date)
            let asleep = back == 0 ? repo.today?.totalSleepMin : byDay[k]?.totalSleepMin
            return Night(id: k, letter: String(date.formatted(.dateTime.weekday(.narrow))),
                         asleepMin: asleep, isToday: back == 0)
        }
    }

    var body: some View {
        ScreenScaffold(title: "Sleep", onRefresh: { ble.syncNow(); await load() }) {
            VStack(spacing: NoopMetrics.sectionGap) {
                LastNightCard(day: repo.today, need: need, night: lastNight)
                weekCard
                averagesCard
            }
        }
        .task { await load() }
    }

    private var weekCard: some View {
        let w = week
        let peak = max(w.compactMap(\.asleepMin).max() ?? need, need) * 1.1
        let barH: CGFloat = 120
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("7 NIGHTS").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    HStack(spacing: NoopMetrics.space1) {
                        Rectangle().fill(StrandPalette.textTertiary).frame(width: 12, height: 2)
                        Text("need \(sleepHM(need))").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                        ForEach(w) { n in
                            VStack(spacing: NoopMetrics.space1) {
                                Text(n.asleepMin.map { String(format: "%.1f", $0 / 60) } ?? "")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                ZStack(alignment: .bottom) {
                                    Capsule().fill(StrandPalette.hairline).frame(height: barH)
                                    if let m = n.asleepMin {
                                        Capsule()
                                            .fill(m >= need ? StrandPalette.restColor : StrandPalette.restColor.opacity(0.55))
                                            .frame(height: max(6, barH * m / peak))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                Text(n.letter).font(StrandFont.caption)
                                    .foregroundStyle(n.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            }
                        }
                    }
                    // Need line, positioned against the bar area (bars sit above the day letters).
                    GeometryReader { g in
                        let y = g.size.height - dayLetterHeight - barH * need / peak
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: g.size.width, y: y))
                        }
                        .stroke(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Height of the day-letter row plus its spacing under the bars.
    private var dayLetterHeight: CGFloat { 16 + NoopMetrics.space1 }

    private var averagesCard: some View {
        let asleep = week.compactMap(\.asleepMin)
        let blocks = Array(nights.values)
        return NoopCard {
            HStack {
                avg("moon.fill", asleep.isEmpty ? "–" : sleepHM(asleep.reduce(0, +) / Double(asleep.count)), "avg sleep")
                Spacer()
                avg("bed.double.fill", averageClock(blocks.map(\.effectiveStartTs)), "avg bedtime")
                Spacer()
                avg("sun.max.fill", averageClock(blocks.map(\.endTs)), "avg wake")
            }
        }
    }

    private func avg(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Image(systemName: icon).foregroundStyle(StrandPalette.restColor)
            Text(value).font(StrandFont.number(18, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Mean clock time of timestamps, wrapped around noon so 23:30 and 00:30 average to midnight.
    private func averageClock(_ ts: [Int]) -> String {
        guard !ts.isEmpty else { return "–" }
        let cal = Calendar.current
        let mins = ts.map { t -> Int in
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(t)))
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            return m < 12 * 60 ? m + 24 * 60 : m
        }
        let mean = (mins.reduce(0, +) / mins.count) % (24 * 60)
        let date = cal.date(bySettingHour: mean / 60, minute: mean % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func load() async {
        let blocks = await repo.allSleepSessions(days: 8)
        var byDay: [String: CachedSleepSession] = [:]
        for b in blocks {
            let k = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(b.endTs)))
            if let cur = byDay[k], cur.endTs - cur.effectiveStartTs >= b.endTs - b.effectiveStartTs { continue }
            byDay[k] = b
        }
        nights = byDay
        lastNight = LastNightCard.pick(blocks)
    }
}

/// Last night: hours asleep against the need (ring), bed → wake, and a stage bar.
struct LastNightCard: View {
    /// Last night's main block: the longest session that ended in the past 20 hours. The one rule
    /// both Today and the Sleep tab use, so the two cards cannot disagree.
    static func pick(_ blocks: [CachedSleepSession], now: Date = Date()) -> CachedSleepSession? {
        let to = Int(now.timeIntervalSince1970)
        return blocks
            .filter { $0.endTs >= to - 20 * 3600 && $0.endTs <= to + 3600 }
            .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
    }

    let day: DailyMetric?
    let need: Double
    let night: CachedSleepSession?

    var body: some View {
        let asleep = day?.totalSleepMin
        let pct = asleep.map { min($0 / max(need, 1), 1) } ?? 0
        let inBed = night.map { Double($0.endTs - $0.effectiveStartTs) / 60 }
        let awake = max((inBed ?? 0) - (asleep ?? 0), 0)
        let tint = StrandPalette.restColor
        return NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("LAST NIGHT").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                if let asleep {
                    HStack(spacing: NoopMetrics.space5) {
                        ZStack {
                            Circle().stroke(StrandPalette.hairline, lineWidth: 10)
                            Circle().trim(from: 0, to: pct)
                                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int((asleep / max(need, 1) * 100).rounded()))%")
                                .font(StrandFont.number(20, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        }
                        .frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(sleepHM(asleep)).font(StrandFont.number(34, weight: .bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("of \(sleepHM(need)) needed").font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            if let n = night {
                                Label("\(sleepClock(n.effectiveStartTs)) → \(sleepClock(n.endTs))", systemImage: "bed.double.fill")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                    stageBar([(day?.deepMin ?? 0, StrandPalette.sleepDeep, "Deep"),
                              (day?.remMin ?? 0, StrandPalette.sleepREM, "REM"),
                              (day?.lightMin ?? 0, StrandPalette.sleepLight, "Light"),
                              (awake, StrandPalette.sleepAwake, "Awake")])
                } else {
                    Label("No sleep recorded last night", systemImage: "moon.zzz")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func stageBar(_ parts: [(min: Double, color: Color, name: String)]) -> some View {
        let shown = parts.filter { $0.min > 0 }
        let total = max(shown.reduce(0) { $0 + $1.min }, 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(shown, id: \.name) { p in
                        Rectangle().fill(p.color)
                            .frame(width: max(2, (g.size.width - CGFloat(shown.count - 1) * 2) * p.min / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: NoopMetrics.space3) {
                ForEach(shown, id: \.name) { p in
                    HStack(spacing: NoopMetrics.space1) {
                        Circle().fill(p.color).frame(width: 7, height: 7)
                        Text(p.name).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(sleepHM(p.min)).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .lineLimit(1)
                }
            }
            .minimumScaleFactor(0.8)
        }
    }
}

func sleepHM(_ minutes: Double) -> String {
    let m = Int(minutes.rounded())
    return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
}

func sleepClock(_ ts: Int) -> String {
    Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
}
