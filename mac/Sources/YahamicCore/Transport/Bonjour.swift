import dnssd
import Dispatch

// Bonjour 注册(_yahamic._tcp),dnssd C API:进程多次非正常退出后
// NWListener.service 会静默失效;这里行为明确,且成功时有回调确认。
final class Bonjour {
    final class Box {
        let handler: (String) -> Void
        init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    }

    private var ref: DNSServiceRef?
    private var box: Box
    private let queue: DispatchQueue

    init?(name: String, type: String, port: UInt16, queue: DispatchQueue,
          onRegistered: @escaping (String) -> Void) {
        self.queue = queue
        let handler = Box(onRegistered)
        self.box = handler
        var dnsRef: DNSServiceRef?
        let status = DNSServiceRegister(
            &dnsRef, 0, UInt32(kDNSServiceInterfaceIndexAny),
            name, type, "local.", nil,
            port.bigEndian, 0, nil,
            { _, _, errorCode, registered, _, _, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if errorCode == kDNSServiceErr_NoError, let registered {
                    box.handler(String(cString: registered))
                } else if errorCode != kDNSServiceErr_NoError {
                    print("Bonjour 注册错误:\(errorCode)")
                }
            },
            Unmanaged.passUnretained(handler).toOpaque()
        )
        guard status == kDNSServiceErr_NoError, let dnsRef else { return nil }
        ref = dnsRef
        DNSServiceSetDispatchQueue(dnsRef, queue)
    }

    deinit {
        if let ref { DNSServiceRefDeallocate(ref) }
    }
}
