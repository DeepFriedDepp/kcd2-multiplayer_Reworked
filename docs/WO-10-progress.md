# WO-10 progress — weapon sync + injection liveness-check fix

Session date: 2026-07-31. Branch `main`. Two independent pieces of work,
both done and verified live against the real game. Full detail in
`docs/WO-10-weapon-sync.md` (Part A) and `docs/WO-10-injection-fix.md`
(Part B) — this file is the session log and the regression record.

**Status: both done, committed (`10ad471`), pushed, and human-visually
confirmed.** Beyond the automated `Test-AppearanceE2E.ps1` pass, the human
watched a live ghost cycle through 3 swords, an axe, a mace, a shield+sword
combo, and a crossbow (`tools/Bot-WeaponShowcase.ps1`, written for this
purpose) and confirmed every one rendered correctly before this was
committed. See "Post-commit: visual confirmation and a new finding" below
for what happened after the commit landed.

---

## Part A — weapon sync

Confirmed live before writing any code: `EquipmentManager.EquippedWeaponsByClassId`
has the identical shape to the armor map WO-9 already syncs, and
`EquipItem`/`UnequipItem`/`CreateItems` are item-class-agnostic — the exact
same calls that equip armor equip a weapon, proven by unequipping and
re-equipping a real weapon class on a live test ghost before touching
`GameBridge`.

**Design choice: extended the existing Appearance message (0x1A/0x1B)
rather than adding a sibling one, no protocol version bump.** The wire
payload was already "a list of ItemClass GUIDs" with no armor-specific
shape, and the receiver's diff/apply logic already had no category branch
anywhere in it. Only the outbound *read* changed (merge two REST maps
instead of one); `EquipItemOnGhostAsync`/`UnequipItemOnGhostAsync`/
`ApplyAppearanceAsync`/`VerifyAndRetryAsync` needed zero changes. Consequence:
no `tools\*.ps1` hardcoded `$PROTOCOL_VERSION` to hunt down — the exact trap
WO-9 hit does not apply here because there was nothing to bump.

**Checked the spawn-preset seeding trap proactively, not by screenshot
after the fact**: spawned a fresh ghost and read its `EquippedWeaponsByClassId`
immediately — confirmed it carries `sermiry_longSwordMenhart` from
`KCD2MP_SpawnGhost`'s `EquipWeaponPreset` call the moment it exists, the
exact shape of bug WO-9 found live for armor. Fixed the same way: added
that item class to `GameBridge.GhostSpawnPresetItems` before ever running
the E2E test.

**Verified end-to-end**, `tools\Test-AppearanceE2E.ps1` extended to push 4
armor classes + 1 real weapon class through a real relay + real running
agent + real game:

```
PASS - all 5 pushed item classes are equipped on the ghost
```

Agent log: `[appearance] ghost 2: +5 -10` — confirms the preset-seed fix
(10 preset items proposed for removal: 9 armor + 1 weapon, not the pre-fix
"only ever add" bug). No retry needed, first attempt.

**Open item, stated plainly**: whether a sheathed/two-handed weapon or a
torch in the off-hand slot has an exclusivity rule the way Hood-vs-Helmet
does for armor was not checked with a human watching the screen this
session (no one was watching during this pass). REST read-back confirms
the state changes correctly; whether it always *renders* is unconfirmed,
flagged for a session where the game is actually being watched.

## Part B — injection liveness-check fix

The bug (`docs/VERIFICATION-REPORT.md`): the native DLL sampled
`frame_count()` once after a 1-second sleep and permanently aborted if it
read 0 — which it reliably did on automatic/early injection, because
`WHGame.dll` loads almost instantly but the game's actual per-frame tick
doesn't start until well past the splash/menu, into a loaded save.

**Fix chosen: (i), make the native check poll.** `dllmain.cpp` now checks
`frame_count()` every 1s for up to 5 minutes instead of sampling once,
logging progress every 30s so a long wait doesn't look hung. Runs on its
own background thread (unchanged), so waiting costs nothing but time.

**A real complication found while fixing it, not after**: `KCDMP_launcher`
already added its own gameplay-signal gate in WO-7 (player clicks CONNECT
only after they can see and move their character) — close to option (ii)
already, but it doesn't close the race for direct/manual injection
(the dev workflow this very session's own verification used), and its
`VerifyInjectionAsync` regex-parses the exact native log line this fix
changed the wording of. **Updated `Home.razor.cs`'s regex in the same
commit** — caught before it could ship as a silent break (the launcher
would have timed out on every launch, since the old log format never gets
written anymore).

**Verified by real cold-start injection**, matching `VERIFICATION-REPORT.md`'s
own method: closed the running game, started a fresh process, injected the
instant it existed — well before any save loaded. The old code's exact
failure point (1s, 0 frames, permanent abort) was reproduced and survived:
the new code logged a 30-second progress line, then picked up the tick
becoming live 42 seconds after the hook installed, instead of having
aborted 41 seconds earlier. A second injection (fresh DLL copy, same
process, save now loaded) confirmed the full success path unchanged and
**not regressed**: `25 frames after ~1000 ms`, soul walk succeeded, and
`PIPE: listening on \\.\pipe\kcdmp` — both pieces of evidence the brief
asked for, both real log lines from a real run.

**Residual gap, honestly flagged, not fixed this session**: the soul walk
immediately after the liveness check has its own unrelated 5-second
timeout with no retry of its own, and can still fail if injection lands in
the narrow window where one sparse frame has ticked but a save hasn't
actually finished loading (observed directly in the first cold-start
injection above). Different mechanism, different fix, out of this WO's
scope (brief was specific: fix the `frame_count()` check). Left for
whoever picks this up next.

---

## Installer version

`VERSION` bumped `0.9.0` → `0.9.1`. Also found and worth recording: an
uncommitted `RELEASE-NOTES-0.8.5-Beta.md` in the working tree names the
WO-9 armor-sync release "0.8.5-Beta", which does not match the committed
`VERSION` history (`0.8.0` → `0.9.0` in `4fd2ff8`) or the existing
`release\KCDMP-Setup-0.8.5.exe` build on disk (no `-Beta` suffix, no
`0.9.0` build present despite the commit message claiming one was built).
**Not reconciled this session** — out of scope for this WO and not this
session's draft to rewrite; flagged here so a future session doesn't
silently pick one numbering scheme without knowing the other exists.
`0.9.1` is unambiguously newer than both `0.9.0` and `0.8.5` either way, so
it satisfies "distinguishable from 0.8.5-Beta in Add/Remove Programs"
regardless of which scheme is eventually treated as canonical.

`tools\Build-Installer.ps1` already threads a real version through from
the `VERSION` file (confirmed reading it, not assumed) — no script changes
needed. **`Build-Installer.ps1` was not run** this session, per the
brief's own instruction: building the release artifact is the human's
call once they're satisfied.

---

## Regression suite — run this session

| Suite | Result | Notes |
|---|---|---|
| `dotnet test KcdMp.Farkle.Tests` | **59/59 PASS** | headless, no game/relay |
| `Test-Combat.ps1` | **14/14 PASS** | relay only |
| `Test-Sessions.ps1` | **22/22 PASS** | timeout case skipped, as documented |
| `Test-Dice.ps1` | **9/10, 1 pre-existing flaky failure** | see below — not caused by this session |
| `Test-Pipe.ps1` | **PASS** | against the freshly-rebuilt DLL from Part B's own cold-start verification |
| `Test-InstallerDetect.ps1` | **21/21 PASS** | headless Steam-detection fixture, no built Setup.exe needed |
| `Test-Installer.ps1` | **not run** | needs a built `release\KCDMP-Setup-0.9.1.exe`; building it is deferred to the human (see above) |
| `Test-AppearanceE2E.ps1` | **PASS** | extended for weapons this session, see Part A |
| `dotnet build KCD2-MP.sln` | **0 errors**, same 8 pre-existing warnings | unrelated to this session (nullable/CA1416) |

**`Test-Dice.ps1`'s "seeded match reproduces the same result" sub-test
failed reproducibly, 3/3 runs**, with a different score mismatch each
time, while the "same outcome" (winner) assertion mostly passed. **Zero
dice/Farkle/relay-session files were touched this session** — confirmed
via `git status` before investigating — so this is pre-existing, not a
regression from Part A or B. Flagged as a separate background task
(`task_aad879a1`) rather than fixed here, since chasing it would be
scope creep on a WO about weapon sync and an injection race, and the
brief's own "no session-framework or unrelated engine changes" rule
applies.

**Protocol.Version was not bumped** (Part A's design choice), so there was
no `tools\*.ps1` hardcoded version to hunt down and update — confirmed by
grep, not assumed.

---

## Post-commit: visual confirmation and a new finding

After `Test-AppearanceE2E.ps1` passed headlessly, the human asked for a
visual check before trusting it enough to commit. Built
`tools/Bot-WeaponShowcase.ps1` for this: spawns a test ghost 3 m in front
of the player (`mp_spawn_test`) and cycles it through 7 real weapon states,
each held on screen for a configurable dwell so a human can actually look —
same idea as `Probe-Visual.ps1`'s dwell pattern, but driving the WO-9/WO-10
equip mechanism directly rather than a Scaleform/UI probe. Every item class
used was read live off the real player's own `Inventory` (`?depth=2`), not
guessed. **Human-confirmed, all 7 steps**: spawn preset sword, 2 more
swords, an axe, a mace, shield+sword simultaneously, and crossbow-only.
This is the visual-hiding edge case from `docs/WO-10-weapon-sync.md`
partially answered: shield+sword rendered correctly together, so the
Hood-vs-Helmet-style exclusivity does **not** reproduce for that
combination at least. Committed and pushed as part of `10ad471`.

**A new, unresolved anomaly found afterward, informally, not yet
investigated**: minutes after the showcase finished (ghost left in its
final "crossbow only" state, `_shieldKite_twitch_ and _huntingSword_`
unequipped, `_crossbowLightNormal01_` the only thing that should remain),
a REST read of the ghost's `EquippedWeaponsByClassId` showed
**`longswordHenry_reforged` back in the equipped map alongside the
crossbow** — a sword that had been unequipped several steps earlier and
never re-equipped by anything this session ran. Reproduced on a second
read minutes later; not a one-off blip. Two live possibilities, neither
confirmed:

- The game itself may auto-fill an empty melee weapon slot from whatever
  is sitting in the ghost's inventory once nothing occupies it — every
  `CreateItems` this session ever ran left an instance sitting in
  inventory even after being unequipped, so there was something for it to
  pick back up.
- Or an `UnequipItem` call earlier in the session silently did not
  actually take, and the read-back that "confirmed" the crossbow step
  never checked that the *previous* item was actually gone — only that
  the *new* target was present. (`Bot-WeaponShowcase.ps1`'s own
  `Show-Step` verifies additions landed; it does not separately verify
  removals did. `GameBridge.VerifyAndRetryAsync` in the shipped agent has
  the same asymmetry — it retries what should now be equipped, never
  confirms what should now be gone.)

**Not investigated further this session** — found while answering an
unrelated question after the commit, and root-causing it means the next
session, not a note appended after the fact. If it is the second
explanation, it is a real correctness gap in the shipped diff/verify
logic (a stale weapon could sit on a ghost indefinitely, wrongly believed
unequipped) and deserves priority. If it is the first, it may not be a
bug in this project's own code at all, and the shipped design (unequip
what's not wanted, rely on the next diff/heartbeat to correct anything
that drifts) may already be self-healing against it — untested either
way.

---

## Files touched this session

```
dotnet/KcdMp.Client/GameBridge.cs         weapon spawn-preset seed, doc comments
dotnet/KcdMp.Client/HttpGameTransport.cs  merge armor+weapon reads
dotnet/KcdMp.Client/IGameTransport.cs     doc comments
dotnet/KcdMp.Protocol/Protocol.cs         doc comments (no wire/version change)
tools/Test-AppearanceE2E.ps1              weapon coverage
native/KCDMP/dllmain.cpp                  liveness-check poll instead of sample-once
KCDMP_launcher/Pages/Home.razor.cs        VerifyInjectionAsync regex, matches new log wording
VERSION                                   0.9.0 -> 0.9.1
docs/WO-10-weapon-sync.md                 new
docs/WO-10-injection-fix.md               new
docs/WO-10-progress.md                    new (this file)
tools/Bot-WeaponShowcase.ps1              new -- visual confirmation tool, see "Post-commit" above
```

No session-framework, dice, or unrelated engine changes.

---

## Next session starts here

- **The unequip/reappearing-weapon anomaly** (see "Post-commit" above) —
  highest-priority pickup of the items below: a sword thought unequipped
  reappeared in the ghost's `EquippedWeaponsByClassId` unprompted. Not
  root-caused. Start by checking whether `VerifyAndRetryAsync`-style
  read-back-of-removals would have caught it, and whether it reproduces
  against a fresh ghost (this session's ghost had been through 7 equip/
  unequip cycles first, so heavy churn may be a factor — same shape as the
  DLL-injection-recency correlation WO-9 noted and never explained).
- **Weapon visual-hiding edge case** (sheathed/off-hand exclusivity) —
  partially answered post-commit: shield+sword rendered correctly
  together for one real human-confirmed case. Not exhaustively checked
  against every weapon pairing (e.g. two-handed weapons, crossbow +
  sidearm) — still needs a human watching the screen for anything beyond
  what was tried. See `docs/WO-10-weapon-sync.md`.
- **The soul-walk residual gap** in the injection path — a real, smaller
  version of the same shape of race, found but not fixed this session.
  See `docs/WO-10-injection-fix.md`.
- **`Test-Dice.ps1` seeded-reproducibility flakiness** — confirmed real,
  reproducible, pre-existing, flagged as `task_aad879a1`. Not weapon-sync
  or injection related; independent pickup.
- **`VERSION`/release-notes numbering mismatch** (`0.9.0` vs the
  uncommitted `0.8.5-Beta` release notes) — not reconciled, flagged above.
- Once the human is satisfied, `tools\Build-Installer.ps1` produces
  `release\KCDMP-Setup-0.9.1.exe` bundling armor sync (WO-9) + weapon sync
  + the injection fix (both WO-10) — not run automatically this session,
  per instruction.
