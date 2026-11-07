import Foundation
import Security
import DeskProtocol

/// Factory identity from the `identity` characteristic: the leaf cert's CN is the factory device id
/// (`yd_` + 26 chars of [0-9a-z]), used as DMS device_addr and device_sn. The server verifies the chain.
public enum FactoryIdentity {
    public static func deviceID(certificate der: Data) throws -> String {
        guard !der.isEmpty else { throw DeskProtocolError("设备没有出厂身份") }
        var name: CFString?
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              SecCertificateCopyCommonName(cert, &name) == errSecSuccess, let cn = name as String?,
              cn.hasPrefix("yd_"), cn.count == 29,
              cn.dropFirst(3).allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            throw DeskProtocolError("设备出厂证书无效")
        }
        return cn
    }
}
