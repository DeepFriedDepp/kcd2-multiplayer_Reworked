-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log
local lerpVal = KCD2MP.util.lerp
local lerpAngle = KCD2MP.util.lerpAngle
local tickAlive = KCD2MP.util.tickAlive
local mp_remove_entity_verified = KCD2MP.util.removeEntityVerified
local sampleGhostHealth = KCD2MP.util.sampleGhostHealth

-- ===== Animation Update =====

-- Sneak animation candidates (probed on first use, result cached).
local SNEAK_WALK_ANIMS = {
    "3d_sneak_walk_turn_strafe",
    "3d_sneaking_walk_turn_strafe",
    "3d_stealth_walk_turn_strafe",
    "3d_crouch_walk_turn_strafe",
}
local SNEAK_IDLE_ANIMS = {
    "sneak_idle_both",
    "sneaking_idle_both",
    "stealth_idle_both",
    "crouch_idle_both",
}
KCD2MP._sneakWalkAnim = nil
KCD2MP._sneakIdleAnim = nil

-- Jump animation candidates (WO-38 Phase 3, Section A). Same probe-on-first-
-- use pattern as every other list here: findAnim keeps the first name the
-- entity actually has (GetAnimationLength > 0), so unverified candidates
-- cost one probe each, once, and a wrong guess can never play. If none probe
-- out, the ghost keeps its locomotion animation while airborne (legs keep
-- moving), which is still strictly better than the reported stiff teleport.
--
-- WO-40 Phase 8: the list is now led by REAL clip names read from
-- Animations.pak's male.animevents this session (plain one-shot .caf files,
-- the class that renders via StartAnimation -- not the 1d_jump_* blendspaces,
-- which never render). The old WO-38 guesses stay as a tail.
local JUMP_ANIMS = {
    "relaxed_jump_idle",                 -- full in-place jump (Animations.pak, WO-40)
    "relaxed_run_jump_rleg_start",       -- moving jump, start half
    "relaxed_jump_start",                -- start half (pairs with land)
    "relaxed_walk_jump_lleg_start",
    "3d_relaxed_jump", "3d_jump", "relaxed_jump", "jump",
    "3d_relaxed_jump_turn_strafe", "jump_both", "relaxed_jump_both",
    "3d_relaxed_run_jump", "run_jump", "walk_jump",
}
KCD2MP._jumpAnim = nil   -- nil=not probed yet, false=probed and none found, string=found

-- WO-40 Phase 8: fence-vault candidates -- the same real-clip sweep. The
-- game's own JumpOver Mannequin fragment plays exactly
-- relaxed_jump_over_obstacle_idle_high (read from kcd_male_database.adb).
-- Same probe pattern; used by the airborne branch when the arc looks like a
-- vault (low vertical speed but a z step up), live-tuning deferred -- for
-- now the list rides behind mp_combat_frag-style manual probing and the
-- jump branch's fallback ordering.
local VAULT_ANIMS = {
    "relaxed_jump_over_obstacle_idle_low",
    "relaxed_jump_over_obstacle_idle_high",
    "relaxed_jump_over_obstacle_lleg_walk_low",
    "relaxed_jump_over_obstacle_lleg_run_low",
}
KCD2MP._vaultAnim = nil

-- Riding animation candidates (probed on first use, result cached).
-- false = probed but none found (avoid re-probing every tick).
local RIDING_IDLE_ANIMS = {
    -- Confirmed working on KCD2 NPC class:
    "horse_idle",
    -- Simple names
    "riding_idle", "riding_idle_both", "horse_riding_idle",
    "mounted_idle", "horseback_idle", "cavalry_idle",
    -- 3d_ prefix (confirmed KCD2 convention)
    "3d_riding_idle", "3d_riding_idle_both",
    "3d_horse_idle", "3d_horse_idle_both",
    "3d_horseback_idle", "3d_mounted_idle",
    "3d_relaxed_horse_idle", "3d_relaxed_horse_idle_both",
    "3d_relaxed_riding_idle", "3d_relaxed_riding_idle_both",
    -- relaxed_ prefix (confirmed KCD2 convention)
    "relaxed_riding_idle", "relaxed_riding_idle_both",
    "relaxed_horse_idle", "relaxed_horse_idle_both",
    -- wagon / sit (seated pose that might work)
    "wagon_idle", "wagon_idle_both", "wagon_ride_idle",
    "sit_idle", "sit_idle_both", "3d_sit_idle",
    "seated_idle", "seated_idle_both",
    -- combat horse
    "combat_horse_idle", "combat_horse_idle_both",
    "3d_combat_horse_idle", "3d_combat_horse_idle_both",
    -- act / mm prefix
    "act_horse_idle", "mm_horse_idle",
    -- npc specific
    "npc_horse_idle", "npc_riding_idle",
}
local RIDING_GALLOP_ANIMS = {
    -- Based on confirmed idle pattern: 1d_idle_slope_relaxed_idle_rider_01
    "1d_gallop_slope_relaxed_gallop_rider_01",
    "1d_canter_slope_relaxed_canter_rider_01",
    "1d_trot_slope_relaxed_trot_rider_01",
    "1d_walk_slope_relaxed_walk_rider_01",
    -- Other candidates
    "horse_gallop", "horse_run", "horse_trot", "horse_canter",
    "riding_gallop", "riding_gallop_both",
    "3d_riding_gallop", "3d_horse_gallop",
    "relaxed_horse_run", "combat_horse_run", "mounted_gallop",
}
KCD2MP._ridingIdleAnim  = nil   -- nil=not probed yet, false=not found, string=found
KCD2MP._ridingGallopAnim = nil

-- Horse entity animation candidates (Horse class entity, not NPC riding).
local HORSE_ENTITY_IDLE_ANIMS = {
    -- Confirmed present on KCD2 horse entities (from mp_scan_horse on real game horse):
    "relaxed_idle",
    -- Other candidates:
    "idle", "stand", "horse_idle", "animal_idle",
    "idle_loop", "horse_idle_loop", "stand_loop",
    "loco_idle", "act_idle", "mm_idle",
    "walk_idle", "stand_idle",
    "horse_stand", "horse_stand_idle", "horse_rest",
}
-- Separate walk vs gallop so we don't accidentally use relaxed_walk for full gallop.
local HORSE_ENTITY_WALK_ANIMS = {
    "relaxed_walk", "relaxed_trot",
    "horse_walk", "horse_trot", "walk", "trot",
}
local HORSE_ENTITY_GALLOP_ANIMS = {
    -- Fastest gaits first — confirmed on KCD2 horse entities:
    "relaxed_gallop", "relaxed_canter", "relaxed_run",
    -- Other candidates:
    "gallop", "canter", "run",
    "horse_gallop", "horse_canter", "horse_run",
    "horse_loco_gallop", "horse_loco_run",
    "animal_gallop", "animal_run",
    "loco_gallop", "loco_run",
}
KCD2MP._horseEntityIdleAnim   = nil  -- nil=not probed, false=not found, string=found
KCD2MP._horseEntityWalkAnim   = nil
KCD2MP._horseEntityGallopAnim = nil

local function findAnim(entity, candidates)
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = entity:GetAnimationLength(0, name) or 0 end)
        if len > 0 then return name end
    end
    return nil
end

-- ===== Combat visibility, inbound half (WO-39 Phase 1) =====
--
-- Swing/block one-shot candidates, LIVE-TUNED 2026-08-18 against the real
-- Mannequin databases (kcd_male_combat_database.adb + _generated.adb,
-- extracted from Animations.pak) and eyeball-verified on a live ghost.
-- What that session established, so nobody re-walks it:
--   - REAL full swings are 1d- blendspaces (parametric by attack angle).
--     StartAnimation "starts" them (returns true) but they never render,
--     and the plain "natk_slash_*_upper" clips are upper-guard partials
--     that read as blocking. Swings are Mannequin-locked on this build.
--   - Human.PlayAnim(fragment, tags) executes fault-free and renders
--     NOTHING for FreeAttack/CombatAttack/CombatHit/FreeBlock on a ghost.
--   - What DOES render correctly via StartAnimation: guard idles, the
--     dz "blk" block reactions, hit "flinch" reactions, and guard
--     TRANSITIONS. Naming decode: lg/rg = left/right guard (rg raises the
--     sword arm and reads correctly; lg raises the EMPTY left arm and
--     reads like phantom-shield blocking), sz = distance zone, az/dz =
--     attack/defense zone.
-- The swing cue therefore is a fast right-to-left guard transition -- a
-- big lateral sword move, human-confirmed "usable" as an attack read at a
-- few metres -- played at SWING_ANIM_SPEED. Not a true swing; the honest
-- reachable ceiling this build gives us.
local COMBAT_SWING_ANIMS = {
    "combat_rg_sz1_idle_to_lg_sz0_idle_lngsw",   -- CONFIRMED live 2026-08-18
    "combat_rg_sz1_idle_to_rg_sz5_idle_lngsw",   -- confirmed exists; second choice
}
local SWING_ANIM_SPEED = 1.6   -- the transition reads as a strike at this rate
local COMBAT_BLOCK_ANIMS = {
    "combat_rg_sz1_dz0_blk_slash_lngsw",         -- CONFIRMED live 2026-08-18
    "combat_free_blk_lngsw_player_over",         -- exists; long hold, worse read
}
-- Weapon-ready idle for a ghost whose owner has their weapon drawn, so the
-- drawn state reads at a glance even between swings. Right guard: the
-- sword arm is the raised one.
local COMBAT_IDLE_ANIMS = {
    "combat_rg_sz1_idle_lngsw_player",           -- CONFIRMED live 2026-08-18
    "combat_lg_sz0_idle_lngsw_player",           -- exists; reads shield-y (left guard)
}
KCD2MP._swingAnim = nil        -- nil=not probed, false=none found, string=found
KCD2MP._blockAnim = nil
KCD2MP._combatIdleAnim = nil

-- Mannequin escape hatch: Human.PlayAnim(fragmentName, tags) is documented
-- and may reach the real combat fragments that raw StartAnimation cannot.
-- Fragment names cannot be probed by GetAnimationLength, so this route stays
-- OFF until a live session finds a working name and sets it here (or via
-- mp_combat_frag). When set, it is tried before the CAF one-shot.
KCD2MP.combatSwingFragment = nil   -- e.g. "MeleeAttack"
KCD2MP.combatSwingFragTags = ""

-- WO-43: every prior live attempt on this route (WO-39 empty tags, WO-40
-- generic tags like "lngsw") used GUESSED fragment/tag data, never a real
-- shipped Mannequin row. docs/WO-42-findings.md §9.2 extracted real rows
-- straight from Tables.pak; this is one, verbatim, for a human/human sync
-- attack (not invented -- do not substitute a guessed tag string here):
--   mp_combat_frag CombatAttackSyncGen l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
-- Untried before WO-43. If this still renders nothing on a real ghost in a
-- real fight, that is evidence against "the tags were just wrong" and for
-- the guard/gate explanation combat_playanim.cpp's native probe checks.

-- WO-40 Phase 6: paired takedown cue on a puppet KO transition. Called from
-- KCD2MP_ApplyNpcState (defined earlier; Lua resolves this global at call
-- time, after the whole file has loaded). Clip names come from the
-- Animations.pak sweep (plain .caf clips, the class that renders via
-- StartAnimation) -- probed with findAnim, none-found degrades to the
-- existing KO freeze.
local TAKEDOWN_MASTER_ANIMS = {
    "stealth_kill_hand_stand_success_start_m",   -- choke-out, perpetrator half
    "combat_takedown_back_nw_nw_m",              -- unarmed takedown, perpetrator
}
local TAKEDOWN_VICTIM_ANIMS = {
    "stealth_kill_hand_stand_success_start_s",   -- choke-out, victim half
    "combat_takedown_back_nw_nw_s",              -- unarmed takedown, victim
}
KCD2MP._takedownMasterAnim = nil   -- nil=not probed, false=none, string=found
KCD2MP._takedownVictimAnim = nil

function KCD2MP_NpcTakedownCue(name, e, x, y, z)
    local p = KCD2MP.npcPuppets[name]
    -- Victim half on the NPC itself.
    if KCD2MP._takedownVictimAnim == nil then
        KCD2MP._takedownVictimAnim = findAnim(e, TAKEDOWN_VICTIM_ANIMS) or false
        mp_log("TakedownVictimAnim: " .. tostring(KCD2MP._takedownVictimAnim))
    end
    if KCD2MP._takedownVictimAnim then
        local len = 0
        pcall(function() len = e:GetAnimationLength(0, KCD2MP._takedownVictimAnim) or 0 end)
        pcall(function() e:StartAnimation(0, KCD2MP._takedownVictimAnim, 0, 0.1, 1.0, false) end)
        if p then p.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5) end
    end
    -- Master half on the nearest ghost within arm's reach.
    local best, bestD2 = nil, 6.25
    for _, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            local gp = nil
            pcall(function() gp = g.entity:GetWorldPos() end)
            if gp then
                local gdx, gdy = gp.x - x, gp.y - y
                local d2 = gdx * gdx + gdy * gdy
                if d2 < bestD2 then best, bestD2 = g, d2 end
            end
        end
    end
    if best then
        if KCD2MP._takedownMasterAnim == nil then
            KCD2MP._takedownMasterAnim = findAnim(best.entity, TAKEDOWN_MASTER_ANIMS) or false
            mp_log("TakedownMasterAnim: " .. tostring(KCD2MP._takedownMasterAnim))
        end
        if KCD2MP._takedownMasterAnim then
            local len = 0
            pcall(function() len = best.entity:GetAnimationLength(0, KCD2MP._takedownMasterAnim) or 0 end)
            pcall(function() best.entity:StartAnimation(0, KCD2MP._takedownMasterAnim, 0, 0.1, 1.0, false) end)
            if best.istate then
                best.istate.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5)
            end
        end
    end
    mp_log(string.format("NPC-SYNC takedown cue %s (victim=%s master=%s ghost=%s)",
        name, tostring(KCD2MP._takedownVictimAnim), tostring(KCD2MP._takedownMasterAnim),
        best and "yes" or "none-near"))
end

-- WO-40 Phase 6: the puppet-side swing cue -- same clip, speed and one-shot
-- window as the ghost swing cue, applied to an NPC puppet.
function KCD2MP_PuppetSwingCue(name, p, e)
    if KCD2MP._swingAnim == nil then
        KCD2MP._swingAnim = findAnim(e, COMBAT_SWING_ANIMS) or false
        mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
    end
    if not KCD2MP._swingAnim then return end
    local len = 0
    pcall(function() len = e:GetAnimationLength(0, KCD2MP._swingAnim) or 0 end)
    pcall(function() e:StartAnimation(0, KCD2MP._swingAnim, 0, 0.08, SWING_ANIM_SPEED, false) end)
    local dur = (len > 0 and len or 0.8) / SWING_ANIM_SPEED
    p.oneShotUntil = os.clock() + math.min(dur, 1.5)
    p.animTag = "swing"   -- locomotion re-asserts itself after the window
    mp_log("NPC-SYNC swing cue " .. name)
end

-- WO-49: the Lua half of a NATIVE puppet swing (KCD2MP_GhostNativeSwingHold's
-- twin for NPC puppets): the agent queues the real Mannequin combat action
-- through the DLL; this only pauses the puppet's per-tick writes so they do
-- not stomp the playing action (WO-39's one-shot lesson). No clip is started
-- here -- the native action owns the render. Clears any pending Lua cue so a
-- packet that raced both paths cannot double-render.
function KCD2MP_NpcNativeSwingHold(name)
    local p = KCD2MP.npcPuppets[name]
    if p then
        p.swingCuePending = nil
        p.oneShotUntil = os.clock() + 0.9
        p.animTag = "swing"   -- locomotion re-asserts itself after the window
    end
end

-- WO-49: agent-called fallback when the native swing did not apply (DLL
-- absent, stale entity id after a save reload) -- re-arms the WO-40 cue the
-- agent stripped from the flags byte, late but visible.
function KCD2MP_NpcSwingCueFallback(name)
    local p = KCD2MP.npcPuppets[name]
    if p and not p.dead and not p.ko then p.swingCuePending = true end
end

-- WO-49: agent-pushed note that this NPC's main-hand weapon lives in the
-- Oversized equip slot; the puppet tick's draw then goes through
-- DrawFromInventory instead of DrawWeapon (see the draw branch).
function KCD2MP_NpcSetOversized(name, classGuid)
    KCD2MP.npcOversized = KCD2MP.npcOversized or {}
    KCD2MP.npcOversized[name] = tostring(classGuid)
end

-- WO-40 Phase 6: probe-once accessor for the weapon-ready guard idle, shared
-- with the ghost path's cache.
function KCD2MP_CombatIdleFor(e)
    if KCD2MP._combatIdleAnim == nil then
        KCD2MP._combatIdleAnim = findAnim(e, COMBAT_IDLE_ANIMS) or false
        mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
    end
    return KCD2MP._combatIdleAnim or nil
end

-- Applies one peer combat event to that peer's ghost. evt matches Protocol's
-- combat event bytes: 0=drawn, 1=sheathed, 2=swing, 3=block. Unknown values
-- are ignored, so a newer peer can emit events this build has no name for.
-- Everything here is cosmetic; no health is touched on any path.
function KCD2MP_GhostCombat(id, evt)
    id = tostring(id)
    evt = tonumber(evt)
    if evt == nil then return end
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity) then return end

    if evt == 0 or evt == 1 then
        local wantDrawn = (evt == 0)
        local isDrawn = KCD2MP.ghostWeaponDrawn[id] and true or false
        if isDrawn == wantDrawn then return end   -- heartbeat re-emits land here
        KCD2MP.ghostWeaponDrawn[id] = wantDrawn or nil
        if ghost.entity.human then
            if wantDrawn then
                -- Confirmed live (WO-16/17): draws the ghost's real equipped
                -- weapon item, when the appearance layer has given it one.
                pcall(function() ghost.entity.human:DrawWeapon() end)
            else
                pcall(function() ghost.entity.human:HolsterWeapon() end)
            end
        end
        mp_log("CombatViz: ghost " .. id .. (wantDrawn and " drew weapon" or " sheathed weapon"))
        return
    end

    if evt == 2 or evt == 3 then
        -- Mannequin route first, when a live session has configured it.
        if evt == 2 and KCD2MP.combatSwingFragment and ghost.entity.human then
            local ok = pcall(function()
                ghost.entity.human:PlayAnim(KCD2MP.combatSwingFragment, KCD2MP.combatSwingFragTags or "")
            end)
            if ok then
                if ghost.istate then ghost.istate.oneShotUntil = os.clock() + 1.0 end
                return
            end
        end

        local anim
        if evt == 2 then
            if KCD2MP._swingAnim == nil then
                KCD2MP._swingAnim = findAnim(ghost.entity, COMBAT_SWING_ANIMS) or false
                mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
            end
            anim = KCD2MP._swingAnim
        else
            if KCD2MP._blockAnim == nil then
                KCD2MP._blockAnim = findAnim(ghost.entity, COMBAT_BLOCK_ANIMS) or false
                mp_log("BlockAnim: " .. tostring(KCD2MP._blockAnim))
            end
            anim = KCD2MP._blockAnim
        end
        if not anim then return end

        -- Swings play fast (the guard transition reads as a strike at 1.6x,
        -- confirmed live); blocks at natural speed. The one-shot window is
        -- the played duration, so the speed divides the length.
        local speed = (evt == 2) and SWING_ANIM_SPEED or 1.0
        local len = 0
        pcall(function() len = ghost.entity:GetAnimationLength(0, anim) or 0 end)
        pcall(function() ghost.entity:StartAnimation(0, anim, 0, 0.08, speed, false) end)
        -- Hold the one-shot: KCD2MP_UpdateAnimation restarts locomotion every
        -- tick and would stomp this on the very next one (confirmed live:
        -- one-shots were invisible until the loop was suppressed). Capped so
        -- a bad length can never freeze the ghost for long. istate always
        -- exists on a spawned ghost; a half-spawned one has no loop to fight.
        if ghost.istate then
            local dur = (len > 0 and len or 0.8) / speed
            ghost.istate.oneShotUntil = os.clock() + math.min(dur, 1.5)
        end
    end
end

-- Local eyeball test: play a combat event on every ghost in this world with
-- no wire involved (mp_ghost_combat <0|1|2|3>). The apply path is identical
-- to a real inbound packet.
-- WO-46: the Lua half of a NATIVE swing. The agent queues the real Mannequin
-- combat action through the DLL (a full swing, WO-45); this only holds the
-- one-shot window so KCD2MP_UpdateAnimation's per-tick locomotion restart
-- does not fight the playing action on a moving ghost. No clip is started
-- here -- the native action owns the render.
function KCD2MP_GhostNativeSwingHold(id)
    local ghost = KCD2MP.ghosts[tostring(id)]
    if ghost and ghost.istate then
        ghost.istate.oneShotUntil = os.clock() + 0.9
    end
end

-- WO-47: draw a SPECIFIC inventory item into the ghost's hands, for weapon
-- classes DrawWeapon() ignores (equip_slot="Oversized": halberds/polearms).
-- Live-verified this session: EquipItem reports a polearm equipped but never
-- attaches the model, DrawWeapon() draws the sidearm instead, and
-- human:DrawFromInventory(item, 0, true) is the one call that puts the
-- polearm in hand. ORDER MATTERS (live-observed): DrawFromInventory AFTER a
-- DrawWeapon()-style draw suppressed native swing rendering entirely;
-- called INSTEAD of it, swings render. The agent routes a draw event here
-- (rather than KCD2MP_GhostCombat) when its weapon catalog says the ghost's
-- synced main-hand weapon is Oversized.
function KCD2MP_GhostDrawItem(id, classGuid)
    id = tostring(id)
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity and ghost.entity.human and ghost.entity.inventory) then return end
    if KCD2MP.ghostWeaponDrawn[id] then return end   -- heartbeat re-emits land here
    local drew = false
    pcall(function()
        local it = ghost.entity.inventory:FindItem(tostring(classGuid))
        if it then
            ghost.entity.human:DrawFromInventory(it, 0, true)
            drew = true
        end
    end)
    if drew then
        KCD2MP.ghostWeaponDrawn[id] = true
        mp_log("CombatViz: ghost " .. id .. " drew oversized item from inventory")
    else
        -- Item not in the ghost's inventory (appearance apply still in
        -- flight): fall back to the plain draw so the state flag and any
        -- sidearm still behave as before.
        KCD2MP_GhostCombat(id, 0)
    end
end

function KCD2MP_GhostCombatAll(arg)
    local evt = tonumber(arg)
    if evt == nil then
        System.LogAlways("[KCD2-MP] usage: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
        return
    end
    local n = 0
    for id in pairs(KCD2MP.ghosts) do
        KCD2MP_GhostCombat(id, evt)
        n = n + 1
    end
    System.LogAlways("[KCD2-MP] GhostCombatAll evt=" .. evt .. " applied to " .. n .. " ghost(s)")
end

-- One-command probe for the live session: registration checks on the Human
-- binds this layer calls, plus every combat anim candidate that exists on a
-- ghost (all hits, not just the first -- the lists get tuned from this).
function KCD2MP_CombatProbe()
    System.LogAlways("[KCD2-MP] === COMBAT VIZ PROBE ===")
    if player and player.human then
        System.LogAlways("[KCD2-MP] player.human.IsWeaponDrawn=" .. tostring(type(player.human.IsWeaponDrawn)))
        System.LogAlways("[KCD2-MP] player.human.DrawWeapon="    .. tostring(type(player.human.DrawWeapon)))
        System.LogAlways("[KCD2-MP] player.human.HolsterWeapon=" .. tostring(type(player.human.HolsterWeapon)))
        System.LogAlways("[KCD2-MP] player.human.PlayAnim="      .. tostring(type(player.human.PlayAnim)))
        local d = "?"
        pcall(function() d = tostring(player.human:IsWeaponDrawn()) end)
        System.LogAlways("[KCD2-MP] IsWeaponDrawn() now=" .. d)
    else
        System.LogAlways("[KCD2-MP] player.human is nil")
    end
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do if g.entity then ghost = g; break end end
    if not ghost then
        System.LogAlways("[KCD2-MP] no ghost to probe anims on (spawn one first)")
        return
    end
    local lists = { SWING = COMBAT_SWING_ANIMS, BLOCK = COMBAT_BLOCK_ANIMS, CIDLE = COMBAT_IDLE_ANIMS,
                    JUMP = JUMP_ANIMS, VAULT = VAULT_ANIMS,
                    TDWN_M = TAKEDOWN_MASTER_ANIMS, TDWN_S = TAKEDOWN_VICTIM_ANIMS }
    for label, list in pairs(lists) do
        local hits = {}
        for _, nm in ipairs(list) do
            local len = 0
            pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
            if len > 0 then hits[#hits + 1] = string.format("%s=%.2f", nm, len) end
        end
        System.LogAlways("[KCD2-MP] " .. label .. ": " .. (#hits > 0 and table.concat(hits, ", ") or "none"))
    end
    System.LogAlways("[KCD2-MP] ghost.human=" .. tostring(ghost.entity.human ~= nil)
        .. " HolsterWeapon=" .. tostring(ghost.entity.human and type(ghost.entity.human.HolsterWeapon) or "n/a")
        .. " PlayAnim=" .. tostring(ghost.entity.human and type(ghost.entity.human.PlayAnim) or "n/a"))
    System.LogAlways("[KCD2-MP] === END ===")
end

-- mp_entity_id [name] (WO-43): print the raw CryEngine entity id for a named
-- entity, or every current ghost's id if no name is given. This is the value
-- kcdmp-playanim.txt's first line needs for the arbitrary-actor case of the
-- native PlayAnim diagnostic in combat_playanim.cpp -- that file cannot look
-- an entity up by name itself, only by this numeric id.
function KCD2MP_ReportEntityId(name)
    name = tostring(name or "")
    if name ~= "" then
        local e = System.GetEntityByName(name)
        System.LogAlways("[KCD2-MP] " .. name .. " id=" .. tostring(e and e.id or "not found"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            System.LogAlways("[KCD2-MP] ghost " .. tostring(id) .. " (" ..
                tostring(g.spawnName or ("kcd2mp_" .. tostring(id))) .. ") id=" .. tostring(g.entity.id))
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no spawned ghosts to report") end
end

-- Hysteresis thresholds (m/s).
-- Different enter/exit speeds prevent oscillation when speed hovers at a boundary.
-- Enter: must EXCEED this speed to switch INTO this state.
-- Exit:  must DROP BELOW this speed to switch OUT of this state (go lower).
local ANIM_UP   = { walk=1.0, run=2.5, sprint=4.0 }
local ANIM_DOWN = { walk=0.4, run=1.8, sprint=3.2 }

local function calcAnimTag(speed, cur, stance)
    if stance == "c" then
        return speed > 0.3 and "sneak_walk" or "sneak_idle"
    end
    -- Start from current tag and check if we cross hysteresis bands.
    local t = cur or "idle"
    if t == "sprint" then
        if speed < ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed <  ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed >= ANIM_UP.run     then return "run"
        elseif speed <  ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    -- idle / sneak states
    if     speed >= ANIM_UP.sprint then return "sprint"
    elseif speed >= ANIM_UP.run    then return "run"
    elseif speed >= ANIM_UP.walk   then return "walk"
    else                                 return "idle" end
end

function KCD2MP_UpdateAnimation(id, ghost)
    local istate = ghost.istate

    -- WO-39: a one-shot combat animation (swing/block) is mid-play. This
    -- function restarts locomotion every tick, which would stomp it on the
    -- next tick -- so hold off until the one-shot's window expires. Checked
    -- before everything else, jump included: a swing beats an air-frame.
    if istate.oneShotUntil then
        if os.clock() < istate.oneShotUntil then return end
        istate.oneShotUntil = nil
    end

    local speed = istate.smoothedSpeed or 0
    local stance = istate.stance or "s"

    -- Sanity: can't be sneaking at running speeds (auto-clears bad toggle state)
    if stance == "c" and speed > 4.0 then stance = "s" end
    local wantTag = calcAnimTag(speed, istate.animTag, stance)

    -- WO-38 Phase 3 (Section A): a jump used to render as a stationary
    -- vertical teleport, because this function only ever saw horizontal
    -- speed. While the interp tick reports the ghost airborne, play a jump
    -- animation if this build has one; if the probe finds none, fall through
    -- to the ordinary locomotion tag rather than freezing.
    if istate.isAirborne and stance ~= "c" then
        -- WO-40 live battery: the MotionJump Mannequin fragment RENDERS via
        -- Human.PlayAnim on a ghost (eyeball-confirmed 2026-08-20 -- the
        -- first fragment ever seen rendering; combat fragments stay locked).
        -- It is the game's own jump, with proc layers a raw clip lacks, so
        -- it goes first: once per airborne episode, not per tick.
        if not istate.jumpFragPlayed and ghost.entity.human then
            istate.jumpFragPlayed = true
            local okJ = pcall(function() ghost.entity.human:PlayAnim("MotionJump", "") end)
            if okJ then
                istate.oneShotUntil = os.clock() + 0.9
                if istate.animTag ~= "jump" then
                    mp_log(string.format("Anim: %s %s->jump (MotionJump fragment)", id, istate.animTag or "?"))
                    istate.animTag = "jump"
                end
                return
            end
        end
        if istate.animTag == "jump" then return end  -- fragment already playing
        if KCD2MP._jumpAnim == nil then
            KCD2MP._jumpAnim = findAnim(ghost.entity, JUMP_ANIMS) or false
            mp_log("JumpAnim: " .. tostring(KCD2MP._jumpAnim))
        end
        if KCD2MP._jumpAnim then
            pcall(function() ghost.entity:StartAnimation(0, KCD2MP._jumpAnim, 0, 0.1, 1.0, false) end)
            if istate.animTag ~= "jump" then
                mp_log(string.format("Anim: %s %s->jump vz-driven", id, istate.animTag or "?"))
                istate.animTag = "jump"
            end
            return
        end
    elseif istate.jumpFragPlayed then
        istate.jumpFragPlayed = nil   -- re-arm for the next airborne episode
    end

    local animName
    if wantTag == "sneak_walk" then
        if not KCD2MP._sneakWalkAnim then
            KCD2MP._sneakWalkAnim = findAnim(ghost.entity, SNEAK_WALK_ANIMS)
                                    or "3d_relaxed_walk_turn_strafe"
            mp_log("SneakWalkAnim: " .. KCD2MP._sneakWalkAnim)
        end
        animName = KCD2MP._sneakWalkAnim
    elseif wantTag == "sneak_idle" then
        if not KCD2MP._sneakIdleAnim then
            KCD2MP._sneakIdleAnim = findAnim(ghost.entity, SNEAK_IDLE_ANIMS)
                                    or "relaxed_idle_both"
            mp_log("SneakIdleAnim: " .. KCD2MP._sneakIdleAnim)
        end
        animName = KCD2MP._sneakIdleAnim
    else
        local anims = {
            sprint = "3d_relaxed_sprint_turn_strafe",
            run    = "3d_relaxed_run_turn_strafe",
            walk   = "3d_relaxed_walk_turn_strafe",
            idle   = "relaxed_idle_both",
        }
        animName = anims[wantTag]
        -- WO-39: a ghost whose owner has their weapon drawn idles in a
        -- weapon-ready stance when this build has one, so the drawn state
        -- reads at a glance between swings. Probe-on-first-use like every
        -- other list; none-found keeps the relaxed idle.
        if wantTag == "idle" and KCD2MP.ghostWeaponDrawn[id] then
            if KCD2MP._combatIdleAnim == nil then
                KCD2MP._combatIdleAnim = findAnim(ghost.entity, COMBAT_IDLE_ANIMS) or false
                mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
            end
            if KCD2MP._combatIdleAnim then animName = KCD2MP._combatIdleAnim end
        end
    end

    -- Call StartAnimation every tick to override Mannequin's idle.
    -- blend=0.15s: short enough to react quickly, long enough to not look choppy.
    pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.15, 1.0, true) end)

    -- Log only when tag actually changes
    if istate.animTag ~= wantTag then
        mp_log(string.format("Anim: %s %s->%s spd=%.2f", id, istate.animTag or "?", wantTag, speed))
        istate.animTag = wantTag
    end
end

-- ===== Interpolation Tick (20ms) =====

-- Floor detection: physics raycast hits real geometry (roads, rocks, bridges).
-- Falls back to terrain elevation if raycast unavailable.
local function getFloorZ(x, y, curZ)
    local floorZ = nil
    local reliable = false

    -- Physics raycast: origin 2m above ghost, ray goes 12m DOWN.
    -- Direction vector magnitude = ray length in CryEngine: {z=-12} = 12m downward.
    -- This covers range [curZ+2 .. curZ-10] - hits bridges, stairs, terrain.
    -- Flags 15 = ent_terrain(1)|ent_static(2)|ent_rigid(4)|ent_sleeping_rigid(8)
    pcall(function()
        local hits = Physics.RayWorldIntersection(
            {x=x, y=y, z=curZ + 2.0},
            {x=0,  y=0, z=-12},
            15,
            1
        )
        if hits and hits[1] then
            local h = hits[1]

            -- Log raycast field layout once (helps identify correct field name)
            if not KCD2MP._rayFmtLogged then
                KCD2MP._rayFmtLogged = true
                local parts = {}
                for k, v in pairs(h) do
                    if type(v) == "number" then
                        parts[#parts+1] = k .. "=" .. string.format("%.2f", v)
                    elseif type(v) == "table" then
                        parts[#parts+1] = k .. "={z=" .. tostring(v.z) .. "}"
                    end
                end
                mp_log("RAY_FORMAT: " .. table.concat(parts, " "))
            end

            -- CryEngine may return hit point as h.pt, h.pos, or h.point
            local hz = nil
            if     h.pt    then hz = h.pt.z
            elseif h.pos   then hz = h.pos.z
            elseif h.point then hz = h.point.z
            end
            -- Accept hits within 10m below current position
            if hz and hz > curZ - 10.0 then
                floorZ   = hz
                reliable = true
            end
        end
    end)

    -- Fallback to terrain mesh (underestimates height on bridges/platforms)
    if not floorZ then
        pcall(function()
            local gz = Terrain.GetElevation(x, y)
            if gz then floorZ = gz end
        end)
    end

    return floorZ, reliable
end

-- `arg` is the timer id when this fires from Script.SetTimer, and the string
-- "ext" when the agent pumps it in through ExecuteString while a local menu
-- has focus (WO-13). Compared against the sentinel rather than tested for
-- truthiness, because a real timer id is truthy too.
--
-- A pumped call must NOT reschedule. Script.SetTimer is frozen for the whole
-- duration of a local menu (WO-12 s0.3), so every timer queued by a pumped
-- call would still be pending when the menu closes and fire as one burst.
function KCD2MP_InterpTick(arg)
    if not KCD2MP.interpRunning then return end
    if arg ~= "ext" then
        Script.SetTimer(20, KCD2MP_InterpTick)  -- reschedule FIRST: crash-safe, tick never stops
        -- Only a scheduled fire counts as the chain being alive. A pumped call
        -- must not stamp this, or the pump would make a dead chain look
        -- healthy and stop KCD2MP_StartInterp from ever rebuilding it.
        KCD2MP._interpAliveAt = os.clock()
    end

    -- Heartbeat: confirm tick is alive (every ~5s = 250 * 20ms)
    KCD2MP._tickN = (KCD2MP._tickN or 0) + 1
    if KCD2MP._tickN % 250 == 0 then
        local gc = 0; for _ in pairs(KCD2MP.ghosts) do gc = gc + 1 end
        mp_log("TICK_ALIVE #" .. KCD2MP._tickN .. " ghosts=" .. gc)
    end

    -- Fetch player position once per tick for label distance calculations.
    local _playerPos = nil
    if player then pcall(function() _playerPos = player:GetWorldPos() end) end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local _ok, _err = pcall(function()  -- catch any crash, keep tick alive
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1

            -- If ghost drifted very far from target (>5m), teleport directly.
            -- Prevents STEP_CAP from locking ghost hundreds of meters away.
            local distSq = (istate.tx-istate.cx)*(istate.tx-istate.cx)
                         + (istate.ty-istate.cy)*(istate.ty-istate.cy)
                         + (istate.tz-istate.cz)*(istate.tz-istate.cz)
            if distSq > 25.0 then
                mp_log(string.format("TELEPORT id=%s dist=%.1f", id, math.sqrt(distSq)))
                istate.cx = istate.tx
                istate.cy = istate.ty
                istate.cz = istate.tz
                istate.cr = istate.tr
            end

            -- Non-destructive DR: project render target forward WITHOUT touching istate.tx/ty.
            -- istate.tx/ty stays = last received packet. When next packet arrives it's
            -- simply overwritten - no snap-back rubber-band.
            -- DR just makes the ghost look ahead of the last-known position while waiting
            -- for the next packet, keeping movement smooth at sprint speeds.
            --
            -- WO-38 Phase 3 (Section A, the "two steps forward, one step
            -- back"): the old projection reverted to the bare last-packet
            -- position the moment the gap exceeded DR_MAX ticks -- and gaps
            -- exceed it constantly, because delivery is bursty (the
            -- ExecuteString channel runs 60-130 ms warm, WO-30). Every such
            -- revert moved the render target BACKWARD by the projected
            -- amount, which the 0.5 lerp then faithfully rendered as a
            -- visible step back. The projection now HOLDS at the DR_MAX
            -- point instead of reverting; the next real packet simply
            -- overwrites it.
            local renderX = istate.tx or istate.cx
            local renderY = istate.ty or istate.cy
            local DR_MAX = 3  -- 3 * 20ms = 60ms lookahead (covers 50ms packet gap)
            local ticks = istate.ticksSincePacket or 0
            if ticks >= 1 then
                local vx = istate.vx or 0
                local vy = istate.vy or 0
                if math.sqrt(vx*vx + vy*vy) > 0.5 then
                    local proj = math.min(ticks, DR_MAX)
                    renderX = renderX + vx * (proj * 0.020)
                    renderY = renderY + vy * (proj * 0.020)
                end
            end

            -- Smooth ghost toward render target (DR-extended, never snaps back).
            --
            -- WO-38 Phase 3: corrections AGAINST the direction of travel are
            -- damped harder than corrections along it. A backward correction
            -- is almost always a stale/regressed target (burst jitter, DR
            -- overshoot), not the player actually moonwalking -- rendering it
            -- at full strength is the visible rubber-band. Forward and
            -- sideways corrections keep the responsive factor.
            local factor = 0.5
            local dxT = renderX - istate.cx
            local dyT = renderY - istate.cy
            local vxS = istate.vx or 0
            local vyS = istate.vy or 0
            if (vxS*vxS + vyS*vyS) > 0.25 and (dxT*vxS + dyT*vyS) < 0 then
                factor = 0.15
            end
            local prevCx = istate.cx
            local prevCy = istate.cy
            local nx = lerpVal(istate.cx, renderX, factor)
            local ny = lerpVal(istate.cy, renderY, factor)
            local nz = istate.tz or istate.cz   -- Z tracks packet directly, no lerp (avoids sinking into rocks)

            istate.cx = nx
            istate.cy = ny
            istate.cz = nz
            istate.cr = lerpAngle(istate.cr, istate.tr, factor)

            local x = istate.cx
            local y = istate.cy
            local z = istate.cz
            local r = istate.cr

            -- WO-38 Phase 3 (Section A jump): airborne detection from the
            -- packet stream's vertical rate. While airborne, the snap-DOWN
            -- below must not fire -- a jump arc peaks well under its 2 m
            -- window, so the snap was flattening the whole arc back onto the
            -- floor. Held briefly past the last upward motion so the falling
            -- half of the arc isn't snapped either.
            local nowClock = os.clock()
            if (istate.vz or 0) > 1.2 and not istate.isRiding then
                istate.airborneUntil = nowClock + 0.6
            end
            local airborne = (istate.airborneUntil or 0) > nowClock

            -- Floor snap: correct ghost Z against raycast floor.
            -- Snap-UP: underground up to 10m (handles slopes, slight embedding).
            -- Snap-DOWN: hovering up to 2m (hover fix; >2m cap prevents snapping off bridges).
            -- Skip floor snap when riding: horse engine handles terrain, NPC follows horse.
            local sz = z
            if not istate.isRiding then
                local floorZ, reliable = getFloorZ(x, y, z)
                if floorZ then
                    local diff = sz - floorZ
                    if diff < -0.05 and diff > -10.0 then
                        -- Underground up to 10m: snap up to floor
                        sz = floorZ
                        istate.cz = floorZ
                    elseif diff > 0.05 and diff < 2.0 and not airborne then
                        -- Hovering up to 2m above floor: snap down
                        sz = floorZ
                    end
                end
            end
            istate.isAirborne = airborne

            -- When nativeMounted, the engine links NPC to horse - skip manual NPC SetWorldPos.
            -- We only update horse position; rider follows automatically.
            --
            -- WO-34 issue D: a corpse must not be dragged. Position sync is an
            -- always-on channel, entirely separate from the 0x23/0x24 death
            -- notification, so until now a ghost that had died -- either
            -- because its owner died, or because an NPC killed it in THIS
            -- world -- kept having SetWorldPos written onto it every 20 ms and
            -- slid around the map tracking a live player. Reported from a real
            -- two-player session: "once the NPC killed his stand in the dead
            -- body moved around where he did."
            --
            -- Frozen means: stop writing position and stop driving animation,
            -- but keep the nameplate -- moved onto the body's ACTUAL world
            -- position, not the incoming stream's, or the label would fly off
            -- and leave a nameless corpse behind (the WO-28 Q3 failure shape).
            -- istate keeps integrating normally underneath, so when the ghost
            -- is recycled it starts from the current stream position.
            local ok = true
            local frozen = mp_ghost_is_corpse(id, ghost)
            -- WO-39: a one-shot combat animation (swing/block) pins the ghost
            -- for its duration (<= 1.5 s). Confirmed live: the per-tick
            -- SetWorldPos writes interrupt a one-shot before a single frame
            -- of it renders -- swings played to a stationary unstreamed ghost
            -- and never to a streamed one -- and the z floor-snap fighting
            -- the clip's root motion was the reported up/down phasing during
            -- blocks. istate keeps integrating underneath, exactly like the
            -- frozen case, so the ghost catches up the moment the window ends.
            local oneShot = istate.oneShotUntil and os.clock() < istate.oneShotUntil
            if frozen then
                local wp = nil
                pcall(function() wp = ghost.entity:GetWorldPos() end)
                if wp then x, y, sz = wp.x, wp.y, wp.z end
            elseif oneShot then
                -- no position/angle writes; the one-shot owns the body
            elseif not istate.nativeMounted then
                local _, err = pcall(function()
                    ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                    ghost.entity:SetWorldAngles({x=0, y=0, z=r})
                end)
                if err then
                    System.LogAlways("[KCD2-MP] InterpTick err '" .. id .. "': " .. tostring(err))
                    ghost.entity = nil
                    ok = false
                end
            end
            if ok then
                -- Speed from rendered XY movement this tick
                local movedDx = nx - prevCx
                local movedDy = ny - prevCy
                local rendSpeed = math.sqrt(movedDx*movedDx + movedDy*movedDy) / 0.020
                istate.smoothedSpeed = lerpVal(istate.smoothedSpeed or 0, rendSpeed, 0.4)

                if frozen then
                    -- WO-34 issue D: no animation on a corpse. Driving walk/run
                    -- onto a dead actor is what made the reported body look
                    -- like it was walking around rather than lying where it
                    -- fell. The horse half is skipped for the same reason.
                elseif istate.isRiding then
                    -- One-time riding diagnostic when interp tick first sees this ghost riding.
                    -- (% 50 == 1 never fires: interp=20ms, packets=10ms → only even counts seen)
                    if not istate._rideFirstTick then
                        istate._rideFirstTick = true
                        local hd = KCD2MP.horseGhosts[id]
                        local hasAI = false
                        pcall(function() hasAI = hd and hd.entity and hd.entity.AI ~= nil end)
                        mp_log(string.format("RIDE_FIRST id=%s hasHorse=%s hasAI=%s",
                            id, tostring(hd ~= nil), tostring(hasAI)))
                    end
                    -- Probe valid riding animations once (on first ghost that is riding).
                    if KCD2MP._ridingIdleAnim == nil then
                        KCD2MP._ridingIdleAnim = findAnim(ghost.entity, RIDING_IDLE_ANIMS) or false
                        mp_log("RideIdleAnim: " .. tostring(KCD2MP._ridingIdleAnim))
                    end
                    if KCD2MP._ridingGallopAnim == nil then
                        KCD2MP._ridingGallopAnim = findAnim(ghost.entity, RIDING_GALLOP_ANIMS) or false
                        mp_log("RideGallopAnim: " .. tostring(KCD2MP._ridingGallopAnim))
                    end

                    -- Engine sync auto-assigns idle rider anim at ForceMount time.
                    -- For gallop we must set it explicitly — engine does NOT auto-update.
                    -- ridingFallback: engine failed to mount, set all anims manually.
                    local isGallop = rendSpeed > 3.0
                    if istate.nativeMounted then
                        -- Only override for gallop; leave idle to engine sync system.
                        if isGallop and KCD2MP._ridingGallopAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, KCD2MP._ridingGallopAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    else
                        local rideAnim = (isGallop and KCD2MP._ridingGallopAnim)
                                      or KCD2MP._ridingIdleAnim
                        if rideAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, rideAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    end

                    -- Horse entity origin = ground level (~1.5m below rider/saddle).
                    -- getFloorZ from sz can hit the horse's own physics body (rigid) and return
                    -- a Z close to sz, putting the horse on top of the NPC ghost.
                    -- Fix: use sz-1.5 as default; only accept raycast if it finds ground
                    -- at least 0.5m below saddle (rules out horse/player body hits).
                    local horseGroundZ = sz - 1.5
                    local hFloorZ, _ = getFloorZ(x, y, sz)
                    if hFloorZ and (sz - hFloorZ) >= 0.5 then
                        horseGroundZ = hFloorZ
                    end
                    local horseData = KCD2MP.horseGhosts[id]
                    if horseData and horseData.entity then
                        local dt = 0.020
                        local vx = (x - (horseData.lastX or x)) / dt
                        local vy = (y - (horseData.lastY or y)) / dt
                        local spd = math.sqrt(vx*vx + vy*vy)
                        horseData.lastX = x
                        horseData.lastY = y

                        -- Smooth horse Z and rotation to remove raycast noise / snap artifacts
                        if not horseData.smoothZ then horseData.smoothZ = horseGroundZ end
                        horseData.smoothZ = lerpVal(horseData.smoothZ, horseGroundZ, 0.25)
                        if not horseData.smoothR then horseData.smoothR = r end
                        horseData.smoothR = lerpAngle(horseData.smoothR, r, 0.35)
                        local hz = horseData.smoothZ
                        local hr = horseData.smoothR

                        -- Probe horse entity animations once.
                        if KCD2MP._horseEntityIdleAnim == nil then
                            KCD2MP._horseEntityIdleAnim = findAnim(horseData.entity, HORSE_ENTITY_IDLE_ANIMS) or false
                            mp_log("HorseEntityIdleAnim: " .. tostring(KCD2MP._horseEntityIdleAnim))
                        end
                        if KCD2MP._horseEntityWalkAnim == nil then
                            KCD2MP._horseEntityWalkAnim = findAnim(horseData.entity, HORSE_ENTITY_WALK_ANIMS) or false
                            mp_log("HorseEntityWalkAnim: " .. tostring(KCD2MP._horseEntityWalkAnim))
                        end
                        if KCD2MP._horseEntityGallopAnim == nil then
                            KCD2MP._horseEntityGallopAnim = findAnim(horseData.entity, HORSE_ENTITY_GALLOP_ANIMS) or false
                            mp_log("HorseEntityGallopAnim: " .. tostring(KCD2MP._horseEntityGallopAnim))
                        end

                        -- Store render target for 8ms render loop (avoids 20ms stutter).
                        horseData.renderX = x
                        horseData.renderY = y
                        horseData.renderZ = hz
                        horseData.renderR = hr

                        -- Play horse entity animation based on speed.
                        -- relaxed_idle → engine sync assigns matching rider idle.
                        -- relaxed_gallop → we explicitly set rider gallop above.
                        local horseAnim
                        if spd > 3.0 then
                            horseAnim = KCD2MP._horseEntityGallopAnim or KCD2MP._horseEntityWalkAnim
                        elseif spd > 0.5 then
                            horseAnim = KCD2MP._horseEntityWalkAnim or KCD2MP._horseEntityGallopAnim
                        else
                            horseAnim = KCD2MP._horseEntityIdleAnim
                        end
                        if horseAnim then
                            pcall(function()
                                horseData.entity:StartAnimation(0, horseAnim, 0, 0.2, 1.0, true)
                            end)
                        end
                    end
                    -- NPC ghost Z = sz = packet player Z = saddle height (correct).
                    -- Already set above in the nativeMounted block. No extra offset needed.
                else
                    KCD2MP_UpdateAnimation(id, ghost)
                end

                -- Update label cache for the render loop (runs at 8ms to avoid flicker).
                -- When riding: sz = saddle height, head ~1.3m above saddle.
                -- When on foot: sz = feet, head ~1.8m above feet.
                local displayName = KCD2MP.ghostNames[id] or ("Player" .. tostring(id))
                -- WO-13 Phase 2: a player in a menu is standing perfectly still
                -- and not responding, which reads as broken. Say so instead.
                -- No pose work needed -- KCD2MP_UpdateAnimation already settles
                -- a stationary ghost into its idle animation on its own.
                if KCD2MP.ghostInMenu[id] then
                    displayName = displayName .. " [in menu]"
                end
                -- WO-28 Flow C, before health: a dead player's remaining
                -- number is stale by definition, so saying "dead" and a health
                -- figure at once would be two answers to one question.
                if KCD2MP.ghostDead[id] then
                    displayName = displayName .. " [dead - reloading]"
                else
                    -- WO-28 Flow A. This is the owner's own authoritative
                    -- health, not this world's local copy of the ghost --
                    -- see KCD2MP_SetGhostHealth.
                    local hs = KCD2MP.ghostHealth[id]
                    if hs and hs.h and hs.h >= 0 then
                        displayName = string.format("%s  %d HP", displayName, math.floor(hs.h + 0.5))
                        if hs.s and hs.s >= 0 then
                            displayName = string.format("%s / %d ST", displayName, math.floor(hs.s + 0.5))
                        end
                    end
                end
                -- WO-28 Flow B: sample this ghost's LOCAL health for
                -- NPC-inflicted damage. No-op unless this client holds
                -- NPC→player damage authority.
                sampleGhostHealth(id, ghost)
                local labelZ = sz + (istate.isRiding and 1.1 or 1.8)
                local labelSize = 0  -- 0 = hidden (too far)
                if _playerPos then
                    local dx = x - _playerPos.x
                    local dy = y - _playerPos.y
                    local dz = labelZ - _playerPos.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist <= 60.0 then
                        labelSize = math.max(0.3, math.min(2.0, 10.0 / math.max(dist, 1.0)))
                    end
                end
                KCD2MP.labelCache[id] = {x=x, y=y, z=labelZ, size=labelSize, name=displayName}
            end
        end
        end)  -- end pcall for ghost update
        if not _ok then
            mp_log("InterpTick ERR id=" .. tostring(id) .. ": " .. tostring(_err))
        end
    end

    -- Update local player riding state every 5 ticks (~100ms)
    if KCD2MP._ridingCheckTick == nil then KCD2MP._ridingCheckTick = 0 end
    KCD2MP._ridingCheckTick = KCD2MP._ridingCheckTick + 1
    if KCD2MP._ridingCheckTick >= 5 then
        KCD2MP._ridingCheckTick = 0
        if player then
            local riding = false
            local mountName = nil
            -- Method 0: Find "Horse" class entity within 2.5m of player.
            -- When riding, horse origin is ~1.5m below saddle (player pos).
            -- Exclude our own ghost horses (kcd2mp_horse_*) to avoid false positives.
            pcall(function()
                local pos = player:GetWorldPos()
                if pos then
                    local ents = System.GetEntitiesInSphere(pos, 2.5)
                    if ents then
                        for _, e in ipairs(ents) do
                            local ec = "?"
                            local en = ""
                            pcall(function() ec = tostring(e.class or "?") end)
                            pcall(function() en = tostring(e:GetName() or "") end)
                            if ec == "Horse" and not en:find("kcd2mp_horse_") then
                                -- Require player to be >1.0m ABOVE horse pivot.
                                -- Horse entity pivot is at ground level; when mounted,
                                -- player Z = saddle height (~1.5m above ground).
                                -- Filters false positives when merely standing next to horse.
                                local horsePos = nil
                                pcall(function() horsePos = e:GetWorldPos() end)
                                if horsePos and (pos.z - horsePos.z) > 1.0 then
                                    riding = true
                                    -- WO-38 Phase 5: this IS the mounted horse.
                                    -- Only a plain authored name travels -- it is
                                    -- the cross-client key (same rule as NPC sync);
                                    -- a generated per-save name stays local and the
                                    -- receiver keeps its proxy fallback.
                                    if en ~= "" and string.find(en, "^[%w_]+$") then
                                        mountName = en
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            -- Method 1: KCD2 human:IsRiding() (returns nil in v1.5, kept as fallback)
            if not riding then
                pcall(function()
                    if player.human then
                        local r = player.human:IsRiding()
                        if r then riding = true end
                    end
                end)
            end
            -- Method 2: CryEngine linked parent
            if not riding then
                pcall(function()
                    local p = player:GetLinkedParent()
                    if p then riding = true end
                end)
            end
            KCD2MP.isRiding = riding

            -- WO-38 Phase 5: broadcast which horse we are on, by authored
            -- name, on change plus a slow re-emit while mounted (late
            -- joiners; the relay replays nothing). "-" = dismounted or a
            -- mount whose identity could not be read (methods 1/2 detect
            -- riding without identifying the horse).
            if not riding then mountName = nil end
            KCD2MP._mountedHorseName = mountName
            local wire = mountName or "-"
            local nowC = os.clock()
            if wire ~= KCD2MP._horseInfoSentName
               or (mountName and (nowC - (KCD2MP._horseInfoSentAt or 0)) > 30) then
                KCD2MP._horseInfoSentName = wire
                KCD2MP._horseInfoSentAt = nowC
                KCD2MP_EmitEvent("horse_info", wire)
            end
        end
    end

end

-- ===== Main Tick (500ms) - position reporting =====

function KCD2MP_Tick()
    KCD2MP.tickCount = KCD2MP.tickCount + 1
    local ok, err = pcall(function()
        KCD2MP_WritePos()

        if KCD2MP.tickCount % 20 == 0 then
            local ghostCount = 0
            for _ in pairs(KCD2MP.ghosts) do ghostCount = ghostCount + 1 end
            System.LogAlways(string.format("[KCD2-MP] tick=%d ghosts=%d",
                KCD2MP.tickCount, ghostCount))
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Tick error: " .. tostring(err))
    end
    if KCD2MP.running then
        Script.SetTimer(500, KCD2MP_Tick)
    end
end

-- ===== Ghost reconciliation after a save load (WO-28 Phase 0) =====
--
-- Measured live, 2026-08-07: loading a save destroys every ghost ENTITY in the
-- world, but KCD2MP.ghosts keeps holding the entity table it was given at spawn
-- time. That table stays non-nil -- it is a Lua value, and nothing about the
-- world unload reaches in and clears it -- so KCD2MP_UpdateGhost's own
-- "spawn if missing" test (`if not ghost or not ghost.entity`) reads as
-- "present" forever and the ghost is never respawned.
--
-- What that looks like in game, in the human's own words while it was
-- happening: *"the ghost is invisible for me but I can see its nametag
-- continuing in the same path"* -- because istate keeps taking position
-- packets and KCD2MP_InterpTick keeps writing labelCache from it, with no
-- body under the label. It never recovers on its own.
--
-- The check has to be a real world lookup by spawn name (never the display
-- name -- WO-26 established that is not a key anything resolves by), which is
-- too expensive for the 20 ms interp path. So the agent calls this on a slow
-- cadence instead, the same shape as WO-13's KCD2MP_StartInterp re-arm.
--
-- Deliberately drops only the bookkeeping rather than calling
-- KCD2MP_RemoveGhost: there is no entity left to remove, the display name and
-- menu/health/death tags are all still correct for that player, and the very
-- next position packet respawns the body through the ordinary path.
function KCD2MP_ReconcileGhosts()
    local fixed = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost and ghost.entity then
            local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
            local live = nil
            pcall(function() live = System.GetEntityByName(spawnName) end)
            -- WO-34 issue D, the other half of the freeze. A ghost an NPC
            -- killed in THIS world is a corpse for good -- death is a one-way
            -- transition (WO-25 Phase 3: SetState health writes do not reverse
            -- IsDead) -- so freezing alone would leave its owner permanently
            -- invisible here while they carry on playing. Recycled through the
            -- same path a save-load-destroyed entity takes: drop the
            -- bookkeeping, let the next position packet spawn a fresh body.
            --
            -- Only the ENTITY being dead triggers this. A ghost whose OWNER
            -- died (KCD2MP.ghostDead, tagged "[dead - reloading]") is still a
            -- perfectly good standing body and must NOT be recycled -- WO-28
            -- chose to leave it exactly so a player back in seconds does not
            -- cost a full spawn cycle, and that reasoning is unchanged.
            -- WO-59 Thread B: the name resolving is NOT the tracked body
            -- surviving. A reload of a save that EMBEDS a same-id ghost body
            -- (saved while that ghost stood nearby, reloaded in the same
            -- session so the id matches) destroys the tracked entity but
            -- leaves GetEntityByName answering with the embedded copy -- a
            -- different entity. The old "did the name resolve" test then
            -- passed forever: interp writes went to the destroyed entity,
            -- the nameplate walked on (it renders from the interp table),
            -- and the player was invisible -- WO-28's eyewitness shape,
            -- WO-38 Section G's unexplained report. Compare identities and
            -- treat a mismatch as an imposter: remove the embedded body and
            -- fall through to the normal clear-and-respawn path.
            if live and ghost.entityId and tostring(live.id) ~= tostring(ghost.entityId) then
                mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                       "' resolves to a DIFFERENT entity (save-embedded body?) -- removing the imposter so a fresh ghost respawns")
                mp_remove_entity_verified(live.id, spawnName, "imposter ghost " .. tostring(id))
                live = nil
            end
            local corpse = false
            if live and live.actor then
                pcall(function() corpse = live.actor:IsDead() and true or false end)
            end
            if live and corpse then
                mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                       "' is DEAD in this world -- removing the body so a fresh ghost respawns")
                -- Remove the corpse rather than abandoning it. An untracked
                -- body is what WO-27 spent a session cleaning up, and this one
                -- is also a real lootable/grabbable object that another player
                -- can commit corpseViolation on (docs/WO-34-findings.md).
                mp_remove_entity_verified(ghost.entityId, spawnName, "ghost corpse " .. tostring(id))
                live = nil
            end
            if not live then
                if not corpse then
                    mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                           "' is gone from the world (save load?) -- clearing so it respawns")
                end
                -- The horse half is destroyed by the same unload and tracked
                -- separately, so it has to be dropped too or a remounting
                -- ghost would sit on a horse that no longer exists.
                KCD2MP.horseGhosts[id] = nil
                KCD2MP.ghosts[id] = nil
                KCD2MP.labelCache[id] = nil
                -- The Flow B baseline belonged to the destroyed entity. A
                -- fresh one starts at full health, so keeping it would read as
                -- a large positive delta -- harmless (guard 3 drops it) but
                -- meaningless, and clearing it is what makes that certain.
                KCD2MP.ghostHpSeen[id] = nil
                KCD2MP.ghostHpSkip[id] = nil
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 then
        System.LogAlways("[KCD2-MP] Reconcile: " .. fixed .. " ghost(s) had lost their entity; will respawn")
    end
    return fixed
end

-- ===== Ghost Remove =====

function KCD2MP_RemoveGhost(id)
    local ghost = KCD2MP.ghosts[id]
    if not ghost then return end
    -- Remove horse ghost first (if riding)
    KCD2MP_RemoveHorse(id)
    -- WO-27: was a single unchecked System.RemoveEntity. It returns without
    -- error while leaving the entity standing, which is how orphans survived
    -- every "removal" the mod thought it had done. Look the entity up by the
    -- spawn name -- NOT the display name, which since WO-26 is known not to be
    -- a key anything resolves by (and which this mod no longer sets).
    local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
    if ghost.entityId or spawnName then
        mp_remove_entity_verified(ghost.entityId, spawnName, "ghost " .. tostring(id))
    end
    KCD2MP.ghosts[id] = nil
    KCD2MP.labelCache[id] = nil
    -- A player who disconnects while in a menu must not leave a stale
    -- "[in menu]" tag behind for whoever next reuses this ghost id (WO-13).
    KCD2MP.ghostInMenu[id] = nil
    -- Same reasoning for every WO-28 per-ghost fact: relay ids are reassigned
    -- per connection, so a leftover health figure, death tag or sampler
    -- baseline would be attributed to whoever next gets this id. The sampler
    -- baseline especially -- a stale one would read as an enormous first
    -- delta and fire a fake hit at the new occupant.
    KCD2MP.ghostHealth[id] = nil
    KCD2MP.ghostDead[id] = nil
    KCD2MP.ghostHpSeen[id] = nil
    KCD2MP.ghostHpSkip[id] = nil
    -- WO-39: same id-reuse reasoning -- a stale drawn flag would make whoever
    -- next gets this id spawn weapon-ready for no reason.
    KCD2MP.ghostWeaponDrawn[id] = nil
    System.LogAlways("[KCD2-MP] Removed ghost: " .. id)
    -- Reset riding anim probes: if they were cached while NPC was ForceMount'd they may be
    -- wrong (false). Re-probe on next riding ghost (free NPC → correct results).
    KCD2MP._ridingIdleAnim = nil
    KCD2MP._ridingGallopAnim = nil
end

function KCD2MP_RemoveAllGhosts()
    local count = 0
    for id, _ in pairs(KCD2MP.ghosts) do
        KCD2MP_RemoveGhost(id)
        count = count + 1
    end
    -- Clean up any orphaned horse ghosts
    for id, _ in pairs(KCD2MP.horseGhosts) do
        KCD2MP_RemoveHorse(id)
    end
    KCD2MP_SweepStrayGhosts()
    System.LogAlways("[KCD2-MP] Removed " .. count .. " ghosts")
end

-- WO-58: remove ghost/horse bodies this Lua state does not know about.
-- Ghosts are real world entities, so KCD2's own save system captures one
-- standing nearby at save time exactly as it was. Reload that save in a
-- LATER session (game restarted, or days later on a new mod version) and
-- the embedded body is a stray: relay ids are per-connection, so the
-- returning player almost never gets the same id back, which means
-- SpawnGhost's own same-name preexisting check never fires and
-- RemoveStaleGhostsForPlayer (which only walks the TRACKED table) never
-- sees it. The stray stands there forever wearing whatever face the old
-- session picked -- including an old fallback-keyed female body, which is
-- exactly what a "player joined as the wrong gender" report looks like
-- from across the room. Spawn names are "kcd2mp_<relayId>" and relay ids
-- are single-byte and small in practice, so a bounded name probe finds
-- every possible stray cheaply. Untracked proxies only: a name the live
-- tables own is left alone, and adopted world horses are real local
-- content that is never removed by name.
function KCD2MP_SweepStrayGhosts()
    local swept = 0
    for i = 0, 31 do
        local sid = tostring(i)
        local gname = "kcd2mp_" .. sid
        local tracked = KCD2MP.ghosts[sid] or KCD2MP.ghosts[i]
        if not tracked then
            local stray = nil
            pcall(function() stray = System.GetEntityByName(gname) end)
            if stray then
                mp_log("SweepStrayGhosts: untracked " .. gname .. " in the world (save-embedded or leaked) -- removing")
                mp_remove_entity_verified(stray.id, gname, gname)
                swept = swept + 1
            end
        end
        local hname = "kcd2mp_horse_" .. sid
        local htracked = KCD2MP.horseGhosts[sid] or KCD2MP.horseGhosts[i]
        if not htracked then
            local strayH = nil
            pcall(function() strayH = System.GetEntityByName(hname) end)
            if strayH then
                mp_log("SweepStrayGhosts: untracked " .. hname .. " in the world -- removing")
                pcall(function() System.RemoveEntity(strayH.id) end)
                swept = swept + 1
            end
        end
    end
    if swept > 0 then
        mp_log("SweepStrayGhosts: removed " .. swept .. " stray bodies")
    end
    return swept
end

-- ===== Start / Stop =====

function KCD2MP_Start()
    if KCD2MP.running then
        System.LogAlways("[KCD2-MP] Already running")
        return
    end
    KCD2MP.running = true
    KCD2MP.tickCount = 0
    System.LogAlways("[KCD2-MP] Starting (pos tick=500ms, interp tick=50ms)")
    Script.SetTimer(500, KCD2MP_Tick)
    KCD2MP_StartInterp()
end

function KCD2MP_Stop()
    KCD2MP.running = false
    KCD2MP.interpRunning = false
    KCD2MP.labelRunning = false
    KCD2MP.labelCache = {}
    KCD2MP_RemoveAllGhosts()
    System.LogAlways("[KCD2-MP] Stopped")
end


KCD2MP.modules.animation = true
