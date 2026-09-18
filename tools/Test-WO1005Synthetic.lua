-- WO-100.5 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- Phase 2 -- the continuous body-state channel:
--   (a) a packet carrying body state resolves ordinals to NAMES on istate.body
--   (b) an ordinal this build has no name for is a SPECIFIC rejection:
--       counted, logged once per distinct value, and istate.body left nil
--   (c) a six-argument call (a pre-0.23.1 agent) leaves istate.body nil --
--       absence is the signal, there is no probe and no negotiation
--   (d) the locomotion tag comes from the peer's pace, not from our inferred
--       speed: a body that says "walk" while the packets say "sprint" walks
--   (e) mp_anim_legacy_on puts the inference back
--   (f) a posture the chooser declines (horse) falls back rather than idling
--   (g) MP-GHOSTCORR carries correction magnitude and the snap count
--
-- Phase 0 -- the ghost class/NoAI toggles:
--   (h) KCD2MP_GhostClassName swaps only "NPC", and only when asked
--   (i) the NoAI toggle reaches the spawn table
--
-- What this proves: the wire vocabulary, the rejection path, the chooser's
-- preference order and the counters behave as docs/WO-100.5-findings.md says.
-- What it does NOT prove: that a ghost driven this way looks better. That is
-- the two-machine A/B the toggle exists for, and no live session has run it.
--
-- Part 1: engine stubs + a fake clock.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; ALLCMDS = {}; DRAWS = {}; SPAWNS = {}

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

-- Records the spawn table so (i) can read NoAI back out of it.
XGenAIModule = mkstub()
XGenAIModule.SpawnEntity = function(t)
    SPAWNS[#SPAWNS + 1] = t
    local e = { class = (t.ClassName == "NPC_NAI") and "NPC" or t.ClassName, id = 9000 + #SPAWNS }
    e.GetName = function(self) return t.Name end
    e.GetWorldPos = function(self) return { x = 0, y = 0, z = 0 } end
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

-- @@KDCMP@@

-- WO-102: these scenarios pin the 0.23.2 CLAIM model, which now ships as `mp_authority_host_off`
-- (host authority is the shipped default since WO-102; Test-WO102Synthetic.lua covers that side).
KCD2MP.wo102.authorityHost = false

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
end
local function logHas(pat)
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function logCount(pat)
    local n = 0
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

-- A ghost with a body, pre-seeded so UpdateGhost never has to spawn one.
local function mkGhostEntity(name)
    local e = { class = "NPC", id = 4660, px = 0, py = 0, pz = 0, rz = 0, anims = {} }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.SetWorldPos = function(self, p) self.px, self.py, self.pz = p.x, p.y, p.z end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = anim end
    e.GetCharacterFileName = function(self) return "male.cdf" end
    e.actor = { IsDead = function() return false end, IsUnconscious = function() return false end,
                GetHealth = function() return 100 end }
    e.human = mkstub()
    return e
end

local function seedGhost(id)
    local name = "kcd2mp_" .. id
    local e = mkGhostEntity(name)
    ENTS[name] = e
    KCD2MP.ghosts[id] = {
        entity = e, entityId = e.id, spawnName = name,
        facePick = { className = "NPC", soulName = "ttkc_man_26", guid = "g" },
        istate = {
            tx = 0, ty = 0, tz = 0, tr = 0, cx = 0, cy = 0, cz = 0, cr = 0,
            vx = 0, vy = 0, vz = 0, lastPacketX = 0, lastPacketY = 0, lastPacketZ = 0,
            ticksSincePacket = 0, packetCount = 0, animTag = "idle", smoothedSpeed = 0,
            prevCx = 0, prevCy = 0, speedDropTicks = 0, spawnedAtClock = 0,
        },
    }
    return KCD2MP.ghosts[id]
end

local function resetAll()
    KCD2MP.ghosts = {}
    LOG = {}; ERRS = {}; SPAWNS = {}
    KCD2MP._animUnknown = {}
    KCD2MP._animStats = { applied = 0, legacy = 0, noBody = 0, rejected = 0 }
    KCD2MP.animLegacy = false
    KCD2MP.ghostNai = false
    KCD2MP.ghostNoAi = false
end

-- ---------------------------------------------------------------------------
-- (a) ordinals resolve to names
-- ---------------------------------------------------------------------------
resetAll()
local g = seedGhost("7")
KCD2MP_UpdateGhost("7", 1, 0, 0, 0, false, 2, 1, 0, 375)
local b = g.istate.body
check("(a) body state resolves", b ~= nil)
check("(a) pace name", b and b.pace == "run", b and b.pace)
check("(a) dir name", b and b.dir == "forward", b and b.dir)
check("(a) stance name", b and b.stance == "upright", b and b.stance)
check("(a) anim speed is centimetres -> metres", b and math.abs(b.speed - 3.75) < 1e-6, b and b.speed)

-- ---------------------------------------------------------------------------
-- (b) an unknown ordinal is a specific, once-logged rejection
-- ---------------------------------------------------------------------------
resetAll()
g = seedGhost("7")
KCD2MP_UpdateGhost("7", 1, 0, 0, 0, false, 9, 0, 0, 0)
check("(b) unknown pace leaves body nil", g.istate.body == nil)
check("(b) counted as rejected", KCD2MP._animStats.rejected == 1, KCD2MP._animStats.rejected)
check("(b) logged with the specific reason", logHas("MP-ANIM reject=unknown-ordinal") ~= nil)
local before = logCount("MP-ANIM reject=unknown-ordinal")
KCD2MP_UpdateGhost("7", 2, 0, 0, 0, false, 9, 0, 0, 0)
KCD2MP_UpdateGhost("7", 3, 0, 0, 0, false, 9, 0, 0, 0)
check("(b) and only once per distinct value", logCount("MP-ANIM reject=unknown-ordinal") == before,
      logCount("MP-ANIM reject=unknown-ordinal"))
check("(b) but still counted every time", KCD2MP._animStats.rejected == 3, KCD2MP._animStats.rejected)

-- ---------------------------------------------------------------------------
-- (c) a six-argument call -- an older agent -- leaves body nil
-- ---------------------------------------------------------------------------
resetAll()
g = seedGhost("7")
KCD2MP_UpdateGhost("7", 1, 0, 0, 0, false)
check("(c) no body state from a pre-0.23.1 agent", g.istate.body == nil)
check("(c) and nothing is rejected -- absence is not an error", KCD2MP._animStats.rejected == 0)

-- ---------------------------------------------------------------------------
-- (d)/(e)/(f) the chooser's preference order, through the real ghost path.
--
-- The tag chooser is a local function, so it is exercised the way the game
-- does: set a body, run the ghost animation, read back which clip was asked
-- for. istate.smoothedSpeed is set to a SPRINT speed throughout, so a tag of
-- "walk" can only have come from the peer's tags and not from our inference.
-- ---------------------------------------------------------------------------
local function tagFor(pace, stance, legacy)
    resetAll()
    KCD2MP.animLegacy = legacy and true or false
    local gg = seedGhost("7")
    KCD2MP_UpdateGhost("7", 0, 0, 0, 0, false, pace, 1, stance, 0)
    gg.istate.smoothedSpeed = 7.0     -- sprint speed, by inference
    gg.istate.animTag = "idle"
    KCD2MP_UpdateAnimation("7", gg, false)
    return gg.istate.animTag, KCD2MP._animStats
end

if type(KCD2MP_UpdateAnimation) == "function" then
    local t = tagFor(1, 0, false)
    check("(d) peer says walk while packets say sprint -> walk", t == "walk", t)
    t = tagFor(2, 0, false); check("(d) run", t == "run", t)
    t = tagFor(3, 0, false); check("(d) sprint", t == "sprint", t)
    t = tagFor(0, 0, false); check("(d) none -> idle", t == "idle", t)
    t = tagFor(5, 0, false); check("(d) steps -> walk", t == "walk", t)
    t = tagFor(4, 0, false); check("(d) dash -> sprint", t == "sprint", t)
    t = tagFor(1, 1, false); check("(d) stealth + moving -> sneak_walk", t == "sneak_walk", t)
    t = tagFor(0, 1, false); check("(d) stealth + still -> sneak_idle", t == "sneak_idle", t)

    t = tagFor(1, 0, true)
    check("(e) mp_anim_legacy on: the inference wins again", t == "sprint", t)

    local t2, st = tagFor(1, 4, false)   -- stance = horse
    check("(f) a declined posture falls back rather than idling", t2 == "sprint", t2)
    check("(f) and is counted as declined", st.noBody >= 1, st.noBody)
else
    check("(d-f) KCD2MP_UpdateAnimation is reachable", false, "function not found -- name changed?")
end

-- ---------------------------------------------------------------------------
-- (g) MP-GHOSTCORR carries correction magnitude and the snap count
-- ---------------------------------------------------------------------------
resetAll()
g = seedGhost("7")
if type(KCD2MP_InterpTick) == "function" then
    -- The tick refuses to run unless the chain is marked live (WO-78's
    -- restart gate). Same flag KCD2MP_StartInterp sets.
    KCD2MP.interpRunning = true
    KCD2MP._chainLeakSeen = {}
    -- A target 20 m away is past the 5 m teleport threshold: one snap.
    g.istate.tx, g.istate.ty, g.istate.tz = 20, 0, 0
    g.istate.renderAt = NOW
    NOW = NOW + 0.020
    KCD2MP_InterpTick("ext")
    check("(g) a >5 m gap snaps", (g.istate.corrSnaps or 0) >= 1, g.istate.corrSnaps)

    -- Then drive eleven seconds of small corrections so the 10 s window closes.
    for i = 1, 600 do
        NOW = NOW + 0.020
        g.istate.tx = g.istate.cx + 0.25
        KCD2MP_InterpTick("ext")
    end
    local line = logHas("MP-GHOSTCORR")
    check("(g) MP-GHOSTCORR is emitted", line ~= nil)
    if line then
        check("(g) it carries a mean", line:find("corr_mean_m=", 1, true) ~= nil, line)
        check("(g) it carries a max", line:find("corr_max_m=", 1, true) ~= nil)
        check("(g) it carries the snap count", line:find("snaps=", 1, true) ~= nil)
    end
else
    check("(g) KCD2MP_InterpTick is reachable", false, "function not found")
end

-- ---------------------------------------------------------------------------
-- (h) the class helper
-- ---------------------------------------------------------------------------
resetAll()
check("(h) off: NPC stays NPC", KCD2MP_GhostClassName("NPC") == "NPC")
KCD2MP.ghostNai = true
check("(h) on: NPC becomes NPC_NAI", KCD2MP_GhostClassName("NPC") == "NPC_NAI")
check("(h) on: NPC_Female is NOT swapped -- there is no NPC_NAI_Female",
      KCD2MP_GhostClassName("NPC_Female") == "NPC_Female")
KCD2MP.ghostNai = false

-- ---------------------------------------------------------------------------
-- (i) the NoAI toggle reaches the spawn table
-- ---------------------------------------------------------------------------
resetAll()
SPAWNS = {}
KCD2MP_SpawnGhost("42", 1, 2, 3, 0)
local sawNoAi = false
for _, t in ipairs(SPAWNS) do if t.NoAI ~= nil then sawNoAi = true end end
check("(i) off: NoAI is absent from the spawn table entirely", not sawNoAi)

resetAll()
SPAWNS = {}
KCD2MP.ghostNoAi = true
KCD2MP_SpawnGhost("43", 1, 2, 3, 0)
sawNoAi = false
for _, t in ipairs(SPAWNS) do if t.NoAI == true then sawNoAi = true end end
check("(i) on: NoAI=true is passed", sawNoAi)

-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do
    print(r)
    if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end
end
print(string.format("RESULT: %d passed, %d failed", pass, fail))
OUT = string.format("%d passed, %d failed", pass, fail)
