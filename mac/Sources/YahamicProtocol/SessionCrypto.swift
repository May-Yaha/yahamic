import CommonCrypto
import CryptoKit
import Foundation

/// 协议 v2 密码学(与 firmware/main/protocol.cpp 一一对应,测试向量见
/// firmware/tools/protocol_vectors.py):
///   K      = PBKDF2-HMAC-SHA256(配对码, "yahamic-v2", 4096, 32)
///   proof  = HMAC(K, "m"|"d" ‖ dn ‖ mn)            welcome / auth 的双向证明
///   方向键 = HMAC(K, "d2m"|"m2d" ‖ dn ‖ mn)
///   载荷   = ChaChaPoly(方向键, nonce = 0^8 ‖ seq_LE, aad = 12 字节头) 密文 ‖ 16B tag
public enum SessionCrypto {
    public static let minCodeLength = 8
    public static let maxCodeLength = 63
    public static let nonceSize = 16
    public static let tagSize = 16

    /// 配对码 → 主密钥。PBKDF2 抬高离线爆破成本;换码时算一次即可。
    public static func masterKey(code: String) -> SymmetricKey {
        let password = Array(code.utf8)
        let salt = Array("yahamic-v2".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 4096, &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 失败:\(status)")
        return SymmetricKey(data: out)
    }

    public static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    public static func mac(_ key: SymmetricKey, _ label: String, dn: Data, mn: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + dn + mn, using: key))
    }

    /// 常量时间比较证明(CryptoKit 的 isValidAuthenticationCode 内部即常量时间)。
    public static func verify(_ key: SymmetricKey, _ label: String, dn: Data, mn: Data, proof: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(label.utf8) + dn + mn, using: key)
    }

    /// 一次会话的两把方向密钥。
    public struct Session {
        public let send: SymmetricKey
        public let receive: SymmetricKey

        /// Mac 侧:发送用 m2d,接收用 d2m。
        public init(macSideWith key: SymmetricKey, dn: Data, mn: Data) {
            send = SymmetricKey(data: SessionCrypto.mac(key, "m2d", dn: dn, mn: mn))
            receive = SymmetricKey(data: SessionCrypto.mac(key, "d2m", dn: dn, mn: mn))
        }

        public init(send: SymmetricKey, receive: SymmetricKey) {
            self.send = send
            self.receive = receive
        }

        public func seal(header: Data, seq: UInt32, plaintext: Data) -> Data {
            // 只有 nonce 长度不对才会抛,这里 nonce 固定 12 字节。
            let box = try! ChaChaPoly.seal(plaintext, using: send, nonce: SessionCrypto.nonce(seq),
                                           authenticating: header)
            return box.ciphertext + box.tag
        }

        /// 验 tag 失败返回 nil(伪造、篡改、用错配对码)。
        public func open(header: Data, seq: UInt32, sealed: Data) -> Data? {
            guard sealed.count >= tagSize,
                  let box = try? ChaChaPoly.SealedBox(nonce: SessionCrypto.nonce(seq),
                                                      ciphertext: sealed.dropLast(tagSize),
                                                      tag: sealed.suffix(tagSize))
            else { return nil }
            return try? ChaChaPoly.open(box, using: receive, authenticating: header)
        }
    }

    static func nonce(_ seq: UInt32) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: seq.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
