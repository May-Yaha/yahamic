import Foundation

// 单生产者(网络线程)单消费者(音频渲染线程)的环形缓冲:16 kHz 单声道 Int16。
// 临界区只有拷贝与下标更新(几十纳秒),实时线程可承受。
// 另外维护少量统计(溢出、欠载),供状态行打印。
public final class JitterBuffer {
    private var storage: [Int16]
    private var head = 0  // 下一个写入位置
    private var tail = 0  // 下一个读出位置
    private let mask: Int  // 容量-1(容量为 2 的幂)
    private let lock = NSLock()

    private var overflows = 0
    private var underruns = 0

    public init(ms: Int) {
        var capacity = 1
        while capacity < ms * 16 { capacity <<= 1 }
        mask = capacity - 1
        storage = [Int16](repeating: 0, count: capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return (head - tail) & mask
    }

    /// 写入一帧采集样本;缓冲将满时丢最旧的(麦克风宁可低延迟,不要攒延迟)。
    public func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        let used = (head - tail) & mask
        let free = mask - used
        if samples.count > free {
            tail = (tail + (samples.count - free)) & mask
            overflows += 1
        }
        for s in samples {
            storage[head] = s
            head = (head + 1) & mask
        }
        lock.unlock()
    }

    /// 读一个样本;空返回 nil。
    public func pop() -> Int16? {
        lock.lock()
        defer { lock.unlock() }
        if head == tail { return nil }
        let value = storage[tail]
        tail = (tail + 1) & mask
        return value
    }

    /// 静音/重连:清空,渲染端随之输出静音。
    public func clear() {
        lock.lock()
        tail = head
        lock.unlock()
    }

    public func noteUnderrun() {
        lock.lock()
        underruns += 1
        lock.unlock()
    }

    public func stats() -> (overflows: Int, underruns: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (overflows, underruns)
    }
}
