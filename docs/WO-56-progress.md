# WO-56 — progress log

## 2026-08-25 (Fable 5) — design session: every player a real Henry?

Design-document session, no code, no VERSION change. Sequence:

1. Re-read the original "Be Henry" attempt (`WO-26-findings.md` Phase 1) in
   full: the spawn line, the two log signatures, the BugSplat, and the
   gate's own honest limits (crash inferred from adjacency, no dump read).
2. Assembled the modern toolkit view: WO-42 §9.5/§9.6, WO-43's correction,
   WO-44 §1/§2 (+ its correction), WO-45 §1 (live vptr identifications),
   WO-51 (Flow B + proximity gating), WO-52 (no netcode help), WO-28 Phase 3
   (Flow B anatomy).
3. New static evidence this session (targeted fact-checking, no game
   launched):
   - Parsed EntityModule's export table (PowerShell PE walk): no exported
     player *setter*; `GetPlayer`/`GetPlayerActor`/`GetScriptBindPlayer`/
     `GetPlayerTouchedManager` only.
   - Reused the surviving WO-42 Ghidra project (`gproj3`, EntityModule):
     decompiled `GetPlayerActor` (0x71B330), `GetPlayer` (0x71B300),
     `C_Player::Init` (0xADB1A0, vftable slot +0x38, string-anchored) and
     `C_Player::InitLocalPlayer` (0xADBEA0, slot +0x290, string-anchored).
   - Found the WO-26 crash strings ("no archetype found for '%s' of class
     '%s'", "does not have a faction") both live in RPGModule.dll; imported
     RPGModule into a fresh Ghidra project and anchor-read both —
     `C_SoulList::GetDefaultSoulArchetypeFromEntity` (non-fatal, returns
     archetype 0) and `C_NPCFactionNode::GetFactionPtr` (non-fatal, returns
     the null).
   - Extracted `player.lua` from the shipped `Scripts.pak`: it declares
     `defaultSoulClass = "player"` and no `defaultSoulArchetype` — the
     starvation is by design for a *spawned* Player-class entity.
4. Wrote `docs/WO-56-findings.md`: the crash re-explained (candidate
   mechanism, labelled), the singularity audit (slot vs class), the input
   question, the Phase-4 payoff chased and found topology-blocked, honest
   scope, and a real recommendation (do not pursue; what would change it).

Ghidra projects: EntityModule reused from the WO-42 scratchpad
(`...\d434c2da...\scratchpad\gproj3`); RPGModule imported fresh this session
(`...\f3b10e26...\scratchpad\gproj-rpg`, ~19 MB DLL). Re-import recipe:
WO-42 §7.1.
