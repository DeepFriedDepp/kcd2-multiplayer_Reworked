# WO-104 — findings

Session 2026-09-18. Progress: `docs/WO-104-progress.md`. Field runbook:
`docs/WO-104-field-runbook.md`. Input: the first two-player session since
0.23.2 (0.26.1, both machines, same day).

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).

## 0. Answer first

* **Time sync died on a number-formatting threshold, not on any recent
  work.** The world clock crossed 1e6 and `tostring()` in this build's Lua
  produced `1.00255e+06`; the agent's integer parse refused every reading
  from then on (observed, agent.log). Fixed at the sender with `%.0f`;
  parser deliberately left strict. Every other 1e6-exposed field audited
  and named (§1.3). Shipped on its own as commit `6637e5e`.
* **The pause lever does not work under a live stream.** 155/155
  `MP-AUTHORITY-VIOLATION` with `paused=1` on the joiner (observed). Solo
  5/8 measured a body nothing else was writing. Default flipped OFF (§2).
* **The replacement is built: brainless replicas for contested NPCs,
  behind `mp_npc_replica_on`, default OFF** (§3). The body is `NPC` +
  `NoAI=true` soul-bound to the original's own soul id, not `NPC_NAI` —
  the prompt's class is unreachable with a soul on this build (observed,
  WO-100.5 §1.3) and the prompt's brief said to say so plainly. Nothing in
  §3 has run live; every claim there is (synthetic) or (code-verified).

## 1. Phase 0 — time sync formatting

### 1.1 The failure (observed)

agent.log, joiner and host, 2026-09-18:

```
[timeskip] malformed time_now '1.00255e+06'
[timeskip] malformed time_now '1.02563e+06'
[timeskip] malformed time_now '1.04008e+06'
```

Last good `982149`, first broken `1.00255e+06`. Sender:
`KCD2MP_EmitEvent("time_now", tostring(math.floor(t)))`. Standard Lua 5.1
formats numbers with `%.14g` (1002550 prints as `1002550`); this engine's
Lua prints `%g` — six significant digits, exponent at 1e6. (observed:
the log; code-verified: the sender line.) At 1e6 world-seconds ≈ 11.6
world-days, so every save reaches it.

Every symptom the maintainer reported follows: sleep/wait fast-forwards
locally, nothing crosses; a peer's wait does nothing; NPCs "behaved oddly
after a sleep" (the two clocks were hours apart and the schedules with
them).

### 1.2 The fix (code-verified; synthetic 7/7)

`string.format("%.0f", math.floor(t))` — exact for any integer a double
holds, never an exponent. **Sender fixed, parser not widened**: the
agent's `TryParseWorldTime` is digits-only. A parser that accepted
`1.00255e+06` would also accept a reading that had already lost digits
(six significant figures at 1e6 is a ~5 s granularity) and the clock-jump
watcher would see phantom jumps.

Synthetic: `tools/Test-WO104Synthetic.ps1` installs a `%g` `tostring`
mimic *before* `kdcmp.lua` loads — the mimic itself reproduces
`1.00255e+06`, so the test is proven to bite — then reads `1002550`
exactly at 1002550, 1002550.7 and 4294967295, and a >1e6 apply lands
exactly. Agent: `WorldTimeFormatTests` (13 new, 170/170) pins the strict
parse and source-guards both fixed Lua lines.

### 1.3 The audit — every other numeric field, named (code-verified)

Direction that is exposed: **Lua → agent only**, and only fields the agent
parses as integers. Agent → Lua is not exposed: numbers are interpolated
as C# invariant integers or `F3/F4` floats, and Lua's lexer accepts an
exponent anyway. Native pipe and relay are binary.

| Lua → agent field | how built | agent parse | exposed? |
|---|---|---|---|
| `time_now` | `tostring(math.floor(t))` | `uint` | **YES — fixed** (`%.0f`) |
| `invite_send` wager | `tostring(math.floor(wagerAmount))` | `int` | latent (groschen ≥ 1e6 is theoretical) — **hardened** to `%.0f` |
| `invite_send` target id | `tostring(bestId)` | `byte` | no — ghost id ≤ 255 |
| `dice_intent` keep mask | `tostring(math.floor(mask))` | `byte` | no — ≤ 63 |
| `ghostid`, `npcid` | `string.match(tostring(e.id), "(%x+)%s*$")` | hex `ulong` | no — `e.id` is an engine handle, tostring is its hex form, not a number |
| `npc_state`/`npc_drag`/`npc_claim` x y z rot hp | `%.3f %.3f %.3f %.4f %.1f %d` | `float` (`NumberStyles.Float`) / `byte` | no — fixed specifiers |
| `npc_death` hp | `tostring(hp)` | `float` | no — accepts exponent; hp < 1e6 |
| `ghost_hit` | `%.2f` | `float` | no |
| `item_drop` amount / health | `%d` / `%.4f` | `ushort` / `float` | no |
| `item_claim` | `tostring(dropId)` | `uint` | no — `dropId` arrives from the agent as a **quoted string**, tostring is identity |
| `authority_radius` | `%.1f` | `float` | no |
| `[KCD2-MP-DATA]` frame | `%d %.3f … %.2f` | fixed | no |
| `[KCD2-MP-EVT]` seq | `%d` | — | no (2^31 events) |

Two `tostring(number)` fields on the integer-parsed channel, both fixed.
Log-only `tostring` calls (mp_log, MP-SUMMARY-MOD's `clock_offset_ms=%s`)
are unaffected by design — nothing parses them.

## 2. Phase 2 — the pause lever, live

(observed, joiner kcd.log, 2026-09-18, 0.26.1)

```
MP-AUTHORITY-VIOLATION npc=ttkc_man_10 kind=contention dist_m=0.41 owner=0 paused=1 n=1
```

155 lines, 148 `contention`, 7 `diverge`, **all `paused=1`**. That is the
diagnostic WO-102 §4.3 defined for exactly this: the mod issued
`wh_ai_PauseNPC`, believes the NPC paused, the local brain still writes.
Under a live stream the lever is 0/155. The solo probe (8/8, then 5/8 —
WO-102.5 §6.1) was not wrong; it measured a body with no second writer.

Shipped: `KCD2MP.wo102.authorityPause = false`. The agent does not push
this toggle at connect (code-verified: only `authority_host`,
`pos_native`, `npc_scan_native` are pushed), so the Lua default is the
shipped default. Code and toggle kept — it may hold for idle NPCs; the
violation counter shows it. Recorded next to WO-102.5 §1.1, §6.1 and
WO-102 §4.3.

What did work and was not touched: authority (zero `owner-change`, host
owned everything), the damage path, native position (observed).

## 3. Phase 1 — replicas for contested NPCs

### 3.1 Why not `NPC_NAI` (the prompt's class) — observed, prior sessions

WO-100.5 §1.3, 3 of 3: `XGenAIModule.SpawnEntity{ClassName="NPC_NAI"}`
builds `NPC`; `System.SpawnEntity{class="NPC_NAI"}` builds `NPC_NAI` but
binds no `SharedSoulGuid`. The class or the soul, never both. A soulless
body is the WO-56 bare-spawn family (faction spam every frame, A1
knockdown) — and the prompt's own item 3 says the replica needs a soul.
So `NPC_NAI` is unreachable for this job on this build. The reachable
brainless body is **`NPC` + `NoAI=true`** (WO-100.5 §1.4, observed): soul
binds, `SituationController` 0, behaviour tree 0, self-initiated dialogue
0, still perceptible, still a crime victim. Built on that.

### 3.2 What was built (code-verified; synthetic 91/91)

`kdcmp.lua`, "WO-104 Phase 1" block before `KCD2MP_ApplyNpcState`;
`GameBridge.cs` `npc_replica` handler + outbound remap.

* **Trigger**: the first `MP-AUTHORITY-VIOLATION` for an owned puppet on
  a non-owner under host authority (`KCD2MP_NpcReplicaConsider`, called
  from `mp_wo102_violation`). One violation is already 10 consecutive
  displaced ticks or a >8 m yank. Not "weapon drawn" — a guard walking
  with a drawn weapon is not contention.
* **Promote** (`KCD2MP_NpcReplicaPromote`), one Lua call = one frame:
  read the NPC's actual pose → spawn `kcd2mp_r_<name>` there
  (`ClassName="NPC"`, `NoAI=true`, `SharedSoulGuid = tostring(e.soul:GetId())`)
  → verify it has a soul (else remove it and refuse) → turn it to the
  NPC's facing → `e:Hide(1)` on the NPC → register → reset the puppet's
  render state → emit `npcid <name> <replica hex id>` and `npc_replica
  <name> kcd2mp_r_<name>` → `MP-NPCREPLICA event=promote`. The spawn
  comes first, the hide second, both before the call returns: no frame
  in which neither or both bodies render.
* **The puppet tick drives the body** via `KCD2MP_NpcBody(name)`
  (replica while registered and alive, else the NPC) and **reads life
  state from the NPC** (`IsDead`/`IsUnconscious`/health), never the
  replica. The tick that promotes returns before writing, so the first
  write lands on the new body.
* **Demote** (`KCD2MP_NpcReplicaDemote`), one call: NPC teleported to the
  replica's pose, facing copied, `Hide(0)`, replica removed (4-pass
  verified), `npcid` re-emitted with the NPC's id, `npc_replica <name> -`.
  Reasons: `sheathed` (stream's drawn bit off for 10 s), `dead`/
  `unconscious` (stream bit or the NPC's own state — the real corpse is
  the one on the ground), `silence`/`diverge` (puppet released),
  `toggle-off`, `host-authority-off`, `mod-stop`, `replica-gone`/
  `original-gone`/`no-puppet` (sweep).
* **Sweep** every 5 s from `KCD2MP_NpcSyncTick` next to the pause
  reconcile, toggle or not: vanished bodies, and any unregistered
  `kcd2mp_r_` entity within 60 m of the player is removed and its
  original unhidden (`event=orphan`). This is the mitigation for the
  save hazard (§3.5).
* **Names.** Replica `kcd2mp_r_<name>` → in `MP_NPC_NAME_EXCLUDE`, so this
  world's emitter never streams it and no inbound stream can target it.
  The NPC keeps its name: 0x31 damage, remote death, resync, the RPG
  SoulList all keep resolving to the canonical local copy. Two by-body
  paths are re-pointed: native swings (`npcid` → `_npcEntityIds`) and
  the agent's outbound damage name — the DLL hit sensor reports the
  struck body's own soul, REST resolves that to `kcd2mp_r_<name>`, which
  the owner cannot resolve and which this agent would drop as a ghost
  body (`kcd2mp_` prefix). `_npcReplicaOrig` remaps it to the NPC's name
  before the guard and the send. **No wire change.**
* **Toggle**: `mp_npc_replica_on|off|status`, argless (WO-94's console
  rule). Default **OFF** — the one exception to shipping new mechanisms
  on, because a wrong replica is visible and disruptive in a way a quiet
  toggle is not. `MP-AUTHORITY-VIOLATION` gained `body=npc|replica`;
  MP-SUMMARY-MOD gained `replica_*` counters.

### 3.3 Appearance — answered, with the boundary stated

* `soul:GetId()` — "Returns unique and persistent id of this soul (WUID)"
  (Warhorse scriptbind reference, `C_ScriptBindSoul::GetId`). The roster
  guids are WUIDs of the same form (code-verified). A body spawned with a
  real soul's `SharedSoulGuid` gets that soul's authored head, hair,
  beard **and default outfit** (observed: WO-20 §"soul-bound … his own
  authored default outfit"; WO-69 19/19 roster souls). So the replica
  wears the NPC's authored appearance.
* **What it does not copy**: live inventory state. An NPC the player
  stripped, or one the game re-dressed, comes back in its authored
  outfit. A **real gap**: whether `soul:GetId()` on an arbitrary world
  NPC returns the authored soul WUID or a per-save instance id is
  (inconclusive) — never read live for a world NPC in this project (the
  DLL's guid read is per-save, WO-39/40; the scriptbind says
  "persistent"). If it is per-save, `XGenAI` may bind nothing and the
  spawn comes back soulless → refused, nothing hidden, `why=
  replica-soulless` logged. Fail-closed by construction: **the NPC is
  never hidden unless the replica has a soul.** A WUID that binds a
  *different* appearance is the one case the guard cannot catch; the
  runbook asks for a look at the face.
* Two entities on one soul at once is the shipped state already: every
  ghost is a roster soul whose real NPC is alive in the world
  (code-verified, WO-20/WO-69).

### 3.4 What this cannot serve — named, not promoted

Refused, logged once per name+reason, nothing spawned, nothing hidden:

1. **Any class but `NPC`** — `NPC_Female` (`NoAI` never probed on it),
   `Horse`, animals.
2. **Down or carried bodies** — dead, unconscious, `carried` bit.
3. **An NPC in a conversation** — `human:IsInDialog()`, a documented bind
   never live-verified (WO-88 §2.1); guarded by type and pcall, an error
   counts as not-in-dialog.
4. **A soul whose id does not read as a WUID** (§3.3).
5. `DialogTwin_*`, `kcd2mp_*`, the local player — refused upstream.

By consequence, not by check: **while promoted the NPC cannot be talked
to** (its body is hidden) and **hits it takes on the replica stay on the
replica** — the NPC returns with the health it had. Bounded: promotion
ends 10 s after the owner's stream sheathes, or at once on death. A quest
NPC that must be spoken to *during* a fight the joiner is contesting is
the one case this design makes worse than today; nothing in the mod can
identify it (WO-90/92: no quest scriptbind on retail).

Perception is **not** lost on this body (class `NPC` keeps
`bWH_PerceptibleObject`; WO-100.5 §1.4 observed it witnessed and
reported) — the prompt's "anything another NPC must react to" category
applies to `NPC_NAI`, not to `NPC`+`NoAI`. Look/head tracking and
self-initiated dialogue are gone on the replica; irrelevant for a
stream-driven body in a fight.

### 3.5 Risks stated

* **Save hazard** (same class as the pause lever's, WO-102.5 §1.3): a
  save written mid-promotion persists a hidden NPC and a `kcd2mp_r_` body.
  No pre-save hook exists. The 5 s sweep cleans it the next time the
  NPC-sync tick runs in a connected session; a solo load without
  connecting shows a brainless duplicate until then. (code-verified
  mitigation; the persistence itself is inferred from WO-84's
  savegame-restored ghosts — inconclusive for `Hide`.)
* **Fist fights**: the drawn bit never rises, so `sheathedSince` starts at
  promotion and demotes after 10 s; renewed contention re-promotes. Each
  cycle is one one-frame swap. Acceptable; visible in the log as
  repeated promote/demote pairs.
* **Whether `Hide(1)` stops the hidden NPC's physics** on this build is
  (inconclusive) — CryEngine convention says yes. If not, the player
  could bump an invisible body standing where the fight began.
* **Native swings on the replica**: `npcid` re-points the DLL's entity id
  (code-verified); whether the DLL's swing path accepts a `NoAI` body is
  (inconclusive) — WO-45/49 verified it on full NPCs and ghosts.

### 3.6 Coverage (synthetic, MoonSharp on the real kdcmp.lua)

`tools/Test-WO104Synthetic.ps1` 91/91: (b) toggle off byte-identical to
today (violation logged `body=npc`, nothing spawned, NPC never hidden,
still written); (c) promote: one spawn, `NPC`/`NoAI`/original's soul id/
`kcd2mp_r_` name, hidden once in the same call, `npcid`+`npc_replica`,
stream writes the replica and never the NPC again, zero replica
violations; (d) sheathed demote after 10 s, NPC back where the replica
stood, events reversed, writes resume on the NPC; (e) death via stream
bit and via the NPC's own `IsDead`; (f) silence, toggle-off, host-off,
mod-stop; (g) 8 refusals; (h) sweep incl. from the sync tick with the
toggle off; (i) commands, status, summary. Agent 170/170. WO-102 196/196;
every other Lua suite unchanged (48/35/72/47/70/101/32/160/50/39/33, WO-99
"exits 2" and WO-1005 "RESULT 0" quirks pre-existing on HEAD, confirmed by
re-running WO-1005 against HEAD's kdcmp.lua).

## 4. The trap this session adds

**A solo probe that passes proves the solo case only.** `wh_ai_PauseNPC`
held 5/8 with nothing else writing the body and 0/155 with a live stream.
The probe was measuring a different situation than the one the lever
shipped into. Corollary for §3: 91/91 synthetic proves the Lua half does
what it says against stubs; it proves nothing about `XGenAI` binding a
world NPC's `soul:GetId()`, about `Hide`, or about the swap being
invisible. That is why the toggle is off.

## 5. Open, not this WO

Unchanged from the prompt: the native scan never reaching Lua (`unfinished
string near '<eof>'` every ~2 s), NPC existence divergence, a synced
quicksave, peer-reload un-pausing, co-location runtime setters,
`C_PortRef::Trigger`, Steam P2P, the byte-wide relay id wrap.
