# WO-6 native dice — research findings

Investigation started 2026-07-28 against KCD2 v1.5.2 (or whatever's current at
session start), Modding Tools build, game running with a save loaded.
Following the methodology of `NATIVE-PLUGIN-findings.md`: proven / unverified
/ guessed, evidence per claim, negatives recorded.

---

## R0 — framework/dependency scout (timeboxed)

Searched Nexus Mods and GitHub for existing community native
frameworks/plugin-loaders/hooks that might expose the minigame or UI layer,
per the WO's "dependencies are encouraged" instruction.

| Candidate | What it is | License | Verdict |
|---|---|---|---|
| [`googleben/kcd2_rttr_dumper`](https://github.com/googleben/kcd2_rttr_dumper) | Offline tool that dumps RTTR type info from a live process or a full minidump into a pseudo-C++ listing (`out.cpp`, committed to the repo, ~57k lines) | **none set** (GitHub reports `license: null`) | **Not vendored** — no license to vendor under. Used read-only as a research reference (downloaded to local scratch space, not committed to this repo) to shortcut R1's surface-mapping. Author's own README admits it's "quick and dirty" and may miss or misreport properties (RTTR's `constexpr std::array` members defeat static offset recovery) — treat every claim sourced from it as **unverified** until confirmed live. |
| [`violetanvil/kcdx`](https://github.com/violetanvil/kcdx) | SKSE-style script extender: declarative function hooking, Address Library (name→address resolution), Lua+C++ parity, pub/sub messaging | GitHub license API returns `"other"/NOASSERTION` despite repo claiming MIT informally | **Declined.** General-purpose hooking/memory framework, still early (58/60 internal tests passing, some features unimplemented). This project already has a working, proven native plugin (`KCDMP.dll`: IAT hook, hand-modelled RTTR ABI, agent pipe) — adopting a third-party script-extender wholesale would mean a large rewrite for no capability this project doesn't already have. Its Address Library approach is worth remembering as a fallback idea *if* R3/R4 hit the "outbound problem" (an unexported function that needs hooking without a hand-recovered offset), but not adopted now. |
| [`JerryYOJ/KCSE-for-kcd2`](https://github.com/JerryYOJ/KCSE-for-kcd2), [`xiaoxiao921/KCD2ModLoader`](https://github.com/xiaoxiao921/KCD2ModLoader) | Similar script-extender / Lua-mod-loader frameworks | Unchecked | **Declined**, same reasoning as kcdx — general loaders, no minigame-specific capability, would replace a working mechanism rather than extend it. |
| [`souky-byte/kcd2-modding-docs`](https://github.com/souky-byte/kcd2-modding-docs) | Community modding documentation, 15+ mods analyzed | Per-repo, not unified | **Declined** — doesn't cover the dice minigame, GUI/Scaleform module, or minigame-adjacent RTTR types. Checked directly, not just by title. |

**Outcome: no dependency adopted.** Nothing found exposes the minigame or UI
layer more directly than probing it ourselves. The RTTR dumper's static
output is useful as an offline map to decide *where* to point live probes
(see below) but is not a substitute for them and is not part of this repo.

---

## R1 — mapping the reflected surface (read-only, in progress)

### Static lead: `wh::guimodule::C_UIDice`

From the (unlicensed, unvendored) RTTR dumper's static output, a real
reflected UI class exists:

```
class wh::guimodule::C_UIDice : class wh::guimodule::C_UIBase {
    ShowDiceScore( int, string const &, int, int, int, string const &, int, int, int, int, int, string const &, int, int );
    HideDiceScore( );
    ShowDiceProperties( string const &, int );
    HideDiceProperties( );
    SetCurrentPlayer( bool );
};
```

No properties recovered statically — only methods. `ShowDiceScore`'s 14
parameters are the strongest available clue about data shape before any live
game is observed: they look plausibly like (total, playerName, ..., some
per-die or per-player breakdown, ..., opponentName, ...) but this is a
**guess**, not yet confirmed against an actual screen.

Also present statically, evidence these are real registered rttr types (not
dumper noise): enums `DiceGameState` (`Inactive/Queued/Starting/InProgress`),
`DiceMinigameResult` (`None/PlayerWon/PlayerLost/PlayerLeft/GameInterrupted`),
`DiceResult`, `dice_minigameResult`, `dice_gameLevel`, `dice_betType`,
`dice_initDialogResultType`, `dice_badgeEffects`. These read like
flowgraph/UIAction node parameter enums (quest scripting glue), not
necessarily live queryable state — **unverified which, if either**.

A `wh::playermodule::I_Minigame` / `C_Minigame` base pair exists, with
**one** concrete subclass found statically: `C_Pickpocketing`. No
`C_Dice`/`C_DiceGame`/similar subclass was found anywhere in the static dump.
Either dice doesn't use this base (state machine is elsewhere, maybe pure
Lua/flowgraph), or the dumper missed it. Unresolved.

### Live confirmation via the debug REST API (`localhost:1403`)

Following `NATIVE-PLUGIN-findings.md`'s method exactly — walk the reflection
browser, always with `?depth=`.

- `GET /api?depth=1` — module roots include `GUIModule`/`gui`,
  `PlayerModule`/`player`, alongside the already-known `RPGModule`/`rpg`,
  `XGenAIModule`/`xgen`, `EntityModule`/`ent`.
- `GET /api/gui?depth=1` — `GUIModule.UIElements` is a live 31-element vector
  of singletons, index 22 is `C_UIDice` (confirmed by name match against
  `UIElementsByName`). Sibling elements include `C_UIPickpocketing`,
  `C_UIShop`, `C_UIShootingContest` — the game's other minigames follow the
  same one-singleton-per-minigame-type pattern.
- `GET /api/gui/UIElements/22?depth=2` — **`<C_UIDice />`, empty at depth 2.**
  Confirms the static finding live: **`C_UIDice` genuinely has zero
  reflected properties**, not a dumper gap. Same test against
  `C_UIPickpocketing` (index 26) — also empty at depth 2. This is a real
  pattern across this whole minigame-UI family, not specific to dice.
- `GET /api/player?depth=1` — `PlayerModule` exposes only
  `RandomEventManager` and `TutorialManager` as static singletons. No
  minigame instance reachable from this root while no game is in progress.

**Working conclusion (unverified until a live game is diffed against
this baseline): the dice minigame's C++/reflected surface is presentation-only
and one-directional (something pushes 14 values *into* `C_UIDice` via
`ShowDiceScore`; `C_UIDice` does not hold or expose game state for reflection
to pull back out).** If true, this is the same shape as the "outbound
problem" already solved for combat (`TakeDamage` not exported, solved by
sampling) — reflection alone may not find the logical dice values; whoever
*calls* `ShowDiceScore` holds them, and that caller is not yet located.

This is exactly why R1 needs the human playing: nothing reachable from a
static root shows what exists only while a game is active. **Next: snapshot
`gui/UIElements/22`, `player`, and the player's own soul record before
sitting, at the table, mid-roll, on the keep screen, on bank, and on win,
diffing each against this baseline**, per the WO's protocol.

### Live session, real game against "Dicer Filip" (beggar-level table)

Played two real games. `Save-DiceProbe` snapshots taken before sitting, mid
first game (gave up), before a second clean sit, seated (beggar-level table),
and mid-match with **known ground-truth scores (Player 600 banked, NPC 350
banked)** to search for.

**Negative result, confirmed with real known values, not just absence of
change:** none of `C_UIDice` (any depth, confirmed empty even at depth=4),
`PlayerModule` (depth=2), `PlayerSoul` (depth=2, `CombatSoul` subtree
included), or the module roots `ent`/`concept`/`db`/`dialog`/`behavior`/`xgen`
(depth=1) contain the literal values `600` or `350` anywhere, mid-match.
**Pull-based reflection genuinely cannot see the dice minigame's live state.**
Same shape as combat's already-solved outbound problem: something computes
the roll and pushes it into `C_UIDice::ShowDiceScore`; nothing reachable holds
it for us to read back.

**The opponent NPC ("Dicer Filip") could not be identified as a queryable
soul at all.** Proximity search down to 3 m of the player while actively
seated and playing found nothing but the player's own soul (internally named
`Dude` — this resolves the old "Dude decoy" note in
`NATIVE-PLUGIN-findings.md`: it is not a lookalike soul, it *is* the player's
own internal soul name in this build) and this project's own ghost-NPC
artifacts. Either Filip's `Position` does not update live during the scripted
dice interaction, or he is not tracked as a normal `SoulsByName` entry at all
during play. Unresolved; not blocking, since the roots above don't need his
identity.

**Environment correction mid-session:** the human had launched the game via
`KCDMP_launcher` rather than directly through the Modding Tools Steam entry.
This does not affect the debug REST API (built into the game itself,
independent of this mod's DLL) — every finding above is unaffected. It does
mean `KCDMP.dll`'s automatic injection hit the exact race condition already
documented in `VERIFICATION-REPORT.md` Track 1 (injected the instant
`WHGame.dll` was loadable, aborted with "0 frames in ~1s" before
`C_ModulesManager::Update` started ticking). Manually re-injected a fresh copy
into the same already-running, already-deep-in-session game process
(`native/build/KCDMP_retry2/KCDMP.dll` → pid confirmed from `tasklist`) —
succeeded immediately, pipe listening, sampler tracking souls. This is the
same fix already verified to work last session; the automatic-injection race
itself is still open (`PROJECT-STATE.md` §7, `VERIFICATION-REPORT.md` Track 1)
and out of scope here. The already-running agent process does not
auto-reconnect to the new pipe (`CombatPipe.EnsureConnectedAsync` only fires
once at agent startup) — not fixed, since nothing tonight needed the
agent-side pipe, only the DLL's own in-process RTTR access.

### A real lead: `wh::playermodule::C_Dice`, found by cross-checking exports against the RTTR dump

The static RTTR dump (R0) does **not** contain this class — direct evidence
of the dumper's own admitted incompleteness. Found instead by dumping
`PlayerModule.dll`'s export table (`dumpbin /exports`, MSVC tools located via
the same `vswhere` path `Build-Native.ps1` uses):

```
?SetPauseWorldTime@C_Dice@playermodule@wh@@QEAAX_N@Z
  = wh::playermodule::C_Dice::SetPauseWorldTime(bool)
```

This is the first hard evidence of a real game-logic controller class for
dice, distinct from the presentation-only `wh::guimodule::C_UIDice`, and
distinct from the `wh::playermodule::I_Minigame`/`C_Minigame` base pair (whose
only known concrete subclass, statically, is `C_Pickpocketing` — `C_Dice`
does not appear to derive from this base, or the dumper missed that too).

**What's still needed and what's blocking it, all checked before touching
anything risky:**

1. **Is `C_Dice` itself rttr-registered?** Not yet tested. Would need a
   `get_by_name("wh::playermodule::C_Dice")` + `is_valid` check from inside
   the now-live DLL — cheap, safe, reuses 100% already-proven infrastructure.
   Not yet done this session; next concrete step.
2. **Enumerating its methods/properties safely (no name-guessing) is
   possible in principle** — `CrySystem.dll` exports `type::get_methods()`
   and `type::get_properties()` (the enumerate-all calls, confirmed present
   via `dumpbin /exports`), not just the by-name lookups already modelled in
   `rttr_abi.h`. **But their return type, `rttr::array_range<T>`, has no ABI
   model yet** — unlike `variant`/`argument`/`instance` (each reverse
   engineered from real disassembly evidence, see `NATIVE-PLUGIN-findings.md`
   "Milestone 2"), `array_range` has **no exported constructor, destructor, or
   iteration methods** (checked directly — `dumpbin /exports` filtered for
   `array_range` shows only the various `get_methods`/`get_properties`/
   `get_types`/etc. producers, never a consumer). Its own member functions are
   template-inline, unrecoverable by export-table cross-referencing the way
   everything else in this ABI was. `dumpbin /disasm` cannot be scoped to one
   function's prologue the way a real disassembler (Ghidra/IDA) can, and this
   session doesn't have one — decoding `array_range`'s layout blind, the way
   `variant`'s 24-byte `{data[16], policy}` shape was recovered, needs that
   tooling. **Deferred, not abandoned** — this is real, bounded work for a
   session with proper disassembly tooling, not a dead end.
3. **No exported accessor reaches a live `C_Dice*` instance.** Checked
   `PlayerModule.dll`'s full export table for `GetActive*`/`GetCurrent*`/
   `GetInstance*`-shaped symbols near `C_Dice` or `C_Minigame` — none exist.
   `WHGame.dll`/`GUIModule.dll`/`EntityModule.dll` do not import
   `SetPauseWorldTime` via their IAT (checked with `dumpbin /imports`) — so
   the safe, already-proven IAT-hook technique (used for
   `C_ModulesManager::Update`) has no attachment point here. The only
   remaining route to a live instance is an inline detour on
   `SetPauseWorldTime`'s own exported address, which needs correct x86-64
   instruction-boundary handling to install safely (more invasive than any
   hook this project has done so far) — **not attempted tonight**, on the
   judgment that installing an unverified inline hook against the human's
   live, unbacked-up-for-this-specific-risk game session is not a call to
   make solo mid-session. Flagged for the R-gate discussion.

**Interim R2 status: a real controller class is identified by name, with a
confirmed-real exported method proving it exists in memory, but no safe path
to a live instance or to reading its state has been established yet.** This
is meaningfully more than "reflection sees nothing" (the R1 conclusion) — it
is "reflection sees nothing *from the roots tried so far*, and the object
that matters is real, named, and partially mapped, but reaching it needs
either proper disassembly tooling (for `array_range`) or an inline hook
(for `SetPauseWorldTime`) that deserves a deliberate go/no-go rather than
being attempted live and improvised.

### The `SetPauseWorldTime` hook: installed cleanly, never fired — a real negative result

With the human's explicit go-ahead, built and installed the inline detour
described above (`native/KCDMP/dice_hook.cpp`). Evidence gathered before
writing a single byte:

- `PlayerModule.dll` exports the target by name (no hardcoded offset — the
  address is resolved via `GetProcAddress` at runtime, same discipline as
  every other export used in this plugin).
- `dumpbin /disasm` of the first 13 bytes at that address showed four
  complete, self-contained instructions (`mov [rsp+8],rbx` / `push rdi` /
  `sub rsp,20h` / `mov rbx,rcx`) with no internal jumps or RIP-relative
  operands — a clean instruction-boundary hook site, stealable into a
  trampoline with no address fixup.
- A few instructions later the function does `mov byte ptr [rbx+0x650],dil`
  — independent confirmation `this` (captured in `rbx`) is a real, sizeable
  C++ object with at least one known field offset, not a thin wrapper.

**Installed against the human's live, actively-running game (pid confirmed
via `tasklist`). No crash, no instability** — `kcdmp-native.log`:
`DICE: hook installed at 0x...75732D40 (PlayerModule.dll+0x372D40)`.

**Then: zero captures across two real transitions that should plausibly
trigger a pause/unpause call** — finishing an in-progress game (won,
got up from the table) and starting a brand-new one (sat down again with the
hook already live and waiting). Neither produced a
`DICE: C_Dice instance captured` log line. This is a genuine negative result,
not a missed timing window — the hook was confirmed installed and live for
several minutes spanning both transitions.

**Reading of this result:** `wh::playermodule::C_Dice::SetPauseWorldTime`
almost certainly is **not** part of the ordinary "walk up to an NPC and
gamble" flow this project needs. It may exist for a different dice context
entirely — a scripted quest cutscene, a specific narrative dice sequence —
that never engages during ad-hoc NPC gambling. **This closes this specific
hook as a route to a live `C_Dice*` instance for the feature this WO actually
needs.** The class name and its one known field offset (`+0x650`, a bool)
remain true and recorded, but this was the only concrete lead R2 had toward a
live instance, and it did not pan out.

**R2 is now genuinely blocked** on the two remaining routes already
identified above (proper disassembly tooling for `array_range`, or finding a
*different* hookable call site that actually fires during ordinary NPC
gambling — the outbound-detection problem again, this time with no confirmed
call site at all). Recommend taking this to the R-gate rather than
continuing to improvise further hooks tonight.

### Ghidra brought in, `array_range<T>` recovered, and a clean, final negative on `C_Dice`

With the human's help (installed Ghidra 12.1.2 + a Temurin JDK 21, both from
official sources), ran headless auto-analysis
(`support/analyzeHeadless -analysisTimeoutPerFile`) against `CrySystem.dll`
(212 s) and wrote a Java `GhidraScript`
(`DumpArrayRangeFuncs.java`) to decompile every function whose name matched
`get_methods`/`get_properties`/`array_range`/`SetPauseWorldTime`. This is the
proper version of the technique this project already used for `variant`,
`argument` and `instance` — reading the ABI out of real disassembly instead
of guessing — just with a real disassembler instead of `dumpbin`.

**Result: `array_range<T>`'s layout is settled**, not guessed. Decompiling
`rttr::type::get_methods()`/`get_properties()` (both overloads) shows the
hidden sret buffer's first two 8-byte slots written directly as a raw
`{begin, end}` pointer pair into a contiguous array of 8-byte elements —
each element directly usable as a `Method::data` / `Property::data` value,
no extra indirection. Everything past offset 0x10 belongs to an embedded,
never-populated `default_predicate` functor (only relevant to the filtered
overload, which this project never calls). Implemented as
`kArrayRangeBufBytes` (96-byte over-allocated buffer, same rule as the
associative-view buffers) plus a plain begin/end read in
`rttr_abi.h`/`rttr_abi.cpp`, with `GetMethods`/`GetProperties` resolved by
exact-suffix export matching (`@2@XZ` selects the no-filter overload out of
each pair) and a new `probe_dice_class()` that asks rttr directly, by name,
for every method and property `wh::playermodule::C_Dice` has — no
name-guessing anywhere in this path.

**Result of actually running it, live, against the game: `is_valid` is
false.** `get_by_name("wh::playermodule::C_Dice")` resolves without
faulting, but the type is **not RTTR-registered at all**
(`kcdmp-native.log`: `DICECLS: wh::playermodule::C_Dice is NOT
rttr-registered`). This is a clean negative, not a bug in the new code — the
same shape of negative control this project already trusts elsewhere (a
deliberately-bogus type name resolving invalid is how `ABI: validate()`
proves the model isn't rubber-stamping garbage). `array_range` enumeration
itself was never exercised against a real populated result because there was
nothing to enumerate.

**This closes the entire reflection-based path for `C_Dice`, definitively.**
The class is real (proven by its one exported method) but was, deliberately
or incidentally, never registered with rttr — meaning no amount of further
`get_methods`/`get_properties`/`get_property_value` work can ever read it,
regardless of tooling. Combined with the `SetPauseWorldTime` hook never
firing during ordinary NPC gambling, the likeliest reading is that `C_Dice`
belongs to a **different dice context than the one this project needs** — a
scripted quest/narrative dice sequence (the `dice_gameLevel`/`dice_betType`/
`SpokeWithDicePlayers`/`DicePlayersAreDead`-shaped enums found earlier in the
static dump read like flowgraph glue for exactly that) — not the "walk up to
any NPC and gamble" interaction the mod needs to support.

**What Ghidra *did* deliver, and remains available for a future session:**
a working headless pipeline (Ghidra + Temurin JDK 21, both installed) that
can decompile arbitrary functions in any of these DLLs on demand. The next
useful move with it, if this thread is picked back up, is not more work on
`C_Dice` — it's finding what actually *does* run during ordinary NPC
gambling, by locating and decompiling whatever code calls the reflected
`C_UIDice::ShowDiceScore` (R1's presentation-only sink). That caller is the
real target; `C_Dice` was a plausible-looking lead that this session's
evidence now closes.

---

## R-gate: Tier verdict

**R2 (find the logical dice): exhausted for this session, without success.**
Every avenue tried — pull-based reflection across every reachable root
(R1), the one concrete hookable call site found (`SetPauseWorldTime`), and
full RTTR method/property enumeration once a real disassembler was
available — reached a clean negative. Read `docs/WO-6-native-dice-findings.md`
in full for the evidence trail; nothing here is a guess or an absence of
trying.

**Tier I and Tier II are unaffected and unblocked.** Neither depends on
reading the native minigame's state: Tier I is invite/accept/teleport
plumbing on the existing session framework, Tier II is a fully
relay-authoritative overlay match using WO-5's already-proven engine and
wire protocol, rendered by this mod's own code. Both can be built now.

**Tier III+ is not proven unreachable, but is not reachable by anything
tried this session.** The one live, evidence-backed idea for a next attempt
is decompiling the real caller of `C_UIDice::ShowDiceScore` (see above) with
the now-working Ghidra pipeline, rather than continuing to chase `C_Dice`.
That is genuinely open-ended reverse-engineering work, not a bounded task —
recommend treating Tier III+ as a distinct, separately-scoped follow-up
rather than a blocker for shipping Tier I/II.

**Human decision needed:** build Tier I/II now (this session or next), and
treat Tier III+ research as its own follow-up whenever there's appetite for
more reverse engineering — or keep pushing on `ShowDiceScore`'s caller
tonight. Per the WO's own instruction, stopping here rather than building
past Tier II without that decision.
