# 基线代码事实清单（baseline-code-audit，只读核查）

> ⚠️ **行号已失效（2026-11-01 标注）**：本文写于 board.cpp 758 行时代；此后固件经多轮真实修改（波形 LUT 优化、频谱重心、Dashboard 在途功能），board.cpp 已达 1094 行，文中全部行号锚点漂移（如 `blit()` 281→326、`render_waves_direct` 571→846）。**语义事实经 2026-11-01 审计复核仍然成立**，请按符号名检索，勿按行号引用。最新审计与决策记录见 `evolution-2026-11-01-audit-cleanup.md`。
>
> 范围：`firmware/main/board.cpp`(758 行)、`board.h`、`audio.cpp`(348 行)、`audio.h`、`main.cpp`；另核 `Kconfig.projbuild` 与 `sdkconfig` 确认编译分支。**未修改 firmware/ 下任何文件。**
> 行号以当前工作区文件为准，供后续任务（频谱重心提取、双缓冲流水线）直接引用，避免实现时猜测。

## 1. 32 对数频带：计算位置、数据结构与更新节奏

- **位置**：`firmware/main/audio.cpp`
  - 手写基-2 迭代 FFT：`fft()` @ audio.cpp:126（位反转 + 每级旋转因子递推，显示精度）。
  - 频带计算：`update_spectrum()` @ audio.cpp:158，在**采集线程** `capture_loop()`（audio.cpp:190 起）每次成功读帧后调用（audio.cpp:230）。
- **数据流**（常量 @ audio.cpp:29-33）：
  - `kRate=16000`，`kFrameSamples=960`（60ms Opus 帧长），`kFftN=1024`（64ms 窗），`kBars=32`。
  - 滑窗 `int16_t window[1024]`（audio.cpp:47）：每帧 `memmove` 前移 960 样本、追加 960 新样本（audio.cpp:228-229，仅 64 样本重叠）。
  - Hann 窗（静态一次性构建）→ FFT → 取 bin 1..511 功率 → 32 个对数频带：`lo=50Hz, hi=8kHz`（比值 160），边界 `50·160^(b/32)`；带内取 bin **功率峰值**（非均值）。
  - 归一化：`10·log10(peak/2^26 + 1e-12)`，-72..-12 dB → 0..1，clamp。
- **更新节奏**：每 60ms 音频帧一次 ≈ **16.7 Hz**，与渲染帧率解耦（audio.cpp:227 注释明示；board.h 也注明）。33ms 渲染循环下同一份 bars 会被渲染约 2 次。
- **共享/导出**：`float bars[32]` + `std::mutex bars_lock`（audio.cpp:45-46）保护；`audio::spectrum(float*, int)`（audio.cpp:311）加锁拷贝导出。`set_muted(true)` 清零 window 与 bars（audio.cpp:284-291）。
- 频谱在 Opus 编码**前**对原始 PCM 计算（audio.h 注释）。

## 2. 传屏是否阻塞、同步方式（结论：逐带阻塞串行，无渲染/DMA 重叠）

- 两条传屏路径，均为「提交 → 阻塞等完成」逐带串行：
  - `blit()` @ board.cpp:281（`draw()`/`draw_level()`/未用的 `draw_waves()` 走这里）：memcpy canvas→band + 逐 16bit 字节交换（RGB565 小端→面板大端）→ `esp_lcd_panel_draw_bitmap(panel,0,y,kWidth,y+lines,band)`（board.cpp:293）→ **`xSemaphoreTake(blit_done, pdMS_TO_TICKS(100))` 阻塞**（board.cpp:294，100ms 超时，返回值未检查）。
  - `render_waves_direct()` @ board.cpp:571（Live 屏默认路径）：每条 80 行带 memset 清底 → 三条正弦查表画线（颜色预字节交换，绕过 PSRAM canvas）→ `draw_bitmap`（board.cpp:654）→ 同样的 `xSemaphoreTake` 阻塞（board.cpp:655）。**下一带的清底/画线与上一带 DMA 完全串行**——这正是流水线改造点。
- **同步机制**：二值信号量 `blit_done`（board.cpp:170）；ISR 回调 `on_band_sent`（IRAM_ATTR，board.cpp:208 附近）注册为 `on_color_trans_done`（init_screen，board.cpp:319-322），每带 DMA 完成 `xSemaphoreGiveFromISR`。单 band 缓冲的复用约束：DMA 未读完不得改写（注释：初版花屏原因，同 LVGL 单缓冲+on_color_trans_done 做法）。
- **传输量与时序**：频谱区 kSpecY0=90..kSpecY1=430（board.cpp:85-86）共 340 行 ×480px×2B = 326,400B；QSPI pclk 40MHz（board.cpp:340）×4 数据线 ≈ 20MB/s → 纯传输 ≈16.3ms ≈ 任务所述「传屏 17ms」量级，另加命令阶段+信号量往返。带切分 `kBufferLines=80`（board.cpp:41）：频谱区 340 行→5 带（80/80/80/80/20），整屏 480→6 带；y0 偶对齐、行数取偶（面板坐标要求）。
- SPI：SPI2_HOST、QUAD、`max_transfer_sz = 480×80×2 = 76800`、`trans_queue_depth=10`（但被单缓冲+阻塞节拍实际串行化）。

## 3. 帧缓冲数量、大小与内存位置（当前：单 canvas + 单 band，无双缓冲）

| 缓冲 | 大小 | 分配 | 位置 | 用途 |
|---|---|---|---|---|
| `canvas` | 480×480×2B = **460,800B** | `heap_caps_calloc(..., MALLOC_CAP_SPIRAM)`（board.cpp:370-371） | **PSRAM** | 整屏合成（静态屏文字/频谱柱/波形旧版）；Live 波形路径不用它 |
| `band` | 480×80×2B = **76,800B** | `heap_caps_malloc(..., MALLOC_CAP_DMA \| MALLOC_CAP_INTERNAL)`（board.cpp:372-373） | **内部 SRAM（DMA）** | 唯一 DMA 搬运缓冲，blit 与 render_waves_direct 共用 |

- 注：board.cpp:165 注释仍写「48 行」，实际 `kBufferLines=80`（board.cpp:38-41 注释为最新：80 行=77KB 内部 DMA 内存）。
- sdkconfig：`CONFIG_SPIRAM=y`（OCT 模式）、16MB flash、`# CONFIG_YAHAMIC_SPECTRUM_BARS is not set`（Kconfig 默认 `YAHAMIC_SPECTRUM_WAVES`）→ **`draw_spectrum()`（board.cpp:736）实际编译走 `render_waves_direct`**；`draw_bars`/`draw_waves` 为未编译分支（前者 `#if` 柱状图，后者 `[[maybe_unused]]` canvas 版前身）。

## 4. main.cpp 主循环每帧步骤顺序（kLoopMs=33，main.cpp:46；while @ main.cpp:158）

1. `now = now_ms()`（esp_timer 毫秒）。
2. 按键：`board::key_down()` 原始电平 + 20ms 消抖；短按(<400ms)切 `audio::set_muted`+`uplink::set_muted`；按住 5s `uplink::open_setup()`。
3. `uplink::snapshot()`。
4. 每 1000ms：从原子量刷新电池缓存（真实 I2C 读在独立任务 `battery_task`，Core0、1s 周期，prio 2）。
5. `uplink::consume_dump_request()` → `board::request_screen_dump()`。
6. `compose(screen)` + 字符串指纹；指纹变化（或 dump 请求）才 `board::draw(screen)`（main.cpp:199/201）——整屏重画含 6 带全屏 blit（约 23ms 传输），与频谱渲染同线程顺序执行。
7. 仅 `state == Live`：`audio::spectrum(bars,32)`（mutex 拷贝）→ `board::draw_spectrum(bars,32)`（main.cpp:205）→ `render_waves_direct`（含 5 带 DMA 传屏）。
8. 每 10000ms：遥测日志（`spectrum_frame_count` 差分算 fps、`board::render_timing`、`audio::capture_stats`）。
9. 睡眠：`spent = now_ms()-now; vTaskDelay(kLoopMs - spent)`（main.cpp:226）——睡剩余时间；注释：渲染本身 ~31ms，固定睡 33ms 会只剩 15fps。

**现有耗时插桩点**：
- `board::render_timing(int32_t& frame_us, int32_t& dma_us)`（board.cpp:747）← `render_frame_us_v`/`render_dma_us_v`（board.cpp:159-160）。
  - `frame_us0` @ board.cpp:625（band 循环前）；每带 `t0/t1` 环绕 draw_bitmap+信号量往返（board.cpp:652-656），累加 `draw_us`；`dma_us` 累加的是与 `draw_us` **完全相同的值**（两者恒等，遥测日志里「帧-传屏」差即画线/清底 CPU 时间）。
- `board::spectrum_frame_count()`（board.cpp:742）累计渲染帧数；`audio::capture_stats(avg/min/max ms)` 采集帧间隔遥测（读完即清零）。
- 线程布局：主循环在 app_main 任务（默认优先级）；`capture_loop` prio 6、pin Core1、16KB 内部栈（audio.cpp:268-270，注释：PSRAM 栈在 Core1 出过缓存一致性问题）；battery_task prio 2、Core0。

## 5. 现有相位/时间驱动动画变量（render_waves_direct，后续重心驱动改造的落点）

- **相位**：`flow = fmod(now_us·1e-6 · 0.45, 1.0)`（board.cpp:598）——每帧从 `esp_timer_get_time()` 时间戳**直接推导**，流速恒定 0.45Hz，不跨帧累计（注释：避免浮点漂移）。各波初始相位 = `fmod(flow·speed,1) + offset/2π`，列间固定步进 `cycles/(W-1)` 查 `sin_lut`（`lut_sin` 线性插值）。⇒ 频谱重心→流速/空间周期的改造应沿用「时间戳推导相位」模式以保相位连续。
- **时间平滑（帧率无关，dt clamp [5,200]ms）**：
  - `bands_s[32]`：攻 τ=60ms（×0.83）/ 放 τ=350ms（×0.33）（board.cpp:585-590 一带）。
  - `level_s`：level = 0.6×均值 + 0.4×峰值；攻 60ms / 放 350ms。
- **波形常量**：`kWaves=3`，`kWaveSpecs`（cycles,speed,offset,scale,color）：(1.0,1.00,0.0,1.00,0x07FF 青)、(1.7,1.35,2.1,0.72,0x4C1F 蓝紫)、(2.4,0.80,4.2,0.52,0xFB56 紫粉)。振幅 = max_amp(136px)·scale·(0.06+0.94·level_s)·正弦包络 `wave_env[x]`·(0.55+0.9·相邻频带线性插值)；中心 cy=260。
- **查表**（`init_wave_tables()` 惰性构建，热路径零三角函数/零堆分配）：`sin_lut[1024]`、`wave_env[480]`、`wave_grad[3][6]`（距波心 0..2 亮芯 / 3..5 柔光 1/4 亮度，颜色预字节交换；kCoreHalf=2、kGlowHalf=5，board.cpp:462-464 一带）。静态帧状态：`ys[3][480]`、`last_us`、`spectrum_frames`。
- 未编译分支：`draw_bars`（弹簧 pos/vel，固定步长 0.32/0.70，帧率相关、静默两帧后停刷）；`draw_waves`（canvas 两遍绘制前身，逻辑同 direct 版）。

## 6. 对后续任务的关键提示（事实推论，非猜测）

- 频谱重心（centroid）可直接在 `update_spectrum()` 的 power/bin 循环处并行累加（有 50Hz-8kHz 带限与 dB 归一化前的原始功率可用），沿用 `bars_lock` 导出；上游 16.7Hz 更新，需在 board 侧做时间常数平滑（现有 bands_s/level_s 模式可复用）。
- 双缓冲流水线的最小改法事实基础：单 `band`（76.8KB 内部 DMA）+ 单二值信号量；要重叠需第 2 块 band（内部 DMA 内存预算需另核，boot 后日志有 free internal KB 遥测）或「带 N 提交后先画带 N+1 再等带 N」的乒乓。
- 状态切换整屏 `draw()`（6 带全屏 blit）与频谱渲染同线程，改造后需保持二者不并发写 band。
