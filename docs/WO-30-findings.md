# WO-30 — transport speed + code cleanup

Investigated 2026-08-08, live against KCD2 (Modding Tools build) for Phase 1,
desk audit for Phase 2, code-only for Phase 3.

**Bottom line up front:** RC works on Modding Tools exactly like it does on
retail — but on Modding Tools, unlike retail, it isn't a net win. The
reflection debug API (`:1403`) it would sit alongside is *already* live, and
RC has no path to most of what that API does. Migration is **not
recommended**, and nothing was migrated. Phase 2 found nothing better than
the existing poll. Phase 3's cleanup landed: six duplicate scripts collapsed
into one, three stale/misleading comments in `kdcmp.lua` fixed, and the
native aggro-attach path confirmed still fully load-bearing, from source, not
guesswork.

---

## Phase 1 — does the RC transport also work on Modding Tools?

**Yes, and it reaches further than it did on retail — but the reflection API
it would replace is already available here, which retail never had.**

### Port and protocol

With the game up via Modding Tools (`localhost:1403` answering), enabling
RemoteConsole through the existing debug API —

```
GET /api/System/Console/ExecuteString?command=log_EnableRemoteConsole%201
```

— opened `0.0.0.0:4600` immediately, same as retail's `-devmode` default.
Same wire format (`<ascii-digit type><payload><0x00>`, `'1'` banner,
`'5'` outbound console command), banner received, `#`-prefixed Lua executes
and reaches `kcd.log`. Verified with a live save loaded (not just the main
menu, which is all WO-18 could test on retail):

```
[WO30-RC-CHECK] KCD2MP=true ghosts=true player=true
```

RC reaches the exact same live `KCD2MP` mod table, `ghosts`, and `player`
that the current debug-API transport does — stronger evidence than WO-18 had,
since that test never had a save loaded.

### Latency, measured directly (not extrapolated from retail)

Same method WO-18 used: send, poll `kcd.log` for a unique tagged line,
measure elapsed time. Both channels measured with the *identical* detection
loop for a fair comparison (`tools` note: this polling overhead — `Get-Content
-Tail 30` on every 5ms tick — inflates both readings equally above the
project's own tighter production benchmark in `docs/WO-1-transport.md`, so
treat the two numbers below as comparable *to each other*, not as new
absolute production numbers).

```
RC (:4600), n=10, one persistent connection:
  min=51.9ms  p50=98.4ms  max=156.2ms  avg=101.6ms

HTTP debug API (:1403 ExecuteString), n=10:
  min=57.3ms  p50=130.4ms  max=2248.7ms  avg=328.3ms
  (max is the first call; calls 2-10 alone: 57-167ms, avg ~114ms)
```

Warm-to-warm, RC and the debug API are the same order of magnitude — RC is
not meaningfully faster once both are warm.

**Cold-start: confirmed real for HTTP, confirmed absent for RC**, both
directly measured here (not assumed from retail):

- HTTP debug API: first `ExecuteString` call after the game/API had already
  been idle-but-reachable cost **2248.7ms**, matching WO-1's own
  ~2.15s finding almost exactly. This recurred on a session where `:1403`
  had already answered other requests minutes earlier — the penalty is
  per-connection or per-endpoint-idle, not strictly "first call ever."
- RC: three separate fresh TCP connections, first send after each: **118.4ms,
  57.1ms, 77.4ms** — no cold-start penalty, same range as warm. Matches
  WO-18's retail finding exactly.

### The scope-critical finding: RC cannot replace most of what `:1403` does

Read `HttpGameTransport.cs` to find every current use of the debug API. Only
**one** endpoint is Lua execution:

```
/api/System/Console/ExecuteString    <- the only RC-replaceable call
```

Everything else is a direct RTTR reflection method invocation over HTTP, with
**no RC equivalent** — RC only reaches the Lua VM, never the reflection
method browser:

```
/api/rpg/Calendar
/api/rpg/SoulList/PlayerSoul
/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedArmorsByClassId   <- appearance sync read
/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedWeaponsByClassId
/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/EquipItem        <- appearance sync write
/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/UnequipItem
/api/rpg/SoulList/SoulsByName/{soul}/Inventory/CreateItems
/api/System/Console/GetCvarValue
```

WO-9 already established *why* appearance sync uses this and not Lua: the
Lua clothing bindings (`EquipInventoryItem` etc.) are stubs that don't
render; only the native reflection layer's `EquipmentManager` actually works.
That fact doesn't change here — RC cannot read or write equipped items at
all, in principle, not just in this session's testing.

Combat/health/death sync is unaffected either way: it goes through the
native pipe (`\\.\pipe\kcdmp` → `KCDMP.dll`) directly, never through `:1403`
or RC.

### Why retail's case doesn't transfer

On retail, RC was valuable because it was the *only* way to reach Lua at
all — `:1403`'s reflection API doesn't exist there (WO-18 P0a). On Modding
Tools, the reflection API is already present and already serves appearance
sync, which RC categorically cannot replace. The one thing RC *could* take
over here — the batched `ExecuteString` calls that push ghost
position/state, dice moves, and aggro/`DrawWeapon` triggers into Lua — shows
no material warm-latency win in direct measurement, and the cold-start
penalty it would avoid is a per-idle-connection cost the production code
already amortizes by keeping the channel busy rather than by making sporadic
first-calls.

### Gate 1 — stated plainly

**Not recommending migration.** The gap that made RC valuable on retail
(the only Lua channel available) does not exist on Modding Tools (the
reflection API is already there and irreplaceable for appearance sync). If
migration were pursued anyway, scope would be: replace only the one
`ExecuteString` call site in `HttpGameTransport.cs`/`LogTailGameTransport`
with an RC-backed sender; leave every reflection GET/RPC call, the log-tail
outbound path, and the native combat pipe completely untouched. That is a
narrow, contained change — but the measured benefit (no cold-start penalty on
an already-warm, already-batched channel) doesn't clear the bar to justify
touching a load-bearing transport. **Not built. Available if wanted, on this
evidence, not recommended.**

---

## Phase 2 — appearance/armor sync detection

**Confirmed: nothing better than the current poll exists in the docs
available this session.**

Checked the cached `muyuanjin/kcd2-mod-docs` scriptbind HTML set (a copy
survived from a prior session's scratchpad; a fresh clone attempt from GitHub
timed out — network access was unreliable this session, noted rather than
retried repeatedly) for any equip-change listener/callback/event surface.
Grepped every file for `listener`, `callback`, `OnEquip`, `ItemEquip`,
`EquipEvent`. Hits are all unrelated (audio listeners, UI action/element
listeners, `ItemManager.AddOnEquipBuff` — a buff-on-equip trigger, not a
general change-detection hook). Nothing equip-change-shaped.

This matches WO-9's own original finding verbatim ("No existing event hook
fires on equip/unequip ... nothing reflected on `EquipmentManager` besides
the two properties and the mutator methods") and WO-23's independent
re-audit, which touched `EquipmentManager` and the gender-mapping question
but did not surface a hook either.

**One gap, stated honestly:** the fuller Skald schema (`d_definitions.xml`,
used by WO-23 for other reflection-node checks) was not re-checked this
session — the clone that would provide it wasn't reachable. WO-23 already
checked `EquipmentManager` against that schema for a *different* question
(the `EquipItem`/`EquippedWeaponsByClassId` shape) and found nothing beyond
what's already used; nothing in that prior check hinted at an event port
either. Treat the schema specifically as **unconfirmed this session**, not
newly disproved — the scriptbind HTML check plus two independent prior
findings (WO-9, WO-23) is strong enough to leave the polling design in place
without re-deriving it a third time.

### Gate 2 — confirmed nothing better exists than the current polling approach.

---

## Phase 3 — code cleanup

### 3a — consolidated the `woNN-lua.ps1` family

`tools/wo21-lua.ps1`, `wo22-lua.ps1`, `wo24-lua.ps1`, `wo25-lua.ps1`,
`wo26-lua.ps1`, `wo27-lua.ps1` were byte-for-byte identical except for a
hardcoded `[WONN]` tag string. Checked for references before touching
anything: only historical mentions in `docs/WO-2{1,2,4,5,6,7}-*.md` ("new
tooling" lists describing what each WO created) — no script sources or
dot-includes any of them. Safe to remove.

Replaced with `tools/Lua-Driver.ps1`, one parameterized driver:

```powershell
. tools\Lua-Driver.ps1 -Tag WO30 ; Lua 'W("hi")' ; Show
```

Same four functions (`Lua`, `Show`, `Reset-Seen`, `Api`) plus the `Init-W`
helper the later scripts (24-27) had converged on independently. The six
originals were deleted (`git rm`), not archived — nothing in the repo
executes them, and the historical doc mentions describe what a session did,
not a live dependency.

**Not touched:** `tools/Wo21-Watch.ps1`, `Wo22-Watch.ps1`, `Wo26-Watch.ps1`.
These looked like the same family but aren't pure duplicates on inspection —
each genuinely adds fields the prior one didn't have (WO-22 adds a movement
delta over WO-21; WO-26 adds AI engagement state and the player's own health
over WO-22). Consolidating those would mean building one watcher flexible
enough for the union of all three shapes, which is a real design task, not a
duplicate-deletion — out of scope for a cleanup pass and not requested by the
brief, which named the `woNN-lua.ps1` family specifically.

### 3b — stale comments in `kdcmp.lua`

Fixed the flagged one and two more found by the same read-through.

1. **The `DrawWeapon` comment** (WO-23 item 1, left unfixed there as
   cosmetic/out-of-scope). It claimed the call "does NOT flip
   `CombatSoul.HasMeleeWeapon`" — disproved by WO-21 (flips true on a male
   ghost with a real weapon item) and confirmed still true for soul-backed
   ghosts by WO-22/23. Rewrote to state the current, correct picture:
   `HasMeleeWeapon` does flip, a female ghost (no weapon item) correctly
   stays `false`, and landing a blow is a separate emergent AI decision this
   call doesn't control.
2. **The `esModularBehaviorTree` removal comment**, next to the WO-22 spawn
   change, claimed "Aggro still works — it comes from the native faction
   attach, as it always actually did." That predates WO-26, which found
   reactive combat (self-defense, joining fights) is unconditional and comes
   from the engine's own AI/soul/brain system once a soul is bound — nothing
   to do with the faction attach. Rewrote to attribute reactive combat to the
   soul binding and the faction attach to the toggle specifically, per WO-27.
3. **The `mp_enable_aggro` doc comment**, above `KCD2MP_EnableAggro`, claimed
   the toggle "affects every ghost spawned AFTER the toggle flips" and that
   an already-spawned ghost needs a respawn/reconnect to pick up a change.
   Checked against `GameBridge.cs`: `_aggroEnabled` is a single flag checked
   live inside `TriggerReactiveAggroAsync` at **hit-time**, for every ghost,
   with no per-ghost state baked in at spawn — confirmed by reading the field
   usage directly (`GameBridge.cs:1698,1535`), not by re-deriving WO-27.
   Flipping the toggle takes effect on the next hit for every ghost already
   in the world. Rewrote to say so, and folded in WO-27's precise
   characterization of what the toggle actually adds.

Scanned the rest of the file (every `--` comment referencing a WO number or
words like "never"/"does NOT"/"inert") for other drift; nothing else turned
up a contradiction against current findings docs.

**Found but explicitly not touched, out of this phase's stated scope**
(kdcmp.lua only): `dotnet/KcdMp.Client/CombatPipe.cs:118-123`'s doc comment
on `SetFactionHostileAsync` still says "a locally-spawned ghost proxy carries
SharedSoulGuid=0" — true before WO-22, not true after (soul-backed ghosts
carry a real, non-zero `SharedSoulGuid`). Doesn't affect correctness (the
code always used the ghost's own `Soul.Guid`, which is unaffected either
way), just a stale example in the comment. Flagged here for a future pass
rather than fixed, since Phase 3b's brief named `kdcmp.lua` specifically and
this is a different file/language.

### 3c — is the native `SetParent`+donor-soul attach path still load-bearing?

**Yes — fully. Confirmed from the current source, not inferred.**

Traced the live call path: `mp_enable_aggro on` → Lua emits `aggro_toggle` →
`GameBridge.cs:1535` sets `_aggroEnabled` → next hit (`OnLocalHit` or
inbound `DamageDown`) calls `TriggerReactiveAggroAsync` →
`CombatPipe.SetFactionHostileAsync` → the DLL's `SetFactionHostile` command →
`set_ghost_faction_hostile()` in `native/KCDMP/rttr_abi.cpp:1416-1512`.

That function **is** the donor-soul path, unchanged since it was written:

```cpp
constexpr const char* kDonorGuidText = "4fc4eb57-9f12-4b65-8acc-ed9fb3f8730a";
// "prepadeni_bandit_1, a despawned-but-still-in-SoulList leftover from this
//  playthrough's ambush sequence"
```

On attach, it looks up this exact hardcoded soul GUID, reads its live
`FactionNode.Parent` (the hostile bandit faction), and `SetParent`s that onto
the ghost's own `FactionNode` — the same mechanism, same donor, same faction
(`trosecko_enemies_bandits_prepadeniAmbushers_group1`) that WO-27's live A/B
test exercised and confirmed still fires correctly against post-WO-22
soul-backed ghosts. `git log` on `GameBridge.cs` shows no commits between
WO-27 and now except WO-28 (shared player combat, unrelated file regions) —
the mechanism WO-27 verified live is still exactly what runs today; this
session traced it in the current source rather than re-running the same live
test.

**Not vestigial. This is the entire mechanism behind the toggle's effect.**
It is exactly as fragile as `README.md` already says: `find_soul_by_guid`
returns null and the attach fails quietly (logged, not crashed) on any save
that hasn't reached the point where `prepadeni_bandit_1` entered the
`SoulList` — a specific playthrough dependency, hardcoded, not general.

WO-23 item 3's flagged alternative — binding a hostile `factionName` directly
via `SharedSoulGuid` at spawn, no donor, no native attach — remains a
**promising, partially-validated, still-untested-in-its-exact-shippable-form**
lead (WO-22's own evidence shows the mechanism's ingredients work
individually; the specific combination WO-23 named was never run). Not
chased further here — Phase 3c's question was whether the *current* mechanism
is still in use, not whether a better one exists, and the answer to the
former is unambiguous. Left open, correctly, for whoever picks up WO-23's
lead.

---

## What this session does not resolve

- RC-on-Modding-Tools latency numbers above use a uniform tag-poll
  measurement method for fair RC/HTTP comparison; they are **not** a
  replacement for `docs/WO-1-transport.md`'s tighter, production-code
  benchmark (`--benchmark`), which remains the authoritative number for the
  current transport's actual round-trip cost.
- The Skald schema (`d_definitions.xml`) was not re-checked for Phase 2 —
  network access to re-clone `kcd2-mod-docs` was unavailable this session.
  Treat Phase 2 as settled by three independent findings (WO-9, WO-23, this
  session's scriptbind-HTML check), not as exhaustively re-verified against
  every source WO-23 had access to.
- WO-23 item 3's soul-only hostile-faction lead (no donor, no native attach)
  remains untested in its exact shippable form.
- `CombatPipe.cs`'s stale `SharedSoulGuid=0` comment (found during 3b, out
  of that phase's stated scope) is unfixed.

## Files touched

- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — three comment fixes (3b), no
  logic change
- `tools/Lua-Driver.ps1` (new) — consolidates the six `woNN-lua.ps1` drivers
- `tools/wo21-lua.ps1`, `wo22-lua.ps1`, `wo24-lua.ps1`, `wo25-lua.ps1`,
  `wo26-lua.ps1`, `wo27-lua.ps1` — deleted, superseded
- `docs/WO-30-findings.md` (this file)
- `docs/WO-30-progress.md`

## Regression

`dotnet test dotnet\KcdMp.Farkle.Tests\KcdMp.Farkle.Tests.csproj`: **59/59
passed**, 28ms. No C# code was changed this session; run as the project's
standing check per convention.

No `VERSION`/release action taken, per `docs/VERSIONING.md`.
