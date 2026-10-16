# Cursor / Grok 共享额度接入

唯一权威计划。工作目录 `/Users/peilin/Desktop/token_spend`。用户要求修正已整合的 Cursor、Grok、Grok Bot，明确选择“合并显示，共用额度”，移除已不存在的独立“三方”额度，并重新核对 Cursor。2026-10-16，Asia/Shanghai。允许实施、打包及重启验收；不创建 PR、不发布、不引入依赖。

## 已证实的事实

- 官方说明：https://prod.cursor.com/help/models-and-usage/usage-limits 、https://docs.x.ai/x-subscription/grok-bot 。X Subscription 是三端共享周池；第三方模型按量另付费，不是附赠的独立额度池。旧 Cursor 套餐仍为月度双池，需兼容。
- 本机 Cursor 3.25.6、Grok Bot 0.71.2。TokenSpend 当前只读旧 `cursor.com/api/usage-summary`，返回 membershipType=super、月度 used=0/limit=16159、auto/api=0，窗口误显示自家/三方0%。
- 普通文件静态调查（无 REA 工具/CLI，未安装）确认新版原生客户端使用 `https://api2.cursor.sh/aiserver.v1.DashboardService/*` 的 Connect JSON RPC，`Authorization: Bearer` + `Content-Type: application/json` + `Connect-Protocol-Version: 1`。个人请求不设team header；有明确团队上下文时才使用 `x-cursor-team-id`，不猜测团队。
- Cursor `/Applications/Cursor.app/Contents/Resources/app/out/vs/workbench/workbench.desktop.main.js` 的 UsageDataService 调用 GetPlanInfo/GetCurrentPeriodUsage；Grok Bot ASAR `dist/electron-main/main-app.cjs` 的 fetchSandWeeklyUsage 调用 GetSandUsageStatus。`proto.cjs` 提供字段契约。
- 只读真实 POST `GetSandUsageStatus {}` 成功：`isUnified=true, usagePercent=1.8379850238257318, currentPeriodStart=2026-10-16T01:55:03.315Z, nextResetTimestampUtc=2026-10-23T01:55:03.315Z, cursorPlanName=Super, hasNonZeroIncludedLimit=true`。这是共享周池的权威数据，不使用旧月度0%。
- 当前原生 access token 存于 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 的 ItemTable `cursorAuth/accessToken`（plaintext JWT）。只读 GetMe 的 userId 与已存 cursor_account_id 一致。JWT.sub 是另一种身份格式，不能直接比较。不得打印或保存 token、邮箱、完整身份/请求正文。
- 真实 POST `GetFilteredUsageEvents`，body=startDate/endDate 毫秒字符串、page/pageSize，成功返回 totalUsageEventsCount=2538，usageEventsDisplay[]，字段与旧同步器兼容，含 model=grok-bot-automation。最新事件为 2026-10-13；服务端目前没返回之后的 token 明细。`GetAggregatedUsageEvents` 查询今日返回空对象，不能由共享额度百分比反推token。
- Web GET summary 用 Bearer 返回401，Web POST events返回307；应直接用已验证的原生RPC，不对凭据跨域乱试。Token明细必须保留“服务端已返回记录”边界，不能宣称三端所有行为都有token数据。

## 设计与接口契约

### 1. 原生账号与网络读取

在 CursorSource 内或小型 `CursorRPC.swift` 中增加原生会话读取/请求封装，便于注入测试DB路径、会话提供者和URLSession/请求闭包。优先当前已登录 Cursor 的原生 token，使用 SQLite 只读连接读取上述单一 key；有效JWT检查exp，不能输出凭据，不能刷新/改写 Cursor 自身账号或token。仅当原生 profile DB 文件不存在时允许旧 Cookie 兼容；profile 存在但缺token、缺表、锁定、不可读或token过期都必须明确失败，不能切换至Chrome账号。

新RPC只向固定 `https://api2.cursor.sh` 服务路径发Bearer。共享额度用 GetSandUsageStatus `{}`；原生明细用 GetFilteredUsageEvents，复用当前 syncEvents 的分页、事件key、account检测和幂等upsert，保持 `.cursor` 持久来源值与已存历史。原生401不要悄悄换用另一个Chrome账号继续拼接；显示需要登录当前Cursor。GetFilteredUsageEvents的空protobuf JSON默认可视为空记录；非预期错误必须标记失败，不能伪造明细。

共享额度读取与明细同步各自处理：一方失败不阻止成功的另一方提交。任一 RPC 返回401/403时仍提交另一请求成功的数据，但整次刷新优先报告需要重新登录，不显示为已连接。原生共享成功时不再写旧月度summary覆盖它。已知共享缓存请求失败时保留上次值并明确提示更新失败/上次结果；不降级成旧接口0%。额度状态、额度观测时间和最新明细时间各自持久化，不能用“同步成功”冒充明细已覆盖今天。

`GetSandUsageStatusResponse.isUnified` 是 protobuf bool；旧套餐的默认 `false` 可能在 ProtoJSON 中省略。显式 `false` 调用已验证的 `GetCurrentPeriodUsage`；缺省时，仅当响应具有合法 `usagePercent`、周期字段和计划/品牌标签，且没有已知共享缓存，才按旧套餐处理。空或类型错误响应视为无效；已知共享缓存遇到缺省 marker 时保留缓存并标记额度错误。

### 2. 模型与显示

`CursorQuota` 增加明确的共享周/旧月类型（可用isUnified/枚举），解析共享原始JSON的 usagePercent/currentPeriodStart/nextResetTimestampUtc，兼容带/不带小数ISO时间。共享记录忽略旧auto/api字段；缺失或无效percent不当0。保持已有totalPercentUsed等调用方可迁移；used/limit/bonus不从百分比估计。集中提供periodLabel/共享标题/是否展示旧pool等属性。

统一套餐显示一条“共享周额度”（compact标签可用“Grok周”），包含当前已用/剩余与重置日期，详情说明“Cursor、Grok、Grok Bot 共用”。不显示自家/三方双条、不显示月度。菜单栏、详情、悬浮窗、可选通知、只读 `--print-quota` 均用同一类型/周期，避免残留月度文字。

`.cursor` 存储key不改；共享用户的可见分组可称“Cursor / Grok”，但token数字必须明确是已记录明细（包含服务器返回的Grok Bot记录）。在详情显示最近明细日期/“token 按已返回明细统计”，额度与token覆盖范围分开。无法获得的Grok聊天/图片/语音token不推算。旧套餐仍能正确显示其月度合法池；本次用户为真实isUnified=true，因此不会再显示三方独立池。

### 3. 数据保护

不修改 Codex v4、opencode、用户偏好、存储来源枚举值、历史 Cursor 贡献key或定价定义，不删除任何已有历史，不升级触发旧cursorKey迁移。现有未提交修改全部保留。新增metadata放StoreKeys。HTTP错误不保存带凭据的原始错误/响应；用户只见简短状态。

## 实施增量与交接

单个 Luna Max（gpt-6-luna/max/fork none）连续实施，先读局部规则和本计划，核对前提。负责 CursorSource、新原生请求小模块（如需要）、Models、StoreKeys、AppState必要状态、QuotaStripView、DetailView、StatusBarController、main.swift只读quota输出、README和隔离测试。不要与主代理同时改代码；主代理只做文档/只读真实验收。

1. 增加可隔离的原生凭据与RPC解析测试，复现月度0% vs真实共享1.84%，缺percent与0percent区分。
2. 原生额度/RPC明细同步接入，保留旧套餐fallback；额度与明细失败隔离、保留旧值状态、幂等事件复用。
3. 各显示面统一共享周、删除统一用户自家/三方条、显示可验证明细边界，更新README说明。
4. 运行 `bash Tests/run.sh`、`swift build -c release`、`git diff --check`，回报实际结果及偏离。所有测试仅临时DB与脱敏JSON/模拟HTTP，不读真实凭据、不网络调用、不使用UsageStore.shared。

必须覆盖：共享周真实字段/0/缺失/错误值，旧月兼容，三个显示消费同一周期属性，Bearer只发固定RPC host、401不换账号、token不持久化，原生事件重复同步不重复、数值字符串/空JSON、额度成功明细失败/额度失败明细成功、已知共享缓存失败不被legacy0覆盖、其他来源/旧cursor贡献保留。不要制作镜像实现的冗余测试。

主代理审查后 `bash build.sh`，先保留旧应用与一致数据库备份/元数据采样，再停止旧TokenSpend并启动新包。以只读原生RPC与存储/界面对照共享percent/reset/isUnified，确认无三方条/无月度误标；复核历史行未丢失或重复，明细最新日期如仍10/13需如实呈现。运行 `--audit-codex` 确认无回归。不要使用有广泛刷新副作用的 --print-summary 做审计。

## 恢复与状态

仅追加metadata和幂等记录，无不可逆迁移。回退先停止TokenSpend，恢复旧应用；如需恢复数据库，使用一致备份并在停机时处理WAL/SHM。原生Cursor/Grok app、登录状态与原日志保持不变。

- [x] 用户范围确认与官方资料核实。
- [x] 新接口、身份与真实共享额度/事件数据验证。
- [x] 实现与隔离验证：13 项 Cursor quota/RPC/session/event checks 与 41 项 Codex regression checks 通过；`swift build -c release` 成功（仅已有 Swift/linker warnings）；`git diff --check` 通过。所有 Cursor 测试使用临时数据库和模拟 HTTP。
- [x] 主代理审查、签名打包、重启及真实验收。

审查补强（未扩展用户范围）：已存在profile的SQLite读取错误统一识别为原生会话不可读，只有文件缺失进入旧Cookie路径；缺token视为无效会话。quota/events任一遇401/403时保留另一请求成功提交的数据，同时整体要求重新登录。隐式protobuf false仅在两个marker key均缺失、usage有效、周期至少一项可解析为日期且有计划/品牌标签时接受；错误类型、空/垃圾周期和已知共享缓存均不回落月度接口。


## 主代理审查与上线记录

- 独立 Luna Max 只读复核三项审查修复，无剩余阻塞发现。识别省略false的旧状态时，有一项合法周期边界足以进入原生月度RPC；最终额度仍必须由该RPC合法响应获得。这是兼容性识别选择，不用该边界推算额度。
- `bash build.sh` 成功，使用 `TokenSpend Dev` 签名，生成 `build/TokenSpend.app`。已保存旧应用 `.build/cursor-shared-validation/TokenSpend-before-shared.app` 与 SQLite一致备份 `store-before-shared.db`（0600）、初始采样 `before.json`。
- 2026-10-16 12:33 +08:00 再次只读调用原生共享接口：已用1.8441735255894547%，共享周重置2026-10-23 09:55:03 +08:00；见 `live-quota.json`（0600）。旧月度0%不能代表当前共享周池。
- 新包执行 `--audit-codex` 退出0，`consistent=true`、`blockers=[]`、`differenceByDay={}`、parser4。报告 `audit-codex-after.json`（0600）。25936字节追加内容在当时已提交游标之后，明确列为待后续刷新内容，未混入旧数据库对比。
- 停止旧应用PID70056后，CUA启动新包被系统锁屏阻止；已提示用户解锁。窗口、真实新包同步、历史行逐项对比尚待解锁后完成，不能宣布全部完成。


### 解锁后最终验收（2026-10-16 12:42 +08:00）

- 用户确认解锁，CUA成功启动新版。启动时先显示旧缓存，原生同步完成后立即切换为“共享 已用1.8%”；悬浮窗截图与AX文本已核实，无自家/三方独立池、无月度误标。通过现有右键菜单“立即刷新”再验，显示保持正确，未改用户偏好。详情中的周期/明细提示经过源代码与编译检查；CUA未能可靠展开详情面板，未将其记录为目视验收。
- 原生接口与新包提交的共享快照一致：isUnified=true、usagePercent=1.8441735255894547、重置2026-10-23 09:55:03 +08:00。quota/events error均为空，账号未变，最新返回明细仍2026-10-13。此日期是接口返回范围，不能据此宣称三端全部token已覆盖。
- 与12:12的一致备份逐key对比：Cursor原有3537行全部保留，刷新后仍3537行，无新增/缺失，日期和四个token桶全部相同。11行10/13费用值因原生JSON响应数值精度而变化，最大绝对差1.178741451668408e-9 USD；未改费用转换公式，未发生token变更。结果见 `.build/cursor-shared-validation/after.json`（0600）。
- 新包重启后再次执行只读 `--audit-codex` 退出0，consistent=true、blockers=[]、differenceByDay={}、parser4；报告 `.build/cursor-shared-validation/audit-codex-after-restart.json`（0600）。
- 本次交付完成：共享周额度读取与悬浮显示实际验收通过，历史token无丢失/重复。保留旧月套餐兼容分支；第三方模型额外付费与共享额度分开，不展示为当前账号的独立附赠池。无PR、无发布、无新增依赖。
