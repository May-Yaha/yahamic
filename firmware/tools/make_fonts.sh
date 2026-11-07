#!/usr/bin/env bash
# make_fonts.sh — 用全局 lv_font_conv 1.5.3 生成 LVGL 9 的 C 字体,输出到
# firmware/main/generated/fonts/。幂等:每次全量重新生成五个 .c(副题字体含 GB2312 一级字),可重复执行。
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
#   searching  → 寻找电脑
#   pairing    → 蓝牙配对
#   setup      → 配网模式
#   joining    → 正在连接 Wi-Fi
#   nowifi     → 未连接 Wi-Fi
#   on_air_s   → 讲话中
#   hold_fn    → 按住 Fn 键讲话(已改为 hold_key → 按住讲话键,字形是子集)
#   run_app    → 请在电脑上运行 Yaha Desk
#   hold_setup → 长按按键 5 秒进入配网
#   hotspot    → 热点
#   password   → 密码
#   firmware   → 固件

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 在 tools/ 目录下用相对路径调用:lv_font_conv 会把 --font 参数原样写进生成的 .c
# 头注释,用相对路径避免把本机绝对路径(用户名、目录结构)带进开源仓库。
cd "$HERE"
FONT="fonts/NotoSansCJKsc-Medium.otf"
OUT="../main/generated/fonts"  # 相对 tools/:同上,不把本机路径写进 .c
mkdir -p "$OUT"

LV_FONT_CONV="${LV_FONT_CONV:-lv_font_conv}"
command -v "$LV_FONT_CONV" >/dev/null || {
  echo "error: 找不到 lv_font_conv(npm i -g lv_font_conv@1.5.3)" >&2
  exit 1
}

# 上面 13 个短语的全部非 ASCII 字符(去重);ASCII 部分由 --range 0x20-0x7E 覆盖。
ZH_CHARS='雅哈麦克风已静音寻找中配网模式正在连接未讲话按住键请上运行桌面长秒进入热点密码固件蓝牙对电脑'

# 副题字体同时承担云端卡片(AI 日报、agent 消息)的任意中文:GB2312 一级字 3755 个
# + 常用中文标点(、。〈〉《》「」『』【】、全角符号、·—…‘’“”)。库外生僻字显示为空。
GB2312_L1="$(python3 -c "print(''.join(bytes([r, c]).decode('gb2312') for r in range(0xB0, 0xD8)
  for c in range(0xA1, 0xFF) if not (r == 0xD7 and c > 0xF9)))")"
CN_PUNCT='0xB7,0x2014,0x2018-0x201D,0x2026,0x3001-0x3002,0x3008-0x3011,0xFF01-0xFF5E'

# 1) 标题字体 ~48px:13 短语全部字符 + ASCII 0x20-0x7E
"$LV_FONT_CONV" --font "$FONT" --size 48 --bpp 4 \
  --range 0x20-0x7E --symbols "$ZH_CHARS" \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_title \
  -o "$OUT/font_zh_title.c"

# 2) 副标题 / 卡片字体 ~28px:13 短语 + GB2312 一级字 + 中文标点
"$LV_FONT_CONV" --font "$FONT" --size 28 --bpp 4 \
  --range 0x20-0x7E,"$CN_PUNCT" --symbols "$ZH_CHARS$GB2312_L1" \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_sub \
  -o "$OUT/font_zh_sub.c"

# 2b) 通知卡跑马灯正文 32px:与副题同字集(正文可能是任意中文)。
"$LV_FONT_CONV" --font "$FONT" --size 32 --bpp 4 \
  --range 0x20-0x7E,"$CN_PUNCT" --symbols "$ZH_CHARS$GB2312_L1" \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_marquee \
  -o "$OUT/font_zh_marquee.c"

# 3) 时钟数字字体 ~72px:仅 0-9 与冒号(0x30-0x3A)
"$LV_FONT_CONV" --font "$FONT" --size 72 --bpp 4 \
  --range 0x30-0x3A \
  --format lvgl --lv-include lvgl.h --lv-font-name font_clock_num \
  -o "$OUT/font_clock_num.c"

# 4) 辅助标签 18px:首页/工作台状态、像素时钟标题及通知来源。
"$LV_FONT_CONV" --font "$FONT" --size 18 --bpp 4 \
  --range 0x20-0x7E --symbols '像素时钟处理器内存鼠标键盘雅哈电量充联网离线蓝牙待连接外源日报最新文章' \
  --format lvgl --lv-include lvgl.h --lv-font-name font_zh_label \
  -o "$OUT/font_zh_label.c"
# lv_font_conv appends an empty EOF line; keep the new source whitespace-clean.
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes().rstrip(b"\n")+b"\n")' "$OUT/font_zh_label.c"

echo "done: $(ls -1 "$OUT")"
