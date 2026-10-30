/**
 * anhsbot/targeting.sp — 索敌系统（人类 bot）
 *
 * 敌人集合（ANHS 僵尸 FPS）：
 *  - 玩家：僵尸队 team4（僵尸模式下与人类 2/3 对立）；HL2MP 原生 Rebels(2) 与
 *    Combine(3) 互为敌方，也判定为敌对（射击场可放双队 bot 互射验证）。
 *  - 敌对 NPC：遍历实体索引 + GetEntityClassname（FindEntityByClassname 的
 *    "weapon_"/"npc_" 前缀枚举在 ANHS 不可靠，已实证）。命中敌对类名表，或
 *    m_iTeamNum 与 bot 敌对的 npc_* 都算目标。
 *
 * 性能（重要，踩过的坑）：
 *  - 【脚本执行超时】早期版本每个 bot 每次重选目标都全图扫实体并对每个敌对
 *    NPC 做一次 TR_TraceRayFilterEx。多个 bot 同时出生会让重选时刻对齐，
 *    同一 tick 内堆出上千次 trace → SM "Script execution timed out"。
 *    现在改为：全局 NPC 缓存（每 ANH_CACHE_TTL 秒重建一次，与队伍无关，
 *    避免多队 bot 互相刷新）+ 只对距离最近的少数候选做 LOS。
 *  - 【瞄准打空】NPC 位置必须读 m_vecAbsOrigin(datamap 640)，
 *    不能读 m_vecOrigin(776) —— 后者是父物体相对坐标，实测 X 分量不可信。
 *    详见 Targ_AimPoint 注释。
 */

// 敌对 NPC 类名表（命中即视为目标，子串包含匹配，覆盖 npc_zombie / npc_zombie_torso 等）。
static const char g_szHostileNPC[][] =
{
    "npc_zombie",
    "npc_fastzombie",
    "npc_poisonzombie",
    "npc_headcrab",
    "npc_manhack",
    "npc_combine",
    "npc_metropolice",
    "npc_hunter",
    "npc_antlion",
    "npc_houndeye",
    "npc_turret"
};

// ---- 全局 NPC 缓存（防脚本超时的核心）----
#define ANH_MAX_CACHE   512        // 缓存的 npc_* 条目上限
#define ANH_CACHE_TTL   0.4        // 缓存重建间隔（秒）
#define ANH_MAX_LOS     8          // 每次索敌最多做多少次 LOS 追踪

int   g_iCacheEnt[ANH_MAX_CACHE];
float g_fCachePos[ANH_MAX_CACHE][3];
int   g_iCacheTeam[ANH_MAX_CACHE];
int   g_iCacheCount = 0;
float g_fCacheAt = -1.0;

// 玩家队伍是否敌对。
// teamplay 开启（anhsbot_teamplay=1，默认）：幸存者 2/3 视为同一阵营，不互杀；
// 关闭：2/3 互敌（HL2MP 原生，射击场双队互射验证用）。
public bool Targ_TeamsEnemy(int myTeam, int otherTeam)
{
    if (otherTeam == TEAM_SPECTATOR || otherTeam == 0)
        return false;
    if (myTeam == TEAM_ZOMBIE)
        return (otherTeam == TEAM_REBELS || otherTeam == TEAM_COMBINE);
    // 人类 bot：僵尸队是敌人；Rebels/Combine 是否互敌取决于 teamplay 开关。
    if (otherTeam == TEAM_ZOMBIE)
        return true;
    if (Targ_SameSide(myTeam, otherTeam))
        return false;
    return (myTeam != otherTeam);
}

// 是否同一阵营（队友）。teamplay 开启时 2/3（幸存者）互认为队友。
public bool Targ_SameSide(int myTeam, int otherTeam)
{
    if (myTeam == otherTeam)
        return true;
    if (g_cvTeamplay != null && g_cvTeamplay.BoolValue)
    {
        if (myTeam >= TEAM_REBELS && myTeam <= TEAM_COMBINE
            && otherTeam >= TEAM_REBELS && otherTeam <= TEAM_COMBINE)
            return true;
    }
    return false;
}

// 找最近的同阵营玩家（空闲集结用）。返回 client 索引，0 = 无。
public int Targ_FindTeammate(int client, float maxDist)
{
    int myTeam = GetClientTeam(client);
    float myPos[3];
    GetClientAbsOrigin(client, myPos);

    int best = 0;
    float bestD = maxDist * maxDist;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !IsClientInGame(i))
            continue;
        if (!Targ_Alive(i))
            continue;
        if (!Targ_SameSide(myTeam, GetClientTeam(i)))
            continue;
        float p[3];
        GetClientAbsOrigin(i, p);
        float dx = p[0] - myPos[0], dy = p[1] - myPos[1], dz = p[2] - myPos[2];
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD)
        {
            bestD = d2;
            best = i;
        }
    }
    return best;
}

// 弹道（eye → aim）是否被队友遮挡（防友伤）。返回 true = 有队友挡线，本帧应放弃开火。
// 过滤器：玩家实体（除自己）挡线，其余实体不挡；世界( entity 0 )由 MASK_SHOT 正常处理。
public bool Targ_FriendlyBlock(int client, int targetEnt, const float aimPos[3])
{
    if (g_cvTeamplay == null || !g_cvTeamplay.BoolValue)
        return false;
    int myTeam = GetClientTeam(client);
    float eye[3];
    GetClientEyePosition(client, eye);
    Handle tr = TR_TraceRayFilterEx(eye, aimPos, MASK_SHOT, RayType_EndPoint,
                                    Targ_FriendlyFilter, view_as<any>(client));
    bool blocked = false;
    if (TR_DidHit(tr))
    {
        int hit = TR_GetEntityIndex(tr);
        if (hit > 0 && hit <= MaxClients && hit != client && hit != targetEnt
            && Targ_SameSide(myTeam, GetClientTeam(hit)))
        {
            blocked = true;
        }
    }
    delete tr;
    return blocked;
}

public bool Targ_FriendlyFilter(int entity, int contentsMask, any data)
{
    int self = view_as<int>(data);
    if (entity == self)
        return false;
    if (entity > MaxClients)
        return false;   // 非玩家实体不参与友伤判定
    return true;
}

// 实体是否为敌对 NPC（类名表 + 队伍兜底）。
public bool Targ_IsHostileNPC(int ent, int myTeam)
{
    char cls[64];
    if (!GetEntityClassname(ent, cls, sizeof(cls)))
        return false;
    if (strncmp(cls, "npc_", 4) != 0)
        return false;

    for (int i = 0; i < sizeof(g_szHostileNPC); i++)
    {
        if (StrContains(cls, g_szHostileNPC[i], false) == 0)
            return true;
    }
    // 队伍兜底：有 m_iTeamNum 且与 bot 敌对也打。
    if (HasEntProp(ent, Prop_Data, "m_iTeamNum"))
    {
        int t = GetEntProp(ent, Prop_Data, "m_iTeamNum");
        if (t >= 2 && t <= 4 && Targ_TeamsEnemy(myTeam, t))
            return true;
    }
    return false;
}

// 目标存活判定（玩家用 lifeState，NPC 用 health/生命状态）。
public bool Targ_Alive(int ent)
{
    if (ent >= 1 && ent <= MaxClients)
        return IsClientInGame(ent) && Bot_IsAlive(ent);
    if (HasEntProp(ent, Prop_Data, "m_lifeState"))
    {
        if (GetEntProp(ent, Prop_Data, "m_lifeState") != LIFE_ALIVE)
            return false;
    }
    if (HasEntProp(ent, Prop_Data, "m_iHealth"))
    {
        if (GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
            return false;
    }
    return true;
}

// 实体世界坐标。NPC 必须用 m_vecAbsOrigin，见 Targ_AimPoint 注释。
public void Targ_EntityPos(int ent, float out[3])
{
    if (ent >= 1 && ent <= MaxClients)
    {
        GetClientAbsOrigin(ent, out);
        return;
    }
    if (HasEntProp(ent, Prop_Data, "m_vecAbsOrigin"))
        GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", out);
    else
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", out);
}

// 目标（玩家或 NPC）的瞄准点（近似眼/胸高度）。
//
// 【实测坑】ANHS 的 NPC 上 m_vecOrigin（datamap 偏移 776）不可信：
// 脚本生成的 npc_zombie 读出来 X 是 NaN，地图僵尸读出来 X 恒为 0（y/z 正常）。
// 它是"父物体相对坐标"；权威世界坐标是 m_vecAbsOrigin（偏移 640）。
// 读错字段会让 bot 瞄向幻影位置 → 子弹全空。玩家走 GetClientEyePosition，
// 不受影响。实测修正后 bot 能对 npc_fastzombie 造成 45 点伤害。
public void Targ_AimPoint(int ent, float out[3])
{
    if (ent >= 1 && ent <= MaxClients)
    {
        GetClientEyePosition(ent, out);
        return;
    }
    Targ_EntityPos(ent, out);
    // 无眼睛高度的 NPC 打躯干中上部。
    out[2] += 48.0;
}

// 视线过滤器：忽略 bot 自身与掉落武器，其余（含墙、地形、第三方实体）阻挡。
public bool Targ_TraceFilter(int entity, int contentsMask, any data)
{
    int self = view_as<int>(data);
    if (entity == self)
        return false;
    if (entity > MaxClients)
    {
        // 武器/挂件不挡视线；NPC 实体挡视线（误射会打到它）。
        char cls[64];
        if (GetEntityClassname(entity, cls, sizeof(cls))
            && strncmp(cls, "weapon_", 7) == 0)
        {
            return false;
        }
    }
    return true;
}

public bool Targ_HasLOS(int client, int targetEnt, const float target[3])
{
    float eye[3];
    GetClientEyePosition(client, eye);
    Handle tr = TR_TraceRayFilterEx(eye, target, MASK_SHOT, RayType_EndPoint,
        Targ_TraceFilter, view_as<any>(client));
    bool visible;
    if (!TR_DidHit(tr))
    {
        // 终点未撞到任何实体（落在目标内部/贴脸）：可见。
        visible = true;
    }
    else
    {
        // 命中的第一个实体就是目标本身：可见；否则被墙/第三方挡住。
        visible = (TR_GetEntityIndex(tr) == targetEnt);
    }
    delete tr;
    return visible;
}

// 前方视野锥：目标方向与 bot 视角前向的夹角余弦是否达标。
public bool Targ_InViewCone(int client, const float targetPos[3])
{
    float eye[3], ang[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    float fwd[3];
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);

    float dir[3];
    MakeVectorFromPoints(eye, targetPos, dir);
    NormalizeVector(dir, dir);
    float dot = GetVectorDotProduct(fwd, dir);
    // 近目标放宽视角（转身成本低）；这里统一用固定阈值。
    return (dot >= -0.6); // 先放宽到接近全向，保证能发现；瞄准插值负责转身
}

// ---- 全局 NPC 缓存 ----

// 重建缓存：扫一遍实体索引，只留存活的 npc_*（与队伍无关，多队 bot 共用）。
public void Targ_RebuildCache()
{
    g_iCacheCount = 0;
    int total = GetEntityCount();
    // 上限 2048：足以覆盖任意地图（NPC 实体数远小于此，且 2048 远高于本图实测的
    // 349+ 生成索引，避免"漏掉高索引 NPC"；同时远小于整张实体数组(4000+)，
    // 防止单次全量扫描触发 SourcePawn 脚本超时看门狗。
    if (total > 2048)
        total = 2048;

    for (int e = MaxClients + 1; e < total; e++)
    {
        if (g_iCacheCount >= ANH_MAX_CACHE)
            break;
        if (!IsValidEntity(e))
            continue;
        char cls[64];
        if (!GetEntityClassname(e, cls, sizeof(cls)))
            continue;
        if (strncmp(cls, "npc_", 4) != 0)
            continue;
        if (!Targ_Alive(e))
            continue;
        // 存 entity reference（而非裸索引）：缓存 TTL 内 NPC 死亡/被移除后，
        // 裸索引会失效甚至被新实体复用；EntRefToEntIndex 能区分这两种情况。
        g_iCacheEnt[g_iCacheCount] = EntIndexToEntRef(e);
        Targ_EntityPos(e, g_fCachePos[g_iCacheCount]);
        g_iCacheTeam[g_iCacheCount] =
            HasEntProp(e, Prop_Data, "m_iTeamNum")
                ? GetEntProp(e, Prop_Data, "m_iTeamNum") : 0;
        g_iCacheCount++;
    }
    g_fCacheAt = GetGameTime();
    Dbg("Targ_RebuildCache entities=%d npcCached=%d", total, g_iCacheCount);
}

// 缓存条目对某队伍是否敌对（类名表命中即敌对，否则看队伍）。
public bool Targ_CacheEntryHostile(int idx, int myTeam)
{
    // 缓存的是 ent ref；NPC 可能在 TTL 内死亡/被移除，必须先还原并校验。
    int ent = EntRefToEntIndex(g_iCacheEnt[idx]);
    if (ent == -1 || !IsValidEntity(ent))
        return false;
    char cls[64];
    if (!GetEntityClassname(ent, cls, sizeof(cls)))
        return false;
    for (int i = 0; i < sizeof(g_szHostileNPC); i++)
    {
        if (StrContains(cls, g_szHostileNPC[i], false) == 0)
            return true;
    }
    int t = g_iCacheTeam[idx];
    return (t >= 2 && t <= 4 && Targ_TeamsEnemy(myTeam, t));
}

// 选最佳目标：距离最近、存活、有 LOS 的敌人。返回实体，0 无。
public int Targ_FindBest(int client)
{
    int myTeam = GetClientTeam(client);
    float myEye[3];
    GetClientEyePosition(client, myEye);

    // 缓存刷新（TTL 到期或首次）。与队伍无关，多 bot 共用，避免同时全图扫描。
    float now = GetGameTime();
    if (g_iCacheCount <= 0 || now - g_fCacheAt > ANH_CACHE_TTL)
        Targ_RebuildCache();

    int best = 0;
    // 【单位制注意】下方所有距离比较都用平方距离（GetVectorDistance(...,true)），
    // 所以 bestDist 也必须用平方值，否则会把 2500 当成"2500 平方单位=50 单位"，
    // 导致几乎所有远于 50 单位的目标被拒（实测 tgt 恒为 0 的根因）。
    float bestDist = ANH_FOV_HUMAN * ANH_FOV_HUMAN;

    // 1) 玩家目标（数量少，直接遍历）。
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !IsClientInGame(i))
            continue;
        if (!Targ_Alive(i))
            continue;
        if (!Targ_TeamsEnemy(myTeam, GetClientTeam(i)))
            continue;
        float aim[3];
        Targ_AimPoint(i, aim);
        float dist = GetVectorDistance(myEye, aim, true);
        if (dist >= bestDist)
            continue;
        if (!Targ_HasLOS(client, i, aim))
            continue;
        best = i;
        bestDist = dist;
    }

    // 2) 敌对 NPC：先从缓存挑出最近的若干个候选（无 trace），再逐个验 LOS。
    //    避免"每个敌对 NPC 都做一次 trace"导致的脚本超时。
    int cand[ANH_MAX_LOS];
    float candDist[ANH_MAX_LOS];
    int nCand = 0;
    float npcRangeSq = ANH_FOV_NPC * ANH_FOV_NPC;

    for (int c = 0; c < g_iCacheCount; c++)
    {
        if (!Targ_CacheEntryHostile(c, myTeam))
            continue;
        float d = GetVectorDistance(myEye, g_fCachePos[c], true);
        if (d >= npcRangeSq)
            continue;
        // 插入排序维护"最近的 ANH_MAX_LOS 个"
        if (nCand < ANH_MAX_LOS)
        {
            cand[nCand] = c;
            candDist[nCand] = d;
            nCand++;
            // 冒泡到正确位置
            for (int k = nCand - 1; k > 0 && candDist[k] < candDist[k-1]; k--)
            {
                int te = cand[k]; cand[k] = cand[k-1]; cand[k-1] = te;
                float td = candDist[k]; candDist[k] = candDist[k-1]; candDist[k-1] = td;
            }
        }
        else if (d < candDist[nCand-1])
        {
            cand[nCand-1] = c;
            candDist[nCand-1] = d;
            for (int k = nCand - 1; k > 0 && candDist[k] < candDist[k-1]; k--)
            {
                int te = cand[k]; cand[k] = cand[k-1]; cand[k-1] = te;
                float td = candDist[k]; candDist[k] = candDist[k-1]; candDist[k-1] = td;
            }
        }
    }

    // 只对最近的候选做 LOS（最多 ANH_MAX_LOS 次 trace）
    for (int k = 0; k < nCand; k++)
    {
        int c = cand[k];
        // 第一遍筛选到这里之间实体可能已失效，再校验一次。
        int ent = EntRefToEntIndex(g_iCacheEnt[c]);
        if (ent == -1 || !IsValidEntity(ent) || !Targ_Alive(ent))
            continue;
        float aim[3];
        aim = g_fCachePos[c];
        aim[2] += 48.0;
        if (!Targ_HasLOS(client, ent, aim))
            continue;
        if (candDist[k] < bestDist)
        {
            best = ent;
            bestDist = candDist[k];
        }
    }

    return best;
}

// 缓存目标失效检测（死了、断开、没视线超过容忍则丢弃）。
public bool Targ_StillValid(int client, int target)
{
    if (target <= 0 || !IsValidEntity(target))
        return false;
    if (!Targ_Alive(target))
        return false;
    if (target <= MaxClients)
    {
        if (!Targ_TeamsEnemy(GetClientTeam(client), GetClientTeam(target)))
            return false;
    }
    return true;
}
