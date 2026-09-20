import OffloadCore
import SwiftUI

struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        Group {
            switch verdict {
            case .safe:
                Label("Можно перенести", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .caution:
                Label("С оговорками", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .blocked:
                Label("Не трогать", systemImage: "hand.raised.fill").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(verdict.notes.joined(separator: "\n"))
    }
}

struct SizeBar: View {
    let fraction: Double

    // Без GeometryReader: внутри строк List он заставляет таблицу пересчитывать высоту строки
    // прямо из своего делегата — AppKit ругается на реентерабельность и ломает отрисовку.
    var body: some View {
        ProgressView(value: min(1, max(0.005, fraction)))
            .progressViewStyle(.linear)
            .tint(Color.accentColor)
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
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(details, id: \.self) { detail in
                    Text("— " + detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Нет полного доступа к диску").font(.headline)
                Text("Без него Offload не видит «Документы», «Рабочий стол», Почту и данные многих приложений, и часть занятого места останется неизвестной. Выдайте доступ в настройках и перезапустите Offload.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Открыть настройки") { FullDiskAccess.openSettings() }
                    Button("Проверить снова") { app.refreshVolumes() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DestinationFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            Text("Внешний диск").font(.caption).foregroundStyle(.secondary)
            if app.volumes.isEmpty {
                Label("Не подключён", systemImage: "externaldrive.badge.xmark").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Внешний диск", selection: $app.destinationID) {
                    ForEach(app.volumes) { volume in
                        Text(volume.name).tag(Optional(volume.id))
                    }
                }
                .labelsHidden()
                if let volume = app.destination {
                    Text("\(volume.fsDisplayName) · свободно \(Format.bytes(volume.availableBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
