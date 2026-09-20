# WO-105 — contradictions

Every place the CRYENGINE source disagrees with, or materially refines, a claim
this repository asserts. Companion to `docs/WO-105-cryengine-reference.md`.

Source: `CRYTEK/CRYENGINE_Source`, branch `release`, commit
`cd017c4f782aaa03806dc73370ea91ad86147a72` (tag `5.7.1`, 2022-05-13).

**The standing caveat applies to every entry.** KCD2 runs a Warhorse fork.
"The source says X" means *CRYENGINE 5.7.1 is built this way*. Each entry
states separately how likely that is to hold on the KCD2 build, and what would
settle it. **Nothing here has been tested against a running game.** These are
corrections to *reasoning*, and every one of them is a hypothesis until
something in the field says otherwise. That is the trap this WO exists to help
avoid, not an exemption from it.

Entries are ordered by value, highest first.

---

## 1. The console does not refuse arguments. The placeholder is lowercase.

**Confidence: high.** The engine reproduces both observed symptoms exactly,
from one cause, and the observed warning text is verbatim the engine's.

### What we believed

`memory/kcd2mp-console-drops-arguments.md`, marked LIVE-VERIFIED 2026-09-13:

> the KCD2 console refuses arguments to Lua-registered `mp_*` commands ("Too
> many arguments for:") and passes the literal `%LINE` when none is given;
> every `on|off|<n>` toggle since WO-17 only works as `#Lua`
>
> **How to apply:** register toggles as ARGLESS commands […] treat `%LINE` as
> "no argument"

### What the source says

`System.AddCCommand(name, template, help)` registers a **script** console
command: the template is a Lua string with **placeholders**, substituted at
execution time. (code-verified) Three placeholder forms exist:

| form | meaning |
|---|---|
| `%1`, `%2`, … `%N` | the Nth argument, quoted |
| `%%` | every argument as a comma-separated quoted list |
| `%line` | everything after the first space, as one quoted string |

The substitution loop walks `i = 1 .. argc` looking for `%i` in the template.
If `%i` is **not** present and `i` is not the last index, it emits
**"Too many arguments for: \<name\>"** and **returns without running anything**.
(code-verified)

The `%line` lookup is a plain substring search, and CryString's find is
`strstr` — **case-sensitive**. (code-verified, both)

### Why that produces exactly what was observed

The mod writes `"%LINE"` — uppercase.

* `mp_x 35` → argc is 2. `%%` not found. **`%line` not found, because the
  template says `%LINE`.** Falls into the numbered loop: i=1, `%1` not present,
  i ≠ 2 → **"Too many arguments for: mp_x"**, nothing runs.
* `mp_x` bare → argc is 1. Same misses. i=1, `%1` not present, i == 1 == argc →
  no warning, and the template runs **unsubstituted**, so Lua receives the
  literal string `%LINE`.

Both halves of the field observation, from one cause. The observation was
right; the conclusion drawn from it was wrong.

There is also a second, entirely separate registration route —
`AddCommand(name, nativeFunc, …)` — which hands the callback an argument object
and has no such restriction. (code-verified) It is not reachable from Lua.

### Which finding to correct

* `memory/kcd2mp-console-drops-arguments.md` — the premise, and the "how to
  apply" advice. The console does not refuse arguments; the mod asked for a
  placeholder that does not exist.
* `docs/WO-94-findings.md` §9's open follow-up ("re-registering the older
  commands").
* Every argless `*_on` / `*_off` command pair shipped since WO-17 as a
  workaround for this.

### How confident, and what would settle it

High. The warning string is the engine's own, verbatim, so the KCD2 build is
running this code path. The remaining risk is that Warhorse edited the
substitution logic. **One console line settles it**: register a command with
`%line` (lowercase) or `%1`, then type it with an argument.

If it holds, every documented field rollback toggle works as typed, for the
cost of a case change.

---

## 2. `Hide()` is not inconclusive. It suspends physics, AI, updates and triggers.

**Confidence: high for the engine; medium for the fork.**

### What we believed

`docs/WO-104-findings.md` §3.5:

> **Whether `Hide(1)` stops the hidden NPC's physics** on this build is
> (inconclusive) — CryEngine convention says yes. If not, the player could bump
> an invisible body standing where the fight began.

and the associated save hazard, marked "inferred […] inconclusive for `Hide`".

### What the source says

(code-verified, all of the following — full detail in the reference §17.2)

* **Physics: suspended, not ignored.** `Hide` disables physics, which destroys
  the physical entity in *suspend* mode: detached from the broadphase grid
  thunks, unlinked from the typed entity lists, simulation class stashed and
  replaced with a hidden sentinel, moved onto a hidden list. Character physics
  on every character slot is suspended alongside it.
  **A suspended entity is out of the broadphase: no collision, no ray-cast hit,
  no overlap result.** The invisible-body worry is unfounded.
* **Proximity and areas: removed, not skipped.** The relocation path takes its
  else-branch: the partition-grid location is freed and the proximity-trigger
  entity is destroyed outright (unless the entity is the local player).
* **AI: off, unconditionally.** The game object's AI-update predicate returns
  false the moment the entity is hidden, before it consults visibility, range or
  the AI activation mode. Pre-physics updates under the when-AI-activated rule
  stop with it.
  **`ENTITY_FLAG_UPDATE_HIDDEN` does not rescue this** — it changes only the
  visibility answer, in a branch the hidden gate never reaches.
* **Game object: not necessarily inactive.** Activation is the union of the AI
  answer, any extension update slot that should run, and a force-update count.
  An extension with an always-on slot keeps a hidden entity ticking.
* **Lua updates: stopped**, by the script component dropping the update event
  from its mask — unless `ENTITY_FLAG_UPDATE_HIDDEN` is set, which *is* the
  escape hatch for this one.
* **Children: recursive.** Hide propagates to every child with a parent-hide
  marker.
* **Persistence: confirmed, not inferred.** The save writes each entity's
  hidden flag as basic entity data and the load restores it. The save hazard
  WO-104 identified is real and is now code-verified.

Also worth having: **`Invisible()` is a separate, weaker flag** — same physics
suspension and render update, but **no grid or proximity removal**. If the goal
is ever "stop drawing it but keep it in the world", that is the tool.

### Which finding to correct

`docs/WO-104-findings.md` §3.5 — three of its four bullets. The physics
uncertainty resolves to *yes, fully*; the save persistence resolves from
inferred to verified.

### How confident, and what would settle it

High for CRYENGINE. `CEntity` is deep structural code that a fork is unlikely
to have rewritten, but "unlikely" is not evidence. A single probe settles the
physics half: hide an NPC, then walk the player through where it stood.

---

## 3. `soul:GetId()` and `SharedSoulGuid` are probably different identity spaces.

**Confidence: medium-high on the width mismatch; medium on the consequence.**

### What we believed

`docs/WO-104-findings.md` §3.3:

> `soul:GetId()` — "Returns unique and persistent id of this soul (WUID)"
> (Warhorse scriptbind reference). **The roster guids are WUIDs of the same
> form (code-verified).**

and the replica gate, which requires `tostring(e.soul:GetId())` to match a
dashed five-group pattern, and which has refused **34/34**.

### What the source and this repo's own data say

* A **`CryGUID` is 128 bits** — two 64-bit halves — and its string form is the
  dashed 8-4-4-4-12 shape. (code-verified)
* The mod's roster soul guids are full 128-bit CryGUIDs with every group
  populated, e.g. the fallback face's `cfa65480-f361-4cf8-80c5-1900b7846bc8`.
  (read from this repo's `kdcmp.lua`)
* A **WUID is 64 bits**. This repo's own field capture:
  `wuid=0x05000000000005DD` (`docs/WO-68-findings.md`) — sixteen hex digits.

**They are not "the same form". They are different widths and, on that
evidence, different identity spaces.** A 64-bit soul WUID is not a 128-bit
soul CryGUID, and there is no reason to expect one to bind where the other is
asked for.

### Why 34/34 proves less than it looks

From the source, a scriptbind return value can `tostring` to exactly four
things, and only one of them could ever match a dashed pattern:
(code-verified — reference §3.3, §17.4)

| bind returns | Lua type | `tostring` gives | matches the gate? |
|---|---|---|---|
| a number | number | a numeral; for a 64-bit value, `%g` exponent form — **and already destroyed**, because every number crossing the bind boundary is a **float** (entry 5) | no |
| a `ScriptHandle` | light userdata | a `userdata: <hex>` form | no |
| a string | string | the string | only if it is already dashed |
| a table | table | a `table: <hex>` form | no |

So **the 34/34 refusals are fully explained by the validator's shape assumption
and say nothing about whether the soul id is readable.** The gate refuses
before the question is asked.

### The lead, stated as a lead

`CryGUID::FromString` accepts **three** inputs: braced, dashed, **and a bare hex
string of at most 16 hex digits**, loaded into the high half with the low half
zero — the "old 64-bit GUID system" path. `FindEntityByGuid` has the matching
lookup. (code-verified)

So a 64-bit WUID in hex **is** a syntactically valid CryGUID input on stock.
Whether Warhorse's `SharedSoulGuid` handler routes through that parser is
**(inferred)**, and whether a soul WUID means anything in the soul-GUID space
is **(inconclusive)**.

### Which finding to correct

`docs/WO-104-findings.md` §3.3 — the "same form (code-verified)" claim, and the
framing of the gap. The real gap is not "does `GetId()` return a WUID or a
per-save instance id"; it is **"is a soul WUID the same thing as a soul
CryGUID at all"**, and the widths say probably not.

### What would settle it, in order

1. Run the probe that is **already written** in `kdcmp.lua` (the
   `player.soul:GetId()` logging line) against a **world NPC**, and record
   `type()` and `tostring()`. This has never been done for a world NPC.
2. If it is a **number** — the WUID is already float-destroyed (entry 5) and
   that route is dead; look for a bind that returns the soul's CryGUID as a
   string.
3. If it is **userdata or hex** — extract the hex (the mod's own `entity.id`
   handling already does exactly this) and try the **bare hex string**, undashed,
   as `SharedSoulGuid`. Fail-closed as today: refuse if the spawn comes back
   soulless.

---

## 4. There is a lever for keeping spawned bodies out of the player's save.

**Confidence: high for the engine; medium for the fork.**

### What we believed

`docs/WO-104-findings.md` §3.5:

> a save written mid-promotion persists a hidden NPC and a `kcd2mp_r_` body.
> **No pre-save hook exists.** The 5 s sweep cleans it the next time the
> NPC-sync tick runs in a connected session; a solo load without connecting
> shows a brainless duplicate until then.

### What the source says

(code-verified)

* The save walks every entity and writes a record for each one **that is not
  flagged `ENTITY_FLAG_NO_SAVE`**. That flag is the engine's own answer to
  "do not persist this".
* **`ENTITY_FLAG_NO_SAVE` is registered as a Lua global**, and
  `entity:SetFlags(flags, mode)` is a scriptbind. Mode semantics: 1 = AND,
  2 = AND-NOT (clear), anything else = OR (set). So setting it from Lua is a
  one-liner on stock.
* The engine itself sets this flag alongside no-proximity and client-only when
  a script marks a slot as 3D HUD — i.e. for a body that must never be
  persisted or trigger anything. Same intent, same combination.
* On load, every entity that is not the local player and not flagged
  unremovable is destroyed before the save is applied — so a flagged entity
  simply never exists again, which is the desired outcome for a replica.

It is not a *pre-save hook*. It is better: it removes the need for one.

### Which finding to correct

`docs/WO-104-findings.md` §3.5 — "No pre-save hook exists" is true and
misleading. The conclusion it supports (that only a periodic sweep is
available) does not follow.

Applies to the same problem in its other forms: ghosts, dropped-item proxies,
and any future mod-spawned body.

### How confident, and what would settle it

High for CRYENGINE, and this is a broadly-used engine flag rather than an
obscure corner. Unknown whether the KCD2 build registers the global —
**one console line settles it**: print the global and check it is a number.

Caveat worth keeping: the flag stops the *replica* being saved. It does **not**
stop the *hidden original* being saved as hidden (entry 2). Both halves of
WO-104's hazard need addressing, and only one of them has a flag.

---

## 5. The number audit is complete for formatting and silent on the float bridge under it.

**Confidence: high.**

### What we believed

`docs/WO-104-findings.md` §1.3, the audit table, concluding:

> Direction that is exposed: **Lua → agent only**, and only fields the agent
> parses as integers. Agent → Lua is not exposed: numbers are interpolated as
> C# invariant integers or `F3/F4` floats, and Lua's lexer accepts an exponent
> anyway. Native pipe and relay are binary.

Two fields found exposed, both fixed.

### What the source says

That audit covers **string formatting**. Underneath it sits a second, entirely
independent precision ceiling that it does not mention. (code-verified)

**Every scalar crossing the Lua↔C++ scriptbind boundary through
`ScriptAnyValue` is a 32-bit `float`:**

* the stored number type is `float`; the setter takes a `float`; the getter
  returns a `float`;
* the constructors from `int` and `unsigned int` both cast to `float`;
* Lua→C++ reads the Lua `double` and casts it to `float`;
* C++→Lua pushes the `float`;
* the `int` and `unsigned int` extractors cast the stored `float` back.

**Integers are therefore exact only to 2^24 = 16,777,216** across any
scriptbind, in either direction, regardless of how anything is formatted.

The engine documents its own escape: `ScriptHandle`, a pointer-width integer
union pushed as **light userdata**, exists precisely because Lua has no
integers and full-range values must travel that way. (code-verified) That is
why `entity.id` is userdata and why `tostring` on it yields a hex form — a
fact this project discovered empirically and worked around without knowing why.

### Why this matters beyond the audit

* **World time in milliseconds breaks at ~4.6 hours** through any bind.
  In seconds it is safe to ~194 world-days. WO-104 hit a formatting ceiling at
  1e6 seconds; there is a second, lower, unrelated one waiting on any ms-based
  field.
* **A 64-bit identifier cannot survive the number path at all** — relevant
  directly to entry 3.
* Money in decagroschen, sequence numbers and frame counters all cap at 16.7 M.
* This is invisible: no warning, no exception, no exponent in the output. The
  value is just wrong.

### Which finding to correct

`docs/WO-104-findings.md` §1.3 — scope it explicitly to string formatting, and
add the float bridge as a second axis. The table's "exposed?" column answers a
narrower question than its heading implies.

### How confident, and what would settle it

High. `ScriptAnyValue` is core Lua-bridge code. **One line settles it on the
KCD2 build**: pass a value above 2^24 into any bind that echoes a number back
and compare.

---

## 6. The case for going native is reach, not speed.

**Confidence: high on the mechanism; the conclusion is an argument, not a fact.**

### What we believed

Stated or implied across the native-migration work: that moving hot paths out
of Lua buys performance, and that the per-call cost of a scriptbind is the
thing being escaped. `docs/WO-102.5-findings.md` §6.2 and
`docs/WO-103-findings.md` weigh a main-thread-blocking walk against "a freshness
win". The per-call cost itself is named in the WO-105 brief as *"the number the
entire Lua→native migration argument rests on, never measured."*

### What the source says

The fixed dispatch path is: a Lua C-function dispatch, one upvalue pointer
read, a **stack-allocated** four-field handler with a trivial constructor, and
one indirect call. **No heap allocation, no lock, no global state, no
marshalling unless a parameter is actually read.** (code-verified)

The bridge is thin. The per-call overhead is not where the time goes.

Where it does go, in the order that matters at this project's scale:

1. **Table allocation in the vector getters.** Binds returning a `Vec3` use a
   shared helper that **reuses a table passed as a parameter**, and allocates a
   fresh Lua table only when the caller passes nothing. (code-verified)
   In `kdcmp/Data/Scripts/Startup/kdcmp.lua` today: **84 no-argument
   `GetWorldPos()` call sites and 0 using the reusable-table form**, plus 13
   no-argument `GetWorldAngles()`. Every one allocates a Lua table per call, and
   the script system runs **one incremental GC step every frame** (code-verified),
   so that churn converts directly into per-frame work.
2. **Re-executing strings.** `ExecuteBuffer` compiles each time; `CompileBuffer`
   plus a call on the returned handle compiles once. (code-verified)
3. **Whatever the bind body does**, which for entity lookups, sphere queries and
   spawns dominates everything above.

### The reach argument, which is the real one

Four of the transform-write suppression levers are **native-only** — no Lua
bind passes transform flags at all (reference §17.1):

* `ENTITY_XFORM_IGNORE_PHYSICS` — skip the physics half of a write entirely
* `ENTITY_XFORM_NO_EVENT` — skip the event, render and physics notifications
* `ENTITY_XFORM_NOT_REREGISTER` — skip 3D engine re-registration
* `bRecalcBounds` bit 32 — **a position change that does not release a living
  entity's ground collider** (entry 7)

That last one is, on this reading, the single most valuable native-only lever
this reference surfaced.

### Which finding to correct

No single document states the wrong thing outright — this is a framing
correction across the native-migration work. The brief asked what a scriptbind
call costs; the answer is *"little, and that was never the reason."*

### How confident

High on the mechanism. The conclusion is an argument about priorities, and the
maintainer's call. The table-allocation figure is a count of call sites, not a
measurement of their cost.

---

## 7. The ground-collider release is the mechanism behind puppets phasing.

**Confidence: high on the mechanism; medium that it is the cause in KCD2.**

This is a *completion* of an existing finding rather than a reversal, but the
mechanism inverts what the symptom predicts, so it is listed here.

### What we believed

`docs/WO-102-findings.md` §1.2, from decompilation:

> `SetWorldPos` writes the same matrix through `CEntity::SetWorldTM` — so this
> IS the entity's transform, not a cache

True, and incomplete. The brief names the suspected mechanism as "physics
re-registration, area triggers, movement-controller notification, animation
arbitration".

### What the source says

All four of those happen (reference §17.1). One more does, and it is the one
that explains the symptom: (code-verified)

When a **living entity** — every humanoid — receives a position parameter
change **without `bRecalcBounds` bit 32**, and the move exceeds **about 1% of
the capsule's z-size**, the engine **releases the ground collider, raises the
flying flag, and zeroes the velocity**.

`pe_params_pos` defaults `bRecalcBounds` to 1, bit 32 clear. The entity system
constructs it with that default and never sets bit 32. Bit 32 is the engine's
own "this is a teleport, skip the real-move response" flag — the living entity
sets 16|32 on its *own* repositioning, vehicles use 16|32|64, and the rigid-body
path gates its real-move handling on the same bit.

### Why this matters more than it sounds

The consequence is not "the NPC gets nudged". It is:

* every write puts the capsule into the airborne state with **no ground
  contact** and **zero velocity**;
* ground contact is re-acquired only during the living entity's own simulation,
  by falling onto something;
* at 20 Hz the next write lands before that converges and re-releases it;
* so the capsule is **permanently airborne**, its vertical position is governed
  entirely by what the stream says, and vertical error **accumulates instead of
  being corrected by the floor**.

**The symptom therefore scales with write frequency, not with write magnitude**
— which is the opposite of what "the positions are slightly wrong" predicts,
and matches what the field actually showed.

### Which finding to correct

Add the mechanism to `docs/WO-102-findings.md` §1.2's table and to the puppet
work in WO-63 / WO-75 / WO-78. It reframes the interpolation work: smoothing
the *values* does not address a state machine that is being reset on every
write. Writing **less often** would, which is the opposite of the direction
that work has been taking.

### How confident, and what would settle it

High that CRYENGINE does this. Medium that it is the cause in KCD2 — Warhorse
could have changed the living-entity step, and KCD2 humanoids may not even be
`PE_LIVING`. **A cheap field test exists**: halve the puppet write rate on one
NPC and see whether sinking gets better rather than worse. If it does, the
mechanism is live.

---

## 8. `Script.SetTimer` chains die by design, and there may be a timer that does not.

**Confidence: high on the mechanism; the alternative is unprobed.**

### What we believed

`memory/kcd2mp-lua-timer-liveness.md` and `memory/kcd2mp-save-reload-behaviour.md`:

> a save load kills every `Script.SetTimer` chain while `*Running` flags stay
> true; check a heartbeat, not the flag

and `memory/kcd2mp-wo78-state.md`:

> chain leak ROOT-CAUSED: suspended != dead

**Both are correct.** The source explains them and adds something.

### What the source says

(code-verified — reference §12.2)

* `CScriptTimerMgr::Serialize`, **saving**, skips every timer that holds a
  **function reference**. Only timers registered by **global function name** are
  written, and only when their user data is absent or an entity table.
* **Loading resets the manager first** — destroying every live timer — then
  re-adds only what was saved.
* So a `Script.SetTimer(ms, function() … end)` chain is neither saved nor
  survives the reset. It cannot come back. Lua globals are untouched, which is
  exactly why the `*Running` flags stay true.
* A second bind exists: **`Script.SetTimerForFunction(ms, "globalName", …)`**,
  which stores the name and **is** saved and restored.
* The pause flag skips rather than destroys — "suspended != dead" is precisely
  right — but **nothing in stock CRYENGINE ever calls the script timer
  manager's pause**. The always-called `PauseTimers` is the *entity* timer
  system, a different mechanism. If KCD2 suspends Lua chains during menus, a
  fork-added caller is doing it.

### Which finding to correct

Nothing to reverse. Two things to add:

* **`memory/kcd2mp-lua-timer-liveness.md`** — the mechanism (not saved, then
  reset on load) and the existence of a name-registered alternative.
* **`memory/kcd2mp-wo78-state.md`** — that the pause path is fork-added, so
  whatever suspends chains during menus on KCD2 is not stock behaviour and
  should not be reasoned about from CryEngine convention.

### How confident, and what would settle it

High for the engine. **`docs/kcd2_lua_api.md` lists only `Script.SetTimer`**,
so whether `Script.SetTimerForFunction` exists on the KCD2 build is
**(inconclusive)**. One `type(Script.SetTimerForFunction)` settles it. If it
exists, the restart gate WO-78 built may be replaceable by registering the tick
by name — but only if the KCD2 save path calls the script-timer serialisation
at all, which is a second unknown.

---

## 9. A refused removal becomes a hide, silently.

**Confidence: high for the engine; unknown whether KCD2 registers such a sink.**

### What we believed

Not asserted anywhere — this is a gap rather than a contradiction. Listed
because the mod verifies removals.

`docs/WO-104-findings.md` §3.2: "replica removed (4-pass verified)".

### What the source says

`RemoveEntity` offers each registered entity-system sink a veto. When a sink
refuses, the engine does not leave the entity alone and does not report
failure — **it hides the entity and returns.** (code-verified)

So an entity that "went away" may be a **hidden entity that still exists**.
A removal check that tests reachability by name or id will see it gone from
neither.

Related, same family: **spawning with an explicit id that is already in use
warns and returns the existing entity** rather than creating one.
(code-verified)

### Which finding to correct

Nothing to reverse. Worth adding to the replica and ghost removal paths as a
known failure mode: after a remove, `IsHidden` is a distinct question from
"does it resolve".

### How confident

High that the engine does this. Whether KCD2 registers a sink that would veto
removal of an `NPC` is **(inconclusive)** — Warhorse's RPG layer is exactly the
sort of thing that would.

---

## 10. `System.GetEntitiesInSphere` is the full-array walk. There is an indexed alternative.

**Confidence: high.**

### What we believed

`docs/WO-103-findings.md` around line 216 weighs the
"main-thread-blocking 37,079-entity walk" against a freshness win, and notes the
by-name primitive was not decompiled. `docs/WO-102.5-findings.md` §6.2 records
37,079 entities walked per native scan.

### What the source says

Four indexes exist. (code-verified — reference §1.3)

| query | structure | cost |
|---|---|---|
| by `EntityId` | flat array + salt check | **O(1)** |
| by name | case-insensitive **multimap** | **O(log n)**, first match only |
| by GUID | hash map | **O(1)** average |
| everything | iterator over the flat array | O(highest used index), yields nulls |

So walking 37,079 entities is the cost of **not having a key**, not the cost of
a by-name lookup. With a roster of names, the per-name cost is logarithmic.

**And the enumeration case has an indexed answer too, which the mod is not
using.** Two Lua binds look interchangeable and are not: (code-verified)

* **`System.GetEntitiesInSphere` takes the full entity iterator and walks every
  entity**, distance-checking each one, allocating a fresh script table per
  call. It is not a spatial query. Same for its by-class variant.
* **`System.GetPhysicalEntitiesInBox` issues a proximity query against the
  partition grid** — a real spatial index, which can filter by entity flags and
  by entity class at the grid level — then keeps entities that have physics.

`kdcmp.lua` has **28 `GetEntitiesInSphere` call sites**, and
`docs/WO-102.5-findings.md` §2.1 describes the Lua path as walking
`System.GetEntitiesInSphere` per anchor. **Each of those is a full-array walk.**

Which reframes the native scan: the 37,079 figure is not something the native
path introduced. It is **what the Lua path was already doing, per call, per
anchor** — and the engine has an indexed alternative one bind away.

Two properties that bite:

* **Duplicate names are legal and silent.** The index is a multimap;
  `FindEntityByName` returns the first match and gives no sign that others
  exist. This matters directly to name-addressed damage (0x30/0x31) and to the
  `kcd2mp_r_` prefix scheme: two entities can answer to one name and the lookup
  will always hand back the same one.
* **Name lookup is case-insensitive.** (code-verified)

### Which finding to correct

`docs/WO-103-findings.md`'s framing of the by-name primitive as unknown, and
any design that assumes a by-name scan requires a walk. The 37,079 figure is
correct for what that scan does; the question is whether it needs to do it.

### How confident, and what would settle it

High for the engine. Whether the KCD2 entity system kept the same indexes is
**(inferred)** — but this project's own decompilation already found
`gEnv->pEntitySystem->FindEntityByName(name)` in use by Warhorse's own pause
code (`docs/WO-102-findings.md` §376), which means the name index is there and
is what Warhorse itself uses.

**One caveat before swapping any call site.** The grid query is gated on the
`es_UseProximityTriggerSystem` CVar; with that CVar off the partition grid is
not maintained and the query returns nothing. (code-verified) It is also a box
rather than a sphere, restricted to entities with physics, and its result should
not be assumed unique. **Check the CVar and compare the two binds' results
side by side on one anchor before trusting the fast one** — a silent empty
result would look exactly like "no NPCs nearby".

---

## 11. Smaller items

Each of these is real, verified in the engine, and too small for its own entry.

| # | what the source says | relevance | confidence |
|---|---|---|---|
| 11.1 | `entity:SetPos` and `entity:SetWorldPos` are **byte-identical** implementations; both go through the world matrix. Neither takes flags. (code-verified) | Any doc or code treating them as different is wrong | high |
| 11.2 | A transform write on a **scaled** entity makes its world matrix non-orthonormal, which triggers an **affine spectral decomposition** on every write. (code-verified) | Hidden per-write cost on any scaled body | high |
| 11.3 | A transform write **recurses into every child**, forcing position, rotation and scale reasons on each. (code-verified) | A mounted rider or an attached body pays the whole subtree per puppet write | high |
| 11.4 | A runtime spawn with no GUID **mints a fresh random `CryGUID`**. (code-verified) | Complete explanation for WO-39/40's field-confirmed unstable per-save GUIDs: for runtime spawns they are *designed* to be | high |
| 11.5 | **Disabling an entity layer stashes each entity's hidden state and restores it on re-enable.** (code-verified) | A layer toggle will overwrite a mod-driven `Hide`. Two owners, one flag | high engine / unknown KCD2 |
| 11.6 | **AI full updates are time-sliced** by a per-actor target interval, round-robin, with everyone else getting a cheap dry update that frame. Decision rate **falls as enabled actor count rises**. (code-verified) | Reframes contention: the brain re-decides at ~10 Hz and slower in a crowd, not per frame. A 50 ms puppet is writing faster than the brain thinks | high engine / KCD2 uses Warhorse's brain, so **(inferred)** at best |
| 11.7 | **Physics is LOD'd by rendering**: not drawn for ~10 frames or beyond `es_MaxPhysDist` → flagged invisible; beyond `es_MaxPhysDistInvisible` and unimportant → allowed to sleep. (code-verified) | One of at least four independent engine causes of NPC existence divergence between two players standing in different places | high |
| 11.8 | Physics parameter changes made while the physics world is stepping are **deep-copied into a request queue** and applied at the next sync. (code-verified) | A write is immediate on the entity and possibly a frame late in physics; the two disagree meanwhile | high |
| 11.9 | The save reads an **active rigid body's position from physics, not from the entity**, with a comment that the entity lags because of multithreading. (code-verified) | Independent confirmation of 11.8 from the engine's own code | high |
| 11.10 | An **animated character ignores a transform write flagged `ENTITY_XFORM_USER`** and treats an unflagged one as a teleport, re-basing its cached location. (code-verified) | The unflagged Lua write is the *right* one for a puppet. A future native path must not "helpfully" flag it as user | high |
| 11.11 | The **movie/sequence system runs on the UI clock, not the game clock**, explicitly so pause does not affect it. (code-verified) | A general engine pattern and a plausible source of "it kept running while paused" | high engine |
| 11.12 | In stock CryEngine an inventory item **is a full entity with an `EntityId`**; in KCD2 it is a WUID with no entity until dropped. (code-verified engine / this project's own field work for KCD2) | Do not reach for the `IItemSystem` mental model when reasoning about KCD2 inventory — it will mislead | high |
| 11.13 | Flow-graph propagation is capped at **256 iterations per event round**, after which it warns and flushes. (code-verified) | A quiet ceiling worth remembering if a cascade of quest beats ever stops halfway. KCD2's port system is Warhorse's, so **(inferred)** | low for KCD2 |

---

## 12. What did *not* contradict

Recorded because a reference that only ever disagrees is not being read
honestly.

* **WO-102's decompilation of the transform write** — `SetWorldPos` reaching
  `CEntity::SetWorldTM`, and the position living in the entity's world matrix —
  is **exactly right**. Incomplete, not wrong (entry 7).
* **WO-78's "suspended != dead"** is exactly the right reading of the timer
  pause mechanism (entry 8).
* **WO-104's save hazard for hidden bodies** was marked inferred and is
  **confirmed** (entry 2).
* **WO-104's fail-closed design** for the replica — never hide the original
  unless the replica bound a soul — is the right shape, and is why 34/34
  refusals cost nothing (entry 3).
* **WO-52's reading** that KCD2 ships CryEngine's netcode live while almost
  nothing implements `NetSerialize` is entirely consistent with the engine:
  the machinery is generic, the content is per-component opt-in that a
  single-player game has no reason to write.
* **WO-99.5's finding that trigger ports can never be read** matches the normal
  design of a data-flow port system. It is not an anomaly and not worth
  re-litigating.
* **The mod's use of light-userdata hex for `entity.id`** was empirically
  correct and is exactly what the engine intends (entry 5).
* **The decision to address damage by name rather than by per-save GUID**
  (WO-40) is well-founded: runtime GUIDs are random by design (11.4). The
  duplicate-name caveat in entry 10 is a refinement, not a reversal.
