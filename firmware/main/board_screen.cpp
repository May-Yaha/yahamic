// board_screen.cpp — LVGL 9.2 静态屏层(替代旧手写 canvas 自绘的 draw/
// draw_dashboard 路径)。8 个状态各一个 LVGL screen 对象,lv_screen_load 切换;
// 文本用 LVGL 字体管线生成的子集字体(tools/make_fonts.sh):
//   font_zh_title(48px,13 中文短语 + ASCII)  标题行
//   font_zh_sub(28px,同子集)                 副题/日期/状态行/环名
//   font_clock_num(72px,仅数字+冒号)         Dashboard 大钟
// 旧 "#key" 短语语法保留在 board.h 的 Screen 契约里(main.cpp 不改),这里查
// key→中文映射表渲染;无 # 前缀的 ASCII 文本直接显示。
// 版式(圆屏,四角与上下边缘会被切掉):状态屏 = 「彩色圆点 + 白色标题」一行
// + 副题,文字组居中;状态行统一在 y=kStatusY,整行落在圆内。
// Live 屏:默认 24 根居中对称的电平条 + 计时(Kconfig CONFIG_YAHAMIC_SPECTRUM_BARS),
// 或三条包络曲线画布(WAVES,见 make_spectrum_chart);数值层与渲染节奏在
// board.cpp 的 draw_spectrum。

#include "board_screen.h"

#include <cstdio>
#include <cstring>
#include <string>

#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_lvgl_port.h"
#include "lvgl.h"

// 字体由 generated/fonts/*.c 定义(lv_font_conv 生成)。
LV_FONT_DECLARE(font_zh_title);
LV_FONT_DECLARE(font_zh_sub);
LV_FONT_DECLARE(font_clock_num);

namespace board::screens {
namespace {

constexpr int kWidth = 480;
constexpr int kHeight = 480;

// 颜色:macOS 深色模式的系统色(与 Mac 端讲话浮层一致),比纯 RGB 原色柔和。
const lv_color_t kBlack = lv_color_hex(0x000000);
const lv_color_t kWhite = lv_color_hex(0xFFFFFF);
const lv_color_t kSoft = lv_color_hex(0xE5E5EA);    // 副题/电平条/计时
const lv_color_t kRed = lv_color_hex(0xFF453A);     // 送声
const lv_color_t kBlue = lv_color_hex(0x0A84FF);    // 寻找 Mac
const lv_color_t kOrange = lv_color_hex(0xFF9F0A);  // 蓝牙配对
const lv_color_t kGray = lv_color_hex(0x8E8E93);    // 静音圆点、状态行
const lv_color_t kTrack = lv_color_hex(0x1C1C1E);   // 环的暗槽
const lv_color_t kInvalid = lv_color_hex(0x48484A); // 无效环灰显

constexpr int kStatusY = 400;  // 状态行 y:y=434 处圆的弦长约 280px,整行不被切

// Dashboard 四环主色(任务书:CPU 青/MEM 蓝/MOUSE 紫/KEYB 粉,底弧暗灰):
const lv_color_t kArcColors[4] = {
    lv_color_hex(0x00FFFF),  // CPU 青(旧 kDashArcMid 0x07FF)
    lv_color_hex(0x3A3CFF),  // MEM 蓝
    lv_color_hex(0xA020F0),  // MOUSE 紫
    lv_color_hex(0xFF69B6),  // KEYB 粉(旧频谱第三波 0xFB56)
};
constexpr const char* kArcNames[4] = {"CPU", "MEM", "MOUSE", "KEYB"};

// —— "#key" 中文短语映射表 ——
// 唯一真源:tools/make_fonts.sh 顶部注释(逐字抄自旧 tools/gen_text.swift 的
// Phrase 表);字体子集的字形清单也由这份表导出,改文案要同步重跑 make_fonts.sh。
struct Phrase {
  const char* key;
  const char* text;
};
constexpr Phrase kPhrases[] = {
    {"boot", "雅哈麦克风"},
    {"muted", "已静音"},
    {"searching", "寻找 Mac 中"},
    {"on_air_s", "讲话中"},
    {"hold_key", "按住讲话键"},
    {"run_app", "请在 Mac 上运行 Yaha 家居"},
    {"firmware", "固件"},
};

// 解析一行文本:以 '#' 开头 → '#' 到首个空格之间是 key,查表换成中文,空格
// 之后的内容(SSID/密码/版本号等 ASCII)原样拼接;查不到 key 时退化为显示 key
// 本身(便于发现遗漏,同旧 stub 语义)。无 '#' 前缀的文本原样返回。
std::string resolve_line(const std::string& s) {
  if (s.empty() || s[0] != '#') return s;
  const size_t sp = s.find(' ');
  const std::string key = s.substr(1, sp == std::string::npos ? std::string::npos : sp - 1);
  const std::string suffix = sp == std::string::npos ? "" : s.substr(sp);  // 含前导空格
  for (const Phrase& p : kPhrases) {
    if (key == p.key) return std::string(p.text) + suffix;
  }
  return key + suffix;  // 未知 key:露出原文,真机一眼可见
}

// —— 普通状态屏(boot/pairing/searching/muted/live)——
// 结构:标题行(状态色圆点 + font_zh_title 白字,flex 行整体水平居中)+ 两行
// 副题 + 底部状态行(font_zh_sub,灰)。不画顶部色条与分隔线:圆屏上会被切成
// 弧形碎片,状态色只留在圆点上。
struct StatusScreen {
  lv_obj_t* root = nullptr;
  lv_obj_t* dot = nullptr;     // 状态色圆点
  lv_obj_t* title = nullptr;   // line1
  lv_obj_t* line2 = nullptr;
  lv_obj_t* line3 = nullptr;
  lv_obj_t* status = nullptr;  // 底部状态行
};

lv_obj_t* make_label(lv_obj_t* parent, int y, const lv_font_t* font, lv_color_t color) {
  lv_obj_t* label = lv_label_create(parent);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, color, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(label, kWidth);
  lv_obj_set_pos(label, 0, y);
  lv_label_set_text(label, "");
  return label;
}

// 无边框、无内边距、不可点的纯色块(圆点、电平条、透明容器共用)。
lv_obj_t* make_box(lv_obj_t* parent) {
  lv_obj_t* box = lv_obj_create(parent);
  lv_obj_set_style_border_width(box, 0, 0);
  lv_obj_set_style_pad_all(box, 0, 0);
  lv_obj_set_style_shadow_width(box, 0, 0);
  lv_obj_clear_flag(box, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(box, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(box, LV_SCROLLBAR_MODE_OFF);
  return box;
}

lv_obj_t* make_screen() {
  lv_obj_t* scr = lv_obj_create(nullptr);
  lv_obj_set_style_bg_color(scr, kBlack, 0);
  lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(scr, 0, 0);
  lv_obj_set_style_pad_all(scr, 0, 0);
  // 设备屏无触摸交互:关滚动与滚动条——否则任一子对象贴边/越界,LVGL 就在右缘
  // 画一条滚动条指示器(真机截图实测:右边缘一条贯穿竖线)。
  lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
  return scr;
}

void add_status_row(lv_obj_t* scr, lv_obj_t** status_out) {
  *status_out = make_label(scr, kStatusY, &font_zh_sub, kGray);
}

// line2_font:Pairing 的配对数字与 Live 的计时用 72px 数字字体,其余用副题字体。
StatusScreen make_status_screen(int title_y, int line2_y, int line3_y,
                                const lv_font_t* line2_font = &font_zh_sub) {
  StatusScreen s;
  s.root = make_screen();
  // 标题行:宽高随内容,对齐方式存在样式里,文字变长变短都自动保持居中。
  lv_obj_t* row = make_box(s.root);
  lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
  lv_obj_set_size(row, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(row, 16, 0);
  lv_obj_align(row, LV_ALIGN_TOP_MID, 0, title_y);
  s.dot = make_box(row);
  lv_obj_set_size(s.dot, 18, 18);
  lv_obj_set_style_radius(s.dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(s.dot, LV_OPA_COVER, 0);
  s.title = lv_label_create(row);
  lv_obj_set_style_text_font(s.title, &font_zh_title, 0);
  lv_obj_set_style_text_color(s.title, kWhite, 0);
  lv_label_set_text(s.title, "");
  s.line2 = make_label(s.root, line2_y, line2_font, kSoft);
  if (line2_font == &font_clock_num) lv_obj_set_style_text_letter_space(s.line2, 6, 0);
  s.line3 = make_label(s.root, line3_y, &font_zh_sub, kGray);
  add_status_row(s.root, &s.status);
  return s;
}

// 文字没变就不碰标签:lv_label_set_text 即使同文也会重排并无效化,Live 每秒
// 一次的计时重绘会连带标题行一起重画。
void set_text(lv_obj_t* label, const char* text) {
  if (strcmp(lv_label_get_text(label), text) != 0) lv_label_set_text(label, text);
}

void set_line(lv_obj_t* label, const std::string& text) {
  set_text(label, text.c_str());
  if (text.empty()) {
    lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_remove_flag(label, LV_OBJ_FLAG_HIDDEN);
  }
}

// 6 个状态的 screen 对象(boot/dash/muted/searching/pairing/live)。
StatusScreen s_boot;
StatusScreen s_pairing;
StatusScreen s_searching;
StatusScreen s_live;
StatusScreen s_muted;

// —— Live 屏频谱 ——
#if CONFIG_YAHAMIC_SPECTRUM_BARS
lv_obj_t* live_bars[kSpectrumPoints] = {};  // 居中的圆角电平条
int32_t live_bar_h[kSpectrumPoints] = {};   // 上次设的高度,没变就不动对象
constexpr int kBarW = 10;      // 条宽
constexpr int kBarStep = 16;   // 条距(条宽 + 6px 空隙),24 根共 378px
constexpr int kBarMinH = 10;   // 无声时的高度 = 条宽,即一颗圆点
#endif
lv_obj_t* live_canvas = nullptr;  // WAVES 模式:lv_canvas(PSRAM)

// Live 屏频谱。BARS 模式:24 个圆角 lv_obj,以频谱区中线上下对称伸缩
// (lv_chart 的柱子只能从底部长,做不出居中);WAVES 模式用 lv_canvas——why 见
// board_screen.h spectrum_canvas 注释(lv_chart 折线在 partial 模式下每分块重分发
// 720 段,真机 139 ms/帧)。
void make_spectrum_chart() {
  constexpr int h = kSpectrumY1 - kSpectrumY0;
#if CONFIG_YAHAMIC_SPECTRUM_BARS
  constexpr int x0 = (kWidth - (kSpectrumPoints - 1) * kBarStep - kBarW) / 2;
  for (int i = 0; i < kSpectrumPoints; ++i) {
    lv_obj_t* bar = make_box(s_live.root);
    lv_obj_set_style_radius(bar, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(bar, kSoft, 0);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
    lv_obj_set_size(bar, kBarW, kBarMinH);
    lv_obj_set_pos(bar, x0 + i * kBarStep, kSpectrumY0 + (h - kBarMinH) / 2);
    live_bars[i] = bar;
    live_bar_h[i] = kBarMinH;
  }
#else
  // 画布缓冲 480×h RGB565,放 PSRAM(内部 RAM 只剩 ~75 KB),按 LV_DRAW_BUF_ALIGN
  // 对齐——LVGL 合成时把它当普通图像,从 PSRAM 读一次拷进内部 partial 缓冲再 DMA,
  // 不走 PSRAM 直 DMA(S3 的 GPSPI 对非缓存行对齐的 PSRAM 区会退回拷临时缓冲,见
  // board.cpp init_screen 注释)。
  constexpr int w = kWidth;
  const size_t bytes = LV_CANVAS_BUF_SIZE(w, h, 16, LV_DRAW_BUF_STRIDE_ALIGN);
  void* buf = heap_caps_aligned_calloc(LV_DRAW_BUF_ALIGN, 1, bytes, MALLOC_CAP_SPIRAM);
  assert(buf);
  live_canvas = lv_canvas_create(s_live.root);
  lv_canvas_set_buffer(live_canvas, buf, w, h, LV_COLOR_FORMAT_RGB565);
  lv_obj_set_pos(live_canvas, 0, kSpectrumY0);
  lv_obj_clear_flag(live_canvas, LV_OBJ_FLAG_CLICKABLE);
  lv_canvas_fill_bg(live_canvas, lv_color_black(), LV_OPA_COVER);
#endif
}

// —— Dashboard 屏 ——
// 布局:顶部 HH:MM 大钟(font_clock_num)+ 日期小字(font_zh_sub 灰);中部
// 2x2 lv_arc(几何见 make_dashboard);底部状态行同其他屏。
lv_obj_t* dash_root = nullptr;
lv_obj_t* dash_clock = nullptr;
lv_obj_t* dash_date = nullptr;
lv_obj_t* dash_arcs[4] = {nullptr, nullptr, nullptr, nullptr};
lv_obj_t* dash_arc_vals[4] = {nullptr, nullptr, nullptr, nullptr};  // 环中心百分数
lv_obj_t* dash_status_label = nullptr;

// 最近一次 Mac 下发的仪表盘数据与时间基准(why 每包重置见 set_dashboard)。
DashboardData dash_data;
int64_t dash_base_local_s = 0;  // 基准本地秒 = epoch + tz*60
int64_t dash_base_us = 0;       // 基准单调微秒(esp_timer_get_time)
bool dash_has_base = false;     // 收到过至少一包数据
std::string dash_status;        // 底部状态行(draw 时从 Screen 带入)

constexpr const char* kDashMonths[12] = {"JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                         "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"};
constexpr const char* kDashWeekdays[7] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};

// 本地秒 → 公历年月日(Howard Hinnant 的 civil_from_days 算法,纯整数运算,
// 不依赖时区数据库:换算的是已经加过时区偏移的本地秒)。自旧手写实现原样保留。
void civil_from_days(int64_t z, int& y, int& m, int& d) {
  z += 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = unsigned(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int yy = int(yoe) + int(era) * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  d = int(doy - (153 * mp + 2) / 5 + 1);
  m = int(mp < 10 ? mp + 3 : mp - 9);
  y = yy + (m <= 2);
}

void make_dashboard() {
  dash_root = make_screen();
  dash_clock = make_label(dash_root, 36, &font_clock_num, kWhite);
  lv_label_set_text(dash_clock, "--:--");
  dash_date = make_label(dash_root, 98, &font_zh_sub, kGray);

  // 四环收在圆屏内切区里(最远点离屏心约 200px < 240,不被圆边切):环名用小号
  // Montserrat 放进环内、百分数下方,不再占环上方一行,省出的空间给环径。
  constexpr int kRingCx[2] = {165, 315};
  constexpr int kRingCy[2] = {196, 330};
  constexpr int kRingSize = 120;
  for (int i = 0; i < 4; ++i) {
    const int cx = kRingCx[i % 2];
    const int cy = kRingCy[i / 2];
    // lv_arc:270° 弧,缺口朝下居中(LVGL 默认 135°..45°,与旧手绘弧同向);
    // 无旋钮、不可点;MAIN = 底弧(暗灰),INDICATOR = 进度(主色)。
    lv_obj_t* arc = lv_arc_create(dash_root);
    lv_obj_set_size(arc, kRingSize, kRingSize);
    lv_obj_set_pos(arc, cx - kRingSize / 2, cy - kRingSize / 2);
    lv_arc_set_range(arc, 0, 100);
    lv_arc_set_value(arc, 0);
    lv_obj_remove_style(arc, nullptr, LV_PART_KNOB);
    lv_obj_clear_flag(arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(arc, 10, LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, 10, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(arc, kInvalid, LV_PART_MAIN);       // 初始无效:整环灰显
    lv_obj_set_style_arc_color(arc, kInvalid, LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(arc, true, LV_PART_MAIN);
    lv_obj_set_style_arc_rounded(arc, true, LV_PART_INDICATOR);
    dash_arcs[i] = arc;

    // 环中心百分数(无效 "--",随环一起灰显)。
    lv_obj_t* val = lv_label_create(arc);
    lv_obj_set_style_text_font(val, &font_zh_sub, 0);
    lv_obj_set_style_text_color(val, kGray, 0);
    lv_label_set_text(val, "--");
    lv_obj_align(val, LV_ALIGN_CENTER, 0, -8);
    dash_arc_vals[i] = val;

    lv_obj_t* name = lv_label_create(arc);
    lv_obj_set_style_text_font(name, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(name, kGray, 0);
    lv_label_set_text(name, kArcNames[i]);
    lv_obj_align(name, LV_ALIGN_CENTER, 0, 18);
  }
  add_status_row(dash_root, &dash_status_label);
}

// 更新一只环:有效值(0..100)按主色显示百分数;无效值(>100,Mac 侧发 255)
// 整环灰显、中心 "--"(逻辑自旧 draw_dash_ring/compose_dashboard 原样保留)。
void set_ring(int i, uint8_t pct) {
  static int shown[4] = {-1, -1, -1, -1};  // 改样式会整环重画,值没变就不动
  if (shown[i] == pct) return;
  shown[i] = pct;
  const bool ok = pct <= 100;
  lv_arc_set_value(dash_arcs[i], ok ? int(pct) : 0);
  lv_obj_set_style_arc_color(dash_arcs[i], ok ? kTrack : kInvalid, LV_PART_MAIN);
  lv_obj_set_style_arc_color(dash_arcs[i], ok ? kArcColors[i] : kInvalid, LV_PART_INDICATOR);
  char val_buf[8];
  if (ok) {
    snprintf(val_buf, sizeof val_buf, "%d%%", int(pct));
  } else {
    memcpy(val_buf, "--", 3);
  }
  set_text(dash_arc_vals[i], val_buf);
  lv_obj_set_style_text_color(dash_arc_vals[i], ok ? kWhite : kGray, 0);
}

// 刷新 Dashboard 的时间相关控件(大钟/日期)与四环。时间基准逻辑自旧
// compose_dashboard(L442-470)原样保留:显示时间 = 基准本地秒 + (当前单调
// 微秒 - 基准单调微秒)/1e6;基准随每包重置,无累计分钟漂移(why 见
// set_dashboard 注释)。
void refresh_dashboard() {
  int64_t local_s = dash_base_local_s;
  if (dash_has_base)
    local_s += (esp_timer_get_time() - dash_base_us) / 1000000;
  char clock_buf[8];
  if (dash_has_base) {
    int hh = int((local_s / 3600) % 24);
    int mm = int((local_s / 60) % 60);
    snprintf(clock_buf, sizeof clock_buf, "%02d:%02d", hh, mm);
  } else {
    memcpy(clock_buf, "--:--", 6);  // 尚未收到任何一包:时钟占位
  }
  set_text(dash_clock, clock_buf);
  // 日期小字(如 "NOV 25 TUE"):本地日期由本地秒 ÷ 86400 经 civil 算法换算,
  // 星期由 1970-01-01(周四)推。
  if (dash_has_base) {
    int64_t days = local_s / 86400;
    int y, m, d;
    civil_from_days(days, y, m, d);
    int wd = int(((days % 7) + 4 + 7) % 7);  // 0=周日;1970-01-01 是周四
    char date_buf[16];
    snprintf(date_buf, sizeof date_buf, "%s %d %s", kDashMonths[m - 1], d, kDashWeekdays[wd]);
    set_text(dash_date, date_buf);
  } else {
    set_text(dash_date, "");
  }
  const uint8_t values[4] = {dash_data.cpu, dash_data.mem,
                             dash_data.mouse_batt, dash_data.kb_batt};
  for (int i = 0; i < 4; ++i) set_ring(i, values[i]);
  set_text(dash_status_label, dash_status.c_str());
}

lv_color_t state_color(Screen::State state) {
  switch (state) {
    case Screen::State::Boot: return kWhite;
    case Screen::State::Pairing: return kOrange;
    case Screen::State::Searching: return kBlue;
    case Screen::State::Live: return kRed;     // 与 Mac 顶栏/浮层的"送声"红一致
    case Screen::State::Muted: return kGray;
    case Screen::State::Dashboard: return kWhite;
  }
  return kWhite;
}

StatusScreen* pick(Screen::State state) {
  switch (state) {
    case Screen::State::Boot: return &s_boot;
    case Screen::State::Pairing: return &s_pairing;
    case Screen::State::Searching: return &s_searching;
    case Screen::State::Live: return &s_live;
    case Screen::State::Muted: return &s_muted;
    case Screen::State::Dashboard: return nullptr;  // 走 Dashboard 独立路径
  }
  return &s_boot;
}

// 已是当前屏就不再 load:lv_screen_load 每次都整屏无效化,主循环每次状态行
// 变化都调 draw,会让整屏重刷(讲话中标题随之闪烁)。
void show(lv_obj_t* scr) {
  if (lv_screen_active() != scr) lv_screen_load(scr);
}

bool ready = false;

}  // namespace

void init() {
  if (!lvgl_port_lock(0)) return;
  if (!ready) {
    // 文字组以 y≈225 为中心(状态行在 kStatusY,组心略高于屏心)。
    // Live:标题在频谱区上方,line2 是频谱区下方的 mm:ss 计时;
    // Pairing:line2 是 6 位配对数字。两者都用 72px 数字字体。
    s_live = make_status_screen(92, kSpectrumY1 + 8, 0, &font_clock_num);
    s_muted = make_status_screen(170, 246, 290);
    s_searching = make_status_screen(170, 246, 290);
    s_boot = make_status_screen(170, 246, 290);
    s_pairing = make_status_screen(124, 200, 280, &font_clock_num);
    make_dashboard();
    make_spectrum_chart();  // Live 屏的电平条/曲线画布(由 Kconfig 定)
    ready = true;
  }
  lvgl_port_unlock();
}

void draw(const Screen& s) {
  if (!ready || !lvgl_port_lock(0)) return;
  if (s.state == Screen::State::Dashboard) {
    // Dashboard 屏:布局与数据源不同,走独立路径;底部状态行从 Screen 带入。
    dash_status = s.status;
    refresh_dashboard();
    show(dash_root);
    lvgl_port_unlock();
    return;
  }
  StatusScreen* t = pick(s.state);
  const lv_color_t dot = state_color(s.state);
  if (!lv_color_eq(lv_obj_get_style_bg_color(t->dot, 0), dot)) lv_obj_set_style_bg_color(t->dot, dot, 0);
  set_text(t->title, resolve_line(s.line1).c_str());
  set_line(t->line2, resolve_line(s.line2));
  set_line(t->line3, resolve_line(s.line3));
  set_text(t->status, s.status.c_str());
  show(t->root);
  lvgl_port_unlock();
}

void set_dashboard(const DashboardData& d) {
  dash_data = d;
  // why 每包重置基准:固件不跑日历/NTP 守护,显示时间完全由"基准本地秒 +
  // esp_timer 单调微秒增量"合成;基准随每包重算,固件侧没有任何运行中的
  // 日历累加器,单包的时间误差不会跨包累计(无累计分钟漂移);单调时钟只
  // 提供增量,不受系统校时影响。
  dash_base_local_s = int64_t(d.epoch) + int64_t(d.tz_offset_minutes) * 60;
  dash_base_us = esp_timer_get_time();
  dash_has_base = true;
  // why 时区只做加法:固件不维护时区数据库与 DST 规则,Mac 每包下发的
  // tz_offset_minutes 已包含当时的 DST 状态,夏令时切换由下一包带的新偏移
  // 自动纠正,设备端永远只是一次加法。
}

void draw_dashboard() {
  if (!ready || !lvgl_port_lock(0)) return;
  refresh_dashboard();
  lvgl_port_unlock();
}

lv_obj_t* spectrum_canvas() { return live_canvas; }

#if CONFIG_YAHAMIC_SPECTRUM_BARS
bool set_bars(const int32_t* values) {
  if (!ready) return false;
  constexpr int kMaxH = kSpectrumY1 - kSpectrumY0;
  constexpr int kMid = kSpectrumY0 + kMaxH / 2;
  bool changed = false;
  for (int i = 0; i < kSpectrumPoints; ++i) {
    const int32_t h = kBarMinH + values[i] * (kMaxH - kBarMinH) / 1000;
    if (h == live_bar_h[i]) continue;
    live_bar_h[i] = h;
    lv_obj_set_height(live_bars[i], h);  // set_* 自己无效化新旧两块区域
    lv_obj_set_y(live_bars[i], kMid - h / 2);
    changed = true;
  }
  return changed;
}
#endif

}  // namespace board::screens
