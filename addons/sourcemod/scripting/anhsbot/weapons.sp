/**
 * anhsbot/weapons.sp — 武器系统（全部基于真机逆向验证）
 *
 * 关键结论（ANHS server.dll，见 HANDOFF.md）：
 *  - GiveNamedItem = 玩家 vtable slot 400（RVA 0x2343e0）。sdktools 的 GivePlayerItem
 *    native 读 gamedata 的 GiveNamedItem，已在 custom/game.anhsource.txt 修正为 400。
 *    但它对 fake client 只把武器 spawn 在脚边、不装备（引擎 touch pickup 对 fake
 *    client 的物理 hull 不触发）。
 *  - WeaponEquip = 玩家 vtable slot 261（玩家重写 0x322580，内部调
 *    CBaseCombatCharacter::WeaponEquip 0x23e6f0 -> Weapon_AddToInventory 0x108990，
 *    把武器 handle 写进 m_hMyWeapons 空槽）。ZPS gamedata 的 272 在 ANHS 是武器射击
 *    音效函数，错误。
 *  - 故发武器必须 GivePlayerItem(...) 后立刻 SDKCall WeaponEquip(261)。
 *  - 切枪走 CUserCmd 的 weaponselect/subtype（OnPlayerRunCmd 里写 weapon/subtype 并
 *    return Plugin_Changed），不调 Weapon_Switch（zpsbot 实测 SDKCall 切枪会坏）。
 *
 * 已确认 ANHS 武器类名：weapon_smg1 / weapon_pistol / weapon_shotgun / weapon_357 /
 *  weapon_crowbar / weapon_stunstick / weapon_frag / weapon_slam / weapon_physcannon
 * （无 weapon_ar2）。
 */

// 玩家 vtable slot（32 位 sdk2013）
#define ANH_VT_SLOT_WEAPON_EQUIP   261

Handle g_hWeaponEquip = null;

// 人类 bot 标准 loadout（人类队伍 Rebels/Combine）。
// 重力枪 weapon_physcannon 出生自带，无需处理。
// 真机探针 wepprobe 验证 ANHS 共 44 把可生成武器；下表是其枪械子集（按偏好排序）。

// 主武器池（随机选一把，丰富火力；前面的在 Wep_ChooseBestGun 中优先选用）。
static const char g_szPrimaryPool[][] =
{
    "weapon_ar2", "weapon_ak47", "weapon_m4a1", "weapon_mp5", "weapon_ump45",
    "weapon_galil", "weapon_sg552", "weapon_smg1", "weapon_m249", "weapon_m3pump",
    "weapon_shotgun", "weapon_357", "weapon_crossbow", "weapon_scout", "weapon_dualies",
    "weapon_fiveseven", "weapon_glock", "weapon_p228", "weapon_pistolsilenced",
    "weapon_baikal56", "weapon_annabelle"
};

// 近战池（兜底/贴脸/补刀）。
static const char g_szMeleePool[][] =
{
    "weapon_crowbar", "weapon_stunstick", "weapon_knife", "weapon_axe",
    "weapon_cleaver", "weapon_sledgehammer", "weapon_bat", "weapon_hockeystick",
    "weapon_pipe", "weapon_pipewrench", "weapon_shovel", "weapon_pickaxe",
    "weapon_pitchfork", "weapon_hammer"
};

// 选枪优先级（=主武器池顺序；Wep_ChooseBestGun 按顺序取第一把有弹药的）。
#define g_szGunPriority g_szPrimaryPool

// 按实体索引记录每把武器首次见到时的"满弹夹"（give 后即满，作为补弹基准）。
int g_iMaxClip[4096];

// 换图后武器实体全部重建，清空弹夹基准（索引会复用）。
public void Wep_ResetForMap()
{
    for (int i = 0; i < sizeof(g_iMaxClip); i++)
        g_iMaxClip[i] = 0;
}

public void Wep_InitSDK()
{
    // thiscall(this=player, CBaseEntity *weapon) -> void，ret 4。
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetVirtual(ANH_VT_SLOT_WEAPON_EQUIP);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Plain);
    g_hWeaponEquip = EndPrepSDKCall();
}

// 给 bot 发一把武器并装备。返回武器实体（>0 成功），-1 失败。
public int Wep_GiveAndEquip(int client, const char[] className)
{
    int w = GivePlayerItem(client, className);
    if (w <= 0 || !IsValidEntity(w))
    {
        Dbg("Wep_GiveAndEquip GivePlayerItem(%d,%s) failed=%d", client, className, w);
        return -1;
    }

    if (g_hWeaponEquip != null)
        SDKCall(g_hWeaponEquip, client, w);

    // 记录满弹夹基准（刚 give 时是满的）。
    if (HasEntProp(w, Prop_Data, "m_iClip1"))
    {
        int clip = GetEntProp(w, Prop_Data, "m_iClip1");
        if (clip > 0)
            g_iMaxClip[w] = clip;
    }
    return w;
}

// 人类 bot 出生后发放标准装备：随机主武器一把 + 手枪（副武器必有）+ 随机近战一把。
// 已发放则跳过（由 g_Bot[client].bArmed 守门）。
public void Wep_EquipHumanLoadout(int client)
{
    int nPrim = sizeof(g_szPrimaryPool);

    // 主武器：随机挑一把能成功生成（GivePlayerItem 可能个别类失败，逐个尝试）。
    int order[MAXPLAYERS + 1];
    for (int i = 0; i < nPrim; i++) order[i] = i;
    for (int i = nPrim - 1; i > 0; i--)   // Fisher-Yates 打乱
    {
        int j = GetRandomInt(0, i);
        int t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (int k = 0; k < nPrim; k++)
    {
        int idx = order[k];
        if (Wep_FindByClass(client, g_szPrimaryPool[idx]) != -1)
            continue;
        if (Wep_GiveAndEquip(client, g_szPrimaryPool[idx]) > 0)
            break;
    }

    // 手枪：副武器兜底，必有。
    if (Wep_FindByClass(client, "weapon_pistol") == -1)
        Wep_GiveAndEquip(client, "weapon_pistol");

    // 近战：随机一把（贴脸/补刀/无子弹时）。
    if (Wep_GetMelee(client) == -1)
    {
        int idx = GetRandomInt(0, sizeof(g_szMeleePool) - 1);
        Wep_GiveAndEquip(client, g_szMeleePool[idx]);
    }
}

// 枚举 m_hMyWeapons，返回第一把类名匹配的武器实体，-1 无。
public int Wep_FindByClass(int client, const char[] className)
{
    if (!HasEntProp(client, Prop_Send, "m_hMyWeapons"))
        return -1;
    int max = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < max; i++)
    {
        int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (w <= 0 || !IsValidEntity(w))
            continue;
        char cls[64];
        if (GetEntityClassname(w, cls, sizeof(cls)) && StrEqual(cls, className, false))
            return w;
    }
    return -1;
}

public int Wep_GetActive(int client)
{
    int w = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
    return (w > 0 && IsValidEntity(w)) ? w : -1;
}

public int Wep_GetClip(int w)
{
    if (w <= 0 || !IsValidEntity(w) || !HasEntProp(w, Prop_Data, "m_iClip1"))
        return -1;
    return GetEntProp(w, Prop_Data, "m_iClip1");
}

// 选一把当前应优先使用的枪（有弹药）；无可用枪返回 -1。
public int Wep_ChooseBestGun(int client)
{
    for (int i = 0; i < sizeof(g_szGunPriority); i++)
    {
        int w = Wep_FindByClass(client, g_szGunPriority[i]);
        if (w == -1)
            continue;
        // 弹夹还有子弹即可选；弹夹空则交给补弹逻辑，期间降级到下一把。
        if (Wep_GetClip(w) != 0)
            return w;
    }
    return -1;
}

// 近战兜底（子弹打光/贴脸时）。
public int Wep_GetMelee(int client)
{
    int w = Wep_FindByClass(client, "weapon_crowbar");
    if (w != -1)
        return w;
    return Wep_FindByClass(client, "weapon_stunstick");
}

// 请求在 CUserCmd 里切到指定武器（引擎下一帧处理）。
public void Wep_RequestSwitch(int client, int w)
{
    if (w <= 0 || !IsValidEntity(w))
    {
        g_Bot[client].iWantWeapon = 0;
        return;
    }
    g_Bot[client].iWantWeapon = w;
    g_Bot[client].iWantSubtype = HasEntProp(w, Prop_Data, "m_iSubType")
        ? GetEntProp(w, Prop_Data, "m_iSubType") : 0;
}

// 换枪是否已落地。
public bool Wep_SwitchDone(int client)
{
    int want = g_Bot[client].iWantWeapon;
    if (want <= 0)
        return true;
    return (Wep_GetActive(client) == want);
}

// 补弹：弹夹低于阈值补满 + 备弹充足。低频调用（看门狗/计时器）。
public void Wep_Refill(int client)
{
    if (!HasEntProp(client, Prop_Send, "m_hMyWeapons"))
        return;
    int max = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < max; i++)
    {
        int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (w <= 0 || !IsValidEntity(w))
            continue;
        if (!HasEntProp(w, Prop_Data, "m_iClip1"))
            continue;

        int maxClip = g_iMaxClip[w];
        if (maxClip <= 0)
        {
            // 未记录基准（如出生自带 physcannon）：当前 clip>0 时学一次。
            int c = GetEntProp(w, Prop_Data, "m_iClip1");
            if (c > 0)
                g_iMaxClip[w] = c;
            continue;
        }

        int clip = GetEntProp(w, Prop_Data, "m_iClip1");
        if (clip < maxClip)
            SetEntProp(w, Prop_Data, "m_iClip1", maxClip);

        // 备弹：写玩家 m_iAmmo[type]。
        if (HasEntProp(w, Prop_Data, "m_iPrimaryAmmoType"))
        {
            int at = GetEntProp(w, Prop_Data, "m_iPrimaryAmmoType");
            if (at >= 0 && at < 32 && HasEntProp(client, Prop_Send, "m_iAmmo"))
                SetEntProp(client, Prop_Send, "m_iAmmo", 999, _, at);
        }
    }
}
