-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log
local lerpVal = KCD2MP.util.lerp
local mp_remove_entity_verified = KCD2MP.util.removeEntityVerified


-- WO-27: how many ghost entities actually exist right now, counted from the
-- world rather than from KCD2MP.ghosts. The bookkeeping table is exactly what
-- the leak got wrong, so a count taken from it would agree with itself and
-- prove nothing. Returns registered, live, and the list of live spawn names.
function KCD2MP_GhostAudit()
    local registered, live, names = 0, 0, {}

    for gid, g in pairs(KCD2MP.ghosts) do
        registered = registered + 1
        local e = nil
        if g.entityId then pcall(function() e = System.GetEntity(g.entityId) end) end
        if e then
            live = live + 1
            table.insert(names, "kcd2mp_" .. tostring(gid))
        end
    end

    -- Orphans: an entity still in the world under a spawn name that no longer
    -- has a KCD2MP.ghosts row. This is the shape the leak actually took.
    for probe = 0, 32 do
        if not KCD2MP.ghosts[tostring(probe)] and not KCD2MP.ghosts[probe] then
            local e = nil
            pcall(function() e = System.GetEntityByName("kcd2mp_" .. probe) end)
            if e then
                live = live + 1
                table.insert(names, "kcd2mp_" .. probe .. " (ORPHAN)")
            end
        end
    end

    mp_log(string.format("GhostAudit registered=%d live=%d [%s]",
        registered, live, table.concat(names, ", ")))
    return registered, live
end

-- WO-27: which player a ghost belongs to, as a key that survives a reconnect.
--
-- The connection id does NOT: the relay hands out a fresh byte per connection,
-- so the same human coming back is a different id, and the old id's row is
-- never touched again. That is the whole leak -- WO-26 found three registered
-- ghosts (ids 1, 2, 3) that were all one player, all wearing the same Steam
-- nick, two of them orphaned.
--
-- The Steam nick is the only stable identity that reaches Lua: it arrives in
-- the 0x03 Name packet at handshake time, before the first Position packet
-- (docs/WO-20-faces.md), and it is already what KCD2MP_PickFaceForPlayer keys
-- the face roster on. When it has NOT arrived, this falls back to
-- "Player<id>", which is per-connection and so cannot dedupe -- an honest
-- limit, not a silent one: two nameless reconnects will still leak, and the
-- fallback is logged at spawn.
local function mp_ghost_identity(id)
    return KCD2MP.ghostNames[id]
end

-- Removes any ghost belonging to the same player under a DIFFERENT connection
-- id. Called before a spawn, so a reconnect replaces its predecessor instead
-- of orphaning it.
function KCD2MP_RemoveStaleGhostsForPlayer(identity, keepId)
    if not identity then return 0 end
    local doomed = {}
    for gid, g in pairs(KCD2MP.ghosts) do
        if gid ~= keepId and g.identity == identity then
            table.insert(doomed, gid)
        end
    end
    for _, gid in ipairs(doomed) do
        mp_log(string.format("Reconnect: '%s' returned as id=%s -- removing stale ghost id=%s",
            tostring(identity), tostring(keepId), tostring(gid)))
        KCD2MP_RemoveGhost(gid)
    end
    return #doomed
end

function KCD2MP_SpawnGhost(id, x, y, z, rotZ)
    if KCD2MP.ghosts[id] then
        KCD2MP_RemoveGhost(id)
    end

    -- WO-27: same player, new connection id. Must run BEFORE the spawn, so
    -- there is never a moment with two ghosts for one person.
    local identity = mp_ghost_identity(id)
    if identity then
        KCD2MP_RemoveStaleGhostsForPlayer(identity, id)
    else
        mp_log("SpawnGhost id=" .. tostring(id) ..
               " has no Steam nick yet -- reconnect dedupe cannot run for this spawn")
    end

    local pos = {x=x, y=y, z=z}
    -- WO-66: the "kcd2mp_" prefix here (and in every other spawn name this
    -- file mints: kcd2mp_horse_, kcd2mp_npc_, kcd2mp_ianchor_) is RESERVED at
    -- the relay -- Protocol.NpcReservedNamePrefix in dotnet/KcdMp.Protocol/
    -- Protocol.cs makes the relay refuse NPC claims for names under it.
    -- If this naming scheme ever changes, change that constant too.
    local name = "kcd2mp_" .. id

    System.LogAlways(string.format("[KCD2-MP] Spawning ghost '%s' at %.1f,%.1f,%.1f", id, x, y, z))

    -- WO-20: deterministic real face. Keyed on the Steam name if it has
    -- already arrived (KCD2MP_SetGhostName runs at Handshake time on the
    -- server, before any Position packet -- see docs/WO-20-faces.md -- so in
    -- practice it almost always has), falling back to the same "Player<id>"
    -- string the nameplate itself falls back to so a spawn is never blocked
    -- waiting on the name.
    local faceKey = identity or ("Player" .. tostring(id))
    local facePick = KCD2MP_PickFaceForPlayer(faceKey)

    -- WO-27: an entity may still be standing under this exact spawn name with
    -- no KCD2MP.ghosts row behind it -- after a save load, after the mod
    -- reinitialised, or after a RemoveEntity that silently did nothing.
    -- Spawning over it would leave the old one in the world untracked, which
    -- is the other half of how WO-26 found three ghosts for one player.
    local preexisting = nil
    pcall(function() preexisting = System.GetEntityByName(name) end)
    if preexisting then
        mp_log("SpawnGhost: untracked entity already named " .. name .. " -- removing it first")
        mp_remove_entity_verified(preexisting.id, name, name)
    end

    -- WO-22: SharedSoulGuid is a TOP-LEVEL parameter of SpawnEntity's table, not
    -- something nested under Properties. Warhorse's own shipped scriptbind doc
    -- (C_ScriptBindXGenAIModule__SpawnEntity) gives a flat table -- Name,
    -- SharedSoulGuid, SoulArchetypeName, ClassName, Pos, Rot, NoAI,
    -- SchedulerProxyName, ... -- with no Properties key in it at all.
    --
    -- Passing it nested, as this did until WO-22, binds NO soul: the spawned
    -- ghost's SharedSoulGuid reads back all-zeroes and it gets an arbitrary
    -- engine-generated appearance. That is why every ghost was brainless --
    -- a Warhorse brain is a column on the soul row (brain_id in
    -- Libs/Tables/rpg/soul__*.xml), so no soul means no brain.
    --
    -- Passed correctly, the ghost gets the roster soul's real face, faction
    -- identity, reputation log and combat level -- and, verified live, it
    -- RECOVERS from being knocked unconscious (<=54s and <=26s over two
    -- cycles) where a brainless ghost stayed down forever. That is A1 from
    -- WO-16-release-candidate.md, fixed. See docs/WO-22-brain-lead.md.
    --
    -- SchedulerProxyName is deliberately NOT passed. It is what would make the
    -- ghost pick its own activities and walk off under its own power, which
    -- fights KCD2MP_InterpTick's position stream. It is not needed for the
    -- recovery fix -- the soul alone buys that -- so a ghost spawned this way
    -- stays byte-stationary, exactly as before. ForceMount is unaffected
    -- (re-tested against a real horse on this exact shape).
    --
    -- esModularBehaviorTree is gone rather than emptied: WO-21 proved it is
    -- inert and that "IdleSeq" names no tree anywhere in the shipped game
    -- data. It was never a live variable, so the aggro toggle's switch on it
    -- was a no-op. A soul-backed ghost's reactive combat (self-defense,
    -- joining nearby fights) comes from the engine's own AI/soul/brain
    -- system once SharedSoulGuid is bound here, and is always on regardless
    -- of the aggro toggle (WO-26). The toggle's own effect is a separate,
    -- additive native hostile-faction attach applied at hit-time, not at
    -- spawn (WO-27) -- see KCD2MP_EnableAggro above.
    local entity = nil
    pcall(function()
        XGenAIModule.SpawnEntity{
            Name           = name,
            ClassName      = facePick.className,
            Pos            = {x, y, z},
            SharedSoulGuid = facePick.guid,
        }
        entity = System.GetEntityByName(name)
    end)
    if not entity then
        System.LogAlways("[KCD2-MP] XGenAI spawn failed, fallback System.SpawnEntity")
        local ok2, e2 = pcall(System.SpawnEntity, {
            class = facePick.className, position = pos, name = name,
            properties = { esFaction = "Civilians", guidSharedSoulId = facePick.guid },
        })
        if ok2 then entity = e2 end
    end
    System.LogAlways(string.format("[KCD2-MP] face pick for '%s': key=%s class=%s soul=%s guid=%s",
        id, faceKey, facePick.className, facePick.soulName, facePick.guid))

    if not entity then
        System.LogAlways("[KCD2-MP] SpawnEntity failed for ghost id=" .. tostring(id))
        return nil
    end

    -- WO-69: verify-after-spawn. The face-pick line above records what was
    -- ASKED FOR; on its own it is not evidence of what the engine built. A
    -- discarded SharedSoulGuid produces a soulless default body with no error
    -- of any kind (WO-22), and a roster soul absent from the loaded save is
    -- the same silent no-op (WO-33) -- both would have been invisible in
    -- every field log the project has ever collected. This line ships
    -- permanently, and stays even now that the roster is male-only, so a
    -- silent fallback can never again hide behind a correct-looking request.
    --
    -- entity.class is the authoritative gender read: gender comes from the
    -- CLASS ("NPC" vs "NPC_Female"), not from the soul, and it is proven
    -- readable on a real ghost. entity.soul.name is read as a soul-binding
    -- probe only, BEFORE KCD2MP_ApplyName overwrites it with the nickname.
    --
    -- Nil is "unknown", never "mismatch". ApplyName's own field logs show
    -- `before=nil` on live ghosts, so the soul is not reliably reachable at
    -- spawn+0; treating an empty read as a negative would respawn healthy
    -- ghosts forever. Only a DEFINITE, non-nil disagreement acts.
    local resolvedClass, resolvedSoul = nil, nil
    pcall(function() resolvedClass = entity.class end)
    pcall(function() resolvedSoul  = entity.soul and entity.soul.name end)
    System.LogAlways(string.format(
        "[KCD2-MP] spawn verify ghost '%s': requested class=%s soul=%s guid=%s | resolved class=%s soul=%s",
        tostring(id), facePick.className, facePick.soulName, facePick.guid,
        tostring(resolvedClass), tostring(resolvedSoul)))

    if resolvedClass ~= nil and tostring(resolvedClass) ~= facePick.className then
        -- Loud: this is the failure mode that produced the field report and
        -- then hid from four sessions of logs.
        System.LogAlways(string.format(
            "[KCD2-MP] SPAWN MISMATCH ghost '%s': asked for class=%s, engine built class=%s"
            .. " -- respawning once on the deterministic fallback soul %s",
            tostring(id), facePick.className, tostring(resolvedClass),
            KCD2MP.faceFallback.soulName))
        mp_remove_entity_verified(entity.id, name, "mismatched ghost " .. tostring(id))
        entity = nil
        -- Exactly one re-attempt, never a loop, and never the engine default:
        -- a named male commoner whose guid is checked into this file.
        facePick = KCD2MP.faceFallback
        pcall(function()
            XGenAIModule.SpawnEntity{
                Name           = name,
                ClassName      = facePick.className,
                Pos            = {x, y, z},
                SharedSoulGuid = facePick.guid,
            }
            entity = System.GetEntityByName(name)
        end)
        if not entity then
            System.LogAlways("[KCD2-MP] fallback respawn failed for ghost id=" .. tostring(id))
            return nil
        end
        local reClass = nil
        pcall(function() reClass = entity.class end)
        System.LogAlways(string.format(
            "[KCD2-MP] spawn verify (fallback) ghost '%s': resolved class=%s soul=%s",
            tostring(id), tostring(reClass), facePick.soulName))
    end

    -- Set faction via AI system (XGenAIModule ignores Properties.esFaction at spawn time)
    pcall(function()
        entity.Properties.esFaction = "Civilians"
        AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
    end)

    System.LogAlways("[KCD2-MP] Spawned entityId=" .. tostring(entity.id))

    -- Apply white/red armor preset (ClothingPreset first, then WeaponPreset + visor).
    --
    -- WO-20: white_red's item list is entirely male mesh variants ("_m0X").
    -- Confirmed live: an NPC_Female entity fault-freely accepts the preset
    -- call (pcall ok=true, no error) but nothing renders and
    -- EquippedArmorsByClassId reads back EMPTY afterwards -- not just missing
    -- the preset items, but stripped of the soul's own authored default
    -- outfit too, leaving her in the bare base layer. A plain NPC_Female
    -- spawned with NO preset call keeps her own default outfit fine (also
    -- confirmed live). So the preset call is actively destructive on a
    -- female-classed ghost, not merely ineffective -- skip it for her and
    -- let the soul's own authored outfit stand. The male path is unchanged.
    if facePick.className ~= "NPC_Female" then
        local p = KCD2MP.armorPresets.white_red
        pcall(function() entity.actor:EquipClothingPreset(p.preset) end)
        pcall(function() entity.actor:EquipWeaponPreset(p.weapons) end)
    end
    local ghostName = name
    Script.SetTimer(800, function()
        pcall(function() System.ExecuteCommand("closeVisorOn " .. ghostName) end)
    end)

    -- WO-17: human:DrawWeapon() is a real, visually-confirmed native mutation
    -- (unlike EquipWeaponPreset, which is cosmetic-only, WO-9). WO-17's own
    -- claim that it never flips CombatSoul.HasMeleeWeapon was disproved by
    -- WO-21: on a male ghost with a real equipped weapon item, this call does
    -- flip HasMeleeWeapon=true, and WO-22/23 confirmed it holds true for
    -- soul-backed, brained ghosts. On a female ghost (no weapon item to draw)
    -- the flag correctly stays false -- that is the item being absent, not a
    -- broken call. Whether a ghost actually lands a blow is a separate,
    -- emergent AI-brain decision (morale, odds, context) that this call does
    -- not control either way (WO-22/23: every hostile ghost tested so far
    -- chose to flee rather than fight, being outnumbered).
    if KCD2MP.aggroEnabled then
        Script.SetTimer(1000, function()
            local g = KCD2MP.ghosts[id]
            if g and g.entity and g.entity.human then
                pcall(function() g.entity.human:DrawWeapon() end)
            end
        end)
    end

    local r = rotZ or 0

    -- Interpolation state: buffer with prev packet (A) and target packet (B)
    -- alpha: 0 = at A, 1 = at B, >1 = dead reckoning beyond B
    -- alphaStep: how much alpha advances per 50ms tick (= 50ms / packetInterval)
    --   default assumes 200ms server tick -> step = 0.25 (reaches B in 4 ticks)
    local istate = {
        -- Previous packet (lerp source)
        px = x, py = y, pz = z, pr = r,
        -- Target packet (lerp destination)
        tx = x, ty = y, tz = z, tr = r,
        -- Current rendered position
        cx = x, cy = y, cz = z, cr = r,
        -- Interpolation progress
        alpha = 1.0,
        alphaStep = 0.25,
        -- Dead reckoning velocity (units/sec), computed from last two packets
        vx = 0, vy = 0, vz = 0,
        -- Last ACTUAL packet position (separate from tx/ty which DR extends)
        lastPacketX = x, lastPacketY = y,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
        -- Animation state
        animTag = "idle",     -- "idle"/"walk"/"run" - current animation state
        smoothedSpeed = 0,
        prevCx = x, prevCy = y,
        speedDropTicks = 0,   -- consecutive ticks with low speed after high speed
        -- WO-40 Phase 0: crash guard -- ForceMount must never race a fresh
        -- spawn's soul/equip initialization (host crash #2 died exactly at
        -- spawn+400ms mount). Mount waits until the ghost is >=3 s old.
        spawnedAtClock = os.clock(),
    }

    KCD2MP.ghosts[id] = {
        entity = entity,
        entityId = entity.id,
        istate = istate,
        facePick = facePick,
        faceKey = faceKey,
        -- WO-27: nil until the Steam nick has arrived. Refreshed by
        -- KCD2MP_SetGhostName if the name turns up after the spawn, so a late
        -- name still arms the reconnect dedupe for the NEXT reconnect.
        identity = identity,
        spawnName = name,
    }

    -- WO-46: report the ghost's raw CryEngine entity id to the agent, which
    -- feeds it to the native swing path (the DLL addresses actors by this id,
    -- not by name or guid). entity.id is a userdata whose tostring prints the
    -- id as zero-padded hex -- the ONLY faithful numeric form this sandbox
    -- can produce, since its 32-bit-float numbers lose integer precision
    -- above 2^24 (WO-20/WO-40). Re-emitted naturally on every respawn because
    -- all spawns funnel through here, so the agent's cache self-heals after
    -- a save reload rebuilds the ghost bodies.
    local hexid = string.match(tostring(entity.id), "(%x+)%s*$")
    if hexid then
        KCD2MP_EmitEvent("ghostid", tostring(id) .. " " .. hexid)
    else
        mp_log("SpawnGhost: could not extract entity id hex from " .. tostring(entity.id)
               .. " -- native swings unavailable for ghost " .. tostring(id))
    end

    -- WO-38 Phase 7: if the stimulus-deafness A/B toggle is on, new spawns
    -- get it too, or a reconnect would silently undo the experiment mid-test.
    -- WO-59: the result is now logged instead of discarded. A silently
    -- failed SetIgnorant leaves the ghost's brain fully perceptive -- a real
    -- crime witness -- and no log line ever recorded whether the one
    -- spawn-time call actually ran (Thread C: the caught-stealing kill).
    if KCD2MP.ghostsIgnorant then
        local igOk, igErr = pcall(function() AI.SetIgnorant(entity.id, 1) end)
        System.LogAlways("[KCD2-MP] SetIgnorant at spawn for ghost " .. tostring(id)
            .. " ok=" .. tostring(igOk) .. (igOk and "" or (" err=" .. tostring(igErr))))
    end

    -- WO-65: civic isolation, applied in the spawn path itself (not a timer --
    -- menus suspend timers and reload kills them). If the soul is not ready
    -- yet this logs and the settle pass below retries.
    KCD2MP_ApplyGhostIsolation(id, "spawn")

    -- Schedule name apply after entity fully inits (soul may not be ready at spawn time).
    -- Uses Steam nick if already received via 0x03, else fallback "Player<id>".
    local captId = id
    Script.SetTimer(1500, function()
        local displayName = KCD2MP.ghostNames[captId] or ("Player" .. captId)
        KCD2MP_ApplyGhostName(captId, displayName)
        -- WO-65: opportunistic re-assert on the existing settle timer, for the
        -- case where the soul was not reachable at spawn+0. No-ops if the
        -- spawn pass landed (ghost.isolated) or the toggle is off.
        KCD2MP_ApplyGhostIsolation(captId, "settle")
    end)

    -- Auto-start interp loop as soon as we have a ghost to move
    KCD2MP_StartInterp()

    return entity
end

-- ===== Ghost Name (Steam nick above head) =====

-- Actually applies name to a ready entity. Logs before/after to diagnose soul.name write.
function KCD2MP_ApplyGhostName(id, name)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then
        mp_log("ApplyName id=" .. id .. " no entity")
        return
    end
    local e = ghost.entity

    -- Read current soul.name before assignment (to see what the default is)
    local before = nil
    pcall(function() before = e.soul and e.soul.name end)

    -- Attempt 1: soul.name = plain string (KCD2 shows this in NPC nameplates)
    local ok1 = pcall(function() e.soul.name = name end)
    -- Attempt 2: soul.sName (alternative field name seen in some CryEngine versions)
    local ok2 = pcall(function() e.soul.sName = name end)

    -- WO-27: `e:SetName(name)` USED to be attempt 3 here, and is deliberately
    -- gone. It renamed the entity away from "kcd2mp_<id>" -- the name it was
    -- spawned under and, critically, the key the RPG SoulList continues to
    -- file its soul under. Confirmed live in WO-26: after the rename,
    -- SoulsByName/Player91 404s while SoulsByName/kcd2mp_91 resolves. So the
    -- rename made every by-name lookup -- ours and the agent's -- miss the
    -- entity it was trying to find, including the ones that clean it up.
    --
    -- Nothing wanted it. The nameplate a player actually sees is drawn by this
    -- mod from KCD2MP.ghostNames (see KCD2MP_InterpTick's labelCache write),
    -- and the game's own NPC nameplate reads soul.name, which attempt 1 sets.

    -- Read back to verify assignment succeeded
    local after = nil
    pcall(function() after = e.soul and e.soul.name end)

    mp_log(string.format("ApplyName id=%s name=%s ok1=%s ok2=%s before=%s after=%s",
        id, name, tostring(ok1), tostring(ok2), tostring(before), tostring(after)))
end

-- Store name; if ghost already exists apply with short delay, else applied at spawn (1.5s).
function KCD2MP_SetGhostName(id, name)
    -- WO-58: the agent re-asserts names on a slow cadence (a mid-connection
    -- game restart wipes this Lua state while the agent's relay session
    -- lives on, and nothing else re-delivers the name). Make the repeat
    -- call free: same name, already backfilled, correctly-keyed face --
    -- nothing to do, no timer, no log line.
    local ghost = KCD2MP.ghosts[id]
    if KCD2MP.ghostNames[id] == name and ghost and ghost.identity == name then
        return
    end
    KCD2MP.ghostNames[id] = name
    -- WO-58: a ghost that spawned before its nick arrived was face-picked
    -- from the "Player<id>" fallback key -- wrong face, and (hash parity)
    -- a coin-flip on gender: hash("Player1") is even, so that ghost spawns
    -- as a woman regardless of who the player is. Live-hit twice in the
    -- 2026-08-25/26 session (both joiner-side kcd.logs carry the "no Steam
    -- nick yet" spawn). If the real name resolves to a different look,
    -- remove the mispicked body; the next position packet respawns it
    -- through the normal path, which now has the name.
    if ghost and ghost.entity and ghost.identity == nil then
        local rightPick = KCD2MP_PickFaceForPlayer(name)
        local current = ghost.facePick
        if not current or current.soulName ~= rightPick.soulName
           or current.className ~= rightPick.className then
            mp_log(string.format(
                "SetGhostName: ghost %s wears the '%s' fallback face (%s) but '%s' resolves to %s -- respawning with the right one",
                tostring(id), tostring(ghost.faceKey), tostring(current and current.soulName),
                tostring(name), tostring(rightPick.soulName)))
            KCD2MP_RemoveGhost(id)
            return
        end
    end
    -- WO-27: a ghost that spawned before its nick arrived has identity=nil and
    -- could not be deduped. Backfill it now, and sweep any older ghost that
    -- turns out to belong to this same player, so the leak is closed even in
    -- the race where the Position packet beat the Name packet.
    if ghost then
        ghost.identity = name
        KCD2MP_RemoveStaleGhostsForPlayer(name, id)
    end
    if ghost and ghost.entity then
        -- Ghost already alive when name packet arrives — apply after 300ms
        local captId = id
        local captName = name
        Script.SetTimer(300, function()
            KCD2MP_ApplyGhostName(captId, captName)
        end)
    end
    -- No ghost yet: name stored in ghostNames, applied at spawn (1.5s delay there)
end

-- ===== Horse Ghost Spawn / Remove =====

-- WO-38 Phase 5. Called by the agent from a HorseInfoDown (0x2B): the
-- authored name of the horse that player is riding, "" for dismounted or
-- unknown. Stored for the next mount; if that ghost is ALREADY riding a
-- spawned proxy and the named world horse exists here, the proxy is swapped
-- out for the real horse -- the identity packet and the riding flag race on
-- two different channels, so late arrival is the normal case, not an error.
function KCD2MP_SetGhostHorse(id, name)
    id = tostring(id)
    name = tostring(name or "")
    KCD2MP.ghostHorseName[id] = name
    mp_log("GHOST_HORSE id=" .. id .. " name='" .. name .. "'")

    local hd = KCD2MP.horseGhosts[id]
    local ghost = KCD2MP.ghosts[id]
    if name ~= "" and hd and not hd.isWorldHorse and ghost and ghost.istate
       and ghost.istate.isRiding then
        local world = nil
        pcall(function() world = System.GetEntityByName(name) end)
        if world and tostring(world.class or "") == "Horse" then
            mp_log("GHOST_HORSE swapping proxy for world horse '" .. name .. "' id=" .. id)
            if ghost.istate.nativeMounted then
                pcall(function() ghost.entity.human:ForceDismount() end)
                ghost.istate.nativeMounted = false
            end
            KCD2MP_RemoveHorse(id)
            local wp = nil
            pcall(function() wp = ghost.entity:GetWorldPos() end)
            KCD2MP_SpawnHorse(id, wp and wp.x or 0, wp and wp.y or 0, wp and wp.z or 0,
                ghost.istate.tr or 0)
        end
    end
end

function KCD2MP_SpawnHorse(id, x, y, z, rotZ)
    if KCD2MP.horseGhosts[id] then
        KCD2MP_RemoveHorse(id)
    end

    -- WO-38 Phase 5: if we know WHICH horse that player mounted and this
    -- world has the same-named entity, adopt it instead of spawning the
    -- generic proxy. Right look (Section D's grey-horse report was the
    -- proxy's default appearance), and a real horse the local player can
    -- still interact with. Position is driven exactly like a proxy while
    -- ridden; on dismount the entry is dropped and the engine takes the
    -- horse back (the WO-32 release principle -- verified on human NPCs,
    -- horse behaviour is live-gated).
    local wantName = KCD2MP.ghostHorseName[id]
    -- WO-40 Phase 0: both real host crashes (19:25:05 / 20:23:54 in the
    -- 2026-08-18 bundles) landed within ~1.5 s of an inbound ghost mount.
    -- Two guards, both cheap:
    --   1. never adopt the horse the LOCAL player is riding -- ForceMounting
    --      a second rider onto an occupied horse was never tested and is the
    --      strongest suspect for crash #1 (PA was galloping when PB's mount
    --      flip arrived);
    --   2. adoption can be turned off entirely (mp_horse_adopt off) so field
    --      testers can separate "adoption crashes" from everything else.
    if wantName and wantName ~= "" and KCD2MP.horseAdoptEnabled == false then
        mp_log("HorseAdopt: disabled (mp_horse_adopt off); proxy for id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" and KCD2MP._mountedHorseName == wantName then
        mp_log("HorseAdopt: '" .. wantName .. "' is the LOCAL player's own mount -- proxy instead (crash guard) id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" then
        local world = nil
        pcall(function() world = System.GetEntityByName(wantName) end)
        -- WO-58: distance guard. The 2026-08-25 host freeze (16:55) is pinned
        -- to this exact path: kcd.log's final line is MountNPCOnHorse for a
        -- freshly-adopted world horse, the native sampler's per-frame log
        -- stops on the same tick, and the game never ran another frame --
        -- ForceMount hung the main thread. The adopted horse only has to
        -- EXIST to pass GetEntityByName; in that session the same-named
        -- horse lived in a different part of the host's world entirely
        -- (the ghost spawned ~2 km from where the host was playing).
        -- ForceMounting an NPC onto a far-away, unstreamed, AI-owned horse
        -- was never live-tested before that moment and froze the engine on
        -- its first execution. Adopt only a horse that is actually standing
        -- near the ghost; anything else gets the proven proxy.
        if world and tostring(world.class or "") == "Horse" then
            local wpos = nil
            pcall(function() wpos = world:GetWorldPos() end)
            local dx = (wpos and wpos.x or 1e9) - x
            local dy = (wpos and wpos.y or 1e9) - y
            local distSq = dx * dx + dy * dy
            if not wpos or distSq > (60 * 60) then
                mp_log(string.format(
                    "HorseAdopt: '%s' exists but is %s m away from the ghost -- proxy instead (WO-58 freeze guard) id=%s",
                    wantName, wpos and string.format("%.0f", math.sqrt(distSq)) or "?", id))
                world = nil
            end
        end
        if world and tostring(world.class or "") == "Horse" then
            KCD2MP.horseGhosts[id] = {
                entity = world,
                entityId = world.id,
                isWorldHorse = true,
                worldName = wantName,
            }
            mp_log("HorseAdopt OK id=" .. id .. " world horse '" .. wantName .. "'")
            Script.SetTimer(400, function()
                KCD2MP_MountNPCOnHorse(id)
            end)
            return world
        end
        mp_log("HorseAdopt: '" .. tostring(wantName) .. "' not loaded here; falling back to proxy id=" .. id)
    end

    local pos = {x=x, y=y, z=z}
    local horseName = "kcd2mp_horse_" .. id

    -- Use System.SpawnEntity only (XGenAIModule is async → creates orphan second entity)
    local horse = nil
    local ok2, h2 = pcall(System.SpawnEntity, {
        class = "Horse", position = {x=x, y=y, z=z},
        name = horseName, properties = { esFaction = "Civilians" },
    })
    if ok2 and h2 then horse = h2 end

    if not horse then
        mp_log("HorseSpawn FAILED id=" .. id)
        return nil
    end

    pcall(function() horse:SetWorldAngles({x=0, y=0, z=rotZ or 0}) end)
    pcall(function() horse:SetMountableByPlayer(false) end)
    -- Set faction directly. Do NOT use CryAction.RegisterWithAI - that gives the horse an
    -- AI object which fights against our SetWorldPos calls every tick.
    pcall(function() AI.ChangeParameter(horse.id, AIPARAM_FACTION, "Civilians") end)

    KCD2MP.horseGhosts[id] = {
        entity = horse,
        entityId = horse.id,
    }

    mp_log("HorseSpawn OK id=" .. id .. " entityId=" .. tostring(horse.id))

    Script.SetTimer(400, function()
        KCD2MP_MountNPCOnHorse(id)
    end)

    return horse
end

function KCD2MP_MountNPCOnHorse(id)
    local ghost     = KCD2MP.ghosts[id]
    local horseData = KCD2MP.horseGhosts[id]
    if not ghost or not ghost.entity or not horseData or not horseData.entity then
        mp_log("MountNPCOnHorse: missing entity id=" .. id)
        return
    end

    local horse = horseData.entity
    local human = ghost.entity.human
    mp_log(string.format("MountNPCOnHorse id=%s hasHuman=%s", id, tostring(human ~= nil)))

    if not human then
        local captId = id
        Script.SetTimer(1000, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: a ghost younger than 3 s is still settling
    -- (soul attach, inbound appearance equips). Host crash #2 (2026-08-18
    -- 20:23:54) died exactly at fresh-spawn + 400 ms ForceMount. Defer.
    local age = os.clock() - (ghost.istate and ghost.istate.spawnedAtClock or 0)
    if ghost.istate and ghost.istate.spawnedAtClock and age < 3.0 then
        local captId = id
        mp_log(string.format("MountNPCOnHorse: ghost %s is %.1fs old -- deferring mount (crash guard)", id, age))
        Script.SetTimer(1500, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: re-check occupancy at mount time too -- the
    -- local player may have mounted this horse during the timer delay.
    if horseData.isWorldHorse and horseData.worldName
       and KCD2MP._mountedHorseName == horseData.worldName then
        mp_log("MountNPCOnHorse: '" .. horseData.worldName .. "' now occupied by the LOCAL player -- swapping to proxy id=" .. id)
        KCD2MP.horseGhosts[id] = nil
        local wp = ghost.istate
        KCD2MP_SpawnHorse(id, wp and wp.tx or 0, wp and wp.ty or 0, wp and wp.tz or 0, wp and wp.tr or 0)
        return
    end

    local ok1 = pcall(function() human:ForceMount(horse.id) end)
    mp_log("ForceMount ok=" .. tostring(ok1) .. " id=" .. id)
    if not ok1 then return end

    -- Verify mount after short delay; if confirmed, try to suppress scheduler errors
    local captId = id
    Script.SetTimer(300, function()
        local g2 = KCD2MP.ghosts[captId]
        if not g2 then return end
        local mounted = false
        pcall(function() mounted = g2.entity.human and g2.entity.human:IsMounted() end)
        mp_log("IsMounted=" .. tostring(mounted) .. " id=" .. captId)
        if not mounted then return end

        g2.istate.nativeMounted = true
        mp_log("NATIVE MOUNT SUCCESS id=" .. captId)

        -- === OPTION C: suppress "No valid scheduler behavior while occupying stance" ===
        -- Try 1: send OnHorseMounted signal so scheduler updates its state
        local s1 = pcall(function() AI.Signal(SIGNALFILTER_SENDER, 1, "OnHorseMounted", g2.entity.id) end)
        -- Try 2: disable AI entirely so scheduler stops fighting the mount
        local s2 = pcall(function() g2.entity:EnableAI(false) end)
        -- Try 3: AI.AutoDisable keeps AI alive but prevents auto-sleep cycles
        local s3 = pcall(function() AI.AutoDisable(g2.entity.id, 0) end)
        -- Try 4: generic OnMount signal
        local s4 = pcall(function() AI.Signal(0, 1, "OnMount", g2.entity.id) end)
        mp_log(string.format("OptionC signals id=%s s1=%s s2=%s s3=%s s4=%s",
            captId, tostring(s1), tostring(s2), tostring(s3), tostring(s4)))
    end)
end

function KCD2MP_RemoveHorse(id)
    local horseData = KCD2MP.horseGhosts[id]
    if not horseData then return end
    if horseData.isWorldHorse then
        -- WO-38 Phase 5: an adopted world horse is REAL local content --
        -- never removed, just released. The engine restores its own
        -- behaviour once position writes stop (WO-32's release principle).
        KCD2MP.horseGhosts[id] = nil
        mp_log("ReleaseWorldHorse id=" .. id .. " '" .. tostring(horseData.worldName) .. "'")
        return
    end
    if horseData.entityId then
        pcall(function() System.RemoveEntity(horseData.entityId) end)
    end
    KCD2MP.horseGhosts[id] = nil
    mp_log("RemoveHorse id=" .. id)
end

-- ===== Ghost Update (called by server each packet) =====

function KCD2MP_UpdateGhost(id, x, y, z, rotZ, isRiding)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet, then fall through to process isRiding on same call.
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        ghost = KCD2MP.ghosts[id]
        if not ghost or not ghost.entity then return end  -- spawn failed
    end

    local istate = ghost.istate
    if not istate then return end

    local r = rotZ or istate.tr

    -- Velocity from actual packet positions (for dead reckoning).
    -- Use real elapsed time between packets instead of fixed SERVER_INTERVAL
    -- (echo mode sends every ~10ms, not 50ms, so fixed interval gave 5x underestimate).
    local ddx = x - (istate.lastPacketX or x)
    local ddy = y - (istate.lastPacketY or y)
    local ddz = z - (istate.lastPacketZ or z)
    local now = os.clock()
    local dt = now - (istate.lastPacketTime or now)
    istate.lastPacketTime = now
    istate.lastPacketDt = dt
    -- WO-38 Phase 3: packets arrive in BURSTS, not on a clean cadence -- the
    -- agent batches ExecuteString and flushes per tick (WO-30 measured that
    -- channel at 60-130 ms warm), so several UpdateGhost calls often land
    -- microseconds apart. The old code set raw velocity to 0 for every
    -- burst packet (dt < 5 ms), halving the smoothed velocity each time and
    -- making the dead-reckoning estimate oscillate between 0 and real --
    -- one direct cause of the reported rubber-banding. A burst packet now
    -- leaves the velocity estimate alone instead of dragging it to zero.
    if dt > 0.005 and dt < 1.0 then
        istate.vx = lerpVal(istate.vx or 0, ddx / dt, 0.5)
        istate.vy = lerpVal(istate.vy or 0, ddy / dt, 0.5)
        -- Vertical rate, for jump detection (WO-38 Section A: a jumping
        -- player read as a stationary vertical teleport because animation
        -- selection only ever saw horizontal speed).
        istate.vz = lerpVal(istate.vz or 0, ddz / dt, 0.5)
    elseif dt >= 1.0 then
        istate.vx, istate.vy, istate.vz = 0, 0, 0
    end
    istate.lastPacketX = x
    istate.lastPacketY = y
    istate.lastPacketZ = z

    -- Log large target jumps; reset velocity on teleport/fast-travel
    -- Jump detection: XY only — Z changes from terrain must NOT reset velocity
    local jumpDist = math.sqrt(ddx*ddx + ddy*ddy)
    if jumpDist > 5.0 then
        istate.vx = 0
        istate.vy = 0
        mp_log(string.format("JUMP id=%s xyDist=%.2f vx/vy reset", id, jumpDist))
    elseif jumpDist > 2.0 then
        mp_log(string.format("JUMP id=%s xyDist=%.2f", id, jumpDist))
    end

    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    -- Horse riding sync
    local riding = (isRiding == true)
    local wasRiding = (istate.isRiding == true)
    istate.isRiding = riding

    if riding and not wasRiding then
        -- Player just mounted a horse: spawn horse ghost
        mp_log("Riding START id=" .. id)
        KCD2MP_SpawnHorse(id, x, y, z, r)
    elseif not riding and wasRiding then
        -- Player dismounted: remove horse ghost, restore walk animation
        mp_log("Riding STOP id=" .. id)
        -- Dismount if natively mounted
        if istate.nativeMounted then
            pcall(function() ghost.entity.human:ForceDismount() end)
            istate.nativeMounted = false
        end
        KCD2MP_RemoveHorse(id)
        istate.animTag = "idle"  -- force animation reset
    end

    if istate.packetCount % 40 == 1 then
        local spd = math.sqrt(raw_vx*raw_vx + raw_vy*raw_vy)
        mp_log(string.format("pkt#%d id=%s pos=%.1f,%.1f,%.1f spd=%.1f riding=%s",
            istate.packetCount, id, x, y, z, spd, tostring(riding)))
    end
end

-- ===== Exchange: read local player state + apply ghost from other player =====
-- Returns CSV "x,y,z,rotZ,stance"  (stance: "s"=stand, "c"=crouch/sneak)
-- gstance: other player's stance to apply to ghost
function KCD2MP_Exchange(ghost_id, gx, gy, gz, gr, gstance)
    -- Apply incoming ghost state
    if ghost_id and gx then
        KCD2MP_UpdateGhost(ghost_id, gx, gy, gz, gr, gstance)
    end
    -- Read and return local player state
    if not player then return "" end
    local pos = player:GetWorldPos()
    if not pos then return "" end
    local rot = 0
    pcall(function()
        local ang = player:GetWorldAngles()
        if ang then rot = ang.z or 0 end
    end)
    -- Stance: use OnAction-tracked flag (most reliable in KCD2)
    -- Fallback to engine API in case action hook missed something
    local stance = "s"
    if KCD2MP.playerSneaking then
        stance = "c"
    else
        pcall(function()
            local s = player:GetStance()
            if s == 2 or s == 3 then stance = "c" end
        end)
        if stance == "s" then
            pcall(function()
                if player.actor and player.actor.bSneaking then stance = "c" end
            end)
        end
    end
    return string.format("%.3f,%.3f,%.3f,%.4f,%s", pos.x, pos.y, pos.z, rot, stance)
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    -- Liveness, not the flag -- see the comment on tickAlive. A save load
    -- leaves interpRunning true over a dead timer chain, and the old
    -- flag-only guard here made that permanent: every remote ghost frozen for
    -- the rest of the session with no way to recover short of restarting the
    -- game.
    if not tickAlive(KCD2MP.interpRunning, KCD2MP._interpAliveAt) then
        KCD2MP.interpRunning = true
        KCD2MP._interpAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Interp tick started (20ms)")
        Script.SetTimer(20, KCD2MP_InterpTick)
    end
    -- Start label render loop if not already running (8ms < 16.7ms frame = no flicker)
    if not tickAlive(KCD2MP.labelRunning, KCD2MP._labelAliveAt) then
        KCD2MP.labelRunning = true
        KCD2MP._labelAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Label render loop started (8ms)")
        Script.SetTimer(8, KCD2MP_LabelTick)
    end
end

-- Update horse positions at 8ms to avoid 20ms stutter (physics fights SetWorldPos less).
--
-- Split out of KCD2MP_LabelTick for WO-13's external pump. InterpTick only
-- computes horseData.render*; this is what actually applies it, so a pump that
-- drove InterpTick alone would leave a mounted ghost's horse standing still
-- while the rider slid along on top of it.
function KCD2MP_ApplyHorseTransforms()
    for id, horseData in pairs(KCD2MP.horseGhosts) do
        if horseData.entity and horseData.renderX then
            pcall(function()
                horseData.entity:SetWorldPos({x=horseData.renderX, y=horseData.renderY, z=horseData.renderZ})
                horseData.entity:SetWorldAngles({x=0, y=0, z=horseData.renderR})
            end)
        end
    end
end

-- WO-13: driven by the agent over ExecuteString while a LOCAL menu has focus.
-- Script.SetTimer -- which schedules every tick in this file -- is frozen for
-- the whole duration of a local menu (WO-12 s0.3), so without this the other
-- players' ghosts stand still on your own screen while you are the one in the
-- inventory. ExecuteString-driven Lua keeps executing throughout (WO-12 s0.4),
-- which is the whole reason this works.
--
-- Deliberately does NOT pump KCD2MP_LabelTick's drawing half. DrawLabel and
-- DrawText are immediate-mode -- one frame per call -- so pumping them would
-- draw a nameplate on some frames and not others, i.e. strobe rather than
-- render. Measured pump rate live is 35-86 Hz against a 60 fps frame, which
-- is fast enough for motion to look continuous but is NOT frame-locked, so
-- the strobing is real. Labels therefore stay hidden for the duration of the
-- menu -- exactly what already happens today. This fix is about ghost bodies
-- moving, not about labels.
function KCD2MP_InterpPump()
    KCD2MP_InterpTick("ext")
    KCD2MP_ApplyHorseTransforms()
    -- WO-40 Phase 2: pump the NPC puppet tick too, at its own 50 ms cadence
    -- (the pump loop runs at 40-70 Hz; the puppet tick's lerp/speed math
    -- assumes 50 ms, and per-tick StartAnimation restarts get worse, not
    -- better, when run faster -- WO-39's stomping lesson).
    local nowP = os.clock()
    if KCD2MP.npcPuppetRunning and (nowP - (KCD2MP._npcPuppetPumpAt or 0)) >= 0.045 then
        KCD2MP._npcPuppetPumpAt = nowP
        KCD2MP_NpcPuppetTick("ext")
    end
end

-- WO-13 Phase 2. Called by the agent when a PauseDown (0x1D) says a peer
-- entered or left a menu. Ghost ids are strings on this side (they key
-- KCD2MP.ghosts), so the caller must pass the same form it uses everywhere
-- else; tostring here rather than trusting that.
function KCD2MP_SetGhostMenuState(id, inMenu)
    id = tostring(id)
    KCD2MP.ghostInMenu[id] = inMenu and true or nil
    mp_log("GHOST_MENU id=" .. id .. " inMenu=" .. tostring(inMenu and true or false))
end

-- ===== Shared player combat (WO-28) =====

-- Flow A receiver. Called by the agent from a PlayerStateDown (0x20): this is
-- the owner's own authoritative health, so it is stored and rendered, never
-- reconciled against whatever this world's local copy of that ghost thinks.
--
-- It deliberately does NOT write the ghost entity's own health. Lua health
-- writes are inert in this sandbox (docs/PROJECT-STATE.md s2), and the ghost's
-- local health is a separate, local fact -- worlds are not shared, and the
-- honest deliverable is that every peer can SEE the right number, not that two
-- simulations are made to agree. What players actually read is the nameplate,
-- which this drives.
--
-- It does, however, reset the Flow B sensor baseline and skip one sample. That
-- is guard 2 from the design doc: an externally-written health shows up as a
-- delta on the next sample and would otherwise be re-reported as a fresh hit,
-- echoing forever. Implemented here rather than at the write site so it holds
-- whether or not a health write ever lands.
function KCD2MP_SetGhostHealth(id, health, stamina, flags)
    id = tostring(id)
    KCD2MP.ghostHealth[id] = {
        h = tonumber(health) or -1,
        s = tonumber(stamina) or -1,
        flags = tonumber(flags) or 0,
        at = os.clock(),
    }
    KCD2MP.ghostHpSkip[id] = true
end

-- Flow C receiver. Called by the agent from a PlayerDeathDown (0x24).
-- Idempotent: a repeat for an already-dead player changes nothing, which is
-- the contract Protocol 0x24 states.
--
-- The ghost entity is deliberately left standing. That player is reloading
-- their own most recent save and will be back in the world within seconds to a
-- minute; removing and respawning the entity would cost a full spawn cycle
-- (and, before WO-27's dedupe fix, was exactly how duplicates appeared). The
-- nameplate says what happened instead, and the ordinary position stream moves
-- the ghost to wherever their save point put them once their game is back.
-- Death-pose candidates (WO-38 Phase 4). The WO-28 design leaves a dead
-- player's ghost standing (cheap recovery for a player back in seconds), and
-- the real two-player test read that as a bug: "his body stands there as if
-- alive... no animation of the body falling". The [dead - reloading] tag
-- rides the nameplate, which is distance-scaled -- a body-level cue is
-- needed too. Same probe-on-first-use pattern as the jump list: none of
-- these names is confirmed on this build; a wrong candidate can never play,
-- and none-found keeps today's standing body.
local DEATH_ANIMS = {
    "relaxed_death", "death", "3d_death", "dead_pose",
    "relaxed_lie_pose", "lie_pose", "lying_idle", "3d_lying_idle",
    "relaxed_knockdown", "knockdown", "ko_pose", "unconscious_pose",
}
KCD2MP._deathAnim = nil   -- nil=not probed, false=none found, string=found

function KCD2MP_SetGhostDead(id, dead)
    id = tostring(id)
    local was = KCD2MP.ghostDead[id] and true or false
    local now = dead and true or false
    KCD2MP.ghostDead[id] = now or nil
    if was ~= now then
        mp_log("GHOST_DEATH id=" .. id .. " dead=" .. tostring(now))
        -- WO-38 Phase 4: on the owner dying, put the standing body into a
        -- fall/lie pose once. mp_ghost_is_corpse freezes all locomotion
        -- driving while dead, so a one-shot here is not overwritten; on the
        -- owner coming back the ordinary animation path resumes by itself.
        if now then
            local ghost = KCD2MP.ghosts[id]
            if ghost and ghost.entity then
                if KCD2MP._deathAnim == nil then
                    local found = nil
                    for _, nm in ipairs(DEATH_ANIMS) do
                        local len = 0
                        pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
                        if len > 0 then found = nm; break end
                    end
                    KCD2MP._deathAnim = found or false
                    mp_log("DeathAnim: " .. tostring(KCD2MP._deathAnim))
                end
                if KCD2MP._deathAnim then
                    pcall(function() ghost.entity:StartAnimation(0, KCD2MP._deathAnim, 0, 0.2, 1.0, false) end)
                end
            end
        end
    end
end

-- Rule 2 gate, set by the agent from a CombatRole (0x25) packet. When off, the
-- per-ghost health sampling in KCD2MP_InterpTick does not run at all -- the
-- cost is skipped as well as the send, and a client that was never told it
-- holds authority cannot generate a hit by accident.
function KCD2MP_SetHitSensor(on)
    local now = on and true or false
    if KCD2MP.hitSensorOn ~= now then
        mp_log("HIT_SENSOR " .. (now and "on (this client holds NPC damage authority)" or "off"))
    end
    KCD2MP.hitSensorOn = now
    if not now then
        KCD2MP.ghostHpSeen = {}
        KCD2MP.ghostHpSkip = {}
    end
end

-- Reports everything this WO added, in one place, so a live check needs one
-- command rather than a hand-written Lua chunk. Logs rather than returns: the
-- console swallows return values.
function KCD2MP_ReportVitals()
    local h, s, d, u = KCD2MP_ReadSelfVitals()
    System.LogAlways(string.format(
        "[KCD2-MP] VITALS self health=%.1f stamina=%.1f dead=%s unconscious=%s emitter=%s hitSensor=%s",
        h, s, tostring(d), tostring(u), EMIT_VERSION, tostring(KCD2MP.hitSensorOn)))
    for id, ghost in pairs(KCD2MP.ghosts) do
        local hs = KCD2MP.ghostHealth[id]
        local localHp = "?"
        if ghost and ghost.entity and ghost.entity.actor then
            pcall(function() localHp = string.format("%.1f", ghost.entity.actor:GetHealth()) end)
        end
        System.LogAlways(string.format(
            "[KCD2-MP] VITALS ghost %s name=%s owner_health=%s owner_stamina=%s dead=%s local_health=%s seen=%s",
            tostring(id), tostring(KCD2MP.ghostNames[id] or "?"),
            hs and string.format("%.1f", hs.h) or "none",
            hs and string.format("%.1f", hs.s) or "none",
            tostring(KCD2MP.ghostDead[id] and true or false), localHp,
            KCD2MP.ghostHpSeen[id] and string.format("%.1f", KCD2MP.ghostHpSeen[id]) or "none"))
    end
end

-- WO-34 issue D. Is this ghost a body rather than a stand-in right now?
--
-- Two independent ways it happens, and the reported one is the second:
--
--   1. The OWNER died and their client sent 0x23, so every peer got 0x24 and
--      set KCD2MP.ghostDead. The entity here is untouched and still standing
--      (KCD2MP_SetGhostDead deliberately leaves it), but it no longer stands
--      for anybody who is playing.
--   2. An NPC killed the ghost in THIS world. No packet is involved at all --
--      worlds are not shared (docs/WO-26-shared-combat-design.md s2), so the
--      owner may be alive and well and completely unaware. Nothing in the mod
--      had ever looked at the ghost entity's own death state, which is why
--      this case went unnoticed through WO-28.
--
-- The IsDead() read is per-ghost per-20ms-tick, which is the same cadence and
-- the same object sampleGhostHealth already calls GetHealth() on, so it adds
-- one native call to a path that was already making one. pcall'd and treated
-- as "not dead" on failure: guessing a ghost is dead would freeze a live
-- player in place, which is far worse than a corpse that slides for one more
-- reconcile cycle.
function mp_ghost_is_corpse(id, ghost)
    if KCD2MP.ghostDead[id] then return true end
    -- WO-38 Phase 6: the owner reporting themselves unconscious (0x1F/0x20
    -- flags bit 0) is also a body -- they are lying in their own world, so a
    -- position stream that keeps arriving is stale-by-definition and driving
    -- walk animation onto their slumped stand-in is the same walking-corpse
    -- shape WO-34 fixed for death.
    local gh = KCD2MP.ghostHealth[id]
    if gh and gh.flags and (math.floor(gh.flags) % 2) == 1 then return true end
    if not (ghost and ghost.entity and ghost.entity.actor) then return false end
    local dead = false
    pcall(function() dead = ghost.entity.actor:IsDead() and true or false end)
    if dead then return true end
    -- WO-38 Phase 6: an NPC knocked this ghost out in THIS world. KCD2's
    -- unconsciousness is a real state distinct from death (the original A1
    -- lesson), and an unconscious body must freeze for exactly the same
    -- reason a dead one does. Same read WO-28's self-vitals already proved
    -- (actor:IsUnconscious), same pcall discipline: on failure assume
    -- conscious, because wrongly freezing a live player is the worse error.
    local ko = false
    pcall(function() ko = ghost.entity.actor:IsUnconscious() and true or false end)
    return ko
end

function KCD2MP_LabelTick()
    if not KCD2MP.labelRunning then return end
    Script.SetTimer(8, KCD2MP_LabelTick)
    KCD2MP._labelAliveAt = os.clock()
    KCD2MP_ApplyHorseTransforms()
    for id, lbl in pairs(KCD2MP.labelCache) do
        if lbl.size > 0 then
            pcall(function()
                System.DrawLabel({x=lbl.x, y=lbl.y, z=lbl.z}, lbl.size, lbl.name, 1, 1, 0, 1)
            end)
        end
    end
    -- Draw ping in top-left corner using 2D screen-space DrawText(x, y, text, size).
    if KCD2MP.pingText then
        pcall(function()
            System.DrawText(10, 10, KCD2MP.pingText, 2)
        end)
    end

    -- Interaction prompt (WO-2) shares this loop rather than adding a timer.
    pcall(KCD2MP_DrawInteractionUI)

    -- NOTE: the dice board deliberately does NOT ride this loop. This loop only
    -- starts when the agent connects and calls KCD2MP_StartInterp, so hanging
    -- the board off it meant the board silently never rendered with no agent
    -- running -- verified: labelRunning=false while diceOpen=true. The board is
    -- pushed into the game's own UI on state change instead, so it needs no
    -- per-frame loop at all.
end


KCD2MP.modules.ghosts = true
