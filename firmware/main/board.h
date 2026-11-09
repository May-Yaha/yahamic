#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "display.h"

#include "driver/i2c_master.h"
#include "esp_lcd_types.h"

// 板级支持(Waveshare ESP32-S3-Touch-AMOLED-2.16,与 OpenCharm 相同的参考板):
// I2C 总线、CO5300 屏幕、CST9220 触摸(0x5A,INT GPIO11,RST GPIO40)、板上按键(GPIO18)。屏幕由 LVGL 渲染(board_screen.cpp):
// 状态屏是「彩色圆点 + 标题」(红 = 讲话中,灰 = 已静音,蓝 = 寻找 Mac,橙 = 蓝牙
// 配对码),Live 时叠加电平条与计时(见 draw_spectrum)。引脚与初始化序列同
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
  enum class State { Boot, Pairing, Searching, Live, Muted, Workbench };
  struct Row {
    std::string title, text, level;  // level: ok / warn / error,其余灰显
  };
  State state = State::Boot;
  std::string line1;  // 大字:状态名(#on_air_s、#muted、PAIR…);工作台详情/告警/通知页为页标题
  std::string line2;  // 中字:副标题、提示;工作台详情页为摘要、通知页为正文
  std::string line3;  // 中字第二行;工作台首页为通知条(空则隐藏)、通知页为序号
  float level = 0;    // 响度条,0..1(当前固件未用:Live 屏电平由波形振幅表现)
  std::string status; // 底部一行小字:电量、IP、RSSI、版本
  int battery = -1;   // 底部状态行的电池图标:0..100;-1 = 没装电池(图标隐藏)
  bool charging = false;
  // 首页 line1/line2 是麦克风与连接状态；管理员工作台 alert 非空时显示入口。
  // 总览 rows = 5 个云端分区；详情 rows 为明细；告警页 rows 为告警。
  display::Page page = display::Page::Home;
  std::string tone;
  Row alert;
  std::vector<Row> rows;
  std::vector<int64_t> trend;
  uint8_t speed = 1;  // 通知页跑马灯速度档 0..display::kSpeeds-1(慢/中/快)
  bool marquee_paused = false;
};

void init(Board& b);
bool key_down();
// 触摸(CST9220):LVGL 点击回调记下目标,主循环每圈取一次;无点击返回 display::kTapNone。
// 首页 kTapHub、麦克风卡 kTapDevice、息屏卡 kTapScreenOff；阅读页另有翻页、暂停与速度循环。
int take_tap();
// 告警页第 n 行被按住 1.5 s(desk.operate 的确认动作);无长按返回 -1。
int take_hold();
// 时间基准:Mac dashboard 包或 SNTP 校时后调用;工作台首页顶部时钟按
// "基准本地秒 + 单调增量"推进,主循环约 1 Hz 重画即可秒级刷新。
void set_clock(uint32_t epoch, int tz_offset_minutes);

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
// 纵向脏带;CONFIG_YAHADESK_SPECTRUM_BARS 时为 lv_chart 32 根弹簧色柱。持
// lvgl_port_lock 同步 lv_refr_now,供主循环按 24-30 fps 目标节奏调用(真机 24.3 fps,
// 遥测见日志)。why 不用 lv_chart 折线/为何分批 dispatch 见 board_screen.h 与实现注释。
void draw_spectrum(const float* bars, int count);
void set_brightness(uint8_t percent);
// 息屏:关面板显示 + 亮度归零(AMOLED 黑屏几乎不耗电);触摸芯片照常工作。
void set_display(bool on);
uint32_t touch_idle_ms();  // 距最近一次触摸的毫秒数(LVGL 活动计时),息屏时用来判断唤醒
uint32_t spectrum_frame_count();  // 遥测:频谱累计渲染帧数
void request_screen_dump();       // 回传一帧屏幕(经日志口,Mac 侧重建成图)
void render_timing(int32_t& frame_us, int32_t& dma_us);  // 遥测:最近一帧耗时/其中传屏耗时

}  // namespace board
