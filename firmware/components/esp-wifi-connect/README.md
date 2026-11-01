# esp-wifi-connect (Yahamic 的副本)

来自 [78/esp-wifi-connect](https://github.com/78/esp-wifi-connect) 3.3.1(MIT,见
`LICENSE`;OpenCharm 按同一策略拷贝,我们沿用其副本)。代码保持上游原样,仅包含上游
一处带 `OpenCharm:` 标记的修复(`wifi_configuration_ap.cc` 中页面 JSON 的网络名转义)。

只有 `assets/wifi_configuration.html` 和 `assets/wifi_configuration_done.html` 是
Yahamic 自己的页面(中文,同一套请求接口),其中"配对码"字段借道组件现成的
`ota_url` 存储(NVS `wifi` 命名空间),固件把它当配对码读取。
`main/idf_component.yml` 通过 `override_path` 指向这里。
