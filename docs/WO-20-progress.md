# WO-20 progress — real faces (shipped) + aggro Lua binds re-test (investigated, not shipped)

Two independent phases, built and tested live 2026-08-04 against this
project's own Modding Tools build, human watching the screen for every
visual claim. `VERSION` not touched (still `0.10.0`); no release built —
another WO is expected to extend this work before anything ships. See
`VERSIONING.md` before touching that file.

Full detail lives in the two phase docs; this is the tying-together
progress doc, written to be read first by whichever session picks this up
next.

- `docs/WO-20-faces.md` — Phase 1, real faces. **Shipped, in `kdcmp.lua`,
  live-tested and human-confirmed.**
- `docs/WO-20-aggro-findings.md` — Phase 2, Lua `AI.*` aggro binds
  re-tested with a corrected method. **Investigated only — real findings,
  nothing shipped, because nothing tested produced observable NPC
  behavior.**

Both phases build on `docs/WO-18-findings.md`'s assessment of
`Jefferson25625/kcd2-exports` (forked to `DeepFriedDepp/kcd2-exports` under
explicit permission) — credited throughout both docs and in code comments
touching that material, same courtesy this project extends to marczukmichal.

---

## Phase 1 — real faces via `guidSharedSoulId`: shipped

Every ghost used to share one generic default face. Now each gets a real,
distinct head/body/hair, deterministically picked from a 48-soul roster
(24 male, 24 female — real, hand-placed commoner NPCs, `SharedSoulGuid`
pulled live from this project's own save) hashed from the player's Steam
name, stable across reconnects.

**What to know before extending this:**

- The roster lives in `kdcmp.lua` as `KCD2MP.faceRoster`. It was built from
  souls loaded in *one area* of *one save* (trosecko, around
  Troskovice/Semine/etc.) during this session — real and durable
  (`SharedSoulGuid` is authored, confirmed stable across restarts in
  `NATIVE-PLUGIN-findings.md`), but not sourced from a systematic sweep of
  all three levels. Widening the roster (more variety, or covering
  kutnohorsko/klaster) is a natural next step and does not require
  re-deriving the mechanism, just more `SoulsByName` lookups.
- **The open gap**: gear sync (WO-9/WO-10) cannot visibly render on a
  female-faced ghost. Not a bug in this WO's code — a real engine rule
  (male-only item mesh classes silently rejected on a female skeleton,
  reproduced on a plain unbound `NPC_Female` control) — but it does mean
  roughly half of ghosts (by the roster's 50/50 split) will never show the
  real player's actual equipped gear, only their own authored default
  outfit. **Disclosed, not fixed.** A real fix needs a per-slot
  gender-equivalent item mapping (e.g. a male boot class → a female boot
  class) — new scope, sketched but not started.
- A durable, project-wide trap was found and recorded in
  `PROJECT-STATE.md` §5: **this mod's embedded Lua uses 32-bit floats, not
  doubles.** Any future Lua arithmetic that produces values above ~16.7M
  will silently corrupt. Cost a full extra rebuild/relaunch cycle to find
  this session; check `WO-20-faces.md`'s writeup before writing another
  hash/checksum in Lua.
- `tools/Test-Faces.ps1` is a kept scratch probe (spawn-time
  `guidSharedSoulId` verification), not a formal E2E test. No
  `Test-FacesE2E.ps1` exists yet — would need to assert on
  `SoulsByName/.../Guid` matching the expected roster pick, straightforward
  to add if wanted.

## Phase 2 — Lua `AI.*` aggro binds: investigated, findings only

Re-tested `PROJECT-STATE.md` §4's "Lua `AI.*` — inert" verdict, using a
corrected method (real native addresses recovered via a Lua-closure walk —
new native capability, `native/KCDMP/lua_closure.{h,cpp}` — instead of a
guessed call signature). The verdict does not survive unchanged, but it
also isn't reversed:

- **Real, new capability found**: `AI.AddPersonallyHostile`/
  `IsPersonallyHostile` and `AI.SetAttentiontarget`/`AI.AddAggressiveTarget`
  write genuine, verified engine state on a real NPC — confirmed by
  independent getters, not fault-free returns. This project did not know
  this before this session.
- **Still confirmed inert**: `AI.SetFactionOf` (4 argument shapes tried) and
  `AI.CreateStimulusEvent` (5 shapes tried, including
  `CreateStimulusEventInRange`).
- **The load-bearing negative result**: none of it, alone or combined
  (tried all five binds plus `AI.Signal` together), made a real NPC
  actually move toward or attack a ghost. Writing the state is not
  sufficient to make the AI act on it. **A1 (floored-ghost recovery) and A2
  (one-sided combat) from `WO-16-release-candidate.md` remain open, exactly
  as they were before this session.**
- **The native faction-attach mechanism (WO-15/16/17's fixed `SetParent`)
  remains the only proven path to real aggro.** Nothing here replaces or
  simplifies it — the hoped-for safer Lua-level alternative to the
  ownership-fragile native call does not exist.

**What's now available for a future session, even though this one didn't
find the missing piece**: the closure-walk technique itself
(`tools/Probe-LuaClosure.ps1` + the native `0x05 ResolveLuaClosure` pipe
command) is a reusable, patch-resilient way to recover any Lua scriptbind's
real native address and confirm it isn't a stub, without guessing. If a
future session wants to push the disassembly further — following the
`pH->GetParam()` call sites inside `CreateStimulusEvent`/`SetFactionOf` to
recover their actual Lua-visible argument types, rather than just their
entry prologue — this is the tool to start from. Not attempted this session
because it's a materially larger task than reading 48 prologue bytes.

---

## What a next WO building on this should probably pick up

In the order they seem cheapest/most valuable, not a commitment:

1. **Widen the face roster** past the one save-area it was built from, and/or
   decide whether to weight the male/female split given the gear-sync gap
   (e.g. bias the hash toward male picks until a female gear fix exists).
2. **The female gear-sync gap** — either a per-slot gender-equivalent item
   map (real fix) or an explicit product decision to accept it (like this
   project already accepted one-sided aggro in WO-17).
3. **Push the `AI.CreateStimulusEvent`/`SetFactionOf` disassembly further**
   using `tools/Probe-LuaClosure.ps1` as the starting point, if aggro is
   still a priority — the entry-prologue read this session did is not the
   ceiling of what the technique can do, just as far as time went.
4. **A formal E2E test for faces** (`Test-FacesE2E.ps1`), same shape as
   `Test-AppearanceE2E.ps1`, if faces are going to keep changing.

## Files touched this session

- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — face roster, hash, picker,
  `KCD2MP_SpawnGhost` wiring, `NPC_Female` preset-skip fix (Phase 1)
- `kdcmp/Data/kdcmp.pak` — rebuilt
- `native/KCDMP/lua_closure.h`, `native/KCDMP/lua_closure.cpp` (new, Phase 2)
- `native/KCDMP/pipe_server.h`, `native/KCDMP/pipe_server.cpp`,
  `native/KCDMP/CMakeLists.txt` — `0x05 ResolveLuaClosure`/`0x84
  ClosureInfo` (Phase 2)
- `tools/Test-Faces.ps1` (new, Phase 1), `tools/Probe-LuaClosure.ps1` (new,
  Phase 2)
- `docs/PROJECT-STATE.md` — §4 (aggro) amended, §5 (traps) got the Lua
  float32 entry
- `docs/WO-20-faces.md`, `docs/WO-20-aggro-findings.md`, this file (new)
