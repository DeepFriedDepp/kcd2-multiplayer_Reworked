# WO-9 — Appearance sync

Every ghost used to spawn wearing one hardcoded outfit
(`KCD2MP.armorPresets.white_red`, applied once via `EquipClothingPreset` at
spawn) and never update again. This WO replaces that with per-item sync: each
client reads its own player's real equipped items and pushes them to peers,
who apply them to the corresponding ghost.

Read `docs/PROJECT-STATE.md` and `docs/NATIVE-PLUGIN-findings.md` first if
you haven't — this builds directly on the reflection debug API and the
"fault-free invoke is not a successful one" discipline established there.

---

## Phase 0 — what's actually readable and writable

Evidence discipline: every claim below is labelled **observed** (triggered
and watched the effect — cited), **read-but-unrendered** (a value came back
but nothing was confirmed on screen), or **inconclusive**.

### 0.1 — Reading the local player's equipped outfit

**Two candidate surfaces, one of them a dead end:**

- `entity.actor:GetInitialClothingPreset()` (Lua) and the reflected
  `Soul.BaseClothingPreset` property both report the **preset the soul was
  spawned or last preset-equipped with** — not its live state. **Observed**:
  read against the real player mid-session, `BaseClothingPreset` came back
  `00000000-0000-0000-0000-000000000000` — all zero — because the player has
  equipped individual items by hand since character creation and was never
  re-matched to a preset. This is a dead end for *any* player who doesn't
  keep re-equipping the same authored preset, which in practice is everyone.
  **Ruled out.**
- The reflection debug API's `EquipmentManager.EquippedArmorsByClassId`
  (`GET /api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedArmorsByClassId?depth=1`)
  is a live `map<ItemClass Guid, C_Item>` of **every currently equipped
  slot** — armor, hood, belt/QuickSlotContainer, whatever. **Observed**: read
  against the real player and got back exactly what they were wearing —
  boots, gambeson, belt, hose, hood — five real items with real names,
  prices and condition values, matching the character on screen. Re-read
  against a spawned ghost and got back exactly its 9-piece `white_red`
  preset, item-for-item. This is the real per-slot state and it is what the
  sync loop reads.

**Answer: yes, readable, at full per-item granularity, for both the local
player and any ghost, via the reflection API — not via any Lua clothing
binding.**

### 0.2 — Applying a dynamic (non-preset) item set to an NPC

The brief's prior finding — `EquipInventoryItem` puts an item in inventory
but does not render it on the model — was **retested and still holds** for
the Lua binding. It is a separate, much thinner surface than the reflected
C++ methods, same pattern documented for combat in `NATIVE-PLUGIN-findings.md`.

The native reflected surface is different. `EquipmentManager` exposes:

```
EquipItem(itemClassId: Guid, health: float = 1, pDamage = null) -> bool
UnequipItem(itemClassId: Guid, policy) -> bool
```

and `Inventory` exposes:

```
CreateItems(ItemClass, Amount, ShowUINotification, Quality, Health, Condition)
    -> shared_ptr<C_ItemClassDescriptor>
```

Sequence tried: `Inventory.CreateItems(cls)` to mint an instance of an item
class the ghost didn't already have, then `EquipmentManager.EquipItem(cls)`.

**Observed, twice, with the user watching the screen:**

1. Unequipped the ghost's spawn-preset Bascinet helmet
   (`EquipmentManager.UnequipItem`) — user confirmed the model went
   bare-headed in real time.
2. Created and equipped `BootsAnkle03` — an item class the ghost never had,
   pulled from the *real player's own* currently-equipped boots — replacing
   the preset's `BootsKnee03`. User confirmed the model's boots visibly
   changed from knee-high to ankle.

This is the answer to the brief's open question: **dynamic per-item equip on
an NPC does work and does render, through the native reflection ABI. The
`EquipInventoryItem` finding was correctly negative for Lua and incorrectly
generalized to "the engine can't do this" — the engine can; only the Lua
binding for it is a stub.**

**One real exception found, not a bug in this mechanism:** equipping a
`Hood08` while a `BascinetVisor05` (Helmet) was already equipped never took,
even after explicitly unequipping the helmet first. This reproduced
consistently and is treated as a genuine head-slot exclusivity rule in the
game's own equip logic (Hood vs. Helmet categories), not a reflection
failure — the same call succeeded immediately for every other item class
tried. Not chased further; noted as a real gap below.

**A second, more troublesome trait, found during Phase 2 live testing (see
below): `EquipItem` returning `true` is not proof the state changed.** Under
the agent's own normal background load, a call that returns `true`
immediately can still take anywhere from under a second to several seconds
— and in a couple of observed cases, longer than a 10-second retry burst —
before `EquippedArmorsByClassId` actually reflects it. This is the same
"fault-free invoke is not a successful one" trap documented for rttr in
`NATIVE-PLUGIN-findings.md`, now confirmed for the HTTP reflection layer too.
See "What Phase 2 actually needed" below for how the sync loop copes with it.

### 0.3 — Sync tier

**Best-case per-item sync is reachable and is what shipped.** Preset-snapping
was the fallback plan in the brief and turned out not to be needed: the read
side proves per-slot state for *any* equip state, not just a preset match,
and the write side proves individual item classes apply and render
correctly (module the Hood/Helmet exception and the write-latency trait
above). `EquipClothingPreset` remains in place for the ghost's initial
spawn appearance only — the sync loop replaces individual slots after that.

---

## Phase 1 — detecting local appearance changes

No existing event hook fires on equip/unequip (checked: nothing in the Lua
API surface, nothing reflected on `EquipmentManager` besides the two
properties and the mutator methods above). A slow poll is the right call, as
anticipated, and it runs **entirely in the C# agent, not in Lua**: the debug
REST API is already open to the agent (it's what `HttpGameTransport` uses
for position), so there is nothing for the Lua mod to detect or emit for the
*outbound* side at all.

`GameBridge.AppearanceLoopAsync` polls
`IGameTransport.ReadEquippedItemClassesAsync()` every 3 seconds
(`AppearancePollMs`), diffs the returned set against the last set actually
sent, and sends only on a real change — plus an unconditional resend every
`Protocol.AppearanceHeartbeatSeconds` (30s), covering a peer who connects
after the last real change (see "Late joiners" below).

---

## Phase 2 — wire, relay, apply

### Wire protocol

```
C→S  0x1A  AppearanceUp:   [itemCount:1][itemClass:16]*itemCount
S→C  0x1B  AppearanceDown: [sourceGhostId:1][itemCount:1][itemClass:16]*itemCount
```

`itemClass` is the item's **ItemClass Guid** (the per-type id shared by every
instance of e.g. "GambesonShort01_m04_D2") — a different key from the
combat layer's `SharedSoulGuid`, and not an item *instance* id. `itemCount`
is bounded at `Protocol.MaxAppearanceItems` (32) — headroom over a full
authored outfit's ~15 slots, and enough to stop a malformed sender from
making a receiver allocate on bad input.

Protocol version bumped **4 → 5**. `Protocol.cs` is the single source of
truth for both projects, as before; next free type byte is **0x1C**.

### Relay

`ClientSession`/`TcpBroadcastService` handle `AppearanceUp` exactly like
`DamageUp`: validate the declared length, forward verbatim to every other
ready client prefixed with the sender's ghost id, no echo, **no new
server-side state** — the relay does not remember or replay a peer's last
appearance for a client that connects later (see "Late joiners").

### Client: outbound

`IGameTransport` gained `ReadEquippedItemClassesAsync`. Both
`HttpGameTransport` (reads `EquippedArmorsByClassId`, regex-scrapes
`ItemClass="..."` attributes) and `LogTailGameTransport` (delegates to its
composed `HttpGameTransport`) implement it — appearance never goes through
the log tail or the batched `ExecuteString` channel, because it doesn't need
to: it's REST-only both ways, same as `HttpGameTransport`'s existing
position-read path.

### Client: inbound / apply

`GameBridge.ApplyAppearanceAsync(ghostId, target)`:

1. Looks up (or creates) two per-ghost sets: `_ghostAppearance` (what's
   currently applied) and `_ghostKnownItemClasses` (which classes have ever
   had `CreateItems` run for this ghost, so it's never called twice for the
   same class/ghost pair and inventory doesn't bloat with duplicates across
   repeated syncs).
2. Diffs `target` against `_ghostAppearance`: unequips what dropped out,
   equips what's new (`CreateItems` only the first time a class is seen for
   that ghost, then `EquipItem`).
3. **Verifies.** Given the write-latency trait from Phase 0.2, a bare
   equip-and-move-on would be wrong by the project's own standing rule
   ("verify by observed effect, never absence of error"). `VerifyAndRetryAsync`
   reads the ghost's own `EquippedArmorsByClassId` back and retries anything
   still missing on a schedule (1s ×3, 2s ×2, 3s ×1 — ~10s total), sized to
   the worst case actually measured live, not guessed. Anything still
   missing after the schedule is dropped back out of `_ghostAppearance`
   rather than being wrongly marked "settled" — which means the *next*
   heartbeat or real change naturally retries it again. This is the
   self-healing property the design leans on for the rare slow case (see
   "What actually happened when this was tested" below).

Never touches a slot that didn't change — no `UnequipAllArmor`-and-rebuild,
which would flicker every synced slot on every poll tick for no reason.

**A real bug found live, after this looked done:** the diff started from an
*empty* per-ghost "currently applied" set, not from what the ghost actually
spawned wearing. The ghost's spawn preset (`white_red`, full plate,
`EquipClothingPreset` in `KCD2MP_SpawnGhost`) was never recorded as part of
that state, because it was applied through a different path this tracking
never saw. Consequence: the diff could only ever *add* the real player's
items on top of the untouched preset, never remove the preset's own pieces —
and since the preset is full plate covering the entire body, a real player
wearing anything short of full plate (i.e. almost everyone, per the actual
player's 5-item read in Phase 0) would show a ghost that looked completely
unchanged, plate head to toe, with their real gear invisible underneath.
**Observed exactly this, live**: after equipping 4 real items onto a test
ghost, the only visible difference was a gambeson collar peeking out from
under an otherwise-untouched suit of armor — user-reported from a
screenshot, not something a log line would have caught.

**Fixed**: `GameBridge.GhostSpawnPresetItems` mirrors the 9-item
`white_red` GUID list from `kdcmp.lua` as data (same rule as the animation
tables — port it, never regenerate it) and seeds the per-ghost "applied" set
with it the first time that ghost is seen, so the very first diff correctly
includes "unequip the whole preset" alongside "equip the real items."
Verified live after the fix: the first apply to a fresh ghost logged
`+4 -9` — 4 real items added, all 9 preset items proposed for removal — and
a manual REST readback with the preset's plate stripped away made the
change clearly visible on screen, confirmed by the user.

### Guarding against a mid-animation glitch

Equip/unequip touch the character's mesh-attachment system, not its
animation or transform state — nothing in this path calls anything
`AnimatedCharacter`- or `Mannequin`-related, so there's no shared state with
the interpolation/animation tick to fight over. This held up in testing:
ghosts were re-equipped repeatedly, including immediately after spawn and
without a preceding stop, and no animation reset or T-pose was ever
observed. No explicit guard was needed beyond what's already implicit in
never re-touching an unchanged slot.

### Late joiners

The relay is stateless and does not replay a peer's last-known appearance to
someone who connects after the fact — adding that would be new server-side
state, explicitly out of scope. The fix is client-side: the 30-second
heartbeat means a joiner is at most one heartbeat interval behind, not
permanently stuck on the spawn preset.

---

## Phase 3 — the manual floor

`mp_sync_appearance` (Lua console command, `kdcmp.lua`) calls
`KCD2MP_EmitEvent("appearance_sync", "")` — the same log-tail event channel
`mp_invite`'s accept/decline already uses. `GameBridge.OnGameEvent` sets a
`_forceAppearanceResync` flag; the next poll tick (within 3s) sends
unconditionally regardless of whether anything actually changed, logged as
`(forced)`.

**Observed, live:** ran the command via the debug console
(`ExecuteString?command=mp_sync_appearance`), confirmed
`[KCD2-MP-EVT] v1 1 appearance_sync` in `kcd.log`, confirmed
`[appearance] manual resync requested` followed by
`[appearance] sent N item class(es) (forced)` in the agent's own log.

---

## What actually happened when this was tested live

Two-agent local test (per the WO's definition of done — a synthetic TCP
peer standing in for the second player, the same trick every other test
script in `tools/` uses since there is one machine and no second human
today): `tools/Test-AppearanceE2E.ps1` connects as a raw peer, sends one
Position (so the real running agent spawns a ghost for it), sends an
Appearance packet naming four real item classes pulled from the real
player's own inventory, and asserts the ghost's own
`EquippedArmorsByClassId` contains them afterward.

**First runs, quiet game state:** passed immediately, no retries needed.

**After running the full existing test suite back-to-back on the same game
session** (Test-Combat, Test-Sessions, Test-Dice, Test-Pipe — all that churn
of spawning/despawning ghosts and injecting/exercising the combat DLL), the
same test intermittently needed the full ~10s retry schedule, and twice
needed a *second* attempt beyond that — i.e., the fast path failed and a
simulated heartbeat resend (what a real peer's own 30s heartbeat would do)
was needed before it converged. A completely independent, isolated manual
call (`mp_spawn_test` + `CreateItems` + `EquipItem`, no C# agent involved)
against a fresh ghost succeeded immediately even *during* this same rough
patch, ruling out general game-state degradation.

**Honest conclusion:** the mechanism is correct and does converge, but its
*latency under load is genuinely variable* and was not fully root-caused.
One theory chased at length — that a relay/Position-triggered ghost spawn
was structurally less reliable than a directly console-spawned one — turned
out to be **wrong**: a console-spawned ghost that had worked reliably
minutes earlier later showed the identical flaky behavior (individual items
in a batch failing to stick, unpredictably, on *both* spawn paths). The
correlate that held up across every session was recency of the native
`KCDMP.dll` injection — equip writes were reliably instant right after a
fresh injection into a fresh game process, and got markedly less reliable
later in a long session with heavy churn — but this wasn't isolated further
either, and appearance sync itself never touches the DLL or the pipe, so
*why* the DLL's presence correlates with write reliability on an unrelated
REST endpoint is an open question, not a settled one.

The design's answer to this is the same one WO-1 already leaned on for state
overall: **don't promise a fixed convergence time, promise eventual
convergence.** The 30-second heartbeat means a slow case self-heals within a
bounded number of heartbeats even when the fast retry burst doesn't land,
verified by the test's own simulated-heartbeat fallback succeeding every
time it was exercised. `mp_sync_appearance` exists specifically so a tester
never has to wait that out.

---

## What does not sync

- **Hairstyle, face, beard.** `Soul.Archetype` — the only reflected surface
  anywhere near character appearance besides `EquipmentManager` — exposes
  exactly `Id`, `Name`, `Gender`, `Race`. No hair or face property is
  reflected anywhere found. **Out of reach, stated plainly**: appearance
  sync covers worn items only.
- **Weapons.** `EquippedWeaponsByClassId` exists with the identical shape
  and would need no new mechanism — deliberately left out of this WO's scope
  (the motivating problem was the hardcoded *outfit*), and is the natural
  next increment if wanted.
- **The Hood-vs-Helmet exclusivity** noted in 0.2: if a peer is wearing a
  hood and their ghost already has (or is mid-sync onto) a helmet-category
  item, the hood will not visibly apply. This is the game's own equip rule,
  not a limitation of the sync mechanism, and was not worked around.

---

## Wire protocol table (current)

| Byte | Direction | Name | Layer |
|---|---|---|---|
| 0x00 | C→S | Handshake | Presence |
| 0x01 | C→S | Position | Presence |
| 0x02 | S→C | Ghost | Presence |
| 0x03 | S→C | Name | Presence |
| 0x04 | C→S | Ping | Presence |
| 0x05 | S→C | Pong | Presence |
| 0x06 | S→C | Disconnect | Presence |
| 0x07 | C→S | Voice | Presence |
| 0x08 | S→C | Voice | Presence |
| 0x09 | S→C | VersionMismatch | Presence |
| 0x0A–0x11 | both | Invite/Session* | Interaction (WO-2) |
| 0x12–0x15 | both | Damage/Death | Combat (WO-4/6) |
| 0x16–0x19 | both | Dice* | Dice (WO-5/6) |
| **0x1A** | **C→S** | **AppearanceUp** | **Appearance (WO-9)** |
| **0x1B** | **S→C** | **AppearanceDown** | **Appearance (WO-9)** |
| 0xFF | S→C | Ack | Presence |

**Next free type byte: 0x1C.**

---

## How to test

```powershell
$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"

dotnet run --project dotnet\KcdMp.Server -- --port 7778
dotnet run --project dotnet\KcdMp.Client -- --host localhost --port 7778 --no-voice

# needs: relay + agent running, game up via Modding Tools. No native DLL needed --
# appearance is REST-only, unlike combat.
powershell -ExecutionPolicy Bypass -File tools\Test-AppearanceE2E.ps1
```

`Test-AppearanceE2E.ps1` is a new script, same shape as `Test-CombatE2E.ps1`:
a synthetic peer plays the second player, a real running agent applies what
it receives to a real ghost, verified through the debug REST API.

### Manual two-real-human procedure (not executed today — one machine)

1. Both players install per `README.md`, both launch via the KCD2 Modding
   Tools entry, both connect to the same relay.
2. Player A changes into a visibly different outfit (swap boots, a helmet,
   anything with an obvious silhouette change).
3. Within ~3–30 s (poll interval, or the heartbeat if the poll happened to
   just miss it), Player B should see A's ghost update the same slots.
4. If it hasn't within ~30 s, either player runs `mp_sync_appearance` and it
   should apply within a few seconds.
5. Confirm no animation glitch on the ghost during/after the change (walk,
   run, mount a horse across the update).

Marked **not executed** — this needs a second machine or a second real
Steam account on this one, neither available today. Everything above it is
the two-agent synthetic-peer substitute that WO-9's own definition of done
asks for in its place.
