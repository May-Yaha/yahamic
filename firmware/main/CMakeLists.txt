idf_component_register(
  SRCS main.cpp board.cpp board_screen.cpp audio.cpp power.cpp uplink.cpp protocol.cpp mic_state.cpp
       generated/fonts/font_zh_title.c generated/fonts/font_zh_sub.c
       generated/fonts/font_clock_num.c
  INCLUDE_DIRS .
  REQUIRES esp_lcd esp_driver_gpio esp_driver_i2c esp_driver_i2s esp_driver_spi esp_timer
           esp_app_format nvs_flash log lwip mbedtls mdns esp_wifi
           esp_lvgl_port
)
# Waveshare 的触摸配置宏留字段默认值(xiaozhi-esp32 也如此容忍)。
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-missing-field-initializers)
