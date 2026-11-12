cmake_minimum_required(VERSION 3.22)

# YahaDesk:Mac mini 的无线麦克风固件(基于 OpenCharm 的 ESP-IDF 工程)。
# 目标板:Waveshare ESP32-S3-Touch-AMOLED-2.16。用 ESP-IDF 6.1 构建:
#   idf.py build && idf.py flash monitor
set(PROJECT_VER "0.5.3")  # 与 Mac 侧统一版本(make-app.sh VERSION 同值)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# 只构建 main 实际用到的组件,不带上 IDF 自带的全部。
idf_build_set_property(MINIMAL_BUILD ON)
project(yahadesk)
