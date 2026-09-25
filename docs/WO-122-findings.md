# WO-122: shared-world foundations

Session 2026-09-25. Solo, one machine, Modding Tools build 1.5.5, a local
relay and a synthetic peer (`tools/wo118/synthpeer`) where a second player was
needed. Progress, method and side effects: `docs/WO-122-progress.md`.
Settled decisions: `docs/DECISIONS-coop-design.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
Paths are written as `<saves>`, `<install>`. **Nothing two-player. No
installer, no VERSION bump.** Only Phase 1 changes anything for players;
everything else sits behind `mp_shared_world`, default **off**.

---

## 0. Answer first

| phase | result | evidence |
|---|---|---|
| 1 owner death (ships ON) | a copy alive here while the owner streams it dead now dies; the corpse is moved onto the stream's spot; again after an in-process load; one-way | observed (synthetic peer) |
| 2 host-only saving (dormant) | named script lock `kcdmp_host_only`, read back, re-asserted after every load; autosave refused with no file; **Save & Quit and Save Game grey out under the lock** (no hang possible); refused autosave tells the player | observed; Schnapps, sleep, quest saves not run live (see §2.3) |
| 3 host autosave (dormant) | `mp_autosave_minutes` (default 5) through the engine's own autosave queue; every verified world save is announced as WorldSaved (0x46/0x47) and logged on the receiver | observed end to end |
| 4 world save on demand (dormant) | `mp_world_save` → the engine writes an ordinary `autosaveNNN` in the host's playline; the agent returns the file after verifying it; retries for 60 s | observed; read back by both readers |
| 5 save tools in C# | reader, verify, splicer, check (`KcdMpClient --save-tool`); 19 synthetic-fixture tests; cross-check vs Python on real saves | stream byte-identical; **file not byte-identical** (different zlib, §5.2) |
| 6 toggles, marker | `mp_shared_world`, `mp_owner_death`, `mp_autosave_minutes`, `mp_world_save`; both presets; `WO122-BUILD` | observed at the main menu |

Gates: 19 synthetic Lua suites, the two static Lua checks, 231 client tests,
38 relay tests: all green.

---

## 1. Phase 1: the owner's death wins

### 1.1 The cause of the 0.26.5 bug (code-verified)

* WO-86 kills a local copy only on a **witnessed** 0→1 dead bit on the
  stream. After a load, the stream has said "dead" all along: no transition,
  so nothing applies. A body dead on its **first** packet is "freeze only"
  on purpose (WO-86: a stranger's save must not kill a living NPC).
* The agent's per-name memory (`_npcLastDead`) survives a load, so even the
  host-authority resync route (`!nWasDead`) stays shut.

### 1.2 The fix

* The mod reads its own copy every puppet tick (and on a one-shot resync).
  Stream dead + local alive → `npc_owner_dead <npc> <x y z> <owner>`.
  Throttle: every 3 s for 5 tries, then every 20 s while the stream insists.
* The agent applies it through the WO-86 route (`ApplyDeath`, DLL),
  bypassing the 60 s dedupe (the mod just read the copy alive). **Joiner
  only:** a machine holding damage authority refuses (its world is the truth).
* The flip is marked remote before it lands, so it is never announced back.
* Once it reads dead, the corpse is `SetWorldPos`'d onto the stream's
  position and read back.
* One-way: a stream saying alive never touches a local corpse (the WO-86
  safeguard, unchanged).
* Toggle `mp_owner_death on|off`, default on; `mp_preset_legacy` = off.
  Also off with `mp_npc_deathsync off`.

### 1.3 Live, synthetic host (observed)

Synthetic host at id 0 streaming `ttkc_man_26` dead 3 m from where it stood;
the agent as joiner; throwaway `quicksave038`.

| step | log | read-back |
|---|---|---|
| first packet | old rule: `dead on its first packet here … freeze only`; new: `MP-OWNERDEATH request=1` | — |
| apply | agent `ApplyDeath applied`; mod `died here … applied from a peer via owner-death, not announced` | — |
| corpse | `corpse_to_stream_m=8.00 placed=true residual_m=0.00` | 5 s later: dead, hp 0, **1.50 m** from the stream's spot (the ragdoll slid) |
| requests | 1 in total | — |
| in-process load | chains restart ~8 s after `Gameplay started`; `request=1`, applied, corpse moved 5.98 m | dead, hp 0, **1.00 m** from the spot |
| one-way | host streams it **alive** 3 m away | `DIVERGENCE … corpse writes suppressed`; still dead, not moved; no request |

* After a load the copy stands alive for ~8 s: the WO-78 chain restart
  delay, not this code. (observed)
* The host's own "reload the world" case (the joiner reloads with the host)
  is not this path; it is the next WOs' join. (design)

---

## 2. Phase 2: only the host saves

### 2.1 The lock (code-verified, observed)

* `Game.AddSaveLock(name, text)` is a direct call of Framework
  `AddScriptSaveLock` (WHGame 0x18C990, code-verified). Named: it cannot
  collide with anything. **WO-113 shipped no save lock at all** (no
  `SaveLock` call in Lua, agent or DLL; code-verified), so nothing to
  reconcile.
* Read-back: a second add of the same name is refused by the engine. Each
  refusal logs `[Error] Script save lock 'kcdmp_host_only' already exists`
  (observed), so a held lock is re-checked only every 30 s on the tick (one
  add), and at once after a load.
* Held only while all of: `mp_shared_world on`, connected, role known,
  not the damage authority. Released on disconnect, on a role change and on
  `mp_shared_world off`. An agent killed while holding it leaves it until the
  next load; the next agent's first tick sweeps it (observed: `released
  why=agent-start remove=true`).

### 2.2 Load wipes, re-assert (observed)

* Without the agent: lock held → `wh_sys_LoadGame` → the first add succeeds
  again (`it was gone`), the second is refused (held).
* With the agent: the engine resets locks **when the load starts**; the
  agent's 1 s tick re-added it during the load, and the check on `Gameplay
  started` found it held. An autosave after the load: refused, no file.

### 2.3 Save types under the lock

| save | result | evidence |
|---|---|---|
| autosave (`Game.SaveGameViaResting` = `EnqueueAutoSave`) | refused, **no file**; kcd.log `[Error] AutoSave is disabled under a script lock 'Script:kcdmp_host_only'` | observed ×3 |
| control, lock released | `autosave039.whs` written | observed |
| pause menu **Save & Quit** | **greyed out** under the lock; enabled again with the lock released | observed (screenshots, control) |
| pause menu **Save Game** | greyed out; also greyed without the lock because Henry held no Schnapps | inconclusive |
| Saviour Schnapps | not run: RTTR `CreateItems` refuses the potion class silently (a pear works), and no UI input was sent while the machine was in use | inconclusive; WO-112 code: refused, potion kept |
| sleep | not run (needs a bed); the rest save goes through `EnqueueAutoSave`, refused above | code-verified |
| quest saves | not triggerable; Regular = autosave (refused above); Important = permanent (`Game.CreateSavepoint` is **not registered** in this build) | code-verified (WO-112 `CanSave`) |
| QuickSave | passes a script lock (WO-112); nothing in the mod calls it; in shipped data only a debug Haste trigger calls `Game.QuickSave()` | code-verified |

* **Save & Quit cannot hang:** the engine removes it from the menu under a
  script lock. The joiner's exit is the plain **Quit**. No mod change needed.
  (observed)
* Player message: on the first hold, "Co-op: The host saves this world."; on
  a refused autosave (agent sees the engine's line), "The host saves this
  world." at most once per 30 s. (observed)
* A save that still lands on a joiner is logged `MP-SAVELOCK LEAK` (the
  agent watches the saves folder with the toggle on). None seen.

---

## 3. Phase 3: the host's scheduled world save

* `Game.SaveGameViaResting()` is `EnqueueAutoSave(1, "")` (WHGame 0x18B7C0,
  code-verified): one queued autosave the engine writes when `CanSave`
  passes. Any engine lock (cutscene, skip, death, a quest's own lock) makes
  it wait or refuse.
* `mp_autosave_minutes <n>`, default **5**, 0 = none, 0..120. Why 5: early
  saves cost ~0.4 s of stall (below) and 1.4 MB; 5 min is the low end of
  WO-112's 5–10 proposal, so a host reload or crash loses at most 5 minutes
  of both players' work; 100 autosave slots per playline = 8 h at 5 min.
  The timer runs from the last world save of any kind (a sleep resets it).
* Every world save the host's game writes (any type) is seen in the saves
  folder, verified (footer + framing + a Henry record) and announced:
  WorldSaved `[seq][senderUnixMs][kind][playline][idx][md5]`. The relay
  forwards it **only from the damage authority**.

Observed (agent as host, synthetic joiner):

* `MP-WORLDSAVE saved playline1/autosave040.whs (autosave, 1434374 B, verify
  ok, engine generation_ms=32) -> WorldSaved seq=1`; verified 1.70 s after
  the request; the joiner printed it 3 ms after the stamp; the relay logged
  `[worldsave] … saved the world`.
* Receiver: the real agent as joiner logged `MP-WORLDSAVED in: host ghost 0
  saved playline1/autosave043.whs seq=… md5=…` and the mod the same.

### 3.1 The hitch (observed, early game only)

| window | max frame gap | frames / 8 s |
|---|---|---|
| no save (background-limited) | 45, 47 ms | 213 |
| no save (foreground) | 22 ms | 589 |
| world save | **434, 456** ms (background), **453** ms (foreground) | 203–556 |

* ≈ 0.43 s per save, early game (1.4 MB file, 4.4 MB stream). The engine's
  own `generation time` says 32–48 ms: it is only a part of the stall.
* **Late game: not measured.** No late-game 1.5.5 save of Henry exists on
  disk. The biggest 1.5.5 file (`playline2/permanent001`, 3.3 MB) is the
  prologue siege (not Henry), and its quest holds a save lock
  (`…posledniPomazani…bitevniCast.savelock86`): 12 requests were refused
  over 60 s and the retry gave up cleanly. (observed; the save was a copy,
  removed; the original is unchanged)

---

## 4. Phase 4: a world save on demand

* Route: the same `EnqueueAutoSave` → file lands → the agent verifies it
  (`WhsSave.Verify`) → returns `playlineN/autosaveNNN.whs`. Re-requested every
  5 s up to 12 times (60 s). (observed ×3; the refusal case observed ×12)
* **Name and place:** an ordinary `autosaveNNN.whs` in the host's current
  playline. File names are fixed by type in Framework (`autosave%03d`,
  `quicksave%03d`, `save%03d`, …; code-verified): no API takes a name.
  Autosave was chosen because it is a real save of the host's world in the
  host's playline, recognisable as "the newest autosave at join time",
  rotates with the host's own autosaves, and never takes one of the host's
  quicksave numbers.
* The engine logs the path itself: `Writing 4514935 bytes to file
  '%USER%/saves/playline1/autosave041.whs'` (no account name). The agent
  uses a folder watch; log lines name files as `playlineN/file`, never the
  absolute path.
* Read-back: `autosave040/041` verify in C# and in `Read-SaveAnatomy.py`
  (same MD5s); the C# inflated length equals the engine's "Writing N bytes"
  exactly. (observed)
* Console `mp_world_save` (host, `mp_shared_world on`). The join (next WO)
  calls the same request.

---

## 5. Phase 5: the save tools in the agent

`dotnet/KcdMp.Client/WhsSave.cs`, CLI `KcdMpClient --save-tool
verify|splice|check|inflate`. Same behaviour as the Python tools: TLV walk,
soul record, the WO-115 rules (key-binding merge, quest-class items stripped
by `IsQuestItem` class, the host's renown `0x12FF` and story stat 8, `0x1300`
carried), never overwrites an input or an existing file, refuses unverified
inputs and mixed builds.

### 5.1 Verify is stricter than the game

The game loads a file with a wrong MD5 (WO-115). `Verify` checks the footer,
that every block inflates to its stated length and the blocks end at the
footer, and that the soul list holds a full `player_henry`. All **230** saves
on disk verify. (observed)

### 5.2 Cross-check vs Python (local, never committed)

Pairs: WO-115's `quicksave027` + `save021`, and `quicksave035` +
`permanent014` (copies).

| check | result |
|---|---|
| both `check` PASS on their own output | yes |
| Python `check` on the C# file / C# `check` on the Python file | PASS / PASS |
| inflated stream, description header, block framing (137 blocks), footer tail | **byte-identical** |
| the files | **not byte-identical** (1,369,397 vs 1,370,793 B) |
| Python's `deflate()` over the C# stream | **= the Python file, byte for byte** |
| negative control (host given as the output) | both fail the same 15 checks |

* The only difference is the zlib encoder: CPython 3.14 ships zlib-ng 2.2.4
  (level 5); .NET 8 ships another zlib and has no level-5 setting. Byte
  identity of the compressed blocks is not reachable without shipping a zlib.
  The spec's "byte-identical output" holds for everything the splicer
  decides; the compressed bytes are the library's. (observed)
* The C# file is a different compression of the same stream as WO-115's
  loaded splice. Loading a C#-spliced file live: **not run**. (inconclusive)

### 5.3 Tests (synthetic)

`WhsSaveTests.cs` builds `.whs` files in code (no real save anywhere):
round trip, flipped MD5, a corrupt byte that still inflates (caught only by
the footer), lying block length under a valid footer, missing Henry,
truncation; TLV/replace/leaves; the splice (Henry fields, side blocks, key
merge, quest strip / host mode, equipped quest item refused, 0x1300), check
negatives, mixed builds, determinism, `IsQuestItem` parsing, CLI output.

---

## 6. Toggles and marker

| command | default | presets (clean / legacy) |
|---|---|---|
| `mp_shared_world on|off` | off | off / off |
| `mp_owner_death on|off` | on | on / off |
| `mp_autosave_minutes <0..120>` | 5 | 5 / 5 |
| `mp_world_save` | — | — |

`WO122-BUILD shared_world=off owner_death=on autosave_minutes=5
lock=kcdmp_host_only …` at init (observed). With `mp_shared_world` off:
no lock, no schedule, no folder watch, no WorldSaved (synthetic + observed).
The agent re-reads the toggles on every connect (a restarted agent kept
defaults otherwise; found and fixed live).

---

## 7. Carry-forwards

1. **Late-game hitch unmeasured** (§3.1). Needs a late 1.5.5 Henry save.
2. **Schnapps, sleep and quest saves not run live** under the lock (§2.3).
   Runbook in progress §5.
3. **A C#-spliced file has not been loaded live** (§5.2).
4. An agent crash (no restart) leaves the joiner locked until its next load
   or game restart. The next agent sweeps it.
5. Owner death assumes two players: with more joiners, any non-host's dead
   stream would also apply on a joiner (under host authority only the host
   streams NPCs, so this does not arise today).
6. WorldSaved `age_ms` includes the machines' clock skew (WO-98: seconds).
   The pairing WO should use `seq`/md5, not time.
