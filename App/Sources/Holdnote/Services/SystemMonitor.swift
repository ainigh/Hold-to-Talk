import Darwin
import Foundation
import Harness
import Observation

/// Samples what the Mac is spending and Holdnote's share of it, every few seconds: CPU across
/// all cores (Mach host ticks) against this process's CPU time, memory in use against this
/// process's footprint, and the thermal state. Reading it costs next to nothing.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var sample: UsageSample?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastAppCPU: (time: TimeInterval, at: TimeInterval)?

    static let interval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var systemCPU = sample?.systemCPU ?? 0
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                systemCPU = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        var appCPU = sample?.appCPU ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUTime()
        if let last = lastAppCPU, now > last.at {
            appCPU = (cpuTime - last.time) / (now - last.at) / Double(cores)
        }
        lastAppCPU = (cpuTime, now)
        sample = UsageSample(systemCPU: max(0, min(1, systemCPU)), appCPU: max(0, min(1, appCPU)), cores: cores,
                             memoryUsed: Self.memoryInUse() ?? 0, memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                             appMemory: Self.footprint() ?? 0, thermal: Self.thermal())
    }

    // MARK: - Readings

    /// Busy and total ticks summed over every core since boot (host_processor_info).
    nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var cpuCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// CPU seconds this process has used across all its threads.
    nonisolated static func processCPUTime() -> TimeInterval {
        var ts = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0 else { return 0 }
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
    }

    /// Bytes in use on the Mac: active, wired and compressed pages (what Activity Monitor
    /// calls memory used).
    nonisolated static func memoryInUse() -> Int64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Int64(pages * page)
    }

    /// This process's physical footprint, as Activity Monitor shows it.
    nonisolated static func footprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    nonisolated static func thermal() -> UsageSample.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
