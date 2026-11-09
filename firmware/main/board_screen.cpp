// board_screen.cpp — LVGL 9.2 静态屏层(替代旧手写 canvas 自绘的 draw 路径)。
// 状态屏与工作台各页各一个 LVGL screen 对象,lv_screen_load 切换;
// 文本用 LVGL 字体管线生成的子集字体(tools/make_fonts.sh):
//   font_zh_title(48px,13 中文短语 + ASCII)  标题行
//   font_zh_sub(28px,同子集 + GB2312 一级字)  副题/工作台全部文字/云端卡片
//   font_zh_marquee(32px,与 font_zh_sub 同字集) 仅通知卡跑马灯正文
//   font_clock_num(72px,仅数字+冒号)         配对码、讲话计时与首页时钟
//   font_zh_label(18px,极小子集)             全部屏的底部状态行、首页环名
// 旧 "#key" 短语语法保留在 board.h 的 Screen 契约里(main.cpp 不改),这里查
// key→中文映射表渲染;无 # 前缀的 ASCII 文本直接显示。
// 版式(480×480 方屏):状态屏 = 「彩色圆点 + 白色标题」一行
// + 副题,文字组居中;底部状态行全部屏统一(make_footer),工作台与卡片另有独立布局。
// Live 屏:默认 24 根居中对称的电平条 + 计时(Kconfig CONFIG_YAHADESK_SPECTRUM_BARS),
// 或三条包络曲线画布(WAVES,见 make_spectrum_chart);数值层与渲染节奏在
// board.cpp 的 draw_spectrum。

#include "board_screen.h"
#include "memory_diagnostics.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_lvgl_port.h"
#include "lvgl.h"

// 字体由 generated/fonts/*.c 定义(lv_font_conv 生成)。
LV_FONT_DECLARE(font_zh_title);
LV_FONT_DECLARE(font_zh_sub);
LV_FONT_DECLARE(font_zh_marquee);  // 通知卡跑马灯正文,比 font_zh_sub 大一号
LV_FONT_DECLARE(font_clock_num);
LV_FONT_DECLARE(font_zh_label);

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
const lv_color_t kTrack = lv_color_hex(0x1C1C1E);   // 工作台格与卡片底色
const lv_color_t kPressed = lv_color_hex(0x48484A); // 工作台格按下态
const lv_color_t kGreen = lv_color_hex(0x30D158);   // 工作台正常
const lv_color_t kLine = lv_color_hex(0x2C2C2E);    // 分组列表分隔线
const lv_color_t kDim = lv_color_hex(0x3A3A3C);     // 趋势历史柱

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
    {"searching", "寻找电脑"},
    {"pairing", "蓝牙配对"},
    {"on_air_s", "讲话中"},
    {"hold_key", "按住讲话键"},
    {"run_app", "请在电脑上运行 Yaha Desk"},
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
// 副题 + 底部状态行(与工作台同一 make_footer)。状态色只留在圆点上。
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
  // 触摸只用点击、不滚动:关滚动与滚动条——否则任一子对象贴边/越界,LVGL 就在右缘
  // 画一条滚动条指示器(真机截图实测:右边缘一条贯穿竖线)。
  lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
  return scr;
}

// 全部屏的底部状态行:18px 灰字,同一位置。
lv_obj_t* make_footer(lv_obj_t* parent) {
  lv_obj_t* label = make_label(parent, 448, &font_zh_label, kGray);
  lv_obj_set_width(label, 424);
  lv_obj_set_x(label, 28);
  return label;
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
  s.status = make_footer(s.root);
  return s;
}

// 文字没变就不碰标签:lv_label_set_text 即使同文也会重排并无效化,Live 每秒
// 一次的计时重绘会连带标题行一起重画。
void set_text(lv_obj_t* label, const char* text) {
  if (strcmp(lv_label_get_text(label), text) != 0) lv_label_set_text(label, text);
}

// 同理:颜色没变就不改样式。
void set_bg(lv_obj_t* obj, lv_color_t c) {
  if (!lv_color_eq(lv_obj_get_style_bg_color(obj, 0), c)) lv_obj_set_style_bg_color(obj, c, 0);
}
void set_color(lv_obj_t* label, lv_color_t c) {
  if (!lv_color_eq(lv_obj_get_style_text_color(label, 0), c)) lv_obj_set_style_text_color(label, c, 0);
}

void set_line(lv_obj_t* label, const std::string& text) {
  set_text(label, text.c_str());
  lv_obj_update_flag(label, LV_OBJ_FLAG_HIDDEN, text.empty());
}

// 状态屏对象(boot/muted/searching/pairing/live;工作台与 card 各自独立见下文)。
StatusScreen s_boot;
StatusScreen s_pairing;
StatusScreen s_searching;
StatusScreen s_live;
StatusScreen s_muted;

// —— Live 屏频谱 ——
#if CONFIG_YAHADESK_SPECTRUM_BARS
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
#if CONFIG_YAHADESK_SPECTRUM_BARS
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

// 已是当前屏就不再 load:lv_screen_load 每次都整屏无效化,主循环每次状态行
// 变化都调 draw,会让整屏重刷(讲话中标题随之闪烁)。
void show(lv_obj_t* scr) {
  if (lv_screen_active() != scr) lv_screen_load(scr);
}

// —— 工作台 ——
// 时间基准:Mac dashboard 包或 SNTP 校时(why 每次重置见 set_clock)。
int64_t base_local_s = 0;  // 基准本地秒 = epoch + tz*60
int64_t base_us = 0;       // 基准单调微秒(esp_timer_get_time)
bool has_base = false;

constexpr const char* kWeekdays[7] = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"};

// 本地秒 → 公历年月日(Howard Hinnant 的 civil_from_days 算法,纯整数运算,
// 不依赖时区数据库:换算的是已经加过时区偏移的本地秒)。
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

// 点击目标:LVGL 任务里的回调写,主循环 take_tap 取走;只留最近一次。
// SHORT_CLICKED:长按后松手不再算一次点击(LVGL 9.2 的 CLICKED 长按后照发)。
std::atomic<int> tapped{display::kTapNone};
void on_click(lv_event_t* e) { tapped.store(int(intptr_t(lv_event_get_user_data(e)))); }
void clickable(lv_obj_t* obj, int target) {
  lv_obj_add_flag(obj, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_event_cb(obj, on_click, LV_EVENT_SHORT_CLICKED, reinterpret_cast<void*>(intptr_t(target)));
}
// 告警行长按(触摸驱动设 1.5 s):记下行号,主循环 take_hold 取走。
std::atomic<int> held{-1};
void on_hold(lv_event_t* e) { held.store(int(intptr_t(lv_event_get_user_data(e)))); }

lv_color_t tone(const std::string& level) {
  if (level == "ok") return kGreen;
  if (level == "warn") return kOrange;
  if (level == "error") return kRed;
  if (level == "info") return kBlue;
  return kGray;
}
// 摘要文字:正常白字,警告/错误随等级着色,不可用灰字——不看圆点也能扫出异常。
lv_color_t value_color(const std::string& level) { return level == "ok" ? kWhite : tone(level); }

lv_obj_t* make_text(lv_obj_t* parent, int x, int w, lv_color_t color) {
  lv_obj_t* label = make_label(parent, 0, &font_zh_sub, color);
  // Fixed one-line height: LONG_DOT only truncates when the text is taller than the label, so a
  // content-sized label wraps to two lines instead (seen on the first alerts draw).
  lv_obj_set_size(label, w, lv_font_get_line_height(&font_zh_sub));
  lv_obj_align(label, LV_ALIGN_LEFT_MID, x, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, 0);
  lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
  return label;
}

// 一行 = 等级圆点 + 标题 + 摘要;tap >= 0 时整行可点(按下变亮)。
struct RowView {
  lv_obj_t* box = nullptr;
  lv_obj_t* dot = nullptr;
  lv_obj_t* title = nullptr;
  lv_obj_t* text = nullptr;
};
constexpr int kRowX = 28, kRowW = 424, kRowH = 42;
RowView make_row(lv_obj_t* parent, int y, int title_w, int tap) {
  RowView r;
  r.box = make_box(parent);
  lv_obj_set_size(r.box, kRowW, kRowH);
  lv_obj_set_pos(r.box, kRowX, y);
  lv_obj_set_style_radius(r.box, 12, 0);
  lv_obj_set_style_bg_color(r.box, kTrack, 0);
  lv_obj_set_style_bg_opa(r.box, tap >= 0 ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
  if (tap >= 0) {
    lv_obj_set_style_bg_color(r.box, kPressed, LV_STATE_PRESSED);
    clickable(r.box, tap);
  }
  r.dot = make_box(r.box);
  lv_obj_set_size(r.dot, 14, 14);
  lv_obj_set_style_radius(r.dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(r.dot, LV_OPA_COVER, 0);
  lv_obj_align(r.dot, LV_ALIGN_LEFT_MID, 14, 0);
  r.title = make_text(r.box, 38, title_w, kWhite);
  r.text = make_text(r.box, 38 + title_w + 12, kRowW - 38 - title_w - 12 - 14, kSoft);
  return r;
}

void set_row(const RowView& v, const Screen::Row* row) {
  lv_obj_update_flag(v.box, LV_OBJ_FLAG_HIDDEN, !row);
  if (!row) return;
  set_bg(v.dot, tone(row->level));
  set_text(v.title, row->title.c_str());
  set_text(v.text, row->text.c_str());
}

// 多行文本左对齐、按原文定高并以 max_lines 截成 "..."(LONG_DOT 会原地截短文本,
// 先按原文量高,避免短文换长文时按旧高度提前省略)。
void set_wrapped(lv_obj_t* label, const std::string& text, int width, int max_lines) {
  lv_point_t size;
  lv_text_get_size(&size, text.c_str(), &font_zh_sub, 0, 1, width, LV_TEXT_FLAG_NONE);
  lv_obj_set_height(label, LV_MAX(1, LV_MIN(size.y, lv_font_get_line_height(&font_zh_sub) * max_lines + 4)));
  set_line(label, text);
}

lv_obj_t* make_block(lv_obj_t* parent, int y, lv_color_t color) {
  lv_obj_t* label = make_label(parent, y, &font_zh_sub, color);
  lv_obj_set_width(label, kRowW);
  lv_obj_set_x(label, kRowX);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, 0);
  lv_obj_set_style_text_line_space(label, 1, 0);
  lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
  return label;
}

// 圆角 16 的深灰面板(分组列表、详情行底)。
lv_obj_t* make_panel(lv_obj_t* parent, int y) {
  lv_obj_t* panel = make_box(parent);
  lv_obj_set_pos(panel, kRowX, y);
  lv_obj_set_width(panel, kRowW);
  lv_obj_set_style_radius(panel, 16, 0);
  lv_obj_set_style_bg_color(panel, kTrack, 0);
  lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
  return panel;
}

// 首页只突出麦克风；Mac 指标留在设备详情，工作台仅管理员可见。
lv_obj_t* home_root = nullptr;
lv_obj_t* home_clock = nullptr;
lv_obj_t* home_date = nullptr;
lv_obj_t* home_week = nullptr;
lv_obj_t* home_mic_badge = nullptr;
lv_obj_t* home_mic_parts[4] = {};
lv_obj_t* home_mic_title = nullptr;
lv_obj_t* home_mic_state = nullptr;
lv_obj_t* home_status = nullptr;
RowView home_hub;

// Zhi.AI 总览:页标题、告警条(有告警时染色)、云端分区分组列表、状态行;点背景回首页。
constexpr int kAlertY = 66, kListY = 118, kListRowH = 48;
lv_obj_t* overview_root = nullptr;
lv_obj_t* overview_list = nullptr;
lv_obj_t* overview_lines[display::kRows - 1] = {};
lv_obj_t* overview_status = nullptr;
RowView overview_alert;
RowView overview_rows[display::kRows];

// 详情:标题行、摘要、面板里的详情行、近 7 日趋势柱(今天一根用分区等级色)。
constexpr int kTrend = 7, kTrendTop = 324, kTrendBottom = 412;
constexpr int kDetailPadX = 14, kDetailTextW = kRowW - 2 * kDetailPadX;
lv_obj_t* detail_root = nullptr;
lv_obj_t* detail_summary = nullptr;
lv_obj_t* detail_panel = nullptr;
lv_obj_t* detail_lines = nullptr;
lv_obj_t* detail_status = nullptr;
lv_obj_t* detail_bars[kTrend] = {};
RowView detail_head;

// 告警页:最多 8 条(API 截 20 条,屏上只放得下 8 行)。
constexpr int kAlertRows = 8;
lv_obj_t* alerts_root = nullptr;
lv_obj_t* alerts_empty = nullptr;
lv_obj_t* alerts_status = nullptr;
RowView alerts_head;
RowView alerts_rows[kAlertRows];

lv_obj_t* make_page() {
  lv_obj_t* root = make_screen();
  clickable(root, 0);  // 详情/告警/通知页:点任意处翻页或返回(display::Workbench::tap)
  return root;
}

void make_home() {
  home_root = make_screen();
  home_clock = make_label(home_root, 10, &font_clock_num, kWhite);
  lv_obj_set_width(home_clock, 240);
  lv_obj_set_x(home_clock, kRowX);
  lv_obj_set_style_text_align(home_clock, LV_TEXT_ALIGN_LEFT, 0);
  home_date = make_label(home_root, 6, &font_zh_sub, kWhite);
  home_week = make_label(home_root, 38, &font_zh_sub, kGray);
  for (lv_obj_t* label : {home_date, home_week}) {
    lv_obj_set_width(label, 184);
    lv_obj_set_x(label, kRowX + kRowW - 184);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_RIGHT, 0);
  }
  auto card = [](int x, int y, int w, int h, int tap) {
    lv_obj_t* box = make_box(home_root);
    lv_obj_set_pos(box, x, y);
    lv_obj_set_size(box, w, h);
    lv_obj_set_style_radius(box, 22, 0);
    lv_obj_set_style_bg_color(box, kTrack, 0);
    lv_obj_set_style_bg_opa(box, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(box, kPressed, LV_STATE_PRESSED);
    clickable(box, tap);
    return box;
  };
  lv_obj_t* mic = card(kRowX, 96, kRowW, 166, display::kTapDevice);
  // 圆形徽章里用色块拼出话筒(头、U 形托架、立杆、底座),随连接状态着色;不再用"麦"字。
  home_mic_badge = make_box(mic);
  lv_obj_set_size(home_mic_badge, 96, 96);
  lv_obj_align(home_mic_badge, LV_ALIGN_LEFT_MID, 22, 0);
  lv_obj_set_style_radius(home_mic_badge, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(home_mic_badge, LV_OPA_20, 0);
  auto part = [](int w, int h, int y) {
    lv_obj_t* p = make_box(home_mic_badge);
    lv_obj_set_size(p, w, h);
    lv_obj_align(p, LV_ALIGN_TOP_MID, 0, y);
    lv_obj_set_style_radius(p, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(p, LV_OPA_COVER, 0);
    return p;
  };
  home_mic_parts[0] = part(22, 38, 18);  // 话筒头
  home_mic_parts[1] = part(38, 34, 34);  // U 形托架:只画左右下三边的圆角描边
  lv_obj_set_style_bg_opa(home_mic_parts[1], LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(home_mic_parts[1], 4, 0);
  lv_obj_set_style_border_side(home_mic_parts[1],
                               lv_border_side_t(LV_BORDER_SIDE_LEFT | LV_BORDER_SIDE_RIGHT | LV_BORDER_SIDE_BOTTOM), 0);
  home_mic_parts[2] = part(4, 10, 67);   // 立杆
  lv_obj_set_style_radius(home_mic_parts[2], 0, 0);
  home_mic_parts[3] = part(26, 4, 76);   // 底座
  home_mic_title = make_text(mic, 140, 260, kWhite);
  lv_obj_align(home_mic_title, LV_ALIGN_LEFT_MID, 140, -38);
  lv_label_set_text(home_mic_title, "麦克风");
  home_mic_state = make_text(mic, 140, 260, kGreen);
  lv_obj_align(home_mic_state, LV_ALIGN_LEFT_MID, 140, 0);
  lv_obj_t* hint = make_text(mic, 140, 260, kGray);
  lv_obj_align(hint, LV_ALIGN_LEFT_MID, 140, 38);
  lv_label_set_text(hint, "按住 Fn 讲话");
  // 息屏省电:main.cpp 关面板,触摸任意处再点亮。
  lv_obj_t* off = card(kRowX, 278, kRowW, 112, display::kTapScreenOff);
  lv_obj_t* off_title = make_text(off, 24, 260, kWhite);
  lv_obj_align(off_title, LV_ALIGN_LEFT_MID, 24, -18);
  lv_label_set_text(off_title, "息屏");
  lv_obj_t* off_hint = make_text(off, 24, 260, kGray);
  lv_obj_align(off_hint, LV_ALIGN_LEFT_MID, 24, 24);
  lv_label_set_text(off_hint, "省电 · 触摸唤醒");
  home_hub = make_row(home_root, 402, 90, display::kTapHub);
  home_status = make_footer(home_root);
}

void make_workbench() {
  make_home();
  overview_root = make_screen();
  clickable(overview_root, display::kTapHub);  // 背景回首页(display::Workbench::tap)
  lv_obj_t* title = make_block(overview_root, 18, kWhite);
  lv_label_set_text(title, "Zhi.AI 工作台");
  overview_alert = make_row(overview_root, kAlertY, 380, display::kTapAlerts);
  // 分组列表:一块面板 + 透明行(按下才亮)+ 行间细线,比独立胶囊安静。
  overview_list = make_panel(overview_root, kListY);
  for (int i = 0; i < display::kRows; ++i) {
    RowView& r = overview_rows[i];
    r = make_row(overview_list, i * kListRowH, 90, i);
    lv_obj_set_x(r.box, 0);
    lv_obj_set_height(r.box, kListRowH);
    lv_obj_set_style_bg_opa(r.box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_bg_opa(r.box, LV_OPA_COVER, LV_STATE_PRESSED);
    lv_obj_set_style_text_color(r.title, kGray, 0);
  }
  for (int i = 0; i < display::kRows - 1; ++i) {
    overview_lines[i] = make_box(overview_list);
    lv_obj_set_size(overview_lines[i], kRowW - 38, 1);
    lv_obj_set_pos(overview_lines[i], 38, (i + 1) * kListRowH);
    lv_obj_set_style_bg_color(overview_lines[i], kLine, 0);
    lv_obj_set_style_bg_opa(overview_lines[i], LV_OPA_COVER, 0);
  }
  overview_status = make_footer(overview_root);

  detail_root = make_page();
  detail_head = make_row(detail_root, 16, 380, -1);
  detail_summary = make_block(detail_root, 60, kWhite);
  detail_panel = make_panel(detail_root, 104);
  lv_obj_set_style_pad_hor(detail_panel, kDetailPadX, 0);
  lv_obj_set_style_pad_ver(detail_panel, 10, 0);
  detail_lines = make_block(detail_panel, 0, kSoft);
  lv_obj_set_pos(detail_lines, 0, 0);
  lv_obj_set_width(detail_lines, kDetailTextW);
  for (int i = 0; i < kTrend; ++i) {
    detail_bars[i] = make_box(detail_root);
    lv_obj_set_style_radius(detail_bars[i], 6, 0);
    lv_obj_set_style_bg_color(detail_bars[i], kDim, 0);
    lv_obj_set_style_bg_opa(detail_bars[i], LV_OPA_COVER, 0);
    lv_obj_set_size(detail_bars[i], 40, 8);
    lv_obj_set_pos(detail_bars[i], kRowX + 12 + i * 60, kTrendBottom - 8);
  }
  detail_status = make_footer(detail_root);

  alerts_root = make_page();
  alerts_head = make_row(alerts_root, 16, 380, -1);
  // 告警行是实色卡片(按下变亮):短按同整页(返回),长按交给主循环判断是否有可执行操作;
  // 右栏右对齐放"长按重试"等提示(蓝)或发生时间(灰)。
  for (int i = 0; i < kAlertRows; ++i) {
    alerts_rows[i] = make_row(alerts_root, 66 + i * 46, 240, 0);
    lv_obj_set_style_text_align(alerts_rows[i].text, LV_TEXT_ALIGN_RIGHT, 0);
    lv_obj_add_event_cb(alerts_rows[i].box, on_hold, LV_EVENT_LONG_PRESSED, reinterpret_cast<void*>(intptr_t(i)));
  }
  alerts_empty = make_label(alerts_root, 200, &font_zh_sub, kGray);
  alerts_status = make_footer(alerts_root);
}

void refresh_clock() {
  if (!has_base) {
    set_text(home_clock, "");  // 数字字体没有 '-',未校时只写文字
    set_text(home_date, "等待校时");
    set_text(home_week, "");
    return;
  }
  const int64_t local_s = base_local_s + (esp_timer_get_time() - base_us) / 1000000;
  const int64_t days = local_s / 86400;
  int y, m, d;
  civil_from_days(days, y, m, d);
  char clock[8], date[16];
  snprintf(clock, sizeof clock, "%02d:%02d", int(local_s / 3600 % 24), int(local_s / 60 % 60));
  snprintf(date, sizeof date, "%d月%d日", m, d);
  set_text(home_clock, clock);
  set_text(home_date, date);
  set_text(home_week, kWeekdays[(days % 7 + 11) % 7]);  // 1970-01-01 周四
}

// 告警条底色:有告警时整条染成暗红/暗橙,无告警保持深灰。
lv_color_t alert_bg(const std::string& level) {
  if (level == "error") return lv_color_hex(0x3A1715);
  if (level == "warn") return lv_color_hex(0x3A2A12);
  return kTrack;
}

void draw_home(const Screen& s) {
  refresh_clock();
  set_text(home_mic_state, s.line2.c_str());
  const lv_color_t mic = s.tone == "ok" ? kGreen : kOrange;
  set_color(home_mic_state, mic);
  set_bg(home_mic_badge, mic);
  for (lv_obj_t* p : home_mic_parts) set_bg(p, mic);
  lv_obj_set_style_border_color(home_mic_parts[1], mic, 0);
  const bool hub = !s.alert.title.empty();
  const Screen::Row entry{"工作台", s.alert.title, s.alert.level};
  set_row(home_hub, hub ? &entry : nullptr);
  if (hub) {
    set_bg(home_hub.box, alert_bg(s.alert.level));
    set_color(home_hub.text, value_color(s.alert.level));
  }
  set_text(home_status, s.status.c_str());
  show(home_root);
}

void draw_overview(const Screen& s) {
  const bool alert = !s.alert.title.empty();
  set_row(overview_alert, alert ? &s.alert : nullptr);
  if (alert) set_bg(overview_alert.box, alert_bg(s.alert.level));
  const int n = int(LV_MIN(s.rows.size(), size_t(display::kRows)));
  lv_obj_set_y(overview_list, alert ? kListY : kAlertY);
  lv_obj_set_height(overview_list, n * kListRowH);
  lv_obj_update_flag(overview_list, LV_OBJ_FLAG_HIDDEN, n == 0);
  for (int i = 0; i < display::kRows; ++i) {
    const Screen::Row* row = i < n ? &s.rows[i] : nullptr;
    set_row(overview_rows[i], row);
    if (row) set_color(overview_rows[i].text, value_color(row->level));
  }
  for (int i = 0; i < display::kRows - 1; ++i) lv_obj_update_flag(overview_lines[i], LV_OBJ_FLAG_HIDDEN, i + 1 >= n);
  set_text(overview_status, s.status.c_str());
  show(overview_root);
}

void draw_detail(const Screen& s) {
  const Screen::Row head{s.line1, "", s.tone};
  set_row(detail_head, &head);
  set_wrapped(detail_summary, s.line2, kRowW, 1);
  set_color(detail_summary, value_color(s.tone));
  std::string lines;
  for (const auto& r : s.rows) lines += (lines.empty() ? "" : "\n") + r.title;
  set_wrapped(detail_lines, lines, kDetailTextW, s.trend.empty() ? 8 : 5);
  // 显式定高:LV_SIZE_CONTENT 不算隐藏子项,空→单行切换时面板会停在 20 px。
  lv_obj_set_height(detail_panel, lv_obj_get_style_height(detail_lines, 0) + 20);
  lv_obj_update_flag(detail_panel, LV_OBJ_FLAG_HIDDEN, lines.empty());
  int64_t top = 1;
  for (int64_t v : s.trend) top = LV_MAX(top, v);
  for (int i = 0; i < kTrend; ++i) {
    if (size_t(i) >= s.trend.size()) {
      lv_obj_add_flag(detail_bars[i], LV_OBJ_FLAG_HIDDEN);
      continue;
    }
    const int h = 8 + int(LV_MAX(int64_t(0), s.trend[i]) * (kTrendBottom - kTrendTop - 8) / top);
    lv_obj_remove_flag(detail_bars[i], LV_OBJ_FLAG_HIDDEN);
    set_bg(detail_bars[i], size_t(i) + 1 == s.trend.size() ? tone(s.tone) : kDim);
    if (lv_obj_get_height(detail_bars[i]) != h) {
      lv_obj_set_height(detail_bars[i], h);
      lv_obj_set_y(detail_bars[i], kTrendBottom - h);
    }
  }
  set_text(detail_status, s.status.c_str());
  show(detail_root);
}

void draw_alerts(const Screen& s) {
  const Screen::Row head{s.line1, "", s.tone};
  set_row(alerts_head, &head);
  for (int i = 0; i < kAlertRows; ++i) {
    const Screen::Row* row = size_t(i) < s.rows.size() ? &s.rows[i] : nullptr;
    set_row(alerts_rows[i], row);
    // 右栏是 display::hold_label 的"长按…"提示或 HH:MM 时间。
    if (row) set_color(alerts_rows[i].text, row->text.rfind("长按", 0) == 0 ? kBlue : kGray);
  }
  set_line(alerts_empty, s.line2);
  set_text(alerts_status, s.status.c_str());
  show(alerts_root);
}

// —— 卡片屏(云端下发的 AI 日报、agent 消息)——
// 内容阅读页:来源 + 最多两行标题 + 单行跑马灯；底部为图标化翻页、速度、暂停与结束。
// 点卡片其余处回首页。字体是含 GB2312 一级字的 font_zh_sub,
// 正文用同字集放大一号的 font_zh_marquee;库外字显示为空。
lv_obj_t* card_root = nullptr;
lv_obj_t* card_title = nullptr;
lv_obj_t* card_body = nullptr;
lv_obj_t* card_source = nullptr;
lv_obj_t* card_speed = nullptr;
lv_obj_t* card_pause = nullptr;
lv_obj_t* card_status = nullptr;
constexpr int kCardW = 424;
constexpr int kCardPadding = 24;
constexpr int kCardTextW = kCardW - 2 * kCardPadding;
constexpr int kCardButtonsY = 380;
// 慢/中/快 每秒像素(跑马灯中文一字 32 px,约 2.5/4/6 字每秒),真机按阅读速度调。
constexpr uint32_t kMarqueePxPerSec[display::kSpeeds] = {80, 128, 192};

lv_obj_t* make_button(lv_obj_t* parent, int x, int w, const char* text, int tap) {
  lv_obj_t* b = make_box(parent);
  lv_obj_set_size(b, w, 48);
  lv_obj_set_pos(b, x, kCardButtonsY);
  lv_obj_set_style_radius(b, 12, 0);
  lv_obj_set_style_bg_color(b, kTrack, 0);
  lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(b, kPressed, LV_STATE_PRESSED);
  clickable(b, tap);
  lv_obj_t* label = lv_label_create(b);
  lv_obj_set_style_text_font(label, &font_zh_sub, 0);
  lv_obj_set_style_text_color(label, kWhite, 0);
  lv_label_set_text(label, text);
  lv_obj_center(label);
  return b;
}

void make_card() {
  const int line_h = lv_font_get_line_height(&font_zh_sub);
  card_root = make_page();
  lv_obj_t* panel = make_box(card_root);
  lv_obj_set_size(panel, kCardW, LV_SIZE_CONTENT);
  lv_obj_set_style_radius(panel, 26, 0);
  lv_obj_set_style_bg_color(panel, kTrack, 0);
  lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
  lv_obj_set_style_pad_all(panel, kCardPadding, 0);
  lv_obj_set_style_pad_row(panel, 12, 0);
  lv_obj_set_flex_flow(panel, LV_FLEX_FLOW_COLUMN);
  lv_obj_align(panel, LV_ALIGN_CENTER, 0, -24);  // 让出底部按钮行
  lv_obj_t* source = make_box(panel);
  lv_obj_set_size(source, kCardTextW, 24);
  lv_obj_set_style_bg_opa(source, LV_OPA_TRANSP, 0);
  lv_obj_set_style_pad_column(source, 12, 0);
  lv_obj_set_flex_flow(source, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(source, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_t* badge = make_box(source);
  lv_obj_set_size(badge, 24, 24);
  lv_obj_set_style_radius(badge, 7, 0);
  lv_obj_set_style_bg_color(badge, lv_color_hex(0x294F76), 0);
  lv_obj_set_style_bg_opa(badge, LV_OPA_COVER, 0);
  lv_obj_t* mark = lv_label_create(badge);
  lv_obj_set_style_text_font(mark, &font_zh_label, 0);
  lv_obj_set_style_text_color(mark, kWhite, 0);
  lv_label_set_text(mark, "雅");
  lv_obj_center(mark);
  card_source = lv_label_create(source);
  lv_obj_set_style_text_font(card_source, &font_zh_label, 0);
  lv_obj_set_style_text_color(card_source, kGray, 0);
  lv_label_set_text(card_source, "雅哈");

  card_title = make_label(panel, 0, &font_zh_sub, kWhite);
  lv_obj_set_size(card_title, kCardTextW, line_h * 2);
  lv_obj_set_style_text_align(card_title, LV_TEXT_ALIGN_LEFT, 0);
  lv_label_set_long_mode(card_title, LV_LABEL_LONG_WRAP);
  card_body = make_label(panel, 0, &font_zh_marquee, lv_color_hex(0xB6B6BE));
  lv_obj_set_size(card_body, kCardTextW, lv_font_get_line_height(&font_zh_marquee));
  lv_obj_set_style_text_align(card_body, LV_TEXT_ALIGN_LEFT, 0);
  lv_label_set_long_mode(card_body, LV_LABEL_LONG_SCROLL_CIRCULAR);
  lv_obj_add_flag(card_body, LV_OBJ_FLAG_HIDDEN);
  make_button(card_root, 28, 64, "<", display::kTapPrev);
  card_speed = make_button(card_root, 108, 64, "1x", display::kTapSpeedCycle);
  card_pause = make_button(card_root, 188, 104, "||", display::kTapPause);
  set_bg(card_pause, kBlue);
  make_button(card_root, 308, 64, ">", display::kTapNext);
  make_button(card_root, 388, 64, ">>", display::kTapEnd);
  card_status = make_footer(card_root);
}

// 换了卡(标题或正文变)从头滚;同一张卡重画(页码、状态行变)不打断;换速度从当前位置接着滚。
void set_card_body(std::string text, uint8_t speed, bool fresh, bool paused) {
  for (char& c : text)
    if (c == '\n' || c == '\r') c = ' ';
  // LVGL 循环滚动的一圈 = 文字宽 + 3 个空格;anim_duration 是一圈的时长。
  lv_point_t size;
  lv_text_get_size(&size, text.c_str(), &font_zh_marquee, 0, 0, LV_COORD_MAX, LV_TEXT_FLAG_EXPAND);
  const int32_t lap = size.x + 3 * lv_font_get_glyph_width(&font_zh_marquee, ' ', ' ');
  const uint32_t ms = uint32_t(lap) * 1000 / kMarqueePxPerSec[speed];
  if (fresh || text != lv_label_get_text(card_body)) {
    lv_label_set_text(card_body, "");
    lv_obj_set_style_anim_duration(card_body, ms, 0);
    lv_label_set_text(card_body, text.c_str());
    lv_obj_update_flag(card_body, LV_OBJ_FLAG_HIDDEN, text.empty());
  } else if (lv_obj_get_style_anim_duration(card_body, 0) != ms) {
    lv_obj_set_style_anim_duration(card_body, ms, 0);
    if (lv_anim_t* a = lv_anim_get(card_body, nullptr)) {
      a->act_time = int32_t(int64_t(a->act_time) * ms / a->duration);
      a->duration = ms;
    }
  }
  // 阅读页只有跑马灯动画；离开或恢复时总是恢复全局动画定时器。
  if (paused) lv_timer_pause(lv_anim_get_timer()); else lv_timer_resume(lv_anim_get_timer());
  const char* rates[display::kSpeeds] = {"1x", "1.5x", "2x"};
  set_text(lv_obj_get_child(card_speed, 0), rates[speed]);
  set_text(lv_obj_get_child(card_pause, 0), paused ? ">" : "||");
}

lv_color_t state_color(Screen::State state) {
  switch (state) {
    case Screen::State::Boot: return kWhite;
    case Screen::State::Pairing: return kOrange;
    case Screen::State::Searching: return kBlue;
    case Screen::State::Live: return kRed;     // 与 Mac 顶栏/浮层的"送声"红一致
    case Screen::State::Muted: return kGray;
    case Screen::State::Workbench: return kWhite;
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
    case Screen::State::Workbench: return nullptr;  // 走工作台独立路径
  }
  return &s_boot;
}

bool ready = false;

void memory(const char* phase) {
  diagnostics::heap(phase);
  lv_mem_monitor_t pool = {};
  lv_mem_monitor(&pool);
  ESP_LOGI("heap", "%s LVGL total=%u free=%u largest=%u max_used=%u", phase,
           unsigned(pool.total_size), unsigned(pool.free_size),
           unsigned(pool.free_biggest_size), unsigned(pool.max_used));
}

}  // namespace

void init() {
  if (!lvgl_port_lock(0)) return;
  if (!ready) {
    memory("screens before");
    // 文字组以 y≈225 为中心(状态行在底部 make_footer,组心略高于屏心)。
    // Live:标题在频谱区上方,line2 是频谱区下方的 mm:ss 计时;
    // Pairing:line2 是 6 位配对数字。两者都用 72px 数字字体。
    s_live = make_status_screen(92, kSpectrumY1 + 8, 0, &font_clock_num);
    s_muted = make_status_screen(170, 246, 290);
    s_searching = make_status_screen(170, 246, 290);
    s_boot = make_status_screen(170, 246, 290);
    s_pairing = make_status_screen(124, 200, 280, &font_clock_num);
    make_workbench();
    make_card();
    make_spectrum_chart();  // Live 屏的电平条/曲线画布(由 Kconfig 定)
    memory("screens ready");
    ready = true;
  }
  lvgl_port_unlock();
}

void draw(const Screen& s) {
  if (!ready || !lvgl_port_lock(0)) return;
  // 离开通知卡就停掉滚动(不在后台空转),再进来从头滚。
  if (s.state != Screen::State::Workbench || s.page != display::Page::Notice) set_card_body("", s.speed, false, false);
  if (s.state == Screen::State::Workbench) {
    switch (s.page) {
      case display::Page::Home: draw_home(s); break;
      case display::Page::Overview: draw_overview(s); break;
      case display::Page::Detail: draw_detail(s); break;
      case display::Page::Alerts: draw_alerts(s); break;
      case display::Page::Notice:
        {
          const bool fresh = s.line1 != lv_label_get_text(card_title);
          set_text(card_title, s.line1.c_str());
          set_text(card_source, "雅哈");
          set_card_body(s.line2, s.speed, fresh, s.marquee_paused);
        }
        set_text(card_status, s.line3.c_str());
        show(card_root);
        break;
    }
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

void set_clock(uint32_t epoch, int tz_offset_minutes) {
  // why 每次重置基准:固件不跑日历守护,显示时间由"基准本地秒 + esp_timer 单调
  // 增量"合成,单次误差不跨次累计;时区只做加法,Mac 每包下发的偏移已含 DST。
  base_local_s = int64_t(epoch) + int64_t(tz_offset_minutes) * 60;
  base_us = esp_timer_get_time();
  has_base = true;
}

int take_tap() { return tapped.exchange(display::kTapNone); }
int take_hold() { return held.exchange(-1); }

lv_obj_t* spectrum_canvas() { return live_canvas; }

#if CONFIG_YAHADESK_SPECTRUM_BARS
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
