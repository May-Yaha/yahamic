import Foundation
import IOKit

// MetricsCollector:Mac 端系统/外设指标采集器,供 YahamicCore 的仪表盘上报链路
// 以 2~5s(建议 3s)的周期按需调用 sample(),结果通过 type 7 帧下发到设备屏。
// (尚未接线:Uplink.sendDashboard 已就绪但暂无调用方,等待 dashboard 任务收尾)
// 只依赖系统框架(Foundation/IOKit),Package.swift 不需要新增依赖。

/// 一次采样的结果快照。电量取值 0~100,255 为「未知」哨兵:
/// 0~100 是合法电量区间,无法表达「读不到」的状态,因此用 255 表示
/// 设备休眠、未连接或键缺失,设备端据此前端展示为「--」而不是误导性的 0%。
public struct MetricsSnapshot: Sendable {
    public var cpuPercent: UInt8        // 0~100,相邻两次采样的 CPU 忙时占比
    public var memoryPercent: UInt8     // 0~100,active+wired+compressed 占物理内存比例
    public var mouseBattery: UInt8      // 0~100,取不到为 255
    public var keyboardBattery: UInt8   // 0~100,取不到为 255

    public init(cpuPercent: UInt8, memoryPercent: UInt8, mouseBattery: UInt8, keyboardBattery: UInt8) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.mouseBattery = mouseBattery
        self.keyboardBattery = keyboardBattery
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
        MetricsSnapshot(
            cpuPercent: sampleCPU(),
            memoryPercent: sampleMemory(),
            mouseBattery: batteryPercent(productName: "Yaha的Magic Mouse"),
            keyboardBattery: batteryPercent(productName: "Yaha-Keyboard")
        )
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
                let user = UInt64(bitPattern: Int64(ptr[i + Int(CPU_STATE_USER)]))
                let system = UInt64(bitPattern: Int64(ptr[i + Int(CPU_STATE_SYSTEM)]))
                let idle = UInt64(bitPattern: Int64(ptr[i + Int(CPU_STATE_IDLE)]))
                let nice = UInt64(bitPattern: Int64(ptr[i + Int(CPU_STATE_NICE)]))
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

    /// 匹配 AppleDeviceManagementHIDEventService(Apple 自家键鼠走这个
    /// HID 事件服务进 IORegistry),遍历服务节点,按 'Product' 字符串找到
    /// 目标设备后读 'BatteryPercent'。设备休眠、未配对或键缺失时返回 255。
    private func batteryPercent(productName: String) -> UInt8 {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iter) == KERN_SUCCESS
        else { return 255 }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            // 先按 Product 名过滤,再取 BatteryPercent:一个 Mac 上可能同时
            // 挂着多个 HID 服务(鼠标/键盘/触控板),不能用「第一个有电量的」。
            guard let product = IORegistryEntryCreateCFProperty(
                service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                product == productName
            else { continue }
            guard let battery = IORegistryEntryCreateCFProperty(
                service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            else { return 255 }  // 设备在但电量键缺失(休眠中常见),按未知处理
            return battery.uint8Value
        }
        return 255
    }
}
