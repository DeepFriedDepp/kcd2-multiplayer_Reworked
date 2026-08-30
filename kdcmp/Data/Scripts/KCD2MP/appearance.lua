-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log

-- ===== WO-65 — ghost civic isolation (Phase 1) =====
--
-- What the live probe settled (2026-08-27, all observed in-game):
--   - Contexts global is nil; no script-context setter exists under any
--     plausible name on soul/entity/AI/Game/XGenAIModule/System/Script;
--     SetEntityScriptContext is not a console command ("Unknown command").
--     The seven isolation contexts CANNOT be set from Lua on this build --
--     the crime-report half of KCD2Online's block is native-only here.
--   - soul:RestrictDialog(true) is a REAL write: IsDialogRestricted flipped
--     false->true on a live ghost. human:InterruptDialogs() runs clean.
-- So this applies what the build offers (the dialog half), logs
-- missing-on-this-build for each context, and keeps a generic setter hook so
-- a future patch that ships Contexts.SetPersistentOption lights up the rest
-- without a code change.
--
-- Lifecycle: called directly in KCD2MP_SpawnGhost (spawn path, not a timer --
-- menus suspend Script.SetTimer and reload kills timers), and re-asserted
-- opportunistically from the existing 1500ms name-settle timer in case the
-- soul was not ready at spawn+0. All respawn paths funnel through SpawnGhost
-- (UpdateGhost respawns missing bodies, ReconcileGhosts recycles into the
-- next packet's spawn), so save-load re-application comes free.
--
-- Toggle semantics: mp_ghost_isolate off gates application at spawn. The
-- dialog half has a clean removal (RestrictDialog(false), verified readable)
-- and off takes it on live ghosts. Persistent context options would NOT be
-- cleanly removable -- moot while no setter exists; if one appears, off must
-- not pretend to strip them.
function KCD2MP_ApplyGhostIsolation(id, stage)
    if not KCD2MP.ghostIsolate then return end
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end
    if stage == "settle" and ghost.isolated then return end  -- spawn pass already landed
    local e = ghost.entity
    if type(e.soul) ~= "table" then
        mp_log("Isolate[" .. tostring(id) .. "] " .. tostring(stage)
            .. ": soul not ready -- settle pass will retry")
        return
    end

    -- Context half. setCtx stays nil on this build (probe: no setter).
    local setCtx = nil
    if type(Contexts) == "table" and type(Contexts.SetPersistentOption) == "function" then
        setCtx = function(ctx)
            local okSet = pcall(function() Contexts.SetPersistentOption(e, ctx, "KCDMPGhost") end)
            if not okSet then return "call-failed" end
            local has = nil
            pcall(function() has = e.soul:HasScriptContext(ctx) end)
            if has == true then return "applied-and-verified" end
            return "applied-but-not-readable"
        end
    end
    -- WO-68: the contexts are applied NATIVELY now. KCDMP.dll owns that half
    -- (script_context.cpp, driven by the agent off this ghost's spawn-time
    -- "ghostid" event over pipe 0x07), because WO-68 Phase 0 found the applier
    -- is C_ScriptContextManager in WHGame.dll with no Lua binding anywhere.
    -- The per-context readback lives in the native log; from here the honest
    -- statement is which side owns it. The generic setter hook below still
    -- lights up if a future patch ever ships Contexts.SetPersistentOption.
    for _, ctx in ipairs(KCD2MP.isolationContexts) do
        local verdict = setCtx and setCtx(ctx) or "native (KCDMP.dll, see SCTX lines)"
        mp_log("Isolate[" .. tostring(id) .. "] " .. ctx .. ": " .. verdict)
    end

    -- Dialog half (live-verified writes).
    local okR = pcall(function() e.soul:RestrictDialog(true) end)
    local isR = nil
    pcall(function() isR = e.soul:IsDialogRestricted() end)
    mp_log("Isolate[" .. tostring(id) .. "] RestrictDialog(true): ok=" .. tostring(okR)
        .. " readback=" .. tostring(isR)
        .. (isR == true and " (applied-and-verified)" or " (applied-but-not-readable)"))
    if type(e.human) == "table" then
        local okI = pcall(function() e.human:InterruptDialogs() end)
        mp_log("Isolate[" .. tostring(id) .. "] InterruptDialogs(): ok=" .. tostring(okI)
            .. " (no readback exists -- one-shot)")
    end
    ghost.isolated = true
end

-- mp_ghost_isolate on|off. on: applies to every live ghost immediately and
-- future spawns. off: future spawns skip isolation, and the dialog half is
-- cleanly removed from live ghosts (RestrictDialog(false) + readback).
function KCD2MP_SetGhostIsolate(arg)
    local s = tostring(arg or ""):lower()
    local on
    if s:find("on") then on = true
    elseif s:find("off") then on = false
    else
        System.LogAlways("[KCD2-MP] mp_ghost_isolate: expected on|off (currently "
            .. (KCD2MP.ghostIsolate and "on" or "off") .. ")")
        return
    end
    KCD2MP.ghostIsolate = on
    -- WO-68: one switch, two halves. The context half is native (no Lua setter
    -- exists on this build), so the toggle has to reach the agent, which drives
    -- KCDMP.dll's applier over pipe 0x07 for every ghost standing right now.
    KCD2MP_EmitEvent("isolate", on and "on" or "off")
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost and ghost.entity then
            if on then
                ghost.isolated = nil
                KCD2MP_ApplyGhostIsolation(id, "toggle")
            else
                ghost.isolated = nil
                pcall(function() ghost.entity.soul:RestrictDialog(false) end)
                local isR = nil
                pcall(function() isR = ghost.entity.soul:IsDialogRestricted() end)
                mp_log("Isolate[" .. tostring(id) .. "] RestrictDialog(false): readback=" .. tostring(isR))
            end
            n = n + 1
        end
    end
    System.LogAlways("[KCD2-MP] ghostIsolate=" .. tostring(on) .. " (touched " .. n .. " live ghosts)")
end

-- ===== Spawn NPC with custom armor =====

-- Preset table (name -> {items, preset})
KCD2MP.armorPresets = {
    ghost = {
        items  = "00b7ed62-a7bd-4269-acfa-8d852366579b,10ff6d35-8c14-4871-8656-bdc3476d8b12",
        preset = "dc000001-0000-0000-0000-000000000000",
    },
    -- White/Red: LegsBrigandine04 + LegsPadded01 + knackersGloves + GambesonLong01
    -- + Brigandine10 + ArmPlate04 + CoifMail01 + BascinetVisor05 + BootsKnee03
    -- weapon: kkut_menhart preset (sermiry_longSwordMenhart)
    white_red = {
        items  = "a8b22da0-e42e-4d79-abe7-52e6eebad6eb"  -- LegsBrigandine04_m04_A5 (spodnie)
              .. ",cc1adb78-fa5a-45c9-be7b-b7b50e182cb3"  -- LegsPadded01_m02_C3 (nogawice)
              .. ",36a701ed-2144-452a-b113-385efba2c0d1"  -- rasuvUcen_knackersGloves
              .. ",46b051c4-d4e2-4f3a-8b88-e3f64dae4618"  -- GambesonLong01_m03_C3 (przeszywanica)
              .. ",1aadf1e5-c37b-41c3-bc65-354187022c91"  -- Brigandine10_m09_A5 (plate armor)
              .. ",a5322fcd-27b4-4f4e-bfbf-49c519c74c74"  -- ArmPlate04_m08_A5 (naramienniki)
              .. ",cfc1fd72-dbb7-49a4-8713-6acf215a72be"  -- CoifMail01_m02_C2 (coif mail)
              .. ",b6fe59ec-c854-402a-848e-a77f55661c19"  -- BascinetVisor05_m04_C4 (bascinet)
              .. ",a06cfbf0-3d59-4003-89d4-69a82eb735af", -- BootsKnee03_m01_C (buty)
        preset  = "dc000003-0000-0000-0000-000000000000",
        weapons = "af2dd849-92a4-4081-9955-0afcb861fcd5", -- kkut_menhart (sermiry_longSwordMenhart)
    },
    -- LegsPadded01(pikowane) + GambesonShort01 + CoifMail02 + MailShort01
    -- + Cuirass07 + ArmPlate04 + Gauntlets08 + LegsPlate03 + BascinetVisor04
    -- + longSwordDuel (inventory only) - no boots
    knight = {
        items  = "078e439b-1a5b-40ca-b009-d4abf6fcf810"  -- LegsPadded01_m07_C3 (pikowane)
              .. ",00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
              .. ",0b383bf7-a67b-4caa-9db8-501ed8d6aa9f"  -- CoifMail02_mPrague_B3
              .. ",0364c89d-ac13-44ef-94d5-22b4047e7a26"  -- MailShort01_m03_C4
              .. ",a8723887-ac6e-45a0-a6a4-0cf905716b6d"  -- Brigandine05_m04_C3 (silesian body)
              .. ",dcc178b9-ed1c-41c4-b2e7-ebda930e8af9"  -- BrigandineArm05_m11_B4 (silesian)
              .. ",2dd6ea92-4024-4113-97ed-6a23f19b39d9"  -- Gauntlets08_m01_B4
              .. ",1972ac07-f8e1-41f0-9fb4-cf115b0088ec"  -- LegsPlate03_m03_A5
              .. ",96841ac9-4cdc-41e7-a84e-d212389a0d71"  -- BascinetVisorScaring_m01_closed
              .. ",00cca9e3-8ef2-46db-8cbf-86ec51930919", -- longSwordDuel (inventory)
        preset = "dc000002-0000-0000-0000-000000000000",
    },
}

-- ===== WO-20 — deterministic face roster (guidSharedSoulId) =====
--
-- The appearance lever -- binding a spawned NPC's guidSharedSoulId spawn
-- property to a real soul's SharedSoulGuid, which makes the engine build a
-- full distinct head+body+hair+beard automatically -- is Jefferson25625's
-- find (AppearanceApi.md, github.com/DeepFriedDepp/kcd2-exports fork, used
-- with permission). Confirmed live against this project's own build
-- (docs/WO-20-faces.md), not trusted from their doc.
--
-- Their own soul_roster.lua (the actual 48-soul GUID list) was never
-- committed to the repo -- prose only, same pattern WO-18 found for their
-- whole C# stack. So this roster is our own: real, hand-placed souls pulled
-- live from this save's own SoulsByName and spread across settlements for
-- visual variety. SharedSoulGuid is the authored, cross-session-stable key
-- (NATIVE-PLUGIN-findings.md), so these values hold regardless of which save
-- or session picks them.
--
-- WO-69: it is now 19, all male. The 24-entry female table is gone -- see
-- KCD2MP_PickFaceForPlayer below for why (every player character in KCD2 is
-- Henry, so a female ghost was always wrong, and WO-23 established that zero
-- female combat armour exists in Warhorse's catalog, so gear sync could not
-- render on one either). All 19 male SharedSoulGuids below were read back
-- live from a running build during WO-69 and matched 19/19 -- observed, so
-- H2 (an unresolvable roster soul falling back to a default body) is ruled
-- out for the shipped roster, not merely assumed.
--
-- WO-34: it was 48 (24 male, 24 female) and it then became 43 (19 male, 24
-- female). Five of the male entries were NOT commoners -- tbuk_man_5,
-- tkop_man_1, tkop_man_2, tzda_man_6 and tzda_man_9 were bandits, and are
-- gone. Read off the shipped tables, not inferred:
--
--   soul__tkop.xml   factionName = trosecko_enemies_bandits_campKopanina
--                    social_class_id = 38  voice_group_name = Bandits
--   social_class.xml 38 -> social_class_name "bandit", soul_crime_role_id 3
--   soul_crime_role  3  -> "renegade"
--   FactionTree.xml  ancestor trosecko_enemies carries Labels="publicEnemy"
--                    and reputation="-1" toward every trosecko settlement,
--                    outskirt, miller and ally faction
--   text_ui_soul.xml soul_ui_name_ruffian -> "Ruffian"
--
-- Until WO-22 this was harmless: the GUID was passed nested under Properties
-- and bound no soul at all, so the roster was decorative and the faction
-- never applied. WO-22 made SharedSoulGuid a real top-level parameter, which
-- turned five of these slots into genuinely hostile public enemies. Live
-- two-player report (WO-34): players hostile to each other on sight, one
-- attacked by ambient NPCs, bandit combat barks, and a corpse labelled
-- "Ruffian". KCD2MP_SpawnGhost's AI.ChangeParameter(..., "Civilians")
-- override does not defeat the soul row.
--
-- Removing rather than replacing takes the male #list from 24 to 19, and
-- KCD2MP_PickFaceForPlayer's modulus is over #list, so EVERY male player's
-- face changes with this build, not only the five. Accepted deliberately
-- (see docs/WO-34-findings.md); appearance stability across a version was
-- already broken once by WO-22 for the same underlying reason.
KCD2MP.faceRoster = {
    male = {
        {"tneb_man_11",  "43b076df-4be8-f9d9-e2e4-dd5cafd0db96"},
        {"tneb_man_18",  "4a5baae4-2667-2892-178d-b47b10e562b3"},
        {"tpod_man_1",   "4e628918-2a38-c1ea-c786-2424123506ae"},
        {"tpod_man_5",   "4f45df7c-4667-77a0-a415-d03b0cd1e293"},
        {"tsem_man_21",  "4072c96a-3bb5-f744-078c-8ef89203a49c"},
        {"tsem_man_22",  "46356c7b-ab60-1377-e8e4-514c8a8dcfbb"},
        {"tsla_man_2",   "4166b913-6b12-1965-cbb6-509a49250ba6"},
        {"ttac_man_8",   "fd1af8c5-c500-4add-b0b6-6c0505fe80c2"},
        {"ttac_man_9",   "69dfede7-a999-43dd-9dfa-5bf0c5aefe01"},
        {"ttkc_man_26",  "cfa65480-f361-4cf8-80c5-1900b7846bc8"},
        {"ttkc_man_3",   "4b4c6520-21a6-6125-d814-564837f165a2"},
        {"ttro_man_30",  "40fd3055-48be-a9f5-de48-0b882695cca5"},
        {"ttro_man_59",  "7e4881d6-ffb7-416f-bbbe-49bc622747b2"},
        {"tvez_man_20",  "2f825ed0-1d9b-4df0-ad90-d6e2b136ce04"},
        {"tvez_man_21",  "4badc882-824c-407e-b823-059fa3e5df5b"},
        {"tvid_man_3",   "48ea5c5c-fcbb-6a90-be4d-8b7f7ad6a4ac"},
        {"tvid_man_7",   "6947a43f-30eb-49bd-9997-44396f01fcba"},
        {"tzel_man_10",  "8158f557-018e-4016-95a4-024bb060bd18"},
        {"tzel_man_7",   "271ac033-a516-4928-b1f7-825bc57c46e3"},
    },
}

-- djb2-style string hash. Pure +/*/% arithmetic, deliberately no bitwise
-- ops -- this mod's sandbox is stripped Lua 5.1, which has no bit library.
--
-- WO-20 correction, found live: this engine's embedded Lua uses 32-bit
-- FLOAT numbers, not doubles -- confirmed by probing KCD2MP_HashString with
-- a %2147483647 modulus (the obvious choice) and watching tostring(h) print
-- in scientific notation ("1.93453e+08") with the low digits already gone,
-- which then made "h % 2" parity flip unpredictably and sent every test
-- name to the same roster slot (or an out-of-range one). Float32 is only
-- exact for integers up to 2^24 (~16.7M), so every intermediate value here
-- is kept under a 65521 modulus (largest prime below 2^16) -- h*33 then
-- tops out around 2.16M, safely inside the exact range.
function KCD2MP_HashString(s)
    local h = 5381 % 65521
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 65521
    end
    return h
end

-- Deterministic per-player face pick: same name key -> same soul, every
-- time, in this or any future session.
--
-- WO-69: gender is no longer derived from the hash. It used to be
-- `isFemale = (h % 2) == 0`, which made half of all name keys resolve to a
-- female body -- and every KCD2 player character is Henry, so that half was
-- wrong by construction, not by accident. The field report ("the host's
-- ghost often spawns as a female NPC") is this line, working exactly as
-- written: the tester's host nick hashes to 46000, which is even, so his
-- ghost was female on all four spawns of the reported session -- observed,
-- not inferred (docs/WO-69-findings.md). WO-58 had already fixed a *second*,
-- independent path to the same symptom (the "Player<id>" fallback key, whose
-- hash is also even for odd ids); that fix is intact and did not cover this.
--
-- Deliberately NOT changed: the hash, the `math.floor(h / 2)` term, and the
-- male table's contents and order. `#list` was already 19 here (the gender
-- branch chose the list BEFORE the modulus), so every player whose hash is
-- odd -- everyone who was already rendering correctly -- keeps the exact
-- same face across this upgrade. Only the ~50% who were rendering as women
-- change, and they change from a wrong body to a right one. Reordering or
-- "tidying" the male table would re-roll all 19 and break that property.
function KCD2MP_PickFaceForPlayer(nameKey)
    local h = KCD2MP_HashString(tostring(nameKey or ""))
    local list = KCD2MP.faceRoster.male
    local idx = (math.floor(h / 2) % #list) + 1
    local pick = list[idx]
    return { className = "NPC", soulName = pick[1], guid = pick[2] }
end

-- WO-69: the deterministic fallback for a spawn that resolves to something
-- other than what was asked for. One specific, always-loaded male commoner --
-- never the engine's own default body, which is what a discarded
-- SharedSoulGuid silently produces (WO-22). Kuttenberg is the largest
-- always-streamed settlement in the game, and this soul's SharedSoulGuid was
-- read back live from a running build during WO-69 (19/19 male roster souls
-- resolved; this is roster slot 11).
KCD2MP.faceFallback = { className = "NPC", soulName = "ttkc_man_3",
                        guid = "4b4c6520-21a6-6125-d814-564837f165a2" }

-- Split "a,b,c" -> {"a","b","c"}, trims whitespace
local function splitCSV(s)
    local parts = {}
    for part in string.gmatch(s, "[^,]+") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

-- Spawn NPC in front of player, add items to inventory, optionally equip via ClothingPreset.
-- items_csv    : comma-separated item GUIDs (inventory)
-- preset_guid  : ClothingPreset GUID for visual equip (must exist in clothing_preset__kdcmp.xml)
-- weapon_preset: WeaponPreset GUID (from weapon_preset.xml) - equips weapon in hand slot
function KCD2MP_SpawnArmoredNPC(items_csv, preset_guid, weapon_preset)
    if not player then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: no player")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Spawn 3m in front of player
    local ox, oy = 3, 0
    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end
    local spawnPos = {x = pos.x + ox, y = pos.y + oy, z = pos.z}

    KCD2MP.spawnCount = (KCD2MP.spawnCount or 0) + 1
    local npcName = "kcd2mp_npc_" .. KCD2MP.spawnCount

    System.LogAlways(string.format("[KCD2-MP] SpawnArmoredNPC '%s' at %.1f,%.1f,%.1f",
        npcName, spawnPos.x, spawnPos.y, spawnPos.z))

    local npc = nil
    local ok1, e1 = pcall(function()
        npc = System.SpawnEntity({class="NPC", name=npcName, position=spawnPos})
    end)
    if not ok1 or not npc then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: SpawnEntity failed: " .. tostring(e1))
        return
    end
    System.LogAlways("[KCD2-MP] SpawnArmoredNPC: entityId=" .. tostring(npc.id))

    -- Visually equip via ClothingPreset FIRST (may reset inventory state)
    if preset_guid and preset_guid ~= "" then
        local ok2, e2 = pcall(function()
            npc.actor:EquipClothingPreset(preset_guid)
        end)
        System.LogAlways("[KCD2-MP] EquipClothingPreset " .. preset_guid
            .. ": ok=" .. tostring(ok2)
            .. (ok2 and "" or (" err=" .. tostring(e2))))
    end

    -- Add items to inventory AFTER preset (so preset cannot wipe them)
    local guids = (items_csv and items_csv ~= "") and splitCSV(items_csv) or {}
    System.LogAlways("[KCD2-MP] Adding " .. #guids .. " items to inventory")
    for i, guid in ipairs(guids) do
        local ok, e = pcall(function()
            local item = ItemManager.CreateItem(guid, 1, 1)
            npc.inventory:AddItem(item)
        end)
        System.LogAlways(string.format("[KCD2-MP]   item[%d] %s: ok=%s%s",
            i, guid, tostring(ok), ok and "" or (" err=" .. tostring(e))))
    end

    -- Equip weapon via WeaponPreset (visual + inventory, works for swords/shields)
    if weapon_preset and weapon_preset ~= "" then
        local ok3, e3 = pcall(function()
            npc.actor:EquipWeaponPreset(weapon_preset)
        end)
        System.LogAlways("[KCD2-MP] EquipWeaponPreset " .. weapon_preset
            .. ": ok=" .. tostring(ok3)
            .. (ok3 and "" or (" err=" .. tostring(e3))))

        -- Close visor after short delay using native console command
        -- pattern from VIA mod: closeVisorOn <entityName>
        local npcNameRef = npcName
        Script.SetTimer(800, function()
            pcall(function()
                System.ExecuteCommand("closeVisorOn " .. npcNameRef)
                System.LogAlways("[KCD2-MP] closeVisorOn " .. npcNameRef)
            end)
        end)
    end

    mp_log(string.format("SpawnArmoredNPC '%s' items=%d preset=%s weapons=%s",
        npcName, #guids, tostring(preset_guid or "none"), tostring(weapon_preset or "none")))
end

-- Spawn white/red armored NPC (uses XML preset dc000003 + weapon preset kkut_menhart)
function KCD2MP_SpawnWhiteRed()
    local p = KCD2MP.armorPresets.white_red
    KCD2MP_SpawnArmoredNPC(p.items, p.preset, p.weapons)
end

-- Spawn fully armored knight (all 6 pieces, uses XML preset dc000002)
function KCD2MP_SpawnKnight()
    local p = KCD2MP.armorPresets.knight
    KCD2MP_SpawnArmoredNPC(p.items, p.preset)
end

-- ===== WO-38 Phase 7: ghost stimulus-deafness probe =====
-- Section B.1: a ghost's soul-assigned voice set fires real combat-distress
-- barks ("HELP! GET ME OUT OF HERE") that never stop -- plausibly because the
-- distress behaviour wants the body to flee and the interp tick pins it in
-- place, so the state never resolves. AI.SetIgnorant(entityId, 0|1) is
-- REGISTERED on this build (WO-32 s1f: "ignore system signals, visual and
-- sound stimuli") and is the obvious lever -- but it might also stop the
-- ghost being a valid combat TARGET, which would silently regress the
-- always-on reactive combat WO-26/27 shipped. So it ships as a toggle for a
-- live A/B, not as a default: turn it on, start a fight near a ghost, and
-- check (a) the barks stop and (b) NPCs still attack the ghost.
-- Usage: mp_ghost_ignorant on|off
function KCD2MP_SetGhostsIgnorant(arg)
    local s = tostring(arg or ""):lower()
    local on
    if s:find("on") then on = 1
    elseif s:find("off") then on = 0
    else
        System.LogAlways("[KCD2-MP] mp_ghost_ignorant: expected on|off")
        return
    end
    KCD2MP.ghostsIgnorant = (on == 1)
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local ok, err = pcall(function() AI.SetIgnorant(ghost.entity.id, on) end)
            System.LogAlways(string.format("[KCD2-MP] SetIgnorant(%s, %d) ok=%s err=%s",
                tostring(id), on, tostring(ok), tostring(err)))
            n = n + 1
        end
    end
    System.LogAlways("[KCD2-MP] mp_ghost_ignorant " .. s .. " applied to " .. n .. " ghost(s)"
        .. " -- new spawns " .. (KCD2MP.ghostsIgnorant and "WILL" or "will NOT") .. " get it")
end

-- WO-59 Thread C: re-assert stimulus-deafness on every live ghost. Called by
-- the agent on the same 2.5 s re-arm cadence as StartInterp/SetGhostName.
-- SetIgnorant was applied exactly once at spawn with its pcall result thrown
-- away; if that one call failed, or the engine dropped the flag somewhere no
-- doc covers, the ghost's brain was a full crime witness for the rest of the
-- session with zero evidence trail (the field report: a ghost catching a
-- sneaking player mid-theft, barking the authored catch line, and killing
-- them). Re-asserting is one flag write per ghost; the engine treats a
-- same-value write as a no-op, and a FAILURE is logged once per ghost id so
-- a field bundle finally shows whether this lever works when it matters.
function KCD2MP_ReassertGhostIgnorance()
    if not KCD2MP.ghostsIgnorant then return end
    KCD2MP._ignorantFailLogged = KCD2MP._ignorantFailLogged or {}
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local ok, err = pcall(function() AI.SetIgnorant(ghost.entity.id, 1) end)
            if not ok and not KCD2MP._ignorantFailLogged[id] then
                KCD2MP._ignorantFailLogged[id] = true
                System.LogAlways("[KCD2-MP] ReassertGhostIgnorance: SetIgnorant FAILED for ghost "
                    .. tostring(id) .. " err=" .. tostring(err))
            elseif ok and KCD2MP._ignorantFailLogged[id] then
                KCD2MP._ignorantFailLogged[id] = nil
                System.LogAlways("[KCD2-MP] ReassertGhostIgnorance: SetIgnorant recovered for ghost " .. tostring(id))
            end
        end
    end
end

-- ===== WO-40 Phase 9: hostility remediation + faction-bind probe =====
-- The footage's pickpocket incident left PB's ghost persistently hostile to
-- PA (aggro indicator + forced combat stance long after). Ignorant-by-default
-- prevents NEW incidents; this clears an already-aggroed ghost, and reports
-- the registration state of the per-pair hostility binds the retail-1.5 dump
-- says exist (AI.GetFactionOf was previously dismissed on a guessed
-- signature -- project memory corrected this WO).
function KCD2MP_GhostCalm()
    System.LogAlways("[KCD2-MP] AI.GetFactionOf="            .. tostring(AI and type(AI.GetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.SetFactionOf="            .. tostring(AI and type(AI.SetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.AddPersonallyHostile="    .. tostring(AI and type(AI.AddPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.RemovePersonallyHostile=" .. tostring(AI and type(AI.RemovePersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.IsPersonallyHostile="     .. tostring(AI and type(AI.IsPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.ResetPersonallyHostiles=" .. tostring(AI and type(AI.ResetPersonallyHostiles)))
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            n = n + 1
            if AI and type(AI.IsPersonallyHostile) == "function" and player then
                local ok, hostile = pcall(function() return AI.IsPersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s IsPersonallyHostile(player) ok=%s -> %s",
                    tostring(id), tostring(ok), tostring(hostile)))
            end
            -- Live-verified 2026-08-20: the engine's own parameter-check
            -- error revealed the real signature -- ResetPersonallyHostiles
            -- (entityID, hostileID), two args like Remove. Both called
            -- pairwise against the local player.
            if AI and type(AI.ResetPersonallyHostiles) == "function" and player then
                local ok, err = pcall(function() return AI.ResetPersonallyHostiles(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s ResetPersonallyHostiles(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
            if AI and type(AI.RemovePersonallyHostile) == "function" and player then
                local ok, err = pcall(function() return AI.RemovePersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s RemovePersonallyHostile(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to calm") end
end


KCD2MP.modules.appearance = true
