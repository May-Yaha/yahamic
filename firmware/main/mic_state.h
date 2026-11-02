#pragma once

// 静音的唯一入口:板上按键、Mac 的 Fn 遥控、断链自动静音都走这里,
// 采集(audio)与上报(uplink)在一把锁里一起切换,两条路径不会交错成不一致。
namespace mic {

void set_muted(bool muted);
void toggle();  // 按键短按

}  // namespace mic
