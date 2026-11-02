#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include <psa/crypto.h>

// 协议 v2 的纯逻辑部分(README「协议」一节是规范,Mac 端对应 YahamicProtocol):
// 12 字节小端头、"key value" 行、配对码派生的会话密码学。不碰 socket,不碰 Wi-Fi。
//   K      = PBKDF2-HMAC-SHA256(配对码, "yahamic-v2", 4096, 32)
//   proof  = HMAC(K, "m"|"d" ‖ dn ‖ mn)        welcome / auth 的双向证明
//   方向键 = HMAC(K, "d2m"|"m2d" ‖ dn ‖ mn)
//   载荷   = ChaCha20-Poly1305(方向键, nonce = 0^8 ‖ seq_LE, aad = 12 字节头),密文 ‖ 16B tag
namespace proto {

constexpr uint8_t kVersion = 2;
constexpr uint8_t kHello = 1;      // 设备→Mac 明文:名字/固件/音频参数/dn
constexpr uint8_t kWelcome = 2;    // Mac→设备 明文:ok/host/dn/mn/proof(或 ok 0 + err)
constexpr uint8_t kAudio = 3;      // 设备→Mac 加密:Opus 帧
constexpr uint8_t kStatus = 4;     // 设备→Mac 加密:muted 0/1(静音时兼作心跳)
constexpr uint8_t kKeepalive = 5;  // Mac→设备 加密:最新静音指令 muted/cmd
constexpr uint8_t kControl = 6;    // Mac→设备 加密:muted/cmd、dump 1
constexpr uint8_t kDashboard = 7;  // Mac→设备 加密:10 字节仪表盘
constexpr uint8_t kAuth = 8;       // 设备→Mac 明文:proof

constexpr size_t kNonceSize = 16;   // dn / mn
constexpr size_t kKeySize = 32;
constexpr size_t kTagSize = 16;
constexpr size_t kMaxPayload = 512;  // 明文载荷上限(Opus 帧 ≤ 512B);超长包直接拒收
constexpr size_t kMaxPacket = 12 + kMaxPayload + kTagSize;
constexpr size_t kMinCode = 8, kMaxCode = 63;

struct __attribute__((packed)) Header {
  uint8_t magic;
  uint8_t version;
  uint8_t type;
  uint8_t flags;  // bit0 = 静音
  uint32_t seq;
  uint32_t ts;
};
static_assert(sizeof(Header) == 12, "wire header");

inline bool is_sealed(uint8_t type) { return type >= kAudio && type <= kDashboard; }
Header make_header(uint8_t type, uint8_t flags, uint32_t seq, uint32_t ts);
// magic/version 对得上才返回 true;长度不足、超过 kMaxPacket 都拒收。
bool parse_header(const uint8_t* data, size_t len, Header& out);

// "key value" 行里取值:key 必须在行首;值超过 out_size-1 返回 false(不截断)。
bool field(const char* text, const char* key, char* out, size_t out_size);

void to_hex(const uint8_t* bytes, size_t n, char* out);           // out 至少 2n+1
bool from_hex(const char* text, uint8_t* out, size_t n);         // 必须正好 2n 个十六进制字符

// 配对码:8–63 位可见 ASCII(与 Mac 端 Pairing.isValid、配网页校验一致)。
bool valid_code(const std::string& code);
bool master_key(const std::string& code, uint8_t out[kKeySize]);
bool mac(const uint8_t key[kKeySize], const char* label, const uint8_t dn[kNonceSize],
         const uint8_t mn[kNonceSize], uint8_t out[32]);
// 常量时间验证(psa_mac_verify)。
bool verify(const uint8_t key[kKeySize], const char* label, const uint8_t dn[kNonceSize],
            const uint8_t mn[kNonceSize], const uint8_t proof[32]);

// 一次会话的两把方向密钥(设备侧:发 d2m、收 m2d)。不加锁,调用方负责串行。
class Session {
 public:
  ~Session() { end(); }
  bool begin(const uint8_t key[kKeySize], const uint8_t dn[kNonceSize], const uint8_t mn[kNonceSize]);
  void end();
  bool active() const { return send_ != 0; }
  // out 至少 len + kTagSize;nonce 取自头里的 seq。
  bool seal(const Header& h, const uint8_t* plain, size_t len, uint8_t* out, size_t* out_len) const;
  // tag 不对(伪造/篡改/错码)返回 false;out 至少 len - kTagSize。
  bool open(const Header& h, const uint8_t* sealed, size_t len, uint8_t* out, size_t* out_len) const;

 private:
  psa_key_id_t send_ = 0, recv_ = 0;
};

// 开机自检:对 tools/protocol_vectors.py 的测试向量跑一遍(约 1 秒 PBKDF2)。
bool self_test();

}  // namespace proto
