# anhsbot 变更日志 / Changelog

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
