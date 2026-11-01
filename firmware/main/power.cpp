#include "power.h"

#include "esp_log.h"

namespace power {
namespace {

constexpr const char* kTag = "power";
constexpr uint16_t kAddress = 0x34;
constexpr int kTimeoutMs = 50;

// AXP2101 寄存器(数据手册;同 XPowersLib 驱动与 OpenCharm 的 power.cpp)。
constexpr uint8_t kStatus1 = 0x00;      // bit 5 VBUS good, bit 3 battery present
constexpr uint8_t kStatus2 = 0x01;      // bits 7..5: 1 charging, 2 discharging; bit 3 VBUS not in
constexpr uint8_t kAdcEnable = 0x30;    // bit 0 battery voltage, bit 4 die temperature
constexpr uint8_t kPercent = 0xA4;      // 电量计的电池百分比
constexpr uint8_t kLdoEnable = 0x90;    // bit 0:ALDO1(板上麦克风的供电)

i2c_master_dev_handle_t chip = nullptr;

bool read_reg(uint8_t reg, uint8_t& out) {
  return i2c_master_transmit_receive(chip, &reg, 1, &out, 1, kTimeoutMs) == ESP_OK;
}

bool write_reg(uint8_t reg, uint8_t value) {
  uint8_t data[2] = {reg, value};
  return i2c_master_transmit(chip, data, 2, kTimeoutMs) == ESP_OK;
}

}  // namespace

bool init(i2c_master_bus_handle_t bus) {
  i2c_device_config_t device = {};
  device.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  device.device_address = kAddress;
  device.scl_speed_hz = 400 * 1000;
  if (i2c_master_bus_add_device(bus, &device, &chip) != ESP_OK) {
    chip = nullptr;
    return false;
  }
  uint8_t adc = 0;
  if (!read_reg(kAdcEnable, adc) || !write_reg(kAdcEnable, adc | 0x01 | 0x10)) {
    ESP_LOGE(kTag, "no AXP2101 on I2C 0x34");
    // 不在就别每秒都去等它:从总线上摘下来。
    i2c_master_bus_rm_device(chip);
    chip = nullptr;
    return false;
  }
  // Yahamic:麦克风由 ALDO1 供电(xiaozhi-esp32 会显式打开它),不依赖出厂状态。
  uint8_t ldos = 0;
  if (read_reg(kLdoEnable, ldos) && !(ldos & 0x01)) {
    write_reg(kLdoEnable, ldos | 0x01);
    read_reg(kLdoEnable, ldos);
  }
  ESP_LOGI(kTag, "AXP2101 ready, mic power (ALDO1) %s", (ldos & 0x01) ? "on" : "off");
  return true;
}

Reading read() {
  Reading r;
  uint8_t s1 = 0;
  uint8_t s2 = 0;
  if (chip && read_reg(kStatus1, s1) && read_reg(kStatus2, s2)) {
    bool present = s1 & (1 << 3);
    r.usb = (s1 & (1 << 5)) && !(s2 & (1 << 3));
    r.charging = (s2 >> 5) == 0x01;
    uint8_t percent = 0;
    if (present && read_reg(kPercent, percent)) r.percent = percent > 100 ? 100 : percent;
  }
  return r;
}

}  // namespace power
