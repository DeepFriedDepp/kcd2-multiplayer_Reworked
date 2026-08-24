# WO-47 progress

Worked 2026-08-24 (Fable 5), live session, human at the machine.
`docs/WO-47-findings.md` is the deliverable; this is the session log.

## What was done, in order

1. Read WO-46/WO-42 §9.2/WO-9/WO-10. Extracted the weapon/item/combat tables
   from the real `Tables.pak` and answered Phase 1's structure offline first:
   `weapon_class.xml` is the shared id space; item.xml `Class="N"` maps
   ItemClass GUIDs into it; one-handers ride group-tagged `-1` rows resolved
   through shipped `combat_weapon_group*` tables.
2. Built `WeaponSwingCatalog` + swing-site wiring + `--dump-swing-catalog`
   + `Test-SwingCatalog.ps1` (offline PASS against the real pak). Committed
   UNTESTED (f3da3c4) before any live work.
3. Deploy detour #1: staged the agent+relay set **server-first, client-last**
   — the client's System.Text.Json **8.0** overwrote the server's required
   **10.0** and the relay died at startup (event-log confirmed, exact WO-46
   signature). Also: my shell's view of `%LocalAppData%` is sandbox-redirected
   (listed stale 8/15 files while the genuinely-running agent printed new
   code) — reconfirmed the standing rule: never verify installs from this
   shell. Re-staged client-first; Json 10.0.25 wins; relay lived.
4. Phase 1 live (Gate 1): 5/5 exact MATCH, with the bonus discovery that the
   live map's `Value` carries `Type=N` — the game itself states the weapon
   class. (Parser traps: XmlElement `.Value` vs `<Value>` child; `-like` vs
   `[plain]`.)
5. User asked about halberds/mallets/crossbows/etc. — enumerated the full
   item tables per class (63 mace-class items incl. warhammers/clubs, 22
   polearms, 190 shields; bows/crossbows/guns are MissileWeapon with zero
   attack rows) and stated the ranged scope honestly. Ranged probe agreed on.
6. Spawned test gear into the player's inventory via REST (bow+arrows,
   crossbow+bolts, gun+shot+powder items, 2 polearms).
7. Live swing runs (Gate 2), each human-watched, each with agent+DLL log
   evidence: **mace PASS, axe PASS, longsword regression PASS.**
8. Halberd run #1: swings rendered as real polearm animations but
   **empty-handed** — REST equip reports the polearm equipped (Type=7,
   verify loop passes) yet no model attaches; `DrawWeapon()` ignores the
   Oversized slot (drew a preset sidearm instead). Mined the shipped
   scriptbind docs → `human:DrawFromInventory(FindItem(guid), 0, true)`
   puts it in hand (human-confirmed on a wire-free test ghost).
9. Ordering trap found live: `DrawFromInventory` AFTER the draw event killed
   swing rendering (status=1, nothing rendered); BEFORE it, everything works.
   (One run lost to a Claude Code app crash mid-injection; rerun clean.)
10. Ranged probe with the action logger: drawn-state events fire for all
    three families; `bow_primary(_release)`, `crossbow_prepare/execute/abort`,
    `gun_prepare/execute/abort` all reach the Lua hook, unmapped; the bow can
    leak fake swing/block events (input-context noise, observed once, absent
    on a clean cycle).
11. Shipped the polearm fix: Lua `KCD2MP_GhostDrawItem` + agent routing
    (Oversized main-hand → DrawFromInventory route). Pak rebuild + game
    restart (one bounce lost to a skipped pak install — the game was running;
    caught by comparing installed pak bytes to the repo build).
12. **Final production-path bardiche run: PASS** — ghost drew the bardiche
    into its hands on its own draw event and swung it three times,
    human-watched, all three log layers agreeing.
13. Cleanup (test ghost removed, action logger off), suites green
    (Farkle 59/59 + Test-SwingCatalog PASS), docs written, committed, pushed.

## Gates

- **Gate 1 (mapping): PASSED** — real values side by side, exact match, live
  `Type` corroboration.
- **Gate 2 (generic lookup, multiple weapons live): PASSED** — mace, axe,
  longsword, halberd(bardiche), each watched rendering real swings with
  slash/stab rotation; halberd additionally through the new Oversized draw
  route with the weapon visibly in hand.
- Gate 3 (bounded hardcode fallback): not needed — Phase 1 supported Phase 2.

## Not done, on purpose

- No VERSION change (docs/VERSIONING.md).
- Ranged combat visibility: probed and scoped (findings §6), not built.
- Oversized sheathe behavior: untested, flagged for next session.
