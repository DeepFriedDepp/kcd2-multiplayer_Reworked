-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

-- ===== Register Console Commands =====

local ok, err = pcall(function()
    System.AddCCommand("mp_pos",         "KCD2MP_GetPos()",         "Get player position")
    System.AddCCommand("mp_start",       "KCD2MP_Start()",          "Start MP sync")
    System.AddCCommand("mp_stop",        "KCD2MP_Stop()",           "Stop MP sync")
    System.AddCCommand("mp_spawn_test",  "KCD2MP_SpawnTest()",      "Spawn test ghost")
    System.AddCCommand("mp_remove_all",  "KCD2MP_RemoveAllGhosts()","Remove all ghosts")
    System.AddCCommand("mp_inspect",     "KCD2MP_InspectGhost()",   "Inspect ghost interp state")
    System.AddCCommand("mp_find_npcs",   "KCD2MP_FindNPCs()",       "Find nearby human NPCs")
    System.AddCCommand("mp_map_marker",  'KCD2MP_ProbeMapMarker("%LINE")', "WO-38: probe GameRules.AddMinimapEntity on ghosts (arg: type int, or 'sweep')")
    System.AddCCommand("mp_ghost_ignorant", 'KCD2MP_SetGhostsIgnorant("%LINE")', "WO-38/40: AI.SetIgnorant on all ghosts -- DEFAULT ON since WO-40 (pickpocket aggro): on|off")
    System.AddCCommand("mp_ghost_calm",  "KCD2MP_GhostCalm()", "WO-40: probe faction/hostility binds and clear per-pair hostility on every ghost")
    System.AddCCommand("mp_probe_anims",   "KCD2MP_ProbeAnims()",    "Probe anim names on ghost (GetAnimationLength)")
    System.AddCCommand("mp_copy_npc",     "KCD2MP_CopyNPCModel()",  "Find human NPC, copy CDF to ghost, probe anims")
    System.AddCCommand("mp_scan_anims",   "KCD2MP_ScanAnims()",     "Scan animation directories")
    System.AddCCommand("mp_test_ai_nav",  "KCD2MP_TestAINav()",     "Test AI.SetForcedNavigation on ghost")
    System.AddCCommand("mp_read_adb",     "KCD2MP_ReadADB()",       "Read kcd_male_database.adb via CryEngine XML loader")
    System.AddCCommand("mp_probe_tags",   "KCD2MP_ProbeAnimTags()", "Probe Mannequin animation tags on ghost")
    System.AddCCommand("mp_test_run",     "KCD2MP_TestRunAnim()",   "Test 3d_relaxed_run_turn_strafe on ghost")
    System.AddCCommand("mp_terrain",      "KCD2MP_TerrainCheck()",  "Check player/ghost vs terrain height")
    System.AddCCommand("mp_probe_stance", "KCD2MP_ProbeStance()",   "Log player stance value (for crouch detection calibration)")
    System.AddCCommand("mp_probe_contexts", "KCD2MP_ProbeContexts()", "WO-65: dump script-context isolation surface (Contexts global, soul/human methods, per-context HasScriptContext on ghost + player) -- read-only")
    System.AddCCommand("mp_ghost_isolate", 'KCD2MP_SetGhostIsolate("%LINE")', "WO-65: ghost civic isolation (default on). On this build: RestrictDialog+InterruptDialogs only -- the script-context crime fix has no Lua setter here: mp_ghost_isolate on|off")
    System.AddCCommand("mp_sneak_on",     "KCD2MP.playerSneaking=true;System.LogAlways('[KCD2-MP] SNEAK ON (manual)')",  "Force ghost into sneak mode")
    System.AddCCommand("mp_sneak_off",    "KCD2MP.playerSneaking=false;System.LogAlways('[KCD2-MP] SNEAK OFF (manual)')", "Force ghost out of sneak mode")
    -- mp_spawn_armor <guid1,guid2,...>  -- inventory only (no visual unless preset given as 2nd arg)
    System.AddCCommand("mp_spawn_armor",  'KCD2MP_SpawnArmoredNPC("%LINE")',  "Spawn NPC with items: mp_spawn_armor guid1,guid2,...")
    System.AddCCommand("mp_spawn_knight",    "KCD2MP_SpawnKnight()",    "Spawn fully armored knight (BascinetVisor04+Cuirass07+Gauntlets08+LegsPlate03+MailLong01)")
    System.AddCCommand("mp_spawn_white_red", "KCD2MP_SpawnWhiteRed()", "Spawn white/red armored NPC (Brigandine10+BascinetVisor05+sword)")
    System.AddCCommand("mp_scan_horse",      "KCD2MP_ScanNearbyHorse()", "Scan real horse NPC within 20m: anims, AI fns, horse.horse API")
    System.AddCCommand("mp_find_horses",     "KCD2MP_FindHorses()",     "Find horse entities near player - shows class names")
    System.AddCCommand("mp_spawn_horse_test","KCD2MP_SpawnHorseTest()", "Force-spawn a horse at player position (class probe)")
    System.AddCCommand("mp_riding_state",    "KCD2MP_RidingState()",    "Log current riding detection state")
    System.AddCCommand("mp_emit_on",         "KCD2MP_StartEmitter()",   "Start [KCD2-MP-DATA] state emitter (WO-1 log transport)")
    System.AddCCommand("mp_emit_off",        "KCD2MP_StopEmitter()",    "Stop the state emitter")
    System.AddCCommand("mp_emit_once",       "KCD2MP_EmitState()",      "Emit a single state line")
    System.AddCCommand("mp_accept",          "KCD2MP_AcceptInvite()",   "Accept a pending interaction invite")
    System.AddCCommand("mp_decline",         "KCD2MP_DeclineInvite()",  "Decline a pending interaction invite")
    System.AddCCommand("mp_sync_appearance", "KCD2MP_SyncAppearance()", "Force an immediate appearance resync to peers (WO-9)")
    System.AddCCommand("mp_slow_time",       "KCD2MP_SlowTime()",       "Toggle manually broadcasting a paused/unavailable state to peers (WO-11 fallback)")
    System.AddCCommand("mp_invite",          'KCD2MP_InviteNearest("%LINE")', "Invite the nearest player: mp_invite dice|duel")
    System.AddCCommand("mp_ghost_state",     "KCD2MP_GhostState()",     "Dump all ghost riding/mount state")
    System.AddCCommand("mp_horse_adopt",     'KCD2MP_SetHorseAdopt("%LINE")', "WO-40: adopt real world horses for ghosts (default on). off = proxy horses only -- use if the game crashes when a peer mounts")
    System.AddCCommand("mp_weather",         'KCD2MP_WeatherCmd("%LINE")', "WO-40: bare = report rain intensity; mp_weather <profile> = blend to a time_of_day profile locally (probe, not broadcast)")
    System.AddCCommand("mp_enable_aggro",    'KCD2MP_EnableAggro("%LINE")', "WO-17: opt-in NPC aggro on ghosts, this client only: mp_enable_aggro on|off")
    System.AddCCommand("mp_debug_hud",       'KCD2MP_DebugHud("%LINE")', "WO-50: toggle the CryEngine debug HUD (r_DisplayInfo), off by default in release: mp_debug_hud on|off")

    -- NPC sync (WO-32)
    System.AddCCommand("mp_npc_sync",    'KCD2MP_EnableNpcSync("%LINE")', "WO-32: stream nearby NPCs to peers (world authority only): mp_npc_sync on|off")
    System.AddCCommand("mp_npc_proximity", 'KCD2MP_EnableNpcProximity("%LINE")', "WO-60: non-authority claims NPCs near its own player (default on). off = pre-WO-60 host-only tracking: mp_npc_proximity on|off")

    -- Dropped-item sync (WO-48)
    System.AddCCommand("mp_item_sync",   'KCD2MP_EnableItemSync("%LINE")', "WO-48: share deliberately dropped items with peers: mp_item_sync on|off")
    System.AddCCommand("mp_npc_fight",   "KCD2MP_NpcFightReport()", "WO-40: dump per-puppet tug-of-war counts and competing attractor positions")
    System.AddCCommand("mp_npc_chainfix", 'KCD2MP_SetNpcChainFix("%LINE")', "WO-69: off (default) logs a leaked puppet-tick chain and leaves it running; on makes the stale chain exit: mp_npc_chainfix on|off")

    -- Shared player combat (WO-28)
    System.AddCCommand("mp_vitals",      "KCD2MP_ReportVitals()",   "WO-28: report this player's health/stamina/death and every ghost's known health")
    System.AddCCommand("mp_fake_death",  'KCD2MP_FakeDeath("%LINE")', "WO-28: report yourself dead for N seconds (default 20) so peers can be observed reacting -- test only")
    System.AddCCommand("mp_reconcile",   "KCD2MP_ReconcileGhosts()", "WO-28: respawn any ghost whose entity was destroyed by a save load")

    -- Dice overlay (WO-6). These console commands are the SUPPORTED path: the
    -- keybinds below them are unverified action-name guesses, exactly as WO-2's
    -- accept/decline were. Everything here is reachable without a working key.
    System.AddCCommand("mp_dice",        "KCD2MP_InviteDiceAtTable()", "Challenge the nearest player to dice -- only at a real dice table")
    System.AddCCommand("mp_dice_wager",  'KCD2MP_SetDiceWager("%LINE")', "WO-33: set groschen staked on the next dice invite this client sends (0 = none)")
    System.AddCCommand("mp_dice_cast",   "KCD2MP_DiceConfirm()",       "Cast, or set aside the marked dice (depends on phase)")
    System.AddCCommand("mp_dice_mark",   'KCD2MP_DiceMark("%LINE")',   "Mark/unmark a die on the board: mp_dice_mark 1..6")
    System.AddCCommand("mp_dice_unmark_all", "KCD2MP_DiceUnmarkAll()", "Clear every pending mark without rerolling")
    System.AddCCommand("mp_dice_bank",   "KCD2MP_DiceBank()",          "Bank this hand and end thy turn")
    System.AddCCommand("mp_dice_yield",  "KCD2MP_DiceForfeit()",       "Yield the match")
    System.AddCCommand("mp_dice_close",  "KCD2MP_DiceClose()",         "Dismiss the dice board")
    System.AddCCommand("mp_dice_table",  "KCD2MP_ReportDiceTable()",   "Report the nearest dice table, for verifying table detection")
    System.AddCCommand("mp_dice_redraw", "KCD2MP_DiceRender()",        "Force the board to re-push (use if it ever goes stale)")
    System.AddCCommand("mp_dice_flush",  "KCD2MP_DiceFlush()",         "Clear every queued/shown tutorial panel -- fixes a stuck or flickering board")
    System.AddCCommand("mp_dice_scan",   'KCD2MP_ScanTables("%LINE")', "List nearby entity classes, to find a table's real class: mp_dice_scan 6")
    System.AddCCommand("mp_dice_seat",   "KCD2MP_ReportSeat()",        "Report the seat under you: distance, table id, teleport anchor")
    System.AddCCommand("mp_dice_gate",   'KCD2MP_DiceGate("%LINE")',   "Require a real table for mp_dice: mp_dice_gate on|off (default off for testing)")
    System.AddCCommand("mp_dice_demo",   "KCD2MP_DiceDemo()",          "Open the board with fake state, to review the visuals without a second player")
    System.AddCCommand("mp_combat_probe", "KCD2MP_CombatProbe()", "WO-39: registration + anim-candidate probe for combat visibility (needs a ghost for the anim half)")
    System.AddCCommand("mp_ghost_combat", 'KCD2MP_GhostCombatAll("%LINE")', "WO-39: play a combat event on every local ghost, no wire: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
    System.AddCCommand("mp_log_actions", 'KCD2MP_LogActions("%LINE")', "Log every OnAction name (floods log -- for discovering action names): mp_log_actions on|off")
    System.AddCCommand("mp_combat_frag", 'KCD2MP_SetCombatFragment("%LINE")', "WO-39: set the Mannequin fragment tried for swings (empty to clear): mp_combat_frag <name> [tags]")
    System.AddCCommand("mp_entity_id", 'KCD2MP_ReportEntityId("%LINE")', "WO-43: print an entity's raw id by name, or every ghost's id with no argument")
    System.AddCCommand("mp_anim_tag",    'KCD2MP_AnimTagCmd("%LINE")', "WO-40: probe AI.Set/ClearAnimationTag on every ghost: mp_anim_tag set|clear <tag>")
    System.AddCCommand("mp_test_xgen_nullai", 'KCD2MP_TestXGenSpawn("NullAI")', "Test XGenAIModule.SpawnEntity ClassName=NullAI")
    System.AddCCommand("mp_test_xgen_npc",    'KCD2MP_TestXGenSpawn("NPC")',    "Test XGenAIModule.SpawnEntity ClassName=NPC")
    System.AddCCommand("mp_test_xgen_horse",  'KCD2MP_TestXGenSpawn("Horse")',  "Test XGenAIModule.SpawnEntity ClassName=Horse")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- mp_log_actions on|off (WO-39). The KCD2MP.logActions global existed since
-- WO-6 but had no console command -- discovering action names needed a
-- hand-typed Lua chunk. The live combat-input probe made it a first-class
-- command.
function KCD2MP_LogActions(arg)
    local on = tostring(arg or ""):lower()
    KCD2MP.logActions = (on == "on" or on == "true" or on == "1")
    System.LogAlways("[KCD2-MP] logActions=" .. tostring(KCD2MP.logActions))
end

-- mp_anim_tag set|clear <tag> (WO-40 Phase 6): probe AI.SetAnimationTag /
-- ClearAnimationTag (documented in the retail-1.5 dump, never tried here) on
-- every ghost. Mannequin tags select fragment variants -- potentially the
-- clean lever for stance/combat variants that raw StartAnimation cannot pick.
function KCD2MP_AnimTagCmd(line)
    line = tostring(line or "")
    local op, tag = line:match("^(%S+)%s+(%S+)$")
    if not op or not tag then
        System.LogAlways("[KCD2-MP] usage: mp_anim_tag set|clear <tag>  (applies to every ghost)")
        System.LogAlways("[KCD2-MP] AI.SetAnimationTag=" .. tostring(AI and type(AI.SetAnimationTag) or "no AI")
            .. " AI.ClearAnimationTag=" .. tostring(AI and type(AI.ClearAnimationTag) or "no AI"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            n = n + 1
            local ok, err
            if op == "set" then
                ok, err = pcall(function() return AI.SetAnimationTag(g.entity.id, tag) end)
            else
                ok, err = pcall(function() return AI.ClearAnimationTag(g.entity.id, tag) end)
            end
            System.LogAlways(string.format("[KCD2-MP] %s AnimationTag('%s') ghost %s ok=%s err=%s",
                op, tag, tostring(id), tostring(ok), tostring(err)))
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to tag") end
end

-- mp_combat_frag <name> [tags] (WO-39): configure the Mannequin fragment the
-- swing apply path tries before the CAF one-shot. Live-tuning tool -- once a
-- session finds a working fragment, it gets hardcoded as the default.
function KCD2MP_SetCombatFragment(line)
    line = tostring(line or "")
    local name, tags = line:match("^(%S+)%s*(.*)$")
    KCD2MP.combatSwingFragment = (name ~= "" and name) or nil
    KCD2MP.combatSwingFragTags = tags or ""
    System.LogAlways("[KCD2-MP] combatSwingFragment=" .. tostring(KCD2MP.combatSwingFragment)
        .. " tags='" .. tostring(KCD2MP.combatSwingFragTags) .. "'")
end


KCD2MP.modules.commands = true
