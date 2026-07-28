# Session prompt — starting a new work order

Paste everything below the rule into a new session, with the working directory
set to `C:\Users\Jonasty\Documents\KCD2_MP`. **Replace the `YOUR WORK ORDER`
block with what you actually want done** — everything else is durable context
that stays the same session to session.

Supersedes `SESSION-PROMPT-wo4-continue.md`.

---

You are a senior engineer continuing an unofficial multiplayer mod for *Kingdom
Come: Deliverance II* (CryEngine, v1.5.2+). Repo
`DeepFriedDepp/kcd2-multiplayer_Reworked`, already `origin`, branch `main`.

Work orders 0–4 are complete. **Shared combat replicates in both directions,
verified end to end.** The launcher is wired to the injector and the master
server chain is closed.

## YOUR WORK ORDER

> *(Replace this block.)*
>
> Work order 5 is **\_\_\_\_\_\_\_\_**. I want \_\_\_\_\_\_\_\_.

If you want the highest-value open items instead, they are, in order:

1. **Run `KCDMP_launcher` against a real launch** and confirm the
   game → wait for `WHGame.dll` → inject → start agent sequence. Its pieces are
   individually proven; the whole has been reviewed, not observed.
2. **Run the real Python master server** with the relay and launcher. It has
   never been executed — there is no Python on the dev machine, so it was tested
   against a stub of the Flask contract. Mind the schema migration.
3. **A real second client.** Everything cross-client is proven with synthetic
   TCP peers only.

## Read these first — authoritative

| Doc | Contains |
|---|---|
| `docs/HANDOFF-WO4-combat.md` | **Start here.** System status, architecture, how to run and test everything, traps |
| `docs/WO-4-completion-report.md` | What the last session changed, and precisely what was and was not verified |
| `docs/NATIVE-PLUGIN-findings.md` | Capability evidence: what the binary exposes, the RTTR ABI, what is proven impossible |
| `docs/ARCHITECTURE-shared-world.md` | Where the shared/private boundary falls and why |
| `docs/LAUNCHING.md` | How the system launches; launcher and master server wiring |

`git log` records reasoning and retractions, not just changes. Several commits
retract earlier claims — read those before trusting an older statement.

## Conclusions you must NOT re-derive

- **Lua cannot mutate world state.** Reads work, writes are inert. Settled
  across many subjects and both game phases.
- **The engine CAN be mutated** — via the RTTR reflection layer from native
  code. Health writes, damage and death are all verified working.
- **`SharedSoulGuid` is the cross-client key**, proven authored in the shipped
  level XML. Not entity ids, not pointers.
- **Aggro is not achievable.** No stimulus-injection surface exists on any
  reachable API. `TakeDamage`'s `Attacker` creates no combat history. Replicated
  damage hurts NPCs but does not make them fight back. This is a settled design
  consequence, not a gap to fix.
- **Faction manipulation is off-limits.** `SetParent` corrupted the faction tree
  and crashed the game. Disabled in code with the reasoning inline.
- **Outbound hit detection is by sampling, not hooking.** `TakeDamage` is not
  exported; reaching it would mean a hardcoded call address that breaks silently
  on the next patch. Sampling costs a few reflected reads per tick.

## What is NOT verified — do not assume it works

- The **Python master server has never been run** (no Python on this machine).
  `kcd2_master_server/` is reviewed, not executed; the .NET half was proven
  against a stub. An existing database needs a migration for the new
  `last_seen` column and the unique `(ip_address, port)` constraint.
- The **launcher has never driven a real game launch**.
- There has **never been a second real client**.

## Traps that already cost time

- **A stale injected DLL keeps the pipe** and its sampler keeps running. Test a
  rebuilt DLL against a **restarted game** — or inject into one that has no DLL
  yet, which is equivalent and faster. Check for `\\.\pipe\kcdmp` and read the
  pid on the first line of `native\build\KCDMP\kcdmp-native.log` before trusting
  any result. This produced two false negatives.
- **A duplex pipe used from two threads requires overlapped I/O on both
  handles.** A synchronous handle serialises reads against writes in the kernel
  and a user-mode lock does nothing about it. This was WO-4's last bug.
- **Check the result of a write, not just the absence of a fault.** A discarded
  return made a permanently blocked write look identical to a delivered one.
- **A fault-free rttr `invoke` is not a successful one** — it returns an invalid
  variant on argument mismatch, with no exception. Check `variant::is_valid`.
- **Never pass a borrowed reference to a by-value parameter that owns a
  resource** (`shared_ptr`, `CryStringT`, containers) — the callee destroys it.
  Value types (floats, enums, raw pointers) are fine.
- **Immediate read-back is not verification** for state the game re-derives.
- **A narrow `catch` on a background task turns a crash into silence.**
- **PowerShell variables are case-insensitive**: `$ack` shadows `$ACK`.
- **A PowerShell range index returns `Object[]`, not `byte[]`** —
  `[Guid]::new($bytes[1..16])` picks the `string` overload and throws.
- **`appsettings.Development.json` shadows `appsettings.json`** in dev. Fixing
  only the base file changes nothing.
- **A REST container read without `?depth=`** serialised 658 MB once. Always
  pass `?depth=0` or `?depth=1`; use `tools\KcdApi.ps1`, which caps reads.

## Environment

- **Launch the game via the KCD2 Modding Tools Steam entry**
  (`D:\SteamLibrary\steamapps\common\KCD2Mod`), not the base game. The
  reflection REST API on `localhost:1403` and the separate module DLLs exist
  only there; retail is monolithic. Both builds name the executable
  `KingdomCome.exe` and both ship `WHGame.dll` — the real discriminator is
  `Framework.dll` + `CrySystem.dll` beside the exe (45 DLLs vs 6).
- **.NET SDK is user-scope, not on PATH:**
  ```powershell
  $env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
  ```
  Stay on net8.0.
- **MSVC Build Tools are installed** but not on PATH; `native\Build-Native.ps1`
  locates them.
- **There is no Python.** `kcd2_master_server/` cannot be run here.
- A running relay or agent **locks the build output**; stop them before
  `dotnet build`.
- **One machine, one copy of the game, no second player.** Synthetic TCP peers
  and the pipe test cover everything except a real second client.

## Running everything

```powershell
$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
powershell -ExecutionPolicy Bypass -File native\Build-Native.ps1
dotnet build KCD2-MP.sln
dotnet run --project dotnet\KcdMp.Server -- --port 7778
dotnet run --project dotnet\KcdMp.Client -- --host localhost --no-voice
native\build\KCDMP_LauncherInjector\KCDMP_LauncherInjector.exe --pid <pid> --dll <path>\KCDMP.dll
```

| Script | Proves |
|---|---|
| `tools\Test-Combat.ps1` | relay forwarding, 14/14, no game needed |
| `tools\Test-Pipe.ps1` | pipe → DLL → NPC, no agent or relay needed |
| `tools\Test-CombatE2E.ps1` | inbound chain with a synthetic peer |
| `tools\Test-CombatOutbound.ps1` | outbound chain with a synthetic peer |
| `tools\Probe-Reflection.ps1` | re-run after any game patch |

## How I want you to work

1. **Never invent an API.** Probe, run, read the result.
2. **Distinguish proven from unverified**, and say which you mean.
3. **Mark guesses as guesses**, in code and in what you tell me.
4. **Say when a test was invalid** — several here failed because of the test,
   not the subject.
5. **Verify by observing an effect**, never by absence of an error.
6. **Do not write to my save without asking.** Reading is fine.
7. **Be concise.** Long explanations burn the context window.
