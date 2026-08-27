# WO-69 — field regressions: female ghost spawns + puppet jitter

Two tester reports from build **0.18.2**, diagnosed against current `main`
(**0.18.6**, not 0.18.4 as the work order assumed — 0.18.5/0.18.6 are WO-68's
native civic isolation and a version bump; neither touches ghost spawning or
puppet presentation, confirmed by `git log --name-only`).

Evidence tags used throughout, never rounded up:
**(observed)** seen running or read out of a real log ·
**(code-verified)** read in current source, not seen running ·
**(read-but-unrendered)** stated by a prior doc, not re-checked here ·
**(inconclusive)** the evidence does not settle it.

Privacy: the tester bundle carries real identifiers. No real player name,
Windows username, IP or hostname appears in this document. The host's nick is
referred to structurally only; its literal bytes and exact hash were used
locally to produce the verification below and are deliberately not recorded here.

---

## Report 1 — the host's ghost spawns female

### Root cause

**H1, pure and deterministic.** `KCD2MP_PickFaceForPlayer` derived gender from
the parity of a djb2 hash of the player's name key — `isFemale = (h % 2) == 0`
— against a roster that still contained 24 female souls. The tester's host nick
hashes to an **even** value, so his ghost resolved to female roster slot 9
(`ttac_woman_7`) **every single time**. Nothing failed. The picker executed
exactly as written. (observed + code-verified)

The report's word "often" is the only misleading part of the symptom, and it is
the tester generalising across players, not across spawns: gender was a coin
flip **per name**, not per spawn. Roughly half of all possible nicks hash even.
Since every KCD2 player character is Henry, that half was wrong **by
construction**.

### Evidence

- (observed) The bundle contains exactly **4** ghost spawns, all of ghost id 1
  (the host), and all four print a byte-identical line:
  `face pick for '1': key=<hostNick> class=NPC_Female soul=ttac_woman_7
  guid=ddf4ac93-d15d-4728-8083-16cf46f68444`.
  `grep -c` over the bundle: `"Spawning ghost"`=4, `"face pick"`=4.
- (observed) Recomputing `KCD2MP_HashString` over the nick's real bytes
  reproduces the logged pick exactly: parity **even** → female list → index 9 →
  `ttac_woman_7` → that guid. The algorithm is not merely consistent with the
  log, it *is* the log.
- (observed) The engine really built a female body, not just a mislabelled one:
  **7,904** engine lines name `kcd2mp_1` as class `(NPC_Female)`, and the female
  skeleton database (`wh_female_database.adb`,
  `humans/female/skeleton/female.chr`) loads 1–2 lines after each spawn.
- (observed) **H2 and H3 are ruled out for this incident.** Zero
  `"XGenAI spawn failed"`, zero `"SpawnEntity failed"`, zero nils and zero
  errors anywhere on the spawn path; all four spawns logged
  `SetIgnorant ok=true` and `ApplyName ok1=true ok2=true`. There was no
  unresolvable soul and no failed binding to fall back from.
- (observed) **H2 is additionally ruled out for the shipped roster as a
  class.** All 19 male roster `SharedSoulGuid`s were read back live from a
  running build during this session via
  `/api/rpg/SoulList/SoulsByName/<name>/SharedSoulGuid` — **19/19 matched** the
  values checked into `kdcmp.lua`.

### WO-58's fix is intact, and did not cover this

(observed) WO-58 fixed a *different, independent* path to the same symptom: a
ghost that spawned before its nick arrived was face-picked from the
`"Player<id>"` fallback key, and `hash("Player1")` is also even. That fix
shipped in 0.17.5 and is an ancestor of the 0.18.2 tag
(`git merge-base --is-ancestor` confirms).

It did not fire here and did not need to: (observed) the name packet arrived
**88 ms before** the first spawn, only **one** `[name]` line exists in the whole
40k-line agent log, and the bundle contains **zero** `"no Steam nick yet"` lines
and **zero** corrective-respawn lines. The fallback keys produce
`tsem_woman_9`/`tsla_woman_1`/`ttac_woman_3` for ids 1/3/5 — none of which is
the observed `ttac_woman_7`, which independently proves the fallback never ran.

So the belief that the bug was "fixed alongside the bandit roster removal" was
wrong on both counts: (code-verified) **WO-34 removed five bandit souls, all
male; it never touched the female table**, and WO-58 fixed a different cause of
the same symptom. Two independent mechanisms, one visible outcome — which is
why fixing one left the report standing.

### Two incidental findings worth carrying

- (observed) **Soul collision.** The real world NPC `ttac_woman_7`
  (entity `0x1B3E`) was streamed in and puppeted at 22:36–22:38 **while the
  ghost bound to that same soul GUID was still alive** — two identical bodies
  sharing one soul. Removing the female roster removes this instance, but the
  general hazard (a roster soul colliding with its own live world NPC) applies
  to the 19 male souls too and is **not** addressed here.
- (observed) A female-classed ghost **skips the armour and weapon presets
  entirely** (`kdcmp.lua` guards the preset on `className ~= "NPC_Female"`),
  which is why the agent logged 13 `"no table row for its weapon set"` lines for
  this ghost. This is WO-23's "no female combat armour exists" showing up as
  behaviour, not just as a catalogue fact.

### Fixed

- Gender no longer derives from the hash: the picker returns `className = "NPC"`
  unconditionally and reads only `KCD2MP.faceRoster.male`.
- The 24-entry female table is deleted.
- **Existing male players keep their exact faces.** The work order assumed
  `#list` would go 43→19; (code-verified) it would not — the gender branch chose
  the list *before* the modulus, so `#list` was already 19. Only the ~50% who
  were rendering as women change, and they change from a wrong body to a right
  one. This is strictly milder than WO-34's 100% re-roll. Reordering or
  "tidying" the male table would forfeit this property.
- **Verify-after-spawn ships permanently**, even though the root cause is now
  removed: every spawn logs `requested class=… soul=… guid=… | resolved
  class=… soul=…`. `entity.class` is the authoritative gender read (gender comes
  from the class, not the soul). A **definite, non-nil** disagreement logs
  `SPAWN MISMATCH` loudly and respawns **once** onto a named male commoner
  (`ttkc_man_3`, guid live-verified this session) — never the engine default,
  which is what a discarded `SharedSoulGuid` silently produces (WO-22).
  Nil is treated as *unknown*, never as mismatch: `ApplyName` already logs
  `before=nil` on live ghosts, so treating an empty read as a negative would
  respawn healthy ghosts in a loop.

### Not established

- (inconclusive) Whether the symptom is *ever* genuinely intermittent for one
  player. This bundle shows 1 distinct key over 4 spawns; a second player with
  an odd-hashing nick would have rendered male all session. The
  `"Player<id>"` race remains a real second mechanism — WO-58 repairs it
  *after* the fact (spawn female → detect → respawn), so a brief female flash
  is still possible on a name-after-position race. Not observed here.
- (inconclusive) Whether the fallback respawn path works, because it has never
  fired — there is no known way to make a roster soul fail to resolve on demand.

---

## Report 2 — puppet jitter

### Verdict: D1 is present and quantitatively confirmed. D2 was never tested. A third cause (D3) is likely and is the reason to be careful.

The work order's D1 as literally worded — "applies raw positions at emit
cadence" — is **false for XY**: (code-verified) the puppet path does have a
first-order lerp. But it is the *only* smoothed channel, and the lerp is the
wrong shape for the cadence it runs against.

### The mechanism, with arithmetic

(code-verified) `emitMs = 250` — the emitter is **4 Hz**, not the 50 ms stream
the work order and WO-32 both describe. The puppet apply tick is **50 ms**. So
**4 of every 5 ticks carry no new data**, and the lerp

```lua
p.cx = p.cx + dx * 0.5      -- dx measured against a target that only moves 4x/sec
```

is an exponential decay toward a *stale* target that resets on every packet.
Rendered per-tick speed across one 250 ms window is `10·D·0.5^k` for
k = 1..5 — a **16× velocity swing, four times a second**, then a spike back to
full. Coordinates stay correct; the motion between them is a lurch-and-coast.

(observed) **The log confirms this arithmetically, not just qualitatively.** The
mod derives its animation tag from that same rendered speed
(`spd = sqrt(dx²+dy²) * 0.5 / 0.050`), so the anim log is a direct readout of
rendered velocity. For a single NPC it reads:

```
run walk idle run walk idle run walk idle run walk idle …
```

— a perfectly periodic 3-state cycle, repeating without end. Substituting a
walking NPC's per-packet delta into `10·D·0.5^k` against the shipped thresholds
(sprint ≥5.5, run ≥3.0, walk ≥0.3) predicts exactly `run → walk → idle` then a
spike back to `run`. **The prediction and the field log match term for term.**
Session-wide the churn is heavy: 2,241 `walk->idle`, 1,778 `run->walk`,
1,199 `sprint->run`.

### What the puppet path lacks that the ghost path has

(code-verified) The two are entirely separate code, and the puppet state table
(`{tx,ty,tz,tr,hp,dead,cx,cy,cz,cr,lastPacketAt,animTag}`) has **no** `px/py`,
`alpha`, `alphaStep`, `vx/vy`, `smoothedSpeed` or `speedDropTicks`.

| | puppet (`KCD2MP_NpcPuppetTick`, 50 ms) | ghost (`KCD2MP_InterpTick`, 20 ms) |
|---|---|---|
| position | first-order lerp, factor 0.5, snap >25 m² | constant-rate `alpha`/`alphaStep` lerp |
| velocity | **none** | dt-based from last two packets, smoothed |
| dead reckoning | **none** | present, capped |
| direction damping | **none** | present |
| yaw | **hard snap** | `lerpAngle` (shortest-path) |
| anim speed | pre-lerp residual | smoothed + hysteresis |

The yaw hard-snap is a second, independent jitter source that no amount of
position smoothing would fix.

### D2 — not refuted, not tested

(observed) The `p.fightN` contention counter **never ran**: it prints only via
the manual `mp_npc_fight` console command, and the bundle has zero such lines.
Its threshold is also `> 0.5625` m² per 50 ms tick = **15 m/s**, blind to
essentially all realistic contention. (code-verified) The local brain is **not**
suppressed on puppets, so D2 remains live as a mechanism — and the code already
carries a same-class precedent: puppets log
`re-asserted drawn/sheathed (local brain fought back)`, i.e. the brain
demonstrably fights the *drawn state*. Whether it also fights position was
never measured, in either direction. **(inconclusive.)**

### D3 — a probable chain leak, newly found

(observed) `puppet tick started (50ms)` appears **114** times against **39**
`stopped`, in runs of up to 9 consecutive starts with no stop between.
(code-verified) The mechanism is available: `tickAlive` treats a heartbeat older
than 1.0 s as dead, and a menu suspends `Script.SetTimer` (WO-12/13) — so a
menu open can make a *live but suspended* chain look dead, start a second, and
leave both running once the menu closes. N concurrent chains apply the 0.5 lerp
N times per 50 ms, which converts the decay into a near-instant snap followed by
a 250 ms wait — **worse** jitter, not better, and it amplifies D1 rather than
competing with it.

**(inconclusive)** as stated, and honestly so: the log **cannot** distinguish
"restarted after a genuine death" from "second concurrent chain", because there
is no per-chain identity and no per-packet record anywhere. Five save loads
occurred in the session, and save loads legitimately kill timers. The
same shape appears on the send side — 22,019 `npc_claim` lines in 368 bursts,
15× duplication, with 12,412/12,412 consecutive same-NPC pairs inside one frame
carrying byte-identical coordinates.

### Ruled out

(observed) Latency: RTT p50 16 / p90 51 / p99 109 ms over 22,761 samples — not
the cause. Both-sides-applying: 5 overlap events all session.

### For WO-70

Stated in WO-70-facing terms, because **the fix is deliberately not landed
here** — see the scope note below:

1. **"Port the four ghost presentation pieces onto the puppet path"** —
   packet-velocity estimate, dead reckoning, direction-damped correction, and
   `lerpAngle` on yaw. Each has a live-verified ghost-side donor.
2. **"Copy the math; do not extract a shared helper."** The ghost block carries
   baked-in WO-38/WO-40 field fixes and is the live-verified one; sharing it
   risks a ghost regression for no gain.
3. **"Re-derive `spd` from the new velocity estimate in the same change."** It
   currently reads the pre-lerp residual; adding DR silently retunes every
   animation threshold otherwise.
4. **"Do not close the loop."** Derive velocity from the packet stream, never
   from a `GetWorldPos()` readback — that couples the interpolator to the
   unsuppressed brain and turns a yank-back into a feedback oscillator.
5. **"Do not port the floor raycast."** WO-63 excludes it, and `getFloorZ` is a
   `local function` declared *after* the puppet tick — a reference to it from
   there binds to a nil global and fails silently inside the surrounding
   `pcall`, stopping that tick's write with no error.
6. **Fix D3 first, and instrument.** Per-chain generation tokens on both the
   puppet and emit chains; a per-packet counter in `KCD2MP_ApplyNpcState`
   (none exists today); `p.fightN` rethresholded from 0.5625 to ~0.0025 and
   made to *log*. Until these exist, every cadence number except `emitMs = 250`
   is a proxy, and a DR layer tuned to a 50 ms tick would be tuned to a period
   that does not exist in the field.
7. **Run the D1-vs-D2 discriminator before tuning anything.**
   `tools/Test-NpcSyncE2E.ps1` Phase 3 already streams 32 packets at 4 Hz and
   reads engine positions back. Drive two NPCs, one with `AI.SetIgnorant(id,1)`
   and one without. If the suppressed one still steps, D1 is sufficient; if it
   goes smooth, D2 dominates and the interp port is the wrong lever.

### Why the fix is not landed in this work order

(read-but-unrendered) `docs/WO-63-findings.md:182-193` sets an explicit ordering
gate: **live-verify WO-60 before touching the puppet renderer**, because
smoothing landed first "would smooth over any remaining authority artifacts…
contaminating the very footage needed to judge WO-60". WO-60 is still
wire-verified only. WO-63 also predicted this exact field report in advance —
"walking/fighting puppets glide instead of dashing 4×/s, and turning puppets
stop head-yanking" — so the diagnosis is a confirmation of an existing plan, not
a new discovery, and the plan's own sequencing should not be broken by a hotfix.

### Not established

- (inconclusive) Actual inbound packet arrival times. No per-packet record
  exists in any log; every cadence figure except `emitMs = 250` is a proxy.
- (inconclusive) Receiver-side brain displacement magnitude — never measured.
- (inconclusive) Whether D3 reproduces off the field.
- (read-but-unrendered) **No footage of a walking puppet has ever been
  reviewed** — `docs/WO-63-findings.md:46-48` says so itself. Every jitter
  characterisation to date, this one included, is code plus an event-gated log
  proxy.

---

## Verification run this session

- (observed) 19/19 male roster souls resolved live over REST against a running
  build.
- (observed) Pak rebuilt clean; `Verify-Install`'s roster assertions
  re-checked against the new pak: 19 male entries, no bandit souls, female
  table gone, picker's `NPC_Female` branch gone, and **both world-NPC
  `cls == "NPC_Female"` filters still intact** (these match real female world
  NPCs for NPC-sync and body drag — removing them would silently drop half the
  world's NPCs from sync).
- (observed) Relay suites, all against a **freshly source-built** relay on 7778
  (the installed `%LocalAppData%` relay was running and was replaced — the
  WO-32 stale-relay trap): `Test-Sessions` 22/0, `Test-Combat` 14/0,
  `Test-Dice` 14/0, `Test-NpcClaimValidation` 23/0, `Test-TimeSkipRelay` 35/0,
  `Test-ItemSyncRelay` 11/0. **119 passed, 0 failed.**
- **`Test-Pipe` not run**: it requires the native DLL injected and a live game.
  The game process exited partway through this session, so the pipe did not
  exist. Nothing in this work order touches the native side.
### Live checks, run against a running 0.18.8 build

- (observed) **Lua 5.1 syntax: OK.** `loadfile` against the edited source,
  evaluated by the game's own interpreter, returned a function — and the pak
  build printed `[KCD2-MP] === MOD INIT ===`, which a parse failure would have
  prevented outright. This closes the one gap the earlier commits had to ship
  with (there is no `lua`/`luac` on this machine and the build gates only on
  BOM).
- (observed) **Picker is male-only: 15/15 name keys, non-male = 0.** Nine of
  the fifteen hash **even** — i.e. every one of them resolved to a female body
  before this change — and all fifteen now return `class=NPC`.
  `KCD2MP.faceRoster.female` reads `nil`, `#male` is 19, and
  `KCD2MP.faceFallback` resolves to `ttkc_man_3`.
- (observed) **Existing male players keep their exact faces.** All six
  odd-hash keys tested resolve to the same soul the old code gave them —
  `Host`→`ttac_man_9`, `Player0`→`tsla_man_2`, `Player2`→`ttac_man_8`,
  `Player4`→`ttac_man_9`, `Player11`→`tsem_man_22`, `Player91`→`tsem_man_21`.
  This was argued from `#list` already being 19; it is now measured.
- (observed) The engine's own hash matches the offline computation used
  throughout this document, key for key (`Henry`=7308, `Player1`=51656,
  `Player91`=1415, …) — so the arithmetic in the diagnosis above is the
  interpreter's, not a reimplementation that merely agrees.

- (observed) **Real spawns: 4/4 male, zero mismatches.** Three fresh spawns on
  previously-female keys (`Henry`, `Jonas`, `Player1` — all even-hash) plus one
  respawn, each logging
  `spawn verify … requested class=NPC soul=… | resolved class=NPC soul=nil`.
  No `SPAWN MISMATCH`, no fallback respawn, no loop.
- (observed) **`resolved soul=nil` is the nil-guard working, not a failure.**
  The soul is not reachable at spawn+0 — the same thing `ApplyName` has always
  logged as `before=nil`. The code treats that as *unknown*, so it did not
  fire a corrective respawn on three healthy ghosts. Had nil been treated as a
  mismatch, this run would have looped.
- (observed) **Independent world read agrees.** Querying the three live
  entities directly afterwards:
  `world 90 class=NPC`, `world 91 class=NPC`, `world 93 class=NPC` — read off
  the entities themselves, not echoed from the request. (Their `soul.name`
  reads back as the *nickname*, because `ApplyName` overwrites it; that is why
  the verify samples it before ApplyName and treats it as a probe only, never
  as the gender check.)
- Test ghosts removed afterwards; `GhostAudit registered=0 live=0`.

**Still not observed:**

- The **save-load rebuild** spawn path. Three of the field bundle's four
  spawns came from exactly this path, so it is the most field-relevant one
  left. It needs a ghost alive across a save load.
- The **`SPAWN MISMATCH` / fallback branch**, which has still never executed —
  there is no known way to make a roster soul fail to resolve on demand, so it
  remains unexercised code.
- The **WO-69 NPC-sync instrumentation** (chain-leak line, packet cadence,
  `NPC-FIGHT`). None of it fired: puppets only exist when receiving a peer's
  stream, and this was a single machine with no peer. Shipped but unexercised
  — it needs a real two-player session, which is also the only place the D3
  question can be settled.
- The **WO-68 witness A/B**, which requires committing a theft in-game with
  only a ghost watching.
