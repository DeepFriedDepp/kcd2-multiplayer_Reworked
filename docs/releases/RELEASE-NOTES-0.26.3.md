# KCD2-MP 0.26.3 — console commands actually take arguments now

The label for everything on `main` as of WO-106 (2026-09-19), packaged as
`KCDMP-Setup-0.26.3.exe`. Setup exe only. **To go back:** the tag
`rollback/0.26.2` and `KCDMP-Setup-0.26.2.exe`, or `rollback/0.26.1` two
steps back.

---

## The fix: every argument-taking console command was silently broken since WO-17

If you ever typed `mp_authority_pause on` or `mp_npc_yield 0.3 10 1.0` (or
almost any `mp_*` command with an argument) and either saw `[Warning] Too
many arguments for: ...` or nothing happened at all, this is why.
`System.AddCCommand`'s argument placeholder is `%line` — **lowercase**.
Every command in this mod that needed an argument was registered with
`%LINE` — uppercase — since WO-17. The engine's placeholder lookup is
case-sensitive, so it silently matched nothing: typing an argument got
refused outright, and typing the command bare fed it the literal text
`%LINE` instead of "no argument". Both symptoms this project chased across
several work orders (`docs/WO-94-findings.md`, `docs/WO-98-log-format.md`)
turn out to be one four-letter typo.

**Fixed:** every `%LINE` in the console command registration is now
`%line`. Confirmed live before the fix went in — a disposable test command
reproduced both symptoms exactly, and the corrected case fixed both at
once, no other change needed. Two commands that previously had **no**
console form at all — `mp_authority_radius <metres>` and
`mp_together_params <enterM> <exitM> <dwellS>` — now have one; both were
already working Lua functions, only reachable before through the `#Lua`
console syntax.

**Verification status: (observed)** for the underlying case bug and its
fix, tested against a live disposable console command this session. **Not
yet observed for the ~30 real `mp_*` commands this build changes** — this
release is the first time the fix ships in an actual pak. See the test
list below before relying on any of them in a real session.

---

## New: `mp_puppet_rate <ms>` — change the NPC puppet write rate mid-session

Default 50 ms, unchanged from every prior build. Lower it (floor 10 ms)
to test whether an NPC sinking into the ground under another player's
control gets better or worse — the current working theory (from reading
CryEngine's own source, `docs/WO-105-cryengine-reference.md` §4.4/17.1) is
that every position write to a puppeted NPC releases its ground collider,
and the symptom should scale with **how often** it's written, not how far.
Takes effect on the very next tick — no reconnect, no restart. This ships
as a diagnostic tool, not a fix: the live two-player test that would
confirm or refute the mechanism has not been run yet. If you can, try
lowering it (`mp_puppet_rate 200`, `mp_puppet_rate 500`) next time an NPC
sinks and report what you see.

---

## Also in this build (no visible behavior change expected)

* **`ENTITY_FLAG_NO_SAVE` applied to every mod-spawned body** (replicas,
  ghosts, proxy horses, test spawns, the dropped-item placement anchor).
  These should no longer be written into your save file at all, rather
  than being cleaned up by the existing periodic sweep after the fact.
  The sweep stays as a backstop. A real dropped item from a peer is
  deliberately **not** covered by this — it should keep persisting across
  saves exactly as before.
* **A small number of hot per-tick position reads reuse a scratch table**
  instead of allocating a fresh one every call (player position, NPC
  puppet reads, ghost interpolation). Aimed at reducing per-frame garbage
  collector work at high NPC counts. No measured before/after exists yet
  for this build — flagged honestly rather than claimed.
* The NPC replica system (WO-104, still `mp_npc_replica_on` by default)
  was investigated further and is **confirmed still blocked**, for a
  clearer reason than before: the identifier it needs
  (`SharedSoulGuid`) indexes a different, unrelated database than a live
  NPC's own runtime id. This is a completed investigation, not a new
  limitation — nothing behaves differently because of it.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` all from the same build. **No wire/protocol change
this release** — the relay is untouched and 0.26.2 peers would still
connect — but every fix above lives in the pak, so a mixed pair gets none
of them reliably from the older side. Verify hashes from your OWN
terminal (`certutil -hashfile`), never through the coding assistant's
shell.

---

## What to test before a real session (from `docs/WO-106-findings.md`)

1. `mp_authority_radius 45` then `mp_npc_cull_on` — confirm
   `WO1025-RADIUS set=45.0` in `kcd.log`, not a rejection or a silently
   unchanged default.
2. `mp_together_params 60 90 10` — confirm
   `WO1025-TOGETHER-PARAMS enterM=60.0 exitM=90.0 dwellS=10.0`. Then
   `mp_together_params 90 60 10` (inverted) should be **rejected**.
3. `mp_npc_yield 0.3 10 1.0` — confirm `NPC-YIELD ENABLED dispM=0.30
   ticks=10 repinM=1.00`, typed bare, no `#` prefix.
4. `mp_puppet_rate 100` — confirm `NPC-PUPPET-RATE set=100ms was=50ms`.
5. Spot-check two or three other `on|off` toggles typed bare (e.g.
   `mp_ghost_ignorant on`, `mp_debug_hud on`) — no `Too many arguments
   for:` warning.
6. If any of the above fails, check the pak actually rebuilt (compare
   `kdcmp.pak`'s size/timestamp to the previous build) before assuming the
   source fix is wrong.

---

## Verification status, stated plainly

| item | status |
|---|---|
| console placeholder case fix | (observed) on a disposable test command; (synthetic) `tools/Test-WO106ConsolePlaceholder.ps1` 5/5; **not yet observed on the ~30 real commands this build changes** |
| `mp_puppet_rate` | (observed) the setter and reschedule live; **the ground-collider hypothesis it exists to test is unconfirmed — no two-player session has run it yet** |
| `ENTITY_FLAG_NO_SAVE` on spawned bodies | (observed) the flag is set on a live test entity; **not yet observed across an actual save/reload in this build** |
| vector-getter scratch tables | (code-verified) reviewed by hand for the "returns a stored reference" trap; **no before/after performance measurement taken** |
| replica soul-id investigation | (observed) live, both candidate forms refused, a known-good GUID accepted as a control — conclusive, not a behavior change |
| everything from 0.26.2 | unchanged | time sync, pause-lever-off, replica toggle default all untouched |

Full write-up: `docs/WO-106-findings.md`, `docs/WO-106-progress.md`,
`docs/WO-106-native-migration.md`.
