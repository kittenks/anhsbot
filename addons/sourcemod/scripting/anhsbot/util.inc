/**
 * anhsbot/util.inc — 工具函数
 */

// 仅在调试 cvar 开启时输出
stock void Dbg(const char[] fmt, any ...)
{
    if (g_cvDebug == null || !g_cvDebug.BoolValue)
        return;
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    PrintToServer("[anhsbot] %s", buf);
}

stock void Log(const char[] fmt, any ...)
{
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    PrintToServer("[anhsbot] %s", buf);
}

// 读 m_fFlags
stock int GetPlayerFlags(int client)
{
    return GetEntProp(client, Prop_Send, "m_fFlags");
}

// 写 m_fFlags（整值）
stock void SetPlayerFlags(int client, int flags)
{
    SetEntProp(client, Prop_Send, "m_fFlags", flags);
}

// 确保盖上 FL_FAKECLIENT；返回是否发生了写入
stock bool EnsureFakeClientFlag(int client)
{
    int flags = GetPlayerFlags(client);
    if (flags & ANH_FL_FAKECLIENT)
        return false;
    SetPlayerFlags(client, flags | ANH_FL_FAKECLIENT);
    return true;
}

stock bool Bot_IsAlive(int client)
{
    return IsClientInGame(client)
        && GetEntProp(client, Prop_Data, "m_lifeState") == LIFE_ALIVE;
}

// 统计本插件管理的在线 bot 数（含重建中的，避免 autofill 与重建竞争）
stock int CountManagedBots()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && (g_Bot[i].bManaged || g_Bot[i].bRebuilding))
            n++;
    }
    return n;
}
