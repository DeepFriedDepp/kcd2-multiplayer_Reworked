-- WO-96 synthetic test: divergence-gated prompting and WAITING_FOR_PEER.
--
-- The prompt is now raised from the agent's story-divergence signal
-- (KCD2MP_QuestDivergence), not from a peer's proximity to a beat. These
-- scenarios drive that entry point the way the agent does and assert on the
-- state machine, the screen rows, the keys and the console commands:
--   (a) divergence, catch-up available: we are behind, the peer is on a
--       different main quest with an unspent fireable beat -> prompt; F11
--       fires exactly that beat; the beat is then spent; the approach hint
--       and the peer's live position each pick a specific beat
--   (b) divergence, nothing to offer (same quest) -> WAITING_FOR_PEER
--       entered once: status row drawn, one toast, no prompt, no command
--   (c) WAITING_FOR_PEER exits on convergence
--   (d) WAITING_FOR_PEER exits on peer disconnect
--   (e) debounce: a second divergence inside the 60 s gap does not
--       re-prompt (deferred into the waiting row); the deferred offer is
--       raised by the 1 Hz tick once the gap has elapsed; repeated calls
--       while a prompt is up produce one prompt
--   (f) update in place: a changing peer objective updates the waiting row
--       without a new toast; a changed who-is-ahead does toast again
--   (g) decline: F12 on a prompt is remembered; the next divergence to that
--       quest goes to WAITING_FOR_PEER ("declined"), never a prompt
--   (h) spent: a beat fired here is never offered again -> WAITING_FOR_PEER
--   (i) prologue: M01 vs M02 (zero fireable beats) -> WAITING_FOR_PEER only,
--       no prompt, no command; production-code order decides who is behind
--   (j) we are ahead -> "is behind you" row, no prompt
--   (k) cannot tell (same quest, agent unknown) -> "STORY DIVERGED" row
--   (l) F12 with no prompt hides the row until the pair changes; F11 with no
--       prompt does nothing
--   (m) peer quest outside the registry -> WAITING_FOR_PEER, no prompt
--   (n) mp_quest_off -> divergence ignored, nothing drawn
--   (o) nothing pauses; the only console command ever issued is
--       wh_concept_HasteTrigger; the game's own OnAction runs on every press
--   (p) the 2026-09-13 host, replayed: stuck on "rekni ptackovi" while the
--       joiner takes the sacks, the guard, then leaves M03 for M05 -- the
--       waiting row names the joiner as ahead at the first step, updates in
--       place, and the prompt returns only when M05's beat becomes available
--
-- Driven by Test-WO96Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: the decision table, the waiting state's entry/exit/
-- dismiss, the debounce and the spent/declined gates against the real Lua.
-- What it does NOT prove: that the agent's rel (behind/ahead) is right in
-- the field, how often the row appears at a real objective-change rate,
-- whether it reads as help or as nagging, or that wh_concept_HasteTrigger
-- does anything when the string reaches the engine. Those are the live
-- checks in docs/WO-96-findings.md.
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
local function draw()
    DRAWS = {}
    KCD2MP_QuestDrawUI()
end
local function drawn(needle)
    for _, d in ipairs(DRAWS) do if d.text:find(needle, 1, true) then return d end end
    return nil
end
PRESSES = 0
local function press(action)
    PRESSES = PRESSES + 1
    Player.Client.OnAction(nil, action, "press", 1)
    Player.Client.OnAction(nil, action, "release", 0)
end
local function second()
    NOW = NOW + 1.0
    KCD2MP_QuestProximityTick()
end
local Q = KCD2MP.quest
local function resetQuest()
    Q.enabled = true; Q.radius = 35.0; Q.windowS = 120.0; Q.promptGapS = 60.0
    Q.level = nil; Q.current = nil
    Q.announced = {}; Q.declined = {}; Q.prompt = nil
    Q.catchup = nil; Q.catchupRemote = {}; Q.lastTickAt = 0; Q.lastPos = nil
    Q.fired = {}; Q.lastPromptAt = {}; Q.hint = {}; Q.waiting = {}
    KCD2MP.invite = nil; KCD2MP.interactionMsg = nil
    KCD2MP.ghosts = {}
    if KCD2MP.dice then KCD2MP.dice.open = false end
    KCD2MP._questDeadEdge = false; PDEAD = false
    ENTS = {}
    ERRS = {}; TOASTS = {}; DRAWS = {}; CMDS = {}
    NOW = NOW + 1000     -- every scenario starts well clear of any debounce
end
local function ent(x, y, z)
    return { id = math.random(1, 1e6), GetWorldPos = function() return { x = x, y = y, z = z } end }
end
-- The agent's call, verbatim shape: (ghostId, who, peerQuestLower, peerObjHuman, localObjHuman, rel, hintBeat)
local function diverge(rel, peerQuest, peerObj, localObj, hint, id, who)
    return KCD2MP_QuestDivergence(id or "7", who or "Joiner", peerQuest, peerObj, localObj, rel, hint or "")
end

check("registry sanity: socky has one fireable beat", KCD2MP_QuestIsRegistryBeat("socky._initAndStart"))
check("registry sanity: svatba has two entity beats", KCD2MP_QuestIsRegistryBeat("svatba.02_init_blacksmith") and KCD2MP_QuestIsRegistryBeat("svatba.03_init_concubine"))
check("registry sanity: prepadeni and zachrana have none",
    (function() for _, q in ipairs(KCD2MP_MAINQUESTS) do if (q.name == "prepadeni" or q.name == "zachrana") and #q.beats > 0 then return false end end return true end)())

-- ---------------------------------------------------------------------------
-- (a) divergence, catch-up available
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
local r = diverge("behind", "svatba", "svatba: some objective", "socky: rekni ptackovi o pr")
check("(a) returns prompt", r == "prompt", r)
check("(a) a prompt is up for the peer's quest, first usable beat", Q.prompt ~= nil and Q.prompt.beat == "svatba.02_init_blacksmith", Q.prompt and Q.prompt.beat)
check("(a) prompt reason is divergence", Q.prompt and Q.prompt.reason == "divergence")
check("(a) QUEST-PROMPT shown (divergence) logged", countLog("QUEST-PROMPT shown (divergence)") == 1)
draw()
check("(a) row says the peer is ahead and names the beat", drawn("Joiner is ahead of you") ~= nil and drawn("svatba.02_init_blacksmith") ~= nil)
check("(a) no waiting row under an open prompt", drawn("WAITING FOR PEER") == nil)
local before = #CMDS
press("kcd2mp_dice_bank")
check("(a) F11 fired exactly the prompted beat", countCmds("wh_concept_HasteTrigger svatba.02_init_blacksmith", before) == 1 and #CMDS == before + 1, CMDS[#CMDS])
check("(a) the beat is now spent", Q.fired["svatba.02_init_blacksmith"] == true)
check("(a) quest_catchup begin event went out", countEvt("quest_catchup", "begin svatba.02_init_blacksmith") == 1)
check("(a) prompt cleared, window open", Q.prompt == nil and Q.catchup ~= nil)
noErrs("(a)")

-- hint picks a specific beat
resetQuest()
KCD2MP_QuestSetCurrent("socky")
r = diverge("behind", "svatba", "svatba: x", "socky: y", "svatba.03_init_concubine")
check("(a) approach hint selects that beat", r == "prompt" and Q.prompt and Q.prompt.beat == "svatba.03_init_concubine", Q.prompt and Q.prompt.beat)
check("(a) pick reason logged as hint", lastLog("QUEST-DIVERGENCE #") ~= nil and lastLog("QUEST-DIVERGENCE #"):find("peer approach hint", 1, true) ~= nil)
-- a hint for another quest is ignored
resetQuest()
KCD2MP_QuestSetCurrent("socky")
r = diverge("behind", "svatba", "svatba: x", "socky: y", "socky._initAndStart")
check("(a) a hint outside the peer's quest is ignored", r == "prompt" and Q.prompt and Q.prompt.beat == "svatba.02_init_blacksmith")
-- the peer's live position picks the nearest beat
resetQuest()
KCD2MP_QuestSetCurrent("socky")
ENTS["ttac_blacksmith"] = ent(500, 500, 0)
ENTS["tvez_concubine"]  = ent(100, 100, 0)
KCD2MP.ghosts["7"] = { entity = ent(110, 100, 0) }
r = diverge("behind", "svatba", "svatba: x", "socky: y")
check("(a) the peer's ghost position picks the nearest beat", r == "prompt" and Q.prompt and Q.prompt.beat == "svatba.03_init_concubine", Q.prompt and Q.prompt.beat)
check("(a) pick reason logged with a distance", lastLog("QUEST-DIVERGENCE #"):find("nearest to the peer", 1, true) ~= nil)
noErrs("(a) picks")

-- ---------------------------------------------------------------------------
-- (b) divergence, nothing to offer -> WAITING_FOR_PEER
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
local l0 = #LOG
r = diverge("behind", "socky", "socky: nos pytle 05", "socky: rekni ptackovi o pr")
check("(b) returns waiting", r == "waiting", r)
check("(b) no prompt", Q.prompt == nil)
check("(b) waiting entry exists for the peer, rel behind", Q.waiting["7"] ~= nil and Q.waiting["7"].rel == "behind")
check("(b) reason: same quest, ordinary play", Q.waiting["7"].why:find("same quest", 1, true) ~= nil, Q.waiting["7"].why)
check("(b) WAITING_FOR_PEER entered logged once", countLog("WAITING_FOR_PEER entered", l0) == 1)
check("(b) exactly one toast, naming the peer as ahead", #TOASTS == 1 and TOASTS[1]:find("Joiner is ahead of you", 1, true) ~= nil, TOASTS[1])
draw()
local row = drawn("WAITING FOR PEER")
check("(b) status row drawn", row ~= nil)
check("(b) row names who is ahead and both objectives", row and row.text:find("Joiner is ahead", 1, true) and row.text:find("nos pytle 05", 1, true) and row.text:find("rekni ptackovi", 1, true))
check("(b) no console command issued", #CMDS == 0)
noErrs("(b)")

-- ---------------------------------------------------------------------------
-- (c) exit on convergence
-- ---------------------------------------------------------------------------
l0 = #LOG
KCD2MP_QuestConverged("7")
check("(c) waiting cleared on convergence", Q.waiting["7"] == nil)
check("(c) exit logged (converged)", countLog("WAITING_FOR_PEER exit (converged)", l0) == 1)
draw()
check("(c) row gone", drawn("WAITING FOR PEER") == nil)
noErrs("(c)")

-- ---------------------------------------------------------------------------
-- (d) exit on peer disconnect
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
diverge("behind", "socky", "socky: a", "socky: b")
check("(d) waiting entered", Q.waiting["7"] ~= nil)
l0 = #LOG
KCD2MP_QuestPromptMoot("peer left", "7")
check("(d) waiting cleared when the peer leaves", Q.waiting["7"] == nil)
check("(d) exit logged (peer left)", countLog("WAITING_FOR_PEER exit (peer left)", l0) == 1)
-- another peer's waiting is untouched
diverge("behind", "socky", "socky: a", "socky: b", "", "9", "Third")
KCD2MP_QuestPromptMoot("peer left", "7")
check("(d) another peer's waiting is untouched by an unrelated disconnect", Q.waiting["9"] ~= nil)
noErrs("(d)")

-- ---------------------------------------------------------------------------
-- (e) debounce
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
r = diverge("behind", "svatba", "svatba: x", "socky: y")
check("(e) first divergence prompts", r == "prompt")
local shownAt = NOW
-- repeated agent calls while the prompt is up: one prompt
local n0 = countLog("QUEST-PROMPT shown")
diverge("behind", "svatba", "svatba: x", "socky: y")
diverge("behind", "svatba", "svatba: x", "socky: y")
check("(e) repeated divergence while the prompt is up adds no prompt", countLog("QUEST-PROMPT shown") == n0 and Q.prompt ~= nil)
-- pair converges, then diverges again 10 s later
KCD2MP_QuestConverged("7")
check("(e) prompt withdrawn on convergence", Q.prompt == nil)
NOW = shownAt + 10
r = diverge("behind", "svatba", "svatba: x2", "socky: y")
check("(e) inside the gap: deferred, not prompted", r == "deferred" and Q.prompt == nil, r)
check("(e) deferred offer sits in the waiting row", Q.waiting["7"] ~= nil and Q.waiting["7"].pendingBeat == "svatba.02_init_blacksmith")
check("(e) deferral logged with the remaining seconds", lastLog("deferred") ~= nil and lastLog("deferred"):find("50s", 1, true) ~= nil, lastLog("deferred"))
draw()
check("(e) row explains the cooling down", drawn("cooling down") ~= nil)
-- 40 more seconds: still nothing
for i = 1, 40 do second() end
check("(e) 50 s after the prompt: still no re-prompt", Q.prompt == nil)
-- past the gap: the tick raises it
for i = 1, 11 do second() end
check("(e) 61 s after the prompt: the deferred offer is raised by the tick", Q.prompt ~= nil and Q.prompt.beat == "svatba.02_init_blacksmith", Q.prompt and Q.prompt.beat)
check("(e) the waiting entry was replaced by the prompt", Q.waiting["7"] == nil)
check("(e) exactly two prompts in the whole scenario", countLog("QUEST-PROMPT shown") == n0 + 1)
noErrs("(e)")

-- ---------------------------------------------------------------------------
-- (f) update in place
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
diverge("behind", "socky", "socky: nos pytle 05", "socky: rekni ptackovi")
check("(f) entered", Q.waiting["7"] ~= nil and #TOASTS == 1)
l0 = #LOG
diverge("behind", "socky", "socky: bran ptacka", "socky: rekni ptackovi")
check("(f) same rel, new objective: updated in place", Q.waiting["7"].peerObj == "socky: bran ptacka" and countLog("WAITING_FOR_PEER updated", l0) == 1)
check("(f) no new toast for an in-place update", #TOASTS == 1, #TOASTS)
check("(f) since is kept from the first entry", Q.waiting["7"].since <= NOW)
draw()
check("(f) row shows the new objective", drawn("bran ptacka") ~= nil)
-- identical call again: silent
l0 = #LOG
diverge("behind", "socky", "socky: bran ptacka", "socky: rekni ptackovi")
check("(f) an identical pair logs nothing new", countLog("WAITING_FOR_PEER", l0) == 0)
-- who-is-ahead flips: toast again
diverge("ahead", "socky", "socky: bran ptacka", "socky: rekni ptackovi")
check("(f) a changed rel toasts again", #TOASTS == 2 and TOASTS[2]:find("behind you", 1, true) ~= nil, TOASTS[2])
noErrs("(f)")

-- ---------------------------------------------------------------------------
-- (g) decline
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("prepadeni")
r = diverge("behind", "socky", "socky: x", "prepadeni: y")
check("(g) prompt for socky's beat", r == "prompt" and Q.prompt.beat == "socky._initAndStart")
press("kcd2mp_dice_yield")
check("(g) F12 declined, remembered", Q.prompt == nil and Q.declined["socky._initAndStart"] == true)
check("(g) decline event logged, no command", countEvt("quest_catchup", "decline socky._initAndStart") == 1 and #CMDS == 0)
NOW = NOW + 120
r = diverge("behind", "socky", "socky: x2", "prepadeni: y")
check("(g) next divergence goes to waiting, not a prompt", r == "waiting" and Q.prompt == nil, r)
check("(g) reason names declined", Q.waiting["7"].why:find("declined", 1, true) ~= nil, Q.waiting["7"].why)
noErrs("(g)")

-- ---------------------------------------------------------------------------
-- (h) spent
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("prepadeni")
r = diverge("behind", "socky", "socky: x", "prepadeni: y")
press("kcd2mp_dice_bank")
check("(h) F11 fired socky._initAndStart", countCmds("wh_concept_HasteTrigger socky._initAndStart") == 1)
KCD2MP_QuestConverged("7")
NOW = NOW + 200
Q.catchup = nil
r = diverge("behind", "socky", "socky: x2", "prepadeni: y")
check("(h) a spent beat is not offered again", r == "waiting" and Q.prompt == nil, r)
check("(h) reason says already used", Q.waiting["7"].why:find("already used", 1, true) ~= nil, Q.waiting["7"].why)
check("(h) no second command", countCmds("wh_concept_HasteTrigger") == 1)
-- the direct ShowPrompt path refuses it too
check("(h) ShowPrompt refuses a spent beat", KCD2MP_QuestShowPrompt("7", "Joiner", "socky._initAndStart", 1) == false and lastLog("spent") ~= nil)
noErrs("(h)")

-- ---------------------------------------------------------------------------
-- (i) prologue
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("prepadeni")
r = diverge("unknown", "zachrana", "zachrana: x", "prepadeni: y")
check("(i) M01 vs M02, agent unknown: order says we are behind", r == "waiting" and Q.waiting["7"].rel == "behind", Q.waiting["7"] and Q.waiting["7"].rel)
check("(i) reason: no fireable beat", Q.waiting["7"].why:find("no fireable beat", 1, true) ~= nil, Q.waiting["7"].why)
check("(i) no prompt, no command", Q.prompt == nil and #CMDS == 0)
check("(i) one toast", #TOASTS == 1)
KCD2MP_QuestConverged("7")
-- the other way round
KCD2MP_QuestSetCurrent("zachrana")
r = diverge("unknown", "prepadeni", "prepadeni: x", "zachrana: y")
check("(i) M02 vs M01: we are ahead", r == "waiting" and Q.waiting["7"].rel == "ahead")
noErrs("(i)")

-- ---------------------------------------------------------------------------
-- (j) ahead
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("svatba")
r = diverge("ahead", "socky", "socky: x", "svatba: y")
check("(j) ahead: waiting, no prompt", r == "waiting" and Q.prompt == nil)
draw()
check("(j) row says the peer is behind you", drawn("Joiner is behind you") ~= nil)
check("(j) no command", #CMDS == 0)
noErrs("(j)")

-- ---------------------------------------------------------------------------
-- (k) cannot tell
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
r = diverge("unknown", "socky", "socky: x", "socky: y")
check("(k) same quest, unknown: waiting with rel unknown", r == "waiting" and Q.waiting["7"].rel == "unknown")
draw()
check("(k) row reads STORY DIVERGED", drawn("STORY DIVERGED") ~= nil)
noErrs("(k)")

-- ---------------------------------------------------------------------------
-- (l) F12 hides; F11 alone does nothing
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
diverge("behind", "socky", "socky: a", "socky: b")
draw()
check("(l) row visible", drawn("WAITING FOR PEER") ~= nil)
before = #CMDS
press("kcd2mp_dice_bank")
check("(l) F11 with no prompt issues nothing", #CMDS == before and Q.catchup == nil)
press("kcd2mp_dice_yield")
check("(l) F12 hides the row", Q.waiting["7"].dismissed == true)
draw()
check("(l) row not drawn while hidden", drawn("WAITING FOR PEER") == nil)
check("(l) hide logged", lastLog("hidden by the player") ~= nil)
diverge("behind", "socky", "socky: a", "socky: b")
check("(l) the same pair stays hidden", Q.waiting["7"].dismissed == true)
diverge("behind", "socky", "socky: c", "socky: b")
draw()
check("(l) a changed pair shows the row again", Q.waiting["7"].dismissed == false and drawn("WAITING FOR PEER") ~= nil)
-- mp_quest_hide does the same
KCD2MP_QuestWaitingDismiss()
draw()
check("(l) mp_quest_hide hides too", drawn("WAITING FOR PEER") == nil)
noErrs("(l)")

-- ---------------------------------------------------------------------------
-- (m) peer quest outside the registry
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
r = diverge("behind", "hledanipsa", "hledanipsa: x", "socky: y")
check("(m) side quest peer: waiting, not a prompt", r == "waiting" and Q.prompt == nil, r)
check("(m) reason names the registry", Q.waiting["7"].why:find("registry", 1, true) ~= nil, Q.waiting["7"].why)
noErrs("(m)")

-- ---------------------------------------------------------------------------
-- (n) mp_quest_off
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
KCD2MP_QuestSetSync("off")
r = diverge("behind", "svatba", "svatba: x", "socky: y")
check("(n) off: divergence ignored", r == "off" and Q.prompt == nil and Q.waiting["7"] == nil, r)
draw()
check("(n) nothing drawn", #DRAWS == 0)
KCD2MP_QuestSetSync("on")
noErrs("(n)")

-- ---------------------------------------------------------------------------
-- (p) the 2026-09-13 host, replayed
-- ---------------------------------------------------------------------------
resetQuest()
KCD2MP_QuestSetCurrent("socky")
-- 16:12 the joiner advanced first inside socky and the host fired F11 for
-- socky._initAndStart (under the new rule the same-quest step would have
-- waited; we still mark the beat spent as it was that night).
Q.fired["socky._initAndStart"] = true
-- 16:23 joiner: the sacks. Host stuck on "rekni ptackovi".
l0 = #LOG
r = diverge("behind", "socky", "socky: nos pytle 05", "socky: rekni ptackovi o pr")
check("(p) 16:23 sacks: WAITING_FOR_PEER names the joiner as ahead", r == "waiting" and Q.waiting["7"].rel == "behind")
check("(p) one toast", #TOASTS == 1 and TOASTS[1]:find("nos pytle 05", 1, true) ~= nil)
draw()
check("(p) row: joiner is ahead on the sacks, host on rekni ptackovi", drawn("Joiner is ahead") ~= nil and drawn("nos pytle 05") ~= nil)
-- 16:27 joiner: bran ptacka
diverge("behind", "socky", "socky: bran ptacka", "socky: rekni ptackovi o pr")
check("(p) 16:27 bran ptacka: updated in place, still one toast", Q.waiting["7"].peerObj == "socky: bran ptacka" and #TOASTS == 1)
-- 16:33 joiner leaves M03 for M05 (svatba)
r = diverge("behind", "svatba", "svatba: x", "socky: rekni ptackovi o pr")
check("(p) 16:33 joiner in M05: the offer returns for svatba's beat", r == "prompt" and Q.prompt and Q.prompt.beat == "svatba.02_init_blacksmith", r)
check("(p) the waiting row is replaced by the prompt", Q.waiting["7"] == nil)
check("(p) no command fired without the player's F11", #CMDS == 0)
noErrs("(p)")

-- ---------------------------------------------------------------------------
-- (o) nothing pauses; only wh_concept_HasteTrigger; the game's handler ran
-- ---------------------------------------------------------------------------
local bad = {}
for _, c in ipairs(ALLCMDS) do
    local lc = c:lower()
    if lc:find("t_scale", 1, true) or lc:find("pause", 1, true) or lc:find("freeze", 1, true) or lc:find("g_dialog", 1, true) then bad[#bad + 1] = c end
    if not lc:find("^wh_concept_hastetrigger ") then bad[#bad + 1] = c end
end
check("(o) no time-scale, pause, freeze or dialogue command on any path", #bad == 0, bad[1])
check("(o) the only console command ever issued is wh_concept_HasteTrigger", #bad == 0, #ALLCMDS .. " commands")
check("(o) the game's own OnAction handler ran for every press and release", PRESSES >= 5 and ORIG_ONACTION_CALLS == PRESSES * 2, ORIG_ONACTION_CALLS .. " calls for " .. PRESSES .. " presses")

OUT = table.concat(RESULTS, "\n")
