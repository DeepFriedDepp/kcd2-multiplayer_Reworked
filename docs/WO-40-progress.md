# WO-40 progress

Worked 2026-08-20. Full detail: `docs/WO-40-findings.md`. Evidence base:
`docs/WO-40-footage-findings.md` + the first real two-machine log bundles
(`docs/WO-40-test-logs/`), both read in full.

| Phase | Item | State |
|---|---|---|
| pre | Footage findings + both log bundles committed; bundles read in full via two dedicated readers | **Done.** Neither bundle contained kcd.log or config.json (collector bugs, fixed in Phase 0); joiner agent logs contain ZERO NPC-sync/cue telemetry (it all lives in kcd.log). |
| 0 | The host's two crashes | **Real, both** (abrupt game deaths, no menu open, launcher exits all clean-marked). Both within ~1.5 s of a ghost riding=False→True (2 of only 5 all session); crash #2 lands exactly on fresh-spawn + 400 ms ForceMount. Fixes: occupied-horse guard, 3 s fresh-spawn mount deferral, `mp_horse_adopt off` escape hatch. Honest label: strongest-correlated suspect mitigated, not a proven root cause. Also fixed: COLLECT LOGS now really collects kcd.log (walk-up + Steam scan) and settings.json; agent log rotation two-deep. |
| 1 | Repo investigations (first) | **Done, productive.** Weather write surface found (`EnvironmentModule.BlendTimeOfDay`, in the game's own scripts); real jump/vault/sleep/takedown clip names from Animations.pak; `Human:PlayAnim` TAG vocabulary + `AI.SetAnimationTag` (untried levers); libKCD2 (GPL-3.0, docs-only) maps the native Mannequin QueueAction route incl. verified vtable slots; kcd2lua/kcd2db (MIT) give hot-reload + save/load-listener patterns; retail dump proves `AI.GetFactionOf`/`SetFactionOf`/`AddPersonallyHostile` exist (memory corrected). |
| 2 | Pause-freeze, NPC-sync side | **Fixed by reapplying WO-13's pattern** — the menu pump now drives `KCD2MP_NpcPuppetTick` too (50 ms-throttled). Gate not used. Dialogue-not-detected-as-pause recorded as a follow-up lead. |
| 3 | Weather sync | **Built + wire-verified** (0x2E/0x2F, T15). Mod-arbitrated (no current-profile read exists): damage-authority holder picks/broadcasts, ~20 min repick, 2 min heartbeat, silent solo, `--no-weather-sync` opt-out, `mp_weather` probe. Live render check pending. |
| 4 | Reload as fourth time trigger | **Built.** Backward clock jump = reload; with live peers the reloader fast-forwards ITSELF to the session clock (backward writes are engine-ignored, so convergence is forward and the reloader's). Solo reloads untouched. Double-report bug (kind=2+kind=0 for one sleep) fixed. The 24.5 h desync mechanism fully evidenced in the bundles. |
| 5 | Entity lifecycle bugs | **Diagnosed, gate NOT earned.** Double-render = schedule divergence (NPC-sync cannot spawn duplicates by construction); three-point phasing gets `mp_npc_fight` (attractor-clustering tug-of-war meter) since logs were dark; global anim collapse is load-correlated → zero-damage hit flood gated at sender + puppet anim churn cut 20x. Per-save-Guid instability FIELD-CONFIRMED (571/571 vs 176/176) → name-addressed NPC damage 0x30/0x31 built + wire-verified (T16). |
| 6 | Combat viz on puppets + quality | **Extended:** 0x26 bits 2 (drawn) + 3 (swing cue via authority self-damage attribution); guard-stance idle; pinned one-shots on puppets; paired takedown clips on KO-next-to-ghost; choke miscue fixed (no block cue while sheathed). Quality: tag-vocabulary probes ready (`mp_combat_frag`, `mp_anim_tag`); native QueueAction escalation mapped but NOT invoked. All render claims live-gated. |
| 7 | Knockout-then-carry | **Diagnosed** (KO never crossed = the guid problem; 0x30 fixes it) **+ carried flag** (npc_drag bit 4, <1.5 m glued) with smooth-follow on receivers. |
| 8 | Jump + fence vault | **Real clip names shipped** in the probe lists (`relaxed_jump_idle`, `relaxed_jump_over_obstacle_*` — the exact clip the game's JumpOver fragment plays). `mp_combat_probe` dumps all lists. Render check live-gated. |
| 9 | Ghost-brain crime/aggro | **Ghosts stimulus-deaf by default** (WO-38 recommendation + WO-39 targeting-safety + this footage). `mp_ghost_calm` probes/clears per-pair hostility. WO-36's crime-cost measurements remain open (two-human). |
| 10 | Clothing directional regression | **Decoded as item data, gate NOT earned:** PB's outfit was quest-item aliases (alias_prepadeni_*); receivers now substitute all 40 ItemAlias classes with their sources. A→B vs B→A discrepancy between logs and footage recorded honestly; GambesonShort02_m03_E1 failure unexplained, live probe flagged. |

Suites: Test-TimeSkipRelay **26/26** (new T15 weather, T16 npc-damage).
Solution + launcher build clean. Pak rebuilt + installed locally.

**Session state / resume point:** all ten phases have shipped code or a
closed, evidenced diagnosis. What remains is the LIVE battery (game
confirmed available, save disposable): mount-guard exercise, weather render
(`mp_weather foggy_storm`), `SoulsByGuid` REST route check (0x30's sender
half), anim probes (`mp_combat_probe`, `mp_anim_tag`, tagged
`mp_combat_frag`, jump/vault/takedown renders), `mp_ghost_calm` bind
registration, reload convergence E2E, alias-item equip. If a fresh session
picks this up: read WO-40-findings.md end to end; every live item above is
one console command or one synthetic-peer script away.

**Live battery addendum (same day):** weather verified end to end (eyeball + rain readback, both snap and slow blend); SoulsByGuid route confirmed (0x30 premise); all five jump/vault/takedown clips RENDER on a calm ghost (brain-in-combat eats one-shots -- isolated deliberately); MotionJump is the first fragment ever seen rendering (shipped as the jump branch first choice); combat fragments stay locked even with tags -- the native escalation is now formally EARNED and documented, deferred as its own WO + license decision; all six hostility binds registered, ResetPersonallyHostiles real signature recovered from the engine error; the quest-alias clothing failure reproduced on demand and the alias-to-source fix validated at the equip layer. Repo pak rebuilt with the three live-tuning fixes; install pending game close.
