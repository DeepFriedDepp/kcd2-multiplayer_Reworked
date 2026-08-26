# WO-54 — Findings: the first live two-human session

Observed live 2026-08-25 (this document written same day), cross-checked
against both players' own exported log bundles after the fact. Evidence
tiers used throughout, never rounded up: **observed** (seen directly in a
log this session, source cited) / **corroborated** (seen independently in
both players' logs, or in more than one log channel) / **inferred**
(a plausible read from code or log shape, labelled as such) /
**unverified** (reported by a human, no log evidence either way).

Privacy: no real IP, DDNS hostname, or personal name appears below.
`<host>` = the session's host/authority player (Player A in the human's own
notes). `<joiner>` = the connecting remote player (Player B). Both were
playing **existing saves**, not the same save — `<host>` was mid-way through
the `zoufalaObranaZaBohutu` siege quest (WO-15's location); `<joiner>` was
free-roaming near Kutná Hora on their own save. `<host>` is in the US;
`<joiner>` is in the Czech Republic — a genuine transatlantic link, the
first this project has had.

**Bottom line up front.** The session never produced the thing this WO
exists to measure — sustained joint combat on a shared NPC never happened;
the two players were in different locations for almost the entire session
and `<joiner>` never drew a weapon. What it produced instead is a rich,
uncomfortable stability picture: the host's game/relay cycled through five
restarts in under 45 minutes, each one severing the joiner's connection too;
a known WO-26/WO-56 crash-adjacent log signature recurred four times on real
ghost respawns without ever crashing (a live confirmation of WO-56's
theory); a documented-but-never-fixed Discord presence bug fired
repeatedly on both machines; and the two players' logs disagree in a small
but real way — decimal points vs. commas — that traces to their machines
running different Windows locales, a live, previously undiscussed
cross-machine risk. A separate, human-reported "New Game from the very
beginning, tutorial crashes" episode is **not covered by any log this
document had access to** and is recorded as unverified, not corroborated or
refuted.

---

## 1. What was actually available, and its limits

Two sources, not one:
1. **This observer's own live tail** of `kcd.log`, `kcdmp-native.mirror.log`,
   and `<host>`'s `agent.log` for roughly the session's first 40 minutes
   (16:15–16:59 local to `<host>`), recorded incrementally in
   `WO-54-progress.md`.
2. **Four log bundles the human exported and shared afterward** — two
   incremental snapshots from `<host>`'s machine (16:51–16:56 window) and two
   from `<joiner>`'s machine (`01:25`–`02:00` `<joiner>`'s local clock, which
   is `16:25`–`17:00` `<host>`'s clock — a ~9 h offset consistent with a
   US–Czech Republic gap, not a bug).

The two sources overlap for most of their range but neither is complete:
this observer's live tail stops before the final restart cycle; the
exported bundles only cover from `<joiner>`'s connection onward and do not
include whatever happened on either machine **before** `<joiner>` first
connected. In particular, **no bundle contains a "New Game" / tutorial
session** — see §6.

---

## 2. Priority 1 — joint combat on a shared NPC: never came up

Across everything available — live observation and both players' full
exported logs — `<joiner>` is never once seen in a `combat draw` / `combat
sheathe` state, and the two players occupy the same coordinates for only a
few minutes total out of the whole session:

- `<joiner>` joined at `<host>`'s siege location once (`ghost 6`, spawned
  760.8, 3346.4 — inside the siege), stood still ~6 s, then walked/climbed
  the siege structure for about a minute before the connection was severed
  by `<host>`'s second restart.
- On the next successful reconnect, `<joiner>` (`ghost 3`) spawned at
  `142.0, 2058.9` — **a different area entirely**, mounted, and spent the
  rest of the observed/logged time riding through open country, never
  drawing a weapon (`grep`'d for `combat draw`/`combat sheathe` in
  `<joiner>`'s own exported `kcd.log`: **zero matches**).
- `<host>` fought extensively and solo throughout (dozens of fatal native
  hits, detailed in §5), but never with `<joiner>` present and engaged.

**This is a complete, honest answer to the WO's central question: it did
not come up this session.** Nothing here supports or undermines WO-51's
option 2/3/5 recommendations — there was simply no data generated. The
`mp_npc_fight` diagnostic was never invoked (no joint engagement to
diagnose).

## 3. Priority 2 — item drop/claim race: never came up as a race

One drop/claim cycle was observed live (§ live notes, ~16:27): `<host>`
picked up a self-dropped crossbow bolt (`item_claim 1276324444`,
`ITEM-SYNC drop ... taken locally -> claim sent`) with no competing claim
attempt. The WO-48 pipeline is confirmed firing correctly end-to-end in real
play, but **no two-player race was ever attempted or observed** — the
players were never at the same loot in the same moment.

## 4. Priority 3 — Flow B (NPC damage landing on the non-authority player): never came up

Damage authority did move during this session (§7.2) — `<joiner>` briefly
held it while `<host>`'s game was down — but during that exact window
`<host>`'s game process was itself offline (mid-restart), so nobody was in
a position to be hit by an NPC while non-authority. **Still unverified
cross-machine, exactly as it stood after WO-28/WO-51; this session neither
confirms nor breaks it.**

## 5. Priority 4 — general stability: this is where the session's real data is

### 5.1 Five host-side restarts in under 45 minutes, cascading to the joiner every time

Observed directly (`tasklist`/WMI `CreationDate` on `<host>`'s machine) and
independently **corroborated** from `<joiner>`'s own log, which shows
`<host>`'s ghost re-spawning under four different ghost ids across the
session (`ghost 1`, `4`, `8`, `10`, all named as `<host>`) and `<joiner>`'s
own client logging `Removing all ghosts... / Reconnecting in 3 s...` at
`16:49:26.977` `<host>`-clock — **within one second of the identical line in
`<host>`'s own log.** This is the strongest single piece of evidence in
this document: the joiner's connection did not just happen to drop near the
same time as a host restart — it dropped in the *same second*, both times
checked. Architecturally this reads as the relay's own session being tied
to the host's local client (a design choice, not a bug in itself) — when
`<host>`'s side dies, `<joiner>` is forced to reconnect too, every time,
with no independent path to stay in a "solo-but-still-connected" state.

Restart timeline (all times `<host>`-local):
| # | New process created | Precursor in `agent.log` |
|---|---|---|
| 1 | 16:18:37.868 | none captured (predates this observer's tail) |
| 2 | 16:41:49.440 | `[combat] pipe reader exited` during an open pause menu |
| 3 | 16:45:59.919 | same — pipe-reader-exit during an open pause menu |
| 4 | ~16:50:35 (after a full process exit, not just a bounce) | pipe-reader-exit, **no menu open this time** |
| 5 | 16:58:48.387 | pipe-reader-exit while `<joiner>`'s ghost was actively riding, no menu |

**Corrected finding, stated plainly because the evidence changed mid-session:**
the first three restarts all followed the same open-pause-menu → pipe-reader-exit
sequence, which looked like a real trigger after three-for-three — but the
fifth restart's pipe-reader-exit happened during active gameplay with no
menu open at all, which falsifies "opening the menu" as a *necessary*
trigger. What holds across all five: **every restart was preceded by
`[combat] pipe reader exited`.** What makes the native combat pipe exit is
not established from these logs.

**A concrete, unconfirmed lead for what's behind the pipe-reader-exits**:
in the same window as the fifth restart's pipe-reader-exit, `<host>`'s own
appearance-sync HTTP calls (to the game's own local debug API,
`localhost:1403`) started failing on an 0.8 s timeout, repeatedly, for six
different item GUIDs in a row over about four seconds. A local HTTP call to
your own process timing out at 0.8 s is a real signal that the game's main
thread was busy/unresponsive right then — consistent with, though not
proof of, the human's own note that "PA's game dropped to 15fps" (see
§5.4). If the native pipe reader and the local HTTP client are both
starved by the same main-thread stall, that would explain why pipe-exits
and restarts cluster the way they do without needing the pause menu at
all. **Not confirmed — no frame-time counter was read this session — but
it is the single best-supported candidate here.**

No restart produced a BugSplat crash report (checked after every one,
`BugSplatAttachments\` stayed empty throughout).

### 5.2 The WO-26/WO-56 "no faction" signature recurred four times, live, on real ghosts — and never crashed

Every one of the four *successful* post-restart reconnects (restarts 2, 3,
4, 5) produced the exact same burst on `kcd.log`: ~50 consecutive `[Error]
NPC kcd2mp_0 does not have a faction.` lines, then `kcd2mp_0 deleted 0
reconciled changes`, then one more single recurrence. This is the identical
per-frame signature WO-26 died on and WO-56 traced statically
(`C_NPCFactionNode::GetFactionPtr`'s non-fatal null-return path). Four
times, the game kept running normally afterward (same PID, RSS climbing
with ordinary play, native DLL and agent reconnecting cleanly within
seconds).

**This is a live confirmation of WO-56's central claim** — the fatal path
belongs to `C_Player::Init`'s null-character guard, which cannot fire for
an NPC-class ghost. A ghost losing its faction assignment is the WO-26
symptom with the WO-26 crash mechanically unreachable.

**Why it happens, read from the actual code (`kdcmp.lua:2658–2690`):**
unlike WO-26's bare spawn, this path passes `SharedSoulGuid` at spawn time
(soul-backed, not starved) — the missing piece is a *separate* step right
after spawn, wrapped in an unlogged `pcall`:
```lua
pcall(function()
    entity.Properties.esFaction = "Civilians"
    AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
end)
```
Always on ghost id `0` specifically (the first ghost spawned in a fresh
reconnect cycle) — a later spawn on the same reconnect (`ghost 3`, restart
5) hit no such error. **Plausible, code-consistent, not proven**: something
about the very first respawn immediately after a reconnect makes this
`AI.ChangeParameter` call fail or no-op silently, and because the `pcall`
swallows the result unconditionally, nothing ever recorded which. This is
the first time this exact gap has been caught live rather than inferred
from disassembly.

### 5.3 A documented Discord presence bug fires repeatedly, on both machines, unfixed in the field

`System.NullReferenceException` in `DiscordRPC.Assets.Merge` — the exact
bug project memory already has on file from WO-50 — fired at least **9
times across the session on `<host>`'s side and 8 times on `<joiner>`'s
side**, roughly once per (re)connection event on each machine. It never
appears fatal (both agents keep logging afterward), but its persistence
across a full external two-human session, on two independently-updated
installs, is itself informative: **whatever WO-50 shipped is not
suppressing this in the field.** Not re-diagnosed this session (out of
scope for pure observation), but the count here (17 total occurrences) is
new data for whoever revisits it.

### 5.4 A real, quantified transatlantic latency floor, with real jitter spikes

`<joiner>`'s own `[ping] N ms` samples (859 in the exported window):
minimum **169 ms**, median **237 ms**, mean **319 ms**, and **11 samples
above 1000 ms** (worst: **1415 ms**). The 169 ms floor is consistent with
genuine US↔Czech-Republic network distance and is not fixable — any
latency-sensitive design for this project (combat cue timing, claim
hysteresis windows, etc.) needs to assume at minimum a quarter-second
round trip on a real cross-continental link, several times worse than
anything tested domestically before. The spikes above 500 ms (113 of 859
samples, 13%) recur every few seconds to every ~15 seconds throughout —
not occasional, a standing condition of this specific link — and are
plausibly the same congestion/stall class discussed in §5.1, though ping
alone can't distinguish network jitter from host-side processing stalls.

### 5.5 A real locale/culture mismatch between the two machines — confirmed, not yet shown to cause a crash

`<host>`'s Windows system language is English (`en-US`); `<joiner>`'s is
Czech (`cs-CZ`) — both confirmed directly from each side's own `kcd.log`
(`System language: English` / `System language: Czech`, distinct input
locale ids `409`/`405`). This produces a directly observable artifact: the
identical client log line renders with a period on `<host>`'s machine
(`HttpClient.Timeout of 0.8 seconds`) and a **comma** on `<joiner>`'s
(`HttpClient.Timeout of 0,8 seconds`) — .NET's culture-sensitive number
formatting picking up each machine's OS locale. No `FormatException` or
parse failure was found anywhere in either player's logs this session, so
**this specific manifestation is cosmetic, not a confirmed crash cause** —
but it is real, live evidence that this codebase has at least one place
that does not force invariant culture for number formatting, and if any
*wire-protocol* value is ever serialized/parsed the same way (rather than
explicitly invariant), a real US-machine ↔ Czech-machine pairing is exactly
the condition that would surface it. This directly answers the human's own
question ("is it trying to sync translations?") — **no**, there is no
translation-sync mechanism in this project; what's actually happening is
each machine independently running its own OS/game locale, and the .NET
client's own log formatting inheriting that difference. Worth a static
audit of the wire-serialization code for the same culture-sensitivity,
given this is the first real cross-locale pairing this project has ever
tested against.

### 5.6 Damage authority failed over from `<host>` to `<joiner>` during `<host>`'s outage — a live first for a previously-untested mechanism

`<joiner>`'s own log: `16:41:39.150` (`<host>`-clock) `[role] this client
now holds NPC->player damage authority` — within two seconds of `<host>`'s
own restart-2 pipe-reader-exit/menu-close sequence. Per the standing Rule 2
design (lowest-ready relay id wins authority), this is exactly correct
behavior — when the host's client dropped out, authority should and did
move to the only other ready client. **WO-32/WO-51 both flag this exact
mechanism as essentially untested** (one inconclusive WO-32 anomaly,
never reproduced). This session reproduces it cleanly, working as designed,
purely as a side effect of the restart cascade rather than anything
deliberately tested — a genuinely new, positive data point for that file.
No combat happened during the window `<joiner>` held authority (`<host>`'s
game was offline), so this doesn't extend to verifying anything *combat*-
related about authority-holding, just the handoff itself.

### 5.7 Other recurrences from earlier WOs, confirmed live

- **WO-40's "zero-damage hit flood" signature**, reproduced on a real siege
  NPC (`..._sideWallSubstitute_4`) during solo play: a sustained
  `LocalHit 0.01`–`0.09` stream at 5–15 Hz for over a minute while `<host>`
  stood near it with a weapon drawn, before one real `36.82 (fatal)` hit
  eventually killed it — leaving genuinely open (not resolved by this
  session) whether the tiny hits were real chip damage or a sensor
  artifact.
- **WO-40's `Reconcile` ghost-recovery path** fired once, cleanly, on a real
  session: a ghost lost its world entity mid-siege, the mod detected it and
  respawned it at the identical position, invisibly to an observer — the
  fix in `kdcmp.lua:4811` doing exactly what it was built to do, on its
  first real-world trigger.
- **A new error type, not previously on file**: `[version-ipc] request
  failed: Could not load file or assembly 'System.IO.Pipelines, Version=
  10.0.0.0...'` — an assembly-version-mismatch shape matching WO-46's own
  documented "partial publish" class of bug. Hit a peripheral endpoint
  (the launcher's version-check channel), not the main relay connection;
  not diagnosed further this session (no build/deploy inspection was in
  scope).

---

## 6. The reported "New Game / tutorial / priest" crash episode: unverified, not corroborated or refuted

The human's own notes describe a distinct, earlier attempt: both players
starting brand-new saves from the very beginning, where KCD2's opening
sequence has the player controlling a different (non-Henry) character
before the main game proper; repeated crashing on `<joiner>`'s side; a
15 fps drop on `<host>`'s side the moment `<joiner>` joined; frozen NPCs on
`<joiner>`'s screen; and a crash on `<joiner>`'s machine when `<host>`
advanced the tutorial further.

**None of the four exported log bundles contain this episode.** All four
show the players on their own pre-existing, mid-game saves (`<host>` at the
Bohutá siege; `<joiner>` near Kutná Hora), and `<joiner>`'s earliest log
timestamp (`01:25:52` their clock) converts to `16:25:52` `<host>`-clock —
which matches, almost to the second, this observer's own live record of
`<joiner>`'s *first* connection of the day (`ghost 6` spawn at
`16:25:57.835`). That means, as far as any log available to this document
shows, **`<joiner>` was never connected before that moment** — so if the
New-Game/tutorial attempt happened, it happened earlier still, on a run
that produced no logs anyone exported, and this document cannot corroborate
or refute any specific detail of it (the 15 fps figure, the frozen NPCs, or
the tutorial-specific crash). It is recorded here as reported human
testimony, not as an observed or corroborated finding, and the honest
answer to "what does the evidence say about the tutorial phase" is: **there
is none available.**

One structural note worth passing along regardless of that gap: the siege
session this document *does* have full evidence for shows the same
family of symptoms the human described from the tutorial attempt —
a real local responsiveness stall correlating with the joiner's presence
(§5.4), and repeated involuntary disconnects (§5.1) — which is at least
consistent with (not proof of) the tutorial episode being the same
underlying instability showing up earlier and harder, rather than an
unrelated problem.

---

## 7. What this changes for standing open questions

- **WO-51's recommendation stack (measure → Flow B → suppression →
  engagement claims) is unchanged** — this session didn't reach joint
  combat, so nothing here promotes or demotes any item in that list. The
  measurement WO-51 called for still has not happened.
- **WO-56's central claim now has a live data point, not just static
  analysis**: the `C_Player`-class-only fatal guard theory held up across
  four real occurrences.
- **A new, previously-undiscussed risk surfaces for the first time**: real
  cross-locale (en-US / cs-CZ) pairing is now known to produce at least one
  observable formatting difference in this codebase, and the wire protocol
  itself has never been audited against this specific condition.
- **The restart-cascades-to-the-joiner behavior** is a real architectural
  fact worth anyone building on WO-51's stack knowing: there is currently
  no way for a non-host player to stay connected through a host-side
  hiccup — every host restart this session cost the joiner their session
  too, within about a second.

## 8. What this document did NOT do

No code, config, or `VERSION` changes were made in producing this analysis.
No fix was attempted for any issue named above. The tutorial/New-Game
episode was not investigated beyond checking whether the supplied logs
covered it (they do not). No recommendation is made about what to build
next — per this WO's own scope, that is a separate, later decision.
