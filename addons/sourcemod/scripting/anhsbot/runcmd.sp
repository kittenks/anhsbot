/**
 * anhsbot/runcmd.sp — OnPlayerRunCmd 驱动入口 + 人类 bot 战斗大脑
 *
 * 前置条件（gamedata PlayerRunCmd=418 + FL_FAKECLIENT）由 bot.sp 看门狗保证。
 *
 * 本模块在 CUserCmd 层完成战斗闭环（每 tick 一次）：
 *   1) 首次活着 → 发放人类 loadout（GivePlayerItem + WeaponEquip[261]，见 weapons.sp）；
 *   2) 低频补弹；
 *   3) 目标管理（索敌/校验，见 targeting.sp）；
 *   4) 选枪并通过 usercmd 的 weaponselect/subtype 切枪；
 *   5) 转向目标（改写 viewangles，角度插值），到位后按 IN_ATTACK 开火；
 *   6) 关闭 upmove、规范化移动分量，return Plugin_Changed 让引擎回写。
 *
 * 走位体系（四层，优先级从高到低）：
 *   a) nav 寻路（nav.inc）：目标 > ANH_NAV_ENGAGE_DIST 或目标无 LOS 时，
 *      A* 规划路径并跟随（Bot_ComputeMovement 的 bNavMove 分支）；
 *      无目标时向队友集结（teamplay）或随机漫游（Bot_IdleBehavior）。
 *   b) 三段式距离带：远逼近 / 近后撤 / 中段环形绕步（边走边打）。
 *   c) 墙滑（Bot_SlideDir）：期望方向被遮挡时旋转探测，贴墙滑过防卡死。
 *   d) 几何兜底游走（Bot_StartScoutWalk）：寻路连续失败或连续卡住
 *      （≥3 个 2s 窗口零位移）时随机方向 + 墙滑强行移动 2.5s，战斗/空闲
 *      共用——nav 岛不连通、目标不可达、顶着墙干追都靠它拔出头。
 *   地图无 .nav 文件时自动回退到 b/c 纯几何走位。
 *
 * 团队模式（anhsbot_teamplay）：幸存者 2/3 互认为队友——不互杀、开火前做
 * 友伤遮挡检查（Targ_FriendlyBlock）、空闲向队友集结。
 */

#define ANH_AIM_ERR_DEG   5.0    // 瞄准到位误差（度），小于即开火

// 角度差（target-cur），归一化到 [-180,180]，处理 ±180 环绕。
stock float Bot_AngleDiff(float target, float cur)
{
    float d = target - cur;
    while (d > 180.0)  d -= 360.0;
    while (d < -180.0) d += 360.0;
    return d;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                            float vel[3], float angles[3], int &weapon, int &subtype,
                            int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsClientInGame(client) || !IsFakeClient(client) || !g_Bot[client].bManaged)
        return Plugin_Continue;

    g_Bot[client].iRunCmds++;

    if (!Bot_IsAlive(client))
        return Plugin_Continue;

    bool changed = BotAI_OnRunCmd(client, buttons, impulse, vel, angles, weapon, subtype);
    return changed ? Plugin_Changed : Plugin_Continue;
}

// 战斗决策。返回 true 表示改写了 CUserCmd。
stock bool BotAI_OnRunCmd(int client, int &buttons, int &impulse,
                          float vel[3], float angles[3], int &weapon, int &subtype)
{
    bool changed = false;
    float now = GetGameTime();

    // 几何兜底游走到期检查（战斗/空闲共用的卡住自救，见 Bot_StartScoutWalk）。
    // 到期后重置卡住检测窗口，并允许空闲行为立刻重选漫游目标。
    if (g_Bot[client].bScoutWalk && now >= g_Bot[client].fScoutUntil)
    {
        g_Bot[client].bScoutWalk = false;
        g_Bot[client].fStuckCheckAt = 0.0;
        g_Bot[client].fNextWanderAt = 0.0;
    }

    // 危险区（trigger_hurt 等）低频扫描：内部 TTL 5s，多 bot 同帧调用也只有
    // 第一个真正执行扫描；缓存供 Nav_GetMoveDir 的路径方向规避使用。
    if (g_bNavLoaded)
        Nav_ScanDanger(now);

    // 1) 本命首次：发放武器 loadout。
    if (!g_Bot[client].bArmed)
    {
        Wep_EquipHumanLoadout(client);
        g_Bot[client].bArmed = true;
        int primary = Wep_ChooseBestGun(client);
        if (primary != -1)
            Wep_RequestSwitch(client, primary);
        Dbg("bot %d armed (skill %d)", client, g_Bot[client].iSkill);
    }

    // 2) 低频补弹（弹夹/备弹）。
    if (now >= g_Bot[client].fNextAmmoCheck)
    {
        Wep_Refill(client);
        g_Bot[client].fNextAmmoCheck = now + 1.5;
    }

    // 3) 目标管理。
    int target = g_Bot[client].iTarget;
    if (target > 0 && !Targ_StillValid(client, target))
    {
        // 目标失效：NPC 没有 player_death 事件，只能靠"近期打到过它 + 它现在没了"
        // 来归属击杀。关键：ANHS 僵尸会"死亡→复活"（同一实体 ent 不变、血量重置回满），
        // 若只在血量归零时记击杀，一只反复复活的僵尸会被刷成几十次击杀。
        // 故仅在【实体被真正移除】(IsValidEntity==false) 时才记击杀；复活刷血不计数。
        bool removed = !IsValidEntity(target);
        if (removed && g_Bot[client].fLastDamageAt > 0.0
            && now - g_Bot[client].fLastDamageAt < 5.0)
        {
            g_Bot[client].iKills++;
            Log("bot %d killed %d (total %d)", client, target, g_Bot[client].iKills);
        }
        else if (!removed)
        {
            Dbg("bot %d target %d went invalid but not removed (revive?); no kill counted",
                client, target);
        }
        Dbg("bot %d lost target %d", client, target);
        target = 0;
        g_Bot[client].iTarget = 0;
        g_Bot[client].fLastTargetHp = -1.0;
    }
    if (target <= 0 || now >= g_Bot[client].fRetargetAt)
    {
        int t = Targ_FindBest(client);
        if (t > 0)
        {
            if (t != g_Bot[client].iTarget)
                Dbg("bot %d acquired target %d", client, t);
            g_Bot[client].iTarget = t;
            target = t;
            g_Bot[client].fLastTargetHp = -1.0;
        }
        // 【防脚本超时】给重选时刻加抖动，避免多个 bot 同帧全量索敌。
        g_Bot[client].fRetargetAt = now + ANH_RETARGET_INTERVAL
            + float(client % 8) * (ANH_RETARGET_INTERVAL / 8.0);
    }

    // 无目标：空闲行为——teamplay 向队友集结 / nav 随机漫游（无 nav 则站住）。
    if (target <= 0)
    {
        g_Bot[client].fLastTargetHp = -1.0;
        g_Bot[client].bNavMove = false;
        return Bot_IdleBehavior(client, buttons, angles, vel);
    }

    // 3b) 伤害/击杀统计：对比当前目标血量变化。
    if (HasEntProp(target, Prop_Data, "m_iHealth"))
    {
        float hp = float(GetEntProp(target, Prop_Data, "m_iHealth"));
        if (hp >= 0.0)
        {
            if (g_Bot[client].fLastTargetHp >= 0.0 && hp < g_Bot[client].fLastTargetHp)
            {
                int delta = RoundToNearest(g_Bot[client].fLastTargetHp - hp);
                if (delta > 0)
                {
                    g_Bot[client].iDamageDealt += delta;
                    g_Bot[client].fLastDamageAt = now;
                    Dbg("bot %d dealt %d to %d (total %d)",
                        client, delta, target, g_Bot[client].iDamageDealt);
                }
            }
            g_Bot[client].fLastTargetHp = hp;
        }
    }

    // 4) 选枪 + 切枪。优先有弹药的枪，近战兜底。
    int wantGun = Wep_ChooseBestGun(client);
    float aimPoint[3];
    Targ_AimPoint(target, aimPoint);
    float eye[3];
    GetClientEyePosition(client, eye);
    float dist = GetVectorDistance(eye, aimPoint);

    // 4a) nav 寻路决策：目标很远（> ANH_NAV_ENGAGE_DIST）或看不到目标时，
    //     走 A* 路径逼近；其余情况用距离带几何走位（Bot_ComputeMovement）。
    //     LOS 检测限频（0.3s + 按 client 抖动），避免每 bot 每帧一次 trace。
    //     本帧是否 nav 走位由 bNavMove 通知 Bot_ComputeMovement。
    g_Bot[client].bNavMove = false;
    if (g_cvNavEnable != null && g_cvNavEnable.BoolValue && g_bNavLoaded)
    {
        // 卡住暂停期一律让几何走位（距离带 + 墙滑 + 兜底游走）接管。
        // 【实测教训 2026-10-18】旧代码只在 wantNav=false（目标<700）时理会
        // 暂停，远目标直接无视暂停、每 2s 重算同一条路径又卡住——bot 顶着墙
        // 干追 60s+（stuck count 11）。暂停必须优先于距离/LOS 判断。
        bool wantNav;
        if (now < g_Bot[client].fNavPauseUntil)
        {
            wantNav = false;
        }
        else
        {
            wantNav = (dist > ANH_NAV_ENGAGE_DIST);
            if (!wantNav)
            {
                if (now >= g_Bot[client].fNextLosCheck)
                {
                    g_Bot[client].fNextLosCheck = now + 0.3 + float(client % 8) * 0.04;
                    g_Bot[client].bHasLOS = Targ_HasLOS(client, target, aimPoint);
                }
                wantNav = !g_Bot[client].bHasLOS;
            }
        }
        if (wantNav)
        {
            float goal[3];
            Targ_EntityPos(target, goal);
            goal[2] += 48.0;    // 与瞄准点高度对齐（Nav_FindArea 用 z 加权）
            if (Nav_UpdatePath(client, goal))
            {
                float pos[3];
                GetClientAbsOrigin(client, pos);
                float dir[3];
                if (Nav_GetMoveDir(client, pos, dir))
                {
                    if (Bot_CheckStuck(client))
                    {
                        // 卡住：本帧起几何走位接管，nav 暂停；连续卡住暂停更久，
                        // 避免"清路径→重算同一条→又卡住"的快速循环。
                        g_Bot[client].bNavMove = false;
                        g_Bot[client].fNavPauseUntil = now
                            + ((g_Bot[client].iStuckCount >= 2) ? 5.0 : 3.0);
                        // 连续卡住 2 次（≈4s 零进展）：几何兜底游走，把 bot
                        // 从"顶着不可通行的路径方向"的状态里拔出来（随机
                        // 方向 + 墙滑 + 周期跳跃，期间仍瞄准/开火）。
                        if (g_Bot[client].iStuckCount >= 2)
                            Bot_StartScoutWalk(client, now, ANH_SCOUT_WALK_TIME);
                    }
                    else
                    {
                        g_Bot[client].bNavMove = true;
                        g_Bot[client].fNavDirX = dir[0];
                        g_Bot[client].fNavDirY = dir[1];
                        g_Bot[client].fNavSpeed = ANH_MOVE_SPEED;
                    }
                }
            }
        }
    }

    if (wantGun == -1)
    {
        // 枪械全空/过近：贴脸用近战。
        wantGun = (dist < 90.0) ? Wep_GetMelee(client) : -1;
        if (wantGun == -1)
            wantGun = Wep_ChooseBestGun(client); // 没近战就拿（空）枪等待补弹
    }
    if (wantGun != -1)
        Wep_RequestSwitch(client, wantGun);

    // 切枪未落地：本帧下发 weaponselect，等待引擎切换。
    if (g_Bot[client].iWantWeapon > 0 && !Wep_SwitchDone(client))
    {
        weapon = g_Bot[client].iWantWeapon;
        subtype = g_Bot[client].iWantSubtype;
        changed = true;
        // 切枪期间也先开始转向，缩短开火延迟。
        AimAt(client, target, angles, changed);
        return true;
    }
    if (Wep_SwitchDone(client))
        g_Bot[client].iWantWeapon = 0;

    // 5) 转向目标。
    bool aimed = AimAt(client, target, angles, changed);
    changed = true;

    // 6) 开火：瞄准到位且当前武器有弹。
    //    teamplay 开启时先做友伤遮挡检查：队友挡在弹道上则本帧放弃开火
    //    （Targ_FriendlyBlock 内部限 teamplay 开启才生效）。
    int active = Wep_GetActive(client);
    if (active != -1)
    {
        int clip = Wep_GetClip(active);
        if (aimed && (clip > 0 || clip == -1))
        {
            if (Targ_FriendlyBlock(client, target, aimPoint))
            {
                if (now - g_Bot[client].fLastFriendlyHold > 1.0)
                {
                    Dbg("bot %d holds fire: teammate blocking line to %d", client, target);
                    g_Bot[client].fLastFriendlyHold = now;
                }
            }
            else
            {
                buttons |= IN_ATTACK_BIT;
                g_Bot[client].iShotsFired++;
            }
        }
    }

    // 7) 走位：nav 路径优先（4a 已置位 bNavMove），否则在"距离带"内做三段式
    //    机动；卡住自救的几何兜底游走（bScoutWalk）优先于两者。三者都带墙滑
    //    保险（Bot_SlideDir / Bot_ApplyNavVel）。
    //    兜底游走期间周期性跳跃：lip/台阶/小突起卡住时最有效的自救手段。
    if (g_Bot[client].bScoutWalk && now >= g_Bot[client].fNextJumpAt)
    {
        g_Bot[client].fNextJumpAt = now + 0.7;
        buttons |= IN_JUMP_BIT;
    }
    Bot_ComputeMovement(client, eye, aimPoint, angles, vel);
    return changed;
}

// 空闲行为（无目标）：teamplay 集结 → nav 随机漫游。
// 返回 true 表示改写了 vel（需要 Plugin_Changed）。
//
// 【防卡死设计（2026-10-18 实测教训）】随机目标落在不连通 nav 岛 → A* 永久
// 失败 → 1s 退避循环 → bot 干站 60s 无任何日志（失败路径全是 Dbg，默认
// debug=0 被压制，排查不到）。现在：
//  1) 漫游选目标"近环带优先 + 多候选"：身侧 200~900u 的 area 最可能与 bot
//     同岛，第一个 A* 成功的候选即用；仍失败才放宽到全图随机。
//  2) 连续失败 ANH_WANDER_MAX_FAILS 次 → 几何兜底游走（随机方向 + 墙滑 +
//      周期跳跃）2.5s，保证 bot 永远在动，并有机会挪出"贴住错误 area"的位置。
//  3) 集结目标不可达同样计数，连续失败暂停集结 8s 转漫游（两只 bot 在
//     不同岛时不会互相干等）。
//  4) 卡住/寻路失败/scout 全部走 Log（限频 10s/bot），不再依赖 debug cvar。
stock bool Bot_IdleBehavior(int client, int &buttons, float angles[3], float vel[3])
{
    g_Bot[client].bNavMove = false;
    if (g_cvNavEnable == null || !g_cvNavEnable.BoolValue || !g_bNavLoaded)
        return false;
    float now = GetGameTime();

    // 0) 几何兜底游走进行中：优先执行（寻路连续失败/卡住时的保底移动）。
    //    到期检查已在 BotAI_OnRunCmd 开头统一处理（战斗/空闲共用）。
    if (g_Bot[client].bScoutWalk)
    {
        float dir[3];
        float rad = g_Bot[client].fScoutYaw * (3.14159265 / 180.0);
        dir[0] = Cosine(rad);
        dir[1] = Sine(rad);
        dir[2] = 0.0;
        if (now >= g_Bot[client].fNextJumpAt)
        {
            g_Bot[client].fNextJumpAt = now + 0.7;
            buttons |= IN_JUMP_BIT;
        }
        Bot_LookAlong(client, angles, dir);
        Bot_ApplyNavVel(client, angles, dir, ANH_MOVE_SPEED * 0.55, vel);
        return true;
    }

    // 1) teamplay 集结：向最近队友靠拢（保持 ANH_REGROUP_DIST 不贴身），
    //    已在集结距离内则原地站岗（不漫游走散）。
    //    目标不可达连续失败 → 暂停集结转漫游（fRegroupPauseUntil）。
    if (g_cvTeamplay != null && g_cvTeamplay.BoolValue
        && now >= g_Bot[client].fRegroupPauseUntil)
    {
        int mate = Targ_FindTeammate(client, ANH_REGROUP_MAX);
        if (mate > 0)
        {
            float mp[3], myp[3];
            GetClientAbsOrigin(mate, mp);
            GetClientAbsOrigin(client, myp);
            float dx = mp[0] - myp[0], dy = mp[1] - myp[1];
            if (SquareRoot(dx * dx + dy * dy) > ANH_REGROUP_DIST)
            {
                if (Nav_UpdatePath(client, mp))
                {
                    float dir[3];
                    if (Nav_GetMoveDir(client, myp, dir))
                    {
                        // 【实测教训 2026-10-18 回归测试】集结分支此前没有卡住
                        // 检测：bot 1/4 相距 1537u < ANH_REGROUP_MAX(1600) 互相
                        // 集结，双方 hull 嵌进几何陷阱——vel 有值但零位移，而
                        // 本分支不调用 Bot_CheckStuck 也不产生任何日志，wander
                        // 分支的 scout/curse/rebuild 自救链被完全绕过，bot 静默
                        // 冻结 90s+（实测位置零变化、全局仅 1 条 stuck 日志）。
                        // 这里补上与 wander/战斗分支相同的卡住检测。
                        if (Bot_CheckStuck(client))
                        {
                            // 集结路卡死：暂停集结转漫游；连续卡住 → 兜底游走
                            // （Bot_CheckStuck 内部已按 ≥2 诅咒 area、≥4 挂起重建）。
                            g_Bot[client].fRegroupPauseUntil = now + 1.0;
                            if (g_Bot[client].iStuckCount >= 2)
                                Bot_StartScoutWalk(client, now, ANH_SCOUT_WALK_TIME);
                            return false;
                        }
                        Bot_LookAlong(client, angles, dir);
                        Bot_ApplyNavVel(client, angles, dir, ANH_MOVE_SPEED * 0.75, vel);
                        return true;
                    }
                }
                else
                {
                    // 集结寻路失败（队友在别的 nav 岛/不可达）：计数限流，
                    // 连续失败暂停集结，让 bot 先去漫游而不是互相干等。
                    g_Bot[client].iRegroupFails++;
                    if (g_Bot[client].iRegroupFails >= ANH_REGROUP_MAX_FAILS)
                    {
                        g_Bot[client].fRegroupPauseUntil = now + ANH_REGROUP_PAUSE;
                        g_Bot[client].iRegroupFails = 0;
                        char msg[128];
                        Format(msg, sizeof(msg), "regroup unreachable - pausing %.0fs",
                            ANH_REGROUP_PAUSE);
                        Bot_IdleLogMsg(client, now, msg);
                    }
                }
            }
            else
            {
                return false;   // 已跟住队友，站岗
            }
        }
    }

    // 2) 随机漫游：到期或上一条走完就选新的随机 area 中心。
    //    多候选（近环带优先）提高连通率；连续失败 → 几何兜底游走。
    if (!g_Bot[client].bWanderActive && now >= g_Bot[client].fNextWanderAt)
    {
        float myp[3];
        GetClientAbsOrigin(client, myp);
        float wc[3];
        bool ok = false;
        for (int t = 0; t < ANH_WANDER_TRIES && !ok; t++)
        {
            if (t == 0)
            {
                // 首选：身侧 200~900u 环带（最可能同岛连通）
                if (!Nav_RandomAreaCenterNear(wc, myp,
                        ANH_WANDER_NEAR_MIN, ANH_WANDER_NEAR_MAX, 8))
                    continue;
            }
            else if (!Nav_RandomAreaCenter(wc))
            {
                continue;
            }
            ok = Nav_RequestPath(client, wc);
        }
        if (ok)
        {
            g_Bot[client].fWanderX = wc[0];
            g_Bot[client].fWanderY = wc[1];
            g_Bot[client].fWanderZ = wc[2];
            g_Bot[client].bWanderActive = true;
            g_Bot[client].iWanderFails = 0;
            g_Bot[client].fNextWanderAt = now + GetRandomFloat(ANH_WANDER_MIN, ANH_WANDER_MAX);
        }
        else
        {
            g_Bot[client].iWanderFails++;
            char msg[128];
            Format(msg, sizeof(msg), "wander path failed (fails %d)",
                g_Bot[client].iWanderFails);
            Bot_IdleLogMsg(client, now, msg);
            if (g_Bot[client].iWanderFails >= ANH_WANDER_MAX_FAILS)
                Bot_StartScoutWalk(client, now, ANH_SCOUT_WALK_TIME);
            g_Bot[client].fNextWanderAt = now + 1.0;   // 失败退避
        }
    }
    if (g_Bot[client].bWanderActive)
    {
        float myp[3];
        GetClientAbsOrigin(client, myp);
        float dir[3];
        if (Nav_GetMoveDir(client, myp, dir))
        {
            if (Bot_CheckStuck(client))
            {
                // 卡住：放弃当前漫游目标，稍后重选（Nav_ClearPath 已清）；
                // 连续卡住 → 几何兜底游走，别在同一个坑里反复重选。
                g_Bot[client].bWanderActive = false;
                g_Bot[client].fNextWanderAt = now + 1.0;
                g_Bot[client].fNavPauseUntil = now + 1.0;
                if (g_Bot[client].iStuckCount >= 2)
                    Bot_StartScoutWalk(client, now, ANH_SCOUT_WALK_TIME);
                return false;
            }
            Bot_LookAlong(client, angles, dir);
            Bot_ApplyNavVel(client, angles, dir, ANH_MOVE_SPEED * 0.6, vel);
            return true;
        }
        // 路径走完（正常，稍作停顿再选下一条）或被危险区阻断（失败，升级）。
        g_Bot[client].bWanderActive = false;
        if (Nav_PathActive(client))
        {
            // 路径还在但给不出方向（危险区遮挡；ant_deadend_drive 实测有 12 处
            // trigger_hurt）：计失败并当场检查阈值——不能只靠"选新路"分支升级，
            // 因为选路成功会把计数清零，形成"选路→被挡→+1→选路成功清零→被挡"
            // 的静默死循环（实测 bot 干站 60s 零日志）。
            g_Bot[client].iWanderFails++;
            if (g_Bot[client].iWanderFails >= ANH_WANDER_MAX_FAILS)
                Bot_StartScoutWalk(client, now, ANH_SCOUT_WALK_TIME);
            else
                g_Bot[client].fNextWanderAt = now + 1.0;
        }
        else
        {
            g_Bot[client].fNextWanderAt = now + 0.4 + GetRandomFloat(0.0, 0.3);
        }
    }
    return false;
}

// 启动几何兜底游走：随机方向 + 墙滑行走 duration 秒（寻路连续失败/卡住时的
// 保底移动）。期间不寻路（scout 分支优先执行），到点后立刻重试 nav。
stock void Bot_StartScoutWalk(int client, float now, float duration)
{
    g_Bot[client].bScoutWalk = true;
    g_Bot[client].fScoutUntil = now + duration;
    g_Bot[client].fScoutYaw = GetRandomFloat(0.0, 360.0);
    g_Bot[client].fNextJumpAt = 0.0;    // 立刻允许第一次跳跃
    g_Bot[client].bWanderActive = false;
    g_Bot[client].iWanderFails = 0;
    g_Bot[client].iRegroupFails = 0;
    g_Bot[client].fStuckCheckAt = 0.0;
    Nav_ClearPath(client);
    char msg[128];
    Format(msg, sizeof(msg), "path unreachable - scout walk %.0f deg for %.1fs",
        g_Bot[client].fScoutYaw, duration);
    // 直接 Log 不限频：scout 是关键状态转换，曾被 10s 限频器吞掉导致回归测试
    // 误判"未触发"（实测 2026-10-18）。触发率有下限（count≥2 才起，2.5s 冷却），
    // 量级可接受。
    Log("bot %d: %s", client, msg);
}

// 空闲诊断日志（卡住/寻路失败/scout），限频 ANH_IDLE_LOG_INTERVAL 秒/bot。
// 【为什么用 Log 不用 Dbg】这些是"bot 干站"的唯一信号，默认 debug=0 时
// Dbg 全被压制，线上排查不到；限频保证最坏 4 bot ≈ 0.4 行/秒。
stock void Bot_IdleLogMsg(int client, float now, const char[] msg)
{
    if (now < g_Bot[client].fLastIdleLogAt)
        return;
    g_Bot[client].fLastIdleLogAt = now + ANH_IDLE_LOG_INTERVAL;
    Log("bot %d: %s", client, msg);
}

// 卡住检测（nav 走位自救）：每 2s 比较一次水平位移，<40 单位判定卡住
// （nav waypoint 中心可能落在不可达处：道具堆里、门后、高台上……）。
// 返回 true = 本帧检测到卡住（调用方应清路径换策略）。
// 只在 nav 走位期间调用；战斗距离带/站岗时不检测。
stock bool Bot_CheckStuck(int client)
{
    float now = GetGameTime();
    if (g_Bot[client].fStuckCheckAt <= 0.0)
    {
        // 首次：只记录参考点
        float p0[3];
        GetClientAbsOrigin(client, p0);
        g_Bot[client].fStuckRefX = p0[0];
        g_Bot[client].fStuckRefY = p0[1];
        g_Bot[client].fStuckCheckAt = now + 2.0;
        return false;
    }
    if (now < g_Bot[client].fStuckCheckAt)
        return false;

    float p[3];
    GetClientAbsOrigin(client, p);
    float dx = p[0] - g_Bot[client].fStuckRefX;
    float dy = p[1] - g_Bot[client].fStuckRefY;
    float moved = SquareRoot(dx * dx + dy * dy);

    // 重置参考点与窗口
    g_Bot[client].fStuckRefX = p[0];
    g_Bot[client].fStuckRefY = p[1];
    g_Bot[client].fStuckCheckAt = now + 2.0;

    if (moved < 40.0)
    {
        g_Bot[client].iStuckCount++;
        Nav_ClearPath(client);
        char msg[128];
        Format(msg, sizeof(msg), "stuck (moved %.0f in 2s, count %d) - path cleared",
            moved, g_Bot[client].iStuckCount);
        Bot_IdleLogMsg(client, now, msg);

        // 连续卡住 ≥2 次（≈4s 零进展）：诅咒当前所在与目标 waypoint 的 area。
        // 【根因 2026-10-18 探针实证】ant_deadend_drive 静态 nav 与运行时动态
        // 几何不一致（nav 生成时开着的门/路障，运行时关闭）：bot 走进去 hull
        // 嵌进几何体——vel 有值但零位移、m_hGroundEntity=0、TeleportEntity
        // 对 fake client 无效。诅咒后 A* 绕开，后续 bot 不再走同一条死路。
        if (g_Bot[client].iStuckCount >= 2)
            Nav_CurseAround(client, p, now);

        // 兜底游走（随机方向 + 墙滑 + 跳跃）也救不回（≥3 次 ≈6s 零进展）→
        // 挂起重建：kick + CreateFakeClient 在安全出生点重来（K/D/伤害结转）。
        // 瞬移无效，重建是唯一可靠的"挪出几何陷阱"手段；30s 限频防止出生点
        // 也被污染时的重建 churn。由 Bot_ThinkWatchdog 下半秒执行。
        // 【阈值 4→3，实测 2026-10-18 回归】bot 3 在陷阱口袋震荡：窗口位移
        // 15~29u（<40 判卡）但偶尔 180u 大幅摆动把计数满血清零，count 永远
        // 摸不到 4——配合下面的衰减计数，3 次即可重建（≈6s），不再依赖
        // "连续"。
        if (g_Bot[client].iStuckCount >= 3
            && now >= g_Bot[client].fNextStuckRebuildAt
            && g_Bot[client].fStuckRebuildAt <= 0.0)
        {
            g_Bot[client].fNextStuckRebuildAt = now + 30.0;
            g_Bot[client].fStuckRebuildAt = now + 0.5;
            Log("bot %d: stuck %dx - geometry trap, rebuild scheduled",
                client, g_Bot[client].iStuckCount);
        }
        return true;
    }
    // 有进展：衰减而非清零（-1）。【实测 2026-10-18 回归】陷阱口袋里的 bot
    // 会周期性大幅摆动（>40u）后继续卡——满血重置让计数永远攒不到阈值，
    // 重建永不触发；衰减后震荡模式下计数仍能爬到 3。
    if (g_Bot[client].iStuckCount > 0)
        g_Bot[client].iStuckCount--;
    return false;
}

// 把视角平滑转向移动方向（空闲漫游时让 bot "看着路走"）。
stock void Bot_LookAlong(int client, float angles[3], const float dir[3])
{
    float lookDir[3];
    lookDir[0] = dir[0]; lookDir[1] = dir[1]; lookDir[2] = 0.0;
    float want[3];
    GetVectorAngles(lookDir, want);

    float cur[3];
    GetClientEyeAngles(client, cur);
    float dYaw = Bot_AngleDiff(want[1], cur[1]);
    cur[1] += dYaw * 0.25;    // 缓慢转头，避免瞬间抽头

    angles[0] = 0.0;
    angles[1] = cur[1];
    angles[2] = 0.0;
}

// 把世界方向 dir 转成本地前/侧移速度写回 vel[]（带墙滑保险）：
// nav 方向被障碍挡住时旋转探测最近可通方向，防卡死。
stock void Bot_ApplyNavVel(int client, const float angles[3], const float dir[3],
                           float speed, float vel[3])
{
    float resolved[3];
    resolved[0] = dir[0]; resolved[1] = dir[1]; resolved[2] = 0.0;

    // 墙滑保险：通畅直接用；被挡才做 7 向旋转探测（省 trace）。
    float hit;
    if (!Bot_TraceDir(client, resolved, ANH_MOVE_CLEAR_DIST, hit))
        Bot_SlideDir(client, resolved, resolved);

    // 世界方向 → 本地前/侧移（基于本帧 viewangles）。
    float fwd[3], right[3], up[3];
    GetAngleVectors(angles, fwd, right, up);
    fwd[2]  = 0.0; NormalizeVector(fwd,  fwd);
    right[2] = 0.0; NormalizeVector(right, right);

    float lf = GetVectorDotProduct(resolved, fwd);
    float lr = GetVectorDotProduct(resolved, right);

    vel[0] = lf * speed;
    vel[1] = lr * speed;
    vel[2] = 0.0;
    g_Bot[client].fLastVelFwd = vel[0];
    g_Bot[client].fLastVelRight = vel[1];
}

// 计算 bot 的世界期望移动方向（单位水平向量），再转成本地前/侧移速度并写回 vel[]。
// 同时做"墙滑"：若期望方向被遮挡，旋转找最近的可通方向。
//
// nav 优先：BotAI_OnRunCmd 在"目标远/无 LOS"时置位 bNavMove，本函数直接用
// nav 路径方向（含墙滑保险）覆盖距离带逻辑；无 nav 或路径结束时回退距离带。
stock void Bot_ComputeMovement(int client,
                               const float eye[3], const float aim[3],
                               const float angles[3], float vel[3])
{
    // 几何兜底游走（卡住自救，战斗/空闲共用）优先于 nav/距离带：
    // 随机方向 + 墙滑走 2.5s，把 bot 从 wedge/不可通行方向里拔出来。
    // 战斗中来这里时 angles 已是瞄准角，bot 会"一边射击一边横向挪步"。
    if (g_Bot[client].bScoutWalk)
    {
        float sdir[3];
        float rad = g_Bot[client].fScoutYaw * (3.14159265 / 180.0);
        sdir[0] = Cosine(rad);
        sdir[1] = Sine(rad);
        sdir[2] = 0.0;
        Bot_ApplyNavVel(client, angles, sdir, ANH_MOVE_SPEED * 0.55, vel);
        return;
    }

    if (g_Bot[client].bNavMove)
    {
        float nd[3];
        nd[0] = g_Bot[client].fNavDirX;
        nd[1] = g_Bot[client].fNavDirY;
        nd[2] = 0.0;
        Bot_ApplyNavVel(client, angles, nd, g_Bot[client].fNavSpeed, vel);
        return;
    }

    float toTgt[3];
    MakeVectorFromPoints(eye, aim, toTgt);
    float horiz[3];
    horiz[0] = toTgt[0]; horiz[1] = toTgt[1]; horiz[2] = 0.0;
    float flatDist = GetVectorLength(horiz);

    float toDir[3] = { 1.0, 0.0, 0.0 };
    if (flatDist > 1.0)
    {
        NormalizeVector(horiz, toDir);
    }

    // 距离带 → 期望世界方向。
    float desired[3];
    float now = GetGameTime();
    if (flatDist > ANH_MOVE_BAND_FAR)
    {
        desired = toDir;                       // 逼近
    }
    else if (flatDist < ANH_MOVE_BAND_NEAR)
    {
        desired[0] = -toDir[0];                // 后撤拉开
        desired[1] = -toDir[1];
        desired[2] = 0.0;
    }
    else
    {
        // 环形绕步：取 toDir 的垂直方向，符号由 iStrafeSign 决定（定时翻转）。
        if (now >= g_Bot[client].fNextStrafeFlip)
        {
            g_Bot[client].iStrafeSign = -g_Bot[client].iStrafeSign;
            g_Bot[client].fNextStrafeFlip = now
                + ANH_STRAFE_FLIP_MIN
                + GetRandomFloat(0.0, ANH_STRAFE_FLIP_MAX - ANH_STRAFE_FLIP_MIN);
        }
        float s = float(g_Bot[client].iStrafeSign);
        desired[0] = -toDir[1] * s;
        desired[1] =  toDir[0] * s;
        desired[2] = 0.0;
    }

    // 墙滑：把期望方向旋转到最近的可通方向。
    float resolved[3];
    Bot_SlideDir(client, desired, resolved);

    // 世界方向 → 本地前/侧移（基于本帧已写好的 viewangles，与瞄准朝向一致）。
    float fwd[3], right[3], up[3];
    GetAngleVectors(angles, fwd, right, up);
    fwd[2]  = 0.0; NormalizeVector(fwd,  fwd);
    right[2] = 0.0; NormalizeVector(right, right);

    float lf = GetVectorDotProduct(resolved, fwd);
    float lr = GetVectorDotProduct(resolved, right);

    float speed = (flatDist < ANH_MOVE_BAND_NEAR) ? ANH_MOVE_BACKOFF
               : (flatDist > ANH_MOVE_BAND_FAR)   ? ANH_MOVE_SPEED
               : ANH_MOVE_STRAFE;
    vel[0] = lf * speed;
    vel[1] = lr * speed;
    vel[2] = 0.0;
    g_Bot[client].fLastVelFwd = vel[0];
    g_Bot[client].fLastVelRight = vel[1];
}

// 忽略 bot 自身的移动射线过滤器。
public bool Bot_MoveFilter(int entity, int contentsMask, any data)
{
    return (entity != view_as<int>(data));
}

// 沿 dir（单位水平向量）探测 maxDist 距离内是否通畅。
// 返回 true 表示通畅；hitDist 写入实际可通行距离（被挡时为命中点距离，否则 maxDist）。
stock bool Bot_TraceDir(int client, const float dir[3], float maxDist, float &hitDist)
{
    float eye[3];
    GetClientEyePosition(client, eye);
    float end[3];
    for (int i = 0; i < 3; i++)
        end[i] = eye[i] + dir[i] * maxDist;
    Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint,
                                    Bot_MoveFilter, view_as<any>(client));
    bool clear;
    if (!TR_DidHit(tr))
    {
        clear = true;
        hitDist = maxDist;
    }
    else
    {
        // 本 SM 版本无 TR_GetDistance；用命中分数 × 总长得到命中点距离。
        float frac = TR_GetFraction(tr);
        hitDist = frac * maxDist;
        clear = (hitDist >= ANH_MOVE_CLEAR_DIST);
    }
    delete tr;
    return clear;
}

// 墙滑：给定一个期望水平方向，返回旋转后"最通畅"的方向（绕 z 轴尝试若干角度）。
stock void Bot_SlideDir(int client, const float desired[3], float out[3])
{
    // 候选旋转角（度），0 原方向 + 两侧分步偏移，覆盖贴墙滑过的情况。
    int  rots[] = { 0, 55, -55, 110, -110, 165, -165 };
    float bestDir[3];
    bestDir[0] = desired[0]; bestDir[1] = desired[1]; bestDir[2] = 0.0;
    float bestClear = -1.0;
    bool  originClear = false;

    float sinr, cosr, d[3];
    for (int k = 0; k < sizeof(rots); k++)
    {
        float rad = rots[k] * (3.14159265 / 180.0);
        sinr = Sine(rad); cosr = Cosine(rad);
        // 绕 z 轴旋转水平向量
        d[0] = desired[0] * cosr - desired[1] * sinr;
        d[1] = desired[0] * sinr + desired[1] * cosr;
        d[2] = 0.0;

        float hit;
        if (Bot_TraceDir(client, d, ANH_MOVE_SLIDE_DIST, hit))
        {
            if (rots[k] == 0)
                originClear = true;
            if (hit > bestClear)
            {
                bestClear = hit;
                bestDir[0] = d[0]; bestDir[1] = d[1];
            }
        }
        else if (hit > bestClear)
        {
            // 被挡，但仍取"更通畅"的（命中点更远）作为次优。
            bestClear = hit;
            bestDir[0] = d[0]; bestDir[1] = d[1];
        }
    }

    if (originClear)
    {
        // 原方向通畅，直接用，避免无谓绕路。
        out[0] = desired[0]; out[1] = desired[1]; out[2] = 0.0;
    }
    else
    {
        out[0] = bestDir[0]; out[1] = bestDir[1]; out[2] = 0.0;
    }
}

// 把 bot 视角插值转向目标，写入 angles（OnPlayerRunCmd 的 viewangles）。
// 返回 true 表示已在开火误差内。
stock bool AimAt(int client, int target, float angles[3], bool &changed)
{
    float eye[3], aimPos[3];
    GetClientEyePosition(client, eye);
    Targ_AimPoint(target, aimPos);

    float dir[3];
    MakeVectorFromPoints(eye, aimPos, dir);
    float desired[3];
    GetVectorAngles(dir, desired);

    float cur[3];
    GetClientEyeAngles(client, cur);

    // yaw 需处理 ±180 环绕，pitch 用 GetAngleDifference 同理。
    // 瞄准插值随技能变化：高技能更跟手（更快收敛），低技能更迟钝。
    float lerp = g_fAimLerpBySkill[g_Bot[client].iSkill];
    float dYaw = Bot_AngleDiff(desired[1], cur[1]);
    float dPitch = Bot_AngleDiff(desired[0], cur[0]);

    cur[1] += dYaw * lerp;
    cur[0] += dPitch * lerp;

    angles[0] = cur[0];
    angles[1] = cur[1];
    angles[2] = 0.0;
    changed = true;

    // 开火允许误差随技能变化：高技能要求瞄得更准才开火（更少打偏）。
    float errDeg = g_fAimErrBySkill[g_Bot[client].iSkill];
    return (SquareRoot(dYaw * dYaw + dPitch * dPitch) <= errDeg);
}
