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
- [ ] Phase 2 — vector-getter table churn (unconditional, in progress /
      not yet started as of this checkpoint).
- [ ] Phase 3 — ground-collider mechanism. **Blocked: no peer tonight.**
      Not attempted. The mitigation half (runtime-settable puppet emit
      rate) is a candidate to still ship per the brief's §3.4 — decision
      not yet made as of this checkpoint.
- [ ] Phase 4 — replica soul-id. Cleared by 0.4 (Branch B, 64-bit
      `ScriptHandle` hex). Attempt not yet made as of this checkpoint.
- [ ] Phase 5 — `ENTITY_FLAG_NO_SAVE`. Cleared by 0.2. Not yet started as
      of this checkpoint.
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

1. Phase 2 (unconditional) — no gate, can run without a rebuild decision.
2. Decide and record: does Phase 3's rate-mitigation tunable ship this
   session despite the mechanism itself being untested tonight? (Brief
   §3.4 says the tunable is worth shipping regardless; the *mechanism* is
   not being marked confirmed either way without the live A/B.)
3. Phase 4 attempt (soul-id Branch B: try the bare 16-hex-digit string as
   `SharedSoulGuid`).
4. Phase 5 (`ENTITY_FLAG_NO_SAVE` on every mod-spawned entity).
5. Phase 6 audit doc.
6. Ask the maintainer for rebuild/deploy/live-test timing and the exact
   VERSION string before any end-gate build.
