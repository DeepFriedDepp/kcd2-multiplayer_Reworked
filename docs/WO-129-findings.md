# WO-129 — the first shared-world session's fixes: findings

Solo work on one machine (Modding Tools build, a throwaway save, a synthetic
v8 peer from `tools/wo121/avatarpeer`, WO-118's SynthPeer), plus a read of
both field logs from the first two-player 0.29.9 session. Evidence marks:
(observed), (code-verified), (synthetic), (inconclusive). Animations are
judged by screenshot strips (consecutive frames), never by a counter alone. Field lines
are quoted scrubbed (no names, addresses, paths, saves, GUIDs).

## 0. Answer first

- **There is no first bad commit.** The WO-121 commit itself (`dd7ab9b`,
  0.29.0) slides exactly like 0.29.9 (`2b3561e`): same flat ground, same
  1.4 m/s avatarpeer walk, legs together in 8/8 frames on both (observed,
  `docs/wo129-shots/1-slide-vs-walk.jpg` rows 1–2). Both ends of the range
  are bad, so there is nothing to bisect. The named suspects are cleared by
  that result, and by reading them: the relay clears flag 0x40 and forwards
  the tail verbatim; the WO-124 menu gate and the WO-125/127 agent edits never
  touch the gait path; the native motion/driver code has had only read-only
  leash additions since WO-121 (code-verified).
- **Why every avatar and NPC copy slid (observed with a probe DLL).**
  `C_ActorMovementController::Update` (EntityModule+0xB18D0, call at
  +0xB4D6A) calls `SetPseudoSpeed(<movement request's value>)` on every actor
  every frame. For a body with no movement request that value is 0. It runs
  **after** our frame-hook write and **before** `C_Actor::UpdateMannequinTags`
  (C_Actor vftable slot 0xC98, EntityModule+0x94750) reads it. So the tags
  saw 0: no pace tag. The requested velocity (actor+0x574) and the move vector
  (actor+0x614) were 0 too: no direction tag. Mannequin never picked the
  movement fragment, and the writer moved a standing body.
- **Why WO-121 read this as gait.** Its proof was "readback equals the
  stream". That readback runs at our frame hook, right after our own write
  and before the engine overwrites it. It is also true while the body slides:
  field `WO121-GAIT … wrote_mps=3.05 readback=3.05` (observed). Its sheet
  (`docs/wo121-shots/1-gait.jpg`) has one frame per speed, on a slope, and
  one frame cannot tell a stride from a pose. Why that sheet looked right
  stays (inconclusive).
- **A second defect under it: pseudo-speed is a speed class, not m/s**
  (code-verified). The RPG manager maps it as `id = (int)(x + 0.5) − 1` into
  the body's class table, which has 3 entries on avatars (walk, run, sprint).
  WO-121 wrote m/s. 1.4 m/s came out as walk by luck, 3.05 m/s (a jog) as
  sprint, and every player sprint (4.66–5.28 m/s) as id 4, outside the table:
  `requested logical speed id 4 is out of range 3`, 432 lines in the host's
  kcd.log and 2191 in the joiner's (observed).
- **The fix.** An inline hook at the entry of `UpdateMannequinTags`. For
  bodies we drive, and only for them, it puts back the class (clamped to that
  body's own range) and the rendered planar velocity. Result (observed): walk,
  run, sprint, crouch, crouch-walk, jump, backward, guard, locked swing and
  held block on the avatar all read like Henry. An NPC copy walks on the
  joiner's screen. The candidate's kcd.log has 0 speed-id warnings.

## 1. The items

| # | item | result |
|---|---|---|
| 1 | no animations on avatars / NPC copies | **fixed**. Root cause §0 (observed), strips §2 (observed) |
| — | clock skew | the only local-vs-remote stamp now removes the measured offset; 8 s artificial skew → gait fresh (observed) §3 |
| — | speed id out of range | class clamped to the body's own count (observed: 0 warnings) §3 |
| 2 | swings not seen by the peer | capture fix (code-verified); a real swing on the host was **not** played live (inconclusive) §4 |
| 3 | joiner: no grave | **fixed**: graves arm at the menu and make a grave (observed). Arming audit §5 |
| 4 | joiner as NPC scan anchor | in a shared world every player stays an anchor when apart (observed, solo) §6 |
| 5 | NPC copies sinking | tried once, not reproduced (inconclusive) §7 |
| 6 | launcher: stuck "Connecting...", no join buttons | root cause found (code-verified); fix built, window not seen connected (inconclusive) §8 |
| 6 | host's join bar | stage + elapsed seconds (observed) §8 |
| 7 | Discord `Assets.Merge` NRE | reproduced in a unit test and fixed (synthetic) §9 |

## 2. Screenshots (Henry's references: `docs/wo121-shots/`)

Images in `docs/wo129-shots/`. Each strip is 4–8 consecutive frames of one motion,
window-only capture (PrintWindow), the game window never in front.

| sheet | what | verdict |
|---|---|---|
| `1-slide-vs-walk.jpg` | 1.4 m/s: `dd7ab9b` / `2b3561e` / the fix / the fix with the peer's clock 8 s ahead | rows 1–2 legs together 8/8 (slide); rows 3–4 alternate strides like Henry's walk in `wo121-shots/1-gait.jpg` (observed) |
| `2-run-sprint.jpg` | 3.05 and 5.0 m/s on the fix | run: long stride; sprint: the lean and arm pump of Henry's sprint (observed) |
| `3-crouch-jump-back.jpg` | crouch, crouch-walk, jump, backward walk | crouched pose and crouch steps, airborne tuck, backward steps (observed) |
| `4-combat.jpg` | drawn, free slash, guard, locked slash (row replay), held block | guard, locked slash and block clear. The free slash is subtle, a small arm move (observed) |
| `5-npc-copy.jpg` | joiner side: a paused NPC copy walking under a synthetic host stream | strides; its own tags read `pace=walk dir=forward` (observed) |
| `6-host-join-bar.jpg` | the host's screen while a synthetic joiner loads | `synth-joiner is loading your world... 16 s` and the stage ladder (observed) |

## 3. Clock skew and the speed clamp

- **Offset, from the logs.** The joiner's `MP-CLOCK offset_ms` ran from
  −8064 to −8042 (offset = relay/host clock − local), so the joiner's clock
  was **8.04 s ahead** of the host's, not behind (observed).
- **Where skew could bite.** Every comparison of a received stamp with a
  local clock was read (code-verified):
  - The native gait/stream age uses local arrival time.
  - The action staleness check compares two stamps from the same sender.
  - Only `MP-WORLDSAVED` compared local wall time with the host's stamp.
    Field: `age_ms=8096 (clock skew not removed)` for a save a few ms old
    (observed). It was log-only.
- **Fix.** `Wo129.HostStampAgeMs` removes the measured offset. The line now
  says `skew_removed=yes`, or `no (no clock sample yet)`. Unit tests cover
  the field's own −8042 (synthetic).
- **Skew gate.** avatarpeer `--skew-ms 8000`: `WO121-GAIT state=fresh
  age_s=0.7`, class 1 walking and 3 sprinting, stride on screen (observed,
  sheet 1 row 4).
- **The clamp.** Class = walk 1 (< 2.4 m/s), run 2 (< 4.0), sprint 3. It is
  clamped to the body's own class count. The count comes from the engine:
  manager = GetGameIface()+0x138 → vtbl[0x100], count = vtbl[0x08](soul,
  kind), with kind = actor+0x860. It is re-read every 0.5 s, because the kind
  can follow stance or combat. Only `range=3` was ever seen on avatars, so
  whether the count really changes with state stays (inconclusive).
- **The engine's own cap.** `GetCurrentLogicalSpeedTag` caps the class by the
  animated character's real speed. It did not bite with the writer's flags
  unchanged (observed), so the writer's XFORM flags stay as shipped.

## 4. Swings (item 2)

- **Field (observed).** `cap_attack=0` on both machines for the whole
  session. `cap_dropped` was 5 (host) and 11 (joiner). The host's one jump
  was captured (`cap_jump=1`), so the capture hooks were running; attack
  captures never survived.
- **Defect (code-verified).** WO-121's capture compared the action's
  combat-actor pointer with C_CombatActor's primary vftable only. RTTI gives
  C_CombatActor two vftables, at COL offsets 0 and 8. A pointer typed as the
  +8 base carries the +8 vptr, fails the check and is counted as dropped. It
  also never equals the player's own combat actor, so a player swing could
  not be recognised as the player's.
- **Fix.** `as_combat_actor` normalises a +8 pointer to the object start
  (checked against both vftables) in the capture and in `combat_actor_of`.
  The drops now carry a reason: `cap_drop_notca / nodesc / noguid / noowner`,
  `cap_via_base8`, `cap_ours` in the status, and one `WO129-CAPTURE drop
  reason=…` line for each reason's first two.
- **Not proven live (inconclusive).** A real swing needs a real mouse click
  on Henry. That is input into the maintainer's desktop, so it was not done.
  A scripted takedown (`RequestKnockOut`) produced no swing on a
  native-driven avatar (observed). Row replay onto the avatar works (observed,
  sheet 4). Whether the field drops were the +8 pointer or another reason is
  also (inconclusive): WO-121's single counter did not say. The runbook's
  first check reads `cap_attack` and the drop reasons after one swing each way.

## 5. Graves and lazy arming (item 3)

- **Field joiner (observed).** At the main-menu injection:
  `ACTIONS: inventory: player inventory NOT found` → `ACTIONS: graves NOT
  armed`. At its death: `MP-RESPAWN grave NOT made (grave piece not armed or
  spawn failed) -- the player keeps their items`. The host injected in a
  world, armed graves, and made its grave (`inventory items=34`).
- **Fix.** Graves arm on their static anchors alone (RTTI, exports, the
  stash spawn). `make_grave` and the item moves fetch the player's inventory
  and the item manager at use, and refuse cleanly without them. One line when
  they first exist: `ACTIONS: graves live (player inventory and item manager
  found)`.
- **Candidate (observed).** At the menu: `graves armed`, `WO113-BUILD …
  graves=on`, `graves live` on the load. A lethal hit in the throwaway save
  made a grave.

The audit, piece by piece. The source is the field joiner's own menu-injection
lines (observed) plus what each piece keys on (code-verified):

| piece | keyed on | armed at the menu (field joiner) |
|---|---|---|
| Game Over guard | PlayerModule RTTI + string refs | yes |
| fade | GUIModule RTTI | yes |
| teleport + ground re-snap | C_Player RTTI / vtable slots | yes |
| clock | C_Calendar RTTI; the time is read at use | yes |
| map marker, leash brain read | RTTI + XGenAI exports; the map is looked up at use | yes |
| **graves** | **the live player inventory** (the only one) | **no → fixed** |
| reconcile | C_RPGUtils RTTI + function body | yes |
| area-label test, bleeding cure | scriptbind bodies | yes |
| stop-fight | RTTR registration | yes |
| punishment reset | exports + RTTI; the node state is read at use | yes (`UNREADABLE now`, by design) |
| native NPC write, motion pieces, hits | exports / code anchors | yes |
| dice hook | PlayerModule code | yes |
| save list | Framework code; arms on first use | yes (at 40 s) |
| **WO-129 gait tag hook** | EntityModule code (slot 0xC98 body) | installed at the menu (observed, candidate) |

Nothing else sets itself up once from a live world object.

## 6. The joiner as a scan anchor (item 4)

- **Field (observed).** The agent's scan did use both players
  (`MP-NPCSCAN … anchors=2` once the joiner's ghost existed). The mod's own
  tracking did not. It follows the peer only while "together", and when the
  host respawned far away it logged `WO1025-COLOCATE event=exit dist_m=476.5
  released=97`. From then on the host tracked and streamed only the NPCs
  around itself, not those around the joiner (code-verified: `mp_npc_rescan`
  adds the peer's anchor only when together).
- **Fix (Lua).** With the shared world hosted here, every player is an NPC
  scan anchor and "apart" never releases. The line is `WO129-SHARED shared
  world hosted here: every player is an NPC scan anchor, apart never
  releases`. No leash was set.
- **Cost.** Solo candidate with the peer about 400 m away: anchors stayed 2,
  85 NPCs scanned at 16–19 ms (observed). Field, with two anchors: 94–119
  NPCs at 10–50 ms, under the 200 cap (observed).

## 7. NPC copies sinking (item 5, one try)

- **Field (observed).** The joiner's 94 `MP-NPCPULL` windows show a vertical
  drift of −1.3 to +13.6 cm (`dz_mean_cm`). 47 windows had `flying>0`.
  Physics never pulled a copy down by the height of a knee.
- **Solo (observed).** The NPC copy on the village road kept its feet on the
  ground (sheet 5).
- **Verdict (inconclusive).** Not reproduced, and the cause is not known. If
  it is real, the stream's own z is the next suspect, not the writer. The
  tester page asks for where and when.

## 8. Launcher (item 6)

- **Stuck "Connecting..." and no join buttons (code-verified).** In 0.29.9
  the connection line and the join banner shared one poll with the
  version-mismatch check (`versionPollCts`). The launch panel ends with "The
  game is ready ... you can close this." Its **CLOSE** button calls
  `ResetLaunchState`, and that cancels `versionPollCts`. From then on nothing
  read `/connection-status` or `/join-status`, the screen kept its last line,
  and the `choose` state that shows **Bring my character / Start fresh** was
  never seen. The agents were fine: IPC listening, `connected` after the
  relay's Ack (observed, field agent logs). The field launcher logs have no
  line after `Agent started via ...` (observed): 0.29.9 logged no status.
  Whether both players clicked CLOSE is (inconclusive), but it explains both
  symptoms on both machines.
- **Fix.** The status poll has the agent's lifetime (`agentPollCts`, one
  loop per agent process), each iteration is caught and logged once, and each
  change writes an `Agent status:` line to the launcher log. The rules live in
  `AgentStatusBanner`: the line clears once connected, "isn't answering" after
  8 s unread, and the buttons show in `choose` only. Unit tests (synthetic).
  The window itself was not seen reaching `connected` or `choose`: that needs
  a second game (inconclusive).
- **Host's join bar.** It showed a fixed "loading" with no progress for about
  a minute. It now shows the stage and its seconds, for example
  `<partner> is loading your world... 34 s`, over a ladder `[x] save [x] send
  [>] load 34 s [ ] ready` (observed, sheet 6; Lua suite).

## 9. Discord (item 7)

- **Field (observed).** 3 per agent log on both machines, right after
  `ready`: `NullReferenceException … at DiscordRPC.Assets.Merge`.
- **Cause (code-verified, DiscordRPC 1.6.1).** `Assets.Merge` calls
  `StartsWith` on the reply's small-image key without a null check. Discord's
  echo of our activity has no small image, and the library merges the echo
  into its cached copy of our presence, which has assets.
- **Fix.** Right after `SetPresence`, the cached copy's assets are dropped
  (`DiscordPresence.ForgetCachedAssets`), so the merge adopts Discord's echo.
- **Proof (synthetic).** A unit test reproduces the library's exception with
  the field's shapes and passes with the fix. Live Discord was not run.

## 10. Gates

- `tools\Build-Installer.ps1`: relay round trip 48/48, agent 337/337 (12 are
  WO-129's), 26 synthetic Lua suites (WO-129's 26/26), both static checks,
  native unit tests 33/33 (new, `native/tests`), payload smoke. All green.
  WO-123's bar checks were updated to the new wording.
- Regression coverage for the root cause:
  - `native/tests/wo129_gait_tests.cpp` pins the class bands against the
    engine's `round(x)−1` mapper. It fails on WO-121's m/s semantics: raw 4.71
    is id 4, raw 3.05 is sprint.
  - `tools/wo129/gait_gate.py` is the live gate. It reads the avatar's own
    Mannequin tags while it walks, runs and sprints, and needs `tags_applied`
    above 0. It is RED on any DLL without the tag hook.
  - Live, on the installer's own `KCDMP.dll`: **GREEN**. Walk 9/9, run 8/8
    and sprint 9/9 samples carry `walk|run|sprint/forward`, `tags_applied`
    3197, and kcd.log has 0 speed-id warnings (observed).
  - The same gate on the 0.29.9 DLL (`2b3561e`): **RED**. Walk 0/9, run 0/9
    and sprint 0/8; every sample reads `pace=- dir=-` while the log says
    `readback=1.40|3.05|5.00` (observed). That run used the 0.30.0 pak, whose
    Lua changes do not touch the gait.
- `release\KCDMP-Setup-0.30.0.exe`, built locally, not on GitHub. Both
  players must install it: 0.29.9 and 0.30.0 refuse each other.

## 11. Carry forward

- The two-player checks that could not be done solo: a real swing each way,
  the launcher's buttons and cleared line, a joiner grave, NPCs around a
  far-away joiner, and sinking if it recurs. All of them are in
  `docs/TEST-0.30.0.md` and the runbook.
- The avatars' class count by state (only 3 ever seen).
- Why WO-121's single-frame sheet looked like gait.
