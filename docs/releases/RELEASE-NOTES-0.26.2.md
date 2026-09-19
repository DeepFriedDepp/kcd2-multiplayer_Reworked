# KCD2-MP 0.26.2 — time sync fixed past 1e6; pause lever off; replicas on

The label for everything on `main` as of WO-104 (2026-09-18), packaged as
`KCDMP-Setup-0.26.2.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0). **To go back:** the tag `rollback/0.26.1` and
`KCDMP-Setup-0.26.1.exe`, or `rollback/0.26.0` two steps back.

---

## The fix: time sync had stopped, permanently, on any save older than ~11 days of game time

If sleeping or waiting on one machine stopped moving the clock on the
other, this is why. The world clock is counted in seconds since the save
began; the moment it passed **1,000,000** (about 11.6 in-game days) the
mod's Lua began writing it as `1.00255e+06` — scientific notation — and
the agent rejected every reading from then on:

```
[timeskip] malformed time_now '1.00255e+06'
```

Every save that has reached that point was affected, forever, on both
machines, since WO-38 first shipped time sync. Sleep/wait fast-forwarded
NPCs locally, nothing crossed, NPCs "behaved oddly after a sleep" (the two
clocks were hours apart, and their schedules with them). Not a regression
from recent work — a latent formatting bug that detonated on the
maintainer's save on 2026-09-18.

Fixed at the sender: the clock is now always written as a plain integer.
The agent's parser is deliberately unchanged — a value that had lost
digits must still be refused, not silently rounded. Every other number the
mod sends the agent was audited for the same exposure; one more (the dice
wager on an invite) was hardened the same way, the rest are formatted
with fixed specifiers or are not numbers at all. Full table in
`docs/WO-104-findings.md` §1.3.

**Verification status: (synthetic)** — a test that makes Lua format
numbers exactly the way the game does reproduces `1.00255e+06` and then
proves the fix emits `1002550`. Not yet seen live: "the other machine's
sky moves". The maintainer's own save is the test case (runbook §1).

---

## Toggles and defaults in this build

| toggle | default | changed |
|---|---|---|
| `mp_authority_host_on\|off` — host owns every NPC | on | no |
| `mp_pos_native_on\|off` — native position read | on | no |
| `mp_npc_scan_native_on\|off` — native NPC scan | on | no |
| `mp_authority_pause_on\|off` — pause a puppet's local brain (`wh_ai_PauseNPC`) | **off** | **yes — was on** |
| `mp_npc_replica_on\|off` — brainless replica for a contested NPC | **on** | **new** |

### `mp_authority_pause` is now off

0.25.x shipped it on, on a solo probe that held 8 of 8 (later 5 of 8).
The first two-player session with it on (0.26.1) logged **155**
`MP-AUTHORITY-VIOLATION` lines on the joiner, **every one `paused=1`**:
the mod had paused the NPC, and its local brain kept moving the body
anyway. `wh_ai_PauseNPC` does not hold a body that a live stream is also
writing. The solo probe measured a body nothing else was touching — a
different situation, not a wrong measurement. The toggle stays; the
default is off. (observed)

### `mp_npc_replica` — new, ON, unverified live

The replacement for the pause lever. When an NPC the host owns is being
fought on the joiner's machine and the joiner's own AI starts moving it
against the host's stream (that is exactly what the 155 violations were),
the joiner now can — with this switched on — hide its copy of the NPC in
place and stand a **brainless replica** at the same spot, wearing the same
soul's face and outfit, driven purely by the host's stream. When the
fight ends the real NPC returns where the replica stood. Both edges
happen inside one frame: no flicker, no second body, no body dropped.

**None of it has run against a real game yet.** It ships on anyway, by
the maintainer's call: it only fires on real contention and demotes
itself, so leaving it off means it never gets tested; ghost appearance is
already imperfect, so a wrong face is not a new class of problem; and
**`mp_npc_replica_off` switches it off at once** (every replica demotes,
every NPC returns) if it misbehaves. The two-machine test is
`docs/WO-104-field-runbook.md` §3: fight the same NPC together and the
pass condition is zero `MP-AUTHORITY-VIOLATION ... body=replica` for that
NPC. What to expect on screen if it works: the moment the joiner's own AI
starts fighting the host's stream over an NPC, the NPC is swapped for a
look-alike with no brain of its own; when the fight ends it swaps back.
Both swaps should be invisible. It cannot
serve women NPCs, horses, animals, downed or carried bodies, or an NPC in
a conversation (all refused and logged); while promoted an NPC cannot be
talked to. Everything else about it — the appearance guarantee and its
boundary, what happens to damage during the swap, the save-hazard and its
sweep — is in `docs/WO-104-findings.md` §3.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` all from the same build, on both machines. **No
wire/protocol change this release** — the relay is untouched and 0.26.1
peers would still connect — but the time-sync fix lives in the pak and the
replica's damage attribution lives in the agent, so a mixed pair gets
neither reliably. Verify hashes from your OWN terminal (`certutil
-hashfile`), never through the coding assistant's shell (WO-103's lesson:
it reads a stale sandboxed shadow of the install directory).

---

## Verification status, stated plainly

| item | status |
|---|---|
| time-sync formatting fix | (code-verified); (synthetic) 7/7 with an engine-faithful `tostring` mimic + 13 agent unit tests incl. a source guard; **not yet observed live** |
| pause lever default off | (observed) the 155/155 that motivated it; (synthetic) default pinned, no pause issued on a puppet start |
| replica path | (code-verified); (synthetic) 84 checks: promote/demote on every path, refusals, sweep, toggle-off byte-identical to 0.26.1; **nothing live**; ships ON by the maintainer's call, `mp_npc_replica_off` reverts |
| everything from 0.26.1 | unchanged | authority, damage path, native position, native scan all untouched |

Test counts in this build: WO-104 suite 91/91, WO-102 suite 196/196,
agent 170/170, every other Lua suite unchanged, relay round-trip gate run
by the installer build. `docs/WO-104-findings.md` and
`docs/WO-104-progress.md` have the full write-up.
