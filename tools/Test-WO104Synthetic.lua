-- WO-104 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- Phase 0 -- world-time wire formatting:
--   (a) with tostring() made to behave like this build's engine Lua ("%g",
--       observed 2026-09-18: 1002550 -> '1.00255e+06'), KCD2MP_ReportWorldTime
--       still emits the exact integer for a clock above 1e6, and for a
--       fractional clock; the pre-WO-104 form is shown to break under the
--       same tostring so the mimic is proven to bite.
--
-- Phase 1 -- brainless replicas for contested NPCs (mp_npc_replica_on|off):
--   (b) toggle OFF: a contention violation changes nothing (today's path)
--   (c) toggle ON: the first violation promotes -- one NPC+NoAI spawn bound
--       to the original's soul id, original hidden in the same call, npcid
--       and npc_replica re-pointed, the stream writes the replica from then
--       on and never the NPC, no violation on the replica body
--   (d) resolution: weapon away on the stream for sheathedDemoteS demotes;
--       NPC unhidden where the replica stood, replica removed, events back
--   (e) death (stream bit or the WORLD NPC's own IsDead) demotes at once
--   (f) silence release, toggle off, host-authority off and KCD2MP_Stop all
--       demote; with the toggle off nothing promotes again
--   (g) refusals, once each, nothing spawned: NPC_Female, Horse, no soul,
--       non-WUID soul id, dead, in-dialog, a soulless replica, spawn failure
--   (h) the 5 s sweep: an unregistered kcd2mp_r_ body is removed and its
--       original unhidden; a vanished replica demotes; runs toggle or not
--   (i) argless console commands, status line, MP-SUMMARY-MOD counters
--
-- Driven by Test-WO104Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about a live game -- see docs/WO-104-findings.md.
--
-- Part 1: engine stubs + a fake clock (same shape as Test-WO102Synthetic.lua).

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; ALLCMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntity = function(id) for _, e in pairs(ENTS) do if e.id == id then return e end end return nil end
System.GetEntitiesInSphere = function() return SPHERE end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s); ALLCMDS[#ALLCMDS + 1] = tostring(s) end
System.DrawText = function(x, y, text, size) DRAWS[#DRAWS + 1] = { x = x, y = y, text = tostring(text) } end
System.RemoveEntity = function(eid) for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end end
System.AddCCommand = function(name, body, help) CCMDS[name] = { body = tostring(body), help = tostring(help or "") } end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }
XGenAIModule = mkstub()
-- Spawned bodies: a full entity stub (position, angles, actor, human, soul)
-- so a replica can be driven by the puppet tick exactly like a world NPC.
NEXTID = 9000
function mkEntity(name, x, y, z, class)
    NEXTID = NEXTID + 1
    local e = { class = class or "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0,
                writes = {}, dead = false, ko = false, hp = 100, hidden = 0, hides = {}, anims = {} }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = pos end
    e.SetWorldAngles = function(self, a) self.rz = a.z; self.angles = self.angles or {}; self.angles[#self.angles + 1] = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = anim end
    e.GetAnimationLength = function() return 1.0 end
    e.Hide = function(self, v) if v == nil then v = 1 end; self.hidden = v; self.hides[#self.hides + 1] = v end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return e.ko end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return e.drawnNow == true end,
                DrawWeapon = function() e.drawnNow = true; return true end,
                HolsterWeapon = function() e.drawnNow = false; return true end }
    e.soul = { GetId = function() return e.soulId or ("4e628918-2a38-c1ea-c786-2424" .. string.format("%08d", e.id)) end, name = name }
    return e
end
XGenAIModule.SpawnEntity = function(t)
    SPAWNS[#SPAWNS + 1] = t
    if SPAWN_FAIL then return nil end
    local p = t.Pos or { 0, 0, 0 }
    local e = mkEntity(t.Name, p[1], p[2], p[3], t.ClassName)
    if SPAWN_SOULLESS then e.soul = nil end
    e.spawnTable = t
    ENTS[t.Name] = e
    return e
end

player = { id = 1, GetName = function(self) return "Dude" end,
           GetWorldPos = function() return { x = 0, y = 0, z = 0 } end,
           GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
           actor = { GetHealth = function() return 100 end, IsDead = function() return false end } }

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return table.unpack(r)
end

-- WO-104 Phase 0: make tostring() behave like this build's engine Lua for
-- numbers. Standard Lua 5.1 uses "%.14g" (1002550 prints as 1002550);
-- the engine's build prints '1.00255e+06' -- i.e. plain "%g", six
-- significant digits. Installed BEFORE kdcmp.lua loads so every number the
-- mod stringifies goes through it, exactly as in the game.
local rawtostring = tostring
tostring = function(v)
    if type(v) == "number" then return string.format("%g", v) end
    return rawtostring(v)
end

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. rawtostring(detail) .. "]") or "")
end
local function logCount(pat)
    local n = 0
    for _, l in ipairs(LOG) do if string.find(l, pat, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(pat)
    for i = #LOG, 1, -1 do if string.find(LOG[i], pat, 1, true) then return LOG[i] end end
    return nil
end
local function clearLog() LOG = {} end
local function evtArg(evName)
    -- "[KCD2-MP-EVT] v1 <seq> <name> <arg>" -> arg of the LAST such event
    for i = #LOG, 1, -1 do
        local a = string.match(LOG[i], "^%[KCD2%-MP%-EVT%] v1 %d+ " .. evName .. " (.*)$")
        if a then return a end
    end
    return nil
end

-- ---------------------------------------------------------------- Phase 0
do -- (a) time_now formatting past 1e6
    -- The mimic itself bites: this is what the pre-WO-104 sender produced.
    check("a: tostring mimic reproduces the field failure", tostring(1002550) == "1.00255e+06", tostring(1002550))

    clearLog(); WORLD_T = 1002550
    KCD2MP_ReportWorldTime()
    check("a: time_now above 1e6 is the exact integer", evtArg("time_now") == "1002550", evtArg("time_now"))

    clearLog(); WORLD_T = 1002550.7
    KCD2MP_ReportWorldTime()
    check("a: fractional clock floors to a plain integer", evtArg("time_now") == "1002550", evtArg("time_now"))

    clearLog(); WORLD_T = 982149
    KCD2MP_ReportWorldTime()
    check("a: below 1e6 unchanged", evtArg("time_now") == "982149", evtArg("time_now"))

    clearLog(); WORLD_T = 4294967295   -- uint32 max, the agent's parse ceiling
    KCD2MP_ReportWorldTime()
    check("a: uint32 max still a plain integer", evtArg("time_now") == "4294967295", evtArg("time_now"))

    -- Round trip: the value the agent pushes back as a Lua literal parses to
    -- the same clock, and the mod's own forward-only apply accepts it.
    clearLog(); WORLD_T = 1002550
    KCD2MP_ApplyTimeSkip("peer", 1, "1002560", true)
    check("a: apply of a >1e6 target lands exactly", WORLD_T == 1002560, WORLD_T)
    check("a: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- Phase 1
-- Replica scenarios. Every one runs as a NON-authority under host
-- authority (the only role that has owned puppets to contest).
local function resetReplica()
    KCD2MP.wo102.authorityHost = true; KCD2MP.wo102.authorityPause = false
    KCD2MP.wo102.npcScanNative = false; KCD2MP.wo102.posNative = false
    KCD2MP.hitSensorOn = false
    KCD2MP.npcPuppets = {}; KCD2MP.npcTracked = {}; KCD2MP.dragging = {}; KCD2MP.dragWatch = {}
    KCD2MP.npcPuppetRunning = false; KCD2MP._npcDivergeUntil = {}
    KCD2MP._npcPaused = {}; KCD2MP._authViolationAt = {}; KCD2MP._authViolationN = {}
    KCD2MP._authStats = { acquire = 0, release = 0, ownerChange = 0, pause = 0, resume = 0, violation = 0 }
    KCD2MP._npcDeathRemote = {}; KCD2MP._npcDeathDiverged = {}
    KCD2MP.npcDiverge = true; KCD2MP.npcYield.enabled = true
    KCD2MP.ghosts = {}; KCD2MP._npcScanAnchors = nil
    KCD2MP.wo1025.together = false; KCD2MP._togetherWantSince = nil; KCD2MP._colocatePendingRelease = {}
    KCD2MP._npcReplicas = {}
    KCD2MP._npcReplicaStats = { promote = 0, demote = 0, refused = 0, orphan = 0, violationsOnReplica = 0 }
    KCD2MP._npcReplicaRefused = {}
    KCD2MP.npcReplica.enabled = false
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}; SPAWNS = {}; CMDS = {}
    SPAWN_FAIL = false; SPAWN_SOULLESS = false
    clearLog()
end
-- One stream packet + one puppet tick; the "local brain" then drags the
-- world NPC `e` by dragM (the WO-102 suite's contention model).
local function driveTick(name, e, dragM, flags)
    NOW = NOW + 0.05
    KCD2MP_ApplyNpcState(name, 10, 0, 0, 0, 100, flags or 0, 1)   -- stream keeps it at x=10
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
    if dragM and dragM ~= 0 then e.px = e.px + dragM end
end
local function drive(name, e, dragM, n, flags)
    for i = 1, n do driveTick(name, e, dragM, flags) end
end
local function replicaOf(name) return ENTS["kcd2mp_r_" .. name] end
local CONTEND = KCD2MP.npcYield.ticks + 3

do -- (b) toggle OFF: today's behaviour, byte for byte
    resetReplica()
    check("b: replica toggle ships OFF", KCD2MP.npcReplica.enabled == false)
    local e = mkEntity("b_npc", 10, 0, 0); ENTS["b_npc"] = e
    NOW = 100
    drive("b_npc", e, 0.6, CONTEND, 4)
    check("b: contention violation still logged, body=npc", logCount("MP-AUTHORITY-VIOLATION npc=b_npc kind=contention") >= 1
          and string.find(lastLog("MP-AUTHORITY-VIOLATION npc=b_npc"), "body=npc", 1, true) ~= nil, lastLog("MP-AUTHORITY-VIOLATION"))
    check("b: nothing spawned", #SPAWNS == 0)
    check("b: no MP-NPCREPLICA line", logCount("MP-NPCREPLICA") == 0)
    check("b: the world NPC is never hidden", #e.hides == 0 and e.hidden == 0)
    check("b: the world NPC is still the body being written", #e.writes >= CONTEND - 1)
    check("b: no npc_replica event", evtArg("npc_replica") == nil)
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (c) toggle ON: a contention violation promotes, the stream moves to the replica
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local e = mkEntity("c_npc", 10, 0, 0); e.rz = 1.25; ENTS["c_npc"] = e
    local soulId = e.soul:GetId()
    NOW = 200
    drive("c_npc", e, 0.6, CONTEND, 4)   -- weapon drawn on the stream
    local r = replicaOf("c_npc")
    check("c: promoted on the first violation", logCount("MP-NPCREPLICA npc=c_npc event=promote why=violation-contention body=kcd2mp_r_c_npc") == 1, lastLog("MP-NPCREPLICA"))
    check("c: exactly one spawn", #SPAWNS == 1 and r ~= nil)
    local t = SPAWNS[1] or {}
    check("c: spawn is class NPC with NoAI=true (not NPC_NAI -- WO-100.5 s1.3)", t.ClassName == "NPC" and t.NoAI == true, tostring(t.ClassName) .. "/" .. tostring(t.NoAI))
    check("c: spawn is soul-bound to the ORIGINAL's soul id", t.SharedSoulGuid == soulId, tostring(t.SharedSoulGuid))
    check("c: spawn named kcd2mp_r_<npc>", t.Name == "kcd2mp_r_c_npc")
    check("c: replica name is excluded from inbound streams (kcd2mp_ prefix)", KCD2MP.npcPuppets["kcd2mp_r_c_npc"] == nil)
    -- The first angle written to the replica is the NPC's facing at the
    -- moment of the swap (under a stream that is already the stream's
    -- rotation -- the puppet tick had been writing it); the original is not
    -- written again afterwards, so its rz still holds that value.
    check("c: replica first turned to the way the NPC faced at the swap", r ~= nil and r.angles ~= nil and math.abs(r.angles[1] - e.rz) < 1e-6, (r and r.angles and r.angles[1] or "nil") .. " vs " .. e.rz)
    check("c: the world NPC is hidden, once, in the same call", #e.hides == 1 and e.hidden == 1)
    -- same tostring-hex idiom the mod uses (a stub id is a number; in the game it is the engine's hex handle)
    local function hexOf(x) return string.match(tostring(x.id), "(%x+)%s*$") end
    check("c: npcid re-pointed at the replica's entity id", r ~= nil and evtArg("npcid") == "c_npc " .. hexOf(r), evtArg("npcid"))
    check("c: npc_replica event names the pair", evtArg("npc_replica") == "c_npc kcd2mp_r_c_npc", evtArg("npc_replica"))
    check("c: puppet table survives the swap (same owner)", KCD2MP.npcPuppets["c_npc"] ~= nil and KCD2MP.npcPuppets["c_npc"].owner == 1)
    local origWrites, repWrites = #e.writes, #(r and r.writes or {})
    drive("c_npc", e, 0.6, 20, 4)   -- the brain keeps dragging the (hidden) NPC
    check("c: after promotion the stream writes the replica", r ~= nil and #r.writes >= repWrites + 15, r and #r.writes)
    check("c: and no longer writes the world NPC", #e.writes == origWrites, #e.writes - origWrites)
    check("c: no violation on the replica body", KCD2MP._npcReplicaStats.violationsOnReplica == 0 and logCount("body=replica") == 0)
    check("c: replica drew its weapon like any puppet", r ~= nil and r.drawnNow == true)
    check("c: promote counter", KCD2MP._npcReplicaStats.promote == 1)
    check("c: no Lua errors", #ERRS == 0, ERRS[1])

    -- (d) resolution: the owner's stream has the weapon away for sheathedDemoteS
    clearLog()
    local rx = r.px
    drive("c_npc", e, 0, 5, 0)   -- sheathed, 0.25 s: not yet
    check("d: not demoted before sheathedDemoteS", KCD2MP._npcReplicas["c_npc"] ~= nil and replicaOf("c_npc") ~= nil)
    drive("c_npc", e, 0, math.floor(KCD2MP.npcReplica.sheathedDemoteS / 0.05) + 2, 0)
    check("d: demoted why=sheathed", logCount("MP-NPCREPLICA npc=c_npc event=demote why=sheathed") == 1, lastLog("MP-NPCREPLICA"))
    check("d: replica removed", replicaOf("c_npc") == nil and KCD2MP._npcReplicas["c_npc"] == nil)
    check("d: world NPC unhidden", e.hidden == 0 and e.hides[#e.hides] == 0)
    check("d: world NPC returned where the replica stood (x=10 stream)", math.abs(e.px - 10) < 0.6, e.px)
    check("d: npcid re-pointed back at the world NPC", evtArg("npcid") == "c_npc " .. hexOf(e), evtArg("npcid"))
    check("d: npc_replica release event", evtArg("npc_replica") == "c_npc -", evtArg("npc_replica"))
    check("d: puppet still alive, now writing the world NPC again", KCD2MP.npcPuppets["c_npc"] ~= nil)
    local w0 = #e.writes
    drive("c_npc", e, 0, 3, 0)
    check("d: writes land on the world NPC after demote", #e.writes > w0)
    check("d: held_s recorded", string.find(lastLog("event=demote why=sheathed"), "held_s=1", 1, true) ~= nil, lastLog("event=demote"))
    check("d: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (e) death demotes at once, so the real corpse is the one on the ground
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local e = mkEntity("e_npc", 10, 0, 0); ENTS["e_npc"] = e
    NOW = 400
    drive("e_npc", e, 0.6, CONTEND, 4)
    check("e: promoted", replicaOf("e_npc") ~= nil)
    clearLog()
    driveTick("e_npc", e, 0, 4 + 1)   -- drawn + dead bit on the stream
    check("e: stream dead -> demote why=dead", logCount("MP-NPCREPLICA npc=e_npc event=demote why=dead") == 1, lastLog("MP-NPCREPLICA"))
    check("e: replica gone, NPC unhidden", replicaOf("e_npc") == nil and e.hidden == 0)
    check("e: no Lua errors", #ERRS == 0, ERRS[1])

    -- local copy dies (0x31 FATAL landed on the world NPC by name) while promoted
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local f = mkEntity("f_npc", 10, 0, 0); ENTS["f_npc"] = f
    NOW = 450
    drive("f_npc", f, 0.6, CONTEND, 4)
    check("e2: promoted", replicaOf("f_npc") ~= nil)
    f.dead = true   -- the WORLD NPC, not the replica: life state is read from the canonical copy
    clearLog()
    driveTick("f_npc", f, 0, 4)
    check("e2: local death read from the world NPC demotes why=dead", logCount("MP-NPCREPLICA npc=f_npc event=demote why=dead") == 1, lastLog("MP-NPCREPLICA"))
    check("e2: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (f) every other demote path
    -- silence release
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local e = mkEntity("g_npc", 10, 0, 0); ENTS["g_npc"] = e
    NOW = 500
    drive("g_npc", e, 0.6, CONTEND, 4)
    check("f: promoted", replicaOf("g_npc") ~= nil)
    clearLog()
    NOW = NOW + KCD2MP.npcSync.releaseS + 0.5
    KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")
    check("f: silence release demotes first (why=silence), then releases", logCount("MP-NPCREPLICA npc=g_npc event=demote why=silence") == 1
          and logCount("NPC-SYNC release g_npc (stream silent)") == 1 and KCD2MP.npcPuppets["g_npc"] == nil)
    check("f: NPC back, replica gone", e.hidden == 0 and replicaOf("g_npc") == nil)

    -- toggle off
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local h = mkEntity("h_npc", 10, 0, 0); ENTS["h_npc"] = h
    NOW = 550
    drive("h_npc", h, 0.6, CONTEND, 4)
    clearLog()
    KCD2MP_SetNpcReplica(false)
    check("f: mp_npc_replica_off demotes every replica", logCount("MP-NPCREPLICA npc=h_npc event=demote why=toggle-off") == 1
          and logCount("MP-NPCREPLICA toggle state=off was=on demoted=1") == 1 and h.hidden == 0 and replicaOf("h_npc") == nil)
    check("f: toggle event emitted", evtArg("npc_replica_toggle") == "off")
    drive("h_npc", h, 0.6, CONTEND, 4)
    check("f: with the toggle off the next contention promotes nothing", #SPAWNS == 1 and replicaOf("h_npc") == nil)

    -- host authority off
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local i = mkEntity("i_npc", 10, 0, 0); ENTS["i_npc"] = i
    NOW = 600
    drive("i_npc", i, 0.6, CONTEND, 4)
    clearLog()
    KCD2MP_Wo102Set("authority_host", false, "agent")
    check("f: host authority off demotes (why=host-authority-off)", logCount("MP-NPCREPLICA npc=i_npc event=demote why=host-authority-off") == 1 and i.hidden == 0)

    -- mod stop
    resetReplica(); KCD2MP.npcReplica.enabled = true
    local j = mkEntity("j_npc", 10, 0, 0); ENTS["j_npc"] = j
    NOW = 650
    drive("j_npc", j, 0.6, CONTEND, 4)
    clearLog()
    KCD2MP_Stop()
    check("f: KCD2MP_Stop demotes (why=mod-stop)", logCount("MP-NPCREPLICA npc=j_npc event=demote why=mod-stop") == 1 and j.hidden == 0)
    KCD2MP.running = true
    check("f: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (g) the categories this cannot serve: refused, once, nothing spawned
    resetReplica(); KCD2MP.npcReplica.enabled = true
    NOW = 700
    local function refusedCase(tag, name, e, expect)
        ENTS[name] = e
        drive(name, e, 0.6, CONTEND * 2, 4)   -- two violation windows: the refusal is logged once
        check(tag .. ": refused " .. expect, logCount("MP-NPCREPLICA npc=" .. name .. " event=refuse why=" .. expect) == 1, lastLog("MP-NPCREPLICA npc=" .. name))
        check(tag .. ": nothing left standing", replicaOf(name) == nil and e.hidden == 0)
    end
    refusedCase("g", "g_fem", mkEntity("g_fem", 10, 0, 0, "NPC_Female"), "class=NPC_Female")
    refusedCase("g", "g_horse", mkEntity("g_horse", 10, 0, 0, "Horse"), "class=Horse")
    local nosoul = mkEntity("g_nosoul", 10, 0, 0); nosoul.soul = nil
    refusedCase("g", "g_nosoul", nosoul, "soul-id-unreadable")
    local badid = mkEntity("g_badid", 10, 0, 0); badid.soulId = "12345"
    refusedCase("g", "g_badid", badid, "soul-id-unreadable")
    -- a locally-dead body never reaches the violation path (the corpse
    -- branch returns first), so the guard is exercised directly
    local dead = mkEntity("g_dead", 10, 0, 0); dead.dead = true; ENTS["g_dead"] = dead
    KCD2MP_NpcReplicaPromote("g_dead", { owner = 1 }, "direct")
    check("g: refused dead", logCount("MP-NPCREPLICA npc=g_dead event=refuse why=dead") == 1 and replicaOf("g_dead") == nil and dead.hidden == 0)
    local talk = mkEntity("g_talk", 10, 0, 0); talk.human.IsInDialog = function() return true end
    refusedCase("g", "g_talk", talk, "in-dialog")
    check("g: none of the refusals spawned anything", #SPAWNS == 0)
    -- a replica that comes back soulless (the WO-56 bare-spawn family) is removed at once
    SPAWN_SOULLESS = true
    local sl = mkEntity("g_soulless", 10, 0, 0); ENTS["g_soulless"] = sl
    drive("g_soulless", sl, 0.6, CONTEND, 4)
    check("g: soulless replica refused and removed", logCount("MP-NPCREPLICA npc=g_soulless event=refuse why=replica-soulless") == 1 and replicaOf("g_soulless") == nil and sl.hidden == 0)
    SPAWN_SOULLESS = false
    SPAWN_FAIL = true
    local sf = mkEntity("g_spawnfail", 10, 0, 0); ENTS["g_spawnfail"] = sf
    drive("g_spawnfail", sf, 0.6, CONTEND, 4)
    check("g: spawn failure refused, NPC never hidden", logCount("MP-NPCREPLICA npc=g_spawnfail event=refuse why=spawn-failed") == 1 and sf.hidden == 0)
    SPAWN_FAIL = false
    check("g: refused counter", KCD2MP._npcReplicaStats.refused == 8, KCD2MP._npcReplicaStats.refused)
    check("g: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (h) the 5 s sweep: orphans and vanished bodies
    resetReplica(); KCD2MP.npcReplica.enabled = true
    NOW = 800
    -- a savegame-restored replica: unregistered kcd2mp_r_ body near the player, its original hidden
    local orig = mkEntity("orph", 5, 0, 0); orig.hidden = 1; ENTS["orph"] = orig
    local ghostBody = mkEntity("kcd2mp_r_orph", 5, 0, 0); ENTS["kcd2mp_r_orph"] = ghostBody
    SPHERE = { orig, ghostBody }
    KCD2MP_NpcReplicaSweep()
    check("h: orphan replica removed and its original unhidden", ENTS["kcd2mp_r_orph"] == nil and orig.hidden == 0
          and logCount("MP-NPCREPLICA npc=orph event=orphan why=removed-and-unhid") == 1, lastLog("MP-NPCREPLICA"))
    SPHERE = {}   -- the engine's sphere query would not return a removed entity
    -- a registered replica whose body vanished (save reload)
    local e = mkEntity("k_npc", 10, 0, 0); ENTS["k_npc"] = e
    drive("k_npc", e, 0.6, CONTEND, 4)
    check("h: promoted", replicaOf("k_npc") ~= nil)
    ENTS["kcd2mp_r_k_npc"] = nil   -- gone
    clearLog()
    KCD2MP_NpcReplicaSweep()
    check("h: vanished replica -> demote why=replica-gone, NPC unhidden", logCount("MP-NPCREPLICA npc=k_npc event=demote why=replica-gone") == 1 and e.hidden == 0)
    -- the sweep runs from the NPC-sync tick on the reconcile interval, toggle or not
    KCD2MP.npcReplica.enabled = false
    local o2 = mkEntity("orph2", 5, 0, 0); o2.hidden = 1; ENTS["orph2"] = o2
    local b2 = mkEntity("kcd2mp_r_orph2", 5, 0, 0); ENTS["kcd2mp_r_orph2"] = b2
    SPHERE = { o2, b2 }
    KCD2MP._npcReconcileAt = 0; KCD2MP.npcSyncRunning = true
    KCD2MP_NpcSyncTick()
    KCD2MP.npcSyncRunning = false
    check("h: NpcSyncTick runs the sweep with the toggle OFF", ENTS["kcd2mp_r_orph2"] == nil and o2.hidden == 0)
    check("h: orphan counter", KCD2MP._npcReplicaStats.orphan == 2)
    check("h: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (i) console surface and the summary line
    for _, n in ipairs({ "mp_npc_replica_on", "mp_npc_replica_off", "mp_npc_replica_status" }) do
        local c = CCMDS[n]
        check("i: " .. n .. " registered argless", c ~= nil and not string.find(c.body, "%LINE", 1, true))
    end
    resetReplica(); KCD2MP.npcReplica.enabled = true
    KCD2MP_NpcReplicaStatus()
    check("i: status line", logCount("MP-NPCREPLICA status enabled=on active=0 promotes=0 demotes=0 refused=0 orphans=0 violations_on_replica=0") == 1, lastLog("MP-NPCREPLICA status"))
    clearLog()
    KCD2MP_LogSummary("test")
    local sum = lastLog("MP-SUMMARY-MOD")
    check("i: MP-SUMMARY-MOD carries the replica counters", sum ~= nil and string.find(sum, "replica_promotes=0 replica_demotes=0 replica_refused=0 replica_active=0 replica_orphans=0 replica_violations=0", 1, true) ~= nil, sum)
    check("i: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
