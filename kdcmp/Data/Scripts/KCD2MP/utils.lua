-- KCD2 Multiplayer - shared utilities
-- Keep this module limited to helpers used by more than one feature module.

KCD2MP.util = {}
KCD2MP.debugLog = {}

local MP_LOG_MAX = 50
local TICK_ALIVE_WINDOW = 1.0
local HIT_MIN_DELTA = 0.05

function KCD2MP.util.log(msg)
    local entry = string.format("[%.2f] %s", os.clock(), msg)
    table.insert(KCD2MP.debugLog, entry)
    if #KCD2MP.debugLog > MP_LOG_MAX then
        table.remove(KCD2MP.debugLog, 1)
    end
    System.LogAlways("[KCD2-MP] " .. msg)
end

function KCD2MP_PopLog()
    if #KCD2MP.debugLog > 0 then
        return table.remove(KCD2MP.debugLog, 1)
    end
    return ""
end

function KCD2MP.util.lerp(a, b, t)
    return a + (b - a) * t
end

function KCD2MP.util.lerpAngle(a, b, t)
    local diff = b - a
    local twopi = math.pi * 2
    diff = diff - math.floor((diff + math.pi) / twopi) * twopi
    return a + diff * t
end

function KCD2MP.util.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function KCD2MP.util.tickAlive(flag, stamp)
    return flag and stamp ~= nil and (os.clock() - stamp) < TICK_ALIVE_WINDOW
end

-- Entity removal can return without error while the entity is still alive.
-- Verify by both stable identifiers and retry before reporting success.
function KCD2MP.util.removeEntityVerified(entityId, spawnName, label)
    local function alive()
        local entity = nil
        if entityId then pcall(function() entity = System.GetEntity(entityId) end) end
        if (not entity) and spawnName then
            pcall(function() entity = System.GetEntityByName(spawnName) end)
        end
        return entity
    end

    for pass = 1, 4 do
        local entity = alive()
        if not entity then
            if pass > 1 then
                KCD2MP.util.log(string.format("RemoveEntity %s gone after %d pass(es)", tostring(label), pass - 1))
            end
            return true
        end
        pcall(function() System.RemoveEntity(entity.id or entityId) end)
    end

    local entity = alive()
    if entity then
        KCD2MP.util.log(string.format("RemoveEntity %s STILL ALIVE after 4 passes (entityId=%s name=%s)",
            tostring(label), tostring(entityId), tostring(spawnName)))
        return false
    end
    return true
end

-- Flow-B damage sensor shared by the ghost lifecycle and interpolation code.
-- An authoritative inbound health write arms ghostHpSkip, preventing it from
-- being reflected back as a new hit on the next sample.
function KCD2MP.util.sampleGhostHealth(id, ghost)
    if not KCD2MP.hitSensorOn then return end
    if not (ghost and ghost.entity and ghost.entity.actor) then return end

    local hp = nil
    pcall(function() hp = ghost.entity.actor:GetHealth() end)
    if type(hp) ~= "number" then return end

    local prev = KCD2MP.ghostHpSeen[id]
    KCD2MP.ghostHpSeen[id] = hp
    if KCD2MP.ghostHpSkip[id] then
        KCD2MP.ghostHpSkip[id] = nil
        return
    end
    if prev == nil then return end

    local delta = prev - hp
    if delta < HIT_MIN_DELTA then return end
    KCD2MP_EmitEvent("ghost_hit", string.format("%s %.2f", tostring(id), delta))
end

KCD2MP.modules.utils = true
