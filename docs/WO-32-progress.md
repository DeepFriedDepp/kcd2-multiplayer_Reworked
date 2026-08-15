# WO-32 progress

2026-08-15, one session, human at the machine for the live phases.

1. **Read-first**: WO-26 findings (InterpTick vs fighting ghost), the shared-
   combat design §2–3 (authority model), PROJECT-STATE, WO-30 (transport
   numbers), WO-34 in full (faction-resolution trap, live-verification
   discipline, control-NPC requirement).
2. **Phase 0**: enumerated the 17 real NPCs near the player's save position;
   vetted `ttkc_man_16` (varlet, civilian crime role, clean faction ancestry
   walked through FactionTree.xml, vip 0, brain npc_basic, zero quest table
   references). Control: `ttkc_man_10` (musician). Guards identified and
   excluded. Bound: 30 m radius, 5 NPCs.
3. **Phase 1 live**: single write lands and is reverted to a byte-identical
   anchor in ~1.5 s; a 50 ms stream wins completely with **no AI suppression**;
   release is automatic (anchor restore ≤3 s); dialogue works after release
   (human-verified); no crime/faction/buff contact on NPC, control, or player;
   forced walk animation works (human-verified) — without it the NPC slides in
   its activity pose. `AI.SetIgnorant` registered but unneeded;
   `Actor.SetAIBrainId` documented but NOT registered on this build.
4. **Gate 1: works — built it.** Wire `0x26/0x27` (name-addressed,
   authority-gated on WO-28's Rule 2 role), relay routing + drop-from-non-
   authority, agent event→wire→Lua bridging with three-layer name validation,
   Lua emit tick (250 ms, 4 Hz/NPC, change-gated + 2 s heartbeat) and puppet
   tick (50 ms, ghost-interp shape, WO-34 corpse rule, 3 s silence release),
   `mp_npc_sync` toggle off by default, WO-13 liveness stamps + agent re-arm.
5. **Test harness lessons this session**:
   - The first E2E run failed because the *old installed relay* was still
     running (`AppData\Local\KCDMP`) — it silently skips unknown type bytes,
     which also made the authority-guard "pass" meaningless. Process paths
     checked before trusting any wire test from now on.
   - `Drain`'s quiet-window pattern (copied from the vitals test) hangs
     forever while the local player moves (Ghost stream never goes quiet);
     hard cap added.
   - "≤5 distinct names over a 6 s window" was the wrong cap assertion —
     NPCs walk across the radius boundary between rescans; the real
     invariant is the concurrent tracked count, read from the mod.
6. **Final E2E: 15/15 PASS** (`tools\Test-NpcSyncE2E.ps1`) — emit side
   (packets match engine positions), authority guard (relay log warning
   observed), apply side (real NPC driven over the real wire by a synthetic
   peer, tracked mid-drive, puppet lifecycle, silence release, engine
   restore). Post-test world state verified clean. One intermediate-run
   anomaly (a non-authority packet applied once during the relay swap) is
   recorded in the findings with its unconfirmed half-joined-session
   hypothesis.
7. Cost measured: ~4 pkt/s (~150 B/s) observed for 5 NPCs, 740 B/s worst
   case — less than one player position stream. Extrapolation and the real
   (client-side) scaling ceiling are in the findings.
8. Shipped shape: `mp_npc_sync`, **off by default**, 5 NPCs / 30 m.
   Human's decision on default-on vs. flag: PENDING-DECISION
