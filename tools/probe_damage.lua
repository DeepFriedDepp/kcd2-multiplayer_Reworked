-- Damage / health discovery. THE gate for shared combat.
--
-- If a script cannot apply damage to an NPC, then two players cannot wear down
-- the same enemy and "fight together" degrades to "fight your own copy while
-- standing next to each other". Everything else in the shared-ambient design
-- has candidate APIs already; this does not.
--
-- The earlier probe found nothing health-shaped on entity.soul, but it only
-- walked pairs(), which misses methods inherited through a metatable __index,
-- and it never looked at entity.human. So this widens the search before
-- concluding anything.
--
-- Also collects the NPC's name, class and faction, because the design needs a
-- runtime way to tell an ambient guard from a quest-critical character and
-- there is no known flag for that.
--
-- Run: powershell -File tools\Probe-Transport.ps1 -LuaFile tools\probe_damage.lua

--@@BLOCK pick
-- Stash a real NPC and describe it well enough to reason about classification.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
KCD2MP = KCD2MP or {}
local ents = System.GetEntitiesInSphere(player:GetWorldPos(), 40)
local found = nil
for i = 1, (ents and #ents or 0) do
    local e = ents[i]
    if e and e ~= player and e.actor and e.soul and not string.find(tostring(e:GetName()), "kdcmp") then
        found = e
        break
    end
end
KCD2MP._dnpc = found
if not found then P("pick", "NO_NPC") else
    P("pick.entityName", tostring(found:GetName()))
    P("pick.class", tostring(found.class))
    P("pick.soulName", tostring(found.soul.name))
    P("pick.sName", tostring(found.soul.sName))
end

--@@BLOCK faction
-- Faction and properties are the most plausible basis for classifying an NPC as
-- ambient rather than quest-critical.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e then P("faction", "NO_NPC") else
    if type(e.Properties) == "table" then
        for k,v in pairs(e.Properties) do
            if type(v) ~= "table" then P("prop."..tostring(k), tostring(v)) end
        end
    end
    pcall(function() P("faction.param", tostring(AI.GetParameter(e.id, AIPARAM_FACTION))) end)
end

--@@BLOCK human
-- entity.human was never inspected and is the next likely home for health.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e or type(e.human) ~= "table" then P("human", "NO_HUMAN") else
    for k,v in pairs(e.human) do P("human."..tostring(k), type(v)) end
end

--@@BLOCK metasoul
-- Walk the metatable chain on soul: pairs() misses inherited methods, which is
-- how player.soul:GetSkillLevel can exist without showing up in a key dump.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e then P("metasoul", "NO_NPC") else
    local mt = getmetatable(e.soul)
    P("soul.hasMeta", mt ~= nil)
    if mt and type(mt.__index) == "table" then
        for k,v in pairs(mt.__index) do P("soulMeta."..tostring(k), type(v)) end
    end
end

--@@BLOCK metaactor
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e then P("metaactor", "NO_NPC") else
    local mt = getmetatable(e.actor)
    P("actor.hasMeta", mt ~= nil)
    if mt and type(mt.__index) == "table" then
        for k,v in pairs(mt.__index) do P("actorMeta."..tostring(k), type(v)) end
    end
end

--@@BLOCK metahuman
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e or type(e.human) ~= "table" then P("metahuman", "NO_HUMAN") else
    local mt = getmetatable(e.human)
    P("human.hasMeta", mt ~= nil)
    if mt and type(mt.__index) == "table" then
        for k,v in pairs(mt.__index) do P("humanMeta."..tostring(k), type(v)) end
    end
end

--@@BLOCK statsoul
-- Souls carry stats for the player (HaveSkill/GetSkillLevel are documented), so
-- health is plausibly a named stat rather than a method. Probe read access.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._dnpc
if not e then P("statsoul", "NO_NPC") else
    for _, n in ipairs({ "health", "hp", "vitality", "stamina" }) do
        pcall(function() P("stat.get."..n, tostring(e.soul:GetState(n))) end)
        pcall(function() P("stat.derived."..n, tostring(e.soul:GetDerivedStat(n))) end)
        pcall(function() P("stat.base."..n, tostring(e.soul:GetBaseStat(n))) end)
    end
end
