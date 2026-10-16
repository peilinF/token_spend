# TokenSpend

一个轻量的 macOS 桌面悬浮圆窗，实时统计 **opencode / codex / cursor** 三个 AI 编码工具的 token 消耗与剩余额度。

纯 Swift 原生实现（AppKit + SwiftUI），零第三方依赖，单二进制约 5MB。

```
   ╭──────╮        点击圆窗展开详情面板
   │ 25M  │        ┌──────────────────────────┐
   │ 今日  │   →    │ Token 消耗      更新于 xx │
   ╰──────╯        │ [日|周|月|年] [精简|全量]  │
     彩色旋转弧     │ opencode  2.6M  消耗中·12s │
                   │ codex    13.2M  ▓▓▓▓▓    │
                   │ cursor    9.2M  ▓▓░░░░   │
                   │ 近 7 天 ▁▃▅▂▇▆█          │
                   └──────────────────────────┘

  周 剩74% ▓░ · 08-30 重置    悬浮窗额度条（常驻/悬浮可切）
```

## 功能

- **悬浮圆窗**：置顶、全 Space 显示、可拖动（位置记忆）、进度环显示当前周期流逝；遮挡时自动暂停动画
- **实时活动指示**：哪个工具正在消耗，对应颜色的能量环弧段绕圆窗旋转（空闲零开销，可选 30/60fps）；详情行显示 `消耗中·Ns`。回合级完成检测，结束后 3 秒内熄灭
- **等待检测**：agent 等待确认时圆窗变橙，单工具显示 `● 工具名`+`等你回答/等你确认`，多工具显示数量与彩色工具名；菜单栏图标同步变橙并带彩点。运行中命令不再误报为等待：opencode 授权看 asking 之后有无新进展（回答后继续跑会熄灭）、codex/cursor 的终端（含后台）执行期抑制、执行子进程存活时不报停滞；codex 的 `apply_patch` 按正常编辑处理不再当授权
- **剩余额度**：
  - codex：短窗口（5h）/ 长窗口（周）各“剩 X%”+ 重置时间（解析 rollout 中 `rate_limits`，按 `limit_id` 家族分桶再按窗口时长归类；无 5h 的计划只显示周窗口）
  - Cursor / Grok：Cursor、Grok、Grok Bot 共用的周额度与重置时间；旧 Cursor 套餐继续显示月度额度与合法的自家/API 用量池
  - 三档显示：常驻在悬浮窗内（默认）/ 悬浮时显示 / 隐藏；详情面板与状态栏菜单始终有完整/摘要展示
- **个性化**：偏好设置面板可改工具颜色（任意色，ColorPicker）与动画帧率（30 省电 / 60 流畅），实时生效、持久化；一键恢复默认颜色
- **周期切换**：今日 / 本周（周一起始）/ 本月 / 今年，本地时区
- **双统计口径**：精简 = 不含缓存的输入 + 输出；全量 = 精简 + cache read/write。token 数量不等于费用或额度
- **数量单位**：使用「万／亿」，例如 4,000,000 tokens 显示为「400万」
- **详情面板**：分工具明细、占比条、额度条、近 7 天堆叠柱状图、费用、Cursor 登录状态
- **菜单栏**：额度摘要行、等待行、切周期/口径、阈值与同步间隔、显示/隐藏圆窗、偏好设置、开机自启、立即刷新、导出诊断日志
- **CLI 调试**：`--print-summary` / `--print-live` / `--print-waiting` / `--print-quota` / `--reconcile` / `--audit-codex [报告路径]`

## 数据来源

| 工具 | 来源 | 方式 |
|---|---|---|
| opencode | `~/.local/share/opencode/opencode.db` | 只读 SQLite，按 `time_updated` 水位增量；活动看最近 part / 进程 `running`；等待看 `question` part |
| codex | `~/.codex/sessions/**/*.jsonl` | v4 用固定大小的完整行边界和持久 raw-prefix SHA-256 校验做字节增量扫描；显式 fork 子会话仅跳过与父原始事件序列一致的连续前缀，并保留后续新增用量；备份成功、全量重算暂存后原子提交；读取失败保留上次统计并提示未完成；输入扣除缓存后分别存储；额度解析 `token_count.rate_limits` |
| Cursor / Grok | `api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` + `GetFilteredUsageEvents` | 只读当前 Cursor 应用会话，Bearer 仅发往固定的 `api2.cursor.sh`；共享周额度单独读取，token 仅按接口已返回的明细累加。无原生会话时保留旧套餐 cookie 接口兼容；活动与等待检测仍读取本机 Cursor 日志 |

### Cursor 凭据自动化

1. 优先只读 `Cursor/User/globalStorage/state.vscdb` 中 Cursor 已登录会话的 access token，仅在内存中用于固定 API2 RPC
2. 不刷新、不改写 Cursor 自身 token；Bearer 不发送到其他域名，401 时提示当前 Cursor 会话需要重新登录
3. 仅找不到原生会话时，旧套餐兼容流程才读取 Chrome / Cursor Cookies 数据库、钥匙串与 `WorkosCursorSessionToken`

共享额度和明细请求分别记录成功与失败；失败时保留上次缓存并标明状态。token 明细显示服务端最新已返回日期，不从周额度百分比推算 token。

## 构建要求

- macOS 13+
- Swift 6 工具链（Xcode 或 Command Line Tools）

```bash
git clone git@github.com:peilinF/token_spend.git
cd token_spend
./build.sh
open build/TokenSpend.app
```

`build.sh` 会找名为 `TokenSpend Dev` 的签名证书，找不到则 ad-hoc 签名。稳定证书签名后，钥匙串授权只需一次——重新编译也不再弹窗。创建证书：

```bash
openssl req -newkey rsa:2048 -nodes -keyout key.pem -x509 -days 3650 \
  -out cert.pem -subj "/CN=TokenSpend Dev" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
security import cert.pem -k ~/Library/Keychains/login.keychain-db
security import key.pem -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm key.pem cert.pem
```

## 使用

| 操作 | 效果 |
|---|---|
| 点击圆窗 | 展开/收起详情面板 |
| 拖动圆窗 | 移动位置（自动记忆） |
| 右键圆窗 / 点状态栏图标 | 切周期/口径、阈值、同步间隔、偏好设置、刷新、开机自启、退出 |
| 悬浮圆窗 | 悬浮模式下显示额度条（不拦截点击） |
| 偏好设置 | 改工具颜色、切 30/60fps、额度显示方式（常驻/悬浮/隐藏） |

### CLI

```bash
.build/debug/TokenSpend --print-summary   # 所有周期×口径汇总
.build/debug/TokenSpend --print-live      # 采样两次打印实时活动
.build/debug/TokenSpend --print-waiting   # 当前等待状态
.build/debug/TokenSpend --print-quota     # 只读本地额度快照（codex / Cursor 共享周或旧套餐月度）
.build/debug/TokenSpend --reconcile       # 手动对账清理
.build/debug/TokenSpend --audit-codex     # 只读 SQLite 快照与已提交 Codex 日志独立对账，输出 JSON
.build/debug/TokenSpend --audit-codex /tmp/codex-audit.json # 将对账 JSON 写入指定路径
.build/debug/TokenSpend --export-csv [path] # 按天分工具导出 CSV（不给 path 则打 stdout）
```

`--audit-codex` 直接以只读方式打开本地 store，在单个 SQLite 读事务中读取已提交行和游标；它不初始化共享 store、不刷新任何来源，也不访问网络。报告按系统本地时区给出每日桶、fork 匹配前缀、未提交尾部和数据库差值；退出码 `0` 表示一致，`1` 表示数值不一致，`2` 表示无法完成审计。

### 可选配置（均经 `defaults write com.peilin.tokenspend`）

```bash
# codex 费用估算（USD/1M tokens，codex 源本身不带费用，配了才显示）
defaults write com.peilin.tokenspend price_input_per_1m -float 1.5
defaults write com.peilin.tokenspend price_output_per_1m -float 6
# 额度告警（默认关；codex 周/5h 剩 <20% 或 Cursor 共享周/旧套餐月额度已用 >80% 时每天提醒一次）
defaults write com.peilin.tokenspend quota_alert_enabled -bool true
```

## 刷新策略

| 任务 | 频率 | 说明 |
|---|---|---|
| opencode/codex 增量 | 30s + 3s 轮询 | Codex 未变化文件按签名跳过；变化文件先流式核对已提交 raw 前缀，再解析新完整行，改写或截断触发重算；文件变更立刻点亮活动环；codex 额度随增量落盘 |
| 活动保持/熄灭 | 回合级 | opencode/codex 回合结束 3s 内熄灭；cursor 活跃期 3s |
| 等待检测 | 2s | opencode question / codex request_user_input / cursor 提问或停滞（终端执行期抑制；授权提示后有新进展视为已回答；执行子进程存活不报停滞） |
| Cursor 明细 | 8s（活跃）/ 300s（空闲） | 原生 RPC 分页同步，复用稳定事件 key 幂等写入；失败独立记录，指数退避至 60min |
| Cursor 额度 | 随明细刷新 | `GetSandUsageStatus` 提供共享周额度；额度与明细分别提交，旧月池不会覆盖共享结果 |
| 详情汇总重算 | 按需 | UsageStore 版本号脏检查，未变化跳过 SQL；至少 60s 刷新一次进度环/跨天 |
| 缓存对账 | 1h | 仅 opencode / codex |
| 睡眠唤醒 | 60s 节流 | 全量刷新一次 |

## 隐私与安全

- 所有数据留在本机：`~/Library/Application Support/TokenSpend/store.db`
- Cursor access token 与旧 cookie 仅内存使用，不写日志、不写入 TokenSpend 数据库
- 不上传任何数据，cursor API 仅读你自己的用量事件

## 已知限制

- Cursor 配额与明细依赖官方客户端使用的 RPC；明细日期以服务端实际返回范围为准，未返回的 Grok 聊天/图片/语音用量不会估算
- Cursor 初次同步回溯 400 天，更早无法获取；官网明细可能晚于共享周额度更新
- codex 额度仅在 codex 发起请求后刷新（来自响应头的 `rate_limits`）；窗口按时长自适应归类（短/长），迟到的旧形状事件不会覆盖新窗口，计划取消某窗口后旧值过期自动消失
- codex 5h 窗口重置显示短窗口用时刻、长窗口用日期（由 `window_minutes` 决定）
- 圆窗不显示每分钟速率（`+xx/m` 已取消）

## 卡顿排查

长时间运行后如果圆窗或面板变卡，先开诊断日志（默认关闭），跑 2 小时以上看 `footprint_mb` 斜率和 `main_stall` 条数：

```bash
defaults write com.peilin.tokenspend diag_enabled -bool true
# 重启 TokenSpend 后，状态栏菜单「导出诊断日志」打开
# ~/Library/Application Support/TokenSpend/diag.log
```

关诊断：

```bash
defaults write com.peilin.tokenspend diag_enabled -bool false
```

判定：footprint 持续上涨更像泄漏；footprint 平稳但 `main_stall` 增多或 CPU 抬升，更像主线程卡住 / 动画残留。卡顿当下可再采：

```bash
sample TokenSpend 10 -file /tmp/ts.txt
leaks $(pgrep -x TokenSpend)
footprint $(pgrep -x TokenSpend)
```

Instruments：Allocations（Record reference counts）+ Leaks + Time Profiler，跑 1–2 小时对比 Persistent；SwiftUI instrument 看 View Body 次数是否随时间上升。

## 目录结构

```
Sources/TokenSpend/
├── main.swift
├── AppDelegate.swift
├── Core/
│   ├── Models.swift        # Tool/Period/UsageMode/聚合模型/额度模型
│   ├── AppState.swift      # 状态机、定时器、活动保持、额度订阅
│   ├── ActivityWatcher.swift # 文件变更即时点亮（2s retarget, 0.3s 去抖）
│   ├── UsageStore.swift    # 自有 SQLite（contrib/meta，版本号脏检查）
│   ├── WaitingDetector.swift # 等待/停滞检测
│   ├── Diagnostics.swift   # 可选 footprint / 主线程卡顿日志
│   ├── SQLite.swift
│   ├── Fmt.swift           # 数字/日期格式化 + 线程安全 ISO8601 + 周期数学
│   └── LaunchAtLogin.swift
├── Sources/
│   ├── OpenCodeSource.swift
│   ├── CodexSource.swift   # 会话文件 2s 缓存、回合标记、额度快照分桶
│   ├── CursorLogs.swift    # request-trace / renderer 扫描（5s 缓存）
│   ├── CursorRPC.swift     # 原生 Cursor 会话只读读取 + 固定 api2.cursor.sh RPC
│   └── CursorSource.swift  # 共享额度、原生明细同步 + 旧套餐 cookie 回退
└── UI/
    ├── CircleView.swift    # 圆窗 + 30/60fps + 遮挡暂停 + 动态工具色
    ├── DetailView.swift    # 详情面板 + 额度条
    ├── QuotaStripView.swift # 悬浮窗额度条共享组件
    ├── SettingsView.swift  # 偏好设置（帧率/颜色/额度显示）
    ├── PanelController.swift
    └── StatusBarController.swift
Sources/CCrypto/            # CommonCrypto module shim
```

## License

MIT
