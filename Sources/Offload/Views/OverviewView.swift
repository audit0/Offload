import OffloadCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.overview
        PageScroll {
            if let disk = app.connectedPrompt {
                ConnectedPrompt(disk: disk)
            }
            if !app.hasFullDiskAccess { FullDiskAccessBanner() }
            // Три карточки одной высоты: fixedSize по вертикали отдаёт ряду высоту самой высокой,
            // а карточки с fillsHeight растягиваются до неё.
            HStack(alignment: .top, spacing: 16) {
                DiskCard(volume: model.disk)
                ExternalDiskCard()
                MemoryCard(snapshot: model.memory)
            }
            .fixedSize(horizontal: false, vertical: true)
            ScenarioCard(macDisk: model.disk)
            if !model.advice.isEmpty {
                Card {
                    CardTitle("Что стоит сделать", systemImage: "lightbulb")
                    ForEach(model.advice, id: \.self) { tip in
                        Label {
                            Text(tip).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            if let memory = model.memory, !memory.apps.isEmpty {
                Card {
                    CardTitle("Память по приложениям", systemImage: "square.stack.3d.up")
                    AppMemoryList(apps: memory.apps, physical: memory.physicalBytes)
                }
            }
        }
        .navigationTitle("Обзор")
        .task { await model.poll() }
    }
}

struct DiskCard: View {
    let volume: VolumeInfo?

    var body: some View {
        Card(spacing: 14, fillsHeight: true) {
            CardTitle("Диск Mac", systemImage: "internaldrive")
            if let volume, volume.totalBytes > 0 {
                let used = Double(volume.totalBytes - volume.availableBytes) / Double(volume.totalBytes)
                // Те же пороги, что у шага «Освободите место» и у совета: меньше 15% свободно — мало.
                let low = used > 0.85
                let tint = used > 0.9 ? Color.red : low ? Color.orange : Theme.brand
                HStack(spacing: 14) {
                    RingGauge(fraction: used, tint: tint) {
                        Text("\(Int((used * 100).rounded()))%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.bytes(volume.availableBytes))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("свободно из \(Format.bytes(volume.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Label(low ? "Мало места" : "Места достаточно",
                      systemImage: low ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(low ? tint : Color.green)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }
}

/// Внешний диск и сейф на нём: куда Offload переносит и в каком состоянии замок.
struct ExternalDiskCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(spacing: 14, fillsHeight: true) {
            CardTitle("Внешний диск", systemImage: "externaldrive")
            if let disk = app.destination {
                VStack(alignment: .leading, spacing: 6) {
                    Text(disk.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if disk.totalBytes > 0 {
                        CapacityBar(fraction: Double(disk.totalBytes - disk.availableBytes) / Double(disk.totalBytes))
                    }
                    Text("\(disk.fsDisplayName) · свободно \(Format.bytes(disk.availableBytes)) из \(Format.bytes(disk.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                let summary = app.safe.summary
                Label(summary.title, systemImage: summary.systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(summary.tone.color)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Не подключён")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("На него Offload переносит то, что не нужно держать на Mac, и там же живёт сейф.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct MemoryCard: View {
    let snapshot: MemorySnapshot?

    var body: some View {
        Card(spacing: 14, fillsHeight: true) {
            CardTitle(title: "Память", systemImage: "memorychip") {
                if let snapshot {
                    Text(Format.memory(snapshot.physicalBytes)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle().fill(color(snapshot.pressure)).frame(width: 10, height: 10)
                        Text(snapshot.pressure.title).font(.system(size: 17, weight: .semibold))
                    }
                    Text("давление памяти").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 5) {
                    InfoRow("Swap", value: "\(Format.memory(snapshot.swapUsedBytes)) из \(Format.memory(snapshot.swapTotalBytes))")
                    InfoRow("Сжато", value: Format.memory(snapshot.compressedBytes))
                    InfoRow("Свободно", value: Format.memory(snapshot.freeBytes))
                    InfoRow("Без перезагрузки", value: uptime(snapshot.uptime))
                }
                .font(.caption)
                .monospacedDigit()
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    private func color(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func uptime(_ interval: TimeInterval) -> String {
        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return days > 0 ? "\(days) дн. \(hours) ч." : "\(hours) ч."
    }
}

struct AppMemoryList: View {
    let apps: [AppMemory]
    let physical: UInt64

    var body: some View {
        VStack(spacing: 10) {
            ForEach(apps) { app in
                HStack(spacing: 12) {
                    Text(app.name).lineLimit(1).truncationMode(.middle).frame(width: 240, alignment: .leading)
                    CapacityBar(fraction: physical > 0 ? Double(app.bytes) / Double(physical) : 0)
                    Text(Format.memory(app.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

/// Порядок работы одним взглядом: что уже сделано, что дальше и куда для этого нажать.
/// Каждый шаг — правда о текущем состоянии, а не заученная инструкция.
struct ScenarioCard: View {
    @Environment(AppModel.self) private var app
    let macDisk: VolumeInfo?

    struct Step: Identifiable {
        enum State { case done, todo, warning }
        let id: Int
        let state: State
        let title: String
        let detail: String
        var action: (title: String, section: SidebarSection)?
    }

    var body: some View {
        let list = steps
        let done = list.filter { $0.state == .done }.count
        // Первый несделанный шаг — «следующий»: его кнопка главная, остальные спокойнее.
        let next = list.first { $0.state != .done }?.id
        Card(padding: 0, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Порядок работы", systemImage: "list.number") {
                    Text("готово \(done) из \(list.count)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                CapacityBar(fraction: Double(done) / Double(max(1, list.count)), tint: .green, height: 4)
            }
            .padding(Theme.cardPadding)
            Divider()
            ForEach(Array(list.enumerated()), id: \.element.id) { index, step in
                StepRow(number: index + 1, step: step, isNext: step.id == next) { app.section = $0 }
                if step.id != list.last?.id { RowDivider(inset: 54) }
            }
        }
    }

    private var steps: [Step] {
        var steps: [Step] = []
        let host = app.destination
        steps.append(host.map {
            Step(id: 1, state: .done, title: "Внешний диск «\($0.name)»",
                 detail: "\($0.fsDisplayName) · свободно \(Format.bytes($0.availableBytes))" + (app.safe.state?.hostEncrypted == true ? " · зашифрован целиком" : ""))
        } ?? Step(id: 1, state: .todo, title: "Подключите внешний диск",
                  detail: "На него Offload переносит то, что не нужно держать на Mac, и там же живёт сейф."))

        let safe = app.safe
        if host != nil {
            if let state = safe.state, state.exists, state.isEncrypted, let limit = state.sizeLimit, limit < 20 << 30 {
                steps.append(Step(id: 2, state: .warning, title: "Сейф мал для переноса",
                                  detail: "«\(state.displayName)» ограничен \(Format.bytes(limit)): для ключей хватит, для больших папок — нет. Предел можно увеличить без потери содержимого.",
                                  action: ("Сейф", .safe)))
            } else if let state = safe.state, state.exists, state.isEncrypted {
                steps.append(Step(id: 2, state: .done,
                                  title: safe.isOpen ? "Сейф открыт" : "Сейф закрыт",
                                  detail: safe.isOpen
                                      ? "Перенос, бэкап и ключи идут в него. Закройте, когда закончите."
                                      : "На диске только шифротекст. Откройте, чтобы класть в сейф или брать из него.",
                                  action: ("Сейф", .safe)))
            } else {
                steps.append(Step(id: 2, state: .todo, title: "Заведите сейф",
                                  detail: "Зашифрованный образ на внешнем диске: без пароля его содержимое не прочтёт никто.",
                                  action: ("Создать", .safe)))
            }
        }

        if let macDisk, macDisk.totalBytes > 0 {
            let free = Double(macDisk.availableBytes) / Double(macDisk.totalBytes)
            steps.append(Step(id: 3, state: free < 0.15 ? .warning : .done,
                              title: free < 0.15 ? "Освободите место на Mac" : "Места на Mac достаточно",
                              detail: "Свободно \(Format.bytes(macDisk.availableBytes)) из \(Format.bytes(macDisk.totalBytes))."
                                  + (free < 0.15 ? " Перенесите большое и редко нужное в сейф — вернуть можно в любой момент." : ""),
                              action: ("Освободить место", .space)))
        }

        if host != nil {
            let plain = app.plainRecords
            if !plain.isEmpty {
                let bytes = plain.reduce(Int64(0)) { $0 + $1.bytes }
                steps.append(Step(id: 4, state: .warning, title: "Зашифруйте то, что уже лежит на диске открыто",
                                  detail: "\(plain.count) \(pluralRu(plain.count, "объект", "объекта", "объектов")), \(Format.bytes(bytes)) — прочтёт любой, у кого окажется диск.",
                                  action: ("Зашифровать", .safe)))
            }
        }

        let sources = app.backup.sources.count
        steps.append(Step(id: 5, state: sources == 0 ? .todo : .done,
                          title: sources == 0 ? "Настройте бэкап проектов и ключей" : "Бэкап: папок \(sources)",
                          detail: "Обновляемая копия проектов и ключи с токенами — в сейф.",
                          action: ("Бэкап", .backup)))
        return steps
    }
}

/// Шаг порядка работы: номер или отметка, что сделано, текст и кнопка перехода.
private struct StepRow: View {
    let number: Int
    let step: ScenarioCard.Step
    let isNext: Bool
    let open: (SidebarSection) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).fontWeight(.medium)
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
            Spacer(minLength: 12)
            if let action = step.action {
                if isNext {
                    Button(action.title) { open(action.section) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action.title) { open(action.section) }
                }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(isNext ? Theme.brand.opacity(0.05) : Color.clear)
    }

    @ViewBuilder
    private var indicator: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
        case .todo:
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isNext ? Theme.brand : Color.secondary)
                .frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(isNext ? Theme.brand : Color.secondary.opacity(0.5), lineWidth: 1.5) }
        }
    }
}

/// Только что подключили внешний диск — самое время разобрать Mac.
struct ConnectedPrompt: View {
    @Environment(AppModel.self) private var app
    let disk: String

    var body: some View {
        Card(tint: Theme.brand) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: "externaldrive.fill.badge.plus", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подключён «\(disk)»").font(.headline)
                    Text("Разобрать Mac: найду, что занимает место зря, и спрошу про каждое — удалить, убрать в сейф или добавить в бэкап. Без вашего «да» ничего не трогаю.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            app.connectedPrompt = nil
                            app.section = .cleanup
                            app.cleanup.scan(app: app)
                        } label: { Label("Разобрать", systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent)
                        Button("Не сейчас") { app.connectedPrompt = nil }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}
