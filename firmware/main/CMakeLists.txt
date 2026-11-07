idf_component_register(
  SRCS main.cpp board.cpp board_screen.cpp audio.cpp power.cpp uplink.cpp mic_state.cpp cloud.cpp dms.cpp
       generated/fonts/font_zh_title.c generated/fonts/font_zh_sub.c generated/fonts/font_zh_marquee.c
       generated/fonts/font_clock_num.c generated/fonts/font_zh_label.c
  INCLUDE_DIRS .
  LDFRAGMENTS memory.lf
  REQUIRES esp_lcd esp_driver_gpio esp_driver_i2c esp_driver_i2s esp_driver_spi esp_timer
           esp_app_format nvs_flash log bt esp_wifi esp_netif esp_event esp_http_client mbedtls espressif__cjson
           espressif__mqtt esp_lvgl_port
)
# Waveshare 的触摸配置宏留字段默认值(xiaozhi-esp32 也如此容忍)。
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-missing-field-initializers)
