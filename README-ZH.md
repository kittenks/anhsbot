# anhsbot — A Nights Haunting Source 机器人插件

`anhsbot` 是一个为 **A Nights Haunting Source (ANHS)** 开发的 SourceMod 机器人插件，
仿照 `zpsbot` 的架构，用 fake client（假客户端）驱动 bot 的视角、移动与开火，使其能
自主索敌、射击、走位、击杀地图中的僵尸 NPC，并统计击杀/死亡/伤害。

> 引擎背景：ANHS = **HL2MP（Source 2013）引擎** + **ZPS（Zombie Panic! Source）代码血统**
> （Steam AppId 243750）。这一双重血统决定了插件必须使用 ZPS 版的 gamedata。

> **作者**：[kittenks](https://github.com/kittenks) · English README: [README.md](README.md)

---

## 1. 环境要求

| 组件 | 版本 |
|---|---|
| MetaMod:Source | 1.12.0-git1228 或更新 |
| SourceMod | 1.12.0-git7255 或更新 |
| 游戏 | A Nights Haunting Source（`anhsource` 游戏目录） |
| 编译器 | 配套 SourcePawn Compiler 1.12（仅自行编译时需要） |

---

## 2. 安装

1. 把本目录下的内容按相同目录结构覆盖到你的 ANHS **游戏目录**（即 `anhsource/`
   本身，例如 `D:\anh\anhsource\`）：

   ```
   addons/sourcemod/plugins/anhsbot.smx
   addons/sourcemod/gamedata/sdktools.games/custom/game.anhsource.txt
   addons/sourcemod/configs/anhsbot_bots.cfg
   cfg/sourcemod/plugin.anhsbot.cfg
   ```

   （注意：`addons/` 与 `cfg/` 都在游戏目录 `anhsource/` 里面，不是 srcds 启动器
   所在的上级目录。）

2. **关键 gamedata**：`game.anhsource.txt` 必须放在
   `addons/sourcemod/gamedata/sdktools.games/custom/` 目录下
   （不是 `gamedata/custom/`）。它基于 ZPS 版的 `game.zpanic.txt` 改写游戏名为
   `anhsource`，并提供正确的 `PlayerRunCmd` 偏移（详见第 4 节）。

3. 启动服务器时，**必须在 `+map` 之前加上 `+mp_teamplay 1`**，例如：

   ```
   srcds.exe -game anhsource +mp_teamplay 1 +map anh_killhaus +sv_pure 0
   ```

   `mp_teamplay` 必须在建图前设置，否则 bot 会卡在 team 0 无法出生。

4. 重启或热加载插件：

   ```
   rcon sm plugins load anhsbot
   ```

5. **bot 数量**：编辑 `cfg/sourcemod/plugin.anhsbot.cfg` 中的 `anhsbot_quota`
   （推荐）或 `anhsbot_count`。ANHS 最高玩家数硬上限 16，即最多约 15 bot + 1 人类。

---

## 3. 配置（ConVar）

配置文件 `cfg/sourcemod/plugin.anhsbot.cfg`（中英文注释，自动执行；已存在则不覆盖）。
所有 cvar 也可用 rcon 热改：`sm_cvar anhsbot_<name> <value>`。

| ConVar | 默认 | 说明 |
|---|---|---|
| `anhsbot_enable` | `1` | 总开关。0=停用插件（bot 不生成/不驱动）。 |
| `anhsbot_quota` | `0` | **bot 配额**：目标在线总数，不足自动加、超出自动踢（>0 覆盖 `anhsbot_count`）。 |
| `anhsbot_count` | `0` | 旧方式目标数量（0=不自动补齐）。推荐用 `anhsbot_quota`。 |
| `anhsbot_quota_joinzombie` | `0` | 允许加入僵尸队的配额 bot 数（0/1）。引擎限制，见第 4 节。 |
| `anhsbot_teamplay` | `1` | 团队模式：幸存者 team 2/3 互为队友——不互杀、防友伤、空闲集结。0=各自为战。 |
| `anhsbot_nav` | `1` | nav A\* 寻路开关。地图有 `.nav` 时启用；无则自动回退纯几何走位。 |
| `anhsbot_no_achievements` | `1` | 地图启动禁用 logic_achievement（规避假客户端成就空指针崩溃）。 |
| `anhsbot_skill` | `2` | 默认技能等级：0=低 1=普通 2=高 3=精英（影响瞄准误差与反应）。 |
| `anhsbot_name_prefix` | `AnhBot` | bot 名字前缀（未安装名字池时使用，自动加两位序号）。 |
| `anhsbot_autofill` | `1` | 是否自动补齐到目标数量。 |
| `anhsbot_fill_interval` | `3.0` | 自动补齐检查间隔（秒）。 |
| `anhsbot_manage_flags` | `1` | 看门狗每帧重设 `FL_FAKECLIENT` 标志。 |
| `anhsbot_respawn_delay` | `6.0` | bot 死亡后多久看门狗重建它（秒）。 |
| `anhsbot_debug` | `0` | 1=输出详细调试日志到控制台。 |

**bot 名字池**：`addons/sourcemod/configs/anhsbot_bots.cfg`，每行
`<名字> <技能0-3>`，共 32 个预设。删除该文件则回退到名字前缀方式。

---

## 4. 工作原理（关键逆向结论）

要让 fake client bot 真正"活"起来，必须满足三个在 ANHS 上实测验证的前提：

1. **正确的 `PlayerRunCmd` 虚函数槽位 = 玩家 vtable[418]（offset 0x688）。**
   ANHS 是 ZPS 血统，必须用 ZPS 版偏移（HL2MP 的 426 是 bool getter，空函数 432 也错）。
   gamedata 已在 `game.anhsource.txt` 固化。

2. **bot 必须带 `FL_FAKECLIENT`（1<<9 = 0x200）。**
   注意：SourceMod 头文件里的 `FL_FAKECLIENT=(1<<8)=0x100` 是标准 HL2 值，
   **在 ANHS 上布局右移一位**，真正的 fake-client 标志是 `0x200`。
   ANHS 的 fake-client 命令循环只对带 `0x200` 的玩家调用 `PlayerRunCommand`，
   不带则 `OnPlayerRunCmd` 永远不触发（`runcmds` 恒 0）。插件一律用自定义
   `ANH_FL_FAKECLIENT=0x200`，看门狗每帧兜底重设。

3. **`OnPlayerRunCmd` 内必须改写 `vel`/`angles`/`buttons` 并 `return Plugin_Changed`。**
   移动用 `vel[0]=forwardmove`、`vel[1]=sidemove`（不是世界速度）。

### 走位体系（四层，优先级从高到低）

1. **nav A\* 寻路**：目标 >700u 或无 LOS 时规划路径跟随；无目标时向队友集结或随机漫游。
2. **三段式距离带**：远(>220)逼近 / 近(<90)后撤 / 中段环形绕步（边走边打）。
3. **墙滑**：期望方向被遮挡时旋转探测最近可通方向，贴墙滑过。
4. **几何兜底游走（scout walk）**：寻路连续失败或卡住时随机方向 + 墙滑 + 周期跳跃 2.5s。

### 卡住自救（三层）

静态 `.nav` 与运行时动态几何可能不一致（nav 生成时开着的门/路障，运行时关闭），
bot 可能嵌进几何体（vel 有值但零位移；`TeleportEntity` 对 fake client 无效）。
插件三层自救：① **诅咒 area**（连续卡住 → A\* 绕开该区域，TTL 90s）；
② **几何兜底游走**（随机方向强行移动）；③ **重建 bot**（kick + CreateFakeClient
到安全出生点重来，K/D/伤害结转）。

### 僵尸机制（两者都有）

- **NPC 僵尸**：地图实体（`npc_zombie` / `npc_fastzombie` / `npc_manhack` 等），由
  `npc_template_maker` 刷怪器生成。bot 通过全局 NPC 缓存 + 视线（LOS）检测索敌。
- **僵尸玩家队**：隐藏第 4 队，需 `mp_teamplay 1`，**引擎限制全局同时只允许 1 名僵尸玩家，
  且换队赋值无法在重生中保持**（实测换队即自杀、复活后回到人类队）。
  因此本插件以"人类 bot（team 2/3）对抗 NPC 僵尸"为默认形态；
  `anhsbot_quota_joinzombie 1` 保留实验代码路径（进队即死、30s 退避重试）。

---

## 5. 管理命令（rcon / 控制台，需管理员权限）

| 命令 | 说明 |
|---|---|
| `anhsbot_add [名字]` | 添加一个 bot（自动入队 team 2/3）。 |
| `anhsbot_kick <名字\|#序号>` | 踢掉一个 bot。 |
| `anhsbot_kickall` | 踢掉全部 bot。 |
| `anhsbot_list` | 列出全部受管 bot 及实时状态（队伍/存活/目标/射击/伤害/KD）。 |
| `anhsbot_status` | 汇总在线/存活/激活数量与累计 KD/伤害、nav 状态。 |
| `anhsbot_aim [client\|0]` | 诊断：位置/朝向/目标/瞄准误差/武器/nav 路径状态。 |
| `anhsbot_diag` | 诊断：索敌缓存/LOS/武器切换细节。 |
| `anhsbot_tele <client> <x> <y> <z>` | 传送 bot 到坐标（注意：实测瞬移对 fake client 效果有限）。 |
| `anhsbot_npc <类名> <nearClient> [距离]` | 在指定 bot 前方生成一个 NPC（测试用）。 |

---

## 6. 已知限制 / 后续路线

- **僵尸队**：引擎限制（见第 4 节），当前形态为人类队对抗 NPC。
- **nav 覆盖**：37 张图中 11 张带 `.nav` 可直接寻路；其余 26 张可用引擎命令
  `nav_generate`（需 `sv_cheats 1`）现场烘焙后同样支持。有 nav 的图若与运行时几何
  不一致，bot 可能嵌进几何体——三层自救可自动恢复，根治靠重新烘焙。
- **重生**：HL2MP 无回合制/无 `mp_forcerespawn`，死亡 bot 由看门狗用原生
  `CreateFakeClient` 重建（同名同队、结转统计）。
- **反作弊/公网**：部署时建议配合 VAC/SV 反作弊与 `sv_pure 0`（按运营需要）。

---

## 7. 故障排查

- **bot 不动 / `runcmds` 为 0**：检查 `anhsbot_manage_flags` 是否为 1，以及 gamedata
  是否放在 `sdktools.games/custom/`。
- **bot 卡在 team 0**：确认启动参数里 `+mp_teamplay 1` 在 `+map` 之前。
- **bot 干站不动**：看控制台日志——卡住会打 `stuck (moved N in 2s, count N)`，
  随后 `scout walk` / `cursed N area(s)` / `geometry trap, rebuild scheduled`
  是自救链在工作的信号（均带 bot 序号，可定位到具体 bot）。
- **服务器崩溃**：崩溃时 cdb 会自动生成 `anh_crash.dmp`，用
  `cdb -z anh_crash.dmp -c "!analyze -v; q"` 分析。
- **插件加载失败**：用 `sm plugins list` 查看报错；常见为 gamedata 路径/偏移错误。
