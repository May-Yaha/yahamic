"""Check emitted glyph coverage and advances, including actual LVGL pair kerning."""

from pathlib import Path
import re

def numbers(body):
    return [int(x, 0) for x in re.findall(r'-?0x[0-9a-f]+|-?\d+', body)]

class Font:
    def __init__(self, path):
        s = Path(path).read_text()
        self.height = int(re.search(r'\.line_height = (\d+)', s)[1])
        glyphs = re.search(r'glyph_dsc\[\] =\s*\{(.*?)\n\};', s, re.S)[1]
        self.advances = [int(x) for x in re.findall(r'\.adv_w = (\d+)', glyphs)]
        self.cmaps = []
        cmaps = re.search(r'cmaps\[\] =\s*\{(.*?)\n\};', s, re.S)[1]
        for block in re.findall(r'\{([^{}]+)\}', cmaps):
            start = int(re.search(r'\.range_start = (\d+)', block)[1])
            length = int(re.search(r'\.range_length = (\d+)', block)[1])
            first = int(re.search(r'\.glyph_id_start = (\d+)', block)[1])
            name = re.search(r'\.unicode_list = (\w+)', block)[1]
            offsets = None if name == 'NULL' else numbers(re.search(name+r'\[\] =\s*\{(.*?)\};', s, re.S)[1])
            self.cmaps.append((start, length, first, offsets))
        self.kerns = {}
        if 'kern_pair_glyph_ids[]' in s:
            ids = numbers(re.search(r'kern_pair_glyph_ids\[\] =\s*\{(.*?)\};', s, re.S)[1])
            values = numbers(re.search(r'kern_pair_values\[\] =\s*\{(.*?)\};', s, re.S)[1])
            scale = int(re.search(r'\.kern_scale = (\d+)', s)[1])
            self.kerns = {(a,b): (v*scale)>>4 for a,b,v in zip(ids[::2], ids[1::2], values)}

    def glyph(self, char):
        code = ord(char)
        for start, length, first, offsets in self.cmaps:
            relative = code - start
            if 0 <= relative < length:
                if offsets is None:
                    return first + relative
                if relative in offsets:
                    return first + offsets.index(relative)
        raise ValueError(f'missing glyph {char} U+{code:04X}')

    def check(self, text, limit):
        glyphs = [self.glyph(c) for c in text]
        width = sum((self.advances[g] + self.kerns.get((g, glyphs[i+1] if i+1<len(glyphs) else 0), 0) + 8)>>4 for i,g in enumerate(glyphs))
        print(f'{text}: width={width}/{limit}px line_height={self.height}px')
        assert width <= limit

root = Path(__file__).resolve().parents[2]
base = root / 'firmware/main/generated/fonts'
small = Font(base / 'font_zh_label.c')
sub = Font(base / 'font_zh_sub.c')
title = Font(base / 'font_zh_title.c')
marquee = Font(base / 'font_zh_marquee.c')
assert marquee.cmaps == sub.cmaps  # the notice marquee body shows any card text: same glyph set as font_zh_sub
assert small.height <= 24  # the notification badge and source row are 24 px high
small.check('雅', 24)
small.check('雅哈', 340)
for text in ['电量100%  联网  蓝牙-127', '充电100%  离线  待连接', '外接电源  离线  待连接']:
    small.check(text, 424)  # workbench footer
# Workbench overview rows: title 90 px, text 270 px; alert row 380 px; alert hint/time column 120 px.
for text in ['任务', '采集', '处理', 'GLM', '小程序', '设备']:
    sub.check(text, 90)
for text in ['离线', '等待数据', '暂不可用', 'CPU100% 内存100%', '电脑未连接', '20 待核对 · 20 暂停']:
    sub.check(text, 270)
for text in ['告警 20 条', '无告警', '数据180分钟未更新', '告警']:
    sub.check(text, 380)
for text in ['23:59', '长按重试', '长按取消', '长按暂停', '长按恢复', '长按补跑']:
    sub.check(text, 120)
# Home: microphone card, the screen-off card, the Zhi.AI entry row and overview title.
sub.check('麦克风', 260)
for text in ['按住 Fn 讲话', '麦克风未连接', '已连接 · 静音', '等待电脑连接']:
    sub.check(text, 260)
for text in ['息屏', '省电 · 触摸唤醒']:
    sub.check(text, 260)
sub.check('工作台', 90)
for text in ['告警 20 条', '无告警', '数据180分钟未更新', '离线', '等待数据']:
    sub.check(text, 270)
sub.check('Zhi.AI 工作台', 424)
# Home header: 72 px clock on the left, date and weekday right-aligned in 184 px.
clock = Font(base / 'font_clock_num.c')
clock.check('23:59', 240)
for text in ['12月31日', '星期三', '等待校时']:
    sub.check(text, 184)
for text in ['电池 充电中 100%', '外接电源', '电池 --', '网络 已连接',
             '网络 未连接', '蓝牙 -127 dBm', '蓝牙 待连接', '电脑电量 100% 充电中', '电脑电量 100% 已接电',
             '鼠标 100% 键盘 100%', '固件 0.0.0', '22/22', '在电脑上输入配对码', '请在电脑上运行 Yaha Desk']:
    sub.check(text, 424)
# Notice card source, buttons and speed controls.
small.check('雅哈', 340)
for text in ['上一篇', '下一篇']:
    sub.check(text, 100)
for text in ['慢', '中', '快']:
    sub.check(text, 64)
for text in ['蓝牙配对', '雅哈麦克风', '寻找电脑', '已静音', '讲话中']:
    title.check(text, 480)

# Cloud strings shown verbatim must exist in font_zh_sub, or they render blank. The cloud service lives
# outside this public repository, so its display contract is checked in as a versioned text fixture.
texts = [
    line.strip() for line in (Path(__file__).with_name('cloud_display_strings.txt')).read_text().splitlines()
    if line.strip() and not line.startswith('#')
]
# desk_operate results replace the alert page header (380 px); firmware adds its own local states.
operate = ['正在提交', '未送达，请重试', '操作失败，稍后重试']
operate += [text for text in texts if text.startswith(('已', '无权', '操作', '状态'))]
assert '已提交重试' in operate and '状态已变化，请刷新' in operate, 'desk_operate messages not found'
for text in set(operate):
    sub.check(text, 380)
assert any('断流' in t for t in texts), 'monitor.go strings not found'
for text in texts:
    for char in text:
        sub.glyph(char)
print(f'{len(texts)} cloud strings covered by font_zh_sub')
print('Chinese UI glyph and width checks passed')
