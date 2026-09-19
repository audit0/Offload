import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    public var title: String {
        switch self {
        case .normal: return "Нормальное"
        case .warning: return "Повышенное"
        case .critical: return "Критическое"
        case .unknown: return "Неизвестно"
        }
    }
}

public struct AppMemory: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let bytes: UInt64
    public let processes: Int
}

public struct MemorySnapshot: Sendable {
    public var physicalBytes: UInt64
    public var freeBytes: UInt64
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var pressure: MemoryPressure
    public var uptime: TimeInterval
    public var apps: [AppMemory]
}

public enum MemoryStats {
    public static let virtualMachinesName = "Виртуальные машины (Docker, UTM и др.)"

    public static func snapshot(top: Int = 8) -> MemorySnapshot {
        let pageSize = UInt64(vm_kernel_page_size)
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
            ? MemoryPressure(rawValue: Int(level)) ?? .unknown : .unknown

        return MemorySnapshot(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: status == KERN_SUCCESS ? UInt64(vm.free_count) * pageSize : 0,
            compressedBytes: status == KERN_SUCCESS ? UInt64(vm.compressor_page_count) * pageSize : 0,
            swapUsedBytes: swapOK ? swap.xsu_used : 0,
            swapTotalBytes: swapOK ? swap.xsu_total : 0,
            pressure: pressure,
            uptime: uptimeSinceBoot(),
            apps: topApps(limit: top)
        )
    }

    /// Время с загрузки по часам (включая сон), как в `uptime`.
    static func uptimeSinceBoot() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Date().timeIntervalSince1970 - (TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    /// Память по приложениям: физический след (включая сжатую память), сгруппированный по .app.
    static func topApps(limit: Int) -> [AppMemory] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let found = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var totals: [String: (bytes: UInt64, processes: Int)] = [:]
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let name = appName(forExecutable: String(cString: buffer))
            totals[name, default: (0, 0)].bytes += info.ri_phys_footprint
            totals[name, default: (0, 0)].processes += 1
        }
        return totals.map { AppMemory(name: $0.key, bytes: $0.value.bytes, processes: $0.value.processes) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    public static func appName(forExecutable path: String) -> String {
        if path.contains("com.apple.Virtualization.VirtualMachine") { return virtualMachinesName }
        if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return (path as NSString).lastPathComponent
    }

    static let browsers: Set<String> = ["Google Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Yandex", "Opera", "Brave Browser"]

    /// Советы на человеческом языке по текущему состоянию памяти.
    public static func advice(for snapshot: MemorySnapshot) -> [String] {
        var tips: [String] = []
        let days = Int(snapshot.uptime / 86_400)
        if snapshot.swapUsedBytes > snapshot.physicalBytes / 2, days >= 2 {
            tips.append("Перезагрузите Mac: в swap \(Format.memory(snapshot.swapUsedBytes)), и сам он не освободится. Mac работает без перезагрузки \(days) дн.")
        }
        if snapshot.pressure == .warning || snapshot.pressure == .critical {
            tips.append("Оперативной памяти не хватает — закройте приложения, которыми сейчас не пользуетесь.")
        }
        for app in snapshot.apps {
            if app.name == virtualMachinesName, app.bytes > 2 << 30 {
                tips.append("Виртуальные машины занимают \(Format.memory(app.bytes)). Закройте Docker Desktop или UTM, если они сейчас не нужны.")
            } else if browsers.contains(app.name), app.bytes > 3 << 30 {
                tips.append("\(app.name) занимает \(Format.memory(app.bytes)) — закройте лишние вкладки.")
            }
        }
        return tips
    }
}
