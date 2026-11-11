#!/bin/bash
# 同一轮留存:设备解码 PCM、BlackHole 实际输出、TTS 参考音和链路指标。
set -euo pipefail
cd "$(dirname "$0")/.."

ROUNDS="${1:-3}"
DURATION_SECONDS="${2:-60}"
OUTPUT_DIR="${3:-$PWD/audio-stress-$(date +%Y%m%d-%H%M%S)}"
SOCKET="$HOME/Library/Application Support/YahaDesk/control.sock"
BLACKHOLE_INPUT="${BLACKHOLE_INPUT:-:BlackHole 2ch}"

for command in nc ffmpeg jq python3; do
  command -v "$command" >/dev/null || { echo "缺少命令:$command" >&2; exit 2; }
done
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ && "$DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "用法:$0 [轮数] [每轮秒数] [输出目录]" >&2
  exit 2
}
[ -S "$SOCKET" ] || { echo "Yaha Desk 控制接口不存在:$SOCKET" >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

capture_pid=""
cleanup() {
  if [ -n "$capture_pid" ]; then kill "$capture_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

round=1
while [ "$round" -le "$ROUNDS" ]; do
  target="$OUTPUT_DIR/round-$(printf '%02d' "$round")"
  mkdir -p "$target"
  echo "▸ 第 $round/$ROUNDS 轮:${DURATION_SECONDS}s"
  ffmpeg -y -hide_banner -loglevel error -f avfoundation -i "$BLACKHOLE_INPUT" \
    -t "$((DURATION_SECONDS + 2))" -af 'aresample=async=1000:first_pts=0' \
    -ar 16000 -ac 1 -c:a pcm_s16le "$target/blackhole.wav" &
  capture_pid=$!
  sleep 1
  # 10 分钟等长测有6000次 async sleep，调度误差会累积；预留20%+60s收尾时间。
  control_timeout=$((DURATION_SECONDS + DURATION_SECONDS / 5 + 60))
  printf '{"cmd":"stress","seconds":%s,"source":"tts"}\n' "$DURATION_SECONDS" \
    | nc -w "$control_timeout" -U "$SOCKET" > "$target/stress.json"
  wait "$capture_pid"
  capture_pid=""

  decoded=$(jq -er '.decodedPath' "$target/stress.json")
  cp "$decoded" "$target/decoded.wav"
  jq -r '.referenceText // ""' "$target/stress.json" > "$target/reference.txt"
  /usr/bin/say -v Tingting -f "$target/reference.txt" -o "$target/source.aiff"
  ffmpeg -y -hide_banner -loglevel error -i "$target/source.aiff" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$target/source.wav"
  rm "$target/source.aiff"
  python3 scripts/audio_quality.py --decoded "$target/decoded.wav" \
    --blackhole "$target/blackhole.wav" --source "$target/source.wav" \
    --output "$target/quality.json" >/dev/null
  if [ "${ENHANCE:-0}" = "1" ]; then
    jq -nc --arg path "$decoded" '{cmd:"enhance_capture",path:$path}' \
      | nc -w 300 -U "$SOCKET" > "$target/enhancement.json"
    enhanced=$(jq -er '.path' "$target/enhancement.json")
    cp "$enhanced" "$target/enhanced.wav"
    python3 scripts/audio_quality.py --decoded "$target/decoded.wav" \
      --blackhole "$target/blackhole.wav" --source "$target/source.wav" \
      --enhanced "$target/enhanced.wav" --output "$target/quality.json" >/dev/null
  fi
  jq '{underrunsDelta,overflowsDelta,droppedFramesDelta,bufferMsMin,bufferMsP05,bufferMsP50,bufferMsP95,bufferMsMax,diagDelta}' \
    "$target/stress.json"
  round=$((round + 1))
done

echo "✓ 压测证据:$OUTPUT_DIR"
