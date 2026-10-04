import OffloadCore
import SwiftUI

extension Verdict {
    var title: String {
        switch self {
        case .safe: return tr("Можно перенести")
        case .caution: return tr("С оговорками")
        case .blocked: return tr("Не трогать")
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .safe: return .good
        case .caution: return .caution
        case .blocked: return .neutral
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        StatusPill(title: verdict.title, systemImage: verdict.symbol, tone: verdict.tone)
            .help(verdict.notes.joined(separator: "\n"))
    }
}

struct Notice: View {
    enum Kind: Sendable { case info, success, warning, error }

    /// Текст вместе с тем, как его показывать. Без этого неудача возврата выглядела
    /// точно так же, как удача: одна и та же синяя плашка «info».
    struct Message: Equatable, Sendable {
        var kind: Kind
        var text: String
        /// Оговорки: каждая отдельной строкой под заголовком. Слитые в одно предложение,
        /// они читались как сплошной текст, и было не видно, сколько их и о чём каждая.
        var details: [String]

        init(_ kind: Kind, _ text: String, details: [String] = []) {
            self.kind = kind
            self.text = text
            self.details = details
        }
    }

    let kind: Kind
    let text: String
    let details: [String]

    init(_ kind: Kind, _ text: String, details: [String] = []) {
        self.kind = kind
        self.text = text
        self.details = details
    }

    init(_ message: Message) {
        self.kind = message.kind
        self.text = message.text
        self.details = message.details
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(details, id: \.self) { detail in
                    Text("— " + detail)
                        .font(.callout).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(soft, in: shape)
        .overlay { shape.strokeBorder(kind == .error ? Color.clear : Theme.line) }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return Theme.ink
        case .success: return Theme.ok
        case .warning: return Theme.warn
        case .error: return Theme.bad
        }
    }

    /// Белая плашка с тонкой рамкой; у ошибки — розоватая.
    private var soft: Color {
        switch kind {
        case .info, .success, .warning: return Color.white.opacity(0.5)
        case .error: return Theme.badSoft
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(tint: Theme.warn) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: "lock.shield", tone: .caution, size: 36)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Нет полного доступа к диску")).font(.headline)
                    Text(tr("Без него OffLoadAI не видит «Документы», «Рабочий стол», Почту и данные многих приложений, и часть занятого места останется неизвестной. Выдайте доступ в настройках и перезапустите OffLoadAI."))
                        .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(tr("Открыть настройки")) { FullDiskAccess.openSettings() }
                            .prominentButton()
                        Button(tr("Проверить снова")) { app.refreshVolumes() }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}
