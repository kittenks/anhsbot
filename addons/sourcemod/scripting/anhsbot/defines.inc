/**
 * anhsbot/defines.inc — 常量
 */
#define ANHSBOT_VERSION "0.2.0"

// 引擎位标志（m_fFlags，Prop_Send，offset 0x108）
// 【重要】不要用 SM 头文件 entity_prop_stocks.inc 的 FL_FAKECLIENT——它是
// 标准 HL2 的 (1<<8)=0x100；但 ANHS 实测 m_fFlags 布局右移一位：
//   0x100=FL_CLIENT(玩家)，0x200=FL_FAKECLIENT(fake-client 命令循环门槛)。
// 一律用下面的 ANH_FL_* 实机值。
#define ANH_FL_ONGROUND     (1 << 0)    // 0x1
#define ANH_FL_FROZEN       (1 << 6)    // 0x40
#define ANH_FL_CLIENT       (1 << 8)    // 0x100 玩家标记
#define ANH_FL_FAKECLIENT   (1 << 9)    // 0x200 关键：fake-client 命令循环的门槛

// 生命状态（m_lifeState，Prop_Data，offset 0xE8）
#define LIFE_ALIVE        0
#define LIFE_DEAD         2

// 移动类型（m_MoveType，Prop_Data，offset 0x13E）
#define MOVETYPE_NONE     0
#define MOVETYPE_WALK     2
#define MOVETYPE_FLYGRAVITY 5

// 队号（ANHS / HL2MP）
#define TEAM_SPECTATOR    1
#define TEAM_REBELS       2
#define TEAM_COMBINE      3
#define TEAM_ZOMBIE       4

// CUserCmd 按钮（OnPlayerRunCmd 的 buttons）
#define IN_FORWARD_BIT    (1 << 3)   // 8
#define IN_BACK_BIT       (1 << 2)   // 4
#define IN_MOVELEFT_BIT   (1 << 4)   // 16
#define IN_MOVERIGHT_BIT  (1 << 5)   // 32
#define IN_ATTACK_BIT     (1 << 0)   // 1  开火
#define IN_JUMP_BIT       (1 << 1)   // 2  跳跃
#define IN_SPEED_BIT      (1 << 17)  // 疾跑
#define IN_RELOAD_BIT     (1 << 13)  // 换弹

// 合法移动指令分量范围（cl_forwardspeed / cl_sidespeed）
#define MOVE_SPEED_MAX    450.0

// 战斗参数
#define ANH_FOV_HUMAN       2500.0    // 人类索敌视野半径（Source 单位）
#define ANH_FOV_NPC         1500.0    // 对 NPC 的有效作战半径
#define ANH_FOV_COS         0.25      // 视野锥 cos（约 75° 半角，宽松）
#define ANH_RETARGET_INTERVAL 0.30    // 目标重选间隔（秒）
#define ANH_AIM_LERP        0.35      // 默认瞄准角度插值（0~1，越大越硬）
#define ANH_EYE_OFFSET_Z    64.0      // 站立眼高近似（HL2）
#define ANH_MAX_WEAP_SLOTS  48        // m_hMyWeapons 槽数

// —— 技能等级（0=低 1=普通 2=高 3=精英）——
// 影响瞄准插值（跟手程度）与开火允许误差（越准越难打偏）。
// 数组下标 = 技能等级。
#define ANH_SKILL_MAX       3
float g_fAimLerpBySkill[4] = { 0.20, 0.30, 0.42, 0.55 };
float g_fAimErrBySkill[4]  = { 10.0, 6.0,  3.0,  1.5  };

// —— 走位 ——
// 距离带：把"逼近 / 站定"的二值逻辑升级为三段式，
// 让 bot 维持在有效射程内（太近会贴脸穿模且易被秒，太远打不到）。
#define ANH_MOVE_BAND_FAR    220.0     // 超过此距离 → 向前逼近
#define ANH_MOVE_BAND_NEAR    90.0     // 小于此距离 → 后撤拉开
// 处于 [NEAR, FAR] 之间 → 环形绕步（circle-strafe，边走位边开火）
#define ANH_MOVE_SPEED        400.0    // 逼近时的前向移动速度
#define ANH_MOVE_BACKOFF      320.0    // 后撤速度（略慢，避免背身暴毙）
#define ANH_MOVE_STRAFE       300.0    // 绕步侧移速度
#define ANH_MOVE_SLIDE_DIST   70.0     // 前方障碍探测距离（墙/箱/掩体）
#define ANH_MOVE_CLEAR_DIST   55.0     // 探测结果 ≥ 此值才算"通路通畅"
#define ANH_STRAFE_FLIP_MIN   0.7      // 绕步方向翻转最小间隔（秒）
#define ANH_STRAFE_FLIP_MAX   1.8      // 绕步方向翻转最大间隔（秒）

// —— navmesh 寻路（nav.inc）——
#define ANH_NAV_ENGAGE_DIST   700.0    // 目标超过此距离（或无 LOS）→ 走 nav 寻路逼近
#define ANH_WANDER_MIN        6.0      // 空闲漫游最小间隔（秒）
#define ANH_WANDER_MAX        14.0     // 空闲漫游最大间隔（秒）
#define ANH_REGROUP_DIST      250.0    // 与队友小于此距离不集结（太近会穿模）
#define ANH_REGROUP_MAX       1600.0   // 只集结此距离内的队友
#define ANH_REGROUP_MAX_FAILS 3        // 集结连续失败此次数 → 暂停集结转漫游
#define ANH_REGROUP_PAUSE     8.0      // 集结暂停时长（秒）
#define ANH_WANDER_TRIES      6        // 漫游选目标最大候选数（近环带优先，逐步放宽）
#define ANH_WANDER_NEAR_MIN   200.0    // 首选候选环带内径（身侧，最可能同岛连通）
#define ANH_WANDER_NEAR_MAX   900.0    // 首选候选环带外径
#define ANH_WANDER_MAX_FAILS  3        // 连续寻路失败此次数 → 几何兜底游走
#define ANH_SCOUT_WALK_TIME   2.5      // 几何兜底游走时长（秒）
#define ANH_IDLE_LOG_INTERVAL 10.0     // 空闲诊断日志限频（秒/bot）

// 每个 bot 的运行时状态
enum struct BotState
{
    bool   bManaged;          // 是否为本插件创建并管理的 bot
    bool   bActivated;        // 是否已成功盖上 FL_FAKECLIENT
    int    iDesiredTeam;      // 期望队伍
    int    iNameUid;          // 名字序号
    float  fBornAt;           // 创建时间
    float  fNextRespawnCheck; // 下次看门狗处理死亡的时间
    int    iRunCmds;          // OnPlayerRunCmd 心跳计数
    bool   bMoved;            // 是否观察到过位移
    bool   bRebuilding;       // 死亡重建中（防止看门狗重复触发）
    int    iSkill;            // 技能等级 0..ANH_SKILL_MAX

    // —— 战斗 AI（人类 bot）——
    bool   bArmed;            // 本条命是否已发过武器 loadout
    int    iTarget;           // 当前目标实体（玩家或 NPC），0 无
    float  fRetargetAt;       // 下次重选目标的游戏时间
    int    iWantWeapon;       // 待切武器实体（usercmd weaponselect），0 无
    int    iWantSubtype;      // 待切武器 m_iSubType
    float  fNextAmmoCheck;    // 下次补弹时间
    float  fNextFireAt;       // 下次允许开火的游戏时间（点射节奏控制）
    int    iStrafeSign;       // 绕步方向（+1/-1），定时翻转制造不规则走位
    float  fNextStrafeFlip;   // 下次翻转绕步方向的游戏时间
    float  fLastVelFwd;       // 诊断：上帧本地前向速度（走位验证用）
    float  fLastVelRight;     // 诊断：上帧本地侧向速度（绕步/墙滑验证用）
    int    iShotsFired;       // 本命开火次数（统计）
    int    iKills;            // 累计击杀（统计）
    int    iDeaths;           // 累计死亡（统计）

    // —— 伤害/击杀统计（对 NPC 也生效；NPC 无 player_death 事件）——
    int    iDamageDealt;      // 累计造成的伤害
    float  fLastTargetHp;     // 上一 tick 当前目标的血量（-1 = 无）
    float  fLastDamageAt;     // 最近一次打到目标的时间（用于归属判定）
    float  fDiedAt;           // 死亡时间（重生看门狗用）

    // —— navmesh 走位 / 空闲行为（nav.inc）——
    bool   bNavMove;          // 本帧是否使用 nav 路径方向（覆盖距离带逻辑）
    float  fNavDirX;          // nav 期望世界方向（单位水平向量）
    float  fNavDirY;
    float  fNavSpeed;         // nav 走位速度
    float  fNextWanderAt;     // 下次空闲漫游选目标的游戏时间
    float  fWanderX;          // 当前漫游目标
    float  fWanderY;
    float  fWanderZ;
    bool   bWanderActive;     // 是否有有效漫游目标
    int    iWanderFails;      // 连续漫游寻路失败次数（达上限 → 几何兜底游走）
    bool   bScoutWalk;        // 几何兜底游走中（随机方向 + 墙滑，不寻路）
    float  fScoutUntil;       // 兜底游走截止时间
    float  fScoutYaw;         // 兜底游走方向（度）
    float  fNextJumpAt;       // 兜底游走期间下次跳跃时间（lip/台阶卡住自救）
    float  fNextZombieTry;    // 下次尝试加入僵尸队的游戏时间（引擎限制退避）

    // —— 队友识别（teamplay）——
    int    iRegroupFails;     // 连续集结寻路失败次数（达上限 → 暂停集结）
    float  fRegroupPauseUntil;// 集结暂停截止时间（不可达时转漫游）
    float  fLastFriendlyHold; // 诊断：上次因队友遮挡放弃开火的游戏时间
    float  fLastIdleLogAt;    // 空闲诊断日志限频（卡住/寻路失败/scout）

    // —— LOS 检测缓存（限频，防每帧 trace 堆积）——
    float  fNextLosCheck;     // 下次做目标 LOS 检测的游戏时间
    bool   bHasLOS;           // 最近一次 LOS 检测结果（目标可见性）

    // —— 卡住检测（nav 走位自救）——
    float  fStuckCheckAt;     // 下次卡住检测的游戏时间（0 = 未开始）
    float  fStuckRefX;        // 上次检测时的水平位置
    float  fStuckRefY;
    int    iStuckCount;       // 卡住计数（好窗口 -1 衰减，非连续；≥2 诅咒/scout，≥3 重建）
    float  fNavPauseUntil;    // nav 暂停截止时间（卡住后让几何走位接管几秒）
    float  fStuckRebuildAt;   // 挂起的卡住重建执行时间（0 = 无；bot.sp 看门狗执行）
    float  fNextStuckRebuildAt;// 下次允许卡住重建的时间（限频，防出生点污染的 churn）
}
