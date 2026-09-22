import OffloadCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.hasFullDiskAccess { FullDiskAccessBanner() }
                ScenarioCard(macDisk: model.disk)
                HStack(alignment: .top, spacing: 16) {
                    DiskCard(volume: model.disk)
                    MemoryCard(snapshot: model.memory)
                }
                if !model.advice.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.advice, id: \.self) { tip in
                                Label(tip, systemImage: "lightbulb").fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    } label: {
                        Text("Что стоит сделать").font(.headline)
                    }
                }
                if let memory = model.memory {
                    GroupBox {
                        AppMemoryList(apps: memory.apps, physical: memory.physicalBytes)
                    } label: {
                        Text("Память по приложениям").font(.headline)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Обзор")
        .task { await model.poll() }
    }
}

struct DiskCard: View {
    let volume: VolumeInfo?

    var body: some View {
        GroupBox {
            if let volume, volume.totalBytes > 0 {
                let used = Double(volume.totalBytes - volume.availableBytes) / Double(volume.totalBytes)
                VStack(alignment: .leading, spacing: 10) {
                    Gauge(value: used) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(used > 0.9 ? .red : used > 0.8 ? .orange : .accentColor)
                    Text("Свободно \(Format.bytes(volume.availableBytes)) из \(Format.bytes(volume.totalBytes))")
                        .font(.title3.weight(.semibold))
                    Text("Занято \(Int((used * 100).rounded()))%").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } label: {
            Label("Диск Mac", systemImage: "internaldrive").font(.headline)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MemoryCard: View {
    let snapshot: MemorySnapshot?

    var body: some View {
        GroupBox {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Давление памяти") { Text(snapshot.pressure.title).foregroundStyle(color(snapshot.pressure)) }
                    LabeledContent("Swap") {
                        Text("\(Format.memory(snapshot.swapUsedBytes)) из \(Format.memory(snapshot.swapTotalBytes))")
                    }
                    LabeledContent("Сжато") { Text(Format.memory(snapshot.compressedBytes)) }
                    LabeledContent("Свободно") { Text(Format.memory(snapshot.freeBytes)) }
                    LabeledContent("Без перезагрузки") { Text(uptime(snapshot.uptime)) }
                }
                .padding(6)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } label: {
            Label("Оперативная память" + (snapshot.map { " · \(Format.memory($0.physicalBytes))" } ?? ""),
                  systemImage: "memorychip").font(.headline)
        }
        .frame(maxWidth: .infinity)
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
        VStack(spacing: 8) {
            ForEach(apps) { app in
                HStack(spacing: 12) {
                    Text(app.name).lineLimit(1).truncationMode(.middle).frame(width: 280, alignment: .leading)
                    SizeBar(fraction: physical > 0 ? Double(app.bytes) / Double(physical) : 0)
                    Text(Format.memory(app.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
            }
        }
        .padding(6)
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
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(step.state))
                            .foregroundStyle(color(step.state))
                            .font(.title3)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.body.weight(.medium))
                            Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if let action = step.action {
                            Button(action.title) { app.section = action.section }
                        }
                    }
                    .padding(.vertical, 8)
                    if step.id != steps.last?.id { Divider().padding(.leading, 36) }
                }
            }
            .padding(6)
        } label: {
            Label("Порядок работы", systemImage: "list.number").font(.headline)
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
                                  detail: "«\(state.displayName)» ограничен \(Format.bytes(limit)): для ключей хватит, для больших папок — нет. Заведите сейф на весь диск.",
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

    private func symbol(_ state: Step.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .todo: return "circle"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ state: Step.State) -> Color {
        switch state {
        case .done: return .green
        case .todo: return .secondary
        case .warning: return .orange
        }
    }
}
