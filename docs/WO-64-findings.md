# WO-64 — KCD2Online: what actually comes into this repo, and how

Reference read this session: `github.com/DeepFriedDepp/KCD2Online_forked` @ `5777c15`
(v0.1.6, 2026-08-14), shallow-cloned locally. MIT-licensed; adoption is a cost
question only. Evidence tiers: **source-read** (the .cpp/.hpp was read this
session, cited by file) / **docs-only** (their markdown claims it, code not
located or contradicts) / **inconclusive**. Nothing below is live-observed —
their mod never ran here.

A recurring pattern worth stating once: **their docs over-claim relative to
their shipped code** in at least four places (each cited below). Every
conclusion in this file is drawn from the code, not the docs.

---

## Phase 1 — native vs. Lua for remote-player representation

### What their code actually does (source-read)

`src/kcse/native_remote_avatar_backend.cpp`:

- **The spawn is Lua.** `queue_avatar_spawn()` (line ~258) builds a Lua string
  and runs it through `pScriptSystem->ExecuteBuffer`: a `Script.SetTimer(1,…)`
  that calls `XGenAIModule.SpawnEntity{Name=…, ClassName=…, Pos=…,
  SharedSoulGuid=…}` and falls back to `System.SpawnEntity{class=…,
  properties={esFaction='Civilians', guidSharedSoulId=…}}`. That is the **same
  soul-backed SpawnEntity family this project has shipped since WO-22** (flat
  table, shared-soul GUID). Their migration doc's claim of "Native
  `IActorSystem::CreateActor("NPC")`" describes a **removed** path — the code
  comment at `poll_active_probe()` says the old CreateActor probe raced XGen's
  Human/Soul registration and was abandoned. Docs-vs-code discrepancy #1.
- **Locomotion animation is Lua too.** `start_avatar_animation()` runs
  `e:StartAnimation(0, clip, …)` via ExecuteBuffer; the clip is selected from
  the **rendered** speed with a 25% low-pass
  (`smoothed_visual_speed = 0.75*old + 0.25*target`, line ~1636), with the
  literal comment: *"Match the working Ghost implementation: animation state
  is derived from what this client actually rendered."* Their multiplayer.md
  claims "Native Actor MovementController requests" — `grep MovementController
  src/` returns **zero hits**. Discrepancy #2. Movement = native
  `IEntity::SetWorldTM` writes (throttled to 16 ms) + Lua clip selection.
- **What is genuinely native** (and genuinely good):
  - *Readiness gating* — `status_impl()` walks typed pointers:
    entity → `GetActorById` → `IsHumanActor()` →
    `m_pMannequinStateParams`/`m_pHitDeathReactions`/`m_pConditionController`
    → `m_pSoul` → a 3-frame + 250 ms soul-settle window
    (`remote_avatar_readiness.hpp`) → `m_inventorySoul.GetInventory()` +
    `GetEquipmentManager()`. Nothing is touched until every stage is ready;
    monotonic state machine, regression = fail-closed
    (`remote_avatar.hpp`'s `is_valid_remote_avatar_transition`).
  - *Equipment* — `native_remote_avatar_equipment.cpp`: real
    `C_Inventory::CreateItem(guid, 1.0, 1)` + `m_inventorySoul.EquipItem`,
    layer-ordered, incremental (unchanged instances retained), verified by
    item-flag and equipment-manager slot readback, transactional rollback.
  - *Weapon draw/holster* — a native weapon-set controller
    (`set_weapon_set_drawn`), SEH-guarded, and on the first fault it
    **disables itself per-avatar** instead of failing the avatar
    (`native_weapon_actions_enabled` flag, line ~1525).
- **Player interpolation** (`client.cpp:3175`): snapshot history buffer,
  adaptive delay `1000/rate + 10 ms` clamped 40–100 ms, lerp between samples,
  ≤60 ms velocity extrapolation past the newest packet, 5 m snap. Same layer
  design our player ghosts already have (WO-63 confirmed ours carries the
  DR/velocity layer); nothing here is ahead of ours.
- **Remote-player behaviour isolation** (`apply_multiplayer_semantics`,
  line ~1243) — the single most portable find of the whole phase, and it is
  **pure Lua**:
  ```lua
  Contexts.SetPersistentOption(e, ctx, 'KCD2OnlineRemotePlayer')
  -- for ctx in: switch_disabledInformationReaction, switch_disabledHearingReaction,
  --   switch_disabledPerceptionReaction, switch_disabledPickpocketReaction,
  --   switch_disabledNearMissReaction, switch_disabledHitBehavioralReaction,
  --   crime_disableReport
  e.soul:RestrictDialog(true)
  e.human:InterruptDialogs()
  -- verified per-context afterwards with e.soul:HasScriptContext(ctx)
  ```
  This is a documented-shape answer to a real, cited problem of ours: WO-31
  found a ghost is a **full crime victim** (real fines, jail, settlement rep
  loss) and that the Civilians faction override is inert. `crime_disableReport`
  plus the disabled-reaction switches attack exactly that, from Lua, with a
  built-in verification read-back. Source-read, not live-verified here.
- **HUD display name** — the interaction/target HUD name is a CryString at
  `C_Soul+0x3E8` (`soul_display_name_string_id_offset`, their comment: this is
  what `Soul.GetNameStringId()` reads; `IEntity::GetName` is only the technical
  id). They assign it natively → real per-player nameplates on ghosts.
  Offset is pinned to **their** build (WHGame `1308617_856`); must be
  re-verified against ours before any write.
- **Station activities** — remote blacksmithing/sharpening/alchemy presented
  via Lua `e.actor:StartInteractiveActionByName('<action>', stationId, true, 1)`
  against the station resolved by GUID (`apply_activity`, line ~1311).

### Does their native path solve problems we actually have?

| Our documented problem | Does their code solve it? |
|---|---|
| Inert Lua writes (health/damage) | Yes — but we already solved this ourselves natively (WO-45+, RTTR/direct calls). Their `C_CombatSoul::DealDamage` confirms the same layer. |
| Mannequin-lock ceiling (WO-39/43) | **No.** They never fight it — combat replay is "deliberately deferred" (multiplayer.md), locomotion/combat fragments are explicitly rejected from their replay path. We are *ahead* here: native ghost swings shipped (WO-45–47); they have nothing equivalent. |
| Brain-fights-the-stream (WO-49 re-assert fix) | Different layer — see Phase 3: `IEntity::Activate(false)`. |
| Ghost joins vanilla crime/pickpocket systems (WO-31) | **Yes — the Contexts/RestrictDialog block above**, and it's Lua, adoptable as-is. |

### Recommendation — do NOT migrate the ghost to a "native backend"

The premise of the phase dissolves on reading: their shipped remote-avatar
spawn *is* our spawn (Lua `SpawnEntity` + shared-soul GUID), their locomotion
presentation *is* our approach (clip from rendered speed — their comment even
cites "the working Ghost implementation"), and the one area where a native
path would matter most to us (combat animation) is the one they punted on and
we shipped. A migration would be churn with no capability gain.

**Adopt instead, as scoped follow-up WOs:**

1. **WO-A (small, pure Lua, highest value/effort ratio): ghost civic
   isolation.** On ghost spawn in `kdcmp.lua`, apply the seven
   `Contexts.SetPersistentOption` switches + `soul:RestrictDialog(true)` +
   `human:InterruptDialogs()`, verify with `soul:HasScriptContext`, log the
   per-context result, and put it behind `mp_ghost_isolate on|off`
   (default on). Success test: punch a ghost in front of a guard — no crime
   report, no fine (WO-31's exact repro). Risk: these context names are from
   their build; if a context doesn't exist ours logs and continues.
2. **WO-B (small, native): ghost nameplates.** In KCDMP.dll, on ghost-ready,
   write the player display name into the Soul's name CryString. First step is
   verification, not the write: locate the field on our build (their 0x3E8 is
   a candidate, RTTR/`GetNameStringId` disassembly confirms), then
   assign + live-verify the target HUD shows the name.
3. **WO-C (optional, Lua): station-activity presentation** via
   `StartInteractiveActionByName` when a peer is at a station — only if we add
   an "activity" field to the emit line; park until someone asks.

**Recorded but not adopted:** their native equipment transaction. Real and
well-built, but our clothing sync works via the preset path and nothing in the
field says fidelity is the bottleneck. Revisit only if per-item equipment
fidelity becomes a goal; the recipe (CreateItem → EquipItem → flag/slot
readback → rollback) is fully captured above.

---

## Phase 2 — the dedicated server: real, and worth building toward?

### What it actually is (source-read)

- `CMakeLists.txt:382`: `KCD2OnlineServer` links **only**
  `KCD2OnlineServerCore` (item ledger, NPC registry, world store, config,
  property, protocol) + networking + winhttp + nlohmann-json. **No libKCD2, no
  engine, no game code.** It genuinely runs without a game client — confirmed
  structurally, not by execution.
- What it "simulates" independently (source-read across
  `server_core.hpp`, `npc_registry.cpp`, `environment.hpp`):
  - **Time**: pure arithmetic — anchor + timescale projection
    (`project_world_time_seconds`). No game clock involved.
  - **NPCs**: *nothing*. `npc_registry` state advances **only** when a
    lease-owning client reports (`npc_registry::update`). With no clients in
    range, every NPC is frozen state in a hash map. The world catalog that
    seeds NPC identity/transform is **generated offline from game files**
    (`npc_world_catalog.json`), not simulated.
  - **Items/containers/doors**: persistence + transactional arbitration
    (protobuf files, atomic-replace writes). No behaviour.
  - Plus: auth/identity (DPAPI tokens, SHA-256 at rest), permissions/GM
    scopes, moderation, chat/voice recipient selection from authoritative
    transforms, test "dummy" players.

### Recommendation — no pilot; the idea it might reopen stays closed

`KCD2OnlineServer.exe` is an **authority-and-persistence process, not a
headless game**. Every unit of world behaviour still comes from a real,
rendering game client that holds a lease. So it does *not* reopen WO-51/56's
"dedicated background instance" idea — that idea needed headless world
*simulation*, and their architecture is positive evidence the leading team in
the space couldn't get one either (consistent with WO-53: no null renderer in
any KCD2 build).

What it *does* validate: our topology. Our relay is already a standalone
authority process (claim table, item claim-echo, time-skip arbitration); theirs
is the same shape with more state promoted into it. The right move is
**selective promotion of authority into the existing relay** where field pain
exists — Phase 3's validation gates are the first concrete instance — not a
new server codebase. No follow-up WO beyond what Phase 3 scopes.

---

## Phase 3 — their NPC "simulation lease" vs. our proximity authority

### Their mechanism (source-read, `src/server/npc_registry.cpp`)

- Server-side, single-writer: at most one lease per NPC. `assign_authorities`
  picks the **nearest interested** connected player (ties → lower id);
  interest = 120 m enter / 150 m leave hysteresis, server-computed.
- Lease = 5 s (`lease_duration`, line 23 — their docs say "two-second";
  discrepancy #3), renewed by every valid update; `lease_id` is monotonic so
  stale owners are rejected; expiry/disconnect/interest-loss → reassign to
  nearest.
- Update validation before acceptance: generation match, owner match, lease-id
  match, not expired, **rotation normalizes**, and a **plausibility speed gate**
  — reject if the NPC moved farther than `40 m/s * elapsed + 2 m`.
- Server owns combat semantics: a monotonic health *decrease* in an accepted
  report becomes a combat result attributed to the reporter, bumps that
  player's server-side **aggro** (decays 5/s outside combat), and sets the NPC's
  combat target. The owner's report can never clear aggro or the combat
  target — the server splices them back into every update (lines 251–261).
- Observers (client side, `native_entity_backend.cpp:1497`): adopt the local
  authored entity, `IEntity::Activate(false)` + transform writes from network;
  damage applied via `C_CombatSoul::DealDamage` (zeroed 0x48 effect descriptor
  — null crashes WHGame, their comment), opponent established via
  `C_CombatActor::SetOpponent(target->GetOrCreateCombatActor())`, behaviour
  intent via native `RequestLocomotion(&goal, speed)`. Original hidden/active
  state saved and restored on teardown.
- **Their own caution is real and visible in code**: the duplicate-spawn bug
  is why `npc_registry.cpp:176` **drops every runtime-dynamic observation**
  ("only catalog-backed authored NPCs are safe to replicate") even though
  their docs describe runtime-spawn support as shipped. Discrepancy #4. Root
  cause per their comments: a runtime Entity GUID is process-local; treating
  it as global identity made two clients mint two canonical NPCs and then
  spawn each other's copy.

### Head-to-head on the scenario ours was built for

Two players engaged with one NPC, and the KCD2-specific killer: **a menu pause
silences the holder** (WO-12/13 — menus suspend `Script.SetTimer`; reload
kills timers outright).

- **Theirs**: no engagement concept at all. Owner silent 5 s → lease reassigns
  to the other (nearest, engaged-or-not) player → NPC snaps to the rival's
  diverged simulation → holder returns, is nearer, reclaims → snaps back.
  That is **exactly the oscillator WO-60's 15 s engagement hold was built to
  prevent**. Their design is *more* exposed to our documented failure case,
  not less. (Their client isn't timer-driven so their silence windows differ,
  but the mechanism has no defense — only the constant.)
- **Ours**: first-claim-wins + engaged-hold (bit 32, 15 s), wire-verified
  T17–T20 (WO-60). The two-players-one-NPC case is explicitly protected.
- What theirs does better: **update validation** (ours accepts any claim
  packet's content), **server-owned damage attribution/aggro** (ours: cue
  sampler + 0x30 events, adequate), and **single-assignment by distance**
  (ours can leave an NPC unclaimed until someone's rescan reaches it — by
  design, and fine).

### Recommendation — keep our system; port three narrow refinements + one pilot

Our claim/hold stands as built; nothing here supports replacement. Port:

1. **WO-D (small, relay-only): claim-update plausibility gates.** In
   `RouteNpcState`: reject a claimed-NPC update whose position implies
   `> 40 m/s * elapsed + 2 m` movement (log + drop, don't release the claim),
   and reject non-normalizable rotations. Copy of `npc_registry.cpp:240–248`.
   Cheap armor against the exact stale-relay/garbage-packet class WO-32 hit.
2. **WO-D (same WO): reserved-name rejection at the relay.** Never accept an
   NPC claim whose entity name matches our ghost/puppet prefixes — defense in
   depth for the recursive-puppet-discovery failure their reserved-name guard
   exists for (`reserved_managed_actor_name`). Ours is currently Lua-side only.
3. **WO-E (pilot, native, the one genuinely superior mechanism): puppet brain
   suppression via `IEntity::Activate(false)`.** This is their answer to the
   unsuppressed-puppet-brain gap WO-51 §joint-combat documents and WO-49's
   re-assert fix works around. Scope: KCDMP.dll resolves the puppet's IEntity
   (vtable slot for `Activate` from their `Offsets/vtables/IEntity.h` shape,
   re-derived for our build), calls `Activate(false)` when a puppet stream
   starts, restores the **saved original** active state on release/expiry —
   behind `mp_npc_suppress on|off`, default **off** until live-verified.
   Success test: puppet under stream stops fighting the 50 ms position writes
   (no rubber-banding against local AI), and cleanly resumes local AI on
   release. Risks, stated: their overall NPC sync is self-declared unreliable
   (identity bugs, not this call); unknown interaction with Warhorse
   schedulers possibly re-activating entities; menus/reload interplay
   unobserved. That's why it's a toggle-gated pilot, not a port.

Explicitly **not** ported: nearest-player lease assignment (breaks our
engagement hold's ownership stability for zero demonstrated gain), server-side
aggro (solves a problem our cue path already covers), interest radii at
120/150 m (ours are sized to our 45 m tracking design).

---

## Phase 4 — smaller comparisons

### 4.1 Shared containers — keep separate pools (don't adopt)

Their shared, server-authoritative containers (`world_store.cpp`,
`native_world_object_sync.*`; docs multiplayer.md §containers) exist to serve
a **persistent-server product**: profiles live on the server, so container
state must too. Two consequences visible in their own code argue *against*
importing this into our two-vanilla-saves model: (a) it drags the whole item
ledger in (every instance needs exactly one owner), and (b) they must actively
fight local saves — save-baseline pickups are refused as multiplayer items so
a local save can't mint instances. Our separate-pools choice avoids both by
construction. Nothing in their reasoning changes our case; the designs serve
different products. **No follow-up WO.**

### 4.2 Item ledger — no real gap of ours it closes (don't adopt now)

`item_ledger.hpp/.cpp`: every instance UUID mapped to exactly one location
(player/container/world); atomic move/split/merge with stack-count
conservation; duplicate ownership rejected. It is the bookkeeping shared
containers require. Our only shared item surface is dropped items, and WO-48's
claim-echo already arbitrates the pickup race there. One idea worth keeping in
the back pocket if the field ever reports duplicate/ghost drops: their
**tombstone + same-UUID re-drop reactivation** makes pickup/re-drop idempotent
across late/replayed packets. Not a current gap → **no follow-up WO;
re-evaluate on field evidence.**

### 4.3 Time/weather — time equivalent; two small weather refinements

- **Time**: theirs = server anchor + timescale, arithmetic projection,
  forward-only day-preserving corrections (`environment.hpp`,
  `next_world_time_at_hour`). Ours = GetWorldTime + connect exchange +
  forward-only convergence (WO-38/59). Equivalent layer, equivalent rules.
  **Nothing to adopt.**
- **Weather**: theirs applies `cheat_set_weather id:{1–33}
  transition:{s}` via console (`native_runtime.cpp:1479`) with a **separate
  weather revision** so re-sends don't restart a transition, and clients
  **periodically reassert** the authoritative profile before the vanilla
  random-preset interval can elapse (multiplayer.md §environment). Ours
  (WO-40) blends by profile name and broadcasts on change — between
  broadcasts, a joiner's vanilla weather randomizer can drift it. **WO-F
  (small): add a periodic weather reassert** on receivers (re-apply the
  last-received profile with blend 0 every few minutes unless a newer 0x2E
  arrived), and record `cheat_set_weather` (already noted in WO-40:197) as the
  numeric-preset alternative if profile-name blending ever proves lossy.

---

## Cross-cutting discovery — libKCD2 + Address Library (evaluate once, separately)

Their entire native layer stands on two pinned vendor submodules:
[F02K/libKCD2](https://github.com/F02K/libKCD2) (typed engine headers —
`C_Actor`, `C_Soul`, `C_Human`, `C_Inventory`, `C_CombatSoul::DealDamage`,
`C_CombatActor::SetOpponent`, `RequestLocomotion`, IEntity/IActorSystem vtable
tables) and F02K/Address-Library-For-KCSE (per-build address tables with
audit tooling, Steam/GOG/Epic). We hand-derive RVAs per WO (WO-42/44/45…).
Adopting libKCD2 as a reference (or dependency) for KCDMP.dll could replace
per-WO disassembly with typed lookups — but it targets game 1.5/KCSE and its
own license/build-pinning need checking first. **WO-G (evaluation, half a
session): clone libKCD2, check license + build compatibility with our
installed game version, and diff three offsets we already know (e.g.
QueueAction RVA, C_Player::PlayAnim, GetOrCreateCombatActor) against its
tables.** If they match, future native WOs get dramatically cheaper.

---

## Prioritized summary — what to bring in, in order

| # | WO | What | Size | Why this order |
|---|----|------|------|----------------|
| 1 | WO-A | Ghost civic isolation: `Contexts.SetPersistentOption` (7 switches incl. `crime_disableReport`) + `RestrictDialog` + `InterruptDialogs`, behind `mp_ghost_isolate` | Small, Lua-only | Directly kills a shipped, user-visible defect (ghost = crime victim, WO-31), near-zero risk, verifiable in one live session |
| 2 | WO-D | Relay claim-update plausibility gates (40 m/s speed cap, rotation validation) + reserved-name rejection | Small, relay + tests | Pure hardening of WO-60's shipped system; wire-testable without a game |
| 3 | WO-G | libKCD2/Address-Library evaluation (license, build match, 3-offset diff) | Half-session | Multiplies the value of every future native WO; zero product risk |
| 4 | WO-B | Ghost nameplates via Soul display-name CryString (verify offset on our build first; their 0x3E8 is the candidate) | Small, native | High-visibility polish; needs offset verification before the write |
| 5 | WO-E | **Pilot**: puppet brain suppression via `IEntity::Activate(false)`, default-off toggle, saved-state restore | Medium, native, live-verify required | The one mechanism of theirs genuinely ahead of ours; attacks WO-51's core gap; flagged as a deliberate pilot, not a reflexive port |
| 6 | WO-F | Weather periodic reassert on receivers (idempotent re-apply, revision-split) | Small, Lua + agent | Closes a real drift window; low urgency |
| — | — | Not adopted: native avatar backend migration, dedicated game-simulating server, nearest-player lease, shared containers, item ledger, server-side aggro | — | Reasons in each phase above |
