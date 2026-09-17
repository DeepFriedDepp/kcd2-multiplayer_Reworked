-- WO-98 synthetic test: the instrumentation channels and the cutscene-held
-- readiness prompt, against the real kdcmp.lua under MoonSharp.
--
--   (a) every native toast leaves an MP-TOAST line carrying its final text
--   (b) a persistent DrawText row logs MP-SCREEN once when its text changes
--       and once (text="") when it disappears -- never per frame
--   (c) a divergence that arrives DURING a cutscene parks the offer: no
--       prompt row, F11 logs MP-KEY (cutscene=1) and fires nothing; the
--       cutscene's end re-offers it and F11 then fires exactly once
--   (d) a cutscene starting over an open prompt hides it; a withdrawal while
--       parked clears it; the cutscene's end re-offers nothing
--   (e) identical divergence re-pushes collapse: one full QUEST-DIVERGENCE
--       line, then one "unchanged (re-pushed xN)" line per minute; a changed
--       pair logs in full again
--   (f) KCD2MP_LogSummary writes MP-SUMMARY-MOD with the live counters
--   (g) every [KCD2-MP] line ends with the mod clock (" t=<s>.<ms>")
--   (h) the clock offset shows beside the ping
--   (i) a peer's cutscene state appears in the local MP-CUTSCENE line
--
-- Driven by Test-WO98Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: the Lua half of the WO-98 channels emits what
-- docs/WO-98-log-format.md says, and the prompt cannot be shown while the
-- mod believes a cutscene is playing. What it does NOT prove: that the
-- agent's tail actually sees CutscenePlayer lines on a live build (WO-80
-- did, for "Rendered"; "Ingame" is new here and unverified live), or that
-- an F11 press is genuinely swallowed by the engine during a cutscene --
-- the field evidence for that is indirect (docs/WO-98-findings.md s5).
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; ALLCMDS = {}; DRAWS = {}
ORIG_ONACTION_CALLS = 0

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

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

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
local function countCmds(prefix, fromN)
    local n = 0
    for i = (fromN or 0) + 1, #CMDS do if CMDS[i]:find(prefix, 1, true) == 1 then n = n + 1 end end
    return n
end
local function draw()
    DRAWS = {}
    KCD2MP_DrawInteractionUI()
end
local function drawn(needle)
    for _, d in ipairs(DRAWS) do if d.text:find(needle, 1, true) then return d end end
    return nil
end
local function press(action)
    Player.Client.OnAction(nil, action, "press", 1)
    Player.Client.OnAction(nil, action, "release", 0)
end
local Q = KCD2MP.quest
local function resetQuest()
    Q.enabled = true; Q.radius = 35.0; Q.windowS = 120.0; Q.promptGapS = 60.0
    Q.level = nil; Q.current = "socky"
    Q.announced = {}; Q.declined = {}; Q.prompt = nil; Q.pendingPrompt = nil
    Q.catchup = nil; Q.catchupRemote = {}; Q.lastTickAt = 0; Q.lastPos = nil
    Q.fired = {}; Q.lastPromptAt = {}; Q.hint = {}; Q.waiting = {}
    Q._lastDivergeLogKey = nil; Q._divergeRepeat = 0; Q._divergeRepeatAt = 0
    KCD2MP.invite = nil; KCD2MP.interactionMsg = nil; KCD2MP.diceTurn = nil
    KCD2MP.ghosts = {}
    KCD2MP.cutsceneActive = false; KCD2MP.cutsceneName = nil; KCD2MP.peerCutscene = {}
    if KCD2MP.dice then KCD2MP.dice.open = false end
    KCD2MP._questDeadEdge = false; PDEAD = false
    ENTS = {}
    ERRS = {}; TOASTS = {}; DRAWS = {}; CMDS = {}
    NOW = NOW + 1000     -- every scenario starts well clear of any debounce
end
local function diverge(rel, peerQuest, peerObj, localObj, hint, id, who)
    return KCD2MP_QuestDivergence(id or "7", who or "Joiner", peerQuest, peerObj, localObj, rel, hint or "")
end

-- ---------------------------------------------------------------------------
-- (a) toast text is logged
resetQuest()
local before = #LOG
KCD2MP_ShowNativeToast('Joiner is ahead of you: "Carry the sacks". Waiting.')
check("(a) the toast reached the HUD stub", TOASTS[#TOASTS] ~= nil and TOASTS[#TOASTS]:find("Carry the sacks", 1, true) ~= nil, TOASTS[#TOASTS])
local tl = lastLog("MP-TOAST kind=native", before)
check("(a) MP-TOAST line written with the final text (quotes folded to apostrophes)",
    tl ~= nil and tl:find([[text="Joiner is ahead of you: 'Carry the sacks'. Waiting."]], 1, true) ~= nil, tl)
KCD2MP_ShowInteractionMsg("Staying on your own story")
check("(a) interaction messages log as kind=msg", lastLog('MP-TOAST kind=msg text="Staying on your own story"', before) ~= nil)
check("(a) the toast counter advanced by two", KCD2MP._stats.toasts >= 2, KCD2MP._stats.toasts)
noErrs("(a)")

-- ---------------------------------------------------------------------------
-- (b) screen rows: once on change, once on disappearance, never per frame
resetQuest()
before = #LOG
KCD2MP_ShowInteractionMsg("m1")
draw(); draw(); draw()
check("(b) the row is drawn every frame", drawn("m1") ~= nil)
check("(b) MP-SCREEN row=msg logged exactly once across three frames", countLog('MP-SCREEN row=msg text="m1"', before) == 1, countLog('MP-SCREEN row=msg', before))
KCD2MP.interactionMsg = nil
draw(); draw()
check("(b) the row's disappearance logged exactly once as text=\"\"", countLog('MP-SCREEN row=msg text=""', before) == 1)
check("(b) no other MP-SCREEN lines leaked", countLog("MP-SCREEN", before) == 2, countLog("MP-SCREEN", before))
noErrs("(b)")

-- ---------------------------------------------------------------------------
-- (c) divergence during a cutscene: parked, F11 inert, re-offered on end
resetQuest()
before = #LOG
KCD2MP_SetCutscene(true, "socky_3_tavern")
check("(c) MP-CUTSCENE local start logged", lastLog("MP-CUTSCENE side=local state=start name=socky_3_tavern", before) ~= nil)
local r = diverge("behind", "svatba", "Find the blacksmith.", "Carry the sacks.")
check("(c) the divergence path reports the offer as made (held is truthy)", r == "prompt", r)
check("(c) no prompt is up", Q.prompt == nil)
check("(c) the offer is parked", Q.pendingPrompt ~= nil and Q.pendingPrompt.beat == "svatba.02_init_blacksmith", Q.pendingPrompt and Q.pendingPrompt.beat)
check("(c) QUEST-PROMPT held logged, naming the cutscene", lastLog("QUEST-PROMPT held: a cutscene is playing (socky_3_tavern)", before) ~= nil)
draw()
check("(c) no prompt row drawn during the cutscene", drawn("catch up to") == nil and drawn("F11") == nil)
local cmdsBefore = #CMDS
press("kcd2mp_dice_bank")
check("(c) F11 during the cutscene fired nothing", countCmds("wh_concept_HasteTrigger", cmdsBefore) == 0 and Q.catchup == nil)
local key = lastLog("MP-KEY action=kcd2mp_dice_bank", before)
check("(c) MP-KEY recorded the press with cutscene=1 pending=1 prompt=0",
    key ~= nil and key:find("prompt=0", 1, true) and key:find("pending=1", 1, true) and key:find("cutscene=1", 1, true), key)
check("(c) mp_quest_yes during the cutscene is refused", KCD2MP_QuestAnswer(true) == false and lastLog("QUEST-PROMPT answer refused: a cutscene is playing", before) ~= nil)
KCD2MP_SetCutscene(false, "socky_3_tavern")
check("(c) MP-CUTSCENE local end logged", lastLog("MP-CUTSCENE side=local state=end", before) ~= nil)
check("(c) the parked offer is re-raised as a real prompt", Q.prompt ~= nil and Q.prompt.beat == "svatba.02_init_blacksmith" and Q.pendingPrompt == nil, Q.prompt and Q.prompt.beat)
check("(c) QUEST-PROMPT re-offered + shown logged", lastLog("QUEST-PROMPT re-offered after the cutscene", before) ~= nil and lastLog("QUEST-PROMPT shown (divergence)", before) ~= nil)
draw()
check("(c) the prompt row is drawn now", drawn("catch up to svatba.02_init_blacksmith") ~= nil)
check("(c) the prompt row logged as MP-SCREEN row=quest_prompt", lastLog("MP-SCREEN row=quest_prompt text=", before) ~= nil)
cmdsBefore = #CMDS
press("kcd2mp_dice_bank")
check("(c) F11 after the cutscene fired the beat exactly once", countCmds("wh_concept_HasteTrigger svatba.02_init_blacksmith", cmdsBefore) == 1 and Q.fired["svatba.02_init_blacksmith"] == true)
key = lastLog("MP-KEY action=kcd2mp_dice_bank", before)
check("(c) MP-KEY recorded the second press with prompt=1 cutscene=0", key ~= nil and key:find("prompt=1", 1, true) and key:find("cutscene=0", 1, true), key)
noErrs("(c)")

-- ---------------------------------------------------------------------------
-- (d) cutscene over an open prompt hides it; withdrawal while parked clears it
resetQuest()
before = #LOG
diverge("behind", "svatba", "Find the blacksmith.", "Carry the sacks.")
check("(d) prompt is up before the cutscene", Q.prompt ~= nil)
KCD2MP_SetCutscene(true, "socky_6_pillary")
check("(d) the open prompt was hidden and parked", Q.prompt == nil and Q.pendingPrompt ~= nil and Q.pendingPrompt.beat == "svatba.02_init_blacksmith")
check("(d) QUEST-PROMPT hidden logged", lastLog("QUEST-PROMPT hidden: cutscene started", before) ~= nil)
check("(d) the local MP-CUTSCENE line shows prompt=0 pending=1", (lastLog("MP-CUTSCENE side=local state=start", before) or ""):find("prompt=0 pending=1", 1, true) ~= nil)
KCD2MP_QuestPromptMoot("objectives now agree", "7")
check("(d) the parked offer was withdrawn on convergence", Q.pendingPrompt == nil and lastLog("QUEST-PROMPT pending offer withdrawn (objectives now agree)", before) ~= nil)
KCD2MP_SetCutscene(false, "socky_6_pillary")
check("(d) nothing is re-offered after the cutscene", Q.prompt == nil and Q.pendingPrompt == nil)
check("(d) no HasteTrigger was ever issued", countCmds("wh_concept_HasteTrigger") == 0)
noErrs("(d)")

-- ---------------------------------------------------------------------------
-- (e) identical re-pushes collapse
resetQuest()
before = #LOG
local n0 = Q.divergeN or 0     -- cumulative across scenarios; assert relative
for i = 1, 10 do
    diverge("ahead", "socky", "Talk to the woman.", "Carry the sacks.")
    NOW = NOW + 2.5
end
check("(e) ten identical pushes produced one full QUEST-DIVERGENCE line", countLog("QUEST-DIVERGENCE #", before) == 1, countLog("QUEST-DIVERGENCE #", before))
check("(e) the divergence counter still counts every push", Q.divergeN == n0 + 10, Q.divergeN - n0)
NOW = NOW + 61
diverge("ahead", "socky", "Talk to the woman.", "Carry the sacks.")
local rep = lastLog("QUEST-DIVERGENCE #" .. (n0 + 11) .. " unchanged (re-pushed x10)", before)
check("(e) after a minute the repeats surface as one counter line", rep ~= nil, lastLog("QUEST-DIVERGENCE", before))
diverge("ahead", "socky", "Talk to the woman.", "Defend Capon.")
check("(e) a changed pair logs in full again, preceded by the repeat total",
    countLog("QUEST-DIVERGENCE #" .. (n0 + 12) .. ":", before) == 1 and lastLog("QUEST-DIVERGENCE previous pair was re-pushed x10 unchanged", before) ~= nil)
check("(e) exactly one WAITING_FOR_PEER toast for the pair (rel unchanged)", #TOASTS == 1, #TOASTS)
noErrs("(e)")

-- ---------------------------------------------------------------------------
-- (f) summary line
resetQuest()
before = #LOG
KCD2MP_LogSummary("test")
local sm = lastLog("MP-SUMMARY-MOD reason=test", before)
check("(f) MP-SUMMARY-MOD written", sm ~= nil, sm)
check("(f) it carries the live toast counter", sm ~= nil and sm:find("toasts=" .. tostring(KCD2MP._stats.toasts), 1, true) ~= nil, sm)
check("(f) it carries the quest divergence count", sm ~= nil and sm:find("quest_divergences=" .. tostring(Q.divergeN), 1, true) ~= nil)
noErrs("(f)")

-- ---------------------------------------------------------------------------
-- (g) mod clock on every mp_log line. A handful of init-time lines go
-- through System.LogAlways directly (MOD INIT, hook confirmations) and are
-- exempt; every structured channel and every QUEST-/NPC- line is mp_log.
local stamped, unstamped, sample = 0, 0, nil
for _, l in ipairs(LOG) do
    if l:find("[KCD2-MP] ", 1, true) == 1 and (l:find("MP-", 1, true) or l:find("QUEST-", 1, true) or l:find("NPC-", 1, true)) then
        if l:match(" t=%d+%.%d%d%d$") then stamped = stamped + 1 else unstamped = unstamped + 1; sample = sample or l end
    end
end
check("(g) every MP-/QUEST-/NPC- line ends with t=<s>.<ms>", stamped > 0 and unstamped == 0, "stamped=" .. stamped .. " unstamped=" .. unstamped .. " e.g. " .. tostring(sample))

-- ---------------------------------------------------------------------------
-- (h) clock offset beside the ping
KCD2MP_SetClockOffset(4750, 30, 5)
KCD2MP_ShowPing(12)
check("(h) ping text shows the offset in seconds", KCD2MP.pingText == "Ping: 12 ms  clock +4.75 s", KCD2MP.pingText)
noErrs("(h)")

-- ---------------------------------------------------------------------------
-- (i) peer cutscene state in the local line
resetQuest()
before = #LOG
KCD2MP_SetPeerCutscene("7", true, "socky_5_departure")
KCD2MP_SetCutscene(true, "socky_5_departure")
check("(i) local line carries peers=7:1", (lastLog("MP-CUTSCENE side=local state=start", before) or ""):find("peers=7:1", 1, true) ~= nil, lastLog("MP-CUTSCENE", before))
KCD2MP_SetCutscene(false, "socky_5_departure")
noErrs("(i)")

OUT = table.concat(RESULTS, "\n")
return OUT
