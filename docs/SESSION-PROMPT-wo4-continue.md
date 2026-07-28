# Session prompt — finish WO-4 (shared combat)

Paste everything below the rule into a new session, with the working directory
set to `C:\Users\Jonasty\Documents\KCD2_MP`.

---

You are a senior engineer continuing an unofficial multiplayer mod for *Kingdom
Come: Deliverance II* (CryEngine, v1.5.2+). Repo `DeepFriedDepp/kcd2-multiplayer_Reworked`,
already `origin`. Work order 4 — **shared combat** — is ~85% done and I want it
finished.

## Your first task

**One bug is blocking everything.** A frame the injected DLL writes to
`\\.\pipe\kcdmp` is never read by the C# agent.

- The DLL logs `PIPE: LocalHit 9.00 guid=...` **without** the
  `[no agent attached, not sent]` suffix, so an agent was connected and
  `send_frame` ran.
- `CombatPipe.ReadLoopAsync` logs *every* frame it receives. It logs nothing.
- The same pipe carries `ApplyDamage`/`Result` the other way perfectly.

So the DLL writes and the agent does not read. Files:
`native/KCDMP/pipe_server.cpp` and `dotnet/KcdMp.Client/CombatPipe.cs`.

Four untested hypotheses, cheapest first, in
`docs/HANDOFF-WO4-combat.md` §"THE OPEN BUG". Start with widening the catch in
`ReadLoopAsync` — it currently only catches `IOException`/`ObjectDisposedException`,
so anything else dies as an unobserved task exception with no output.

Reproduce with `tools\Test-CombatOutbound.ps1` (needs relay + agent + game with
the DLL injected). When it goes green, WO-4's last unknown is closed.

Then: `KCDMP_launcher` still needs wiring to the now-real injector, and the two
master-server gaps in `docs/LAUNCHING.md` are still open.

## Read these first — authoritative

| Doc | Contains |
|---|---|
| `docs/HANDOFF-WO4-combat.md` | **Start here.** Status, the open bug, architecture, how to run and test everything, traps |
| `docs/NATIVE-PLUGIN-findings.md` | Capability evidence: what the binary exposes, the RTTR ABI, what is proven impossible |
| `docs/ARCHITECTURE-shared-world.md` | Where the shared/private boundary falls and why |
| `docs/LAUNCHING.md` | How the system launches; remaining launcher gaps |

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

## Traps that already cost time

- **A stale injected DLL keeps the pipe** and its sampler keeps running. Test a
  rebuilt DLL against a **restarted game**, or you are testing the old one. This
  produced two false negatives.
- **A fault-free rttr `invoke` is not a successful one** — it returns an invalid
  variant on argument mismatch, with no exception. Check `variant::is_valid`.
- **Never pass a borrowed reference to a by-value parameter that owns a
  resource** (`shared_ptr`, `CryStringT`, containers) — the callee destroys it.
  Value types (floats, enums, raw pointers) are fine.
- **Immediate read-back is not verification** for state the game re-derives.
- **PowerShell variables are case-insensitive**: `$ack` shadows `$ACK`.
- **A REST container read without `?depth=`** serialised 658 MB once. Always
  pass `?depth=0` or `?depth=1`; use `tools\KcdApi.ps1`, which caps reads.

## Environment

- **Launch the game via the KCD2 Modding Tools Steam entry**
  (`D:\SteamLibrary\steamapps\common\KCD2Mod`), not the base game. The
  reflection REST API on `localhost:1403` and the exported module DLLs exist
  only there; retail is monolithic and exports nothing.
- **.NET SDK is user-scope, not on PATH:**
  ```powershell
  $env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
  ```
  Stay on net8.0.
- **MSVC Build Tools are installed** but not on PATH; `native\Build-Native.ps1`
  locates them.
- **One machine, one copy of the game, no second player.** Synthetic TCP peers
  and the pipe test cover everything except a real second client.

## How I want you to work

1. **Never invent an API.** Probe, run, read the result.
2. **Distinguish proven from unverified**, and say which you mean.
3. **Mark guesses as guesses**, in code and in what you tell me.
4. **Say when a test was invalid** — several here failed because of the test,
   not the subject.
5. **Verify by observing an effect**, never by absence of an error.
6. **Do not write to my save without asking.** Reading is fine.
7. **Be concise.** Long explanations burn the context window.
