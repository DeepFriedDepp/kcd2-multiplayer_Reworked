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

## Update: 0.26.3 built and delivered

Between drafting this doc and now, the maintainer asked for two more
things in the same session: a runtime `mp_puppet_rate <ms>` command (the
Phase 3 mitigation tunable, shipped with default 50ms unchanged) and an
installer build for their tester.

The end-gate build ran for real: `rollback/0.26.2` tagged at `ebb0046`,
`VERSION` bumped to `0.26.3`, README badge + release notes updated
(`docs/releases/RELEASE-NOTES-0.26.3.md`), built from a **fresh clone of
origin/main**, not the working tree. The first build attempt correctly
**failed its own release gate** — `Test-WO104Synthetic.ps1` hit 7 "no Lua
errors" failures, all from the same cause: Phase 5's new
`entity:SetFlags` call had no mock in the synthetic test harness's
`mkEntity`. Fixed the mock (not the mod — the real `SetFlags` call was
already live-verified against the actual game earlier this session),
re-cloned fresh, rebuilt clean: relay round-trip 13/13, agent unit tests
170/170, WO-102 synthetic 196/196, WO-104 synthetic 92/92.

Privacy sweep: zero occurrences of the real username anywhere in the
built payload (checked UTF-8 and UTF-16LE, every file in the release
folder, not just text files). Pak content check: extracted
`Scripts/Startup/kdcmp.lua` from the built `kdcmp.pak` directly, confirmed
all 41 of this session's markers present and zero uppercase `%LINE` in
any `AddCCommand` call — the shipped pak is not stale.

`KCDMP-Setup-0.26.3.exe` (100,581,707 bytes, SHA256
`60cacbd6aa43ac57120cac27d6560a0a421f0696cfec8c518e0a9330815193a2` as
computed in this session's own shell — the maintainer should still
re-verify independently before trusting it, per this project's own
standing rule about not trusting the coding assistant's shell for
verification) sent directly to the maintainer. **Not published as a
GitHub Release** — only asked for a build, not a public release; that's a
separate, more visible action to confirm first if wanted.

**Important caveat carried into this build: none of Phase 1/2/3/5's
actual behavior has been tested against the real running game with THIS
pak.** The synthetic suites run under MoonSharp against mocked engine
objects, not the real CryEngine Lua sandbox — they caught a real gap
(the missing `SetFlags` mock) but cannot substitute for the live
console-command checklist in `docs/WO-106-findings.md` §3.6/§6.5 and this
release's own release notes. The tester's first session with 0.26.3 is
the first real-world test of everything this WO changed.

## Session complete except Phase 3

All phases with no live-two-player gate are done: Phase 0 (probes),
Phase 1 (console placeholder), Phase 2 (table churn), Phase 4 (replica
dead end), Phase 5 (`ENTITY_FLAG_NO_SAVE`), Phase 6 (audit), plus the
Phase 3 mitigation tunable (`mp_puppet_rate`) and a full end-gate build to
0.26.3 (see "Update: 0.26.3 built and delivered" above). Every commit
pushed to `origin main`.

**Phase 3's live write-rate A/B test is the only thing not attempted** —
it needs a live two-player session per its own design (halving the
puppet write rate on one NPC and watching whether sinking improves), and
the maintainer confirmed none tonight. The mitigation the test would
confirm or refute ships anyway, per the brief's own "ship the tunable
regardless" guidance — it does nothing until someone runs `mp_puppet_rate`.

## Next steps (in order)

1. **The post-deploy test checklist** (findings §3.6, §6.5, and this
   release's own release notes) — the game was closed for the whole build
   process, so nothing in 0.26.3 has been exercised against the real
   engine yet. This is the tester's job now.
2. Phase 3, next time a peer is available: the live write-rate test using
   the now-shipped `mp_puppet_rate`, per its own field runbook shape
   (§3.2 of the WO-106 brief).
3. The Phase 6 audit's recommended next WO: multi-anchor before/after for
   the `GetEntitiesInSphere`→`GetPhysicalEntitiesInBox` swap on
   `mp_npc_rescan`, before touching that code.
   actually happening, since an end-gate build from a tree that was never
   locally verified live would be building blind on Phase 1/2/5's changes.
