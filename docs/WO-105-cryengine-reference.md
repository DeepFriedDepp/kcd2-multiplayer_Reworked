# WO-105 — CryEngine reference

A working reference to the engine KCD2 is built on, assembled by reading the
CRYENGINE source. Written to be searched, not read end to end.

## 0. Provenance, licence, and how to read this

### 0.1 The source

| | |
|---|---|
| repo | `CRYTEK/CRYENGINE_Source` (private; cloned with the maintainer's credentials) |
| branches present | exactly one: `release` |
| tags present | `5.7.0`, `5.7.1` |
| taken | `release`, which is the same commit as tag `5.7.1` |
| commit | `cd017c4f782aaa03806dc73370ea91ad86147a72` |
| commit date | 2022-05-13 |
| clone | `--depth 1 --single-branch`, ~880 MB |
| location | `<ENGINE_REF>/CRYENGINE_Source` — **outside the working tree, never committed** |

No fallback was used. `MergHQ/CRYENGINE`, the 2019 snapshot and the O3DE
`2107.1` checkout were not touched. This is the real CRYTEK repository at its
most recent available branch.

### 0.2 Licence

The CRYENGINE Limited License Agreement governs this source. It is
source-available, not open source, and not GPL-compatible. This project is
GPLv3. Consequences, followed throughout:

* The checkout is read-only and lives outside the repository.
* **No engine source is reproduced here.** Every mechanism below is described
  in prose. Type, function, flag and CVar names are used as identifiers —
  they are facts about an interface, not copied code.
* Where something could not be explained without transcribing code, it is
  named and left undescribed rather than quoted.
* Nothing from the engine may be pasted into this repository, its docs, or a
  commit message, at any later date.

### 0.3 Evidence marks

* **(code-verified)** — read in the CRYENGINE 5.7.1 source named above.
* **(inferred)** — a conclusion drawn from the source, not a statement of it.
* **(inconclusive)** — checked, not answered. What was checked is stated.

### 0.4 The standing caveat — read this once

KCD2 runs a **Warhorse fork** of CryEngine, forked well before 5.7.1 and
modified heavily. Nothing here is automatically true of the KCD2 build.
What (code-verified) means in this document is *"this is how the mechanism is
built in CRYENGINE 5.7.1"*, and nothing more.

That is still worth a great deal, because:

* The engine's *shape* — the entity/component split, the Lua bridge, the
  physics request queue, the Mannequin scope model — is deeply structural and
  expensive to replace. Warhorse replaced the brain and the RPG layer; they
  did not rewrite `CEntity`.
* Several behaviours this project observed in the field match the stock code
  exactly, symptom for symptom (§17.3, §17.7, and the console entry in
  `WO-105-contradictions.md`). That is corroboration in both directions.

Where a claim depends on the fork behaving like stock, this document says so.
**A mechanism read here is a hypothesis to test against the KCD2 build, not a
result.** That is the standing trap this project keeps paying for, and reading
the engine does not exempt anything from it.

### 0.5 Index

| § | subsystem |
|---|---|
| 1 | Entity system |
| 2 | Game object / actor layer |
| 3 | Script system (Lua bridge) |
| 4 | Physics |
| 5 | Animation and Mannequin |
| 6 | Movement |
| 7 | AI |
| 8 | Serialisation and saves |
| 9 | Flow graph and game logic |
| 10 | Sequences, cutscenes, dialogue |
| 11 | Inventory and items |
| 12 | Time and scheduling |
| 13 | Streaming and layers |
| 14 | Networking |
| 15 | Audio, UI, rendering (light pass) |
| 16 | The frame |
| 17 | **Phase 2 — the six questions** |
| 18 | Levers index |
| 19 | What this reference does not cover |

---

## 1. Entity system

### 1.1 What an entity is

`CEntity` is a concrete final class implementing `IEntity`. It is not a base
class for game types — there is one entity implementation, and everything
game-specific hangs off it as **components** (`IEntityComponent`). (code-verified)

Fixed, non-component members on the entity itself: id, GUID, name, class,
flags (public and internal), local position/rotation/scale, cached world
matrix, parent/child hierarchy, and pointers into the partition grid and the
proximity trigger system. Everything else — render, physics, script, audio,
trigger, area, camera, rope, clip volume, substitution — is a component.
(code-verified)

The older "proxy" vocabulary (`ENTITY_PROXY_SCRIPT` etc.) survives as an
alias layer over components. (code-verified)

### 1.2 Identity: EntityId, salt, GUID

* `EntityId` is a `uint32` split into a **16-bit index** (low) and a **16-bit
  salt** (high). `INVALID_ENTITYID` is 0. (code-verified)
* That caps the world at **65,535 simultaneously live entities**.
  (code-verified)
* Entities live in one flat array indexed by the index half. Lookup is a bounds
  mask, an array read, and a salt comparison — O(1), branchless. (code-verified)
* On removal the slot's salt is incremented and the index goes on a free list.
  A recycled index therefore produces a **different** `EntityId`, so a stale
  handle fails the salt check and resolves to null rather than to the wrong
  entity. (code-verified)
* `EntityGUID` is a **`CryGUID`: 128 bits, two `uint64` halves.** It is a
  *separate* identity from `EntityId`, held in its own hash map. (code-verified)
* A runtime spawn with no GUID supplied **mints a fresh random `CryGUID`**.
  (code-verified) — see §17.4 and `WO-105-contradictions.md`.
* `CryGUID`'s string form is the familiar dashed 8-4-4-4-12 hex shape: a
  4-byte group, two 2-byte groups, then the eight bytes of the low half split
  2 + 6. (code-verified)
* `CryGUID::FromString` accepts **three** inputs: braced, dashed, **and a bare
  hex string of at most 16 hex digits**, which is loaded into `hipart` with
  `lopart` left zero — the "old 64-bit GUID system" path. (code-verified)
  This matters a great deal; see §17.4.
* `FindEntityByGuid` has matching legacy handling: if an exact match fails and
  the query has a non-zero `hipart` with a zero `lopart`, it will match on
  `hipart` alone. (code-verified)

### 1.3 Indexes and lookup

Four indexes exist. Knowing which one a query uses is the difference between
O(1) and a full walk.

| query | structure | cost |
|---|---|---|
| by `EntityId` | the flat entity array + salt check | **O(1)** |
| by name | `std::multimap<const char*, EntityId>` with a **case-insensitive** comparator | **O(log n)**, first match only |
| by GUID | `std::unordered_map<CryGUID, EntityId>` | **O(1) average** |
| everything | an iterator over the flat array | O(highest used index), yields nulls |

(code-verified, all four)

Notes that bite:

* The name index is a **multimap**: duplicate names are legal. `FindEntityByName`
  takes a lower bound and confirms with a case-insensitive compare, so it
  returns **the first entity with that name** and gives no indication that
  others exist. (code-verified)
* The name map keys on a pointer into the entity's own name buffer, which is
  why a rename must erase from the map before mutating the name. Renaming also
  fires `ENTITY_EVENT_SET_NAME`. (code-verified)
* Registering a GUID uses a plain map insert. A **second entity registering an
  already-registered GUID does not displace the first** — the insert is a
  no-op — but the entity's own GUID member is still assigned. Two entities can
  therefore carry the same GUID while only one is findable by it.
  (code-verified) See §17.6.
* Counting entities walks the whole array. (code-verified)

**Spatial queries — and the trap in them.** Two Lua binds look interchangeable
and are not: (code-verified)

| bind | what it actually does |
|---|---|
| `System.GetEntitiesInSphere(center, r)` | **takes the full entity iterator and walks every entity**, distance-checking each one. No spatial index is involved. Same for the by-class variant. |
| `System.GetPhysicalEntitiesInBox(center, r)` | issues a **proximity query against the partition grid** — a real spatial index — then keeps only entities that have physics |

The grid query supports filtering by **entity flags** and by **entity class**
at the grid level, before anything reaches script. (code-verified)

Two caveats on the fast one: (code-verified)

* It is **gated on the `es_UseProximityTriggerSystem` CVar**. With that CVar
  off the partition grid is not maintained at all (the same CVar gates grid
  relocation on every transform write, §17.1) and the query returns nothing.
* It filters to entities **that have a physical entity**, and its box is a box,
  not a sphere — a caller wanting a sphere must distance-filter afterwards.
* Its own comment says it de-duplicates entities that physics reports more than
  once; the filter as written removes only entities without physics, so a
  caller should not rely on the result being unique.

### 1.4 Spawning

Order, per spawn: (code-verified)

1. Validate params. An archetype class resolves to the archetype's class; a
   null class becomes the default class.
2. A spawn **lock** can refuse the whole thing unless the caller passes the
   ignore-lock flag.
3. Registered sinks get `OnBeforeSpawn` and **any one of them can veto**.
4. An id is allocated, or a caller-supplied id is claimed. Supplying an id that
   is already in use **warns and returns the existing entity** rather than
   creating one — a silent aliasing hazard.
5. A null GUID is replaced by a freshly created random `CryGUID`.
6. The entity is constructed, pre-initialised, placed in the array, and its
   GUID registered.
7. `Init` runs (components created, script bound). **A failed `Init` deletes the
   entity.**
8. Sinks get `OnSpawn`.

### 1.5 Removal and lifetime

* Removal is **deferred by default**: the entity is marked garbage, put on a
  pending list, and destroyed during the entity system's frame update. A force
  flag destroys immediately. (code-verified)
* Sinks get `OnRemove` and **can refuse**. When one does, the engine does not
  leave the entity untouched — **it hides it instead** and returns. A caller
  that only checks "did the entity go away" can be looking at a hidden entity
  that still exists. (code-verified) This is directly relevant to any
  remove-then-verify loop.
* Before the done event, the physics component is prepared for deletion
  (physicalised to none, physics flagged disabled) so no outstanding physics
  callback can fire into a dying entity. (code-verified)
* Id/salt mismatch on removal is detected and refused. (code-verified)

### 1.6 Events

* Events are a flag mask (`Cry::Entity::EventFlags`), not a subscription list
  per listener. Each component declares the events it wants via `GetEventMask`;
  the entity keeps a per-event vector of interested listeners. (code-verified)
* A component changing its mind calls back into the entity to re-derive the
  mask. (code-verified)
* `ENTITY_EVENT_UPDATE` is special: subscribing to it puts the component into a
  **global sorted list** that the entity system walks each frame. An entity is
  "active" exactly when at least one of its components is in that list, and it
  gets `ENTITY_EVENT_ACTIVATED` the first time it enters. (code-verified)
* **The engine does not iterate all entities per frame.** It iterates the
  update-subscribed component list. (code-verified)

### 1.7 Class registry

* Classes are registered by name into a name→class map; duplicate registration
  warns and is refused unless the class carries the modify-existing flag.
  (code-verified)
* A class carries: name, flags, script file, an optional script-file handler,
  an optional **user proxy create function** (the hook by which a native module
  attaches its own component to every entity of a class), an event list, and a
  GUID. (code-verified)
* Class flags worth knowing: entity-archetype, create-per-client, invisible in
  editor, modify-existing, send-script-events-from-flowgraph. (code-verified)

### 1.8 Implications for a multiplayer mod

* **Safe from outside:** id lookups, name lookups (with the duplicate caveat),
  GUID lookups, reading flags, reading the transform.
* **Has hidden side effects:** every transform write (§4.3, §17.1); `Hide`
  (§17.2); anything that changes a component's event mask; spawning with an
  explicit id.
* **Not safe to assume:** that an `EntityId` held across a save/load still
  means anything (§8.3); that a name is unique; that a GUID is stable for a
  runtime-spawned entity; that a removal removed anything (§1.5).
* **Levers:** `ENTITY_FLAG_NO_SAVE`, `ENTITY_FLAG_NO_PROXIMITY`,
  `ENTITY_FLAG_UPDATE_HIDDEN`, `ENTITY_FLAG_TRIGGER_AREAS`, the transform
  suppression flags (§4.3), entity system sinks. All but the sinks are reachable
  from Lua (§18).

---

## 2. Game object / actor layer

`IGameObject` sits above the entity as a component and is where the actor
stack lives. In 5.7 it derives from `IEntityComponent`, `IActionListener` and
`INetEntity`. (code-verified)

### 2.1 Extensions

* A game object holds a list of **extensions** (`IGameObjectExtension`).
  An actor, an inventory, an item, a vehicle are all extensions.
  (code-verified)
* Extensions are queried by name or by a registered extension id.
  (code-verified)
* Each extension has up to **five update slots**, each independently enabled
  and each carrying an **enable condition**: never, always, visible, in range,
  visible-and-in-range, visible-or-in-range, visible-or-in-range-ignoring-AI,
  visible-ignoring-AI, without-AI. (code-verified)
* A separate pre-physics update rule: never, always, when-AI-activated.
  (code-verified)

### 2.2 Activation, visibility and distance

* The game object tracks a six-state visibility/distance machine: visible or
  not-visible or check-visibility, crossed with close or far away.
  (code-verified)
* **`ShouldUpdateAI` returns false immediately if the entity is hidden, or has
  no AI.** Only then does it consult the AI activation mode: never → false,
  always → true, visible-or-in-range → the visibility/distance test.
  (code-verified)
  * So **hidden defeats AI updates unconditionally**, and
    `ENTITY_FLAG_UPDATE_HIDDEN` does **not** rescue it — that flag only changes
    the answer of `IsProbablyVisible`, which is consulted in a branch the hidden
    gate has already returned from. (code-verified)
* Whether the game object is activated at all is a **union**, not just the AI
  answer: the AI answer, **or** any extension update slot that should run,
  **or** a non-zero force-update count. (code-verified)
  * A slot runs if it is force-enabled; else not if it is flagged never-update
    or is disabled; else it passes its visibility and/or range gates, combined
    with AND or OR per a per-slot flag.
  * Those gates use the **raw** visibility state, not the
    `ENTITY_FLAG_UPDATE_HIDDEN`-aware form. (code-verified)
  * When AI is off and the entity has AI, slots flagged disable-with-AI are
    skipped; other slots still evaluate. (code-verified)
* **So a hidden entity's game object does not necessarily go inactive.** Its
  AI-driven reason to be active is gone, and pre-physics updates under the
  when-AI-activated rule stop, but an extension with an always-on update slot
  keeps it ticking. (code-verified)
* Two auto-disable policies are layered on top:
  * **AI activation mode**: never / always / visible-or-in-range.
  * **Auto-disable-physics mode**: never / when-AI-deactivated /
    when-invisible-and-far-away. (code-verified)
* A debug CVar (`g_forceFastUpdate`) forces "not visible, far away" for every
  game object — a global worst-case switch. (code-verified)

### 2.3 Aspect profiles

* `IGameObjectProfileManager` lets an extension react to an aspect's **profile**
  changing. A profile is a discrete mode for a networked aspect — the canonical
  case is a physics aspect switching between a living-entity profile and a
  ragdoll profile. (code-verified) See §14.

### 2.4 Implications for a multiplayer mod

* An NPC that is far away or unrendered may have **stopped updating its actor
  extension entirely** before anything the mod does is involved. That is engine
  policy, not a mod bug (§17 and §13).
* `ENTITY_FLAG_UPDATE_HIDDEN` keeps a hidden entity's **Lua update** alive and
  makes `IsProbablyVisible` answer true. It does **not** re-enable AI updates
  on a hidden entity — the hidden gate in `ShouldUpdateAI` is unconditional
  (§2.2). (code-verified)
* A second entity sharing an identity does **not** share a game object; each has
  its own extensions, its own inventory, its own update state. (inferred, from
  the per-entity component model)

---

## 3. Script system (the Lua bridge)

### 3.1 How a scriptbind is registered

A bind is a C++ functor stored in a Lua **userdata upvalue** attached to a C
closure, keyed into a table by raw set. The userdata packs the functor, a
parameter-id offset, and a human-readable signature string used for error
messages. (code-verified)

### 3.2 What a call actually costs

Per call, the fixed path is: (code-verified)

1. Lua's own C-function dispatch.
2. One pointer read to recover the functor from the closure's upvalue.
3. A `CFunctionHandler` constructed **on the stack** — four members, trivial
   constructor and destructor, **no heap allocation**.
4. One indirect call through the functor.
5. Per parameter actually read: one virtual call into the handler, one Lua
   stack type switch.
6. Return values pushed through the same switch.

There is **no lock, no global marshalling step, and no allocation** in that
path. The base cost of a Lua→native call in this engine is small and constant.

What is *not* cheap, and is what any real measurement will actually be
measuring: (code-verified)

* **Tables.** A table parameter or return value allocates a script table
  wrapper, takes a reference, and attaches it to the Lua value. Returning a
  fresh table allocates a Lua table and feeds the garbage collector.
* **Strings**, which may allocate on the Lua side.
* Whatever the bind's body does — which for most useful binds dwarfs
  everything above.

**The `SetCachedVector` convention.** Binds that return a `Vec3` (world
position, world angles, direction, velocity) use a shared helper that
**reuses a table the caller passes as a parameter**, and only allocates a new
one when the caller passes nothing. (code-verified) So:

* `e:GetWorldPos()` — allocates a Lua table, every call, forever.
* `e:GetWorldPos(reusableTable)` — writes into the caller's table, allocates
  nothing.

This is not a micro-optimisation at the scale this project runs at. See
`WO-105-contradictions.md` for the count of affected call sites in `kdcmp.lua`.

### 3.3 The number problem — read this before designing any wire field

**Every scalar that crosses the Lua↔C++ boundary through `ScriptAnyValue` is a
32-bit `float`.** (code-verified)

* The stored number type is `float`. The setter takes a `float`. The getter
  returns a `float`.
* The constructors from `int` and from `unsigned int` both cast to `float`.
* Lua→C++ conversion reads the Lua number (a C `double`) and casts it to
  `float`.
* C++→Lua conversion pushes the `float` as a Lua number.
* The `int`/`unsigned int` extractors cast the stored `float` back.

Consequence: **integers are exact only up to 2^24 = 16,777,216** across a
scriptbind boundary. Above that, silently, they are not.

The engine knows this and provides the escape: **`ScriptHandle`**, a union of a
pointer-width integer and a `void*`, pushed into Lua as **light userdata**.
The header states plainly that handles exist because Lua has no integers and
full-range integers must travel this way. (code-verified) An `EntityId`, a
timer id, and anything else needing full range go as handles.

That is why `entity.id` in Lua is userdata, not a number, and why
`tostring()` on it yields a hex form rather than a numeral — a fact this
project discovered empirically and worked around; the source explains it.

**Design rules that follow** (inferred, but directly from the above):

* Any 64-bit identifier (a WUID, a soul id, an item id) **cannot survive the
  number path**. If a bind returns one as a number it is already destroyed
  before Lua sees it.
* World time in seconds is safe as a float until 2^24 seconds ≈ 194 world-days;
  world time in **milliseconds** breaks at ~4.6 hours.
* Money in decagroschen, sequence numbers, and frame counters all have a hard
  ceiling at 16.7 M **regardless of how they are formatted**.
* WO-104's number audit checked string *formatting* on the Lua→agent channel.
  It did not check this. See `WO-105-contradictions.md`.

### 3.4 Executing a buffer

`ExecuteBuffer` compiles and runs a string, optionally in a supplied
environment table. `CompileBuffer` compiles once and returns a reusable
function handle. (code-verified) A hot path that re-executes the same string
is paying the compile every time; compiling once and calling the handle is the
supported alternative. (inferred)

### 3.5 Per-frame script work

`CScriptSystem::Update`, once per frame, before input and before physics:
(code-verified)

1. Sets the debugger mode from a CVar.
2. Writes the globals `_time` (current time, seconds, **float**), `_frametime`
   (frame delta, float) and `_aitick` (AI tick count).
3. Runs **one incremental Lua garbage-collection step** — a fixed step size,
   every frame. Table churn from Lua therefore converts into per-frame GC work.
4. Runs the script timer manager (§12).

### 3.6 The entity script component

* Each entity with a script gets a Lua script component holding the entity's
  script table and a state machine (`GotoState`, begin/end state functions).
  (code-verified)
* Its event mask is a large fixed set — init, done, reset, attach/detach, the
  five area events, physics break, audio trigger ended, level loaded, start
  level, start game, pre/post serialize, hide, unhide, collision, anim event.
  (code-verified)
* **`ENTITY_EVENT_UPDATE` is added to that mask only when** the script actually
  implements an update function, updates are enabled, **and** the entity is not
  hidden — or is hidden but carries `ENTITY_FLAG_UPDATE_HIDDEN`. (code-verified)

### 3.7 Implications for a multiplayer mod

* **Safe:** reading state through binds; calling binds at high frequency — the
  dispatch is not the bottleneck.
* **Costly, and avoidable:** the no-argument `Vec3` getter form, in a loop.
* **Unsafe:** any integer over 16.7 M through a bind; assuming a bind that
  "returns an id" returns a number you can compare or format.
* **Lever:** pass a scratch table to every vector getter in a hot loop.

---

## 4. Physics

### 4.1 Entity types

Physical entities are typed: static, rigid, wheeled vehicle, living,
particle, articulated, rope, soft, area. A humanoid is a **living entity** — a
capsule or cylinder with a pivot height, a ground collider, a velocity, and a
flying flag. It is not a rigid body and does not behave like one.
(code-verified)

### 4.2 The threading model

**Physics runs on its own thread.** The main loop *requests* a step with the
frame delta and continues; the AI update and the entity update run
concurrently with the physics step. (code-verified)

Parameter changes from another thread are mediated by a request wrapper:
(code-verified)

* If the physics world is stepping, or the entity is already queued, **the
  entire parameter struct is deep-copied into a request queue** (including
  pointed-to sub-blocks) and applied at the next physics sync point. The call
  returns success immediately.
* Otherwise the caller takes a spin lock and the change applies in place.

So a transform write from the main thread is **immediate on the entity and
possibly a frame late in physics**. The two can disagree for a frame, in both
directions. (code-verified)

Logged physics events are pumped on the main thread at a defined point in the
frame (§16); immediate events fire on the physics thread. (code-verified)

### 4.3 What a position parameter change does

The generic path, when bounds recalculation is on (which is the default):
(code-verified)

1. A broadphase query for **physics triggers** around the *old* bounding box
   — unless the entity is flagged never-affect-triggers.
2. Bounding box recomputation from every part's geometry.
3. Reposition in the broadphase grid.
4. Under a write lock: position, rotation, and the synchronised coordinate
   block are written.
5. Bounding box recomputed again, per-part boxes updated.
6. Parts repositioned.
7. A second broadphase query for physics triggers around the *new* bounding box.

Plus, if the entity is being moved to a different physics grid, its velocities
are re-based into the new grid's frame. (code-verified)

`bRecalcBounds` is not a boolean. It is a bit field, and the bits change
behaviour materially. Observed uses: bit 1 (recalc at all), bit 2, bit 16,
**bit 32**, bit 64, bit 128. (code-verified)

### 4.4 The living-entity teleport rule — the important one

When a living entity receives a position parameter change **without bit 32
set**, and the new position differs from the old by more than **1% of the
entity's capsule z-size**, the engine: (code-verified)

* **releases the ground collider**,
* **sets the flying flag**,
* **zeroes the velocity**,
* zeroes the height delta.

`pe_params_pos` **defaults `bRecalcBounds` to 1** — bit 32 clear.
(code-verified) The entity system constructs it with that default and never
sets bit 32 (code-verified). Therefore:

> **Every transform write that reaches a living entity through the entity
> system, and moves it more than about a centimetre, puts that NPC into the
> airborne state with no ground contact and zero velocity.**

Bit 32 is the engine's own "this is a teleport, do not run the real-move
response" flag. The living entity sets bits 16 and 32 on its *own* internal
repositioning; vehicles use 16, 32 and 64; the rigid-body path likewise gates
its real-move handling on bit 32 being clear. (code-verified)

See §17.1 — this is the mechanism behind NPCs sinking under a puppet write, and
it explains why the symptom scales with write frequency rather than write
magnitude.

### 4.5 Physics → entity writeback

Every physics post-step, for every entity with physics enabled: (code-verified)

* An internal recursion guard is raised so the writeback does not bounce back
  into physics.
* The entity's position and rotation are set from the physics state, tagged
  `ENTITY_XFORM_PHYSICS_STEP`.
* For articulated and wheeled types, each slot's local transform is set from
  the corresponding physics part.
* If the entity is re-parented by physics (a moving-platform grid change), the
  entity hierarchy is detached and re-attached to match.

**So physics writes the entity transform back continuously.** A puppet writing
at 20 Hz is interleaved with a physics thread writing back at the physics rate.
(code-verified)

### 4.6 Physics level-of-detail

Also on post-step, keyed off the render node: (code-verified)

* Not drawn for the last ~10 frames, **or** beyond `es_MaxPhysDist`
  (`es_MaxPhysDistCloth` for soft bodies) → the physical entity is flagged
  invisible.
* Beyond `es_MaxPhysDistInvisible` **and** flagged unimportant → a physics
  idle timeout of `es_FarPhysTimeout` is applied, i.e. it is allowed to sleep.
* An ocean-flag update is deferred to avoid contending with octree jobs.

This is engine-level culling of physics by rendering. An entity the camera has
not drawn is on a different physics footing from one it has.

### 4.7 Suspension vs destruction

`DestroyPhysicalEntity` takes a mode: normal (0), **suspend (1)**, **restore
(2)**, keep-if-referenced (4). (code-verified)

Suspend: detach from the broadphase grid thunks, unlink from the typed entity
lists, stash the simulation class and set it to the "hidden" sentinel, and move
the entity to a hidden list. Restore: put the simulation class back, re-register
in the grid, clear the deletion time. (code-verified)

**A suspended physical entity is out of the broadphase entirely** — it will not
collide, will not be hit by a ray cast, and will not appear in an overlap
query. (code-verified) This is what `Hide` uses (§17.2).

### 4.8 Implications for a multiplayer mod

* **A transform write is not a cheap assignment.** It is two trigger broadphase
  sweeps, two bounding-box computations, a grid reposition, and — on a
  humanoid — a ground-collider release.
* **The designed way to move an NPC is not a transform write** (§6).
* **Levers:** `ENTITY_XFORM_IGNORE_PHYSICS` suppresses the physics half
  entirely; `ENTITY_XFORM_NO_EVENT` suppresses the event half;
  `ENTITY_FLAG_NO_PROXIMITY` suppresses the proximity half. Whether the KCD2
  Lua bind exposes any of them is (inconclusive) — the stock bind does not
  (§17.1).
* **Do not treat a physics read taken on the main thread as synchronous with a
  write issued on the main thread.** The write may be queued.

---

## 5. Animation and Mannequin

### 5.1 Character instance

An entity slot can hold an `ICharacterInstance`: a skeleton pose, a skeleton
animation controller, an attachment manager, and a facial instance. Animation
evaluation is job-driven and **synchronised once per frame** at a defined point
after the game framework's post-update and before the camera is finalised — the
comment in the main loop states this must happen before view update in case the
camera depends on a joint. (code-verified)

### 5.2 Mannequin: the model

Mannequin replaced the animation graph. Its pieces: (code-verified)

* **Fragment** — a named, tagged unit of animation, resolved from an animation
  database.
* **Tag / tag state** — a bitfield of named tags. The current tag state selects
  which fragment variant plays and, critically, **which scopes a fragment
  occupies**.
* **Scope** — a channel on a character (full body, upper body, weapon, a
  secondary character). Each scope binds a character instance and a context.
* **Scope context** — the entity plus character instance a group of scopes acts
  on. A context whose entity has gone stale is detected and warned about.
* **Action** (`IAction`) — a request to play a fragment. This is the unit the
  outside world queues.
* **Action controller** — per character; owns the scopes, the pending action
  queue, and the arbitration.

### 5.3 Action lifecycle and arbitration

An action's status is one of: none, pending, installed, exiting, finished.
(code-verified) Its flags include blend-out, no-auto-blend-out, interruptable,
installing, started, requeued, trump-self, transitioning, playing-fragment,
transitioning-out, transition-pending, fragment-is-one-shot, stopping.
(code-verified)

Queuing an action does **not** play it: (code-verified)

1. `Queue` initialises the action and inserts it into the pending list
   **ordered by priority comparison** — higher priority inserts ahead; equal
   priority inserts ahead only if the newcomer is a requeue and the incumbent
   is not.
2. The scope mask comes from the action's forced mask **or** from looking up the
   fragment id plus the current tag state in the controller definition.
3. The mask is then **intersected with the controller's active scopes**. A
   scope whose context has no valid character is not active, and an action
   restricted to it installs on nothing.
4. Installation on an occupied scope asks the incumbent root action to blend
   out, passing the priority comparison. The incumbent decides.

So an externally queued action competes with whatever the character's own
behaviour system has installed, on priority and on scope, every time.
**A queue call succeeding is not evidence the fragment played.** (code-verified)

### 5.4 Update and pause

* The controller update is skipped wholesale when its paused flag is set.
  (code-verified)
* Otherwise: time is scaled by the controller's time scale; context validity is
  checked; the tag state is recorded; each scope's root action is updated with
  a per-action speed bias; blend channels are copied from the skeleton's user
  data into the action's parameters; one-shot scopes are checked for early
  blend-out. (code-verified)
* `Resume` optionally restarts animations rather than just unpausing.
  (code-verified)

### 5.5 Animation vs physics: who owns the position

Two orthogonal settings, both per character, both layered: (code-verified)

**Movement control method** — set independently for horizontal and vertical:

| value | meaning |
|---|---|
| entity | the entity/physics drives; animation follows |
| animation | **animation root motion drives**; physics follows |
| decoupled catch-up | animation drives, entity catches up |
| clamped entity | entity drives, clamped |
| smoothed entity | entity drives, smoothed |
| animation + horizontal collision | animation drives with collision |

**Collider mode** — disabled, grounded-only, pushable, non-pushable,
pushes-players-only, spectator — requested through a **layer stack**:
animation-graph, game, **script**, flow-graph, animation, force-sleep, debug.
(code-verified) A script-layer request is an explicit, supported entry point.

### 5.6 What an animated character does when something writes its transform

The animated character subscribes to the transform event. On receiving one:
(code-verified)

* If the write is flagged **user** or **physics-step**, it is **ignored**.
* Otherwise it is treated as a **teleport**: the character re-bases its cached
  entity location from the entity's current world rotation (if rotation
  changed) and world position (if position changed).

A block that would have forced the movement control method back to
entity-driven on teleport is present but **disabled**. (code-verified) So after
an external teleport the control method stays whatever it was — and if it was
animation-driven, root motion continues to drive the position and will fight
the write.

### 5.7 Implications for a multiplayer mod

* **A Lua transform write (no flags) is seen as a teleport and re-bases the
  animated character** — which is the behaviour you want for a puppet.
  A write flagged `ENTITY_XFORM_USER` would be *ignored* by the animated
  character and then overwritten by its own logic.
* **Queueing a swing is a request, not an outcome.** Priority, tag state and
  scope activity all gate it. This is the mechanism behind this project's
  repeated finding that a successful call produced no animation.
* The **tag state is the lever** for which fragment and which scopes — it is
  continuous state, not an event, and must be sampled, not polled slowly.
* The **script collider-mode layer** is a designed hook this project has not
  used. (inferred as unused; not verified against the KCD2 bind set)

---

## 6. Movement

### 6.1 The funnel

`IMovementController` has one entry point for motion:
`RequestMovement(CMovementRequest&)`. (code-verified) Both AI and player input
end up here.

A movement request is **sparse and flag-based** — only the fields whose flags
are set mean anything. It can carry: (code-verified)

* a move target and a distance-to-path-end,
* a desired speed, a target speed, a pseudo-speed,
* a look target with an importance, an aim target, a body target,
* a desired lean and peek-over,
* a stance,
* an alertness (with change detection),
* **an actor target** — the exact-positioning system,
* Mannequin tag requests,
* a context.

The controller may **refuse** a request and rewrite it into the nearest one it
could satisfy, for the caller to inspect and re-issue. (code-verified)

### 6.2 Exact positioning

The actor target describes "be at this position, with this orientation, by the
end of this animation", with a query id and completion callbacks
(`IExactPositioningListener`). (code-verified) This is the engine's own answer
to *put this character precisely here* — and it runs **through animation**, so
it does not teleport, does not release the ground collider, and does not
produce a foot-slide.

### 6.3 Implications for a multiplayer mod

* **The designed API for moving an NPC to a place is `RequestMovement`, not a
  transform write.** Everything in §4.4 and §17.1 is a consequence of bypassing
  it.
* Whether KCD2 exposes a movement controller at all from Lua is
  **(inconclusive)** — not checked; Warhorse replaced the brain, and their
  souls/brain system is the likely equivalent. This is worth a probe before any
  further puppet-smoothing work (§19).
* A request-based mover is inherently laggier and less exact than a transform
  write, and cannot be driven at 20 Hz from a remote peer without a local
  prediction layer. That is a real trade-off, not an obvious win.

---

## 7. AI

### 7.1 Objects and actors

* Everything the AI knows about is an **AI object** with a type; actors are a
  subclass, puppets and pipe-users below that, players a sibling.
  (code-verified)
* AI objects are referenced by **weak references**, and the source carries an
  explicit warning that a weak reference does not type-check: after a chain-load
  or a savegame load, an id may have been reused by a different object, so a
  reference that was an actor may no longer be one. (code-verified) Load
  invalidates AI references silently.

### 7.2 The update loop and its LODing — the important part

The AI system's per-frame actor update is **time-sliced, not per-frame**:
(code-verified)

* `ai_AIUpdateInterval` is a *target period per actor*.
* Each frame the system computes how many **full updates** it owes:
  roughly `(enabled actor count / update interval) × frame delta`, with the
  fractional remainder carried forward so the long-run rate is exact.
* It walks a **round-robin head** through the enabled actor set and gives that
  many actors a full update.
* **Every other enabled actor that frame gets a cheap "dry update".**
* Full-update priority for puppets is recomputed per full update.
* A complete pass over all actors flips a flag that allows smart objects to
  update.

Consequences (inferred, from the above):

* **An NPC's brain re-decides at roughly the configured interval, not every
  frame.** At the stock default that is on the order of 10 Hz, and it *falls*
  as the enabled actor count rises, because the per-frame budget is spread
  further.
* Actor count directly buys latency: doubling the number of enabled AI actors
  halves each one's decision rate.
* The brain's *output* — the movement request it left standing — is applied
  every frame by the movement controller and animation regardless. So an NPC
  keeps walking between decisions.

### 7.3 Subsystems

One AI update runs, in order: smart-object initialisation, action manager,
radial occlusion raycast, light manager, navigation, banned smart objects;
then system components, ambient fire, accessory quota, communication, **vision
map**, **audition map**, group manager, cover system, navigation system; then
players and groups; then the movement system; then **actors + target tracking
+ ORCA**, leaders, smart-object manager, interest manager; then the behaviour
tree manager, the global ray caster, the global intersection tester, the
cluster detector, and the tactical point system. (code-verified)

Several of these are individually schedulable from outside via a
subsystem-update entry point. (code-verified)

Perception is **vision map + audition map** — a registration-based system, not
a per-frame all-pairs check. (code-verified)

### 7.4 Enabled and disabled sets

Actors live in an enabled set or a disabled set; only the enabled set is
updated. The system asserts if the set is mutated while being iterated, with a
comment that the fix would be double-buffering. (code-verified) Enabling or
disabling an actor from inside an AI callback is therefore hazardous.

### 7.5 Implications for a multiplayer mod

* **KCD2 does not use this AI system** for NPC behaviour — Warhorse's brain
  replaces it, and this project has already established that CryEngine
  behaviour trees are inert on the KCD2 build. Treat §7 as *the shape of the
  problem Warhorse solved differently*, not as a description of KCD2.
  (inferred)
* What is likely to carry over regardless, because it is a design pattern
  rather than a module: **decision rate is budgeted and scales inversely with
  actor count**, and **perception is registration-based**. Both are worth
  testing for on the KCD2 build before attributing behaviour to the mod.
* AI weak references going stale across a load is a pattern this project has
  already been bitten by in a different form (§8.3).

---

## 8. Serialisation and saves

### 8.1 The save

A save is built from named **sections**. The game-state section is written in a
fixed order: (code-verified)

1. **Basic entity data** — one record per entity, for every entity **not
   flagged `ENTITY_FLAG_NO_SAVE`**. Each record holds: entity id, GUID, name,
   class name, archetype name, AI object id, position, rotation, scale, flags,
   **hidden flag**, **invisible flag**, **physics-enabled flag**, parent entity
   id, physics type, and an ignore-transform flag.
   * For an active rigid body the position is taken **from physics, not from
     the entity**, with a comment that the entity transform lags behind because
     of multithreading. (code-verified) — a direct confirmation of §4.2.
   * A Lua `Properties.bSerialize` of false sets the ignore-transform flag, and
     only when the `es_SaveLoadUseLUANoSaveFlag` CVar is on.
2. Entity properties, for entities whose class asks for it and which are not
   unremovable.
3. Breakables and other CryAction state.
4. The rest of the game data (per-extension serialisation).

### 8.2 The load

(code-verified)

1. Entity timers are paused for the whole load.
2. The basic entity data is read.
3. **Every entity that is not the local player and not flagged unremovable is
   removed**, and pending deletions are forced through.
4. Entity ids from the save are **reserved** so they can be re-created with the
   same ids.
5. Entities are re-created and repositioned from the basic entity data.
6. Per-extension state is restored.
7. Entity timers are unpaused, on both the success and the failure paths.

### 8.3 What this means for anything holding state across a load

* **Every runtime-spawned entity is destroyed on load.** Anything the mod
  spawned is gone unless it is in the save and gets re-created.
* **Hidden state is persisted and restored.** An entity hidden at save time
  comes back hidden. (code-verified)
* **A runtime-spawned entity IS saved** unless it carries
  `ENTITY_FLAG_NO_SAVE`. So an un-flagged mod-spawned body becomes part of the
  save file. (code-verified)
* Entity ids are preserved across the save/load for saved entities, but the
  salt is rebuilt from the saved handles, so id values are re-established rather
  than freshly allocated. (code-verified)
* AI object references go stale silently (§7.1).
* Script timers are handled separately and mostly destroyed (§12.2).

### 8.4 Serialisation contexts

`TSerialize` carries a **target**: save-game, network, or others. Code branches
on it — the script timer manager, for instance, does nothing at all when the
target is network. (code-verified) The same serialise function therefore
behaves differently in a save and on the wire.

Two concrete writers exist: an XML/binary writer pair and a script-table
reader/writer pair that marshals Lua tables into and out of the stream.
(code-verified)

### 8.5 Implications for a multiplayer mod

* **`ENTITY_FLAG_NO_SAVE` is the lever for "do not let my spawned body into the
  player's save".** It is registered as a Lua global and `entity:SetFlags` is a
  scriptbind, so it is reachable from Lua on stock. (code-verified) See
  `WO-105-contradictions.md` — this project concluded no pre-save hook existed
  and built a periodic sweep instead.
* A synced quicksave is a hard problem here for a reason the source makes
  plain: a load is a **full world teardown and rebuild**, not a state patch.
  Any cross-machine save sync has to survive both peers destroying every
  dynamic entity they own.
* Anything the mod hides must be unhidden before a save, or it comes back
  hidden. There is no save-time callback in the stock entity path to do that
  from; the flag is the only clean answer.

---

## 9. Flow graph and game logic

### 9.1 Model

A flow graph is a **data-flow graph**: nodes with typed input and output ports;
activating an output port propagates a value to connected input ports and marks
the target node modified. (code-verified)

Per update: (code-verified)

* Nodes that asked for regular updates are activated unconditionally.
* The modified-node list is swapped into an activating list (so a node may
  safely mark others modified while being processed), and the activating list
  is walked, calling each node with an activation info block carrying the graph,
  the node id and the resolved entity.
* This repeats until nothing is modified, capped at **256 iterations**, after
  which it warns and, on the initialise event, flushes pending activations so
  they do not leak into the next event round.

The modified list is an **intrusive linked list over an index array**, not a
container of pointers. (code-verified)

Graphs are per-entity or global; `CFlowGraphModule` supports instanced
sub-graphs which are reaped at the end of each flow-system update.
(code-verified) Game tokens are a separate global named-variable store with its
own scriptbind. (code-verified)

### 9.2 Entity control from flow graph

Flow-graph entity nodes set transforms with the **TrackView** reason tag
(§10.1). (code-verified) That is a *label*, not a suppression: the full write
path still runs.

### 9.3 Implications for a multiplayer mod

* KCD2's quest/logic layer is **not** this. It is Warhorse's concept/port
  system — the one this project reached through `I_Port` and `C_PortRef`.
  (inferred, from this project's own prior work)
* The structural analogy is nonetheless close and worth keeping in mind:
  ports carry values, activation propagates, and **a trigger port is an event
  sink with no readable value** — which is exactly the shape of this project's
  WO-99.5 finding that trigger ports can never be read. That is the normal
  design of a data-flow port system, not an anomaly. (inferred)
* The 256-iteration cap is the kind of quiet ceiling worth remembering if a
  cascade of quest beats ever appears to stop halfway. (inferred)

---

## 10. Sequences, cutscenes, dialogue

### 10.1 TrackView / the movie system

* A sequence is a set of **animation nodes**, each bound to a target, each
  holding **tracks** of keys. Node types present: entity, camera, light,
  material, event, layer, scene, script variable, CVar, audio, comment, post-FX,
  screen fader, shadow setup, geometry cache. (code-verified)
* The movie system is updated **twice per frame** — a pre-update before the
  entity system and a post-update after it — and is driven by the **UI timer,
  not the game timer**, explicitly so that it is not affected by game pause.
  (code-verified)
* Entity nodes drive their target with ordinary transform writes tagged
  `ENTITY_XFORM_TRACKVIEW`; camera nodes set rotation the same way.
  (code-verified)
* The movie system is paused and resumed by the game framework's pause path,
  alongside time-of-day and entity timers. (code-verified)

### 10.2 Dialogue

CRYENGINE 5.7.1 as shipped here **contains no dialogue system directory** in
CryAction. (code-verified — searched; the CryEngine 3-era dialog system is not
present in this tree.) Conversation is expected to be built on TrackView
sequences, Mannequin actions, flow graph, and the Dynamic Response System.

The **Dynamic Response System** (`CryDynamicResponseSystem`) is the shipped
generic answer: a rules/response engine updated once per frame from the main
loop, before input. (code-verified) Not examined in depth.

### 10.3 Implications for a multiplayer mod

* KCD2's dialogue is Warhorse's own and does not correspond to anything here.
  This project's findings about dialogue cameras and `DialogTwin_*` entities
  stand on their own evidence.
* One transferable fact: **a cinematic/sequence system moves entities with
  ordinary transform writes**, distinguished only by a reason tag. Anything
  that watches for external transform writes will see cutscene motion, and
  anything that fights external transform writes will fight cutscenes.
  (code-verified for the engine's own sequence system; inferred for KCD2)
* The pause asymmetry — sequences on the UI clock, game logic on the game clock
  — is a general engine pattern and a plausible source of "it kept running while
  paused" surprises. (code-verified for CryMovie)

---

## 11. Inventory and items

### 11.1 The stock model

* An **item is a full entity** carrying an `IItem` game object extension.
  (code-verified)
* An **inventory is a game object extension** on the actor, holding
  `EntityId`s. (code-verified)
* `GiveItem` on the item system spawns an entity of the named item class and
  adds it to the actor's inventory, with flags for sound, selection and history.
  (code-verified)
* An inventory-changed listener interface exists (`IInventoryListener` — add
  item, and related callbacks). (code-verified)
* Inventory add is mirrored to the server by RMI in the stock networked model.
  (code-verified)

### 11.2 How KCD2 differs, and why it matters

**KCD2's item model is structurally different.** In KCD2 an inventory item is a
**WUID** with no world entity until it is dropped; the item class travels as a
16-byte class GUID; the engine mints a fresh WUID per save. That is this
project's own established, field-verified finding.

The contrast is the useful part (inferred):

* In stock CryEngine, "the item in my pack" and "the item on the ground" are the
  **same entity** with the same `EntityId`, so syncing items is syncing entity
  state.
* In KCD2 they are different things, which is exactly why this project's item
  sync had to mint its own drop ids and carry a class GUID plus a per-save WUID
  separately.

So: **do not reach for the `IItemSystem` mental model when reasoning about KCD2
inventory.** It will mislead. The WUID/class-GUID split is the real model.

---

## 12. Time and scheduling

### 12.1 Clocks

* The system timer exposes several **timer channels**; game logic uses the game
  channel and UI/movie uses the UI channel, which is unaffected by game pause.
  (code-verified)
* `ITimer::GetFrameStartTime` returns a high-precision time value; the script
  timer manager works in **integer milliseconds** derived from it.
  (code-verified)
* The Lua globals `_time` and `_frametime` are **floats** (§3.5), so `_time`
  loses sub-second precision after ~2^24 seconds and loses more as it grows.
  (code-verified)
* Time of day has its own tick and its own pause. (code-verified)

### 12.2 Script timers — the mechanism this project has been fighting

Two registrations exist: (code-verified)

| bind | callback held as | survives a save? |
|---|---|---|
| `Script.SetTimer(ms, luaFunction [, userData [, bUpdateDuringPause]])` | a **function reference** | **no** |
| `Script.SetTimerForFunction(ms, "globalName" [, userData [, bUpdateDuringPause]])` | a **name string** | **yes**, conditionally |

Behaviour: (code-verified)

* A new timer goes into a **staging map** and is promoted into the live map at
  the *end* of the update pass — deliberately, so that creating a timer from
  inside a timer callback does not recurse.
* A timer is **one-shot**: when it fires it is called once and then erased. A
  repeating chain exists only because the callback re-arms it.
* Removing the timer currently being called is refused with a warning.
* The manager has a **pause flag**. When it is set, a timer is **skipped, not
  destroyed**, unless it was created with the update-during-pause argument.
  Suspended is genuinely not the same as dead — this project reached that
  conclusion empirically and it is the correct reading of the mechanism.
* **In stock CRYENGINE 5.7.1 nothing calls the script timer manager's pause.**
  (code-verified — searched the whole tree.) The pause flag is always false and
  the update-during-pause argument is inert unless a fork adds a caller. The
  *entity* timer pause, which is called from several places, is a **different
  system**.

**Serialisation — the answer to the chain deaths:** (code-verified)

* **Saving skips every timer that holds a function reference.** Only
  name-registered timers are written, and only those whose user data is either
  absent or an entity table (anything else is skipped with a warning).
* **Loading resets the manager first — destroying every live timer — and then
  re-adds only what was saved.**

So a `Script.SetTimer` chain cannot survive a save load, by construction: it is
not written, and the reset on load destroys the live one. A
`Script.SetTimerForFunction` chain can. Lua globals are untouched by any of
this, which is why "still running" flags stay true across the load — they are
plain Lua state, and only the timer manager was reset.

Whether the KCD2 build exposes `Script.SetTimerForFunction`, and whether its
save path calls the script-timer serialisation at all, is **(inconclusive)** —
`docs/kcd2_lua_api.md` lists only `Script.SetTimer`. It is a one-line probe.

### 12.3 Implications for a multiplayer mod

* The restart gate this project built is the right *shape*. The name-registered
  timer is a possible way to not need it. Probe before relying on it.
* A repeating Lua tick is N separate one-shot timers, not one recurring timer.
  Every re-arm is a fresh allocation and a fresh map insert.
* Do not put a wall-clock-derived millisecond value through a scriptbind and
  expect exactness (§3.3).

---

## 13. Streaming and layers

### 13.1 Entity layers

* Entities are grouped into named, hierarchical **layers**, each with an id.
  (code-verified)
* Enabling or disabling a layer: waits for the physics thread first, explicitly
  to avoid flooding the physics request queue (§4.2); activates/deactivates the
  3D engine's object layer for brushes and, separately, for static lights;
  then walks the layer's entities. (code-verified)
* Children are disabled before parents and enabled after them. (code-verified)
* **On disable, each entity's current hidden state and script-update state are
  stashed into the layer record, and the entity is hidden. On enable they are
  restored.** (code-verified)
* `ENTITY_EVENT_LAYER_HIDE` / `LAYER_UNHIDE` are sent to every entity in the
  layer, and listeners are notified. (code-verified)
* Layers can have their own memory heap, released on a delayed schedule with a
  leak warning after 32 frames. (code-verified)

### 13.2 Object and render streaming

The 3D engine streams geometry by distance and view-distance ratio CVars
(`e_ViewDistRatio` and its per-type variants, `e_StreamCgf*`), and maintains a
per-render-node streaming priority updated from the object manager.
(code-verified — surveyed, not read in depth.)

Physics LOD by rendering is described in §4.6; game-object update LOD by
visibility and range in §2.2.

### 13.3 Implications for a multiplayer mod

* **A layer toggle will overwrite a mod-driven hide.** If the mod hides an NPC
  and a layer containing it is disabled and re-enabled, the layer machinery
  stashes and restores hidden state on its own terms. Two owners, one flag.
  (code-verified mechanism; interaction inferred)
* "NPC existence divergence" between two machines has at least four independent
  engine-level causes before any mod logic is involved: layer enable state,
  object streaming distance, game-object update LOD, and physics LOD. Each is
  camera- and position-dependent, so **two players standing in different places
  are by design looking at different subsets of the world.** (inferred, from
  §2.2, §4.6, §13.1, §13.2)
* That is worth stating plainly: **the engine does not guarantee that two
  clients have the same entities in the same state**, and never did — its own
  multiplayer model solves this by having a server own the truth (§14).

---

## 14. Networking

### 14.1 The model

* An entity goes on the wire by being **bound to the network**. (code-verified)
* State is divided into **32 aspects**, each one bit of a mask. Named aspects:
  script (1), physics (3), game-client-static (4), game-server-static (5),
  game-client-dynamic (6), game-server-dynamic (7), then a long list of
  game-client/server lettered aspects up to 31. (code-verified)
* A component serialises itself per aspect through `NetSerialize`.
  (code-verified)
* Changed state is announced with **`MarkAspectsDirty`** — the engine does not
  diff for you. (code-verified)
* An aspect can have a **profile**: a discrete mode whose change is a separate
  event and which re-serialises the aspect's state under new rules. The physics
  aspect's alive/ragdoll split is the canonical use. (code-verified)
* **Authority is server-side by default.** Specific aspects can be marked
  delegatable so the server can hand a client authority over them; this must be
  configured before binding. (code-verified)
* There is a one-off call to permanently disable the physics aspect for an
  entity, which must also be made before binding. (code-verified)
* **RMIs** (remote method invocations) are declared per game-object extension
  with a reliability type (reliable/unreliable × ordered/unordered), an
  attachment type, and a target set: to-client-channel, to-own-client,
  to-other-clients, to-all-clients, to-server, with no-local and no-remote
  modifiers. (code-verified)
* The network is synchronised with the game at **three points per frame**:
  frame start, frame end, and a wake call at the very end. (code-verified)

### 14.2 What the engine assumes about authority

Worth stating explicitly, because it is the assumption the mod is working
against: (inferred, from the above)

* **One server owns the world.** Clients are views with delegated slices.
* **Entity existence is server-decided.** Clients do not independently spawn
  world entities and hope they agree.
* **Divergence is not reconciled; it is prevented** by never letting two
  machines own the same state.
* The entity id space is expected to be **shared and server-assigned** — the
  spawn path's support for a forced id and for reserving known handles exists
  for exactly this.

A peer-to-peer mod on a single-player game has none of those. Every one of this
project's hardest problems — contention, divergence, claims, host authority —
is a re-derivation of a thing the engine solves by fiat. That is not a criticism
of the design; it is the correct framing for why the problems are hard.

### 14.3 Implications for a multiplayer mod

* This project's own finding — that KCD2 ships the netcode live but almost
  nothing implements `NetSerialize` — is consistent with everything above: the
  machinery is generic engine code, and the *content* is per-component opt-in
  that a single-player game has no reason to write.
* The **aspect profile** concept is a good model to steal even without the
  netcode: a discrete mode change that invalidates the meaning of the state
  bytes, sent reliably and separately from the state itself. The mod's
  puppet/replica promotion is exactly an aspect profile change.
* `MarkAspectsDirty` is the right instinct: **do not diff, declare.**

---

## 15. Audio, UI, rendering — light pass

Enough to know what exists and where it hooks. None of this was read in depth.

### 15.1 Audio

* `CryAudioSystem` is a request-based façade over a middleware implementation,
  with its own object/listener/environment/trigger model and callback request
  data. (code-verified — surveyed)
* Audio is updated from the main loop after the entity system and the 3D engine
  tick. (code-verified)
* Entities carry an audio component; the entity system has an audio proxy.
  (code-verified)

### 15.2 UI

* `FlashUI` in CryAction is the Scaleform-backed UI layer: UI **actions** (which
  are themselves flow graphs or Lua), UI elements with named variables, arrays
  and functions, and an action manager with start/end and a state map.
  (code-verified)
* The Lua surface is broad and element-oriented: reload/unload/show/hide an
  element, call a function on it, get and set variables and arrays, goto-and-play
  by frame number or frame name, alpha and visibility on a named movie clip.
  (code-verified)
* This is the family KCD2 exposes as `UIAction.*`, and it is why rich UI in this
  project goes through `UIAction` rather than through direct drawing. The
  engine's own model agrees: there is no general-purpose immediate-mode screen
  drawing intended for gameplay code, only debug auxiliary text and geometry.
  (code-verified)

### 15.3 Rendering

* `RenderDll` is split into a common layer and a D3D backend; there is a
  Scaleform bridge. (code-verified — directory level only)
* The render-relevant facts that reach gameplay are covered where they bite:
  render nodes per entity slot (§1.1), slot world-matrix invalidation on
  transform change (§4.3 / §17.1), the draw-frame counter used for physics LOD
  (§4.6), and occlusion preparation before render in the frame order (§16).
* Rendering begins **before** the main system update in the frame and ends after
  it (§16). (code-verified)

---

## 16. The frame

Canonical order for one frame, from the main loop. (code-verified)

```
PreSystemUpdate (game framework)
  └─ execute any queued "next frame" console command
plugin UpdateBeforeSystem
network SyncWithGame(SleepNetwork)
RenderBegin
── CSystem::Update ──────────────────────────────────────────────
   timer UpdateOnFrameStart
   3DEngine OnFrameStart
   network SyncWithGame(FrameStart)
   SCRIPT SYSTEM UPDATE
     ├─ set _time / _frametime / _aitick globals   (floats)
     ├─ one incremental Lua GC step
     └─ SCRIPT TIMER MANAGER UPDATE
   input update
   dynamic response system
   mono runtime
   console update
   physics PumpLoggedEvents          (main-thread delivery of physics events)
   PrePhysicsUpdate  (game framework → schematyc → entity system)
   PHYSICS THREAD: RequestStep(frameTime)      ◄── runs CONCURRENTLY
   AI SYSTEM UPDATE                            ◄── concurrent with physics
   movie system pre-update             (UI clock, not game clock)
   ENTITY SYSTEM UPDATE
     ├─ entity timers
     ├─ geom-cache + character-bone attachment managers
     ├─ UpdateEntityComponents  (walks the update-subscribed component list)
     ├─ proximity trigger system update
     ├─ area manager update      (enter/leave area events fire HERE)
     ├─ delete pending entities
     └─ layer garbage heaps
   movie system post-update
   time of day tick, 3DEngine tick
   audio update
   network SyncWithGame(FrameEnd / DisplayDebugInfo / WakeNetwork)
─────────────────────────────────────────────────────────────────
PostSystemUpdate (game framework)
plugin UpdateAfterSystem
SyncAllAnimations                     (all animation jobs joined here)
PreFinalizeCamera
PrepareOcclusion
PreRender / Render / PostRender
RenderEnd, PostRenderSubmit
3DEngine SyncProcessStreamingUpdate
```

Orderings that matter:

* **Script and script timers run before physics and before the entity update.**
  A Lua tick sees last frame's physics result.
* **Area and proximity events fire after component updates**, in the same frame.
  A transform written during a component update produces its area enter/leave
  events later that same frame — deferred, not immediate.
* **Physics and AI run concurrently.** Neither is a safe place to assume the
  other's state is settled.
* **Animation is joined once, late**, after the game framework's post-update.
* A console command queued for "next frame" runs at the very top of the frame,
  before anything else.

---

## 17. Phase 2 — the six questions

### 17.1 What runs when a transform is written from outside?

**Answered.** (code-verified)

The Lua entry points first: `entity:SetPos(v)` and `entity:SetWorldPos(v)` are
**byte-identical implementations** — both read the current world matrix, replace
its translation, and set the world matrix back, **passing no transform flags at
all**. `SetWorldAngles` builds a rotation matrix, re-applies the current world
position and does the same. `SetAngles` and `SetLocalAngles` set rotation
directly. (code-verified) None of them expose any suppression flag.

What that unflagged write then runs, in order:

1. **Parent resolution.** With a parent, the world matrix is converted into the
   parent's attach frame first — so the write on an attached entity (a rider, a
   carried body) is relative, not absolute.
2. **Orthonormality check.** A non-orthonormal matrix triggers an **affine
   spectral decomposition** to split it into position, rotation and scale.
   A scaled entity's world matrix is not orthonormal, so **a scaled entity pays
   a matrix decomposition on every single write.**
3. **Dirty compare.** Position, rotation and scale are each compared and only
   the changed ones set a reason bit. An identical write costs nothing further.
4. **World matrix rebuild**, then **recursion into every child** with the
   from-parent reason, which forces position, rotation and scale reasons on the
   child — so an entity with attachments pays the whole subtree per write.
5. **Relocation**:
   * If the entity carries `ENTITY_FLAG_TRIGGER_AREAS` and position changed, it
     is **marked for area re-evaluation** — deferred to the area manager's pass
     later in the frame (§16).
   * If the proximity trigger system is on, the entity is not flagged
     no-proximity, is not hidden and is not garbage, and position changed: it is
     **relocated in the partition grid** and **moved in the proximity trigger
     system**, creating its proximity entity first if it did not have one.
6. **Notification**, unless the no-event reason is set:
   * the net entity is told its transform changed (aspect dirty),
   * **every render slot's cached world matrix is invalidated**,
   * **physics is told** (below),
   * **`ENTITY_EVENT_XFORM` is sent to every subscribed component**, carrying
     the reason mask.
7. **Physics.** Unless the ignore-physics reason is set, and guarded by an
   internal recursion flag, a position parameter change is issued to the
   physical entity: position if position changed, quaternion if rotation
   changed, full matrix for the parented or scaled cases.
   * If the physics world is stepping, **the whole thing is deep-copied into a
     request queue** and applied later (§4.2).
   * When it lands, the generic path runs **two broadphase trigger sweeps, two
     bounding-box computations, a broadphase grid reposition and a part
     reposition** (§4.3).
   * **On a living entity — every humanoid — it also releases the ground
     collider, sets the flying flag and zeroes the velocity**, whenever the
     move exceeds about 1% of the capsule's z-size (§4.4).
8. **Animation.** An animated character receiving the transform event treats an
   unflagged write as a **teleport** and re-bases its cached location. A write
   flagged user or physics-step is ignored by it instead (§5.6).

**This is the mechanism behind NPCs phasing into the ground under a 50 ms
puppet write.** (code-verified for the mechanism; (inferred) that it is *the*
cause in KCD2, which the fork could have changed.) The shape of it:

* Each write puts the living entity into the airborne state with no ground
  collider and zero velocity.
* The living entity re-acquires ground contact during its **own simulation
  step**, by falling onto something.
* At 20 Hz the next write arrives before that has converged, and re-releases it.
* So the capsule is *permanently* airborne, its vertical position is governed by
  whatever the stream says rather than by ground contact, and any vertical error
  in the stream accumulates instead of being corrected by the floor.
* The symptom therefore **scales with write frequency, not with write
  magnitude** — which matches this project's field observations and is the
  opposite of what a naive "the positions are wrong" reading would predict.

**Levers the engine provides, in decreasing order of bluntness:**

| lever | suppresses | reachable from stock Lua? |
|---|---|---|
| `ENTITY_XFORM_IGNORE_PHYSICS` | the entire physics half | **no** — no bind passes flags |
| `ENTITY_XFORM_NO_EVENT` | the component event, render and physics notifications | **no** |
| `ENTITY_XFORM_NOT_REREGISTER` | 3D engine re-registration | **no** |
| `bRecalcBounds` bit 32 on the physics call | the ground-collider release | **no** — not exposed at all |
| `ENTITY_FLAG_NO_PROXIMITY` | grid + proximity relocation | **yes** (`SetFlags`) |
| clearing `ENTITY_FLAG_TRIGGER_AREAS` | area re-evaluation | **yes** (`SetFlags`) |
| `RequestMovement` instead of a write | all of it | (inconclusive) on KCD2 |

The first four are **native-only**. That is a concrete, specific argument for a
native path that the "Lua is slow" argument never was: it is not about speed,
it is about **reaching flags Lua cannot pass**.

### 17.2 What does `Hide()` actually stop?

**Answered.** This project's WO-104 §3.5 marks it inconclusive; the source is
unambiguous. (code-verified)

`Hide(true)`, when the state actually changes:

| | effect |
|---|---|
| **flag** | an internal hidden flag is set |
| **spatial** | relocation runs down its *else* branch: the **partition grid location is freed** and, unless the entity is the local player, **the proximity trigger entity is removed** |
| **render** | render nodes are updated; a slot's render condition includes not-hidden, so slots stop rendering |
| **physics** | `EnablePhysics(false)` → the physical entity is **suspended** (`DM_SUSPEND`): detached from the broadphase grid thunks, unlinked from the typed entity lists, simulation class stashed and replaced, moved to a hidden list. **Character physics on every character slot is suspended too.** A soft body outside the editor is fully released rather than suspended. |
| **script** | the Lua component drops `ENTITY_EVENT_UPDATE` from its mask — **unless `ENTITY_FLAG_UPDATE_HIDDEN` is set**. Every other subscribed event stays subscribed. |
| **AI** | `ShouldUpdateAI` returns false the moment the entity is hidden, before it consults anything else. **`ENTITY_FLAG_UPDATE_HIDDEN` does not rescue this** — it only changes the visibility answer, in a branch the hidden gate never reaches. Pre-physics updates under the when-AI-activated rule stop with it. |
| **game object** | *Not* necessarily deactivated. Activation is the union of the AI answer, any extension update slot that should run, and a force-update count — and slot gates use the raw visibility state. An extension with an always-on slot keeps a hidden entity's game object ticking. |
| **events** | `ENTITY_EVENT_HIDE` to every component |
| **children** | **recurses into every child**, adding a parent-hide flag |

And on unhide, in addition to the reverse: a forced transform update is issued
specifically to move the physics proxy, with a comment stating that physics
ignores updates while hidden. (code-verified)

So, against this project's open questions:

* **"Whether `Hide(1)` stops the hidden NPC's physics" — yes.** Not merely
  ignored: **removed from the broadphase.** No collisions, no ray-cast hits,
  no overlap results. The worry about a player bumping an invisible body is
  unfounded on stock. (code-verified)
* **Does it stop AI? Yes**, at the game-object layer, by making the object
  inactive. Whether Warhorse's brain honours the same gate is (inconclusive).
* **Does it stop area/proximity triggers? Yes** — the proximity entity is
  destroyed outright, not just skipped.
* **Does it stop Lua updates? Yes**, unless the update-hidden flag is set.
* **Does it persist? Yes.** The hidden flag is written into the save
  (§8.1) and restored on load. The save hazard this project identified is real
  and now code-verified rather than inferred.
* **Does a layer toggle interfere? Yes** (§13.1).

`Invisible()` is a **separate, weaker** flag: same physics suspension and render
update, but **no grid or proximity removal** and a different event. Worth
knowing as a distinct tool. (code-verified)

### 17.3 What does a scriptbind call cost?

**Answered structurally; not answered in nanoseconds.** (code-verified for the
structure; no measurement was taken — this WO ran no game.)

The fixed dispatch cost is **small and constant**: a Lua C-function dispatch,
one upvalue pointer read, a four-field stack-allocated handler, one indirect
call. **No allocation, no lock, no marshalling, no global state.** (§3.2)

Which means the framing this project has been using is wrong in an important
way:

* **"Lua is slow, migrate to native" is not supported by the dispatch cost.**
  The bridge is thin.
* What *is* expensive is **what crosses it**: table parameters and returns, and
  strings.
* And the real argument for native is not cost at all — it is **reach**
  (§17.1's flag table, and anything with no bind).

The measurable costs, in the order they are likely to matter at this project's
scale:

1. **Table allocation in vector getters.** `e:GetWorldPos()` with no argument
   allocates a Lua table every call. The bind supports passing a reusable table
   to write into instead. (code-verified) At 94 tracked NPCs × 20 Hz this is
   thousands of table allocations per second, each feeding a per-frame
   incremental GC step (§3.5).
2. **Re-executing strings.** `ExecuteBuffer` compiles every time;
   `CompileBuffer` plus a call on the handle compiles once. (code-verified)
3. **Everything the bind's body does**, which for the ones this project uses
   heavily (entity lookups, sphere queries, spawns) is orders of magnitude
   above the dispatch.

**How to actually measure it**, for a future WO: the engine's own profiler has a
script section, and script-side timing can be taken with the engine timer around
a tight loop of a known-trivial bind. Nothing in this WO measured anything.

### 17.4 How is persistent identity modelled?

**Partly answered, with a concrete lead for the blocked replica.**

What CryEngine provides: (code-verified)

* `EntityId` — session-scoped, 32 bits, index + salt, recycled, **never
  persistent**.
* `EntityGUID` = `CryGUID` — **128 bits**, two 64-bit halves, persistent,
  authored for level entities, **freshly randomised for anything spawned at
  runtime without one**.
* String form: dashed 8-4-4-4-12.
* `CryGUID::FromString` accepts **braced**, **dashed**, or **a bare hex string
  of at most 16 hex digits**, the last of which is loaded into `hipart` with
  `lopart` zero — described in the source as the old 64-bit GUID system.
* `FindEntityByGuid` has the mirror-image lookup: a query with non-zero
  `hipart` and zero `lopart` matches on `hipart` alone.

Now the KCD2 side. A **WUID** is Warhorse's, not CryEngine's, and this project's
own evidence says it is a **64-bit** handle. The roster GUIDs the mod uses for
`SharedSoulGuid` are **dashed 128-bit CryGUID strings** — and at least one of
them, `dc000001-0000-0000-0000-000000000000`, is **exactly the shape a 64-bit
value takes when it is carried in a CryGUID's `hipart` with a zero `lopart`.**
(code-verified for the CryGUID mechanics; the roster shape is read from this
repo's own `kdcmp.lua`.)

Against the 34/34 refusals: the mod's gate requires
`tostring(e.soul:GetId())` to match a **dashed five-group pattern**. From the
source, a scriptbind return value can `tostring` to exactly four things:

| the bind returns | Lua type | `tostring()` gives | matches the dashed gate? |
|---|---|---|---|
| a number | number | a numeral — and for a 64-bit value, `%g` exponent form, already float-destroyed (§3.3) | **no** |
| a `ScriptHandle` | light userdata | a `userdata: <hex>` form | **no** |
| a string | string | the string | **only route that can** |
| a table | table | a `table: <hex>` form | **no** |

So **34/34 refusals are fully explained by the validator's shape assumption**
and prove nothing about whether the soul id is readable. Two of the four
possible returns would also mean the id is a **64-bit handle in hex**, which is
precisely the form `CryGUID::FromString` accepts bare.

This gives a specific, cheap, falsifiable next step — **not a result**:

1. Log `type(e.soul:GetId())` and `tostring(e.soul:GetId())` for a world NPC.
   The mod **already has this probe written** (a `player.soul:GetId()` log line
   in `kdcmp.lua`); it just has never been run against a world NPC and recorded.
2. If it is a number → the WUID is already destroyed by the float bridge
   (§3.3) and **that route is dead**; look for a bind returning a string.
3. If it is userdata or a hex-ish string → extract the hex (the mod's own
   `entity.id` handling already does exactly this) and try **passing the bare
   hex string** as `SharedSoulGuid`, without dashes.

The standing caveat applies at full strength: whether Warhorse's
`SharedSoulGuid` handler routes through `CryGUID::FromString` is **(inferred)**,
and step 3 could simply fail. But the current gate refuses before ever asking.

**Also relevant to identity:** a runtime spawn with no GUID gets a fresh random
one (code-verified). That is a complete explanation for this project's
field-confirmed finding that per-save GUIDs are unstable — for runtime-spawned
entities they are *designed* to be, and there is no mechanism that would make
them otherwise.

### 17.5 Entity iteration and lookup

**Answered.** (code-verified) Full detail in §1.3.

* **By id: O(1).** Array index plus salt check.
* **By name: O(log n)**, through a real index — a case-insensitive multimap.
  It is **not** a walk. It returns the first match and hides duplicates.
* **By GUID: O(1) average**, through a hash map.
* **The full iterator is the only linear walk**, and it visits every array slot
  up to the highest ever used, yielding nulls.
* **`System.GetEntitiesInSphere` IS that walk.** It takes the full iterator and
  distance-checks every entity, every call. It is not a spatial query despite
  its name. (code-verified)
* **`System.GetPhysicalEntitiesInBox` is the indexed one** — a partition-grid
  proximity query, filtered to entities that have physics, gated on
  `es_UseProximityTriggerSystem` (§1.3). (code-verified)

So: walking 37,079 entities is the cost of **not having a key**. With a name or
an id, the engine has an index and the walk is unnecessary.

And the important part for this project: **the native scan did not introduce
that walk — it reproduced what the Lua path was already doing.** Every
`System.GetEntitiesInSphere` call, per anchor, per scan, is a full-array walk
plus a fresh script table. `kdcmp.lua` has 28 call sites. The engine's own
indexed alternative exists and is one bind away.

The practical consequences (inferred):

* A per-name lookup loop over a known roster should use the name index, not a
  walk, and costs log n per name.
* An enumeration should use a sphere/box query against the partition grid.
* The full walk is justified only when the question is genuinely "everything".
* **Duplicate names are legal and silent**, which matters for a mod that
  addresses damage by name (0x30/0x31): the name index will hand back one
  entity and never mention the other.

### 17.6 What does the engine expect about two entities sharing an identity?

**Answered for the CryEngine identity layers.** (code-verified)

* **`EntityId`: sharing is impossible.** The id *is* the array slot plus its
  salt. Two live entities cannot have one.
* **Name: sharing is fully legal.** The index is a multimap. The cost is that
  name lookup silently returns one of them.
* **`EntityGUID`: sharing is possible but half-broken.** Registration is a plain
  map insert, so a second entity registering an already-present GUID is a
  **no-op** — the map keeps pointing at the first — while the second entity's
  own GUID member is still assigned. So both *claim* the GUID, one *resolves*
  from it, and nothing warns.
* **Spawning with an explicit, already-used id** does not create a second
  entity: it warns and hands back the existing one. (code-verified)

What the engine does **not** model at all: two entities sharing a *game-level*
identity — one soul, one character, one inventory. There is no such concept in
CryEngine. Every entity has its own components, its own game object, its own
extensions, its own inventory. (code-verified, by absence)

So running a ghost on a real soul's GUID is, from the engine's point of view,
**two independent entities that happen to have been configured from the same
authored data**. Nothing reconciles them, nothing notices, and anything that
resolves by GUID gets exactly one of them — whichever registered first.
(inferred)

This is the correct framing for this project's ghost model: it is not that the
engine tolerates a shared identity, it is that **the engine has no opinion**,
because identity above the entity is Warhorse's layer, and the consequences all
land there. A second entity on one soul is a Warhorse-level question — crime,
reputation, dialogue, schedules — and this project's field findings (a ghost is
a full crime victim; a second Player entity crashes the game) are exactly what
"the engine has no opinion" predicts.

---

## 18. Levers index

Things the engine offers that a mod can actually reach. Marked by where they can
be reached from. **Everything here is CRYENGINE 5.7.1 — presence on the KCD2
build is unverified in every case.**

### 18.1 Reachable from Lua on stock

| lever | what it does | see |
|---|---|---|
| `ENTITY_FLAG_NO_SAVE` via `entity:SetFlags` | keeps a spawned entity out of the player's save | §8.5 |
| `ENTITY_FLAG_NO_PROXIMITY` | suppresses grid + proximity relocation on every transform write | §17.1 |
| `ENTITY_FLAG_TRIGGER_AREAS` (clear it) | suppresses area re-evaluation on position change | §17.1 |
| `ENTITY_FLAG_UPDATE_HIDDEN` | keeps a hidden entity's **Lua update** alive; makes `IsProbablyVisible` true. **Does not** re-enable AI updates while hidden | §2.2, §17.2 |
| `ENTITY_FLAG_IGNORE_PHYSICS_UPDATE` | ignores physics-step-sourced transforms | §1.8 |
| passing a scratch table to `GetWorldPos` / `GetWorldAngles` / `GetWorldDir` | removes a Lua table allocation per call | §3.2, §17.3 |
| `Script.SetTimerForFunction` | a timer chain that survives a save load | §12.2 |
| `System.GetPhysicalEntitiesInBox` in place of `GetEntitiesInSphere` | a partition-grid proximity query instead of a full-array walk | §1.3, §17.5 |
| the 4th timer argument (update-during-pause) | a timer that runs while the manager is paused — **inert on stock, no caller** | §12.2 |
| `System.AddCCommand` with `%1` / `%%` / `%line` | console commands that take arguments | contradictions §1 |
| `Invisible` rather than `Hide` | render + physics off, **grid and proximity kept** | §17.2 |

### 18.2 Native-only

| lever | what it does | see |
|---|---|---|
| transform reason flags (ignore-physics, no-event, not-reregister, user) | selective suppression of the transform write's side effects | §17.1 |
| `bRecalcBounds` bit 32 | a position change that does **not** release a living entity's ground collider | §4.4 |
| `IEntitySystemSink` | callbacks on every spawn / before-spawn / remove / reuse, with veto | §1.4, §1.5 |
| `IEntityClass` user proxy create function | attach a native component to every entity of a class | §1.7 |
| `RequestMovement` / actor target | move a character through animation instead of teleporting it | §6 |
| collider-mode script layer | request a collider mode without fighting the animation graph | §5.5 |
| Mannequin action priority and forced scope mask | make a queued action actually win a scope | §5.3 |
| `MarkAspectsDirty` / aspect profiles | the engine's own change-declaration model | §14 |
| entity system `PauseTimers` | pause entity timers (distinct from script timers) | §12.2 |

---

## 19. What this reference does not cover

Stated so the gaps are not mistaken for absences.

* **The Warhorse fork.** Everything here is stock 5.7.1. The brain, souls,
  WUIDs, the RPG layer, the concept/port quest system, the crime and reputation
  systems, the dialogue system, the item model, `XGenAIModule`, and every
  `wh_*` CVar are Warhorse's and appear nowhere in this source.
* **Rendering internals.** Directory-level only (§15.3).
* **Audio internals.** Surveyed only (§15.1).
* **Schematyc / CrySchematyc2**, **CryUDR**, **CryUQS**, **the Sandbox editor**,
  **CryManaged/C#**, **VR**, **CryLobby**, **CryGamePlatform**. Present in the
  tree, not read.
* **The GameSDK sample game**, except for the item system's shape (§11.1).
* **Any measurement.** No game ran during this WO. Every performance statement
  is structural.
* **`IMovementController` on KCD2** — whether any equivalent is reachable
  (§6.3). This is the single most valuable unprobed item this reference
  surfaced, because it is the engine's own answer to the problem the puppet
  system exists to solve.
* **The physics solver itself** — contact resolution, the articulated-body
  solver, the water manager. Only the parameter-change and event paths were
  read.

---

## 20. Changes to make to this repository's documentation

Not made by this WO — this WO changed no code and no findings. See
`docs/WO-105-contradictions.md` for the full list with confidence marks. The
short version:

1. `kcd2mp-console-drops-arguments` — the premise is wrong; the case of the
   placeholder is the bug. Highest value, smallest fix.
2. WO-104 §3.5's `Hide` uncertainty — resolved, three ways.
3. WO-104 §3.3's "roster guids are WUIDs of the same form" — they are
   CryGUID-shaped; a WUID is half the width.
4. WO-104 §3.5's "no pre-save hook exists" — `ENTITY_FLAG_NO_SAVE` is a Lua
   global on stock.
5. WO-104 §1.3's number audit — complete for string formatting, silent on the
   float bridge underneath it.
6. `System.GetEntitiesInSphere` **is** the full-array walk, 28 call sites deep;
   `System.GetPhysicalEntitiesInBox` is the indexed one. The native scan
   reproduced that walk rather than introducing it.
7. The Lua-to-native migration argument — the dispatch is not the cost; reach is
   the reason.
8. `kcd2mp-lua-timer-liveness` — correct, and now with a mechanism and a
   possible fix.
