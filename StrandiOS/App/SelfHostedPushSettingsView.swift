#if os(iOS)
import SwiftUI
import StrandDesign

/// Personal build: the opt-in surface for sending strap data to the owner's own receiver (protocol 1.0,
/// docs/PUSH_PROTOCOL.md). Default OFF; the endpoint is HTTPS (the receiver sits behind `tailscale serve`),
/// the token is kept in the Keychain. Nothing is read back from the receiver beyond acknowledgements.
struct SelfHostedPushSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var center = SelfHostedPushCenter.shared
    @AppStorage(SelfHostedPushSettings.enabledKey) private var enabled = false
    @AppStorage(SelfHostedPushSettings.endpointKey) private var endpoint = ""
    @AppStorage(SelfHostedPushSettings.appleHealthKey) private var appleHealth = true
    @State private var tokenDraft = ""
    @State private var hasToken = SelfHostedPushSettings.token != nil
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        ScreenScaffold(title: "Self-hosted push",
                       subtitle: "Данные с браслета — на свой приёмник, после каждой синхронизации.") {
            settingsCard
            statusCard
        }
    }

    private var endpointValid: Bool { SelfHostedPushSettings.endpoint(from: endpoint) != nil }

    private func field<F: View>(_ label: String, _ content: F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
    }

    private var settingsCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $enabled) {
                    Text("Отправлять после каждой синхронизации")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)

                Toggle(isOn: $appleHealth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Health тоже")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Тренировки, дни и сон с Apple Watch, отдельным устройством")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)

                field("Адрес приёмника", TextField("https://имя-пк.tailnet.ts.net:8443/noop/push", text: $endpoint).keyboardType(.URL))
                if !endpoint.isEmpty && !endpointValid {
                    Text("Нужен адрес https://… без логина, параметров и #")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                field(hasToken ? "Токен (сохранён; введи новый, чтобы заменить)" : "Токен (push из tokens.json)",
                      SecureField("вставь токен", text: $tokenDraft).onSubmit(saveToken))
                if !tokenDraft.isEmpty {
                    Button("Сохранить токен", action: saveToken).buttonStyle(NoopButtonStyle(.secondary))
                }

                HStack(spacing: 10) {
                    Button(checking ? "Проверяю…" : "Проверить связь") {
                        checking = true
                        Task {
                            checkResult = await center.testConnection()
                            checking = false
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(checking || !endpointValid || !hasToken)

                    Button(center.running ? "Отправляю…" : "Отправить сейчас") {
                        Task { await center.sendNow(repo: model.repo, deviceId: model.deviceId) }
                    }
                    .buttonStyle(NoopButtonStyle(.primary))
                    .disabled(center.running || !endpointValid || !hasToken)
                }
                if let checkResult {
                    Text(checkResult)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Телефон отправляет только новые строки и изменения за последние 14 дней. Если сети нет, ничего не теряется: всё уйдёт при следующей синхронизации. Ответ приёмника никогда не меняет данные в NOOP.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Состояние").strandOverline()
                if let success = center.lastSuccess {
                    Text("Последняя отправка: \(success.formatted(date: .abbreviated, time: .shortened)) · строк: \(center.lastRows)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("Ещё ни разу не отправлялось")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let failure = center.lastFailure {
                    Text("Последняя ошибка: \(failure)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func saveToken() {
        guard !tokenDraft.isEmpty else { return }
        if SelfHostedPushSettings.setToken(tokenDraft) {
            tokenDraft = ""
            hasToken = SelfHostedPushSettings.token != nil
            checkResult = "Токен сохранён"
        } else {
            checkResult = "Не удалось сохранить токен в Keychain"
        }
    }
}
#endif
