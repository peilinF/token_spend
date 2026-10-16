# Codex 7d 额度更新修复

工作目录 `/Users/peilin/Desktop/token_spend`。本文件为本次小范围修复的权威交接。用户要求修复 7d 显示停在 67%，保持已正确的 5h。

## 依据与设计

2026-10-09 本地库 `codex_rate_limits`：short used=94、reset=1791546881；long used=33、reset=1792030118。最新真实日志的 secondary used=61、reset=1792029929，故应剩39%。差189秒超过 `CodexQuota.mergeRateSnapshot` 的120秒容差，因此新周额度被旧reset值持续压住。

`Core/Models.swift` 合并每个short/long窗口时改用各自 `observed_ts`。较新的观测胜出，较旧观测不得覆盖；reset保留服务端原值，不靠它判断数据新旧。同时间戳选 incoming（允许从最新原始快照修复旧缓存）。窗口缺失时保留该窗口值及原观测时间。旧窗口缺少observed_ts时，以合并前record.observed_ts为兼容基线，并将基线写入该窗口，不能因只更新5h便使7d时间跟着变新。主record的observed_ts仍保留最大值。窗口分类仍按window_minutes，family独立，剩余=100-used。

`Sources/CodexSource.swift` 启动/刷新时检测缺少窗口级时间的旧缓存，复用已有本地tail prime机制读取最新快照修复；不改变token贡献、游标、版本、其他工具数据或用户偏好，不引入网络查询/依赖。仍缺数据时保留已知额度。

## 交接与验收

Luna Max负责 Models.swift、CodexSource.swift、隔离回归、此文档状态。保留共享目录全部既有修改，先核实实现与测试入口。`bash Tests/run.sh` 覆盖189秒周reset倒退、同时间戳恢复、旧事件延迟、5h/7d分开到达、缺失窗口保留时间、窗口次序和不同family、legacy缓存启动repair。测试只用临时DB/日志。运行 `swift build -c release`、`git diff --check`，报告实际结果。不启动/停止真实app，不修改真实DB。主代理审查后打包重启，检查真实缓存7d与最新日志一致、5h保持正确，并重新运行只读token审计确认统计无回归。

- [x] 调查与设计。
- [x] 实现与隔离验证（Luna Max 报告41项隔离测试通过；主代理完成审查、release打包与diff check）。
- [x] 主代理审查、打包重启与真实额度验收（2026-10-10）。

## 真实验收

2026-10-10 已运行 `bash build.sh` 构建并以 TokenSpend Dev 签名，停止旧进程并启动新应用。窗口实际显示 **7d 剩38%**，与最新日志 long.used_percent=62 一致；昨天39%之后发生的真实使用使剩余额度降低1个百分点，未硬编码为39%。5h也继续随最新快照变化，截图验收时显示剩95%。

旧long used=33/reset=1792030118已被最新long used=62/reset=1792029929替换；short/long均存有自己的observed_ts。修复前后采样与旧应用保存在 `.build/codex-quota-validation/`。`--audit-codex .build/codex-quota-validation/audit-after.json` 退出0，parser=4、ready、consistent=true，无差值和blocker，token统计无回归。`git diff --check`通过。
