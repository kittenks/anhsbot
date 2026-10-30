/**
 * =============================================================================
 *  anhsbot_probe.sp — ANHS 游戏机制探针（anhsbot 开发调研用）v2.0
 *
 *  v2.0 新增（P0 续 / P1）：
 *   - sm_anhfakebot [name]      : CreateFakeClient 建假客户端（zpsbot 生产路径）
 *   - sm_anhfakekick            : 踢出所有 fake client
 *   - sm_anhfakecmd <c> <cmd>   : 对 fake client 发任意玩家命令
 *   - sm_anhfakejoin <c> <team> : 下一帧序列 joingame -> jointeam N
 *   - sm_anhcounts              : 采样所有 client 的 team/alive/runcmd 计数
 *   - 每 10 秒自动采样一次 fake client 状态（写进 console.log）
 *
 *  v1.0 保留：
 *   sm_anhprobe / sm_anhbotevents / sm_anhteam / sm_anhjoin / sm_anhtry
 *   OnPlayerRunCmd 计数器（第 1 次与每 300 次打印 FIRED）
 * =============================================================================
 */
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "ANHS Bot Probe",
    author = "anhsbot dev",
    description = "Probe ANHS game mechanics for anhsbot development",
    version = "2.0.0"
};

int g_iRunCmdCount[MAXPLAYERS+1];
int g_bFake[MAXPLAYERS+1];
Handle g_hSampleTimer = null;
bool g_bSimWatch = false;
int g_iFrameCount = 0;
int g_iLastTick[MAXPLAYERS+1];
bool g_bFakeAuto[MAXPLAYERS+1];
int g_iMoveTest[MAXPLAYERS+1];   // 0=none, 1=IN_FORWARD, 2=IN_MOVERIGHT ...
#define IN_FORWARD_BIT 8
#define IN_MOVERIGHT_BIT 32
#define IN_ATTACK_BIT 1
// 战斗链路测试：>0 = 该武器实体每帧 weaponselect+IN_ATTACK（验证装备后能否开火）
int g_iCombatWeapon[MAXPLAYERS+1];
int g_iCombatSubtype[MAXPLAYERS+1];

// 直接调用游戏原生 ChangeTeam = CHL2MP_Player vtable[463]（ANHS 实测）。
// thiscall(this=player, int team) -> bool。等价于 jointeam 命令最终调用的完整进队/出生逻辑。
Handle g_hChangeTeam = null;
// 对照：vtable[91]（SetTeam，ChangeTeam 内部调用的底层）
Handle g_hSetTeam = null;
// ANHS 真实 WeaponEquip = CHL2MP_Player vtable[261]（静态实证：玩家版 0x322580，
// 内部 call CC WeaponEquip 0x23e6f0 -> Weapon_AddToInventory 0x108990，写入 m_hMyWeapons 空槽）。
// ZPS gamedata 给的 272 在 ANHS 是武器射击音效函数（0x31fda0），错误。
// thiscall(this=player, CBaseEntity *weapon) -> void，ret4。
Handle g_hWeaponEquip = null;
// kernelbase!VirtualAlloc（stdcall 静态函数），用于分配原生 CCommand 内存
Handle g_hVirtualAlloc = null;
Address g_ccmdMem = Address_Null;
#define VA_ADDR 0x758c3cb0          // KERNELBASE!VirtualAlloc（运行时，重启需重查）
#define VA_COMMIT_RESERVE 0x3000
#define VA_RW 0x04
#define CCMD_SIZE 0x1000

public void OnPluginStart()
{
    RegAdminCmd("sm_anhprobe", Command_Probe, ADMFLAG_GENERIC, "Run ANHS mechanism probe");
    RegAdminCmd("sm_anhbotevents", Command_Events, ADMFLAG_GENERIC, "Hook and log game events");
    RegAdminCmd("sm_anhteam", Command_SetTeam, ADMFLAG_GENERIC, "sm_anhteam <client> <team> - force team change test");
    RegAdminCmd("sm_anhjoin", Command_Join, ADMFLAG_GENERIC, "sm_anhjoin <client> <team> - joingame+jointeam test");
    RegAdminCmd("sm_anhtry", Command_TryAll, ADMFLAG_GENERIC, "sm_anhtry <client> - try all join methods");

    RegAdminCmd("sm_anhfakebot", Command_FakeBot, ADMFLAG_ROOT, "sm_anhfakebot [name] - CreateFakeClient");
    RegAdminCmd("sm_anhfakekick", Command_FakeKick, ADMFLAG_ROOT, "Kick all fake clients");
    RegAdminCmd("sm_anhfakecmd", Command_FakeCmd, ADMFLAG_ROOT, "sm_anhfakecmd <client> <command...>");
    RegAdminCmd("sm_anhfakejoin", Command_FakeJoin, ADMFLAG_ROOT, "sm_anhfakejoin <client> <team> - delayed joingame+jointeam");
    RegAdminCmd("sm_anhcounts", Command_Counts, ADMFLAG_GENERIC, "Sample client runcmd counts/teams");
    RegAdminCmd("sm_anhvtable", Command_VTable, ADMFLAG_ROOT, "sm_anhvtable <client> [lo] [hi] - dump player vtable slot addresses");
    RegAdminCmd("sm_anhsim", Command_SimWatch, ADMFLAG_ROOT, "sm_anhsim <0|1> - watch fake client m_nTickBase per frame");
    RegAdminCmd("sm_anhcallteam", Command_CallTeam, ADMFLAG_ROOT, "sm_anhcallteam <client> <team> - direct SDKCall vtable[463] ChangeTeam");
    RegAdminCmd("sm_anhcallset", Command_CallSet, ADMFLAG_ROOT, "sm_anhcallset <client> <team> - direct SDKCall vtable[91] SetTeam");
    RegAdminCmd("sm_anhcallraw", Command_CallRaw, ADMFLAG_ROOT, "sm_anhcallraw <client> <team> [slot] - SDKCall_Raw + SetAddress vtable slot");
    RegAdminCmd("sm_anhcalladdr", Command_CallAddr, ADMFLAG_ROOT, "sm_anhcalladdr <client> <hexaddr> <arg> - SDKCall_Raw arbitrary address");
    RegAdminCmd("sm_anhcmd368", Command_Cmd368, ADMFLAG_ROOT, "sm_anhcmd368 <client> <cmdline...> - build CCommand, call vtable[368] ClientCommand");
    RegAdminCmd("sm_anhsetflag", Command_SetFlag, ADMFLAG_ROOT, "sm_anhsetflag <client> [maskhex] - OR/set m_fFlags (default OR 0x200 FL_FAKECLIENT); no mask = print");
    RegAdminCmd("sm_anhfakeauto", Command_FakeAuto, ADMFLAG_ROOT, "sm_anhfakeauto <client> - re-assert FL_FAKECLIENT every frame");
    RegAdminCmd("sm_anhmove", Command_MoveTest, ADMFLAG_ROOT, "sm_anhmove <client> <0|1|2> - inject move buttons");
    RegAdminCmd("sm_anhstate", Command_State, ADMFLAG_ROOT, "sm_anhstate <client> - dump movetype/vel/flags");
    RegAdminCmd("sm_anhorigin", Command_Origin, ADMFLAG_ROOT, "sm_anhorigin <ent> - compare m_vecOrigin vs m_vecAbsOrigin");
    RegAdminCmd("sm_anhnpcs", Command_Npcs, ADMFLAG_ROOT, "sm_anhnpcs - dump npc_* / hostile entities");
    RegAdminCmd("sm_anhweps", Command_Weapons, ADMFLAG_ROOT, "sm_anhweps <client> - dump weapons held by client");
    RegAdminCmd("sm_anhgive", Command_Give, ADMFLAG_ROOT, "sm_anhgive <client> <weapon_class> - GivePlayerItem + WeaponEquip[261]");
    RegAdminCmd("sm_anhequip", Command_Equip, ADMFLAG_ROOT, "sm_anhequip <client> <weapon_ent> - call WeaponEquip vtable[261]");
    RegAdminCmd("sm_anhcombat", Command_Combat, ADMFLAG_ROOT, "sm_anhcombat <client> <0|weapon_ent> [subtype] - fire test");
    RegAdminCmd("sm_anhents", Command_Ents, ADMFLAG_ROOT, "sm_anhents [prefix] - enumerate entities by classname prefix");

    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_team", Event_PlayerTeam);

    // 准备 ChangeTeam vtable[463]
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetVirtual(463);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hChangeTeam = EndPrepSDKCall();

    // 准备 SetTeam vtable[91]
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetVirtual(91);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSetTeam = EndPrepSDKCall();

    // 准备 WeaponEquip vtable[261]（ANHS 实测）：this=player，参数=武器实体
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetVirtual(261);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Plain);
    g_hWeaponEquip = EndPrepSDKCall();

    // 准备 VirtualAlloc（静态 stdcall）：(lpAddress, size, type, protect) -> addr
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetAddress(view_as<Address>(VA_ADDR));
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // lpAddress
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // size
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // type
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // protect
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hVirtualAlloc = EndPrepSDKCall();
    if (g_hVirtualAlloc != null)
    {
        g_ccmdMem = view_as<Address>(SDKCall(g_hVirtualAlloc, 0, CCMD_SIZE, VA_COMMIT_RESERVE, VA_RW));
        PrintToServer("[ANHPROBE] VirtualAlloc -> 0x%08x", view_as<int>(g_ccmdMem));
    }
    else
    {
        PrintToServer("[ANHPROBE] VirtualAlloc SDKCall prep FAILED");
    }

    PrintToServer("[ANHPROBE] v2.1 loaded (ChangeTeam463=%s SetTeam91=%s WeaponEquip261=%s VAlloc=%s)",
        g_hChangeTeam != INVALID_HANDLE ? "OK" : "FAIL",
        g_hSetTeam != INVALID_HANDLE ? "OK" : "FAIL",
        g_hWeaponEquip != INVALID_HANDLE ? "OK" : "FAIL",
        g_hVirtualAlloc != null ? "OK" : "FAIL");
}

public void OnMapStart()
{
    CreateTimer(10.0, Timer_AutoProbe);
    if (g_hSampleTimer == null)
        g_hSampleTimer = CreateTimer(10.0, Timer_Sample, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
    g_iRunCmdCount[client] = 0;
    g_bFake[client] = IsFakeClient(client) ? 1 : 0;
    PrintToServer("[ANHPROBE] OnClientPutInServer: client=%d fake=%d team=%d",
        client, IsFakeClient(client), GetClientTeam(client));
}

public void OnClientDisconnect(int client)
{
    PrintToServer("[ANHPROBE] OnClientDisconnect: client=%d fake=%d runcmds=%d",
        client, g_bFake[client], g_iRunCmdCount[client]);
    g_iRunCmdCount[client] = 0;
    g_bFake[client] = 0;
}

public Action Timer_AutoProbe(Handle timer)
{
    ProbeAll();
    return Plugin_Stop;
}

public Action Timer_Sample(Handle timer)
{
    bool any = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i))
        {
            if (!any)
            {
                PrintToServer("[ANHPROBE] ---- periodic fake sample ----");
                any = true;
            }
            PrintToServer("[ANHPROBE] sample: client=%d name=%N team=%d alive=%d runcmds=%d",
                i, i, GetClientTeam(i), IsPlayerAlive(i), g_iRunCmdCount[i]);
        }
    }
    return Plugin_Continue;
}

// ---- PlayerRunCmd 可用性验证（anhsbot AI 驱动的关键）----
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    g_iRunCmdCount[client]++;
    if (g_iRunCmdCount[client] == 1 || g_iRunCmdCount[client] % 300 == 0)
    {
        PrintToServer("[ANHPROBE] OnPlayerRunCmd FIRED: client=%d fake=%d count=%d",
            client, IsFakeClient(client), g_iRunCmdCount[client]);
    }
    // P0 驱动验证：对开启 movetest 的 bot 注入移动按钮 + 本地移动分量。
    // 关键：必须 return Plugin_Changed，SourceMod 才把 buttons/vel 回写 CUserCmd。
    // vel[0]=forwardmove、vel[1]=sidemove（cl_forwardspeed/sidespeed=450）。
    if (g_iMoveTest[client] == 1)
    {
        buttons |= IN_FORWARD_BIT;
        vel[0] = 450.0;
        return Plugin_Changed;
    }
    else if (g_iMoveTest[client] == 2)
    {
        buttons |= IN_MOVERIGHT_BIT;
        vel[1] = 450.0;
        return Plugin_Changed;
    }
    // 战斗链路：请求切到 g_iCombatWeapon 并按住 IN_ATTACK（沿当前朝向）。
    if (g_iCombatWeapon[client] > 0)
    {
        int w = g_iCombatWeapon[client];
        if (!IsValidEntity(w))
        {
            g_iCombatWeapon[client] = 0;
        }
        else
        {
            weapon = w;
            subtype = g_iCombatSubtype[client];
            buttons |= IN_ATTACK_BIT;
            return Plugin_Changed;
        }
    }
    return Plugin_Continue;
}

// sm_anhmove <client> <0|1|2>：注入前进/右移按钮测试
public Action Command_MoveTest(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhmove <client> <0=off|1=forward|2=right>");
        return Plugin_Handled;
    }
    char szClient[16], szMode[12];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szMode, sizeof(szMode));
    int target = StringToInt(szClient);
    int mode = StringToInt(szMode);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    g_iMoveTest[target] = mode;
    float pos[3];
    GetClientAbsOrigin(target, pos);
    PrintToServer("[ANHPROBE] movetest client=%d mode=%d startpos=(%.1f,%.1f,%.1f)",
        target, mode, pos[0], pos[1], pos[2]);
    return Plugin_Handled;
}

public Action Command_Probe(int client, int args)
{
    ProbeAll();
    return Plugin_Handled;
}

public Action Command_Events(int client, int args)
{
    PrintToServer("[ANHPROBE] event hooks active (player_death/hurt/spawn/team)");
    return Plugin_Handled;
}

// ---- CreateFakeClient 路径（zpsbot 生产路径）----
public Action Command_FakeBot(int client, int args)
{
    char szName[32];
    if (args >= 1)
    {
        GetCmdArg(1, szName, sizeof(szName));
    }
    else
    {
        static int n = 0;
        Format(szName, sizeof(szName), "AFake%02d", ++n);
    }

    int bot = CreateFakeClient(szName);
    if (bot <= 0)
    {
        PrintToServer("[ANHPROBE] CreateFakeClient('%s') FAILED (slot/map/mod blocked)", szName);
        return Plugin_Handled;
    }
    SetClientInfo(bot, "name", szName);
    g_bFake[bot] = 1;
    g_iRunCmdCount[bot] = 0;
    PrintToServer("[ANHPROBE] CreateFakeClient('%s') OK -> client=%d team=%d",
        szName, bot, GetClientTeam(bot));
    return Plugin_Handled;
}

public Action Command_FakeKick(int client, int args)
{
    int kicked = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i))
        {
            PrintToServer("[ANHPROBE] kicking fake client=%d (%N), runcmds was %d", i, i, g_iRunCmdCount[i]);
            KickClient(i, "[anhsbot probe] fake kick");
            kicked++;
        }
    }
    PrintToServer("[ANHPROBE] kicked %d fake clients", kicked);
    return Plugin_Handled;
}

public Action Command_FakeCmd(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhfakecmd <client> <command...>");
        return Plugin_Handled;
    }
    char szClient[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    int target = StringToInt(szClient);
    if (!IsClientInGame(target) || !IsFakeClient(target))
    {
        PrintToServer("[ANHPROBE] client %d not a fake client in game", target);
        return Plugin_Handled;
    }
    char szCmd[128];
    GetCmdArgString(szCmd, sizeof(szCmd));
    // 去掉第一个参数（client 号）
    int idx;
    if (szCmd[0] == '"')
    {
        idx = 1;
        while (szCmd[idx] != '\0' && szCmd[idx] != '"') idx++;
        if (szCmd[idx] == '"') idx++;
    }
    else
    {
        while (szCmd[idx] != '\0' && szCmd[idx] != ' ') idx++;
    }
    while (szCmd[idx] == ' ') idx++;
    PrintToServer("[ANHPROBE] FakeClientCommand(%d, '%s') team=%d ->", target, szCmd[idx], GetClientTeam(target));
    FakeClientCommand(target, "%s", szCmd[idx]);
    PrintToServer("[ANHPROBE] after cmd: team=%d alive=%d", GetClientTeam(target), IsPlayerAlive(target));
    return Plugin_Handled;
}

public Action Command_FakeJoin(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhfakejoin <client> <team>");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    if (!IsClientInGame(target) || !IsFakeClient(target))
    {
        PrintToServer("[ANHPROBE] client %d not a fake client in game", target);
        return Plugin_Handled;
    }
    DataPack pack = new DataPack();
    pack.WriteCell(target);
    pack.WriteCell(team);
    PrintToServer("[ANHPROBE] scheduling join sequence for %d -> team %d (team now %d)",
        target, team, GetClientTeam(target));
    CreateTimer(0.3, Timer_JoinStep1, pack);
    return Plugin_Handled;
}

public Action Timer_JoinStep1(Handle timer, DataPack pack)
{
    pack.Reset();
    int bot = pack.ReadCell();
    if (IsClientInGame(bot) && IsFakeClient(bot))
    {
        PrintToServer("[ANHPROBE] seq1 joingame bot=%d team=%d", bot, GetClientTeam(bot));
        FakeClientCommand(bot, "joingame");
    }
    CreateTimer(0.3, Timer_JoinStep2, pack);
    return Plugin_Stop;
}

public Action Timer_JoinStep2(Handle timer, DataPack pack)
{
    pack.Reset();
    int bot = pack.ReadCell();
    int team = pack.ReadCell();
    if (IsClientInGame(bot) && IsFakeClient(bot))
    {
        PrintToServer("[ANHPROBE] seq2 jointeam %d bot=%d team(before)=%d", team, bot, GetClientTeam(bot));
        FakeClientCommand(bot, "jointeam %d", team);
        CreateTimer(0.5, Timer_JoinCheck, pack);
        return Plugin_Stop;
    }
    delete pack;
    return Plugin_Stop;
}

public Action Timer_JoinCheck(Handle timer, DataPack pack)
{
    pack.Reset();
    int bot = pack.ReadCell();
    int team = pack.ReadCell();
    if (IsClientInGame(bot) && IsFakeClient(bot))
    {
        PrintToServer("[ANHPROBE] join result: bot=%d team=%d alive=%d (wanted %d)",
            bot, GetClientTeam(bot), IsPlayerAlive(bot), team);
    }
    delete pack;
    return Plugin_Stop;
}

public Action Command_Counts(int client, int args)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            PrintToServer("[ANHPROBE] counts: client=%d name=%N fake=%d team=%d alive=%d runcmds=%d",
                i, i, IsFakeClient(i), GetClientTeam(i), IsPlayerAlive(i), g_iRunCmdCount[i]);
        }
    }
    return Plugin_Handled;
}

public void OnGameFrame()
{
    // P0 实验：对开启 fakeauto 的 bot 每帧强制重设 FL_FAKECLIENT(0x200)。
    // 引擎的 fake-client 命令循环（server RVA 0x426f70）只处理 m_fFlags & 0x200 的玩家。
    for (int f = 1; f <= MaxClients; f++)
    {
        if (g_bFakeAuto[f] && IsClientInGame(f) && IsFakeClient(f))
        {
            int fl = GetEntProp(f, Prop_Send, "m_fFlags");
            if ((fl & 0x200) == 0)
            {
                SetEntProp(f, Prop_Send, "m_fFlags", fl | 0x200);
                PrintToServer("[ANHPROBE] fakeauto: client=%d re-assert FL_FAKECLIENT (was %d)", f, fl);
            }
        }
    }

    if (!g_bSimWatch)
        return;
    g_iFrameCount++;
    if (g_iFrameCount % 15 != 0)
        return;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i))
            continue;
        int tick = GetEntProp(i, Prop_Send, "m_nTickBase");
        int buttons = GetEntProp(i, Prop_Data, "m_nButtons");
        int flags = GetEntProp(i, Prop_Send, "m_fFlags");
        PrintToServer("[ANHPROBE] sim frame=%d client=%d team=%d alive=%d tickbase=%d (delta=%d) buttons=%d flags=%d",
            g_iFrameCount, i, GetClientTeam(i), (IsPlayerAlive(i)?1:0),
            tick, tick - g_iLastTick[i], buttons, flags);
        g_iLastTick[i] = tick;
    }
}

// sm_anhorigin <ent>：对比 m_vecOrigin(776) 与 m_vecAbsOrigin(640)
public Action Command_Origin(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhorigin <ent>");
        return Plugin_Handled;
    }
    char szE[16];
    GetCmdArg(1, szE, sizeof(szE));
    int e = StringToInt(szE);
    if (!IsValidEntity(e))
    {
        PrintToServer("[ANHPROBE] ent %d invalid", e);
        return Plugin_Handled;
    }
    char cls[64];
    GetEntityClassname(e, cls, sizeof(cls));
    float o[3], a[3], v[3];
    GetEntPropVector(e, Prop_Data, "m_vecOrigin", o);
    GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", a);
    GetEntPropVector(e, Prop_Data, "m_vecAbsVelocity", v);
    PrintToServer("[ANHPROBE] origin ent=%d %s", e, cls);
    PrintToServer("[ANHPROBE]   m_vecOrigin    (776) = (%.1f, %.1f, %.1f)", o[0], o[1], o[2]);
    PrintToServer("[ANHPROBE]   m_vecAbsOrigin (640) = (%.1f, %.1f, %.1f)", a[0], a[1], a[2]);
    PrintToServer("[ANHPROBE]   m_vecAbsVelocity       = (%.1f, %.1f, %.1f) movetype=%d",
        v[0], v[1], v[2], GetEntProp(e, Prop_Data, "m_MoveType"));
    return Plugin_Handled;
}

// sm_anhsetflag <client> [maskhex]
// 无 mask：打印当前 m_fFlags；有 mask：OR 上该掩码（默认建议 0x200 = FL_FAKECLIENT）。
public Action Command_SetFlag(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhsetflag <client> [maskhex]");
        return Plugin_Handled;
    }
    char szClient[16], szMask[24];
    GetCmdArg(1, szClient, sizeof(szClient));
    int target = StringToInt(szClient);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    int fl = GetEntProp(target, Prop_Send, "m_fFlags");
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] client=%d m_fFlags=%d (0x%x) fake=%d FL_FAKECLIENT(0x200)=%d",
            target, fl, fl, IsFakeClient(target)?1:0, (fl & 0x200) ? 1 : 0);
        return Plugin_Handled;
    }
    GetCmdArg(2, szMask, sizeof(szMask));
    int mask = StringToInt(szMask, 16);
    SetEntProp(target, Prop_Send, "m_fFlags", fl | mask);
    int now = GetEntProp(target, Prop_Send, "m_fFlags");
    PrintToServer("[ANHPROBE] client=%d m_fFlags 0x%x -> OR 0x%x -> 0x%x", target, fl, mask, now);
    return Plugin_Handled;
}

// sm_anhfakeauto <client>：开关每帧重设 FL_FAKECLIENT
public Action Command_FakeAuto(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhfakeauto <client>");
        return Plugin_Handled;
    }
    char szClient[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    int target = StringToInt(szClient);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    g_bFakeAuto[target] = !g_bFakeAuto[target];
    PrintToServer("[ANHPROBE] fakeauto client=%d -> %s", target, g_bFakeAuto[target] ? "ON" : "OFF");
    return Plugin_Handled;
}

// sm_anhstate <client>：打印移动相关完整状态（movetype/vel/flags/frozen）
public Action Command_State(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhstate <client>");
        return Plugin_Handled;
    }
    char szClient[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    int t = StringToInt(szClient);
    if (!IsClientInGame(t))
    {
        PrintToServer("[ANHPROBE] client %d not in game", t);
        return Plugin_Handled;
    }
    int movetype = GetEntProp(t, Prop_Data, "m_MoveType");
    int flags = GetEntProp(t, Prop_Send, "m_fFlags");
    int life = GetEntProp(t, Prop_Data, "m_lifeState");
    float vel[3], origin[3];
    GetEntPropVector(t, Prop_Data, "m_vecVelocity", vel);
    GetClientAbsOrigin(t, origin);
    PrintToServer("[ANHPROBE] state c=%d movetype=%d life=%d flags=0x%x (frozen0x40=%d onground0x1=%d fake0x200=%d) vel=(%.1f,%.1f,%.1f) origin=(%.1f,%.1f,%.1f)",
        t, movetype, life, flags, (flags&0x40)?1:0, (flags&0x1)?1:0, (flags&0x200)?1:0,
        vel[0], vel[1], vel[2], origin[0], origin[1], origin[2]);
    return Plugin_Handled;
}

void DumpMyWeapons(int t)
{
    int active = GetEntPropEnt(t, Prop_Data, "m_hActiveWeapon");
    int wcount = 0;
    if (HasEntProp(t, Prop_Send, "m_hMyWeapons"))
    {
        int max = GetEntPropArraySize(t, Prop_Send, "m_hMyWeapons");
        for (int i = 0; i < max; i++)
        {
            int we = GetEntPropEnt(t, Prop_Send, "m_hMyWeapons", i);
            if (we < 0 || !IsValidEntity(we))
                continue;
            char cls[64];
            GetEntityClassname(we, cls, sizeof(cls));
            int clip = -1;
            if (HasEntProp(we, Prop_Data, "m_iClip1"))
                clip = GetEntProp(we, Prop_Data, "m_iClip1");
            PrintToServer("[ANHPROBE] mywep[%d] ent=%d %s clip1=%d %s",
                i, we, cls, clip, (we == active) ? "<ACTIVE>" : "");
            wcount++;
        }
    }
    PrintToServer("[ANHPROBE] client %d m_hMyWeapons=%d active=%d", t, wcount, active);
}

public Action Command_Give(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhgive <client> <weapon_class>");
        return Plugin_Handled;
    }
    char szC[16], szW[64];
    GetCmdArg(1, szC, sizeof(szC));
    GetCmdArg(2, szW, sizeof(szW));
    int t = StringToInt(szC);
    if (!IsClientInGame(t))
    {
        PrintToServer("[ANHPROBE] client %d not in game", t);
        return Plugin_Handled;
    }
    int we = GivePlayerItem(t, szW);
    PrintToServer("[ANHPROBE] GivePlayerItem(%d, %s) = %d", t, szW, we);
    if (we >= 0 && IsValidEntity(we) && g_hWeaponEquip != null)
    {
        SDKCall(g_hWeaponEquip, t, we);
        PrintToServer("[ANHPROBE] WeaponEquip[261](%d, %d) called", t, we);
    }
    else if (g_hWeaponEquip == null)
    {
        PrintToServer("[ANHPROBE] g_hWeaponEquip NULL, skipping equip");
    }
    DumpMyWeapons(t);
    return Plugin_Handled;
}

public Action Command_Equip(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhequip <client> <weapon_ent>");
        return Plugin_Handled;
    }
    char szC[16], szW[16];
    GetCmdArg(1, szC, sizeof(szC));
    GetCmdArg(2, szW, sizeof(szW));
    int t = StringToInt(szC);
    int we = StringToInt(szW);
    if (!IsClientInGame(t))
    {
        PrintToServer("[ANHPROBE] client %d not in game", t);
        return Plugin_Handled;
    }
    if (!IsValidEntity(we))
    {
        PrintToServer("[ANHPROBE] weapon ent %d invalid", we);
        return Plugin_Handled;
    }
    if (g_hWeaponEquip == null)
    {
        PrintToServer("[ANHPROBE] g_hWeaponEquip NULL");
        return Plugin_Handled;
    }
    SDKCall(g_hWeaponEquip, t, we);
    PrintToServer("[ANHPROBE] WeaponEquip[261](%d, %d) called", t, we);
    DumpMyWeapons(t);
    return Plugin_Handled;
}

public Action Command_Combat(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcombat <client> <0|weapon_ent> [subtype]");
        return Plugin_Handled;
    }
    char szC[16], szW[16], szS[12];
    GetCmdArg(1, szC, sizeof(szC));
    GetCmdArg(2, szW, sizeof(szW));
    int t = StringToInt(szC);
    int w = StringToInt(szW);
    if (!IsClientInGame(t))
    {
        PrintToServer("[ANHPROBE] client %d not in game", t);
        return Plugin_Handled;
    }
    if (w <= 0)
    {
        g_iCombatWeapon[t] = 0;
        PrintToServer("[ANHPROBE] combat fire OFF for client %d", t);
        return Plugin_Handled;
    }
    int sub = 0;
    if (args >= 3)
    {
        GetCmdArg(3, szS, sizeof(szS));
        sub = StringToInt(szS);
    }
    else if (HasEntProp(w, Prop_Data, "m_iSubType"))
    {
        sub = GetEntProp(w, Prop_Data, "m_iSubType");
    }
    g_iCombatWeapon[t] = w;
    g_iCombatSubtype[t] = sub;
    PrintToServer("[ANHPROBE] combat fire ON client=%d weapon=%d subtype=%d", t, w, sub);
    return Plugin_Handled;
}

public Action Command_Npcs(int client, int args)
{
    int n = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "npc_")) != -1)
    {
        char cls[64];
        GetEntityClassname(ent, cls, sizeof(cls));
        float o[3];
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", o);
        int hp = -1, team = -99, life = -1;
        if (HasEntProp(ent, Prop_Data, "m_iHealth"))
            hp = GetEntProp(ent, Prop_Data, "m_iHealth");
        if (HasEntProp(ent, Prop_Data, "m_iTeamNum"))
            team = GetEntProp(ent, Prop_Data, "m_iTeamNum");
        if (HasEntProp(ent, Prop_Data, "m_lifeState"))
            life = GetEntProp(ent, Prop_Data, "m_lifeState");
        PrintToServer("[ANHPROBE] npc ent=%d %s hp=%d team=%d life=%d origin=(%.0f,%.0f,%.0f)",
            ent, cls, hp, team, life, o[0], o[1], o[2]);
        n++;
        if (n >= 40) break;
    }
    PrintToServer("[ANHPROBE] npc_* count=%d", n);
    return Plugin_Handled;
}

public Action Command_Ents(int client, int args)
{
    char prefix[32];
    if (args < 1)
        prefix = "weapon_";
    else
        GetCmdArg(1, prefix, sizeof(prefix));

    int total = GetEntityCount();
    int n = 0;
    for (int e = 0; e < total; e++)
    {
        if (!IsValidEntity(e))
            continue;
        char cls[64];
        if (!GetEntityClassname(e, cls, sizeof(cls)))
            continue;
        if (StrContains(cls, prefix) != 0)
            continue;
        float o[3] = {0.0, 0.0, 0.0};
        if (HasEntProp(e, Prop_Data, "m_vecOrigin"))
            GetEntPropVector(e, Prop_Data, "m_vecOrigin", o);
        int hp = -1;
        if (HasEntProp(e, Prop_Data, "m_iHealth"))
            hp = GetEntProp(e, Prop_Data, "m_iHealth");
        PrintToServer("[ANHPROBE] ent=%d %s hp=%d origin=(%.0f,%.0f,%.0f)", e, cls, hp, o[0], o[1], o[2]);
        n++;
        if (n >= 60) break;
    }
    PrintToServer("[ANHPROBE] ents prefix '%s' count=%d (maxent=%d)", prefix, n, total);
    return Plugin_Handled;
}

public Action Command_Weapons(int client, int args)
{
    // 无参数：dump 全部 weapon_ 实体及 owner
    if (args < 1)
    {
        int w = -1, cnt = 0;
        while ((w = FindEntityByClassname(w, "weapon_")) != -1)
        {
            char cls[64];
            GetEntityClassname(w, cls, sizeof(cls));
            int owner = -1;
            if (HasEntProp(w, Prop_Data, "m_hOwner"))
                owner = GetEntPropEnt(w, Prop_Data, "m_hOwner");
            else if (HasEntProp(w, Prop_Send, "m_hOwner"))
                owner = GetEntPropEnt(w, Prop_Send, "m_hOwner");
            PrintToServer("[ANHPROBE] wep ent=%d %s owner=%d", w, cls, owner);
            cnt++;
            if (cnt >= 50) break;
        }
        PrintToServer("[ANHPROBE] total weapon_ ents=%d", cnt);
        return Plugin_Handled;
    }
    char szClient[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    int t = StringToInt(szClient);
    if (!IsClientInGame(t))
    {
        PrintToServer("[ANHPROBE] client %d not in game", t);
        return Plugin_Handled;
    }
    int active = GetEntPropEnt(t, Prop_Data, "m_hActiveWeapon");
    // 用 m_hMyWeapons 网络数组枚举玩家持有武器
    int wcount = 0;
    if (HasEntProp(t, Prop_Send, "m_hMyWeapons"))
    {
        int max = GetEntPropArraySize(t, Prop_Send, "m_hMyWeapons");
        for (int i = 0; i < max; i++)
        {
            int we = GetEntPropEnt(t, Prop_Send, "m_hMyWeapons", i);
            if (we < 0 || !IsValidEntity(we))
                continue;
            char cls[64];
            GetEntityClassname(we, cls, sizeof(cls));
            int clip = -1;
            if (HasEntProp(we, Prop_Data, "m_iClip1"))
                clip = GetEntProp(we, Prop_Data, "m_iClip1");
            PrintToServer("[ANHPROBE] mywep[%d] ent=%d %s clip1=%d %s",
                i, we, cls, clip, (we == active) ? "<ACTIVE>" : "");
            wcount++;
        }
    }
    PrintToServer("[ANHPROBE] client %d m_hMyWeapons=%d active=%d", t, wcount, active);
    return Plugin_Handled;
}

public Action Command_SimWatch(int client, int args)
{
    char szOn[8];
    if (args < 1)
    {
        g_bSimWatch = !g_bSimWatch;
    }
    else
    {
        GetCmdArg(1, szOn, sizeof(szOn));
        g_bSimWatch = (StringToInt(szOn) != 0);
    }
    g_iFrameCount = 0;
    PrintToServer("[ANHPROBE] sim watch %s", g_bSimWatch ? "ON" : "OFF");
    return Plugin_Handled;
}

public Action Command_VTable(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhvtable <client> [lo] [hi]");
        return Plugin_Handled;
    }
    char szClient[16], szLo[12], szHi[12];
    GetCmdArg(1, szClient, sizeof(szClient));
    int target = StringToInt(szClient);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    int lo = 400, hi = 470;
    if (args >= 3)
    {
        GetCmdArg(2, szLo, sizeof(szLo));
        GetCmdArg(3, szHi, sizeof(szHi));
        lo = StringToInt(szLo);
        hi = StringToInt(szHi);
    }
    Address ent = GetEntityAddress(target);
    if (ent == Address_Null)
    {
        PrintToServer("[ANHPROBE] GetEntityAddress(%d) null", target);
        return Plugin_Handled;
    }
    Address vt = LoadFromAddress(ent, NumberType_Int32);
    PrintToServer("[ANHPROBE] client=%d entity=%08X vtable=%08X dumping slots %d..%d",
        target, ent, vt, lo, hi);
    for (int i = lo; i <= hi; i++)
    {
        Address fn = LoadFromAddress(vt + i * 4, NumberType_Int32);
        PrintToServer("[ANHPROBE] VT[%d] = %08X", i, fn);
    }
    return Plugin_Handled;
}

// 直接 SDKCall 游戏原生 ChangeTeam vtable[463]：sm_anhcallteam <client> <team>
public Action Command_CallTeam(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcallteam <client> <team>");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    if (g_hChangeTeam == INVALID_HANDLE)
    {
        PrintToServer("[ANHPROBE] ChangeTeam SDKCall invalid");
        return Plugin_Handled;
    }
    int oldTeam = GetClientTeam(target);
    PrintToServer("[ANHPROBE] >>> SDKCall ChangeTeam[463](%d, %d) teamBefore=%d aliveBefore=%d",
        target, team, oldTeam, IsPlayerAlive(target));
    int ret = SDKCall(g_hChangeTeam, target, team);
    PrintToServer("[ANHPROBE] <<< ChangeTeam ret=%d teamAfter=%d aliveAfter=%d",
        ret, GetClientTeam(target), IsPlayerAlive(target));
    return Plugin_Handled;
}

// 直接 SDKCall 底层 SetTeam vtable[91]：sm_anhcallset <client> <team>
public Action Command_CallSet(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcallset <client> <team>");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    if (g_hSetTeam == INVALID_HANDLE)
    {
        PrintToServer("[ANHPROBE] SetTeam SDKCall invalid");
        return Plugin_Handled;
    }
    int oldTeam = GetClientTeam(target);
    PrintToServer("[ANHPROBE] >>> SDKCall SetTeam[91](%d, %d) teamBefore=%d aliveBefore=%d",
        target, team, oldTeam, IsPlayerAlive(target));
    int ret = SDKCall(g_hSetTeam, target, team);
    PrintToServer("[ANHPROBE] <<< SetTeam ret=%d teamAfter=%d aliveAfter=%d",
        ret, GetClientTeam(target), IsPlayerAlive(target));
    return Plugin_Handled;
}

// 直接从实体读 vtable[slot] 地址，用 SDKCall_Raw + SetAddress 调用，
// 完全绕过 SM 的 vtable 索引解析，验证调用目标。
public Action Command_CallRaw(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcallraw <client> <team> [slot]");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8], szSlot[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    GetCmdArg(3, szSlot, sizeof(szSlot));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    int slot = (args >= 3) ? StringToInt(szSlot) : 463;
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }

    Address ent = GetEntityAddress(target);
    Address vt = LoadFromAddress(ent, NumberType_Int32);
    Address fn = LoadFromAddress(vt + slot * 4, NumberType_Int32);
    if (ent == Address_Null || vt == Address_Null || fn == Address_Null)
    {
        PrintToServer("[ANHPROBE] null ptr: ent=0x%08x vt=0x%08x fn=0x%08x", view_as<int>(ent), view_as<int>(vt), view_as<int>(fn));
        return Plugin_Handled;
    }

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetAddress(fn);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle hRaw = EndPrepSDKCall();
    if (hRaw == null)
    {
        PrintToServer("[ANHPROBE] EndPrepSDKCall failed for 0x%08x slot=%d", view_as<int>(fn), slot);
        return Plugin_Handled;
    }

    int oldTeam = GetClientTeam(target);
    PrintToServer("[ANHPROBE] >>> RawCall slot=%d ent=0x%08x vt=0x%08x fn=0x%08x team=%d teamBefore=%d aliveBefore=%d",
        slot, view_as<int>(ent), view_as<int>(vt), view_as<int>(fn), team, oldTeam, IsPlayerAlive(target));
    int ret = SDKCall(hRaw, ent, team);
    PrintToServer("[ANHPROBE] <<< RawCall ret=0x%08x(%d) teamAfter=%d aliveAfter=%d",
        ret, ret, GetClientTeam(target), IsPlayerAlive(target));
    delete hRaw;
    return Plugin_Handled;
}

// 调用任意地址（对照实验）：验证 SDKCall 是否真的执行 call。
public Action Command_CallAddr(int client, int args)
{
    if (args < 3)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcalladdr <client> <hexaddr> <arg>");
        return Plugin_Handled;
    }
    char szClient[16], szAddr[16], szArg[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szAddr, sizeof(szAddr));
    GetCmdArg(3, szArg, sizeof(szArg));
    int target = StringToInt(szClient);
    Address fn = view_as<Address>(StringToInt(szAddr));
    int arg = StringToInt(szArg);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    Address ent = GetEntityAddress(target);

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetAddress(fn);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle h = EndPrepSDKCall();
    if (h == null)
    {
        PrintToServer("[ANHPROBE] EndPrep failed for 0x%08x", view_as<int>(fn));
        return Plugin_Handled;
    }
    PrintToServer("[ANHPROBE] >>> CallAddr ent=0x%08x fn=0x%08x arg=%d", view_as<int>(ent), view_as<int>(fn), arg);
    int ret = SDKCall(h, ent, arg);
    PrintToServer("[ANHPROBE] <<< CallAddr ret=0x%08x(%d)", ret, ret);
    delete h;
    return Plugin_Handled;
}

// ===== 方案 A：构造 CCommand 直接调用 vtable[368] ClientCommand（正常入队路径）=====
// sdk2013 CCommand 布局（分发器实测）：
//   0x000 int   m_nArgc
//   0x004 int   m_nArgv0Size
//   0x008 char  m_pArgSBuffer[0x200]  (原地 token，argv 指针指向这里)
//   0x208 char  m_pArgvBuffer[0x200]
//   0x408 char* m_pArgv[0]            (命令名)
//   0x40C char* m_pArgv[1] ...
static void StoreStringToAddr(Address addr, const char[] s)
{
    int n = strlen(s);
    for (int i = 0; i < n; i++)
        StoreToAddress(addr + i, view_as<int>(s[i]), NumberType_Int8, false);
    StoreToAddress(addr + n, 0, NumberType_Int8);
}

public Action Command_Cmd368(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhcmd368 <client> <cmdline...>");
        return Plugin_Handled;
    }
    int target = GetCmdArgInt(1);
    int nargc = args - 1;
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    if (g_ccmdMem == Address_Null)
    {
        PrintToServer("[ANHPROBE] CCommand memory not allocated");
        return Plugin_Handled;
    }
    if (nargc > 60 || nargc < 1)
    {
        PrintToServer("[ANHPROBE] bad argc=%d", nargc);
        return Plugin_Handled;
    }

    // 清零 CCommand 头部与 argv 指针数组（0x000..0x510）
    for (int z = 0; z < 0x510; z += 4)
        StoreToAddress(g_ccmdMem + z, 0, NumberType_Int32, false);

    // tokens 写入 m_pArgSBuffer(0x008)，argv 指针指向同一区域
    int off = 0x008;
    int baseAddr = view_as<int>(g_ccmdMem);
    char tok[160];
    for (int i = 0; i < nargc; i++)
    {
        GetCmdArg(i + 2, tok, sizeof(tok));
        int len = strlen(tok);
        if (off + len + 1 >= 0x208)
        {
            PrintToServer("[ANHPROBE] cmdline too long");
            return Plugin_Handled;
        }
        StoreStringToAddr(g_ccmdMem + off, tok);
        StoreToAddress(g_ccmdMem + 0x408 + i * 4, baseAddr + off, NumberType_Int32, false);
        off += len + 1;
    }
    GetCmdArg(2, tok, sizeof(tok));
    StoreToAddress(g_ccmdMem + 0x000, nargc, NumberType_Int32, false);
    StoreToAddress(g_ccmdMem + 0x004, strlen(tok) + 1, NumberType_Int32, false);

    Address ent = GetEntityAddress(target);
    Address vt = LoadFromAddress(ent, NumberType_Int32);
    Address fn = LoadFromAddress(vt + 368 * 4, NumberType_Int32);

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetAddress(fn);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // const CCommand*
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle h = EndPrepSDKCall();
    if (h == null)
    {
        PrintToServer("[ANHPROBE] EndPrep failed for 0x%08x", view_as<int>(fn));
        return Plugin_Handled;
    }

    int oldTeam = GetClientTeam(target);
    PrintToServer("[ANHPROBE] >>> ClientCommand[368] %N ent=0x%08x fn=0x%08x ccmd=0x%08x argc=%d teamBefore=%d aliveBefore=%d",
        target, view_as<int>(ent), view_as<int>(fn), view_as<int>(g_ccmdMem), nargc, oldTeam, IsPlayerAlive(target));
    int ret = SDKCall(h, ent, g_ccmdMem);
    PrintToServer("[ANHPROBE] <<< ClientCommand ret=0x%08x(%d) teamAfter=%d aliveAfter=%d",
        ret, ret, GetClientTeam(target), IsPlayerAlive(target));
    delete h;
    return Plugin_Handled;
}

// 强制改队测试：sm_anhteam <client> <team>
public Action Command_SetTeam(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhteam <client> <team>");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    int oldTeam = GetClientTeam(target);
    ChangeClientTeam(target, team);
    PrintToServer("[ANHPROBE] ChangeClientTeam(%d, %d) done (old team was %d, now %d)",
        target, team, oldTeam, GetClientTeam(target));
    return Plugin_Handled;
}

// 引擎命令入队测试：sm_anhjoin <client> <team>
public Action Command_Join(int client, int args)
{
    if (args < 2)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhjoin <client> <team>");
        return Plugin_Handled;
    }
    char szClient[16], szTeam[8];
    GetCmdArg(1, szClient, sizeof(szClient));
    GetCmdArg(2, szTeam, sizeof(szTeam));
    int target = StringToInt(szClient);
    int team = StringToInt(szTeam);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    int oldTeam = GetClientTeam(target);
    ClientCommand(target, "joingame");
    ClientCommand(target, "jointeam %d", team);
    PrintToServer("[ANHPROBE] JoinCmd(%d): joingame + jointeam %d (old team was %d, now %d)",
        target, team, oldTeam, GetClientTeam(target));
    return Plugin_Handled;
}

// 全方式入队测试：sm_anhtry <client>
public Action Command_TryAll(int client, int args)
{
    if (args < 1)
    {
        PrintToServer("[ANHPROBE] usage: sm_anhtry <client>");
        return Plugin_Handled;
    }
    char szClient[16];
    GetCmdArg(1, szClient, sizeof(szClient));
    int target = StringToInt(szClient);
    if (!IsClientInGame(target))
    {
        PrintToServer("[ANHPROBE] client %d not in game", target);
        return Plugin_Handled;
    }
    PrintToServer("[ANHPROBE] --- TryAll on client %d (team now %d) ---", target, GetClientTeam(target));

    ClientCommand(target, "chooseteam 3");
    PrintToServer("[ANHPROBE] after chooseteam 3: team=%d", GetClientTeam(target));

    ChangeClientTeam(target, 3);
    PrintToServer("[ANHPROBE] after ChangeClientTeam 3: team=%d", GetClientTeam(target));

    ForcePlayerSuicide(target);
    PrintToServer("[ANHPROBE] after suicide: team=%d alive=%d", GetClientTeam(target), IsPlayerAlive(target));

    return Plugin_Handled;
}

char g_szMap[64];

void ProbeAll()
{
    GetCurrentMap(g_szMap, sizeof(g_szMap));
    PrintToServer("========== ANHS PROBE ==========");
    PrintToServer("[ANHPROBE] map=%s MaxClients=%d", g_szMap, MaxClients);

    int nHumans = 0, nBots = 0, nZombies = 0, nCombine = 0, nRebels = 0, nSpec = 0, nOther = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        char name[64];
        GetClientName(i, name, sizeof(name));
        int team = GetClientTeam(i);
        bool fake = IsFakeClient(i);
        if (fake) nBots++; else nHumans++;
        switch (team)
        {
            case 1: nSpec++;
            case 2: nCombine++;
            case 3: nRebels++;
            case 4: nZombies++;
            default: nOther++;
        }
        PrintToServer("[ANHPROBE] client=%d name=%s team=%d fake=%d alive=%d runcmds=%d",
            i, name, team, fake, IsPlayerAlive(i), g_iRunCmdCount[i]);
    }
    PrintToServer("[ANHPROBE] humans=%d bots=%d | spec=%d combine=%d rebel=%d zombie=%d other=%d",
        nHumans, nBots, nSpec, nCombine, nRebels, nZombies, nOther);

    ConVar ctp = FindConVar("mp_teamplay");
    ConVar cdt = FindConVar("mp_defaultteam");
    ConVar cbz = FindConVar("bot_zombie");
    ConVar cmr = FindConVar("mp_maxrounds");
    ConVar ctl = FindConVar("mp_timelimit");
    PrintToServer("[ANHPROBE] cvars: mp_teamplay=%d mp_defaultteam=%d bot_zombie=%d mp_maxrounds=%d mp_timelimit=%d",
        ctp ? ctp.IntValue : -999,
        cdt ? cdt.IntValue : -999,
        cbz ? cbz.IntValue : -999,
        cmr ? cmr.IntValue : -999,
        ctl ? ctl.IntValue : -999);

    PrintToServer("[ANHPROBE] testing OnPlayerRunCmd availability...");
    PrintToServer("========== END PROBE ==========");
}

// ---- 事件日志（验证事件字段）----
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    char weapon[32];
    event.GetString("weapon", weapon, sizeof(weapon));
    float pos[3];
    if (victim > 0 && IsClientInGame(victim)) GetClientAbsOrigin(victim, pos);
    int dmgbit = event.GetInt("damagebit", -1);
    PrintToServer("[ANHPROBE] player_death: victim=%d attacker=%d weapon=%s damagebit=%d pos=(%.0f,%.0f,%.0f)",
        victim, attacker, weapon, dmgbit, pos[0], pos[1], pos[2]);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int dmg = event.GetInt("dmg_health");
    int health = event.GetInt("health");
    int aEnt = -1; char aCls[48] = "";
    if (attacker > 0 && IsClientInGame(attacker))
    {
        // attacker 是玩家
    }
    // 伤害来源（非玩家实体）用 m_hOwnerEntity 拿不到事件里，这里只记玩家 attacker
    float pos[3];
    if (victim > 0 && IsClientInGame(victim)) GetClientAbsOrigin(victim, pos);
    // 只打印非零伤害，或每 40 次零伤害打印一次，避免刷屏
    static int s_zeroTick[MAXPLAYERS+1];
    if (dmg == 0 && victim > 0)
    {
        s_zeroTick[victim]++;
        if (s_zeroTick[victim] % 40 != 1) return;
    }
    PrintToServer("[ANHPROBE] player_hurt: victim=%d attacker=%d dmg=%d health=%d pos=(%.0f,%.0f,%.0f)",
        victim, attacker, dmg, health, pos[0], pos[1], pos[2]);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    PrintToServer("[ANHPROBE] player_spawn: client=%d team=%d", client, GetClientTeam(client));
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    PrintToServer("[ANHPROBE] player_team: client=%d team=%d", client, GetClientTeam(client));
}
