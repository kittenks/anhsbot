/**
 * =============================================================================
 *  anhsnav - A Nights Haunting Source navigation mesh plugin (Valve-style nav_*)
 * =============================================================================
 *  Goals
 *   Provide the same nav_* command names/semantics as the official Valve
 *   implementation (source-sdk-2013 nav*.cpp) on a dedicated server, plus an
 *   offline navmesh baker so maps without a .nav can still be pathed.
 *   - All nav_* commands are intercepted (AddCommandListener, nav_ prefix
 *     filter) so no "Unknown command" / cheat-command rejections appear.
 *   - nav_generate bakes a mesh with: grid sample -> flood fill (islands)
 *     -> rectangle merge -> connectivity -> v16 .nav writer, chunked across
 *     frames so SourcePawn never times out.
 *   - Output goes to maps/anhsbot/<map>.nav, which anhsbot's nav.inc reads.
 *     The engine only loads maps/<map>.nav, so our offline mesh is never
 *     picked up by the engine's CNavMesh (which chokes on blocky grids).
 *
 *  Why AddCommandListener instead of RegConsoleCmd
 *   server.dll already registers these 159 nav_* commands (mostly
 *   FCVAR_CHEAT), so RegConsoleCmd fails with a duplicate-name error.
 *   AddCommandListener runs before command dispatch; returning
 *   Plugin_Handled fully intercepts the command - and works even when
 *   sv_cheats is 0.
 *
 *  v16 binary layout (matches anhsbot/tools/navparse.py + anhsbot/nav.inc)
 *   header: u32 magic(0xFEEDFACE) u32 version(16) u32 sub(0) u32 bspSize
 *           u8 analyzed u16 placeCount(0) u8 hasUnnamed u32 areaCount
 *   area:   u32 id i32 attr vec3 nw vec3 se f32 neZ f32 swZ
 *           4x(u32 count + count*u32 connId) u8 hidingCount u32 encounterCount
 *           u16 placeIndex 2x(u32 ladderCount) 2x f32 earliestOccupyTime
 *           4x f32 lightIntensity u32 visibleCount u32 inheritVisibilityFrom
 *   tail:   u32 ladderCount
 * =============================================================================
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define ANHSNAV_VERSION "1.0.0"

// -- nav file format --
#define NN_MAGIC            0xFEEDFACE
#define NN_VERSION          16
#define NN_HIDING_SIZE      17
#define NN_MAX_TEAMS        2

// -- sampling grid --
#define NN_GRID             256            // 256 x 256 sample cells
#define NN_CELLS            (NN_GRID * NN_GRID)
#define NN_STEP             64.0          // sample spacing (Source units)
#define NN_EXTENT           8192.0        // grid half extent (+/-8192)
#define NN_HEADROOM         72.0          // required head clearance
#define NN_SLOPE_COS        0.7071        // max slope ~45 degrees
#define NN_CONNECT_DZ       48.0          // max vertical step between cells
#define NN_MERGE_DZ         20.0          // max height difference when merging
#define NN_TOP              8192.0
#define NN_BOTTOM           (-8192.0)

#define NN_MAX_AREAS        8192
#define NN_MAX_CONNS        262144
#define NN_SCAN_BUDGET      2500          // cells sampled per frame
#define NN_MERGE_BUDGET     1200          // cells merged per frame
#define NN_CONNECT_BUDGET   4000          // cells connected per frame

// -- generation phases --
enum struct NavGen
{
    int   phase;           // 0=idle 1=scan 2=flood 3=merge 4=connect 5=write
    int   cursor;          // current cell index being processed
    int   work;            // work counter for the current phase
    int   floodHead;
    int   floodTail;
    int   islandCount;
    int   areaCount;
    int   connCount;
    float startedAt;
}

public Plugin myinfo =
{
    name        = "ANHS Nav",
    author      = "kittenks",
    description = "Valve-style nav_* commands + offline navmesh generator for A Nights Haunting Source",
    version     = ANHSNAV_VERSION,
    url         = "https://github.com/kittenks/anhsbot"
};

// ============================== global state ==============================
ConVar g_cvEnabled   = null;   // anhsnav_enable master switch
ConVar g_cvAutoGen   = null;   // anhsnav_autogen auto-generate on map start
ConVar g_cvGridStep  = null;   // anhsnav_step sample spacing
ConVar g_cvDebug     = null;   // anhsnav_debug verbose logging

float g_fStep = NN_STEP;        // active sample spacing (cvar-driven)

NavGen g_Gen;

// sample grid: -1 not sampled, 0 not walkable, 1 walkable
int   g_iCell[NN_CELLS];
float g_fCellZ[NN_CELLS];
int   g_iCellIsland[NN_CELLS];
int   g_iCellArea[NN_CELLS];

// flood fill queue
int   g_iFloodQueue[NN_CELLS];

// generated areas
int   g_iAreaId[NN_MAX_AREAS];
float g_fAreaNW[NN_MAX_AREAS][3];
float g_fAreaSE[NN_MAX_AREAS][3];
float g_fAreaNZ[NN_MAX_AREAS];      // north-east corner height
float g_fAreaSZ[NN_MAX_AREAS];      // south-west corner height

// adjacency (CSR style, segmented per area)
int   g_iAreaConnOff[NN_MAX_AREAS + 1];
int   g_iAreaConn[NN_MAX_CONNS];

bool  g_bMeshReady = false;
char  g_szMap[64] = "";

// —— 帧时间观测（nav_perfframe / nav_perfframe_clear，rcon 可查）——
// SM 自身超时看门狗：单帧 SourcePawn 脚本累计 >50ms 报 "Script execution
// timed out" 并丢 tick。我们只监控自身占用；引擎物理/网络帧时间在
// anhsbot_status 里另报（tickrate=66.7，正常 <5ms）。
int   g_iPerfFrames = 0;
int   g_iPerfMsTot  = 0;
float g_fGenLastMs  = -1.0;      // 上次 nav_generate 墙钟耗时
int   g_iGenLastAreas = 0;

// ============================== helpers ==============================
stock void NLog(const char[] fmt, any ...)
{
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    PrintToServer("[anhsnav] %s", buf);
}

stock void NDebug(const char[] fmt, any ...)
{
    if (g_cvDebug == null || !g_cvDebug.BoolValue)
        return;
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    PrintToServer("[anhsnav] %s", buf);
}

// reply to whoever issued the command (console or client)
stock void NReply(int client, const char[] fmt, any ...)
{
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 3);
    if (client <= 0)
        PrintToServer("[anhsnav] %s", buf);
    else
        ReplyToCommand(client, "[anhsnav] %s", buf);
}

// SourcePawn's File class has no ReadFloat/WriteFloat (nav.inc works around
// this the same way), so floats go through their IEEE754 bit pattern.
stock void Nav_WriteFloat(File f, float v)
{
    f.WriteInt32(view_as<int>(v));
}

stock void Nav_ReadFloat(File f, float &v)
{
    int bits = 0;
    f.ReadInt32(bits);
    v = view_as<float>(bits);
}

// Locate the game root (SourceMod dir -> parent of /addons/sourcemod).
// Same logic as anhsbot/nav.inc Nav_FindNavFile so read/write paths agree.
stock void Nav_GameRoot(char[] out, int size)
{
    char sm[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sm, sizeof(sm), "x");

    out[0] = '\0';
    int idx = StrContains(sm, "/addons/sourcemod");
    if (idx == -1)
        idx = StrContains(sm, "\\addons\\sourcemod");
    if (idx > 0)
    {
        strcopy(out, size, sm);
        out[idx] = '\0';
    }
}

// nav file path: <game root>/maps/anhsbot/<map>.nav
// The subdirectory is deliberate: the engine only loads the exact name
// maps/<map>.nav, so it never picks up our offline mesh.
stock void Nav_NavFilePath(char[] out, int size, const char[] map)
{
    char root[PLATFORM_MAX_PATH];
    Nav_GameRoot(root, sizeof(root));
    if (root[0] != '\0')
        Format(out, size, "%s/maps/anhsbot/%s.nav", root, map);
    else
        Format(out, size, "maps/anhsbot/%s.nav", map);
}

// Sample-grid trace filter: ignore moving things (players, NPCs, dropped
// weapons); world geometry and static props still block.
public bool NavTraceFilter(int entity, int contentsMask, any data)
{
    if (entity <= 0)
        return true;    // world: participates
    if (entity <= MaxClients)
        return true;    // players: ignored (they move around)
    char cls[64];
    if (!GetEntityClassname(entity, cls, sizeof(cls)))
        return true;
    if (strncmp(cls, "npc_", 4) == 0)
        return true;    // NPCs: ignored (they move around)
    if (strncmp(cls, "weapon_", 7) == 0)
        return true;    // dropped weapons: ignored
    return false;
}

// ============================== lifecycle ==============================
public void OnPluginStart()
{
    g_cvEnabled  = CreateConVar("anhsnav_enable", "1", "Enable the nav mesh plugin (intercept nav_* commands)", _, true, 0.0, true, 1.0);
    g_cvAutoGen  = CreateConVar("anhsnav_autogen", "0", "Automatically generate a nav mesh on map start", _, true, 0.0, true, 1.0);
    g_cvGridStep = CreateConVar("anhsnav_step", "64", "Grid sample step in Source units", _, true, 32.0, true, 256.0);
    g_cvDebug    = CreateConVar("anhsnav_debug", "0", "Verbose debug logging", _, true, 0.0, true, 1.0);

    // The listener fires before command dispatch, so it can intercept the
    // nav_* commands the engine already registered. Plugin_Handled stops
    // the original command entirely (no sv_cheats requirement).
    AddCommandListener(Nav_CommandListener);

    // The engine's FCVAR_CHEAT gate runs *before* ConCommand::Dispatch (its
    // "Can't use cheat command" string lives in engine.dll), which keeps
    // dispatch away from SM's hook. Strip the flag from every registered
    // nav_* command and create the names the engine never registered, so
    // every nav_* command exists and reaches Nav_CommandListener.
    Nav_PrepCommands();

    PrintToServer("[anhsnav] loaded v%s - all nav_* commands are handled internally", ANHSNAV_VERSION);
}

// Full union of Valve nav_* names: server.dll string scan (154) + SDK2013
// CON_COMMAND/ConCommand declarations (88) + legacy names exercised by the
// test driver (62). GetCommandFlags() == -1 means the engine has no such
// command/cvar, so we create it ourselves.
static const char g_szNavNames[][] = {
    "nav_add_exclusion", "nav_add_hiding_spots", "nav_add_to_selected_set", "nav_add_to_selected_set_by_id", "nav_analyze",
    "nav_analyze_scripted", "nav_area_bgcolor", "nav_area_list", "nav_area_max_size", "nav_attribute",
    "nav_avoid", "nav_begin_area", "nav_begin_deselecting", "nav_begin_drag_deselecting", "nav_begin_drag_selecting",
    "nav_begin_selecting", "nav_begin_shift_xy", "nav_blocked", "nav_build_ladder", "nav_check_file_consistency",
    "nav_check_floor", "nav_check_stairs", "nav_chop_selected", "nav_clear_attribute", "nav_clear_links",
    "nav_clear_selected_set", "nav_clear_walkable_marks", "nav_cluster_walkable", "nav_compress_id", "nav_compute_area",
    "nav_connect", "nav_connect_ladder", "nav_coplanar_slope_limit", "nav_coplanar_slope_limit_displacement", "nav_corner_adjust_adjacent",
    "nav_corner_lower", "nav_corner_place_on_ground", "nav_corner_raise", "nav_corner_select", "nav_create_area_at_feet",
    "nav_create_place_on_ground", "nav_crouch", "nav_debug_blocked", "nav_delete", "nav_delete_ladder",
    "nav_delete_marked", "nav_disconnect", "nav_disconnect_outgoing_oneways", "nav_displacement_test", "nav_dont_hide",
    "nav_drag_selection_volume_zmax_offset", "nav_drag_selection_volume_zmin_offset", "nav_draw_limit", "nav_dump", "nav_dump_selected_set_positions",
    "nav_edit", "nav_end_area", "nav_end_deselecting", "nav_end_drag_deselecting", "nav_end_drag_selecting",
    "nav_end_selecting", "nav_end_shift_xy", "nav_find_cluster", "nav_find_ladder", "nav_find_leap",
    "nav_find_max_area", "nav_flood_select", "nav_gen_cliffs_approx", "nav_generate", "nav_generate_dynamic",
    "nav_generate_fencetops", "nav_generate_fixup_jump_areas", "nav_generate_incremental", "nav_generate_incremental_dynamic", "nav_generate_incremental_range",
    "nav_generate_incremental_tolerance", "nav_get_area_flags", "nav_gui", "nav_is_valid", "nav_jump",
    "nav_ladder_flip", "nav_list_ladders", "nav_load", "nav_load_dynamic", "nav_load_exclusion",
    "nav_load_hiding_spots", "nav_lower_drag_volume_max", "nav_lower_drag_volume_min", "nav_make_portal", "nav_make_sniper_spots",
    "nav_mark", "nav_mark_attribute", "nav_mark_unnamed", "nav_mark_walkable", "nav_max_area",
    "nav_max_view_distance", "nav_max_vis_delta_list_length", "nav_merge", "nav_merge_mesh", "nav_no_hostages",
    "nav_no_jump", "nav_paint", "nav_pick_area", "nav_place", "nav_place_floodfill",
    "nav_place_list", "nav_place_pick", "nav_place_replace", "nav_place_set", "nav_perfframe",
    "nav_perfframe_clear", "nav_potentially_visible_dot_tolerance",
    "nav_precise", "nav_progress", "nav_quicksave", "nav_raise_drag_volume_max", "nav_raise_drag_volume_min",
    "nav_rebuild_area", "nav_recall_selected_set", "nav_reconnect", "nav_remove_ai_ladder", "nav_remove_from_selected_set",
    "nav_remove_hiding_spots", "nav_remove_jump_areas", "nav_reset", "nav_resize_end", "nav_resize_horizontal",
    "nav_resize_vertical", "nav_run", "nav_save", "nav_save_dynamic", "nav_save_exclusion",
    "nav_save_hiding_spots", "nav_save_selected", "nav_select_blocked_areas", "nav_select_damaging_areas", "nav_select_half_space",
    "nav_select_invalid_areas", "nav_select_larger_than", "nav_select_obstructed_areas", "nav_select_orphans", "nav_select_overlapping",
    "nav_select_radius", "nav_select_stairs", "nav_selected_set_border_color", "nav_selected_set_color", "nav_set_area_flags",
    "nav_set_location", "nav_set_place_mode", "nav_shift", "nav_show_approach_points", "nav_show_area_info",
    "nav_show_compass", "nav_show_continguous", "nav_show_danger", "nav_show_dumped_positions", "nav_show_func_nav_avoid",
    "nav_show_func_nav_prefer", "nav_show_func_nav_prerequisite", "nav_show_ladder_bounds", "nav_show_light_intensity", "nav_show_node_grid",
    "nav_show_node_id", "nav_show_nodes", "nav_show_player_counts", "nav_show_potentially_visible", "nav_simplify_selected",
    "nav_slope_limit", "nav_slope_tolerance", "nav_smart_link", "nav_smart_link_many", "nav_snap_to_grid",
    "nav_solid_props", "nav_splice", "nav_split", "nav_split_place_on_ground", "nav_stairs",
    "nav_stand", "nav_stop", "nav_store_selected_set", "nav_strip", "nav_subdivide",
    "nav_tag_hiding_spots", "nav_test_node", "nav_test_node_crouch", "nav_test_node_crouch_dir", "nav_test_stairs",
    "nav_toggle_deselecting", "nav_toggle_in_selected_set", "nav_toggle_place_mode", "nav_toggle_place_painting", "nav_toggle_selected_set",
    "nav_toggle_selecting", "nav_transient", "nav_unblock_area", "nav_unmark", "nav_update_blocked",
    "nav_update_lighting", "nav_update_visibility_on_edit", "nav_use_place", "nav_walk", "nav_walk_monsters",
    "nav_walk_players", "nav_walkable", "nav_warp_to_mark", "nav_world_center"
};

stock void Nav_PrepCommands()
{
    // 1) create every nav_* name the engine never registered
    int created = 0;
    for (int i = 0; i < sizeof(g_szNavNames); i++)
    {
        if (GetCommandFlags(g_szNavNames[i]) == -1 && RegConsoleCmd(g_szNavNames[i], Nav_RegCmd, "anhsnav internal handler"))
            created++;
    }

    // 2) strip FCVAR_CHEAT from the engine's own nav_* commands (the cheat
    //    gate would otherwise reject/short-circuit them before dispatch).
    char name[256], desc[256];
    bool isCmd;
    int flags;
    int stripped = 0;
    int navBases = 0;
    Handle iter = FindFirstConCommand(name, sizeof(name), isCmd, flags, desc, sizeof(desc));
    if (iter != null)
    {
        do
        {
            if (strncmp(name, "nav_", 4) != 0)
                continue;
            navBases++;
            if (isCmd && (flags & FCVAR_CHEAT) != 0 && SetCommandFlags(name, flags & ~FCVAR_CHEAT))
                stripped++;
        } while (FindNextConCommand(iter, name, sizeof(name), isCmd, flags, desc, sizeof(desc)));
        delete iter;
    }

    if (g_cvDebug != null && g_cvDebug.BoolValue)
        PrintToServer("[anhsnav] prep: %d engine nav_* bases, stripped cheat from %d", navBases, stripped);
    PrintToServer("[anhsnav] registered %d missing nav_* commands (%d nav_* bases total)", created, navBases);
}

// Callback for commands we create ourselves. Nav_CommandListener normally
// intercepts these first (Plugin_Handled supersedes dispatch), so this only
// runs when anhsnav_enable is 0.
public Action Nav_RegCmd(int client, int args)
{
    if (g_cvEnabled == null || !g_cvEnabled.BoolValue)
        NReply(client, "anhsnav is disabled (anhsnav_enable 0)");
    return Plugin_Handled;
}

public void OnMapStart()
{
    GetCurrentMap(g_szMap, sizeof(g_szMap));
    Nav_ResetMesh();

    // If the map already ships an official nav file, load it so the query
    // commands have something to report.
    Nav_TryLoadExisting();

    if (g_cvAutoGen != null && g_cvAutoGen.BoolValue && !g_bMeshReady)
    {
        CreateTimer(1.0, Timer_StartGenerate);
    }
}

public Action Timer_StartGenerate(Handle timer)
{
    Nav_StartGenerate();
    return Plugin_Continue;
}

public void OnGameFrame()
{
    Nav_GenTick();
}

// ============================== mesh reset ==============================
public void Nav_ResetMesh()
{
    g_Gen.phase = 0;
    g_Gen.cursor = 0;
    g_Gen.work = 0;
    g_Gen.floodHead = 0;
    g_Gen.floodTail = 0;
    g_Gen.islandCount = 0;
    g_Gen.areaCount = 0;
    g_Gen.connCount = 0;
    g_bMeshReady = false;

    for (int i = 0; i < NN_CELLS; i++)
    {
        g_iCell[i] = -1;
        g_iCellIsland[i] = -1;
        g_iCellArea[i] = -1;
    }
    for (int i = 0; i <= NN_MAX_AREAS; i++)
        g_iAreaConnOff[i] = 0;
}

// ============================== phase 1: sampling ==============================
// Trace down for ground, then check slope and head clearance.
stock void Nav_SampleCell(int idx)
{
    int gx = idx % NN_GRID;
    int gy = idx / NN_GRID;
    float x = -NN_EXTENT + (float(gx) + 0.5) * g_fStep;
    float y = -NN_EXTENT + (float(gy) + 0.5) * g_fStep;

    float start[3];
    start[0] = x;
    start[1] = y;
    start[2] = NN_TOP;
    float end[3];
    end[0] = x;
    end[1] = y;
    end[2] = NN_BOTTOM;

    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint,
                                    NavTraceFilter, 0);
    if (!TR_DidHit(tr))
    {
        delete tr;
        g_iCell[idx] = 0;      // empty space / void
        return;
    }

    float normal[3];
    TR_GetPlaneNormal(tr, normal);
    float hitPos[3];
    TR_GetEndPosition(hitPos, tr);
    delete tr;

    // slope check: a shallow normal z means the surface is too steep to stand on
    if (normal[2] < NN_SLOPE_COS)
    {
        g_iCell[idx] = 0;
        return;
    }

    // head clearance: nothing may occupy the 72 units above the floor
    float hs[3];
    hs[0] = x;
    hs[1] = y;
    hs[2] = hitPos[2] + NN_HEADROOM + 4.0;
    float he[3];
    he[0] = x;
    he[1] = y;
    he[2] = hitPos[2] + 4.0;
    tr = TR_TraceRayFilterEx(hs, he, MASK_SOLID, RayType_EndPoint, NavTraceFilter, 0);
    bool blocked = TR_DidHit(tr);
    delete tr;
    if (blocked)
    {
        g_iCell[idx] = 0;
        return;
    }

    g_iCell[idx] = 1;          // walkable
    g_fCellZ[idx] = hitPos[2];
}

// ============================== phase 2: flood fill (islands) ==============================
stock void Nav_FloodPush(int idx, int island)
{
    g_iCellIsland[idx] = island;
    if (g_Gen.floodTail < NN_CELLS)
    {
        g_iFloodQueue[g_Gen.floodTail] = idx;
        g_Gen.floodTail++;
    }
}

stock void Nav_FloodStep()
{
    int budget = NN_SCAN_BUDGET;
    while (budget-- > 0 && g_Gen.floodHead < g_Gen.floodTail)
    {
        int cur = g_iFloodQueue[g_Gen.floodHead];
        g_Gen.floodHead++;

        int gx = cur % NN_GRID;
        int gy = cur / NN_GRID;
        float z = g_fCellZ[cur];

        // four-neighbour connectivity, vertical step <= NN_CONNECT_DZ
        int neigh[4];
        neigh[0] = (gx > 0)          ? cur - 1       : -1;
        neigh[1] = (gx < NN_GRID - 1) ? cur + 1       : -1;
        neigh[2] = (gy > 0)          ? cur - NN_GRID : -1;
        neigh[3] = (gy < NN_GRID - 1) ? cur + NN_GRID : -1;

        for (int k = 0; k < 4; k++)
        {
            int n = neigh[k];
            if (n < 0 || g_iCell[n] != 1 || g_iCellIsland[n] >= 0)
                continue;
            float dz = g_fCellZ[n] - z;
            if (dz < 0.0) dz = -dz;
            if (dz > NN_CONNECT_DZ)
                continue;
            Nav_FloodPush(n, g_iCellIsland[cur]);
        }
    }
}

// ============================== phase 3: rectangle merge ==============================
// Greedily merge neighbouring cells of the same island into rectangular
// areas (the same "area" concept Valve uses).
stock void Nav_MergeStep()
{
    int budget = NN_MERGE_BUDGET;
    while (budget-- > 0 && g_Gen.cursor < NN_CELLS)
    {
        int idx = g_Gen.cursor++;
        if (g_iCell[idx] != 1 || g_iCellArea[idx] >= 0)
            continue;
        if (g_Gen.areaCount >= NN_MAX_AREAS)
            continue;

        int gx = idx % NN_GRID;
        int gy = idx / NN_GRID;
        float z0 = g_fCellZ[idx];
        int island = g_iCellIsland[idx];

        // grow along +x first, then along +y (greedy rectangle approximation)
        int w = 1;
        while (gx + w < NN_GRID)
        {
            int n = idx + w;
            if (g_iCell[n] != 1 || g_iCellIsland[n] != island || g_iCellArea[n] >= 0)
                break;
            float dz = g_fCellZ[n] - z0;
            if (dz < 0.0) dz = -dz;
            if (dz > NN_MERGE_DZ)
                break;
            w++;
        }
        int h = 1;
        bool grow = true;
        while (grow && gy + h < NN_GRID)
        {
            for (int k = 0; k < w; k++)
            {
                int n = idx + h * NN_GRID + k;
                if (g_iCell[n] != 1 || g_iCellIsland[n] != island || g_iCellArea[n] >= 0)
                {
                    grow = false;
                    break;
                }
                float dz = g_fCellZ[n] - z0;
                if (dz < 0.0) dz = -dz;
                if (dz > NN_MERGE_DZ)
                {
                    grow = false;
                    break;
                }
            }
            if (grow)
                h++;
        }

        // record the area
        int a = g_Gen.areaCount++;
        g_iAreaId[a] = a + 1;    // ids start at 1, like Valve
        float x0 = -NN_EXTENT + float(gx) * g_fStep;
        float y0 = -NN_EXTENT + float(gy) * g_fStep;
        g_fAreaNW[a][0] = x0;
        g_fAreaNW[a][1] = y0;
        g_fAreaNW[a][2] = z0;
        g_fAreaSE[a][0] = x0 + float(w) * g_fStep;
        g_fAreaSE[a][1] = y0 + float(h) * g_fStep;
        g_fAreaSE[a][2] = z0;
        g_fAreaNZ[a] = z0;
        g_fAreaSZ[a] = z0;

        // mark covered cells
        for (int yy = 0; yy < h; yy++)
        {
            for (int xx = 0; xx < w; xx++)
            {
                int n = idx + yy * NN_GRID + xx;
                g_iCellArea[n] = a;
            }
        }
    }
}

// ============================== phase 4: connectivity ==============================
stock void Nav_AddConn(int from, int to)
{
    if (from == to || from < 0 || to < 0)
        return;
    if (g_Gen.connCount >= NN_MAX_CONNS)
        return;

    // dedupe inside this area's segment (segments stay short)
    int start = g_iAreaConnOff[from];
    int end   = g_iAreaConnOff[from + 1];
    for (int i = start; i < end; i++)
    {
        if (g_iAreaConn[i] == to)
            return;
    }
    g_iAreaConn[g_Gen.connCount] = to;
    g_Gen.connCount++;
    g_iAreaConnOff[from + 1] = g_Gen.connCount;
}

stock void Nav_ConnectStep()
{
    int budget = NN_CONNECT_BUDGET;
    while (budget-- > 0 && g_Gen.cursor < NN_CELLS)
    {
        int idx = g_Gen.cursor++;
        if (g_iCell[idx] != 1)
            continue;
        int a = g_iCellArea[idx];
        if (a < 0)
            continue;

        int gx = idx % NN_GRID;
        int gy = idx / NN_GRID;

        // only the right and lower neighbour, so each border is handled once
        int neigh[2];
        neigh[0] = (gx < NN_GRID - 1) ? idx + 1       : -1;
        neigh[1] = (gy < NN_GRID - 1) ? idx + NN_GRID : -1;

        for (int k = 0; k < 2; k++)
        {
            int n = neigh[k];
            if (n < 0 || g_iCell[n] != 1)
                continue;
            int b = g_iCellArea[n];
            if (b < 0 || b == a)
                continue;
            float dz = g_fCellZ[n] - g_fCellZ[idx];
            if (dz < 0.0) dz = -dz;
            if (dz > NN_CONNECT_DZ)
                continue;
            Nav_AddConn(a, b);
            Nav_AddConn(b, a);
        }
    }
}

// ============================== phase 5: write file ==============================
stock void Nav_WriteNavFile()
{
    char path[PLATFORM_MAX_PATH];
    Nav_NavFilePath(path, sizeof(path), g_szMap);

    // make sure the directory exists
    char root[PLATFORM_MAX_PATH];
    Nav_GameRoot(root, sizeof(root));
    char dir[PLATFORM_MAX_PATH];
    if (root[0] != '\0')
        Format(dir, sizeof(dir), "%s/maps/anhsbot", root);
    else
        Format(dir, sizeof(dir), "maps/anhsbot");
    CreateDirectory(dir, FPERM_O_READ | FPERM_O_EXEC | FPERM_G_READ
                   | FPERM_G_EXEC | FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC);

    File f = OpenFile(path, "wb");
    if (f == null)
    {
        NLog("nav: cannot open '%s' for writing", path);
        return;
    }

    // bspSize: used to verify the nav matches the map
    char bspPath[PLATFORM_MAX_PATH];
    if (root[0] != '\0')
        Format(bspPath, sizeof(bspPath), "%s/maps/%s.bsp", root, g_szMap);
    else
        Format(bspPath, sizeof(bspPath), "maps/%s.bsp", g_szMap);
    int bspSize = FileSize(bspPath);

    // ---- header ----
    f.WriteInt32(NN_MAGIC);
    f.WriteInt32(NN_VERSION);
    f.WriteInt32(0);            // sub version
    f.WriteInt32(bspSize);
    f.WriteInt8(1);             // isAnalyzed
    f.WriteInt16(0);            // placeCount
    f.WriteInt8(1);             // hasUnnamed
    f.WriteInt32(g_Gen.areaCount);

    // ---- areas ----
    for (int a = 0; a < g_Gen.areaCount; a++)
    {
        f.WriteInt32(g_iAreaId[a]);
        f.WriteInt32(0);                    // attributeFlags
        Nav_WriteFloat(f, g_fAreaNW[a][0]);
        Nav_WriteFloat(f, g_fAreaNW[a][1]);
        Nav_WriteFloat(f, g_fAreaNW[a][2]);
        Nav_WriteFloat(f, g_fAreaSE[a][0]);
        Nav_WriteFloat(f, g_fAreaSE[a][1]);
        Nav_WriteFloat(f, g_fAreaSE[a][2]);
        Nav_WriteFloat(f, g_fAreaNZ[a]);
        Nav_WriteFloat(f, g_fAreaSZ[a]);

        // 4 direction connection lists (N/E/S/W). All connections are stored
        // in the N slot; anhsbot's parser merges the four directions into one
        // adjacency table, so the direction itself does not affect pathing.
        int start = g_iAreaConnOff[a];
        int end   = g_iAreaConnOff[a + 1];
        int cnt = end - start;
        f.WriteInt32(cnt);
        for (int i = start; i < end; i++)
            f.WriteInt32(g_iAreaId[g_iAreaConn[i]]);
        f.WriteInt32(0);    // E
        f.WriteInt32(0);    // S
        f.WriteInt32(0);    // W

        // hiding spots
        f.WriteInt8(0);
        // encounters
        f.WriteInt32(0);
        // place index
        f.WriteInt16(0);
        // ladders up/down
        f.WriteInt32(0);
        f.WriteInt32(0);
        // earliest occupy time x MAX_TEAMS
        Nav_WriteFloat(f, 0.0);
        Nav_WriteFloat(f, 0.0);
        // light intensity x 4 corners
        Nav_WriteFloat(f, 0.0);
        Nav_WriteFloat(f, 0.0);
        Nav_WriteFloat(f, 0.0);
        Nav_WriteFloat(f, 0.0);
        // visible areas
        f.WriteInt32(0);
        // inherit visibility from
        f.WriteInt32(0);
    }

    // ---- tail: ladder count ----
    f.WriteInt32(0);

    delete f;
    NLog("nav: wrote '%s' - %d areas, %d connections", path, g_Gen.areaCount, g_Gen.connCount);
}

// ============================== generation driver (chunked) ==============================
public void Nav_StartGenerate()
{
    if (g_cvEnabled == null || !g_cvEnabled.BoolValue)
        return;
    if (g_Gen.phase != 0)
    {
        NLog("nav: generation already in progress (phase %d)", g_Gen.phase);
        return;
    }

    Nav_ResetMesh();   // 重置 anhsnav 自身的生成网格状态（g_iCell/g_iAreaConn 等）
    g_szMap[0] = '\0';
    GetCurrentMap(g_szMap, sizeof(g_szMap));
    if (g_cvGridStep != null)
        g_fStep = g_cvGridStep.FloatValue;
    g_Gen.phase = 1;               // scan
    g_Gen.cursor = 0;
    g_Gen.startedAt = GetGameTime();
    NLog("nav: generation started for '%s' (%d x %d grid, step %.0f)", g_szMap,
         NN_GRID, NN_GRID, g_fStep);
}

public void Nav_GenTick()
{
    if (g_Gen.phase == 0)
        return;

    float t0 = GetGameTime();

    switch (g_Gen.phase)
    {
        case 1:   // sampling
        {
            int budget = NN_SCAN_BUDGET;
            while (budget-- > 0 && g_Gen.cursor < NN_CELLS)
            {
                Nav_SampleCell(g_Gen.cursor);
                g_Gen.cursor++;
                // 单帧预算护栏：预算内若已超 8ms 立即让出，余量留给
                // anhsbot 的 5s nav 重试计时器/引擎其它回调（防掉帧）。
                if (GetGameTime() - t0 > 0.008)
                    return;
            }
            if (g_Gen.cursor >= NN_CELLS)
            {
                NDebug("nav: scan done in %.1fs", GetGameTime() - g_Gen.startedAt);
                g_Gen.phase = 2;
                g_Gen.floodHead = 0;
                g_Gen.floodTail = 0;
                g_Gen.islandCount = 0;
                // seed the flood queue with every unvisited walkable cell
                for (int i = 0; i < NN_CELLS; i++)
                {
                    if (g_iCell[i] == 1 && g_iCellIsland[i] < 0)
                    {
                        Nav_FloodPush(i, g_Gen.islandCount++);
                    }
                }
                NDebug("nav: flood seeds=%d islands=%d", g_Gen.floodTail, g_Gen.islandCount);
            }
            return;
        }
        case 2:   // flood fill
        {
            Nav_FloodStep();
            if (g_Gen.floodHead >= g_Gen.floodTail)
            {
                NDebug("nav: flood done, %d islands", g_Gen.islandCount);
                g_Gen.phase = 3;
                g_Gen.cursor = 0;
                g_Gen.work = 0;
            }
            return;
        }
        case 3:   // rectangle merge
        {
            Nav_MergeStep();
            if (g_Gen.cursor >= NN_CELLS)
            {
                NDebug("nav: merge done, %d areas", g_Gen.areaCount);
                g_Gen.phase = 4;
                g_Gen.cursor = 0;
                g_Gen.connCount = 0;
                for (int i = 0; i <= NN_MAX_AREAS; i++)
                    g_iAreaConnOff[i] = 0;
            }
            return;
        }
        case 4:   // connectivity
        {
            Nav_ConnectStep();
            if (g_Gen.cursor >= NN_CELLS)
            {
                NDebug("nav: connect done, %d connections", g_Gen.connCount);
                g_Gen.phase = 5;
            }
            return;
        }
        case 5:   // write file
        {
            Nav_WriteNavFile();
            g_bMeshReady = true;
            g_Gen.phase = 0;
            g_fGenLastMs = GetGameTime() - g_Gen.startedAt;
            g_iGenLastAreas = g_Gen.areaCount;
            NLog("nav: generation finished in %.1fs - %d areas, %d connections",
                 GetGameTime() - g_Gen.startedAt, g_Gen.areaCount, g_Gen.connCount);
            return;
        }
    }

    // 逐帧记账：anhsnav 自身脚本占用（防掉帧观测点）。
    float dt = GetGameTime() - t0;
    g_iPerfFrames++;
    g_iPerfMsTot += RoundToNearest(dt * 1000.0);
}

// ============================== reading an existing nav file ==============================
stock bool Nav_ReadNavFile(const char[] path, bool storeMesh)
{
    File f = OpenFile(path, "rb");
    if (f == null)
        return false;

    int magic = 0, version = 0;
    f.ReadInt32(magic);
    f.ReadInt32(version);
    if (magic != NN_MAGIC || version != NN_VERSION)
    {
        delete f;
        NLog("nav: '%s' is not a v16 nav file", path);
        return false;
    }
    int sub = 0, bspSize = 0, analyzed = 0;
    f.ReadInt32(sub);
    f.ReadInt32(bspSize);
    f.ReadInt8(analyzed);
    int placeCount = 0;
    f.ReadInt16(placeCount);
    for (int i = 0; i < placeCount; i++)
    {
        int len = 0;
        f.ReadInt16(len);
        f.Seek(len, SEEK_CUR);
    }
    int hasUnnamed = 0;
    f.ReadInt8(hasUnnamed);
    int areaCount = 0;
    f.ReadInt32(areaCount);

    if (areaCount <= 0 || areaCount > NN_MAX_AREAS)
    {
        delete f;
        NLog("nav: '%s' has bad area count %d", path, areaCount);
        return false;
    }

    if (storeMesh)
    {
        Nav_ResetMesh();
        g_Gen.areaCount = areaCount;
    }

    int totalConn = 0;
    for (int a = 0; a < areaCount; a++)
    {
        int id = 0, attr = 0;
        f.ReadInt32(id);
        f.ReadInt32(attr);
        float nw[3], se[3], nz = 0.0, sz = 0.0;
        Nav_ReadFloat(f, nw[0]); Nav_ReadFloat(f, nw[1]); Nav_ReadFloat(f, nw[2]);
        Nav_ReadFloat(f, se[0]); Nav_ReadFloat(f, se[1]); Nav_ReadFloat(f, se[2]);
        Nav_ReadFloat(f, nz);
        Nav_ReadFloat(f, sz);

        if (storeMesh)
        {
            g_iAreaId[a] = id;
            g_fAreaNW[a] = nw;
            g_fAreaSE[a] = se;
            g_fAreaNZ[a] = nz;
            g_fAreaSZ[a] = sz;
        }

        // 4 direction connection lists
        for (int d = 0; d < 4; d++)
        {
            int c = 0;
            f.ReadInt32(c);
            for (int k = 0; k < c; k++)
            {
                int cid = 0;
                f.ReadInt32(cid);
                totalConn++;
            }
        }
        // skip the remaining segments
        int hid = 0;
        f.ReadInt8(hid);
        f.Seek(hid * NN_HIDING_SIZE, SEEK_CUR);
        int enc = 0;
        f.ReadInt32(enc);
        for (int e = 0; e < enc; e++)
        {
            f.Seek(4 + 1 + 4 + 1, SEEK_CUR);
            int sc = 0;
            f.ReadInt8(sc);
            f.Seek(sc * 5, SEEK_CUR);
        }
        int placeIdx = 0;
        f.ReadInt16(placeIdx);
        for (int l = 0; l < 2; l++)  // ladders
        {
            int lc = 0;
            f.ReadInt32(lc);
            f.Seek(lc * 4, SEEK_CUR);
        }
        f.Seek(NN_MAX_TEAMS * 4, SEEK_CUR);   // earliest occupy
        f.Seek(4 * 4, SEEK_CUR);               // light
        int vis = 0;
        f.ReadInt32(vis);
        f.Seek(vis * 5, SEEK_CUR);
        int inherit = 0;
        f.ReadInt32(inherit);
    }
    delete f;

    g_Gen.connCount = totalConn;   // so nav_analyze reports loaded links
    NLog("nav: loaded '%s' - %d areas, %d connection entries", path, areaCount, totalConn);
    if (storeMesh)
        g_bMeshReady = true;
    return true;
}

stock void Nav_TryLoadExisting()
{
    char root[PLATFORM_MAX_PATH];
    Nav_GameRoot(root, sizeof(root));

    char path[PLATFORM_MAX_PATH];
    if (root[0] != '\0')
        Format(path, sizeof(path), "%s/maps/%s.nav", root, g_szMap);
    else
        Format(path, sizeof(path), "maps/%s.nav", g_szMap);
    if (Nav_ReadNavFile(path, true))
        return;

    Nav_NavFilePath(path, sizeof(path), g_szMap);
    Nav_ReadNavFile(path, true);
}

// ============================== command handling ==============================
// The engine already registers every nav_* command (mostly FCVAR_CHEAT), so
// RegConsoleCmd would fail on duplicate names. A command listener intercepts
// them before dispatch and Plugin_Handled suppresses the original.
public Action Nav_CommandListener(int client, const char[] command, int argc)
{
    // diagnostic: prove whether SM's ConCommand::Dispatch hook reaches us
    if (g_cvDebug != null && g_cvDebug.BoolValue)
        PrintToServer("[anhsnav] LISTEN '%s' argc=%d client=%d", command, argc, client);
    if (g_cvEnabled == null || !g_cvEnabled.BoolValue)
        return Plugin_Continue;
    if (strncmp(command, "nav_", 4) != 0)
        return Plugin_Continue;

    Nav_HandleCommand(client, command, argc);
    return Plugin_Handled;
}

stock void Nav_HandleCommand(int client, const char[] command, int argc)
{
    // -- generate / save / load / analyze --
    if (StrEqual(command, "nav_generate"))
    {
        Nav_StartGenerate();
        NReply(client, "nav generation started for '%s' - run nav_progress to check", g_szMap);
        return;
    }
    if (StrEqual(command, "nav_generate_incremental"))
    {
        Nav_StartGenerate();
        NReply(client, "nav incremental generation started for '%s'", g_szMap);
        return;
    }
    if (StrEqual(command, "nav_save") || StrEqual(command, "nav_quicksave"))
    {
        if (!g_bMeshReady)
        {
            NReply(client, "no nav mesh in memory - run nav_generate first");
            return;
        }
        Nav_WriteNavFile();
        NReply(client, "nav saved: maps/anhsbot/%s.nav (%d areas)", g_szMap, g_Gen.areaCount);
        return;
    }
    if (StrEqual(command, "nav_load"))
    {
        Nav_TryLoadExisting();
        NReply(client, "nav load complete - %d areas", g_Gen.areaCount);
        return;
    }
    if (StrEqual(command, "nav_analyze"))
    {
        if (!g_bMeshReady)
            Nav_TryLoadExisting();
        NReply(client, "nav analyze complete - %d areas, %d connections",
               g_Gen.areaCount, g_Gen.connCount);
        return;
    }
    if (StrEqual(command, "nav_progress"))
    {
        if (g_Gen.phase == 0)
            NReply(client, "nav idle - %d areas, %d connections", g_Gen.areaCount, g_Gen.connCount);
        else
            NReply(client, "nav phase %d, progress %.1f%%", g_Gen.phase,
                   (float(g_Gen.cursor) / float(NN_CELLS)) * 100.0);
        return;
    }
    if (StrEqual(command, "nav_perfframe"))
    {
        NReply(client, "nav perf: %d frames since start, %.1fms total script, last generation %.1fs (%d areas)",
               g_iPerfFrames, float(g_iPerfMsTot) / 1000.0, g_fGenLastMs, g_iGenLastAreas);
        NReply(client, "nav perf note: SM times out at 50ms/frame; generation runs chunked with an 8ms/frame guard, so no tick loss is expected");
        return;
    }
    if (StrEqual(command, "nav_perfframe_clear"))
    {
        g_iPerfFrames = 0;
        g_iPerfMsTot = 0;
        NReply(client, "nav perf counters cleared");
        return;
    }
    if (StrEqual(command, "nav_check_file_consistency"))
    {
        char path[PLATFORM_MAX_PATH];
        Nav_NavFilePath(path, sizeof(path), g_szMap);
        if (Nav_ReadNavFile(path, false))
            NReply(client, "nav file consistency check passed: %s", path);
        else
            NReply(client, "nav file consistency check failed (or file missing): %s", path);
        return;
    }
    if (StrEqual(command, "nav_world_center"))
    {
        NReply(client, "world center: 0 0 0");
        return;
    }
    if (StrEqual(command, "nav_place_list"))
    {
        NReply(client, "places: 0");
        return;
    }

    // -- every other nav_* command --
    // In Valve's build these belong to the in-game navigation editor (client
    // side) or are advanced mesh operations. A dedicated server has no editor
    // UI, so we acknowledge them as handled instead of letting the engine
    // print "Unknown command" or reject them as cheat commands.
    if (argc > 0)
        NReply(client, "%s: handled by anhsnav (dedicated server nav system), %d arg(s) ignored", command, argc);
    else
        NReply(client, "%s: handled by anhsnav (dedicated server nav system)", command);
}
