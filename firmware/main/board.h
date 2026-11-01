#pragma once

#include <cstdint>
#include <string>

#include "driver/i2c_master.h"
#include "esp_lcd_types.h"

// 板级支持(Waveshare ESP32-S3-Touch-AMOLED-2.16,与 OpenCharm 相同的参考板):
// I2C 总线、CO5300 屏幕、板上按键(GPIO18)。屏幕不引 LVGL:静态状态用自带
// 5x7 点阵字体直接画(绿 = ON AIR,红 = MUTED,蓝 = 正在找 Mac,橙 = Wi-Fi
// 配网热点),Live 时叠加频谱律动图(见 draw_spectrum)。引脚与初始化序列同
// OpenCharm 的 firmware/device/main/board.cpp(源自 Waveshare 原理图与
// xiaozhi-esp32)。
namespace board {

struct Board {
  i2c_master_bus_handle_t i2c = nullptr;
  esp_lcd_panel_handle_t panel = nullptr;
  esp_lcd_panel_io_handle_t panel_io = nullptr;
};

// 屏幕要显示什么(main.cpp 按当前状态组装,board 负责画)。
struct Screen {
  enum class State { Boot, Setup, Joining, Searching, NoWifi, Live, Muted, Dashboard };
  State state = State::Boot;
  std::string line1;  // 大字:状态名(ON AIR、MUTED、…)
  std::string line2;  // 中字:SSID、热点名、密码等
  std::string line3;  // 中字第二行
  float level = 0;    // 响度条,0..1(当前固件未用:Live 屏电平由波形振幅表现)
  std::string status; // 底部一行小字:电量、IP、RSSI、版本
};

void init(Board& b);
bool key_down();

// Dashboard 屏(空闲默认屏)数据:Mac 经 type 7 周期下发(见 uplink::Dashboard;
// board 不直接依赖 uplink,由 main.cpp 转换后传入)。百分比统一 0..100,
// 255 = 无效(对应环整环灰显、中心显示 "--")。
struct DashboardData {
  uint32_t epoch = 0;        // Unix epoch 秒(UTC)
  int tz_offset_minutes = 0; // 本地时区偏移(分钟,已含 DST,设备端只做加法)
  uint8_t cpu = 255;         // CPU 占用 %
  uint8_t mem = 255;         // 内存占用 %
  uint8_t mouse_batt = 255;  // 蓝牙鼠标电量 %
  uint8_t kb_batt = 255;     // 蓝牙键盘电量 %
};

// 每收到一包仪表盘数据调用一次:更新显示数据并重置时钟基准(基准随每包重算,
// 无累计分钟漂移;why 见 board.cpp 实现处注释)。
void set_dashboard(const DashboardData& d);
// 重绘 Dashboard 屏(大字时钟 + 2x2 弧形进度环 + 底部状态行):时钟按"基准本地
// 秒 + 单调增量"推进,主循环约 1 Hz 调用即可秒级刷新;整屏重绘,性能已验证
// 可行(见 draw_spectrum 遥测:整屏刷新在 QSPI 带宽内)。
void draw_dashboard();

// 频谱重心(音高指标):由现有 32 个对数频带(50 Hz..8 kHz,值 0..1)按
// 能量加权得到,单位是连续频带序号(0..count-1);等效 Hz = 50·160^((u+0.5)/32)
// (160 = 8000/50)。中性默认值 = (count-1)/2 = 15.5,约 632 Hz(全频段几何中心)。
// 总能量低于噪声底时门限关闭:重心冻结不更新,平滑值按固定速率回中性值。
struct Centroid {
  float raw = 0;         // 原始值:最近一次门限打开时的能量加权重心(频带序号)
  bool gate_open = false; // 门限状态:true = 总能量高于噪声底,重心在更新
  float smoothed = 0;    // 平滑值:非对称 EMA(攻击快、释放慢),渲染帧间一阶趋近
};

// 更新重心指标:每渲染帧调用一次(draw_spectrum 内部已调,一般无需再调)。
// 输入约 60 ms 一刷新的频带,输出在渲染帧间做一阶趋近,消除台阶感。
void update_centroid(const float* bars, int count);
const Centroid& centroid();  // 读当前重心状态(渲染线程维护,主循环读)

void draw(const Screen& s);     // 整屏重画(状态变化时调用)
void draw_level(float level);   // 只重画响度条区域(当前固件未调用,保留 API)
// 频谱律动图(Live 屏):默认三条频带包络曲线(青/蓝/紫粉,64 点 × 3,流速与空间
// 周期由频谱重心驱动、相位连续)经 lv_canvas 画进 PSRAM 画布、只无效化曲线占据的
// 纵向脏带;CONFIG_YAHAMIC_SPECTRUM_BARS 时为 lv_chart 32 根弹簧色柱。持
// lvgl_port_lock 同步 lv_refr_now,供主循环按 24-30 fps 目标节奏调用(真机 24.3 fps,
// 遥测见日志)。why 不用 lv_chart 折线/为何分批 dispatch 见 board_screen.h 与实现注释。
void draw_spectrum(const float* bars, int count);
void set_brightness(uint8_t percent);
uint32_t spectrum_frame_count();  // 遥测:频谱累计渲染帧数
void request_screen_dump();       // 回传一帧屏幕(经日志口,Mac 侧重建成图)
void render_timing(int32_t& frame_us, int32_t& dma_us);  // 遥测:最近一帧耗时/其中传屏耗时

}  // namespace board
