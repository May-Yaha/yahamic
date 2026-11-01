#include "board.h"

#include "board_screen.h"

#include <cassert>
#include <cmath>
#include <cstring>

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_co5300.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_lvgl_port.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"
#include "esp_timer.h"

namespace board {
namespace {

constexpr const char* kTag = "board";

// 引脚来自 Waveshare 原理图,与 OpenCharm / xiaozhi-esp32 v2.5.2 相同。
constexpr gpio_num_t kI2cSda = GPIO_NUM_15;
constexpr gpio_num_t kI2cScl = GPIO_NUM_14;
constexpr gpio_num_t kLcdCs = GPIO_NUM_12;
constexpr gpio_num_t kLcdClk = GPIO_NUM_38;
constexpr gpio_num_t kLcdD0 = GPIO_NUM_4;
constexpr gpio_num_t kLcdD1 = GPIO_NUM_5;
constexpr gpio_num_t kLcdD2 = GPIO_NUM_6;
constexpr gpio_num_t kLcdD3 = GPIO_NUM_7;
constexpr gpio_num_t kLcdReset = GPIO_NUM_39;
constexpr gpio_num_t kKey = GPIO_NUM_18;  // +/KEY:外部 10 kΩ 上拉,按下为低

constexpr int kWidth = 480;
constexpr int kHeight = 480;
// 每条数据带的行数:越大,带数越少,每帧固定开销(命令阶段+信号量往返)越少;
// 80 行 = 77 KB 内部 DMA 内存(频谱区 340 行 → 5 带,整屏 → 6 带)。
constexpr int kBufferLines = 80;
// LVGL partial draw buffer 的行数(双缓冲 ×2):40 行×480×2 B×2 = 77 KB 内部 DMA 内存,
// 与旧 band 缓冲占用持平——为什么不能放 PSRAM 见 init_screen 的 disp_cfg 注释。
constexpr int kLvglBufLines = 40;

// CO5300 在 QSPI 上收 32 位命令:0x02(写),命令在位 8..15(同 OpenCharm)。
constexpr uint32_t kWriteCmd = 0x02u << 24;
constexpr uint8_t kBrightnessCmd = 0x51;

// 与 Waveshare 板卡包、xiaozhi-esp32 相同的屏幕启动序列。
const co5300_lcd_init_cmd_t kInitCmds[] = {
    {0x11, (uint8_t[]){0x00}, 0, 600},  // sleep out
    {0xFE, (uint8_t[]){0x20}, 1, 0},
    {0x19, (uint8_t[]){0x10}, 1, 0},
    {0x1C, (uint8_t[]){0xA0}, 1, 0},
    {0xFE, (uint8_t[]){0x00}, 1, 0},
    {0xC4, (uint8_t[]){0x80}, 1, 0},
    {0x3A, (uint8_t[]){0x55}, 1, 0},  // RGB565
    {0x35, (uint8_t[]){0x00}, 1, 0},
    {0x53, (uint8_t[]){0x20}, 1, 0},
    {0x51, (uint8_t[]){0xFF}, 1, 0},  // brightness
    {0x63, (uint8_t[]){0xFF}, 1, 0},
    {0x2A, (uint8_t[]){0x00, 0x00, 0x01, 0xDF}, 4, 0},  // columns 0..479
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xDF}, 4, 0},  // rows 0..479
    {0x36, (uint8_t[]){0xA0}, 1, 0},
    {0x29, (uint8_t[]){0x00}, 0, 600},  // display on
};

// RGB565 颜色(小端数值;blit 时统一按屏幕要求做字节序交换)。
constexpr uint16_t kBlack = 0x0000;
constexpr uint16_t kGreen = 0x07E0;
constexpr uint16_t kRed = 0xF800;
constexpr uint16_t kBlue = 0x3DFF;
constexpr uint16_t kOrange = 0xFD20;
constexpr uint16_t kWhite = 0xFFFF;
constexpr uint16_t kGray = 0x8C71;  // 底部状态行的字色
constexpr uint16_t kTrack = 0x18E3; // 响度条的槽色(暗),兼作底部分隔线色

// 响度条区域:Live/Muted 屏上,整宽,y ∈ [kBarY, kBarY + kBarH)。
constexpr int kBarY = 320;
constexpr int kBarH = 20;

// 频谱:只在 Live(按住 Fn 送声)屏上。LVGL 迁移后渲染由 lv_chart 承担
// (创建于 board_screen.cpp,几何 kSpectrumY0/Y1 = 旧 kSpecY0/kSpecY1):默认
// LINE 模式 240 点 × 3 series 包络线(青 0x07FF/蓝 0x8637/紫粉 0xFB56,流速与
// 空间周期由频谱重心驱动、相位连续),CONFIG_YAHAMIC_SPECTRUM_BARS 时为
// COLUMN 模式 32 柱(弹簧动画)。kSpecBars 是频带数:重心加权、包络载波采样
// 与柱值都用它。
constexpr int kSpecBars = 32;

// —— 频谱重心(音高指标)的常量 ——
// 噪声底:32 柱归一化能量(0..1)的均值低于此值视为无声,门限关闭、重心冻结。
// 频带按 -72..-12 dB 映射到 0..1(见 audio.cpp),安静房间的本底噪声均值远低
// 于 0.06,说话声轻松越过;取值宁低不高,避免把人声尾音误判成噪声。
constexpr float kCentroidNoiseFloor = 0.06f;
// 非对称 EMA 时间常数:攻击快(40 ms,跟手)、释放慢(300 ms,音高回落不跳变)。
constexpr float kCentroidAttackS = 0.040f;
constexpr float kCentroidReleaseS = 0.300f;
// 中性默认值:连续频带序号的中点 15.5,约 632 Hz(50 Hz..8 kHz 的几何中心)。
constexpr float kCentroidNeutral = (kSpecBars - 1) / 2.0f;
// 门限持续关闭时向中性值收敛的固定速率(频带/秒):从任一端回到中心约 0.5 秒。
constexpr float kCentroidReturnPerS = float(kSpecBars - 1);

uint32_t spectrum_frames = 0;  // 遥测:频谱实际渲染帧数(渲染线程写,主循环读)
bool dump_requested = false;   // 截图回帧请求(request_screen_dump 置,draw 消费)
bool dump_capture = false;     // 截图采集中:flush 事件把分块拷进影子画布(见 flush_timing_cb)
extern uint16_t* canvas;       // 影子画布(PSRAM 整屏 RGB565,定义在下方)
int32_t render_frame_us_v = 0;  // 最近一帧的总耗时(µs)
int32_t render_dma_us_v = 0;    // 最近一帧的传屏耗时(µs)

// —— 传屏耗时遥测的 LVGL 事件分段计时 ——
// FLUSH_START..FINISH 包住 esp_lvgl_port 的 flush_cb(RGB565 字节序交换 +
// esp_lcd_panel_draw_bitmap 提交);FLUSH_WAIT_START..FINISH 包住等上一个
// draw buffer 的 DMA 完成(双缓冲交换点,完成信号来自 on_trans_done →
// lv_display_flush_ready)。两段都计为"传屏",与旧直渲染 dma_us("提交 +
// 等完成信号量")语义对齐。事件在渲染线程(lv_refr_now 的调用方)上同步
// 触发,回调里只读写这两个变量。
int64_t flush_dma_accum_us = 0;
int64_t flush_seg_t0 = 0;

void flush_timing_cb(lv_event_t* e) {
  switch (lv_event_get_code(e)) {
    case LV_EVENT_FLUSH_START:
      // 截图回帧采集:FLUSH_START 时 LVGL 已把本分块渲染进 draw buffer,而
      // esp_lvgl_port 的 flush_cb 还没做字节交换——此刻是原生 RGB565,正好是旧
      // dump 格式(Mac 侧 scrdump.py 按 %04x 原值解码);逐行拷进影子画布,整屏
      // 无效化 + 一次 lv_refr_now 之后影子画布即完整一帧。
      if (dump_capture && canvas) {
        auto* area = static_cast<const lv_area_t*>(lv_event_get_param(e));
        auto* disp = static_cast<lv_display_t*>(lv_event_get_target(e));
        lv_draw_buf_t* buf = disp ? lv_display_get_buf_active(disp) : nullptr;
        if (area && buf && buf->data) {
          const int w = area->x2 - area->x1 + 1;
          const int h = area->y2 - area->y1 + 1;
          const uint32_t stride = lv_draw_buf_width_to_stride(w, LV_COLOR_FORMAT_RGB565);
          for (int row = 0; row < h; ++row) {
            const int y = area->y1 + row;
            if (y < 0 || y >= kHeight || area->x1 < 0 || area->x1 + w > kWidth) continue;
            memcpy(canvas + size_t(y) * kWidth + area->x1, buf->data + size_t(row) * stride,
                   size_t(w) * sizeof(uint16_t));
          }
        }
      }
      [[fallthrough]];
    case LV_EVENT_FLUSH_WAIT_START:
      flush_seg_t0 = esp_timer_get_time();
      break;
    case LV_EVENT_FLUSH_FINISH:
    case LV_EVENT_FLUSH_WAIT_FINISH:
      if (flush_seg_t0) flush_dma_accum_us += esp_timer_get_time() - flush_seg_t0;
      flush_seg_t0 = 0;
      break;
    default:
      break;
  }
}

// 把影子画布按旧格式经日志口回传:每 4 行取 1 行、每 4 列取 1 列,每行一条
// `SCR r=<行号/4> <120 个 %04x>`,末行 `SCR end`——Mac 侧 scrdump.py 依赖此
// 格式逐字节不变(RGB565 原值,不换序)。
void dump_shadow() {
  if (!canvas) return;
  for (int y = 0; y < kHeight; y += 4) {
    char line[560];
    int at = snprintf(line, sizeof line, "SCR r=%d ", y / 4);
    for (int x = 0; x < kWidth && at + 6 < int(sizeof line); x += 4)
      at += snprintf(line + at, 6, "%04x", canvas[size_t(y) * kWidth + x]);
    line[at] = 0;
    ESP_LOGI("scr", "%s", line);
  }
  ESP_LOGI("scr", "SCR end");
}

esp_lcd_panel_handle_t panel = nullptr;
esp_lcd_panel_io_handle_t panel_io = nullptr;
uint16_t* canvas = nullptr;  // 整屏合成缓冲,PSRAM(开机清屏与保留 API draw_level 用)
uint16_t* band = nullptr;    // 一条 kBufferLines(80)行的搬运缓冲,内部 DMA 内存

// DMA 同步点:一条数据带传完(异步完成中断)给一次信号量。DMA 还在读 band
// 缓冲时,下一条带不能改写它,否则屏幕上每条带显示的都是下一条的内容(初版
// 花屏的原因)。与 LVGL 双缓冲 + on_color_trans_done 的做法同理;直渲染后每帧
// 只写频谱区一遍,单缓冲 + 信号量即可,不需要双缓冲重叠流水线。
SemaphoreHandle_t blit_done = nullptr;

// esp_lvgl_port 创建的 LVGL 显示对象(on_trans_done 链式转发 flush-ready 用)。
lv_display_t* lvgl_disp = nullptr;

// LVGL 迁移后此回调是组合回调:esp_lcd 每个 io 只存一个回调,esp_lvgl_port 在
// lvgl_port_add_disp 里注册的 flush-ready 回调会被 init_screen 里后注册的本回调
// 覆盖,所以这里链式转发 lv_display_flush_ready(只清 flushing 标志,ISR 里调用
// 安全——esp_lvgl_port 原本就从 ISR 调),LVGL 的 flush 等待才不会挂死;副作用是
// LVGL 自己的 flush 完成也会顺手给一次信号量(无害:blit 通路只剩开机清屏与
// 保留 API draw_level 使用)。
bool IRAM_ATTR on_trans_done(esp_lcd_panel_io_handle_t, esp_lcd_panel_io_event_data_t*,
                             void*) {
  BaseType_t wake = pdFALSE;
  xSemaphoreGiveFromISR(blit_done, &wake);
  if (lvgl_disp) lv_display_flush_ready(lvgl_disp);
  portYIELD_FROM_ISR(wake);
  return false;
}

void fill_rect(int x, int y, int w, int h, uint16_t color) {
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x + w > kWidth) w = kWidth - x;
  if (y + h > kHeight) h = kHeight - y;
  for (int row = y; row < y + h; ++row) {
    uint16_t* line = canvas + size_t(row) * kWidth + x;
    for (int col = 0; col < w; ++col) line[col] = color;
  }
}

// 把画布的 [y0, y1) 行搬到屏幕(开机清屏与保留 API draw_level 用;频谱热路径
// 已迁 lv_chart,不再经过画布):kBufferLines(80)行一批,字节序换为大端(CO5300 的要求)。
// y0 对齐偶数、行数取偶,保证区域"起偶止奇"(面板对坐标的要求,同 OpenCharm
// 的 round_area)。每一批发完(信号量)才复用缓冲,见 on_trans_done 的注释。
void blit(int y0, int y1) {
  if (!panel || !band || !blit_done) return;
  y0 = y0 & ~1;
  y1 = y0 + (((y1 - y0) + 1) & ~1);  // 偶数行:最后一行落在奇数上
  if (y1 > kHeight) y1 = kHeight;
  for (int y = y0; y < y1; y += kBufferLines) {
    int lines = (y + kBufferLines <= y1) ? kBufferLines : y1 - y;
    size_t words = size_t(lines) * kWidth;
    memcpy(band, canvas + size_t(y) * kWidth, words * sizeof(uint16_t));
    for (size_t i = 0; i < words; ++i) band[i] = (band[i] >> 8) | (band[i] << 8);
    // 这个驱动的 end 坐标是 exclusive(驱动内按 x_end-1 设窗口),与老 CO5300
    // 驱动的 inclusive 不同;传 480 和 y+lines,正好用满 band 里的 480×lines。
    esp_lcd_panel_draw_bitmap(panel, 0, y, kWidth, y + lines, band);
    xSemaphoreTake(blit_done, pdMS_TO_TICKS(100));  // DMA 读完了才能改写 band
  }
}

void compose_bar(float level) {
  if (level < 0) level = 0;
  if (level > 1) level = 1;
  fill_rect(0, kBarY, kWidth, kBarH, kTrack);
  fill_rect(0, kBarY + 4, int(float(kWidth) * level), kBarH - 8, kGreen);
}

void init_i2c(Board& b) {
  i2c_master_bus_config_t config = {};
  config.i2c_port = I2C_NUM_0;
  config.sda_io_num = kI2cSda;
  config.scl_io_num = kI2cScl;
  config.clk_source = I2C_CLK_SRC_DEFAULT;
  config.flags.enable_internal_pullup = 1;
  ESP_ERROR_CHECK(i2c_new_master_bus(&config, &b.i2c));
}

void init_screen(Board& b) {
  spi_bus_config_t bus = {};
  bus.sclk_io_num = kLcdClk;
  bus.data0_io_num = kLcdD0;
  bus.data1_io_num = kLcdD1;
  bus.data2_io_num = kLcdD2;
  bus.data3_io_num = kLcdD3;
  bus.max_transfer_sz = kWidth * kBufferLines * sizeof(uint16_t);
  bus.flags = SPICOMMON_BUSFLAG_QUAD;
  ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO));

  esp_lcd_panel_io_spi_config_t io = {};
  io.cs_gpio_num = kLcdCs;
  io.dc_gpio_num = GPIO_NUM_NC;
  io.spi_mode = 0;
  io.pclk_hz = 40 * 1000 * 1000;
  io.trans_queue_depth = 10;
  io.lcd_cmd_bits = 32;
  io.lcd_param_bits = 8;
  io.flags.quad_mode = true;
  ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(SPI2_HOST, &io, &b.panel_io));

  // 数据带传输完成 → 信号量(见 blit):缓冲复用的同步点。回调在
  // lvgl_port_add_disp 之后注册(见文件尾 on_trans_done 的 why 注释)。
  blit_done = xSemaphoreCreateBinary();
  assert(blit_done);

  co5300_vendor_config_t vendor = {};
  vendor.init_cmds = kInitCmds;
  vendor.init_cmds_size = sizeof(kInitCmds) / sizeof(kInitCmds[0]);
  vendor.flags.use_qspi_interface = 1;
  esp_lcd_panel_dev_config_t dev = {};
  dev.reset_gpio_num = kLcdReset;
  dev.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  dev.bits_per_pixel = 16;
  dev.vendor_config = &vendor;
  ESP_ERROR_CHECK(esp_lcd_new_panel_co5300(b.panel_io, &dev, &b.panel));
  ESP_ERROR_CHECK(esp_lcd_panel_reset(b.panel));
  ESP_ERROR_CHECK(esp_lcd_panel_init(b.panel));
  ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(b.panel, true));

  panel = b.panel;
  panel_io = b.panel_io;
  // 画布留在 PSRAM(截图回帧/保留 API draw_level 用);旧 band 内部 DMA 缓冲不再
  // 分配:整屏上屏已全部由 LVGL 的 draw buffer 承担,再留 75 KB 内部 RAM 给一条
  // 无人调用的搬运路径,会把 LVGL 第二块 draw buffer 挤到分配失败(真机实测:
  // "Not enough memory for LVGL buffer (buf2)" 启动循环)。blit() 以 band 判空自保。
  canvas = static_cast<uint16_t*>(
      heap_caps_calloc(size_t(kWidth) * kHeight, sizeof(uint16_t), MALLOC_CAP_SPIRAM));
  assert(canvas);

  // —— LVGL 9.2 接管 CO5300 flush(esp_lvgl_port)——
  // GUI 任务钉 CPU0(主循环/频谱直渲染在 CPU1,见 sdkconfig.defaults),栈 8 KB。
  const lvgl_port_cfg_t port_cfg = {
      .task_priority = 4,
      .task_stack = 8192,
      .task_affinity = 0,
      .task_max_sleep_ms = 500,
      .task_stack_caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_DEFAULT,
      .timer_period_ms = 5,
  };
  ESP_ERROR_CHECK(lvgl_port_init(&port_cfg));
  // partial 模式,2 个 draw buffer 各 kLvglBufLines(40)行×480×2 B,**必须内部 DMA 内存**:
  // S3 的 PSRAM 堆区域不带 MALLOC_CAP_DMA 标签(esp-idf heap/port/esp32s3/
  // memory_layout.c L67),buff_dma|buff_spiram 按位或后 heap_caps_aligned_alloc 匹配
  // 不到任何区域而返回 NULL(初次真机:启动黑屏)。40 行×2 = 77 KB 与旧 band 持平。
  // 为什么不用 direct/full 模式把帧缓冲放 PSRAM:esp_lvgl_port 2.6.3 对 SPI 面板的
  // direct 模式是按脏区指针当打包位图发(步长错)+swap 原地改帧缓冲,且 spi_master
  // 对非缓存行对齐的 PSRAM 脏区会退回"拷临时内部缓冲"(真机:priv TX buffer 分配失败、
  // 内部 RAM 被挤到 55 KB 连音频任务都起不来)。频谱热路径的性能靠 lv_canvas
  // 解决(见 draw_spectrum:曲线每帧只画一次进画布,各分块只做图像拷贝)。
  // swap_bytes:CO5300 要大端 RGB565(旧手写 blit 自己做交换,现由 esp_lvgl_port
  // 的 flush 统一换,二者只能有一处换,否则会双重交换花屏——真机验证点)。
  const lvgl_port_display_cfg_t disp_cfg = {
      .io_handle = b.panel_io,
      .panel_handle = b.panel,
      .control_handle = nullptr,
      .buffer_size = uint32_t(kWidth) * kLvglBufLines,
      .double_buffer = true,
      .trans_size = 0,
      .hres = kWidth,
      .vres = kHeight,
      .monochrome = false,
      .rotation = {.swap_xy = false, .mirror_x = false, .mirror_y = false},
      .color_format = LV_COLOR_FORMAT_RGB565,
      .flags = {.buff_dma = 1, .buff_spiram = 0, .sw_rotate = 0,
                .swap_bytes = 1, .full_refresh = 0, .direct_mode = 0},
  };
  lvgl_disp = lvgl_port_add_disp(&disp_cfg);
  assert(lvgl_disp);
  // 传屏耗时遥测:LVGL flush 事件分段计时(见 flush_timing_cb 注释)。
  lv_display_add_event_cb(lvgl_disp, flush_timing_cb, LV_EVENT_ALL, nullptr);
  // 组合回调必须在 add_disp 之后注册(覆盖它的 flush-ready 回调,见
  // on_trans_done 的 why 注释——本回调会链式转发)。
  esp_lcd_panel_io_callbacks_t callbacks = {};
  callbacks.on_color_trans_done = on_trans_done;
  ESP_ERROR_CHECK(esp_lcd_panel_io_register_event_callbacks(b.panel_io, &callbacks, nullptr));
  // 创建 8 个状态的 LVGL screen 对象(boot/dash/muted/searching/joining/
  // nowifi/setup/live,见 board_screen.cpp)。开机黑屏由 LVGL screen 背景负责,
  // 不再经旧画布 blit。
  screens::init();
}

void init_key() {
  gpio_config_t key = {};
  key.pin_bit_mask = 1ULL << kKey;
  key.mode = GPIO_MODE_INPUT;
  key.pull_up_en = GPIO_PULLUP_DISABLE;  // 板上有 10 kΩ 上拉(R18)
  ESP_ERROR_CHECK(gpio_config(&key));
}

}  // namespace

void init(Board& b) {
  init_i2c(b);
  init_screen(b);
  init_key();
  ESP_LOGI(kTag, "screen and key ready");
}

bool key_down() { return gpio_get_level(kKey) == 0; }

void draw(const Screen& s) {
  // LVGL 实现(board_screen.cpp):按状态选屏(lv_screen_load)+ 更新标签。
  screens::draw(s);
  // 截图回帧:整屏无效化 + 一次同步重绘,flush 事件把各分块拷进影子画布(见
  // flush_timing_cb),再按旧 SCR 格式经日志口回传。静态屏与 Live 频谱同一条路径
  // (主循环收到 dump 请求时无论什么状态都会调一次 draw)。
  if (dump_requested && lvgl_port_lock(0)) {
    dump_capture = true;
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(nullptr);
    dump_capture = false;
    lvgl_port_unlock();
    dump_shadow();
    dump_requested = false;
  }
}

void set_dashboard(const DashboardData& d) {
  // 数据源与时间基准在 board_screen.cpp(why 每包重置见其实现处注释,逻辑
  // 自旧手写实现原样迁移)。
  screens::set_dashboard(d);
}

void draw_dashboard() {
  // LVGL 实现(board_screen.cpp):大钟 + 日期 + 2x2 lv_arc + 底部状态行。
  screens::draw_dashboard();
}

void draw_level(float level) {
  // 响度条局部重画(当前固件未调用:Live 屏电平由波形振幅表现;保留 API)。
  if (!canvas) return;
  compose_bar(level);
  blit(kBarY, kBarY + kBarH);
}

#if !CONFIG_YAHAMIC_SPECTRUM_BARS
// —— 相位连续的音高驱动波形动力学 ——
// 平滑频谱重心(连续频带序号,见 update_centroid)映射为波形流速(相位/秒)与
// 空间周期(像素/周期,基波),上下限均为具名常量;映射目标再经限速渐变,保证
// 相邻帧任意像素的相位增量有界、无可见跳变(锚点补偿的等价替代:空间频率本身
// 连续,无需锚点)。主相位用累加器维护,每帧 wrap 到 [0,1) 圈:累加器本身有界,
// 不存在随运行时间变大的量,无累计浮点漂移路径。静音(门限关闭)时重心平滑值
// 连续回中性(15.5),流速/周期随之收敛到中性默认值,相位累加器不重置。
constexpr float kFlowHzMin = 0.20f;         // 流速下限(圈/秒,主相位)
constexpr float kFlowHzMax = 1.00f;         // 流速上限
constexpr float kFlowHzNeutral = 0.45f;     // 中性默认流速(= 原固定流速 0.45 Hz)
constexpr float kPeriodPxMin = 160.0f;      // 空间周期下限(像素/周期,基波)
constexpr float kPeriodPxMax = 480.0f;      // 空间周期上限(整宽一个周期)
constexpr float kPeriodPxNeutral = 320.0f;  // 中性默认空间周期
constexpr float kFlowRatePerS = 1.2f;       // 流速限速(圈/秒²):0.2↔1.0 全程约 0.7 s
constexpr float kCyclesRatePerS = 1.5f;     // 空间频率限速(周期/整宽/秒)
// 帧间相位增量上界(圈):(kFlowHzMax + kCyclesRatePerS)·dt;dt 被调用方钳到
// ≤ 0.2 s,30 fps(dt≈0.033)时约 0.083 圈/帧——连续渐变,无跳变。

struct WaveDynamics {
  float phase_turns;  // 主相位,[0,1) 圈
  float base_cycles;  // 基波空间频率(周期/整宽)
  float flow_hz;      // 当前流速(调试/遥测)
  float period_px;    // 当前空间周期(调试/遥测)
};

WaveDynamics wave_dynamics(float dt) {
  static float phase = 0.0f;  // 主相位累加器(圈),只增不归零(除 wrap)
  static float flow = kFlowHzNeutral;                    // 流速当前值(限速渐变)
  static float cycles = float(kWidth) / kPeriodPxNeutral;  // 空间频率当前值(限速渐变)
  // 重心归一化到 [0,1]:0.5 = 中性(门限关闭时平滑值本身连续回中)。
  float t = centroid().smoothed / float(kSpecBars - 1);
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  // 分段线性映射:中性点两侧分别插值,保证 t=0.5 精确落在中性默认值。
  auto map01 = [t](float at0, float at_half, float at1) {
    return t < 0.5f ? at0 + (at_half - at0) * (t * 2.0f)
                    : at_half + (at1 - at_half) * ((t - 0.5f) * 2.0f);
  };
  const float flow_target = map01(kFlowHzMin, kFlowHzNeutral, kFlowHzMax);
  // 音高越高波形越密:t=0 → 周期上限(疏),t=1 → 周期下限(密)。
  const float period_target = map01(kPeriodPxMax, kPeriodPxNeutral, kPeriodPxMin);
  // 限速渐变:参数每帧变化 ≤ rate·dt ⇒ 帧间任意像素相位增量有界。
  auto slew = [dt](float cur, float target, float rate) {
    float d = target - cur, m = rate * dt;
    return cur + (d > m ? m : (d < -m ? -m : d));
  };
  flow = slew(flow, flow_target, kFlowRatePerS);
  cycles = slew(cycles, float(kWidth) / period_target, kCyclesRatePerS);
  // 相位累加并 wrap 到 [0,1):每帧只加 flow·dt(≤ 0.2 圈),累加器永不增长。
  phase += flow * dt;
  phase -= std::floor(phase);
  return {phase, cycles, flow, float(kWidth) / cycles};
}
#endif  // !CONFIG_YAHAMIC_SPECTRUM_BARS

// —— Live 频谱(lv_chart)数值层:与渲染解耦的动力学计算 ——
// LVGL 迁移后,像素级的画线/画柱全部交给 lv_chart 的软件渲染;本层保留旧
// 实现的数值内核:32 频带非对称平滑(bands_s)、总电平快攻慢放(level_s)、
// 弹簧柱动力学(pos/vel)与相位连续的流速/空间周期动力学(wave_dynamics,
// 由频谱重心驱动)。每帧由这些状态算出 series 目标值写进 int32 数组(经
// lv_chart_set_ext_y_array 零拷贝挂给 chart,见 draw_spectrum),热路径不再
// 逐像素算颜色,也没有堆分配(全部静态存储)。
int32_t spec_values[screens::kSpectrumSeriesN][screens::kSpectrumPoints];
int32_t spec_values_prev[screens::kSpectrumSeriesN][screens::kSpectrumPoints];
#if CONFIG_YAHAMIC_SPECTRUM_BARS
bool spec_attached = false;  // ext 数组已挂载到 chart(LINE 模式走画布,不挂载)
#endif

#if CONFIG_YAHAMIC_SPECTRUM_BARS
// COLUMN 数值层:每柱一个弹簧(逐帧步进,参数与旧 draw_bars 一致:刚度 0.32 /
// 阻尼 0.70,带一点过冲回弹,比纯衰减更"活");输出 0..1000 的柱高(chart
// y 轴 range 0..1000)。下限 30:无声也露一小截"呼吸点"(对齐旧手绘语义)。
void compute_column_values(const float* in, int count) {
  static float pos[kSpecBars] = {0};
  static float vel[kSpecBars] = {0};
  const int bars = count < kSpecBars ? count : kSpecBars;
  for (int b = 0; b < kSpecBars; ++b) {
    float target = b < bars ? in[b] : 0.0f;
    if (target < 0) target = 0;
    if (target > 1) target = 1;
    vel[b] += (target - pos[b]) * 0.32f;  // 弹簧刚度
    vel[b] *= 0.70f;                      // 阻尼:小过冲,很快安定
    pos[b] += vel[b];
    if (pos[b] < 0) pos[b] = 0;
    if (pos[b] > 1) pos[b] = 1;
    spec_values[0][b] = 30 + int32_t(pos[b] * 970.0f);
  }
}
#else
// LINE 数值层:240 点 × 3 series 包络线。
// cycles: 剖面重复次数比(相对基波空间频率);speed: 相位流速比(相对主相位
// 累加器);offset: 固定相位偏移;scale: 振幅比。动力学含义与旧三正弦的
// WaveSpec 一致,只是载波从正弦换成频带剖面(见 compute_line_values 的 why
// 注释);颜色不再属于数值层(在 board_screen.cpp 创建 chart 时设定)。
constexpr int kWaves = 3;
struct WaveSpec { float cycles; float speed; float offset; float scale; };
constexpr WaveSpec kWaveSpecs[kWaves] = {
    {1.0f, 1.00f, 0.0f, 1.00f},  // 青(主包络)
    {1.7f, 1.35f, 2.1f, 0.72f},  // 蓝
    {2.4f, 0.80f, 4.2f, 0.52f},  // 紫粉
};
constexpr float kInvTau = 1.0f / 6.2831853f;

// 汉宁包络(240 点:两端收窄、中间强,同旧 wave_env 的视觉意图,从 480 列
// 改为按 chart 点数建表);三角函数只出现在建表处,热路径只查表。
float spec_env[screens::kSpectrumPoints];
bool spec_env_ready = false;

void init_spec_env() {
  if (spec_env_ready) return;
  for (int i = 0; i < screens::kSpectrumPoints; ++i)
    spec_env[i] = std::sin(3.1415926f * float(i) / float(screens::kSpectrumPoints - 1));
  spec_env_ready = true;
}

void compute_line_values(const float* in, int count) {
  static float level_s = 0;               // 平滑后的总电平
  static float bands_s[kSpecBars] = {0};  // 平滑后的频带(包络载波的剖面)
  init_spec_env();  // 包络表:仅首次构建,之后是空判断

  // 平滑用真实时间常数(快攻/慢放),与刷新帧率无关:跟手且不生硬。
  const int64_t now_us = esp_timer_get_time();
  static int64_t last_us = 0;
  float dt = last_us ? float(now_us - last_us) / 1e6f : 0.033f;
  last_us = now_us;
  if (dt < 0.005f) dt = 0.005f;
  if (dt > 0.2f) dt = 0.2f;
  const float kEaseAttack = 1.0f - std::exp(-dt / 0.060f);
  const float kEaseRelease = 1.0f - std::exp(-dt / 0.350f);

  const int bars = count < kSpecBars ? count : kSpecBars;
  float sum = 0, peak = 0;
  for (int b = 0; b < bars; ++b) {
    float v = in[b] < 0 ? 0 : (in[b] > 1 ? 1 : in[b]);
    sum += v;
    if (v > peak) peak = v;
    bands_s[b] += (v - bands_s[b]) * (v > bands_s[b] ? kEaseAttack * 0.83f : kEaseRelease * 0.33f);
  }
  const float band_mean = sum / bars;
  const float level = 0.6f * band_mean + 0.4f * peak;
  level_s += (level - level_s) * (level > level_s ? kEaseAttack : kEaseRelease);
  // 相位连续的音高驱动动力学:流速/空间周期由平滑重心映射并限速渐变,
  // 主相位累加 wrap(详见 wave_dynamics)。
  const WaveDynamics dyn = wave_dynamics(dt);
  // 调试:约 1 Hz 打一条动力学状态(D 级),供帧间相位增量有界性验证。
  static int64_t dbg_us = 0;
  if (now_us - dbg_us >= 1000000) {
    dbg_us = now_us;
    ESP_LOGD(kTag, "wave flow=%.2fHz period=%.0fpx centroid=%.1f gate=%d",
             double(dyn.flow_hz), double(dyn.period_px),
             double(centroid().smoothed), int(centroid().gate_open));
  }

  // 包络线载波(替代旧三正弦视觉,why):旧实现是三条与频谱形状无关的纯
  // 正弦,只把频谱能量映射到振幅,形状永远是正弦;这里把"平滑频带剖面沿 x
  // 循环平移相位"本身作为载波——曲线的起伏形状就是当前声音的频谱形状
  // (剖面去均值 ≈ [-1,1],低频隆起在左、高频在右),相位偏移来自
  // wave_dynamics 的相位累加器(流速/空间周期仍由频谱重心连续驱动、限速
  // 渐变,帧间无跳变),视觉上保持流动感,且每点一次剖面插值,比逐像素
  // 画三遍柔光/亮芯便宜得多。
  const float amp0 = 1000.0f * (0.06f + 0.94f * level_s);
  for (int w = 0; w < kWaves; ++w) {
    const WaveSpec& s = kWaveSpecs[w];
    const float phase = dyn.phase_turns * s.speed + s.offset * kInvTau;
    const float cycles = dyn.base_cycles * s.cycles;
    const float amp = amp0 * s.scale;
    for (int i = 0; i < screens::kSpectrumPoints; ++i) {
      float p = float(i) / float(screens::kSpectrumPoints - 1) * cycles + phase;
      p -= std::floor(p);  // 沿剖面循环 ⇒ 相位推进 = 曲线水平流动
      const float fb = p * (bars - 1);
      const int b0 = int(fb);
      const int b1 = b0 + 1 < bars ? b0 + 1 : b0;
      const float bandv = bands_s[b0] + (bands_s[b1] - bands_s[b0]) * (fb - b0);
      float carrier = (bandv - band_mean) * 2.2f;  // 剖面去均值,±1 截断
      if (carrier > 1) carrier = 1;
      if (carrier < -1) carrier = -1;
      spec_values[w][i] = int32_t(amp * spec_env[i] * carrier);
    }
  }
}
#endif

// —— 频谱重心(音高指标)——
// 渲染线程(draw_spectrum)每帧调用 update_centroid:总能量越过噪声底时
// 用频带能量加权更新原始重心;否则冻结,平滑值按固定速率回中性默认值。
Centroid centroid_state = {kCentroidNeutral, false, kCentroidNeutral};
int64_t centroid_last_us = 0;

void update_centroid(const float* bars, int count) {
  if (!bars || count <= 0) return;
  // 时间步长与渲染帧率解耦:EMA 系数、回中速率都按真实 dt 折算。
  const int64_t now = esp_timer_get_time();
  float dt = centroid_last_us ? float(now - centroid_last_us) / 1e6f : 0.033f;
  centroid_last_us = now;
  if (dt < 0.005f) dt = 0.005f;
  if (dt > 0.5f) dt = 0.5f;  // 状态切走再回来时不产生巨步
  const float neutral = (count - 1) / 2.0f;

  float sum = 0, wsum = 0;
  for (int b = 0; b < count; ++b) {
    float v = bars[b] < 0 ? 0 : (bars[b] > 1 ? 1 : bars[b]);
    sum += v;
    wsum += v * float(b);
  }
  centroid_state.gate_open = sum / float(count) >= kCentroidNoiseFloor;
  if (centroid_state.gate_open && sum > 0) {
    // 能量加权重心(连续频带序号):对数频带上的加权平均,音高走高它走高。
    float raw = wsum / sum;
    centroid_state.raw = raw;
    // 非对称 EMA(攻击快、释放慢),渲染帧间一阶趋近:输入约 60 ms 一刷新,
    // 30 fps 渲染下每次只迈一小步,消除台阶感。
    float tc = raw > centroid_state.smoothed ? kCentroidAttackS : kCentroidReleaseS;
    centroid_state.smoothed += (raw - centroid_state.smoothed) * (1.0f - std::exp(-dt / tc));
  } else {
    // 门限关闭:原始重心冻结,平滑值按固定速率向中性默认值收敛(无声时波形
    // 参数缓缓回中,不回跳)。
    float step = kCentroidReturnPerS * dt;
    float d = neutral - centroid_state.smoothed;
    if (d > step) {
      centroid_state.smoothed += step;
    } else if (d < -step) {
      centroid_state.smoothed -= step;
    } else {
      centroid_state.smoothed = neutral;
    }
  }
}

const Centroid& centroid() { return centroid_state; }

void draw_spectrum(const float* in, int count) {
  update_centroid(in, count);   // 重心门限/平滑,保留现实现(见上)
  spectrum_frames += 1;         // 遥测:每次调用计一帧(语义同旧:渲染帧计数)
#if CONFIG_YAHAMIC_SPECTRUM_BARS
  lv_obj_t* target = screens::spectrum_chart();
#else
  lv_obj_t* target = screens::spectrum_canvas();
#endif
  if (!target || !lvgl_port_lock(0)) return;  // 持锁下更新数据并同步渲染
#if CONFIG_YAHAMIC_SPECTRUM_BARS
  if (!spec_attached) {
    // 数值数组零拷贝挂载:LVGL 渲染直接读这块静态内存,每帧只写不分配。
    for (int s = 0; s < screens::kSpectrumSeriesN; ++s)
      lv_chart_set_ext_y_array(target, screens::spectrum_series(s), spec_values[s]);
    spec_attached = true;
  }
  compute_column_values(in, count);
#else
  compute_line_values(in, count);
#endif
  if (memcmp(spec_values, spec_values_prev, sizeof spec_values) == 0) {
    // 静默帧:数值与上一帧完全一致(无声时包络/柱高收敛到定值)⇒ 跳过渲染,
    // 省 QSPI 带宽(对齐旧 draw_bars"安静不再刷屏"的语义);遥测记 0,日志里
    // "帧 0.0ms"即表示本帧未渲染。
    render_frame_us_v = 0;
    render_dma_us_v = 0;
    lvgl_port_unlock();
    return;
  }
  memcpy(spec_values_prev, spec_values, sizeof spec_values);
  int64_t t0 = 0;  // 帧耗时起点:BARS 在 refr 前取,LINE 从画线开始取(画线是大头)
#if CONFIG_YAHAMIC_SPECTRUM_BARS
  lv_chart_refresh(target);  // 单次无效化(chart 全区 480×340)
  t0 = esp_timer_get_time();
#else
  // 画布路径(why 见 board_screen.h spectrum_canvas):清底 + 三条折线各
  // kSpectrumPoints-1 段,经 LVGL 画布层 API 软件渲染**一次**进 PSRAM 画布;
  // 之后 LVGL 把画布当图像分块合成,各 40 行分块只做一次行拷贝,不再重分发线段。
  // 坐标映射:x 均分 480 宽;y 以画布中线为 0,±1000 对应 ±(半高-4)px,与旧
  // lv_chart 的 -1000..1000 量程一致,数值层不变。线宽 3px,与旧三正弦对齐。
  constexpr int kH = screens::kSpectrumY1 - screens::kSpectrumY0;
  constexpr int kMid = kH / 2;
  constexpr float kYScale = float(kMid - 4) / 1000.0f;
  constexpr float kXStep = float(kWidth - 1) / float(screens::kSpectrumPoints - 1);
  static const lv_color_t kLineColors[3] = {
      lv_color_hex(0x00FFFF),  // 青(RGB565 0x07FF)
      lv_color_hex(0x8486BD),  // 蓝(RGB565 0x8637)
      lv_color_hex(0xFFAAB5),  // 紫粉(RGB565 0xFB56)
  };
  t0 = esp_timer_get_time();  // 帧耗时从画线开始计(画线是本路径的大头,不能漏)
  // 先算本帧全部点的画布 y 与纵向包围盒,再决定脏带与清底范围。
  int32_t ys[screens::kSpectrumSeriesN][screens::kSpectrumPoints];
  int y_min = kH, y_max = 0;
  for (int w = 0; w < screens::kSpectrumSeriesN; ++w) {
    for (int i = 0; i < screens::kSpectrumPoints; ++i) {
      const int32_t y = int32_t(kMid - spec_values[w][i] * kYScale);
      ys[w][i] = y;
      if (y < y_min) y_min = y;
      if (y > y_max) y_max = y;
    }
  }
  // 脏带 = 本帧 ∪ 上一帧的纵向范围,外扩线宽:安静时曲线贴中线,每帧只搬几十行
  // 而不是整块 480×340(326 KB PSRAM 读 + 换序 + DMA ≈ 25 ms);说话响时自然扩到
  // 接近整块。上一帧范围必须并入,否则缩小的曲线会留下残影。
  static int prev_min = 0, prev_max = kH - 1;
  int inv_min = (y_min < prev_min ? y_min : prev_min) - 3;
  int inv_max = (y_max > prev_max ? y_max : prev_max) + 3;
  if (inv_min < 0) inv_min = 0;
  if (inv_max > kH - 1) inv_max = kH - 1;
  prev_min = y_min;
  prev_max = y_max;

  lv_layer_t layer;
  lv_canvas_init_layer(target, &layer);
  // why 不用 lv_canvas_fill_bg / lv_canvas_finish_layer:二者都会 lv_obj_invalidate
  // 整块画布(lv_canvas.c),把"只无效化脏带"的省带宽努力抵消掉;这里用公开的
  // lv_draw_dispatch_* 接口把任务队列渲染进画布(与 finish_layer 内部一致,只是
  // 不标脏),最后自己按脏带无效化。
  auto dispatch = [&layer]() {
    while (layer.draw_task_head) {
      lv_draw_dispatch_wait_for_request();
      lv_draw_dispatch_layer(nullptr, &layer);
    }
  };
  // 清底只清脏带:一个矩形填充任务(把上一帧的曲线擦掉)。
  lv_draw_rect_dsc_t clear_dsc;
  lv_draw_rect_dsc_init(&clear_dsc);
  clear_dsc.bg_color = lv_color_black();
  clear_dsc.bg_opa = LV_OPA_COVER;
  clear_dsc.border_width = 0;
  clear_dsc.radius = 0;
  clear_dsc.shadow_width = 0;
  clear_dsc.outline_width = 0;
  lv_area_t clear_area = {0, int32_t(inv_min), kWidth - 1, int32_t(inv_max)};
  lv_draw_rect(&layer, &clear_dsc, &clear_area);

  lv_draw_line_dsc_t dsc;
  lv_draw_line_dsc_init(&dsc);
  dsc.width = 3;
  // 分批落盘(why):每个 lv_draw_line 都是一个独立绘制任务,lv_malloc 的小块在
  // SPIRAM_MALLOC_ALWAYSINTERNAL=1024 之下全落内部 RAM;一次攒几百段会把仅剩
  // ~76 KB 的内部 RAM 耗尽——lv_draw_add_task 拿到 NULL 直接解引用(StoreProhibited,
  // 启动即崩,真机实测)。每 kSegBatch 段 dispatch 一次:任务渲染进画布并释放。
  constexpr int kSegBatch = 48;
  int pending = 1;  // 已有清底任务
  for (int w = 0; w < screens::kSpectrumSeriesN; ++w) {
    dsc.color = kLineColors[w % 3];
    for (int i = 0; i + 1 < screens::kSpectrumPoints; ++i) {
      dsc.p1.x = int32_t(i * kXStep);
      dsc.p1.y = ys[w][i];
      dsc.p2.x = int32_t((i + 1) * kXStep);
      dsc.p2.y = ys[w][i + 1];
      lv_draw_line(&layer, &dsc);
      if (++pending >= kSegBatch) {
        dispatch();
        pending = 0;
      }
    }
  }
  dispatch();
  lv_area_t dirty = {0, int32_t(screens::kSpectrumY0 + inv_min), kWidth - 1,
                     int32_t(screens::kSpectrumY0 + inv_max)};
  lv_obj_invalidate_area(target, &dirty);  // 绝对坐标(画布位于 x=0,y=kSpectrumY0)
#endif
  // 遥测(语义对齐旧直渲染:帧=总耗时,传屏=其中传输相关段):
  // frame_us = lv_refr_now 全程(渲染+flush 提交+等缓冲释放);dma_us = 其间
  // LV_EVENT_FLUSH_START..FINISH(提交+RGB565 字节序交换)与
  // LV_EVENT_FLUSH_WAIT_START..FINISH(等上一个 draw buffer 的 DMA 完成)
  // 的累计,由 flush_timing_cb 累加。累加器在每帧开头清零,且本函数持锁
  // 期间 GUI 任务不会并发渲染,跨任务污染只在帧间发生、随即被清零。
  flush_dma_accum_us = 0;
  lv_refr_now(nullptr);  // 持锁同步渲染:本帧频谱立刻上屏
  render_frame_us_v = int32_t(esp_timer_get_time() - t0);
  render_dma_us_v = int32_t(flush_dma_accum_us);
  lvgl_port_unlock();
}

uint32_t spectrum_frame_count() { return spectrum_frames; }

void request_screen_dump() { dump_requested = true; }
void render_timing(int32_t& frame_us, int32_t& dma_us) {
  frame_us = render_frame_us_v;
  dma_us = render_dma_us_v;
}

void set_brightness(uint8_t percent) {
  if (!panel_io) return;
  uint8_t level = uint8_t(255 * (percent > 100 ? 100 : percent) / 100);
  esp_lcd_panel_io_tx_param(panel_io, kWriteCmd | (uint32_t(kBrightnessCmd) << 8), &level, 1);
}

}  // namespace board
