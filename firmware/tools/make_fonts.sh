#!/usr/bin/env bash
# make_fonts.sh — 用全局 lv_font_conv 1.5.3 生成 LVGL 9 的 C 字体,输出到
# firmware/main/generated/fonts/。幂等:每次全量重新生成三个 .c,可重复执行。
#
# 替代旧 tools/gen_text.swift 的预渲染位图流程(text_zh.h 已删除)。
# 字体:Noto Sans CJK SC Medium(SIL OFL 1.1,见 tools/fonts/OFL.txt)。.otf 本体
# 15.8 MB 不入库(.gitignore):从 https://github.com/notofonts/noto-cjk/releases 下载
# NotoSansCJKsc-Medium.otf 放到 tools/fonts/ 即可重新生成;生成的 .c 已提交,日常
# 构建不需要字体文件。
# 参数:--bpp 4,不加 --no-compress(默认压缩,省 flash;固件需开
# CONFIG_LV_USE_FONT_COMPRESSED,见 sdkconfig.defaults)。
#
# 13 个屏幕短语 key → 中文文本对照(逐字抄自旧 tools/gen_text.swift L12-28 的
# Phrase 表,任务3 静态屏的 key→文本映射表以这里为唯一真源):
#   boot       → 雅哈麦克风
#   muted      → 已静音
#   searching  → 寻找 Mac 中
#   setup      → 配网模式
#   joining    → 正在连接 Wi-Fi
#   nowifi     → 未连接 Wi-Fi
#   on_air_s   → 讲话中
#   hold_fn    → 按住 Fn 键讲话
#   run_app    → 请在 Mac 上运行 Yaha 家居
#   hold_setup → 长按按键 5 秒进入配网
#   hotspot    → 热点
#   password   → 密码
#   firmware   → 固件

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE="$(dirname "$HERE")"
# 在 tools/ 目录下用相对路径调用:lv_font_conv 会把 --font 参数原样写进生成的 .c
# 头注释,用相对路径避免把本机绝对路径(用户名、目录结构)带进开源仓库。
cd "$HERE"
FONT="fonts/NotoSansCJKsc-Medium.otf"
OUT="$FIRMWARE/main/generated/fonts"
mkdir -p "$OUT"

LV_FONT_CONV="${LV_FONT_CONV:-lv_font_conv}"
command -v "$LV_FONT_CONV" >/dev/null || {
  echo "error: 找不到 lv_font_conv(npm i -g lv_font_conv@1.5.3)" >&2
  exit 1
}

# 上面 13 个短语的全部非 ASCII 字符(去重);ASCII 部分由 --range 0x20-0x7E 覆盖。
ZH_CHARS='雅哈麦克风已静音寻找中配网模式正在连接未讲话按住键请上运行家居长秒进入热点密码固件'

# 1) 标题字体 ~48px:13 短语全部字符 + ASCII 0x20-0x7E
"$LV_FONT_CONV" --font "$FONT" --size 48 --bpp 4 \
  --range 0x20-0x7E --symbols "$ZH_CHARS" \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_title \
  -o "$OUT/font_zh_title.c"

# 2) 副标题字体 ~28px:同一字符子集
"$LV_FONT_CONV" --font "$FONT" --size 28 --bpp 4 \
  --range 0x20-0x7E --symbols "$ZH_CHARS" \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_sub \
  -o "$OUT/font_zh_sub.c"

# 3) 时钟数字字体 ~72px:仅 0-9 与冒号(0x30-0x3A)
"$LV_FONT_CONV" --font "$FONT" --size 72 --bpp 4 \
  --range 0x30-0x3A \
  --format lvgl --lv-include lvgl.h --lv-font-name font_clock_num \
  -o "$OUT/font_clock_num.c"

echo "done: $(ls -1 "$OUT")"
