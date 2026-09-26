import AppKit
import OffloadCore
import SwiftUI

/// Виртуальные машины UTM: сколько занимает каждая и как освободить место, не потеряв их.
///
/// Переносить машины сам Offload не берётся: UTM помнит машины по месту, а их диски разрежённые.
/// Копия, сделанная в обход UTM, потеряла бы и то и другое, поэтому лист ведёт в сам UTM.
struct UTMSheet: View {
    /// Строка, из которой открыт лист: контейнер UTM, папка внутри него или сама машина.
    let item: SpaceItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var machines: [UTMMachine]? = nil
    @State private var utmApp: URL? = nil

    var body: some View {
        SheetLayout(systemImage: "desktopcomputer", title: "Виртуальные машины UTM", subtitle: subtitle, width: 640) {
            list
            steps
        } actions: {
            Button("Открыть UTM") { if let utmApp { NSWorkspace.shared.open(utmApp) } }
                .disabled(utmApp == nil)
                .help(utmApp == nil ? "UTM не найден" : "Удалять и переносить машины нужно в самом UTM")
            Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .task { await load() }
    }

    private var subtitle: String {
        guard let machines else { return "Считаю, сколько занимает каждая машина…" }
        let total = machines.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(machines.count) \(pluralRu(machines.count, "машина", "машины", "машин")) · \(Format.bytes(total))"
    }

    private func load() async {
        utmApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: UTMMachines.bundleIdentifier)
        let home = app.rules.home
        let focus = item.url
        machines = await Task.detached(priority: .userInitiated) {
            var machines = UTMMachines.list(in: UTMMachines.folder(home: home))
            // Машину, открытую в UTM из другой папки, в его папке не найти — покажем и её.
            if UTMMachines.isMachine(focus), !machines.contains(where: { $0.url.standardizedFileURL == focus.standardizedFileURL }) {
                machines.insert(UTMMachines.machine(at: focus), at: 0)
            }
            return machines
        }.value
    }

    /// Сколько в строке занято не машинами: кеш и прочие данные самого UTM.
    private var rest: Int64? {
        guard let machines, item.isMeasured, !UTMMachines.isMachine(item.url) else { return nil }
        let prefix = item.url.standardizedFileURL.path + "/"
        let inside = machines.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }.reduce(Int64(0)) { $0 + $1.bytes }
        let rest = item.bytes - inside
        return rest >= 512 << 20 ? rest : nil
    }

    // MARK: - Список

    @ViewBuilder
    private var list: some View {
        if let machines {
            if machines.isEmpty {
                Notice(.info, "В папке UTM машин нет. Машины, открытые из других папок, UTM показывает у себя в списке.")
            } else if machines.count > 5 {
                Card(padding: 0, spacing: 0) {
                    ScrollView { rows(machines) }.frame(height: 300)
                }
            } else {
                Card(padding: 0, spacing: 0) { rows(machines) }
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Считаю, сколько занимает каждая машина…").foregroundStyle(.secondary)
            }
        }
    }

    private func rows(_ machines: [UTMMachine]) -> some View {
        VStack(spacing: 0) {
            ForEach(machines) { machine in
                if machine.id != machines.first?.id { RowDivider(inset: 56) }
                machineRow(machine)
            }
            if let rest {
                RowDivider(inset: 56)
                HStack(spacing: 12) {
                    IconTile(systemImage: "tray.full.fill", tone: .neutral, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Прочее в папке UTM")
                        Text("Кеш и данные самого UTM, не машины").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(Format.bytes(rest)).fontWeight(.semibold).monospacedDigit()
                    Color.clear.frame(width: 16, height: 1)
                }
                .rowPadding()
            }
        }
    }

    private func machineRow(_ machine: UTMMachine) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "desktopcomputer", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if let caption = caption(machine) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(Format.bytes(machine.bytes)).fontWeight(.semibold).monospacedDigit()
            Button { revealInFinder(machine.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .frame(width: 16)
                .help("Показать в Finder")
        }
        .rowPadding()
    }

    private func caption(_ machine: UTMMachine) -> String? {
        var parts: [String] = []
        if let modified = machine.modified { parts.append("менялась \(Format.relative(modified))") }
        // Диски машин разрежённые: где разрежённых файлов нет, машина займёт полный объём.
        if machine.logicalBytes > machine.bytes + (1 << 30) {
            parts.append("полный объём дисков \(Format.bytes(machine.logicalBytes))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Как освободить

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Удалить ненужную",
                 "В UTM: правый клик по машине → «Удалить…» (Delete…). UTM удалит её вместе с дисками — место освободится сразу.")
            step(2, "Перенести на внешний диск",
                 "В UTM: правый клик → «Переместить…» (Move…) и выберите папку в сейфе или на диске. UTM скопирует машину, удалит оригинал и запомнит новое место. Перед запуском такой машины подключите диск и откройте сейф — иначе UTM покажет её недоступной, — а перед сном Mac и закрытием сейфа выключите её: диск машины, у которой отключили сейф, может испортиться.")
            if let note = destinationNote { Notice(.warning, note) }
            step(3, "Ужать диск машины QEMU",
                 "Если внутри гостевой системы удалили много файлов, сам образ диска не уменьшается. В настройках машины, в разделе её диска, есть кнопка «Reclaim Space» — она пересобирает образ без пустых блоков.")
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.brand, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Оговорка про диск, выбранный для переноса: FAT32 машину не примет, exFAT раздует её диски.
    private var destinationNote: String? {
        guard let disk = app.destination else { return nil }
        if let limit = disk.maxFileSize, (machines ?? []).contains(where: { $0.largestFile > limit }) {
            return "Диск «\(disk.name)» — \(disk.fsDisplayName): файлы больше 4 ГБ он не принимает, машину туда не перенести. Переносите в сейф."
        }
        guard !disk.keepsSparseFiles, (machines ?? []).contains(where: { $0.logicalBytes > $0.bytes + (1 << 30) }) else { return nil }
        return "Диск «\(disk.name)» — \(disk.fsDisplayName): разрежённых файлов там нет, и машина займёт на нём полный объём дисков, а не нынешний размер. Сейф внутри — APFS, он разрежённые файлы хранит."
    }
}
