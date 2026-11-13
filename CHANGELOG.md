# anhsbot 变更日志 / Changelog

## v0.3.0 (2026-11-11)

anhsnav 导航插件 + 击杀归因优化 + 掉帧看护 + RCON 可观测，真机验证。
anhsnav companion plugin, kill-attribution improvements, frame-drop guards and
RCON observability — all verified on a live server under cdb.

### 新增 / Added
- **anhsnav 配套插件**（`anhsnav.smx`）：拦截全部 204 个 `nav_*` 命令
  （Valve 官方命名，FCVAR_CHEAT 门控剥离 + 缺失命令注册 + 全局命令监听器），
  提供离线导航网格烘焙器：`nav_generate` 网格采样 → 洪水填充 → 矩形合并 →
  连通 → v16 写盘，分片跨帧执行（每帧 8ms 预算护栏，防 SourcePawn 50ms
  超时掉帧）；输出 `maps/anhsbot/<map>.nav` 供 anhsbot 读取（引擎只认
  `maps/<map>.nav`，不会误拾取）。`nav_progress` / `nav_save` / `nav_load` /
  `nav_analyze` / `nav_check_file_consistency` / `nav_world_center` /
  `nav_place_list` 全部有真实应答；其余编辑器命令应答"handled"。
- **`nav_perfframe` / `nav_perfframe_clear`**（anhsnav）：自身每帧脚本开销观测
  （累计 ms + 上次生成墙钟耗时），rcon 可查，配合 anhsbot_perf 定位掉帧来源。
- **anhsbot_navreload**（anhsbot）：从磁盘重载 nav 网格（anhsnav 生成后手动
  重载用；地图启动后 5s 静默自动重试一次，加载成功/失败都停，避免刷屏）。
- **anhsbot_perf**（anhsbot）：性能观测——地图/实体数、NPC 缓存大小、累计
  OnPlayerRunCmd 调用量（脚本负载指标）。
- **低血量优先表**（targeting）：全局 0.5s 刷新 NPC 血量缓存，血 <60 的僵尸
  最多 4 个追加进索敌候选表（归因提速 + 残血人头优先）；bot 每帧调用，
  内部 TTL 闸门（无 bot 不跑）。
- **伤害归因 + 击杀归因走全局血量扫描**（targeting `Targ_ScanHp`）：原每帧
  对目标 `HasEntProp` + 读 m_iHealth 改为 0.5s 全局扫描（与队伍无关，多 bot
  共用，无 bot 不跑）；血量下降 → 归因最近 5s 内 `iTarget==ent` 的 bot；
  血量归零 → 计 1 kill（ANHS 僵尸"死亡→复活"实体不变，靠 0 值跳变计数，
  复活时不归因防刷数）。低血量（hp≤60）NPC 最多 4 个追加进索敌候选表，
  残血目标优先收。
- **中英文文档**：README / README-ZH 补 anhsnav 章节、`anhsbot_navreload` /
  `anhsbot_perf` / `nav_perfframe` 命令、掉帧排查条目、击杀归因已知限制；
  `anhsbot_skill` 默认改 `-1`。

### 修复 / Fixed
- **`anhsbot_skill` 默认 `-1`**（per-name 技能池）：`anhsbot_bots.cfg` 里每个
  名字有独立技能等级，`anhsbot_skill >= 0` 才全局覆盖。
- **nav_analyze 连接数**：`nav_load` 后 `g_Gen.connCount` 未存，导致
  `nav_analyze` 报 0 connections（应为 12064）；已修为读盘时存 totalConn。
- **掉帧看护**：anhsnav `nav_generate` 采样循环加 8ms/帧 预算护栏（超即让出
  剩余给引擎），nav 生成期间不再拖 tickrate；anhsbot 索敌候选表扩容
  `ANH_MAX_LOS` → `ANH_MAX_LOS + 4`（低血量候选追加大小自适应）。
- **击杀归因提速**：低血量 NPC 优先表让 bot 更快锁定残血目标（0.5s 缓存
  刷新，非每帧全量读 prop）；原每帧 `HasEntProp` 开销改走 `Targ_ScanHp`
  全局扫描（血量下降归因 + 血量归零计击杀，5s 归因窗口防僵尸复活刷数）。

### 真机验证（cdb 实跑，tickrate 66.7，5 bot × 35s）
- **无掉帧**：`anhsbot_perf` 报 `entities=537~538 npcCache=8 runcmds=10870`
  （35s 线性增长，无 "Script execution timed out"）；`nav_generate` 全程
  1.5s（分片 <8ms/帧），tickrate 稳定。`nav_perfframe` 确认生成后
  `last generation 1.5s (3072 areas)`，`0.0ms total script`（计时器在
  生成帧之间，非持续占用）。
- **NPC 击杀确认**：`bot 1 killed npc 143` + `bot 4 killed npc 143`
  （global Targ_ScanHp 归因，`kills=2`，`damage=1284`）；`anhsbot_list`
  报 `K/D=1/0` × 2，5 bot 均命中 `npc_zombie`（LOS 正常，cache 6~8 只）。
- **RCON 全链路**：`nav_perfframe` / `anhsbot_perf` / `anhsbot_status` /
  `anhsbot_list` / `nav_generate` / `nav_save` / `nav_load` / `nav_analyze`
  全部经 `ServerCommand`（rcon 等效）驱动，无 `Unknown command` / cheat 拒绝。

### 已知限制 / Known limitations
- 僵尸队引擎限制（全局 1 名、换队即重置回人类队），bot 形态为幸存者打 NPC；
  `anhsbot_quota_joinzombie 1` 仅作实验开关。
- NPC 无 `player_death` 事件，击杀靠全局血量扫描归因（0.5s 窗口，5s 归因
  延时）；ANHS 僵尸"死亡→复活"只计 1 次，但复活循环可能多计。短跑（<1min）
  可能 `kills=0` 但 `damage>0`（窗口未到），属正常。
- 死亡重建定时器(0.7s)与 quota autofill(3s) 抢补同一槽位时瞬时 5 客户端，
  会被 autofill 修剪回配额（终态正确，可能丢一次 K/D 结转）。
- 仅在中/英文社区环境验证；更多地图与僵尸队形态待扩展。

---

## v0.2.0 (2026-10-18)

导航寻路 + 配额管理 + 团队模式 + 卡住自救，全部真机验证。
Navigation, quota management, teamplay mode and stuck self-rescue — all verified on a live server.

### 新增 / Added
- **自研 nav A\* 寻路**（`nav.inc`）：解析 V 社标准 `.nav` v16 二进制（magic 0xFEEDFACE），
  建 CSR 有向邻接图 + 二叉堆 A\* + 路径跟随（waypoint 半径 56、0.6s 低频重算）。
  不依赖 SM navmesh.inc（本机 SM 1.12 没有该头文件）。11/37 张图带 `.nav` 可直接用；
  无 `.nav` 的图自动回退纯几何走位。其余图可用引擎 `nav_generate`（需 `sv_cheats 1`）烘焙。
- **trigger_hurt 危险区规避**：每 5s 枚举危险实体缓存球体，路径直穿则侧移 60°
  （同时缓解"踩熊夹 → 成就 → server.dll 空指针崩溃"）。
- **quota 自动管理**：`anhsbot_quota` 目标在线总数，不足自动加、超出自动踢；
  `anhsbot_quota_joinzombie` 控制是否允许加入僵尸队（引擎限制默认 0）。
- **teamplay 队友识别**（`anhsbot_teamplay`，默认 1）：幸存者 team 2/3 互认为队友——
  不互杀、开火前友伤遮挡检查（队友挡弹道则本帧放弃开火）、空闲向队友集结。
- **卡住三层自救**（ant_deadend_drive 实测冻结根因：静态 nav 与运行时动态几何不一致
  → bot hull 嵌进几何体，vel 有值但零位移；`TeleportEntity` 对 fake client 无效）：
  ① 诅咒 area（连续卡住 → A\* 绕开，TTL 90s）；② 几何兜底游走（随机方向 + 墙滑 +
  周期跳跃 2.5s）；③ 重建 bot（kick + CreateFakeClient 到安全出生点，K/D/伤害结转）。
- **成就崩溃规避**（`anhsbot_no_achievements`，默认 1）：地图启动禁用 logic_achievement。
- **bot 名字池 + 技能等级**：`configs/anhsbot_bots.cfg`（32 个名字 × skill 0-3）。
- 新 cvar：`anhsbot_quota` / `anhsbot_quota_joinzombie` / `anhsbot_teamplay` /
  `anhsbot_nav` / `anhsbot_no_achievements` / `anhsbot_skill`。
- 新诊断：`anhsbot_diag`；`anhsbot_aim` 增加 `nav=/path=/los=` 字段；
  `anhsbot_status` 增加 `nav=on/off areas=N`。
- 中英文配置文件与说明文档 / Bilingual cfg and docs.

### 关键逆向结论（真机验证）/ Key reverse-engineered facts (verified live)
- `PlayerRunCmd` 玩家 vtable 槽位 = **418**（ZPS 血统，非 HL2MP 426；432 是空函数）。
- `FL_FAKECLIENT` 在 ANHS 上为 **0x200**（SM 头文件的 0x100 不可用，布局右移一位）。
- 启动必须 `+mp_teamplay 1` 在 `+map` **之前**，否则 bot 卡 team 0。
- NPC 瞄准点必须读 `m_vecAbsOrigin`（datamap 640），读 `m_vecOrigin`(776) 会瞄幻影。
- ANHS 最高玩家数硬上限 **16**（游戏 DLL `GetPlayerLimits`），即最多约 15 bot + 1 人类。
- 44 把可创建武器探针结论驱动 loadout / 选枪。

### 修复 / Fixed
- 空闲 bot 随机漫游选路失败时干站无日志（失败路径全被 debug cvar 压制）→ 全部改限频 Log。
- nav 暂停逻辑反转：远目标无视卡住暂停、每 2s 重算同一条路径干追 60s。
- 集结分支漏挂卡住检测 → bot 互相集结时静默冻结（90s 位置零变化、仅 1 条 stuck 日志）。
- 卡住计数满血重置 → 陷阱口袋震荡户永远攒不满重建阈值；改衰减计数 + 阈值 4→3。
- scout walk 日志被 10s 限频器吞掉导致回归误判"未触发" → 改直接 Log。

### 已知限制 / Known limitations
- 僵尸玩家队（team 4）为引擎限制（全局仅 1 名、换队即被重置回人类队），bot 形态为
  幸存者打 NPC；`anhsbot_quota_joinzombie 1` 仅作实验开关。
- 26/37 张图无 `.nav`（可用 `nav_generate` 烘焙）；有 nav 的图若与运行时动态几何
  不一致（nav 生成时开着的门/路障运行时关闭），bot 可能嵌进几何体——三层自救可恢复，
  根治靠重新烘焙。
- 死亡重建定时器(0.7s)与 quota autofill(3s) 抢补同一槽位时瞬时 5 客户端，会被 autofill
  修剪回配额（终态正确，可能丢一次 K/D 结转）。
- 仅在中/英文社区环境验证；更多地图与僵尸队形态待扩展。

---

## v0.1.0 (2026-10-18)

首个可运行版本 / First runnable release。

### 新增 / Added
- 基于 fake client 的 bot 生成、自动入队（team 2/3）、看门狗激活（`FL_FAKECLIENT`）。
- `OnPlayerRunCmd` 驱动的战斗大脑：索敌（全局 NPC 缓存 + LOS）、瞄准插值、开火、低频补弹。
- 武器系统：出生时发放人类 loadout，经逆向验证的 `GivePlayerItem` + `WeaponEquip[261]`
  SDKCall 装备，CUserCmd 切枪。
- 统计：击杀 / 死亡 / 伤害（对 NPC 也生效，NPC 无 `player_death` 事件，靠血量变化归属）。
- 死亡重建：HL2MP 无法用命令原地复活死亡 bot，看门狗用原生 `CreateFakeClient`
  重建同名同队 bot 并结转累计统计。
- 换图自动恢复 bot（生产服换图后自动补齐到目标数量）。
- 管理命令：`anhsbot_add/kick/kickall/list/status/aim/diag/tele/npc`。
- 中英文配置文件与说明文档 / Bilingual cfg and docs.
