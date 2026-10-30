/**
 * anhsbot/bot.sp — bot 生命周期：创建、激活、看门狗、事件
 */

public void Bot_ResetMapState()
{
    // 换图：清掉所有在线标记（实体会重连，OnClientPutInServer 重新登记）。
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            g_Bot[i].bManaged = false;
        g_Bot[i].bActivated = false;
        g_Bot[i].iRunCmds = 0;
        g_Bot[i].bMoved = false;
        g_Bot[i].bNavMove = false;
        g_Bot[i].bWanderActive = false;
        g_Bot[i].iWanderFails = 0;
        g_Bot[i].bScoutWalk = false;
        g_Bot[i].iRegroupFails = 0;
        g_Bot[i].fRegroupPauseUntil = 0.0;
        g_Bot[i].bHasLOS = false;
        g_Bot[i].iDesiredTeam = 0;
    }
}

public void Bot_InitialFill()
{
    if (g_cvEnabled != null && g_cvEnabled.BoolValue && g_cvAutoFill.BoolValue)
        Bot_FillToTarget();
}

public void Bot_OnPutInServer(int client)
{
    Dbg("PutInServer client=%d managed=%d", client, g_Bot[client].bManaged?1:0);
    // 仅当本插件在创建时盖过戳（CreateFakeClient 后立刻写入）。
    // OnClientPutInServer 可能延迟到下一帧；戳仍在数组里。
    if (!g_Bot[client].bManaged)
        return;

    g_Bot[client].fBornAt = GetGameTime();
    g_Bot[client].bActivated = false;
    g_Bot[client].iRunCmds = 0;
    g_Bot[client].bMoved = false;

    // 实体刚进 server，部分标志/出生还未完成，延迟两帧再激活。
    RequestFrame(Bot_ActivationFrame, GetClientUserId(client));
    // 再挂一个定时器兜底（RequestFrame 若在实体未就绪时过早执行）。
    CreateTimer(0.15, Timer_DelayedActivate, GetClientUserId(client));
}

public void Bot_ActivationFrame(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client))
        return;
    Bot_Activate(client);
}

// 盖上 FL_FAKECLIENT，让引擎 fake-client 命令循环开始处理本 bot。
public void Bot_Activate(int client)
{
    if (!IsClientInGame(client) || !IsFakeClient(client))
    {
        Dbg("Activate skip client=%d inGame=%d fake=%d", client,
            IsClientInGame(client)?1:0, (IsClientInGame(client)&&IsFakeClient(client))?1:0);
        return;
    }
    int before = GetPlayerFlags(client);
    bool wrote = EnsureFakeClientFlag(client);
    int after = GetPlayerFlags(client);
    g_Bot[client].bActivated = ((after & ANH_FL_FAKECLIENT) != 0);
    Dbg("Activate client=%d flags 0x%x -> 0x%x wrote=%d activated=%d",
        client, before, after, wrote?1:0, g_Bot[client].bActivated?1:0);
}

// 初始化一个受管 bot 的运行时状态（CreateFakeClient 之后的公共逻辑）。
public void Bot_InitState(int bot, int desiredTeam)
{
    g_Bot[bot].bManaged = true;
    g_Bot[bot].bActivated = false;
    g_Bot[bot].bRebuilding = false;
    g_Bot[bot].iDesiredTeam = desiredTeam;
    g_Bot[bot].iNameUid = g_iNameUid;
    g_Bot[bot].fBornAt = GetGameTime();
    g_Bot[bot].fNextRespawnCheck = 0.0;
    g_Bot[bot].iRunCmds = 0;
    g_Bot[bot].bMoved = false;
    g_Bot[bot].bArmed = false;
    g_Bot[bot].iTarget = 0;
    g_Bot[bot].fRetargetAt = 0.0;
    g_Bot[bot].iWantWeapon = 0;
    g_Bot[bot].iWantSubtype = 0;
    g_Bot[bot].fNextAmmoCheck = 0.0;
    g_Bot[bot].iShotsFired = 0;
    g_Bot[bot].iStrafeSign = (GetRandomInt(0,1) == 0) ? -1 : 1;
    g_Bot[bot].fNextStrafeFlip = 0.0;
    g_Bot[bot].iKills = 0;
    g_Bot[bot].iDeaths = 0;
    g_Bot[bot].iDamageDealt = 0;
    g_Bot[bot].fLastTargetHp = -1.0;
    g_Bot[bot].fLastDamageAt = 0.0;
    g_Bot[bot].fDiedAt = 0.0;
    g_Bot[bot].bNavMove = false;
    g_Bot[bot].fNavDirX = 0.0;
    g_Bot[bot].fNavDirY = 0.0;
    g_Bot[bot].fNavSpeed = 0.0;
    g_Bot[bot].fNextWanderAt = 0.0;
    g_Bot[bot].fWanderX = 0.0;
    g_Bot[bot].fWanderY = 0.0;
    g_Bot[bot].fWanderZ = 0.0;
    g_Bot[bot].bWanderActive = false;
    g_Bot[bot].iWanderFails = 0;
    g_Bot[bot].bScoutWalk = false;
    g_Bot[bot].fScoutUntil = 0.0;
    g_Bot[bot].fScoutYaw = 0.0;
    g_Bot[bot].fNextJumpAt = 0.0;
    g_Bot[bot].iRegroupFails = 0;
    g_Bot[bot].fRegroupPauseUntil = 0.0;
    g_Bot[bot].fLastIdleLogAt = 0.0;
    g_Bot[bot].fNextZombieTry = 0.0;
    g_Bot[bot].fLastFriendlyHold = 0.0;
    g_Bot[bot].fNextLosCheck = 0.0;
    g_Bot[bot].bHasLOS = false;
    g_Bot[bot].fStuckCheckAt = 0.0;
    g_Bot[bot].fStuckRefX = 0.0;
    g_Bot[bot].fStuckRefY = 0.0;
    g_Bot[bot].iStuckCount = 0;
    g_Bot[bot].fNavPauseUntil = 0.0;
    g_Bot[bot].fStuckRebuildAt = 0.0;
    g_Bot[bot].fNextStuckRebuildAt = 0.0;
}

// 以指定名字创建 bot（跳过重名检查，供死亡重建使用；调用方需确保旧实体已退出）。
public int Bot_AddExact(const char[] name, int desiredTeam)
{
    if (CountManagedBots() >= MaxClients - 1)
    {
        Log("cannot add bot: server is full");
        return 0;
    }
    int bot = CreateFakeClient(name);
    if (bot <= 0)
    {
        LogError("[anhsbot] CreateFakeClient(%s) failed (no free slot / no map / mod blocks fakes)", name);
        return 0;
    }
    Bot_InitState(bot, desiredTeam);
    SetClientInfo(bot, "name", name);
    // 若回调已在 CreateFakeClient 内同步触发过，这里补一次激活。
    if (IsClientInGame(bot))
        CreateTimer(0.1, Timer_DelayedActivate, GetClientUserId(bot));
    Log("added bot '%s' as client %d", name, bot);
    return bot;
}

// 对外：创建一个 bot。返回 client 索引（>0 成功），0 失败。
public int Bot_Add(const char[] explicitName, int desiredTeam)
{
    if (CountManagedBots() >= MaxClients - 1)
    {
        Log("cannot add bot: server is full");
        return 0;
    }

    char name[64];
    int skill;

    if (explicitName[0] != '\0')
    {
        strcopy(name, sizeof(name), explicitName);
        // 显式名字：在池里查对应技能，没有则用默认。
        skill = (g_cvSkill != null) ? g_cvSkill.IntValue : 1;
        for (int i = 0; i < g_iNamePoolCount; i++)
        {
            if (StrEqual(g_szNamePool[i], name, false))
            {
                skill = g_iNamePoolSkill[i];
                break;
            }
        }
    }
    else
    {
        // 从名字池轮询，跳过当前在线的名字。
        int tries = 0;
        do
        {
            BotsCfg_Pick(name, skill);
            tries++;
        }
        while (Bot_NameInUse(name) && tries < g_iNamePoolCount + 1);

        // 池名字不够（全部占用）或池为空 → 回退前缀名 + 默认技能。
        if (Bot_NameInUse(name))
        {
            char prefix[32] = "AnhBot";
            g_cvNamePrefix.GetString(prefix, sizeof(prefix));
            g_iNameUid++;
            Format(name, sizeof(name), "%s%02d", prefix, g_iNameUid);
            skill = (g_cvSkill != null) ? g_cvSkill.IntValue : 1;
        }
    }

    int bot = Bot_AddExact(name, desiredTeam);
    if (bot > 0)
        g_Bot[bot].iSkill = skill;
    return bot;
}

public Action Timer_DelayedActivate(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client))
        Bot_Activate(client);
    return Plugin_Continue;
}

// 尝试把 bot 加入僵尸队（TEAM_ZOMBIE=4）。
// 【引擎限制】僵尸队最多 1 名玩家；ChangeClientTeam 进队会死一次。本函数：
//  - 队满 → 放弃，转为幸存者（iDesiredTeam 清掉）；
//  - 否则换队，并记 30s 退避（死亡→重建→再试的循环不会每轮都发生）。
public Action Timer_ZombieJoin(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client) || !g_Bot[client].bManaged)
        return Plugin_Continue;
    if (g_Bot[client].iDesiredTeam != TEAM_ZOMBIE)
        return Plugin_Continue;
    if (GetClientTeam(client) == TEAM_ZOMBIE)
        return Plugin_Continue;

    if (Bot_CountTeam(TEAM_ZOMBIE) > 0)
    {
        // 僵尸队已被占（人类玩家或另一个 bot）——引擎上限，放弃。
        g_Bot[client].iDesiredTeam = -1;
        Log("[anhsbot] zombie team already occupied; bot %d stays survivor", client);
        return Plugin_Continue;
    }

    g_Bot[client].fNextZombieTry = GetGameTime() + 30.0;
    Log("[anhsbot] bot %d attempting zombie team join (ChangeClientTeam; HL2MP kills on team change)", client);
    ChangeClientTeam(client, TEAM_ZOMBIE);
    return Plugin_Continue;
}

public bool Bot_NameInUse(const char[] name)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            char other[64];
            GetClientName(i, other, sizeof(other));
            if (StrEqual(other, name, false))
                return true;
        }
    }
    return false;
}

public void Bot_KickByIndex(int client)
{
    if (client > 0 && IsClientInGame(client) && IsFakeClient(client))
    {
        g_Bot[client].bManaged = false;
        KickClient(client, "[anhsbot] removed");
    }
}

public void Bot_KickAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && g_Bot[i].bManaged)
        {
            g_Bot[i].bManaged = false;
            KickClient(i, "[anhsbot] removed");
        }
    }
}

public void Bot_OnDisconnect(int client)
{
    g_Bot[client].bManaged = false;
    g_Bot[client].bActivated = false;
    g_Bot[client].bRebuilding = false;
    g_Bot[client].iRunCmds = 0;
    g_Bot[client].iTarget = 0;
    g_Bot[client].fLastTargetHp = -1.0;
    g_Bot[client].fLastDamageAt = 0.0;
    g_Bot[client].fDiedAt = 0.0;
    g_Bot[client].bWanderActive = false;
    g_Bot[client].iWanderFails = 0;
    g_Bot[client].bScoutWalk = false;
    g_Bot[client].iRegroupFails = 0;
    g_Bot[client].fRegroupPauseUntil = 0.0;
    g_Bot[client].fStuckRebuildAt = 0.0;
    Nav_ClearPath(client);
}

// 死亡重建：HL2MP 死亡玩家无法用 jointeam / respawn 命令原地复活（无回合制、
// 无 mp_forcerespawn）。最稳的是用原生 CreateFakeClient 路径重建一个同名同队 bot，
// 并把累计 K/D/伤害 结转过去，保持统计连续。
public void Bot_RespawnByRebuild(int client)
{
    if (!g_Bot[client].bManaged || g_Bot[client].bRebuilding)
        return;

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    int team = GetClientTeam(client);
    if (team <= 0)
        team = (g_Bot[client].iDesiredTeam > 0) ? g_Bot[client].iDesiredTeam : TEAM_REBELS;

    int kills  = g_Bot[client].iKills;
    int deaths = g_Bot[client].iDeaths;     // 死亡事件已 +1
    int damage = g_Bot[client].iDamageDealt;
    int skill  = g_Bot[client].iSkill;

    g_Bot[client].bRebuilding = true;
    g_Bot[client].bManaged = false;          // 看门狗立即停止触碰本实体
    KickClient(client, "[anhsbot] respawn rebuild");

    DataPack pk = new DataPack();
    pk.WriteString(name);
    pk.WriteCell(team);
    pk.WriteCell(kills);
    pk.WriteCell(deaths);
    pk.WriteCell(damage);
    pk.WriteCell(skill);
    CreateTimer(0.7, Timer_RebuildBot, pk);
    Dbg("watchdog rebuild scheduled client=%d name=%s", client, name);
}

public Action Timer_RebuildBot(Handle timer, DataPack pk)
{
    pk.Reset();
    char name[64];
    pk.ReadString(name, sizeof(name));
    int team   = pk.ReadCell();
    int kills  = pk.ReadCell();
    int deaths = pk.ReadCell();
    int damage = pk.ReadCell();
    int skill  = pk.ReadCell();
    delete pk;

    int bot = Bot_AddExact(name, team);
    if (bot <= 0)
    {
        Log("rebuild failed for '%s' (server full?)", name);
        return Plugin_Continue;
    }
    // 结转累计统计（deaths 已含本次死亡）与技能等级。
    g_Bot[bot].iKills = kills;
    g_Bot[bot].iDeaths = deaths;
    g_Bot[bot].iDamageDealt = damage;
    g_Bot[bot].iSkill = skill;
    Log("rebuilt bot '%s' as client %d (K/D/dmg=%d/%d/%d skill=%d)", name, bot, kills, deaths, damage, skill);
    return Plugin_Continue;
}

public void Bot_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsFakeClient(client))
        return;

    // 每次出生（含可能的重生）都重新确保 FL_FAKECLIENT；
    // 死亡/重生若清掉标志，这里会立刻补回。
    if (g_Bot[client].bManaged)
    {
        Bot_Activate(client);
        g_Bot[client].fNextRespawnCheck = GetGameTime() + 1.0;

        // 期望进僵尸队的 bot：出生后延迟尝试 ChangeClientTeam（引擎限制，见
        // Bot_PickDesiredTeam 注释；默认 cvar=0 时不会走到这里）。
        if (g_Bot[client].iDesiredTeam == TEAM_ZOMBIE
            && GetClientTeam(client) != TEAM_ZOMBIE
            && GetGameTime() >= g_Bot[client].fNextZombieTry)
        {
            CreateTimer(0.6, Timer_ZombieJoin, GetClientUserId(client));
        }

        // 重生后武器/目标全部重置，由 runcmd 首次活帧重新发放 loadout。
        g_Bot[client].bArmed = false;
        g_Bot[client].iTarget = 0;
        g_Bot[client].iWantWeapon = 0;
        g_Bot[client].iWantSubtype = 0;
        g_Bot[client].fRetargetAt = 0.0;
        g_Bot[client].fNextAmmoCheck = 0.0;
        g_Bot[client].iShotsFired = 0;
        g_Bot[client].fLastTargetHp = -1.0;
        g_Bot[client].fLastDamageAt = 0.0;
        g_Bot[client].fDiedAt = 0.0;
        // 走位/索敌缓存也重置：nav 路径、LOS 缓存、漫游目标全部作废。
        g_Bot[client].bNavMove = false;
        g_Bot[client].bWanderActive = false;
        g_Bot[client].iWanderFails = 0;
        g_Bot[client].bScoutWalk = false;
        g_Bot[client].fScoutUntil = 0.0;
        g_Bot[client].fNextJumpAt = 0.0;
        g_Bot[client].iRegroupFails = 0;
        g_Bot[client].fRegroupPauseUntil = 0.0;
        g_Bot[client].fLastIdleLogAt = 0.0;
        g_Bot[client].bHasLOS = false;
        g_Bot[client].fNextLosCheck = 0.0;
        g_Bot[client].fStuckCheckAt = 0.0;
        g_Bot[client].fNavPauseUntil = 0.0;
        g_Bot[client].iStuckCount = 0;
        g_Bot[client].fStuckRebuildAt = 0.0;
        Nav_ClearPath(client);

        Dbg("spawn client=%d team=%d", client, GetClientTeam(client));
    }
}

public void Bot_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsFakeClient(client) || !g_Bot[client].bManaged)
        return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    char weapon[32];
    event.GetString("weapon", weapon, sizeof(weapon));
    Log("bot %d died: attacker=%d weapon=%s", client, attacker, weapon);

    g_Bot[client].iDeaths++;
    g_Bot[client].bArmed = false;
    g_Bot[client].iTarget = 0;
    g_Bot[client].iWantWeapon = 0;
    g_Bot[client].fNextRespawnCheck = GetGameTime() + 2.0;
    g_Bot[client].fDiedAt = GetGameTime();
    g_Bot[client].fLastTargetHp = -1.0;
    g_Bot[client].fLastDamageAt = 0.0;

    // 击杀统计：击杀者是受管 bot。
    if (attacker > 0 && attacker != client && IsFakeClient(attacker)
        && g_Bot[attacker].bManaged)
    {
        g_Bot[attacker].iKills++;
        Dbg("bot %d got kill (total %d)", attacker, g_Bot[attacker].iKills);
    }
}

// 伤害诊断（不区分是否 bot，用来确认弹道是否真的命中并产生伤害）。
public void Bot_OnPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int dmg = event.GetInt("dmg_health");
    int hp = event.GetInt("health");
    char w[32];
    event.GetString("weapon", w, sizeof(w));
    Log("HURT victim=%d attacker=%d dmg=%d hp=%d wep=%s",
        victim, attacker, dmg, hp, w);
}

public void Bot_OnPlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsFakeClient(client) || !g_Bot[client].bManaged)
        return;
    int newTeam = event.GetInt("team");
    Dbg("team change client=%d -> team=%d", client, newTeam);
}

// 自动补齐到目标数量。
// quota 模式（anhsbot_quota > 0）：维持在线总数——不足则加、超出则踢（覆盖 anhsbot_count）。
// 传统模式（quota = 0）：只加不踢，维持 anhsbot_count。
public void Bot_FillToTarget()
{
    if (g_cvEnabled == null || !g_cvEnabled.BoolValue)
        return;
    int quota = (g_cvQuota != null) ? g_cvQuota.IntValue : 0;
    int target = (quota > 0) ? quota : g_cvTargetCount.IntValue;
    if (target <= 0)
        return;
    int online = CountManagedBots();
    for (int n = online; n < target; n++)
    {
        if (Bot_Add("", Bot_PickDesiredTeam()) == 0)
            break;
    }
    // quota 模式：超出配额时踢掉多出的（从高索引开始，即最新加入的）。
    if (quota > 0)
    {
        int excess = online - target;
        for (int i = MaxClients; i >= 1 && excess > 0; i--)
        {
            if (IsClientInGame(i) && IsFakeClient(i) && g_Bot[i].bManaged)
            {
                Bot_KickByIndex(i);
                excess--;
            }
        }
    }
}

// 新 bot 的期望队伍。quota_joinzombie > 0 且僵尸队未满时指定僵尸队（TEAM_ZOMBIE）；
// 否则 -1（引擎自动分配 2/3 幸存者队）。
// 【引擎限制（实测 2026-10-18）】僵尸队最多 1 名玩家；ChangeClientTeam 进僵尸队会
// 死一次（HL2MP 换队自杀），死后重建会回到幸存者队——持久僵尸 bot 不可行，
// 故默认 anhsbot_quota_joinzombie = 0（只出幸存者打 NPC）。
public int Bot_PickDesiredTeam()
{
    if (g_cvQuotaJoinZombie != null && g_cvQuotaJoinZombie.IntValue > 0)
    {
        if (Bot_CountTeam(TEAM_ZOMBIE) < g_cvQuotaJoinZombie.IntValue)
            return TEAM_ZOMBIE;
    }
    return -1;
}

public int Bot_CountTeam(int team)
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && g_Bot[i].bManaged
            && GetClientTeam(i) == team)
            n++;
    }
    return n;
}

public Action Timer_AutoFill(Handle timer)
{
    if (g_cvAutoFill != null && g_cvAutoFill.BoolValue)
        Bot_FillToTarget();
    return Plugin_Continue;
}

// 每帧看门狗：重设 FL_FAKECLIENT（若 cvar 开启）、心跳统计、异常自愈。
public void Bot_ThinkWatchdog()
{
    bool manage = (g_cvManageFlags != null && g_cvManageFlags.BoolValue);
    float now = GetGameTime();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i) || !g_Bot[i].bManaged)
            continue;

        // 卡住重建执行：Bot_CheckStuck 连续 4 次判卡（≈8s 零进展、兜底游走+
        // 跳跃无效）时挂起，这里延迟半秒执行——重建到安全出生点，把 bot 从
        // "hull 嵌进动态几何体（关闭的门/路障）"里捞出来（瞬移对 fake client
        // 无效，重建是唯一可靠手段；限频在 Bot_CheckStuck 内，30s/次）。
        if (g_Bot[i].fStuckRebuildAt > 0.0 && now >= g_Bot[i].fStuckRebuildAt
            && !g_Bot[i].bRebuilding && Bot_IsAlive(i))
        {
            g_Bot[i].fStuckRebuildAt = 0.0;
            Log("[anhsbot] bot %d: geometry trap - rebuilding to escape", i);
            Bot_RespawnByRebuild(i);
            continue;
        }

        if (manage && EnsureFakeClientFlag(i))
        {
            g_Bot[i].bActivated = true;
            Dbg("watchdog re-asserted FL_FAKECLIENT client=%d", i);
        }

        // 重生看门狗：ANHS(HL2MP) 死亡后 bot 可能一直躺着（引擎对 fake client
        // 的自动重生不总触发，且无回合制 / 无 mp_forcerespawn）。死亡超过
        // anhsbot_respawn_delay 秒就用原生 CreateFakeClient 路径重建同名同队 bot，
        // 并把累计 K/D/伤害 结转过去（见 Bot_RespawnByRebuild）。
        if (!Bot_IsAlive(i))
        {
            if (g_Bot[i].fDiedAt <= 0.0)
                g_Bot[i].fDiedAt = now;
            if (now - g_Bot[i].fDiedAt >= g_fRespawnDelay && !g_Bot[i].bRebuilding)
            {
                Bot_RespawnByRebuild(i);
            }
        }
        else if (g_Bot[i].fDiedAt > 0.0 || g_Bot[i].bRebuilding)
        {
            g_Bot[i].fDiedAt = 0.0;
            g_Bot[i].bRebuilding = false;
        }
    }
}
