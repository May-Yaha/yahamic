#pragma once

#include <cstdint>

#include "driver/i2c_master.h"

// 电池读数(OpenCharm firmware/device/main/power.cpp 的裁剪版):这台麦克风可以
// 插电用,也可以装锂电池随身放——屏幕要能报电量。AXP2101 在 I2C 0x34。
namespace power {

struct Reading {
  int percent = -1;     // -1 = 没装电池
  bool charging = false;
  bool usb = false;
};

bool init(i2c_master_bus_handle_t bus);
Reading read();

}  // namespace power
