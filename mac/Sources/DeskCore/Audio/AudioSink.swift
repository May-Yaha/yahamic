import CoreAudio
import Foundation

// 音频出口:把抖动缓冲里的 16 kHz 单声道样本,重采样后写进虚拟麦克风的
// 「输出」侧(BlackHole 的输出侧接它的输入侧——应用选 BlackHole 当麦克风,
// 听到的就是我们写进去的声音)。
//
// 时钟对齐:设备晶振和 Mac 时钟有微量漂移,靠缓冲水位缓慢校正——水位高于
// 目标就消费快一点,低于就慢一点,单次最多 ±0.5%,听感无损。
//
// 起播预缓冲:开播与真实断供恢复都先攒够目标水位再开始消费,
// 攒够前输出静音。预缓冲门限跟随 targetMs；断供时不插静音补洞。
public final class AudioSink {
    private let device: OutputDevice
    private let jitter: JitterBuffer
    private var ioProcID: AudioDeviceIOProcID?
    private let step: Double        // 每产出一个样本要推进的源样本数 = 16000/rate
    // 仅用于播放漂移校正的目标水位(见 render 开头的 adjust 计算);不是开播
    // 门限,也不参与断供/恢复路径——那些用独立的预缓冲门限 prebufferSamples。
    private let targetMs: Double

    // 只在渲染线程(IO 回调)里碰的状态:
    private var frac = 0.0          // 重采样相位 [0, 1)
    private var a: Float = 0        // 插值左点(归一化后的源样本)
    private var b: Float = 0        // 插值右点
    private var primed = false      // 插值两点是否就绪
    private var adjust = 1.0        // 漂移校正因子
    private var ramp: Float = 1.0   // 缓冲空→恢复的淡入斜坡(10ms),消除切换跳变
    // 断供排空渐落(app-drain-fade)剩余帧数:48kHz 下 240 = 5ms 线性衰减。
    // 渲染线程私有:只在 IO 回调链路的 nextSample() 里读写,勿跨线程访问。
    private var releaseSamplesLeft = 0
    // 预缓冲门限跟随目标水位,避免漂移目标高于实际起播库存导致刚开播即欠载。
    // 开播与断供恢复前必须先攒够这个量级,攒够前渲染线程只输出静音、不消费。
    private let prebufferSamples: Int
    private var prebuffering = true  // 正处于预缓冲期(初始即待开播)

    // 断供事件口径需要的额外状态(前两个只在渲染线程碰):
    private var startedPlayback = false  // 已开播:成功渲染出过样本
    private var starving = false         // 正处于一段未恢复的断供中
    // 流活跃标记由喂声方(Uplink 队列)写、渲染线程读,加锁保护。
    private let streamActiveLock = NSLock()
    private var streamActiveFlag = false
    private var streamActivations = 0  // 激活次数(零帧诊断:流是否真的被喂起来过)

    // 会话代际:喂声方(Uplink 队列)在同设备重连/重新握手时经 resetSession()
    // 递增;渲染线程在 render 开头比对,代际变化即整体重置渲染侧会话状态。
    // 加锁是因为写发生在 Uplink 队列、读在 CoreAudio IO 线程(与 jitter 内部
    // 的 NSLock 同一量级,临界区只是一次整数读)。
    private let sessionLock = NSLock()
    private var sessionGeneration = 0
    private var renderSeenGeneration = -1  // 只在渲染线程碰

    // 输出帧数诊断:渲染线程实际消费的源样本累计(60ms=960 样本为 1 帧)。
    // 写只在渲染线程(每次 render 结束汇总一次),读在 Uplink 队列,加锁。
    private let outputLock = NSLock()
    private var outputSamplesTotal = 0
    private var callConsumed = 0  // 只在渲染线程碰:本次 render 已消费的源样本数
    // 渲染线程本地样本块:每次 render 开头从 jitter 一次加锁批量取够本次所需,
    // nextSample 只读这里,不再逐样本加锁。上次没用完的(至多几个)留到下次。
    private var local = [Int16](repeating: 0, count: 8192)
    private var localHead = 0
    private var localCount = 0

    public var deviceName: String { device.name }
    public var sampleRate: Double { device.sampleRate }
    public var deviceID: AudioDeviceID { device.id }

    public init?(device: OutputDevice, jitter: JitterBuffer, targetMs: Int) {
        self.device = device
        self.jitter = jitter
        let normalizedTargetMs = AudioBufferPolicy.normalizedTargetMs(targetMs)
        self.targetMs = Double(normalizedTargetMs)
        self.prebufferSamples = AudioBufferPolicy.prebufferSamples(targetMs: normalizedTargetMs)
        self.step = 16000.0 / device.sampleRate

        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) {
            [weak self] _, _, _, outputData, _ in
            self?.render(outputData)
        }
        guard created == noErr, let procID else {
            return nil
        }
        ioProcID = procID
        let started = AudioDeviceStart(device.id, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device.id, procID)
            ioProcID = nil
            return nil
        }
    }

    deinit {
        if let procID = ioProcID {
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
        }
    }

    // MARK: - 流活跃标记(internal:只给同模块的喂声方 Uplink 用,不进对外 API)

    /// 喂声方在音频帧开始流入时调用(幂等)。断供(underrun)只在流活跃期间
    /// 计数:静默期(静音待命/未开播)CoreAudio 回调空转完全不计数。
    func beginStream() {
        streamActiveLock.lock()
        if !streamActiveFlag { streamActivations += 1 }
        streamActiveFlag = true
        streamActiveLock.unlock()
    }

    /// 喂声方在流结束时调用(静音、设备掉线、链路停止)。
    /// 注意:只清「流活跃」标记,不动渲染侧会话状态;同设备重连请用
    /// resetSession()(那里会把预缓冲/插值/断供挡板等一并作废)。
    func endStream() {
        streamActiveLock.lock()
        streamActiveFlag = false
        streamActiveLock.unlock()
    }

    /// 喂声方在设备(重)连上、新会话开始时调用:
    /// 结束当前流,并递增会话代际,让渲染线程把渲染侧全部会话/预缓冲状态
    /// (预缓冲门、插值相位与两点、漂移因子、淡入斜坡、已开播与断供挡板)
    /// 重置回「从未开播」——而不是依赖旧缓冲自然排空的副作用来间接复位。
    /// 若重连后仍沿用旧会话状态,新会话的帧可能被旧状态卡住/判旧,持续断供。
    func resetSession() {
        endStream()
        sessionLock.lock()
        sessionGeneration &+= 1
        sessionLock.unlock()
    }

    private var streamActive: Bool {
        streamActiveLock.lock()
        defer { streamActiveLock.unlock() }
        return streamActiveFlag
    }

    /// 流活跃诊断(供 status/metrics 观察「激活」阶段):当前是否活跃 + 累计激活
    /// 次数。activations 不涨说明 Uplink 从未调 beginStream(即没有音频帧流入)。
    public func streamStats() -> (active: Bool, activations: Int) {
        streamActiveLock.lock()
        defer { streamActiveLock.unlock() }
        return (streamActiveFlag, streamActivations)
    }

    /// 输出帧数诊断(供 status/metrics 观察「渲染」阶段):渲染线程累计消费的
    /// 60ms 帧数。入队计数(Uplink.Diag.enqueuedFrames)在涨而本计数不涨,说明
    /// 断点在渲染侧(预缓冲门/设备回调),而不是收包或解码。
    public var outputFrameCount: Int {
        outputLock.lock()
        defer { outputLock.unlock() }
        return outputSamplesTotal / 960
    }

    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData else { return }
        callConsumed = 0

        // 会话代际比对:喂声方在同设备重连/重新握手时 resetSession() 递增代际
        // (同时 Uplink 侧已清 jitter 与 lastSeq 序号基线);渲染线程发现代际
        // 变化,把只在本线程碰的会话状态整体归零,回到首次开播前的状态——
        // 预缓冲门重新把守,新会话必须重新攒够目标水位再出声,不会
        // 沿用重连前的播放位置/断供挡板继续渲染。
        sessionLock.lock()
        let generation = sessionGeneration
        sessionLock.unlock()
        if generation != renderSeenGeneration {
            renderSeenGeneration = generation
            primed = false
            frac = 0
            a = 0
            b = 0
            adjust = 1.0
            ramp = 1.0
            prebuffering = true
            startedPlayback = false
            starving = false
            localCount = 0
        }

        // 漂移校正:按水位与目标的偏差微调消费速度。
        let available = jitter.count + localCount
        let occupancyMs = Double(available) / 16.0
        let error = (occupancyMs - targetMs) / targetMs
        adjust = min(max(1.0 + 0.05 * error, 0.995), 1.005)

        // 断供按「事件」边沿计数:仅在流活跃(beginStream 之后)且已开播
        // (成功渲染过)的前提下缓冲变干,记一次断供并转入重新预缓冲;同一
        // 段断供内的后续空回调不重复累计(starving 挡板),恢复(重新取到
        // 样本)后再次断供才算新事件——一次持续断供最终只 +1。
        // 未开播或流不活跃(松 Fn 静音待命、缓冲自然排空)时的空转完全不计
        // 数——否则 push-to-talk 设备静音几小时,underrun 会随每次回调无限
        // 增长。计数只发生在此处,渲染循环内没有其它递增路径。
        if !primed && available < 2, streamActive, startedPlayback, !starving {
            starving = true
            jitter.noteUnderrun()
        }

        // 预缓冲门:攒够 prebufferSamples(目标水位)之前输出静音、不消费缓冲。
        // 覆盖两条入口:首次开播(初始 prebuffering = true)与真实断供后的恢复
        // (nextSample 里缓冲被抽空时重新置位)。饥饿期不清空缓冲——里面已到的
        // 样本原样保留,攒够后连续播出;也不插静音补序号空洞(丢包由喂声方
        // Uplink 丢旧不补静,跳过缺失序号直接解码后续帧)。
        // 门只挡「即将开播」:送声期(streamActive)或从未开播时必须攒够才放行;
        // 松 Fn 静音期(endStream 后)不设门——松 Fn 不清空缓冲,残留话尾有啥
        // 播啥、自然播完,不被预缓冲门卡住(播完后回到 prebuffering 待下次开播)。
        if prebuffering {
            let gateHolds = streamActive || !startedPlayback
            if available >= prebufferSamples || (!gateHolds && available > 0) {
                prebuffering = false
            } else {
                let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        var outFrames = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            outFrames += Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
        }
        refill(Int((Double(outFrames) * step * adjust).rounded(.up)) + 2)
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let out = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let value = nextSample()
                for channel in 0..<channels {
                    out[frame * channels + channel] = value
                }
            }
        }

        // 汇总本次 render 消费的源样本(诊断计数,临界区仅一次整数加)。
        if callConsumed > 0 {
            outputLock.lock()
            outputSamplesTotal += callConsumed
            outputLock.unlock()
        }
    }

    /// 把本地样本块补到 need 个(一次加锁)。
    private func refill(_ need: Int) {
        guard localCount < need else { return }
        if localHead > 0 {
            for i in 0..<localCount { local[i] = local[localHead + i] }
            localHead = 0
        }
        let want = min(need, local.count) - localCount
        guard want > 0 else { return }
        let got = local.withUnsafeMutableBufferPointer {
            jitter.pop(into: UnsafeMutableBufferPointer(rebasing: $0[localCount..<localCount + want]))
        }
        localCount += got
    }

    private func takeSample() -> Int16? {
        guard localCount > 0 else { return nil }
        let value = local[localHead]
        localHead += 1
        localCount -= 1
        if localCount == 0 { localHead = 0 }
        return value
    }

    private func nextSample() -> Float {
        if !primed {
            // 需要相邻两个源样本才能插值。空转恢复时从零淡入(10ms):
            // 缓冲断供→恢复的瞬时跳变是"咔哒"声,听写分段器遇到会重发上一段。
            // 正常路径下到不了这里(预缓冲门已保证攒够才消费),仅作防御。
            guard localCount >= 2, let first = takeSample(), let second = takeSample() else {
                ramp = 0
                prebuffering = true
                return 0
            }
            callConsumed += 2
            a = Float(first) / 32768
            b = Float(second) / 32768
            frac = 0
            primed = true
            startedPlayback = true
            starving = false  // 断供恢复:之后再次断供才计新事件
            // 重新取到样本、再次开播:清零渐落计数;淡入仍由 ramp 负责,不动 ramp 语义。
            releaseSamplesLeft = 0
        }
        let value = (a + (b - a) * Float(frac)) * ramp
        if ramp < 1.0 { ramp = min(1.0, ramp + 1.0 / 480.0) }  // 48k 下 10ms
        frac += step * adjust
        while frac >= 1.0 {
            frac -= 1.0
            a = b
            if let next = takeSample() {
                b = Float(next) / 32768
                callConsumed += 1
            } else {
                // 缓冲被抽空:停播并回到预缓冲期,重新攒够 2 帧再续播。
                // 是否计断供由 render 开头的边沿检测按 streamActive 判定
                // (真实断供计数;松 Fn 自然排空不计)。
                // 断供排空渐落:首次抽空时置 240(5ms @48kHz),给本帧及随后
                // 239 帧挂线性衰减。why:缓冲断供→恢复的瞬时跳变是咔哒声,
                // 听写分段器遇到会重发上一段——同理话尾从 ~0.3 幅值一步跳 0
                // 也是阶跃咔哒;5ms 衰减短到不影响话尾可懂度,只抹平阶跃沿。
                if releaseSamplesLeft == 0 { releaseSamplesLeft = 240 }
                primed = false
                prebuffering = true
                break
            }
        }
        // 断供排空渐落:releaseSamplesLeft>0 时按 240→0 逐帧线性衰减。
        // 抽空首帧乘 240/240 即原幅 value 不突变,随后递减;归零后由上面的
        // !primed 分支恒输出 0,与既有断供静音输出对齐,无阶跃沿。
        if releaseSamplesLeft > 0 {
            let faded = value * Float(releaseSamplesLeft) / 240
            releaseSamplesLeft -= 1
            return faded
        }
        return value
    }
}
