#pragma once
#include <string>
#include "cJSON.h"

// 网盘设备服务(DMS / IoT Core):出厂身份签 PoP、存凭据、MQTT 在线与指令。线上格式见 dms_wire.h,
// 契约见 docs/requirements/desk-pan-dms-2026-11-05/README.md。
namespace dms {
// 出厂证书 DER;没有 fac 分区时为空。BLE identity 特征读它。
const std::string& identity_cert();
// provision 特征里的 dms_proof / dms / dms_reset,BLE host 任务里调;false 即拒绝写入。
bool provision(const std::string& op, const cJSON* j);
// 云端任务每 100 ms 调一次,讲话时也调:签名、连接、presence 与指令都在这里。
void cycle(const std::string& firmware, bool wifi_up, bool speaking);
// cloud 状态 JSON 加 dms / device_id / proof。
void add_status(cJSON* j);
// desk_monitor 上报加 ssid;已绑定时加 dms / pan_device。不带 proof。
void add_report(cJSON* j);
}  // namespace dms
