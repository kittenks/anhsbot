/**
 * anhsbot/globals.inc — 全局变量（ConVar / bot 状态表）
 */
ConVar g_cvEnabled       = null;   // anhsbot_enable 总开关
ConVar g_cvTargetCount   = null;   // anhsbot_count 目标在线 bot 数
ConVar g_cvNamePrefix    = null;   // 名字前缀
ConVar g_cvAutoFill      = null;   // 自动补齐到目标数量
ConVar g_cvFillInterval  = null;   // 补齐检查间隔（秒）
ConVar g_cvManageFlags   = null;   // 看门狗：每帧重设 FL_FAKECLIENT
ConVar g_cvRespawnDelay  = null;   // anhsbot_respawn_delay 死亡多久后主动重生
ConVar g_cvDebug         = null;   // 调试日志
ConVar g_cvSkill         = null;   // anhsbot_skill 默认技能等级（0..3）

// —— quota 自动加入 ----
ConVar g_cvQuota          = null;  // anhsbot_quota bot 配额（>0 时维持在线总数，覆盖 count）
ConVar g_cvQuotaJoinZombie = null; // anhsbot_quota_joinzombie 允许加入僵尸队的配额 bot 数（0/1，引擎限制最多1）
// —— 队友识别 / 导航 / 稳定性 ----
ConVar g_cvTeamplay       = null;  // anhsbot_teamplay 幸存者互为队友（2/3 不互杀、防友伤、集结）
ConVar g_cvNavEnable      = null;  // anhsbot_nav 启用 .nav 寻路（有 nav 文件时）
ConVar g_cvNoAchievements = null;  // anhsbot_no_achievements 地图启动时禁用成就实体（规避 fake client 成就崩溃）

float  g_fRespawnDelay   = 6.0;    // anhsbot_respawn_delay 死亡多久后主动重生

BotState g_Bot[MAXPLAYERS + 1];
int g_iNameUid = 0;

// —— 机器人名字池（从 cfg/sourcemod/anhsbot_bots.cfg 加载，最多 64 条）——
#define ANH_NAMEPOOL_MAX   64
int   g_iNamePoolCount = 0;
char  g_szNamePool[ANH_NAMEPOOL_MAX][64];
int   g_iNamePoolSkill[ANH_NAMEPOOL_MAX];
int   g_iNameCursor = 0;            // 轮询游标
