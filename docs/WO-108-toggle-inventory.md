# WO-108 — toggle inventory: what is actually on in a shipped 0.26.3 build

Session 2026-09-21, solo. Companion to `docs/WO-108-findings.md`. This is
the list the eventual removal WO works from. **Nothing here was deleted
this WO**; the `0.26.4` column says what this build does with each row.

Status vocabulary (exactly one per row):

* **live-and-wanted** — reachable in the shipped configuration and doing a
  job no later WO replaced.
* **live-but-superseded** — reachable and running, but a later WO replaced
  the job it does. Candidate for off-by-default (0.26.4) and removal later.
* **off-and-dead** — shipped off, and no shipped path turns it on.
* **unresolved** — no WO clearly supersedes it, or its role under the
  0.26.4 architecture is not established. Left exactly as it is.

"0.26.3" is what a client sees with no console command typed. Three
toggles (`authority_host`, `pos_native`, `npc_scan_native`) are pushed by
the agent at connect from `ClientConfig` (all `true`); the Lua table mirrors
them, so the Lua default is the shipped default for those too. `0.26.4`
column: `=` unchanged, else the new default.

Every "what it does" cell is (code-verified) — read from `kdcmp.lua` this
session, not from docs.

---

## 1. NPC ownership / authority model

| toggle | what it does | 0.26.3 | 0.26.4 | introduced | superseded by | status |
|---|---|---|---|---|---|---|
| `mp_authority_host_on/off` (`KCD2MP.wo102.authorityHost`) | one machine (damage authority) owns every NPC; a non-authority never claims, never yields, never hands back | on | = | WO-102 | — | live-and-wanted |
| `mp_authority_pause_on/off` (`wo102.authorityPause`) | the non-authority issues `wh_ai_PauseNPC <name>` when a puppet starts, `wh_ai_ResumeNPC` on release | **off** (WO-104) | **on** | WO-102 P4 | — (WO-104 turned it off on a misread metric; WO-107 refuted the misread) | live-and-wanted |
| `mp_npc_replica_on/off` (`KCD2MP.npcReplica.enabled`) | on a violation, hide the world NPC and spawn a brainless soul-bound replica driven by the stream | **on** | **off** | WO-104 | WO-106 §5: structurally dead — `SharedSoulGuid` indexes an authored database a live WUID is never in; 36/36 refusals, has never promoted | live-but-superseded |
| `mp_npc_proximity on/off` (`KCD2MP.npcProx.enabled`) | non-authority claims NPCs near its own player (claim model) | on | = | WO-60 | WO-102 P4 bypasses it entirely under host authority (`KCD2MP_NpcSyncTick` returns before it) | live-but-superseded — **but only reachable with `mp_authority_host_off`**, where it is the 0.23.2 rollback path; left on so the rollback stays intact |
| `mp_npc_yield_on/off` (`KCD2MP.npcYield.enabled`) | hand a puppet back to the local brain after sustained sub-8 m contention | **on** | **off** | WO-99 | WO-102 P4: under host authority the `enabled` flag is never consulted — the host-authority branch turns the same measurement into a violation, never a yield | live-but-superseded (a no-op under the shipped model; off makes the status line truthful) |
| `mp_npc_yield <dispM> <ticks> <repinM>` (`npcYield.dispM/ticks/repinM`) | thresholds; **still used** under host authority as the contention detector's displacement + streak | 0.30 / 10 / 1.0 | = | WO-99 | — | live-and-wanted (as violation thresholds) |
| `mp_npc_diverge on/off/<m>` (`KCD2MP.npcDiverge`; `MP_NPC_DIVERGE_M`=8, 3 hits / 30 s, stand-off 180 s) | release a puppet the local world drags ≥8 m three times in 30 s; refuse to re-puppet for 180 s | on | = | WO-90 (stand-off 180 s: WO-94) | WO-102 P4 refuses the release under host authority (logs `kind=diverge` instead) | unresolved — inert under host authority; not established as the snap-jitter source, so left on (§2.3 rule) |
| `mp_npc_cull_on/off` (`wo1025.npcCull`; `cullRadius`=30 m has no console door) | owned NPCs beyond 30 m of every anchor are tracked but not streamed | on | = | WO-102.5 P3 | — | live-and-wanted |
| `mp_authority_radius <m>` (`wo1025.authorityRadius`, floor 10) | ownership radius around every anchor | 300 | = | WO-102.5 (console door WO-106) | — | live-and-wanted |
| `mp_together_params <enter> <exit> <dwell>` (`wo1025.togetherEnterM/ExitM/DwellS`) | session-level together/apart hysteresis | 60 / 90 / 10 | = | WO-102.5 P4 (setter WO-106) | — | live-and-wanted |
| `mp_npc_scan_native_on/off` (`wo102.npcScanNative`) | rescan candidates come from the agent's native scan push | on | = | WO-102.5 P2 | — | live-and-wanted |
| `mp_npc_read_native_on/off` (`wo1025.readNative`) | tracked-NPC pos/yaw from the native push when fresh; fails closed on a real mismatch | on | = | WO-103 P2 | — | live-and-wanted |
| `mp_pos_native_on/off` (`wo102.posNative`) | agent reads the local player over the DLL pipe (agent-side) | on | = | WO-102 P1 | — | live-and-wanted |
| `mp_resync_npcs` | one-shot NPC resync burst (flag bit 64) | command | = | WO-102 P6 | — | live-and-wanted |
| **new** `mp_resume_dwell <s>` (`wo1025.resumeDwellS`) | seconds a released puppet's pause is held before `wh_ai_ResumeNPC` | — | 10 | WO-108 | — | live-and-wanted |
| **new** `mp_resume_all` | resume every NPC paused this session and switch the lever off | — | command | WO-108 | — | live-and-wanted |
| **new** `mp_preset_clean` / `mp_preset_legacy` | re-apply the 0.26.4 / 0.26.3 defaults (authority model untouched) | — | command | WO-108 | — | live-and-wanted |

## 2. NPC stream: receiver rendering and sender emission

| toggle | what it does | 0.26.3 | 0.26.4 | introduced | superseded by | status |
|---|---|---|---|---|---|---|
| `mp_npc_sync on/off` (`KCD2MP.npcSync.enabled`) | master switch for NPC emission in every role | on | = | WO-32 | — | live-and-wanted |
| `mp_npc_smooth on/off` (`KCD2MP.npcSmooth`) | time-based interpolation-behind (1.2 × emit period); off = per-tick 0.5 lerp | on | = | WO-77 | — | live-and-wanted. **Not stacked**: the two renderers are an if/else, and the WO-69 yaw lerp lives only inside the legacy branch |
| `mp_puppet_rate <ms>` (`KCD2MP.npcPuppetTickMs`, floor 10) | puppet write/tick period | 50 | = | WO-106 | — | live-and-wanted (the unrun write-rate A/B) |
| `mp_npc_deathsync on/off` (`KCD2MP.npcDeathSync`) | NPC deaths cross to peers; a locally-dead body never follows a living stream | on | = | WO-86 | — | live-and-wanted |
| `mp_npc_chainfix on/off` (`KCD2MP.npcChainFix`) | a leaked puppet-tick chain exits when detected | on | = | WO-69 (default on: WO-78) | — | live-and-wanted |
| `mp_ghost_chainfix on/off` (`KCD2MP.ghostChainFix`) | same for the ghost interp chain | on | = | WO-78 | — | live-and-wanted |
| `mp_npc_fight` | dump per-puppet tug-of-war attractors | command | = | WO-40 | — | live-and-wanted (diagnostic) |
| (no door) `npcSync.emitMs` | per-NPC emit period for a MOVING NPC | 100 | = | WO-77 (was 250, WO-32) | — | live-and-wanted |
| (no door) `npcSync.heartbeatS` | idle resend | 2.0 | = | WO-32 | — | live-and-wanted |
| (no door) `npcSync.releaseS` | receiver drops a puppet after this much silence | 3.0 | = | WO-32 | — | live-and-wanted |
| (no door) `npcSync.moveEps` | below this nothing is emitted | 0.05 | = | WO-32 | — | live-and-wanted |
| (no door) `npcSync.scanMs` | tracked-set rebuild cadence | 2000 | = | WO-32 | — | live-and-wanted |
| (no door) `npcSync.radius` / `maxTracked` | 0.23.2 claim-model bounds | 30 / 5 | = | WO-32 | WO-102.5 P3 (uncapped ownership under host authority) | live-but-superseded — reachable only with `mp_authority_host_off`; left as the rollback |
| (no door) `NPC_RECONCILE_INTERVAL_S` | pause-reconcile + replica-sweep cadence | 5.0 | = | WO-102.5 P1 | — | live-and-wanted |
| (no door) `NPC_ENGAGE_RANGE_SQ` | 12 m: armed NPC next to a player = engaged (flag 32, cull-exempt, relay hold) | 12 m | = | WO-60 | — | live-and-wanted |
| (no door) `NPC_TRACK_EXIT_FACTOR` / `NPC_TRACK_STICKY_BONUS` | tracked-set hysteresis | 1.5 / 8 m | = | WO-32/60 | — | live-and-wanted |
| (no door) `MP_NPC_RESYNC_RADIUS` / `MAX` | resync burst bounds | 60 m / 40 | = | WO-102 P6 | — | live-and-wanted |
| (no door) `npcReplica.sheathedDemoteS` / `orphanSweepM` | replica lifetime rules | 10 s / 60 m | = | WO-104 | WO-106 §5 (see replica row) | off-and-dead in 0.26.4 (the orphan sweep itself still runs — cleanup must not depend on the switch) |
| (no door) `DRAG_RADIUS/MIN_MOVE/TAIL_S/SCAN_MS` | drag sensor: a non-authority claims a body its player is dragging | 6 m / 0.3 / 3 s / 500 | = | WO-39 P2 | WO-102 P4 bypasses the drag sensor under host authority | live-but-superseded — rollback path only; left as is |
| `mp_npc_scan_compare` / `mp_npc_read_compare` | known-answer checks for the two native paths | command | = | WO-102.5 / WO-103 | — | live-and-wanted |

## 3. Ghost (peer body) behaviour

| toggle | what it does | 0.26.3 | 0.26.4 | introduced | superseded by | status |
|---|---|---|---|---|---|---|
| `mp_ghost_ignorant on/off` (`KCD2MP.ghostsIgnorant`) | `AI.SetIgnorant` on every ghost | on | = | WO-38/40 | — | live-and-wanted |
| `mp_ghost_isolate on/off` (`KCD2MP.ghostIsolate`) | RestrictDialog + InterruptDialogs on ghosts | on | = | WO-65 | WO-68 shipped the native crime fix; the dialog half is still this | live-and-wanted |
| `mp_ghost_nai_on/off` (`KCD2MP.ghostNai`) | spawn ghosts as `NPC_NAI` | off | = | WO-100.5 | WO-100.5 §1.3 itself: `SpawnEntity` substitutes NPC for NPC_NAI | off-and-dead |
| `mp_ghost_noai_on/off` (`KCD2MP.ghostNoAi`) | spawn ghosts with `NoAI=true` | off | = | WO-100.5 | — | unresolved — works (WO-100.5 §1.4) but removes the WO-26 reactive self-defence the maintainer kept; nobody has decided |
| `mp_anim_legacy_on/off` (`KCD2MP.animLegacy`) | infer ghost locomotion from packet speed instead of Mannequin tags | off | = | WO-100.5 | — | live-and-wanted (rollback) |
| `mp_ghost_anim_refresh <s>` (`KCD2MP.ghostAnimRefreshS`) | looped-clip keep-alive period; 0 = restart every tick | 1.0 | = | WO-84 | — | live-and-wanted |
| `mp_horse_adopt on/off` (`KCD2MP.horseAdoptEnabled`) | ghosts ride real world horses | on | = | WO-40 P0 | — | live-and-wanted |
| `mp_enable_aggro on/off` (`KCD2MP.aggroEnabled`) | hostile-faction attach so NPCs attack ghosts | off | = | WO-17/27 | — | unresolved (opt-in by design) |
| `mp_ghost_sweep on/off/now` (`KCD2MP.orphanSweep`) | remove `kcd2mp_` bodies a savegame restored with no ghost behind them | on | = | WO-58 (in-play: WO-84) | WO-106 P5 `ENTITY_FLAG_NO_SAVE` should make it moot for new saves | live-and-wanted (backstop until a save without strays is observed) |
| `mp_reconcile` | respawn ghosts a save load destroyed (agent calls every 5 s) | command | = | WO-28 | — | live-and-wanted |
| `mp_sneak_on/off`, `mp_slow_time`, `mp_fake_death`, `mp_log_actions` | manual overrides / test aids | off | = | various | — | live-and-wanted (diagnostic) |

## 4. Other systems (not NPC-jitter related; listed for completeness)

| toggle | what it does | 0.26.3 | 0.26.4 | introduced | status |
|---|---|---|---|---|---|
| `mp_item_sync on/off` (`KCD2MP.itemSync.enabled`; scanMs 750, radii 8/70/80 m, max 32) | dropped-item sync | on | = | WO-48 | live-and-wanted |
| `mp_quest_on/off`, `mp_quest_radius` (35), `mp_quest_window` (120), `mp_quest_gap` (60) | shared main-quest readiness prompt | on | = | WO-94/96 | live-and-wanted |
| `mp_dice_gate on/off` (`KCD2MP.dice.requireTable`) | require a real table for `mp_dice` | **off** ("default off for testing") | = | WO-5/57 | unresolved — the source comment says shipping behaviour is on; nobody flipped it |
| `mp_dice_wager <n>` | groschen staked | 0 | = | WO-33 | live-and-wanted |
| `mp_debug_hud on/off` (`KCD2MP.debugHud`) | `r_DisplayInfo` | off | = | WO-50 | live-and-wanted |
| `mp_emit_on/off`, `mp_start/stop` | transport loops (agent re-arms) | on | = | WO-1 | live-and-wanted |
| `mp_weather`, `mp_map_marker`, `mp_probe_*`, `mp_test_*`, `mp_scan_*`, `mp_spawn_*`, `mp_combat_*`, `mp_anim_tag`, `mp_entity_id`, `mp_summary`, `mp_vitals`, `mp_wo102_status`, `mp_npc_replica_status`, `mp_riding_state`, `mp_ghost_state`, `mp_inspect`, `mp_find_*` | probes and reports, no state | command | = | various | live-and-wanted (diagnostic) |
| (no door) `emitIntervalMs` | player-state emit period (agent passes `EmitIntervalMs`=20) | 20 | = | WO-1 | live-and-wanted |
| (no door) `TICK_ALIVE_WINDOW`, `CHAIN_PROBE_MS/SETTLE/REARM` | chain liveness gate | 1.0 s / 400 / 200 / 3.0 | = | WO-13 / WO-78 | live-and-wanted |
| (no door) `STRAY_SWEEP_EVERY_S` / `MAX_ID` | stray-ghost sweep cadence | 30 s / 63 | = | WO-58/84 | live-and-wanted |
| (no door) `NPC_SMOOTH_DELAY_FACTOR` / `RING` / `ANIM_GRACE_S` | interpolation-behind tuning | 1.2 / 3 / 0.06 | = | WO-77 | live-and-wanted |
| `mp_probe_npc_pause` | the WO-102 P3 solo pause probe (pauses the nearest NPC, moves it, resumes) | command | = | WO-102 P3 | live-and-wanted (diagnostic; its "SNAPPED BACK" verdict measures the WO-107 §4 relax, not a brain — help text corrected) |

## 5. Agent-side defaults that gate the same behaviour (`ClientConfig.cs`)

Not `kdcmp.lua`, listed because the shipped state of three rows above is
decided here: `HostAuthorityEnabled=true`, `NativePositionEnabled=true`,
`NpcScanNativeEnabled=true`, `EmitIntervalMs=20`. The pause lever is **not**
pushed by the agent — its Lua default is its shipped default. (code-verified)

## 6. Summary of 0.26.4 default changes

Exactly three flags change. Everything else is `=`.

| flag | from → to | justification |
|---|---|---|
| `wo102.authorityPause` | off → **on** | WO-107 §3/§8 (lever works, latched, multi-owner; WO-104's 0/155 was a Lua-table field plus the §4 relax); WO-108 Phase 0 (bit does not survive any load path); `memory/kcd2mp-ship-new-features-on.md` |
| `npcReplica.enabled` | on → **off** | WO-106 §5 (dead end: `SharedSoulGuid` cannot address a live NPC; has never promoted; runs a refusal path per violation for nothing) |
| `npcYield.enabled` | on → **off** | WO-102 P4 (never consulted under host authority — a no-op flip that stops the status line lying); its thresholds stay live as the violation detector |

Rows left `unresolved`: `mp_npc_diverge`, `mp_ghost_noai`, `mp_enable_aggro`,
`mp_dice_gate`. Rows left `live-but-superseded` but deliberately **not**
flipped because they are only reachable under `mp_authority_host_off` and
are that rollback's substance: `mp_npc_proximity`, `npcSync.radius/maxTracked`,
the drag sensor. Nothing was guessed into a status.
