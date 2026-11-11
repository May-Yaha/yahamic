import Foundation
import IOKit
import IOKit.ps

// MetricsCollector:Mac 端系统/外设指标采集器,供 DeskCore 的仪表盘上报链路
// 以 2~5s(建议 3s)的周期按需调用 sample(),结果通过 dashboard 特征下发到设备屏。
// (已接线:HomeModel 每 3s 采样一次,经 Uplink.sendDashboard 下发)
// 只依赖系统框架(Foundation/IOKit),Package.swift 不需要新增依赖。

/// 一次采样的结果快照。电量取值 0~100,255 为「未知」哨兵:
/// 0~100 是合法电量区间,无法表达「读不到」的状态,因此用 255 表示
/// 设备休眠、未连接或键缺失,设备端据此前端展示为「--」而不是误导性的 0%。
public struct MetricsSnapshot: Sendable {
    public var cpuPercent: UInt8        // 0~100,相邻两次采样的 CPU 忙时占比
    public var memoryPercent: UInt8     // 0~100,active+wired+compressed 占物理内存比例
    public var mouseBattery: UInt8      // 0~100,取不到为 255
    public var keyboardBattery: UInt8   // 0~100,取不到为 255
    public var macBattery: UInt8
    public var macPower: UInt8

    public init(cpuPercent: UInt8, memoryPercent: UInt8, mouseBattery: UInt8, keyboardBattery: UInt8,
                macBattery: UInt8 = 255, macPower: UInt8 = 0) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.mouseBattery = mouseBattery
        self.keyboardBattery = keyboardBattery
        self.macBattery = macBattery
        self.macPower = macPower
    }
}

/// 指标采集器。为什么做成「按需采样」而不是内置定时器:
/// 上报周期由调用方(上报链路)的调度决定,采集器内嵌 Timer 会造成
/// 「采了没人用」的空转耗电;保留采样间隔也让 CPU 差值口径随调用周期自适应。
public final class MetricsCollector: @unchecked Sendable {

    /// 上一次采样的 (busyTicks, totalTicks)。
    /// 为什么存 tick 而不是直接算瞬时值:host_processor_info 返回的是开机以来的
    /// 累计 tick,单点无法得出「当前」占用率,必须与上一次采样做差值,
    /// 差值占比才是两次采样之间的真实忙时比例。
    private var lastBusy: UInt64 = 0
    private var lastTotal: UInt64 = 0
    private var hasLastSample = false

    /// 物理内存总字节数,进程生命周期内不变,惰性缓存一次即可。
    private lazy var physicalMemory: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()

    public init() {}

    /// 按需采样一次。首次调用时 CPU 无「上一次」可比,返回 0(而不是用
    /// 开机累计平均值误导),从第二次调用起返回真实区间占用率。
    public func sample() -> MetricsSnapshot {
        let batteries = hidBatteries()
        let mac = macPowerSource()
        return MetricsSnapshot(
            cpuPercent: sampleCPU(),
            memoryPercent: sampleMemory(),
            mouseBattery: batteries.mouse,
            keyboardBattery: batteries.keyboard,
            macBattery: mac.battery, macPower: mac.power
        )
    }

    // Apple IOPowerSources.h: capacity is current/max; only the internal battery describes the Mac.
    private func macPowerSource() -> (battery: UInt8, power: UInt8) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (255, 0) }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = values[kIOPSCurrentCapacityKey] as? Int ?? -1
            let maximum = values[kIOPSMaxCapacityKey] as? Int ?? 0
            let percent = current >= 0 && maximum > 0 ? UInt8(clamping: min(100, current * 100 / maximum)) : 255
            let charging = values[kIOPSIsChargingKey] as? Bool == true
            let external = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (percent, charging ? 3 : external ? 2 : 1)
        }
        return (255, 2)  // A desktop Mac has external power and no internal battery.
    }

    // MARK: - CPU

    /// 通过 host_processor_info 取 PROCESSOR_CPU_LOAD_INFO,对所有核心的
    /// tick 求和后与上次采样做差:busy = user+system,total 再加 idle(+nice)。
    private func sampleCPU() -> UInt8 {
        var numCPUs: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return 0 }
        defer {
            // host_processor_info 用 vm_allocate 分配返回数组,必须归还内核,
            // 否则每次采样泄漏一块 VM 区域。
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)  // 每个核心 4 个 integer_t: user/system/idle/nice
        info.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { ptr in
            var i = 0
            while i + Int(CPU_STATE_IDLE) < Int(infoCount) {
                let user = UInt64(UInt32(bitPattern: ptr[i + Int(CPU_STATE_USER)]))
                let system = UInt64(UInt32(bitPattern: ptr[i + Int(CPU_STATE_SYSTEM)]))
                let idle = UInt64(UInt32(bitPattern: ptr[i + Int(CPU_STATE_IDLE)]))
                let nice = UInt64(UInt32(bitPattern: ptr[i + Int(CPU_STATE_NICE)]))
                busy += user + system
                total += user + system + idle + nice
                i += stride
            }
        }

        defer {
            lastBusy = busy
            lastTotal = total
            hasLastSample = true
        }
        guard hasLastSample, total > lastTotal else { return 0 }
        let busyDelta = busy >= lastBusy ? busy - lastBusy : 0
        let totalDelta = total - lastTotal
        let pct = Double(busyDelta) / Double(totalDelta) * 100.0
        return UInt8(min(100, max(0, Int(pct.rounded()))))
    }

    // MARK: - 内存

    /// 通过 host_statistics64 取 vm_statistics64:
    /// 使用占比 = (active + wired + compressed) * pageSize / 物理内存。
    /// 为什么不算 free/inactive:macOS 会拿空闲页做文件缓存(inactive),
    /// 这部分按需可回收,不算真实压力;active+wired+compressed 才是
    /// 被应用/系统/压缩器实际占用、不可轻易让出的部分。
    private func sampleMemory() -> UInt8 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS, physicalMemory > 0 else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * pageSize
        let pct = Double(used) / Double(physicalMemory) * 100.0
        return UInt8(min(100, max(0, Int(pct.rounded()))))
    }

    // MARK: - 蓝牙 HID 电量

    /// 遍历 AppleDeviceManagementHIDEventService(蓝牙键鼠走这个 HID 事件服务进 IORegistry),
    /// 读带 'BatteryPercent' 的节点,按 'Product' 名字归类鼠标/键盘;取不到为 255。
    /// ponytail: 按名字关键词归类(Magic Mouse / Yaha-Mouse / Magic Keyboard / HHKB 都能命中),
    /// 改名成不含关键词的设备会归不进去;需要时改成读父节点 IOHIDDevice 的 usage(Generic Desktop 2/6)。
    /// 部分第三方键盘(如 HHKB)不向 macOS 上报电量,该环恒为 "--"。
    static func classify(_ product: String) -> (mouse: Bool, keyboard: Bool) {
        let name = product.lowercased()
        let mouse = ["mouse", "trackpad", "鼠标", "触控板"].contains { name.contains($0) }
        let keyboard = !mouse && ["keyboard", "hhkb", "键盘"].contains { name.contains($0) }
        return (mouse, keyboard)
    }

    private func hidBatteries() -> (mouse: UInt8, keyboard: UInt8) {
        var result: (mouse: UInt8, keyboard: UInt8) = (255, 255)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iter) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let product = IORegistryEntryCreateCFProperty(
                service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                let battery = IORegistryEntryCreateCFProperty(
                service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber  // 休眠中常缺这个键,按未知处理
            else { continue }
            let kind = Self.classify(product)
            if kind.mouse, result.mouse == 255 { result.mouse = battery.uint8Value }
            if kind.keyboard, result.keyboard == 255 { result.keyboard = battery.uint8Value }
        }
        return result
    }
}
