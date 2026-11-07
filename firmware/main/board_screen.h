#pragma once

// board 内部头文件(不进 board.h):LVGL 9.2 静态屏 + Live 频谱层。
// boot/muted/searching/pairing/live 与工作台各页每页一个 LVGL screen 对象,
// draw() 的 LVGL 实现与触摸点击目标都在这里;Live 屏的电平条/曲线画布也由这里
// 创建(经 set_bars()/spectrum_canvas() 暴露给 board.cpp),频带平滑/相位动力学
// 等数值层与渲染节奏在 board.cpp。
// board.h 对 main.cpp 的对外 API 不变。

#include "board.h"

#include "lvgl.h"
#include "sdkconfig.h"

namespace board::screens {

// 创建全部 screen 对象。须在 lvgl_port_init + lvgl_port_add_disp 之后调用
// (内部自行加 lvgl_port_lock)。
void init();

// draw(const Screen&) 的 LVGL 实现:按 s.state 选屏(lv_screen_load 切换),
// 更新 line1/2/3 与底部状态行;Workbench 按 s.page 选子页。
void draw(const Screen& s);
int take_tap();  // 取走最近一次点击目标(LVGL 任务写、主循环读)
int take_hold();  // 取走最近一次长按的告警行号,无则 -1
void set_clock(uint32_t epoch, int tz_offset_minutes);

// —— Live 屏频谱 ——
// 频谱区几何:标题行之下、计时之上;圆屏上这一带的弦长 ≥ 450px。
inline constexpr int kSpectrumY0 = 160;
inline constexpr int kSpectrumY1 = 320;
#if CONFIG_YAHADESK_SPECTRUM_BARS
// 电平条模式(默认):24 根居中对称的圆角条,弹簧动力学数值层在 board.cpp。
inline constexpr int kSpectrumPoints = 24;
inline constexpr int kSpectrumSeriesN = 1;
#else
// LINE 模式(默认):64 点 × 3 series 包络线(lv_canvas 画折线),替代旧三正弦视觉。
// why 64 而不是 240:LVGL 软件画线每段(抗锯齿+3px 宽+遮罩)约 80-100 µs,
// 240 点 × 3 = 717 段真机实测 60-70 ms/帧;曲线本是低频平滑包络,8px 一段
// 肉眼无差,189 段把画线压到 ~18 ms。再降可到 48,线宽 3 → 2 也可再省。
inline constexpr int kSpectrumPoints = 64;
inline constexpr int kSpectrumSeriesN = 3;
#endif

#if CONFIG_YAHADESK_SPECTRUM_BARS
// 电平条模式:kSpectrumPoints 个条高(0..1000)。高度变了的条才改对象并无效化;
// 返回是否有变化。须持 lvgl_port_lock 调用;init 前返回 false。
bool set_bars(const int32_t* values);
#endif

// WAVES 模式的频谱画布(lv_canvas,PSRAM RGB565 480×160):曲线由 board.cpp 每帧经
// LVGL 画布层 API(lv_canvas_init_layer/lv_draw_line/finish_layer)画进画布一次,
// LVGL 再把画布当普通图像分块上屏。why 不直接用 lv_chart 折线:partial 模式下
// 每个 40 行分块都会重新分发全部 720 个线段绘制任务(真机 139 ms/帧,3-7 fps),
// 画布把光栅化从 9 次压回 1 次,各分块只剩一次行拷贝。电平条模式下返回 nullptr。
lv_obj_t* spectrum_canvas();

}  // namespace board::screens
