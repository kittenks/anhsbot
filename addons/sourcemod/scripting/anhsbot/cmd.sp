/**
 * anhsbot/cmd.sp — 管理员命令
 */

public Action Cmd_Add(int client, int args)
{
    char name[64];
    if (args >= 1)
        GetCmdArgString(name, sizeof(name));
    else
        name[0] = '\0';

    int bot = Bot_Add(name, -1);
    if (bot <= 0)
        ReplyToCommand(client, "[anhsbot] failed to add bot");
    else
        ReplyToCommand(client, "[anhsbot] added bot as client %d", bot);
    return Plugin_Handled;
}

public Action Cmd_Kick(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[anhsbot] usage: anhsbot_kick <name|#clientindex>");
        return Plugin_Handled;
    }
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    // 支持 #<clientindex> 精确踢
    if (arg[0] == '#')
    {
        int idx = StringToInt(arg[1]);
        if (idx > 0 && IsClientInGame(idx) && IsFakeClient(idx) && g_Bot[idx].bManaged)
        {
            char nm[MAX_NAME_LENGTH];
            GetClientName(idx, nm, sizeof(nm));
            Bot_KickByIndex(idx);
            ReplyToCommand(client, "[anhsbot] kicked %s", nm);
            return Plugin_Handled;
        }
        ReplyToCommand(client, "[anhsbot] no managed bot at index %d", idx);
        return Plugin_Handled;
    }

    // 按名字子串匹配
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && g_Bot[i].bManaged)
        {
            char nm[MAX_NAME_LENGTH];
            GetClientName(i, nm, sizeof(nm));
            if (StrContains(nm, arg, false) != -1)
            {
                Bot_KickByIndex(i);
                ReplyToCommand(client, "[anhsbot] kicked %s", nm);
                return Plugin_Handled;
            }
        }
    }
    ReplyToCommand(client, "[anhsbot] no matching bot");
    return Plugin_Handled;
}

public Action Cmd_KickAll(int client, int args)
{
    Bot_KickAll();
    ReplyToCommand(client, "[anhsbot] all bots kicked");
    return Plugin_Handled;
}

public Action Cmd_List(int client, int args)
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && g_Bot[i].bManaged)
        {
            char nm[MAX_NAME_LENGTH];
            GetClientName(i, nm, sizeof(nm));
            ReplyToCommand(client, "  #%d %-20s team=%d alive=%d act=%d skl=%d tgt=%d shots=%d dmg=%d K/D=%d/%d",
                i, nm, GetClientTeam(i), Bot_IsAlive(i) ? 1 : 0,
                g_Bot[i].bActivated ? 1 : 0, g_Bot[i].iSkill, g_Bot[i].iTarget,
                g_Bot[i].iShotsFired, g_Bot[i].iDamageDealt,
                g_Bot[i].iKills, g_Bot[i].iDeaths);
            n++;
        }
    }
    ReplyToCommand(client, "[anhsbot] managed bots online: %d", n);
    return Plugin_Handled;
}

public Action Cmd_Count(int client, int args)
{
    int online = 0, alive = 0, activated = 0, fakes = 0;
    int kills = 0, deaths = 0, dmg = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        if (IsFakeClient(i))
            fakes++;
        if (!g_Bot[i].bManaged)
            continue;
        online++;
        if (Bot_IsAlive(i))
            alive++;
        if (g_Bot[i].bActivated)
            activated++;
        kills += g_Bot[i].iKills;
        deaths += g_Bot[i].iDeaths;
        dmg += g_Bot[i].iDamageDealt;
    }
    ReplyToCommand(client, "[anhsbot] managed online=%d alive=%d activated=%d (all fake clients=%d) | kills=%d deaths=%d damage=%d | nav=%s areas=%d",
        online, alive, activated, fakes, kills, deaths, dmg,
        g_bNavLoaded ? "on" : "off", g_iNavAreas);
    return Plugin_Handled;
}

// 诊断：把指定 bot 传送到坐标（TeleportEntity 对 fake client 有效）。
// 【实测 2026-10-18 探针】TeleportEntity 对 ANHS 的 fake client 实际不生效
// （接受调用无报错但位置不变；对照实验：正常 bot 同样瞬移不动）。卡住恢复
// 不依赖瞬移，改用"诅咒 area + 兜底游走 + 重建 bot"（见 Bot_CheckStuck）。
// 本命令保留作诊断占位。
public Action Cmd_Tele(int client, int args)
{
    if (args < 4)
    {
        ReplyToCommand(client, "[anhsbot] usage: anhsbot_tele <client> <x> <y> <z>");
        return Plugin_Handled;
    }
    int b = GetCmdArgInt(1);
    float pos[3];
    pos[0] = GetCmdArgFloat(2);
    pos[1] = GetCmdArgFloat(3);
    pos[2] = GetCmdArgFloat(4);
    if (b > 0 && IsClientInGame(b) && IsFakeClient(b))
    {
        TeleportEntity(b, pos, NULL_VECTOR, NULL_VECTOR);
        ReplyToCommand(client, "[anhsbot] teleported #%d to (%.0f,%.0f,%.0f)", b, pos[0], pos[1], pos[2]);
    }
    return Plugin_Handled;
}

// 诊断：在指定 bot 前方生成一个 NPC（CreateEntityByName，比 ent_create 可靠）。
public Action Cmd_SpawnNpc(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[anhsbot] usage: anhsbot_npc <classname> <nearClient> [distance]");
        return Plugin_Handled;
    }
    char cls[64];
    GetCmdArg(1, cls, sizeof(cls));
    int near = GetCmdArgInt(2);
    float dist = (args >= 3) ? GetCmdArgFloat(3) : 180.0;
    if (near <= 0 || !IsClientInGame(near))
        return Plugin_Handled;

    float eye[3], ang[3], fwd[3];
    GetClientEyePosition(near, eye);
    GetClientEyeAngles(near, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    float pos[3];
    pos = eye;
    pos[0] += fwd[0] * dist;
    pos[1] += fwd[1] * dist;
    pos[2] -= 40.0;

    int n = CreateEntityByName(cls);
    if (n <= 0)
    {
        ReplyToCommand(client, "[anhsbot] CreateEntityByName(%s) failed", cls);
        return Plugin_Handled;
    }
    // 顺序很重要：先 DispatchSpawn 让 NPC 完成内部初始化，再 Activate + 传送。
    // 旧版在 DispatchSpawn 前写 m_vecOrigin，生成的僵尸位置字段是坏的
    // （m_vecOrigin.x=NaN / m_vecAbsOrigin=0,0,0），bot 会瞄到幻影。
    DispatchSpawn(n);
    ActivateEntity(n);
    TeleportEntity(n, pos, NULL_VECTOR, NULL_VECTOR);
    // 双保险：abs origin 也写一次（NPC 的权威世界坐标在 datamap 偏移 640）。
    if (HasEntProp(n, Prop_Data, "m_vecAbsOrigin"))
        SetEntPropVector(n, Prop_Data, "m_vecAbsOrigin", pos);
    ReplyToCommand(client, "[anhsbot] spawned %s as ent %d at (%.0f,%.0f,%.0f)",
        cls, n, pos[0], pos[1], pos[2]);
    return Plugin_Handled;
}

// 诊断：打印 bot 的缓存 NPC / 索敌 LOS / 武器状态（定位"不开火/不打中"用）。
public Action Cmd_Diag(int client, int args)
{
    int only = (args >= 1) ? GetCmdArgInt(1) : 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i) || !g_Bot[i].bManaged)
            continue;
        if (only > 0 && i != only)
            continue;

        int team = GetClientTeam(i);
        float eye[3];
        GetClientEyePosition(i, eye);
        int w = Wep_GetActive(i);
        char wcls[32] = "none";
        int clip = -1;
        if (w != -1)
        {
            GetEntityClassname(w, wcls, sizeof(wcls));
            clip = Wep_GetClip(w);
        }
        ReplyToCommand(client,
            "[diag] bot #%d team=%d alive=%d active=%s clip=%d skl=%d tgt=%d cacheCount=%d shots=%d dmg=%d K/D=%d/%d",
            i, team, Bot_IsAlive(i) ? 1 : 0, wcls, clip, g_Bot[i].iSkill, g_Bot[i].iTarget, g_iCacheCount,
            g_Bot[i].iShotsFired, g_Bot[i].iDamageDealt, g_Bot[i].iKills, g_Bot[i].iDeaths);

        // 武器清单：遍历 m_hMyWeapons，确认 loadout 是否真的进库存。
        if (HasEntProp(i, Prop_Send, "m_hMyWeapons"))
        {
            int maxw = GetEntPropArraySize(i, Prop_Send, "m_hMyWeapons");
            char wline[256] = "[diag]   weapons:";
            for (int s = 0; s < maxw; s++)
            {
                int ew = GetEntPropEnt(i, Prop_Send, "m_hMyWeapons", s);
                if (ew > 0 && IsValidEntity(ew))
                {
                    char ec[32];
                    GetEntityClassname(ew, ec, sizeof(ec));
                    Format(wline, sizeof(wline), "%s %s", wline, ec);
                }
            }
            ReplyToCommand(client, "%s", wline);
        }

        int shown = 0;
        for (int c = 0; c < g_iCacheCount && shown < 12; c++)
        {
            int ent = EntRefToEntIndex(g_iCacheEnt[c]);
            if (ent == -1 || !IsValidEntity(ent))
                continue;
            char cls[64];
            GetEntityClassname(ent, cls, sizeof(cls));
            float d = GetVectorDistance(eye, g_fCachePos[c]);
            bool los = Targ_HasLOS(i, ent, g_fCachePos[c]);
            bool hostile = Targ_CacheEntryHostile(c, team);
            ReplyToCommand(client,
                "   cache[%d] %s ent=%d dist=%.0f hostile=%d los=%d",
                c, cls, ent, d, hostile ? 1 : 0, los ? 1 : 0);
            shown++;
        }
    }
    return Plugin_Handled;
}

// 诊断：打印某个 bot（或全部受管 bot）的位置/朝向/目标/瞄准差/武器。
// only=0 时遍历所有 fake client（含非本插件创建的，便于联调 probe）。
public Action Cmd_AimInfo(int client, int args)
{
    int only = (args >= 1) ? GetCmdArgInt(1) : 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i))
            continue;
        if (only > 0 && i != only)
            continue;
        if (only == 0 && !g_Bot[i].bManaged)
            continue;

        float eye[3], ang[3];
        GetClientEyePosition(i, eye);
        GetClientEyeAngles(i, ang);

        char line[512];
        Format(line, sizeof(line),
            "[anhsbot] bot #%d team=%d eye=(%.0f,%.0f,%.0f) ang=(%.1f,%.1f,%.1f) tgt=%d",
            i, GetClientTeam(i), eye[0], eye[1], eye[2], ang[0], ang[1], ang[2],
            g_Bot[i].iTarget);

        int t = g_Bot[i].iTarget;
        if (t > 0 && IsValidEntity(t))
        {
            float tp[3], dir[3], want[3];
            Targ_AimPoint(t, tp);
            MakeVectorFromPoints(eye, tp, dir);
            NormalizeVector(dir, dir);
            GetVectorAngles(dir, want);
            float dY = Bot_AngleDiff(want[1], ang[1]);
            float dP = Bot_AngleDiff(want[0], ang[0]);
            Format(line, sizeof(line),
                "%s | tgtpos=(%.0f,%.0f,%.0f) dist=%.0f wantAng=(%.1f,%.1f) err=(%.1f,%.1f)",
                line, tp[0], tp[1], tp[2], GetVectorDistance(eye, tp), want[0], want[1], dP, dY);
        }

        int w = Wep_GetActive(i);
        char wcls[32] = "none";
        int clip = -1;
        if (w != -1)
        {
            GetEntityClassname(w, wcls, sizeof(wcls));
            clip = Wep_GetClip(w);
        }
        Format(line, sizeof(line), "%s | active=%s clip=%d wantWep=%d mv=(%.0f,%.0f) nav=%d path=%d los=%d wf=%d sc=%d",
            line, wcls, clip, g_Bot[i].iWantWeapon,
            g_Bot[i].fLastVelFwd, g_Bot[i].fLastVelRight,
            g_Bot[i].bNavMove ? 1 : 0, g_iPathLen[i],
            g_Bot[i].bHasLOS ? 1 : 0,
            g_Bot[i].iWanderFails, g_Bot[i].bScoutWalk ? 1 : 0);
        ReplyToCommand(client, "%s", line);
    }
    return Plugin_Handled;
}
