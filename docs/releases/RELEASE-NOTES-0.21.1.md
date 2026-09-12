# KCD2-MP 0.21.1

The label for everything on `main` as of WO-85 (2026-09-12), packaged as
`KCDMP-Setup-0.21.1.exe` and the update-only `KCDMP-DirectInstall-0.21.1.zip`.

WO-85 is a release-cut session: it did not write new mod behaviour, it built
and packaged three sessions' worth of already-merged work that had not gone
through a full production build together — **WO-83** (guard-class roster
fix, shipped in the 0.20.9 Setup exe already), **WO-84** (animation
throttle, chain-leak retirement, stray-ghost sweep, shipped in the 0.20.8
Setup exe already), and **WO-86** (NPC death sync, merged to `main` but never
before built into an installer). This is the first build where all three are
packaged together, and the first time WO-86's native DLL half has been
compiled and shipped at all.

**Verification status, stated plainly:** every fix below has passed its own
isolated tests — synthetic Lua suites and wire-level relay suites, 415
checks total across 12 suites this session, 0 failures. **The death-sync fix
is the one piece of this build that has never run in a real game.** It spans
four different parts of the system (native DLL, agent, relay, Lua mod) and
until a live two-player session runs it, "does a kill actually sync between
two real machines" is unconfirmed. The guard-roster fix and the
animation/leak/sweep fixes were already shipped in 0.20.9 and 0.20.8
respectively and carry no new risk here — this build just re-packages them
alongside WO-86.

---

## New in this build: NPC death now syncs between players

Until this build, no NPC's death was ever communicated between machines.
Each player's game guessed independently whether an NPC had died, using only
its own damage numbers — and because a killing blow was reported as the
victim's *remaining* health rather than the damage dealt, any earlier
disagreement between two machines' copies (a dropped packet, an earlier
fight one player wasn't in) could leave an NPC alive-and-hurt on one screen
**forever**, with nothing left to reconcile it. The same gap let a body that
was dead only on one machine get dragged around by position updates meant
for the other machine's still-living copy.

A killing blow now carries a FATAL flag over the wire; the machine that
receives it kills its own copy of that NPC to match, and a locally-dead body
no longer follows a still-moving stream. `mp_npc_deathsync off` restores the
old per-machine guessing if this needs to be turned off for any reason.

Verified synthetically (`tools\Test-WO86Synthetic.ps1`, 47/47) and the native
DLL rebuilt fresh for this build (327,680 bytes, confirmed via clean
recompile). **Not yet watched live** — this needs the pak, the agent and
`KCDMP.dll` from this exact build running together on two real machines,
which is explicitly the maintainer's own follow-up session, not this one's.

## Already shipped, carried forward: no roster ghost enforces the drawn-weapon rule

Seven of the nineteen ghost-roster souls carried the game's own "authority
figure" crime role (guard, and two soldier/huntsman classes with the same
flag), which made a ghost built from one of them warn and then fight a
nearby player who drew a weapon — real guard behaviour, running on a ghost
body. Those seven souls were replaced in place with commoners already
elsewhere in the roster; twelve of nineteen face slots are unchanged, seven
now map to a reused face. First shipped in `KCDMP-Setup-0.20.9.exe`; this
build carries it forward unchanged.

## Already shipped, carried forward: animation spam, stray-ghost cleanup, chain-leak false alarm

Three fixes from the project's first real two-player field session, first
shipped in `KCDMP-Setup-0.20.8.exe` and carried forward unchanged:

- A connected ghost's animation was being restarted on every 20 ms tick
  (up to 100 times a second) instead of only when it actually changed —
  `mp_ghost_anim_refresh` controls the keep-alive interval, `0` restores the
  old behaviour.
- Stray ghost bodies left behind in a savegame are now swept during play
  instead of only at shutdown — `mp_ghost_sweep on|off|now`.
- A second, distinct update-loop leak (separate from the one 0.20.6 fixed)
  that the earlier leak detector could not catch by design — a loop that
  legitimately restarts itself inside its own scheduled-tick window was being
  blamed for a leak it did not cause. Fixed; genuine leaks still report and
  toast, and are now counted separately from this one.

## Verified this session

Full regression pass, all green (415 checks, 0 failures):

| Suite | Result |
|---|---|
| Test-Sessions | 22/22 |
| Test-Combat | 14/14 |
| Test-Dice (fresh relay) | 15/15 |
| Test-NpcClaimValidation | 29/29 |
| Test-NpcClaimLifecycle | 28/28 |
| Test-TimeSkipRelay | 35/35 |
| Test-ItemSyncRelay | 11/11 |
| Farkle unit tests | 59/59 |
| Test-NpcSmoothSynthetic | 48/48 |
| Test-GhostInterpSynthetic | 35/35 |
| Test-WO84Synthetic | 72/72 |
| Test-WO86Synthetic | 47/47 |

The native `KCDMP.dll`, the agent (`KcdMpClient`), the relay (`KcdMpServer`)
and the master server were all rebuilt fresh for this build — not reused from
an earlier compile. The install manifest embedded in both the Setup exe and
the DirectInstall zip was generated from, and its SHA-256 confirmed against,
this session's own freshly-built native DLL.

**No live game was available this session** (no `KingdomCome*` process
running when this build was made), so Phase 3's solo smoke pass — confirming
the new pak and DLL actually load in-game and that a real kill produces the
new FATAL log line — did not happen and is not claimed. The install matrix
(virgin install, upgrade from a previous release, idempotent re-run) also was
not run from this session's own shell: this machine's `%LocalAppData%` is
sandbox-redirected for tool processes here, so any install-directory result
produced from this shell would be meaningless. **Both need to be run by the
maintainer** — see Upgrading, below.

## Console commands added

None new in this build. `mp_npc_deathsync on|off` (WO-86), `mp_ghost_anim_refresh <seconds>`
and `mp_ghost_sweep on|off|now` (both WO-84) shipped in 0.20.8/carried in main
already; this build is the first to ship `mp_npc_deathsync` in a compiled
installer.

## Upgrading

Run `KCDMP-Setup-0.21.1.exe` with the game, the launcher, the agent and the
relay all closed, or unpack `KCDMP-DirectInstall-0.21.1.zip` with
`Apply.ps1` over an existing install. Either way, run
`tools\Verify-Install.ps1` afterwards and confirm it reports agreement — this
is the step that catches a half-applied install, and it is the step this
session could not run for you.

**Both players must be on the same version.** The death-sync fix in
particular only works when both machines are running 0.21.1 — an older peer
never sets or reads the new FATAL flag.

## Reading further

- `docs/WO-85-findings.md` / `docs/WO-85-progress.md` — this release-cut
  session: what was rebuilt, what was verified, what is still the
  maintainer's job.
- `docs/WO-86-findings.md` / `docs/WO-86-progress.md` — the death-sync
  design and evidence.
- `docs/WO-84-findings.md`, `docs/releases/RELEASE-NOTES-0.20.8.md` — the
  animation/leak/sweep fixes.
- `docs/WO-83-findings.md`, `docs/releases/RELEASE-NOTES-0.20.9.md` — the
  guard-roster fix.
