-- Shared-world feasibility probes.
--
-- A single shared world state requires four capabilities that are currently
-- UNVERIFIED. None appears in docs/kcd2_lua_api.md, so per the project's first
-- rule these are discovered rather than guessed at:
--
--   1. Suppress or freeze an existing NPC's AI, so a non-authoritative client
--      stops simulating its own copy. Without this every client runs its own
--      brain for the same NPC and they fight each other.
--   2. Apply damage / set health on an NPC from script, so a hit landed on the
--      authority can be reproduced everywhere else.
--   3. Enumerate NPCs cheaply enough for the authority to report their state
--      every tick.
--   4. Set world time, so shared content happens at the same time of day.
--
-- These probes enumerate what the API actually exposes instead of testing
-- guessed names, because a guessed name that comes back nil proves nothing
-- about whether the capability exists under a different name.
--
-- Run with the existing driver:
--   powershell -File tools\Probe-Transport.ps1 -LuaFile tools\probe_sharedworld.lua
--
-- Blocks are kept small: long or deeply nested chunks are silently dropped by
-- the console endpoint with no error (see probe_transport.lua).

--@@BLOCK ai
-- Everything the AI table exposes. Capability 1 lives here if anywhere:
-- something that stops an NPC thinking without deleting it.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
if type(AI) ~= "table" then P("AI", "MISSING") else
    for k,v in pairs(AI) do P("AI."..tostring(k), type(v)) end
end

--@@BLOCK game
-- The Game table. Time-of-day control and global world calls would live here.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
if type(Game) ~= "table" then P("Game", "MISSING") else
    for k,v in pairs(Game) do P("Game."..tostring(k), type(v)) end
end

--@@BLOCK npcfind
-- Grab a real game NPC (not the player, not one of our ghosts) and stash it so
-- later blocks can inspect the genuine article rather than our own spawn.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
KCD2MP = KCD2MP or {}
local ppos = player:GetWorldPos()
local ents = System.GetEntitiesInSphere(ppos, 40)
P("npc.scanned", ents and #ents or "nil")
local found = nil
for i = 1, (ents and #ents or 0) do
    local e = ents[i]
    if e and e ~= player and e.actor and e.soul then
        local nm = tostring(e:GetName())
        if not string.find(nm, "kdcmp") then
            found = e
            P("npc.name", nm)
            P("npc.class", tostring(e.class))
            break
        end
    end
end
KCD2MP._pnpc = found
P("npc.found", found ~= nil)

--@@BLOCK npckeys
-- What the NPC entity itself exposes.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._pnpc
if not e then P("npckeys", "NO_NPC") else
    for k,v in pairs(e) do P("npc."..tostring(k), type(v)) end
end

--@@BLOCK npcsoul
-- The soul is where health and stats live for the player, so it is the most
-- likely home for capability 2.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._pnpc
if not e or type(e.soul) ~= "table" then P("npcsoul", "NO_SOUL") else
    for k,v in pairs(e.soul) do P("soul."..tostring(k), type(v)) end
end

--@@BLOCK npcactor
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._pnpc
if not e or type(e.actor) ~= "table" then P("npcactor", "NO_ACTOR") else
    for k,v in pairs(e.actor) do P("actor."..tostring(k), type(v)) end
end

--@@BLOCK npcai
-- entity.AI, distinct from the global AI table.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
local e = KCD2MP and KCD2MP._pnpc
if not e or type(e.AI) ~= "table" then P("npcai", "NO_ENTITY_AI") else
    for k,v in pairs(e.AI) do P("entAI."..tostring(k), type(v)) end
end

--@@BLOCK time
-- Capability 4. Reading GameTime already works through the REST API; the
-- question is whether anything can write it.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] "..k.."="..tostring(v)) end
for _, n in ipairs({ "Calendar", "Time", "Environment", "Weather", "TimeOfDay" }) do
    P("global."..n, type(rawget(_G, n)))
end
if type(Calendar) == "table" then
    for k,v in pairs(Calendar) do P("Calendar."..tostring(k), type(v)) end
end
