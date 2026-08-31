import Foundation
import Darwin.Mach

/// Lightweight whole-machine CPU sampler. It reads cumulative kernel ticks
/// once per second; no subprocesses are launched and it does not compete with
/// local model inference in any meaningful way.
final class SystemLoadMonitor {
    private var previous: [UInt64]?

    func reset() {
        previous = readTicks()
    }

    func cpuPercent() -> Int? {
        guard let current = readTicks() else { return nil }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }

        let deltas = zip(current, previous).map { now, old in
            now >= old ? now - old : 0
        }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        // CPU_STATE_IDLE is the third tick bucket.
        let busy = total - deltas[Int(CPU_STATE_IDLE)]
        return Int((Double(busy) / Double(total) * 100).rounded())
    }

    private func readTicks() -> [UInt64]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride /
            MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
    }

    static var thermalDescription: String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return nil
        case .fair: return "机器偏热"
        case .serious: return "温度较高，可能降速"
        case .critical: return "温度过高，正在降速"
        @unknown default: return nil
        }
    }
}
