-- WO-94 synthetic test for Shared Quests (the main-story readiness prompt):
--   (a) the registry is bounded: exactly 32 M-coded main quests, every
--       registered beat path validates, side-quest / DLC / made-up paths
--       are refused, and naming a side quest as "current" logs that it is
--       outside the registry
--   (b) side content triggers NOTHING: standing on a main-quest beat while
--       on a side quest (or on no quest) emits no approach
--   (c) proximity detection: fires once per beat, picks the nearest, honours
--       the radius, skips fixed-point beats of the other map, resolves an
--       entity-positioned beat live and stays quiet while the entity is not
--       streamed in
--   (d) the prompt state machine: refuses non-registry beats, shows only when
--       the agent says the objectives differ, persists indefinitely (drawn
--       every label tick, no timeout), is withdrawn when moot, never
--       re-prompts a declined beat, and refuses while a catch-up is running
--   (e) the keys: F11 (kcd2mp_dice_bank) fires wh_concept_HasteTrigger for
--       exactly the prompted beat and opens the window; F12 declines; an open
--       invite takes precedence; an open dice board takes precedence; the
--       game's own OnAction handler runs on EVERY press regardless
--   (f) the hazard window: death / clock / local teleport / chain-suspend
--       lines carry the distinct CATCHUP-HAZARD prefix only inside a window
--       (local or peer-announced), the window closes on time with an "end"
--       event, and nothing is logged outside one
--   (g) not responding: the prompt stays up, nothing fires, no event goes
--       out; WO-90's divergence release still works underneath, and its
--       stand-off is now 180 s (a 61 s lapse is refused, 181 s accepted)
--   (h) nothing pauses: no time-scale, pause, freeze or dialogue kill-switch
--       command is issued on any path
--
-- Driven by Test-WO94Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: the state machine, the registry gate, the key routing
-- and the hazard tagging behave as specified against the real Lua.
-- What it does NOT prove: that wh_concept_HasteTrigger does anything when
-- the string reaches the engine, that F11/F12 arrive as these action names
-- on a real keyboard, that DrawText renders where expected, or that a real
-- player gets usable lead time. Those are the live checks in
-- docs/WO-94-findings.md.
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0                                  -- the fake wall clock, seconds
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}                                -- System.ExecuteCommand strings since a scenario reset
ALLCMDS = {}                             -- every System.ExecuteCommand string of the whole run, never reset
DRAWS = {}                               -- every System.DrawText call since the last reset
ORIG_ONACTION_CALLS = 0                  -- the game's own OnAction handler, chained before ours

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
System.RemoveEntity = function(eid)
    for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end
end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- The local player. Position is mutable through PPOS so scenarios can walk.
PPOS = { x = 0, y = 0, z = 0 }
PDEAD = false
player = {
    GetWorldPos   = function() return { x = PPOS.x, y = PPOS.y, z = PPOS.z } end,
    GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
    actor = { GetHealth = function() return 100 end,
              IsDead = function() return PDEAD end,
              IsUnconscious = function() return false end },
    human = { IsWeaponDrawn = function() return false end },
    inventory = { GetMoney = function() return 1000 end },
}
-- The engine's Player class table, so kdcmp.lua installs its OnAction hooks.
-- The pre-existing handler stands in for the game's own: it must be called
-- for every action whatever our hook does with it.
Player = { Client = { OnAction = function(...) ORIG_ONACTION_CALLS = ORIG_ONACTION_CALLS + 1 end } }

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
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
    ERRS = {}
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
local function countCmds(prefix, fromN)
    local n = 0
    for i = (fromN or 0) + 1, #CMDS do if CMDS[i]:find(prefix, 1, true) == 1 then n = n + 1 end end
    return n
end
local function drawn(needle)
    for _, d in ipairs(DRAWS) do if d.text:find(needle, 1, true) then return d end end
    return nil
end
local function press(action)
    Player.Client.OnAction(nil, action, "press", 1)
    Player.Client.OnAction(nil, action, "release", 0)
end
-- One second of world: the proximity tick is gated to 1 Hz on os.clock.
local function second()
    NOW = NOW + 1.0
    KCD2MP_QuestProximityTick()
end
local Q = KCD2MP.quest
local function resetQuest()
    Q.enabled = true; Q.radius = 35.0; Q.windowS = 120.0
    Q.level = nil; Q.current = nil
    Q.announced = {}; Q.declined = {}; Q.prompt = nil
    Q.fired = {}; Q.lastPromptAt = {}; Q.waiting = {}   -- WO-96 state
    Q.catchup = nil; Q.catchupRemote = {}; Q.lastTickAt = 0; Q.lastPos = nil
    KCD2MP.invite = nil; KCD2MP.interactionMsg = nil
    if KCD2MP.dice then KCD2MP.dice.open = false end
    KCD2MP._questDeadEdge = false; PDEAD = false
    ERRS = {}; TOASTS = {}; DRAWS = {}
end

local NEXTID = 9000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, anims = {}, dead = false, ko = false, hp = 100,
                Properties = {}, AI = {}, inventory = mkstub() }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, p) self.px, self.py, self.pz = p.x, p.y, p.z; self.writes[#self.writes + 1] = { x = p.x, y = p.y, z = p.z, at = NOW } end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = { anim = anim, at = NOW } end
    e.actor = setmetatable({ IsDead = function() return e.dead end, IsUnconscious = function() return e.ko end, GetHealth = function() return e.hp end },
                           { __index = function(_, k) return function(...) return nil end end })
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end, HolsterWeapon = function() return true end }
    ENTS[name] = e
    return e
end

check("hooks: kdcmp.lua installed its OnAction hook over the game's handler", countLog("Player hooks OK") == 1)

-- ---------------------------------------------------------------------------
-- (a) The registry is bounded.
-- ---------------------------------------------------------------------------
do
    resetQuest()
    local n, allM, anyDlc, beats, allValid = 0, true, false, 0, true
    local codes = {}
    for _, q in ipairs(KCD2MP_MAINQUESTS) do
        n = n + 1
        if not tostring(q.code):match("^M%d+[a-z]?$") then allM = false end
        if tostring(q.name):lower():find("dlc", 1, true) then anyDlc = true end
        codes[q.code] = true
        for _, b in ipairs(q.beats or {}) do
            beats = beats + 1
            if not KCD2MP_QuestIsRegistryBeat(q.name .. "." .. b.t) then allValid = false end
            if not (b.e or (b.x and b.y and b.z)) then allValid = false end
        end
    end
    check("(a) exactly 32 main quests in the registry", n == 32, tostring(n))
    check("(a) every registry code is an M-code (main story)", allM)
    check("(a) M01 and M51 bracket the registry", codes["M01"] and codes["M51"])
    check("(a) no DLC-named quest in the registry", not anyDlc)
    check("(a) every registered beat validates and is positioned", allValid and beats > 0, tostring(beats) .. " beats")
    check("(a) a real side quest's path is refused (korenarkaZachrana.init)", not KCD2MP_QuestIsRegistryBeat("korenarkaZachrana.init"))
    check("(a) a tutorial quest's path is refused", not KCD2MP_QuestIsRegistryBeat("combat_tutorial_pro.start"))
    check("(a) a DLC quest's path is refused", not KCD2MP_QuestIsRegistryBeat("dlc2_selling__days_outside_kh_counter.init"))
    check("(a) a main quest with an unregistered trigger is refused", not KCD2MP_QuestIsRegistryBeat("prepadeni.01_init"))
    check("(a) a Lua-injection-shaped string is refused", not KCD2MP_QuestIsRegistryBeat('socky._initAndStart") os.exit() --'))
    check("(a) the empty string and a non-string are refused", not KCD2MP_QuestIsRegistryBeat("") and not KCD2MP_QuestIsRegistryBeat(nil))
    local mark = #LOG
    KCD2MP_QuestSetCurrent("korenarkazachrana")
    check("(a) naming a side quest as current logs it is outside the registry",
        countLog("NOT in the main-quest registry", mark) == 1, lastLog("QUEST current", mark))
    mark = #LOG
    KCD2MP_QuestSetCurrent("kralovskestribro")
    check("(a) naming a main quest (lowercased, as the engine marker does) resolves to its code",
        (lastLog("QUEST current", mark) or ""):find("M34", 1, true) ~= nil, lastLog("QUEST current", mark))
    mark = #LOG
    KCD2MP_QuestSetCurrent("semin")                        -- the engine's marker for M08 mucirna (Necessary Evil)
    check("(a) a marker key that differs from the XML name still resolves (semin -> M08 mucirna)",
        (lastLog("QUEST current", mark) or ""):find("M08", 1, true) ~= nil, lastLog("QUEST current", mark))
    mark = #LOG
    KCD2MP_QuestSetCurrent("bitvazabohutu")               -- M50 zoufalaObranaZaBohutu
    check("(a) ...and so does bitvazabohutu -> M50", (lastLog("QUEST current", mark) or ""):find("M50", 1, true) ~= nil)
    mark = #LOG
    KCD2MP_QuestSetCurrent("mucirna")
    check("(a) the XML name itself is NOT a marker key when the engine uses another",
        (lastLog("QUEST current", mark) or ""):find("NOT in the main-quest registry", 1, true) ~= nil)
    noErrs("(a)")
end

-- ---------------------------------------------------------------------------
-- (b) Side content triggers nothing.
-- ---------------------------------------------------------------------------
do
    resetQuest()
    KCD2MP_QuestSetLevel("kutnohorsko")
    PPOS.x, PPOS.y, PPOS.z = 2913.14, 2226.35, 118.37     -- exactly on kralovskeStribro.02_startMines
    local mark = #LOG
    KCD2MP_QuestSetCurrent("korenarkazachrana")            -- a side quest (field log 2026-08-25)
    for _ = 1, 3 do second() end
    check("(b) on a side quest, standing on a main-quest beat emits nothing", countEvt("quest_approach", "", mark) == 0)
    KCD2MP_QuestSetCurrent("")                             -- no quest known
    for _ = 1, 3 do second() end
    check("(b) with no quest known, nothing is emitted either", countEvt("quest_approach", "", mark) == 0)
    KCD2MP_QuestSetCurrent("prepadeni")                    -- M01: in the registry, zero positioned beats
    for _ = 1, 3 do second() end
    check("(b) a main quest with no positioned beats emits nothing", countEvt("quest_approach", "", mark) == 0)
    check("(b) ...and no prompt can exist", Q.prompt == nil)
    noErrs("(b)")
end

-- ---------------------------------------------------------------------------
-- (c) Proximity detection.
-- ---------------------------------------------------------------------------
do
    resetQuest()
    KCD2MP_QuestSetLevel("kutnohorsko")
    KCD2MP_QuestSetCurrent("kralovskestribro")
    -- 02_startMines is at (2913.14, 2226.35); 04_goToSmelter at (2931.86, 2239.91), 23 m apart.
    PPOS.x, PPOS.y, PPOS.z = 2913.14 - 30.0, 2226.35, 118.37   -- 30 m from 02, ~52 m from 04
    local mark = #LOG
    second()
    check("(c) inside the radius: one approach for the nearest beat",
        countEvt("quest_approach", "kralovskeStribro.02_startMines", mark) == 1 and countEvt("quest_approach", "", mark) == 1)
    check("(c) the approach is logged with the code and distance",
        (lastLog("QUEST-APPROACH", mark) or ""):find("M34", 1, true) ~= nil and (lastLog("QUEST-APPROACH", mark) or ""):find("30.0m", 1, true) ~= nil,
        lastLog("QUEST-APPROACH", mark))
    for _ = 1, 10 do second() end
    check("(c) standing there for 10 s announces it only once", countEvt("quest_approach", "", mark) == 1)
    PPOS.x = 2931.86 + 5.0; PPOS.y = 2239.91                    -- 5 m from 04, ~23 m from 02 (already announced)
    second()
    check("(c) walking to the next beat announces that one", countEvt("quest_approach", "kralovskeStribro.04_goToSmelter", mark) == 1)
    check("(c) ...and not the already-announced one again", countEvt("quest_approach", "kralovskeStribro.02_startMines", mark) == 1)

    -- Radius: 05_goToSecretMint is far away; shrink/grow the radius.
    PPOS.x, PPOS.y = 3555.39 + 40.0, 1797.44                    -- 40 m from 05
    second()
    check("(c) 40 m out with a 35 m radius: nothing", countEvt("quest_approach", "kralovskeStribro.05_goToSecretMint", mark) == 0)
    KCD2MP_QuestSetRadius("50")
    second()
    check("(c) mp_quest_radius 50 brings it inside", countEvt("quest_approach", "kralovskeStribro.05_goToSecretMint", mark) == 1)
    KCD2MP_QuestSetRadius("3")
    check("(c) an out-of-range radius is refused and logged", Q.radius == 50 and countLog("mp_quest_radius: expected", mark) == 1)

    -- Other map: same coordinates, wrong level -> fixed-point beats are skipped.
    resetQuest()
    KCD2MP_QuestSetLevel("trosecko")
    KCD2MP_QuestSetCurrent("kralovskestribro")
    PPOS.x, PPOS.y = 2913.14, 2226.35
    mark = #LOG
    for _ = 1, 3 do second() end
    check("(c) a kutnohorsko fixed-point beat is skipped while trosecko is loaded", countEvt("quest_approach", "", mark) == 0)
    -- Level unknown -> not skipped (the agent has not seen a level banner yet).
    resetQuest()
    KCD2MP_QuestSetCurrent("kralovskestribro")
    mark = #LOG
    second()
    check("(c) with the level unknown, fixed-point beats still detect", countEvt("quest_approach", "kralovskeStribro.02_startMines", mark) == 1)

    -- Entity-positioned beat, resolved live.
    resetQuest()
    KCD2MP_QuestSetLevel("trosecko")
    KCD2MP_QuestSetCurrent("svatba")                            -- M05: 02_init_blacksmith -> entity ttac_blacksmith
    PPOS.x, PPOS.y, PPOS.z = 100, 100, 10
    ENTS = {}
    mark = #LOG
    second()
    check("(c) an entity beat whose entity is not streamed in stays quiet", countEvt("quest_approach", "", mark) == 0)
    mkEntity("ttac_blacksmith", 110, 100, 10)                  -- 10 m away
    second()
    check("(c) once the entity exists nearby, its beat announces", countEvt("quest_approach", "svatba.02_init_blacksmith", mark) == 1)
    -- mp_quest_sync off: nothing.
    resetQuest()
    KCD2MP_QuestSetSync("off")
    KCD2MP_QuestSetCurrent("svatba")
    mark = #LOG
    second()
    check("(c) mp_quest_sync off: no detection", countEvt("quest_approach", "", mark) == 0 and Q.enabled == false)
    KCD2MP_QuestSetSync("on")
    -- the console's literal "%LINE" (no argument given on this build) is status, not an error
    mark = #LOG
    KCD2MP_QuestSetSync("%LINE")
    check("(c) the literal %LINE the console passes reads as a bare status request", Q.enabled == true and countLog("QUEST sync is ON", mark) == 1 and countLog("expected on|off", mark) == 0)
    noErrs("(c)")
end

-- ---------------------------------------------------------------------------
-- (d) The prompt state machine.
-- ---------------------------------------------------------------------------
do
    resetQuest()
    local mark = #LOG
    check("(d) a non-registry beat is refused before anything is shown",
        KCD2MP_QuestShowPrompt("2", "Alice", "korenarkaZachrana.init", 1) == false and Q.prompt == nil and countLog("QUEST-PROMPT refused", mark) == 1)
    check("(d) a registry beat with objectives not known to differ is not shown",
        KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 0) == false and Q.prompt == nil)
    check("(d) a registry beat with differing objectives is shown",
        KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1) == true and Q.prompt ~= nil)
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
    local d1 = drawn("Alice is ahead of you in \"Via Argentum\"  -- catch up to kralovskeStribro.02_startMines?")
    local d2 = drawn("F11 catch up")
    check("(d) the prompt is drawn by the interaction UI (label loop)", d1 ~= nil and d2 ~= nil)
    check("(d) ...as plain DrawText rows below the ping/invite rows", d1 and d1.y == 160 and d2 and d2.y == 184, d1 and d1.y)
    NOW = NOW + 3600
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
    check("(d) an hour later, unanswered, it is still drawn (no timeout)", drawn("Alice is ahead of you") ~= nil and Q.prompt ~= nil)
    KCD2MP_QuestPromptMoot("objectives now agree", "9")
    check("(d) a moot for a different ghost leaves it up", Q.prompt ~= nil)
    KCD2MP_QuestPromptMoot("objectives now agree", "2")
    check("(d) a moot for its ghost withdraws it, logged", Q.prompt == nil and countLog("QUEST-PROMPT withdrawn (objectives now agree)", mark) == 1)
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
    check("(d) ...and nothing is drawn afterwards", drawn("is ahead of you") == nil)
    -- decline memory
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    KCD2MP_QuestAnswer(false)
    check("(d) F12 declines: prompt gone, decline event out, no command", Q.prompt == nil and countEvt("quest_catchup", "decline kralovskeStribro.02_startMines", mark) == 1 and #CMDS == 0)
    check("(d) a declined beat is never re-prompted this session",
        KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1) == false and countLog("declined earlier this session", mark) == 1)
    check("(d) a different beat still prompts", KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.04_goToSmelter", 1) == true)
    KCD2MP_QuestPromptMoot("peer left", "2")
    -- mp_quest_sync off suppresses the prompt
    KCD2MP_QuestSetSync("off")
    check("(d) mp_quest_sync off suppresses a prompt", KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.04_goToSmelter", 1) == false)
    KCD2MP_QuestSetSync("on")
    check("(d) answering with no prompt up is a logged no-op", KCD2MP_QuestAnswer(true) == false and #CMDS == 0)
    noErrs("(d)")
end

-- ---------------------------------------------------------------------------
-- (e) The keys.
-- ---------------------------------------------------------------------------
do
    resetQuest()
    CMDS = {}
    local mark = #LOG
    local calls0 = ORIG_ONACTION_CALLS
    press("kcd2mp_dice_bank")
    check("(e) F11 with nothing up: no command, no event, no error", #CMDS == 0 and countEvt("quest_catchup", "", mark) == 0)
    check("(e) ...and the game's own handler ran for both press and release", ORIG_ONACTION_CALLS == calls0 + 2, tostring(ORIG_ONACTION_CALLS - calls0))

    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    calls0 = ORIG_ONACTION_CALLS
    press("kcd2mp_dice_bank")
    check("(e) F11 with the prompt up fires exactly the prompted beat",
        #CMDS == 1 and CMDS[1] == "wh_concept_HasteTrigger kralovskeStribro.02_startMines", CMDS[1])
    check("(e) ...the prompt is gone and a begin event is out",
        Q.prompt == nil and countEvt("quest_catchup", "begin kralovskeStribro.02_startMines", mark) == 1)
    check("(e) ...the hazard window is open", Q.catchup ~= nil and Q.catchup.beat == "kralovskeStribro.02_startMines")
    check("(e) ...the fire is logged before and after the call",
        countLog("QUEST-CATCHUP FIRE #1", mark) == 1 and countLog("QUEST-CATCHUP ExecuteCommand returned true", mark) == 1)
    check("(e) ...a native toast says whose story we are catching up to", TOASTS[#TOASTS] ~= nil and TOASTS[#TOASTS]:find("Alice", 1, true) ~= nil, TOASTS[#TOASTS])
    check("(e) ...and the game's own handler still ran", ORIG_ONACTION_CALLS == calls0 + 2)
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
    check("(e) the open window is drawn as a status row", drawn("Catch-up in progress (here)") ~= nil)
    -- a second prompt while a catch-up runs is refused
    check("(e) a new prompt while a catch-up is running is refused",
        KCD2MP_QuestShowPrompt("3", "Bob", "socky._initAndStart", 1) == false and countLog("already in progress here", mark) == 1)
    press("kcd2mp_dice_bank")
    check("(e) F11 again with nothing up fires nothing more", #CMDS == 1)

    -- F12
    resetQuest(); CMDS = {}
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.04_goToSmelter", 1)
    press("kcd2mp_dice_yield")
    check("(e) F12 declines: no command, decline event, prompt gone", #CMDS == 0 and Q.prompt == nil and countEvt("quest_catchup", "decline kralovskeStribro.04_goToSmelter", mark) == 1)

    -- Invite precedence: both up, F11 answers the invite, the quest prompt stays.
    resetQuest(); CMDS = {}
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    KCD2MP_ShowInvite("77", "Alice", "dice", 0)
    press("kcd2mp_dice_bank")
    check("(e) with an invite up too, F11 accepts the invite and does not fire",
        #CMDS == 0 and KCD2MP.invite == nil and Q.prompt ~= nil and countEvt("invite_accept", "77", mark) == 1)
    press("kcd2mp_dice_bank")
    check("(e) ...the next F11 answers the quest prompt", #CMDS == 1 and Q.prompt == nil)

    -- Dice board precedence: keys belong to the match while it is open.
    resetQuest(); CMDS = {}
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    KCD2MP.dice.open = true
    press("kcd2mp_dice_bank")
    check("(e) with the dice board open, F11 does not answer the quest prompt", #CMDS == 0 and Q.prompt ~= nil)
    KCD2MP.dice.open = false
    press("kcd2mp_dice_bank")
    check("(e) ...once the match closes, F11 answers it", #CMDS == 1 and Q.prompt == nil)

    -- mp_quest_fire refuses non-registry beats even from the console.
    resetQuest(); CMDS = {}
    check("(e) mp_quest_fire refuses a non-registry beat", KCD2MP_QuestFire("korenarkaZachrana.init", "console") == false and #CMDS == 0)
    check("(e) mp_quest_fire fires a registry beat", KCD2MP_QuestFire("socky._initAndStart", "console") == true and CMDS[1] == "wh_concept_HasteTrigger socky._initAndStart")
    check("(e) mp_quest_test_prompt with no argument prompts the first registered beat",
        (function() resetQuest(); return KCD2MP_QuestTestPrompt("") end)() == true and Q.prompt ~= nil and Q.prompt.who == "TestPeer")
    noErrs("(e)")
end

-- ---------------------------------------------------------------------------
-- (f) The hazard window.
-- ---------------------------------------------------------------------------
do
    resetQuest(); CMDS = {}
    local mark = #LOG
    -- Outside any window: the hooks are silent.
    check("(f) outside a window a hazard call logs nothing", KCD2MP_QuestHazard("npc-death", "x") == false and countLog("CATCHUP-HAZARD", mark) == 0)
    KCD2MP_NpcRemoteDeath("some_npc", "0x31")
    WORLD_T = 1000
    KCD2MP_ApplyTimeSkip("Alice", 1, 5000, false)
    check("(f) a remote death and a clock write outside a window carry no hazard line", countLog("CATCHUP-HAZARD", mark) == 0)

    -- Local window.
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    KCD2MP_QuestAnswer(true)
    NOW = NOW + 3.5
    KCD2MP_NpcRemoteDeath("some_npc", "0x31")
    local l = lastLog("CATCHUP-HAZARD npc-death-remote", mark)
    check("(f) a peer-applied NPC death inside the window is tagged", l ~= nil)
    check("(f) ...naming the beat, where it was fired, by whom and how long ago",
        l and l:find("kralovskeStribro.02_startMines", 1, true) and l:find("fired here by Alice 3.5s ago", 1, true) ~= nil, l)
    WORLD_T = 1000
    KCD2MP_ApplyTimeSkip("Bob", 1, 5000, false)
    check("(f) a world-clock write inside the window is tagged with the delta",
        (lastLog("CATCHUP-HAZARD clock", mark) or ""):find("1000 -> 5000 (+4000s) from Bob", 1, true) ~= nil, lastLog("CATCHUP-HAZARD clock", mark))
    -- local player death edge
    PDEAD = true
    KCD2MP_EmitState()
    KCD2MP_EmitState()
    check("(f) our own death inside the window is tagged once (edge, not level)", countLog("CATCHUP-HAZARD player-death", mark) == 1)
    PDEAD = false
    -- local teleport: two 1 Hz samples 500 m apart
    PPOS.x, PPOS.y, PPOS.z = 0, 0, 0
    second()
    PPOS.x = 500
    second()
    check("(f) a 500 m jump between two 1 Hz samples inside the window is tagged as a local teleport",
        (lastLog("CATCHUP-HAZARD teleport-local", mark) or ""):find("500m", 1, true) ~= nil, lastLog("CATCHUP-HAZARD teleport-local", mark))
    PPOS.x = 501
    second()
    check("(f) ordinary movement is not", countLog("CATCHUP-HAZARD teleport-local", mark) == 1)
    -- per-emitter-tick watch: the live gap. A 19.5 m goto between two 20 ms
    -- emits is caught; a gallop's 0.25 m per tick is not; outside a window
    -- nothing is watched at all.
    local tpBefore = countLog("CATCHUP-HAZARD teleport-local", mark)
    KCD2MP._questTickPos = nil
    for i = 1, 5 do NOW = NOW + 0.02; PPOS.x = PPOS.x + 0.25; KCD2MP_EmitState() end
    check("(f) a gallop (0.25 m per 20 ms emit) is not a teleport", countLog("CATCHUP-HAZARD teleport-local", mark) == tpBefore)
    NOW = NOW + 0.02; PPOS.x = PPOS.x - 4.1; PPOS.y = PPOS.y + 19.0; KCD2MP_EmitState()
    check("(f) a 19.5 m jump in one 20 ms emit IS tagged (the live gap)",
        countLog("CATCHUP-HAZARD teleport-local", mark) == tpBefore + 1
        and (lastLog("CATCHUP-HAZARD teleport-local", mark) or ""):find("in one 20ms tick", 1, true) ~= nil,
        lastLog("CATCHUP-HAZARD teleport-local", mark))
    NOW = NOW + 2.0; PPOS.x = PPOS.x + 30; KCD2MP_EmitState()
    check("(f) two emits 2 s apart are not compared (a suspended chain resuming is not a teleport)",
        countLog("CATCHUP-HAZARD teleport-local", mark) == tpBefore + 1)
    -- chain suspension: a stale emitter stamp whose probe finds it fresh again
    KCD2MP.emitRunning = true
    KCD2MP._emitAliveAt = NOW - 2.0
    KCD2MP._chainProbe = {}
    TIMERS = {}
    KCD2MP_StartEmitter()                       -- arms the probe (stamp stale)
    KCD2MP._emitAliveAt = NOW                   -- the chain "resumes"
    local n0 = #TIMERS
    for i = 1, n0 do TIMERS[i].f() end          -- probe hop 1
    for i = n0 + 1, #TIMERS do TIMERS[i].f() end -- probe hop 2
    check("(f) a chain suspension detected inside the window is tagged",
        countLog("was suspended, not dead", mark) == 1 and countLog("CATCHUP-HAZARD chain-suspend", mark) == 1, lastLog("CHAIN emit", mark))
    -- direct hazard while a window is open counts
    local hz = Q.hazardN
    check("(f) the hazard counter advanced for every tagged line", hz >= 5, tostring(hz))

    -- Window expiry.
    NOW = NOW + 121
    second()
    check("(f) after windowS the window closes with an end event",
        Q.catchup == nil and countEvt("quest_catchup", "end kralovskeStribro.02_startMines", mark) == 1 and countLog("QUEST-CATCHUP window closed", mark) == 1)
    local before = countLog("CATCHUP-HAZARD", mark)
    KCD2MP_NpcRemoteDeath("some_npc", "0x31")
    check("(f) after the window, the same death carries no hazard line", countLog("CATCHUP-HAZARD", mark) == before)

    -- Peer-announced window.
    resetQuest()
    mark = #LOG
    KCD2MP_QuestCatchupRemote("3", "Bob", "finale.01_initAndStart_Mikes_Kozlik_Sam_Dog", 1)
    NOW = NOW + 2.0
    KCD2MP_NpcRemoteDeath("kmal_hastal", "0x31")
    l = lastLog("CATCHUP-HAZARD npc-death-remote", mark)
    check("(f) a death here during a PEER's catch-up is tagged as theirs", l ~= nil and l:find("fired peer by Bob 2.0s ago", 1, true) ~= nil, l)
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
    check("(f) a peer's window is drawn as a status row too", drawn("Catch-up in progress (peer)") ~= nil)
    KCD2MP_QuestCatchupRemote("3", "Bob", "finale.01_initAndStart_Mikes_Kozlik_Sam_Dog", 0)
    check("(f) the peer's end closes it", KCD2MP_QuestWindow() == nil and countLog("window closed (finale.01", mark) == 1)
    noErrs("(f)")
end

-- ---------------------------------------------------------------------------
-- (g) Not responding is a first-class choice; WO-90 underneath is untouched,
--     with the stand-off now 180 s.
-- ---------------------------------------------------------------------------
do
    resetQuest(); CMDS = {}
    local mark = #LOG
    KCD2MP_QuestShowPrompt("2", "Alice", "kralovskeStribro.02_startMines", 1)
    for _ = 1, 1800 do second() end                  -- half an hour of nothing
    check("(g) thirty minutes unanswered: prompt still up, nothing fired, no catch-up event",
        Q.prompt ~= nil and #CMDS == 0 and countEvt("quest_catchup", "", mark) == 0)

    -- WO-90 divergence release, compact: the local world yanks a puppeted
    -- body 57.24 m three times -> released; a 61 s lapse is still refused,
    -- 181 s is accepted.
    ENTS = {}; SPHERE = {}
    KCD2MP.npcPuppets = {}; KCD2MP.npcPuppetRunning = false; KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetRetired = {}; KCD2MP._chainProbe = {}; KCD2MP._npcDivergeUntil = {}; KCD2MP._npcDivergeN = 0
    KCD2MP.npcDiverge = true
    KCD2MP._npcDeathSeen = {}; KCD2MP._npcDeathRemote = {}
    local e = mkEntity("tkop_ptacek", 0, 0, 0)
    local function tick() NOW = NOW + 0.05; KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen) end
    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0); tick()
    for i = 1, 6 do e.px, e.py = 57.24, 0; KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0); tick() end
    check("(g) WO-90 release still fires under the new build", KCD2MP.npcPuppets["tkop_ptacek"] == nil and countLog("NPC-DIVERGE tkop_ptacek: local world moved it", mark) == 1)
    check("(g) ...and its log line names the 180 s stand-off", (lastLog("NPC-DIVERGE tkop_ptacek: local world moved it", mark) or ""):find("for 180s", 1, true) ~= nil)
    NOW = NOW + 61
    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
    check("(g) 61 s later the stream is STILL refused (was accepted at 60 s before WO-94)", KCD2MP.npcPuppets["tkop_ptacek"] == nil)
    NOW = NOW + 120
    KCD2MP_ApplyNpcState("tkop_ptacek", 0, 0, 0, 0, 100, 0)
    check("(g) 181 s later it is accepted again", KCD2MP.npcPuppets["tkop_ptacek"] ~= nil and countLog("stand-off over", mark) == 1)
    check("(g) the unanswered prompt survived all of it", Q.prompt ~= nil)
    noErrs("(g)")
end

-- ---------------------------------------------------------------------------
-- (h) Nothing pauses, on any path.
-- ---------------------------------------------------------------------------
do
    local bad = {}
    for _, c in ipairs(ALLCMDS) do
        local lc = c:lower()
        if lc:find("t_scale", 1, true) or lc:find("t_gamescale", 1, true) or lc:find("pause", 1, true)
           or lc:find("freeze", 1, true) or lc:find("wh_dlg_enable", 1, true) or lc:find("wh_dlg_requestmaxdistance", 1, true) then
            bad[#bad + 1] = c
        end
    end
    check("(h) across every scenario, no time-scale, pause, freeze or dialogue kill-switch command was issued", #bad == 0, bad[1])
    local only = true
    for _, c in ipairs(ALLCMDS) do if c:find("wh_concept_HasteTrigger ", 1, true) ~= 1 then only = false end end
    check("(h) the only console command this feature ever issues is wh_concept_HasteTrigger", only and #ALLCMDS > 0, tostring(#ALLCMDS) .. " commands")
end

OUT = table.concat(RESULTS, "\n")
