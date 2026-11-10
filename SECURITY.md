# 安全策略

## 报告漏洞

请不要在公开 issue 里披露漏洞。用 GitHub 的私密报告:仓库 **Security → Report a vulnerability**。
请附上影响的组件(固件 / Mac App / iOS / 云端接口)、版本号与复现步骤。

## 范围

- 固件的 BLE 配对与 GATT 访问控制、设备凭据存储。
- Mac App 的本机控制接口(`control.sock`)、钥匙串中的凭据、辅助功能与键盘注入。
- 设备与 Mac 的 OAuth / 令牌交付流程。

云端服务 `hub.flyaha.top` 不在本仓库,相关问题同样可以通过上述渠道报告。

## 支持的版本

只修最新发布版本。
