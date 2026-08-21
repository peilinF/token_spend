# TokenSpend

一个轻量的 macOS 桌面悬浮圆窗，实时统计 **opencode / codex / cursor** 三个 AI 编码工具的 token 消耗。

纯 Swift 原生实现（AppKit + SwiftUI），零第三方依赖，单二进制约 5MB，常驻内存 ~70MB。

```
   ╭──────╮        点击圆窗展开详情面板
   │ 25M  │        ┌──────────────────────────┐
   │ 今日 ●│   →    │ Token 消耗      更新于 xx │
   ╰──────╯        │ [日|周|月|年] [精简|全量]  │
                   │ opencode  2.6M  ▓▓▓░░░   │
                   │ codex    13.2M  ▓▓▓▓▓    │
                   │ cursor    9.2M  ▓▓░░░░   │
                   │ 近 7 天 ▁▃▅▂▇▆█          │
                   └──────────────────────────┘
```

## 功能

- **悬浮圆窗**：置顶、全 Space 显示、可拖动（位置记忆）、进度环显示当前周期流逝
- **实时活动指示**：哪个工具正在工作，对应颜色的脉冲点就亮起；token 高速消耗时显示 `+xxM/m` 速率
- **周期切换**：今日 / 本周（周一起始）/ 本月 / 今年，本地时区
- **双统计口径**：
  - 精简 = input（不含 cache）+ output —— 反映真实生成量
  - 全量 = 含 cache read/write —— 反映总吞吐（数字巨大，codex 尤甚）
- **详情面板**：分工具明细、占比条、近 7 天堆叠柱状图、opencode 费用
- **菜单栏图标**：切周期/口径、显示/隐藏圆窗、开机自启、立即刷新
- **CLI 调试**：`--print-summary` / `--print-live` / `--reconcile`

## 数据来源

| 工具 | 来源 | 方式 |
|---|---|---|
| opencode | `~/.local/share/opencode/opencode.db` | 只读 SQLite，按 `time_updated` 水位增量拉取 assistant 消息 |
| codex | `~/.codex/sessions/**/*.jsonl` | 字节偏移量增量解析 `token_count.last_token_usage`，支持 GB 级活跃文件 |
| cursor | `cursor.com/api/dashboard/get-filtered-usage-events` | 自动从 Chrome 或 Cursor 应用提取会话 cookie 调用网页版接口 |

### Cursor 凭据自动化

Cursor 不在本地存 token 数据，TokenSpend 会：

1. 依次尝试 Chrome、Cursor 应用的 Cookies 数据库（复制到临时目录，避开文件锁）
2. 从钥匙串读取 `Chrome Safe Storage` 或 `Cursor Safe Storage`（**首次弹一次授权框，点「始终允许」后永久静默**）
3. AES-128-CBC 解密出 `WorkosCursorSessionToken`（仅存内存，不落盘；Chrome `v20` 加密无法解密，会提示改用 Cursor 应用登录）
4. 删除临时副本，带 cookie 调用 usage API

cookie 过期后详情面板提示「请登录 cursor.com（Chrome 或 Cursor）」，重新登录即自动恢复。

## 构建要求

- macOS 13+
- Swift 6 工具链（Xcode 或 Command Line Tools）

```bash
git clone git@github.com:peilinF/token_spend.git
cd token_spend
./build.sh
open build/TokenSpend.app
```

`build.sh` 会自动寻找名为 `TokenSpend Dev` 的代码签名证书；找不到则降级 ad-hoc 签名。
使用稳定证书签名后，钥匙串授权只需一次——**重新编译也不会再弹窗**。创建证书：

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
| 右键圆窗 | 切周期/口径、刷新、开机自启、退出 |
| 点面板外 | 收起详情面板 |

### CLI

```bash
.build/debug/TokenSpend --print-summary   # 打印所有周期×口径的汇总并退出
.build/debug/TokenSpend --print-live      # 采样两次打印实时活动检测
.build/debug/TokenSpend --reconcile       # 手动触发缓存对账清理
```

## 刷新策略

| 任务 | 频率 | 说明 |
|---|---|---|
| opencode/codex 增量 | 30s + 实时轮询 3s | 毫秒级增量，无 IO 压力 |
| cursor API（空闲） | 300s | 失败指数退避至 60min |
| cursor API（活跃） | 默认 8s，可调 3-30s | 检测到 cursor 正在工作时自动加速，速率显示滞后 ≤8s |
| 缓存对账清理 | 1h | 清理源数据已删除的残留行 |
| 睡眠唤醒 | 60s 节流 | 唤醒后全量刷新一次 |

cursor 的 `+x/m` 速率基于成功同步时的总量快照差分（5 分钟窗口），两次同步之间保持上次数值不闪断。

## 隐私与安全

- 所有数据留在本机：缓存库位于 `~/Library/Application Support/TokenSpend/store.db`
- 解密后的 cookie 只在内存中使用，不写日志不落盘
- Chrome Cookies 临时副本用完即删
- 不上传任何数据，cursor API 仅用于读取你自己的用量事件

## 已知限制

- cursor 的 token 速率依赖官网 usage API（活跃时约 3 秒一刷），圆窗 `+xx/m` 是当前所有正在消耗的工具之和
- cursor 初次同步回溯 400 天，更早的历史无法获取
- Cursor 官网接口为非官方逆向，若失效需跟进适配
- codex 统计口径为各 `token_count` 事件增量求和，与官方 dashboard 可能存在微小差异

## 目录结构

```
Sources/TokenSpend/
├── main.swift              # 入口 + CLI 分发
├── AppDelegate.swift
├── Core/
│   ├── Models.swift        # Tool/Period/UsageMode/聚合模型
│   ├── AppState.swift      # 状态机、定时器、退避、采样
│   ├── UsageStore.swift    # 自有 SQLite 缓存（contrib/meta）
│   ├── WaitingDetector.swift # 等待确认 / 停滞检测
│   ├── SQLite.swift        # sqlite3 C API 薄封装
│   ├── Formatters.swift    # 线程安全 formatter
│   ├── Fmt.swift           # 数字/日期格式化 + 周期数学
│   └── LaunchAtLogin.swift # SMAppService 开机自启
├── Sources/
│   ├── OpenCodeSource.swift
│   ├── CodexSource.swift
│   ├── CursorLogs.swift    # Cursor request-trace / renderer 日志扫描
│   └── CursorSource.swift  # cookie 解密 + API 客户端
└── UI/
    ├── CircleView.swift    # 圆窗视图 + 脉冲动效
    ├── DetailView.swift    # 详情面板
    ├── PanelController.swift # NSPanel 管理/定位/点击监听
    └── StatusBarController.swift
Sources/CCrypto/           # CommonCrypto module shim (AES/PBKDF2)
```

## License

MIT
