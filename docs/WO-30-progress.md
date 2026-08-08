# WO-30 progress

Session 2026-08-08. Game launched mid-session (was not running at start) via
Modding Tools, human's own action, for Phase 1's live test.

## Coverage

| phase | status | result |
|---|---|---|
| 1 — RC transport on Modding Tools | done, live-measured | Works identically to retail (port, protocol, no cold-start), and reaches live mod state (`KCD2MP`, `ghosts`, `player` all live with a save loaded). But `:1403`'s reflection API is already present here and irreplaceable for appearance sync — RC can only take over one `ExecuteString` call site, with no measured warm-latency win. **Migration not recommended.** Scope stated for the record; nothing built. |
| 2 — appearance/armor detection hook | done, desk audit | No event-driven hook found in the locally-cached scriptbind docs. Confirms WO-9's original finding and WO-23's independent re-audit. Full Skald schema re-check blocked by unreliable network this session — noted, not treated as exhaustive. |
| 3a — consolidate `woNN-lua.ps1` | done | Six identical drivers (WO-21,22,24,25,26,27) replaced by one parameterized `tools/Lua-Driver.ps1`. Checked for references first — only historical doc mentions, no live dependency. Watch scripts (`Wo21/22/26-Watch.ps1`) left alone — not pure duplicates, each adds real fields. |
| 3b — stale comments in `kdcmp.lua` | done | Fixed the flagged `DrawWeapon` comment (WO-23 item 1) plus two more found by the same read-through: an `esModularBehaviorTree` comment misattributing reactive combat to the faction attach, and the `mp_enable_aggro` doc comment wrongly claiming a respawn is needed to pick up a toggle change. |
| 3c — native aggro attach path liveness | done, traced from source | `set_ghost_faction_hostile()` in `rttr_abi.cpp` is still exactly what `mp_enable_aggro` triggers, unchanged since WO-27 verified it live. Still uses the hardcoded donor soul (`prepadeni_bandit_1`). Not vestigial — it is the entire mechanism, and exactly as playthrough-fragile as `README.md` already documents. |

## What actually happened, in order

1. Read the five required docs/directories (`WO-1-transport.md`,
   `WO-18-findings.md`'s RC section, `WO-9-appearance-sync.md`,
   `WO-23-findings.md` item 1, `tools/`).
2. Checked whether the game was running for Phase 1 — it wasn't. Asked the
   human how to proceed rather than guessing; they chose to launch it and
   wait. Used the wait productively: did Phase 2 and Phase 3 (desk/code-only
   work) while the human launched the game, rather than blocking.
3. **Phase 2**: found a leftover cached copy of the `muyuanjin/kcd2-mod-docs`
   scriptbind HTML set from a prior session's scratchpad
   (`/tmp/kcdmp_scriptbind`). Grepped it for equip-change event/listener
   surfaces — none found. Attempted a fresh `git clone` for the fuller Skald
   schema; it timed out (network unreliable this session), noted rather than
   retried in a loop.
4. **Phase 3a**: read all six `woNN-lua.ps1` files (byte-identical except the
   tag), confirmed via grep that nothing sources them (only doc mentions),
   wrote `tools/Lua-Driver.ps1` as the parameterized replacement, `git rm`'d
   the six originals.
5. **Phase 3b**: grepped `kdcmp.lua` for every WO-numbered or claim-shaped
   comment, read the three around the aggro/DrawWeapon area in full context,
   cross-checked each claim against `GameBridge.cs` (confirmed
   `_aggroEnabled` is a live hit-time flag, not spawn-time) and against
   WO-21/22/23/26/27's actual findings before rewriting. Found (but left
   unfixed, out of stated scope) a parallel stale comment in
   `CombatPipe.cs`.
6. **Phase 1**: confirmed the game had come up
   (`localhost:1403` answering, `KingdomCome.exe` running). Enabled
   `log_EnableRemoteConsole 1` via the existing debug API, confirmed
   `0.0.0.0:4600` opened. Wrote a small RC client (raw TCP, wire format from
   WO-18) in the scratchpad, ran it against a live save (not main-menu-only
   like WO-18's retail test) — confirmed `KCD2MP`/`ghosts`/`player` all live
   over RC. Measured RC and HTTP-debug-API latency with an identical
   tag-poll method for a fair comparison; measured RC cold-start across three
   fresh connections. Read `HttpGameTransport.cs` to enumerate every current
   `:1403` use and found only one (`ExecuteString`) is Lua execution — the
   rest is reflection RPC with no RC equivalent, which appearance sync
   depends on entirely. Concluded migration is not worth it on the measured
   evidence and stated the narrow scope it would touch, without building it.
7. **Phase 3c**: traced the exact call path from `mp_enable_aggro` through
   `GameBridge.cs` and `CombatPipe.cs` into `native/KCDMP/rttr_abi.cpp`'s
   `set_ghost_faction_hostile()`, read the function in full, confirmed it
   still uses the hardcoded donor-soul GUID, and confirmed via `git log`
   that `GameBridge.cs`'s aggro path hasn't changed since WO-27 verified it
   live (only WO-28 touched the file, unrelated regions).
8. Ran `dotnet test dotnet\KcdMp.Farkle.Tests\KcdMp.Farkle.Tests.csproj` —
   59/59, unrelated to this session's changes (no C# touched), run as the
   project's standing regression check.
9. Wrote `docs/WO-30-findings.md` and this file.

## Judgement calls worth flagging

- **Did not block on the game being down at session start.** Asked the human
  rather than guessing whether to wait, skip, or work around it; used the
  wait for Phases 2-3 rather than idling.
- **Did not chase the network timeout for the Skald schema clone.** One
  attempt, noted as unreliable, moved on — the scriptbind-HTML check plus two
  independent prior findings (WO-9, WO-23) was judged sufficient for Gate 2
  without re-deriving the same negative result a third way.
- **Did not migrate the transport**, even though RC works, because the
  measured evidence doesn't support it being a genuine win here — the
  brief's own instruction was to propose, not build, and the honest
  measurement pointed at "not worth it" rather than "worth it, needs
  sign-off."
- **Did not consolidate the `Wo*-Watch.ps1` scripts** alongside the
  `woNN-lua.ps1` family — they looked similar at a glance but each adds real
  fields the last one didn't have; treated as organic evolution, not
  duplication, and left alone per the brief's own "check first" instruction.
- **Left the `CombatPipe.cs` stale comment unfixed**, flagged instead of
  fixed, since Phase 3b's brief named `kdcmp.lua` specifically and widening
  scope to a different file/language wasn't asked for.

## Open, ranked

1. **WO-23 item 3's soul-only hostile-faction lead** (no donor, no native
   attach) — still the right next step if the donor-soul fragility ever
   needs fixing for real. Untested in its exact shippable form.
2. **`CombatPipe.cs:118-123`'s stale `SharedSoulGuid=0` comment** — cheap fix
   whenever someone is next in that file for an unrelated reason.
3. **RC transport migration** — scoped precisely in `docs/WO-30-findings.md`
   Phase 1 if the human wants to revisit the decision later (e.g. if the
   cold-start penalty turns out to matter more in practice than measured
   here), but not recommended on this session's evidence.

## Next session should

Read `docs/WO-30-findings.md` in full before re-deriving any of Phase 1's
transport comparison or Phase 3c's aggro-path trace — both are settled here
from direct measurement/source reading, not guesses.
