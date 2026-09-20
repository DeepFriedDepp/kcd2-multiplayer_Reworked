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
- [ ] Phase 6 — audit. Not started.
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

## Next steps (in order)

1. Phase 6 audit doc (`docs/WO-106-native-migration.md`) — the only phase
   left besides Phase 3.
2. Phase 3 stays blocked until a two-player session exists. Decide then
   (not now) whether to ship the rate-mitigation tunable ahead of the
   mechanism test, per the brief's §3.4 — deliberately not decided this
   session since the point of §3.2's test is to run it BEFORE building
   anything.
3. Rebuild the pak (`tools\Build-And-Install-Mod.ps1`, game closed first)
   and run every post-deploy test listed in findings §3.6 (Phase 1) and
   §6.5 (Phase 5) before trusting any of this in a real session.
4. Ask the maintainer for the exact VERSION string before any end-gate
   build — do not guess or auto-increment.
