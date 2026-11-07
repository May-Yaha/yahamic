#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

// 链路层:协议 v3,BLE GATT 外设(NimBLE)。开机即广播 `yahadesk-XXXX`,Mac 的
// Yaha Desk 连上后订阅 audio(60 ms 一帧 Opus,按 MTU 分片 notify)与 status,
// 写 control(静音 / 屏幕回传)与 dashboard。所有特征要求加密 + MITM 认证:
// 首次连接由系统蓝牙配对完成(设备屏幕显示 6 位数,Mac 弹框输入),bond 存 NVS。
// 规范见 README「协议 v3」。
namespace uplink {

// 主循环每周期拉取(24-30 fps 目标节奏),用于组屏幕与日志。
struct Snapshot {
  bool connected = false;   // 有 central 连着(未必已配对)
  bool live = false;        // 已认证加密且 Mac 订阅了 audio:音频正在发送
  uint32_t passkey = 0;     // 配对中要显示的 6 位数(0 = 不在配对)
  int rssi = 0;             // 连接的 RSSI(dBm,2 秒缓存;未连接为 0)
  bool muted = false;
  char phase[12] = {0};     // advertising / connected / pairing / live(排障用)
};

using MuteCommand = std::function<void(bool muted)>;

void start(const char* fw_version);
// Mac 端(Fn 键)遥控静音与断链自动静音,NimBLE host 任务里回调;须在 start 之前注册。
void on_remote_mute(MuteCommand command);
bool consume_dump_request();               // Mac 请求的屏幕回传(一次一帧)

void set_muted(bool muted);  // 静音变化(上线时立即 notify status);只由 mic::set_muted 调
bool muted();
Snapshot snapshot();

// dashboard 特征(Mac→设备):空闲屏仪表盘数据,10 字节小端载荷。
// 无效字段统一 255;received_ms 是收到时刻的设备单调毫秒(esp_timer),
// 供上层做新鲜度判定(超过约 10 秒未更新应回退到静音屏)。
struct Dashboard {
  uint32_t epoch = 0;            // Unix epoch 秒(UTC)
  int16_t tz_offset_minutes = 0; // 时区偏移(分钟;可覆盖 30/45 分钟偏移,设备端只做一次加法)
  uint8_t cpu = 255;             // CPU 占用 %(0-100,255=无效)
  uint8_t mem = 255;             // 内存占用 %(0-100,255=无效)
  uint8_t mouse_batt = 255;      // 鼠标电量 %(0-100,255=无效)
  uint8_t kb_batt = 255;         // 键盘电量 %(0-100,255=无效)
  uint8_t mac_battery = 255;
  uint8_t mac_power = 0;
  uint32_t received_ms = 0;      // 收到时刻的单调毫秒
  bool valid = false;            // 是否收到过至少一帧
};

// 主循环拉取最近一次 dashboard 写入(与 snapshot() 一致的轮询方式)。
Dashboard dashboard();

// card 特征(Mac→设备):yahaops 云端下发的文字卡片(AI 日报、agent 消息)。
// 载荷 ttl u16 LE ‖ title UTF-8 ‖ 0x00 ‖ body UTF-8,ttl = 0 清除。
struct Card {
  std::string title;
  std::string body;
  uint32_t expires_ms = 0;  // 到期的设备单调毫秒
  bool active = false;
};

// 主循环拉取当前卡片;已到期的返回 active = false。
Card card();
void publish_cloud_status(const std::string& json);

// 采集线程调用(audio::set_sink 注册):把一帧 Opus 分片 notify 给 Mac。
// 未 live 时直接丢弃,绝不阻塞采集。
void send_audio(const uint8_t* opus, size_t size, uint32_t ts_ms, float level);

}  // namespace uplink
