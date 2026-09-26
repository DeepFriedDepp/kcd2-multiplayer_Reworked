# WO-125: continuity (per-world Henry files)

Session 2026-09-25/26. Solo, one machine, Modding Tools build 1.5.5. The real
game is the **joiner**; a synthetic WO-125 host (`tools/wo118/synthpeer
--join-host125`) serves **copies** of real host saves through a local relay and
is driven by a control file (save / reload / world switch / leave). One short
run had the real game as the **host** with WO-123's synthetic joiner (§9).
Progress, method and side effects: `docs/WO-125-progress.md`. Updated runbook:
`docs/WO-124-first-shared-world-runbook.md`. Settled rules:
`docs/DECISIONS-coop-design.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (save-verified:
decoded from real saves on this machine, nothing committed) / (inconclusive).
Saves are named `playlineN/file`; worlds are "world A/B/C" (the store keys them
by a hash of the seed; no seed value appears here). **Dormant:** nothing runs
unless the HOST runs a shared world. No installer, no VERSION bump, **no
protocol bump, no new message type** (still v9, next free type 0x58).

---

## 0. Answer first

| # | test | result | evidence |
|---|---|---|---|
| 1 | first join, no Henry file → the launcher asks → Bring → join | asked before any request (host never paused); `POST /join-choice` → request → Ready 54.6 s; the join save's pair stored at Ready; first host save → a paired snapshot | observed |
| 2 | first join → Start fresh | Henry from a new game's first Henry save on this machine; live = that file (GetMoney 1403 = the file's money item 14030, 1 inventory entry, stats 5, skills 5); Henry check matched it | observed |
| 3 | host saves ×2, gains between, quit, rejoin | pair 1 and pair 2 stored; 1 apple gained before save 2 (kept), 2 pears after it (gone): rejoin = pair 2, not the quit moment | observed |
| 4 | host loaded an older save while the joiner was away, then saved | rejoin picked the pair of that older save ("branch save #1", matched by md5) | observed (synthetic host) |
| 5 | host reload mid-session | "Your host is reloading…" → rejoin from inside the world → Henry rewound to the loaded save's pair (the apple gone) → in-world load 11.7 s → Ready; host paused 12 s | observed |
| 6 | a second world | first join there (Start fresh); world A's 6 Henry files byte-identical before/after | observed |
| 7 | back to the first world | its Henry restored; the engine's next snapshot differs only in fields that move with play time (§3.3) | observed |
| 8 | non-Henry host world / non-Henry source save | joiner told, **no request sent** (host never paused); a Godwin save is skipped as the Bring source | observed (a prologue save stood in; see §7) |
| 9 | a leaked shared-world save in the playline | console QuickSave while joined → ledgered, moved out at once; Continue = the joiner's own save | observed |
| 10 | a hand-placed copy of the host's world, newest by save time | not used for Bring (next different-seed save is), not moved, one warning; explicit `mp_join_henry` of it refused with a message | observed |
| 11 | same copy, host leaves | leave route loaded the joiner's own save, not the copy (copy hash unchanged) | observed |
| 12 | no own save, host leaves | an empty listed file fails its load → main menu + "Game load failed / OK"; launcher explains; file moved out | observed (no-own-save forced by `KCDMP_TEST_NO_OWN_SAVE=1`) |
| 13 | `mp_henry_reset`, `mp_henry_files` list/delete, 90-day rule | all as specified; 90-day rule on a copy of the store with a synthetic clock | observed |
| 14 | host `mp_shared_world off` | nothing asked, no identity used, no lock | observed |

Gates: 23 Lua suites (1,641 checks; WO-125: 38), both static Lua checks, 291
client tests (24 new), 42 relay, 59 Farkle, native, launcher and synthpeer
builds: green.

Found live and fixed: five defects (§8), three of them in WO-124 code that
only showed with continuity (quit and rejoin with the agent still running,
host world switches).

---

## 1. Phase 0: where a Henry snapshot comes from

### 1.1 Route A chosen: a QuickSave of the joiner's copy

| question | answer | evidence |
|---|---|---|
| does it pass the joiner's lock | yes, by design: `InitiateSaveGame` skips the script-lock check for the QuickSave type and only asks `CanSave(3)` (non-script locks) | code-verified (Framework 0xEF8C0, 0xEFDE0); observed |
| name and place | `quicksaveNNN.whs` in the **current playline** (= where the join placed its file). NNN = highest `SaveId` among quicksave descriptions in the engine's cached list + 1 (023 in the joiner's own world; 039 while the transient mpworld file with the host's header "quicksave 38" was listed; a planted `quicksave040` whose header says id 22 was not touched) | observed |
| aimed at a mod-owned name | no. `InitiateSaveGame(type, overwriteSaveId, questNameOverride)`: the text is the quest name shown in the UI; file names are fixed by type | code-verified |
| hitch | 470, 463 ms (frame-gap window, early game, 1.43 MB file) | observed |
| timing | host save seen → QuickSave requested 0.18–0.21 s → file verified 1.53–1.55 s | observed ×4 |
| crash window | from the file landing to its move-out, ~1.6 s. A pending ledger entry is written **before** the request; the next agent start moves out a save that landed in that playline within 2 min of it (seed = the world's). A stale transient left by a race was moved out at the next start (observed) | observed / code-verified |
| Continue before the move-out | picks the snapshot (the leak is real); after move-out + rescan: the joiner's own save | observed |

**Route B (native read of the live Henry) rejected:** perks, map knowledge,
statistics and tutorials have no live read (WO-112 §2.1), so it cannot
round-trip byte-exactly. Route A goes through the proven splicer by
construction.

### 1.2 The Henry block

* `WhsSave.PartsFromStream`: the `player_henry` record, the six Henry side
  blocks, the key-binding entries naming one of this Henry's items. Serialized
  as `KCDMPHB1` + SHA-256 (format in `WhsSave.Wo125.cs`). **No save header, no world.**
  77–83 KB early game.
* Splicing a block = splicing the save it came from, **byte for byte**: on a
  real pair (host `quicksave038` copy + joiner `quicksave022` copy) the two
  outputs were identical (observed, local), and tested on synthetic saves.
* The splicer now also handles saves with no story stat (host or joiner) and a
  first Henry save with no stat list at all (inserted in key order). Python
  splicer unchanged; the C# one leads for these cases. (synthetic)

### 1.3 `wh_sys_FreezePlayline`

`wh_sys_FreezePlayline 1` blocks QuickSave too: "Saving is disabled by
(quick save is requested)", no file (observed). It would kill Route A. **Not
shipped.** Toggling it around each snapshot would reopen the same window the
ledger already covers.

### 1.4 In-world load of a placed file

A file placed and rescanned while in a world loads from there:
`Gameplay started` 8.3–11.7 s after the command, same level (observed ×4).
Phase 6 relies on this.

## 2. Phase 1: the store

* `<data>/henry/<worldTag>/snap-<utc>-<md5>-<source>.hblk` + `world.json`
  (last joined, log-only details). `<data>` = `KCDMP_DATA_DIR` or
  `%LOCALAPPDATA%\KCDMP`. The world tag is a hash of the seed; the seed itself
  is never stored. The index can always be rebuilt from the file names
  (tested with a corrupt `world.json`). (synthetic + observed)
* **Key = the host save's footer MD5**, the MD5 stored in the save's own
  `0XBP` footer (what `WhsSave.Verify` reads) — the one WorldSaved and
  WorldOffer carry. Not a whole-file MD5. The host computes the same value for
  a save it **loads** (observed: the loaded `autosave059` gave the md5 it was
  announced with when written, §9).
* Writes: `.part` → rename → read back (SHA-256 + full parse). A broken
  snapshot is skipped and the next older one used (synthetic).
* **Keep 100 per world**: the host's autosave rotation (100 slots per
  playline), the fastest-turning one at WO-122's 5-minute cadence, so every
  autosave the host can still load has its pair. Pruned oldest first
  (synthetic). Early-game snapshots are ~80 KB (8 MB per full world).

## 3. Phase 2 and Phase 5: identity, choice, "own", rejoin

### 3.1 On the wire (no version bump, no new type)

* **Session status (JoinStatus state 8)** now carries the host world's seed in
  the joinId slot (always 0 before) and flags in `arg`: seed known, Henry
  world. A WO-124 joiner ignores both. (observed on the synthetic and the real host)
* **State 9 `reloading`**: the host started a load. (observed)
* **Branch replay**: right before each WorldOffer the host replays its
  current branch (the save it loaded and every save since, newest last) as
  WorldSaved messages with kind bit `0x80` (`SenderUnixMs` = position, `Seq` =
  count). Same type, same exact length. (observed)
* JoinAbort 18–20 (`world-changed`, `not-henry`, `no-henry-source`) and
  reasons `not-henry`, `world-changed`, `reloading`, `no-henry-source`
  appended.
* Consequence: a WO-124 **host** never sends a seed, so a WO-125 joiner waits
  ("Waiting for your host…") — fail closed with mixed commits.

### 3.2 First join, restore

* No Henry file for the world: the launcher shows "Bring my character" /
  "Start fresh" (`/join-status` state `choose`; buttons `POST
  /join-choice?c=bring|fresh`). Console: `mp_join_henry auto|fresh|playlineN/file`.
  Nothing is requested until answered. An unavailable choice (e.g. a host
  copy) re-asks with the reason. (observed; the banner itself was not looked
  at, JSON + POST only)
* A Henry file exists: no question; the snapshot paired with the **newest
  save of the host's branch that has a pair** is restored; else the newest
  snapshot of the world. (observed: "paired with the host's newest save",
  "branch save #1")
* After Ready the join save pairs with the Henry just loaded (source
  `bring`/`fresh`/`join`), so a host reload to the join save rewinds correctly.

### 3.3 Byte round trip

Restore → load → the engine's next snapshot, clock frozen (observed twice:
Phase 0 probe and test 7). **Byte-identical:** perks, stat XP, every skill but
one, every non-food item, tutorials, journal UI, item list, key bindings. The
only differences, all time spent in the world between the two:

| field | change |
|---|---|
| states | hunger, exhaust, alcoholism tick (health, stamina exact) |
| skill XP | survival +640 (passive gain in ~15 s) |
| inventory | one freshness float per food item |
| buffs `0928`, statistics `352E` | timers / one counter |
| fog `7309/0001` | 5 cells explored at the arrival spot |
| renown `12FF` | one per-save u32 (the host's by design, replaced at every splice) |
| map knowledge `352D` | +163 duplicate POI records — **vanilla**: the game's own load→save adds them (`save021`→`quicksave022` too) |

A no-load baseline (two snapshots 7 s apart, ratio 0) shows the same ticking
set. Replaces WO-124's missing skills comparison.

### 3.4 "A save with the host's seed is never own"

Applied to: the Bring source, the leave route, the post-join Continue check,
explicit `mp_join_henry`. Each skip is logged (once per file per agent run).
The leave route also rescans and requires the target in the engine's cached
list (a save that appeared after launch would otherwise load nothing,
WO-112 §3.5). Files are never moved. (observed, tests 10/11)

### 3.5 No own save to leave to

An "exit file": the last received world's header over an empty stream (835–837
bytes, no world in it) is placed, rescanned and loaded; the engine fails the
load and returns to the **main menu** with "Game load failed / OK", from inside
a world (observed ×3). It cannot load as anything. The launcher says: "You
have no save of your own to go back to, so the game returns to the main menu.
It shows "Game load failed" -- press OK." Chosen over a quit: the player keeps
the game open and can Continue or pick a save. Fallback if the file cannot be
built: the player is told to quit.

## 4. Phase 3: Start fresh

* Source: **a new game's first Henry save on the joiner's own machine** — a
  save whose player is Henry and whose Henry holds no stat XP and no skill XP
  (KCD2 writes it as `permanent002` right after the prologue). Built at
  runtime, never committed; its seed must differ from the host's; never the
  host's Henry. Quest saves are tried first, oldest first. (observed)
* **Built from game data: refused.** A `player_henry` record with only the
  entity binding (so the engine's soul loader would fill it from the soul
  database) **fails to load**: "Exiting to main menu because save game loading
  failed" (observed). The real first save carries 19 perks and a full
  equipment block; faking those is out of reach here. Kept as a research CLI
  (`--save-tool splice-fresh`).
* No first Henry save on the machine: "Start fresh" re-asks with "Start fresh
  needs a new game's first save on this computer…".
* Report, fresh Henry vs the real first Henry save: **identical by
  construction** (it is that save's Henry). Live: stats 5/5/5/5, the ten
  skills read at 5, GetMoney 1403 (file money item 14030), one inventory entry (the
  money), no gear; 19 perks incl. the new game's codex entries; journal and
  quests are the host's world. No quest items (the strip found none); story
  progress stat = the host's (written by the splice). (observed + save-verified)

## 5. Phase 4: snapshots paired with host saves

* Every WorldSaved from the host while joined → snapshot → stored under that
  md5 → the QuickSave moved out → rescan → Continue checked (observed ×5).
* A snapshot is **not** stored when: it started over 3 s after the host's
  save arrived; it is not of the host's world (seed) or not Henry; the host is
  reloading; the player is not in the world; `mp_henry_reset` this session; a
  join is running; the engine refused the QuickSave (loss, logged).
* Guard: no snapshot into a playline with 95+ quicksaves (the engine rotates
  at 100 and could push out the player's oldest; code-inferred, not observed).
* Quit/crash: nothing extra; the launcher now says "Your progress in this
  world is saved up to your host's last save." (observed, every quit)
* **Pause-menu Quit hook: not done.** `C_UISaveLoad::ExitGame` → `CSystem::Quit`
  ends the process; holding it for a host save means hooking and delaying
  process exit. Not clean enough; the loss is bounded by the host's autosave.

## 6. Phase 6: a host reload takes the joiner along

* Host load starts → state 9 to every peer → the joiner keeps nothing from
  here; the host stays **silent** until `Gameplay started` (§8.4), then
  announces → the joiner asks for the world from inside its copy → WO-123's
  pause + transfer → restore of the pair of the loaded save → in-world load →
  step 0–4 → Ready. (observed, test 5)
* Another playthrough (other seed): the joiner leaves (own newest save), and
  once that load is in, joins the new world (first join or restore). A join
  still running when the host switches finishes first. (observed)
* New post-load **step 0**: the engine's `wh_sys_LastLoadedSave` must be the
  placed file; else leave. The Henry check cannot tell two worlds apart when
  the Henry is the same (a Bring restore = the player's own save's Henry).
  (observed: matched on every join after it was added; the case it guards against is the race in §8.3)

## 7. Phase 7: "is the player Henry"

* Save test: the soul whose `0x12F9` names the player entity `0x7777` is
  `player_henry` and no other. 188 Henry saves and 6 `player_bohuta` saves on
  this machine classify as expected: the prologue (`permanent001` of every
  playline, level kutnohorsko) and four 1.1.1 Godwin-stretch saves.
  (save-verified)
* Live: `player.soul:GetNameStringId()` = `char_26_uiName` for Henry
  (observed); Godwin's `char_BOHUTA_uiName` from the soul table (inconclusive
  live).
* Host in a non-Henry world: announced with the Henry flag off; the joiner
  never asks; a request that arrives anyway is refused **without pausing**;
  a host whose world is still unknown identifies it with a world save before
  pausing (observed on the real host, §9).
* Mid-session: the joiner is told "Your host is in a part of the story you
  can't share yet.", snapshots stop; no further behaviour (quest sync WO).
  Observed only through a host world switch into a non-Henry save.
* **The only non-Henry saves on this 1.5.5 machine are prologue saves.** The
  maintainer ruled them out for tests (the player is not Henry, so any Henry
  test on them is void); they were used here only as the refusal stand-in.
  The Godwin mid-game stretch was not reached on 1.5.5. (inconclusive)

## 8. Found live, fixed

1. **A ghost spawned at the main menu crashed the game** (WO-124 gap). On
   "game quit" the agent set its place to Unknown, which the menu gate does
   not hold; an agent kept across a restart pushed the ghost spawn into the
   new game at its menu (BugSplat; the reporter was closed without sending).
   A quit now leaves the gate closed until the next world. Re-run: 150+ pushes
   held, no crash. (observed)
2. **The joiner's lock failed after a restart** (WO-124 gap). The mod of a new
   process starts without the host's session mode and the agent only sent it
   on a change: `lock=failed`, join aborted. Every main-menu line re-tells it.
   Re-run: `lock=held`. (observed)
3. **A join raced the leave's own load.** After the host switched worlds, the
   join was asked during the leave's 4 s notice; both loads ran, the own save
   landed last, and the agent believed it was in the host's world. The
   snapshot's seed check caught it. No request while a leave is loading; step
   0 added. Re-run: leave → own world in → request. (observed)
4. **The host's periodic status named the world it was leaving** while it
   loaded, so a rewinding joiner rejoined the old world, and a world switch
   landed mid-join (two loads again). Hosts are silent while loading; a switch
   seen mid-join waits for the join to end. Re-run clean. (observed)
5. Leave target not in the engine's cached list: rescanned and checked now
   (hardening; the failure itself was not observed). One warning per host-seed
   copy per run instead of per lookup.

The machine running the session crashed once (unrelated to the game); work
resumed from the committed-to-disk state, playlines were checked clean.

## 9. The real game as host (short run)

Agent as host, WO-123's synthetic joiner (observed):

* `mp_shared_world on` with the world unknown → one world save
  (`autosave059`) identified it: world tag, player Henry, branch depth 1.
* Join: the join save became branch entry 2; branch replayed (2 saves) before
  the offer; Ready → resumed after 6.9 s.
* In-world load of `autosave059`: md5 computed = the md5 announced when it was
  written; the peer got `reloading`; no status during the load; the next
  status carried seed + Henry flags (`arg=3`).
* Load of a prologue save: Henry flag off (`arg=1`); a join request refused
  `not-henry`, no pause.

Not run on a real host: the host branch across agent restarts
(`host-branch.json`), a menu load on the host, the scheduled autosave with a
joiner present.

## 10. Carry-forwards

1. **Two real machines not run** (runbook updated).
2. **The matched pair has a ~1.5 s gap**: the host's save lands first, the
   joiner's QuickSave ~1.5 s later. Something gained inside that gap that the
   host's save still has in the world could be duplicated on a rewind to that
   save. Not observed; the 3 s gate bounds it. (inconclusive)
3. **Fallback "newest snapshot"** (the spec) when nothing on the host's branch
   has a pair can restore progress from an abandoned branch. The branch walk
   crosses host sessions (`host-branch.json`), which makes it rare. (code-verified)
4. The engine refusing a snapshot QuickSave (combat, cutscene) was not seen
   live; it costs that pair (loss).
5. Pause-menu Quit hook (§5), launcher buttons looked at only as JSON/POST,
   Godwin mid-game stretch (§7).
6. `KCDMP_TEST_NO_OWN_SAVE=1` exists for test 12 only (logged loudly when set).
