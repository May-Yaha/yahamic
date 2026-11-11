# test:demo 与可行性验证

这里放「先证明能不能做」的一次性工程:真机/硬件上的可行性验证、协议或系统框架的探针。
产品代码与单元测试不放这里(单元测试跟着各端走:`apps/macos/Tests`、`apps/ios/Tests`、`firmware/tests`)。

约定:

- 每个主题一个目录 `test/<主题>/`,自带 README:要回答的问题、怎么跑、结论与踩过的坑。
- 能独立构建,不依赖也不修改 `apps/` 与 `firmware/` 的产物;不进 CI,不进发布包。
- 跑完把结论写回对应需求文档(`docs/requirements/<需求>/`),这里的 README 保留原始数据与复测步骤。
- 用跟产品不同的 bundle id、BLE UUID,避免与正式 App 或设备互相干扰。

| 目录 | 问题 | 结论 |
| --- | --- | --- |
| [phone-mic-ptt](phone-mic-ptt/README.md) | 手机锁屏后能否经 BLE 讲话键用 PushToTalk 开始采集 | 可以,两条路线锁屏每轮都出首包,首包约 950 ms;见[需求](../docs/requirements/desk-phone-mic-2026-11-11/README.md) |
