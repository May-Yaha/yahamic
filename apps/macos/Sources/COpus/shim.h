// libopus 解码 API 的最小声明(brew install opus)。不 include <opus/opus.h>:
// 机器上没有 pkg-config,systemLibrary 找不到 Homebrew 头文件路径;
// 签名与 opus.h 一致,链接走 Package.swift 的 -L/opt/homebrew/lib。
#pragma once
#include <stdint.h>

typedef struct OpusDecoder OpusDecoder;
OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error);
int opus_decode(OpusDecoder *st, const unsigned char *data, int32_t len,
                int16_t *pcm, int frame_size, int decode_fec);
void opus_decoder_destroy(OpusDecoder *st);
