# WO-20 Phase 1 — real faces via `guidSharedSoulId`

Investigated and built 2026-08-04, live against this project's own Modding
Tools build, human watching the screen for every visual claim below.

Read `docs/WO-18-findings.md` §P1 first — that investigation's own retraction
discipline (`AppearanceApi.md` catching and correcting its own earlier wrong
finding) is exactly the standard this document tries to hold itself to below.
**Two of its own claims did not survive contact with this project's build**
and are corrected here, not silently adopted.

The appearance lever itself — binding a spawned NPC's `guidSharedSoulId`
spawn property to a real soul's GUID, which makes the engine build a full
distinct head+body+hair+beard automatically — is **Jefferson25625's find**
(`AppearanceApi.md`, `github.com/DeepFriedDepp/kcd2-exports`, used with
explicit permission, forked to `DeepFriedDepp/kcd2-exports` per that
permission). Everything below was independently confirmed against this
project's own build rather than trusted from their doc, per this project's
first rule.

---

## Correction #1 — the level-XML claim was too strong

WO-18 said `guidSharedSoulId` "appears in this machine's own shipped level
data," citing `dryingRack_cow/_common.lyr`. Checked directly: the attribute
is there, but **empty** (`guidSharedSoulId=""`). A full sweep of all 16,327
`.lyr` files across all three levels (`trosecko`, `kutnohorsko`, `klaster`)
for a *populated* `guidSharedSoulId` value found **zero**. The schema field
exists everywhere in the authored data; it is never actually given a value
in any shipped level file on this machine.

This doesn't kill the feature — the property still works as a *spawn-time
argument*, proven below — but it means the roster below could not be built
by mining level XML as planned. Real soul GUIDs came from the live
`SoulsByName` reflection API instead, the same way every other identity
question in this project has been settled (`NATIVE-PLUGIN-findings.md` §3).

## Correction #2 — their roster file was never actually committed

`AppearanceApi.md` references `KcdMP.Mod/Data/Scripts/kcdmp/soul_roster.lua`
(their curated 48-soul list) as an existing file. It does not exist anywhere
in the fork — confirmed by cloning it and searching for every `.lua` file
and every `guidSharedSoulId`/`roster` mention. This is the same pattern
WO-18 already found for their whole C# stack: described in prose, never
committed. So the roster in `kdcmp.lua` below is this project's own, not a
port of theirs.

---

## What was wired in

`kdcmp/Data/Scripts/Startup/kdcmp.lua`:

- **`KCD2MP.faceRoster`** — 24 male + 24 female real, hand-placed commoner
  souls (`SharedSoulGuid`, the authored cross-session-stable key per
  `NATIVE-PLUGIN-findings.md` §3), pulled live from this save's own
  `SoulsByName` and spread across settlements (`tbuk`, `tkop`, `tneb`,
  `tpod`, `tsem`, `tsla`, `ttac`, `ttkc`, `ttro`, `tvez`, `tvid`, `tzda`,
  `tzel`) for visual variety.
- **`KCD2MP_HashString(s)`** — deterministic djb2-style string hash, pure
  `+`/`*`/`%` arithmetic (no bitwise ops — this sandbox is stripped Lua 5.1,
  no `bit` library).
- **`KCD2MP_PickFaceForPlayer(nameKey)`** — hashes a name to a gender
  (`h % 2`) and an index within that gender's roster half, returning
  `{className, soulName, guid}`.
- **`KCD2MP_SpawnGhost`** — now computes `faceKey = KCD2MP.ghostNames[id] or
  ("Player" .. id)` (the same fallback string the nameplate itself already
  uses), picks a face from it, spawns with `ClassName = facePick.className`
  and `Properties.guidSharedSoulId = facePick.guid` instead of the old
  hardcoded `ClassName = "NPC"` with no soul binding, and logs the pick
  (`[KCD2-MP] face pick for '<id>': key=... class=... soul=... guid=...`).

### Why name, not connection id

The WO's own text allows hashing "the player's name or id." Checked which is
actually stable: `ClientSession.Id` (`dotnet/KcdMp.Server/Features/
ClientHandling/ClientSession.cs:28`) is `(byte)Interlocked.Increment(ref
_idCounter)` — a **connection-order counter**, different on every reconnect
for the same player. Hashing on it would violate "same face across
reconnects" by construction. The Steam name is the only stable identifier
available, so that's what's hashed, with the id-based fallback string used
only for the rare race window before a peer's Name(0x03) packet arrives
(see below).

### The name-arrival race, checked, not assumed

`BroadcastName`/`SendAllNamesTo` (`TcpBroadcastService.cs:43,122`) fire at
Handshake completion, before the server has ever seen a Position packet from
that client — so in practice a peer's name is already known to every other
ready client before any Ghost(0x02) packet for it is ever sent. The
1.5-second delayed nameplate apply already in `kdcmp.lua` exists as a
defensive measure against cross-connection scheduling jitter, not because
the ordering is normally violated. Not stress-tested under real network
latency (no second machine, same constraint every prior WO has stated); the
id-based fallback is the disclosed edge case if it ever is.

---

## Evidence a real face rendered — not just that the property was set

Confirmed the spawn call being fault-free is not sufficient (this project's
own standing rule) by checking three independent things, live, with the
human watching:

1. **The property is accepted without error.** `spawn.ok=true spawn.err=nil`
   in `kcd.log`, `Guid` in the readback populated (not the ghost's usual
   `SharedSoulGuid=00000000-...` /assigned-`Guid` pattern — a genuinely
   different, real soul identity resolved).
2. **A distinct face actually rendered on screen**, human-confirmed three
   separate times across this session: a standalone female test spawn
   (`ttkc_woman_6`), the real `KCD2MP_SpawnGhost` path picking
   `prepadeni_woman_1` for the key `Playertest_ghost`, and a bare-headed male
   test spawn (`tneb_man_11`, no helmet, so the face itself — not just
   armor — was checked directly).
3. **The same key reproduces the same soul.** `Bob` → `tvez_woman_3` (female,
   `NPC_Female`), independently confirmed byte-identical on a second spawn
   under a different connection id (`p_bob` then `p_bob2`) simulating a
   reconnect. `Alice` → `ttro_man_59` (male, `NPC`). Nine synthetic names
   probed directly against the hash (`Bob, Alice, Charlie, Dave, Eve, Frank,
   Grace, Heidi, Playertest_ghost`) landed on nine distinct roster slots with
   a healthy male/female split — see the float-precision trap below for why
   this needed a second pass to actually be true.

---

## A real bug found live: the mod's Lua numbers are 32-bit floats, not doubles

The first hash implementation used a `% 2147483647` modulus (the obvious
choice for a 32-bit hash). Live-probed against nine different names and
**seven of nine collided on the same roster slot** (`idx=1`), with the
remaining two landing on out-of-range indices (`idx=-7`, `idx=33`).
`tostring(h)` printed in scientific notation (`"1.93453e+08"`) with the low
digits already gone — this engine's embedded Lua uses **32-bit float**
numbers, not the standard 64-bit double, and float32 is only exact for
integers up to 2^24 (~16.7M). Every value above that in the hash chain was
silently corrupted, and `h % 2` (the gender split) flipped unpredictably as
a result.

**Fixed** by keeping every intermediate value under a 65521 modulus (largest
prime below 2^16), so `h * 33` tops out around 2.16M — safely inside
float32's exact range. Re-probed the same nine names live: nine distinct
integer `h` values, printed as plain integers, nine distinct roster picks,
correct male/female split. This is a durable, project-wide trap (any future
Lua code doing integer-ish arithmetic above ~16M is at risk the same way)
and worth carrying into `NATIVE-PLUGIN-findings.md`'s trap list if this mod
ever needs another hash or checksum in Lua.

---

## Regression: WO-9/WO-10 gear sync on a real-faced ghost — a real, disclosed limit found and partially fixed

Tested the actual WO-9 mechanism (`Inventory.CreateItems` + `EquipmentManager
.EquipItem`, not the cosmetic `EquipClothingPreset` Lua binding) against
soul-bound ghosts of both genders, with an unbound control on each class as
isolation:

| Spawn | Item tried | Result |
|---|---|---|
| Control, `NPC`, no soul bind | `BootsKnee03_m01_C` (male mesh) | equips correctly, alongside default outfit |
| Male soul-bound (`tbuk_man_5`) | same item | equips correctly, alongside his own authored default outfit |
| Female soul-bound (`ttkc_woman_6`) | same item | **fault-free (`ok=true`), but never renders** — `EquippedArmorsByClassId` shows her own default outfit, the male item never appears |
| Control, `NPC_Female`, no soul bind | same item | same — her own default outfit only, male item silently rejected |

**Root cause: this is a real, pre-existing engine gender-exclusivity rule on
item classes (`_m0X` mesh variants), not a bug in soul-binding.** It
reproduces identically on a plain `NPC_Female` control with no
`guidSharedSoulId` at all. **This project's real players are always the
game's single male protagonist, so every item WO-9's gear sync ever sends is
a `_m0X` male item class** — meaning gear sync structurally cannot render on
a female-faced ghost, for any player, permanently, not as a transient
convergence issue. Confirmed via `EquipItem` returning `true` with zero
effect, the exact "fault-free invoke is not a successful one" trap WO-9
itself documents.

**A real bug was found and fixed as part of confirming this**, not left
in: `KCD2MP_SpawnGhost` unconditionally called `EquipClothingPreset`/
`EquipWeaponPreset` with the all-male `white_red` preset regardless of
which class was spawned. On an `NPC_Female` entity this call is fault-free
but **actively destructive** — it doesn't just fail to add the preset's
items, it strips the soul's own authored default outfit too (confirmed:
before the fix, `EquippedArmorsByClassId` came back completely empty on a
female ghost, where an untouched `NPC_Female` control keeps her default
dress/shoes/cap fine). Human-visible as "wearing a plain white dress" — the
bare base layer with the Armor category empty. **Fixed**: the preset call is
now skipped entirely for `NPC_Female` spawns, so she keeps her own authored
outfit instead. Re-verified live after the fix: `EquippedArmorsByClassId`
now shows `F_Cap02`, `F_Shoes02`, `F_SimpleDress06` — her own outfit intact
— and the human confirmed on screen ("distinct face + proper outfit").

**The male path is unregressed**, confirmed live end to end: `Alice` (soul
`ttro_man_59`, `NPC` class) spawned with the full `white_red` preset intact,
and a fresh `EquipItem` call on top of it succeeded and rendered normally —
the exact mechanism WO-9/WO-10 rely on, unaffected by this WO's changes.

**What this means for the feature as shipped**: real faces work for both
genders. Real-time WO-9 gear sync (mirroring the *actual* player's equipped
items onto their ghost) only ever visibly renders for male-faced ghosts,
because the real player's items are always male item classes and the engine
rejects them cross-gender. A female-faced ghost keeps looking like her own
authored townswoman regardless of what the real player is wearing — not a
crash, not a silent failure mode invisible in testing, but a real, disclosed
gap between "this ghost has armor sync" (true, mechanically) and "this
ghost's armor visibly matches the real player" (false, for roughly half of
spawns by design of the 50/50 roster split). Not attempted to fix further
this session — a real fix would need a per-slot gender-equivalent item
mapping (e.g. male `BootsKnee03` → a female boot class), which is new scope,
not a regression to close.

---

## Gate, answered plainly

- **`guidSharedSoulId` confirmed as a real spawn-time property** on this
  project's own `XGenAIModule.SpawnEntity` call, not just present as a
  schema string — live, both genders, both the full production spawn path
  and isolated test spawns.
- **A real face rendered**, human-confirmed on screen three separate times,
  not inferred from a fault-free call.
- **Deterministic mapping confirmed correct**, after finding and fixing a
  real float-precision bug that would otherwise have collapsed almost every
  player onto the same face. Same name reproduces the same soul across a
  simulated reconnect (different connection id, same result).
- **Gear-sync regression tested honestly**: the male path (the only path a
  real player's gear can ever render through, since the game's protagonist
  is always male) is fully unregressed. The female path has a real,
  disclosed structural limit — pre-existing engine gender-exclusivity on
  item classes, not something introduced by this WO — and a real destructive
  bug found and fixed so a female-faced ghost degrades to her own authored
  outfit instead of going bare.

## Files touched

- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — face roster, hash, picker,
  `KCD2MP_SpawnGhost` wiring, the `NPC_Female` preset-skip fix.
- `tools/Test-Faces.ps1` — scratch probe used to settle the spawn-time
  property question live; kept as a reusable probe (same shape as
  `Probe-Reflection.ps1`/`Probe-AI-Behaviour.ps1`), not a formal E2E test.

## Not done this session

- No formal `Test-*E2E.ps1` regression script for faces (WO-9-style synthetic
  peer test) — this WO's own gate asked for human-watched live confirmation,
  which is what was done; a headless test would need to assert on
  `SoulsByName/.../Guid` matching the expected roster pick, which is
  straightforward to add later if wanted.
- The female gear-sync gap above is disclosed, not fixed.
- Real two-player test not attempted — one machine, no second player, the
  same constraint every prior WO in this project has stated honestly.
