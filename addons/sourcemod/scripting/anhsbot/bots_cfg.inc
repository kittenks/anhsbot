/**
 * anhsbot/bots_cfg.inc — 机器人名字池配置解析
 *
 * 配置文件：addons/sourcemod/configs/anhsbot_bots.cfg（SourceMod 的 configs 目录，
 * 与 AutoExecConfig 生成的 plugin.anhsbot.cfg 所在的 cfg/sourcemod/ 分开，避免冲突）
 * 每行：<名字> <技能等级 0..3>。空行 / 以 // 或 # 开头忽略。
 * 插件按游标轮询取名，并赋予该名字对应的技能等级。
 */

stock int BotsCfg_Load()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/anhsbot_bots.cfg");

    g_iNamePoolCount = 0;
    g_iNameCursor = 0;

    File f = OpenFile(path, "r");
    if (f == null)
    {
        Log("[anhsbot] bots cfg not found: %s (will use default names)", path);
        return 0;
    }

    char line[128];
    while (g_iNamePoolCount < ANH_NAMEPOOL_MAX && ReadFileLine(f, line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '/' || line[0] == '#')
            continue;

        // 拆分：第一段=名字，第二段=技能（可选，默认 1）
        char name[64];  name[0] = '\0';
        char tmp[2][64];
        int tok = 0;
        int len = strlen(line);
        int start = 0;
        for (int i = 0; i <= len && tok < 2; i++)
        {
            if (i == len || IsCharSpace(line[i]))
            {
                if (i > start)
                {
                    int n = i - start;
                    if (n > 63) n = 63;
                    strcopy(tmp[tok], n + 1, line[start]);
                    tok++;
                }
                start = i + 1;
            }
        }
        if (tok < 1) continue;
        strcopy(name, sizeof(name), tmp[0]);
        int skill = (tok >= 2) ? StringToInt(tmp[1]) : 1;
        if (skill < 0) skill = 0;
        if (skill > ANH_SKILL_MAX) skill = ANH_SKILL_MAX;

        strcopy(g_szNamePool[g_iNamePoolCount], 64, name);
        g_iNamePoolSkill[g_iNamePoolCount] = skill;
        g_iNamePoolCount++;
    }
    delete f;
    Log("[anhsbot] loaded %d bot names from cfg", g_iNamePoolCount);
    return g_iNamePoolCount;
}

// 轮询取一个名字 + 技能。池为空则回退默认名（调用方负责名字唯一性处理）。
stock void BotsCfg_Pick(char name[64], int &skill)
{
    if (g_iNamePoolCount <= 0)
    {
        name[0] = '\0';
        skill = (g_cvSkill != null) ? g_cvSkill.IntValue : 1;
        return;
    }
    strcopy(name, 64, g_szNamePool[g_iNameCursor]);
    skill = g_iNamePoolSkill[g_iNameCursor];
    g_iNameCursor = (g_iNameCursor + 1) % g_iNamePoolCount;
}
