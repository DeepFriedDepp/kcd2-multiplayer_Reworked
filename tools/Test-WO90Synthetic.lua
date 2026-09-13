-- WO-90 synthetic test for the never-synced entity-name exclusion:
--   * mp_npc_rescan (via KCD2MP_NpcSyncTick) never tracks an engine
--     conversation stand-in ("DialogTwin_*") or one of this mod's own ghost
--     bodies ("kcd2mp_*"), and still tracks ordinary world NPCs
--   * the emitter therefore never puts either family on the wire, in EITHER
--     role -- "npc_state" as damage authority or "npc_claim" as a
--     proximity claimant
--   * mp_drag_sensor ignores both families
--   * KCD2MP_ApplyNpcState refuses an inbound stream for either family
--     whatever the sender believes, creates no puppet, and logs once per name
--   * an ordinary name is unaffected on every one of those paths
--
-- Why this exists (docs/WO-90-findings.md finding 3): the engine spawns one
-- "DialogTwin_<soul>" per participant for every staged conversation,
-- INCLUDING "DialogTwin_Dude" for the local player, and attaches the
-- conversation camera to it. Both machines name them identically, so before
-- this change each player's conversation camera rig was being driven at
-- 20 Hz by the OTHER player's copy of the same-named twin -- observed in the
-- 2026-09-12 field logs on both machines, at apparent speeds of 7.6 to
-- 28.1 m/s, with eight relay claims granted on DialogTwin_* names.
--
-- Driven by Test-WO90Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: that the exclusion holds on all four code paths (rescan,
-- emit, drag sensor, inbound apply) and that ordinary NPCs are untouched.
-- What it does NOT prove: that removing the twins from sync actually fixes
-- what the two humans saw on screen. That needs a live two-player session --
-- see docs/WO-90-findings.md.
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0                                  -- the fake wall clock, seconds
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return SPHERE end
System.RemoveEntity = function(eid)
    for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end
end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- The local player, standing at the origin. mp_npc_rescan and mp_drag_sensor
-- both bail out early without one.
player = {
    GetWorldPos   = function() return { x = 0, y = 0, z = 0 } end,
    GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
    actor = { GetHealth = function() return 100 end,
              IsDead = function() return false end,
              IsUnconscious = function() return false end },
    human = { IsWeaponDrawn = function() return false end },
}

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. detail .. "]") or "")
end
local function countLog(needle, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(needle, fromLog)
    for i = #LOG, (fromLog or 0) + 1, -1 do if LOG[i]:find(needle, 1, true) then return LOG[i] end end
    return nil
end
local function noErrs(label)
    check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1])
end
-- Event lines are "[KCD2-MP-EVT] v1 <seq> <name> <arg>"; count by "<name> <argPrefix>".
local function countEvt(name, argPrefix, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do
        local l = LOG[i]
        if l:find("[KCD2-MP-EVT] v1 ", 1, true) and l:find(" " .. name .. " " .. (argPrefix or ""), 1, true) then n = n + 1 end
    end
    return n
end

local NEXTID = 9000
local function mkEntity(name, x, y, z, cls)
    NEXTID = NEXTID + 1
    -- Properties/AI/inventory are present because the real spawn path writes
    -- through them (entity.Properties.esFaction, entity.AI, …); a bare table
    -- would make the spawn scenario fail on the harness rather than the code.
    local e = { class = cls or "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0,
                rz = 0, writes = {}, anims = {}, dead = false, ko = false, hp = 100,
                Properties = {}, AI = {}, inventory = mkstub() }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, p)
        self.px, self.py, self.pz = p.x, p.y, p.z
        self.writes[#self.writes + 1] = { x = p.x, y = p.y, z = p.z, at = NOW }
    end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = { anim = anim, at = NOW } end
    e.actor = setmetatable({
        IsDead        = function() return e.dead end,
        IsUnconscious = function() return e.ko end,
        GetHealth     = function() return e.hp end,
    }, { __index = function(_, k) return function(...) return nil end end })
    e.human = {
        IsWeaponDrawn  = function() return false end,
        DrawWeapon     = function() return true end,
        HolsterWeapon  = function() return true end,
    }
    ENTS[name] = e
    return e
end

local function resetNpcSync()
    ENTS = {}; SPHERE = {}
    KCD2MP.npcPuppets = {}
    KCD2MP.npcPuppetRunning = false
    KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetRetired = {}
    KCD2MP._npcPuppetRetiredN = 0
    KCD2MP._chainLeakSeen = {}
    KCD2MP._chainLeakN = {}
    KCD2MP._chainProbe = {}
    KCD2MP.npcTracked = {}
    KCD2MP.dragging = {}
    KCD2MP.dragWatch = {}
    KCD2MP._dragScanAt = 0
    KCD2MP.ghosts = {}
    KCD2MP.horseGhosts = {}
    KCD2MP.npcDeathSync = true
    KCD2MP._npcDeathSeen = {}
    KCD2MP._npcDeathAnnounced = {}
    KCD2MP._npcDeathRemote = {}
    KCD2MP._npcDeathDiverged = {}
    KCD2MP._npcDeathSuppressedN = 0
    KCD2MP._npcNameRefused = {}
    KCD2MP.npcSync.enabled = true
    KCD2MP.npcProx.enabled = true
    KCD2MP.npcSyncRunning = true
    ERRS = {}; TOASTS = {}
end

-- Force the rescan on the next emit tick (its gate is scanMs since the last).
local function forceRescan() KCD2MP._npcScanAt = -1e9 end

local function tick()
    NOW = NOW + 0.05
    KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
end

-- ---------------------------------------------------------------------------
-- (a) The rescan. A conversation stand-in, one of our own ghost bodies and an
--     ordinary NPC all stand next to the player. Only the ordinary one may be
--     tracked -- and as damage authority, only it may reach the wire.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.hitSensorOn = true                     -- damage authority: emits "npc_state"
    local logMark = #LOG
    local twinNpc  = mkEntity("DialogTwin_tkop_ptacek", 1, 0, 0)
    local twinSelf = mkEntity("DialogTwin_Dude",        2, 0, 0)
    local ghost    = mkEntity("kcd2mp_0",               3, 0, 0)
    local world    = mkEntity("tkop_ptacek",            4, 0, 0)
    SPHERE = { twinNpc, twinSelf, ghost, world }

    forceRescan()
    KCD2MP_NpcSyncTick()

    check("(a) the ordinary world NPC is tracked", KCD2MP.npcTracked["tkop_ptacek"] ~= nil)
    check("(a) the NPC's conversation stand-in is NOT tracked", KCD2MP.npcTracked["DialogTwin_tkop_ptacek"] == nil)
    check("(a) the PLAYER's own conversation stand-in is NOT tracked", KCD2MP.npcTracked["DialogTwin_Dude"] == nil)
    check("(a) our own ghost body is NOT tracked", KCD2MP.npcTracked["kcd2mp_0"] == nil)
    check("(a) exactly one name is tracked",
        (function() local n = 0; for _ in pairs(KCD2MP.npcTracked) do n = n + 1 end; return n end)() == 1)
    check("(a) no 'NPC-SYNC tracking' line for any excluded name",
        countLog("NPC-SYNC tracking DialogTwin_", logMark) == 0
        and countLog("NPC-SYNC tracking kcd2mp_", logMark) == 0)

    check("(a) the ordinary NPC reached the wire as npc_state", countEvt("npc_state", "tkop_ptacek", logMark) == 1,
        tostring(countEvt("npc_state", "tkop_ptacek", logMark)))
    check("(a) no stand-in reached the wire", countEvt("npc_state", "DialogTwin_", logMark) == 0,
        tostring(countEvt("npc_state", "DialogTwin_", logMark)))
    check("(a) no ghost body reached the wire", countEvt("npc_state", "kcd2mp_", logMark) == 0)
    noErrs("(a)")
end

-- ---------------------------------------------------------------------------
-- (b) The same, in the OTHER role: a non-authority emits "npc_claim" for
--     NPCs near its own player (WO-60 proximity claiming). The exclusion must
--     hold there too -- that is the role that actually claimed the twins in
--     the field (relay: eight DialogTwin_* grants, all owner=2, the joiner).
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.hitSensorOn = false                    -- non-authority: emits "npc_claim"
    KCD2MP.ghosts = { ["0"] = { entity = mkEntity("kcd2mp_peer", 50, 0, 0) } }  -- a live ghost exists
    local logMark = #LOG
    local twin  = mkEntity("DialogTwin_Dude", 1, 0, 0)
    local world = mkEntity("prepadeni_voves", 2, 0, 0)
    SPHERE = { twin, world }

    forceRescan()
    KCD2MP_NpcSyncTick()

    check("(b) the ordinary NPC is claimed", countEvt("npc_claim", "prepadeni_voves", logMark) == 1,
        tostring(countEvt("npc_claim", "prepadeni_voves", logMark)))
    check("(b) the stand-in is never claimed", countEvt("npc_claim", "DialogTwin_", logMark) == 0)
    check("(b) the stand-in is not tracked", KCD2MP.npcTracked["DialogTwin_Dude"] == nil)
    noErrs("(b)")
end

-- ---------------------------------------------------------------------------
-- (c) The drag sensor (WO-39 Phase 2) watches downed bodies near the player
--     and claims them by emitting "npc_drag". A downed stand-in must not be
--     claimed either.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.hitSensorOn = false
    KCD2MP.ghosts = { ["0"] = { entity = mkEntity("kcd2mp_peer", 50, 0, 0) } }
    local logMark = #LOG
    local twin = mkEntity("DialogTwin_tkop_ptacek", 1, 0, 0); twin.dead = true; twin.hp = 0
    local body = mkEntity("prepadeni_bandit_1",     2, 0, 0); body.dead = true; body.hp = 0
    SPHERE = { twin, body }

    -- First pass seeds dragWatch, then both bodies "move" and a second pass
    -- sees the movement as local manipulation. Both passes force the sensor's
    -- own DRAG_SCAN_MS interval gate open -- the fake clock does not
    -- necessarily start far enough past zero to clear it on its own.
    KCD2MP._dragScanAt = -1e9
    forceRescan(); KCD2MP_NpcSyncTick()
    check("(c) the ordinary downed body entered the drag watch list", KCD2MP.dragWatch["prepadeni_bandit_1"] ~= nil)

    NOW = NOW + 1.0
    twin.px, twin.py = 1.9, 0
    body.px, body.py = 2.9, 0
    KCD2MP._dragScanAt = -1e9
    forceRescan(); KCD2MP_NpcSyncTick()

    check("(c) the ordinary downed body is drag-claimed", KCD2MP.dragging["prepadeni_bandit_1"] ~= nil)
    check("(c) ...and its claim reached the wire as npc_drag",
        countEvt("npc_drag", "prepadeni_bandit_1", logMark) >= 1,
        tostring(countEvt("npc_drag", "prepadeni_bandit_1", logMark)))
    check("(c) the downed stand-in is NOT drag-claimed", KCD2MP.dragging["DialogTwin_tkop_ptacek"] == nil)
    check("(c) no drag-claim log line for the stand-in",
        countLog("NPC-DRAG claiming DialogTwin_", logMark) == 0)
    check("(c) nothing for the stand-in reached the wire as npc_drag",
        countEvt("npc_drag", "DialogTwin_", logMark) == 0)
    check("(c) the stand-in never entered the drag watch list", KCD2MP.dragWatch["DialogTwin_tkop_ptacek"] == nil)
    noErrs("(c)")
end

-- ---------------------------------------------------------------------------
-- (d) The inbound half. A peer on an older build (or with the exclusion
--     rolled back) still sends these names; we must refuse them whatever the
--     sender believes, create no puppet, write nothing, and say so once.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    local logMark = #LOG
    local twinSelf = mkEntity("DialogTwin_Dude",        0, 0, 0)
    local twinNpc  = mkEntity("DialogTwin_tkop_ptacek", 0, 0, 0)
    local ghost    = mkEntity("kcd2mp_0",               0, 0, 0)
    local world    = mkEntity("tkop_ptacek",            0, 0, 0)

    -- The field case: a stand-in yanked 10 m across the staging area.
    KCD2MP_ApplyNpcState("DialogTwin_Dude", 10, 0, 0, 0, 100, 0)
    KCD2MP_ApplyNpcState("DialogTwin_tkop_ptacek", 10, 0, 0, 0, 100, 0)
    KCD2MP_ApplyNpcState("kcd2mp_0", 10, 0, 0, 0, 100, 0)
    KCD2MP_ApplyNpcState("tkop_ptacek", 1, 0, 0, 0, 100, 0)
    for _ = 1, 4 do tick() end

    check("(d) no puppet was created for the player's own stand-in", KCD2MP.npcPuppets["DialogTwin_Dude"] == nil)
    check("(d) no puppet was created for the NPC's stand-in", KCD2MP.npcPuppets["DialogTwin_tkop_ptacek"] == nil)
    check("(d) no puppet was created for our own ghost body", KCD2MP.npcPuppets["kcd2mp_0"] == nil)
    check("(d) the player's own stand-in was never written to", #twinSelf.writes == 0,
        tostring(#twinSelf.writes) .. " writes")
    check("(d) the NPC's stand-in was never written to", #twinNpc.writes == 0, tostring(#twinNpc.writes) .. " writes")
    check("(d) our own ghost body was never written to", #ghost.writes == 0, tostring(#ghost.writes) .. " writes")
    check("(d) the stand-in was never animated", #twinSelf.anims == 0 and #twinNpc.anims == 0)

    check("(d) REGRESSION: the ordinary NPC still becomes a puppet", KCD2MP.npcPuppets["tkop_ptacek"] ~= nil)
    check("(d) REGRESSION: the ordinary NPC is still written to", #world.writes > 0,
        tostring(#world.writes) .. " writes")

    check("(d) the refusal is logged once per name, not per packet",
        countLog("refusing inbound stream for excluded name 'DialogTwin_Dude'", logMark) == 1,
        tostring(countLog("refusing inbound stream for excluded name 'DialogTwin_Dude'", logMark)))
    KCD2MP_ApplyNpcState("DialogTwin_Dude", 20, 0, 0, 0, 100, 0)
    KCD2MP_ApplyNpcState("DialogTwin_Dude", 30, 0, 0, 0, 100, 0)
    check("(d) ...and stays at one after two more packets",
        countLog("refusing inbound stream for excluded name 'DialogTwin_Dude'", logMark) == 1,
        tostring(countLog("refusing inbound stream for excluded name 'DialogTwin_Dude'", logMark)))
    check("(d) each excluded name gets its own line",
        countLog("refusing inbound stream for excluded name 'DialogTwin_tkop_ptacek'", logMark) == 1
        and countLog("refusing inbound stream for excluded name 'kcd2mp_0'", logMark) == 1)
    check("(d) the ordinary name was never refused",
        countLog("refusing inbound stream for excluded name 'tkop_ptacek'", logMark) == 0)
    noErrs("(d)")
end

-- ---------------------------------------------------------------------------
-- (e) The name test itself, at its edges. The exclusion is a prefix match, so
--     a real NPC whose name merely CONTAINS an excluded token must survive.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.hitSensorOn = true
    local logMark = #LOG
    local a = mkEntity("prepadeni_DialogTwin_decoy", 1, 0, 0)  -- contains, does not start with
    local b = mkEntity("dialogtwin_lowercase",       2, 0, 0)  -- different case: NOT excluded in Lua
    local c = mkEntity("DialogTwin_",                3, 0, 0)  -- the bare prefix
    SPHERE = { a, b, c }
    forceRescan()
    KCD2MP_NpcSyncTick()

    check("(e) a name that merely contains 'DialogTwin_' is still tracked",
        KCD2MP.npcTracked["prepadeni_DialogTwin_decoy"] ~= nil)
    check("(e) the bare prefix is excluded", KCD2MP.npcTracked["DialogTwin_"] == nil)
    check("(e) the Lua test is case-SENSITIVE, matching the engine's own casing",
        KCD2MP.npcTracked["dialogtwin_lowercase"] ~= nil)
    noErrs("(e)")
end

-- ---------------------------------------------------------------------------
-- (f) The divergence release. The field case: the two players are at
--     different story beats, so the local engine keeps dragging the NPC back
--     to where THIS world needs it while the stream keeps putting it where
--     the other world needs it. Reproduces the host's 57.24 m readings.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.npcDiverge = true
    KCD2MP._npcDivergeUntil = {}
    KCD2MP._npcDivergeN = 0
    local logMark = #LOG
    local e = mkEntity("tkop_ptacek", 0, 0, 0)

    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
    tick()
    check("(f) the puppet exists and is being written", KCD2MP.npcPuppets["tkop_ptacek"] ~= nil and #e.writes > 0)

    -- Three ticks where the local world yanks the body 57.24 m away between
    -- our write and our next read -- the exact field displacement.
    local releasedAfter = nil
    for i = 1, 6 do
        e.px, e.py = 57.24, 0
        KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
        tick()
        if KCD2MP.npcPuppets["tkop_ptacek"] == nil and not releasedAfter then releasedAfter = i end
    end

    check("(f) the puppet was released", KCD2MP.npcPuppets["tkop_ptacek"] == nil)
    check("(f) ...on the third far reading, not the first", releasedAfter == 3, "released after " .. tostring(releasedAfter))
    check("(f) the release is logged with the distance and the count",
        (lastLog("NPC-DIVERGE tkop_ptacek", logMark) or ""):find("57.2m", 1, true) ~= nil
        and (lastLog("NPC-DIVERGE tkop_ptacek", logMark) or ""):find("3 times", 1, true) ~= nil,
        lastLog("NPC-DIVERGE tkop_ptacek", logMark))
    check("(f) exactly one release line", countLog("NPC-DIVERGE tkop_ptacek: local world moved it", logMark) == 1)
    check("(f) the release counter advanced", KCD2MP._npcDivergeN == 1, tostring(KCD2MP._npcDivergeN))

    -- The stand-off must survive the next inbound packets, or the release
    -- would be undone immediately by the stream that caused it.
    local writesAtRelease = #e.writes
    for _ = 1, 5 do
        KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
        tick()
    end
    check("(f) inbound packets during the stand-off do not rebuild the puppet",
        KCD2MP.npcPuppets["tkop_ptacek"] == nil)
    check("(f) the body is left alone -- no further writes", #e.writes == writesAtRelease,
        tostring(#e.writes - writesAtRelease) .. " writes after release")

    -- ...and must lapse.
    NOW = NOW + 61.0
    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
    check("(f) after the cooldown the stream is accepted again", KCD2MP.npcPuppets["tkop_ptacek"] ~= nil)
    check("(f) ...and says so once", countLog("stand-off over, accepting the stream again", logMark) == 1)
    noErrs("(f)")
end

-- ---------------------------------------------------------------------------
-- (g) Ordinary brain contention must NOT trigger a release. The counter this
--     builds on fires at 5 cm/tick, and real combat footwork displaces
--     0.05-0.6 m -- the field's ordinary range. Those must be tolerated
--     forever, exactly as before.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.npcDiverge = true
    KCD2MP._npcDivergeUntil = {}
    local logMark = #LOG
    local e = mkEntity("prepadeni_bandit_1", 0, 0, 0)
    KCD2MP_ApplyNpcState("prepadeni_bandit_1", 0, 0, 0, 0, 100, 0)
    tick()

    for i = 1, 40 do
        e.px = e.px + 0.6                      -- footwork-scale contention, every tick
        KCD2MP_ApplyNpcState("prepadeni_bandit_1", 0, 0, 0, 0, 100, 0)
        tick()
    end
    check("(g) 40 ticks of footwork-scale contention never release the puppet",
        KCD2MP.npcPuppets["prepadeni_bandit_1"] ~= nil)
    check("(g) no divergence line", countLog("NPC-DIVERGE", logMark) == 0)
    check("(g) the pre-existing NPC-FIGHT counter still counted them",
        (KCD2MP.npcPuppets["prepadeni_bandit_1"] or {}).fightN ~= nil
        and KCD2MP.npcPuppets["prepadeni_bandit_1"].fightN > 0,
        tostring((KCD2MP.npcPuppets["prepadeni_bandit_1"] or {}).fightN))
    noErrs("(g)")
end

-- ---------------------------------------------------------------------------
-- (h) The toggle. Off restores the pre-WO-90 behaviour verbatim; a bare
--     number retunes the distance without a rebuild; junk is refused.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP._npcDivergeUntil = {}
    local logMark = #LOG

    KCD2MP_SetNpcDiverge("bogus")
    check("(h) a bad argument is refused and changes nothing",
        countLog("expected 'on', 'off' or a distance", logMark) == 1)

    KCD2MP_SetNpcDiverge("%LINE")
    check("(h) a bare invocation reports the current state instead of erroring",
        countLog("NPC-DIVERGE release is ON", logMark) == 1
        and countLog("expected 'on', 'off' or a distance", logMark) == 1,
        lastLog("NPC-DIVERGE release is", logMark))

    KCD2MP_SetNpcDiverge("off")
    check("(h) off is recorded", KCD2MP.npcDiverge == false)
    local e = mkEntity("tkop_ptacek", 0, 0, 0)
    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
    tick()
    for _ = 1, 8 do
        e.px, e.py = 57.24, 0
        KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
        tick()
    end
    check("(h) OFF: the pre-WO-90 tug-of-war continues -- the puppet is never released",
        KCD2MP.npcPuppets["tkop_ptacek"] ~= nil)
    check("(h) OFF: no divergence line", countLog("NPC-DIVERGE tkop_ptacek: local world", logMark) == 0)
    check("(h) OFF: the body is still being dragged back every tick", #e.writes >= 8,
        tostring(#e.writes) .. " writes")

    KCD2MP_SetNpcDiverge("on")
    check("(h) on is recorded", KCD2MP.npcDiverge == true)
    KCD2MP_SetNpcDiverge("25")
    check("(h) a bare number is accepted and leaves the release enabled",
        KCD2MP.npcDiverge == true
        and (lastLog("NPC-DIVERGE release enabled", logMark) or ""):find("threshold 25.0m", 1, true) ~= nil,
        lastLog("NPC-DIVERGE release enabled", logMark))
    KCD2MP_SetNpcDiverge("8")   -- restore the shipped default for any later scenario
    noErrs("(h)")
end

-- ---------------------------------------------------------------------------
-- (i) The spawn-time model read-back (finding 1's detector). A body with no
--     character instance on slot 0 must say so loudly; one with a model must
--     log the model and stay quiet.
-- ---------------------------------------------------------------------------
do
    resetNpcSync()
    KCD2MP.ghosts = {}
    KCD2MP.ghostNames = {}
    local logMark = #LOG

    -- KCD2MP_SpawnGhost removes any pre-existing entity of the spawn name
    -- BEFORE spawning, so the fixture must appear only when SpawnEntity is
    -- called -- exactly as the engine behaves.
    local spawned = mkEntity("kcd2mp_7", 0, 0, 0)
    spawned.cdf = nil                                   -- no model: the field case
    spawned.GetCharacterFileName = function(self, slot) return self.cdf end
    ENTS["kcd2mp_7"] = nil
    XGenAIModule = XGenAIModule or mkstub()
    XGenAIModule.SpawnEntity = function() ENTS["kcd2mp_7"] = spawned; return spawned end

    KCD2MP_SpawnGhost("7", 0, 0, 0, 0)
    check("(i) a body with no character instance is called out loudly",
        countLog("SPAWN NO MODEL ghost '7'", logMark) == 1,
        lastLog("SPAWN NO MODEL", logMark))
    check("(i) ...and the reason is named", (lastLog("SPAWN NO MODEL ghost '7'", logMark) or "")
        :find("no character instance on slot 0", 1, true) ~= nil)
    check("(i) no model line was claimed", countLog("spawn model ghost '7'", logMark) == 0)

    -- And the healthy case.
    local mark2 = #LOG
    KCD2MP.ghosts = {}
    local ok2 = mkEntity("kcd2mp_8", 0, 0, 0)
    ok2.cdf = "objects/characters/humans/male/male.cdf"
    ok2.GetCharacterFileName = function(self, slot) return self.cdf end
    ENTS["kcd2mp_8"] = nil
    XGenAIModule.SpawnEntity = function() ENTS["kcd2mp_8"] = ok2; return ok2 end

    KCD2MP_SpawnGhost("8", 0, 0, 0, 0)
    check("(i) a body WITH a model logs the model path",
        (lastLog("spawn model ghost '8'", mark2) or ""):find("male.cdf", 1, true) ~= nil,
        lastLog("spawn model ghost '8'", mark2))
    check("(i) ...and raises no alarm", countLog("SPAWN NO MODEL ghost '8'", mark2) == 0)
    noErrs("(i)")
end

OUT = table.concat(RESULTS, "\n")
