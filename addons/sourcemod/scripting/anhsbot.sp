/**
 * =============================================================================
 *  anhsbot — A Nights Haunting Source (ANHS) 机器人插件
 *  作者 / Author: kittenks (https://github.com/kittenks/anhsbot)
 *  仿 zpsbot 架构 · SourceMod 1.12 新语法 · 基于实机逆向验证
 *
 *  引擎：ANHS = HL2MP(sdk2013) 引擎 + ZPS 代码血统（Steam AppId 243750）
 *
 *  本插件全部核心机制均在真机上逆向验证（见 HANDOFF.md）：
 *   1) OnPlayerRunCmd 驱动前提：
 *      - gamedata PlayerRunCmd 必须是玩家 vtable[418]（offset 0x688），
 *        旧的 432（空函数）/426（bool getter）均错误。
 *      - CreateFakeClient 的 bot 缺少 m_fFlags 的 FL_FAKECLIENT(1<<9=0x200)，
 *        引擎 fake-client 命令循环（server RVA 0x426f70）只处理带该标志的
 *        玩家，必须显式 OR 上 0x200，OnPlayerRunCmd 才会每 tick 触发。
 *   2) bot 入队：启动命令行必须在 +map 之前 +mp_teamplay 1，
 *      gameRules 构造时 m_bTeamPlayEnabled 才为 1，全新 bot 自动进 2/3 队并
 *      正常出生，无需 changelevel、无需手动 jointeam。
 *   3) 驱动移动：OnPlayerRunCmd 内改 vel[0/1]（forwardmove/sidemove）并
 *      return Plugin_Changed，引擎才会回写 CUserCmd。
 *
 *  红线（继承 zpsbot）：
 *   - 不直接 ChangeClientTeam 绕过出生流程；
 *   - 只用 CreateFakeClient 原生路径；
 *   - 不调用游戏原生 bot_zps_add_*（会打 CUSTOM 水印/不可用于生产）。
 * =============================================================================
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_functions>
#include <sdktools_entinput>

#include "anhsbot/defines.inc"
#include "anhsbot/globals.inc"
#include "anhsbot/util.inc"
#include "anhsbot/weapons.sp"
#include "anhsbot/targeting.sp"
#include "anhsbot/bot.sp"
#include "anhsbot/bots_cfg.inc"
#include "anhsbot/nav.inc"
#include "anhsbot/runcmd.sp"
#include "anhsbot/cmd.sp"

public Plugin myinfo =
{
    name        = "ANHS Bots",
    author      = "kittenks",
    description = "Native fake-client bots for A Nights Haunting Source",
    version     = ANHSBOT_VERSION,
    url         = "https://github.com/kittenks/anhsbot"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("anhsbot_enable", "1", "Master switch for ANHS bots", _, true, 0.0, true, 1.0);
    g_cvTargetCount = CreateConVar("anhsbot_count", "0", "Target number of bots to keep online", _, true, 0.0, true, 32.0);
    g_cvNamePrefix = CreateConVar("anhsbot_name_prefix", "AnhBot", "Name prefix for bots");
    g_cvAutoFill = CreateConVar("anhsbot_autofill", "1", "Automatically maintain the target bot count");
    g_cvFillInterval = CreateConVar("anhsbot_fill_interval", "3.0", "Seconds between autofill checks", _, true, 1.0);
    g_cvManageFlags = CreateConVar("anhsbot_manage_flags", "1", "Continuously re-assert FL_FAKECLIENT on bots");
    g_cvRespawnDelay = CreateConVar("anhsbot_respawn_delay", "6.0", "Seconds a dead bot waits before the watchdog forces a respawn", _, true, 1.0);
    g_cvSkill = CreateConVar("anhsbot_skill", "2", "Default bot skill level 0=low 1=normal 2=high 3=elite", _, true, 0.0, true, float(ANH_SKILL_MAX));
    g_cvDebug = CreateConVar("anhsbot_debug", "0", "Verbose debug logging", _, true, 0.0, true, 1.0);

    // quota：bot 配额（>0 覆盖 anhsbot_count，维持在线总数；不足自动加、超出自动踢）
    g_cvQuota = CreateConVar("anhsbot_quota", "0", "Total bot quota kept online (0 = use anhsbot_count instead)", _, true, 0.0, true, float(MaxClients - 1));
    // 僵尸队配额（引擎限制：僵尸队最多 1 名玩家；换队会死一次，实验性）
    g_cvQuotaJoinZombie = CreateConVar("anhsbot_quota_joinzombie", "0", "How many quota bots may join the zombie team (0/1; engine caps zombie team at 1)", _, true, 0.0, true, 1.0);
    // 队友识别：幸存者(2/3)互为队友——不互杀、防友伤、空闲集结
    g_cvTeamplay = CreateConVar("anhsbot_teamplay", "1", "Treat survivor teams 2/3 as one side: no infighting, no friendly fire, regroup when idle");
    // navmesh 寻路（有 .nav 的地图启用；无 nav 自动回退几何走位）
    g_cvNavEnable = CreateConVar("anhsbot_nav", "1", "Use .nav mesh A* pathfinding when the map has a nav file");
    // 稳定性：地图启动时禁用 logic_achievement（ANHS 成就系统对 fake client 有空指针崩溃）
    g_cvNoAchievements = CreateConVar("anhsbot_no_achievements", "1", "Disable logic_achievement entities on map start (works around fake-client achievement crash)");

    g_fRespawnDelay = GetConVarFloat(g_cvRespawnDelay);

    BotsCfg_Load();

    AutoExecConfig(true, "plugin.anhsbot");

    // 武器 SDKCall（WeaponEquip vtable slot261，真机逆向验证）。
    Wep_InitSDK();

    HookEvent("player_spawn", Bot_OnPlayerSpawn);
    HookEvent("player_death", Bot_OnPlayerDeath);
    HookEvent("player_hurt", Bot_OnPlayerHurt);
    HookEvent("player_team", Bot_OnPlayerTeam);

    RegAdminCmd("anhsbot_add",    Cmd_Add,    ADMFLAG_GENERIC, "anhsbot_add [name] - add one bot");
    RegAdminCmd("anhsbot_kick",   Cmd_Kick,   ADMFLAG_GENERIC, "anhsbot_kick <name|#idx> - kick one bot");
    RegAdminCmd("anhsbot_kickall",Cmd_KickAll,ADMFLAG_GENERIC, "Kick all anhsbot bots");
    RegAdminCmd("anhsbot_list",   Cmd_List,   ADMFLAG_GENERIC, "List anhsbot bots");
    RegAdminCmd("anhsbot_status", Cmd_Count,  ADMFLAG_GENERIC, "Show live bot count/status");
    RegAdminCmd("anhsbot_aim",    Cmd_AimInfo,ADMFLAG_GENERIC, "Debug bot aim/target info");
    RegAdminCmd("anhsbot_diag",   Cmd_Diag,   ADMFLAG_GENERIC, "Diagnose targeting cache/LOS/weapon");
    RegAdminCmd("anhsbot_tele",   Cmd_Tele,   ADMFLAG_GENERIC, "anhsbot_tele <client> <x> <y> <z>");
    RegAdminCmd("anhsbot_npc",    Cmd_SpawnNpc,ADMFLAG_GENERIC, "anhsbot_npc <classname> <nearClient> [dist]");

    CreateTimer(GetConVarFloat(g_cvFillInterval), Timer_AutoFill, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    PrintToServer("[anhsbot] loaded v%s (PlayerRunCmd vtable 418 + FL_FAKECLIENT activation)", ANHSBOT_VERSION);
}

public void OnConfigsExecuted()
{
    // 地图已就绪、cfg 已执行；若开机即要求 bot，下一帧开始补齐。
    RequestFrame(Bot_InitialFill);
}

public void OnMapStart()
{
    // 换图后所有 bot 实体重建；运行时地址/标志状态也重置，交给看门狗重新激活。
    Bot_ResetMapState();
    Wep_ResetForMap();
    // 换图会踢掉所有 bot，且 autofill 计时器被 TIMER_FLAG_NO_MAPCHANGE 销毁，
    // 这里下一帧重新补齐到目标数量（生产服换图后自动恢复 bot）。
    RequestFrame(Bot_InitialFill);

    // navmesh：解析本地图 .nav（无文件则禁用寻路，走位回退几何逻辑）。
    // 延迟一帧执行：此时地图名与实体均已就绪。
    RequestFrame(Nav_MapStartFrame);

    // 稳定性：禁用成就实体（规避 fake client 触发 MOD_* 成就时的 server.dll 空指针崩溃）。
    // 实体在地图加载完成后才存在，延迟 1 秒扫描。
    if (g_cvNoAchievements != null && g_cvNoAchievements.BoolValue)
        CreateTimer(1.0, Timer_DisableAchievements, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Nav_MapStartFrame()
{
    char map[64];
    GetCurrentMap(map, sizeof(map));
    if (g_cvNavEnable == null || g_cvNavEnable.BoolValue)
        Nav_Load(map);
    else
        Log("[anhsbot] nav: disabled by cvar");
}

// 禁用地图上所有 logic_achievement 实体。
// 【背景】实测：bot（fake client）踩 killhaus 熊夹陷阱死亡 → MOD_BEAR_TRAP 成就触发 →
// server.dll 空指针崩溃（server+0x109c90 mov edx,[ecx+0x81C], ecx=0）。禁用后
// 反复踩陷阱不再触发该路径。人类玩家会同时失去成就弹窗， bot 服可接受。
public Action Timer_DisableAchievements(Handle timer)
{
    int n = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "logic_achievement")) != -1)
    {
        AcceptEntityInput(ent, "Disable", -1, -1, 0);
        n++;
    }
    if (n > 0)
        Log("[anhsbot] disabled %d logic_achievement entities (fake-client crash workaround)", n);
    return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
        return;
    // 仅管理本插件创建的 bot（名字戳 + 状态数组）
    Bot_OnPutInServer(client);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
        Bot_OnDisconnect(client);
}

public void OnGameFrame()
{
    Bot_ThinkWatchdog();
}
