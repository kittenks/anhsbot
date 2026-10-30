# anhsbot — A Nights Haunting Source Bot Plugin

![A Nights Haunting Source](https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/3418380/b7b6a7a18c23e2e9625b4c4d15bc49c299bb647a/header_alt_assets_0.jpg?t=1791507492)

`anhsbot` is a SourceMod bot plugin for **A Nights Haunting Source (ANHS)**, built after the
`zpsbot` architecture. It drives fake clients (bots) through `OnPlayerRunCmd` to autonomously
aim, move, path, and fire — hunting zombie NPCs on the map and tracking kills / deaths / damage.

> Engine background: ANHS = **HL2MP (Source 2013) engine** + **ZPS (Zombie Panic! Source)
> code lineage** (Steam AppId 243750). This dual heritage means the plugin must use the ZPS
> build of gamedata.

> **Author**: [kittenks](https://github.com/kittenks) · 中文版说明见 [README-ZH.md](README-ZH.md)

---

## 1. Requirements

| Component | Version |
|---|---|
| MetaMod:Source | 1.12.0-git1228 or newer |
| SourceMod | 1.12.0-git7255 or newer |
| Game | A Nights Haunting Source (`anhsource` game folder) |
| Compiler | bundled SourcePawn Compiler 1.12 (only for self-builds) |

---

## 2. Installation

1. Merge the contents of this directory into your ANHS **game directory** (i.e. `anhsource/`
   itself, e.g. `D:\anh\anhsource\`), preserving the directory layout:

   ```
   addons/sourcemod/plugins/anhsbot.smx
   addons/sourcemod/gamedata/sdktools.games/custom/game.anhsource.txt
   addons/sourcemod/configs/anhsbot_bots.cfg
   cfg/sourcemod/plugin.anhsbot.cfg
   ```

   (Note: `addons/` and `cfg/` live inside the game directory `anhsource/`, NOT in the
   srcds launcher's parent directory.)

2. **Critical gamedata**: `game.anhsource.txt` MUST live in
   `addons/sourcemod/gamedata/sdktools.games/custom/`
   (NOT `gamedata/custom/`). It is derived from ZPS's `game.zpanic.txt`, renamed to
   `anhsource`, with the correct `PlayerRunCmd` offset (see section 4).

3. When starting the server, you MUST put `+mp_teamplay 1` **before** `+map`, e.g.:

   ```
   srcds.exe -game anhsource +mp_teamplay 1 +map anh_killhaus +sv_pure 0
   ```

   `mp_teamplay` must be set before map load, otherwise bots get stuck in team 0 and never spawn.

4. Restart or hot-load the plugin:

   ```
   rcon sm plugins load anhsbot
   ```

5. **Bot count**: set `anhsbot_quota` (recommended) or `anhsbot_count` in
   `cfg/sourcemod/plugin.anhsbot.cfg`. ANHS hard-caps at 16 players, i.e. up to ~15 bots + 1 human.

---

## 3. Configuration (ConVars)

Config file `cfg/sourcemod/plugin.anhsbot.cfg` (bilingual comments, auto-executed on first load;
an existing file is never overwritten). All cvars can also be changed live via rcon:
`sm_cvar anhsbot_<name> <value>`.

| ConVar | Default | Description |
|---|---|---|
| `anhsbot_enable` | `1` | Master switch. 0 = disable plugin (no bots spawned/driven). |
| `anhsbot_quota` | `0` | **Bot quota**: total online target; auto-adds when short, auto-kicks when over (>0 overrides `anhsbot_count`). |
| `anhsbot_count` | `0` | Legacy target count (0 = no auto-fill). Prefer `anhsbot_quota`. |
| `anhsbot_quota_joinzombie` | `0` | How many quota bots may join the zombie team (0/1). Engine-limited, see section 4. |
| `anhsbot_teamplay` | `1` | Teamplay: survivor teams 2/3 treat each other as teammates (no infighting, no friendly fire, regroup when idle). 0 = free-for-all. |
| `anhsbot_nav` | `1` | Nav A* pathfinding switch. Enabled on maps with a `.nav` file; maps without one fall back to pure geometric movement. |
| `anhsbot_no_achievements` | `1` | Disable `logic_achievement` entities on map start (works around a fake-client achievement null-pointer crash). |
| `anhsbot_skill` | `2` | Default bot skill: 0=low 1=normal 2=high 3=elite (aim error and reaction). |
| `anhsbot_name_prefix` | `AnhBot` | Bot name prefix (used when no name pool is installed; auto 2-digit suffix). |
| `anhsbot_autofill` | `1` | Automatically maintain the target bot count. |
| `anhsbot_fill_interval` | `3.0` | Seconds between autofill checks. |
| `anhsbot_manage_flags` | `1` | Watchdog re-asserts `FL_FAKECLIENT` every frame. |
| `anhsbot_respawn_delay` | `6.0` | Seconds a dead bot waits before the watchdog rebuilds it. |
| `anhsbot_debug` | `0` | 1 = verbose debug logging to the console. |

**Bot name pool**: `addons/sourcemod/configs/anhsbot_bots.cfg`, one `<name> <skill 0-3>` per
line, 32 presets. Delete the file to fall back to the name-prefix scheme.

---

## 4. How it works (key reverse-engineered facts)

To make a fake-client bot actually "alive", three ANHS-verified prerequisites must hold:

1. **Correct `PlayerRunCmd` vtable slot = player vtable[418] (offset 0x688).**
   Because ANHS carries ZPS lineage, the ZPS offset is required (HL2MP's 426 is a bool getter,
   and 432 is an empty function — both wrong). The gamedata is fixed in `game.anhsource.txt`.

2. **Bots must carry `FL_FAKECLIENT` (1<<9 = 0x200).**
   Note: SourceMod's header `FL_FAKECLIENT=(1<<8)=0x100` is the standard HL2 value, but on ANHS
   the flag layout is shifted by one bit — the real fake-client flag is `0x200`. ANHS's
   fake-client command loop only calls `PlayerRunCommand` for players carrying `0x200`;
   without it `OnPlayerRunCmd` never fires (`runcmds` stays 0). The plugin always uses its own
   `ANH_FL_FAKECLIENT=0x200`, with a per-frame watchdog re-assert.

3. **Inside `OnPlayerRunCmd` you must modify `vel`/`angles`/`buttons` and
   `return Plugin_Changed`.**
   Movement uses `vel[0]=forwardmove`, `vel[1]=sidemove` (not world velocity).

### Movement system (four layers, highest priority first)

1. **Nav A\* pathfinding**: path and follow when the target is >700u away or has no LOS; with no
   target, regroup with teammates or wander randomly.
2. **Three-band distance combat**: approach (>220) / back off (<90) / circle-strafe mid-range.
3. **Wall slide**: when the desired direction is blocked, rotate-probe for the nearest open
   direction and slide along walls.
4. **Geometric scout walk**: on repeated pathing failure or stuck, force movement in a random
   direction with wall slide and periodic jumps for 2.5s.

### Stuck self-rescue (three layers)

A static `.nav` can disagree with runtime dynamic geometry (doors/barricades open at nav-bake
time, closed at runtime), so a bot's hull may sink into geometry (velocity present, zero
displacement; `TeleportEntity` does not work on fake clients). Three self-rescue layers:
① **curse the area** (on repeated stuck, A\* routes around it, TTL 90s);
② **geometric scout walk** (force movement in a random direction);
③ **rebuild the bot** (kick + `CreateFakeClient` at a safe spawn, K/D/damage carried over).

### Zombie mechanics (both exist)

- **NPC zombies**: map entities (`npc_zombie` / `npc_fastzombie` / `npc_manhack` …) spawned by
  `npc_template_maker`. Bots acquire targets via a global NPC cache + line-of-sight (LOS) checks.
- **Zombie player team**: a hidden team 4 requiring `mp_teamplay 1`. **Engine limits: only one
  zombie player globally, and team assignment cannot survive a respawn** (verified: switching
  teams suicides the bot and it returns to a human team on revive). The plugin's default form is
  therefore "human bots (team 2/3) vs NPC zombies"; `anhsbot_quota_joinzombie 1` keeps an
  experimental code path (instant suicide on join, 30s backoff retry).

---

## 5. Admin commands

| Command | Description |
|---|---|
| `anhsbot_add [name]` | Add one bot (auto-joins team 2/3). |
| `anhsbot_kick <name\|#index>` | Kick one bot. |
| `anhsbot_kickall` | Kick all bots. |
| `anhsbot_list` | List all managed bots with live state (team/alive/target/shots/damage/KD). |
| `anhsbot_status` | Summarize online/alive/activated counts, cumulative KD/damage, nav state. |
| `anhsbot_aim [client\|0]` | Diagnostics: position/angles/target/aim error/weapon/nav path state. |
| `anhsbot_diag` | Diagnostics: targeting cache/LOS/weapon-switch details. |
| `anhsbot_tele <client> <x> <y> <z>` | Teleport a bot (note: teleport has limited effect on fake clients). |
| `anhsbot_npc <class> <nearClient> [dist]` | Spawn an NPC in front of a bot (for testing). |

---

## 6. Known limitations / roadmap

- **Zombie team**: engine-limited (see section 4); the current form is human teams vs NPCs.
- **Nav coverage**: 11 of 37 maps ship a `.nav` and support A\* pathfinding directly; the other
  26 can be baked on the fly with the engine command `nav_generate` (needs `sv_cheats 1`). Where
  a baked nav disagrees with runtime geometry, bots may sink into geometry — the three-layer
  self-rescue recovers automatically; re-baking is the root fix.
- **Respawn**: HL2MP has no round system / no `mp_forcerespawn`, so dead bots are rebuilt by the
  watchdog via the native `CreateFakeClient` path (same name/team, stats carried over).
- **Anti-cheat / public net**: deploy with VAC/SV anti-cheat and `sv_pure 0` as appropriate.

---

## 7. Troubleshooting

- **Bots don't move / `runcmds` is 0**: check `anhsbot_manage_flags` is 1, and that gamedata is
  in `sdktools.games/custom/`.
- **Bots stuck in team 0**: ensure `+mp_teamplay 1` precedes `+map` in launch args.
- **Bots standing still**: watch the console log — stuck detection prints
  `stuck (moved N in 2s, count N)`, followed by `scout walk` / `cursed N area(s)` /
  `geometry trap, rebuild scheduled` — these lines (each tagged with the bot index) are the
  self-rescue chain at work.
- **Server crash**: cdb auto-writes `anh_crash.dmp` on crash; analyze with
  `cdb -z anh_crash.dmp -c "!analyze -v; q"`.
- **Plugin load error**: run `sm plugins list` to see the error; usually a gamedata path/offset issue.
