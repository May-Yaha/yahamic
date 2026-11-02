#include "protocol.h"

#include <cstring>

#include "esp_log.h"

namespace proto {
namespace {

constexpr const char* kTag = "proto";
constexpr const char* kSalt = "yahamic-v2";
constexpr uint32_t kIterations = 4096;

void nonce_of(uint32_t seq, uint8_t out[12]) {
  memset(out, 0, 8);
  for (int i = 0; i < 4; ++i) out[8 + i] = uint8_t(seq >> (8 * i));
}

psa_key_id_t import_hmac(const uint8_t key[kKeySize], psa_key_usage_t usage) {
  psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attr, PSA_KEY_TYPE_HMAC);
  psa_set_key_usage_flags(&attr, usage);
  psa_set_key_algorithm(&attr, PSA_ALG_HMAC(PSA_ALG_SHA_256));
  psa_key_id_t id = 0;
  if (psa_import_key(&attr, key, kKeySize, &id) != PSA_SUCCESS) return 0;
  return id;
}

psa_key_id_t import_aead(const uint8_t key[kKeySize]) {
  psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attr, PSA_KEY_TYPE_CHACHA20);
  psa_set_key_bits(&attr, 256);
  psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_ENCRYPT | PSA_KEY_USAGE_DECRYPT);
  psa_set_key_algorithm(&attr, PSA_ALG_CHACHA20_POLY1305);
  psa_key_id_t id = 0;
  if (psa_import_key(&attr, key, kKeySize, &id) != PSA_SUCCESS) return 0;
  return id;
}

// label ‖ dn ‖ mn(label 最长 3 字节)。
size_t mac_input(const char* label, const uint8_t dn[kNonceSize], const uint8_t mn[kNonceSize],
                 uint8_t out[3 + 2 * kNonceSize]) {
  size_t n = strnlen(label, 3);
  memcpy(out, label, n);
  memcpy(out + n, dn, kNonceSize);
  memcpy(out + n + kNonceSize, mn, kNonceSize);
  return n + 2 * kNonceSize;
}

}  // namespace

Header make_header(uint8_t type, uint8_t flags, uint32_t seq, uint32_t ts) {
  Header h = {};
  h.magic = 'Y';
  h.version = kVersion;
  h.type = type;
  h.flags = flags;
  h.seq = seq;  // ESP32 本机小端,与线上格式一致
  h.ts = ts;
  return h;
}

bool parse_header(const uint8_t* data, size_t len, Header& out) {
  if (len < sizeof(Header) || len > kMaxPacket) return false;
  memcpy(&out, data, sizeof(Header));
  return out.magic == 'Y' && out.version == kVersion;
}

bool field(const char* text, const char* key, char* out, size_t out_size) {
  const size_t klen = strlen(key);
  for (const char* line = text; *line;) {
    const char* end = strchr(line, '\n');
    if (!end) end = line + strlen(line);
    if (size_t(end - line) > klen && strncmp(line, key, klen) == 0 && line[klen] == ' ') {
      const char* from = line + klen + 1;
      const size_t len = size_t(end - from);
      if (len >= out_size) return false;
      memcpy(out, from, len);
      out[len] = 0;
      return true;
    }
    line = *end ? end + 1 : end;
  }
  return false;
}

void to_hex(const uint8_t* bytes, size_t n, char* out) {
  static const char* digits = "0123456789abcdef";
  for (size_t i = 0; i < n; ++i) {
    out[i * 2] = digits[bytes[i] >> 4];
    out[i * 2 + 1] = digits[bytes[i] & 0xF];
  }
  out[n * 2] = 0;
}

bool from_hex(const char* text, uint8_t* out, size_t n) {
  if (strlen(text) != n * 2) return false;
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (size_t i = 0; i < n; ++i) {
    int hi = nibble(text[i * 2]), lo = nibble(text[i * 2 + 1]);
    if (hi < 0 || lo < 0) return false;
    out[i] = uint8_t(hi << 4 | lo);
  }
  return true;
}

bool valid_code(const std::string& code) {
  if (code.size() < kMinCode || code.size() > kMaxCode) return false;
  for (char c : code)
    if (c <= ' ' || c > '~') return false;
  return true;
}

bool master_key(const std::string& code, uint8_t out[kKeySize]) {
  psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
  bool ok = psa_key_derivation_setup(&op, PSA_ALG_PBKDF2_HMAC(PSA_ALG_SHA_256)) == PSA_SUCCESS &&
            psa_key_derivation_input_integer(&op, PSA_KEY_DERIVATION_INPUT_COST, kIterations) == PSA_SUCCESS &&
            psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SALT,
                                           reinterpret_cast<const uint8_t*>(kSalt), strlen(kSalt)) == PSA_SUCCESS &&
            psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_PASSWORD,
                                           reinterpret_cast<const uint8_t*>(code.data()), code.size()) == PSA_SUCCESS &&
            psa_key_derivation_output_bytes(&op, out, kKeySize) == PSA_SUCCESS;
  psa_key_derivation_abort(&op);
  return ok;
}

bool mac(const uint8_t key[kKeySize], const char* label, const uint8_t dn[kNonceSize],
         const uint8_t mn[kNonceSize], uint8_t out[32]) {
  psa_key_id_t id = import_hmac(key, PSA_KEY_USAGE_SIGN_MESSAGE);
  if (!id) return false;
  uint8_t input[3 + 2 * kNonceSize];
  size_t in_len = mac_input(label, dn, mn, input), out_len = 0;
  bool ok = psa_mac_compute(id, PSA_ALG_HMAC(PSA_ALG_SHA_256), input, in_len, out, 32, &out_len) ==
                PSA_SUCCESS && out_len == 32;
  psa_destroy_key(id);
  return ok;
}

bool verify(const uint8_t key[kKeySize], const char* label, const uint8_t dn[kNonceSize],
            const uint8_t mn[kNonceSize], const uint8_t proof[32]) {
  psa_key_id_t id = import_hmac(key, PSA_KEY_USAGE_VERIFY_MESSAGE);
  if (!id) return false;
  uint8_t input[3 + 2 * kNonceSize];
  size_t in_len = mac_input(label, dn, mn, input);
  bool ok = psa_mac_verify(id, PSA_ALG_HMAC(PSA_ALG_SHA_256), input, in_len, proof, 32) == PSA_SUCCESS;
  psa_destroy_key(id);
  return ok;
}

bool Session::begin(const uint8_t key[kKeySize], const uint8_t dn[kNonceSize], const uint8_t mn[kNonceSize]) {
  end();
  uint8_t d2m[32], m2d[32];
  bool ok = mac(key, "d2m", dn, mn, d2m) && mac(key, "m2d", dn, mn, m2d);
  if (ok) {
    send_ = import_aead(d2m);
    recv_ = import_aead(m2d);
  }
  memset(d2m, 0, sizeof d2m);
  memset(m2d, 0, sizeof m2d);
  if (!send_ || !recv_) {
    end();
    return false;
  }
  return true;
}

void Session::end() {
  if (send_) psa_destroy_key(send_);
  if (recv_) psa_destroy_key(recv_);
  send_ = recv_ = 0;
}

bool Session::seal(const Header& h, const uint8_t* plain, size_t len, uint8_t* out, size_t* out_len) const {
  if (!send_) return false;
  uint8_t nonce[12];
  nonce_of(h.seq, nonce);
  return psa_aead_encrypt(send_, PSA_ALG_CHACHA20_POLY1305, nonce, sizeof nonce,
                          reinterpret_cast<const uint8_t*>(&h), sizeof h, plain, len, out,
                          len + kTagSize, out_len) == PSA_SUCCESS;
}

bool Session::open(const Header& h, const uint8_t* sealed, size_t len, uint8_t* out, size_t* out_len) const {
  if (!recv_ || len < kTagSize) return false;
  uint8_t nonce[12];
  nonce_of(h.seq, nonce);
  return psa_aead_decrypt(recv_, PSA_ALG_CHACHA20_POLY1305, nonce, sizeof nonce,
                          reinterpret_cast<const uint8_t*>(&h), sizeof h, sealed, len, out,
                          len - kTagSize, out_len) == PSA_SUCCESS;
}

// 测试向量来自 tools/protocol_vectors.py(Mac 单测用同一组)。
bool self_test() {
  auto hex_eq = [](const uint8_t* bytes, size_t n, const char* want) {
    char got[2 * 64 + 1];
    to_hex(bytes, n, got);
    return strcmp(got, want) == 0;
  };
  uint8_t dn[kNonceSize], mn[kNonceSize], k[kKeySize], proof[32];
  for (int i = 0; i < 16; ++i) dn[i] = uint8_t(i), mn[i] = uint8_t(16 + i);
  const char* step = "pbkdf2";
  bool ok = master_key("ABCD2345EF", k) &&
            hex_eq(k, 32, "b32f3dc50c7781c64ab18cb867e5e2ef1c7baba7dd39b0be26b6e7d7c3e163b8");
  if (ok) {
    step = "proof";
    ok = mac(k, "d", dn, mn, proof) &&
         hex_eq(proof, 32, "df5da4ad5311fe3bfd8288832dee79c5767d946abd766cd15443138cc119c56a");
    uint8_t want_m[32];
    ok = ok && from_hex("cd546160d89ed512d86fffe38651d8ada4613fc242f6162102b1539a20b7f765", want_m, 32) &&
         verify(k, "m", dn, mn, want_m);
    want_m[0] ^= 1;
    ok = ok && !verify(k, "m", dn, mn, want_m);
  }
  Session s;
  if (ok) {
    step = "seal";
    Header h = make_header(kAudio, 0, 5, 300);
    uint8_t out[4 + kTagSize];
    size_t n = 0;
    ok = s.begin(k, dn, mn) && hex_eq(reinterpret_cast<uint8_t*>(&h), 12, "59020300050000002c010000") &&
         s.seal(h, reinterpret_cast<const uint8_t*>("opus"), 4, out, &n) && n == sizeof out &&
         hex_eq(out, n, "adf6bc7da3c0f86bd0d74ae194acbb5ed7a76925");
  }
  if (ok) {
    step = "open";
    Header h = make_header(kControl, 1, 1, 0);
    uint8_t sealed[30], plain[30];
    size_t n = 0;
    ok = from_hex("d8d315ad09ec3e6fda838a4e3122dfc74276717e73a45220594eed0cdaaf", sealed, 30) &&
         s.open(h, sealed, 30, plain, &n) && n == 14 && memcmp(plain, "muted 1\ncmd 1\n", 14) == 0;
    sealed[29] ^= 1;
    ok = ok && !s.open(h, sealed, 30, plain, &n);
  }
  if (ok) {
    step = "field";
    char v[8];
    ok = field("xmuted 1\nmuted 0\n", "muted", v, sizeof v) && strcmp(v, "0") == 0 &&
         !field("name 123456789\n", "name", v, sizeof v) && !field("mute 1\n", "muted", v, sizeof v);
  }
  memset(k, 0, sizeof k);
  if (ok) ESP_LOGI(kTag, "v2 self-test ok");
  else ESP_LOGE(kTag, "v2 self-test FAILED at %s", step);
  return ok;
}

}  // namespace proto
