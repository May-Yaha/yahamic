#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

#include "sdkconfig.h"

// 链路层:Wi-Fi 接入(esp-wifi-connect,配网页见 components/esp-wifi-connect)、
// 在局域网里用 mDNS 找到 Mac 上的 yahamicd(_yahamic._tcp),然后走 UDP:
// 60 ms 一帧的 Opus 编码音频(16 kHz 单声道)直传,外加 hello/welcome 握手、
// 静音状态与保活。
// 全双工只走一个 UDP socket,设备侧无需任何 JSON 依赖(报文是"键 值"行)。
namespace uplink {

// 主循环每周期拉取(24-30 fps 目标节奏),用于组屏幕与日志。
struct Snapshot {
  bool setup = false;       // 配网热点开着
  char setup_ssid[33] = {0};
  char setup_pass[16] = {0};
  bool wifi_up = false;
  bool joining = false;     // 存过网络但没连上(屏幕显示 JOINING 而非 NO WI-FI)
  char ssid[33] = {0};      // 已连接/正在加入的网络
  char ip[16] = {0};
  int rssi = 0;
  bool live = false;        // yahamicd 已应答:音频正在发送
  char daemon[24] = {0};    // yahamicd 的 ip:port
  bool muted = false;
  char phase[12] = {0};     // worker 阶段:idle / discover / handshake / live(排障用)
};

using MuteCommand = std::function<void(bool muted)>;

void start(const char* fw_version);
void open_setup();  // 长按按键:进入配网热点
void on_remote_mute(MuteCommand command);  // Mac 端(Fn 键)遥控静音,worker 线程回调
bool consume_dump_request();               // Mac 请求的屏幕回传(一次一帧)

void set_muted(bool muted);  // 静音变化(立即发一帧状态报文)
bool muted();
Snapshot snapshot();

// type 7 dashboard(Mac→设备):空闲屏仪表盘数据,10 字节小端载荷。
// 无效字段统一 255;received_ms 是收到时刻的设备单调毫秒(esp_timer),
// 供上层做新鲜度判定(超过约 10 秒未更新应回退到静音屏)。
struct Dashboard {
  uint32_t epoch = 0;            // Unix epoch 秒(UTC)
  int16_t tz_offset_minutes = 0; // 时区偏移(分钟;可覆盖 30/45 分钟偏移,设备端只做一次加法)
  uint8_t cpu = 255;             // CPU 占用 %(0-100,255=无效)
  uint8_t mem = 255;             // 内存占用 %(0-100,255=无效)
  uint8_t mouse_batt = 255;      // 鼠标电量 %(0-100,255=无效)
  uint8_t kb_batt = 255;         // 键盘电量 %(0-100,255=无效)
  uint32_t received_ms = 0;      // 收到时刻的单调毫秒
  bool valid = false;            // 是否收到过至少一帧
};

// 主循环拉取最近一次 type 7 报文(与 snapshot() 一致的轮询方式)。
Dashboard dashboard();

// 采集线程调用(audio::set_sink 注册):把一帧 Opus 发给 yahamicd。
// 未握手成功时直接丢弃,绝不阻塞采集。
void send_audio(const uint8_t* opus, size_t size, uint32_t ts_ms, float level);

}  // namespace uplink
