#pragma once

// board 内部头文件(不进 board.h):LVGL 9.2 静态屏 + Live 频谱(lv_chart)层。
// boot/dash/muted/searching/joining/nowifi/setup/live 每状态一个 LVGL screen
// 对象,draw()/draw_dashboard() 的 LVGL 实现都在这里;Live 屏上的频谱
// lv_chart 也由这里创建(句柄经 spectrum_chart()/spectrum_series() 暴露给
// board.cpp),频带平滑/相位动力学等数值层与渲染节奏在 board.cpp。
// board.h 对 main.cpp 的对外 API 不变。

#include "board.h"

#include "lvgl.h"
#include "sdkconfig.h"

namespace board::screens {

// 创建全部 screen 对象。须在 lvgl_port_init + lvgl_port_add_disp 之后调用
// (内部自行加 lvgl_port_lock)。
void init();

// draw(const Screen&) 的 LVGL 实现:按 s.state 选屏(lv_screen_load 切换),
// 更新 line1/2/3 与底部状态行。Dashboard 走 draw_dashboard 的数据路径。
void draw(const Screen& s);

// Dashboard 数据源与时间基准(why 每包重置见 board_screen.cpp 实现处注释,
// 逻辑自旧手写 compose_dashboard 原样迁移)。
void set_dashboard(const DashboardData& d);
// 重绘 Dashboard 屏:大钟(font_clock_num)+ 日期 + 2x2 lv_arc + 底部状态行;
// 时钟按"基准本地秒 + 单调增量"推进(逻辑同旧 compose_dashboard)。
void draw_dashboard();

// —— Live 屏频谱(lv_chart)——
// 频谱区几何(对齐旧手写渲染的 kSpecY0/kSpecY1:顶部标题之下、底部状态行之上)。
inline constexpr int kSpectrumY0 = 90;
inline constexpr int kSpectrumY1 = 430;
#if CONFIG_YAHAMIC_SPECTRUM_BARS
// COLUMN 模式(LVGL 9.2 枚举名 LV_CHART_TYPE_BAR):32 柱 × 1 series,
// 弹簧动力学数值层在 board.cpp。
inline constexpr int kSpectrumPoints = 32;
inline constexpr int kSpectrumSeriesN = 1;
#else
// LINE 模式(默认):64 点 × 3 series 包络线(lv_canvas 画折线),替代旧三正弦视觉。
// why 64 而不是 240:LVGL 软件画线每段(抗锯齿+3px 宽+遮罩)约 80-100 µs,
// 240 点 × 3 = 717 段真机实测 60-70 ms/帧;曲线本是低频平滑包络,8px 一段
// 肉眼无差,189 段把画线压到 ~18 ms。再降可到 48,线宽 3 → 2 也可再省。
inline constexpr int kSpectrumPoints = 64;
inline constexpr int kSpectrumSeriesN = 3;
#endif

// Live 屏 lv_chart 与 series 句柄(init 后有效;仅可在 lvgl_port_lock 持锁下
// 使用)。数值数组不归本层:board.cpp 每帧填充后经 lv_chart_set_ext_y_array
// 零拷贝挂载。
lv_obj_t* spectrum_chart();
lv_chart_series_t* spectrum_series(int idx);

// LINE 模式的频谱画布(lv_canvas,PSRAM RGB565 480×340):曲线由 board.cpp 每帧经
// LVGL 画布层 API(lv_canvas_init_layer/lv_draw_line/finish_layer)画进画布一次,
// LVGL 再把画布当普通图像分块上屏。why 不直接用 lv_chart 折线:partial 模式下
// 每个 40 行分块都会重新分发全部 720 个线段绘制任务(真机 139 ms/帧,3-7 fps),
// 画布把光栅化从 9 次压回 1 次,各分块只剩一次行拷贝。BARS 模式下返回 nullptr。
lv_obj_t* spectrum_canvas();

}  // namespace board::screens
