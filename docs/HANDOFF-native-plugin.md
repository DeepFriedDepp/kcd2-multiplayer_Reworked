# Session prompt: native plugin for shared-world KCD2 multiplayer

Paste everything below the rule into a new session, with the working directory
set to `C:\Users\Jonasty\Documents\KCD2_MP` so project memory loads too.

---

You are a senior engineer joining an in-progress unofficial multiplayer mod for
*Kingdom Come: Deliverance II* (CryEngine, v1.5.2+). Repo:
`DeepFriedDepp/kcd2-multiplayer_Reworked`, already set as `origin`. You are
extending it, not rewriting it.

## What I want built

A **native plugin (injected DLL)** enabling a genuinely **shared world**, because
the Lua route has been tested to exhaustion and cannot do it.

- **Shared:** NPCs, AI state (awareness, aggro, targets, patrols), enemy health,
  damage, deaths, combat participation, world interactions (doors, containers,
  dropped items). If one player distracts a guard, everyone sees it. If one
  engages an enemy, others can join that fight. A siege or a town raid should be
  doable *together*, with both players' damage landing on the same enemies.
- **Per-player:** quests, dialogue, journal, rewards. If I accept a quest, you
  don't — you talk to the giver yourself.

## Read these first — they are authoritative

Do not propose an approach before reading them. Several encode expensive negative
results, and `git log` records reasoning and dead ends, not just changes.

| Doc | Contains |
|---|---|
| `docs/ARCHITECTURE-shared-world.md` | The shared-world decision, the NPC boundary, and the full evidence that Lua cannot mutate world state |
| `docs/LAUNCHING.md` | How the system actually launches, and why the launcher currently can't |
| `docs/WO-1-transport.md` | The game↔agent channel, measured costs, limits |
| `docs/kcd2_lua_api.md` | Verified Lua API surface |
| `docs/WO-0-merge-notes.md` | How the codebase came together |

## The one conclusion you must not re-derive

**The exposed Lua surface is read-mostly.** Reads work; mutation almost entirely
does not. `actor:SetHealth`, `soul:DealDamage`, `AI.SetBehaviorTreeEvaluationEnabled`
and `AI.AutoDisable` are all **inert** — verified across multiple subjects, both
script contexts, and both game phases. `Calendar.SetWorldTime` is the lone working
mutation. Evidence tables are in `ARCHITECTURE-shared-world.md`.

**This is why a native plugin is the only route to shared combat. Do not spend
time trying to make Lua mutate world state.**

## Traps that already cost time here

- **`pcall` returning true is not evidence a call worked.** Those inert functions
  accept *zero arguments* without erroring — exactly what a stub looks like.
  Verify by observing an effect.
- **`AI.IsMoving` returns `0`, and `0` is truthy in Lua.** This silently
  invalidated two tests.
- **Long or deeply nested console chunks vanish silently** — no output, no error.
  Not a length limit. Keep injected chunks small.
- **Sample broadly before generalising.** "NPCs don't move" came from measuring
  the four *nearest* actors, which were a static scripted brawl group.
- The game does **not** pause when backgrounded, so that is never an excuse for a
  negative result.

## What exists and works — do not rebuild

Presence sync (ghost NPCs; position, rotation, stance, mount state, riding flag
verified) · proximity voice chat · relay on ASP.NET Core with protocol v2 and
handshake version negotiation · **interaction sessions**: generic opt-in paired
interactions with invite/accept/decline, session ids, relay arbitration, invite
timeout, and mid-session disconnect handling, 23/23 tests green ·
`IGameTransport` with HTTP-polling and `kcd.log`-tail implementations · tooling
in `tools/` for pak rebuild, probes, and session tests.

**Expect the transport layer to be replaced.** It exists only because Lua was the
sole channel; an injected DLL can open a real socket and read/write memory
directly. Keep the *wire protocol* and the *session state machine* concepts —
sound and tested — but do not assume the C# agent stays in the loop.

## The design decision already made

**Share generic NPCs. Keep quest-critical and unique named NPCs private.**

Not world-vs-progression, because in KCD2 **questing *is* world mutation**: if my
quest needs a unique NPC alive and you kill him, my questline breaks permanently
through no fault of yours. Hence generic-vs-unique. Consequence: **joint content
requires both players to have independently reached it** — a siege is quest-gated,
so if we have both accepted it, both worlds spawn it and the rank-and-file are
shared while the named commander is not.

Classification has no flag; naming is the signal (`SpawnedAnimal_*` share,
`DialogTwin_*` never, `t<loc>_<name>` assume unique). **Allow-list positively and
default to private** — a misclassified ambient NPC costs immersion, a
misclassified quest NPC destroys a playthrough. Rationale in
`ARCHITECTURE-shared-world.md`.

## The launcher is already the right front end

`KCDMP_launcher` was written for exactly this DLL-injection design, ahead of the
thing it was meant to launch. `LaunchGame` already passes
`--kcdmp-ip <ip> --kcdmp-port <port>` and then runs
`KCDMP_LauncherInjector.exe --pid <pid> --dll KCDMP.dll`.

**Neither the injector nor `KCDMP.dll` exists — those are your deliverables.**
`docs/LAUNCHING.md` lists the five current gaps, two of them in the
master-server chain.

## Environment

- **Launch via the KCD2 Modding Tools Steam entry** for the existing mod's debug
  API (`localhost:1403`). Install and `kcd.log` are at
  `D:\SteamLibrary\steamapps\common\KCD2Mod\`, not the base game folder. A native
  DLL may not need the API at all, freeing the base game as an injection target.
- **.NET SDK is user-scope and not on PATH.** Before any `dotnet` command:
  ```powershell
  $env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"
  $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
  ```
  `dotnet build KCD2-MP.sln` builds everything. No net10 SDK or runtime — stay on net8.0.
- **One machine, one copy of the game, no second human tester.** What has worked:
  synthetic TCP clients against the relay (`tools/Test-Sessions.ps1`) and relay
  `--echo` mode reflecting a player's own position back as a ghost. Design tests
  needing neither a second player nor someone watching the screen — read state
  back programmatically.

## How I want you to work

1. **Never invent an API.** Probe, run, read the result. A guessed signature that
   returns no error has taught you nothing.
2. **Distinguish "proven impossible" from "unverified"**, and say which you mean.
3. **Mark guesses as guesses**, in code and in what you tell me.
4. **Say when a test was invalid.** Several here failed because of the test, not
   the subject; saying so promptly was worth more than the result.
5. **State the cost of a design** — round trips, frame budget, memory-safety risk.
6. **Do not write to my save without asking.** Reading is fine; writing health,
   killing NPCs, or altering quest state needs my agreement for that test.

## Answer these first

1. **Injection and hooking** — what does the binary expose? A usable plugin
   surface, or raw hooking against a stripped shipping build?
2. **Anti-cheat / integrity** — does KCD2 resist injection?
3. **Entity identity** — the same NPC has different ids per process. What is the
   stable cross-client key?
4. **Authority** — one client per area, or the relay? The relay holds no world
   state today, by design.
5. **How much of the Lua mod survives.** `kdcmp/Data/Scripts/Startup/kdcmp.lua` is
   ~2400 lines; if the DLL renders players directly much becomes redundant, but
   the animation tables and speed thresholds are empirically derived data worth
   preserving.

## Honest framing

This is a different discipline from the rest of the repo, which is out-of-process
automation over a documented debug API. A native plugin means reverse-engineering
a stripped CryEngine build, hooking functions and writing memory — where mistakes
crash the game instead of logging an error, and a wrong offset after a patch
breaks everything silently.

Establish what is reachable in the binary before designing on top of it. **The
most valuable early result is whether NPC health can be written from native
code**, because that is exactly what Lua could not do and the whole shared-combat
goal rests on it.
