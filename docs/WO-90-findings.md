# WO-90 — story-beat desync on a new game

Field session: 2026-09-12 evening, two players on release 0.21.5, protocol v6,
a brand-new game — the KCD2 prologue (the Bohutu battle, played as Godwin),
the scripted switch to Henry, then the `prepadeni` ambush quest with Hans.
Three log bundles: the host's, continuous; and the joiner's two, split by a
crash. "Host" = the machine that ran the relay (Steam nick `M31`, relay id 0).
"Joiner" = the other player (`MooseSplosion`, relay id 1, then id 2 after
rejoining). Nothing identifying either person is reproduced here.

Every claim is tagged **(observed)** — read directly in these logs, cited by
file and line; **(code-verified)** — traced in the tree at `09bf1da`;
**(inferred)** — the only reading consistent with both, but not itself a log
line; **(inconclusive)** — the logs do not decide it.

---

## 0. Phase 0 — the three logs, before any theory

### 0.1 What the three bundles actually are (observed)

This matters more than usual, because the obvious reading of the filenames is
wrong and would corrupt every timing in the rest of this document.

| Bundle | What it is |
|---|---|
| `host/` | The host machine, whole session. `kcd.log` is 975,030 lines / 66 MB. The relay ran here, so `relay20260912.log` is the session's arbitration record. |
| `j1/` | The joiner's **first** (crashing) session — but collected at **20:45:56**, which is ~80 s *before* the agent finally gave up. `j1/kcd.log` therefore ends at collection time, not at the crash. |
| `j2/` | Collected 22:04. Its `kcd.log` is the **restarted** game (started 20:47:30). Critically, `j2/agent.prev.log` is the **same agent process** as `j1/agent.log` — both begin 20:37:27.725 — and it runs ~80 s further, to 20:47:15. **`j2/agent.prev.log` is the best record of the crash itself.** `j2/logbackups/kcd.log` is a third, short-lived game launch that started 20:46:10 and produced 2,469 lines. |

So the joiner's two bundles are not "before and after"; they overlap, and the
later bundle carries the earlier session's tail.

### 0.2 Calibration, and its one caveat (observed)

`kcd.log` has no timestamps. The mod's own emitter line carries a monotonic
seconds field:

```
[KCD2-MP-DATA] v2 <seq> <t> <x> <y> <z> <rotZ> <flags> <health> <stamina>
```

Wall clock = offset + `t`, with offsets anchored on agent-log events and
verified against a second, independent anchor at the far end of the session:

| Log | Offset | Anchor | Independent check |
|---|---|---|---|
| `host/kcd.log` | 20:34:30.2 | ghost spawn, line 20376, `t=180.443` ↔ agent `[name] ghost 1` 20:37:30.306 | `GHOST_DEATH` `t=4823.444` → 21:54:53.6 vs agent `[death]` 21:54:53.624 (**0.02 s**) |
| `j1/kcd.log` | 20:34:28.0 | ghost spawn, line 16897, `t=184.210` ↔ agent 20:37:32.192 | — |
| `j2/kcd.log` | 20:47:23.4 | ghost spawn, line 109780, `t=857.095` ↔ agent 21:01:40.526 | `GameOver.gfx` `t=4051.681` → 21:54:55.1 vs agent `[death]` 21:54:55.237 |

**The caveat:** `t` only advances when the emitter emits, and a Rendered
cutscene, a menu or a level load suspends every `Script.SetTimer` chain
(WO-80). An event inside such a gap inherits the *last sample before it*, so
its printed time is a **lower bound**. The offsets themselves are unaffected —
`os.clock` keeps running, which is why the far-end check above still lands
within 0.02 s. Every time in this document that falls inside a sample gap is
given as a bound.

### 0.3 The master timeline — quest objectives on both machines (observed)

The load-bearing discovery of Phase 0. At every checkpoint save the engine
writes its own quest+objective key to `kcd.log`:

```
InitiateSaveGame() type: AutoSave, overwriteSaveId: -1,
  questNameOverride: '@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB'
```

**The key is byte-identical on both machines for the same objective.** Nobody
in this project had used it before. It gives, for the first time, a
cross-machine measurement of how far apart two players' stories were:

| Beat | Host | Joiner | Gap |
|---|---|---|---|
| `prepadeni` quest starts (`jmena_obj_zacatek_questu`) | 20:46:27.7 | in [20:47:23, 21:01:40] | joiner behind |
| Ingame cutscene `prepadeni_meetingWithSheriff` | 20:48:03.8 | in [20:47:23, 21:01:40] | — |
| Ingame cutscene `prepadeni_roadToCamp` | 20:50:13.7 | in [20:47:23, 21:01:40] | — |
| `prepadeni_zjisti_od_ptack` (ask Hans) | 20:51:03.3 | in [20:47:23, 21:01:40] | — |
| Ingame cutscene `prepadeni_armorLake` | 21:49:55.8 | 21:40:28.6 | **joiner 9m 27s ahead** |
| `mq01__pre_crouch` (the sneak beat) | 21:50:00.1 | 21:40:36.0 | **joiner 9m 24s ahead** |
| Ingame cutscene `prepadeni_lakeMassacre` | 21:52:08.8 | 21:52:22.5 | host 13.7 s ahead |
| `prepadeni_nasleduj_ptacka` (follow Hans) | 21:52:39.5 | 21:52:42.1 | host 2.6 s ahead |
| Ingame `prepadeni_henryFalls`, `zachrana_cestaPoBrehu` | 21:56:28.1, 21:56:57.3 | — | host alone |
| `zachrana_zastav_krvaceni` (next quest) | 22:02:53.1 | — | host alone |

Host lines 161812 / 183300 / 422892 / 429569 / 966471; joiner lines 107739 /
109567 / 224774 / 268335.

Read it as a story: the joiner started behind (it lost 14 minutes replaying
the prologue after the crash — `j2/kcd.log` 2572 and 8037 load
`permanent001.whs` and the whole Bohutu battle appears again through line
93301), overtook the host by nine and a half minutes, then converged to
within three seconds, and finally fell away for good after dying twice.

### 0.4 The master timeline — who owned which NPC (observed)

From `host/relay20260912.log`, the arbitration record. Claim durations for the
Hans-camp party:

| NPC | Granted | Released | Held |
|---|---|---|---|
| `tkop_ptacek` (Hans) | 21:09:39.4 | 21:41:33.5 | **1914.1 s (31m 54s)** |
| `prepadeni_mikulas` | ~21:09:39 | 21:40:37.4 | 1858.0 s |
| `prepadeni_konrad` | ~21:09:39 | 21:40:37.4 | 1858.0 s |
| `prepadeni_voves` | ~21:09:39 | 21:40:37.7 | 1858.4 s |
| `prepadeni_pivec` | ~21:14:03 | 21:40:38.7 | 1594.9 s |

Every one of them owned by `owner=2`, the joiner. Session totals: **402
claims granted, 386 released, 7 reassigned, 0 contested.**

---

## 1. Phase 1 — is quest/story state synchronized at all?

**No. Not in any form, anywhere. (code-verified)**

An exhaustive search of `kdcmp/**/*.lua`, `dotnet/**/*.cs` and
`native/**/*.cpp|h` returns **zero** hits for `QuestSystem`, `questlog`,
`Journal`, `TrackView`, `objective`, `chapter`, `storyline`, `campaign`,
`cinematic`, `CinematicMode`, `camera`, `Camera`, `hijack`, `firstperson` or
`FirstPerson`. `quest` appears only in prose comments and in quest-*item*
class aliasing for the appearance layer (`GameBridge.cs:1403-1406`), which is
cosmetic item remapping, not state.

The mod synchronizes position, animation, vitals, combat damage and death,
NPC state under a claim-arbitrated authority model, appearance, horses,
weather, world-time skips, dropped items, dice and voice. It has never carried
one bit about where either player was in the story.

The only two story-adjacent pieces that exist:

1. **A Rendered-cutscene pause detector** — `LogTailGameTransport.cs:313-328`
   matches `CutscenePlayer::PlayCutscene called for Rendered cutscene` /
   `OnCutsceneEnd ...` into `AggregatePaused`. Its entire purpose is to keep
   ghost bodies moving while `Script.SetTimer` is frozen. It is not story
   state and nothing reads it as such.
2. **A read-only dialogue probe** — `kdcmp.lua:6951` `KCD2MP_ProbeDialog`,
   shipped by WO-88, with no consumer.

So: two players run two independent campaigns inside one shared NPC
name space. **Every finding below except 2 and 4 is downstream of that one
fact.**

### 1.1 The split the maintainer asked for, explicitly

| Class | Findings |
|---|---|
| **Story-state** — two worlds disagreeing about which behavioural state an NPC is in, or which beat has fired | 3, 5, 6, 7, 8 |
| **Render jitter** — position/animation smoothing, cosmetic but visible | 4 (swing jankiness half) |
| **Stability** | 2 |
| **Neither — a spawn/appearance defect** | 1 |

Finding 4 splits: the *swing jankiness* is render jitter, the *invisible
helmet* is story-state (§2.4).

---

## 2. Phase 2 — the eight findings

### 2.1 Finding 1 — no ghost model during the Godwin prologue

**Status: mechanism established — the body had no character instance. The
cause of *that* is not established. (observed)**

The ghost was not missing, badly dressed, or mis-souled. It was a complete
entity with a transform, an inventory, script contexts and a nameplate — and
nothing on render slot 0.

**The mod's own probes could not resolve a single animation on it
(observed).** `findAnim` against the prologue ghost returned false for every
candidate in both the block and swing clip lists — `GetAnimationLength(0,
name)` was 0 for all four names (`host/kcd.log` 100655 and 100717, 20:41:11.0
and 20:41:11.2). The identical probe against a post-switch ghost succeeded
(`j2/kcd.log` 237649, 21:45:00.1, `BlockAnim:
combat_rg_sz1_dz0_blk_slash_lngsw`).

**And the clip family was demonstrably loaded in that level at that moment
(observed).** Thirty seconds earlier, in the same prologue, the same shared
probe resolved a longsword combat idle against a *real* NPC —
`host/kcd.log` 20925, 20:37:33.4, `CombatIdleAnim:
combat_rg_sz1_idle_lngsw_player`, immediately after the `drew weapon` line for
`zoufalaObranaZaBohutu_defenders_sideWallStationary_3`. So the failure is a
property of the ghost body, not of the level or the clip set.

**The engine said so itself, twenty-four times (observed).**

```
[Error] Combat actor init failed for actor 'kcd2mp_1'
```

24 occurrences, `host/kcd.log` 100694–114421, 20:41:11.1–20:41:25.9, paired
one-for-one with our own DLL's `SWING: entity=260951 --
GetOrCreateCombatActor faulted/null` at the same timestamps. Entity 260951 is
`0x3FB57` — the prologue ghost's id, from its own spawn line
(`host/kcd.log` 20382). **This is the only body in the entire session that
ever failed that call: 24 of 24, against 106 of 106 successes for the host's
post-switch ghost and 340 of 340 for the joiner's.**

An entity with a transform, an inventory and contexts but no character
instance is precisely "nametag, no model".

**Both hypotheses this session started with are refuted (observed):**

* *"The roster soul does not resolve in the prologue level."* **No.** The
  invisible prologue spawn and the visible post-switch spawn are line-for-line
  identical on both machines — same `face pick`, same `spawn verify … soul=nil`,
  same faction attempt, same default-clothing error, same weapon-preset
  refusals (`j1/kcd.log` 16897-16910 vs `j2/kcd.log` 109780-109793;
  `host/kcd.log` 20376-20387 vs 229915-229926).
* *"The appearance layer stripped the body."* **No.** Both machines applied 19
  item classes to the peer ghost during the prologue, with the same two
  slot-rule rejections as the visible case. (The 16 seconds of REST timeouts
  at 20:44:19–20:44:35 are real, but they are *after* the transition.)

**An independent corroboration, from a signal neither probe used
(observed).** Across the whole 975,030-line host log, the prologue ghost
`kcd2mp_1` appears in **zero** `Animation-queue overflow … CharInst:` lines —
the string `kcd2mp_1` occurs only 26 times in the entire file — while the
post-switch ghost `kcd2mp_2` appears in **1,121** of them. A body driven
through 526 locomotion tag transitions over four minutes would have been
queueing the very clips that overflowed on the visible ghost. It never queued
one. (Overflow is only logged above 16 entries, so absence is not proof —
hence **(inferred)** for the conclusion drawn from it — but across four
minutes and 526 transitions the contrast is hard to explain any other way.)

A second in-window control, also new: the host's **first** overflow of the
session is a real kutnohorsko NPC (`kcer_suchyCert`) overflowing on
`combat_rg_sz1_idle_lngsw_player.caf` at the battlefield — same level, same
seconds, same clip family. The engine's animation pipeline was alive all
around the ghost.

**The one competing candidate, named honestly.** The prologue ghost had drawn
an oversized item from its inventory (`host/kcd.log` 88317), and the probes
that returned false used longsword clip names — so "the probes asked about the
wrong weapon" is not excluded by the probe result alone. The overflow census
above is what breaks the tie: a body with a character instance holding *any*
weapon would still have queued locomotion clips, and this one queued nothing.

**Where the evidence runs out:** *why* the character instance was missing. The
spawn call, its arguments and every line the engine printed around it are
identical between the invisible and visible spawns, and the object-layer,
skirmish and precache censuses do not separate the two windows either.

**What would settle it, and what ships here.** The mod has never read back
whether a spawned ghost actually has a character — it verifies class, soul and
faction, and stops there. `GetCharacterFileName(0)` and `GetCharacter(0)` are
both already proven present on this build (used elsewhere in `kdcmp.lua`). A
one-line read-back at spawn turns this entire finding from a mystery into a
logged fact, on the spot, for free. **That read-back is shipped in §4**; the
next prologue session will say outright whether the body has a model.

**One premise from the report, refuted outright (code-verified).** Ghost
creation does *not* assume Henry or any particular player identity. `kdcmp.lua`
never resolves the player itself — it uses the engine's global `player`
unqualified and never tests a name or class — and the ghost is spawned as a
plain `NPC` with a soul chosen by hashing the peer's Steam nick. Nothing in
that path can care which scripted body the local player currently occupies.

Relatedly: **the engine names the player entity `Dude` regardless of who is
being played (observed).** The string `Godwin` appears **zero** times in any
of the three logs, and the prologue's player-side dialogue lines read
`Ex: Dude` exactly as the Henry-era ones do — the same "the player is a slot,
not a class" shape WO-56 found.

### 2.2 Finding 2 — the joiner's crash at the Godwin→Henry transition

**Status: the failure is precisely located in time; the cause is not
recoverable from these logs. (observed + inconclusive)**

The last-two-minutes sequence, from all three of the joiner's streams:

| Time | Stream | Event |
|---|---|---|
| ~20:44:10 | `j1/kcd.log` | **Stops growing.** Its final lines are the trosecko level load completing — PSO precaching, then three `[KCD2-MP] ApplyTimeSkip` lines (118800 → 122400, then two "already at 122400"), then two anim-ref Validator warnings. |
| 20:44:19–20:44:35 | `j2/agent.prev.log` | 21 consecutive equip/unequip failures against `kcd2mp_0`, all `HttpClient.Timeout of 0.8 seconds`. Then five `verify read failed`, then `final verify read failed`. |
| after ~20:44 | `j2/agent.prev.log` | **No further `[pos]` lines.** `[pos]` is printed only when `ReadPlayerStateAsync` returns non-null, and the log-tail transport's `MaxAge` is 500 ms — so the mod's emitter had stopped appearing in `kcd.log`, matching the file above having stopped. |
| 20:44:06 | `j1/kcdmp-native.log` | Last `SAMPLE: tracking 64 souls within 60 m`. **Not a crash signature** — see below. |
| 20:44:18–20:45:56 | `j1/agent.log` | `[ghost 0]` frozen at exactly `120.18 2040.65 56.29` for 98 s — inbound packets still arriving, nothing else moving. |
| 20:45:14–20:45:56 | `j1/agent.log` | `[ping]` 39–135 ms: the network was healthy. |
| 20:46:33–20:47:12 | `j2/agent.prev.log` | `[ping]` climbs monotonically **14803 → 16029 → 17256 → 18481 ms**. |
| 20:47:13.6 | relay | `[-] MooseSplosion disconnected. Clients: 1` |
| 20:46:10 / 20:47:30 | joiner | Two further game launches; the first produced only 2,469 lines. |

So: **the game stopped writing `kcd.log` and stopped sampling natively at
~20:44:10, at the very end of the trosecko level load, and the agent kept
running healthily for three more minutes before the process went.** The
`[ping]` figures rising into the tens of seconds are the agent's own loop
starving, not the network — the same loop was reporting 39 ms a minute
earlier.

Compared line-kind by line-kind against the **host's successful** transition
(`host/kcd.log` 143508→161812), the joiner never reaches the host's
post-load sequence: no `Loading switching save game.`, no
`SetGlobalState 11→12 'LEVEL_LOAD_ENDING'→'LEVEL_LOAD_COMPLETE'`, and none of
the host's `CHAIN … confirmed dead … restarting` burst. The joiner's last
`SetGlobalState` is `10→11 'LEVEL_LOAD_END'→'LEVEL_LOAD_ENDING'`. **It died
inside level-load finalisation.**

**Two apparent discriminators were checked and both dissolved.** This is worth
recording, because each looked like a lead:

* *"The joiner's native sampler died."* It stops at 20:44:06 — and the
  **host's stops too**, at 20:43:32.5, at its own trosecko load. The host then
  played for another eighty minutes (its native log runs to 21:58:04). The
  sampler stopping is what a level load does, not what a crash does.
* *"The joiner's mod fired a clock convergence during the load."* So did the
  host's, at 20:44:08.483/.484, during its own. Same two writes, same phase,
  no crash.

Against WO-58's main-thread-hang shape (`docs/WO-58-findings.md` §1.2–1.3):
the *symptom* matches — a stalled main thread with the agent alive around it —
but the trigger WO-58 pinned (`ForceMount` onto an adopted world horse) is not
in evidence: no `ForceMount`, no `SWING`, no pipe operation appears in the
joiner's native log anywhere near the stop. WO-58's own rule that
pipe-reader-exit is a symptom and not a precursor is respected. **Partial fit,
no identified trigger.**

Honest verdict: **these logs do not root-cause it, and no amount of re-reading
them will.** The mod's last action before the stop (the `ApplyTimeSkip` triple)
is also present on the host, which crossed the same transition successfully.

**What would settle it next time**, in order of value:

1. A **crash dump**. Neither the game nor this mod writes one to any path in
   these bundles, and Collect Logs would not pick one up. Confirming whether
   KCD2 emits a minidump (and adding it to the bundle) is a small, concrete
   piece of work that would turn this class of report from "inconclusive" into
   "a stack".
2. **Windows Error Reporting** for the process — `Get-WinEvent -LogName
   Application` filtered to the game executable, captured at report time.
3. A native-log **heartbeat during level load** specifically: the DLL already
   samples every 3 s, but nothing records which phase the main thread is in, so
   a stop inside load finalisation is indistinguishable from a stop anywhere
   else.

### 2.3 Finding 3 — the host pulled into the joiner's conversation

**Status: mechanism established, fixed this session. (observed + code-verified)**

This one is not a story-state race at all. It is a straightforward name
collision, and it is the cleanest defect in the session.

**The engine spawns a stand-in entity per conversation participant, named
`DialogTwin_<soulName>` — including `DialogTwin_Dude` for the local player's
own character — and attaches the conversation camera to it.** Both machines log
the link explicitly:

```
MasterSlaveManager is setting context: '5' for entities 'DialogTwin_Dude'
  -> 'DialogTwin_DudeCharacterCameraAttachment'
```

(host `kcd.log` 172004, 20:48:09.9; the same on the joiner.) A `DialogTwin_`
even exists for the player's horse — `Actor 'DialogTwin_Dude' starts mounting
horse 'DialogTwin_tsem_sedivka' instantly`.

These entities are class `NPC` and their names pass the authored-name test
`^[%w_]+$` in `mp_npc_rescan` (`kdcmp.lua:2472`), so **the mod tracked,
claimed, streamed and puppeted them exactly like world NPCs** (code-verified).
Because both machines name them identically, each player's conversation rig was
driven by the other's:

* 21:02:18.3 — relay: `[CLAIM] granted npc=DialogTwin_tkop_ptacek owner=2`;
  45 ms later `[CLAIM] granted npc=DialogTwin_Dude owner=2` (the joiner).
* 21:02:29.3 — host opens its **own** conversation with Hans
  (`host/kcd.log` 233961).
* 21:02:30.5 / 21:02:30.6 — host `NPC-SYNC puppet start DialogTwin_tkop_ptacek`
  then `puppet start DialogTwin_Dude` (234095, 234102): **the host's own
  conversation stand-in and camera rig became a puppet of the joiner's stream,
  1.2 s after the host started talking.**
* 21:02:30.6 — `NPC-SYNC anim DialogTwin_Dude -> sprint spd=10.62`: the
  renderer's computed speed for the rig, in metres per second.

Symmetrically, the joiner's own twin was puppeted four times by the host's
stream — `j2/kcd.log` 158503, 159446, 160164, 162965, at **7.64, 11.91, 18.69
and 28.07 m/s**. The puppet tick also rotates what it writes: the host's twin
was turned to the peer's yaw of 2.0718 rad against its own 1.0603 rad.

Across the session the relay granted **eight claims on `DialogTwin_*` names**,
held for up to **618.3 s**.

*(A note for anyone re-checking those speeds: `NPC-SYNC anim … spd=` has two
possible sources. Under `mp_npc_smooth off` it is a per-tick distance-to-target
scaled by ten — not a velocity. Under the shipped default it comes from
`mp_npc_smooth_render`, which returns `distance / segment duration`, i.e. real
m/s. No console toggle ran on any machine this session, so the default was
live and these are metres per second. An adversarial re-check of this section
read the wrong branch and concluded the figures were ten times too large; they
are not.)*

**The camera damage is directly observed, not inferred.** Inside the host's
dialogue 858 the engine logged **26** `Every dialogue camera is invalid` lines,
and the failures line up with the puppet to the tenth of a second:

* The one camera cut issued **before** the puppet started — `host/kcd.log`
  234091 at 21:02:30.5, **0.1 s ahead** of the puppet start at 234095 —
  produced **no** camera failure.
* **All 20 cuts issued after it failed.**

And the cross-machine control removes the remaining alternative. At the same
moment, at the same spot, the **joiner** ran dialogue 629 — same NPC, same
procedural bone modes, 22 cuts, its Henry 1.3 m from the host's — and logged
**zero** per-cut failures. Same place, same time, same NPC, same camera type,
same build. The only asymmetry was which machine's conversation stand-ins were
being driven as puppets.

That closes the "bad location or bad authored geometry" alternative, and it is
why this finding is tagged **(observed)** rather than inferred.

Two parts of finding 3 remain open:

* **"Forced into the fight-Hans beat early"** — the drawn-weapon flag (bit 4)
  does cross the wire on `npc_state`/`npc_claim` and the receiver's puppet tick
  acts on it by calling `DrawWeapon`/`HolsterWeapon` (`kdcmp.lua` ~3016, ~3070),
  so a peer's Hans drawing his sword *does* make the local Hans draw his. The
  host logged `NPC-SYNC tkop_ptacek drew weapon` at 21:05:41.9 and the joiner
  at 21:08:39.7 — the host first, and the host held the claim-free authority
  stream. Whether the host's Hans drew because the host's own quest said so or
  because the joiner's stream did is **(inconclusive)** from the ordering alone.
* **"The joiner could not talk to Hans until the host went through it"** — no
  failed or aborted dialogue attempts appear on the joiner in that window, and
  `RestrictDialog` is only ever applied to ghost bodies, never to a real NPC or
  to the player (`kdcmp.lua:7176-7185`, code-verified). **(inconclusive)**

**The `NPC Chain Leak Detected` toast the reporter remembers at "21:05" is
real and is at 21:04:24.6** (`host/kcd.log` 240728): `NPC-SYNC CHAIN LEAK
CONFIRMED: puppet chain gen=5 is still running while gen=6 is current`. It is
WO-84's mechanism, and per WO-84 §3.5 it is a false positive with one real
cost. It fired four seconds after `puppet start tkop_ptacek` and is
**concurrent with, not causal of,** anything the player saw.

**Is finding 3 the same gap as 5/6/8?** **No — it is a distinct mechanism that
looks similar.** 5/6/8 are two worlds legitimately disagreeing about a shared
NPC. Finding 3 is the mod syncing an entity that was never shareable in the
first place: a per-conversation, per-world stand-in that happens to have the
same name on both machines. It needs no story model to fix — only an exclusion.

### 2.4 Finding 4 — swing jankiness, and the invisible helmet

Two separate things under one heading.

**Part A — the animation quality. Known residual gap, now with numbers.
(observed)**

First, the maintainer's explicit check: **no console toggle was executed on any
machine all session.** The only `[CONSOLE] Executing console command` lines in
the three logs are `exec autoexec.cfg`, `map kutnohorsko`, `map trosecko`,
`goto`, and `closeVisorOn kcd2mp_*`. So `mp_ghost_anim_refresh`, `mp_npc_smooth`,
`mp_npc_chainfix`, `mp_ghost_chainfix`, `mp_npc_proximity` and
`mp_npc_deathsync` were all at shipped defaults throughout. WO-84's throttle
and WO-77's renderer were active.

Second, the measurement. `[KCD2-MP] Anim: <id> <from>-><to> spd=` is logged on
a **tag change**, not on every `StartAnimation`, so its rate measures animation
churn rather than throttle failure. Over the host's whole session:

| Path | Tag changes | Mean implied speed | Max | Mean \|Δspeed\| between consecutive changes |
|---|---|---|---|---|
| Ghost (peer player body) | 4,331 | 2.71 m/s | **50.67 m/s** | **2.34 m/s** (315 pairs jumped > 4 m/s) |
| NPC puppet (WO-77 renderer) | 1,335 | — | — | **1.64 m/s** |

During the Hans fight the ghost's animation tag changed **~3.3 times per
second**, with implied speeds swinging between 1.1 and 9.8 m/s in consecutive
entries. No human locomotion does that; it is the speed *estimate* oscillating.

The reason is structural and already known: the ghost path still uses the
pre-WO-77 per-packet velocity estimator (`istate.vx/vy`, lerped in
`KCD2MP_UpdateGhost`, `kdcmp.lua:4144`), while the NPC puppet path was moved to
time-based interpolation-behind in WO-77 and is measurably smoother in the same
session on the same machine. **This is the already-flagged residual gap that
`docs/WO-75-jitter-design.md` scoped and the WO-63 gate deferred — not
something new.** The 50.67 m/s maximum is the estimator reacting to a packet
gap or a teleport.

**Part B — the helmet. A story-beat gap, and the gap was vanilla.
(observed + code-verified)**

The engine plays a Fader cutscene `prepadeni_ptacekPutsOnHelmet`. It fired on
the **joiner at 21:05:41.7** (`j2/kcd.log` 124302) and on the **host at
21:44:09.4** (`host/kcd.log` 400266) — **38 minutes 28 seconds apart.**

So for those 38 minutes the host's Hans genuinely had not put on a helmet in
the host's own world. There was no appearance change to miss.

**And the reason the host took 38 extra minutes is the base game, not this
mod** — see §2.5's correction. The host made eight attempts at that beat, and
the engine ran four *different* refusal branches that advance as the player
equips more of the required armour: "put it on", then "where's your helmet",
then two more, and only after the host opened the inventory at 21:44:02–
21:44:03 did the attempt at 21:44:05.6 play the winning pair and fire
`prepadeni_ptacekPutsOnHelmet` 4.6 s later. The joiner's successful attempt at
21:05:36.2 played the identical winning lines, after its own single inventory
session at 21:03:27.7. **The gate was a vanilla equipment requirement.**

Separately, and worth recording because it will matter later: **no NPC
appearance state crosses the wire at all** (code-verified). `AppearanceLoopAsync`
(`GameBridge.cs:1305`) reads the **local player's** equipped set
(`HttpGameTransport.cs:245-261`, `…/SoulList/PlayerSoul/EquipmentManager/…`)
and applies it to peer **ghosts**. There is no NPC equivalent and no opcode
carrying NPC equipment. The agent *does* read an NPC's equipped classes — but
only to resolve which swing fragment to play (`[npcsync] <name>: N equipped
item class(es) read for swing resolution`), and it never sends them anywhere.

**Verdict: (b), the story-beat gap, fully explains what was reported.** The
coverage hole in (a) is real and worth recording, but it is not what the player
saw, and this document does not claim it as the cause.

### 2.5 Findings 5, 6 and 8 — the core: two worlds, one NPC

**Status: mechanism established, fixed this session. (observed + code-verified)**

The precise causal chain, which is tighter than the narrative suggests:

1. **21:09:39.4** — the joiner claims Hans. For the next thirty-one minutes
   this is *harmless*: both players are on the same objective
   (`prepadeni_zjisti_od_ptack`), both are at the camp, and both worlds agree
   where Hans is standing. The host logs small contention only — `NPC-FIGHT
   tkop_ptacek displaced 0.63m … (n=293…303)` through 21:40:00–21:40:33.
2. **21:40:28.6–21:40:34.8** — the joiner plays the Ingame cutscene
   `prepadeni_armorLake`, and at **21:40:36.0** its objective advances to
   `mq01__pre_crouch`. The host is still on `prepadeni_zjisti_od_ptack` and
   will be for another nine and a half minutes.
3. **The joiner's Hans now walks off to do the next beat. The host's Hans must
   stay at the camp, because the host's quest needs him there.** Fourteen
   seconds later, at **21:40:50.9**, the host begins logging
   `NPC-FIGHT tkop_ptacek displaced **57.24m** from our last write in one tick`
   — and repeats it, at the same constant distance, through 21:41:28.6
   (`host/kcd.log` 391403–393871). Two fixed attractors, 57 m apart: the
   camp, and the lake.
4. **21:41:33.5** — the claim finally expires (`heldForSec=1914.1`). Not
   because anyone yielded: the joiner's own cutscene had suspended its
   `Script.SetTimer` chains, its emitter went quiet, and the relay's
   5 s-timeout-plus-15 s-engaged-hold lapsed. The same thing released the four
   other camp NPCs in a four-second burst at 21:40:34–21:40:38.
5. **From 21:41:33 onward Hans reverts to the damage authority's stream** —
   the host's. `ClientHandler.cs:512-517` (code-verified): the authority's
   ambient stream is broadcast unconditionally unless *someone else* holds a
   live claim. A non-authority must re-claim by proximity to get it back.
6. **21:54:55.2** — the joiner dies (`j2/kcd.log` 277748 `GameOver.gfx`;
   relay `[death] … reported their own death` 21:54:53.6), reloads
   `autosave005` at 21:54:58.4 and respawns at 21:55:28.6. It emits nothing
   while dead, so it cannot claim anything. **Hans stays on the host's stream.**
   The joiner, whose own objective (`prepadeni_nasleduj_ptacka` — *follow
   Hans*) depends on Hans being where the joiner's quest put him, gets the
   host's Hans instead. That is finding 8, exactly.

**One part of the report does NOT belong to this defect, and saying so
matters (observed).** Finding 6 reports that "the host could not progress at
all". That block was a **vanilla equipment gate**, not the claim lock. The
host's eight attempts at the Hans training beat ran four different refusal
branches that advanced step by step with each inventory session, and the
decisive one came only after the host opened the inventory at 21:44:02. The
attempt at **21:42:21.7 — 48 seconds after the claim had expired, with Hans
fully host-owned — still ran the refusal branch.** If the claim lock had been
the gate, that attempt would have succeeded. The unblocking event was the
player equipping the missing armour.

So: the sync defect below is real, has real visible artefacts, and is fixed
here — but it was not what stopped the host progressing, and this document
does not claim it was.

**The mechanism, stated plainly (code-verified):** the NPC claim layer has no
notion of an NPC being *in use by its own world's story*. It arbitrates purely
on who claimed first (`RouteNpcState`, `ClientHandler.cs:490`) and hands
ownership back to the damage authority by default whenever a claim lapses.
When two players are at different beats, the same NPC is required in two places
at once, and whichever client holds the claim overwrites the other's copy at
20 Hz — including when the other client's *quest* is the thing being
overwritten.

**Finding 5's jitter is not render jitter.** The evidence that distinguishes
them: render jitter is sub-metre and symmetric about the target; this is a
**constant 57.24 m** displacement between two stable attractors, sustained for
38 seconds, with the local engine and the remote stream each winning
alternate frames. No interpolation, smoothing or dead-reckoning change can
help — the two worlds disagree about which behavioural state Hans is in
(mid-fight at the camp vs. walking to the lake), and position smoothing has
nothing to say about that.

**The joiner's half, after it died (observed).** The same measurement on the
joiner's machine is worse. `j2/kcd.log` carries **79** `NPC-FIGHT tkop_ptacek`
readings over 8 m, spanning 759 s, and they climb: 11.95 m at 21:51:52,
22.71 m at 21:52:10, and after the deaths **235.96 m at 22:04:15 and 265.22 m
at 22:04:20**. A quarter of a kilometre between where the joiner's own quest
needed Hans and where the host's stream was putting him. That is finding 8
measured rather than described.

**Time sync held, independently confirmed (observed).** Through the whole
21:40–22:04 window every `ApplyTimeSkip` on both machines was either applied
forward or correctly gated as within-skew; the joiner's post-death reload
converged in 10 s (`[timeskip] reload: converged` 21:58:34.6). The reporter's
recollection is right.

**Would an objective-marker comparison have caught this? Mostly no — and this
is why the shipped fix does not use one.** The damage ran 21:09–21:41, and for
all but the last minute of it *both clients' last-known objective was the same
string*. A gate on objective equality would have been silent through almost
the entire incident. The marker is a checkpoint-coarse clock: six markers in
ninety minutes on the host, four on the joiner.

### 2.6 Finding 7 — Hans crouch-flicker

**Status: the maintainer's hypothesis is refuted at the relay layer.
(observed)**

The hypothesis was an authority/claim fight over Hans's state between the two
players. It is not supported:

* **There are zero `[CLAIM-CONTESTED]` lines in the entire session** — in
  either relay log, at any time, for any NPC. WO-81's detector
  (`docs/WO-81-findings.md` §3.1-3.4) fires both on the rejection path and on
  the reassignment path, and it fired never.
* Session totals are 402 granted / 386 released / **7 reassigned**, and all
  seven reassignments are from the *previous* session's window (17:02–17:09,
  `ttkc_bailiffSon`, `ttkc_woman_2`, `ttkc_man_2`, `ttkc_woman_1`,
  `ttkc_inkeeper`, `ttkc_woman_10`, `ttkc_man_22`) — none in this session, and
  none near the sneak beat.
* Throughout the sneak beat the joiner held every relevant claim uncontested.

**What the evidence does support — and here the engine states it outright.**
`j2/kcd.log` carries **554** `[Error] Animation-queue overflow. More then 16
entries` lines whose character instance is `tkop_ptacek`. They do **not** fall
in the `mq01__pre_crouch` window at all; they run **21:56–22:03** (266 of them
in the 21:57 minute alone), during the stealth escape through the rocks
(`honicka_ve_skalach`), which is where that NPC genuinely sneaks.

The queued clip names on that one character instance are the whole finding:

| Clip | Count | Whose |
|---|---|---|
| `relaxed_idle_both.caf` | 176 | **this mod's** puppet standing clip |
| `3d_relaxed_walk_turn_strafe.comb` | 88 | **this mod's** puppet walk clip |
| `2d_stealth_walk_strafe_spd_fwd.bspace` | 139 | the quest brain's stance clip |
| `2d_stealth_walk_strafe_spd_bwd.bspace` | 116 | the quest brain's stance clip |
| `crouched_idle.caf` | 5 | the quest brain's stance clip |

**That is direct engine-side proof of a standing clip and a crouch clip being
queued onto the same body until the 16-entry queue overflows** — which is
exactly "rapidly toggling crouched/uncrouched". It is the only crouch-specific
evidence anywhere in the three logs.

The two contributing mechanisms, both local, neither requiring a claim fight:

1. **Stance is never transmitted.** The NPC state flags are exactly dead
   `0x01`, unconscious `0x02`, drawn `0x04`, swing `0x08`, carried `0x10`,
   engaged `0x20` (`Protocol.cs`, code-verified). There is no crouch or stance
   bit, and no NPC equivalent of the player-ghost's `KCD2MP.playerSneaking`.
   A puppeted NPC's stance is therefore whatever the **local** brain decides.
2. **The puppet renderer re-issues a standing clip at 1 Hz.** The puppet tick
   restarts its looped clip on every tag change *and* unconditionally every
   1.0 s (`kdcmp.lua` ~3270), and the clips are
   `relaxed_idle_both` / `3d_relaxed_walk_turn_strafe` / … — standing
   animations. During a beat where the local brain wants Hans crouched, a 1 Hz
   standing-clip restart fighting a re-crouching brain reads exactly as
   "rapidly toggling crouched/uncrouched".

**And the puppet renderer has no way to say "crouched" (observed +
code-verified).** Its entire animation-tag vocabulary, measured over the whole
host log, is five values and no more:

| tag | count |
|---|---|
| `walk` | 522 |
| `run` | 251 |
| `combatidle` | 249 |
| `idle` | 187 |
| `sprint` | 127 |

There is no crouch tag, because there is no stance on the wire to derive one
from. A 20 Hz writer that can only ever say "walk" over an NPC whose brain is
crouch-walking is the complete shape of the defect.

The clip census above settles the mechanism: it is (2), the puppet renderer's
standing clips, colliding with the brain's stance clips on one body. (1) is
what makes (2) unfixable by animation tuning alone — with no stance on the
wire, the puppet renderer has no way to *know* the body should be crouched, so
it will always pick a standing clip.

**The shipped fix reaches this one too, by a route worth stating.** The
divergence release (§4) deletes the puppet entry, and the puppet tick is the
only thing calling `StartAnimation` on that body — so a released NPC stops
receiving standing clips entirely and its own brain animates it. The joiner's
`NPC-FIGHT` readings for this NPC run past 8 m throughout 21:51:52–22:04:31,
so the release would have fired during the flicker window and ended it. That
is an incidental consequence of fixing findings 5/6/8, not a separate fix, and
it is **(inferred)** — no live session has confirmed it.

What remains genuinely open: whether stance *should* be added to the wire so a
puppeted NPC can crouch correctly rather than merely being handed back. That
needs a live A/B and is named in §5.

### 2.7 Two defects found on the way

* **The mod tracked its own ghost bodies as world NPCs (observed).**
  `mp_is_mod_entity` (`kdcmp.lua:2440`) tests by entity *reference*, which goes
  stale after a save load while a same-named body still exists. After the
  joiner's 21:58 death and reload it claimed `kcd2mp_0` fifteen times in four
  seconds (relay 21:58:19–21:58:23); WO-66's reserved-name gate refused every
  one. The relay defended correctly, but the local side still spent one of only
  `maxTracked = 5` slots on a body it had spawned itself.
* **An entity literally named `start` was tracked on all three machines** — a
  second wasted slot.

---

## 3. Phase 3 — the mutual-acceptance gate: what is and is not buildable

The maintainer's design, stated with full conviction: *a story beat should not
begin, for either player, until both have accepted it, so the beat and any
cutscene/camera effects play in lockstep for both.*

### 3.1 Detection — mostly yes

Every usable edge is a raw engine log line the agent already tails:

| Edge | Line | Fires |
|---|---|---|
| Cutscene begin/end | `CutscenePlayer::PlayCutscene called for <Type> cutscene '<name>' with holder '…'` / `OnCutsceneEnd …` | Types seen in these logs: `Fader`, `Ingame`, `Rendered`. Already matched for `Rendered` only, as a pause signal. |
| Dialogue begin/end | `Attempting to start new dialogue (runtime id 'N') with souls 'Ex: A; Ex: B'` / `[ID: N] Dialog ending [… flags: NNNN]` | The runtime id pairs the two. 1,028 starts on the host. |
| Quest objective | `InitiateSaveGame() … questNameOverride: '@qname_X\|@obj_Y'` | Coarse: 6 on the host, 4 on the joiner, across 90 minutes. |

Two practical notes, both measured:

* **Barks are not separable at start time by the meta-override suffix.** Of
  1,028 dialogue starts on the host, 660 carry a `meta override:` tag
  (`COMBAT_SHOUT_OPPONENT`, `BATTLE_IDLE_BARK`, …) and 368 do not — and among
  the 368 plenty still end with bark flags (9104/9105/9112/9113). The usable
  start-time discriminator is **participant count**: a real conversation is
  multi-participant and includes the player (`Ex: Dude`). 115 of the host's
  141 `Dude` dialogues were multi-participant.
* **There is no reliable pre-roll.** `=== Precaching render data for cutscene:
  … ===` sometimes precedes `PlayCutscene` (host 171168 before 171213) and
  sometimes *follows* it (428011 after 428007; 446810 after 446804). It cannot
  be used as an "about to fire" hook.

**So a beat can be detected as it begins, never before it begins.**

### 3.2 Holding — not as designed, but not nothing either

Four separate levers were checked against the retail binary, not only against
documentation. That distinction matters: **the `ConsoleHTMLHelp/` reference
ships with the Modding Tools, not with the retail game**, and at least one
command it documents (`wh_ai_PauseNPC`) is absent from retail — so every
"ships on this build" claim below was confirmed by a retail string check.

**Cutscenes: nothing. (code-verified)** `wh_ui_StopCutscene`'s own shipped help
text is "Stop the cutscene previously played with `wh_ui_PlayCutscene`" — it
does not touch a quest-driven cutscene. `wh_game_unpause` exists with no
matching pause; `wh_game_pauseDebug` only "Shows info about game pause
sources"; `mov_NoCutscenes` is a skip, not a hold, and skipping on one machine
would desynchronise the two experiences rather than lock-step them. Whether
Warhorse's cutscenes are even CryMovie sequences, and so reachable by
`Movie.PauseSequences`, is **(inconclusive)** — the 1,370 `Playing sequence`
lines in the host log are all Mannequin idle/death names and none appears
around the Rendered cutscene.

**Quests: nothing at all, and this is stronger than expected.
(code-verified)** There is **no quest scriptbind on this build**.
`QuestSystem`, `ActivateQuest`, `CompleteObjective`, `IsObjectiveStarted`,
`GetActiveObjectives` and `C_ScriptBindQuest` are **0-hit across all four
retail binaries**, while 35 other `C_ScriptBind*` class names are present
(`Actor`, `Dialog`, `Soul`, `InteractionTrigger`, `Minigame`, `RPGModule`,
`SkipTime`, and so on). Warhorse's own scriptbind reference documents a full
quest API; it is simply not in the shipped game. **The maintainer's design
cannot be built on the quest system, because the quest system is not reachable
from Lua on this build at all.**

**Dialogue: a real lever, pointing the opposite way from the obvious guess.
(code-verified)** `soul:RestrictDialog(bool)` gates **being spoken to**, not
the subject's own agency. The shipped game Lua proves it:
`Scripts/Entities/AI/Shared/BasicAIActions.lua` reads
`self.soul:IsDialogRestricted(player.id)` **on the NPC being approached** and
returns a disabled talk hint, which becomes `enabled(false)` on the talk
interactor. Restricting the *player's own* soul would therefore not stop that
player starting a conversation — but restricting the **beat NPC's** soul on
both machines would stop both of them, and release atomically.

That is the shape of a genuine mutual-acceptance gate for player-initiated
conversation. Two things keep it from being shipped here:

* **The primitive is written but its effect has never been observed.** The mod
  performs exactly this write on every ghost spawn and logs
  `RestrictDialog(true): ok=true readback=true`. No line in any of the three
  logs shows a player actually unable to talk to a ghost.
* **Our readback was malformed and has never really run.** The call passed no
  argument where the engine expects the asker's entity id, producing a
  `[Script Error] Wrong parameter type` at every ghost spawn on all three
  machines. The `pcall` swallowed it and the log still printed a verdict.
  **Fixed in §4.**

**Input and engine-level holds: several, all unverified. (code-verified)**
`ActionMapManager.EnableActionMap` is called 25 times by the game's own
`player.lua` and is present in retail; the `interaction_talk` map contains
exactly the `talk` action, and `noninteractive` (exclusivity 1) admits only
camera and menu. The console `freeze` command ships with help text "Freezes
player". `wh_dlg_Enable` is a **global dialogue kill-switch** — "Enable dialog
system. If disabled all NPC's have nothing to say" — and
`wh_dlg_RequestMaxDistance` gates the request at engine level before any Lua
runs. All are reachable through the `ExecuteString` channel this mod already
uses; **none has ever been called on this build.** The cleanest theoretical
lever is the one that is *not* available: `interaction_filter.xml` defines a
`deny_all` Dialog filter, but `DebugEnableInteractionFilter` and
`EnableActionFilter` are 0-hit in retail.

**Time control: works, and was retired on judgement, not on failure.
(code-verified)** WO-11 live-verified a real `t_scale` 1 to 0.3 round trip
against the running game; WO-13 deleted the *response* because broadcasting a
slowdown penalises everyone for one person's menu. `t_Scale` and `t_GameScale`
both ship. Any proposal to revive it must answer that objection, not the false
claim that it does not work.

**One premise this investigation began with is wrong, and it matters for any
future gate. (observed)** A Rendered cutscene freezes the mod's
`Script.SetTimer` chains but **does not stop Lua running**: inside the host's
123.46 s cutscene gap, `kcd.log` carries 180 `[KCD2-MP]` lines including 23
`TICK_ALIVE` heartbeats stepping #8000 to #13500, matching the agent's own
"pumped 5546 frames in 123.4s". Those arrive over `ExecuteString` from the
agent. **So a gate can be armed and released during a cutscene** — the timer
chains are asleep, the push channel is not.

### 3.2.1 Verdict (i): can the beat itself be held?

**Not as a general mechanism. Yes for one specific class.**

* **Cutscenes: no.** No hold primitive exists, and there is no usable pre-roll
  either — `OnCutsceneInitialized` and `PlayCutscene` are adjacent log lines
  for the Rendered cutscene, with at most ~0.45 s of lead anywhere else.
  `InteractiveSceneManager::EnqueueScene` leads by 0.21 to 0.98 s but carries
  no identifier at all, and it fires for dialogues as well as cutscenes, so it
  cannot name the beat it precedes.
* **Quest-forced dialogue (`ForceDialogNode`): no Lua route.** Three of the
  session's beats came this way, including the sheriff negotiation.
* **Player-initiated conversation: yes, in principle.** It has a real
  pre-commit chain — `OnTalk: Dude-><npc>`, then `Soul 'Dude' requested
  dialog`, then `Attempting to start new dialogue`, then `Dialog camera
  activated` — with 0.24 to 0.70 s of measured lead. And
  `BasicAIActions.OnTalk` is ordinary game Lua bound by table reference, which
  a Startup script could in principle replace. Only 12 of the host's 602
  dialogues were player-initiated, but those are the ones a player chooses to
  walk into.

**So the design holds for the beats a player deliberately starts, and not for
the beats the quest system fires at them.** An engine-level lever
(`wh_dlg_Enable 0`, or `wh_dlg_RequestMaxDistance 0`) would cover both classes,
because it does not care how a dialogue was initiated. It is the most
promising single thing a live probe should test.

### 3.2.2 Why it is still not built here

The gate is a research result, not yet an engineering one. Every primitive it
would stand on is unverified on this build, and its failure mode is the worst
available: a restriction that fails to lift leaves an NPC permanently
un-talk-to-able and **hard-blocks both players' campaigns** — strictly worse
than the symptoms it would fix. The one piece of it this mod already uses had
a malformed readback that went unnoticed across two work orders.

So this session ships the readback fix, the detection layer the gate would
need, and this design — and names the gate as its own work order, blocked on a
single short live probe session: does `RestrictDialog` on a world NPC actually
suppress the talk prompt, does `wh_dlg_Enable 0` hold every conversation, and
can a Startup script durably replace `BasicAIActions.OnTalk`?

### 3.3 What *is* buildable, and why it is the better fix anyway

The damage in findings 5, 6, 7 and 8 does not actually come from beats firing
independently. Beats firing independently is, by itself, harmless — each player
sees their own story. **The damage comes from the mod's own sync layer forcing
one world's NPC state onto the other.** That layer is entirely ours, needs no
engine cooperation, no wire negotiation and no agreement from the other client.

That reframing is what §4 ships.

**Verdict (ii):** the largest honest subset is (a) never sync an entity that
was never shareable, (b) stop fighting a world that disagrees, and (c) tell the
players, in words, when their stories have diverged.

**Verdict (iii): what a live two-player session must confirm** — everything
below. Every line of §4 is synthetic-verified only.

---

## 4. Phase 4 — what shipped

| Site | Change |
|---|---|
| `kdcmp.lua` — `mp_is_excluded_npc_name` (new, ~2440) | Name families that never enter NPC sync: `DialogTwin_` (engine conversation stand-ins) and `kcd2mp_` (our own ghost bodies). |
| `kdcmp.lua` — `mp_npc_rescan`, `mp_drag_sensor`, `KCD2MP_ApplyNpcState` | The exclusion applied on all four paths: track, claim, drag-claim, and inbound apply. The inbound refusal logs once per name so a mixed-version session is visible. |
| `Protocol.cs` — `NpcDialogTwinNamePrefix`, `IsNeverSyncedNpcName` | The same two families, for the relay. |
| `ClientHandler.RouteNpcState` | The never-synced check moved to the **top** of the method, ahead of the damage-authority branch — which returned `Broadcast` without ever reaching the old reserved-name gate, and is how conversation stand-ins crossed the wire all session. A refused packet still mutates nothing (WO-66's invariant). |
| `kdcmp.lua` — divergence release (new, in `KCD2MP_NpcPuppetTick`) | When the local world drags a puppeted NPC **> 8 m** from our last write, **3 times within 30 s**, release the puppet and refuse to re-puppet that name for **60 s**. Receiver-side and one-sided: no wire change, no agreement, no quest model. Toast throttled to one a minute. `mp_npc_diverge on\|off\|<metres>`, default on. |
| `Protocol.cs` — `0x37 StoryBeatUp` / `0x38 StoryBeatDown` | The project's first quest-state wire format. `[kind:1][len:1][text]`, relayed verbatim with the sender prefixed. |
| `StoryBeat.cs` (new) | Pure functions: parse the objective key out of a checkpoint line, prettify it for display, describe a divergence. |
| `LogTailGameTransport` | `StoryBeatDetected` event, change-gated, anchored on `InitiateSaveGame()` only (the two `E_MMI_SaveGameRequest*` lines repeat the same value and would triple-fire). |
| `GameBridge` | Sends our objective on change and to each newly-seen peer; tracks each peer's; toasts the divergence once per changed pair. |
| Relay | `BroadcastStoryBeat` / `EnqueueStoryBeat`, no authority gate — a fact about the sender, like `HorseInfo`. |
| `kdcmp.lua` — `KCD2MP_ApplyGhostIsolation` + `KCD2MP_SetGhostIsolate` | `soul:IsDialogRestricted()` was called with no argument where the engine expects the asker's entity id, producing a `[Script Error] Wrong parameter type` at **every ghost spawn on all three machines**. The `pcall` swallowed it and the line still printed a verdict, so the "verified" half of that check has never run. Now passes `player.id`, matching the game's own use. |
| `kdcmp.lua` — `KCD2MP_SpawnGhost` spawn verify | New `GetCharacterFileName(0)` read-back. A ghost with no character instance on slot 0 — finding 1's signature — now says so at the moment it spawns (`SPAWN NO MODEL ghost 'N'`) instead of being reconstructible only by log archaeology afterwards. A healthy spawn logs its model path. |
| `tools/Test-WO90Synthetic.{ps1,lua}` (new) | 70 checks: the exclusion (all four paths, both roles, prefix edges), the divergence release (fires at the field distance, never on footwork, stand-off holds and lapses, toggle rolls back, bare invocation reports), and the spawn model read-back (both outcomes). |
| `dotnet/KcdMp.Client.Tests/StoryBeatTests.cs` (new) | 25 checks pinning the parse to the real field lines. |

**Deliberately not changed:** `VERSION`, `kdcmp.pak` (rebuilt at release cut,
per WO-88/WO-89 precedent), the native DLL, the ghost interpolation path, and
`ProcessPauseMarkers`.

**Test results: 377 checks, 0 failures** — 70 WO-90 synthetic + 48 NpcSmooth +
35 GhostInterp + 72 WO-84 + 47 WO-86 + 46 Client (21 existing + 25 new) + 59
Farkle. Solution builds with the same 8 warnings as WO-89.

### 4.1 The death-mid-beat edge case, answered explicitly

Finding 8 asked what happens when a player dies during a beat whose progression
depends on following an NPC. The shipped answer:

**Nothing needs to happen, because the NPC was never taken away.** Under the
divergence release, the moment the two worlds disagree about where Hans is, each
client hands its own copy back to its own engine and stops accepting the other's
stream for 60 s at a time. A dying player's world keeps its own Hans, standing
where that player's quest put him, for the whole death screen and reload —
because the survivor's stream was already being refused before the death
happened.

The pre-WO-90 behaviour was the opposite and is what the field saw: the dead
player emitted nothing, its claim lapsed, ownership reverted to the damage
authority by default, and the survivor's Hans was imposed on the reloading
player's world.

Two deliberate consequences worth stating: the stand-off is time-based rather
than death-triggered, so it needs no death signal and cannot be defeated by one
arriving late; and it self-heals — when the two worlds converge again the
displacement stops exceeding the threshold and the stream is accepted at the
next lapse.

### 4.2 The thresholds, validated against the session that produced them

The rule was replayed over every `NPC-FIGHT` reading in the real logs. The
readings are throttled to one per NPC per 5 s, so this is a lower bound on how
often the live rule would fire — which is the direction that matters when
checking for false positives.

| | Host | Joiner |
|---|---|---|
| Total readings | 1,139 | 382 |
| under 2 m | 1,106 (97%) | 259 |
| 2–8 m | 17 | 44 |
| over 8 m | **16** | **79** |
| distinct NPCs ever over 8 m | 6 | 1 |

**Across the whole 90-minute session the rule would have fired exactly twice on
the host and once on the joiner** — and every one of those is genuine story
divergence, not noise:

* `tkop_ptacek`, on both machines (§2.5) — the incident this WO exists for.
* `zoufalaObranaZaBohutu_attackers_soldierInCover_1/2/3`, host, 20:37:47–
  20:37:57: displacements of 8.64, 9.61, 9.95, 20.32, 23.85 and 24.49 m on
  three NPCs inside ten seconds. These are the prologue battle's
  cover-repositioning group, moved by the `zoufalaObranaZaBohutu_soldiersToCover_*`
  cutscenes — **the same defect in miniature, with a scripted group move firing
  at different times in the two worlds.** Releasing them is correct.

So the 8 m threshold sits an order of magnitude above ordinary contention —
97% of the host's readings and 68% of the joiner's are under 2 m, and the
joiner's higher tail is itself almost entirely Hans — while still catching both
real events. The three-hits-in-thirty-seconds gate
delays the release by about twelve seconds from the onset of the 57.24 m run —
long enough not to react to a single stray frame, short enough that a player
would barely see it.

### 4.3 Why a legitimate teleport does not trip the release

The obvious false positive is the authority legitimately moving an NPC a long
way — a fast travel, a scripted relocation. It does not trip this, by
construction: the quantity measured is the distance between **where we last
wrote the body** and **where we find it on the next read**, not the distance
the stream moved. A large *stream* jump is absorbed by the puppet tick's
existing snap branch (`dx*dx + dy*dy > 25.0` → set position directly), after
which our last write and the body agree and the next read shows nothing. Only
the **local engine** pulling the body away from our write is counted — which is
precisely the two-worlds-disagree case and nothing else.

The residual risk is the opposite one: a large local displacement caused by
something other than story divergence — ragdoll physics, a fall, a mount —
could release a puppet that did not need releasing. The cost of that is 60 s of
an NPC running on local AI, which is the pre-multiplayer behaviour and is
strictly less bad than the 57 m tug-of-war. `mp_npc_diverge <metres>` exists so
the field can raise the threshold without a rebuild if this turns out to be
common.

---

## 5. Named, not attempted

1. **The mutual-acceptance gate itself.** §3.2 establishes it is buildable for
   player-initiated conversation and names three engine levers that might
   cover the quest-forced class too. Blocked on one short live probe: does
   `RestrictDialog` on a world NPC actually suppress the talk prompt; does
   `wh_dlg_Enable 0` hold every conversation; can a Startup script durably
   replace `BasicAIActions.OnTalk`? The design is written; the research is
   done; what is missing is three measurements.
2. **The crash (finding 2).** Not root-causable from these logs, and two
   apparent discriminators dissolved on checking. The concrete follow-up is
   making a crash dump available at all — §2.2 lists the three things that
   would settle it.
3. **Why finding 1's ghost had no character instance.** The mechanism is now
   established and the detector ships (§4); the *cause* is not. The next
   prologue session's `SPAWN NO MODEL` line, or its absence, is the next
   datum.
4. **Porting WO-77's time-based interpolation to the ghost path.** Finding 4A
   is direct field evidence for it (mean |Δspeed| 2.34 m/s on ghosts against
   1.64 m/s on the already-ported NPC path, with a 50.67 m/s outlier). Still
   behind the WO-63 gate; `docs/WO-75-jitter-design.md` already scopes it.
5. **Stance on the NPC wire.** §2.6 shows the puppet renderer's whole
   vocabulary is five tags with no crouch, against an engine-confirmed clip
   collision. The divergence release ends the flicker by handing the body
   back; making a puppeted NPC actually crouch is a separate, additive change
   and needs a live A/B of `mp_npc_smooth off`.
6. **NPC appearance sync.** No NPC equipment state crosses the wire in any
   form (§2.4B). Not the cause of the reported helmet gap — that was a vanilla
   equipment gate — but a real coverage hole, and the swing-resolution path
   already reads the data.
7. **A clock collapse to zero, unexplained (observed).** The session's final
   relay line, `host/relay20260912.log` 22:06:16.980, is
   `[timeskip] 'MooseSplosion' (id=2) clock sync -> worldTime=0 (quiet)` —
   while every other clock in the session was at 475205. It was quiet, so
   forward-only convergence discarded it and nothing broke. Nobody has
   explained how a client reports a world time of zero, and the next one might
   not be quiet.
8. **Dialogue- and cutscene-scoped beat locks.** Detectable (§3.1) but
   deliberately not shipped: nothing consumes them yet, and a wire kind with
   no consumer is a commitment made on speculation. `0x37` has room, and
   `0x39` is the next free byte.
9. **Two unopened 17 MB logs.** `host/logbackups/kcd.log` and
   `j1/logbackups/kcd.log` are complete, cleanly-terminated runs of the paired
   17:00 session — the one WO-88 analysed from the agent side only. They were
   not needed here and are a standing resource.
10. **The two wasted tracking slots** (§2.7): the `start` entity, and the
    stale `mp_is_mod_entity` reference test. The `kcd2mp_` half is fixed by
    this session's exclusion; the reference test itself is untouched.
