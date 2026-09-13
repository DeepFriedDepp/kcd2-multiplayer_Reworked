# KCD2-MP 0.22.0

The label for everything on `main` as of WO-94 (2026-09-13), packaged as
`KCDMP-Setup-0.22.0.exe` (95.8 MB, sha256
`9827b7938b61aaa2be7d1e061e270b09785bad872b67e44efb74b3262588d63e`).

**There is no DirectInstall ZIP for this release, and there will not be one
for any release after it.** The Setup exe does the same job with less
effort; it detects an existing install and upgrades it in place (the
six-cell upgrade matrix below covers virgin, upgrade-from-0.21.5,
re-run-over-itself and two repair cases).

No native change: `KCDMP.dll` is byte-identical to the one shipped in
0.21.1 and 0.21.5 (sha256
`be76ba6a578a356357485b542dffa5175c4a86d452ce4c376b615c5a872c8984`,
confirmed against the published file). Agent, relay, launcher and master
server are republished as a matched set because the agent and the shared
protocol library changed; the relay's behaviour did not.

**Verification status, stated plainly.** The new feature ran in a live game
once, solo, on the maintainer's disposable save, with the maintainer at the
keyboard: the cheat gate, the proximity detector, the F11 fire (the engine
replayed a 14-step story chain), the F12 decline and the on-screen rows are
**live-verified**. The half that needs two machines — the approach crossing
the relay, the prompt appearing on the *other* player's screen, and the
hazard lines on the machine that did *not* fire — is **not yet run live**.
Two fixes the live run produced are synthetic-only. Synthetic totals this
release: 373 Lua + 131 C# = **504 checks, 0 failures**; install matrix
**97/97**.

---

## New: Shared Quests — the main-story readiness prompt (WO-94)

**Scope, deliberately narrow.** The 32 main-story quests of the base game
(Easy Riders through Judgement Day). Side quests, activities, events and DLC
content have no entry and trigger none of this — no detection, no prompt, no
keys. They keep exactly today's multiplayer behaviour, with WO-90's
divergence release as the only safety net.

**What you see.** When the other player gets within 35 m of a registered
beat of the main quest *they* are on, and your quest objective differs from
theirs, a line appears under the ping in the same plain text style:

> *Alice is nearing a story beat in "Via Argentum" (kralovskeStribro.02_startMines)*
> *F11 catch up (advance my story) / F12 stay (or mp_quest_yes / mp_quest_no)*

It stays until you answer it or it becomes moot (they leave, or your
objectives converge). It does not pause anything and does not block any
input — the mod's key hook runs after the game's own handler and cannot
consume a press.

**The keys.** F11 and F12 are the dice minigame's bank/yield keys, which the
dice-invite prompt already uses for accept/decline. They are only ever
claimed by the dice board while a match is open, so a prompt raised during
a match simply waits until the match ends.

**Yes** fires Warhorse's own story-jump facility,
`wh_concept_HasteTrigger <quest>.<trigger>`, on *your* machine. WO-92 found
it, confirmed it drives the real quest-graph transitions rather than
overwriting a counter, and named exactly what it does not restore (dialogue
history, some rewards and quest items, crime memory, NPC schedules,
discovered locations, elapsed timers, character progression) and six ways a
replay can visibly reach the other player. The maintainer accepted those
tradeoffs; this release builds on them as decided. Live, the first real
fire replayed 14 Haste steps in order: it teleported Henry to the beat's
start point (a few feet above the ground — Warhorse's coordinate), streamed
Hans in, closed the two preceding quests and started Laboratores. Firing
the same beat again replays the same chain, side effects included.

**Not answering** is a first-class choice. Nothing fires, nothing waits, and
WO-90's divergence release keeps handing a dragged NPC back to your own
world — with its stand-off now **180 s** instead of 60.

**Hazard logging, both machines.** For 120 s after a fire, every death,
teleport, world-clock change, chain suspension and divergence release the
mod already notices is *also* written as a distinct line —
`CATCHUP-HAZARD <kind> during catch-up <beat> (fired here|peer by <who> <n>s ago): …`
— in `kcd.log`, and the agent tags its own clock-jump, death-packet,
cutscene and teleport lines the same way. Outside a window nothing extra is
written. This is the "fix it when we see it" plan made greppable. In the two
live windows nothing hazardous happened, so zero lines were produced — and
the 19.5 m teleport the replay *did* cause slipped under the first version
of the local-teleport rule; that rule now watches every 20 ms emitter tick
(synthetic-verified, not yet re-run live).

**Coverage, honestly.** The registry is generated from the quest XML
(`tools\Build-MainQuestRegistry.ps1`, reviewable in
`docs/WO-94-mainquest-registry.csv`): 1,014 Haste triggers across the 32
quests, 138 carry a position, **53 are fireable** — positioned *and*
cumulative (a real "set the world up for this point" entry, not a lone
setter or a bare teleport) *and* not one of Warhorse's own test/debug
entries. **Ten quests, including the prologue Easy Riders, have no such
beat and will never prompt.** Most fireable beats are quest *start* points,
so in practice the prompt appears when the other player begins a main
quest; Via Argentum, Oratores, Taking French Leave and The King's Gambit
also have mid-quest beats. Same-position ties (the finale's sixteen
story-choice variants) resolve to the first in registry order.

**Lead time, measured.** At the default 35 m the prompt appeared 7.0 s
before the maintainer reached the beat at a run; about 12 s at a walk;
under 3 s on a galloping horse. Change it with `#KCD2MP_QuestSetRadius(50)`
typed in the console (see the trap below).

**Console.** `mp_quest_status` (state and the current quest's beats with
distances), `mp_quest_on` / `mp_quest_off` (the rollback: no detection, no
prompt), `mp_quest_yes` / `mp_quest_no` (the keys' console form),
`mp_quest_test_prompt` (raise the prompt solo, first registered beat).

## Changed: divergence stand-off 60 s → 180 s

WO-90's receiver-side release, which hands a puppeted NPC back to your own
world when the two stories disagree about it, now refuses that NPC's stream
for three minutes instead of one after releasing it. One constant; the rule
itself is unchanged and its 70-check suite still passes.

## Found live: the console drops arguments to mod commands

On this build the in-game console refuses an argument to any Lua-registered
command — `mp_quest_radius 35` produces `[Warning] Too many arguments for:
mp_quest_radius` and nothing runs — and passes the literal text `%LINE`
when there is none. **This affects every `mp_* on|off|<n>` command the mod
has ever documented** (`mp_enable_aggro on`, `mp_npc_sync off`,
`mp_npc_diverge 12`, …), which therefore only ever worked from tooling that
called the Lua directly. Until they are re-registered, type the Lua form
with the console's `#` prefix, e.g. `#KCD2MP_SetNpcDiverge("off")`. The new
Shared Quests toggles are argless for this reason.

## Known limits of this release

* Two-machine behaviour is unverified live (see above). Both players need
  0.22.0: a 0.21.5 agent drops the new messages and never raises a prompt.
* The prompt appears only when *both* objectives are known and differ; a
  player who has not yet saved since launch has no known objective, so no
  prompt is raised in either direction until their first checkpoint.
* The level is not on the wire. Fixed-point beats of the other map are
  skipped once your own level is known (from the engine's load banner), but
  a peer on the other map can still be shown approaching a beat by name.
* Firing a catch-up is not undoable in-game; use it knowing WO-92's list.

## Also in this label

Everything on `main` since 0.21.5: WO-90's story-beat telemetry and
divergence release (shipped in 0.21.5's pak already), WO-92's investigation
(docs only), and WO-94.

## Install

Close the game, launcher, agent and relay; run `KCDMP-Setup-0.22.0.exe`;
run `tools\Verify-Install.ps1` afterward and expect the six WO-94 markers
present in both the agent and the pak.
