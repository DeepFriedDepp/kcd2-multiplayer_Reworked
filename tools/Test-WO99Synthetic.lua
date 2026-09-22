-- WO-99 synthetic test: Phase 2's sub-8 m puppet yield arbitration and the
-- Phase 0 Lua exclusion, against the real kdcmp.lua under MoonSharp.
--
--   (a) a puppet whose body the local brain displaces 0.4 m every tick
--       yields after `ticks` consecutive readbacks: one MP-NPCYIELD
--       state=yield line, and no further SetWorldPos writes while yielded
--   (b) a stream target that moves less than repinM does NOT re-pin
--   (c) a stream target that moves more than repinM re-pins: one
--       MP-NPCYIELD state=repin line, writes resume, the ring is re-seeded
--       from where the body actually is (no snap back to the old target)
--   (d) contention under dispM (7 cm, the 2026-09-16 cabin scene) never
--       yields -- the streak resets on every quiet tick
--   (e) mp_npc_yield off: the same 0.4 m contention never yields, and an
--       already-yielded puppet resumes writing on the next tick
--   (f) MP-SUMMARY-MOD carries npc_yields / npc_repins
--   (g) Phase 0: the local player's entity name is refused as an inbound
--       NPC stream, and a real NPC name is not
--
-- Driven by Test-WO99Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: the yield/re-pin state machine and its log lines behave
-- as docs/WO-99-findings.md Phase 2 says, under a brain that displaces the
-- body deterministically. What it does NOT prove: that a real brain's
-- displacement pattern crosses these thresholds in the field, or that the
-- yielded NPC looks better -- that is the live A/B the toggle exists for.
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; ALLCMDS = {}; DRAWS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return SPHERE end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s); ALLCMDS[#ALLCMDS + 1] = tostring(s) end
System.DrawText = function(x, y, text, size) DRAWS[#DRAWS + 1] = { x = x, y = y, text = tostring(text) } end
System.RemoveEntity = function(eid) for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }

-- Phase 0 (g): the local player entity, named as the engine names it.
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

-- @@KDCMP@@

-- WO-102: these scenarios pin the 0.23.2 CLAIM model, which now ships as `mp_authority_host_off`
-- (host authority is the shipped default since WO-102; Test-WO102Synthetic.lua covers that side).
KCD2MP.wo102.authorityHost = false

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. detail .. "]") or "")
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function fmt(v) return string.format("%.3f", v) end

local function mkEntity(name, x, y, z)
    local e = { class = "NPC", id = 4660, px = x, py = y, pz = z, rz = 0, writes = {}, anims = {} }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.SetWorldPos = function(self, p)
        self.px, self.py, self.pz = p.x, p.y, p.z
        self.writes[#self.writes + 1] = { x = p.x, y = p.y, z = p.z, at = NOW }
    end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = { anim = anim, at = NOW } end
    e.actor = {
        IsDead = function() return false end,
        IsUnconscious = function() return false end,
        GetHealth = function() return 100 end,
    }
    return e
end

local function reset(name, x, y, z)
    KCD2MP.npcPuppets = {}
    KCD2MP.npcPuppetRunning = true
    KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetPumpAt = nil
    KCD2MP._chainLeakSeen = {}
    KCD2MP._npcDivergeUntil = {}
    KCD2MP.npcYield = { enabled = true, dispM = 0.30, ticks = 10, repinM = 1.0 }
    ENTS = {}
    local e = mkEntity(name, x, y, z)
    ENTS[name] = e
    ERRS = {}
    return e
end
-- The stream target per name: `contend` re-sends it as the emitter's idle
-- heartbeat would (every 1 s), so a long scenario is not cut short by the
-- release-on-silence rule (KCD2MP.npcSync.releaseS).
local TARGET = {}
local function pkt(name, x, y, z, rot)
    TARGET[name] = { x = x, y = y, z = z, rot = rot or 0 }
    KCD2MP_ApplyNpcState(name, x, y, z, rot or 0, 100, 0)
end
local TICKN = 0
local function tick() NOW = NOW + 0.050; TICKN = TICKN + 1; KCD2MP_NpcPuppetTick("ext") end
local function countLog(pat, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(pat, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(pat)
    for i = #LOG, 1, -1 do if LOG[i]:find(pat, 1, true) then return LOG[i] end end
    return nil
end
local function noErrs(label)
    check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1])
end

-- A brain that pushes the body `d` metres +x after every one of our writes,
-- so the next tick's readback sees exactly `d` of displacement.
local function contend(e, d, n)
    local name = e:GetName()
    for i = 1, n do
        e.px = e.px + d
        tick()
        local t = TARGET[name]
        if t and TICKN % 20 == 0 then KCD2MP_ApplyNpcState(name, t.x, t.y, t.z, t.rot, 100, 0) end
    end
end

-- ------------------------------------------------------------------ (a)
do
    local e = reset("npc_y", 0, 0, 0)
    NOW = 100
    pkt("npc_y", 0, 0, 0)
    pkt("npc_y", 0, 0, 0)           -- second packet: a target exists, ring has data
    tick(); tick()                  -- prime lastWrote
    local log0 = #LOG
    local w0 = #e.writes
    contend(e, 0.40, 9)             -- nine displaced readbacks: streak 9, no yield yet
    local p = KCD2MP.npcPuppets["npc_y"]
    check("(a) nine 0.4 m readbacks do not yield yet (ticks=10)", p and not p.yielded and (p.yieldStreak or 0) == 9,
        "streak=" .. tostring(p and p.yieldStreak))
    contend(e, 0.40, 1)             -- tenth
    check("(a) the tenth consecutive readback yields", p.yielded == true, tostring(p.yielded))
    check("(a) exactly one MP-NPCYIELD state=yield line", countLog("MP-NPCYIELD npc=npc_y state=yield", log0) == 1,
        tostring(countLog("MP-NPCYIELD npc=npc_y state=yield", log0)))
    local yl = lastLog("MP-NPCYIELD npc=npc_y state=yield")
    check("(a) the yield line carries disp_m~0.40 streak=10", yl and yl:find("disp_m=0.40", 1, true) and yl:find("streak=10", 1, true), yl)
    local w1 = #e.writes
    contend(e, 0.40, 20)            -- brain keeps walking the body
    check("(a) no SetWorldPos writes while yielded", #e.writes == w1, "writes " .. tostring(#e.writes - w1))
    check("(a) yielded puppet is still a puppet (not released)", KCD2MP.npcPuppets["npc_y"] ~= nil)
    check("(a) tug-of-war counter stops for a yielded puppet", (p.fightN or 0) <= 10, "fightN=" .. tostring(p.fightN))
    noErrs("(a)")
end

-- ------------------------------------------------------------------ (b)/(c)
do
    local e = reset("npc_r", 0, 0, 0)
    NOW = 200
    pkt("npc_r", 0, 0, 0); pkt("npc_r", 0, 0, 0); tick(); tick()
    contend(e, 0.40, 10)
    local p = KCD2MP.npcPuppets["npc_r"]
    check("(b) precondition: yielded", p.yielded == true)
    local log0 = #LOG
    pkt("npc_r", 0.5, 0, 0)        -- stream moved 0.5 m < repinM 1.0
    tick()
    check("(b) a 0.5 m target move does not re-pin", p.yielded == true and countLog("state=repin", log0) == 0)
    -- body has drifted to x = 0.4*10 + whatever; the brain keeps it there
    local bodyX = e.px
    local w0 = #e.writes
    pkt("npc_r", 1.5, 0, 0)        -- stream moved 1.5 m from the yield anchor (0,0)
    check("(c) a 1.5 m target move re-pins", p.yielded == nil, tostring(p.yielded))
    check("(c) exactly one MP-NPCYIELD state=repin line", countLog("MP-NPCYIELD npc=npc_r state=repin", log0) == 1)
    local rl = lastLog("MP-NPCYIELD npc=npc_r state=repin")
    check("(c) the repin line carries target_moved_m=1.50", rl and rl:find("target_moved_m=1.50", 1, true), rl)
    check("(c) render position re-seeded from the BODY, not the old target", near(p.cx, bodyX, 1e-6), fmt(p.cx) .. " vs body " .. fmt(bodyX))
    tick()
    check("(c) writes resume after the re-pin", #e.writes > w0, "writes " .. tostring(#e.writes - w0))
    local first = e.writes[w0 + 1]
    check("(c) the first resumed write is near the body (a slide, not a snap to x=0)", first and first.x > bodyX - 0.5, first and fmt(first.x))
    noErrs("(b)(c)")
end

-- ------------------------------------------------------------------ (d)
do
    local e = reset("npc_c", 0, 0, 0)
    NOW = 300
    pkt("npc_c", 0, 0, 0); pkt("npc_c", 0, 0, 0); tick(); tick()
    local log0 = #LOG
    contend(e, 0.07, 200)          -- the cabin scene: 7 cm per tick, forever
    local p = KCD2MP.npcPuppets["npc_c"]
    check("(d) 7 cm contention never yields (under dispM 0.30)", p and not p.yielded, tostring(p and p.yielded))
    check("(d) ...and is still counted by the tug-of-war counter", (p.fightN or 0) >= 190, "fightN=" .. tostring(p.fightN))
    check("(d) no MP-NPCYIELD line", countLog("MP-NPCYIELD", log0) == 0)
    -- a streak that breaks resets: 9 far, 1 quiet, 9 far -> no yield
    local e2 = reset("npc_s", 0, 0, 0)
    pkt("npc_s", 0, 0, 0); pkt("npc_s", 0, 0, 0); tick(); tick()
    contend(e2, 0.40, 9); tick(); contend(e2, 0.40, 9)
    local p2 = KCD2MP.npcPuppets["npc_s"]
    check("(d) a quiet tick resets the streak (9+quiet+9 = no yield)", p2 and not p2.yielded and (p2.yieldStreak or 0) == 9,
        "streak=" .. tostring(p2 and p2.yieldStreak))
    noErrs("(d)")
end

-- ------------------------------------------------------------------ (e)
do
    local e = reset("npc_o", 0, 0, 0)
    NOW = 400
    KCD2MP_SetNpcYield("off")
    pkt("npc_o", 0, 0, 0); pkt("npc_o", 0, 0, 0); tick(); tick()
    local log0 = #LOG
    contend(e, 0.40, 30)
    local p = KCD2MP.npcPuppets["npc_o"]
    check("(e) mp_npc_yield off: 0.4 m contention never yields", p and not p.yielded)
    check("(e) off: no MP-NPCYIELD line", countLog("MP-NPCYIELD", log0) == 0)
    KCD2MP_SetNpcYield("on")
    contend(e, 0.40, 10)
    check("(e) on again: yields after ticks", p.yielded == true)
    local w0 = #e.writes
    KCD2MP_SetNpcYield("off")
    check("(e) turning it off clears the yielded state", p.yielded == nil)
    tick()
    check("(e) ...and the puppet writes again on the next tick", #e.writes == w0 + 1, tostring(#e.writes - w0))
    check("(e) thresholds parse: '0.5 4 2.0'", KCD2MP_SetNpcYield("0.5 4 2.0") == true
        and KCD2MP.npcYield.dispM == 0.5 and KCD2MP.npcYield.ticks == 4 and KCD2MP.npcYield.repinM == 2.0)
    check("(e) a bad argument is refused", KCD2MP_SetNpcYield("banana") == false)
    check("(e) the console's literal %LINE reports instead of erroring", KCD2MP_SetNpcYield("%LINE") == true)
    noErrs("(e)")
end

-- ------------------------------------------------------------------ (f)
do
    local log0 = #LOG
    KCD2MP_LogSummary("test")
    local sl = lastLog("MP-SUMMARY-MOD")
    check("(f) MP-SUMMARY-MOD carries npc_yields", sl and sl:find("npc_yields=", 1, true) ~= nil, sl)
    check("(f) ...and npc_repins", sl and sl:find("npc_repins=", 1, true) ~= nil)
    local y = sl and tonumber(sl:match("npc_yields=(%d+)"))
    check("(f) yields counted across scenarios (>=3)", y and y >= 3, tostring(y))
end

-- ------------------------------------------------------------------ (g)
do
    reset("ttkc_drozd", 5, 5, 0)
    ENTS["Dude"] = mkEntity("Dude", 0, 0, 0)
    NOW = 500
    local log0 = #LOG
    pkt("Dude", 1, 1, 0)
    check("(g) an inbound stream for the local player's own name is refused", KCD2MP.npcPuppets["Dude"] == nil)
    check("(g) ...and logged once", countLog("refusing inbound stream for excluded name 'Dude'", log0) == 1)
    pkt("Dude", 2, 2, 0)
    check("(g) the refusal line is not repeated", countLog("refusing inbound stream for excluded name 'Dude'", log0) == 1)
    pkt("ttkc_drozd", 5, 5, 0)
    check("(g) a real NPC name is accepted", KCD2MP.npcPuppets["ttkc_drozd"] ~= nil)
    noErrs("(g)")
end

-- ---------------------------------------------------------------- report
-- WO-110: the shared driver (Test-NpcSmoothSynthetic.ps1) reads the global OUT;
-- this scenario only printed, so it exited 2 with every check passing and was
-- never green as a gate. Caught by the WO-110 fresh-clone build (R10).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
