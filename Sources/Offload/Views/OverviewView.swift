import OffloadCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.hasFullDiskAccess { FullDiskAccessBanner() }
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
