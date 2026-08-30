-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log

-- ===== Test / Inspect =====

function KCD2MP_SpawnTest()
    if not player then return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local ox, oy = 3, 0
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end

    KCD2MP_SpawnGhost("test_ghost", pos.x + ox, pos.y + oy, pos.z, ang and ang.z or 0)
end

function KCD2MP_InspectGhost()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost. Run mp_spawn_test first.")
        return
    end

    local ent = ghost.entity
    local istate = ghost.istate
    System.LogAlways("[KCD2-MP] === GHOST INSPECT ===")
    pcall(function() System.LogAlways("[KCD2-MP] name=" .. tostring(ent:GetName())) end)
    pcall(function() System.LogAlways("[KCD2-MP] class=" .. tostring(ent.class)) end)
    if istate then
        System.LogAlways(string.format("[KCD2-MP] interp: alpha=%.3f step=%.3f ticksSince=%d packets=%d",
            istate.alpha, istate.alphaStep, istate.ticksSincePacket, istate.packetCount))
        System.LogAlways(string.format("[KCD2-MP] prev=%.1f,%.1f,%.1f  target=%.1f,%.1f,%.1f  cur=%.1f,%.1f,%.1f",
            istate.px, istate.py, istate.pz,
            istate.tx, istate.ty, istate.tz,
            istate.cx, istate.cy, istate.cz))
        System.LogAlways(string.format("[KCD2-MP] velocity=%.2f,%.2f,%.2f u/s",
            istate.vx, istate.vy, istate.vz))
    end
    pcall(function()
        local pos = ent:GetWorldPos()
        System.LogAlways(string.format("[KCD2-MP] entity pos=%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Discovery helpers (unchanged) =====

function KCD2MP_FindNPCs()
    System.LogAlways("[KCD2-MP] === FINDING HUMAN NPCs ===")
    if not player then return end

    local ppos = player:GetWorldPos()

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 100)
        if not ents then return end

        local npcCount = 0
        for _, ent in ipairs(ents) do
            local hasChar = false
            pcall(function() hasChar = ent:IsSlotCharacter(0) end)

            if hasChar then
                local isHuman = false
                pcall(function()
                    if ent.soul or ent.human or ent.actor then isHuman = true end
                end)

                if isHuman then
                    local name = "?"
                    local eclass = "?"
                    pcall(function() name = ent:GetName() end)
                    pcall(function() eclass = ent.class or "?" end)

                    npcCount = npcCount + 1
                    System.LogAlways(string.format("[KCD2-MP] NPC: name=%s class=%s",
                        tostring(name), tostring(eclass)))

                    if npcCount >= 10 then
                        System.LogAlways("[KCD2-MP] ... (first 10 only)")
                        break
                    end
                end
            end
        end

        System.LogAlways("[KCD2-MP] Found " .. npcCount .. " human NPCs within 100m")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] FindNPCs error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Animation Discovery =====

-- Probe animation names - only GetAnimationLength > 0 is reliable
function KCD2MP_ProbeAnims()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeAnims: no ghost.")
        return
    end
    local ent = ghost.entity

    -- Full CryEngine path variants (no extension) + short names
    local candidates = {
        -- Short names
        "idle", "run", "walk", "sprint", "jog",
        "Idle", "Run", "Walk", "Sprint",
        -- Full path guesses (KCD2 convention)
        "animations/humans/male/locomotion/run_loop",
        "animations/humans/male/locomotion/walk_loop",
        "animations/humans/male/locomotion/idle_loop",
        "animations/humans/male/locomotion/run_fwd",
        "animations/humans/male/locomotion/walk_fwd",
        "animations/humans/male/locomotion/sprint_loop",
        "animations/humans/male/locomotion/run",
        "animations/humans/male/locomotion/walk",
        "animations/humans/male/locomotion/idle",
        -- KCD1-style paths
        "animations/characters/humans/male/locomotion/run_loop",
        "animations/characters/humans/male/locomotion/walk_loop",
        "animations/characters/humans/male/locomotion/idle_loop",
        -- Assets subfolder
        "animations/assets/humans/locomotion/run_loop",
        "animations/assets/humans/locomotion/walk_loop",
        -- Mannequin fragment names
        "MotionIdle", "MotionRun", "MotionWalk",
        "LocomotionIdle", "LocomotionRun", "LocomotionWalk",
        "Locomotion", "locomotion",
    }

    System.LogAlways("[KCD2-MP] === PROBING ANIMS ON GHOST ===")
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] HIT: '%s' len=%.3f", name, len))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Real Horse Scanner =====
-- Scans a real KCD2 horse NPC within 20m to discover animation names, AI methods,
-- horse.horse component API, rider linkage, etc. Helps calibrate ghost horse behavior.
function KCD2MP_ScanNearbyHorse()
    if not player then
        System.LogAlways("[KCD2-MP] ScanHorse: no player")
        return
    end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === SCAN NEARBY HORSE ===")

    local ents = nil
    pcall(function() ents = System.GetEntitiesInSphere(ppos, 20) end)
    if not ents then
        System.LogAlways("[KCD2-MP] GetEntitiesInSphere failed")
        return
    end

    local animCandidates = {
        "idle","walk","trot","canter","gallop","run","stand",
        "idle_loop","walk_loop","trot_loop","canter_loop","gallop_loop","run_loop",
        "horse_idle","horse_walk","horse_trot","horse_canter","horse_gallop","horse_run",
        "horse_idle_loop","horse_walk_loop","horse_trot_loop","horse_gallop_loop",
        "horse_stand","horse_stand_idle","horse_rest",
        "horse_loco_idle","horse_loco_walk","horse_loco_trot","horse_loco_gallop",
        "animal_idle","animal_walk","animal_trot","animal_gallop","animal_run",
        "loco_idle","loco_walk","loco_run","loco_gallop","loco_trot",
        "act_idle","act_walk","act_run","act_gallop","act_trot",
        "mm_idle","mm_walk","mm_run","mm_gallop",
        "3d_idle","3d_walk","3d_run","3d_gallop","3d_trot",
        "relaxed_idle","relaxed_walk","relaxed_run",
        "stand_idle","stand_loop","rest_idle",
    }

    local found = 0
    for _, e in ipairs(ents) do
        local ec = "?"
        local en = ""
        pcall(function() ec = tostring(e.class or "?") end)
        pcall(function() en = tostring(e:GetName() or "") end)

        if ec == "Horse" and not en:find("kcd2mp_horse_") then
            found = found + 1
            System.LogAlways(string.format("[KCD2-MP] HORSE: name=%s id=%s", en, tostring(e.id)))

            -- Character file path (tells us the skeleton / animation set)
            pcall(function()
                local cf = e:GetCharacterFileName(0)
                System.LogAlways("[KCD2-MP] CharFile[0]: " .. tostring(cf))
            end)
            pcall(function()
                local cf = e:GetCharacterFileName(1)
                System.LogAlways("[KCD2-MP] CharFile[1]: " .. tostring(cf))
            end)

            -- Animation probe: slot 0 and slot 1
            local hits0, hits1 = {}, {}
            for _, nm in ipairs(animCandidates) do
                local l0 = 0; pcall(function() l0 = e:GetAnimationLength(0, nm) or 0 end)
                if l0 > 0 then hits0[#hits0+1] = nm .. "=" .. string.format("%.2f", l0) end
                local l1 = 0; pcall(function() l1 = e:GetAnimationLength(1, nm) or 0 end)
                if l1 > 0 then hits1[#hits1+1] = nm .. "=" .. string.format("%.2f", l1) end
            end
            System.LogAlways("[KCD2-MP] AnimSlot0: " .. (#hits0>0 and table.concat(hits0,", ") or "none"))
            System.LogAlways("[KCD2-MP] AnimSlot1: " .. (#hits1>0 and table.concat(hits1,", ") or "none"))

            -- horse.horse component
            local hc = nil; pcall(function() hc = e.horse end)
            if hc then
                local fns = {}
                pcall(function()
                    for k, v in pairs(hc) do
                        if type(v) == "function" then fns[#fns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] horse.horse fns: " .. table.concat(fns, ", "))
                pcall(function() System.LogAlways("[KCD2-MP] HasRider: " .. tostring(e.horse:HasRider())) end)
                pcall(function() System.LogAlways("[KCD2-MP] IsMountable: " .. tostring(e.horse:IsMountable())) end)
            else
                System.LogAlways("[KCD2-MP] horse.horse = nil")
            end

            -- AI component methods
            local hasAI = false; pcall(function() hasAI = e.AI ~= nil end)
            System.LogAlways("[KCD2-MP] hasAI: " .. tostring(hasAI))
            if hasAI then
                local aiFns = {}
                pcall(function()
                    for k, v in pairs(e.AI) do
                        if type(v) == "function" then aiFns[#aiFns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] AI fns: " .. table.concat(aiFns, ", "))
            end

            -- human / actor / soul
            pcall(function() System.LogAlways("[KCD2-MP] has human: " .. tostring(e.human ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has actor: " .. tostring(e.actor ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has soul: " .. tostring(e.soul ~= nil)) end)

            -- Properties
            pcall(function()
                if e.Properties then
                    local props = {}
                    for k, v in pairs(e.Properties) do
                        if type(v) ~= "table" then props[#props+1] = k .. "=" .. tostring(v) end
                    end
                    System.LogAlways("[KCD2-MP] Props: " .. table.concat(props, " | "))
                end
            end)

            if found >= 2 then break end
        end
    end

    if found == 0 then
        System.LogAlways("[KCD2-MP] No real horses within 20m (try within 20m of a horse NPC)")
    end
    System.LogAlways("[KCD2-MP] === END SCAN ===")
end

-- Find nearby HUMAN NPC and get their character model path, then copy to ghost
function KCD2MP_CopyNPCModel()
    if not player then return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HUMAN NPC + COPY MODEL ===")

    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost entity! Run server first.")
        return
    end

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 50)
        if not ents then return end

        local humanCount = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                -- Must have soul or human (real human NPC, not horse/door/chest)
                local isHuman = false
                pcall(function()
                    isHuman = (ent.soul ~= nil) or (ent.human ~= nil)
                end)
                if not isHuman then
                    -- Also accept NPCs with actor table
                    pcall(function()
                        if ent.actor and ent.actor.__this then isHuman = true end
                    end)
                end

                if isHuman then
                    local ename = "?"
                    pcall(function() ename = ent:GetName() end)
                    local eclass = "?"
                    pcall(function() eclass = ent.class or "?" end)
                    System.LogAlways(string.format("[KCD2-MP] HUMAN NPC: %s (class=%s)", ename, eclass))
                    humanCount = humanCount + 1

                    -- Try to get character filename
                    local cdfPath = nil
                    pcall(function()
                        local ch = ent:GetCharacter(0)
                        if ch then
                            cdfPath = ch:GetFilePath()
                            System.LogAlways("[KCD2-MP]   GetCharacter(0):GetFilePath() = " .. tostring(cdfPath))
                        end
                    end)
                    pcall(function()
                        local fn = ent:GetCharacterFileName(0)
                        System.LogAlways("[KCD2-MP]   GetCharacterFileName(0) = " .. tostring(fn))
                        if fn and not cdfPath then cdfPath = fn end
                    end)
                    -- Check Properties for model path
                    pcall(function()
                        if ent.Properties then
                            for k, v in pairs(ent.Properties) do
                                if type(v) == "string" and #v > 3 then
                                    if k:lower():find("model") or k:lower():find("cdf") or
                                       k:lower():find("file") or k:lower():find("char") then
                                        System.LogAlways("[KCD2-MP]   Props." .. k .. " = " .. v)
                                        if not cdfPath then cdfPath = v end
                                    end
                                end
                            end
                        end
                    end)

                    -- Probe animations on this NPC
                    local animCandidates = {
                        "idle", "run", "walk", "sprint", "jog",
                        "Idle", "Run", "Walk", "Sprint",
                        "run_loop", "walk_loop", "idle_loop", "sprint_loop",
                        "run_fwd", "walk_fwd", "run01", "walk01", "idle01",
                        "mm_run_fwd", "mm_walk_fwd", "mm_idle",
                        "loco_run", "loco_walk", "loco_idle",
                        "act_run", "act_walk", "act_idle",
                    }
                    for _, aname in ipairs(animCandidates) do
                        local len = 0
                        pcall(function() len = ent:GetAnimationLength(0, aname) or 0 end)
                        if len > 0 then
                            System.LogAlways(string.format("[KCD2-MP]   ANIM HIT '%s' len=%.3f", aname, len))
                        end
                    end

                    -- If we found a CDF, try loading it onto ghost
                    if cdfPath and cdfPath ~= "" then
                        System.LogAlways("[KCD2-MP]   Loading CDF onto ghost: " .. cdfPath)
                        local loadOk, loadErr = pcall(function()
                            ghost.entity:LoadCharacter(0, cdfPath)
                        end)
                        System.LogAlways("[KCD2-MP]   LoadCharacter result: " .. tostring(loadOk) .. " " .. tostring(loadErr))

                        if loadOk then
                            -- Now probe ghost again
                            System.LogAlways("[KCD2-MP]   Re-probing ghost after CDF load:")
                            for _, aname in ipairs(animCandidates) do
                                local len = 0
                                pcall(function() len = ghost.entity:GetAnimationLength(0, aname) or 0 end)
                                if len > 0 then
                                    System.LogAlways(string.format("[KCD2-MP]   GHOST HIT '%s' len=%.3f", aname, len))
                                end
                            end
                        end
                    end

                    if humanCount >= 3 then break end
                end
            end
        end
        System.LogAlways("[KCD2-MP] Found " .. humanCount .. " human NPCs")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test AI.SetForcedNavigation on ghost (try to drive locomotion animation via AI)
function KCD2MP_TestAINav()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] TestAINav: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] TestAINav: sending velocity {1,0,0} to entityId=" .. tostring(eid))

    -- Try passing velocity vector (tell AI it's moving forward)
    local ok1, e1 = pcall(function() AI.SetForcedNavigation(eid, {x=3, y=0, z=0}) end)
    System.LogAlways("[KCD2-MP]   SetForcedNavigation: " .. tostring(ok1) .. " " .. tostring(e1))

    local ok2, e2 = pcall(function() AI.SetSpeed(eid, 3) end)
    System.LogAlways("[KCD2-MP]   SetSpeed(3): " .. tostring(ok2) .. " " .. tostring(e2))

    local ok3, e3 = pcall(function() AI.Signal(0, 1, "OnMoveForward", eid) end)
    System.LogAlways("[KCD2-MP]   Signal OnMoveForward: " .. tostring(ok3) .. " " .. tostring(e3))
end

-- Deep scan: recursively list up to 3 levels, log files with .caf/.adb
function KCD2MP_ScanAnims()
    System.LogAlways("[KCD2-MP] === DEEP ANIM SCAN ===")

    local function scanDir(path, depth)
        local entries = nil
        pcall(function() entries = System.ScanDirectory(path) end)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = path .. "/" .. name
            -- Log CAF/ADB files immediately
            if name:find("%.caf$") or name:find("%.CAF$") then
                System.LogAlways("[KCD2-MP] CAF: " .. full)
            elseif name:find("%.adb$") or name:find("%.ADB$") then
                System.LogAlways("[KCD2-MP] ADB: " .. full)
            elseif depth < 3 then
                -- Recurse into subdirectory
                scanDir(full, depth + 1)
            end
        end
    end

    -- Scan humans animation tree
    scanDir("Animations/humans", 1)
    scanDir("Animations/assets", 1)
    scanDir("Animations/Mannequin/adb", 1)

    System.LogAlways("[KCD2-MP] === END DEEP SCAN ===")
end

-- Try AI.SetForcedNavigation to drive locomotion animation
-- dirX, dirY = movement direction (unit vector), speed = 0 to stop
function KCD2MP_SetGhostMovement(id, dirX, dirY, speed)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end

    local eid = ghost.entityId
    if speed > 0 then
        -- Tell AI the entity is moving in this direction at this speed
        pcall(function() AI.SetSpeed(eid, speed) end)
        pcall(function()
            AI.SetForcedNavigation(eid, {x=dirX, y=dirY, z=0})
        end)
    else
        pcall(function() AI.SetForcedNavigation(eid, {x=0, y=0, z=0}) end)
        pcall(function() AI.SetSpeed(eid, 0) end)
    end
end

-- Read Mannequin ADB via CryEngine XML loader (reads from PAK)
function KCD2MP_ReadADB()
    System.LogAlways("[KCD2-MP] === READ ADB ===")

    local adbPaths = {
        "Animations/Mannequin/ADB/kcd_male_database.adb",
        "Animations/Mannequin/adb/kcd_male_database.adb",
        "animations/mannequin/adb/kcd_male_database.adb",
    }

    -- Try CryEngine XML loader (reads files from PAK virtual filesystem)
    for _, path in ipairs(adbPaths) do
        local node = nil
        local ok, err = pcall(function()
            node = System.LoadXMLFile(path)
        end)
        System.LogAlways("[KCD2-MP] LoadXMLFile(" .. path .. "): ok=" .. tostring(ok) .. " node=" .. tostring(node) .. " err=" .. tostring(err))
        if ok and node then
            System.LogAlways("[KCD2-MP] XML loaded! Walking nodes...")
            -- Walk XML tree looking for Fragment names
            local function walkNode(n, depth)
                if depth > 4 then return end
                local tag = ""
                local name = ""
                pcall(function() tag = n:getTag() end)
                pcall(function() name = n:getAttr("name") end)
                if name and name ~= "" then
                    System.LogAlways("[KCD2-MP] " .. string.rep("  ", depth) .. tag .. " name='" .. name .. "'")
                end
                local count = 0
                pcall(function() count = n:getChildCount() end)
                for i = 0, count - 1 do
                    local child = nil
                    pcall(function() child = n:getChild(i) end)
                    if child then walkNode(child, depth + 1) end
                end
            end
            walkNode(node, 0)
            System.LogAlways("[KCD2-MP] === END ===")
            return
        end
    end

    -- Fallback: ScanDirectory
    System.LogAlways("[KCD2-MP] LoadXMLFile failed for all paths. Scanning directories...")
    local dirs = {
        "Animations/Mannequin/ADB",
        "Animations/Mannequin/adb",
        "Animations/Mannequin/adb/adb",
    }
    for _, d in ipairs(dirs) do
        local entries = nil
        pcall(function() entries = System.ScanDirectory(d) end)
        if entries and #entries > 0 then
            System.LogAlways("[KCD2-MP] " .. d .. " -> " .. #entries .. " entries:")
            for i, e in ipairs(entries) do
                System.LogAlways("[KCD2-MP]   " .. e)
                if i > 30 then break end
            end
        else
            System.LogAlways("[KCD2-MP] " .. d .. " -> empty/nil")
        end
    end

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Probe Mannequin animation tags on ghost via AI.SetAnimationTag
-- Tags drive which Mannequin fragments play (including locomotion)
function KCD2MP_ProbeAnimTags()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] ProbeAnimTags: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === PROBE ANIM TAGS ===")
    System.LogAlways("[KCD2-MP] entityId=" .. tostring(eid))

    -- Common Mannequin tag names for locomotion
    local tags = {
        "Moving", "moving", "Run", "run", "Walk", "walk",
        "Sprint", "sprint", "Locomotion", "locomotion",
        "Alert", "alert", "Relaxed", "relaxed",
        "InCombat", "Combat", "Idle", "idle",
        "Forward", "forward", "MoveForward",
        "Jogging", "Running", "Walking",
    }

    System.LogAlways("[KCD2-MP] Trying AI.SetAnimationTag:")
    for _, tag in ipairs(tags) do
        local ok, err = pcall(function()
            AI.SetAnimationTag(eid, tag)
        end)
        -- Log only errors or interesting results
        if not ok then
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' ERROR: " .. tostring(err))
        else
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' OK")
        end
    end

    -- Also try clearing tags
    pcall(function() AI.SetAnimationTag(eid, "") end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test the real animation names from ADB analysis
function KCD2MP_TestRunAnim()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] TestRunAnim: no ghost")
        return
    end
    local ent = ghost.entity
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === TEST REAL ANIM NAMES ===")

    local names = {
        "3d_relaxed_run_turn_strafe",
        "3d_relaxed_walk_turn_strafe",
        "relaxed_idle_both",
        "3d_armored_walk_turn_strafe",
        "3d_wounded_run_turn_strafe",
    }
    for _, name in ipairs(names) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        local started = false
        pcall(function() started = ent:StartAnimation(0, name) end)
        System.LogAlways(string.format("[KCD2-MP] '%s': len=%.3f started=%s",
            name, len, tostring(started)))
    end

    -- Also try AI tag "run"
    System.LogAlways("[KCD2-MP] Setting AI tag 'run'...")
    pcall(function() AI.SetAnimationTag(eid, "run") end)
    pcall(function() AI.SetSpeed(eid, 4) end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Terrain Debug =====

function KCD2MP_TerrainCheck()
    if not player then System.LogAlways("[KCD2-MP] TerrainCheck: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ok, gz = pcall(function() return Terrain.GetElevation(pos.x, pos.y) end)
    System.LogAlways(string.format("[KCD2-MP] TerrainCheck: player pos=%.2f,%.2f,%.2f | Terrain.GetElevation=ok=%s gz=%s",
        pos.x, pos.y, pos.z, tostring(ok), tostring(gz)))

    -- Check ghost position vs terrain
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local gpos = nil
            pcall(function() gpos = ghost.entity:GetWorldPos() end)
            local tgz = nil
            if gpos then
                pcall(function() tgz = Terrain.GetElevation(gpos.x, gpos.y) end)
                System.LogAlways(string.format("[KCD2-MP] Ghost '%s': entity z=%.2f | terrain z=%s | diff=%s",
                    id, gpos.z, tostring(tgz), tgz and string.format("%.2f", gpos.z - tgz) or "?"))
            end
        end
    end
end

-- ===== Stance Probe =====

function KCD2MP_ProbeStance()
    if not player then System.LogAlways("[KCD2-MP] ProbeStance: no player"); return end
    System.LogAlways("[KCD2-MP] === STANCE PROBE ===")
    local s1, s2, s3 = nil, nil, nil
    local ok1 = pcall(function() s1 = player:GetStance() end)
    System.LogAlways("[KCD2-MP] GetStance() ok=" .. tostring(ok1) .. " val=" .. tostring(s1))
    local ok2 = pcall(function()
        if player.actor then
            s2 = player.actor.bSneaking
            System.LogAlways("[KCD2-MP] actor.bSneaking=" .. tostring(s2))
        else
            System.LogAlways("[KCD2-MP] actor=nil")
        end
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== WO-65 — ghost civic isolation: Phase 0 probe =====
--
-- WO-34 proved a ghost is a full crime victim (real fines, jail, settlement
-- rep loss) and the Civilians faction override is inert. KCD2Online's answer
-- (WO-64 Phase 1, source-read @5777c15, never live-observed) is script
-- contexts: seven switch_disabled*/crime_disableReport contexts set via
-- Contexts.SetPersistentOption, then soul:RestrictDialog(true) +
-- human:InterruptDialogs(), verified with soul:HasScriptContext.
--
-- Static evidence on OUR build (checked 2026-08-27):
--   - all seven context names are real rows in Tables.pak
--     Libs/Tables/ai/ScriptContext.xml (crime_disableReport even carries
--     SideEffect="crimeDisableReport")
--   - HasScriptContext / RestrictDialog / InterruptDialogs: in Warhorse's
--     shipped scriptbind docs AND as strings in our module DLLs
--     (RPGModule/DialogModule/EntityModule); HasScriptContext is called by
--     shipped game Lua (BasicActor.lua, TriggerBase.lua)
--   - Contexts.SetPersistentOption: found NOWHERE -- not in any Modding
--     Tools module DLL, not in retail WHGame.dll, not in any pak's Lua.
--     KCD2Online itself only runtime-probes for it and skips if absent.
-- So this probe is authoritative for the setter; everything is read-only.
-- WO-68 Phase 3: the first seven (KCD2Online's block) were applied and
-- verified live -- and the WO-34 repro still outlawed the player. The game's
-- own AI data says why: the observer-side tree that turns a witnessed hit into
-- a crime (Scripts.pak :: AI/npc/basic/switch/handleAwareness_hitVolume.xml)
-- checks crime_ignoredNPCHitVolume on the VICTIM, and never checks
-- crime_disableReport against a victim at all. The last four are that family's
-- victim-side members, each from a real EntityContextCheck. Keep this list in
-- step with kIsolationContexts in native/KCDMP/script_context.cpp -- the
-- native side applies them, this list is what the readback reports.
KCD2MP.isolationContexts = {
    "switch_disabledInformationReaction",
    "switch_disabledHearingReaction",
    "switch_disabledPerceptionReaction",
    "switch_disabledPickpocketReaction",
    "switch_disabledNearMissReaction",
    "switch_disabledHitBehavioralReaction",
    "crime_disableReport",
    "crime_ignoredNPCHitVolume",
    "crime_ignoredUnconsciousBody",
    "crime_ignoredCorpse",
    "crime_ignoredPickpocket",
}

function KCD2MP_ProbeContexts()
    local function L(s) System.LogAlways("[KCD2-MP] " .. s) end
    L("=== CONTEXTS PROBE (WO-65) ===")

    -- 1. The Contexts global. Never found statically; type() here decides.
    L("global Contexts type=" .. type(Contexts))
    if type(Contexts) == "table" then
        pcall(function()
            L("Contexts.SetPersistentOption type=" .. type(Contexts.SetPersistentOption))
            local n = 0
            for k, v in pairs(Contexts) do
                L("  Contexts." .. tostring(k) .. " : " .. type(v))
                n = n + 1
                if n >= 40 then L("  ...truncated at 40 keys"); break end
            end
        end)
    end

    -- 2. Any global whose name mentions Context (catches a renamed table).
    pcall(function()
        if type(_G) ~= "table" then L("_G not iterable in this sandbox"); return end
        local n = 0
        for k, v in pairs(_G) do
            if type(k) == "string" and string.find(k, "ontext") then
                L("_G." .. k .. " : " .. type(v))
                n = n + 1
                if n >= 20 then L("...truncated at 20 globals"); break end
            end
        end
        if n == 0 then L("no *ontext* globals found") end
    end)

    -- 3. Method surface + pre-write context state, on a live ghost if one
    --    exists, and on the player as a known-good control (shipped game Lua
    --    calls player.soul:HasScriptContext, so the player half must work).
    local function probeBody(tag, e)
        if not e then L(tag .. ": no entity"); return end
        L(tag .. ": soul=" .. type(e.soul) .. " human=" .. type(e.human))
        pcall(function()
            if type(e.soul) == "table" then
                L(tag .. ".soul.HasScriptContext : " .. type(e.soul.HasScriptContext))
                L(tag .. ".soul.RestrictDialog   : " .. type(e.soul.RestrictDialog))
                L(tag .. ".soul.IsDialogRestricted : " .. type(e.soul.IsDialogRestricted))
                -- Candidate setters: enumerate, never guess. Any key whose
                -- name mentions Context/Option/Restrict is worth seeing.
                for k, v in pairs(e.soul) do
                    if type(k) == "string" and (string.find(k, "ontext") or string.find(k, "ption") or string.find(k, "estrict")) then
                        L(tag .. ".soul." .. k .. " : " .. type(v))
                    end
                end
            end
            if type(e.human) == "table" then
                L(tag .. ".human.InterruptDialogs : " .. type(e.human.InterruptDialogs))
                for k, v in pairs(e.human) do
                    if type(k) == "string" and (string.find(k, "ontext") or string.find(k, "ialog")) then
                        L(tag .. ".human." .. k .. " : " .. type(v))
                    end
                end
            end
        end)
        for _, ctx in ipairs(KCD2MP.isolationContexts) do
            local res = nil
            local ok, err = pcall(function() res = e.soul:HasScriptContext(ctx) end)
            L(tag .. " HasScriptContext('" .. ctx .. "') ok=" .. tostring(ok)
                .. " -> " .. tostring(res) .. (ok and "" or (" err=" .. tostring(err))))
        end
    end

    local gid, ghost = next(KCD2MP.ghosts)
    if ghost and ghost.entity then
        probeBody("ghost[" .. tostring(gid) .. "]", ghost.entity)
    else
        L("no live ghost -- spawn one (mp_spawn_test) and rerun for the ghost half")
    end
    probeBody("player", player)

    L("=== END CONTEXTS PROBE ===")
end

-- ===== Horse Diagnostics =====

-- Runs in MOD context (has access to Terrain, player, etc).
-- Writes result to sv_servername so probe_riding.ps1 can read it.
function KCD2MP_DiagRideDetect()
    if not player then
        System.SetCVar("sv_servername", "player=nil")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then
        System.SetCVar("sv_servername", "GetWorldPos=nil")
        return
    end

    -- Find entities within 6m - list all classes to identify the horse
    local classes = {}
    pcall(function()
        local ents = System.GetEntitiesInSphere(pos, 6.0)
        if ents then
            for _, e in ipairs(ents) do
                if e ~= player then
                    local ec = "?"
                    local ep = nil
                    pcall(function() ec = tostring(e.class or "?") end)
                    if ec == "?" then pcall(function() ec = tostring(e:GetClass()) end) end
                    pcall(function() ep = e:GetWorldPos() end)
                    local d = ep and math.sqrt((ep.x-pos.x)^2+(ep.y-pos.y)^2+(ep.z-pos.z)^2) or 99
                    if d < 6 then
                        classes[#classes+1] = string.format("%s:%.1f", ec, d)
                    end
                end
            end
        end
    end)

    local clStr = table.concat(classes, " | ")
    if clStr == "" then clStr = "none" end
    -- Trim to fit CVar (max ~200 chars)
    if #clStr > 180 then clStr = clStr:sub(1,180) end
    System.SetCVar("sv_servername", clStr)
end

-- Probe ALL riding anim candidates on any ghost currently in riding state.
-- Shows which names have GetAnimationLength > 0.
-- Also tries to get current player animation name (for when player is on horse).
function KCD2MP_ProbeRidingAnims()
    -- Find first riding ghost
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do
        if g.istate and g.istate.isRiding then ghost = g; break end
    end
    -- Fall back to any ghost
    if not ghost then
        for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeRidingAnims: no ghost. Spawn one first.")
        return
    end

    System.LogAlways("[KCD2-MP] === PROBE RIDING ANIMS ===")
    local ent = ghost.entity
    local allCandidates = {}
    for _, v in ipairs(RIDING_IDLE_ANIMS)   do allCandidates[#allCandidates+1] = v end
    for _, v in ipairs(RIDING_GALLOP_ANIMS) do allCandidates[#allCandidates+1] = v end
    -- Extra patterns
    local extras = {
        "horse", "Horse", "riding", "Riding", "mounted", "Mounted",
        "3d_horse", "3d_riding", "3d_mounted",
        "horse_walk", "horse_run", "horse_idle", "horse_gallop",
        "act_horse", "act_riding", "act_mounted",
        "loco_horse", "loco_riding",
    }
    for _, v in ipairs(extras) do allCandidates[#allCandidates+1] = v end

    local hits = 0
    for _, name in ipairs(allCandidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] RIDING HIT: '%s' len=%.3f", name, len))
            hits = hits + 1
        end
    end
    System.LogAlways(string.format("[KCD2-MP] Riding anims found: %d / %d tested", hits, #allCandidates))

    -- Also try to read the current animation name from player (if riding a horse right now)
    local ok, an = pcall(function()
        if player then
            local n = nil
            pcall(function() n = player:GetCurrentAnimationName(0) end)
            return n
        end
    end)
    System.LogAlways("[KCD2-MP] Player current anim: " .. tostring(an) .. " (useful if player is on horse)")
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Find horse/animal entities near player and log their class names
function KCD2MP_FindHorses()
    if not player then System.LogAlways("[KCD2-MP] FindHorses: no player"); return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HORSES ===")

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 60)
        if not ents then System.LogAlways("[KCD2-MP] GetEntitiesInSphere returned nil"); return end

        local count = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                local eclass = "?"
                local ename  = "?"
                pcall(function() eclass = tostring(ent.class or "?") end)
                pcall(function() ename  = tostring(ent:GetName()) end)

                -- Log anything that looks like it could be a horse or animal
                local lc = eclass:lower()
                local ln = ename:lower()
                if lc:find("horse") or lc:find("animal") or lc:find("mount") or lc:find("creature")
                   or ln:find("horse") or ln:find("roach") or ln:find("pebbles") or ln:find("animal")
                then
                    local pos = nil
                    pcall(function() pos = ent:GetWorldPos() end)
                    local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or -1
                    System.LogAlways(string.format("[KCD2-MP] HORSE? class='%s' name='%s' dist=%.1fm",
                        eclass, ename, dist))
                    count = count + 1
                end
            end
        end

        -- Also just log ALL entity classes within 15m (to catch horses with unexpected class names)
        System.LogAlways("[KCD2-MP] --- All entities within 15m ---")
        for _, ent in ipairs(ents) do
            local eclass = "?"
            local ename  = "?"
            pcall(function() eclass = tostring(ent.class or "?") end)
            pcall(function() ename  = tostring(ent:GetName()) end)
            local pos = nil
            pcall(function() pos = ent:GetWorldPos() end)
            local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or 99
            if dist < 15 then
                System.LogAlways(string.format("[KCD2-MP]   class='%s' name='%s' dist=%.1fm",
                    eclass, ename, dist))
            end
        end
        System.LogAlways(string.format("[KCD2-MP] Horse-like entities found: %d", count))
    end)
    if not ok then System.LogAlways("[KCD2-MP] FindHorses error: " .. tostring(err)) end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Force-spawn a horse using several class name guesses to find what works in KCD2
function KCD2MP_SpawnHorseTest()
    if not player then System.LogAlways("[KCD2-MP] SpawnHorseTest: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Offset 4m to the right of player
    local spawnPos = {x = pos.x + 4, y = pos.y, z = pos.z}

    local classes = {
        "Horse", "Animal", "HorseAnimal", "horse", "animal",
        "kcd_horse", "RPGHorse", "CreatureAnimal", "Creature",
    }

    System.LogAlways("[KCD2-MP] === SPAWN HORSE TEST ===")
    for _, cls in ipairs(classes) do
        local ok, ent = pcall(System.SpawnEntity, {
            class    = cls,
            position = spawnPos,
            name     = "kcd2mp_horsetest_" .. cls,
        })
        if ok and ent then
            System.LogAlways(string.format("[KCD2-MP] SUCCESS class='%s' entityId=%s", cls, tostring(ent.id)))
            -- Don't remove it - let user see which one appears in-game
        else
            System.LogAlways(string.format("[KCD2-MP] FAIL class='%s' err=%s", cls, tostring(ent)))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Log current riding detection state for the local player
function KCD2MP_RidingState()
    System.LogAlways("[KCD2-MP] === RIDING STATE ===")
    System.LogAlways("[KCD2-MP] KCD2MP.isRiding = " .. tostring(KCD2MP.isRiding))

    if not player then System.LogAlways("[KCD2-MP] player=nil"); return end

    -- Test method 1: human:IsRiding
    local ok1, r1 = pcall(function()
        if player.human then
            return player.human:IsRiding()
        end
        return "human=nil"
    end)
    System.LogAlways("[KCD2-MP] human:IsRiding() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))

    -- Test method 2: GetLinkedParent
    local ok2, r2 = pcall(function() return player:GetLinkedParent() end)
    System.LogAlways("[KCD2-MP] GetLinkedParent() ok=" .. tostring(ok2) .. " val=" .. tostring(r2))

    -- Test method 3: soul state
    local ok3, r3 = pcall(function()
        if player.soul then return player.soul.bRiding end
        return "soul=nil"
    end)
    System.LogAlways("[KCD2-MP] soul.bRiding ok=" .. tostring(ok3) .. " val=" .. tostring(r3))

    -- Test method 4: actor mount
    local ok4, r4 = pcall(function()
        if player.actor then return player.actor:GetMount() end
        return "actor=nil"
    end)
    System.LogAlways("[KCD2-MP] actor:GetMount() ok=" .. tostring(ok4) .. " val=" .. tostring(r4))

    System.LogAlways("[KCD2-MP] === END ===")
end

function KCD2MP_GhostState()
    System.LogAlways("[KCD2-MP] === GHOST STATE ===")
    local count = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        count = count + 1
        local istate = ghost.istate or {}
        local horseData = KCD2MP.horseGhosts[id]
        System.LogAlways(string.format(
            "[KCD2-MP] Ghost id=%s isRiding=%s nativeMounted=%s ridingFallback=%s hasHorse=%s",
            tostring(id),
            tostring(istate.isRiding),
            tostring(istate.nativeMounted),
            tostring(istate.ridingFallback),
            tostring(horseData ~= nil)
        ))
        -- Check if NPC has .human and if IsMounted works
        if ghost.entity then
            local ok, mounted = pcall(function() return ghost.human and ghost.human:IsMounted() end)
            System.LogAlways("[KCD2-MP]   IsMounted ok=" .. tostring(ok) .. " val=" .. tostring(mounted))
            -- Check if horse entity exists
            if horseData and horseData.entity then
                local ok2, hasRider = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:HasRider()
                end)
                local ok3, isMountable = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:IsMountable()
                end)
                System.LogAlways("[KCD2-MP]   horse.HasRider ok=" .. tostring(ok2) .. " val=" .. tostring(hasRider))
                System.LogAlways("[KCD2-MP]   horse.IsMountable ok=" .. tostring(ok3) .. " val=" .. tostring(isMountable))
            end
        end
    end
    System.LogAlways("[KCD2-MP] Total ghosts=" .. count .. " horseGhosts=" .. (function()
        local n=0; for _ in pairs(KCD2MP.horseGhosts) do n=n+1 end; return n
    end)())
end

-- ===== WO-38 Phase 8: map marker probe =====
-- The shipped scriptbind docs document GameRules.AddMinimapEntity(entityId,
-- type, lifetime) / RemoveMinimapEntity(entityId) -- exactly the shape a
-- "show connected players on the map" feature needs, because each ghost is
-- already a real local entity whose position the mod keeps synced; marking
-- the ENTITY means the map marker moves for free. But this is a Crysis-era
-- GameRules bind against KCD2's custom Warhorse map UI, and this project has
-- already met documented-but-unregistered binds (Actor.SetAIBrainId, WO-32)
-- and registered-but-inert ones (most AI writes). So the feature ships as a
-- PROBE first: run `mp_map_marker <type>` live with a ghost present, open
-- the map, and see. If a type value renders, wiring it into SpawnGhost is a
-- three-line follow-up.
-- Usage: mp_map_marker <typeInt>   (tries that icon type on every ghost)
--        mp_map_marker sweep       (tries types 0..15, one per ghost re-add)
function KCD2MP_ProbeMapMarker(arg)
    local hasBind = (GameRules ~= nil) and (type(GameRules.AddMinimapEntity) == "function")
    System.LogAlways("[KCD2-MP] MapMarker probe: GameRules.AddMinimapEntity registered=" .. tostring(hasBind))
    if not hasBind then return end

    local types = {}
    if tostring(arg or ""):lower() == "sweep" then
        for t = 0, 15 do types[#types+1] = t end
    else
        types[1] = tonumber(arg) or 1
    end

    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            for _, t in ipairs(types) do
                local ok, err = pcall(function()
                    GameRules.AddMinimapEntity(ghost.entity.id, t, 0)
                end)
                System.LogAlways(string.format("[KCD2-MP] MapMarker ghost=%s type=%d ok=%s err=%s",
                    tostring(id), t, tostring(ok), tostring(err)))
            end
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] MapMarker probe: no ghosts to mark -- connect a peer first") end
end

-- Test spawning entities via XGenAIModule with various class names.
-- Safe: each class wrapped in pcall, entity removed after 10s.
-- Usage: mp_test_xgen <ClassName>  (default: NullAI)
function KCD2MP_TestXGenSpawn(className)
    if not player then System.LogAlways("[KCD2-MP] TestXGenSpawn: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    className = (className and className ~= "") and className or "NullAI"
    local testName = "kcd2mp_xgen_test"
    System.LogAlways("[KCD2-MP] TestXGenSpawn: trying ClassName=" .. className)

    -- Remove previous test entity if exists
    pcall(function()
        local old = System.GetEntityByName(testName)
        if old then System.RemoveEntity(old.id) end
    end)

    -- Try XGenAIModule.SpawnEntity
    local ok, err = pcall(function()
        local eid = XGenAIModule.SpawnEntity{
            Name      = testName,
            ClassName = className,
            Pos       = {pos.x + 2, pos.y, pos.z},
            Properties = { esFaction = "Civilians" },
        }
        System.LogAlways("[KCD2-MP] TestXGenSpawn: XGenAI returned eid=" .. tostring(eid))
        local ent = System.GetEntityByName(testName)
        if ent then
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity found id=" .. tostring(ent.id)
                .. " class=" .. tostring(ent.class))
            -- Check human/actor/horse sub-objects
            local hasSoul   = pcall(function() return ent.soul end)
            local hasHuman  = pcall(function() return ent.human end)
            local isMounted = pcall(function() return ent.human and ent.human:IsMounted() end)
            System.LogAlways("[KCD2-MP] TestXGenSpawn: hasSoul=" .. tostring(hasSoul)
                .. " hasHuman=" .. tostring(hasHuman)
                .. " IsMounted=" .. tostring(isMounted))
            -- Remove after 10s
            local eid2 = ent.id
            Script.SetTimer(10000, function()
                pcall(function() System.RemoveEntity(eid2) end)
                System.LogAlways("[KCD2-MP] TestXGenSpawn: removed test entity")
            end)
        else
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity NOT found by name after spawn")
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] TestXGenSpawn: CRASHED/ERROR: " .. tostring(err))
    end
end


KCD2MP.modules.diagnostics = true
