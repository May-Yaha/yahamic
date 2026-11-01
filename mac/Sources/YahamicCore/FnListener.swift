import ApplicationServices
import CoreGraphics
import Foundation

/// 键盘事件监听权限诊断:macOS 上「辅助功能」(AX)与「输入监听」
/// (Input Monitoring)是两套相互独立的授权,CGEventTap 任一缺失都可能
/// 收不到事件(且 tapCreate 在权限刚失效时仍可能返回非 nil,预检状态比
/// 创建结果更可靠)。两者分开表达,缺哪项指引哪项。
public enum ListenPermission: String, Equatable, CaseIterable {
    case ok                      // 两项都已授权
    case missingInputMonitoring  // 只缺输入监听
    case missingAccessibility    // 只缺辅助功能
    case missingBoth             // 两项都缺

    public var granted: Bool { self == .ok }

    /// 面向日志/界面的可读状态(含具体缺失项)。
    public var description: String {
        switch self {
        case .ok: return "已授权(辅助功能 ✓,输入监听 ✓)"
        case .missingInputMonitoring: return "缺输入监听(辅助功能 ✓)"
        case .missingAccessibility: return "缺辅助功能(输入监听 ✓)"
        case .missingBoth: return "缺辅助功能与输入监听"
        }
    }

    /// 缺失项对应的授权指引。
    public var guidance: String {
        let ax = "系统设置 → 隐私与安全性 → 辅助功能"
        let input = "系统设置 → 隐私与安全性 → 输入监听"
        switch self {
        case .ok: return "权限已齐备"
        case .missingInputMonitoring: return "请授权:\(input)"
        case .missingAccessibility: return "请授权:\(ax)"
        case .missingBoth: return "请授权:\(ax),以及\(input)"
        }
    }

    /// 预检(不弹系统框):辅助功能与输入监听分开评估。
    public static func preflight() -> ListenPermission {
        let ax = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        switch (ax, input) {
        case (true, true): return .ok
        case (true, false): return .missingInputMonitoring
        case (false, true): return .missingAccessibility
        case (false, false): return .missingBoth
        }
    }

    /// 请求授权:输入监听走 CGRequestListenEventAccess(缺时系统弹框/引导),
    /// 辅助功能走 AXIsProcessTrustedWithOptions(prompt),只申请缺失的项。
    /// 返回请求后的即时预检状态(授权常需用户确认,可能仍为缺失)。
    @discardableResult
    public static func request() -> ListenPermission {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        return preflight()
    }
}

// 全局 Fn 键监听(push-to-talk):按住 Fn = 讲话,松开 = 静音。
//
// macOS 上 Fn 有两种上报路径,不同系统版本可能只用其一,也可能并存:
//   A) flagsChanged:Fn 修饰位翻转。即 CoreGraphics 的
//      kCGEventFlagMaskSecondaryFn(CGEventFlags.maskSecondaryFn),
//      对应 IOKit/HID 层的设备 Fn 位(NX_DEVICELFNKEYMASK);
//   B) 键码事件:macOS 27 上 Fn 可能改为上报键码 63(kVK_Function)的
//      keyDown/keyUp,而 flagsChanged 里 SecondaryFn 位不再翻转。
// 因此两条路径都要监听,但必须做到:
//   1) flagsChanged 分支只在 Fn 相关位(SecondaryFn / NX_DEVICELFNKEYMASK)
//      相对上一条 flagsChanged 实际翻转时才判定按下/松开——按住 Fn 再按
//      Shift/Cmd 等产生的 flagsChanged 中 Fn 位不变,整条事件直接忽略,
//      绝不能据此推断「Fn 松开」;
//   2) 键码分支只处理 keyCode==63 的 keyDown/keyUp,其余键码一律放行;
//   3) 两路径并存时(按一次 Fn 同时来 flagsChanged 和键码 63),状态取
//      「任一路径认为按下即按下」的并集,只有并集翻转才回调 onChange,
//      避免双触发与状态抖动;松开也以并集翻回 false 为准。
//
// tap 挂在会话层(.cgSessionEventTap)、默认模式(macOS 27 对 .cghidEventTap 的
// listenOnly tap 出现过"创建成功但零事件")。
// 注意:
// 1) 纯命令行进程里 NSEvent 的全局监听不会触发(需要 NSApplication 事件循环),
//    所以用 CGEventTap + 主 RunLoop;
// 2) 需要「辅助功能」权限;
// 3) 回调通过裸指针(refcon)找回实例:init 里 passRetained 自保,stop() 里成对
//    release。丢弃实例前必须先 stop() 显式摘掉 tap;忘记 stop 也只是泄漏,
//    不会是释放后回调的野指针崩溃(bus error / SIGSEGV)。
public final class FnListener {
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retainedSelf: Unmanaged<FnListener>?  // refcon 的自保引用,stop() 释放
    // 两条上报路径各自维护一份原始状态,互不影响:
    private var keycodeFnDown = false   // 路径 B:键码 63 最近一次 keyDown/keyUp
    private var fnFlagSet = false       // 路径 A:上一条 flagsChanged 中的 Fn 位
    private var lastDown = false        // 对外状态 = 两路径并集,翻转才回调
    private let onChange: (Bool) -> Void  // true = Fn 按下

    /// 创建时预检的监听权限状态(辅助功能 + 输入监听,见 ListenPermission)。
    public let permission: ListenPermission

    public init?(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        // 创建 tap 前先评估权限:辅助功能/输入监听两套授权分开记录,供调用方
        // 诊断与提示(tapCreate 在权限刚失效时仍可能“成功”,不能拿创建结果
        // 当权限依据;创建失败走下方 guard,成对 release 不留残留引用)。
        self.permission = ListenPermission.preflight()
        var mask = CGEventMask(0)
        mask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
        mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        // passRetained:tap 存活期间实例不会被释放,杜绝「实例已 dealloc 而事件
        // 又到」的 use-after-free;stop() 里成对 release。
        let retained = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            return nil
        }
        self.retainedSelf = retained
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 显式停用:从主 RunLoop 摘掉事件源并 invalidate tap,此后不再有任何回调。
    /// 幂等;调用方在丢弃实例引用前必须调用,保证任意时刻至多一个活动 tap。
    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        // 与 init 的 passRetained 成对:tap 已销毁,回调不可能再触发,释放自保。
        retainedSelf?.release()
        retainedSelf = nil
    }

    deinit {
        // 能走到 deinit 说明 retainedSelf 必已释放(refcon 持有期间引用计数不会
        // 归零),这里只是 stop() 幂等收尾 tap/source 的双保险。
        stop()
    }

    /// 并集状态翻转时才通知外部,天然去抖:两路径并存不会双触发。
    private func updateCombined() {
        let down = keycodeFnDown || fnFlagSet
        guard down != lastDown else { return }
        lastDown = down
        onChange(down)
    }

    fileprivate func handle(_ event: CGEvent, type: CGEventType) {
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown || type == .keyUp {
            // 键码分支(路径 B):只有 Fn 键码 63 关心;其余按键直接放行
            // (默认模式必须原样返回事件)。重复 keyDown 由 updateCombined 去抖。
            if key == 63 {
                keycodeFnDown = type == .keyDown
                updateCombined()
            }
            return
        }
        // flagsChanged 分支(路径 A):只看 Fn 相关位
        // (kCGEventFlagMaskSecondaryFn,对应 NX_DEVICELFNKEYMASK)是否相对
        // 上一条 flagsChanged 实际翻转。按住 Fn 期间再按 Shift/Cmd 也会来
        // flagsChanged,但 Fn 位不变——整条忽略,避免误判「Fn 松开」。
        guard type == .flagsChanged else { return }
        let fn = event.flags.contains(.maskSecondaryFn)
        guard fn != fnFlagSet else { return }
        fnFlagSet = fn
        var names: [String] = ["Fn=\(fn)"]
        if event.flags.contains(.maskCommand) { names.append("Cmd") }
        if event.flags.contains(.maskShift) { names.append("Shift") }
        updateCombined()
    }
}

// 文件作用域的 C 回调(不捕获任何上下文),实例经 refcon 找回。
private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let listener = Unmanaged<FnListener>.fromOpaque(refcon).takeUnretainedValue()
    // 系统在事件处理超时/用户输入时会禁用 tap:重新打开,否则此后再也收不到。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = listener.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    listener.handle(event, type: type)
    return Unmanaged.passUnretained(event)  // defaultTap:不修改事件,原样放行
}
