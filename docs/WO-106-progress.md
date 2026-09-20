# WO-106 — progress

Session 2026-09-19. Findings: `docs/WO-106-findings.md`. Solo session
(maintainer confirmed no two-player session tonight) — Phase 3's live test
is blocked for this reason and is explicitly NOT attempted.

## Status

- [x] Read `docs/WO-105-cryengine-reference.md` and
      `docs/WO-105-contradictions.md` in full before starting.
- [x] Cross-checked WO-105's cited numbers directly against `kdcmp.lua`
      rather than trusting the prompt's digest: 84 `GetWorldPos()`, 13
      `GetWorldAngles()`, 28 `GetEntitiesInSphere` — all exact. 41 total
      `%LINE` occurrences (33 in `AddCCommand` templates, the rest in
      comments/sentinel checks).
- [x] Phase 0 — all 5 probes run live, solo, recorded. 5/5 confirmed, 0
      refuted, 0 inconclusive. Gate table in findings §1.6.
- [x] Phase 1 — console placeholder fixed in source (`kdcmp.lua`), two new
      commands added (`mp_authority_radius`, `mp_together_params`),
      `_on`/`_off` pairs audited and deliberately left as pairs, synthetic
      check added and passing (`tools/Test-WO106ConsolePlaceholder.ps1`,
      5/5). **Not rebuilt into the pak, not deployed, not live-tested in
      game this session** — game was mid-session for the Phase 0 probes.
      See findings §3.6 for the exact post-deploy test list.
- [x] Phase 2 — vector-getter table churn. 9 hot call sites converted
      across `KCD2MP_EmitState`, `KCD2MP_NpcSyncTick`,
      `KCD2MP_NpcPuppetTick`, `KCD2MP_InterpTick`; one reusable scratch
      table per call site, none shared. Left ~88 one-off sites untouched
      (scope discipline). **No before/after measurement taken** — needs
      the rebuilt pak deployed; recorded as a gap, not silently skipped.
- [ ] Phase 3 — ground-collider mechanism. **Blocked: no peer tonight.**
      Not attempted, not faked. The mitigation half (runtime-settable
      puppet emit rate) was NOT shipped this session either — no decision
      was made to build it without the confirming test in hand.
- [x] Phase 4 — replica soul-id. Cleared by 0.4 (Branch B). **Attempted
      and concluded: dead end.** Bare hex and correctly-padded dashed
      WUID both fail live (`is not in the database`); a known roster GUID
      succeeds as a control. No code changed in the promote path — the
      existing fail-closed gate was already correct. See findings §5.
- [x] Phase 5 — `ENTITY_FLAG_NO_SAVE`. Cleared by 0.2. Applied at all 8
      real spawn sites (replica, ghost x3, horse proxy, armored-NPC test,
      horse-class-probe test, XGen test, item-drop anchor). Mechanism
      live-verified on a disposable entity, not just compiled. Hidden-
      original half of the save hazard deliberately deferred to the
      existing WO-84 sweep (recorded decision, findings §6.4).
- [x] Phase 6 — audit. `docs/WO-106-native-migration.md`. Live tests this
      session found a build-specific divergence from the WO-105 stock
      reference: `System.GetPhysicalEntitiesInBox` takes `(center,
      radius)` on this build, not two corner points, and the CVar WO-105
      named for gating it doesn't exist here at all -- yet the grid
      clearly works (262 real results vs the sphere walk's 698, and MORE
      named humans than the sphere walk at the same radius, confirming
      the "box not sphere" over-inclusion caveat live). Redesign of
      `mp_npc_rescan` recommended as WO-106's own next WO, not attempted
      this session.
- [ ] End gate build. Not started. **No VERSION bump without the
      maintainer naming the exact string first** (standing rule).

## Environment this session

- Live game: 0.26.2, Modding Tools, solo save, maintainer at the keyboard.
- Debug console driven from the coding shell via
  `http://127.0.0.1:1403/api/System/Console/ExecuteString` (GET,
  `command=` query param — see findings §2 for the exact working shape,
  which differs from how WO-103 described it).
- `kcd.log` read directly at
  `D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log` — not sandboxed,
  unlike the AppData-based retail install path (`memory/appdata-sandbox-
  redirection.md` does not apply to this path).
- A stray git worktree exists at
  `.claude/worktrees/loving-curie-50182f` (branch
  `claude/loving-curie-50182f`) from an unrelated prior session. Not
  touched, not part of this WO.

## Session complete except Phase 3 and the end gate

All phases with no live-two-player gate are done: Phase 0 (probes),
Phase 1 (console placeholder), Phase 2 (table churn), Phase 4 (replica
dead end), Phase 5 (`ENTITY_FLAG_NO_SAVE`), Phase 6 (audit). Every commit
pushed to `origin main` (`b99cc46`, `6ce6ece`, `03510ae`).

**Phase 3 is the only phase not attempted** — it needs a live two-player
session per its own design (halving the puppet write rate on one NPC and
watching whether sinking improves), and the maintainer confirmed none
tonight.

## Next steps (in order)

1. Rebuild the pak (`tools\Build-And-Install-Mod.ps1`, game closed first)
   and run every post-deploy test listed in findings §3.6 (Phase 1) and
   §6.5 (Phase 5) before trusting any of this in a real session. **Not
   done this session** — the maintainer was mid-session for the Phase 0
   probes throughout, and closing the game was never asked for or given.
2. Phase 3, next time a peer is available: the live write-rate test, per
   its own field runbook shape (§3.2 of the WO-106 brief).
3. The Phase 6 audit's recommended next WO: multi-anchor before/after for
   the `GetEntitiesInSphere`→`GetPhysicalEntitiesInBox` swap on
   `mp_npc_rescan`, before touching that code.
4. End-gate build (VERSION bump, README badge, installer, release notes)
   — **not started, and not to be started without the maintainer naming
   the exact VERSION string first** (standing rule). Also gated on step 1
   actually happening, since an end-gate build from a tree that was never
   locally verified live would be building blind on Phase 1/2/5's changes.
