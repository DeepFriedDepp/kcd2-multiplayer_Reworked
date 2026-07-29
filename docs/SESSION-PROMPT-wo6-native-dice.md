# Session prompt — WO-6: Native in-game dice

You are a senior engineer continuing an unofficial multiplayer mod for
*Kingdom Come: Deliverance II*. Repo
`DeepFriedDepp/kcd2-multiplayer_Reworked`, branch `main`. Dice (Farkle) works
end to end today — relay engine (59 tests), sessions (`Test-Dice.ps1` 10/10),
agent↔launcher IPC proven — but the UX lives in the launcher window. This WO
moves the experience in-game, and its centerpiece is a **research track into
the game's native dice minigame**, which has never been examined by anyone on
this project.

## Project scale and status — read before making any design trade-off

- **Target audience: 2–4 friends**, not a public server. Every design
  decision in this WO should be made for that scale. Do not add complexity
  whose only purpose is to resist a modified client belonging to one of the
  players themselves — see the trust model note below.
- **The original developer (marczukmichal) has given permission** to continue
  this work on the fork and to upstream it if it comes together, license or
  not. This is settled; do not re-litigate it or suggest contacting them
  again.
- **The fork will carry a GPL license going forward.** Handle this as a small
  administrative step in this session (see Phase 0.5) — it is not gated on
  anything else in this WO and should not consume research time.

## The goal, in fidelity tiers

The invite flow (Tier I) is required. The match presentation ships at the
**highest tier the research proves reachable**, with each lower tier as the
guaranteed fallback:

- **Tier I — in-game invite/accept/teleport** *(required, verified-tech)*:
  Player A near a dice table presses an invite hotkey; Player B gets a
  top-right in-game toast (custom-drawn is fine) with accept/decline hotkeys;
  on accept B is teleported to A (native position write); match begins when
  both are at the table. No launcher interaction anywhere.
- **Tier II — overlay match** *(required as the floor)*: full match on a
  DrawText/DrawLabel overlay driven by in-game keys. This must work even if
  every higher tier dead-ends.
- **Tier III — native on your turn**: on your own turn, the real minigame UI
  runs — you roll real physics dice at the real table. The DLL reads the
  logical result and reports it. Your opponent's turn renders on the overlay.
- **Tier IV — native both ways**: the minigame's logical dice values are
  forcible, so each client also *displays* the remote player's rolls
  natively. Both players see a native match end to end.
- **Tier V — the full scene**: a player-only dice table (spawned, not
  shared with NPCs) with the other player's ghost seated in the opponent
  chair, native animations both sides.

## Decisions already made — record these, do not relitigate

- **Trust model: roller-authoritative, and that's fine.** At Tier III+, the
  player whose turn it is rolls natively on their own machine; the DLL reads
  the result and reports it to the relay. This is the SPT/FIKA model. **No
  anti-cheat validation is required.** A player who edits their own client to
  win a friendly dice game has only cheated themselves out of a fair game
  with their friends — that's a social problem, not an engineering one, and
  this project is not building for adversarial strangers. The relay may keep
  light sanity checks (values in range, correct dice count) purely to catch
  **bugs**, not malice — treat any validation you add as a debugging aid, not
  a security boundary, and don't spend real effort hardening it.
- **Dependencies are encouraged.** Before building bespoke tooling, spend one
  timeboxed pass looking for existing community native
  frameworks/plugin-loaders/hooks for KCD2 (Nexus Mods, GitHub). If something
  solid exists that exposes the minigame or UI layer, prefer it: pin the
  version, vendor or submodule it, document the dependency and its license
  (check GPL compatibility — see Phase 0.5).
- **No headless game server.** KCD2 has no dedicated-server binary; the
  minigame's physics cannot run "elsewhere". The relay stays a relay.
  Roller-authoritative reads (above) are the mechanism that replaces this
  idea — do not resurrect it.
- **Custom toast is fine**; one timeboxed re-probe for a native notification
  surface, then build the DrawText toast regardless.
- **Teleport = native position write is fine.**

## Read first

1. `docs/PROJECT-STATE.md` — corrections to the original brief.
2. `docs/NATIVE-PLUGIN-findings.md` — the RTTR ABI, how reflected surfaces
   were mapped before, what is proven impossible. **The methodology in this
   doc is the template for the minigame research.**
3. `docs/HANDOFF-WO4-combat.md` — native plugin, main-thread marshalling,
   agent↔DLL pipe, traps.
4. `docs/WO-5-dice.md` — the dice architecture being extended; how
   `DiceState`/`DiceIntent` flow today.
5. Keybind discovery procedure (`KCD2MP.logActions = true` → press key →
   read `ACT` from `kcd.log`). Every hotkey here uses discovered action
   names.

## Phase 0.5 — licensing (small, do early, does not block research)

- Confirm with the human which GPL variant (2, 3, or LGPL) before adding it —
  do not assume.
- Add the `LICENSE` file to the fork root.
- Add a short `NOTICE` or README section: forked from
  `marczukmichal/kcd2-multiplayer` with permission to continue and upstream;
  original repo currently carries no license of its own — state that fact
  plainly rather than implying the upstream project is itself GPL.
- If Phase R's dependency scout (below) adopts any third-party code, check
  its license is GPL-compatible before vendoring; flag anything that isn't
  rather than silently including it.
- This is one commit, `WO-6: add GPL license and attribution`, done before or
  in parallel with everything else.

## Research protocol — the human is the instrument

The human is available and willing to **play as many real dice games against
NPCs as needed** while you observe. Structure every research phase as:

1. You prepare instrumentation (DLL sampling/dumping, logs tailed) and state
   exactly what the human should do, one step at a time ("sit at the table",
   "roll now", "keep the two fives, then pause on the keep screen").
2. The human acts; you capture.
3. You record findings — including negatives — in
   `docs/WO-6-native-dice-findings.md` as you go, with evidence, in the
   style of `NATIVE-PLUGIN-findings.md`.

**Back up the save before the first write-probe** (ask the human to do it and
confirm). Read-only phases first; writes only after the readable surface is
mapped.

## Phase R — the research expedition (gates everything above Tier II)

- **R0 — framework scout** *(timeboxed)*: the dependency search described
  above. Outcome: adopt/decline note, license-checked.
- **R1 — map the minigame's reflected surface** *(read-only)*: while the
  human plays real NPC dice games, dump the GUI/minigame-adjacent reflected
  types: registered types, properties, methods, live instances. Diff
  snapshots across game states — before sitting, at the table, mid-roll,
  on the keep screen, on bank, on win — to find which objects appear and
  which fields change. The deliverable is the first-ever map of this
  surface: what exists, what's readable, with evidence per claim.
- **R2 — find the logical dice** *(read-only)*: locate where the six dice
  values, keep flags, turn totals, and scores live. Prove it by prediction:
  read the values mid-game and have the human confirm they match the screen,
  across at least three games (remember the "Dude" soul lesson — verify
  you're reading the real instance, not a lookalike). If dice values are
  only ever visual/physics-derived with no separable logical layer, that is
  a major finding — record it; it caps the ceiling at Tier III.
- **R3 — start/drive probes** *(writes; save backed up)*: can the minigame
  be started by reflection without the normal NPC interaction? Can a roll be
  triggered? Can a keep/bank be submitted? Can a logical die value be
  **written** before or after the physical roll settles, and does the UI
  honor it? Each probe: observed effect or it didn't happen; invalid rttr
  variants are silent — check `variant::is_valid`; never pass borrowed refs
  to by-value resource-owning params (this crashed the game once already).
- **R4 — the opponent seat and player-only tables** *(writes)*: does the
  minigame require a live NPC opponent soul? Can the ghost occupy the
  opponent seat (it's a real NPC soul — `Mount()` already works on it)? Can
  a dice table be spawned via the proven entity-spawn path, and does a
  spawned table carry the gambling interaction? Does the opponent's "AI
  turn" stall if the opponent never acts, and is that stall recoverable?
- **R-gate:** write `docs/WO-6-native-dice-findings.md` §"Tier verdict":
  which tier the evidence supports, what each blocked tier would need, and a
  build plan for the reachable one. **Stop and present this to the human
  before building past Tier II.** The human decides how deep to go.

## Phase 1 — Tier I build (can proceed in parallel with R, it's independent)

- Invite hotkey + dice-table proximity: probe how tables are identified
  (entity space near a known table via REST `?depth=0/1` through
  `tools\KcdApi.ps1`, or probed Lua entity queries — never invented ones).
  If tables aren't identifiable, "invite anywhere" behind a config flag,
  stated honestly. Invite goes through the existing session framework
  exactly as `mp_invite dice` does; the console command stays as fallback.
- Toast on B's screen (DrawText, self-rescheduling-timer + labelCache
  patterns, auto-expiring, shows inviter + key hints); accept/decline via
  discovered actions (target the user's suggested 9/0 if the action map
  allows; document what was actually achievable).
- Teleport on accept: new agent→DLL pipe command (verify next free opcode
  from code; last known: `0x01`–`0x03` down, `0x81/0x83/0x90` up). Target =
  A's ghost position from the presence stream — no new relay packets unless
  you can justify why. Probe teleport failure modes first (mounted,
  dialogue, combat) and refuse/defer with a toast in the bad states.

## Phase 2 — Tier II build (the floor)

Overlay match rendering + in-game intent keys, exactly as WO-5's engine and
packets expect: dice, keep selection, totals, turn banner, bust/win.
Agent pushes `DiceState` into a Lua-side table over the existing WO-1
transport (state the per-update cost; at 2–4 players it should be trivially
within budget). Launcher window remains as a debug mirror. All existing
suites stay green.

## Phase 3 — build the verdict tier

Implement whatever the R-gate approved.

- Wire changes (a `RollResult` submission packet, etc.) get new type bytes
  from the verified next-free value, documented in the protocol table.
- The relay may run the Farkle engine as a lightweight sanity check on
  submitted rolls purely to catch bugs (per the trust-model decision above)
  — this is optional polish, not a requirement to gate the release on.
- Frame-consistency between two clients is best-effort, not a correctness
  requirement: the relay's state is truth; native visuals are presentation.
  If B's native rendering of A's roll proves flaky, degrade B's view to the
  overlay for remote turns (i.e., ship Tier III behavior) rather than chase
  perfect mirroring.
- Session framework and relay behaviour changes: stop and report first.

## Definition of done

- `docs/WO-6-native-dice-findings.md`: the complete minigame surface map,
  every probe with evidence, the tier verdict, and what each unreached tier
  would require. This document is a deliverable even if every write-probe
  fails — it converts "never examined" into knowledge either way.
- Tier I and Tier II working in-game, manual test procedure written
  (one-machine with synthetic far side, and two-machine variant), each
  clearly marked executed or not.
- Whatever tier shipped: suites green (`Test-Combat`, `Test-Sessions`,
  `Test-Dice`, `Test-Pipe` + teleport coverage), protocol/pipe tables and
  next-free notes updated.
- `LICENSE` and attribution committed (Phase 0.5).
- Scope/decision ledger updated: headless-server idea (closed, with reason),
  dependency adopted or declined and license-checked, table-menu injection
  still out.
- `docs/WO-6-progress.md` appended before session end; next session starts
  cold from it plus this prompt.

## Durable context

**Traps (all cost time before):** stale injected DLL keeps the pipe — test
rebuilt DLLs against a restarted game, check the pid line in
`native\build\KCDMP\kcdmp-native.log`; overlapped I/O on both pipe handles;
check write results, not absence of faults; invalid rttr variants are silent;
never pass borrowed refs to by-value resource-owning params; immediate
read-back is not verification for state the game re-derives; narrow catches
hide crashed background tasks; PowerShell case-insensitivity and `Object[]`
range indexing; `appsettings.Development.json` shadows the base file; REST
always with `?depth=` via `tools\KcdApi.ps1`; dice seed override is
Debug-only; running relay/agent locks build output.

**Environment:** game via the KCD2 Modding Tools Steam entry
(`D:\SteamLibrary\steamapps\common\KCD2Mod`) — discriminator is
`Framework.dll` + `CrySystem.dll` beside the exe;
`$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"`
before any `dotnet` command; MSVC via `native\Build-Native.ps1`; no Python;
one machine, one game copy, no second human *today* — Tier III+ two-client
behaviour is designed now, verified when a second machine exists, and marked
unverified until then.

## How I want you to work

1. Never invent an API — probe, run, read the result. The minigame surface
   is terra incognita; treat every assumption about it as false until
   observed.
2. Read-only before writes; save backed up before the first write-probe.
3. One instruction to the human at a time; you read the logs. The human will
   happily play dice for hours — use that, don't waste it.
4. Distinguish proven / unverified / guessed, in code and in findings.
5. Verify by observed effect, never absence of error.
6. Stop at the R-gate and present the tier verdict before building past
   Tier II.
7. Don't over-engineer for scale or hostile actors — this is 2–4 friends.
8. Be concise.
