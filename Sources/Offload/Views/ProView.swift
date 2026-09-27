import OffloadCore
import SwiftUI

/// Окно «OffLoadAI Pro»: что в нём, что бесплатно всегда, цена, ключ.
struct ProSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    /// Цена — одной строкой здесь и в README («OffLoadAI Pro»).
    static let price = "1 490 ₽ или $19 — один раз"
    static let terms = "Ключ работает всегда. Новые версии — год, дальше продление за полцены; не продлили — остаётся последняя версия того года."

    var body: some View {
        let pro = app.pro
        SheetLayout(systemImage: "sparkles", title: "OffLoadAI Pro", subtitle: subtitle, width: 540) {
            if let reason = pro.reason, !pro.status.isPro {
                Notice(.info, "«\(reason.title)» — в OffLoadAI Pro. \(reasonTail)")
            }
            VStack(spacing: 0) {
                ForEach(ProFeature.allCases, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemImage: feature.symbol, tone: pro.status.isPro ? .good : .brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).fontWeight(.medium)
                            Text(feature.detail).font(.callout).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if pro.status.isPro {
                            Image(systemName: "checkmark").foregroundStyle(Theme.ok).accessibilityLabel("Открыто")
                        }
                    }
                    .padding(.vertical, 8)
                    if feature != ProFeature.allCases.last { RowDivider(inset: 40) }
                }
            }
            Text("Бесплатно всегда: сейф, перенос со сверкой, возврат перенесённого, очистка мусора и Docker, старые установщики, ключи и токены в сейф, восстановление из iCloud. Вернуть своё OffLoadAI не мешает никогда — ни без ключа, ни после пробы.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            licenseBlock
        } actions: {
            if pro.status.isPro {
                if case .licensed = pro.status {} else {
                    Button("Купить…") { NSWorkspace.shared.open(ProModel.purchaseURL) }
                }
                Button("Готово") { dismiss() }
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Купить…") { NSWorkspace.shared.open(ProModel.purchaseURL) }
                    .prominentButton()
            }
        }
        .onAppear { pro.refresh() }
    }

    private var subtitle: String {
        switch app.pro.status {
        case .licensed(let license): return "Ключ на имя «\(license.name)»"
        case .early: return "Вы пользовались OffLoadAI до Pro — всё открыто навсегда"
        case .trial(let days): return "Пробный период: осталось \(days) \(pluralRu(days, "день", "дня", "дней"))"
        case .expired: return "Обновления по ключу закончились"
        case .free: return Self.price
        }
    }

    private var reasonTail: String {
        switch app.pro.status {
        case .expired: return "Ключ не открывает эту версию — продлите его."
        default: return "Пробные две недели закончились; всё найденное по-прежнему видно, а «не сейчас» работает как всегда."
        }
    }

    @ViewBuilder
    private var licenseBlock: some View {
        let pro = app.pro
        switch pro.status {
        case .licensed(let license):
            HStack(alignment: .firstTextBaseline) {
                Text("Ключ №\(license.id). Обновления до \(ProModel.day(license.updatesUntil)).")
                    .font(.callout).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button("Убрать ключ с этого Mac") { pro.removeLicense() }
                    .buttonStyle(InkLinkStyle())
                    .help("Например, перед продажей Mac. Ключ остаётся вашим — введите его на новом Mac.")
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if case .free = pro.status {
                    Text(Self.terms).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(Self.price). \(Self.terms)").font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    TextField("Ключ: OFFLOAD-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(activate)
                    Button("Ввести ключ", action: activate)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let problem = pro.keyProblem {
                    Notice(.error, problem)
                }
            }
        }
    }

    private func activate() {
        if app.pro.activate(key) { key = "" }
    }
}

/// Строка над панелью диска: что открыто на этом Mac. Щелчок — окно «OffLoadAI Pro».
struct ProSidebarRow: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let pro = app.pro
        Button { pro.offer() } label: {
            HStack(spacing: 8) {
                Image(systemName: pro.status.isPro ? "sparkles" : "sparkle")
                    .foregroundStyle(Theme.faint)
                    .frame(width: 20)
                Text(pro.summary).font(.callout).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if !pro.status.isPro {
                    Text("Pro").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.ink, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(hovering ? Color.white.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("OffLoadAI Pro: что в нём и ключ")
    }
}

/// Пометка «Pro» у кнопки, для которой нужен ключ.
struct ProTag: View {
    var body: some View {
        Text("Pro").font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(lineWidth: 1).opacity(0.6))
            .accessibilityLabel("Нужен OffLoadAI Pro")
    }
}
