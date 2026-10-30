/**
 * anhsbot/nav.inc — V社 .nav(v16) 解析 + A* 寻路 + 路径跟随 + 危险区规避
 *
 * 背景：
 *  - SM 1.12 无 navmesh.inc / TheNavMesh natives，导航必须自写。
 *  - ANHS 自带完整 Valve 导航系统：nav_generate 可为 26 张无 nav 地图现场烘焙，
 *    本插件只消费 .nav，不生成。
 *  - v16 二进制布局由 tools/navparse.py 离线反推验证（802 areas 精确到 EOF，
 *    hidingSize=17B、MAX_NAV_TEAMS=2 为唯一解），本文件按同一布局解析。
 *    11 张图全部 v16；area 数最大 4514（anm_story1_set1）。
 *
 * 图结构：
 *  - 两遍读文件：第一遍记每 area 中心/包围盒/id，第二遍把连接 id 解析为索引
 *    （id 非稠密，排序 + 二分映射）并建 CSR 有向邻接。
 *  - 每 area 段内去重；连接按垂直差过滤（NAV_MAX_Z_STEP）防跳崖；
 *    梯子连接段直接跳过（bot 移动模型不走梯子）。
 *
 * A*：二叉堆优先队列（懒删除），启发 = 中心水平距。路径按 bot 缓存，
 * 低频重算（NAV_REPATH_INTERVAL），目标位移 > NAV_GOAL_EPSILON 或路径过期才重算；
 * 寻路失败也记时退避，避免每帧重跑 A*。
 *
 * 危险区（trigger_hurt 等）：低频枚举缓存球体近似，路径方向直穿危险区时侧移规避。
 */

#define NAV_MAGIC           0xFEEDFACE
#define NAV_VERSION         16
#define NAV_MAX_AREAS       8192        // 实测最大 4514
#define NAV_MAX_CONNS       262144      // 连接条目总数上限
#define NAV_MAX_EDGES       262144      // CSR 有向边上限
#define NAV_MAX_PATH        128         // 单条路径最大 waypoint 数
#define NAV_HIDING_SIZE     17          // v16: uint id + vec3 pos + uchar flags
#define NAV_MAX_TEAMS       2
#define NAV_MAX_Z_STEP      90.0        // 可达连接最大垂直差（防跳崖）
#define NAV_WAYPOINT_RADIUS 56.0        // 判定"已到达 waypoint"的水平距离
#define NAV_REPATH_INTERVAL 0.6         // 同 bot 两次 A* 最小间隔（秒）
#define NAV_GOAL_EPSILON    128.0       // 目标位移小于此值不重算路径
#define NAV_PATH_MAX_AGE    4.0         // 路径保质期（秒）

// 危险区（trigger_hurt 等）
#define NAV_MAX_DANGER      96
#define NAV_DANGER_DEFAULT_R 48.0
#define NAV_DANGER_SCAN_TTL 5.0

// 诅咒区域（动态几何陷阱：nav 生成时开着的门/路障，运行时关闭把 bot 夹住）
// ant_deadend_drive 实测：bot 走进关闭的门 → hull 嵌进几何体 → vel 有值但
// 零位移、m_hGroundEntity=0、TeleportEntity 对 fake client 无效。对策：
// 卡住时诅咒"当前所在 + 正在追赶的 waypoint"两个 area，A* 绕开；TTL 到期
// 自动解咒（门可能重开）。同时卡住看门狗会重建 bot 挪出陷阱（见 bot.sp）。
#define NAV_CURSE_TTL       90.0     // 诅咒有效期（秒）
#define NAV_CURSE_MAX       512      // 同时诅咒上限（防呆：避免全图毒化)

bool  g_bNavLoaded = false;
int   g_iNavAreas  = 0;

int   g_iNavId[NAV_MAX_AREAS];          // 文件序 → area id
float g_fNavC[NAV_MAX_AREAS][3];        // area 中心
float g_fNavMinX[NAV_MAX_AREAS];
float g_fNavMinY[NAV_MAX_AREAS];
float g_fNavMaxX[NAV_MAX_AREAS];
float g_fNavMaxY[NAV_MAX_AREAS];

// id → 索引（排序数组 + 二分）
int   g_iNavSortId[NAV_MAX_AREAS];
int   g_iNavSortIdx[NAV_MAX_AREAS];

// 连接平铺数组（第二遍读文件填充为索引）
int   g_iNavConnOff[NAV_MAX_AREAS + 1];
int   g_iNavConn[NAV_MAX_CONNS];

// CSR 有向邻接
int   g_iNavEdgeOff[NAV_MAX_AREAS + 1];
int   g_iNavEdgeTo[NAV_MAX_EDGES];
int   g_iNavEdges = 0;

// A* scratch（单线程，一次一条路径）。堆数组按最坏情况（懒删除）开到边数级。
float g_fAStarG[NAV_MAX_AREAS];
int   g_iAStarFrom[NAV_MAX_AREAS];
bool  g_bAStarClosed[NAV_MAX_AREAS];
int   g_iHeap[NAV_MAX_EDGES + 8];
float g_fHeapKey[NAV_MAX_EDGES + 8];
int   g_iHeapSize = 0;

// 每 bot 路径状态
int   g_iPathLen[MAXPLAYERS + 1];
int   g_iPathCur[MAXPLAYERS + 1];
int   g_iPathNode[MAXPLAYERS + 1][NAV_MAX_PATH];
float g_fPathGoalX[MAXPLAYERS + 1];
float g_fPathGoalY[MAXPLAYERS + 1];
float g_fPathGoalZ[MAXPLAYERS + 1];
float g_fPathAt[MAXPLAYERS + 1];
float g_fPathBorn[MAXPLAYERS + 1];

// 危险区缓存
int   g_iDangerCount = 0;
float g_fDangerPos[NAV_MAX_DANGER][3];
float g_fDangerR[NAV_MAX_DANGER];
float g_fDangerScanAt = -10.0;

// 诅咒区域缓存
bool   g_bNavCursed[NAV_MAX_AREAS];
float  g_fNavCursedAt[NAV_MAX_AREAS];
int    g_iNavCursedCount = 0;

public void Nav_Reset()
{
    g_bNavLoaded   = false;
    g_iNavAreas    = 0;
    g_iNavEdges    = 0;
    g_iDangerCount = 0;
    g_iNavCursedCount = 0;
    for (int i = 0; i < NAV_MAX_AREAS; i++)
        g_bNavCursed[i] = false;
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_iPathLen[i]  = 0;
        g_iPathCur[i]  = 0;
        g_fPathAt[i]   = 0.0;
        g_fPathBorn[i] = 0.0;
    }
}

// 定位当前地图的 .nav 文件，写入 outPath。多候选（本机实测 Path_SM 可能返回
// 相对路径 addons\sourcemod\x，单一截断策略会失败）：
//  1) Path_SM 截掉 /addons/sourcemod 得游戏根（绝对安装）；
//  2) 引擎搜索路径相对形式 maps/<map>.nav（mod 目录为搜索根，SM 的 OpenFile
//     走引擎文件系统，能解析——BotsCfg_Load 的相对路径同样因此生效）。
stock bool Nav_FindNavFile(const char[] map, char[] outPath, int size)
{
    char sm[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sm, sizeof(sm), "x");

    // 定位 mod 根（截断 /addons/sourcemod）
    char root[PLATFORM_MAX_PATH];
    root[0] = '\0';
    int idx = StrContains(sm, "/addons/sourcemod");
    if (idx == -1)
        idx = StrContains(sm, "\\addons\\sourcemod");
    if (idx > 0)
    {
        strcopy(root, sizeof(root), sm);
        root[idx] = '\0';
    }

    // 关键：同一份 .nav 会被两套系统加载——
    //   ① 引擎 CNavMesh（NPC 僵尸寻路）在地图激活时自动加载 maps/<map>.nav，
    //      对 area 几何/连接要求严格，离线网格采样的规则方块会让它卡死/崩溃；
    //   ② 本插件 nav.inc 自己解析 .nav 做 A*。
    // 故离线烘焙产物放到 maps/anhsbot/<map>.nav（引擎只按精确名 maps/<map>.nav
    // 加载，不扫描该子目录），避免引擎加载；官方烘焙图仍用 maps/<map>.nav。
    // 候选 1：官方 maps/<map>.nav（引擎与插件共用，几何最可靠）
    // 候选 2：离线烘焙 maps/anhsbot/<map>.nav（仅插件读取）
    char rel[2][128];
    Format(rel[0], sizeof(rel[]), "maps/%s.nav", map);
    Format(rel[1], sizeof(rel[]), "maps/anhsbot/%s.nav", map);

    for (int c = 0; c < 2; c++)
    {
        if (root[0] != '\0')
        {
            Format(outPath, size, "%s/%s", root, rel[c]);
            File fa = OpenFile(outPath, "rb");
            if (fa != null)
            {
                delete fa;
                return true;
            }
        }
        Format(outPath, size, "%s", rel[c]);
        File fb = OpenFile(outPath, "rb");
        if (fb != null)
        {
            delete fb;
            return true;
        }
    }
    return false;
}

// SM 1.12 的 File 类没有 ReadFloat：读 4 字节 int32 位模式，view_as<float> 重组。
// nav 文件是 x86 little-endian，与 SourcePawn 单元格字节序一致，可直接 reinterpret。
stock bool Nav_ReadFloat(File f, float &out)
{
    int bits;
    if (!f.ReadInt32(bits))
        return false;
    out = view_as<float>(bits);
    return true;
}

// 跳过 n 字节（Read 需要 int[] 缓冲；char[] 传给 any[] 参数编译不过）。
stock void Nav_Skip(File f, int n)
{
    int scratch[512];
    while (n > 0)
    {
        int chunk = (n > sizeof(scratch)) ? sizeof(scratch) : n;
        if (f.Read(scratch, chunk, 1) <= 0)
            return;   // EOF/读失败：交给后续读取的 false 处理
        n -= chunk;
    }
}

stock bool Nav_ReadVec3(File f, float out[3])
{
    return Nav_ReadFloat(f, out[0]) && Nav_ReadFloat(f, out[1]) && Nav_ReadFloat(f, out[2]);
}

// 从当前位置解析一个 area 的固定前缀（id/属性/角落/高度），返回 false = EOF/损坏。
stock bool Nav_ReadAreaHead(File f, int &id, float nw[3], float se[3], float &neZ, float &swZ)
{
    int attr;
    if (!f.ReadInt32(id))
        return false;
    f.ReadInt32(attr);
    if (!Nav_ReadVec3(f, nw) || !Nav_ReadVec3(f, se))
        return false;
    if (!Nav_ReadFloat(f, neZ) || !Nav_ReadFloat(f, swZ))
        return false;
    return true;
}

// 跳过 4 方向连接段。collect=false 只跳过；collect=true 把连接 id 收集进 ids[]。
// 注意：SourcePawn 数组参数必须显式尺寸或用 any[]；这里两种尺寸的调用方
// （pass1 的 idsScratch[1] 与 pass2 的 ids[256]）都走 any[] 入口。
stock bool Nav_ScanConns(File f, bool collect, any[] ids, int idsCap, int &connTotal)
{
    int total = 0;
    for (int d = 0; d < 4; d++)
    {
        int c;
        if (!f.ReadInt32(c) || c < 0)
            return false;
        for (int k = 0; k < c; k++)
        {
            int cid;
            if (!f.ReadInt32(cid))
                return false;
            if (collect && total < idsCap)
                ids[total] = cid;
            total++;
        }
    }
    connTotal = total;
    return true;
}

// 跳过 area 的剩余段（hiding/encounters/place/ladder/occupy/light/vis/inherit）。
stock bool Nav_SkipAreaTail(File f)
{
    int hid;
    f.ReadInt8(hid);
    Nav_Skip(f, hid * NAV_HIDING_SIZE);

    int enc;
    f.ReadInt32(enc);
    for (int e = 0; e < enc; e++)
    {
        Nav_Skip(f, 4 + 1 + 4 + 1);
        int sc;
        f.ReadInt8(sc);
        Nav_Skip(f, sc * (4 + 1));
    }

    int placeIdx;
    f.ReadInt16(placeIdx);

    for (int l = 0; l < 2; l++)   // ladder up/down
    {
        int lc;
        f.ReadInt32(lc);
        Nav_Skip(f, lc * 4);
    }
    Nav_Skip(f, NAV_MAX_TEAMS * 4);   // earliestOccupyTime
    Nav_Skip(f, 4 * 4);               // lightIntensity

    int vis;
    f.ReadInt32(vis);
    Nav_Skip(f, vis * (4 + 1));

    int inherit;
    f.ReadInt32(inherit);
    return true;
}

// 读文件头；返回 false 表示不是可支持的 v16 nav。
stock bool Nav_ReadHeader(File f, int &areaCount)
{
    int magic, version, sub, bspSize, analyzed, placeCount, hasUnnamed;
    if (!f.ReadInt32(magic) || magic != NAV_MAGIC)
        return false;
    if (!f.ReadInt32(version) || version != NAV_VERSION)
    {
        Log("[anhsbot] nav: unsupported version %d (need v16)", version);
        return false;
    }
    f.ReadInt32(sub);
    f.ReadInt32(bspSize);
    f.ReadInt8(analyzed);
    f.ReadUint16(placeCount);
    for (int i = 0; i < placeCount; i++)
    {
        int nlen;
        if (!f.ReadUint16(nlen))
            return false;
        Nav_Skip(f, nlen);
    }
    f.ReadInt8(hasUnnamed);
    if (!f.ReadInt32(areaCount) || areaCount <= 0 || areaCount > NAV_MAX_AREAS)
    {
        Log("[anhsbot] nav: bad areaCount %d", areaCount);
        return false;
    }
    return true;
}

// id → 索引（排序数组二分）。未找到返回 -1。
stock int Nav_IdToIndex(int id)
{
    int lo = 0, hi = g_iNavAreas - 1;
    while (lo <= hi)
    {
        int mid = (lo + hi) / 2;
        int v = g_iNavSortId[mid];
        if (v == id)
            return g_iNavSortIdx[mid];
        if (v < id) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

// 归并排序暂存（与排序数组等长）
int   g_iNavMergeId[NAV_MAX_AREAS];
int   g_iNavMergeIdx[NAV_MAX_AREAS];

// 并行数组按 id 归并排序（id/idx 同步移动）。
// 【性能】最大 4514 areas：插入排序 O(n²)≈10M 次要跑数秒（SourcePawn 解释执行，
// 有脚本超时风险），归并 O(n log n)≈5 万步，毫秒级。
stock void Nav_MergeRange(int lo, int hi)   // 排序区间 [lo, hi)
{
    if (hi - lo <= 1)
        return;
    int mid = (lo + hi) / 2;
    Nav_MergeRange(lo, mid);
    Nav_MergeRange(mid, hi);
    int i = lo, j = mid, k = lo;
    while (i < mid && j < hi)
    {
        if (g_iNavSortId[j] < g_iNavSortId[i])
        {
            g_iNavMergeId[k]  = g_iNavSortId[j];
            g_iNavMergeIdx[k] = g_iNavSortIdx[j];
            j++;
        }
        else
        {
            g_iNavMergeId[k]  = g_iNavSortId[i];
            g_iNavMergeIdx[k] = g_iNavSortIdx[i];
            i++;
        }
        k++;
    }
    while (i < mid)
    {
        g_iNavMergeId[k]  = g_iNavSortId[i];
        g_iNavMergeIdx[k] = g_iNavSortIdx[i];
        i++; k++;
    }
    while (j < hi)
    {
        g_iNavMergeId[k]  = g_iNavSortId[j];
        g_iNavMergeIdx[k] = g_iNavSortIdx[j];
        j++; k++;
    }
    for (int t = lo; t < hi; t++)
    {
        g_iNavSortId[t]  = g_iNavMergeId[t];
        g_iNavSortIdx[t] = g_iNavMergeIdx[t];
    }
}

stock void Nav_BuildIdIndex()
{
    for (int i = 0; i < g_iNavAreas; i++)
    {
        g_iNavSortId[i]  = g_iNavId[i];
        g_iNavSortIdx[i] = i;
    }
    Nav_MergeRange(0, g_iNavAreas);
}

// 解析当前地图 .nav。成功返回 true；无文件/格式不符返回 false（走位回退几何逻辑）。
public bool Nav_Load(const char[] map)
{
    Nav_Reset();

    char path[PLATFORM_MAX_PATH];
    if (!Nav_FindNavFile(map, path, sizeof(path)))
    {
        Log("[anhsbot] nav: %s.nav not found (geometric movement only)", map);
        return false;
    }

    // —— 第一遍：头 + 每 area 中心/包围盒/id ——
    File f = OpenFile(path, "rb");
    if (f == null)
    {
        Log("[anhsbot] nav: %s not found (geometric movement only)", path);
        return false;
    }

    int areaCount;
    if (!Nav_ReadHeader(f, areaCount))
    {
        Log("[anhsbot] nav: %s is not a v16 nav file", path);
        delete f;
        return false;
    }

    int idsScratch[1];
    for (int a = 0; a < areaCount; a++)
    {
        int id, connTotal;
        float nw[3], se[3], neZ, swZ;
        if (!Nav_ReadAreaHead(f, id, nw, se, neZ, swZ))
        {
            Log("[anhsbot] nav: EOF at area %d (pass1)", a);
            delete f;
            return false;
        }
        if (!Nav_ScanConns(f, false, idsScratch, 0, connTotal))
        {
            Log("[anhsbot] nav: bad conns at area %d (pass1)", a);
            delete f;
            return false;
        }
        if (!Nav_SkipAreaTail(f))
        {
            Log("[anhsbot] nav: bad tail at area %d (pass1)", a);
            delete f;
            return false;
        }

        g_iNavId[a]    = id;
        g_fNavC[a][0]  = (nw[0] + se[0]) * 0.5;
        g_fNavC[a][1]  = (nw[1] + se[1]) * 0.5;
        g_fNavC[a][2]  = (neZ + swZ) * 0.5;
        g_fNavMinX[a]  = (nw[0] < se[0]) ? nw[0] : se[0];
        g_fNavMinY[a]  = (nw[1] < se[1]) ? nw[1] : se[1];
        g_fNavMaxX[a]  = (nw[0] > se[0]) ? nw[0] : se[0];
        g_fNavMaxY[a]  = (nw[1] > se[1]) ? nw[1] : se[1];
    }
    delete f;

    g_iNavAreas = areaCount;
    Nav_BuildIdIndex();

    // —— 第二遍：连接 id → 索引 ——
    f = OpenFile(path, "rb");
    if (f == null)
        return false;
    if (!Nav_ReadHeader(f, areaCount))
    {
        delete f;
        return false;
    }

    int connPos = 0;
    int ids[256];
    for (int a = 0; a < areaCount; a++)
    {
        int id, connTotal;
        float nw[3], se[3], neZ, swZ;
        if (!Nav_ReadAreaHead(f, id, nw, se, neZ, swZ))
        {
            Log("[anhsbot] nav: EOF at area %d (pass2)", a);
            delete f;
            return false;
        }
        if (!Nav_ScanConns(f, true, ids, sizeof(ids), connTotal))
        {
            Log("[anhsbot] nav: bad conns at area %d (pass2)", a);
            delete f;
            return false;
        }
        if (!Nav_SkipAreaTail(f))
        {
            Log("[anhsbot] nav: bad tail at area %d (pass2)", a);
            delete f;
            return false;
        }

        g_iNavConnOff[a] = connPos;
        for (int k = 0; k < connTotal; k++)
        {
            if (k < sizeof(ids))
                g_iNavConn[connPos++] = Nav_IdToIndex(ids[k]);
            else
                g_iNavConn[connPos++] = -1;   // 单 area >256 连接的极端情况丢弃
            if (connPos >= NAV_MAX_CONNS)
            {
                Log("[anhsbot] nav: conn cap reached at area %d", a);
                break;
            }
        }
    }
    g_iNavConnOff[areaCount] = connPos;
    delete f;

    // —— 建 CSR：段内去重 + 垂直差过滤 ——
    int e = 0;
    for (int a = 0; a < areaCount; a++)
    {
        g_iNavEdgeOff[a] = e;
        int start = g_iNavConnOff[a];
        int end   = g_iNavConnOff[a + 1];
        for (int k = start; k < end; k++)
        {
            int j = g_iNavConn[k];
            if (j < 0 || j == a)
                continue;
            float dz = g_fNavC[a][2] - g_fNavC[j][2];
            if (dz < 0.0) dz = -dz;
            if (dz > NAV_MAX_Z_STEP)
                continue;
            bool dup = false;
            for (int t = g_iNavEdgeOff[a]; t < e; t++)
            {
                if (g_iNavEdgeTo[t] == j) { dup = true; break; }
            }
            if (dup)
                continue;
            if (e >= NAV_MAX_EDGES)
            {
                Log("[anhsbot] nav: edge cap reached at area %d", a);
                break;
            }
            g_iNavEdgeTo[e] = j;
            e++;
        }
    }
    g_iNavEdgeOff[areaCount] = e;
    g_iNavEdges = e;
    g_bNavLoaded = true;
    Log("[anhsbot] nav: loaded %s — %d areas, %d directed edges", path, areaCount, g_iNavEdges);
    return true;
}

// —— A*（二叉堆，懒删除）——

stock void AStar_HeapPush(int idx, float key)
{
    if (g_iHeapSize >= NAV_MAX_EDGES + 8)
        return;
    int i = g_iHeapSize++;
    g_iHeap[i] = idx;
    g_fHeapKey[i] = key;
    while (i > 0)
    {
        int p = (i - 1) >> 1;
        if (g_fHeapKey[p] <= g_fHeapKey[i])
            break;
        int ti = g_iHeap[i]; g_iHeap[i] = g_iHeap[p]; g_iHeap[p] = ti;
        float tk = g_fHeapKey[i]; g_fHeapKey[i] = g_fHeapKey[p]; g_fHeapKey[p] = tk;
        i = p;
    }
}

stock int AStar_HeapPop()
{
    if (g_iHeapSize <= 0)
        return -1;
    int top = g_iHeap[0];
    g_iHeapSize--;
    g_iHeap[0] = g_iHeap[g_iHeapSize];
    g_fHeapKey[0] = g_fHeapKey[g_iHeapSize];
    int i = 0;
    for (;;)
    {
        int l = (i << 1) + 1;
        int r = l + 1;
        int m = i;
        if (l < g_iHeapSize && g_fHeapKey[l] < g_fHeapKey[m]) m = l;
        if (r < g_iHeapSize && g_fHeapKey[r] < g_fHeapKey[m]) m = r;
        if (m == i)
            break;
        int ti = g_iHeap[i]; g_iHeap[i] = g_iHeap[m]; g_iHeap[m] = ti;
        float tk = g_fHeapKey[i]; g_fHeapKey[i] = g_fHeapKey[m]; g_fHeapKey[m] = tk;
        i = m;
    }
    return top;
}

stock float Nav_Heur2D(int a, int b)
{
    float dx = g_fNavC[a][0] - g_fNavC[b][0];
    float dy = g_fNavC[a][1] - g_fNavC[b][1];
    return SquareRoot(dx * dx + dy * dy);
}

// A* 主过程。成功返回路径长度（pathOut 含起点与终点），失败 0。
stock int Nav_AStar(int startIdx, int goalIdx, int pathOut[NAV_MAX_PATH])
{
    if (startIdx < 0 || goalIdx < 0 || startIdx >= g_iNavAreas || goalIdx >= g_iNavAreas)
        return 0;
    if (startIdx == goalIdx)
    {
        pathOut[0] = startIdx;
        return 1;
    }

    float now = GetGameTime();   // 诅咒过滤用（一次调用，勿放循环里）

    for (int i = 0; i < g_iNavAreas; i++)
    {
        g_fAStarG[i] = 0.0;
        g_bAStarClosed[i] = false;
        g_iAStarFrom[i] = -1;
    }
    g_iHeapSize = 0;

    AStar_HeapPush(startIdx, Nav_Heur2D(startIdx, goalIdx));
    int found = 0;

    while (g_iHeapSize > 0)
    {
        int cur = AStar_HeapPop();
        if (g_bAStarClosed[cur])
            continue;
        g_bAStarClosed[cur] = true;

        if (cur == goalIdx)
        {
            found = 1;
            break;
        }

        for (int e = g_iNavEdgeOff[cur]; e < g_iNavEdgeOff[cur + 1]; e++)
        {
            int to = g_iNavEdgeTo[e];
            if (g_bAStarClosed[to])
                continue;
            if (Nav_AreaCursed(to, now))
                continue;   // 绕开诅咒区域（夹住过 bot 的动态几何陷阱）
            float ng = g_fAStarG[cur] + Nav_Heur2D(cur, to);
            if (g_iAStarFrom[to] == -1 || ng < g_fAStarG[to])
            {
                g_fAStarG[to] = ng;
                g_iAStarFrom[to] = cur;
                AStar_HeapPush(to, ng + Nav_Heur2D(to, goalIdx));
            }
        }
    }

    if (!found)
        return 0;

    int len = 0;
    int walk = goalIdx;
    while (walk >= 0 && len < NAV_MAX_PATH)
    {
        pathOut[len++] = walk;
        if (walk == startIdx)
            break;
        walk = g_iAStarFrom[walk];
    }
    for (int i = 0, j = len - 1; i < j; i++, j--)
    {
        int t = pathOut[i]; pathOut[i] = pathOut[j]; pathOut[j] = t;
    }
    return len;
}

// 找 pos 所在（或最近）的 area。优先 XZ 包含且垂直差最小的。
stock int Nav_FindArea(const float pos[3])
{
    if (g_iNavAreas <= 0)
        return -1;
    int best = -1;
    float bestScore = 0.0;

    for (int a = 0; a < g_iNavAreas; a++)
    {
        bool inside = (pos[0] >= g_fNavMinX[a] && pos[0] <= g_fNavMaxX[a]
                    && pos[1] >= g_fNavMinY[a] && pos[1] <= g_fNavMaxY[a]);
        float dx = pos[0] - g_fNavC[a][0];
        float dy = pos[1] - g_fNavC[a][1];
        float dz = pos[2] - g_fNavC[a][2];
        if (dz < 0.0) dz = -dz;
        float score = dx * dx + dy * dy + dz * dz * 9.0;
        if (inside)
            score -= 1.0e7;   // 包含者优先
        if (best < 0 || score < bestScore)
        {
            best = a;
            bestScore = score;
        }
    }
    return best;
}

// —— 每 bot 路径管理 ——

// 随机取一个 area 的中心点（空闲漫游目标用）。无 nav 返回 false。
public bool Nav_RandomAreaCenter(float out[3])
{
    if (!g_bNavLoaded || g_iNavAreas <= 0)
        return false;
    int a = GetRandomInt(0, g_iNavAreas - 1);
    out[0] = g_fNavC[a][0];
    out[1] = g_fNavC[a][1];
    out[2] = g_fNavC[a][2];
    return true;
}

// 随机取 pos 周围 [minR, maxR] 环带内的一个 area 中心（漫游首选候选）。
// 【用途】nav 图常分多个不连通岛（断桥/单向落差/门外区域），全图随机目标
// A* 大概率失败；身侧环带最可能与 bot 同岛，优先选它可大幅提高连通率。
// tries 次拒绝采样，环带内无 area 返回 false（调用方再放宽范围）。
stock bool Nav_RandomAreaCenterNear(float out[3], const float pos[3],
                                    float minR, float maxR, int tries)
{
    if (!g_bNavLoaded || g_iNavAreas <= 0)
        return false;
    float lo2 = minR * minR, hi2 = maxR * maxR;
    for (int t = 0; t < tries; t++)
    {
        int a = GetRandomInt(0, g_iNavAreas - 1);
        float dx = g_fNavC[a][0] - pos[0];
        float dy = g_fNavC[a][1] - pos[1];
        float d2 = dx * dx + dy * dy;
        if (d2 >= lo2 && d2 <= hi2)
        {
            out[0] = g_fNavC[a][0];
            out[1] = g_fNavC[a][1];
            out[2] = g_fNavC[a][2];
            return true;
        }
    }
    return false;
}

// 当前是否有活跃路径（走完/清掉后为 false）。
// 用来区分"路径正常走完"与"路径还在但本帧给不出方向（危险区遮挡）"。
public bool Nav_PathActive(int client)
{
    return (g_iPathLen[client] > 0);
}

// —— 诅咒区域（动态几何陷阱）——

// area 是否被诅咒中（过期自动解咒）。
stock bool Nav_AreaCursed(int idx, float now)
{
    if (idx < 0 || idx >= NAV_MAX_AREAS || !g_bNavCursed[idx])
        return false;
    if (now - g_fNavCursedAt[idx] > NAV_CURSE_TTL)
    {
        g_bNavCursed[idx] = false;
        if (g_iNavCursedCount > 0)
            g_iNavCursedCount--;
        return false;
    }
    return true;
}

stock void Nav_CurseArea(int idx, float now)
{
    if (idx < 0 || idx >= g_iNavAreas)
        return;
    if (g_bNavCursed[idx])
    {
        g_fNavCursedAt[idx] = now;   // 刷新有效期
        return;
    }
    if (g_iNavCursedCount >= NAV_CURSE_MAX)
        return;                      // 防呆：不无限诅咒
    g_bNavCursed[idx] = true;
    g_fNavCursedAt[idx] = now;
    g_iNavCursedCount++;
}

// bot 在 pos 卡住时调用：诅咒它当前所在 area 与正在追赶的路径 waypoint，
// 让后续 A* 绕开这些"静态 nav 说能走、运行时被动态几何占住"的陷阱。
// 只在连续卡住（≥2 个窗口 ≈4s 零进展）时调用，避免误伤临时蹭墙。
public void Nav_CurseAround(int client, const float pos[3], float now)
{
    int here = Nav_FindArea(pos);
    if (here >= 0)
        Nav_CurseArea(here, now);
    if (g_iPathLen[client] > 0 && g_iPathCur[client] < g_iPathLen[client])
        Nav_CurseArea(g_iPathNode[client][g_iPathCur[client]], now);
    if (g_iNavCursedCount > 0)
        Log("[anhsbot] nav: cursed %d area(s) around bot %d (geometry trap)",
            g_iNavCursedCount, client);
}

// 诅咒过期清扫（Nav_ScanDanger 每 5s 顺带执行；TTL 到期解咒，门可能重开）。
stock void Nav_SweepCurses(float now)
{
    for (int a = 0; a < g_iNavAreas; a++)
    {
        if (g_bNavCursed[a] && now - g_fNavCursedAt[a] > NAV_CURSE_TTL)
        {
            g_bNavCursed[a] = false;
            if (g_iNavCursedCount > 0)
                g_iNavCursedCount--;
        }
    }
}

public void Nav_ClearPath(int client)
{
    g_iPathLen[client] = 0;
    g_iPathCur[client] = 0;
}

// 请求一条到 goal 的路径（无论成败都记录请求时间，失败退避）。
public bool Nav_RequestPath(int client, const float goal[3])
{
    g_fPathAt[client] = GetGameTime();
    if (!g_bNavLoaded)
        return false;

    float pos[3];
    GetClientAbsOrigin(client, pos);

    int from = Nav_FindArea(pos);
    int to   = Nav_FindArea(goal);
    if (from < 0 || to < 0)
    {
        Nav_ClearPath(client);
        return false;
    }

    int pathTmp[NAV_MAX_PATH];
    int len = Nav_AStar(from, to, pathTmp);
    if (len <= 0)
    {
        Nav_ClearPath(client);
        return false;
    }

    g_iPathLen[client] = len;
    g_iPathCur[client] = 1;    // 0 是起点（当前所在），从 1 开始追
    for (int i = 0; i < len; i++)
        g_iPathNode[client][i] = pathTmp[i];
    g_fPathGoalX[client] = goal[0];
    g_fPathGoalY[client] = goal[1];
    g_fPathGoalZ[client] = goal[2];
    g_fPathBorn[client] = GetGameTime();
    return true;
}

// 低频路径更新：目标变化/超期才重算；距离上次请求不足 NAV_REPATH_INTERVAL 沿用现状。
// 返回是否有活跃路径。
public bool Nav_UpdatePath(int client, const float goal[3])
{
    if (!g_bNavLoaded)
        return false;

    float now = GetGameTime();
    if (g_fPathAt[client] > 0.0 && now - g_fPathAt[client] < NAV_REPATH_INTERVAL)
        return (g_iPathLen[client] > 0);   // 频率限制：沿用现状

    bool need = false;
    if (g_iPathLen[client] <= 0)
        need = true;
    else
    {
        float dx = goal[0] - g_fPathGoalX[client];
        float dy = goal[1] - g_fPathGoalY[client];
        if (dx * dx + dy * dy > NAV_GOAL_EPSILON * NAV_GOAL_EPSILON)
            need = true;                                  // 目标明显移动
        else if (now - g_fPathBorn[client] > NAV_PATH_MAX_AGE)
            need = true;                                  // 路径过期，刷新
    }
    if (need)
        Nav_RequestPath(client, goal);
    return (g_iPathLen[client] > 0);
}

// 取当前路径方向（单位水平向量），并推进已到达的 waypoint。
// 返回 true = 有有效方向；false = 无路径/已走完/本帧被危险区挡住。
public bool Nav_GetMoveDir(int client, const float pos[3], float outDir[3])
{
    if (!g_bNavLoaded || g_iPathLen[client] <= 0)
        return false;

    while (g_iPathCur[client] < g_iPathLen[client])
    {
        int node = g_iPathNode[client][g_iPathCur[client]];
        float dx = g_fNavC[node][0] - pos[0];
        float dy = g_fNavC[node][1] - pos[1];
        if (dx * dx + dy * dy <= NAV_WAYPOINT_RADIUS * NAV_WAYPOINT_RADIUS)
            g_iPathCur[client]++;
        else
            break;
    }
    if (g_iPathCur[client] >= g_iPathLen[client])
    {
        Nav_ClearPath(client);
        return false;
    }

    int node = g_iPathNode[client][g_iPathCur[client]];
    float dx = g_fNavC[node][0] - pos[0];
    float dy = g_fNavC[node][1] - pos[1];
    float len = SquareRoot(dx * dx + dy * dy);
    if (len < 1.0)
    {
        g_iPathCur[client]++;
        return false;
    }
    float dirX = dx / len;
    float dirY = dy / len;

    // 危险区规避：方向直穿危险区时侧移 60° 再试
    float probe = NAV_WAYPOINT_RADIUS * 1.5;
    if (!Nav_DirHitsDanger(pos, dirX, dirY, probe))
    {
        outDir[0] = dirX;
        outDir[1] = dirY;
        outDir[2] = 0.0;
        return true;
    }
    float s = Sine(1.0471975), c = Cosine(1.0471975);   // 60°
    float rx = dirX * c - dirY * s;
    float ry = dirX * s + dirY * c;
    if (!Nav_DirHitsDanger(pos, rx, ry, probe))
    {
        outDir[0] = rx;
        outDir[1] = ry;
        outDir[2] = 0.0;
        return true;
    }
    return false;
}

// —— 危险区（trigger_hurt 等）——

// 低频枚举 trigger_hurt 实体，缓存球体近似（TTL 内部控制频率）。
public void Nav_ScanDanger(float now)
{
    if (now - g_fDangerScanAt < NAV_DANGER_SCAN_TTL)
        return;
    g_fDangerScanAt = now;
    g_iDangerCount = 0;
    Nav_SweepCurses(now);   // 诅咒过期清扫（同一节流窗口，零额外成本）

    int total = GetEntityCount();
    if (total > 2048)
        total = 2048;
    for (int e = MaxClients + 1; e < total && g_iDangerCount < NAV_MAX_DANGER; e++)
    {
        if (!IsValidEntity(e))
            continue;
        char cls[64];
        if (!GetEntityClassname(e, cls, sizeof(cls)))
            continue;
        if (!StrEqual(cls, "trigger_hurt", false))
            continue;
        if (!HasEntProp(e, Prop_Data, "m_vecAbsOrigin"))
            continue;
        float origin[3];
        GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", origin);

        float r = NAV_DANGER_DEFAULT_R;
        if (HasEntProp(e, Prop_Data, "m_vecMins") && HasEntProp(e, Prop_Data, "m_vecMaxs"))
        {
            float mins[3], maxs[3];
            GetEntPropVector(e, Prop_Data, "m_vecMins", mins);
            GetEntPropVector(e, Prop_Data, "m_vecMaxs", maxs);
            float ex = (maxs[0] - mins[0]) * 0.5;
            float ey = (maxs[1] - mins[1]) * 0.5;
            if (ex > 1.0 && ey > 1.0)
                r = (ex > ey) ? ex : ey;
        }
        g_fDangerPos[g_iDangerCount][0] = origin[0];
        g_fDangerPos[g_iDangerCount][1] = origin[1];
        g_fDangerPos[g_iDangerCount][2] = origin[2];
        g_fDangerR[g_iDangerCount] = r;
        g_iDangerCount++;
    }
    if (g_iDangerCount > 0)
        Dbg("nav: %d danger volumes cached", g_iDangerCount);
}

// 从 pos 沿 (dx,dy) 前进 dist 的线段是否进入任一危险区（球体近似，含 bot 半径余量）。
public bool Nav_DirHitsDanger(const float pos[3], float dx, float dy, float dist)
{
    for (int i = 0; i < g_iDangerCount; i++)
    {
        float px = pos[0], py = pos[1];
        float qx = px + dx * dist, qy = py + dy * dist;
        float cx = g_fDangerPos[i][0], cy = g_fDangerPos[i][1];
        float rr = g_fDangerR[i] + 24.0;

        float ex = qx - px, ey = qy - py;
        float len2 = ex * ex + ey * ey;
        float t = 0.0;
        if (len2 > 0.0)
        {
            t = ((cx - px) * ex + (cy - py) * ey) / len2;
            if (t < 0.0) t = 0.0;
            if (t > 1.0) t = 1.0;
        }
        float sx = px + ex * t - cx;
        float sy = py + ey * t - cy;
        if (sx * sx + sy * sy <= rr * rr)
            return true;
    }
    return false;
}

// 某点是否在危险区内。
public bool Nav_PointInDanger(const float p[3])
{
    for (int i = 0; i < g_iDangerCount; i++)
    {
        float dx = p[0] - g_fDangerPos[i][0];
        float dy = p[1] - g_fDangerPos[i][1];
        float rr = g_fDangerR[i];
        if (dx * dx + dy * dy <= rr * rr)
            return true;
    }
    return false;
}
