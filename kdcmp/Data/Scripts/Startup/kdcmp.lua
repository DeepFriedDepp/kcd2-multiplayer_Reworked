-- KCD2 Multiplayer - Mod Init Script
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = {}

-- WO-50: release default is the debug HUD (build/memory/FPS corner block)
-- OFF. This is a mod-side CVar override, reasserted on every mod load,
-- not an engine config file -- it does not touch the base game's own
-- system.cfg/autoexec.cfg, and survives whatever CryEngine or the Modding
-- Tools build shipped as ITS default (observed live as r_DisplayInfo=3).
-- Deliberately unrelated to the ping/network indicator, which is the
-- mod's own System.DrawText call elsewhere in this file and is not an
-- engine overlay at all -- toggling this never touches it.
-- `mp_debug_hud on|off` flips it live without a rebuild, same pattern as
-- mp_dice_gate below.
KCD2MP.debugHud = false
if not KCD2MP.debugHud then
    System.SetCVar("r_DisplayInfo", "0")
end
KCD2MP.running = false
KCD2MP.interpRunning = false
KCD2MP.tickCount = 0
KCD2MP.ghosts = {}
KCD2MP.ghostNames = {}          -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ steam name (received via 0x03 Name packet from server)
KCD2MP.ghostInMenu = {}         -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ true while that player has a menu open (WO-13, set by agent on 0x1D)

-- ===== Shared player combat (WO-28) =====
-- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ {h, s, flags, at}  the OWNER's own authoritative health/stamina, set by
-- the agent from a PlayerStateDown (0x20). Rendered, never computed here: a
-- player's health is authoritative on that player's own machine, and that is
-- the only rule about it that cannot produce a disagreement which fails to
-- self-correct (docs/WO-26-shared-combat-design.md s3, Rule 1).
KCD2MP.ghostHealth = {}
KCD2MP.ghostDead = {}           -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ true after a PlayerDeathDown (0x24); idempotent

-- Flow B damage sensor. id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ last sampled LOCAL health of that ghost entity in
-- THIS world, and a one-shot skip flag set whenever an inbound authoritative
-- value is written over it. Only ever populated while KCD2MP.hitSensorOn.
KCD2MP.ghostHpSeen = {}
KCD2MP.ghostHpSkip = {}

-- Rule 2: only ONE client's NPC simulation may generate NPCÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢player hits, or N
-- peers produce N independent damage streams for one conceptual fight and the
-- damage multiplies by N. The relay designates that client and the agent sets
-- this from a CombatRole (0x25) packet. Off until told otherwise -- a client
-- that has not been told it holds authority must never assume it does.
KCD2MP.hitSensorOn = false
KCD2MP.labelCache = {}          -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ {x,y,z,size,name}  updated by interp, drawn by render loop
KCD2MP.labelRunning = false
KCD2MP.horseGhosts = {}         -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ {entity, entityId, isWorldHorse, worldName} horse per player
KCD2MP.ghostHorseName = {}      -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ authored name of the horse that player is riding (WO-38 Phase 5, via 0x2B); "" / absent = unknown
KCD2MP._mountedHorseName = nil  -- authored name of the horse the LOCAL player is on (riding check, Method 0)
KCD2MP.horseAdoptEnabled = true -- WO-40 Phase 0: mp_horse_adopt on|off -- field escape hatch for the mount-crash suspect (off = proxy horses only)
-- WO-40 Phase 9: ghosts are stimulus-deaf BY DEFAULT now. The chain that
-- earned this: WO-38 recommended it (a ghost has no player behind its
-- reactions; every stimulus response is noise), WO-39 live-verified
-- AI.SetIgnorant is targeting-safe (an ignorant ghost stays hittable and
-- still fights back when attacked -- damage response is not a stimulus), and
-- the 2026-08-18 footage showed the cost of leaving it off: a pickpocketed
-- ghost's brain drew a sword and stayed PERSISTENTLY hostile to the other
-- player while its owner sat in a menu. mp_ghost_ignorant off restores the
-- old behaviour.
KCD2MP.ghostsIgnorant = true
-- WO-65: ghost civic isolation (default on). What it actually does on THIS
-- build is the dialog half only -- RestrictDialog + InterruptDialogs, both
-- live-verified 2026-08-27. The script-context half (the real crime fix) has
-- no Lua-reachable setter here; see KCD2MP_ApplyGhostIsolation.
KCD2MP.ghostIsolate = true
-- WO-100.5 Phase 0: spawn ghosts as NPC_NAI (the shipped "NPC, no AI" class)
-- instead of NPC. A ghost is the body representing the REMOTE player on this
-- machine; spawning it as NPC gives it a local brain, and that brain
-- improvises (WO-26: it engages reactively with no toggle). That is the other
-- player's body acting without the other player -- a desync source, not a
-- feature -- and it is the local writer in WO-98's sub-metre tug-of-war
-- against the position stream.
--
-- NPC_NAI keeps the same Mannequin controller def, the same animation
-- database, the same body and clothing config, and still takes a soul and a
-- faction (diff against NPC.lua, WO-100 S5.2; live-confirmed WO-100 S10.6 --
-- it spawns, is a full actor with a soul, and has its own action controller
-- sharing the player's tag definition object).
--
-- What it loses, and the reason this is a toggle rather than a constant:
-- bWH_PerceptibleObject is gone, so other NPCs may not perceive it at all.
-- Off restores the NPC class exactly.
--
-- NOTE: there is no NPC_NAI_Female in this build (code-verified: WHGame.dll
-- carries only NPC_Female and NPC_NAI). Since WO-69 the roster is male-only
-- and KCD2MP_PickFaceForPlayer always returns "NPC", so the swap is total
-- today -- but a future female roster entry must NOT be swapped.
KCD2MP.ghostNai = false
-- WO-100.5 Phase 0, LIVE 2026-09-17: the better lever, found by testing the
-- class swap above and watching it fail.
--
-- XGenAIModule.SpawnEntity takes a NoAI parameter (it is in Warhorse's own
-- shipped scriptbind doc for SpawnEntity, alongside Name/ClassName/
-- SharedSoulGuid/SchedulerProxyName -- the same doc WO-22 read the flat-table
-- shape out of). Passing NoAI=true keeps EVERYTHING the class swap threw away:
--
--   * the entity class stays NPC, so bWH_PerceptibleObject is present and the
--     body is a real hit target. Live tally of the engine's own
--     "Skirmish event: HitTarget on Dude (target X)" lines across one session:
--         NPC + NoAI=true   7 hits registered
--         NPC               2
--         NPC_NAI           0    -- despite "a shitload of hits" landed
--     An NPC_NAI body is not merely imperceptible; the skirmish system never
--     books a hit on it at all. A nearby ordinary NPC DID witness and report
--     an assault on the NoAI body (SVEDEK_BEZI_HLASIT / SVEDEK_REPORTUJE_
--     STRAZI), so it remains a crime victim -- WO-68's ghost-as-crime-victim
--     behaviour survives.
--   * the soul binds, because this is still the XGenAI path. The class swap
--     could not have both: XGenAIModule.SpawnEntity silently builds NPC
--     whatever ClassName says (observed 3x, with and without NoAI), and
--     System.SpawnEntity honours the class but does not bind SharedSoulGuid
--     (WO-22). Class or soul, never both.
--
-- and it still removes the brain: zero SituationController registrations, zero
-- npc_basic_scheduler behaviour-tree lines, zero self-initiated dialogue, and
-- the engine's own "'<name>': no valid reaction found" when hit.
--
-- DEFAULT OFF. It is a real behaviour change on every ghost and the thing it
-- is meant to fix -- WO-98's sub-metre tug-of-war -- can only be measured with
-- two machines. Turning it on also gives up WO-26's reactive self-defence,
-- which is a product decision, not a technical one. Field runbook:
-- docs/WO-100.5-findings.md S5.
KCD2MP.ghostNoAi = false

-- ===== WO-100.5 Phase 2: the continuous body-state channel =====
--
-- Until now a ghost's animation was INFERRED here, from the distance between
-- consecutive position packets (calcAnimTag on istate.smoothedSpeed). That is a
-- guess about what the other player is doing, made from the only signal we had.
-- The peer now sends what their body is ACTUALLY doing: the live Mannequin
-- MoveSpeed / MoveDir / Stance tags, read natively (WO-100 Phase 0, live-verified
-- 286 tags, unknownTags=0) and carried as five bytes behind Position flag 0x04.
--
-- mp_anim_legacy_on restores the inference. Default OFF -- i.e. the new path is
-- the one that runs -- and it is fail-closed rather than trusting: a packet with
-- no body state, an older peer, or a pace this build cannot name all fall
-- straight back to calcAnimTag for that sample. Nothing waits on a probe.
KCD2MP.animLegacy = false

-- The wire vocabulary. MIRRORED, BY NUMBER, in
--   native/KCDMP/mannequin_read.h        (kPace* / kDir* / kStance*)
--   dotnet/KcdMp.Protocol/Protocol.cs    (BodyPace / BodyDir / BodyStance)
-- All three change together. These are ORDINAL -> NAME: the wire carries our
-- ordinal, and the name is what this build matches on, because a CryEngine
-- TagID is a position in a CTagDefinition rebuilt from XML per build and is
-- exactly the table index WO-100 S6.5's rule keeps off the wire.
--
-- A nil here is a SPECIFIC rejection -- an ordinal this build has no name for --
-- counted as KCD2MP._animUnknown and logged once per distinct value, never
-- silently treated as some other tag.
KCD2MP.bodyPaceName   = { [0]="none", [1]="walk", [2]="run", [3]="sprint", [4]="dash", [5]="steps" }
KCD2MP.bodyDirName    = { [0]="none", [1]="forward", [2]="backward", [3]="left", [4]="right" }
KCD2MP.bodyStanceName = { [0]="upright", [1]="stealth", [2]="sitting", [3]="lying",
                          [4]="horse", [5]="leaning", [6]="other" }
KCD2MP._animUnknown   = {}   -- "pace=9" -> true, so each unknown ordinal logs once
KCD2MP._animStats     = { applied = 0, legacy = 0, noBody = 0, rejected = 0 }

KCD2MP._horseInfoSentName = nil -- last horse_info payload actually emitted (change gate)
KCD2MP._horseInfoSentAt = 0     -- for the 30s re-emit while mounted (late joiners)
KCD2MP.workingClass = "AnimObject"
KCD2MP.playerSneaking = false   -- set by OnAction hook when sneak key pressed
KCD2MP.isRiding = false         -- updated each interp tick (player on horse detection)
KCD2MP.logActions = false       -- set true only to discover action names (floods log)

-- ===== Combat visibility (WO-39 Phase 1) =====
-- The WO-38 Phase 4 gap: nothing combat-shaped was ever shared, so a fighting
-- player's ghost stood motionless with arms down. Outbound: the local weapon
-- drawn/sheathed state (polled from Human.IsWeaponDrawn) and swing/block
-- inputs (OnAction hook) ride the event line as "combat <word>"; the agent
-- puts them on the wire as CombatEventUp (0x2C). Inbound: KCD2MP_GhostCombat
-- applies them to the ghost -- DrawWeapon/HolsterWeapon plus one-shot
-- animations. Cosmetic only: no damage flows through this path.
KCD2MP.weaponDrawn = false      -- local player's last polled drawn state
KCD2MP._weaponPollAt = 0        -- last IsWeaponDrawn poll (throttled to 5 Hz)
KCD2MP._weaponEmitAt = 0        -- last "combat draw" emission (30s heartbeat while drawn)
KCD2MP._weaponReadOk = nil      -- nil=not probed, false=IsWeaponDrawn unavailable, true=working
KCD2MP.ghostWeaponDrawn = {}    -- id ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ true while that peer reports weapon drawn
KCD2MP._lastSwingEmit = 0       -- rate limit for swing event emission
KCD2MP._blockHeld = false       -- edge detector: 'block' only ever fires hold/release

-- WO-17: opt-in, off by default, decided locally per player -- see
-- KCD2MP_EnableAggro. Persists for the session (a plain Lua global survives
-- until the mod restarts); never auto-enabled, never negotiated with a peer.
KCD2MP.aggroEnabled = false

-- ===== Debug Logger =====
-- Messages are queued in KCD2MP.debugLog (max 50).
-- Server polls KCD2MP_PopLog() via evalLua and prints to its console.
KCD2MP.debugLog = {}
local MP_LOG_MAX = 50

local function mp_log(msg)
    local entry = string.format("[%.2f] %s", os.clock(), msg)
    table.insert(KCD2MP.debugLog, entry)
    if #KCD2MP.debugLog > MP_LOG_MAX then
        table.remove(KCD2MP.debugLog, 1)
    end
    -- WO-98 Phase 6: every mod line carries the mod clock as a trailing
    -- field. kcd.log has no wall clock; before this, a mod line's time was
    -- "the nearest [KCD2-MP-DATA] line's t", good to ~26 ms and useless in a
    -- menu (no DATA lines). docs/WO-98-log-format.md.
    System.LogAlways(string.format("[KCD2-MP] %s t=%.3f", msg, os.clock()))
end

-- WO-106 Phase 5: keep every mod-spawned body out of the player's save.
-- ENTITY_FLAG_NO_SAVE is registered as a Lua global on this build (WO-106
-- probe 0.2, live-confirmed = 32768, docs/WO-106-findings.md S1.2) and
-- entity:SetFlags is a scriptbind -- mode 3 = OR (set the bit without
-- disturbing whatever else the engine already set on this entity).
-- Called at every spawn site immediately after the entity resolves.
-- This covers only the REPLICA/GHOST/PROXY body itself -- it does NOT stop
-- a hidden ORIGINAL NPC from being saved as hidden (docs/WO-105-
-- contradictions.md entry 2/4); that half is a separate, harder problem
-- (see the Phase 5 section of docs/WO-106-findings.md) and the periodic
-- reconciliation sweep (WO-84) stays as the mitigation for it.
local function mp_set_no_save(e)
    if not e then return false end
    local ok = false
    pcall(function() e:SetFlags(ENTITY_FLAG_NO_SAVE, 3); ok = true end)
    return ok
end

-- WO-98 Phase 6: session counters for the MP-SUMMARY-MOD line (KCD2MP_LogSummary).
KCD2MP._stats = { toasts = 0, screenRows = 0, keys = 0, cutsceneEdges = 0, npcFightEvents = 0 }

-- WO-98 Phase 6: the one place on-screen text gets logged. The 2026-09-15
-- session's toast text was built at nine call sites and logged at none, so a
-- reported wrong name on screen ("kcd2_tctk"-like) could not be checked
-- against any log. Every toast now leaves an MP-TOAST line with its final
-- string; every persistent DrawText row leaves an MP-SCREEN line when its
-- text CHANGES (and text="" when the row disappears), never per frame.
local function mp_log_text(kind, text)
    KCD2MP._stats.toasts = KCD2MP._stats.toasts + 1
    mp_log(string.format('MP-TOAST kind=%s text="%s"', kind, (tostring(text):gsub('"', "'"))))
end

KCD2MP._screenRows = {}     -- row key -> last logged text
KCD2MP._screenSeen = {}     -- row keys drawn this frame
-- stableText: what gets compared and logged when the drawn text carries a
-- per-second countdown (the invite timer, the catch-up window).
local function mp_draw_row(key, x, y, text, size, stableText)
    text = tostring(text)
    local logText = stableText and tostring(stableText) or text
    KCD2MP._screenSeen[key] = true
    if KCD2MP._screenRows[key] ~= logText then
        KCD2MP._screenRows[key] = logText
        KCD2MP._stats.screenRows = KCD2MP._stats.screenRows + 1
        mp_log(string.format('MP-SCREEN row=%s text="%s"', key, (logText:gsub('"', "'"))))
    end
    System.DrawText(x, y, text, size)
end
-- Called once per frame after the rows are drawn: a row that was logged but
-- not drawn this frame has disappeared.
local function mp_screen_frame_end()
    for key, _ in pairs(KCD2MP._screenRows) do
        if not KCD2MP._screenSeen[key] then
            KCD2MP._screenRows[key] = nil
            mp_log(string.format('MP-SCREEN row=%s text=""', key))
        end
    end
    KCD2MP._screenSeen = {}
end

-- Server calls this via evalLua to dequeue one message at a time
function KCD2MP_PopLog()
    if #KCD2MP.debugLog > 0 then
        return table.remove(KCD2MP.debugLog, 1)
    end
    return ""
end

mp_log("MOD INIT")

-- ===== Math Helpers =====

local function lerpVal(a, b, t)
    return a + (b - a) * t
end

-- Shortest-path angle lerp (radians), handles -pi/pi wrap
local function lerpAngle(a, b, t)
    local diff = b - a
    local twopi = math.pi * 2
    diff = diff - math.floor((diff + math.pi) / twopi) * twopi
    return a + diff * t
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ===== Ping Display =====
-- Called by C# every ~2s after Pong. Stored for render loop to draw via DrawLabel.
-- Game.ShowNotification adds unwanted "@" decorators so we use DrawLabel instead.
function KCD2MP_ShowPing(ms)
    KCD2MP.ping = ms
    local off = KCD2MP.clockOffsetMs
    KCD2MP.pingText = string.format("Ping: %d ms", ms)
        .. (off and string.format("  clock %+.2f s", off / 1000) or "")
end

-- WO-98 Phase 1: the agent's clock-offset estimate (relay clock minus this
-- machine's, ms; the relay runs on the host) and its median RTT. Display and
-- summary only -- nothing here is corrected by it yet.
function KCD2MP_SetClockOffset(ms, rttMs, n)
    KCD2MP.clockOffsetMs = tonumber(ms)
    KCD2MP.clockRttMs = tonumber(rttMs)
    KCD2MP.clockSamples = tonumber(n)
end

-- WO-98 Phase 5: cutscene state. The agent's log tail sees every Rendered/
-- Ingame CutscenePlayer edge on this machine and every peer's (StoryBeat
-- kind 6); nothing in the mod knew a cutscene was playing before this. Used
-- for one thing so far: the readiness prompt is held while a cutscene plays
-- (KCD2MP_QuestOnCutscene) -- the 2026-09-15 joiner pressed F11 during a
-- cutscene and nothing fired (docs/WO-98-findings.md s5). Nothing is
-- synchronised on it: with ~4.8 s of wall-clock skew between machines, any
-- alignment must wait for the Phase 1 offset to be consumed.
KCD2MP.cutsceneActive = false
KCD2MP.cutsceneName   = nil
KCD2MP.peerCutscene   = {}     -- ghostId (string) -> { active, name }

function KCD2MP_SetCutscene(active, name)
    active = (active == true)
    KCD2MP.cutsceneActive = active
    KCD2MP.cutsceneName = active and tostring(name or "") or nil
    KCD2MP._stats.cutsceneEdges = KCD2MP._stats.cutsceneEdges + 1
    local peers = ""
    for gid, pc in pairs(KCD2MP.peerCutscene) do
        peers = peers .. (peers == "" and "" or ",") .. tostring(gid) .. ":" .. (pc.active and "1" or "0")
    end
    -- The quest layer reacts first so the line records the state AFTER the
    -- edge (a prompt hidden by this cutscene shows as prompt=0 pending=1).
    if KCD2MP_QuestOnCutscene then pcall(KCD2MP_QuestOnCutscene, active) end
    local q = KCD2MP.quest
    mp_log(string.format("MP-CUTSCENE side=local state=%s name=%s peers=%s prompt=%d pending=%d",
        active and "start" or "end", tostring(name or "-"), peers == "" and "-" or peers,
        (q and q.prompt) and 1 or 0, (q and q.pendingPrompt) and 1 or 0))
end

function KCD2MP_SetPeerCutscene(ghostId, active, name)
    KCD2MP.peerCutscene[tostring(ghostId)] = { active = (active == true), name = tostring(name or "") }
end

-- WO-98 Phase 6: one structured line with the session's counters, on
-- disconnect (the agent asks) or from the console (mp_summary).
function KCD2MP_LogSummary(reason)
    local st = KCD2MP._stats
    local ghosts, ghostPackets = 0, 0
    for _, g in pairs(KCD2MP.ghosts or {}) do
        ghosts = ghosts + 1
        if g.istate then ghostPackets = ghostPackets + (g.istate.packetCount or 0) end
    end
    local puppets = 0
    for _ in pairs(KCD2MP.npcPuppets or {}) do puppets = puppets + 1 end
    -- WO-102.5 Phase 1: how many NPCs this client believes it still has
    -- paused, right now -- the number a bundle audit compares against
    -- (auth_pauses - auth_resumes). A mismatch between the two means some
    -- pause was lost track of without a matching resume log line.
    local pausedNow = 0
    for _ in pairs(KCD2MP._npcPaused or {}) do pausedNow = pausedNow + 1 end
    local replicasActive = 0   -- WO-104
    for _ in pairs(KCD2MP._npcReplicas or {}) do replicasActive = replicasActive + 1 end
    local pausePending = 0     -- WO-108
    for _ in pairs(KCD2MP._npcResumePending or {}) do pausePending = pausePending + 1 end
    local q = KCD2MP.quest
    mp_log(string.format("MP-SUMMARY-MOD reason=%s mod_clock_s=%.0f toasts=%d screen_rows=%d keys=%d cutscene_edges=%d"
        .. " ghosts=%d ghost_packets=%d puppets=%d npcfight_events=%d diverge_releases=%d quest_divergences=%d"
        .. " quest_prompts=%d quest_fires=%d clock_offset_ms=%s clock_rtt_ms=%s npc_yields=%d npc_repins=%d"
        .. " auth_acquire=%d auth_release=%d auth_owner_changes=%d auth_model=%s"
        .. " auth_pauses=%d auth_resumes=%d auth_paused_now=%d auth_violations=%d"
        .. " resync_bursts=%d resync_emitted=%d resync_applied=%d resync_moved=%d resync_skipped=%d"
        .. " replica_promotes=%d replica_demotes=%d replica_refused=%d replica_active=%d replica_orphans=%d replica_violations=%d"
        .. " pause_relax=%d pause_gaps=%d pause_reasserts=%d pause_dwell_resumes=%d pause_cancelled=%d pause_pending=%d pause_refused=%d",
        tostring(reason), os.clock(), st.toasts, st.screenRows, st.keys, st.cutsceneEdges,
        ghosts, ghostPackets, puppets, st.npcFightEvents, KCD2MP._npcDivergeN or 0,
        (q and q.divergeN) or 0, (q and q.promptN) or 0, (q and q.fireN) or 0,
        tostring(KCD2MP.clockOffsetMs or "?"), tostring(KCD2MP.clockRttMs or "?"),
        KCD2MP._npcYieldN or 0, KCD2MP._npcRepinN or 0,
        (KCD2MP._authStats or {}).acquire or 0, (KCD2MP._authStats or {}).release or 0,
        (KCD2MP._authStats or {}).ownerChange or 0,
        (KCD2MP.wo102 and KCD2MP.wo102.authorityHost) and "host" or "claim",
        (KCD2MP._authStats or {}).pause or 0, (KCD2MP._authStats or {}).resume or 0, pausedNow,
        (KCD2MP._authStats or {}).violation or 0,
        (KCD2MP._resyncStats or {}).bursts or 0, (KCD2MP._resyncStats or {}).emitted or 0,
        (KCD2MP._resyncStats or {}).applied or 0, (KCD2MP._resyncStats or {}).moved or 0,
        (KCD2MP._resyncStats or {}).skipped or 0,
        (KCD2MP._npcReplicaStats or {}).promote or 0, (KCD2MP._npcReplicaStats or {}).demote or 0,
        (KCD2MP._npcReplicaStats or {}).refused or 0, replicasActive,
        (KCD2MP._npcReplicaStats or {}).orphan or 0, (KCD2MP._npcReplicaStats or {}).violationsOnReplica or 0,
        (KCD2MP._pauseStats or {}).relax or 0, (KCD2MP._pauseStats or {}).gap or 0, (KCD2MP._pauseStats or {}).reassert or 0,
        (KCD2MP._pauseStats or {}).dwellResumes or 0, (KCD2MP._pauseStats or {}).cancelled or 0, pausePending,
        ((KCD2MP._pauseStats or {}).refusedNoPuppet or 0) + ((KCD2MP._pauseStats or {}).refusedAuthority or 0)))
end

-- ===== Player Position =====

function KCD2MP_GetPos()
    if player then
        local pos = player:GetWorldPos()
        if pos then
            System.LogAlways(string.format("[KCD2-MP] pos: x=%.1f y=%.1f z=%.1f", pos.x, pos.y, pos.z))
            return pos
        end
    else
        System.LogAlways("[KCD2-MP] player is nil")
    end
    return nil
end

-- ===== Outbound State Emitter (WO-1) =====
-- The game has no push channel, so the agent used to poll: one HTTP call for
-- position plus two more to stuff yaw and mount state through the sv_servername
-- CVar and read it back. Measured at ~128 ms for one full sample, capping the
-- sync loop at 7.8 samples/s.
--
-- System.LogAlways costs ~20 us per line and kcd.log is readable by an external
-- tailer roughly 45 ms later, so the game can simply push instead. This emits
-- one line per tick; KcdMpClient tails the log. Three round trips become zero
-- and the rate becomes whatever this timer runs at.
--
-- Line format, space separated, fixed field count:
--   [KCD2-MP-DATA] v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
--
--   seq    monotonic, so the tailer can spot drops and reordering
--   clock  os.clock() at emit, so the agent can age the sample
--   flags  bit0 riding, bit1 sneaking, bit2 dead, bit3 unconscious   (2 and 3 are v2)
--
-- The version token is first so the parser can reject anything it does not
-- understand rather than misread it. Bump it on any field change.
--
-- WO-28 Flow A raised this v1 -> v2, appending health and stamina. WO-26
-- Phase 3 measured why: the line carried position, rotation and two booleans,
-- so when a test ghost was killed the player it represented kept playing at
-- full health and no peer had any way to know otherwise.
--
-- The agent parses BOTH versions (LogTailGameTransport). The pak and the agent
-- are separately installed and update independently, so a new agent reading an
-- old pak's v1 lines is an ordinary state, not a broken one: it degrades to
-- "health unknown" rather than rejecting every line.
--
-- Death rides here as a flag bit rather than as its own event line because the
-- emitter already runs at ~50 Hz and this costs nothing. It is still the
-- *dying player's own client* that declares the death on the wire (Protocol
-- 0x23) -- a peer never infers it from the health field reaching zero.
KCD2MP.emitRunning = false
KCD2MP.emitSeq = 0
KCD2MP.emitIntervalMs = 20

local EMIT_VERSION = "v2"

-- -1 = "no reading available", never a fake zero. Mirrors Protocol.UnknownStat
-- on the agent side; a receiver must be able to tell "this build cannot read
-- stamina" from "that player is exhausted".
local STAT_UNKNOWN = -1

-- Every binding below was enumerated and read live against the running game
-- (2026-08-07) rather than guessed, because the obvious names are wrong here:
--
--   player.actor:GetHealth()          -> 100        (also used by WO-26)
--   player.soul:GetState("stamina")   -> 126.667
--   player.actor:IsDead()             -> false
--   player.actor:IsUnconscious()      -> present on the actor metatable
--
-- and, confirmed NOT to exist on this build, so nothing should reach for them
-- again: player.actor:GetStamina, player.soul:IsDead, player.soul:IsUnconscious,
-- player:IsDead, player.human:IsDead, and GetState("dead"/"unconscious") --
-- the last two return nil rather than erroring, which is the more dangerous
-- shape: a pcall around them succeeds and yields a falsey "not dead" that was
-- never actually measured.
--
-- Reads the local player's own health/stamina/liveness. Every read is pcall'd
-- individually: a binding that disappears in a future patch must degrade one
-- field, not blank the whole state line and stop position sync with it.
function KCD2MP_ReadSelfVitals()
    local health, stamina = STAT_UNKNOWN, STAT_UNKNOWN
    local dead, unconscious = false, false
    if not player then return health, stamina, dead, unconscious end

    if player.actor then
        pcall(function() health = player.actor:GetHealth() end)
        -- Death is read, never derived from health reaching zero: KCD2 has a
        -- real unconscious state distinct from death (WO-22's A1 was an
        -- unending unconsciousness that the knockdown had registered
        -- correctly), so "health is 0" and "dead" are genuinely different
        -- facts and only one of them should make peers see a death.
        pcall(function() dead = player.actor:IsDead() and true or false end)
        pcall(function() unconscious = player.actor:IsUnconscious() and true or false end)
    end

    if player.soul then
        pcall(function()
            local v = player.soul:GetState("stamina")
            if type(v) == "number" then stamina = v end
        end)
    end

    -- Test override (mp_fake_death). Deliberately applied last and only ever
    -- forces "dead" ON: Gate 2 needs a death that peers can observe end to end,
    -- and the only alternative is asking a human to actually die on a real
    -- save. It can never mask a REAL death into looking alive, which is the
    -- one direction that would be dangerous to have in shipped code.
    if KCD2MP.fakeDeadUntil and os.clock() < KCD2MP.fakeDeadUntil then
        dead = true
    end

    return health, stamina, dead, unconscious
end

-- Reports this player as dead for `secs` seconds (default 20), so Flow C can be
-- observed end to end without a real death and a real save reload. Local only:
-- it changes what this client says about itself, which is exactly the thing
-- Rule 1 makes authoritative, so peers react to it identically to a real death.
function KCD2MP_FakeDeath(secs)
    local n = tonumber(secs) or 20
    KCD2MP.fakeDeadUntil = os.clock() + n
    mp_log(string.format("FAKE_DEATH reporting dead for %.0fs", n))
    KCD2MP_ShowInteractionMsg(string.format("Reporting death for %ds (test)", n))
end

-- WO-106 Phase 2: reusable scratch tables for the position-emit path's
-- vector-getter calls (docs/WO-105-cryengine-reference.md S3.2/17.3 --
-- GetWorldPos()/GetWorldAngles() with no argument allocate a fresh Lua
-- table every call; passing one in writes into it instead). One table per
-- call site, file-local, never passed outward -- KCD2MP_EmitState reads
-- pos.x/y/z and ang.z into locals/scalars immediately and never stores or
-- returns either table, so reusing them here is safe.
local EMITSTATE_POS_SCRATCH = {}
local EMITSTATE_ANG_SCRATCH = {}

-- Builds and writes one state line. Returns false when the player is not in a
-- state worth reporting (no world, mid-load).
function KCD2MP_EmitState()
    if not player then return false end

    local pos = nil
    pcall(function() pos = player:GetWorldPos(EMITSTATE_POS_SCRATCH) end)
    if not pos then return false end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles(EMITSTATE_ANG_SCRATCH) end)
    local rotZ = ang and ang.z or 0

    local health, stamina, dead, unconscious = KCD2MP_ReadSelfVitals()

    local flags = 0
    if KCD2MP.isRiding      then flags = flags + 1 end
    if KCD2MP.playerSneaking then flags = flags + 2 end
    if dead                 then flags = flags + 4 end
    if unconscious          then flags = flags + 8 end
    -- WO-94: our own death, edge-detected, inside a catch-up window.
    if dead and not KCD2MP._questDeadEdge and KCD2MP_QuestHazard then
        KCD2MP_QuestHazard("player-death", "the local player is reported dead")
    end
    KCD2MP._questDeadEdge = dead

    -- WO-94: the per-tick teleport watch (live-verified gap: a 19 m Haste
    -- `goto` slipped under the 1 Hz 60 m/s rule). Runs only while a
    -- catch-up window is open; costs one subtraction otherwise.
    if KCD2MP_QuestNotePos then KCD2MP_QuestNotePos(pos.x, pos.y, pos.z) end

    KCD2MP.emitSeq = KCD2MP.emitSeq + 1
    System.LogAlways(string.format("[KCD2-MP-DATA] %s %d %.3f %.3f %.3f %.3f %.4f %d %.2f %.2f",
        EMIT_VERSION, KCD2MP.emitSeq, os.clock(), pos.x, pos.y, pos.z, rotZ, flags, health, stamina))
    return true
end

-- Every *Running flag in this file means "we intended this loop to run", NOT
-- "this loop is running". A save load destroys every pending Script.SetTimer
-- while leaving the globals set, so the flag stays true over a dead chain --
-- and because the Start* functions below early-return on the flag, nothing
-- could ever restart it. Observed live (WO-13): after a save load,
-- emitRunning and interpRunning both read true with ZERO heartbeats and zero
-- emitted frames for as long as you care to wait, and every remote player's
-- ghost stands frozen.
--
-- So each loop stamps a heartbeat, and the Start* functions treat a stale
-- stamp as "not actually running" and restart regardless of the flag.
local TICK_ALIVE_WINDOW = 1.0   -- seconds; all three loops run far faster

local function tickAlive(flag, stamp)
    return flag and stamp and (os.clock() - stamp) < TICK_ALIVE_WINDOW
end

-- WO-78: SUSPENDED IS NOT DEAD. The stale-stamp rule above has a gap the
-- first real two-player session (2026-09-11) measured directly: a menu, the
-- inventory, a DIALOG or a CUTSCENE suspends every Script.SetTimer chain at
-- once while the agent's ExecuteString keeps executing -- so the agent's
-- 2.5 s re-arm (and, for the puppet chain, every inbound packet) found a
-- stale stamp, called the chain dead and started a second one. Then the
-- first one RESUMED. Host: 34 restarts of each of the four re-armed chains
-- (interp/label/emitter/npc-sync), 33 of the 33 non-initial ones directly
-- after a >= 1.0 s stall in the emitter's own os.clock stamps; joiner: one
-- 60 s pillory cutscene produced 24 restarts (= 60 / 2.5) and 14-21
-- concurrent interp chains for the rest of the session (TICK_ALIVE every
-- 0.26-0.38 s against a 5.3-6.6 s single-chain baseline). Save loads reset
-- the count to 1 every time -- those really do kill the timers.
--
-- Lua cannot tell a suspended chain from a dead one by looking at the stamp,
-- because the clock the stamp is compared against keeps running while the
-- timers do not. What it CAN do is ask the timer system itself: arm a
-- one-shot probe and only restart when the probe fires while the stamp is
-- STILL stale. A probe armed during a suspension fires when everything
-- resumes and finds a fresh stamp (no restart); a probe armed after a save
-- load fires into a working timer system and finds no heartbeat (restart).
-- The second hop exists because a resumed chain and the probe come due in
-- the same frame and nothing says which runs first.
--
-- Shared by every chain in this file on purpose: it is liveness plumbing,
-- like tickAlive, not rendering math (WO-70 constraint 1 is about the
-- latter). A chain whose flag is false -- never started, or stopped on
-- purpose (the puppet chain's "no puppets" exit) -- still starts at once.
local CHAIN_PROBE_MS        = 400
local CHAIN_PROBE_SETTLE_MS = 200
local CHAIN_PROBE_REARM_S   = 3.0   -- a probe this old that never fired was itself killed or suspended; arm another
KCD2MP._chainProbe = {}
KCD2MP._chainSuspendedN = 0        -- false restarts this gate has refused (diagnostic)

local function chainMayStart(key, flagField, stampField, restart)
    if tickAlive(KCD2MP[flagField], KCD2MP[stampField]) then return false end
    if not KCD2MP[flagField] or not KCD2MP[stampField] then return true end
    local pr = KCD2MP._chainProbe[key]
    local now = os.clock()
    if pr and pr.deadConfirmed then
        KCD2MP._chainProbe[key] = nil
        return true
    end
    if pr and (now - pr.armedAt) < CHAIN_PROBE_REARM_S then return false end
    local mine = { armedAt = now, staleFor = now - KCD2MP[stampField] }
    KCD2MP._chainProbe[key] = mine
    Script.SetTimer(CHAIN_PROBE_MS, function()
        Script.SetTimer(CHAIN_PROBE_SETTLE_MS, function()
            if KCD2MP._chainProbe[key] ~= mine then return end   -- superseded by a later probe
            if tickAlive(KCD2MP[flagField], KCD2MP[stampField]) then
                KCD2MP._chainProbe[key] = nil
                KCD2MP._chainSuspendedN = (KCD2MP._chainSuspendedN or 0) + 1
                mp_log(string.format(
                    "CHAIN %s was suspended, not dead (stamp %.1fs stale when asked; resumed before the probe) -- restart skipped (#%d)",
                    key, mine.staleFor, KCD2MP._chainSuspendedN))
                if KCD2MP_QuestHazard then KCD2MP_QuestHazard("chain-suspend", string.format("%s chain was suspended (stamp %.1fs stale) -- menu, dialog or cutscene", key, mine.staleFor)) end
                return
            end
            mine.deadConfirmed = true
            KCD2MP._chainDeadRestartAt = os.clock()   -- WO-108: a save load forgets engine NPC suspensions; the pause reconcile re-asserts after this
            mp_log(string.format(
                "CHAIN %s confirmed dead (timers fire, no heartbeat for %.1fs) -- restarting",
                key, os.clock() - (KCD2MP[stampField] or os.clock())))
            restart()
        end)
    end)
    return false
end

-- WO-39 Phase 1, outbound drawn-state half. Rides the emit tick but is
-- throttled to 5 Hz -- a draw/sheathe is a once-in-a-while transition, not a
-- position stream. Human.IsWeaponDrawn() is documented ("return true if human
-- have any weapon set active"); if this build does not actually register it,
-- the read degrades to "drawn-state sync disabled", logged once, and nothing
-- else in the emitter is touched -- the same per-field degradation discipline
-- as KCD2MP_ReadSelfVitals.
function KCD2MP_PollWeaponDrawn()
    if not (player and player.human) then return end
    if KCD2MP._weaponReadOk == false then return end
    local now = os.clock()
    if now - (KCD2MP._weaponPollAt or 0) < 0.2 then return end
    KCD2MP._weaponPollAt = now

    local drawn = nil
    pcall(function()
        if player.human.IsWeaponDrawn then
            drawn = player.human:IsWeaponDrawn() and true or false
        end
    end)
    if drawn == nil then
        KCD2MP._weaponReadOk = false
        mp_log("CombatViz: Human.IsWeaponDrawn unavailable -- drawn-state sync disabled")
        return
    end
    if KCD2MP._weaponReadOk == nil then
        KCD2MP._weaponReadOk = true
        mp_log("CombatViz: IsWeaponDrawn readable, initial=" .. tostring(drawn))
        -- Prime without emitting: a peer's ghost starts sheathed, so only a
        -- drawn initial state is worth announcing.
        KCD2MP.weaponDrawn = drawn
        if drawn then
            KCD2MP._weaponEmitAt = now
            KCD2MP_EmitEvent("combat", "draw")
        end
        return
    end

    if drawn ~= KCD2MP.weaponDrawn then
        KCD2MP.weaponDrawn = drawn
        KCD2MP._weaponEmitAt = now
        KCD2MP_EmitEvent("combat", drawn and "draw" or "sheathe")
    elseif drawn and now - (KCD2MP._weaponEmitAt or 0) >= 30 then
        -- Heartbeat while drawn, so a late joiner converges (the relay is
        -- stateless and replays nothing). Sheathed is the default state and
        -- needs no heartbeat.
        KCD2MP._weaponEmitAt = now
        KCD2MP_EmitEvent("combat", "draw")
    end
end

-- WO-39 Phase 8: skip-kind detection, second route. kcd.log was a confirmed
-- dead end (WO-38 diffed a real bed sleep against a real wait at verbosity 4
-- -- nothing distinguishes them). The bed interaction itself is detectable
-- instead: a usable bed presents a BedTrigger-class entity (observed live,
-- 1.1 m from a player standing at a tavern bed), so "was the player at a bed
-- when the skip started" answers sleep-vs-wait. Polled at 1 Hz on the emit
-- tick; transitions ride the event line so the agent always holds the latest
-- value before any skip marker can arrive.
KCD2MP.bedNear = false
KCD2MP._bedPollAt = 0

function KCD2MP_PollBedNear()
    local now = os.clock()
    if now - (KCD2MP._bedPollAt or 0) < 1.0 then return end
    KCD2MP._bedPollAt = now
    if not player then return end
    local near = false
    pcall(function()
        local pp = player:GetWorldPos()
        local ents = System.GetEntitiesInSphere(pp, 3) or {}
        for _, e in ipairs(ents) do
            if tostring(e.class or "") == "BedTrigger" then near = true; break end
        end
    end)
    if near ~= KCD2MP.bedNear then
        KCD2MP.bedNear = near
        KCD2MP_EmitEvent("bed_near", near and "1" or "0")
    end
end

function KCD2MP_EmitTick()
    if not KCD2MP.emitRunning then return end
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)  -- reschedule FIRST: a Lua error must not kill the stream
    local nowClock = os.clock()

    -- WO-59 Thread D: a frame-rate floor signal, so the next "FPS dropped"
    -- report comes with numbers in the bundle instead of testimony.
    -- Script.SetTimer fires on frames, so each tick's actual delay is
    -- max(emitIntervalMs, frame time): while the game runs faster than
    -- 1000/emitIntervalMs fps the average delta sits at the interval, and
    -- when it runs slower the average delta IS the frame time (15 fps ==
    -- ~67 ms deltas at the 20 ms interval). Logged every 15 s only while
    -- degraded (avg > 2x interval, i.e. below ~25 fps -- quiet on a
    -- healthy-but-modest 30 fps rig), plus one baseline line per 60 s.
    local prev = KCD2MP._emitAliveAt
    if prev then
        local dtMs = (nowClock - prev) * 1000
        local st = KCD2MP._tickStat
        if not st then st = { n = 0, sum = 0, max = 0, winStart = nowClock, baseAt = nowClock }; KCD2MP._tickStat = st end
        st.n, st.sum = st.n + 1, st.sum + dtMs
        if dtMs > st.max then st.max = dtMs end
        if (nowClock - st.winStart) >= 15 and st.n > 0 then
            local avg = st.sum / st.n
            local degraded = avg > KCD2MP.emitIntervalMs * 2.0
            if degraded or (nowClock - st.baseAt) >= 60 then
                System.LogAlways(string.format(
                    "[KCD2-MP] tickstat avg=%.1fms max=%.1fms n=%d interval=%dms%s",
                    avg, st.max, st.n, KCD2MP.emitIntervalMs,
                    degraded and string.format(" DEGRADED (~%.0f fps floor)", 1000 / avg) or ""))
                st.baseAt = nowClock
            end
            st.n, st.sum, st.max, st.winStart = 0, 0, 0, nowClock
        end
    end
    KCD2MP._emitAliveAt = nowClock

    local ok, err = pcall(KCD2MP_EmitState)
    if not ok then
        -- Report once rather than every tick; at 50 Hz a hot error would bury the log.
        if not KCD2MP._emitErrLogged then
            KCD2MP._emitErrLogged = true
            System.LogAlways("[KCD2-MP] EmitTick error: " .. tostring(err))
        end
    end
    pcall(KCD2MP_PollWeaponDrawn)   -- WO-39: throttled internally to 5 Hz
    pcall(KCD2MP_PollBedNear)       -- WO-39 Phase 8: throttled internally to 1 Hz
    if KCD2MP_QuestProximityTick then pcall(KCD2MP_QuestProximityTick) end  -- WO-94: throttled internally to 1 Hz
end

-- intervalMs is optional; the agent passes its configured rate.
function KCD2MP_StartEmitter(intervalMs)
    if intervalMs and intervalMs >= 5 then KCD2MP.emitIntervalMs = intervalMs end
    -- WO-78: probe-confirmed restart (see chainMayStart) -- a menu/dialog/
    -- cutscene suspension no longer counts as death.
    if not chainMayStart("emit", "emitRunning", "_emitAliveAt", function() KCD2MP_StartEmitter() end) then return end
    KCD2MP.emitRunning = true
    KCD2MP._emitAliveAt = os.clock()   -- prime it: the first tick is one interval away
    KCD2MP._emitErrLogged = false
    System.LogAlways("[KCD2-MP] State emitter started (" .. KCD2MP.emitIntervalMs .. "ms)")
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)
end

function KCD2MP_StopEmitter()
    KCD2MP.emitRunning = false
    System.LogAlways("[KCD2-MP] State emitter stopped after " .. KCD2MP.emitSeq .. " lines")
end

-- Legacy name, kept because the 500 ms KCD2MP_Tick calls it. Delegates so there
-- is only ever one [KCD2-MP-DATA] format for the tailer to parse.
function KCD2MP_WritePos()
    return KCD2MP_EmitState()
end

-- ===== Outbound Events (WO-2) =====
-- A second line type on the same log channel, for discrete things the player
-- did rather than continuous state. Accepting an invite has to travel game ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢
-- agent, and the log tail is the only outbound path (no sockets, no io), so it
-- rides here instead of resurrecting the sv_servername CVar hack.
--
--   [KCD2-MP-EVT] v1 <seq> <name> <arg>
--
-- Sequence numbers are separate from the state stream so a dropped position
-- frame cannot be mistaken for a dropped event.
KCD2MP.evtSeq = 0

function KCD2MP_EmitEvent(name, arg)
    KCD2MP.evtSeq = KCD2MP.evtSeq + 1
    System.LogAlways(string.format("[KCD2-MP-EVT] v1 %d %s %s",
        KCD2MP.evtSeq, tostring(name), tostring(arg or "")))
end

-- ===== Interaction Prompt UI (WO-2) =====
-- Drawn from the existing 8 ms label loop via System.DrawText. Game.ShowNotification
-- was already rejected for injecting '@' decorators, and DrawLabel is world-space,
-- so screen-space DrawText is the right tool for a prompt.
KCD2MP.invite = nil            -- {sid, who, kind, shownAt}
KCD2MP.interactionMsg = nil    -- {text, shownAt}
KCD2MP.diceTurn = nil          -- {text} -- optional glanceable hint; the launcher window is the real dice UI

local INVITE_TIMEOUT   = 30    -- matches the relay's invite expiry
local MSG_TIMEOUT      = 5

-- Called by the agent when a peer invites this player. wager (WO-33) is
-- groschen at stake, 0 for none -- shown in the prompt so the player knows
-- what's riding on it before answering, and checked against player.inventory:GetMoney()
-- in KCD2MP_AcceptInvite before an accept is actually sent.
function KCD2MP_ShowInvite(sid, who, kind, wager)
    KCD2MP.invite = { sid = sid, who = tostring(who), kind = tostring(kind),
                       wager = tonumber(wager) or 0, shownAt = os.clock() }
    mp_log("INVITE from " .. tostring(who) .. " (" .. tostring(kind) .. ") session " .. tostring(sid)
        .. " wager=" .. tostring(KCD2MP.invite.wager))
end

function KCD2MP_HideInvite()
    KCD2MP.invite = nil
end

-- Transient feedback: "Declined", "PeerDisconnected", and so on.
function KCD2MP_ShowInteractionMsg(text)
    mp_log_text("msg", text)   -- WO-98 Phase 6
    KCD2MP.interactionMsg = { text = tostring(text), shownAt = os.clock() }
end

function KCD2MP_AcceptInvite()
    if not KCD2MP.invite then
        mp_log("No invite to accept")
        return false
    end

    -- WO-33: refuse locally, before the match ever starts, rather than
    -- discovering mid-game that a loss can't actually be paid. RemoveMoney
    -- itself already refuses to go negative (per the shipped scriptbind docs),
    -- but that's a safety net, not a substitute for telling the player why.
    local wager = KCD2MP.invite.wager or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            mp_log("Cannot accept: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            return false
        end
    end

    KCD2MP_EmitEvent("invite_accept", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Accepted")
    return true
end

function KCD2MP_DeclineInvite()
    if not KCD2MP.invite then return false end
    KCD2MP_EmitEvent("invite_decline", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Declined")
    return true
end

-- WO-9: honest floor for appearance sync. The agent normally polls
-- EquipmentManager.EquippedArmorsByClassId itself (no Lua involved in
-- detection at all -- that read goes straight over the debug REST API), but
-- a player who wants to force it right now rather than wait for the poll or
-- the heartbeat can run this. Same event-channel pattern as invite_accept.
function KCD2MP_SyncAppearance()
    KCD2MP_EmitEvent("appearance_sync", "")
    mp_log("Requested immediate appearance resync")
    KCD2MP_ShowInteractionMsg("Appearance resync requested")
end

-- WO-11: honest floor for pause detection, same idea as KCD2MP_SyncAppearance
-- above. The agent watches kcd.log itself for the menu/inventory/skip-time
-- markers that were confirmed live (docs/WO-11-findings.md) -- no Lua
-- involved in detection there either -- but a tutorial popup and photo mode
-- were never confirmed to emit one, so this lets a player declare "I'm
-- effectively unavailable" by hand regardless of the reason. Toggles: this
-- side has no way to know whether the agent currently considers us paused,
-- so it just flips a manual flag and lets GameBridge OR it with automatic
-- detection.
function KCD2MP_SlowTime()
    KCD2MP_EmitEvent("slow_time_toggle", "")
    mp_log("Requested manual slow-time toggle")
end

-- ===== Time-skip sync (WO-38 Phase 1) =====
-- Day/night synchronisation. Calendar.SetWorldTime is the one Lua world
-- mutation ever verified working in this project (ARCHITECTURE-shared-world.md:
-- +3600 moved the clock exactly one hour, live), and its own scriptbind doc
-- says "Must not be set backwards" -- so every apply here is forward-only.
-- Detection of the local player's own skips lives agent-side (the kcd.log
-- AfterSkipTime markers, WO-11); Lua only answers "what time is it" and
-- applies/announces a peer's resolved skip.

-- A world day is 86,400 world-seconds. Consistent with the live WO-era
-- observation: worldTime 388805 % 86400 = 43205 s = 12.0014 h, matching the
-- hour 12.0015 read in the same probe.
local WORLD_DAY_SECONDS = 86400

-- Called by the agent (skip end, plus a ~10 s poll for the clock-jump
-- watcher). Rides the ordinary event channel.
function KCD2MP_ReportWorldTime()
    local ok, t = pcall(function() return Calendar.GetWorldTime() end)
    if ok and t then
        -- WO-104: NEVER tostring() a world time. This build's Lua formats
        -- numbers with "%g" (observed: 1002550 -> '1.00255e+06' in the
        -- 2026-09-18 session), so past 1e6 world-seconds (~11.6 days of
        -- game time) tostring() switched to scientific notation and the
        -- agent's integer parse rejected every reading -- time sync went
        -- dead on that save permanently. "%.0f" is exact for any integer
        -- that fits a double and never uses an exponent.
        KCD2MP_EmitEvent("time_now", string.format("%.0f", math.floor(t)))
    else
        mp_log("ReportWorldTime: Calendar.GetWorldTime unavailable")
    end
end

-- "8:00 AM" from a worldTime in seconds-from-level-start.
function KCD2MP_FormatWorldTime(t)
    local secOfDay = t % WORLD_DAY_SECONDS
    local h = math.floor(secOfDay / 3600)
    local m = math.floor((secOfDay % 3600) / 60)
    local ampm = (h >= 12) and "PM" or "AM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, ampm)
end

-- Called by the agent when a peer's skip resolves. who = their display name,
-- kind = Protocol.TimeSkipKind* (0 = bed sleep), target = their resulting
-- worldTime, quiet = apply without announcing (a joined skip's own result).
function KCD2MP_ApplyTimeSkip(who, kind, target, quiet)
    target = tonumber(target)
    if not target then return end
    local ok, cur = pcall(function() return Calendar.GetWorldTime() end)
    if not ok or not cur then
        mp_log("ApplyTimeSkip: Calendar.GetWorldTime unavailable")
        return
    end
    if target > cur then
        local ok2, err = pcall(function() Calendar.SetWorldTime(target) end)
        mp_log(string.format("ApplyTimeSkip: %d -> %d (%s)", cur, target,
            ok2 and "written" or ("FAILED " .. tostring(err))))
        if KCD2MP_QuestHazard then KCD2MP_QuestHazard("clock", string.format("world clock written %d -> %d (+%ds) from %s", cur, target, target - cur, tostring(who))) end
        -- WO-59: a quiet apply that moves the clock more than an hour is a
        -- session-convergence jump (connect-time sync across a multi-day
        -- save gap), and silently changing the sky under the player without
        -- a word reads as a bug. One neutral line, no peer attribution.
        if quiet and ok2 and (target - cur) > 3600 then
            KCD2MP_ShowInteractionMsg("Clock synced forward to the session's time ("
                .. KCD2MP_FormatWorldTime(target) .. ")")
        end
    else
        -- Forward-only: already at or past the target (e.g. our own skip
        -- overshot a peer's). Keep our clock; divergence is bounded by the
        -- overshoot, never by hours.
        mp_log(string.format("ApplyTimeSkip: already at %d >= %d, keeping our clock", cur, target))
    end
    if not quiet then
        local verb = (tonumber(kind) == 0) and " slept till " or " passed time to "
        KCD2MP_ShowNativeToast(tostring(who) .. verb .. KCD2MP_FormatWorldTime(target))
    end
end

-- ===== Weather sync (WO-40 Phase 3) =====
-- EnvironmentModule.BlendTimeOfDay(profile, blendDuration, force) is the
-- officially documented weather write (Warhorse's own perf scripts and the
-- debug weather quest use it). There is NO current-profile read, so the
-- session's weather is arbitrated agent-side (damage-authority holder picks
-- and broadcasts); this is just the apply.
function KCD2MP_ApplyWeather(profile, blend)
    profile = tostring(profile or "")
    if profile == "" then return end
    local b = tonumber(blend) or 30
    local ok, err = false, nil
    if EnvironmentModule and EnvironmentModule.BlendTimeOfDay then
        ok, err = pcall(function()
            EnvironmentModule.BlendTimeOfDay(profile, b, true)
        end)
        -- WO-40 live battery: a blend<=1 is a SNAP request (late-join
        -- convergence); ForceImmediateWeatherUpdate is what actually applies
        -- it at once (rain 0 -> 0.82 within seconds, live-verified), while
        -- longer blends complete on their own (rain decayed to ~0 over ~60 s
        -- under blend=30, also live-verified).
        if ok and b <= 1 then
            pcall(function() EnvironmentModule.ForceImmediateWeatherUpdate() end)
            pcall(function() EnvironmentModule.RebuildClouds() end)
        end
    else
        err = "EnvironmentModule.BlendTimeOfDay not registered"
    end
    mp_log("ApplyWeather '" .. profile .. "' blend=" .. tostring(b)
        .. (ok and " (blending)" or (" FAILED: " .. tostring(err))))
end

-- Probe/manual override: mp_weather <profile> sets a profile locally (not
-- broadcast -- this is a probe, not a sync source); bare mp_weather reports
-- the one readable weather value (rain intensity).
function KCD2MP_WeatherCmd(arg)
    local s = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "%LINE" then
        local ok, rain = pcall(function() return EnvironmentModule.GetRainIntensity() end)
        mp_log("Weather: GetRainIntensity=" .. (ok and tostring(rain) or "unavailable")
            .. " (no current-profile read exists on this surface)")
        return
    end
    KCD2MP_ApplyWeather(s, 5)
end

-- The game's own HUD info text -- native KCD2 font, centered, the same
-- surface the dice overlay's say() uses (live-verified there). The user's
-- explicit direction on seeing the DrawText toast live: "I want it in the
-- middle of the screen using the standard KCD2 font... it looks janky being
-- in the top left and is not immersive." DrawText remains the fallback if
-- the UIAction path ever fails.
function KCD2MP_ShowNativeToast(text)
    mp_log_text("native", text)   -- WO-98 Phase 6
    local ok = pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", tostring(text), 10, 5000, true)
    end)
    if not ok then
        KCD2MP_ShowInteractionMsg(text)
    end
end

-- Superseded by the WO-6 dice overlay below, which draws the whole match. Kept
-- as a one-liner so an older agent build talking to a newer pak still puts
-- something on screen instead of erroring.
function KCD2MP_ShowDiceTurn(text)
    if text == nil or text == "" then
        KCD2MP.diceTurn = nil
    else
        KCD2MP.diceTurn = { text = tostring(text) }
    end
end

-- Invites the nearest ghost. Lua picks the target because it already has both
-- the player's position and every ghost's; the agent only knows relay ids.
-- kindStr is "dice" or "duel". wagerAmount (WO-33) is dice-only groschen,
-- ignored for any other kind.
function KCD2MP_InviteNearest(kindStr, wagerAmount)
    kindStr = tostring(kindStr or ""):gsub("%s+", "")
    if kindStr == "" then kindStr = "dice" end
    wagerAmount = tonumber(wagerAmount) or 0

    local ppos = player and player:GetWorldPos()
    if not ppos then return false end

    local bestId, bestD = nil, nil
    for id, g in pairs(KCD2MP.ghosts or {}) do
        if g and g.entity then
            local ok, gp = pcall(function() return g.entity:GetWorldPos() end)
            if ok and gp then
                local d = (gp.x - ppos.x)^2 + (gp.y - ppos.y)^2 + (gp.z - ppos.z)^2
                if not bestD or d < bestD then bestD, bestId = d, id end
            end
        end
    end

    if not bestId then
        mp_log("No other player nearby to invite")
        KCD2MP_ShowInteractionMsg("No player nearby")
        return false
    end

    local payload = tostring(bestId) .. " " .. kindStr
    -- WO-104: %.0f not tostring() -- same 1e6 scientific-notation exposure as
    -- time_now (the agent parses this field with int.TryParse).
    if kindStr == "dice" then payload = payload .. " " .. string.format("%.0f", math.floor(wagerAmount)) end

    mp_log("Inviting ghost " .. tostring(bestId) .. " to " .. kindStr
        .. (kindStr == "dice" and (" wager=" .. tostring(wagerAmount)) or ""))
    KCD2MP_EmitEvent("invite_send", payload)
    KCD2MP_ShowInteractionMsg(wagerAmount > 0 and ("Invite sent (wager " .. wagerAmount .. ")") or "Invite sent")
    return true
end

-- Draws the prompt and any transient message. Called from the label loop, which
-- already runs at 8 ms so text does not flicker between frames.
function KCD2MP_DrawInteractionUI()
    local inv = KCD2MP.invite
    if inv then
        if os.clock() - inv.shownAt > INVITE_TIMEOUT then
            KCD2MP.invite = nil
        else
            local left = math.ceil(INVITE_TIMEOUT - (os.clock() - inv.shownAt))
            local stake = (inv.wager and inv.wager > 0) and ("  for " .. inv.wager .. " groschen") or ""
            local inviteText = inv.who .. " invites you to " .. inv.kind .. stake
            mp_draw_row("invite", 10, 60, inviteText .. "  (" .. left .. "s)", 2, inviteText)
            mp_draw_row("invite_keys", 10, 84, "F11 accept / F12 decline  (or mp_accept / mp_decline)", 1.6)
        end
    end

    local msg = KCD2MP.interactionMsg
    if msg then
        if os.clock() - msg.shownAt > MSG_TIMEOUT then
            KCD2MP.interactionMsg = nil
        else
            mp_draw_row("msg", 10, 110, msg.text, 1.6)
        end
    end

    if KCD2MP.diceTurn then
        mp_draw_row("dice_turn", 10, 134, KCD2MP.diceTurn.text, 1.6)
    end

    -- WO-94: the readiness prompt and the catch-up window, rows 160/184/208.
    if KCD2MP_QuestDrawUI then pcall(KCD2MP_QuestDrawUI) end
    mp_screen_frame_end()   -- WO-98 Phase 6: rows that vanished this frame log text=""
end

-- ============================================================================
-- ===== Dice overlay (WO-6) ==================================================
-- ============================================================================
--
-- The in-game UI for a PvP Farkle match. Replaces the launcher window
-- (KCDMP_launcher/DiceWindow.razor), which is retired -- see docs/WO-6-*.md.
--
-- Renders ONLY what the relay sent. No score, no roll and no turn order is ever
-- computed here; the agent pushes a full DiceState snapshot and this draws it.
-- Same rule DiceClient.cs follows on the C# side.
--
-- The board is HTML pushed into the game's own tutorial panel via
-- UIAction.CallFunction("hud", -1, "ShowTutorial", ...) -- a gilded gothic
-- frame around illuminated parchment, rendered by the game. We supply the
-- markup; Warhorse supplies the art.
--
-- Art direction, palette and the state model are in docs/WO-6-overlay-design.md;
-- what can and cannot be rendered, with the evidence, is in
-- docs/WO-6-visual-capability.md. Read both before changing anything here --
-- most of the obvious ideas have already been tried against the real game and
-- do not work.

KCD2MP.dice = {
    open      = false,

    -- --- how it renders, all established against the real game --------------
    --
    -- The board is an HTML page pushed into the game's own tutorial panel
    -- (hud.ShowTutorial): a gilded gothic frame around illuminated parchment,
    -- rendered by the game itself.
    --
    -- This is the SECOND renderer. The first drew its own panel with
    -- System.Draw2DLine and it rendered NOTHING -- that call is registered,
    -- callable, returns cleanly, and r_enableAuxGeom is already 1, but no line
    -- ever reaches the screen. Only System.DrawText works in screen space, and
    -- plain text was the whole complaint. See docs/WO-6-visual-capability.md
    -- for the full evidence; do not reintroduce Draw2DLine here.
    -- Element id. ShowTutorial QUEUES rather than replaces, so every update is
    -- HideTutorial(id) then ShowTutorial(id, ...); pushing twice without the
    -- hide leaves the second push waiting behind the first. Found the hard way.
    panelId   = "kcd2mp_dice",
    -- The parchment panel IS the whole live board (score, dice, marks) --
    -- see KCD2MP_DiceRender and scheduleRender for how pushes are kept rare
    -- enough not to flicker: immediate on relay-driven state (open, a new
    -- DiceState, error, end), debounced on local rapid-fire input (marking).
    usePanel  = true,
    -- Marks/roll pushes ride the same debounce window so a burst of presses
    -- coalesces into one push instead of one each. See scheduleRender.
    renderDebounceMs = 250,
    -- Safety net, not the intended lifetime: every state change re-pushes, so
    -- the board is normally refreshed long before this expires. Was 120000 (2
    -- minutes) -- too short in practice: a live match hit a real stretch with
    -- no new relay-driven state (the seated-R bug meant no roll was ever sent),
    -- and the card visibly vanished mid-match while the session was still very
    -- much alive on the relay. 30 minutes is generous enough not to intrude on
    -- a legitimately slow human turn while still self-clearing eventually if
    -- this code ever truly stops refreshing. mp_dice_close/mp_dice_flush are
    -- the manual escape hatches if it's ever stuck sooner than that.
    panelMs   = 1800000,

    -- Glyphs VERIFIED renderable in this panel's font library. Everything else
    -- tried came back a tofu box: the Unicode die faces, every box-drawing
    -- character, and all geometric shapes including U+25CF. Worse, a plain
    -- ASCII '|' renders as NOTHING AT ALL -- hence the broken bar.
    pip       = "\226\128\162",   -- U+2022 BULLET
    rule      = "\226\128\148",   -- U+2014 EM DASH
    turnMark  = "\194\187",       -- U+00BB
    sep       = "\194\166",       -- U+00A6 BROKEN BAR
    leader    = "\194\183",       -- U+00B7 MIDDLE DOT

    -- Faces the panel's font library exposes (Libs/UI/fontconfig.xml).
    faceTitle = "DisplayFont",    -- Kingdom Come Display
    faceHand  = "Manuscript",     -- Warhorse Manuscript, a real blackletter hand
    faceBody  = "LightFont",

    -- Transient announcements that suit a line rather than the board.
    -- hud.ShowInfoText is confirmed rendering. hud.ShowDiceScore is confirmed
    -- INERT outside the native minigame, so it is not used at all.
    native    = { modal = false, infotext = true, sting = false },

    -- WO-33: groschen staked on the NEXT invite this client sends, set via
    -- mp_dice_wager. Purely local until it rides the Invite config -- the
    -- relay never computes or holds it, only echoes it back on DiceEnd so
    -- each client can apply it to its own Inventory. 0 = no stake.
    wagerAmount = 0,

    -- --- authoritative state, straight off the wire -------------------------
    role      = 0,             -- OUR SessionRole: 0 initiator, 1 acceptor
    turnRole  = 0,             -- whose turn it is
    target    = 4000,
    phase     = 0,             -- DicePhase: 0 AwaitingRoll, 1 AwaitingKeep
    scores    = { [0] = 0, [1] = 0 },
    turnTotal = 0,
    free      = {},            -- faces still on the board
    kept      = {},            -- faces set aside this turn
    peer      = "opponent",

    -- --- local, non-authoritative -------------------------------------------
    sel       = {},            -- which free dice the player has marked
    hold      = nil,           -- {action, t0} for hold-to-confirm
    outcome   = nil,           -- nil | "win" | "lose"
    err       = nil,           -- {text} from a DiceError
}

local D = KCD2MP.dice

-- Palette, as HTML colours against the panel's parchment. Pulled to KCD2's own
-- register: iron-gall ink, faded ink, candle gold, dried blood.
local COL = {
    ink   = "#2a2018",
    dim   = "#7a6a4f",
    gold  = "#c8a13c",
    -- Was #e8c25c -- too close to the parchment's own lightness to read at a
    -- glance (the live turn total, selected-die marks). Darkened for contrast;
    -- still reads as gold, just no longer washes out against the paper.
    bright= "#96691a",
    blood = "#8a1f14",
    -- Close to the parchment itself -- an "unlit" pip slot. First guess, not
    -- colour-picked from the real texture (no tooling for that); confirm
    -- against a live screenshot and adjust if it reads as too visible or too
    -- invisible.
    faint = "#c9b98f",
}

-- ===== html helpers =========================================================

local NBSP = "&nbsp;"

local function fnt(s, colour, size, face)
    local a = ""
    if face   then a = a .. " face='" .. face .. "'" end
    if size   then a = a .. " size='" .. tostring(size) .. "'" end
    if colour then a = a .. " color='" .. colour .. "'" end
    return "<font" .. a .. ">" .. s .. "</font>"
end

local function rep(s, n)
    local out = ""
    for _ = 1, (n or 0) do out = out .. s end
    return out
end

-- "2 500" -- thousands separated the way a tally board would.
local function groschen(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out, c = "", 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        c = c + 1
        if c % 3 == 0 and i > 1 then out = NBSP .. out end
    end
    return out
end

-- 9, not 13: at 13 the rule wrapped onto a second line and the board grew a
-- row of orphaned dashes after every divider. The panel is narrower than it
-- looks, and its font is proportional, so this is measured against the real
-- thing rather than calculated.
local function ruleLine()
    return fnt(rep(D.rule, 9), COL.dim)
end

-- A name/score row with leader dots between. The panel's font is PROPORTIONAL
-- (verified: "1234567890" and "ABCDEFGHIJ" end at different widths), so the
-- dots cannot align a column exactly -- but leaders are precisely the device
-- that makes an approximate right edge read as intentional.
-- `score` is a NUMBER here, not pre-formatted markup. It used to take the
-- groschen() output and size the leaders with #score -- but that string contains
-- "&nbsp;" entities, so a 4-digit score counted as 10+ characters and the
-- leaders collapsed to the minimum on every row.
local function tallyRow(mark, name, score, colour)
    local digits = #tostring(math.floor(tonumber(score) or 0))
    local budget = 20 - #name - digits
    if budget < 2 then budget = 2 end
    return fnt(mark .. " " .. name .. " " .. rep(D.leader, budget)
               .. " " .. groschen(score), colour)
end

-- ===== dice =================================================================

-- Which of the 3x3 cells carry a pip, per face. Built from BULLET and
-- non-breaking space only: every row of every die uses the same two characters
-- in the same slots, which is what makes the grid line up vertically despite
-- the proportional font (verified in game with a 5 and a 2 side by side).
--
-- NOT the Unicode die faces U+2680..2685 -- those are tofu in this font, as are
-- all box-drawing and geometric shapes. Bullet is what survives.
local PIPCELLS = {
    [1] = { {0,0,0}, {0,1,0}, {0,0,0} },
    [2] = { {1,0,0}, {0,0,0}, {0,0,1} },
    [3] = { {1,0,0}, {0,1,0}, {0,0,1} },
    [4] = { {1,0,1}, {0,0,0}, {1,0,1} },
    [5] = { {1,0,1}, {0,1,0}, {1,0,1} },
    [6] = { {1,0,1}, {1,0,1}, {1,0,1} },
}

-- Three lines of HTML rendering a row of dice side by side.
-- faces: array of 1..6. colours: parallel array of hex, or nil for ink.
--
-- Every cell renders D.pip -- never NBSP. An "unlit" cell is a bullet coloured
-- COL.faint instead of blank space, so every die's row is always exactly three
-- BULLET glyphs wide, whatever the face. Blank space (NBSP) does not render at
-- the same width as a bullet in this proportional font, so a die's rendered
-- width used to depend on how many pips it had (a 1 much narrower than a 6),
-- which is what made the index row drift out from under its die -- no fixed
-- gap can compensate for a per-die width that keeps changing.
--
-- A thin divider (D.sep, the broken bar already proven renderable in the
-- action strip) between dice reads as an actual boundary between two dice,
-- rather than blank space that six 2-character F-key labels (F2..F8) no
-- longer had room for anyway -- fixed a line-wrap the wide all-NBSP gap
-- caused once labels stopped being a single digit.
local GAP = NBSP .. D.sep .. NBSP

local function diceRows(faces, colours)
    local out = { "", "", "" }
    for r = 1, 3 do
        for i, f in ipairs(faces) do
            local cells = PIPCELLS[f] or PIPCELLS[1]
            local dieColour = (colours and colours[i]) or COL.ink
            local s = ""
            for c = 1, 3 do
                local lit = cells[r][c] == 1
                s = s .. fnt(D.pip, lit and dieColour or COL.faint)
            end
            out[r] = out[r] .. s
            if i < #faces then out[r] = out[r] .. GAP end
        end
    end
    return out
end

-- A row under the dice naming the key that marks each one, so the player never
-- has to remember an arbitrary mapping. Shows the real key rather than a plain
-- 1..6 die index now that marking has real keybinds (WO-6) -- the mapping is
-- F2, F4-F8 (F3/F1/F10 are engine debug toggles, skipped), not a clean range,
-- so spelling it out here matters more than it used to. mp_dice_mark still
-- takes the die's POSITION (1-6, left to right), for the console fallback.
--
-- sel (optional) marks a die as selected: its label goes in brackets and gold,
-- matching the gold pips diceRows already gives a selected die above it. No
-- circle/X glyph is used -- the capability doc's verified-renderable set has
-- none (every geometric shape tried came back tofu) -- but '[' ']' are proven
-- safe, they are already used by the action-strip key() labels below.
local DICE_MARK_KEYS = { "F2", "F4", "F5", "F6", "F7", "F8" }

local function indexRow(n, sel)
    local s = ""
    for i = 1, n do
        local marked = sel and sel[i]
        local keyLabel = DICE_MARK_KEYS[i] or tostring(i)
        local label = marked and ("[" .. keyLabel .. "]") or (NBSP .. keyLabel .. NBSP)
        s = s .. fnt(label, marked and COL.bright or COL.dim, 12)
        if i < n then s = s .. GAP end
    end
    return s
end

-- Sizes trimmed from 18/14 -- this panel stacks a lot of rows (title, tally,
-- three pip rows, index row, set-aside, hand total, rules, action strip) and
-- the line spacing scales with font size, so shaving a couple of points off
-- the busiest block buys back real vertical room.
local function diceBlock(faces, colours, numbered, sel)
    if #faces == 0 then
        return fnt(NBSP .. D.leader .. " none " .. D.leader, COL.dim, 16)
    end
    local r = diceRows(faces, colours)
    local h = fnt(r[1] .. "<br/>" .. r[2] .. "<br/>" .. r[3], nil, 15)
    if numbered then h = h .. "<br/>" .. indexRow(#faces, sel) end
    return h
end

-- ===== the board ============================================================

local function buildHtml()
    local mine   = (D.turnRole == D.role) and (D.outcome == nil)
    local myCol  = mine and COL.gold or COL.ink
    local opCol  = (not mine and D.outcome == nil) and COL.gold or COL.ink

    local title = "The Wager"
    if D.outcome == "win"  then title = "Thine!" end
    if D.outcome == "lose" then title = D.peer .. " takes it" end

    local h = fnt(title, (D.outcome == "win") and COL.bright or COL.gold, 26, D.faceTitle)
              .. "<br/>" .. ruleLine() .. "<br/>"

    -- score slip: opponent above, us below, target underneath
    h = h .. tallyRow(mine and NBSP or D.turnMark, D.peer, D.scores[1 - D.role], opCol) .. "<br/>"
    h = h .. tallyRow(mine and D.turnMark or NBSP, "Thou",  D.scores[D.role],     myCol) .. "<br/>"
    h = h .. "<p align='right'>" .. fnt("of " .. groschen(D.target), COL.dim, 16) .. "</p>"

    if D.outcome then
        h = h .. ruleLine() .. "<br/>"
        h = h .. fnt("The wager is settled.", COL.dim, 18) .. "<br/>"
        h = h .. fnt("mp_dice_close", COL.dim, 16)
        return h
    end

    h = h .. ruleLine() .. "<br/>"

    -- the board: free dice, marked ones in bright gold so a pending keep is
    -- obviously reversible before it is sent. No tumble/reveal animation --
    -- a fresh roll just appears with its real faces, per the human's own call
    -- once the panel replaced DrawText: nothing fancy needed for a reroll.
    local faces, cols = {}, {}
    for i, f in ipairs(D.free) do
        faces[i] = f
        cols[i]  = D.sel[i] and COL.bright or COL.ink
    end
    h = h .. fnt("On the board", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(faces, cols, true, D.sel) .. "<br/>"

    -- set aside, in gold: these are locked in and scoring. Not numbered --
    -- there is no command that takes a set-aside die's index, so numbering them
    -- would only invite a keystroke that does nothing.
    local kf, kc = {}, {}
    for i, f in ipairs(D.kept) do kf[i] = f; kc[i] = COL.gold end
    h = h .. fnt("Set aside", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(kf, kc, false) .. "<br/>"

    h = h .. fnt("This hand ", COL.dim, 18)
          .. fnt(groschen(D.turnTotal), (D.turnTotal > 0) and COL.bright or COL.dim, 20) .. "<br/>"
    h = h .. ruleLine() .. "<br/>"

    -- The action strip shows REAL keys. It briefly listed console commands
    -- instead, because the keybinds at that point were unverified guesses and
    -- advertising dead keys reads as broken. The names behind these were
    -- captured from a live game (see DICE_CONFIRM_ACTIONS), so they can be
    -- shown honestly now. The mp_dice_* commands still work and are the
    -- fallback if a key is rebound.
    if D.err then
        h = h .. fnt(D.err.text, COL.blood, 18) .. "<br/>"
    end

    local function key(k, label, hot)
        return fnt("[" .. k .. "] ", hot and COL.gold or COL.dim, 16)
            .. fnt(label, hot and COL.ink or COL.dim, 16)
    end

    if mine then
        if D.phase == 1 then
            h = h .. fnt("key below", COL.gold, 16) .. fnt(" to mark, then ", COL.dim, 16)
                  .. key("F9", "set aside", true) .. "<br/>"
            h = h .. key("U", "clear marks", false) .. "<br/>"
        else
            h = h .. key("F9", "cast", true) .. "<br/>"
        end
        h = h .. key("hold F11", "bank", true) .. fnt("  " .. D.sep .. "  ", COL.dim, 16)
              .. key("hold F12", "yield", false)
    else
        h = h .. fnt(D.peer .. " is casting" .. D.leader .. D.leader .. D.leader, COL.dim, 18)
    end

    return h
end

-- ===== pushing it ===========================================================

-- ShowTutorial is a NOTIFICATION QUEUE, not a panel you can update in place.
-- Two rounds of learning here, both from watching the real thing:
--
--   1. Pushing an update without hiding leaves it waiting BEHIND the current
--      entry, so the board silently stops tracking the match.
--   2. HideTutorial(id) only dismisses the entry being DISPLAYED -- it advances
--      the queue rather than clearing it. Sixteen pushes across one demo match
--      therefore left sixteen queued entries, each asking for a long duration,
--      and the game cycled through them: fade out, fade in, next. On screen that
--      reads as the board flickering and looping forever, long after the match
--      has ended.
--
-- So every push flushes the WHOLE queue first. HideAllTutorials is a blunt
-- instrument -- it will also drop a genuine game tutorial that happens to be
-- showing -- which is accepted only because this runs solely during a PvP dice
-- match the player deliberately started.
--
-- panelMs is a safety net, not the intended lifetime: if this code ever stops
-- refreshing (agent dies, script error), the board expires by itself instead of
-- sitting on screen forever.
-- MEASURED, not assumed: a demo match pushes the panel 24 times in 30 seconds,
-- roughly one every 1.25 s. Each push is HideAllTutorials + ShowTutorial and the
-- panel replays its full fade-out/fade-in every time. That is the "flickering
-- horribly" -- not a loop, and not something queue management can fix.
--
-- ShowTutorial is a NOTIFICATION CARD. There is no in-place text update, so
-- rapid repeated pushes flicker -- but not EVERY push is rapid. A relay-driven
-- DiceState (a roll/keep/bank result) is naturally paced by however long a
-- turn takes; the thing that actually flickered was pushing once per LOCAL
-- mark press too, which can happen several times a second while choosing a
-- keep. So the fix is not "never push the panel", it's "don't push once per
-- keystroke": KCD2MP_DiceRender still pushes immediately for state that's
-- already paced (open, DiceState, DiceError, end); scheduleRender below is
-- what marking uses instead, coalescing a burst of presses into one push.
function KCD2MP_DiceRender()
    if not D.open then return end
    if not D.usePanel then return end
    local ok, html = pcall(buildHtml)
    if not ok then
        mp_log("DICE render error: " .. tostring(html))
        return
    end
    KCD2MP_DiceFlush()
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowTutorial",
            D.panelId, html, D.panelMs, false, 9, 0, false, "")
    end)
end

-- Coalesces bursty local input (marking dice) into one push instead of one
-- per press. Leading-edge: the first call after a quiet period schedules a
-- render renderDebounceMs later; any calls that land inside that window are
-- no-ops, because by the time the scheduled render actually runs it reads
-- whatever D.sel etc. looks like THEN -- which already includes them, since
-- Lua here is single-threaded and D.sel was mutated synchronously by the
-- caller before scheduleRender was ever called.
local renderScheduled = false
local function scheduleRender()
    if renderScheduled then return end
    renderScheduled = true
    Script.SetTimer(D.renderDebounceMs or 250, function()
        renderScheduled = false
        KCD2MP_DiceRender()
    end)
end

-- Drops every queued and displayed tutorial. Also exposed as mp_dice_flush, so
-- a stuck or flickering panel is always one command away from being cleared.
function KCD2MP_DiceFlush()
    pcall(function() UIAction.CallFunction("hud", -1, "HideAllTutorials") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideCurrentTutorial") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideTutorial", D.panelId) end)
end

local function say(text)
    if not D.native.infotext then return end
    mp_log_text("dice", text)   -- WO-98 Phase 6
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", text, 10, 2200, true)
    end)
end
KCD2MP_DiceSay = say

-- Hold-to-confirm needs a light tick, and only while a key is actually held.
local function holdTick()
    if not D.hold then return end
    Script.SetTimer(100, holdTick)
    KCD2MP_DiceHoldTick()
end
KCD2MP_DiceHoldPump = holdTick

-- ===== inbound: called by the agent =========================================

-- Opens the board. role is OUR SessionRole (0 initiator, 1 acceptor).
function KCD2MP_DiceOpen(role, peer, target)
    D.role      = tonumber(role) or 0
    D.peer      = tostring(peer or "opponent")
    D.target    = tonumber(target) or 4000
    D.scores    = { [0] = 0, [1] = 0 }
    D.turnTotal = 0
    D.free, D.kept, D.sel = {}, {}, {}
    D.outcome, D.err, D.hold = nil, nil, nil
    D.open = true
    KCD2MP_DiceRender()      -- the parchment card announcing the match
    mp_log("DICE overlay open vs " .. D.peer .. " to " .. tostring(D.target))
end

function KCD2MP_DiceClose()
    D.open, D.hold = false, nil
    -- Flush rather than hide one entry: anything still queued would otherwise
    -- keep surfacing after the match is over. Runs even if the board was already
    -- closed, so mp_dice_close doubles as "clear whatever is stuck on screen".
    KCD2MP_DiceFlush()
    mp_log("DICE overlay closed")
end

-- A full authoritative snapshot. freeCsv/keptCsv/bustedCsv are comma-separated
-- faces ("3,1,5,6"); empty string means none. Never a delta -- the relay
-- always sends the whole board, so this can replace state wholesale without
-- reconciling. bustedCsv is the roll that just busted (added after WO-5
-- shipped): FreeDice is already cleared by the time a bust reaches the wire,
-- so this is the only place the actual rolled faces ever appear.
function KCD2MP_DiceState(turnRole, s0, s1, turnTotal, target, phase, freeCsv, keptCsv, bustedCsv)
    local function parse(csv)
        local t = {}
        for m in tostring(csv or ""):gmatch("[^,]+") do
            local n = tonumber(m)
            if n then t[#t + 1] = n end
        end
        return t
    end

    -- A snapshot arriving with no board open means the agent connected mid-
    -- session, or SessionStarted was missed. Open FIRST -- KCD2MP_DiceOpen
    -- clears scores, dice and animation state, so opening after applying the
    -- snapshot would wipe the very state this call is delivering.
    if not D.open then KCD2MP_DiceOpen(D.role, D.peer, tonumber(target) or D.target) end

    local prevTurn = D.turnRole

    D.turnRole  = tonumber(turnRole) or 0
    D.scores[0] = tonumber(s0) or 0
    D.scores[1] = tonumber(s1) or 0
    D.turnTotal = tonumber(turnTotal) or 0
    D.target    = tonumber(target) or D.target
    D.phase     = tonumber(phase) or 0
    D.free      = parse(freeCsv)
    D.kept      = parse(keptCsv)
    D.sel       = {}          -- a new snapshot always clears a pending mark

    local bustedFaces = parse(bustedCsv)

    if D.turnRole ~= prevTurn then
        local mine = (D.turnRole == D.role)

        -- Used to be inferred from whether the score moved -- the relay did
        -- not label its snapshots at all. Now it does (bustedFaces), so this
        -- reads real state instead of guessing from a side effect of it.
        local busted = #bustedFaces > 0

        -- The turn hand-off and the bust are the two moments that want to
        -- punch, and a line across the middle of the screen punches harder
        -- than a change inside the panel. This is what ShowInfoText is for.
        if busted then
            local rolled = table.concat(bustedFaces, ", ")
            say((prevTurn == D.role) and ("Bust! Rolled " .. rolled .. " -- nothing scored.")
                                      or (D.peer .. " busts on " .. rolled .. "."))
        else
            say(mine and "Thy cast." or (D.peer .. " casts."))
        end
    end

    D.err = nil

    -- Immediate, not debounced: this is a relay-confirmed result, already
    -- paced by however long the turn took -- it is local rapid-fire input
    -- (marking) that needs coalescing, not this.
    KCD2MP_DiceRender()
end

-- The relay rejected an intent. State did not change; the board says why.
function KCD2MP_DiceError(reason)
    D.err = { text = tostring(reason or "not allowed") }
    KCD2MP_DiceRender()
end

-- outcome: "win" or "lose". wager (WO-33) is the agreed groschen stake,
-- echoed by the relay on the wire DiceEnd packet itself -- see Protocol.cs.
-- Applied here, once, to THIS client's own Inventory only: winner gains,
-- loser loses, never a write into the peer's save. This function is reached
-- only for a match that ran to a clean conclusion -- a mid-match disconnect
-- fires KCD2MP_DiceClose via SessionEnded instead (GameBridge.cs), never
-- this, so a dropped connection can never move money on either side.
function KCD2MP_DiceEnd(outcome, s0, s1, wager)
    D.scores[0] = tonumber(s0) or D.scores[0]
    D.scores[1] = tonumber(s1) or D.scores[1]
    D.outcome   = tostring(outcome or "lose")
    D.sel, D.hold, D.err = {}, nil, nil

    -- Live-checked this session (WO-33): the "Inventory" scriptbind the
    -- vendor docs describe as a global table does not exist in this sandbox
    -- at all. What IS real: player.inventory:GetMoney()/RemoveMoney(n) are
    -- genuine entity-scoped methods, confirmed with a controlled before/after
    -- read (7.9 -> 5.9 groschen for RemoveMoney(2)). There is no AddMoney
    -- anywhere reachable, on this object or via RTTR reflection. The win
    -- side instead uses ItemUtils.AddMoneyToInventory(who, amount), a real
    -- function the shipped game's own Scripts/Utils/ItemUtils.lua defines --
    -- money is a stackable item (guid 5ef63059-...) under the hood, and this
    -- is Warhorse's own sanctioned way to hand someone more of it, built on
    -- ItemManager.CreateItem + entity.inventory:AddItem, both independently
    -- proven elsewhere in this project (docs/kcd2_lua_api.md).
    wager = tonumber(wager) or 0
    if wager > 0 then
        local ok, err
        if D.outcome == "win" then
            ok, err = pcall(function() ItemUtils.AddMoneyToInventory(player, wager) end)
        else
            ok, err = pcall(function() player.inventory:RemoveMoney(wager) end)
        end
        mp_log("DICE wager " .. wager .. " " .. (D.outcome == "win" and "added" or "removed")
            .. " ok=" .. tostring(ok) .. " err=" .. tostring(err))
    end

    say((D.outcome == "win") and ("The wager is thine." .. (wager > 0 and (" +" .. wager .. " groschen.") or ""))
                              or (D.peer .. " takes the pot." .. (wager > 0 and (" -" .. wager .. " groschen.") or "")))
    KCD2MP_DiceRender()
    mp_log("DICE match ended: " .. D.outcome .. " wager=" .. wager)
end

-- ===== demo: review the board without a second player =======================
--
-- One machine, one copy of the game and no second human is the standing
-- constraint on this project, so the visuals would otherwise be unreviewable
-- until a second PC exists. This drives the board through a scripted match with
-- fabricated snapshots -- every moment the design specifies, in order, so the
-- look and the motion can actually be judged.
--
-- It calls the SAME entry points the agent calls and fabricates nothing the
-- relay would not send. It is a view of the presentation layer only: it sends
-- no intents, touches no session, and cannot affect a real match.
--
--   mp_dice_demo

local DEMO = {
    -- {delay after previous step (s), what to do}
    {0.0, function() KCD2MP_DiceOpen(0, "Dicer Filip", 2500) end},
    {0.8, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 0, "",            "") end},
    {1.2, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 1, "1,5,3,6,2,4", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 0, "5,3,6,2,4",   "1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 1, "2,5,4,1,6",   "1") end},
    {1.8, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 0, "2,4,6",       "1,5,1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 1, "3,3,2",       "1,5,1") end},
    -- bust: turn passes and our banked score did NOT move. bustedCsv fabricates
    -- what the roll was -- 2,3,4,6 has no 1, no 5 and no triple, a real bust.
    {2.0, function() KCD2MP_DiceState(1, 0,    0,   0, 2500, 0, "",            "", "2,3,4,6") end},
    {2.4, function() KCD2MP_DiceState(1, 0,    0, 450, 2500, 1, "4,4,4,2",     "5,5") end},
    -- opponent banks: their score moves, so no bust sting
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 0, "",            "") end},
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 1, "1,1,1,4,2,6", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,  450,1000, 2500, 0, "4,2,6",       "1,1,1") end},
    -- a rejected intent
    {1.6, function() KCD2MP_DiceError("those dice score nothing") end},
    -- and a win
    {2.6, function() KCD2MP_DiceState(0, 2550, 450, 0, 2500, 0, "", "") end},
    {0.4, function() KCD2MP_DiceEnd("win", 2550, 450) end},
    {6.0, function() KCD2MP_DiceClose() end},
}

KCD2MP._demoStep = 0

local function demoTick()
    KCD2MP._demoStep = KCD2MP._demoStep + 1
    local s = DEMO[KCD2MP._demoStep]
    if not s then return end
    pcall(s[2])
    local nxt = DEMO[KCD2MP._demoStep + 1]
    if nxt then Script.SetTimer(math.floor(nxt[1] * 1000), demoTick) end
end

function KCD2MP_DiceDemo()
    KCD2MP._demoStep = 0
    mp_log("DICE demo: scripted match, ~30s")
    demoTick()
    return true
end

-- ===== outbound: player intents =============================================
--
-- Every one of these only EMITS. The relay decides whether it was legal, and
-- the answer arrives as the next snapshot or as a DiceError.

-- anyTime: forfeit is legal whenever the match is live -- conceding only on
-- your own turn would mean being unable to walk away from an opponent who has
-- stopped playing.
local function intent(s, anyTime)
    if not D.open then
        KCD2MP_ShowInteractionMsg("No dice match")
        return false
    end
    if D.outcome then return false end
    if not anyTime and D.turnRole ~= D.role then
        D.err = { text = "not thy turn", t0 = os.clock() }
        return false
    end
    KCD2MP_EmitEvent("dice_intent", s)
    return true
end

-- Marks or unmarks a die for the next Keep. Local only, freely reversible --
-- nothing leaves the machine until the player confirms.
function KCD2MP_DiceMark(i)
    i = tonumber(i)
    if not D.open or not i or not D.free[i] then return false end
    if D.turnRole ~= D.role then
        D.err = { text = "not thy turn" }
        scheduleRender()
        return false
    end
    if D.sel[i] then D.sel[i] = nil else D.sel[i] = true end
    D.err = nil
    -- Debounced, not immediate: marking can fire several times a second while
    -- choosing a keep, and pushing the panel once per press is the flicker
    -- this design already fixed once.
    scheduleRender()
    return true
end

-- Clears every pending mark without touching the roll itself, so a player who
-- marked, say, two 5s and then noticed a third can start over on the SAME
-- free dice instead of committing a suboptimal keep. Purely local, like
-- marking itself -- nothing is sent to the relay until KCD2MP_DiceConfirm.
function KCD2MP_DiceUnmarkAll()
    if not D.open or D.phase ~= 1 then return false end
    D.sel = {}
    D.err = nil
    scheduleRender()
    return true
end

-- The primary action, and it does double duty by phase: cast when the relay is
-- waiting for a roll, set aside the marked dice when it is waiting for a keep.
function KCD2MP_DiceConfirm()
    if not D.open then return false end
    if D.phase == 1 then
        local mask = 0
        for i = 1, 6 do if D.sel[i] then mask = mask + 2 ^ (i - 1) end end
        if mask == 0 then
            D.err = { text = "mark thy dice first" }
            KCD2MP_DiceRender()
            return false
        end
        return intent("keep " .. tostring(math.floor(mask)))
    end
    return intent("roll")
end

function KCD2MP_DiceBank()    return intent("bank")          end
function KCD2MP_DiceForfeit() return intent("forfeit", true) end

-- Hold-to-confirm. Bank and forfeit are irreversible, so they are deliberately
-- not on a single press: begin on key-down, fire only if the key survives long
-- enough, cancel on key-up. Pumped by its own short-lived timer, which only
-- runs while a key is actually down.
function KCD2MP_DiceHoldBegin(action)
    if not D.open or D.outcome then return end
    if D.hold then return end
    D.hold = { action = action, t0 = os.clock() }
    KCD2MP_DiceHoldPump()
end

function KCD2MP_DiceHoldEnd()
    D.hold = nil
end

function KCD2MP_DiceHoldTick()
    if not D.hold then return end
    local need = (D.hold.action == "forfeit") and 1.2 or 0.6
    if os.clock() - D.hold.t0 >= need then
        local a = D.hold.action
        D.hold = nil
        if a == "forfeit" then KCD2MP_DiceForfeit() else KCD2MP_DiceBank() end
    end
end

-- ===== dice tables (WO-6 C1) ================================================
--
-- Real tables only -- this mod's dice UI must never appear anywhere a player
-- happens to be standing.
--
-- "DiceInteractor" is not a guess. Scripts.pak ships Entities/DiceInteractor.ent
-- registering that class against Scripts/Entities/WH/Minigames/DiceInteractor.lua,
-- the script that puts the "@ui_hud_play_dice" action on a dice board
-- (objects/manmade/task_specific_props/entertainment/games/dice/dice_board.cgf).
--
-- UNVERIFIED until Probe-Visual.ps1's `dicetable` block is run at a real tavern
-- table: whether world-placed tables are actually instances of this class.
-- If they are not, set KCD2MP.dice.tableClass = nil to fall back to a plain
-- proximity check between the two players -- honest, flagged, and not the
-- default.
-- WO-6 revision: the strict "must be at a DiceInteractor" gate is correct for
-- shipping but hostile to testing, because every dice table in the world is
-- already occupied by an NPC and we cannot drive the native minigame anyway.
-- So the gate is now a list of accepted classes plus a switch.
--
--   requireTable = false  -- test mode, invite anywhere (DEFAULT for now)
--   requireTable = true   -- shipping behaviour, must be at an accepted table
--
-- `mp_dice_gate on|off` flips it live, and `mp_dice_scan` lists the entity
-- classes actually around the player so a generic table's real class name can be
-- ADDED to tableClasses from evidence rather than guessed at.
KCD2MP.dice.tableClasses = { "DiceInteractor" }
KCD2MP.dice.tableClass   = "DiceInteractor"   -- kept: first entry, back-compat
KCD2MP.dice.tableRadius  = 4.0
KCD2MP.dice.requireTable = false

-- Returns entity, distance -- or nil plus a reason. Searches every class in
-- KCD2MP.dice.tableClasses and returns the nearest hit across all of them.
function KCD2MP_NearestDiceTable(radius)
    radius = tonumber(radius) or KCD2MP.dice.tableRadius
    local classes = KCD2MP.dice.tableClasses
    if not classes or #classes == 0 then return nil, "table detection disabled" end
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end

    local best, bestD = nil, nil
    for _, cls in ipairs(classes) do
        local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, cls)
        if ok and list then
            for _, e in ipairs(list) do
                local ok2, ep = pcall(function() return e:GetWorldPos() end)
                if ok2 and ep then
                    local d = math.sqrt((ep.x - ppos.x) ^ 2 + (ep.y - ppos.y) ^ 2 + (ep.z - ppos.z) ^ 2)
                    if not bestD or d < bestD then best, bestD = e, d end
                end
            end
        end
    end
    if not best then return nil, "no table within " .. tostring(radius) .. "m" end
    return best, bestD
end

-- Lists every entity near the player with its class, so a generic table's real
-- class name can be read off the log and ADDED to tableClasses. Evidence, not a
-- guess -- the same discipline that produced DiceInteractor in the first place.
function KCD2MP_ScanTables(radiusStr)
    local radius = tonumber(tostring(radiusStr or ""):match("%d+%.?%d*") or "") or 6.0
    local ppos = player and player:GetWorldPos()
    if not ppos then mp_log("SCAN: no player position"); return false end
    local ok, list = pcall(System.GetEntitiesInSphere, ppos, radius)
    if not ok or not list then mp_log("SCAN: query failed"); return false end
    mp_log(string.format("SCAN: %d entities within %.1fm", #list, radius))
    local seen = {}
    for _, e in ipairs(list) do
        local ok2 = pcall(function()
            local cls = e.class or "?"
            local nm  = tostring(e:GetName())
            local ep  = e:GetWorldPos()
            local d   = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
            -- one line per entity, but collapse identical classes past the third
            seen[cls] = (seen[cls] or 0) + 1
            if seen[cls] <= 3 then
                mp_log(string.format("SCAN  %-22s %-34s %.1fm", tostring(cls), nm, d))
            end
        end)
    end
    return true
end

-- ===== seats at ordinary tables (WO-6 revision) =============================
--
-- Found by scanning entity classes around a real seated player, not guessed.
-- Every tavern seat carries three linked entities, all within ~1.5 m:
--
--   ActionTrigger      sitActionTrigger[Table/table_oneSides_tavern1:...:Bench/...]
--   StanceSmartObject  smartObject2[Table/table_oneSides_tavern1:...:Bench/...]
--   SmartObjectHolder  smartObject[Table/table_oneSides_tavern1_<guid>]
--
-- sitActionTrigger is the useful one. It exists only at a seat attached to a
-- table, its position is a stable anchor to teleport the other player to, and
-- its NAME encodes the table -- so two players can be checked for being at the
-- SAME table rather than merely both sitting somewhere.
--
-- Note this detects "at a seat", not "currently seated": player:GetStance() is
-- not available in this build (returned nil when probed), so there is no direct
-- read of the sitting state. Proximity to the trigger is the proxy, and it is
-- honest to call it that.
KCD2MP.dice.seatRadius = 1.6

-- Pulls "Table/table_oneSides_tavern1" out of a sitActionTrigger's name, so the
-- same table can be recognised from either player's seat.
function KCD2MP_TableIdFromName(name)
    if not name then return nil end
    return (tostring(name):match("%[(Table[/%.][%w_]+)"))
end

-- Returns entity, distance, tableId -- or nil plus a reason.
function KCD2MP_NearestSeat(radius)
    radius = tonumber(radius) or KCD2MP.dice.seatRadius
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end
    local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, "ActionTrigger")
    if not ok or not list then return nil, "entity query failed" end

    local best, bestD, bestName = nil, nil, nil
    for _, e in ipairs(list) do
        local ok2, nm = pcall(function() return tostring(e:GetName()) end)
        if ok2 and nm and nm:find("^sitActionTrigger") then
            local ok3, ep = pcall(function() return e:GetWorldPos() end)
            if ok3 and ep then
                local d = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
                if not bestD or d < bestD then best, bestD, bestName = e, d, nm end
            end
        end
    end
    if not best then return nil, "no seat within " .. tostring(radius) .. "m" end
    return best, bestD, KCD2MP_TableIdFromName(bestName)
end

function KCD2MP_IsAtSeat(radius)
    return (KCD2MP_NearestSeat(radius)) ~= nil
end

-- Reports the seat under the player: distance, table id, and the anchor position
-- the other player would be teleported to.
function KCD2MP_ReportSeat()
    local e, d, tid = KCD2MP_NearestSeat(6.0)
    if not e then
        mp_log("SEAT: none within 6m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No seat nearby")
        return false
    end
    local p = e:GetWorldPos()
    mp_log(string.format("SEAT: %.2fm table=%s anchor=%.2f,%.2f,%.2f",
        d, tostring(tid), p.x, p.y, p.z))
    KCD2MP_ShowInteractionMsg(string.format("Seat %.1fm  %s", d, tostring(tid)))
    return true
end

-- Flip the shipping gate on or off without a rebuild.
function KCD2MP_DiceGate(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.dice.requireTable = true
    elseif s:find("off") then KCD2MP.dice.requireTable = false end
    mp_log("DICE table gate = " .. tostring(KCD2MP.dice.requireTable))
    return true
end

function KCD2MP_IsAtDiceTable(radius)
    local e = KCD2MP_NearestDiceTable(radius)
    return e ~= nil
end

-- Verification helper for the C1 claim above. Run it standing at a real tavern
-- dice table, then again well away from one -- the away run is the negative
-- control that makes the at-table run mean anything.
function KCD2MP_ReportDiceTable()
    local e, d = KCD2MP_NearestDiceTable(25.0)
    if not e then
        mp_log("DICE TABLE: none within 25m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No dice table within 25m")
        return false
    end
    local ok, nm = pcall(function() return e:GetName() end)
    mp_log(string.format("DICE TABLE: '%s' at %.2fm", ok and tostring(nm) or "?", d))
    KCD2MP_ShowInteractionMsg(string.format("Dice table %.1fm away", d))
    return true
end

-- The gate the dice invite goes through. NPC dice games are untouched by any of
-- this: they never call into KCD2MP, and this only ever emits our own invite
-- event to our own agent.
-- The gate is now "at a seat attached to any table", per the design call that
-- every real dice table is NPC-occupied and the native minigame is unreachable
-- anyway. A dice-specific DiceInteractor still counts, so nothing is lost.
--
-- The seat's table id rides along on the invite: it is what lets the acceptor be
-- placed at the SAME table rather than merely at some table of their own.
-- WO-33: mp_dice_wager <amount>. Purely local -- takes effect on the NEXT
-- mp_dice/F9 invite this client sends, and does nothing to any invite already
-- pending. A negative or unparsable amount is treated as 0 (no wager) rather
-- than faulting; groschen are whole numbers here, so this floors.
function KCD2MP_SetDiceWager(line)
    local n = tonumber(tostring(line or ""):match("%-?%d+")) or 0
    KCD2MP.dice.wagerAmount = math.max(0, math.floor(n))
    KCD2MP_ShowInteractionMsg("Dice wager set to " .. KCD2MP.dice.wagerAmount)
    mp_log("Dice wager set to " .. KCD2MP.dice.wagerAmount)
end

function KCD2MP_InviteDiceAtTable()
    -- WO-33: check our OWN balance before sending, not after the peer accepts.
    -- RemoveMoney at DiceEnd would refuse anyway if this were skipped, but a
    -- match that couldn't have been paid for should never start.
    local wager = KCD2MP.dice.wagerAmount or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            mp_log("Refusing dice invite: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            return false
        end
    end

    local seat, d, tid = KCD2MP_NearestSeat()
    if not seat and KCD2MP.dice.requireTable then
        -- fall back to a real dice table before refusing
        local e = KCD2MP_NearestDiceTable()
        if not e then
            KCD2MP_ShowInteractionMsg("Sit at a table first (" .. tostring(d) .. ")")
            return false
        end
    end
    if seat then
        local p = seat:GetWorldPos()
        KCD2MP.dice.seat = { tableId = tid, x = p.x, y = p.y, z = p.z }
        mp_log(string.format("DICE invite from seat table=%s anchor=%.2f,%.2f,%.2f",
            tostring(tid), p.x, p.y, p.z))
    else
        KCD2MP.dice.seat = nil
    end
    return KCD2MP_InviteNearest("dice", wager)
end

-- WO-50: mp_debug_hud on|off. Flips the release-default r_DisplayInfo
-- override above without a rebuild, so a future debugging session can get
-- the build/memory/FPS block back. Does not touch the ping/network
-- indicator -- that is a separate System.DrawText call, not this CVar.
function KCD2MP_DebugHud(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then
        KCD2MP.debugHud = true
        System.SetCVar("r_DisplayInfo", "3")
    elseif s:find("off") then
        KCD2MP.debugHud = false
        System.SetCVar("r_DisplayInfo", "0")
    else
        mp_log("mp_debug_hud: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("DEBUG HUD (r_DisplayInfo) = " .. tostring(System.GetCVarValue("r_DisplayInfo")))
    return true
end

-- ===== Ghost NPC Spawn =====

-- WO-17: mp_enable_aggro on|off. Opt-in, off by default, decided locally on
-- this client only -- it does not need the other player's agreement, the
-- same way dice needed a session invite/accept but this does not, because it
-- only changes how THIS player's world treats an incoming ghost. The agent
-- hears about this via the same log-tail event channel invite_accept already
-- uses (KCD2MP_EmitEvent) -- it, not Lua, is what actually decides when to
-- attach a ghost to the hostile faction, since that write only exists in
-- native code.
--
-- WO-27: this is a single live flag (GameBridge._aggroEnabled), checked at
-- hit-time for every ghost, not baked in per-ghost at spawn -- flipping it
-- takes effect on the very next hit for every ghost already in the world, no
-- respawn or reconnect needed. Reactive combat itself (a ghost defending
-- itself, joining a nearby fight) is unconditional and always on regardless
-- of this toggle (WO-26); what this toggle adds is a ~20s native hostile-
-- faction attach so nearby NPCs recognize the ghost as an enemy generally,
-- not just whoever it's already fighting (WO-27's live A/B test).
function KCD2MP_EnableAggro(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.aggroEnabled = true
    elseif s:find("off") then KCD2MP.aggroEnabled = false
    else
        mp_log("mp_enable_aggro: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    KCD2MP_EmitEvent("aggro_toggle", KCD2MP.aggroEnabled and "on" or "off")
    mp_log("AGGRO " .. (KCD2MP.aggroEnabled and "ENABLED" or "disabled") ..
           " -- affects ghosts spawned from now on")
    KCD2MP_ShowInteractionMsg("Aggro: " .. (KCD2MP.aggroEnabled and "ON" or "OFF"))
    return true
end

-- ===== NPC sync (WO-32) =====
--
-- One player's world dictating what nearby hand-placed NPCs are doing in
-- everyone's world. Built on WO-32's live findings, all observed on a real
-- NPC (ttkc_man_16), not a ghost:
--
--   * A single external SetWorldPos LANDS but the engine restores the NPC to
--     its byte-identical schedule anchor within ~1.5 s. One write is nothing.
--   * A continuous 50 ms write stream WINS completely -- the NPC tracked an
--     external drive across metres with no AI suppression of any kind, while
--     dialogue, crime state and nearby NPCs stayed completely undisturbed.
--   * When the stream stops, the engine restores the NPC to its own schedule
--     by itself (back on anchor within 3 s, talkable, no side effects). So
--     "release" is simply: stop writing.
--   * StartAnimation works on a real NPC exactly as on a ghost, and without
--     it the NPC slides in whatever pose its current activity holds.
--
-- Emitting side (the Rule 2 world authority only): a slow tick tracks up to
-- npcSync.maxTracked NPCs within npcSync.radius of the player and emits an
-- npc_state event line per NPC on movement, on a health change, or on a slow
-- heartbeat. Runtime-spawned entities (ghosts, horses) are excluded -- this
-- layer moves EXISTING authored NPCs, it never creates or names one.
--
-- Receiving side: KCD2MP_ApplyNpcState targets a puppet entry; a 50 ms tick
-- (same cadence family as the ghost interp) lerps the local copy of that NPC
-- toward the stream and drives a walk/run animation from the rendered speed.
-- A puppet that stops receiving packets for releaseS seconds is dropped and
-- the engine takes the NPC back -- that is the whole restore path, verified
-- live before this was built.
KCD2MP.npcSync = {
    enabled    = true,    -- mp_npc_sync on|off. ON by default (human's WO-32
                          -- decision: "if it is off by default then nobody is
                          -- ever going to know how to enable it"). Turn OFF
                          -- with `mp_npc_sync off` in the console. Since
                          -- WO-60 a non-authority emits too (proximity
                          -- claims, see KCD2MP.npcProx), so this master
                          -- switch gates every role's NPC emission.
    radius     = 30,      -- metres around the local player (WO-32 Phase 0 bound)
    maxTracked = 5,       -- hard cap on synced NPCs (WO-32 Phase 0/2 bound)
    emitMs     = 100,     -- per-NPC emit cadence (10 Hz). WO-77 Step 2: was
                          -- 250 (4 Hz, WO-32). The per-NPC gate below is
                          -- unchanged -- an NPC that did not move since its
                          -- last emit still costs only the 2 s heartbeat --
                          -- so this only raises the rate for MOVING NPCs.
                          -- Send-side and unconditional: it is what this
                          -- client transmits about its own locally-simulated
                          -- NPCs, independent of any receiver's
                          -- mp_npc_smooth state (design: WO-75 s2.4/s4 Step
                          -- 2). The receiver's interpolation delay is derived
                          -- from this value (KCD2MP_NpcSmoothDelayS), so the
                          -- two cannot drift apart. Adaptive per-NPC cadence
                          -- (100 ms engaged/near, 250 ms otherwise) is a
                          -- noted future refinement, not built.
    scanMs     = 2000,    -- how often the tracked set is rebuilt
    moveEps    = 0.05,    -- metres; below this nothing is emitted
    heartbeatS = 2.0,     -- unconditional resend so a late joiner converges
    releaseS   = 3.0,     -- receiver: packet age at which a puppet is released
}
KCD2MP.npcSyncRunning  = false

-- WO-102.5 Phase 3: uncapped co-located ownership, host authority only.
-- npcSync.radius/maxTracked above are untouched and still govern the 0.23.2
-- claim model (mp_authority_host_off) exactly as before -- these are a
-- SEPARATE parameter set that only applies under host authority, so flipping
-- authorityHost off returns to the old numbers, not just the old cap logic.
KCD2MP.wo1025 = {
    -- Ownership radius: under host authority, EVERY NPC within this of any
    -- anchor is owned -- no per-anchor cap (mp_npc_rescan). Runtime-
    -- adjustable, not baked: #KCD2MP_SetAuthorityRadius("<metres>") from the
    -- console. The live radius runbook (WO-102.5 findings S6.3) held
    -- 45/90/150m with zero MP-AUTHORITY-VIOLATION/crashes in a busy town,
    -- native-scan cost is radius-independent (S6.2, 37,079 entities walked
    -- regardless), and culling kept 150m's actual streaming cost to
    -- 22-of-78 tracked. The FPS-floor reading that had kept this at 45m was
    -- RETRACTED the same session (S6.3) -- it measured the game window
    -- being unfocused, not the radius.
    -- WO-103 Phase 1: the upper clamp (was 300) is removed -- the point of
    -- this WO is to find the real ceiling by testing to failure, not stop at
    -- a guessed one (docs/WO-103-field-runbook.md). Default raised to
    -- 300 m, the maintainer's original target: it covers a peer wandering
    -- off on their own quest without dropping co-location, and nothing
    -- measured argues against it (WO-102.5 S6.3's own 150m result was
    -- comfortably clean). #KCD2MP_SetAuthorityRadius("45") is one line back
    -- down if a focused-window measurement ever finds a real cost.
    authorityRadius = 300.0,
    -- Cull radius: within authorityRadius but beyond THIS, an owned NPC is
    -- not actively streamed (mp_npc_cull_on, default on) -- it is still
    -- tracked (nobody else can claim it) but KCD2MP_NpcSyncTick skips its
    -- emission. What makes a large authorityRadius affordable: most of a
    -- 150 m circle in a town is behind buildings or just far from both
    -- players. An engaged NPC (fighting a player) is never culled by
    -- construction -- NPC_ENGAGE_RANGE_SQ's 12 m is always inside this.
    cullRadius = 30.0,
    npcCull = true,   -- mp_npc_cull_on|off
    -- WO-102.5 Phase 4: ONE coarse together/apart state for the whole
    -- session, not per-NPC proximity ownership (deliberately unlike the
    -- WO-60 claim model's per-entity claiming, which WO-102 S2.1 showed
    -- produced 52/52 grants to one player and expiries mid-fight -- a
    -- single, rarely-changing, session-level state is a different and much
    -- safer shape). Hysteresis: must close to <= togetherEnterM to become
    -- "together", must open past togetherExitM to become "apart" again,
    -- each sustained for togetherDwellS before the transition commits -- a
    -- momentary crossing does not flip it.
    together        = false,
    togetherEnterM  = 60.0,
    togetherExitM   = 90.0,
    togetherDwellS  = 10.0,
    -- WO-103 Phase 2: mp_npc_read_native_on|off. When on, KCD2MP_NpcSyncTick
    -- takes a tracked NPC's position/yaw from the agent's native push
    -- (KCD2MP._nativeScan.pos) when fresh, instead of e:GetWorldPos()/
    -- GetWorldAngles() -- health/dead/KO/drawn/engaged are unaffected, still
    -- read off `e` every tick (WO-103.5's job, unmapped offsets). The
    -- fallback is never a second GetEntityByName -- `e` is already in hand
    -- for those state-bit reads regardless of this toggle, so an absent or
    -- stale native sample just costs what today's code already costs.
    -- Ships on per the standing rule (new mechanisms default on); auto-fails
    -- closed (this flag flips back to false) if KCD2MP_NpcReadCompare finds
    -- a real mismatch, not merely a stale one -- see that function.
    readNative      = true,
    -- WO-108 s3.5: seconds a released puppet's brain pause is held before
    -- wh_ai_ResumeNPC (mp_resume_dwell <s>). 10 s: the same dwell as the
    -- co-location hysteresis above, longer than the cull-boundary flapping a
    -- joiner produces walking a town, and bounded so an NPC that really left
    -- the stream is back under its own brain within releaseS + 10 s. 0 =
    -- resume the moment the puppet drops (the 0.26.3 behaviour).
    resumeDwellS    = 10.0,
}

-- name:string metres. Registered as mp_authority_radius (WO-106; was
-- Lua-only via #KCD2MP_SetAuthorityRadius("90") because of the %LINE/%line
-- case bug -- see docs/WO-105-contradictions.md entry 1). The '#<lua>' form
-- still works. Floor-clamped, not merely validated: a runaway small radius (or
-- garbage input) is still rejected outright. WO-103 Phase 1: the UPPER bound
-- is deliberately gone -- finding the real ceiling by testing to failure is
-- this WO's whole point (docs/WO-103-field-runbook.md); stopping at a
-- guessed number would defeat it.
local AUTHORITY_RADIUS_MIN = 10.0
function KCD2MP_SetAuthorityRadius(arg)
    local m = tonumber(arg)
    if not m or m ~= m then   -- m ~= m catches NaN
        mp_log("WO1025-RADIUS rejected '" .. tostring(arg) .. "' -- expected a number of metres")
        return false
    end
    if m < AUTHORITY_RADIUS_MIN then
        mp_log(string.format("WO1025-RADIUS rejected %.1f -- must be >= %.0f", m, AUTHORITY_RADIUS_MIN))
        return false
    end
    local was = KCD2MP.wo1025.authorityRadius
    KCD2MP.wo1025.authorityRadius = m
    mp_log(string.format("WO1025-RADIUS set=%.1f was=%.1f", m, was))
    KCD2MP_ShowInteractionMsg(string.format("Authority radius: %.0fm", m))
    -- The agent's native scan (WO-102.5 Phase 2) has its own copy of this
    -- number -- it cannot read this table, only the event channel -- so a
    -- radius change here is silently capped at whatever the agent last knew
    -- unless it is told. Radius is Lua-owned (set from the console, not
    -- pushed by the agent at connect like the wo102 booleans), so the mod is
    -- the one side that must announce a change.
    KCD2MP_EmitEvent("authority_radius", string.format("%.1f", m))
    return true
end

-- WO-106: runtime setter for the together/apart hysteresis band (WO-102.5
-- Phase 4, see the comment above KCD2MP.wo1025.together). Previously baked
-- constants with no console command at all -- flagged as a gap, not built,
-- because of the same %LINE/%line case bug (docs/WO-105-contradictions.md
-- entry 1). "on" with no further arguments restores the shipped defaults.
-- enterM must be strictly less than exitM or the hysteresis band inverts and
-- the together/apart state would oscillate every tick instead of debouncing.
function KCD2MP_SetTogetherParams(arg)
    local s = tostring(arg or ""):lower()
    local w = KCD2MP.wo1025
    if s == "" or s == "on" then
        w.togetherEnterM, w.togetherExitM, w.togetherDwellS = 60.0, 90.0, 10.0
    else
        local enterM, exitM, dwellS = string.match(s, "^%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s*$")
        enterM, exitM, dwellS = tonumber(enterM), tonumber(exitM), tonumber(dwellS)
        if not (enterM and exitM and dwellS) then
            mp_log("mp_together_params: expected 'on' (defaults) or '<enterM> <exitM> <dwellS>', got '" .. tostring(arg) .. "'")
            return false
        end
        if enterM <= 0 or exitM <= 0 or dwellS <= 0 then
            mp_log("mp_together_params rejected: all three values must be > 0")
            return false
        end
        if enterM >= exitM then
            mp_log(string.format("mp_together_params rejected: enterM (%.1f) must be < exitM (%.1f) or the hysteresis band inverts", enterM, exitM))
            return false
        end
        w.togetherEnterM, w.togetherExitM, w.togetherDwellS = enterM, exitM, dwellS
    end
    mp_log(string.format("WO1025-TOGETHER-PARAMS enterM=%.1f exitM=%.1f dwellS=%.1f",
        w.togetherEnterM, w.togetherExitM, w.togetherDwellS))
    KCD2MP_ShowInteractionMsg(string.format("Together/apart: enter<=%.0fm exit>%.0fm dwell=%.0fs",
        w.togetherEnterM, w.togetherExitM, w.togetherDwellS))
    return true
end

-- WO-106 Phase 3 mitigation: runtime puppet write-rate control, so a field
-- session can find the rate where ground-collider sinking stops (see the
-- comment above KCD2MP.npcPuppetTickMs). Read fresh by
-- KCD2MP_NpcPuppetTick's own reschedule, so this takes effect on the next
-- tick, not next restart -- no reconnect, no pak rebuild.
local NPC_PUPPET_TICK_MIN_MS = 10   -- floor: below this is pegging the tick, not testing it
function KCD2MP_SetPuppetRate(arg)
    local ms = tonumber(arg)
    if not ms or ms ~= ms then   -- ms ~= ms catches NaN
        mp_log("mp_puppet_rate rejected '" .. tostring(arg) .. "' -- expected a number of milliseconds")
        return false
    end
    if ms < NPC_PUPPET_TICK_MIN_MS then
        mp_log(string.format("mp_puppet_rate rejected %.0f -- must be >= %.0f", ms, NPC_PUPPET_TICK_MIN_MS))
        return false
    end
    local was = KCD2MP.npcPuppetTickMs
    KCD2MP.npcPuppetTickMs = ms
    mp_log(string.format("NPC-PUPPET-RATE set=%.0fms was=%.0fms", ms, was))
    KCD2MP_ShowInteractionMsg(string.format("Puppet write rate: %.0fms", ms))
    return true
end

function KCD2MP_SetNpcCull(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.wo1025.npcCull = true
    elseif s:find("off") then KCD2MP.wo1025.npcCull = false
    else
        mp_log("mp_npc_cull: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("WO1025-CULL " .. (KCD2MP.wo1025.npcCull and "on" or "off"))
    return true
end

-- WO-103 Phase 2: mp_npc_read_native_on|off. Turning it back on re-arms a
-- fresh known-answer check immediately (KCD2MP_NpcReadCompare, defined
-- further down next to mp_npc_read_compare) rather than waiting for the next
-- periodic one -- the same "prove it's healthy before relying on it" shape
-- mp_npc_scan_native_on's own toggle doesn't have (that one only disarms
-- itself on repeated agent-side refusals, never re-verifies its answers).
function KCD2MP_SetNpcReadNative(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.wo1025.readNative = true
    elseif s:find("off") then KCD2MP.wo1025.readNative = false
    else
        mp_log("mp_npc_read_native: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("WO103-READNATIVE " .. (KCD2MP.wo1025.readNative and "on" or "off"))
    if KCD2MP.wo1025.readNative and KCD2MP_NpcReadCompare then pcall(KCD2MP_NpcReadCompare) end
    return true
end

-- WO-102.5 Phase 4's co-location transition/tick functions live further
-- down (just before mp_npc_rescan), not here -- they call mp_auth_log,
-- a local not yet defined at this point in the file.
KCD2MP._colocatePendingRelease = {}
KCD2MP._npcSyncAliveAt = nil
KCD2MP.npcTracked      = {}   -- name -> {lastX,lastY,lastZ,lastRot,lastHp,lastSentAt}
KCD2MP._npcScanAt      = 0

-- WO-77 Step 1: puppet renderer = time-based snapshot interpolation-behind
-- (design: docs/WO-75-jitter-design.md s2.3/s4 Step 1). The receiver keeps a
-- 3-deep ring of stamped samples per puppet and renders the puppet at
-- `os.clock() - DELAY` along the segment between the two samples bracketing
-- that time. Speed along a segment is constant, so the rendered velocity and
-- the anim tag derived from it never modulate inside a packet gap (WO-69 D1).
-- No velocity estimator, no dead reckoning, no extrapolation past the newest
-- sample -- an NPC that stopped emitting has stopped moving (the emitter's
-- `moved` gate). Everything advances by real elapsed time, never by "one
-- tick", so a leaked second timer chain (WO-69 D3) or the menu pump's faster
-- cadence computes the same renderAt and writes the same position: a no-op,
-- not doubled movement.
--
-- `mp_npc_smooth on|off`, default ON (WO-77 overrides the WO-63/WO-75
-- default-off recommendation; reasoning in docs/WO-77-findings.md). Off
-- restores the pre-WO-77 per-tick 0.5 lerp verbatim for a live A/B.
KCD2MP.npcSmooth = true

-- DELAY = 1.2 x the emit period, derived from emitMs at call time so the two
-- can never drift out of sync (0.12 s at 100 ms). Also the cap on the
-- segment duration used for speed: a packet arriving after a `moved`-gated
-- silence renders as a DELAY-long move at the NPC's implied speed, not as a
-- slow slide across the whole silent gap.
local NPC_SMOOTH_DELAY_FACTOR = 1.2
function KCD2MP_NpcSmoothDelayS()
    return ((KCD2MP.npcSync and KCD2MP.npcSync.emitMs) or 250) / 1000 * NPC_SMOOTH_DELAY_FACTOR
end
-- Ring depth: renderAt only ever looks DELAY back, and packets are ~emitMs
-- apart, so three samples cover it with one to spare.
local NPC_SMOOTH_RING = 3
-- Anim only: while the renderer holds at the newest sample because the next
-- packet is merely LATE (jitter past DELAY), keep the last segment's speed
-- for up to this long before reading the hold as "stopped". Position is not
-- affected -- it holds regardless. Without this a 130 ms gap against a
-- 120 ms delay would flick walk->idle->walk for one tick, which is exactly
-- the churn Step 1 exists to remove.
local NPC_SMOOTH_ANIM_GRACE_S = 0.06

-- Copy of the ghost path's calcAnimTag hysteresis bands (kdcmp.lua ANIM_UP /
-- ANIM_DOWN + calcAnimTag), stance-free. Deliberately a COPY, not a shared
-- helper: the puppet and ghost render paths must stay separate code (WO-70
-- constraint 1), so a retune of one can never silently retune the other.
local NPC_ANIM_UP   = { walk=1.0, run=2.5, sprint=4.0 }
local NPC_ANIM_DOWN = { walk=0.4, run=1.8, sprint=3.2 }
local function mp_npc_anim_tag(speed, cur)
    local t = cur or "idle"
    if t == "combatidle" then t = "idle" end
    if t == "sprint" then
        if speed < NPC_ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= NPC_ANIM_UP.sprint  then return "sprint"
        elseif speed <  NPC_ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= NPC_ANIM_UP.sprint  then return "sprint"
        elseif speed >= NPC_ANIM_UP.run     then return "run"
        elseif speed <  NPC_ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    if     speed >= NPC_ANIM_UP.sprint then return "sprint"
    elseif speed >= NPC_ANIM_UP.run    then return "run"
    elseif speed >= NPC_ANIM_UP.walk   then return "walk"
    else                                     return "idle" end
end

-- Push one stamped sample onto a puppet's ring. An XY step over 5 m from the
-- previous sample is a teleport: keep the pre-WO-77 snap behaviour (clear
-- the ring, jump the render state to the packet) -- a teleport is never
-- smoothed.
local function mp_npc_ring_push(p, x, y, z, rot, at)
    local ring = p.ring
    if not ring then ring = {}; p.ring = ring end
    local last = ring[#ring]
    if last then
        local sdx, sdy = x - last.x, y - last.y
        if sdx*sdx + sdy*sdy > 25.0 then
            ring = {}
            p.ring = ring
            p.cx, p.cy, p.cz, p.cr = x, y, z, rot
            p.segSpd = 0
        end
    end
    ring[#ring + 1] = { x = x, y = y, z = z, rot = rot, at = at }
    while #ring > NPC_SMOOTH_RING do table.remove(ring, 1) end
end

-- Render state for one puppet at wall-clock `now`: position/yaw plus the
-- constant speed of the segment being rendered. Returns nil when the ring is
-- empty (caller falls back to the legacy lerp). Pure bookkeeping -- never
-- reads the entity (WO-70 constraint 3); Z is packet-direct, no floor
-- raycast (constraint 4).
local function mp_npc_smooth_render(p, now)
    local ring = p.ring
    local n = ring and #ring or 0
    if n == 0 then return nil end
    local delay = KCD2MP_NpcSmoothDelayS()
    local renderAt = now - delay
    local a, b
    if renderAt >= ring[n].at then
        a, b = ring[n], ring[n]              -- past the newest: hold, never extrapolate
    elseif renderAt <= ring[1].at then
        a, b = ring[1], ring[1]              -- before the oldest (ring too shallow): hold at oldest
    else
        for i = n, 2, -1 do
            if ring[i-1].at <= renderAt then a, b = ring[i-1], ring[i]; break end
        end
    end
    local spd
    if a == b then
        p.cx, p.cy, p.cz, p.cr = a.x, a.y, a.z, a.rot
        -- Holding. A late packet (jitter) is indistinguishable from a stop
        -- for the first NPC_SMOOTH_ANIM_GRACE_S; after that it is a stop.
        if a == ring[n] and (renderAt - a.at) <= NPC_SMOOTH_ANIM_GRACE_S then
            spd = p.segSpd or 0
        else
            spd = 0
        end
    else
        -- Effective segment start: the later of the previous sample and
        -- (b.at - DELAY). For a steady stream that is a.at itself; after a
        -- moved-gated silence it clips the segment to DELAY so both the
        -- position slide and the speed read as one DELAY-long move (design
        -- s2.3: "does not slide slowly"). Position and speed always use the
        -- SAME segment, so the rendered velocity equals spd.
        local aAt = a.at
        if b.at - aAt > delay then aAt = b.at - delay end
        local segDur = b.at - aAt
        if segDur < 0.05 then segDur = 0.05 end
        local t = (renderAt - aAt) / segDur
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        p.cx = a.x + (b.x - a.x) * t
        p.cy = a.y + (b.y - a.y) * t
        p.cz = b.z
        p.cr = lerpAngle(a.rot, b.rot, t)
        local sdx, sdy = b.x - a.x, b.y - a.y
        spd = math.sqrt(sdx*sdx + sdy*sdy) / segDur
        p.segSpd = spd
    end
    return spd
end

function KCD2MP_SetNpcSmooth(arg)
    local s = tostring(arg or ""):lower()
    if s == "on" or s == "1" or s == "true" then
        KCD2MP.npcSmooth = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.npcSmooth = false
    end
    mp_log(string.format("mp_npc_smooth = %s (interp delay %.0f ms = %.1f x emitMs %d)",
        tostring(KCD2MP.npcSmooth), KCD2MP_NpcSmoothDelayS() * 1000,
        NPC_SMOOTH_DELAY_FACTOR, KCD2MP.npcSync.emitMs))
end

-- WO-69: chain identity for the two NPC-sync Script.SetTimer chains.
--
-- `tickAlive` calls a chain dead when its heartbeat is older than 1.0 s, and a
-- menu SUSPENDS Script.SetTimer (WO-12/13) -- so a menu open longer than a
-- second makes a live-but-frozen chain look dead, Start* launches a second
-- one, and when the menu closes BOTH resume. Nothing in the code could ever
-- notice: a chain had no identity, so a stale one was indistinguishable from
-- the real one. The field bundle shows 114 `puppet tick started` against 39
-- `stopped`, in runs of up to nine consecutive starts.
--
-- N concurrent chains apply the position lerp N times per 50 ms, which turns
-- the intended decay into a near-instant snap followed by a wait for the next
-- 4 Hz packet -- i.e. this AMPLIFIES the WO-69 D1 jitter rather than competing
-- with it.
--
-- Deliberately observe-only by default: WO-69's own rule is that the leak is
-- SUSPECTED until a log line shows two chains alive at once. `mp_npc_chainfix
-- on` flips the stale chain from "log and keep running" to "log and exit", so
-- the same build both proves the leak and fixes it without a second deploy.
-- The EMIT chain is deliberately left un-instrumented here. The field bundle
-- shows the same duplication shape on the send side (22,019 npc_claim lines in
-- 368 bursts, ~15x, with byte-identical coordinates repeated inside one frame),
-- but this is a one-machine session: a send-side change could not be observed,
-- only asserted. It goes to WO-70 with the evidence rather than shipping
-- unverified. Same mechanism, same fix shape, different burden of proof.
KCD2MP.npcPuppetGen   = 0
KCD2MP.npcChainFix    = false  -- mp_npc_chainfix on|off
KCD2MP._chainLeakSeen = {}     -- "puppet" / "interp" -> true, so the line logs once per chain kind
-- WO-84: _chainLeakSeen is a latch that is never reset, so ONE firing silences
-- the report for the rest of the session. That was tolerable while a firing
-- was assumed to be rare and real; the 2026-09-11 session showed a firing that
-- was neither (see the retirement note in KCD2MP_NpcPuppetTick). Counting them
-- separately from reporting them means a later firing is still visible even
-- though the loud line and the toast stay once-per-session.
KCD2MP._chainLeakN = {}
-- WO-84: generations that stopped THEMSELVES and still have one scheduled
-- successor timer in flight. See KCD2MP_NpcPuppetTick's retirement check.
KCD2MP._npcPuppetRetired = {}
KCD2MP._npcPuppetRetiredN = 0  -- orphan timers absorbed (diagnostic)
-- WO-84: the same retirement for the ghost interp chain. KCD2MP_Stop is the
-- only place that clears interpRunning, and it does so while a generation's
-- timer is in flight -- so a Stop immediately followed by a Start (a
-- reconnect) has the identical orphan race. PREVENTATIVE: unlike the puppet
-- case this has never been observed in a field log, and it is recorded that
-- way rather than claimed as a fixed bug.
KCD2MP._interpRetired = {}
KCD2MP._interpRetiredN = 0
-- WO-78: both stale-chain exits default ON. WO-69's rule was "observe-only
-- until a log line shows two chains alive at once"; the 2026-09-11 session
-- showed exactly that on both machines (host: puppet gen=1 alive at gen=8;
-- joiner: gen=5 alive at gen=9) with `mp_npc_chainfix` never toggled -- the
-- observe-only default produced the observation and then could do nothing
-- with it. With chainMayStart refusing the false restart in the first place,
-- a stale chain can now only exist through a bug, and two chains writing one
-- entity is never wanted. The toggles stay as the rollback.
KCD2MP.npcChainFix = true
KCD2MP.ghostChainFix = true

-- WO-84: how long a ghost's looped locomotion clip may play before it is
-- restarted as a keep-alive, in seconds. 0 restores the pre-WO-84 behaviour
-- (restart on EVERY tick) as the rollback -- see mp_anim_loop for why that
-- was a defect and what it cost in the 2026-09-11 field session.
KCD2MP.ghostAnimRefreshS = 1.0

function KCD2MP_SetGhostChainFix(arg)
    local s = tostring(arg or ""):lower()
    if s == "on" or s == "1" or s == "true" then
        KCD2MP.ghostChainFix = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.ghostChainFix = false
    end
    mp_log("mp_ghost_chainfix = " .. tostring(KCD2MP.ghostChainFix)
        .. " (interp gen=" .. tostring(KCD2MP.interpGen) .. ", false restarts refused="
        .. tostring(KCD2MP._chainSuspendedN or 0) .. ")")
end

-- WO-69: measured inbound packet cadence. Before this there was NO per-packet
-- record anywhere in the mod, so every cadence number in the WO-69 diagnosis
-- except the emitter's own `emitMs = 250` was a proxy inferred from
-- animation-tag transitions. WO-70 cannot tune a dead-reckoning layer against
-- a cadence nobody has measured. Summarised on a 5 s cadence rather than
-- logged per packet -- a per-packet line at 4 Hz x N puppets is exactly the
-- log volume that changed what it was measuring in WO-39.
-- WO-95: `n/sum/min/max` now cover MOTION-to-MOTION gaps only; `idleN`
-- counts the emitter's idle heartbeats, which are by design `heartbeatS`
-- apart and must not be averaged into the cadence a jitter fix tunes on.
KCD2MP.npcPacketStats = { n = 0, sum = 0, min = 1e9, max = 0, idleN = 0, dumpAt = 0 }

KCD2MP.npcPuppets        = {} -- name -> {tx,ty,tz,tr,hp,dead,cx,cy,cz,cr,lastPacketAt,animTag}
KCD2MP.npcOversized      = {} -- name -> item class GUID whose draw must go through DrawFromInventory (WO-49)

-- WO-106 Phase 3 mitigation: the puppet write/tick rate, runtime-settable
-- (mp_puppet_rate <ms>) instead of hardcoded, so a live session can find
-- the rate where ground-collider sinking (docs/WO-106-findings.md,
-- WO-105-cryengine-reference.md S4.4/17.1) stops without a rebuild. 50ms
-- is the value every session before this one used, unchanged as the
-- default. Read fresh by KCD2MP_NpcPuppetTick's own reschedule each tick,
-- so a change takes effect on the VERY NEXT tick, not next restart.
KCD2MP.npcPuppetTickMs   = 50

-- ===== WO-86: NPC death sync =====
--
-- The field report: a villager killed by one player stayed alive, hurt and
-- walking on the other player's screen, and the corpse on the killer's screen
-- kept moving afterwards. Traced from code (docs/WO-86-findings.md):
--
--   * No NPC death was ever on the wire. 0x14/0x15 exist since WO-4 with a
--     relay route and a receiver, and no client ever sent one; the DLL's
--     LocalHit frame dropped its own `died` bit. So each world decided
--     "dead" alone from health deltas -- and the DLL reports a killing blow
--     as the hp the victim had LEFT, so a peer copy with more hp survives it
--     forever. Nothing reconciled the two.
--   * The corpse moved because of the WO-38 body-follow branch in
--     KCD2MP_NpcPuppetTick: it let a locally-dead body follow a stream move of
--     more than 0.5 m, meant for the authority dragging a corpse -- but it
--     never asked whether the STREAM thought the body was dead. A stream from
--     a world where the NPC is alive and walking teleported the corpse along
--     the walk.
--
-- What ships here:
--   1. The safeguard: a body that is dead/KO only LOCALLY (stream says alive)
--      gets no writes at all, and says so once per body. Body-follow is kept
--      exactly for the case it was built for: the stream itself says the body
--      is down.
--   2. The observer: every place this file already reads actor:IsDead() for a
--      world NPC (emitter, drag sensor, puppet tick) reports into
--      mp_npc_death_observe; a WITNESSED alive->dead transition is announced
--      once as an `npc_death` event line, which the agent sends as a
--      zero-delta 0x30 with the FATAL bit (Protocol.cs). The DLL's own
--      frame-accurate `died` bit (also new in WO-86) takes the same wire path
--      and marks the body announced so the observer stays quiet for it.
--   3. The receiver: the agent applies an inbound death through the DLL
--      (ApplyDeath, idempotent) and tells this file first via
--      KCD2MP_NpcRemoteDeath, so the local IsDead flip it causes is not
--      announced back.
--
-- `mp_npc_deathsync on|off`, default ON (WO-78 precedent: a structural fix
-- ships on, with a live rollback). Off restores the pre-WO-86 puppet branch
-- verbatim, stops announcing, and (mirrored in the agent) stops applying.
KCD2MP.npcDeathSync        = true
KCD2MP._npcDeathSeen       = {}  -- name -> last observed actor:IsDead() (nil = never read)
KCD2MP._npcDeathAnnounced  = {}  -- name -> "lua"|"dll": this death already went out
KCD2MP._npcDeathRemote     = {}  -- name -> {via, at}: this death was applied FROM a peer (puppet held still 10 s from `at`)
KCD2MP._npcDeathDiverged   = {}  -- name -> true once the divergence line was logged
KCD2MP._npcDeathSuppressedN = 0  -- corpse writes refused by the safeguard (session total)

-- One reader, three callers. `src` names the caller for the log; `hp` is
-- whatever the caller already had (-1 for unknown). Returns true when this
-- call announced a death.
local function mp_npc_death_observe(name, dead, hp, src)
    local was = KCD2MP._npcDeathSeen[name]
    KCD2MP._npcDeathSeen[name] = dead
    if was == nil then
        if dead then
            -- First sight, already dead: a corpse from a save or a fight that
            -- ended before we looked. Never announced -- there is no
            -- transition here, and a peer's living NPC must not die to a
            -- stranger's savegame.
            mp_log(string.format("NPC-DEATH %s first seen already dead (by %s) -- not announced", name, src))
        end
        return false
    end
    if dead and not was then
        -- WO-94: inside a catch-up window this transition is a candidate
        -- consequence of the replay (WO-92 s6.4 hazard 2) -- one extra line.
        if KCD2MP_QuestHazard then
            KCD2MP_QuestHazard("npc-death", string.format("%s died here (by %s, hp=%s)", name, src, tostring(hp)))
        end
        local remote = KCD2MP._npcDeathRemote[name]
        local announced = KCD2MP._npcDeathAnnounced[name]
        if remote then
            mp_log(string.format("NPC-DEATH %s died here (by %s, hp=%s) -- applied from a peer via %s, not announced",
                name, src, tostring(hp), tostring(remote.via)))
        elseif announced then
            mp_log(string.format("NPC-DEATH %s died here (by %s, hp=%s) -- already announced by %s",
                name, src, tostring(hp), tostring(announced)))
        elseif not KCD2MP.npcDeathSync then
            mp_log(string.format("NPC-DEATH %s died here (by %s, hp=%s) -- mp_npc_deathsync off, NOT announced",
                name, src, tostring(hp)))
        else
            KCD2MP._npcDeathAnnounced[name] = "lua"
            mp_log(string.format("NPC-DEATH %s died here (by %s, hp=%s) -- witnessed alive->dead, announcing (npc_death)",
                name, src, tostring(hp)))
            KCD2MP_EmitEvent("npc_death", string.format("%s %s %s", name, tostring(hp), src))
            return true
        end
    elseif was and not dead then
        -- A body we saw dead reads alive: a save reload (WO-13/WO-59), or a
        -- different entity answering to the name. Forget the death so the
        -- next one can be announced again.
        mp_log(string.format("NPC-DEATH %s reads ALIVE again (by %s) -- was dead; reload? clearing its death marks", name, src))
        KCD2MP._npcDeathAnnounced[name] = nil
        KCD2MP._npcDeathRemote[name] = nil
        KCD2MP._npcDeathDiverged[name] = nil
    end
    return false
end

-- Agent -> mod, before it applies a peer's death through the DLL: log this
-- world's state for the body, mark the death remote so the observer does not
-- announce it back, and flag the puppet entry dead so the puppet tick stops
-- writing it on this very tick rather than after the stream catches up.
function KCD2MP_NpcRemoteDeath(name, via)
    if KCD2MP_QuestHazard then KCD2MP_QuestHazard("npc-death-remote", tostring(name) .. " killed by a peer's packet via " .. tostring(via)) end
    local e = System.GetEntityByName(name)
    local dead, hp = nil, -1
    if e and e.actor then
        pcall(function() dead = e.actor:IsDead() == true end)
        pcall(function() hp = e.actor:GetHealth() or -1 end)
    end
    local p = KCD2MP.npcPuppets[name]
    mp_log(string.format("NPC-DEATH %s: peer says dead (via %s); local copy %s, IsDead=%s hp=%s, puppet=%s%s",
        name, tostring(via),
        e and "loaded" or "NOT LOADED", tostring(dead), tostring(hp),
        p and "yes" or "no",
        KCD2MP.npcDeathSync and "" or " -- mp_npc_deathsync off, agent will not apply"))
    if not KCD2MP.npcDeathSync then return false end
    KCD2MP._npcDeathRemote[name] = { via = tostring(via), at = os.clock() }
    if p then p.dead = true end
    return true
end

-- Agent -> mod: the DLL's FATAL LocalHit already announced this body's death
-- on the wire; the observer must not send a second one.
function KCD2MP_NpcDeathAnnounced(name, src)
    if not KCD2MP._npcDeathAnnounced[name] then
        KCD2MP._npcDeathAnnounced[name] = tostring(src or "dll")
        mp_log(string.format("NPC-DEATH %s announced by %s (FATAL hit on the wire)", name, tostring(src or "dll")))
    end
end

function KCD2MP_SetNpcDeathSync(arg)
    local s = tostring(arg or ""):lower()
    if s == "on" or s == "1" or s == "true" then
        KCD2MP.npcDeathSync = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.npcDeathSync = false
    else
        mp_log("mp_npc_deathsync: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return
    end
    mp_log("NPC-DEATH sync " .. (KCD2MP.npcDeathSync and "enabled" or "disabled (pre-WO-86 behaviour: corpse body-follow on either source, no announce, no apply)"))
    KCD2MP_EmitEvent("npc_deathsync", KCD2MP.npcDeathSync and "on" or "off")
end
-- WO-90: divergence release. When the local engine repeatedly drags a
-- puppeted NPC far away from where the inbound stream is putting it, the two
-- worlds are at different story beats and no amount of position smoothing can
-- reconcile them -- the body belongs to whichever world is actually using it.
-- The receiver gives up, releases the puppet and stands off for a cooldown.
-- Thresholds are set from the 2026-09-12 field numbers: ordinary brain
-- contention displaces 0.05-0.6 m, the story divergence displaced 57.24 m.
-- `mp_npc_diverge on|off|<metres>`; off restores the pre-WO-90 behaviour
-- (fight forever, log every 5 s) exactly, for a live A/B.
KCD2MP.npcDiverge          = true

-- WO-99 Phase 2: sub-8 m yield arbitration (WO-98 s3a, landed).
--
-- Below the WO-90 release threshold nothing arbitrated the puppet write
-- against the local brain: KCD2MP_NpcPuppetTick wrote SetWorldPos every
-- 50 ms and the brain moved the body back, forever. 2026-09-16 cabin scene
-- (host, observed): `MP-NPCFIGHT npc=ttkc_drozd n=177 mean_m=0.07 max_m=0.08
-- window_s=10` -- 177 corrections in 10 s at 7 cm, three orders of magnitude
-- under 8 m, so the release never saw it; joiner session totals tzel_rowdy_2
-- 3826, tzel_rowdy_1 3448, tzel_bretislav 3429. The maintainer's "NPCs
-- glitching badly for the host, clean for the joiner, same scene" is exactly
-- this: they were puppets on the host (authority=peer) and locally driven on
-- the joiner.
--
-- Rule: when the readback displacement (where the engine put the body vs
-- where we wrote it one tick earlier) stays above `dispM` for `ticks`
-- consecutive ticks, stop writing that puppet -- yield to the brain while it
-- is walking -- and re-pin only when an inbound packet has moved the STREAM
-- TARGET more than `repinM` from where it was at yield time (the peer's copy
-- actually went somewhere). The body's own drift never re-pins, so a
-- yielded puppet cannot oscillate yield/re-pin against a stationary stream.
-- The WO-90 release still applies to written puppets; a yielded puppet is
-- already off the write path, so it is not measured until re-pinned.
--
-- Named risk (WO-51): an NPC the peer is fighting may walk off on this
-- machine. That is divergence made visible instead of jitter; a field report
-- of "NPC wandered away" is THIS, not a new bug.
--
-- Toggle: `mp_npc_yield_on` / `mp_npc_yield_off` (argless -- the console
-- drops arguments, docs/WO-98), `mp_npc_yield` reports; thresholds via
-- `#KCD2MP_SetNpcYield("0.3 10 1.0")` = dispM ticks repinM. Default ON.
-- Every yield and re-pin logs MP-NPCYIELD (docs/WO-98-log-format.md).
-- WO-108: `enabled` ships OFF. Under host authority (the shipped model) the
-- flag is never consulted -- KCD2MP_NpcPuppetTick's host-authority branch
-- turns the same measurement into an MP-AUTHORITY-VIOLATION and never
-- yields (WO-102 Phase 4) -- so this is a no-op flip that stops the status
-- line claiming a mechanism that cannot fire. dispM/ticks stay LIVE: they
-- are the contention detector's thresholds. mp_preset_legacy restores on.
KCD2MP.npcYield = { enabled = false, dispM = 0.30, ticks = 10, repinM = 1.0 }
KCD2MP._npcYieldN, KCD2MP._npcRepinN = 0, 0

function KCD2MP_SetNpcYield(arg)
    local s = tostring(arg or ""):lower()
    local y = KCD2MP.npcYield
    if s == "on" or s == "1" or s == "true" then
        y.enabled = true
    elseif s == "off" or s == "0" or s == "false" then
        y.enabled = false
        -- a puppet already yielded resumes writing on the next tick
        for _, p in pairs(KCD2MP.npcPuppets or {}) do p.yielded, p.yieldStreak = nil, 0 end
    else
        local d, t, r = string.match(s, "^%s*([%d%.]+)%s+(%d+)%s+([%d%.]+)%s*$")
        if d then
            y.dispM, y.ticks, y.repinM = tonumber(d), tonumber(t), tonumber(r)
        elseif s ~= "" and s ~= "%line" then
            mp_log("mp_npc_yield: expected on|off|<dispM> <ticks> <repinM>, got '" .. tostring(arg) .. "'")
            return false
        end
    end
    mp_log(string.format("NPC-YIELD %s dispM=%.2f ticks=%d repinM=%.2f yields=%d repins=%d",
        y.enabled and "ENABLED" or "disabled (pre-WO-99: write every tick below 8 m)",
        y.dispM, y.ticks, y.repinM, KCD2MP._npcYieldN or 0, KCD2MP._npcRepinN or 0))
    KCD2MP_ShowInteractionMsg("NPC puppet yield: " .. (y.enabled and "ON" or "OFF"))
    return true
end
local MP_NPC_DIVERGE_M          = 8.0    -- metres in one tick that cannot be footwork
local MP_NPC_DIVERGE_HITS       = 3      -- far readings needed inside the window
local MP_NPC_DIVERGE_WINDOW_S   = 30.0   -- sliding window
local MP_NPC_DIVERGE_COOLDOWN_S = 180.0  -- how long the name refuses to re-puppet (WO-90 shipped 60; WO-94 raised to 3 min at the maintainer's direction)
KCD2MP._npcDivergeUntil    = {}          -- name -> os.clock() the stand-off ends
KCD2MP._npcDivergeN        = 0

-- `mp_npc_diverge on|off|<metres>`. A bare number sets the distance threshold
-- and leaves the release enabled, so the field can widen or tighten it without
-- a rebuild.
function KCD2MP_SetNpcDiverge(arg)
    local s = tostring(arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(s)
    if s == "" or s == "%line" then
        -- Bare invocation reports, like mp_weather. The console substitutes
        -- the literal "%LINE" when no argument was typed.
        mp_log(string.format("NPC-DIVERGE release is %s (threshold %.1fm, %d hits in %.0fs,"
            .. " %.0fs stand-off; released %d so far). Usage: mp_npc_diverge on|off|<metres>",
            KCD2MP.npcDiverge and "ON" or "OFF", MP_NPC_DIVERGE_M, MP_NPC_DIVERGE_HITS,
            MP_NPC_DIVERGE_WINDOW_S, MP_NPC_DIVERGE_COOLDOWN_S, KCD2MP._npcDivergeN or 0))
        return
    elseif n and n > 0 then
        MP_NPC_DIVERGE_M = n
        KCD2MP.npcDiverge = true
    elseif s == "on" or s == "1" or s == "true" then
        KCD2MP.npcDiverge = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.npcDiverge = false
        KCD2MP._npcDivergeUntil = {}   -- drop stand-offs so the rollback is immediate
    else
        mp_log("mp_npc_diverge: expected 'on', 'off' or a distance in metres, got '" .. tostring(arg) .. "'")
        return
    end
    mp_log(string.format("NPC-DIVERGE release %s (threshold %.1fm, %d hits in %.0fs, %.0fs stand-off; released %d so far)",
        KCD2MP.npcDiverge and "enabled" or "disabled (pre-WO-90: fight forever)",
        MP_NPC_DIVERGE_M, MP_NPC_DIVERGE_HITS, MP_NPC_DIVERGE_WINDOW_S,
        MP_NPC_DIVERGE_COOLDOWN_S, KCD2MP._npcDivergeN or 0))
end

KCD2MP.npcPuppetRunning  = false
KCD2MP._npcPuppetAliveAt = nil

-- Per-entity authority migration (WO-39 Phase 2). A NON-authority player
-- physically manipulating a downed body (dragging/carrying) claims that
-- body's stream by emitting state for it -- the relay's per-entity table
-- (first claim wins, TimeSkip shape) arbitrates and mutes the global
-- authority's stream for that entity while the claim is fresh.
KCD2MP.dragWatch = {}   -- name -> {x,y,z}   last sampled position of a nearby downed body
KCD2MP.dragging  = {}   -- name -> os.clock() of the last observed local move (claim window)
KCD2MP._dragScanAt = 0

-- WO-60: proximity-based NPC authority. With this on, a NON-authority also
-- runs the rescan/emit loop around its OWN player and claims nearby NPCs
-- through the relay's existing per-entity table (first claim wins, refresh
-- by packet, expiry on silence -- the drag sensor's mechanism, generalized).
-- NPCs someone else is already streaming are puppets here and are excluded
-- by the rescan, so claims only ever target entities nobody is driving.
-- This is the fix for WO-51 ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â§1.4's radius-gap and engagement-asymmetry rows:
-- an NPC fighting the non-authority player, previously invisible to sync
-- because it was far from the host, is now streamed by the machine actually
-- next to it -- the one simulating it at full fidelity.
--
-- mp_npc_proximity off is the FIELD ROLLBACK: it restores the old host-only
-- tracking exactly (non-authority emits nothing but drag claims; standing
-- relay claims expire within seconds and the host's stream resumes).
KCD2MP.npcProx = {
    enabled = true,   -- mp_npc_proximity on|off (mp_npc_sync default-on precedent)
}

-- ===== WO-102: host-authoritative NPCs -- the toggle set =====
-- Every behavioural change WO-102 makes sits behind one of these, flips at
-- runtime without a restart, and returns the 0.23.2 code path exactly when
-- off. They are the instrument Phase 7's A/B measures with, not safety
-- furniture: an A/B that cannot switch mid-fight cannot measure anything.
--
-- Argless console commands only: the console drops arguments from
-- Lua-registered commands on this build (docs/WO-94, live), so every toggle
-- is a pair (`mp_<x>_on` / `mp_<x>_off`) plus one status command.
--
-- Defaults here are the mod's own, used when no agent ever pushes one. The
-- agent pushes ITS configured default at connect (KCD2MP_Wo102Set from the
-- agent, source "agent"), so the shipped default lives in ClientConfig and
-- this table mirrors it -- one source of truth, and an older agent that
-- pushes nothing leaves the mod at 0.23.2 behaviour.
--
--   authorityHost  mp_authority_host_on|off  Phase 4: the damage-authority
--                  holder (Rule 2, KCD2MP.hitSensorOn) owns EVERY NPC,
--                  permanently. Non-authorities never claim (the WO-60
--                  proximity emitter and the WO-39 drag claim are bypassed,
--                  not removed), the NPC-DIVERGE release is refused on an
--                  owned body, and the authority scans around every peer
--                  ghost as well as its own player. Off = the claim model.
--   posNative      mp_pos_native_on|off      Phase 1: the agent reads the
--                  local position/rotation/riding state through the DLL
--                  pipe instead of the [KCD2-MP-DATA] log line. Agent-side;
--                  the mod only relays the switch (and keeps emitting the
--                  log line, which stays the fallback).
--                  WO-102.5: ships ON. Still genuinely unverified live (zero
--                  path=native/LOCALSTATE lines in any bundle to date), but
--                  fail-closed on its own (GameBridge.cs: 20 consecutive
--                  pipe refusals or 20 samples >3m from the log-line oracle
--                  disarms it for the session, no player action needed) and
--                  both machines are expected on this build together, so the
--                  older-DLL stall this would otherwise risk does not apply.
--                  Same principle as npcScanNative below: unmeasured is not
--                  a reason to park a fail-closed path.
--   authorityPause mp_authority_pause_on|off Phase 3/4: the local-brain
--                  suppression lever. Under host authority a non-authority
--                  issues the engine's own `wh_ai_PauseNPC <name>` when a
--                  puppet starts and `wh_ai_ResumeNPC <name>` when it is
--                  released ("the pausing system", shipped console commands,
--                  docs/WO-102-findings.md S3). Does nothing unless
--                  authorityHost.
--                  WO-102.5 Phase 1 shipped it ON on the solo probe's 8/8
--                  (later 5/8). WO-104 shipped it OFF on a 2026-09-18
--                  two-machine reading (155 MP-AUTHORITY-VIOLATION, every
--                  one paused=1). WO-107 refuted that reading: `paused=1`
--                  reported THIS Lua table, not engine state, and the
--                  dist_m it fired on is the engine position-relax (WO-107
--                  s4), not a brain. The lever itself is
--                  C_IntelligentObject::Suspend -- latched, multi-owner,
--                  held through a 38 Hz stream, damage, combat and ~50 min
--                  (WO-107 s3, observed). WO-108 ships it ON again, with
--                  the suspend-set invariant (s2.2), identity logging
--                  (s3.1), a release dwell (s3.5) and mp_resume_all.
--                  WO-108 Phase 0 confirmed the suspension does NOT
--                  survive a save load (quick-load, wh_sys_LoadGame, cold
--                  relaunch -- observed). Resume is guaranteed on release/silence,
--                  toggle-off, host-authority-off, `mp_stop`
--                  (KCD2MP_Stop), the AGENT going away
--                  (KCD2MP_Wo102ResumeAll, called from GameBridge.cs's own
--                  disconnect path -- the game and its Lua state keep
--                  running without the agent, so this reaches them from
--                  outside), and a periodic reconciliation sweep (every 5s,
--                  from KCD2MP_NpcSyncTick) that resumes anything still
--                  believed-paused but no longer a tracked puppet -- the
--                  catch-all for peer disconnect and any other way a puppet
--                  stops existing without the normal release call. See
--                  docs/WO-102.5-findings.md S1 for what is and is not
--                  covered (notably: whether the pause survives INTO a
--                  savegame written mid-pause is still open, see S1.3 --
--                  there is no engine hook to resume-before-save, so the
--                  reconciliation sweep's 5s exposure window is the actual
--                  mitigation, not a real "before" guarantee).
--   npcScanNative  mp_npc_scan_native_on|off WO-102.5 Phase 2: the agent
--                  periodically calls the DLL's batched native NPC scan and
--                  pushes the candidate name list here as
--                  KCD2MP_ApplyNativeScan(csv); mp_npc_rescan reads it
--                  instead of walking System.GetEntitiesInSphere per anchor
--                  when this is on and the push is fresh. Agent-side (like
--                  posNative); the mod only relays the switch and keeps the
--                  Lua enumerate as the fallback. Live-verified once
--                  (2026-09-18 field session): 37,079 entities walked, zero
--                  vptr mismatches, known-answer check clean (only_lua=0)
--                  -- docs/WO-102.5-findings.md S6.2. ON by the maintainer's
--                  own call: exercise what is new rather than default back
--                  to the already-known-broken path.
-- Shipped defaults: host authority ON (replaces a known-broken model);
-- native position and the native NPC scan ON; the pause lever ON since
-- WO-108 (0.26.4) -- the agent does not push this one, so the Lua default
-- IS the shipped default. The agent pushes ClientConfig's values for the
-- other three at connect; these are what an agent that pushes nothing
-- leaves in place, so they agree with ClientConfig by construction.
-- `mp_preset_legacy` is the 0.26.3 set (lever off) in one command.
KCD2MP.wo102 = {
    authorityHost  = true,    -- mp_authority_host_off is the 0.23.2 claim model
    posNative      = true,    -- never run live; fail-closed, kept on per the maintainer's call (same principle as npcScanNative)
    authorityPause = true,    -- WO-108: ON. WO-104 turned it off on `paused=1` (this Lua table, not engine state) and a
                              -- dist_m that was the WO-107 s4 position-relax. WO-107 s3: the lever is
                              -- C_IntelligentObject::Suspend, latched and multi-owner, held solo through a 38 Hz
                              -- stream, melee damage, mid-combat application and ~50 min. WO-108 Phase 0: the
                              -- suspension does not survive any save-load path (observed). Two-player: UNVERIFIED --
                              -- this build exists to collect that evidence (docs/WO-108-peer-test-runbook.md).
    npcScanNative  = true,    -- live-verified clean 2026-09-18 (findings S6.2); kept on per the maintainer's call
}
KCD2MP._wo102Names = { authority_host = "authorityHost", pos_native = "posNative", authority_pause = "authorityPause", npc_scan_native = "npcScanNative" }

-- name: "authority_host" | "pos_native"; on: boolean; source: "console" | "agent".
function KCD2MP_Wo102Set(name, on, source)
    local field = KCD2MP._wo102Names[tostring(name)]
    if not field then
        mp_log("WO102-TOGGLE unknown toggle '" .. tostring(name) .. "'")
        return false
    end
    local want = (on == true or on == 1 or on == "on" or on == "true")
    local was = KCD2MP.wo102[field]
    KCD2MP.wo102[field] = want
    mp_log(string.format("WO102-TOGGLE name=%s state=%s was=%s source=%s",
        tostring(name), want and "on" or "off", was and "on" or "off", tostring(source or "console")))
    -- The agent owns the other half of every toggle (its own gates, and the
    -- relay's view of them); a console flip travels out on the event
    -- channel like npc_deathsync does. An agent-sourced push is not echoed
    -- back -- it would only bounce.
    if source ~= "agent" then
        KCD2MP_EmitEvent("wo102_toggle", tostring(name) .. " " .. (want and "on" or "off"))
    end
    if source ~= "agent" or was ~= want then
        KCD2MP_ShowInteractionMsg(string.format("%s: %s",
            field == "authorityHost" and "Host NPC authority"
                or field == "authorityPause" and "NPC brain pause lever"
                or field == "npcScanNative" and "Native NPC scan" or "Native position", want and "ON" or "OFF"))
    end
    -- Phase 4 hooks its side effects here (a non-authority dropping its
    -- claim stream on the spot when host authority switches on), Phase 1 has
    -- none in the mod.
    if KCD2MP_Wo102OnChange then pcall(KCD2MP_Wo102OnChange, field, want, was) end
    return true
end

function KCD2MP_Wo102Status()
    local paused, pending, ever = 0, 0, 0
    for _ in pairs(KCD2MP._npcPaused or {}) do paused = paused + 1 end
    for _ in pairs(KCD2MP._npcResumePending or {}) do pending = pending + 1 end
    for _ in pairs(KCD2MP._npcEverPaused or {}) do ever = ever + 1 end
    mp_log(string.format("WO102-STATUS authority_host=%s pos_native=%s authority_pause=%s npc_scan_native=%s authority=%s paused_npcs=%d"
        .. " pause_pending=%d pause_ever=%d pause_dwell_s=%.1f npc_replica=%s npc_yield=%s",
        KCD2MP.wo102.authorityHost and "on" or "off",
        KCD2MP.wo102.posNative and "on" or "off",
        KCD2MP.wo102.authorityPause and "on" or "off",
        KCD2MP.wo102.npcScanNative and "on" or "off",
        KCD2MP.hitSensorOn and "self" or "peer", paused, pending, ever,
        (KCD2MP.wo1025 and KCD2MP.wo1025.resumeDwellS) or 0,
        (KCD2MP.npcReplica and KCD2MP.npcReplica.enabled) and "on" or "off",
        (KCD2MP.npcYield and KCD2MP.npcYield.enabled) and "on" or "off"))
end

-- WO-102 Phase 2: MP-AUTHORITY -- per NPC, who owns it, how it was acquired,
-- how it was lost, how long it was held (docs/WO-98-log-format.md).
--
--   MP-AUTHORITY npc=<name> event=acquire|release|owner-change owner=<self|ghostId>
--                via=<how> held_s=<F1> model=claim|host [from=<ghostId>]
--
--   acquire via: authority-default  this client is the damage authority and
--                                   started streaming the NPC (owner=self)
--                claim              this non-authority started a proximity
--                                   claim stream for it (owner=self)
--                drag               the drag sensor claimed a downed body
--                stream             an inbound stream made it a puppet here
--                                   (owner = the sending ghost id)
--                repin              a yielded puppet was re-pinned
--   release via: untrack | drag-idle | silence | diverge | yield
--   owner-change: an existing puppet's packets now come from another sender
--                 (a claim moved at the relay); from= is the previous owner.
--
-- "owner=self" is this machine; a number is the peer ghost id whose stream
-- drives the body. Under the 0.23.2 claim model every NPC is expected to
-- change hands; under host authority (Phase 4) a non-authority must only ever
-- see acquire via=stream from the one authority and no owner-change at all --
-- that absence is what the Phase 7 A/B reads.
KCD2MP._authStats = { acquire = 0, release = 0, ownerChange = 0, pause = 0, resume = 0, violation = 0 }
local function mp_auth_log(name, event, owner, via, heldS, from)
    local st = KCD2MP._authStats
    if event == "acquire" then st.acquire = st.acquire + 1
    elseif event == "release" then st.release = st.release + 1
    elseif event == "owner-change" then st.ownerChange = st.ownerChange + 1
    elseif event == "pause" then st.pause = st.pause + 1
    elseif event == "resume" then st.resume = st.resume + 1 end
    mp_log(string.format("MP-AUTHORITY npc=%s event=%s owner=%s via=%s held_s=%.1f model=%s%s",
        tostring(name), event, tostring(owner), via, heldS or 0,
        KCD2MP.wo102.authorityHost and "host" or "claim",
        from ~= nil and (" from=" .. tostring(from)) or ""))
end

-- ===== WO-102 Phase 4: host authority -- the pause lever and the violation log =====
--
-- Under host authority (mp_authority_host_on) exactly one machine -- the
-- damage-authority holder, KCD2MP.hitSensorOn -- decides every NPC. What
-- that means in this file:
--   * a NON-authority never claims: KCD2MP_NpcSyncTick returns before the
--     drag sensor and the proximity emitter (both are bypassed, not removed);
--     flipping the toggle on drops any claim stream it was running;
--   * the AUTHORITY scans around every peer ghost as well as its own player
--     (mp_npc_rescan anchors), with the per-anchor cap, so the NPCs near the
--     other player are streamed too;
--   * a puppet is never handed back: the WO-90 divergence release and the
--     WO-99 yield are refused and logged as MP-AUTHORITY-VIOLATION instead --
--     under a single writer there is nothing to diverge FROM, so a body that
--     still moves on its own is a bug to see, not a case to accommodate;
--   * optionally (mp_authority_pause_on) the local brain of every puppet is
--     paused with the engine's own `wh_ai_PauseNPC <name>` ("Pauses the
--     execution of the NPC with given name", ConsoleHTMLHelp) and resumed on
--     release. That is the Phase 3 lever; its live behaviour is unverified,
--     so it ships off with `mp_probe_npc_pause` as the proof.
--
--   MP-AUTHORITY-VIOLATION npc=<name> kind=diverge|contention dist_m=<F2> owner=<id> paused=0|1 n=<int>
--   (per-NPC throttled to one line per 10 s; the count is exact)
KCD2MP._npcPaused = {}           -- name -> os.clock() when wh_ai_PauseNPC was issued. The mod's OWN bookkeeping,
                                 -- not engine state (WO-107 s3.4): a field derived from it is `pause_issued`, never `paused`.
KCD2MP._npcPauseExec = {}        -- name -> "ok" | "err:<msg>": pcall result of the last wh_ai_PauseNPC for the name
KCD2MP._npcEverPaused = {}       -- name -> true for every name paused this Lua session (mp_resume_all sweeps this set)
KCD2MP._npcResumePending = {}    -- name -> os.clock() deadline: released, pause held for the dwell (WO-108 s3.5)
KCD2MP._authViolationAt = {}     -- "name|kind" -> last logged
KCD2MP._authViolationN = {}      -- name -> count
KCD2MP._pauseStats = { relax = 0, gap = 0, reassert = 0, refusedNoPuppet = 0, refusedAuthority = 0, dwellResumes = 0, cancelled = 0 }
KCD2MP._chainDeadRestartAt = nil -- WO-108: stamped by chainMayStart when a chain is CONFIRMED dead (a save load); the
                                 -- reconcile sweep re-asserts every live puppet's pause after it (Phase 0: the engine
                                 -- forgets suspensions on a load while this Lua state survives it)
KCD2MP._pauseReassertedAt = 0

-- WO-108 s3.1: identity on every pause/resume line. The two clients resolve
-- a NAME to a body independently; if they disagree, the joiner suspends the
-- wrong NPC and the peer test reads exactly like WO-104 again. wuid is
-- soul:GetId() (the 64-bit ScriptHandle, WO-106 s1.4), eid the entity id's
-- hex tail (the WO-49 idiom). Same fields on both machines, greppable, so
-- the two kcd.logs can be diffed after a session.
local function mp_pause_identity(name)
    local e = nil
    pcall(function() e = System.GetEntityByName(name) end)
    if not e then return "wuid=? eid=? body=missing" end
    local wuid, eid = "?", "?"
    pcall(function()
        if e.soul and e.soul.GetId then
            local s = tostring(e.soul:GetId())
            wuid = string.match(s, "(%x+)%s*$") or s
        end
    end)
    pcall(function() eid = string.match(tostring(e.id), "(%x+)%s*$") or tostring(e.id) end)
    return string.format("wuid=%s eid=%s body=%s", tostring(wuid), tostring(eid), tostring(e.class or "?"))
end

--   MP-PAUSE npc=<name> event=pause|resume|release|cancel|reassert|refused wuid=<hex> eid=<hex> body=<class>
--            exec=ok|err:<msg>|none why=<via> owner=<id> held_s=<F1>
-- `exec` is the pcall verdict of System.ExecuteCommand -- the only reply the
-- console gives Lua. "The call succeeded" is not "the brain is suspended":
-- engine-side suspend state is not readable from Lua on this build.
local function mp_pause_log(name, event, exec, why, owner, heldS)
    mp_log(string.format("MP-PAUSE npc=%s event=%s %s exec=%s why=%s owner=%s held_s=%.1f",
        tostring(name), event, mp_pause_identity(name), tostring(exec or "none"), tostring(why or "?"),
        tostring(owner or "?"), heldS or 0))
end

-- WO-108 s2.2, the suspend-set invariant: a name is suspended ONLY while it
-- is a puppet this machine is writing -- never on radius entry, never from a
-- roster scan, never on the authority (its brains ARE the truth). A coverage
-- gap therefore produces a jittery NPC (today's behaviour), never a statue.
local function mp_wo102_pause(name, p)
    if not (KCD2MP.wo102.authorityHost and KCD2MP.wo102.authorityPause) then return end
    if KCD2MP.hitSensorOn then
        KCD2MP._pauseStats.refusedAuthority = KCD2MP._pauseStats.refusedAuthority + 1
        if not KCD2MP._pauseRefusedAuthLogged then
            KCD2MP._pauseRefusedAuthLogged = true
            mp_pause_log(name, "refused", "none", "this-machine-is-authority", p and p.owner or "?", 0)
        end
        return
    end
    if not KCD2MP.npcPuppets[name] then
        KCD2MP._pauseStats.refusedNoPuppet = KCD2MP._pauseStats.refusedNoPuppet + 1
        mp_pause_log(name, "refused", "none", "not-a-puppet", p and p.owner or "?", 0)
        return
    end
    if KCD2MP._npcResumePending[name] then
        -- The stream came back inside the dwell: the engine bit is still set.
        KCD2MP._npcResumePending[name] = nil
        KCD2MP._pauseStats.cancelled = KCD2MP._pauseStats.cancelled + 1
        mp_pause_log(name, "cancel", "none", "stream-back-inside-dwell", p and p.owner or "?",
            os.clock() - (KCD2MP._npcPaused[name] or os.clock()))
        return
    end
    if KCD2MP._npcPaused[name] then return end
    KCD2MP._npcPaused[name] = os.clock()
    KCD2MP._npcEverPaused[name] = true
    local ok, err = pcall(System.ExecuteCommand, "wh_ai_PauseNPC " .. tostring(name))
    local exec = ok and "ok" or ("err:" .. tostring(err))
    KCD2MP._npcPauseExec[name] = exec
    mp_auth_log(name, "pause", p and p.owner or "?", "wh_ai_PauseNPC", 0)
    mp_pause_log(name, "pause", exec, "puppet-start", p and p.owner or "?", 0)
    if not ok then mp_log("WO102-PAUSE ExecuteCommand failed for " .. tostring(name) .. ": " .. tostring(err)) end
end

-- The unconditional resume: wh_ai_ResumeNPC now, forget the name.
local function mp_wo102_resume(name, why)
    local at = KCD2MP._npcPaused[name]
    if not at then return end
    KCD2MP._npcPaused[name] = nil
    KCD2MP._npcResumePending[name] = nil
    local ok, err = pcall(System.ExecuteCommand, "wh_ai_ResumeNPC " .. tostring(name))
    local exec = ok and "ok" or ("err:" .. tostring(err))
    mp_auth_log(name, "resume", "?", why, os.clock() - at)
    mp_pause_log(name, "resume", exec, why, "?", os.clock() - at)
end

-- WO-108 s3.5: the release used when WRITES STOP (silence). The pause is held
-- for wo1025.resumeDwellS so a stream that comes straight back (a cull
-- boundary, a packet gap, the joiner walking the radius edge) does not cost a
-- resume, a ~14 s re-plan (WO-107 s10) and a re-pause. A stream that stays
-- away resumes from mp_wo102_pending_tick when the deadline passes. Dwell 0
-- is the 0.26.3 behaviour (resume the moment the puppet drops).
local function mp_wo102_release(name, why)
    if not KCD2MP._npcPaused[name] then return end
    local dwell = (KCD2MP.wo1025 and KCD2MP.wo1025.resumeDwellS) or 0
    if dwell <= 0 then mp_wo102_resume(name, why); return end
    if not KCD2MP._npcResumePending[name] then
        KCD2MP._npcResumePending[name] = os.clock() + dwell
        mp_pause_log(name, "release", "none", tostring(why) .. "+dwell", "?", os.clock() - KCD2MP._npcPaused[name])
    end
end

local function mp_wo102_resume_all(why)
    local names = {}
    for name in pairs(KCD2MP._npcPaused) do names[#names + 1] = name end
    for _, name in ipairs(names) do mp_wo102_resume(name, why) end
end

-- Every KCD2MP_NpcSyncTick (100 ms): dwell deadlines.
local function mp_wo102_pending_tick()
    local now = os.clock()
    local due = nil
    for name, deadline in pairs(KCD2MP._npcResumePending) do
        if now >= deadline then due = due or {}; due[#due + 1] = name end
    end
    if not due then return end
    for _, name in ipairs(due) do
        KCD2MP._pauseStats.dwellResumes = KCD2MP._pauseStats.dwellResumes + 1
        mp_wo102_resume(name, "dwell")
    end
end

-- WO-102.5 Phase 1: the agent's own disconnect/shutdown path (GameBridge.cs,
-- alongside its existing KCD2MP_RemoveAllGhosts() call) has no other way to
-- reach this local function. Guarantees resume when the AGENT goes away --
-- closed, crashed, or the relay dropped it -- even though the game and its
-- Lua state keep running.
function KCD2MP_Wo102ResumeAll(why)
    mp_wo102_resume_all(tostring(why or "agent-disconnect"))
end

-- WO-102.5 Phase 1 / WO-108 s2.2: the safety net and the coverage-gap
-- detector. Rate-limited by the caller (KCD2MP_NpcSyncTick); runs regardless
-- of npcSync.enabled or authority role, since a stray pause can outlive
-- either. Three cases per believed-paused name:
--   * no puppet and no pending dwell  -> MP-PAUSE-GAP reason=untracked, resume
--     (via=reconcile -- the WO-102.5 line, kept verbatim)
--   * a puppet that has received no packet for releaseS + this interval ->
--     MP-PAUSE-GAP reason=no-writes, drop the puppet, resume. The puppet tick
--     should have released it at releaseS; if it did not, the chain is dead
--     or suspended and the body must not stay a statue. Greppable: this line
--     IS the coverage-gap detector the invariant asks for.
--   * a live puppet after a confirmed-dead chain restart (a save load) ->
--     re-issue wh_ai_PauseNPC (Suspend is idempotent: mask |= bit).
local NPC_RECONCILE_INTERVAL_S = 5.0
local function mp_wo102_pause_gap_s()
    return ((KCD2MP.npcSync and KCD2MP.npcSync.releaseS) or 3.0) + NPC_RECONCILE_INTERVAL_S
end
local function mp_wo102_reconcile_pauses()
    local now = os.clock()
    local gapS = mp_wo102_pause_gap_s()
    local reload = KCD2MP._chainDeadRestartAt ~= nil and KCD2MP._chainDeadRestartAt > (KCD2MP._pauseReassertedAt or 0)
    local gaps, reassert = {}, {}
    for name in pairs(KCD2MP._npcPaused) do
        local p = KCD2MP.npcPuppets[name]
        if not p then
            if not KCD2MP._npcResumePending[name] then gaps[#gaps + 1] = { name, "untracked", 0 } end
        elseif (now - (p.lastPacketAt or 0)) > gapS then
            gaps[#gaps + 1] = { name, "no-writes", now - (p.lastPacketAt or 0) }
        elseif reload then
            reassert[#reassert + 1] = name
        end
    end
    for _, g in ipairs(gaps) do
        local name, reason, age = g[1], g[2], g[3]
        KCD2MP._pauseStats.gap = KCD2MP._pauseStats.gap + 1
        mp_log(string.format("MP-PAUSE-GAP npc=%s reason=%s age_s=%.1f -- paused but not being written; resuming (WO-108 coverage-gap detector)",
            tostring(name), reason, age or 0))
        if reason == "no-writes" then KCD2MP.npcPuppets[name] = nil end
        mp_wo102_resume(name, reason == "untracked" and "reconcile" or "gap-no-writes")
        mp_log("WO102-AUTHORITY reconcile: resumed " .. tostring(name) .. " (paused but no longer a tracked puppet)")
    end
    if reload then
        KCD2MP._pauseReassertedAt = now
        for _, name in ipairs(reassert) do
            KCD2MP._pauseStats.reassert = KCD2MP._pauseStats.reassert + 1
            local ok, err = pcall(System.ExecuteCommand, "wh_ai_PauseNPC " .. tostring(name))
            local exec = ok and "ok" or ("err:" .. tostring(err))
            KCD2MP._npcPauseExec[name] = exec
            mp_pause_log(name, "reassert", exec, "chain-dead-restart", (KCD2MP.npcPuppets[name] or {}).owner or "?",
                now - (KCD2MP._npcPaused[name] or now))
        end
        if #reassert > 0 then
            mp_log(string.format("MP-PAUSE reasserted %d pause(s) after a confirmed-dead chain restart (a save load forgets engine suspensions -- WO-108 Phase 0)", #reassert))
        end
    end
end

-- WO-108 s3.3: the WO-107 s4 position-relax, tagged instead of counted as a
-- violation. Stop writing a body and it returns to its pre-write anchor on a
-- clean exponential (ratio ~0.32 per ~1.2 s sample, settled in ~5 s) --
-- paused, unpaused and NoAI alike, so it is neither brain nor mod. Between
-- two puppet writes the same pull moves the body a few percent of its
-- distance to the anchor, straight AT the anchor. That is the signature:
-- displacement pointing at the puppet's creation anchor (cos >= 0.90) with a
-- magnitude that is a small fraction of the distance to it (1.5%..12% per
-- 50 ms tick, scaled with mp_puppet_rate). A brain walking (a fixed ~0.05 m
-- per tick whatever the distance) falls below the band on any anchor further
-- than ~3 m; a 131 m yank is far above it -- both still report as what they
-- are. Tagged lines still log (kind=relax, with anchor_m and cos so the tag
-- can be audited), and count in pause_relax; they never feed the replica
-- trigger. Heuristic, stated as such; root-causing the relax is out of scope.
local MP_RELAX_COS_MIN   = 0.90
local MP_RELAX_RATIO_MIN = 0.015
local MP_RELAX_RATIO_MAX = 0.12
local function mp_wo102_relax_shaped(p, fx, fy)
    if not (p and p.ax and p.lastWroteX) then return false, 0, 0 end
    local axv, ayv = p.ax - p.lastWroteX, p.ay - p.lastWroteY
    local aLen = math.sqrt(axv * axv + ayv * ayv)
    local fLen = math.sqrt(fx * fx + fy * fy)
    if aLen < 0.5 or fLen <= 0 then return false, 0, aLen end
    local cosA = (fx * axv + fy * ayv) / (fLen * aLen)
    local ratio = fLen / aLen
    local scale = math.max(1.0, (KCD2MP.npcPuppetTickMs or 50) / 50)
    return (cosA >= MP_RELAX_COS_MIN and ratio >= MP_RELAX_RATIO_MIN and ratio <= MP_RELAX_RATIO_MAX * scale), cosA, aLen
end

--   MP-AUTHORITY-VIOLATION npc=<name> kind=diverge|contention|relax dist_m=<F2> owner=<id>
--                          pause_issued=0|1 pause_exec=ok|err:..|none n=<int> body=npc|replica anchor_m=<F2> cos=<F2>
--   (per-NPC, per-kind throttled to one line per 10 s; the count is exact)
-- WO-108 s3.2: `paused=` is gone. `pause_issued` is what it always was -- the
-- mod believes it issued a pause -- and `pause_exec` is the console call's
-- pcall verdict. Neither is engine state; that is not readable from Lua here.
local function mp_wo102_violation(name, p, kind, distM, fx, fy)
    local cosA, anchorM = 0, 0
    if fx ~= nil and kind == "contention" then
        local relax
        relax, cosA, anchorM = mp_wo102_relax_shaped(p, fx, fy)
        if relax then kind = "relax" end
    end
    local st = KCD2MP._authStats
    if kind == "relax" then
        KCD2MP._pauseStats.relax = KCD2MP._pauseStats.relax + 1
    else
        st.violation = st.violation + 1
    end
    KCD2MP._authViolationN[name] = (KCD2MP._authViolationN[name] or 0) + 1
    local now = os.clock()
    local tkey = tostring(name) .. "|" .. kind
    if (now - (KCD2MP._authViolationAt[tkey] or -1e9)) >= 10.0 then
        KCD2MP._authViolationAt[tkey] = now
        mp_log(string.format("MP-AUTHORITY-VIOLATION npc=%s kind=%s dist_m=%.2f owner=%s pause_issued=%d pause_exec=%s n=%d body=%s anchor_m=%.2f cos=%.2f",
            tostring(name), kind, distM or 0, tostring(p and p.owner or "?"),
            KCD2MP._npcPaused[name] and 1 or 0, tostring(KCD2MP._npcPauseExec[name] or "none"),
            KCD2MP._authViolationN[name],
            (KCD2MP._npcReplicas or {})[name] and "replica" or "npc", anchorM or 0, cosA or 0))
    end
    if kind == "relax" then return end   -- tagged and counted; never a contention signal
    -- WO-104 Phase 1: a violation IS the contention signal. Promote (no-op
    -- unless mp_npc_replica_on) -- every event, not only the rate-limited log.
    if KCD2MP_NpcReplicaConsider then KCD2MP_NpcReplicaConsider(name, p, kind) end
    if (now - (KCD2MP._authViolationToastAt or -1e9)) >= 300.0 then
        KCD2MP._authViolationToastAt = now
        pcall(function() KCD2MP_ShowNativeToast("KCD2-MP: an NPC is being moved by this machine's own AI under host authority -- see kcd.log (MP-AUTHORITY-VIOLATION)") end)
    end
end

-- Toggle side effects (called by KCD2MP_Wo102Set).
function KCD2MP_Wo102OnChange(field, want, was)
    if field == "authorityHost" then
        if want and not KCD2MP.hitSensorOn then
            local n = 0
            for name, t in pairs(KCD2MP.npcTracked or {}) do
                n = n + 1
                mp_auth_log(name, "release", "self", "host-authority-on", os.clock() - ((t and t.since) or os.clock()))
            end
            KCD2MP.npcTracked = {}
            for name in pairs(KCD2MP.dragging or {}) do KCD2MP.dragging[name] = nil end
            mp_log(string.format("WO102-AUTHORITY host authority ON on a non-authority: dropped %d claim stream(s); this machine now only displays", n))
        elseif want then
            mp_log("WO102-AUTHORITY host authority ON on the authority: scanning around every peer ghost as well as this player")
        end
        if not want then
            mp_wo102_resume_all("host-authority-off")
            if KCD2MP_NpcReplicaDemoteAll then KCD2MP_NpcReplicaDemoteAll("host-authority-off") end   -- WO-104
        end
    elseif field == "authorityPause" then
        if not want then mp_wo102_resume_all("pause-lever-off") end
    end
end

-- ===== WO-108: the dwell setter, the panic button, the two presets =====

function KCD2MP_SetResumeDwell(arg)
    local s = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "%line" then
        mp_log(string.format("MP-PAUSE dwell=%.1fs (mp_resume_dwell <seconds>; 0 = resume the moment writes stop, the 0.26.3 behaviour)",
            KCD2MP.wo1025.resumeDwellS or 0))
        return true
    end
    local n = tonumber(s)
    if not n or n ~= n or n < 0 or n > 120 then
        mp_log("mp_resume_dwell rejected '" .. tostring(arg) .. "' -- expected seconds 0..120")
        return false
    end
    local was = KCD2MP.wo1025.resumeDwellS or 0
    KCD2MP.wo1025.resumeDwellS = n
    mp_log(string.format("MP-PAUSE dwell set=%.1fs was=%.1fs", n, was))
    return true
end

-- mp_resume_all: the panic button for the peer test. Switches the lever OFF
-- first (KCD2MP_Wo102Set -> OnChange resumes everything still believed
-- paused, and the puppet tick can no longer re-pause anything 50 ms later),
-- then issues wh_ai_ResumeNPC for every OTHER name this Lua session ever
-- paused -- resuming a context that is not suspended is a documented engine
-- no-op ("...in which it was not suspended", WO-107 s3.2), so the sweep is
-- safe and catches a pause the bookkeeping lost. mp_authority_pause_on or
-- mp_preset_clean brings the lever back.
function KCD2MP_ResumeAllPaused(why)
    why = tostring(why or "mp_resume_all")
    local leverWas = KCD2MP.wo102.authorityPause
    if leverWas then KCD2MP_Wo102Set("authority_pause", false, "resume-all") end
    mp_wo102_resume_all(why)   -- anything OnChange did not reach (lever already off)
    local names = {}
    for name in pairs(KCD2MP._npcEverPaused) do names[#names + 1] = name end
    table.sort(names)
    local swept = 0
    for _, name in ipairs(names) do
        local ok, err = pcall(System.ExecuteCommand, "wh_ai_ResumeNPC " .. name)
        mp_pause_log(name, "resume", ok and "ok" or ("err:" .. tostring(err)), why .. "-sweep", "?", 0)
        swept = swept + 1
    end
    KCD2MP._npcResumePending = {}
    mp_log(string.format("MP-PAUSE resume-all why=%s swept=%d lever_was=%s lever_now=off -- mp_authority_pause_on (or mp_preset_clean) to re-enable",
        why, swept, leverWas and "on" or "off"))
    KCD2MP_ShowInteractionMsg(string.format("Resumed %d NPC(s); NPC brain pause lever OFF", swept))
    return swept
end

-- mp_preset_clean = the 0.26.4 defaults, mp_preset_legacy = the 0.26.3
-- defaults, each re-applied in full so a mid-session tweak is undone too.
-- Neither touches the authority model: authority_host, pos_native and
-- npc_scan_native are the agent's (ClientConfig) and identical in both
-- builds. Every value set logs one MP-PRESET line.
KCD2MP._presets = {
    clean  = { authority_pause = true,  npc_replica = false, npc_yield = false, resume_dwell_s = 10.0 },
    legacy = { authority_pause = false, npc_replica = true,  npc_yield = true,  resume_dwell_s = 0.0 },
}
function KCD2MP_ApplyPreset(which)
    which = tostring(which or "")
    local P = KCD2MP._presets[which]
    if not P then mp_log("MP-PRESET unknown preset '" .. which .. "' (clean|legacy)"); return false end
    local n = 0
    local function set(key, from, to, apply)
        n = n + 1
        mp_log(string.format("MP-PRESET name=%s set=%s from=%s to=%s", which, key, tostring(from), tostring(to)))
        local ok, err = pcall(apply)
        if not ok then mp_log(string.format("MP-PRESET name=%s set=%s FAILED: %s", which, key, tostring(err))) end
    end
    local w, y = KCD2MP.wo1025, KCD2MP.npcYield
    set("authority_pause", KCD2MP.wo102.authorityPause, P.authority_pause, function() KCD2MP_Wo102Set("authority_pause", P.authority_pause, "preset") end)
    set("npc_replica",     KCD2MP.npcReplica.enabled,    P.npc_replica,     function() KCD2MP_SetNpcReplica(P.npc_replica) end)
    set("npc_yield",       y.enabled,                    P.npc_yield,       function() KCD2MP_SetNpcYield(P.npc_yield and "on" or "off") end)
    set("resume_dwell_s",  w.resumeDwellS,               P.resume_dwell_s,  function() KCD2MP_SetResumeDwell(P.resume_dwell_s) end)
    -- shared by both builds
    set("npc_yield_thresholds", string.format("%.2f %d %.2f", y.dispM, y.ticks, y.repinM), "0.30 10 1.00", function() KCD2MP_SetNpcYield("0.30 10 1.0") end)
    set("npc_cull",        w.npcCull,                    true,              function() KCD2MP_SetNpcCull("on") end)
    set("npc_diverge",     KCD2MP.npcDiverge,            "on (8 m)",        function() KCD2MP_SetNpcDiverge("8") end)
    set("npc_smooth",      KCD2MP.npcSmooth,             true,              function() KCD2MP_SetNpcSmooth("on") end)
    set("npc_deathsync",   KCD2MP.npcDeathSync,          true,              function() KCD2MP_SetNpcDeathSync("on") end)
    set("npc_chainfix",    KCD2MP.npcChainFix,           true,              function() KCD2MP_SetNpcChainFix("on") end)
    set("puppet_rate_ms",  KCD2MP.npcPuppetTickMs,       50,                function() KCD2MP_SetPuppetRate(50) end)
    set("authority_radius_m", w.authorityRadius,         300,               function() KCD2MP_SetAuthorityRadius("300") end)
    set("together_params", string.format("%.0f %.0f %.0f", w.togetherEnterM, w.togetherExitM, w.togetherDwellS), "60 90 10", function() KCD2MP_SetTogetherParams("60 90 10") end)
    set("npc_read_native", w.readNative,                 true,              function() KCD2MP_SetNpcReadNative("on") end)
    set("npc_proximity",   KCD2MP.npcProx.enabled,       true,              function() KCD2MP_EnableNpcProximity("on") end)
    set("npc_sync",        KCD2MP.npcSync.enabled,       true,              function() KCD2MP_EnableNpcSync("on") end)
    mp_log(string.format("MP-PRESET applied name=%s values=%d authority_model=untouched (authority_host=%s pos_native=%s npc_scan_native=%s)",
        which, n, KCD2MP.wo102.authorityHost and "on" or "off", KCD2MP.wo102.posNative and "on" or "off",
        KCD2MP.wo102.npcScanNative and "on" or "off"))
    KCD2MP_ShowInteractionMsg("Preset applied: " .. which .. (which == "clean" and " (0.26.4 defaults)" or " (0.26.3 defaults)"))
    if KCD2MP_Wo102Status then pcall(KCD2MP_Wo102Status) end
    return true
end


-- WO-40 Phase 5: dump every puppet's tug-of-war evidence -- how often the
-- entity was found away from where we wrote it, and the clustered positions
-- it kept being found at. Distinct clusters = distinct competing writers.
function KCD2MP_NpcFightReport()
    local n = 0
    for name, p in pairs(KCD2MP.npcPuppets or {}) do
        n = n + 1
        local attrs = ""
        for i, a in ipairs(p.attr or {}) do
            attrs = attrs .. string.format(" [%d] %.1f,%.1f n=%d", i, a.x, a.y, a.n)
        end
        mp_log(string.format("NPC-FIGHT %s fights=%d target=%.1f,%.1f attractors:%s",
            name, p.fightN or 0, p.tx or 0, p.ty or 0, attrs == "" and " none" or attrs))
    end
    if n == 0 then mp_log("NPC-FIGHT no active puppets") end
end

-- WO-40 Phase 0: field escape hatch for the ghost-mount crash suspect. Off
-- means every ghost mount uses the spawned proxy horse, never a real one.
function KCD2MP_SetHorseAdopt(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.horseAdoptEnabled = true
    elseif s:find("off") then KCD2MP.horseAdoptEnabled = false
    else
        mp_log("mp_horse_adopt: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("HorseAdopt " .. (KCD2MP.horseAdoptEnabled and "ENABLED" or "disabled -- proxy horses only"))
    KCD2MP_ShowInteractionMsg("Horse adoption: " .. (KCD2MP.horseAdoptEnabled and "ON" or "OFF"))
    return true
end

function KCD2MP_EnableNpcSync(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.npcSync.enabled = true
    elseif s:find("off") then
        KCD2MP.npcSync.enabled = false
        KCD2MP.npcTracked = {}   -- drop bookkeeping so re-enabling starts fresh
    else
        mp_log("mp_npc_sync: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    if KCD2MP.npcSync.enabled then KCD2MP_StartNpcSync() end
    mp_log("NPC-SYNC " .. (KCD2MP.npcSync.enabled and "ENABLED" or "disabled")
        .. " radius=" .. KCD2MP.npcSync.radius .. "m max=" .. KCD2MP.npcSync.maxTracked)
    KCD2MP_ShowInteractionMsg("NPC sync: " .. (KCD2MP.npcSync.enabled and "ON" or "OFF"))
    return true
end

-- WO-60: the proximity-authority rollback toggle. Off = the pre-WO-60
-- host-only tracking model, exactly: a non-authority's tracked set is
-- dropped on the spot so its claim stream stops within one tick, its relay
-- claims expire on silence, and the host's default stream resumes. The
-- authority's own behaviour never depended on this flag, so flipping it
-- there changes nothing -- no hybrid state exists to get stuck in.
function KCD2MP_EnableNpcProximity(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.npcProx.enabled = true
    elseif s:find("off") then
        KCD2MP.npcProx.enabled = false
        if not KCD2MP.hitSensorOn then
            KCD2MP.npcTracked = {}   -- stop the claim stream immediately
        end
    else
        mp_log("mp_npc_proximity: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("NPC-PROX " .. (KCD2MP.npcProx.enabled
        and "ENABLED (non-authority claims NPCs near its own player)"
        or "disabled (host-only tracking, pre-WO-60 behaviour)"))
    KCD2MP_ShowInteractionMsg("NPC proximity authority: " .. (KCD2MP.npcProx.enabled and "ON" or "OFF"))
    return true
end

-- WO-90: entity-name families that must NEVER enter NPC sync, in any role --
-- not tracked, not claimed, not puppeted, not accepted inbound.
--
-- "DialogTwin_<soul>": the engine spawns one of these per participant for
-- every staged conversation, INCLUDING "DialogTwin_Dude" for the local
-- player's own character, and hangs the conversation camera off it. The
-- 2026-09-12 field logs show the link explicitly, on both machines:
--   MasterSlaveManager is setting context: '5' for entities 'DialogTwin_Dude'
--   -> 'DialogTwin_DudeCharacterCameraAttachment'
-- These are class NPC and their names pass the ^[%w_]+$ authored-name test,
-- so before this change they were tracked, claimed and puppeted exactly like
-- a world NPC. Because both machines name them identically, one player's
-- conversation rig was driven by the OTHER player's copy: the host's own
-- DialogTwin_Dude became a puppet 1.2 s after the host opened a conversation
-- with Hans (host kcd.log 234102, 21:02:30.6) and was immediately rendered at
-- "anim DialogTwin_Dude -> sprint spd=10.62" -- a camera rig snapped across
-- the staging area. The joiner's own twin took the same treatment four times
-- (j2 kcd.log 158503/159446/160164/162965, apparent speeds 7.6 to 28.1 m/s).
-- The relay granted eight claims on DialogTwin_* names, held up to 618 s.
-- Nothing about a per-conversation stand-in is shareable: each world stages
-- its own conversation. See docs/WO-90-findings.md finding 3.
--
-- "kcd2mp_<id>": this mod's own ghost bodies. mp_is_mod_entity below tests by
-- entity REFERENCE, which goes stale after a save load while a same-named
-- body still exists in the world -- so a reloaded client tracked its peer's
-- ghost as if it were a world NPC (relay log, 15 attempts at 21:58:19-23,
-- all refused by WO-66's reserved-name gate). The relay already rejects
-- these (Protocol.NpcReservedNamePrefix); this stops the local side spending
-- one of only maxTracked=5 slots on a body it spawned itself.
local MP_NPC_NAME_EXCLUDE = { "DialogTwin_", "kcd2mp_" }

-- WO-99 Phase 0: the LOCAL PLAYER's own entity name ("Dude" on every
-- machine). The NPC-sync emitter is class-filtered (NPC/NPC_Female) so the
-- player never enters the tracked set from this side, but an inbound stream
-- or a damage packet carrying that name resolves to OUR player here -- the
-- 2026-09-16 collision (docs/WO-99-findings.md Phase 0). Read from the live
-- player entity, not hard-coded, so a renamed player entity is still caught.
KCD2MP._localPlayerName = nil
local function mp_local_player_name()
    if KCD2MP._localPlayerName == nil then
        local n = false
        pcall(function()
            if player and type(player.GetName) == "function" then n = player:GetName() or false end
        end)
        KCD2MP._localPlayerName = n
    end
    return KCD2MP._localPlayerName
end

local function mp_is_excluded_npc_name(name)
    if not name or name == "" then return true end
    for i = 1, #MP_NPC_NAME_EXCLUDE do
        local prefix = MP_NPC_NAME_EXCLUDE[i]
        if string.sub(name, 1, #prefix) == prefix then return true end
    end
    local pn = mp_local_player_name()
    if pn and name == pn then return true end
    return false
end

-- Is this entity one of ours (a ghost or a ghost's horse)? Checked by
-- reference against the registries, NOT by name -- KCD2MP_ApplyGhostName
-- renames ghost entities to the player's nick (WO-26), so a name prefix
-- test would miss every renamed ghost.
local function mp_is_mod_entity(e)
    for _, g in pairs(KCD2MP.ghosts) do
        if g.entity == e then return true end
    end
    for _, h in pairs(KCD2MP.horseGhosts or {}) do
        if h.entity == e then return true end
    end
    return false
end

-- Rebuild the tracked set: the maxTracked nearest live human NPCs within
-- radius. Names not re-selected simply age out of KCD2MP.npcTracked (their
-- entries are dropped so a re-entering NPC re-heartbeats immediately).
--
-- WO-59 Thread A: hysteresis. The old single-radius rescan was a documented
-- ~5 s oscillator (WO-38 findings, "boundary flapping"): an NPC near the
-- 30 m edge was tracked/untracked every 2 s rescan, and each untrack let
-- the receiver's engine yank the puppet back to its own schedule position
-- before the re-track snapped it away again -- jitter with no combat and no
-- restart needed. Two asymmetries fix it: (1) an ALREADY-tracked NPC stays
-- eligible out to 1.5x radius, so crossing the enter-edge back and forth
-- cannot untrack it; (2) when more candidates exist than maxTracked slots,
-- already-tracked NPCs win near-ties (an 8 m bonus), so the tracked set
-- stops churning as ranks 5 and 6 swap places.
local NPC_TRACK_EXIT_FACTOR  = 1.5   -- tracked NPCs stay eligible to radius*this
local NPC_TRACK_STICKY_BONUS = 8.0   -- metres subtracted from a tracked NPC's rank distance
-- WO-60: an NPC with its weapon out within this range of the local player is
-- ENGAGED -- the emit carries flag bit 32, which arms the relay's anti-flap
-- hold on that entity's claim. 12 m covers a melee fight's footwork without
-- holding claims on every armed guard the player merely walks past.
local NPC_ENGAGE_RANGE_SQ    = 12.0 * 12.0
-- WO-102 Phase 3 live probe (argless: nearest NPC within 15 m, or the
-- nearest puppet/tracked NPC). Proves, on one machine, what
-- `wh_ai_PauseNPC` does to a body: does it stay where WE put it (no brain
-- write-back, the WO-32 1.5 s snap-back is the negative), does it still
-- animate on StartAnimation, does it resume cleanly. Every step logs
-- MP-PAUSEPROBE; the verdict line is the last one. Reversible: it always
-- ends in wh_ai_ResumeNPC and puts the body back where it was.
function KCD2MP_ProbeNpcPause()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end
    local best, bestD = nil, 1e9
    for _, e in ipairs(System.GetEntitiesInSphere(pp, 15) or {}) do
        local cls = e.class
        if (cls == "NPC" or cls == "NPC_Female") and not mp_is_mod_entity(e) then
            local n = e:GetName()
            if n and string.find(n, "^[%w_]+$") and not mp_is_excluded_npc_name(n) then
                local ep = e:GetWorldPos()
                local d = (ep.x - pp.x) ^ 2 + (ep.y - pp.y) ^ 2
                if d < bestD then best, bestD = e, d end
            end
        end
    end
    if not best then mp_log("MP-PAUSEPROBE step=abort reason=no-npc-within-15m"); return end
    local name = best:GetName()
    local p0 = best:GetWorldPos()
    local anim0 = nil
    pcall(function() anim0 = best:GetCurAnimation() end)
    mp_log(string.format("MP-PAUSEPROBE step=0 npc=%s pos=(%.2f,%.2f,%.2f) anim=%s action=wh_ai_PauseNPC", name, p0.x, p0.y, p0.z, tostring(anim0)))
    local okc, errc = pcall(System.ExecuteCommand, "wh_ai_PauseNPC " .. name)
    mp_log(string.format("MP-PAUSEPROBE step=1 npc=%s execute_ok=%s err=%s", name, tostring(okc), tostring(errc)))
    local target = { x = p0.x + 2.0, y = p0.y, z = p0.z }
    Script.SetTimer(1000, function()
        local e = System.GetEntityByName(name); if not e then mp_log("MP-PAUSEPROBE step=abort reason=entity-gone"); return end
        local pa = e:GetWorldPos()
        mp_log(string.format("MP-PAUSEPROBE step=2 npc=%s paused_1s_pos=(%.2f,%.2f,%.2f) moved_m=%.2f action=SetWorldPos+2m", name, pa.x, pa.y, pa.z, math.sqrt((pa.x-p0.x)^2+(pa.y-p0.y)^2)))
        pcall(function() e:SetWorldPos(target) end)
        Script.SetTimer(3000, function()
            local e2 = System.GetEntityByName(name); if not e2 then mp_log("MP-PAUSEPROBE step=abort reason=entity-gone"); return end
            local pb = e2:GetWorldPos()
            local heldM = math.sqrt((pb.x-target.x)^2+(pb.y-target.y)^2)
            mp_log(string.format("MP-PAUSEPROBE step=3 npc=%s after_3s_pos=(%.2f,%.2f,%.2f) off_target_m=%.2f verdict_pos=%s action=StartAnimation(walk)",
                name, pb.x, pb.y, pb.z, heldM, heldM < 0.5 and "HELD (no brain write-back)" or "SNAPPED BACK (brain still writes)"))
            pcall(function() e2:StartAnimation(0, "3d_relaxed_walk_turn_strafe", 0, 0.15, 1.0, true) end)
            Script.SetTimer(2000, function()
                local e3 = System.GetEntityByName(name); if not e3 then return end
                local anim1 = nil
                pcall(function() anim1 = e3:GetCurAnimation() end)
                local pc = e3:GetWorldPos()
                mp_log(string.format("MP-PAUSEPROBE step=4 npc=%s anim_after=%s (was %s) pos=(%.2f,%.2f,%.2f) action=SetWorldPos(back)+wh_ai_ResumeNPC", name, tostring(anim1), tostring(anim0), pc.x, pc.y, pc.z))
                pcall(function() e3:SetWorldPos(p0) end)
                pcall(System.ExecuteCommand, "wh_ai_ResumeNPC " .. name)
                Script.SetTimer(4000, function()
                    local e4 = System.GetEntityByName(name); if not e4 then return end
                    local pd = e4:GetWorldPos()
                    local anim2 = nil
                    pcall(function() anim2 = e4:GetCurAnimation() end)
                    mp_log(string.format("MP-PAUSEPROBE step=5 npc=%s resumed_4s_pos=(%.2f,%.2f,%.2f) moved_since_resume_m=%.2f anim=%s -- probe done; report steps 3 and 4 verbatim",
                        name, pd.x, pd.y, pd.z, math.sqrt((pd.x-p0.x)^2+(pd.y-p0.y)^2), tostring(anim2)))
                end)
            end)
        end)
    end)
end

-- ===== WO-102 Phase 6: NPC resync burst (the sleep / fast-travel / reload net) =====
--
-- The owner (damage authority, host authority on) emits ONE npc_state sample
-- per NPC it has loaded within MP_NPC_RESYNC_RADIUS of its own player or any
-- peer ghost, flagged RESYNC (bit 64), on the events that already resync
-- world time (the agent calls this) and on `mp_resync_npcs`. Receivers snap
-- their copy once (KCD2MP_ApplyNpcState) -- no puppet, no stream follows.
-- This is the net for ambient drift, and nothing more: an NPC mid-interaction
-- is Phase 4's business (the stream), and an NPC only the other game has
-- loaded cannot be in this scan (docs/WO-102-findings.md S6).
local MP_NPC_RESYNC_RADIUS = 60     -- metres around each anchor
local MP_NPC_RESYNC_MAX    = 40     -- hard cap per burst (one 0x26 each, ~40 bytes)
KCD2MP._resyncStats = { bursts = 0, emitted = 0, applied = 0, moved = 0, skipped = 0 }

function KCD2MP_NpcResyncBurst(reason)
    reason = tostring(reason or "?")
    if not KCD2MP.hitSensorOn then
        mp_log("MP-NPCRESYNC dir=skip reason=" .. reason .. " cause=not-authority")
        return 0
    end
    if not player then return 0 end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return 0 end
    local anchors = { pp }
    for _, g in pairs(KCD2MP.ghosts or {}) do
        local gp = nil
        pcall(function() if g.entity and g.entity.GetWorldPos then gp = g.entity:GetWorldPos() end end)
        if not gp and g.istate and g.istate.tx then gp = { x = g.istate.tx, y = g.istate.ty, z = g.istate.tz or pp.z } end
        if gp then anchors[#anchors + 1] = gp end
    end
    local seen, n = {}, 0
    for _, a in ipairs(anchors) do
        for _, e in ipairs(System.GetEntitiesInSphere(a, MP_NPC_RESYNC_RADIUS) or {}) do
            if n >= MP_NPC_RESYNC_MAX then break end
            local cls = e.class
            local isHorse = (cls == "Horse")
            if (cls == "NPC" or cls == "NPC_Female" or isHorse) and not mp_is_mod_entity(e)
               and not (isHorse and KCD2MP._mountedHorseName and e:GetName() == KCD2MP._mountedHorseName) then
                local name = e:GetName()
                if name and not seen[name] and string.find(name, "^[%w_]+$") and not mp_is_excluded_npc_name(name) then
                    seen[name] = true
                    pcall(function()
                        local ep = e:GetWorldPos()
                        local rot = 0
                        pcall(function() rot = e:GetWorldAngles().z or 0 end)
                        local hp, dead, ko, drawn = -1, false, false, false
                        if e.actor then
                            pcall(function() hp = e.actor:GetHealth() or -1 end)
                            pcall(function() dead = e.actor:IsDead() == true end)
                            pcall(function() ko = e.actor:IsUnconscious() == true end)
                        end
                        pcall(function() drawn = e.human and e.human:IsWeaponDrawn() == true end)
                        local flags = (dead and 1 or 0) + (ko and 2 or 0) + (drawn and 4 or 0) + 64
                        KCD2MP_EmitEvent("npc_state", string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                            name, ep.x, ep.y, ep.z, rot, hp, flags))
                        n = n + 1
                    end)
                end
            end
        end
    end
    local st = KCD2MP._resyncStats
    st.bursts = st.bursts + 1
    st.emitted = st.emitted + n
    mp_log(string.format("MP-NPCRESYNC dir=burst reason=%s n=%d anchors=%d radius_m=%d cap=%d",
        reason, n, #anchors, MP_NPC_RESYNC_RADIUS, MP_NPC_RESYNC_MAX))
    return n
end

-- `mp_resync_npcs` (argless): the agent decides -- owner bursts, non-owner
-- asks the owner over the action channel, claim model logs a skip.
function KCD2MP_NpcResyncRequest()
    mp_log("MP-NPCRESYNC dir=request reason=manual model=" .. (KCD2MP.wo102.authorityHost and "host" or "claim (no single owner -- the agent will skip)"))
    KCD2MP_EmitEvent("npc_resync_request", "manual")
end

-- WO-103 Phase 0: reusable duration-histogram stats for MP-NPCREAD, mirroring
-- CadenceStats.cs's bucketed-percentile scheme (dotnet/KcdMp.Client/
-- CadenceStats.cs) -- Lua cannot call that C# class, so the SCHEME is
-- mirrored (same line shape, same 1ms-bucket/percentile algorithm), not the
-- code. Unlike CadenceStats (which measures the GAP between samples --
-- cadence), this measures the DURATION of one bracketed span -- the
-- per-tracked-NPC read loop in KCD2MP_NpcSyncTick -- so `Add` takes an
-- already-computed elapsed-ms value, not a clock reading.
local NPCREAD_MAX_MS = 500
local function mp_durstat_new()
    return { win = {}, life = {}, winN = 0, lifeN = 0, winSum = 0, lifeSum = 0,
             winMax = 0, lifeMax = 0, winStartClock = os.clock() }
end
local function mp_durstat_add(st, ms)
    local b = math.max(0, math.min(NPCREAD_MAX_MS, math.floor(ms + 0.5)))
    st.win[b] = (st.win[b] or 0) + 1
    st.life[b] = (st.life[b] or 0) + 1
    st.winN = st.winN + 1; st.lifeN = st.lifeN + 1
    st.winSum = st.winSum + ms; st.lifeSum = st.lifeSum + ms
    if ms > st.winMax then st.winMax = ms end
    if ms > st.lifeMax then st.lifeMax = ms end
end
local function mp_durstat_percentile(hist, n, q)
    if n <= 0 then return -1 end
    local target = math.ceil(q * n)
    if target < 1 then target = 1 end
    local seen = 0
    for b = 0, NPCREAD_MAX_MS do
        seen = seen + (hist[b] or 0)
        if seen >= target then return b end
    end
    return NPCREAD_MAX_MS
end
-- Formats+resets the WINDOW (matching CadenceStats.Report); returns nil when
-- the window holds nothing, exactly like CadenceStats.Report does, so a
-- caller only logs a line when there is one.
local function mp_durstat_report(st, path)
    if st.winN == 0 then st.winStartClock = os.clock(); return nil end
    local windowS = os.clock() - st.winStartClock
    local p50 = mp_durstat_percentile(st.win, st.winN, 0.50)
    local p95 = mp_durstat_percentile(st.win, st.winN, 0.95)
    local line = string.format("MP-NPCREAD path=%s n=%d mean_ms=%.1f p50_ms=%s p95_ms=%s max_ms=%.0f window_s=%.0f",
        path, st.winN, st.winSum / st.winN,
        p50 >= NPCREAD_MAX_MS and (">=" .. NPCREAD_MAX_MS) or tostring(p50),
        p95 >= NPCREAD_MAX_MS and (">=" .. NPCREAD_MAX_MS) or tostring(p95),
        st.winMax, windowS)
    st.win = {}; st.winN = 0; st.winSum = 0; st.winMax = 0; st.winStartClock = os.clock()
    return line
end

-- WO-103 Phase 0: n=1 sample every KCD2MP_NpcSyncTick tick where the
-- per-tracked-NPC loop actually ran (0 tracked ticks add nothing). `mixed`
-- covers a tick where some tracked NPCs read from the native push and
-- others fell back live -- classified per-tick, not per-NPC, since the
-- native push's freshness window (below) makes most ticks uniformly one or
-- the other in practice; a genuinely mixed tick is reported as such rather
-- than folded into either pure bucket.
KCD2MP._npcReadStat = { lua = mp_durstat_new(), native = mp_durstat_new(), mixed = mp_durstat_new() }
KCD2MP._wo103ReportAt = 0
local WO103_REPORT_INTERVAL_S = 15.0

-- How long a native push stays trustworthy before KCD2MP_NpcSyncTick's own
-- position read falls back to the live e:GetWorldPos() call it always used
-- to make -- the SAME gate mp_npc_rescan already established for trusting
-- the pushed NAME list at all (staleAfterS there), reused here rather than
-- inventing a second clock: one freshness gate for the whole native push.
local function mp_native_scan_stale_after_s()
    return (KCD2MP.npcSync.scanMs / 1000) * 3
end

-- WO-103 Phase 0/2: periodic, readable-directly counters -- previously a
-- bundle audit had to count "NPC-SYNC tracking"/"untracking" log lines by
-- hand (WO-102.5's own runbook friction). Also runs the read-native
-- known-answer check (KCD2MP_NpcReadCompare) while that path is on, so a
-- regression is caught within one interval, not only when the console
-- happens to be asked.
local function mp_wo103_periodic_report()
    local nowR = os.clock()
    if (nowR - (KCD2MP._wo103ReportAt or 0)) < WO103_REPORT_INTERVAL_S then return end
    KCD2MP._wo103ReportAt = nowR
    for _, path in ipairs({ "lua", "native", "mixed" }) do
        local line = mp_durstat_report(KCD2MP._npcReadStat[path], path)
        if line then mp_log(line) end
    end
    local tracked, culled = 0, 0
    for _, t in pairs(KCD2MP.npcTracked) do
        tracked = tracked + 1
        if t.culled then culled = culled + 1 end
    end
    mp_log(string.format("MP-NPCTRACK tracked=%d culled=%d", tracked, culled))
    if KCD2MP.wo1025.readNative and KCD2MP_NpcReadCompare then pcall(KCD2MP_NpcReadCompare) end
end

-- WO-102.5 Phase 2: the agent's push target (GameBridge.cs's NpcScanTickAsync).
-- csv is a comma-separated list of "name:x:y:z:yaw:isHorse" entries (WO-103
-- Phase 2 added the position/yaw fields -- the name-only format WO-102.5
-- shipped had nowhere to put them). The whole entry is matched by one
-- pattern, so a malformed or non-conforming name (agent-side gate is
-- [A-Za-z0-9_]+, re-checked here, never trusted blind) drops the WHOLE entry
-- rather than parsing a name next to garbage numbers. Empty/nil clears it
-- rather than erroring, since "the scan found nothing near you" is a normal
-- reply, not a malformed one.
KCD2MP._nativeScan = { at = nil, names = {}, pos = {} }

function KCD2MP_ApplyNativeScan(csv)
    local names, pos = {}, {}
    if csv and #csv > 0 then
        for entry in string.gmatch(csv, "[^,]+") do
            local name, x, y, z, yaw, horse =
                string.match(entry, "^([%w_]+):(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+):([01])$")
            if name then
                names[#names + 1] = name
                pos[name] = { x = tonumber(x), y = tonumber(y), z = tonumber(z),
                              yaw = tonumber(yaw), isHorse = (horse == "1") }
            end
        end
    end
    KCD2MP._nativeScan.names = names
    KCD2MP._nativeScan.pos = pos
    KCD2MP._nativeScan.at = os.clock()
end

-- WO-103 Phase 2 known-answer check, on the model of KCD2MP_NpcScanCompare
-- below: native position/yaw (the agent's last push) against a fresh LIVE
-- Lua read (e:GetWorldPos()/GetWorldAngles()) for the SAME entity, same
-- tick -- only over currently-tracked names, since those are the ones the
-- substitution actually touches. A moving NPC genuinely drifts during the
-- push's own staleness window, so the tolerance scales with the push's age
-- at a generous walking/jogging bound (NPC_READ_COMPARE_SPEED_MPS) plus a
-- flat base for read/measurement noise -- a mismatch beyond that is not
-- explainable by movement, so it means the offset math itself disagrees.
-- Disagreement means stop, not tune: any mismatch fails the whole check
-- closed (KCD2MP.wo1025.readNative = false), not just for the mismatched
-- name, since a wrong offset is wrong for every entity, not one.
local NPC_READ_COMPARE_BASE_M = 1.0
local NPC_READ_COMPARE_SPEED_MPS = 3.0
function KCD2MP_NpcReadCompare()
    local ageS = KCD2MP._nativeScan.at and (os.clock() - KCD2MP._nativeScan.at) or nil
    if not ageS then mp_log("MP-NPCREAD dir=compare verdict=no-data reason=never-received"); return end
    -- Live-found bug (2026-09-18 field session): without this gate, the
    -- allowed-drift formula below grows UNBOUNDED with age, so a push that
    -- went stale minutes ago still reports "match" against whatever the
    -- live entity has drifted to since -- the exact "disagreement means
    -- stop, not tune" property this check exists for, defeated by its own
    -- tolerance formula. The read substitution itself already refuses a
    -- push this old (mp_native_scan_stale_after_s); the compare must refuse
    -- it too, for the same reason -- comparing something that would never
    -- be used for a real read proves nothing.
    local staleAfterS = mp_native_scan_stale_after_s()
    if ageS > staleAfterS then
        mp_log(string.format("MP-NPCREAD dir=compare verdict=no-data reason=stale native_age_s=%.1f stale_after_s=%.1f",
            ageS, staleAfterS))
        return
    end

    local n, sumD, maxD, mismatches = 0, 0, 0, {}
    for name in pairs(KCD2MP.npcTracked) do
        local nat = KCD2MP._nativeScan.pos and KCD2MP._nativeScan.pos[name]
        if nat then
            local e = System.GetEntityByName(name)
            if e then
                local ok, p = pcall(function() return e:GetWorldPos() end)
                if ok and p then
                    local dx, dy, dz = p.x - nat.x, p.y - nat.y, p.z - nat.z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    n = n + 1
                    sumD = sumD + d
                    if d > maxD then maxD = d end
                    local allowed = NPC_READ_COMPARE_BASE_M + NPC_READ_COMPARE_SPEED_MPS * ageS
                    if d > allowed then
                        mismatches[#mismatches + 1] = string.format("%s:%.2f", name, d)
                    end
                end
            end
        end
    end

    local verdict = n == 0 and "no-data" or (#mismatches == 0 and "match" or "fail-closed")
    mp_log(string.format("MP-NPCREAD dir=compare n=%d delta_mean_m=%.2f delta_max_m=%.2f mismatches=%d native_age_s=%.1f verdict=%s",
        n, n > 0 and sumD / n or 0, maxD, #mismatches, ageS, verdict))
    if #mismatches > 0 then
        mp_log("MP-NPCREAD dir=compare mismatches=" .. table.concat(mismatches, ","))
        KCD2MP.wo1025.readNative = false
        mp_log("WO103-READNATIVE off -- known-answer check failed closed")
    end
end

-- WO-102.5 Phase 2 known-answer check: the native scan's last pushed name set
-- against a fresh Lua GetEntitiesInSphere enumerate over the SAME anchors and
-- radius mp_npc_rescan itself would compute right now. only_native names are
-- expected to include some the Lua side would still drop (mod bodies, a
-- mounted horse, an excluded name) -- native does not replicate that
-- filtering (findings Phase 2); only_lua names are the interesting failure,
-- since every one means the native scan missed something the Lua walk finds.
function KCD2MP_NpcScanCompare()
    if not player then mp_log("MP-NPCSCAN dir=compare verdict=no-player"); return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then mp_log("MP-NPCSCAN dir=compare verdict=no-pos"); return end

    -- WO-102.5 field session, 2026-09-18: this used to hardcode
    -- npcSync.radius (30m, the claim-model bound) regardless of authority
    -- state, while the native scan itself is requested at
    -- wo1025.authorityRadius (45m default) -- under host authority the two
    -- sides were being compared at different radii, which made
    -- only_native look inflated by every real NPC between 30m and the
    -- authority radius. only_lua stayed correct regardless (a smaller-radius
    -- Lua set is trivially a subset of a larger-radius native one), so the
    -- safety-critical verdict was never wrong, only the only_native count's
    -- readability. Matches mp_npc_rescan's own radius choice exactly now.
    local underHostAuthorityCmp = KCD2MP.wo102.authorityHost and KCD2MP.hitSensorOn
    local enterRadius = underHostAuthorityCmp and KCD2MP.wo1025.authorityRadius or KCD2MP.npcSync.radius
    local exitRadius = enterRadius * NPC_TRACK_EXIT_FACTOR
    local anchors = { pp }
    if underHostAuthorityCmp then
        for _, g in pairs(KCD2MP.ghosts or {}) do
            local gp = nil
            pcall(function() if g.entity and g.entity.GetWorldPos then gp = g.entity:GetWorldPos() end end)
            if not gp and g.istate and g.istate.tx then gp = { x = g.istate.tx, y = g.istate.ty, z = g.istate.tz or pp.z } end
            if gp then anchors[#anchors + 1] = gp end
        end
    end

    local luaSet, luaCount, seenEnt = {}, 0, {}
    for _, a in ipairs(anchors) do
        for _, e in ipairs(System.GetEntitiesInSphere(a, exitRadius) or {}) do
            local key = e.id or e
            if not seenEnt[key] then
                seenEnt[key] = true
                local cls = e.class
                local isHorse = (cls == "Horse")
                local isHuman = (cls == "NPC" or cls == "NPC_Female")
                if (isHuman or isHorse) and not mp_is_mod_entity(e)
                   and not (isHorse and KCD2MP._mountedHorseName and e:GetName() == KCD2MP._mountedHorseName) then
                    local name = e:GetName()
                    if name and string.find(name, "^[%w_]+$") and not mp_is_excluded_npc_name(name) then
                        local ep = e:GetWorldPos()
                        local d = 1e9
                        for _, aa in ipairs(anchors) do
                            local dx, dy = ep.x - aa.x, ep.y - aa.y
                            local da = math.sqrt(dx*dx + dy*dy)
                            if da < d then d = da end
                        end
                        if d <= enterRadius and not luaSet[name] then
                            luaSet[name] = true; luaCount = luaCount + 1
                        end
                    end
                end
            end
        end
    end

    local nativeSet, nativeCount = {}, 0
    for _, name in ipairs(KCD2MP._nativeScan.names or {}) do
        if not nativeSet[name] then nativeSet[name] = true; nativeCount = nativeCount + 1 end
    end

    local onlyLua, onlyNative, both = {}, {}, 0
    for name in pairs(luaSet) do
        if nativeSet[name] then both = both + 1 else onlyLua[#onlyLua + 1] = name end
    end
    for name in pairs(nativeSet) do
        if not luaSet[name] then onlyNative[#onlyNative + 1] = name end
    end

    mp_log(string.format("MP-NPCSCAN dir=compare anchors=%d lua_n=%d native_n=%d both=%d only_lua=%d only_native=%d native_age_s=%s",
        #anchors, luaCount, nativeCount, both, #onlyLua, #onlyNative,
        KCD2MP._nativeScan.at and string.format("%.1f", os.clock() - KCD2MP._nativeScan.at) or "never"))
    if #onlyLua > 0 then mp_log("MP-NPCSCAN dir=compare only_lua=" .. table.concat(onlyLua, ",")) end
    if #onlyNative > 0 then mp_log("MP-NPCSCAN dir=compare only_native=" .. table.concat(onlyNative, ",")) end
end

-- WO-102.5 Phase 4: the co-location transition. Runs on the AUTHORITY only
-- (the non-authority never claims regardless of together/apart, Phase 0 S0.2
-- -- nothing there needs to change). Going apart releases OWNERSHIP here;
-- it does NOT reach across the wire to tell a puppeting peer to let go --
-- untracking simply stops this machine emitting for that name, and the
-- EXISTING silence-release path (WO-32/WO-90, <=3 s of no packets) already
-- resumes the pause and drops the puppet on the other side. No new wire
-- message, no resync-flag repurposing.
--
-- Never mid-interaction: an NPC this machine is fighting (t.sentEngaged) or
-- that is in dialogue (e.human:IsInDialog(), the same per-entity check
-- KCD2MP_ApplyNpcState's resync path already uses) is left exactly as it
-- is and marked pending -- KCD2MP_NpcSyncTick's own per-NPC loop sweeps it
-- the moment neither is true any more (below), even if that is minutes
-- later. "Frozen" NPCs are still logged by count, never silently dropped
-- from the transition's own accounting.
local function mp_wo1025_colocate_transition(newTogether, distM)
    KCD2MP.wo1025.together = newTogether
    local frozen, released = 0, 0
    if not newTogether then
        for name, t in pairs(KCD2MP.npcTracked) do
            local e = System.GetEntityByName(name)
            local inDialog = false
            pcall(function() if e and e.human and e.human.IsInDialog then inDialog = e.human:IsInDialog() == true end end)
            if t.sentEngaged or inDialog then
                frozen = frozen + 1
                KCD2MP._colocatePendingRelease[name] = true
            else
                KCD2MP.npcTracked[name] = nil
                mp_auth_log(name, "release", "self", "colocate-apart", os.clock() - (t.since or os.clock()))
                released = released + 1
            end
        end
    end
    mp_log(string.format("WO1025-COLOCATE event=%s dist_m=%.1f frozen=%d released=%d",
        newTogether and "enter" or "exit", distM, frozen, released))
    KCD2MP_ShowInteractionMsg(newTogether and "Players together: NPCs shared" or "Players apart: NPCs local")
end

-- Hysteresis + dwell over the nearest peer ghost's distance. Called at the
-- rescan cadence (KCD2MP_NpcSyncTick, scanMs). A momentary crossing does
-- not flip the state -- togetherDwellS of SUSTAINED wanting-the-other-state
-- is required, tracked by KCD2MP._togetherWantSince.
local function mp_wo1025_colocation_tick()
    if not (KCD2MP.wo102.authorityHost and KCD2MP.hitSensorOn) then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    local nearest = nil
    for _, g in pairs(KCD2MP.ghosts or {}) do
        local gp = nil
        pcall(function() if g.entity and g.entity.GetWorldPos then gp = g.entity:GetWorldPos() end end)
        if not gp and g.istate and g.istate.tx then gp = { x = g.istate.tx, y = g.istate.ty, z = g.istate.tz or pp.z } end
        if gp then
            local dx, dy = gp.x - pp.x, gp.y - pp.y
            local d = math.sqrt(dx * dx + dy * dy)
            if not nearest or d < nearest then nearest = d end
        end
    end

    local w = KCD2MP.wo1025
    if not nearest then
        -- No peer ghost loaded at all -- there is nothing to be "together"
        -- with. Apart, no hysteresis needed (there is no boundary to bounce
        -- across when the other side does not exist here).
        KCD2MP._togetherWantSince = nil
        if w.together then mp_wo1025_colocate_transition(false, -1) end
        return
    end

    local wantTogether = w.together
    if w.together and nearest > w.togetherExitM then wantTogether = false
    elseif not w.together and nearest <= w.togetherEnterM then wantTogether = true end

    if wantTogether == w.together then
        KCD2MP._togetherWantSince = nil
        return
    end

    local now = os.clock()
    if not KCD2MP._togetherWantSince then KCD2MP._togetherWantSince = now end
    if (now - KCD2MP._togetherWantSince) >= w.togetherDwellS then
        KCD2MP._togetherWantSince = nil
        mp_wo1025_colocate_transition(wantTogether, nearest)
    end
end

local function mp_npc_rescan()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    local found = {}
    -- WO-102.5 Phase 3: under host authority, ownership uses the runtime-
    -- adjustable authority radius (KCD2MP.wo1025.authorityRadius, see that
    -- table for the current default and WO-103 Phase 1's uncap) instead of
    -- npcSync.radius -- the claim model (authorityHost off) is untouched,
    -- npcSync.radius/30m exactly as before.
    local underHostAuthority = KCD2MP.wo102.authorityHost and KCD2MP.hitSensorOn
    local enterRadius = underHostAuthority and KCD2MP.wo1025.authorityRadius or KCD2MP.npcSync.radius
    local exitRadius  = enterRadius * NPC_TRACK_EXIT_FACTOR
    -- WO-102 Phase 4: under host authority the authority owns the NPCs near
    -- the OTHER players too, so it scans around every peer ghost as well as
    -- its own player -- one anchor per body. An NPC only the peer's game has
    -- loaded cannot be scanned here; that is the stated limit (findings
    -- S4.4), not a gap in the scan.
    -- WO-102.5 Phase 4: a peer's anchor is only added while the coarse
    -- co-location state says "together" -- this is what lets players apart
    -- play independently: the authority simply stops discovering (and, via
    -- the transition, stops owning) anything near a far peer, rather than
    -- each NPC crossing its own radius threshold independently.
    local anchors = { pp }
    if underHostAuthority and KCD2MP.wo1025.together then
        for _, g in pairs(KCD2MP.ghosts or {}) do
            local gp = nil
            pcall(function() if g.entity and g.entity.GetWorldPos then gp = g.entity:GetWorldPos() end end)
            if not gp and g.istate and g.istate.tx then gp = { x = g.istate.tx, y = g.istate.ty, z = g.istate.tz or pp.z } end
            if gp then anchors[#anchors + 1] = gp end
        end
    end
    -- WO-102.5 Phase 3: the per-anchor cap is a claim-model bound (Lua could
    -- not afford more before the native scan paid for the walk). Under host
    -- authority it is removed entirely -- every NPC in radius is owned.
    local cap = underHostAuthority and math.huge or (KCD2MP.npcSync.maxTracked * #anchors)
    KCD2MP._lastAnchors = anchors   -- WO-102.5 Phase 3: read by KCD2MP_NpcSyncTick's cull check
    if #anchors ~= (KCD2MP._npcScanAnchors or 1) then
        KCD2MP._npcScanAnchors = #anchors
        mp_log(string.format("WO102-AUTHORITY scan anchors=%d cap=%s radius_m=%.1f", #anchors,
            underHostAuthority and "uncapped" or tostring(cap), enterRadius))
    end
    -- WO-102.5 Phase 2: the enumerate+read half of this function, natively.
    -- When on and fresh, `ents` is resolved from the agent's pushed name list
    -- (KCD2MP_ApplyNativeScan) instead of walking System.GetEntitiesInSphere
    -- per anchor -- the C++ scan already did the class+radius filtering
    -- against the SAME anchors/radius this function computed above.
    -- Everything from here on (mod-entity/mounted-horse/puppet exclusion,
    -- name-pattern gate, distance-to-nearest-anchor ranking, the cap, the
    -- tracked-set diff) is unchanged and runs over `ents` exactly as before,
    -- so a native candidate list is a speed change, not a behaviour change.
    local ents, seenEnt = {}, {}
    local staleAfterS = mp_native_scan_stale_after_s()   -- WO-103: one shared freshness gate for the whole native push
    if KCD2MP.wo102.npcScanNative and KCD2MP._nativeScan.at
       and (os.clock() - KCD2MP._nativeScan.at) <= staleAfterS then
        for _, name in ipairs(KCD2MP._nativeScan.names) do
            local e = System.GetEntityByName(name)
            if e then
                local key = e.id or e
                if not seenEnt[key] then seenEnt[key] = true; ents[#ents + 1] = e end
            end
        end
        mp_log(string.format("MP-NPCSCAN dir=consume verdict=native pushed=%d resolved=%d age_s=%.1f",
            #KCD2MP._nativeScan.names, #ents, os.clock() - KCD2MP._nativeScan.at))
    else
        if KCD2MP.wo102.npcScanNative then
            mp_log(string.format("MP-NPCSCAN dir=consume verdict=fallback reason=%s",
                KCD2MP._nativeScan.at and "stale" or "never-received"))
        end
        for _, a in ipairs(anchors) do
            for _, e in ipairs(System.GetEntitiesInSphere(a, exitRadius) or {}) do
                local key = e.id or e
                if not seenEnt[key] then seenEnt[key] = true; ents[#ents + 1] = e end
            end
        end
    end
    for _, e in ipairs(ents) do
        local cls = e.class
        -- WO-38 Phase 5: Horse-class entities travel on the same channel --
        -- an idle horse both worlds have (authored name) converges exactly
        -- like a wandering NPC, which is what makes a peer's unmounted horse
        -- visible in the right place BEFORE anyone mounts it. The horse the
        -- local player is riding is excluded: its position is already implied
        -- by our own position stream, and receivers drive their copy through
        -- the ghost-mount path -- streaming it here too would double-drive.
        local isHorse = (cls == "Horse")
        local isHuman = (cls == "NPC" or cls == "NPC_Female")
        if (isHuman or isHorse) and not mp_is_mod_entity(e)
           and not (isHorse and KCD2MP._mountedHorseName and e:GetName() == KCD2MP._mountedHorseName)
           and not KCD2MP.npcPuppets[e:GetName() or ""] then
            local name = e:GetName()
            -- Only plain authored names travel: they are the cross-client
            -- key, and anything else (spaces, renames) could not be looked
            -- up on the other side anyway. WO-90: and never an engine
            -- conversation stand-in or one of our own ghost bodies.
            if name and string.find(name, "^[%w_]+$")
               and not mp_is_excluded_npc_name(name) then
                local ep = e:GetWorldPos()
                local d = 1e9
                for _, a in ipairs(anchors) do
                    local dx, dy = ep.x - a.x, ep.y - a.y
                    local da = math.sqrt(dx*dx + dy*dy)
                    if da < d then d = da end
                end
                local tracked = KCD2MP.npcTracked[name] ~= nil
                -- New NPCs must be inside the enter radius; tracked ones
                -- survive out to the exit radius (the sphere query bound).
                if tracked or d <= enterRadius then
                    table.insert(found, { name = name, e = e,
                        rank = tracked and (d - NPC_TRACK_STICKY_BONUS) or d })
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)

    local keep = {}
    for i = 1, math.min(#found, cap) do
        local name = found[i].name
        keep[name] = true
        if not KCD2MP.npcTracked[name] then
            KCD2MP.npcTracked[name] = { since = os.clock() }
            mp_log("NPC-SYNC tracking " .. name)
            mp_auth_log(name, "acquire", "self", KCD2MP.hitSensorOn and "authority-default" or "claim", 0)   -- WO-102
        end
    end
    for name, t in pairs(KCD2MP.npcTracked) do
        if not keep[name] then
            KCD2MP.npcTracked[name] = nil
            mp_log("NPC-SYNC untracking " .. name)
            mp_auth_log(name, "release", "self", "untrack", os.clock() - (t.since or os.clock()))   -- WO-102
        end
    end
end

-- WO-39 Phase 2: the non-authority half of NPC sync. Watches downed
-- hand-placed humans near the player; a downed body that MOVES while the
-- player stands next to it is being manipulated locally (a dead body does
-- not move by itself -- the only other mover is the inbound puppet stream,
-- which is recognised and excluded below). While the manipulation is fresh,
-- its state is emitted as npc_drag lines -- which is how the entity is
-- claimed; the relay arbitrates first-come and mutes the authority's stream
-- for it. Nothing is sent for bodies nobody is touching.
local DRAG_RADIUS   = 6.0   -- metres: bodies this close to the player are watched
local DRAG_MIN_MOVE = 0.3   -- metres between samples that count as manipulation
local DRAG_TAIL_S   = 3.0   -- emit tail after the last observed move
local DRAG_SCAN_MS  = 500   -- watch-scan cadence (emission runs every tick)

local function mp_drag_sensor()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end
    local now = os.clock()

    if (now - (KCD2MP._dragScanAt or 0)) * 1000 >= DRAG_SCAN_MS then
        KCD2MP._dragScanAt = now
        local ents = System.GetEntitiesInSphere(pp, DRAG_RADIUS) or {}
        local seen = {}
        for _, e in ipairs(ents) do
            local cls = e.class
            if (cls == "NPC" or cls == "NPC_Female") and not mp_is_mod_entity(e) then
                local name = e:GetName()
                if name and string.find(name, "^[%w_]+$")
                   and not mp_is_excluded_npc_name(name) then   -- WO-90
                    local dead, ko = false, false
                    if e.actor then
                        pcall(function() dead = e.actor:IsDead() == true end)
                        pcall(function() ko = e.actor:IsUnconscious() == true end)
                    end
                    mp_npc_death_observe(name, dead, -1, "drag")   -- WO-86
                    if dead or ko then
                        seen[name] = true
                        local p = e:GetWorldPos()
                        local w = KCD2MP.dragWatch[name]
                        if w then
                            local dx, dy, dz = p.x - w.x, p.y - w.y, p.z - w.z
                            if (dx*dx + dy*dy + dz*dz) > DRAG_MIN_MOVE * DRAG_MIN_MOVE then
                                -- A move that lands on the inbound stream's
                                -- target was the puppet body-follow, not us.
                                local pup = KCD2MP.npcPuppets[name]
                                local streamMove = false
                                if pup and pup.tx then
                                    local sx, sy = p.x - pup.tx, p.y - pup.ty
                                    streamMove = (sx*sx + sy*sy) < 0.25
                                end
                                if not streamMove then
                                    if not KCD2MP.dragging[name] then
                                        mp_log("NPC-DRAG claiming " .. name .. " (local manipulation)")
                                        KCD2MP._dragSince = KCD2MP._dragSince or {}
                                        KCD2MP._dragSince[name] = now
                                        mp_auth_log(name, "acquire", "self", "drag", 0)   -- WO-102
                                    end
                                    KCD2MP.dragging[name] = now
                                end
                            end
                        end
                        KCD2MP.dragWatch[name] = { x = p.x, y = p.y, z = p.z }
                    end
                end
            end
        end
        for name in pairs(KCD2MP.dragWatch) do
            if not seen[name] then KCD2MP.dragWatch[name] = nil end
        end
    end

    for name, lastMove in pairs(KCD2MP.dragging) do
        if now - lastMove > DRAG_TAIL_S then
            KCD2MP.dragging[name] = nil
            mp_log("NPC-DRAG released " .. name .. " (idle " .. DRAG_TAIL_S .. "s)")
            mp_auth_log(name, "release", "self", "drag-idle", now - ((KCD2MP._dragSince or {})[name] or now))   -- WO-102
        else
            pcall(function()
                local e = System.GetEntityByName(name)
                if not e then return end
                local p = e:GetWorldPos()
                local rot = 0
                pcall(function() rot = e:GetWorldAngles().z or 0 end)
                local hp, dead, ko = -1, false, false
                if e.actor then
                    pcall(function() hp = e.actor:GetHealth() or -1 end)
                    pcall(function() dead = e.actor:IsDead() == true end)
                    pcall(function() ko = e.actor:IsUnconscious() == true end)
                end
                -- WO-40 Phase 7: a downed body moving while glued to the
                -- player (<1.5 m) is being CARRIED, not dragged along the
                -- ground -- a third state (footage: "phases upward onto
                -- shoulders"). Bit 4 tells receivers to follow smoothly
                -- instead of teleport-stepping per half metre.
                local carried = false
                if player then
                    local pp2 = nil
                    pcall(function() pp2 = player:GetWorldPos() end)
                    if pp2 then
                        local cdx, cdy = p.x - pp2.x, p.y - pp2.y
                        carried = (cdx * cdx + cdy * cdy) < 2.25
                    end
                end
                local flags = (dead and 1 or 0) + (ko and 2 or 0) + (carried and 16 or 0)
                KCD2MP_EmitEvent("npc_drag", string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                    name, p.x, p.y, p.z, rot, hp, flags))
            end)
        end
    end
end

-- WO-106 Phase 2: scratch tables for KCD2MP_NpcSyncTick's read loop -- the
-- loop MP-NPCREAD brackets (WO-103 Phase 0). ppos is one player-position
-- read per tick; p/rot are read fresh per tracked NPC per tick inside the
-- per-name pcall below. Both are read into locals/scalars immediately (p.x
-- etc. feed string.format and t.lastX/Y/Z, never the table itself), so one
-- reused table per call site is safe -- see the ownership rule in
-- docs/WO-106-findings.md S "Phase 2".
local NPCSYNCTICK_PPOS_SCRATCH = {}
local NPCSYNCTICK_POS_SCRATCH  = {}
local NPCSYNCTICK_ANG_SCRATCH  = {}
function KCD2MP_NpcSyncTick()
    if not KCD2MP.npcSyncRunning then return end
    Script.SetTimer(KCD2MP.npcSync.emitMs, KCD2MP_NpcSyncTick)  -- reschedule FIRST
    KCD2MP._npcSyncAliveAt = os.clock()

    -- WO-102.5 Phase 1: the pause reconciliation sweep, independent of
    -- npcSync.enabled and the authority gate below -- a stray pause is a
    -- native engine state this tick's own early returns must not hide.
    local nowRec = os.clock()
    pcall(mp_wo102_pending_tick)   -- WO-108 s3.5: dwell deadlines, every tick
    if (nowRec - (KCD2MP._npcReconcileAt or 0)) >= NPC_RECONCILE_INTERVAL_S then
        KCD2MP._npcReconcileAt = nowRec
        pcall(mp_wo102_reconcile_pauses)
        if KCD2MP_NpcReplicaSweep then pcall(KCD2MP_NpcReplicaSweep) end   -- WO-104
    end

    -- Gate at tick time, not start time: mp_npc_sync can flip and authority
    -- can migrate mid-session, and both must take effect without a restart.
    if not KCD2MP.npcSync.enabled then return end
    local isAuthority = KCD2MP.hitSensorOn
    if not isAuthority then
        -- WO-102 Phase 4: under host authority a non-authority never claims
        -- -- not by drag, not by proximity. The claim code below is bypassed,
        -- not removed; mp_authority_host_off returns to it on the next tick.
        if KCD2MP.wo102.authorityHost then return end
        -- WO-39 Phase 2: a non-authority always watches for bodies its own
        -- player is dragging, proximity toggle or no.
        pcall(mp_drag_sensor)
        -- WO-60: with proximity authority on and a peer actually present,
        -- fall through and run the SAME rescan/emit loop around this
        -- player -- emitted as npc_claim, which claims each NPC through the
        -- relay's per-entity table. NPCs someone else already streams are
        -- puppets here and never enter the rescan, so this only picks up
        -- entities nobody is driving (the radius-gap NPCs). Turning
        -- mp_npc_proximity off restores the pre-WO-60 return right here.
        if not KCD2MP.npcProx.enabled then return end
        local anyGhost = false
        for _ in pairs(KCD2MP.ghosts) do anyGhost = true; break end
        if not anyGhost then return end
    end

    local now = os.clock()
    if (now - (KCD2MP._npcScanAt or 0)) * 1000 >= KCD2MP.npcSync.scanMs then
        KCD2MP._npcScanAt = now
        -- WO-102.5 Phase 4: the co-location hysteresis, same cadence as the
        -- rescan it gates (mp_npc_rescan reads KCD2MP.wo1025.together).
        -- Decided BEFORE the rescan so a transition this tick is reflected
        -- in the anchor list the rescan is about to build, not one tick late.
        pcall(mp_wo1025_colocation_tick)
        pcall(mp_npc_rescan)
    end

    -- WO-40 Phase 6: an NPC's real swings are invisible to Lua, but the one
    -- moment that matters most -- the NPC landing a hit on THIS player -- is
    -- visible as our own health dropping. That edge, attributed to a nearby
    -- weapon-drawn tracked NPC, becomes a swing cue on the observers' side.
    local playerHit, ppos = false, nil
    if player then
        pcall(function() ppos = player:GetWorldPos(NPCSYNCTICK_PPOS_SCRATCH) end)
        if player.actor then
            local ph = nil
            pcall(function() ph = player.actor:GetHealth() end)
            if ph then
                if KCD2MP._npcSyncPrevPlayerHp and ph < KCD2MP._npcSyncPrevPlayerHp - 0.5 then
                    playerHit = true
                end
                KCD2MP._npcSyncPrevPlayerHp = ph
            end
        end
    end

    -- WO-103 Phase 0: brackets the WHOLE loop below (one sample per tick it
    -- runs), not per-NPC -- MP-NPCREAD's "n" is tick count, and its
    -- mean/p95/max describe how long the tracked set as a whole costs this
    -- tick, which is what scales with tracked count (Phase 1's point: cost
    -- scales with tracked, not streamed).
    local readT0 = os.clock()
    local readNativeHits, readLuaHits = 0, 0
    for name, t in pairs(KCD2MP.npcTracked) do
        pcall(function()
            -- WO-60: the drag sensor already emits (and claims) this body on
            -- its own channel -- don't double-stream it from here too.
            if not isAuthority and KCD2MP.dragging[name] then return end
            local e = System.GetEntityByName(name)
            if not e then KCD2MP.npcTracked[name] = nil; return end

            -- WO-103 Phase 2: the one substitution point. `e` is fetched
            -- above regardless (health/dead/ko/drawn below all need it --
            -- WO-103.5's job to move those natively, not this WO's), so the
            -- fallback is never a second GetEntityByName -- it is exactly
            -- the e:GetWorldPos()/GetWorldAngles() call this loop always
            -- made. Nothing here can ship a stale position: outside the
            -- freshness window (mp_native_scan_stale_after_s, the SAME gate
            -- mp_npc_rescan trusts the pushed name list under) it is simply
            -- today's live read.
            local p, rot
            local nat = KCD2MP.wo1025.readNative and KCD2MP._nativeScan.pos and KCD2MP._nativeScan.pos[name]
            local natFresh = nat and KCD2MP._nativeScan.at
                and (os.clock() - KCD2MP._nativeScan.at) <= mp_native_scan_stale_after_s()
            if natFresh then
                p = { x = nat.x, y = nat.y, z = nat.z }
                rot = nat.yaw
                readNativeHits = readNativeHits + 1
            else
                p = e:GetWorldPos(NPCSYNCTICK_POS_SCRATCH)
                rot = 0
                pcall(function() rot = e:GetWorldAngles(NPCSYNCTICK_ANG_SCRATCH).z or 0 end)
                readLuaHits = readLuaHits + 1
            end
            local hp, dead, ko = -1, false, false
            if e.actor then
                pcall(function() hp = e.actor:GetHealth() or -1 end)
                pcall(function() dead = e.actor:IsDead() == true end)
                -- WO-38 Phase 6: knockout is a real state distinct from death
                -- and travels as its own flag bit, so a receiver can freeze
                -- its copy of a knocked-out NPC instead of walking it.
                pcall(function() ko = e.actor:IsUnconscious() == true end)
            end
            -- WO-86: this is one of the three places a world NPC's death is
            -- visible to this file; report it.
            mp_npc_death_observe(name, dead, hp, "emitter")

            -- WO-40 Phase 6: the NPC's weapon state travels as flag bit 2 so
            -- an observer's copy fights in a guard stance instead of standing
            -- with arms down (the footage's "the NPC itself does nothing").
            local drawn = false
            pcall(function() drawn = e.human and e.human:IsWeaponDrawn() == true end)
            local swingCue = false
            if playerHit and drawn and ppos then
                local sx, sy = p.x - ppos.x, p.y - ppos.y
                if sx * sx + sy * sy <= 16.0 then swingCue = true end
            end

            -- WO-60: engagement -- a live NPC with its weapon out right next
            -- to this player is being fought here. Travels as flag bit 32;
            -- on a claim it arms the relay's hold so the claim cannot flap
            -- to another sender through a brief packet gap mid-fight.
            local engaged = false
            if drawn and not dead and not ko and ppos then
                local gx, gy = p.x - ppos.x, p.y - ppos.y
                engaged = (gx * gx + gy * gy) <= NPC_ENGAGE_RANGE_SQ
            end

            -- WO-102.5 Phase 4: a co-location "going apart" release deferred
            -- because this NPC was engaged or in dialogue at the time --
            -- swept the moment neither is true any more, however much later
            -- that is. Checked every tick regardless of the current
            -- together/apart state: if players went back together in the
            -- meantime the pending flag is simply stale and harmless (the
            -- NPC stays tracked either way).
            if KCD2MP._colocatePendingRelease[name] and not engaged then
                local inDialog = false
                pcall(function() if e.human and e.human.IsInDialog then inDialog = e.human:IsInDialog() == true end end)
                if not inDialog then
                    KCD2MP._colocatePendingRelease[name] = nil
                    KCD2MP.npcTracked[name] = nil
                    mp_auth_log(name, "release", "self", "colocate-apart-deferred", os.clock() - (t.since or os.clock()))
                    mp_log("WO1025-COLOCATE deferred release now clear: " .. name)
                    return
                end
            end

            -- WO-102.5 Phase 3: culling. Owned (tracked, so nobody else can
            -- claim it) but not actively streamed while nothing is close
            -- enough to care -- the network cost the larger authority radius
            -- would otherwise add. Engaged is exempt by construction:
            -- NPC_ENGAGE_RANGE_SQ's 12 m is always inside cullRadius. t.last*
            -- is deliberately left untouched below (this returns first), so
            -- the tick after re-entry reads as "moved" against the pre-cull
            -- values and sends immediately, at the entity's CURRENT position
            -- and life state (read fresh above, every tick, cull or not) --
            -- never a stale resume.
            if isAuthority and KCD2MP.wo102.authorityHost and KCD2MP.wo1025.npcCull and not engaged then
                local dCull = 1e9
                for _, a in ipairs(KCD2MP._lastAnchors or {}) do
                    local dx, dy = p.x - a.x, p.y - a.y
                    local da = math.sqrt(dx * dx + dy * dy)
                    if da < dCull then dCull = da end
                end
                if dCull > KCD2MP.wo1025.cullRadius then
                    t.culled = true
                    return
                end
            end
            if t.culled then
                t.culled = false
                mp_log("WO1025-CULL re-entry " .. name)
            end

            local moved = not t.lastX
                or math.abs(p.x - t.lastX) > KCD2MP.npcSync.moveEps
                or math.abs(p.y - t.lastY) > KCD2MP.npcSync.moveEps
                or math.abs(p.z - t.lastZ) > KCD2MP.npcSync.moveEps
            local hpChanged = t.lastHp and hp >= 0 and math.abs(hp - t.lastHp) > 0.5
            local heartbeat = not t.lastSentAt or (now - t.lastSentAt) >= KCD2MP.npcSync.heartbeatS

            local koChanged = (ko ~= (t.sentKo or false))
            local drawnChanged = (drawn ~= (t.sentDrawn or false))
            local engagedChanged = (engaged ~= (t.sentEngaged or false))
            if moved or hpChanged or heartbeat or koChanged or drawnChanged or swingCue
               or engagedChanged or (dead and not t.sentDead) then
                local flags = (dead and 1 or 0) + (ko and 2 or 0)
                    + (drawn and 4 or 0) + (swingCue and 8 or 0)
                    + (engaged and 32 or 0)
                -- npc_state rides the authority's default stream; npc_claim
                -- (WO-60) is the same payload sent down the asClaim path, so
                -- the agent's authority gate lets it through and sending it
                -- IS the claim.
                KCD2MP_EmitEvent(isAuthority and "npc_state" or "npc_claim",
                    string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                    name, p.x, p.y, p.z, rot, hp, flags))
                -- WO-86 Phase 1: the outbound dead bit, the moment it first
                -- goes out (it then rides every heartbeat for this body).
                if dead and not t.sentDead then
                    mp_log(string.format("NPC-DEATH %s outbound dead bit set on %s (hp=%.1f flags=%d)",
                        name, isAuthority and "npc_state" or "npc_claim", hp, flags))
                end
                t.lastX, t.lastY, t.lastZ, t.lastRot = p.x, p.y, p.z, rot
                t.lastHp, t.lastSentAt, t.sentDead, t.sentKo = hp, now, dead, ko
                t.sentDrawn = drawn
                t.sentEngaged = engaged
            end
        end)
    end

    if readNativeHits + readLuaHits > 0 then
        local readDurMs = (os.clock() - readT0) * 1000
        local path = (readNativeHits > 0 and readLuaHits == 0) and "native"
            or (readLuaHits > 0 and readNativeHits == 0) and "lua" or "mixed"
        mp_durstat_add(KCD2MP._npcReadStat[path], readDurMs)
    end
    pcall(mp_wo103_periodic_report)
end

function KCD2MP_StartNpcSync()
    if not chainMayStart("npcsync", "npcSyncRunning", "_npcSyncAliveAt", KCD2MP_StartNpcSync) then return end  -- WO-78
    KCD2MP.npcSyncRunning = true
    KCD2MP._npcSyncAliveAt = os.clock()
    mp_log("NPC-SYNC emit tick started (" .. KCD2MP.npcSync.emitMs .. "ms)")
    Script.SetTimer(KCD2MP.npcSync.emitMs, KCD2MP_NpcSyncTick)
end

-- ===== WO-104 Phase 1: brainless replicas for contested NPCs =====
--
-- WO-108 CORRECTION to the premise below: WO-107 showed the pause lever DOES
-- suppress the brain (C_IntelligentObject::Suspend, latched, held through a
-- 38 Hz stream). The 155 `paused=1` lines reported the mod's own Lua table
-- and the dist_m they fired on was the WO-107 s4 position-relax. The replica
-- path is therefore OFF by default since 0.26.4 (and structurally dead per
-- WO-106 s5 regardless); the text below is kept as the record of why it was
-- built.
-- ORIGINAL: The pause lever (WO-102 Phase 4, wh_ai_PauseNPC) does not suppress a
-- local brain that is fighting a live puppet stream: 2026-09-18, joiner,
-- 155 MP-AUTHORITY-VIOLATION lines, every one paused=1 (observed). The
-- solo probe's 5/8 HELD measured a body nothing else was writing.
--
-- This is the other answer: do not suppress the brain, drive a body that
-- has none. When an owned puppet is CONTESTED here (a violation fires for
-- it -- the local brain moved it off our write), the local world NPC is
-- hidden in place and a replica spawned at its exact pose takes the
-- stream. On resolution the NPC is unhidden where the replica stood and the
-- replica is removed. Both edges happen inside one Lua call, i.e. one
-- frame, so nothing flickers and no body drops.
--
-- The replica body. NOT the NPC_NAI class: XGenAIModule.SpawnEntity
-- substitutes ClassName=NPC_NAI with NPC (observed 3/3, WO-100.5 s1.3) and
-- System.SpawnEntity, which honours the class, does not bind SharedSoulGuid
-- -- so NPC_NAI can be had only soulless, which is the WO-56 bare-spawn
-- family (faction spam, A1 knockdown). The reachable brainless body is
-- class NPC with the shipped NoAI=true spawn parameter (WO-100.5 s1.4,
-- observed): soul binds, no SituationController, no behaviour tree, no
-- self-initiated dialogue, still perceptible, still a crime victim.
--
-- Appearance. The replica is spawned with SharedSoulGuid = the ORIGINAL's
-- own soul WUID (soul:GetId(), "unique and persistent id of this soul",
-- Warhorse scriptbind doc). A soul-bound body wears that soul's authored
-- head, hair, beard and default outfit (WO-20 / WO-69, observed on the
-- roster souls). What it does NOT copy is live inventory state: an NPC the
-- player stripped, or that the game re-dressed, comes back in its authored
-- outfit. If the soul id cannot be read as a WUID the NPC is NOT promoted
-- -- a visibly wrong body is worse than a jittering correct one.
--
-- Naming. The replica is "kcd2mp_r_<name>": the kcd2mp_ prefix puts it in
-- MP_NPC_NAME_EXCLUDE, so this world's own emitter never streams it and
-- an inbound stream can never target it. The ORIGINAL keeps its name:
-- every by-name path (inbound damage 0x31, remote death, resync, the RPG
-- SoulList) keeps resolving to the real NPC, which stays the canonical
-- local copy -- the replica is only what the eye and the stream see. The
-- two places that address the BODY are re-pointed explicitly: the native
-- swing entity id (npcid event) and the agent's outbound damage name
-- (npc_replica event -> GameBridge remaps the struck replica's name back
-- to the NPC's).
--
-- What this cannot serve, stated plainly (never promoted, logged once):
--   * any class but NPC -- NPC_Female (NoAI unprobed on it), Horse, animals
--   * a body already dead, unconscious or carried
--   * an NPC in a conversation with this player (human:IsInDialog, a
--     documented bind never live-verified -- WO-88 s2.1; treated as
--     not-in-dialog when it errors)
--   * a soul whose id does not read back as a WUID (appearance not
--     guaranteed)
--   * DialogTwin_*, kcd2mp_* and the local player (excluded upstream)
--   and, by consequence rather than by check: while promoted the NPC
--   cannot be talked to (its body is hidden) and hits the player lands on
--   the replica stay on the replica -- the original returns with the
--   health it had, unless the stream or the local copy says dead, which
--   demotes at once so the real corpse is the one on the ground.
--
-- Save hazard, same class as the pause lever's (WO-102.5 s1.3): a save
-- written while an NPC is promoted persists a hidden original and a
-- brainless kcd2mp_r_ body. There is no pre-save hook. The 5 s sweep
-- (KCD2MP_NpcReplicaSweep) removes any unregistered kcd2mp_r_ body near the
-- player and unhides its original the next time the NPC-sync tick runs.
--
-- Default ON (mp_npc_replica_on|off) -- the maintainer's call for 0.26.2:
-- it fires only on real contention and demotes itself, so shipping it off
-- means it never gets tested; ghost appearance is already imperfect, so a
-- wrong face is not a new class of problem; and the toggle stays live if it
-- is bad. Nothing here has run against a real game yet (synthetic only).
-- The two-machine pass condition is zero MP-AUTHORITY-VIOLATION with
-- body=replica on a fought NPC.
--
--   MP-NPCREPLICA npc=<name> event=promote|demote|refuse|orphan why=<w> body=<replica name>|- held_s=<F1> n=<int>
KCD2MP.npcReplica = {
    enabled         = false,   -- mp_npc_replica_on|off. WO-108: OFF. Structurally dead (WO-106 s5): SharedSoulGuid indexes an
                               -- authored database a live NPC's WUID is never in -- 36/36 refusals, never promoted once. Was ON
                               -- 0.26.2-0.26.3 (the maintainer's call for a fail-closed path); mp_preset_legacy puts it back.
    sheathedDemoteS = 10.0,    -- stream says weapon away for this long -> the fight is over -> demote
    orphanSweepM    = 60.0,    -- radius of the 5 s orphan sweep around the player
}
KCD2MP._npcReplicas = {}       -- name -> { entName=, since=, guid=, sheathedSince= }
KCD2MP._npcReplicaStats = { promote = 0, demote = 0, refused = 0, orphan = 0, violationsOnReplica = 0 }
KCD2MP._npcReplicaRefused = {} -- name|reason -> true (logged once per pair)

local NPC_REPLICA_PREFIX = "kcd2mp_r_"

local function mp_replica_log(name, event, why, body, heldS)
    local st = KCD2MP._npcReplicaStats
    local n = (event == "promote" and st.promote) or (event == "demote" and st.demote)
        or (event == "refuse" and st.refused) or (event == "orphan" and st.orphan) or 0
    mp_log(string.format("MP-NPCREPLICA npc=%s event=%s why=%s body=%s held_s=%.1f n=%d",
        tostring(name), event, tostring(why), tostring(body or "-"), heldS or 0, n))
end

local function mp_replica_hexid(e)
    local h = nil
    pcall(function() h = string.match(tostring(e.id), "(%x+)%s*$") end)
    return h
end

-- Same 4-pass remove-and-verify idiom as mp_remove_entity_verified (which
-- is a local defined further down this file, so not visible here).
local function mp_replica_remove(entName)
    for pass = 1, 4 do
        local e = nil
        pcall(function() e = System.GetEntityByName(entName) end)
        if not e then return true end
        pcall(function() System.RemoveEntity(e.id) end)
    end
    local e = nil
    pcall(function() e = System.GetEntityByName(entName) end)
    if e then mp_log("MP-NPCREPLICA remove: " .. tostring(entName) .. " STILL ALIVE after 4 passes") end
    return e == nil
end

-- The body the puppet tick should drive for `name`: the replica while one
-- is registered and alive, else the world NPC. Second return: isReplica.
function KCD2MP_NpcBody(name)
    local r = KCD2MP._npcReplicas[name]
    if r then
        local e = nil
        pcall(function() e = System.GetEntityByName(r.entName) end)
        if e then return e, true end
        KCD2MP_NpcReplicaDemote(name, "replica-gone")
    end
    local e = nil
    pcall(function() e = System.GetEntityByName(name) end)
    return e, false
end

local function mp_replica_refuse(name, why)
    local key = tostring(name) .. "|" .. tostring(why)
    if KCD2MP._npcReplicaRefused[key] then return false end
    KCD2MP._npcReplicaRefused[key] = true
    KCD2MP._npcReplicaStats.refused = KCD2MP._npcReplicaStats.refused + 1
    mp_replica_log(name, "refuse", why, "-", 0)
    return false
end

-- Promote `name` (an owned puppet, table p) to a replica. Returns true when
-- a replica now drives it (including "already promoted").
function KCD2MP_NpcReplicaPromote(name, p, why)
    if not KCD2MP.npcReplica.enabled then return false end
    if not KCD2MP.wo102.authorityHost then return false end
    if KCD2MP._npcReplicas[name] then return true end
    if not p or mp_is_excluded_npc_name(name) then return false end
    if p.dead or p.ko or p.carried then return mp_replica_refuse(name, "down-or-carried") end

    local e = nil
    pcall(function() e = System.GetEntityByName(name) end)
    if not e then return false end

    local cls = nil
    pcall(function() cls = tostring(e.class or "") end)
    if cls ~= "NPC" then return mp_replica_refuse(name, "class=" .. tostring(cls)) end

    local dead, ko = false, false
    if e.actor then
        pcall(function() dead = e.actor:IsDead() == true end)
        pcall(function() ko = e.actor:IsUnconscious() == true end)
    end
    if dead or ko then return mp_replica_refuse(name, dead and "dead" or "unconscious") end

    local inDialog = false
    if e.human and type(e.human.IsInDialog) == "function" then
        pcall(function() inDialog = e.human:IsInDialog() == true end)
    end
    if inDialog then return mp_replica_refuse(name, "in-dialog") end

    local guid = nil
    if e.soul then pcall(function() guid = tostring(e.soul:GetId()) end) end
    if not (guid and string.match(guid, "^%x+%-%x+%-%x+%-%x+%-%x+$")) then
        return mp_replica_refuse(name, "soul-id-unreadable")
    end

    local pos, ang = nil, nil
    pcall(function() pos = e:GetWorldPos() end)
    pcall(function() ang = e:GetWorldAngles() end)
    if not pos then return false end

    -- 1. The replica first, at the NPC's ACTUAL pose (the body the eye is
    --    on right now), soul-bound to the same soul, no brain.
    local rname = NPC_REPLICA_PREFIX .. name
    mp_replica_remove(rname)   -- a stale one from an earlier session/save must not double up
    local r = nil
    pcall(function()
        XGenAIModule.SpawnEntity({
            Name           = rname,
            ClassName      = "NPC",
            Pos            = { pos.x, pos.y, pos.z },
            SharedSoulGuid = guid,
            NoAI           = true,
        })
        r = System.GetEntityByName(rname)
    end)
    if not r then return mp_replica_refuse(name, "spawn-failed") end
    mp_set_no_save(r)   -- WO-106 Phase 5: never let a replica into the player's save
    local rSoul = false
    pcall(function() rSoul = r.soul ~= nil end)
    if not rSoul then
        -- WO-56 bare-spawn family: a soulless body logs every frame and
        -- falls over. Never leave one standing.
        mp_replica_remove(rname)
        return mp_replica_refuse(name, "replica-soulless")
    end
    if ang then pcall(function() r:SetWorldAngles({ x = 0, y = 0, z = ang.z }) end) end

    -- 2. Hide the NPC in the same call -- same frame as the spawn.
    pcall(function() e:Hide(1) end)

    KCD2MP._npcReplicas[name] = { entName = rname, since = os.clock(), guid = guid, sheathedSince = nil }
    KCD2MP._npcReplicaStats.promote = KCD2MP._npcReplicaStats.promote + 1

    -- The puppet's render state restarts on the new body: no phantom
    -- displacement against the original's last write, the animation and the
    -- weapon state re-assert on the replica on its first tick.
    p.cx, p.cy, p.cz = pos.x, pos.y, pos.z
    if ang then p.cr = ang.z end
    p.lastWroteX, p.lastWroteY = nil, nil
    p.animTag, p.animRefreshAt, p.appliedDrawn, p.drawnCheckAt = "idle", 0, nil, 0
    p.yieldStreak = 0

    -- Re-point the two by-BODY paths (see the header): native swings by
    -- entity id, and the agent's struck-name remap for outbound damage.
    local hexid = mp_replica_hexid(r)
    if hexid then KCD2MP_EmitEvent("npcid", name .. " " .. hexid) end
    KCD2MP_EmitEvent("npc_replica", name .. " " .. rname)
    mp_replica_log(name, "promote", why, rname, 0)
    if KCD2MP_QuestHazard then KCD2MP_QuestHazard("npc-replica", string.format("%s hidden and replaced by a brainless replica (%s)", name, tostring(why))) end
    return true
end

-- Demote: the NPC returns where the replica stands, the replica goes. One
-- call, one frame. Safe to call for a name that is not promoted.
function KCD2MP_NpcReplicaDemote(name, why)
    local r = KCD2MP._npcReplicas[name]
    if not r then return false end
    KCD2MP._npcReplicas[name] = nil
    local re, orig = nil, nil
    pcall(function() re = System.GetEntityByName(r.entName) end)
    pcall(function() orig = System.GetEntityByName(name) end)
    local pos, ang = nil, nil
    if re then
        pcall(function() pos = re:GetWorldPos() end)
        pcall(function() ang = re:GetWorldAngles() end)
    end
    local p = KCD2MP.npcPuppets[name]
    if not pos and p and p.cx then pos = { x = p.cx, y = p.cy, z = p.cz } end
    if orig then
        if pos then pcall(function() orig:SetWorldPos({ x = pos.x, y = pos.y, z = pos.z }) end) end
        if ang then pcall(function() orig:SetWorldAngles({ x = 0, y = 0, z = ang.z }) end) end
        pcall(function() orig:Hide(0) end)
    end
    if re then mp_replica_remove(r.entName) end
    if p then
        if pos then p.cx, p.cy, p.cz = pos.x, pos.y, pos.z end
        p.lastWroteX, p.lastWroteY = nil, nil
        p.animTag, p.animRefreshAt, p.appliedDrawn, p.drawnCheckAt = "idle", 0, nil, 0
        p.yieldStreak = 0
    end
    if orig then
        local hexid = mp_replica_hexid(orig)
        if hexid then KCD2MP_EmitEvent("npcid", name .. " " .. hexid) end
    end
    KCD2MP_EmitEvent("npc_replica", name .. " -")
    KCD2MP._npcReplicaStats.demote = KCD2MP._npcReplicaStats.demote + 1
    mp_replica_log(name, "demote", why, r.entName, os.clock() - (r.since or os.clock()))
    return true
end

function KCD2MP_NpcReplicaDemoteAll(why)
    local names = {}
    for name in pairs(KCD2MP._npcReplicas) do names[#names + 1] = name end
    for _, name in ipairs(names) do KCD2MP_NpcReplicaDemote(name, why) end
    return #names
end

-- Called from mp_wo102_violation: the contention trigger. One violation is
-- already a sustained signal (10 consecutive ticks displaced, or a >8 m
-- yank), so the first one promotes. A violation on a body that IS the
-- replica is counted separately -- that is the field number the two-machine
-- test reads (a brainless body should produce none).
function KCD2MP_NpcReplicaConsider(name, p, kind)
    if KCD2MP._npcReplicas[name] then
        KCD2MP._npcReplicaStats.violationsOnReplica = KCD2MP._npcReplicaStats.violationsOnReplica + 1
        return
    end
    if not KCD2MP.npcReplica.enabled then return end
    KCD2MP_NpcReplicaPromote(name, p, "violation-" .. tostring(kind))
end

-- 5 s sweep from KCD2MP_NpcSyncTick: (1) a registered replica whose body or
-- original is gone (save reload minted new entities) is demoted/forgotten;
-- (2) an UNREGISTERED kcd2mp_r_ body near the player -- a savegame-restored
-- replica, or one from a previous Lua state -- is removed and its original
-- unhidden. Runs regardless of the toggle: cleanup must not depend on the
-- switch that created the mess.
function KCD2MP_NpcReplicaSweep()
    local names = {}
    for name in pairs(KCD2MP._npcReplicas) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        local r = KCD2MP._npcReplicas[name]
        local re, orig = nil, nil
        pcall(function() re = System.GetEntityByName(r.entName) end)
        pcall(function() orig = System.GetEntityByName(name) end)
        if not re then KCD2MP_NpcReplicaDemote(name, "replica-gone")
        elseif not orig then
            KCD2MP._npcReplicas[name] = nil
            mp_replica_remove(r.entName)
            KCD2MP_EmitEvent("npc_replica", name .. " -")
            KCD2MP._npcReplicaStats.demote = KCD2MP._npcReplicaStats.demote + 1
            mp_replica_log(name, "demote", "original-gone", r.entName, os.clock() - (r.since or os.clock()))
        elseif not KCD2MP.npcPuppets[name] then
            KCD2MP_NpcReplicaDemote(name, "no-puppet")
        end
    end
    if not player then return end
    local ppos = nil
    pcall(function() ppos = player:GetWorldPos() end)
    if not ppos then return end
    local ents = nil
    pcall(function() ents = System.GetEntitiesInSphere(ppos, KCD2MP.npcReplica.orphanSweepM) end)
    for _, e in ipairs(ents or {}) do
        local nm = nil
        pcall(function() nm = e:GetName() end)
        if nm and string.sub(nm, 1, #NPC_REPLICA_PREFIX) == NPC_REPLICA_PREFIX then
            local orig = string.sub(nm, #NPC_REPLICA_PREFIX + 1)
            local r = KCD2MP._npcReplicas[orig]
            if not (r and r.entName == nm) then
                local o = nil
                pcall(function() o = System.GetEntityByName(orig) end)
                if o then pcall(function() o:Hide(0) end) end
                mp_replica_remove(nm)
                KCD2MP._npcReplicaStats.orphan = KCD2MP._npcReplicaStats.orphan + 1
                mp_replica_log(orig, "orphan", o and "removed-and-unhid" or "removed", nm, 0)
            end
        end
    end
end

function KCD2MP_SetNpcReplica(on)
    local want = (on == true or on == 1 or on == "on" or on == "true")
    local was = KCD2MP.npcReplica.enabled
    KCD2MP.npcReplica.enabled = want
    local demoted = 0
    if not want then demoted = KCD2MP_NpcReplicaDemoteAll("toggle-off") end
    mp_log(string.format("MP-NPCREPLICA toggle state=%s was=%s demoted=%d", want and "on" or "off", was and "on" or "off", demoted))
    KCD2MP_ShowInteractionMsg("NPC replicas for contested NPCs: " .. (want and "ON" or "OFF"))
    KCD2MP_EmitEvent("npc_replica_toggle", want and "on" or "off")
end

function KCD2MP_NpcReplicaStatus()
    local st, active, names = KCD2MP._npcReplicaStats, 0, {}
    for name, r in pairs(KCD2MP._npcReplicas) do
        active = active + 1
        names[#names + 1] = string.format("%s(%.0fs)", name, os.clock() - (r.since or os.clock()))
    end
    mp_log(string.format("MP-NPCREPLICA status enabled=%s active=%d promotes=%d demotes=%d refused=%d orphans=%d violations_on_replica=%d [%s]",
        KCD2MP.npcReplica.enabled and "on" or "off", active, st.promote, st.demote, st.refused, st.orphan,
        st.violationsOnReplica, table.concat(names, ", ")))
end

-- Receiving side. Called by the agent for each NpcStateDown (0x27). Never
-- spawns anything: an NPC not loaded in this world is simply not ours to move.
-- WO-102 Phase 2: `src` is the sending ghost id (the stream's owner), an
-- APPENDED parameter -- an agent older than this build calls with seven
-- arguments and it arrives nil, which MP-AUTHORITY prints as owner=?.
function KCD2MP_ApplyNpcState(name, x, y, z, rot, hp, flags, src)
    -- WO-90: refuse an inbound stream for a name that must never be synced,
    -- whatever the sender believes. The send-side exclusion above stops US
    -- emitting these; this stops a peer on an older build (or with the
    -- exclusion rolled back) from driving our conversation camera rig or our
    -- own ghost body. Logged once per name so a mixed-version session is
    -- visible in the field log rather than silent.
    if mp_is_excluded_npc_name(name) then
        KCD2MP._npcNameRefused = KCD2MP._npcNameRefused or {}
        if not KCD2MP._npcNameRefused[name] then
            KCD2MP._npcNameRefused[name] = true
            mp_log("NPC-SYNC refusing inbound stream for excluded name '" .. tostring(name)
                .. "' (WO-90: engine conversation stand-in or our own ghost body)")
        end
        return
    end

    local e = KCD2MP_NpcBody(name)   -- WO-104: the replica while one drives this NPC, else the world NPC
    if not e then return end

    -- WO-38 Phase 5: a horse currently adopted as some ghost's mount is owned
    -- by the ghost-mount driver -- a puppet stream for the same entity would
    -- be a second writer fighting it every tick.
    for _, hd in pairs(KCD2MP.horseGhosts or {}) do
        if hd.isWorldHorse and hd.worldName == name then return end
    end

    -- WO-102 Phase 6: a RESYNC sample (bit 64). With no puppet for the name it
    -- is a ONE-SHOT snap of this world's copy onto the owner's position -- no
    -- puppet is created and no stream follows. With a puppet it is an ordinary
    -- packet (a > 5 m jump snaps through the ring as before). Never moves a
    -- body this player is within 2 m of or talking to, and never a local corpse.
    local fIn = tonumber(flags) or 0
    if (math.floor(fIn / 64) % 2) == 1 then
        flags = fIn - 64
        if not KCD2MP.npcPuppets[name] then
            local st = KCD2MP._resyncStats
            local cur = nil
            pcall(function() cur = e:GetWorldPos() end)
            if not cur then return end
            local dx, dy, dz = x - cur.x, y - cur.y, z - cur.z
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            local streamDead = (math.floor(fIn) % 2) == 1
            local locallyDead, inDialog, nearPlayer = false, false, false
            if e.actor then pcall(function() locallyDead = e.actor:IsDead() == true end) end
            pcall(function() if e.human and e.human.IsInDialog then inDialog = e.human:IsInDialog() == true end end)
            if player then
                pcall(function()
                    local pp = player:GetWorldPos()
                    nearPlayer = ((cur.x - pp.x)^2 + (cur.y - pp.y)^2) < 4.0
                end)
            end
            local skip = locallyDead and "local-corpse" or inDialog and "in-dialog" or nearPlayer and "near-player" or nil
            local moved = false
            if not skip and dist > 1.0 then
                pcall(function() e:SetWorldPos({ x = x, y = y, z = z }) end)
                pcall(function() e:SetWorldAngles({ x = 0, y = 0, z = rot }) end)
                moved = true
            end
            st.applied = st.applied + 1
            if moved then st.moved = st.moved + 1 end
            if skip then st.skipped = st.skipped + 1 end
            mp_log(string.format("MP-NPCRESYNC dir=apply npc=%s dist_m=%.2f moved=%d dead=%d owner=%s%s",
                name, dist, moved and 1 or 0, streamDead and 1 or 0, tostring(src == nil and "?" or src),
                skip and (" skipped=" .. skip) or ""))
            return
        end
    end

    local p = KCD2MP.npcPuppets[name]

    -- WO-90: while a divergence stand-off is running for this name, do not
    -- build a new puppet for it -- that is what makes the release stick
    -- rather than being undone by the very next inbound packet. An existing
    -- puppet is never touched here (there is none: the release deleted it),
    -- and once the stand-off lapses the name resumes normally.
    if not p then
        local standoff = KCD2MP._npcDivergeUntil[name]
        if standoff then
            if os.clock() < standoff then return end
            KCD2MP._npcDivergeUntil[name] = nil
            mp_log("NPC-DIVERGE " .. tostring(name) .. ": stand-off over, accepting the stream again")
        end
    end

    if not p then
        local cur = e:GetWorldPos()
        p = { cx = cur.x, cy = cur.y, cz = cur.z, cr = rot, animTag = "idle",
              ax = cur.x, ay = cur.y }   -- WO-108 s3.3: where the engine had this body before we wrote it (the relax anchor)
        -- WO-77: seed the sample ring with where the puppet actually IS,
        -- stamped one DELAY in the past, so the first packet renders as a
        -- DELAY-long slide from the entity's current position onto the
        -- stream instead of a pop. This is the same one-time creation read
        -- the pre-WO-77 code already made for cx/cy/cz -- not a per-tick
        -- readback into the render path. A first packet more than 5 m away
        -- snaps, exactly as before (mp_npc_ring_push).
        p.ring = { { x = cur.x, y = cur.y, z = cur.z, rot = rot,
                     at = os.clock() - KCD2MP_NpcSmoothDelayS() } }
        KCD2MP.npcPuppets[name] = p
        mp_log("NPC-SYNC puppet start " .. name)
        p.owner, p.ownerSince = src, os.clock()
        mp_auth_log(name, "acquire", src == nil and "?" or src, "stream", 0)   -- WO-102
        mp_wo102_pause(name, p)   -- WO-102 Phase 4: no-op unless authorityHost + authorityPause
        -- WO-49: report this world's copy's entity id so the agent can
        -- address it on the native swing path. Same tostring-hex idiom as
        -- SpawnGhost's ghostid emit -- a decimal path would corrupt ids
        -- above 2^24 in this float32 sandbox.
        local hexid = string.match(tostring(e.id), "(%x+)%s*$")
        if hexid then KCD2MP_EmitEvent("npcid", name .. " " .. hexid) end
    end
    -- WO-95: did this packet carry MOTION, or is it the emitter's idle
    -- heartbeat? The emitter gate (KCD2MP_NpcSyncTick) sends a moving NPC
    -- every `emitMs` and a still one every `heartbeatS`; both arrive here.
    -- Decided against the PREVIOUS target, before it is overwritten below.
    -- WO-102 Phase 2: the stream changed hands (a claim moved at the relay).
    if src ~= nil and p.owner ~= nil and p.owner ~= src then
        mp_auth_log(name, "owner-change", src, "stream", os.clock() - (p.ownerSince or os.clock()), p.owner)
        p.owner, p.ownerSince = src, os.clock()
    elseif src ~= nil and p.owner == nil then
        p.owner, p.ownerSince = src, os.clock()
    end
    local eps = (KCD2MP.npcSync and KCD2MP.npcSync.moveEps) or 0.05
    local hadPrevTarget = p.tx ~= nil
    local pktMoved = hadPrevTarget
        and (math.abs(x - p.tx) > eps or math.abs(y - p.ty) > eps or math.abs(z - (p.tz or z)) > eps)
    p.tx, p.ty, p.tz, p.tr = x, y, z, rot
    p.hp = hp
    -- WO-99 Phase 2: a yielded puppet re-pins only when the STREAM moved.
    if p.yielded then
        local ax, ay = x - (p.yieldAnchorX or x), y - (p.yieldAnchorY or y)
        local yc = KCD2MP.npcYield
        local rm = (yc and yc.repinM) or 1.0
        if (ax*ax + ay*ay) > rm * rm then
            local cur = nil
            pcall(function() cur = e:GetWorldPos() end)
            if cur then
                -- slide from where the body actually IS onto the stream,
                -- the same seed the puppet got at creation (WO-77)
                p.cx, p.cy, p.cz = cur.x, cur.y, cur.z
                p.ring = { { x = cur.x, y = cur.y, z = cur.z, rot = p.cr or rot,
                             at = os.clock() - KCD2MP_NpcSmoothDelayS() } }
            end
            local bx, by = (cur and cur.x or x) - x, (cur and cur.y or y) - y
            KCD2MP._npcRepinN = (KCD2MP._npcRepinN or 0) + 1
            mp_log(string.format("MP-NPCYIELD npc=%s state=repin target_moved_m=%.2f body_off_m=%.2f yielded_s=%.1f total_yields=%d total_repins=%d",
                name, math.sqrt(ax*ax + ay*ay), math.sqrt(bx*bx + by*by),
                os.clock() - (p.yieldAt or os.clock()), KCD2MP._npcYieldN or 0, KCD2MP._npcRepinN))
            p.yielded, p.yieldStreak, p.yieldAnchorX, p.yieldAnchorY, p.yieldAt = nil, 0, nil, nil, nil
            mp_auth_log(name, "acquire", p.owner == nil and "?" or p.owner, "repin", 0)   -- WO-102
        end
    end
    local f = tonumber(flags) or 0
    local wasKo = p.ko
    local wasDead = p.dead
    p.dead  = (math.floor(f) % 2) == 1          -- bit 0
    p.ko    = (math.floor(f / 2) % 2) == 1      -- bit 1 (WO-38 Phase 6: knocked out in the authority's world)
    p.drawn = (math.floor(f / 4) % 2) == 1      -- bit 2 (WO-40 Phase 6: weapon out in the authority's world)
    local swingCue = (math.floor(f / 8) % 2) == 1  -- bit 3 (WO-40 Phase 6: it just landed a hit there)
    p.carried = (math.floor(f / 16) % 2) == 1   -- bit 4 (WO-40 Phase 7: a player is carrying this body)
    -- WO-69: measure the real inbound cadence (see KCD2MP.npcPacketStats).
    -- Read the PREVIOUS stamp before overwriting it. Intervals above 5 s are
    -- dropped rather than averaged in: they are a puppet resuming after a
    -- release, a save load or a menu, not a stream cadence, and a handful of
    -- them would drag the mean far off the thing being measured.
    --
    -- WO-95: only gaps between two consecutive MOTION packets are averaged.
    -- The 2026-09-13 field logs reported a mean of 1,738 ms (host) and
    -- 1,887 ms (joiner) against `emitter is 100ms`, which reads as a stream
    -- starved 17x. It was not: the sample was dominated by the 2 s idle
    -- heartbeats of NPCs standing still, which are correct and cost nothing
    -- to render. Mixing the two makes the one number a jitter work order is
    -- meant to tune against meaningless, so they are counted apart.
    -- The very first packet of a puppet's life has no previous target to
    -- compare against, so it is neither motion nor heartbeat: `nil`, and the
    -- gap that ends on the packet after it is skipped rather than guessed.
    local nowPkt = os.clock()
    if p.lastPacketAt and p.lastPacketMoved ~= nil then
        local dtMs = (nowPkt - p.lastPacketAt) * 1000
        if dtMs > 0 and dtMs < 5000 then
            local s = KCD2MP.npcPacketStats
            if pktMoved and p.lastPacketMoved then
                s.n   = s.n + 1
                s.sum = s.sum + dtMs
                if dtMs < s.min then s.min = dtMs end
                if dtMs > s.max then s.max = dtMs end
            else
                s.idleN = (s.idleN or 0) + 1
            end
        end
    end
    p.lastPacketAt = nowPkt
    if hadPrevTarget then p.lastPacketMoved = pktMoved else p.lastPacketMoved = nil end
    -- WO-77 Step 1: stamp and ring the sample. Pushed regardless of
    -- mp_npc_smooth so a live toggle-on has data to render from.
    mp_npc_ring_push(p, x, y, z, rot, nowPkt)
    if swingCue and not p.dead and not p.ko then
        p.swingCuePending = true
    end
    -- WO-40 Phase 6: a knockout happening next to a player's ghost is almost
    -- always that player's takedown (the footage's choke rendered as a brief
    -- shield-block on the observer's screen). Play the paired master/victim
    -- takedown clips: victim on the NPC, master on the closest ghost within
    -- arm's reach. Names are probed (findAnim); none-found degrades to the
    -- existing freeze behaviour. Only a WITNESSED transition cues -- a body
    -- that is already KO on its first packet (late join) just freezes.
    if p.ko and wasKo == false and p.everPacket then
        pcall(function() KCD2MP_NpcTakedownCue(name, e, x, y, z) end)
    end
    -- WO-86 Phase 1: the inbound dead bit, against this world's copy. The
    -- agent applies the death (witnessed transition only); this line is what
    -- a future log reader needs to see whether the two worlds agreed.
    if p.dead and not wasDead then
        local localDead, localHp = nil, -1
        if e.actor then
            pcall(function() localDead = e.actor:IsDead() == true end)
            pcall(function() localHp = e.actor:GetHealth() or -1 end)
        end
        mp_log(string.format("NPC-DEATH %s inbound stream says DEAD (stream hp=%s)%s; local copy IsDead=%s hp=%s",
            name, tostring(hp),
            p.everPacket and " -- witnessed alive->dead on this stream" or " -- dead on its first packet here (late join / save state): freeze only",
            tostring(localDead), tostring(localHp)))
    elseif wasDead and not p.dead then
        mp_log(string.format("NPC-DEATH %s inbound stream says ALIVE again (stream hp=%s) -- was dead on this stream", name, tostring(hp)))
    end
    p.everPacket = true
    KCD2MP_StartNpcPuppet()
end

-- WO-49: draw the puppet's weapon, routing an Oversized main-hand through
-- DrawFromInventory INSTEAD of DrawWeapon (WO-47's polearm lesson + ordering
-- trap). Shared by the drawn-transition apply and the brain-fought-back
-- re-assert below.
local function mp_npc_draw(name, e)
    local og, drew = (KCD2MP.npcOversized or {})[name], false
    if og and e.inventory then
        pcall(function()
            local it = e.inventory:FindItem(tostring(og))
            if it then
                e.human:DrawFromInventory(it, 0, true)
                drew = true
            end
        end)
    end
    if not drew then pcall(function() e.human:DrawWeapon() end) end
end

-- WO-106 Phase 2: scratch tables for KCD2MP_NpcPuppetTick -- ppos is one
-- player-position read per tick (target-tracking); ap is read fresh per
-- live puppet per tick inside the per-name pcall below (tug-of-war
-- detection). Both feed only scalar math (ap.x/y, ppos.x/y) immediately,
-- never stored past the closure, so one reused table per call site is safe.
local NPCPUPPETTICK_PPOS_SCRATCH = {}
local NPCPUPPETTICK_AP_SCRATCH   = {}
function KCD2MP_NpcPuppetTick(arg, gen)
    -- WO-84: absorb the orphan of a generation that stopped ITSELF.
    --
    -- This tick reschedules its successor at the TOP (below) and may decide at
    -- the BOTTOM that there is nothing left to drive ("puppet tick stopped (no
    -- puppets)"). That leaves exactly one scheduled timer belonging to a
    -- generation that is no longer running. Normally it fires 50 ms later,
    -- finds npcPuppetRunning false, and dies quietly.
    --
    -- It does not die quietly when a packet arrives inside that window.
    -- KCD2MP_StartNpcPuppet then calls chainMayStart, which -- correctly --
    -- grants a stopped chain an IMMEDIATE restart: the flag is false, so it
    -- returns true on its second line without arming any probe. Generation
    -- N+1 starts, sets the flag back to true, and the orphaned generation-N
    -- timer wakes into a live chain and is reported as a leak it did not
    -- cause. A menu widens that 50 ms window to the whole menu, because
    -- Script.SetTimer is suspended while the agent's pump and its inbound
    -- ExecuteString traffic keep running: the orphan and the new chain's first
    -- timer are both released together when the menu closes.
    --
    -- That is exactly what the 2026-09-11 joiner log shows, in five
    -- consecutive mod lines: five `NPC-SYNC release ... (stream silent)`, then
    -- `puppet tick stopped (no puppets)`, then `NPC-SYNC puppet start
    -- ttkc_scribe`, then `puppet tick started (50ms) gen=17` -- and the leak
    -- line 1,225 lines later, 21 lines after the map screen closed.
    --
    -- It is NOT the mechanism WO-78 fixed. WO-78's leaks came from a false
    -- restart of a chain that was suspended rather than dead, and its probe
    -- gate stops those. Here the chain really did stop, the restart is
    -- legitimate, and the gate is bypassed by design. So the orphan is
    -- retired by name instead: it exits silently, writes no puppet, and is
    -- counted rather than reported as a leak.
    if gen ~= nil and KCD2MP._npcPuppetRetired[gen] then
        KCD2MP._npcPuppetRetired[gen] = nil
        KCD2MP._npcPuppetRetiredN = (KCD2MP._npcPuppetRetiredN or 0) + 1
        return
    end
    if not KCD2MP.npcPuppetRunning then return end
    -- WO-69: chain identity. `gen` is nil for the external menu pump (which
    -- never reschedules and so cannot be a leaked chain) and for any legacy
    -- bare reschedule; only a generation-stamped chain is checked.
    if gen ~= nil and gen ~= KCD2MP.npcPuppetGen then
        KCD2MP._chainLeakN.puppet = (KCD2MP._chainLeakN.puppet or 0) + 1
        if not KCD2MP._chainLeakSeen.puppet then
            KCD2MP._chainLeakSeen.puppet = true
            mp_log(string.format(
                "NPC-SYNC CHAIN LEAK CONFIRMED: puppet chain gen=%s is still running while gen=%s"
                .. " is current -- two chains were writing the same puppets%s",
                tostring(gen), tostring(KCD2MP.npcPuppetGen),
                KCD2MP.npcChainFix and " (stale chain exiting now)"
                                    or " (observe-only; `mp_npc_chainfix on` to stop it)"))
            -- WO-78: the 2026-09-11 session logged this line on both machines
            -- and nobody could have known to act on it live. Surface it.
            pcall(function() KCD2MP_ShowNativeToast("KCD2-MP: NPC puppet chain leak detected -- see kcd.log") end)
        end
        -- The fix, gated: a stale chain stops rescheduling and dies here.
        if KCD2MP.npcChainFix then return end
    end
    -- WO-40 Phase 2: same pump pattern as KCD2MP_InterpTick. A menu suspends
    -- Script.SetTimer (WO-12/13), which froze every NPC puppet for the paused
    -- player -- the WO-13 ghost fix was never applied to this second tick.
    -- The agent's menu pump now calls this with arg="ext": no reschedule, no
    -- alive-stamp (a pumped call must not make a dead chain look healthy).
    if arg ~= "ext" then
        Script.SetTimer(KCD2MP.npcPuppetTickMs, function() KCD2MP_NpcPuppetTick(nil, gen) end)  -- reschedule FIRST, rate read fresh every tick (mp_puppet_rate)
        KCD2MP._npcPuppetAliveAt = os.clock()
    end

    local now = os.clock()

    -- WO-69: dump the measured inbound cadence every 5 s. This is the number
    -- WO-70 needs and the one nothing has ever recorded.
    local st = KCD2MP.npcPacketStats
    if (st.n > 0 or (st.idleN or 0) > 0) and (now - (st.dumpAt or 0)) >= 5.0 then
        st.dumpAt = now
        mp_log(string.format(
            "NPC-SYNC packet cadence: moving n=%d mean=%.0fms min=%.0fms max=%.0fms; idle-heartbeat n=%d"
            .. " (emitter is %dms, heartbeat %.0fms;"
            .. " apply tick is 50ms; chain leaks=%d orphans absorbed=%d corpse writes suppressed=%d)",
            st.n, st.n > 0 and (st.sum / st.n) or 0, st.n > 0 and st.min or 0, st.max, st.idleN or 0,
            KCD2MP.npcSync.emitMs or 250, ((KCD2MP.npcSync.heartbeatS or 2.0) * 1000),
            KCD2MP._chainLeakN.puppet or 0, KCD2MP._npcPuppetRetiredN or 0,
            KCD2MP._npcDeathSuppressedN or 0))
        st.n, st.sum, st.min, st.max, st.idleN = 0, 0, 1e9, 0, 0
    end
    -- WO-102 Phase 5: which owned NPC is this player facing? The nearest live
    -- puppet within 4 m, re-evaluated every tick, emitted on change as
    -- `npc_target <name|->`. The agent turns a committed attack at it into an
    -- NpcRequest to the owner. Only meaningful on a non-authority under host
    -- authority (a puppet IS an owned body there); off that model nothing is
    -- emitted, so the event channel is byte-identical to 0.23.2.
    if KCD2MP.wo102.authorityHost and not KCD2MP.hitSensorOn and player then
        local ppos = nil
        pcall(function() ppos = player:GetWorldPos(NPCPUPPETTICK_PPOS_SCRATCH) end)
        local best, bestD = nil, 16.0   -- 4 m squared
        if ppos then
            for name, p in pairs(KCD2MP.npcPuppets) do
                if not (p.dead or p.ko) and p.cx then
                    local dx, dy = p.cx - ppos.x, p.cy - ppos.y
                    local d = dx * dx + dy * dy
                    if d < bestD then best, bestD = name, d end
                end
            end
        end
        if best ~= KCD2MP._npcTarget then
            KCD2MP._npcTarget = best
            KCD2MP_EmitEvent("npc_target", best or "-")
        end
    elseif KCD2MP._npcTarget ~= nil then
        KCD2MP._npcTarget = nil
        KCD2MP_EmitEvent("npc_target", "-")
    end

    local any = false
    for name, p in pairs(KCD2MP.npcPuppets) do
        pcall(function()
            -- Release on silence: the engine restores the NPC to its own
            -- schedule the moment we stop writing (observed live, WO-32).
            if (now - (p.lastPacketAt or 0)) > KCD2MP.npcSync.releaseS then
                KCD2MP_NpcReplicaDemote(name, "silence")   -- WO-104: the NPC returns before the puppet is dropped
                KCD2MP.npcPuppets[name] = nil
                mp_log("NPC-SYNC release " .. name .. " (stream silent)")
                mp_auth_log(name, "release", p.owner == nil and "?" or p.owner, "silence", now - (p.ownerSince or now))   -- WO-102
                mp_wo102_release(name, "silence")   -- WO-102 Phase 4; WO-108 s3.5: held for the dwell, resumed by mp_wo102_pending_tick
                return
            end
            any = true

            local e, isReplica = KCD2MP_NpcBody(name)
            if not e then return end
            -- WO-104: life state (dead/KO/hp) is read from the WORLD NPC -- the
            -- canonical local copy every by-name path still targets -- never
            -- from the replica body.
            local lifeE = e
            if isReplica then
                local o = nil
                pcall(function() o = System.GetEntityByName(name) end)
                if o then lifeE = o end
            end
            -- WO-102 Phase 4: a puppet that existed before the pause lever was switched on.
            if KCD2MP.wo102.authorityHost and KCD2MP.wo102.authorityPause and not KCD2MP._npcPaused[name] then
                mp_wo102_pause(name, p)
            end

            -- WO-34's corpse lesson, applied on both death sources: if the
            -- authority says dead, or this world's copy died locally, stop
            -- driving -- a corpse must not be dragged around. WO-38 Phase 6
            -- extends the same rule to unconsciousness on both sources: a
            -- knocked-out NPC kept walking under the stream (Section G).
            local locallyDead, locallyKo = false, false
            if lifeE.actor then
                pcall(function() locallyDead = lifeE.actor:IsDead() == true end)
                pcall(function() locallyKo = lifeE.actor:IsUnconscious() == true end)
            end
            -- WO-86: the third death reader. This is the one that covers the
            -- field report's killer: the NPC was a PUPPET on their machine
            -- (streamed by the peer), so the emitter never tracked it and the
            -- drag sensor only sees bodies within 6 m. The local hp is read
            -- only for a dead body (one extra call per death, not per tick).
            local localHp = -1
            if locallyDead and lifeE.actor then pcall(function() localHp = lifeE.actor:GetHealth() or -1 end) end
            mp_npc_death_observe(name, locallyDead, localHp, "puppet")
            -- WO-104 Phase 1: resolution. A dead/KO NPC demotes at once so the
            -- real corpse is the one on the ground; a fight is over when the
            -- owner's stream has had the weapon away for sheathedDemoteS.
            if isReplica then
                local r = KCD2MP._npcReplicas[name]
                if p.dead or p.ko or locallyDead or locallyKo then
                    KCD2MP_NpcReplicaDemote(name, (p.dead or locallyDead) and "dead" or "unconscious")
                    return
                end
                if p.drawn then r.sheathedSince = nil
                else
                    r.sheathedSince = r.sheathedSince or now
                    if (now - r.sheathedSince) >= KCD2MP.npcReplica.sheathedDemoteS then
                        KCD2MP_NpcReplicaDemote(name, "sheathed")
                        return
                    end
                end
            end
            -- A peer has declared this body dead (KCD2MP_NpcRemoteDeath) and
            -- the DLL apply is in flight or failed: hold it still for a few
            -- seconds rather than lerp a body that is about to be a corpse.
            -- Bounded so a FAILED apply cannot freeze a living NPC for the
            -- rest of the session; a successful one makes locallyDead true
            -- and the hold is moot.
            local rd = KCD2MP._npcDeathRemote[name]
            local remoteDead = rd ~= nil and (now - (rd.at or 0)) < 10.0
            -- WO-40 Phase 6: the authority's weapon state, applied on the
            -- transition (the same DrawWeapon/HolsterWeapon calls the ghost
            -- path live-verified in WO-39).
            if (p.drawn or false) ~= (p.appliedDrawn or false) then
                p.appliedDrawn = p.drawn or false
                if e.human then
                    if p.drawn then mp_npc_draw(name, e)
                    else pcall(function() e.human:HolsterWeapon() end) end
                end
                p.drawnCheckAt = now   -- give the draw/holster time before the re-assert below judges it
                mp_log("NPC-SYNC " .. name .. (p.drawn and " drew weapon" or " sheathed weapon"))
            end

            if p.dead or p.ko or locallyDead or locallyKo or remoteDead then
                -- WO-86, the safeguard. Body-follow below exists for ONE case:
                -- the stream's owner is manipulating a body that is down in
                -- THEIR world too (their packet carries the dead/KO bit). When
                -- only THIS world's copy is down and the stream says alive,
                -- the stream is a living NPC walking in the peer's world, and
                -- following it is the field report's corpse being dragged
                -- along the walk. Nothing is written. The divergence is
                -- logged once per body; the observer above has already
                -- announced the death (or is about to), which is the fix
                -- that makes the two worlds agree.
                if KCD2MP.npcDeathSync and not (p.dead or p.ko) then
                    KCD2MP._npcDeathSuppressedN = (KCD2MP._npcDeathSuppressedN or 0) + 1
                    if not KCD2MP._npcDeathDiverged[name] then
                        KCD2MP._npcDeathDiverged[name] = true
                        mp_log(string.format(
                            "NPC-DEATH DIVERGENCE %s: local copy is %s but the inbound stream says ALIVE (stream hp=%s)"
                            .. " -- corpse writes suppressed (WO-86 safeguard; pre-WO-86 this body would follow the stream)",
                            name,
                            locallyDead and "DEAD" or locallyKo and "KO" or "peer-declared dead (DLL apply in flight or failed)",
                            tostring(p.hp)))
                    end
                    return
                end
                -- WO-38 Phase 6, the drag gap: on THIS channel the stream is
                -- the body's actual location in the authority's world (unlike
                -- the ghost stream, which is a live player's position -- that
                -- one must stay frozen, WO-34). So a body is allowed to
                -- FOLLOW a meaningful stream move -- the authority dragging a
                -- corpse -- as a one-shot placement, no animation, no per-tick
                -- lerp fighting the local ragdoll. Small jitter stays frozen.
                -- WO-40 Phase 7: a CARRIED body follows the stream smoothly
                -- every tick (a body on someone's shoulders moves like they
                -- do), instead of the half-metre teleport steps that read as
                -- "phases upward onto shoulders" in the footage. Dragged/
                -- static bodies keep the one-shot placement -- a per-tick
                -- lerp would fight the local ragdoll for no reason.
                if p.carried then
                    local cdx2 = (p.tx or p.cx) - p.cx
                    local cdy2 = (p.ty or p.cy) - p.cy
                    if cdx2 * cdx2 + cdy2 * cdy2 > 25.0 then
                        p.cx, p.cy, p.cz = p.tx, p.ty, p.tz
                    else
                        p.cx = p.cx + cdx2 * 0.5
                        p.cy = p.cy + cdy2 * 0.5
                        p.cz = p.tz or p.cz
                    end
                    pcall(function() e:SetWorldPos({x = p.cx, y = p.cy, z = p.cz}) end)
                    if p.animTag ~= "carried" then
                        p.animTag = "carried"
                        mp_log("NPC-SYNC body carried-follow " .. name)
                    end
                    return
                end
                local bx = p.dragX or p.cx
                local by = p.dragY or p.cy
                local ddx = (p.tx or bx) - bx
                local ddy = (p.ty or by) - by
                if (ddx*ddx + ddy*ddy) > 0.25 then
                    p.dragX, p.dragY = p.tx, p.ty
                    pcall(function() e:SetWorldPos({x = p.tx, y = p.ty, z = p.tz or p.cz}) end)
                    mp_log(string.format("NPC-SYNC body follow %s -> %.1f,%.1f", name, p.tx, p.ty))
                end
                return
            end

            -- WO-40 Phase 6: swing cue, and the one-shot pin. Per-tick
            -- SetWorldPos + anim restarts stomp one-shots before a frame
            -- renders (WO-39's ghost lesson) -- while a cue plays, this
            -- puppet gets no writes at all; the lerp catches up after.
            if p.swingCuePending then
                p.swingCuePending = nil
                pcall(function() KCD2MP_PuppetSwingCue(name, p, e) end)
            end
            if (p.oneShotUntil or 0) > now then return end

            -- WO-49 live-gate fix (observed): the NPC's own unsuppressed
            -- brain can re-holster on its own schedule -- two swings in,
            -- the puppet sheathed, went back to its wall lean, and cue 3
            -- rendered bare-handed. The transition gate above never fires
            -- again (p.appliedDrawn still matches p.drawn), so re-assert
            -- the STREAMED drawn state against the entity's REAL state,
            -- throttled, only for live non-held puppets (returns above).
            if e.human and (now - (p.drawnCheckAt or 0)) >= 1.5 then
                p.drawnCheckAt = now
                local actual = nil
                pcall(function() actual = e.human:IsWeaponDrawn() == true end)
                if actual ~= nil and actual ~= (p.drawn or false) then
                    if p.drawn then mp_npc_draw(name, e)
                    else pcall(function() e.human:HolsterWeapon() end) end
                    mp_log("NPC-SYNC " .. name .. " re-asserted "
                        .. (p.drawn and "drawn" or "sheathed") .. " (local brain fought back)")
                end
            end

            -- WO-40 Phase 5 diagnostic: measure the tug-of-war instead of
            -- guessing. If the entity is found away from where we last wrote
            -- it, something else moved it -- count it, and cluster WHERE it
            -- was found so a live session can answer "how many competing
            -- attractors does this NPC have" (the footage's wagon worker
            -- phased between THREE points, not the documented two).
            if p.lastWroteX then
                local ap = nil
                pcall(function() ap = e:GetWorldPos(NPCPUPPETTICK_AP_SCRATCH) end)
                if ap then
                    local fx, fy = ap.x - p.lastWroteX, ap.y - p.lastWroteY
                    -- WO-99 Phase 2: sustained sub-8 m contention -> yield.
                    local yc = KCD2MP.npcYield
                    if KCD2MP.wo102.authorityHost then
                        -- WO-102 Phase 4: no yielding -- no second writer is
                        -- allowed. Sustained contention is a violation, logged,
                        -- never a hand-back.
                        if yc and (fx*fx + fy*fy) > yc.dispM * yc.dispM then
                            p.yieldStreak = (p.yieldStreak or 0) + 1
                            if p.yieldStreak >= (yc.ticks or 10) then
                                mp_wo102_violation(name, p, "contention", math.sqrt(fx*fx + fy*fy), fx, fy)   -- WO-108 s3.3: may be tagged relax
                                p.yieldStreak = 0
                            end
                        else
                            p.yieldStreak = 0
                        end
                    elseif yc and yc.enabled and not p.yielded then
                        if (fx*fx + fy*fy) > yc.dispM * yc.dispM then
                            p.yieldStreak = (p.yieldStreak or 0) + 1
                            if p.yieldStreak >= yc.ticks then
                                p.yielded = true
                                p.yieldAnchorX, p.yieldAnchorY = p.tx or p.cx, p.ty or p.cy
                                p.yieldAt = now
                                KCD2MP._npcYieldN = (KCD2MP._npcYieldN or 0) + 1
                                mp_auth_log(name, "release", p.owner == nil and "?" or p.owner, "yield", now - (p.ownerSince or now))   -- WO-102
                                mp_log(string.format("MP-NPCYIELD npc=%s state=yield disp_m=%.2f streak=%d fight_n=%d total_yields=%d total_repins=%d",
                                    name, math.sqrt(fx*fx + fy*fy), p.yieldStreak, p.fightN or 0,
                                    KCD2MP._npcYieldN, KCD2MP._npcRepinN or 0))
                            end
                        else
                            p.yieldStreak = 0
                        end
                    end
                    -- WO-69: the threshold was 0.5625 m^2 = 0.75 m of drift in
                    -- one 50 ms tick = 15 m/s. Nothing short of a teleport
                    -- moves that fast, so this counter was blind to every
                    -- realistic brain contention and its lifetime count of
                    -- zero meant nothing. 0.0025 m^2 = 5 cm/tick = 1 m/s,
                    -- which is walking pace and the scale D2 would actually
                    -- act at. It also LOGS now, throttled: the count alone
                    -- only ever printed from the manual mp_npc_fight command,
                    -- which no field session has ever run.
                    if (fx*fx + fy*fy) > 0.0025 then
                        p.fightN = (p.fightN or 0) + 1
                        KCD2MP._stats.npcFightEvents = KCD2MP._stats.npcFightEvents + 1
                        local fdist = math.sqrt(fx*fx + fy*fy)
                        -- WO-98 Phase 6: the machine-readable record is a
                        -- per-NPC 10 s aggregate; the prose line stays for a
                        -- human skimming the log, at 30 s instead of 5 s.
                        local fw = p.fightWin
                        if not fw then fw = { n = 0, sum = 0, max = 0, since = now }; p.fightWin = fw end
                        fw.n = fw.n + 1; fw.sum = fw.sum + fdist
                        if fdist > fw.max then fw.max = fdist end
                        if (now - fw.since) >= 10.0 then
                            mp_log(string.format("MP-NPCFIGHT npc=%s n=%d mean_m=%.2f max_m=%.2f window_s=%.0f total=%d authority=peer",
                                name, fw.n, fw.sum / fw.n, fw.max, now - fw.since, p.fightN))
                            p.fightWin = { n = 0, sum = 0, max = 0, since = now }
                        end
                        if (now - (p.fightLogAt or 0)) >= 30.0 then
                            p.fightLogAt = now
                            mp_log(string.format(
                                "NPC-FIGHT %s displaced %.2fm from our last write in one tick (n=%d) -- something else is moving it",
                                name, fdist, p.fightN))
                        end
                        p.attr = p.attr or {}
                        local matched = false
                        for _, a in ipairs(p.attr) do
                            local ax, ay = ap.x - a.x, ap.y - a.y
                            if (ax*ax + ay*ay) < 1.0 then a.n = a.n + 1; matched = true; break end
                        end
                        if not matched and #p.attr < 6 then
                            p.attr[#p.attr + 1] = { x = ap.x, y = ap.y, n = 1 }
                        end

                        -- WO-90: stop fighting a world that disagrees.
                        --
                        -- The counter above has always measured exactly the
                        -- thing that hurts and has never acted on it. In the
                        -- 2026-09-12 field session the host's copy of Hans
                        -- read 57.24 m from our last write, over and over,
                        -- for 38 s (host kcd.log 391403-393871, 21:40:50 to
                        -- 21:41:28) while the joiner -- nine and a half
                        -- minutes further along the same quest -- held the
                        -- claim on him and streamed him from the lake. The
                        -- local engine wanted Hans at the camp because the
                        -- host's own quest needed him there. Neither side was
                        -- wrong: the two worlds were at different story
                        -- beats, and one NPC cannot be in both.
                        --
                        -- Displacements at this scale are not combat
                        -- footwork (the ordinary contention this counter sees
                        -- is 0.05-0.6 m). They mean the local brain is
                        -- driving this body somewhere else entirely, and
                        -- every tick we spend dragging it back is the "severe
                        -- jitter" the field reported -- and, worse, it is what
                        -- made the NPC unusable for the player whose own
                        -- progression needed it (findings 5, 6 and 8).
                        --
                        -- So: hand the body back. Release the puppet, let the
                        -- local world own it, and refuse to re-puppet that
                        -- name for a cooldown so the release is not undone by
                        -- the next inbound packet. Deliberately receiver-side
                        -- and one-sided -- it needs no agreement from the
                        -- other client, no wire change and no quest model,
                        -- and it self-heals when the worlds converge again.
                        --
                        -- Counted in a sliding window rather than on
                        -- consecutive ticks because that is the shape the
                        -- field data actually has: 10 far readings in 38 s,
                        -- not 760 (we write every tick, so most ticks read
                        -- back exactly where we put it; the engine yanks it
                        -- away intermittently).
                        if KCD2MP.wo102.authorityHost and (fx*fx + fy*fy) > MP_NPC_DIVERGE_M * MP_NPC_DIVERGE_M then
                            -- WO-102 Phase 4: under host authority there is no
                            -- second world to diverge from. The body is NOT
                            -- released -- the stream stays the truth -- and the
                            -- event is logged loudly as what it is: something
                            -- on this machine is still writing this body.
                            mp_wo102_violation(name, p, "diverge", math.sqrt(fx*fx + fy*fy), fx, fy)
                        elseif KCD2MP.npcDiverge and (fx*fx + fy*fy) > MP_NPC_DIVERGE_M * MP_NPC_DIVERGE_M then
                            local keep = {}
                            for _, t0 in ipairs(p.farHits or {}) do
                                if (now - t0) <= MP_NPC_DIVERGE_WINDOW_S then keep[#keep + 1] = t0 end
                            end
                            keep[#keep + 1] = now
                            p.farHits = keep
                            if #keep >= MP_NPC_DIVERGE_HITS then
                                mp_log(string.format(
                                    "NPC-DIVERGE %s: local world moved it %.1fm from our write, %d times in %.0fs"
                                    .. " -- releasing the puppet and leaving it to this world for %.0fs"
                                    .. " (WO-90; `mp_npc_diverge off` to restore the pre-WO-90 tug-of-war)",
                                    name, math.sqrt(fx*fx + fy*fy), #keep, MP_NPC_DIVERGE_WINDOW_S,
                                    MP_NPC_DIVERGE_COOLDOWN_S))
                                -- WO-94: a release inside a catch-up window is the "dragged NPC state" hazard (WO-92 s6.4 hazard 3).
                                if KCD2MP_QuestHazard then KCD2MP_QuestHazard("npc-dragged", string.format("%s released by the divergence rule (%.1fm from our write)", name, math.sqrt(fx*fx + fy*fy))) end
                                KCD2MP_NpcReplicaDemote(name, "diverge")   -- WO-104
                                KCD2MP.npcPuppets[name] = nil
                                KCD2MP._npcDivergeUntil[name] = now + MP_NPC_DIVERGE_COOLDOWN_S
                                KCD2MP._npcDivergeN = (KCD2MP._npcDivergeN or 0) + 1
                                mp_log(string.format("MP-NPCDIVERGE npc=%s dist_m=%.1f hits=%d window_s=%.0f standoff_s=%.0f total=%d",
                                    name, math.sqrt(fx*fx + fy*fy), #keep, MP_NPC_DIVERGE_WINDOW_S, MP_NPC_DIVERGE_COOLDOWN_S, KCD2MP._npcDivergeN))
                                mp_auth_log(name, "release", p.owner == nil and "?" or p.owner, "diverge", now - (p.ownerSince or now))   -- WO-102
                                -- Tell the player, at most once a minute: an
                                -- NPC that suddenly stops matching the other
                                -- player's world is otherwise inexplicable,
                                -- and this is the one moment where saying
                                -- "you are at different points in the story"
                                -- actually helps. The agent's own story layer
                                -- (WO-90, 0x37/0x38) names WHICH points when
                                -- both clients are new enough to carry it.
                                -- WO-98 Phase 4 Target C / Phase 7: this toast led with
                                -- the NPC's entity name ("KCD2-MP: ttkc_inkeeper is at a
                                -- different point...") and was the only toast in the
                                -- 2026-09-15 session that could read as a peer named
                                -- "kcd2_tctk"-like. It now names the PEER, tucks the NPC
                                -- name at the end, stays quiet while the quest layer's own
                                -- divergence row or prompt is already explaining the
                                -- situation, and fires at most once per 5 min.
                                local questExplaining = KCD2MP.quest and (KCD2MP.quest.prompt
                                    or (KCD2MP_QuestWaitingVisible and KCD2MP_QuestWaitingVisible()))
                                if not questExplaining and (now - (KCD2MP._npcDivergeToastAt or -1e9)) >= 300.0 then
                                    KCD2MP._npcDivergeToastAt = now
                                    local peer = "your friend"
                                    for gid, _ in pairs(KCD2MP.ghosts) do
                                        local nm = KCD2MP.ghostNames and KCD2MP.ghostNames[gid]
                                        if nm and nm ~= "" then peer = nm; break end
                                    end
                                    pcall(function()
                                        KCD2MP_ShowNativeToast(
                                            "KCD2-MP: your story and " .. peer .. "'s have diverged -- nearby NPCs"
                                            .. " now follow your own game (e.g. " .. tostring(name) .. ")")
                                    end)
                                end
                                return
                            end
                        end
                    end
                end
            end

            -- WO-99 Phase 2: a yielded puppet gets no position/angle/anim
            -- writes -- the local brain owns the body until the stream moves
            -- (re-pin in KCD2MP_ApplyNpcState). lastWrote is cleared so the
            -- tug-of-war counter does not measure a write we did not make.
            -- WO-104: the body changed inside this tick (a violation above just
            -- promoted it) -- the first write goes to the new body next tick.
            if ((KCD2MP._npcReplicas or {})[name] ~= nil) ~= isReplica then return end

            if p.yielded then
                p.lastWroteX, p.lastWroteY = nil, nil
                return
            end

            -- WO-77 Step 1: interpolation-behind (mp_npc_smooth on, the
            -- default). Everything below derives from os.clock() elapsed --
            -- the D3 structural fix (WO-75 s2.5). `spd` is the constant
            -- speed of the segment being rendered.
            local spd = nil
            if KCD2MP.npcSmooth then
                spd = mp_npc_smooth_render(p, now)
            end
            local dx, dy = 0, 0
            if spd ~= nil then
                -- rendered; fall through to the write below
            else
            -- Legacy path (mp_npc_smooth off, or an empty ring): the
            -- pre-WO-77 per-tick 0.5 lerp, kept verbatim for the live A/B.
            -- Same teleport-vs-lerp shape as the ghost interp: snap on a big
            -- gap, smooth otherwise.
            dx, dy = (p.tx or p.cx) - p.cx, (p.ty or p.cy) - p.cy
            if dx*dx + dy*dy > 25.0 then
                p.cx, p.cy, p.cz, p.cr = p.tx, p.ty, p.tz, p.tr
            else
                p.cx = p.cx + dx * 0.5
                p.cy = p.cy + dy * 0.5
                p.cz = p.tz or p.cz
                -- WO-69: yaw was a HARD SNAP (`p.cr = p.tr or p.cr`) while
                -- position was lerped -- so a puppet's body slid smoothly
                -- while its facing jumped 4x/sec to whatever the last packet
                -- said. That is a jitter source entirely independent of the
                -- position stream, and no amount of position smoothing would
                -- have fixed it. lerpAngle is the ghost path's own
                -- shortest-path helper (file-top local, in scope here --
                -- unlike getFloorZ, which is declared AFTER this tick and
                -- would bind to a nil global).
                --
                -- Position smoothing is deliberately NOT changed in this work
                -- order: it is WO-70's, behind the WO-63 ordering gate
                -- (live-verify WO-60 first). Yaw is safe to land now because
                -- it smooths ROTATION, so it cannot mask the position
                -- snap-between-attractors that WO-60's footage has to show.
                if p.tr then p.cr = lerpAngle(p.cr or p.tr, p.tr, 0.5) end
            end
            -- Legacy speed: per-tick rendered displacement, no hysteresis.
            spd = math.sqrt(dx*dx + dy*dy) * 0.5 / 0.050
            end

            e:SetWorldPos({x = p.cx, y = p.cy, z = p.cz})
            p.lastWroteX, p.lastWroteY = p.cx, p.cy
            pcall(function() e:SetWorldAngles({x = 0, y = 0, z = p.cr}) end)

            -- Animation from rendered speed. Without this the NPC slides in
            -- its current activity pose (observed live: a seated NPC slid
            -- sitting).
            --
            -- WO-77: on the smooth path the tag comes from the segment speed
            -- through a copy of the ghost path's hysteresis bands
            -- (mp_npc_anim_tag), so the tag cannot churn inside a packet gap
            -- -- the design's constraint 2, re-deriving spd in the same
            -- change as the position math. The legacy path keeps its raw
            -- thresholds so `mp_npc_smooth off` really is the old renderer.
            --
            -- WO-38 Phase 5: a Horse-class puppet gets horse gaits, not
            -- humanoid locomotion. These three names were confirmed present
            -- on real KCD2 horse entities by the mp_scan_horse probes (see
            -- the HORSE_ENTITY_* candidate lists' comments). Horse gaits are
            -- unchanged by WO-77 (segment speed is already constant).
            local tag, anim
            if tostring(e.class or "") == "Horse" then
                if     spd >= 4.0 then tag, anim = "gallop", "relaxed_gallop"
                elseif spd >= 0.3 then tag, anim = "walk",   "relaxed_walk"
                else                    tag, anim = "idle",   "relaxed_idle" end
            else
                if KCD2MP.npcSmooth and p.ring and #p.ring > 0 then
                    tag = mp_npc_anim_tag(spd, p.animTag)
                    if     tag == "sprint" then anim = "3d_relaxed_sprint_turn_strafe"
                    elseif tag == "run"    then anim = "3d_relaxed_run_turn_strafe"
                    elseif tag == "walk"   then anim = "3d_relaxed_walk_turn_strafe"
                    else   tag, anim = "idle", "relaxed_idle_both" end
                else
                if     spd >= 5.5 then tag, anim = "sprint", "3d_relaxed_sprint_turn_strafe"
                elseif spd >= 3.0 then tag, anim = "run",    "3d_relaxed_run_turn_strafe"
                elseif spd >= 0.3 then tag, anim = "walk",   "3d_relaxed_walk_turn_strafe"
                else                    tag, anim = "idle",   "relaxed_idle_both" end
                end
                -- WO-40 Phase 6: a weapon-out NPC idles in the combat guard
                -- (human-confirmed correct read on ghosts, WO-39), so a
                -- fighting NPC reads as fighting instead of standing.
                if tag == "idle" and p.drawn then
                    local cIdle = nil
                    pcall(function() cIdle = KCD2MP_CombatIdleFor(e) end)
                    if cIdle then tag, anim = "combatidle", cIdle end
                end
            end
            -- WO-40 Phase 5: restart the looped locomotion only on a tag
            -- change, with a 1 s keep-alive refresh -- not every 50 ms tick.
            -- Restarting a loop 20x/sec is pure animation-system churn (the
            -- WO-39 stomping mechanism, applied to a second code path), and
            -- the joiner's global animation collapse followed the session's
            -- heaviest per-frame load. External stops recover within 1 s.
            if p.animTag ~= tag or (now - (p.animRefreshAt or 0)) > 1.0 then
                p.animRefreshAt = now
                pcall(function() e:StartAnimation(0, anim, 0, 0.15, 1.0, true) end)
                if p.animTag ~= tag then
                    p.animTag = tag
                    mp_log(string.format("NPC-SYNC anim %s -> %s spd=%.2f", name, tag, spd))
                end
            end
        end)
    end

    -- Nothing left to drive: let the chain die. A future packet restarts it.
    if not any then
        local empty = true
        for _ in pairs(KCD2MP.npcPuppets) do empty = false; break end
        if empty then
            KCD2MP.npcPuppetRunning = false
            -- WO-84: this tick already scheduled its successor (above, or on
            -- the last scheduled tick if this stop came from a pumped call).
            -- Retire the generation that owns that orphan so it exits silently
            -- instead of waking into whatever generation a new packet starts.
            -- Retire the CURRENT generation rather than `gen`: a pumped call
            -- arrives with gen == nil but the in-flight timer still belongs to
            -- KCD2MP.npcPuppetGen.
            local orphan = KCD2MP.npcPuppetGen
            if orphan then KCD2MP._npcPuppetRetired[orphan] = true end
            mp_log("NPC-SYNC puppet tick stopped (no puppets)")
        end
    end
end

function KCD2MP_StartNpcPuppet()
    -- WO-78: this is the per-packet caller of the shared gate. The field
    -- session showed it restarting once per ~1 s of suspension (67 starts vs
    -- 34 for the 2.5 s-re-armed chains) -- same defect, faster caller.
    if not chainMayStart("puppet", "npcPuppetRunning", "_npcPuppetAliveAt", KCD2MP_StartNpcPuppet) then return end
    KCD2MP.npcPuppetRunning = true
    KCD2MP._npcPuppetAliveAt = os.clock()
    -- WO-69: every start claims a new generation. Any chain still running
    -- under an older one is, by definition, a leaked chain -- and now says so.
    KCD2MP.npcPuppetGen = (KCD2MP.npcPuppetGen or 0) + 1
    local myGen = KCD2MP.npcPuppetGen
    mp_log(string.format("NPC-SYNC puppet tick started (%.0fms) gen=%s", KCD2MP.npcPuppetTickMs, tostring(myGen)))
    Script.SetTimer(KCD2MP.npcPuppetTickMs, function() KCD2MP_NpcPuppetTick(nil, myGen) end)
end

-- WO-69: `mp_npc_chainfix on|off`. Off (default) = a leaked chain is logged
-- and left running, so the leak can be OBSERVED before it is fixed. On = the
-- stale chain exits. Deliberately a toggle rather than a hardcoded fix: it
-- makes the before/after a live A/B on one build instead of two deploys, and
-- leaves a rollback if stopping a chain turns out to stop the wrong one.
function KCD2MP_SetNpcChainFix(arg)
    local s = tostring(arg or ""):lower()
    if s == "on" or s == "1" or s == "true" then
        KCD2MP.npcChainFix = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.npcChainFix = false
    end
    mp_log("mp_npc_chainfix = " .. tostring(KCD2MP.npcChainFix)
           .. " (leak seen so far: puppet=" .. tostring(KCD2MP._chainLeakSeen.puppet and true or false) .. ")")
end

-- WO-27: verified entity removal.
--
-- System.RemoveEntity has been observed returning without error while the
-- entity is still alive and still in the world -- seen in WO-25 and again in
-- WO-26, where it took four passes to clear three ghosts. A single call is
-- therefore not evidence of removal, so this reads the entity back and
-- retries, and reports what actually happened rather than that the call did
-- not throw.
--
-- Two lookups, both by keys that survive the entity's lifetime: the entity id
-- captured at spawn, and the SPAWN name ("kcd2mp_<id>") -- which is also the
-- key the RPG SoulList files the ghost's soul under. The display name is
-- deliberately not used: it is not a key anything can be looked up by.
local function mp_remove_entity_verified(entityId, spawnName, label)
    local function alive()
        local e = nil
        if entityId then pcall(function() e = System.GetEntity(entityId) end) end
        if (not e) and spawnName then
            pcall(function() e = System.GetEntityByName(spawnName) end)
        end
        return e
    end

    for pass = 1, 4 do
        local e = alive()
        if not e then
            if pass > 1 then
                mp_log(string.format("RemoveEntity %s gone after %d pass(es)", tostring(label), pass - 1))
            end
            return true
        end
        pcall(function() System.RemoveEntity(e.id or entityId) end)
    end

    local e = alive()
    if e then
        mp_log(string.format("RemoveEntity %s STILL ALIVE after 4 passes (entityId=%s name=%s)",
            tostring(label), tostring(entityId), tostring(spawnName)))
        return false
    end
    return true
end

-- WO-27: how many ghost entities actually exist right now, counted from the
-- world rather than from KCD2MP.ghosts. The bookkeeping table is exactly what
-- the leak got wrong, so a count taken from it would agree with itself and
-- prove nothing. Returns registered, live, and the list of live spawn names.
function KCD2MP_GhostAudit()
    local registered, live, names = 0, 0, {}

    for gid, g in pairs(KCD2MP.ghosts) do
        registered = registered + 1
        local e = nil
        if g.entityId then pcall(function() e = System.GetEntity(g.entityId) end) end
        if e then
            live = live + 1
            table.insert(names, "kcd2mp_" .. tostring(gid))
        end
    end

    -- Orphans: an entity still in the world under a spawn name that no longer
    -- has a KCD2MP.ghosts row. This is the shape the leak actually took.
    for probe = 0, 32 do
        if not KCD2MP.ghosts[tostring(probe)] and not KCD2MP.ghosts[probe] then
            local e = nil
            pcall(function() e = System.GetEntityByName("kcd2mp_" .. probe) end)
            if e then
                live = live + 1
                table.insert(names, "kcd2mp_" .. probe .. " (ORPHAN)")
            end
        end
    end

    mp_log(string.format("GhostAudit registered=%d live=%d [%s]",
        registered, live, table.concat(names, ", ")))
    return registered, live
end

-- WO-27: which player a ghost belongs to, as a key that survives a reconnect.
--
-- The connection id does NOT: the relay hands out a fresh byte per connection,
-- so the same human coming back is a different id, and the old id's row is
-- never touched again. That is the whole leak -- WO-26 found three registered
-- ghosts (ids 1, 2, 3) that were all one player, all wearing the same Steam
-- nick, two of them orphaned.
--
-- The Steam nick is the only stable identity that reaches Lua: it arrives in
-- the 0x03 Name packet at handshake time, before the first Position packet
-- (docs/WO-20-faces.md), and it is already what KCD2MP_PickFaceForPlayer keys
-- the face roster on. When it has NOT arrived, this falls back to
-- "Player<id>", which is per-connection and so cannot dedupe -- an honest
-- limit, not a silent one: two nameless reconnects will still leak, and the
-- fallback is logged at spawn.
local function mp_ghost_identity(id)
    return KCD2MP.ghostNames[id]
end

-- Removes any ghost belonging to the same player under a DIFFERENT connection
-- id. Called before a spawn, so a reconnect replaces its predecessor instead
-- of orphaning it.
function KCD2MP_RemoveStaleGhostsForPlayer(identity, keepId)
    if not identity then return 0 end
    local doomed = {}
    for gid, g in pairs(KCD2MP.ghosts) do
        if gid ~= keepId and g.identity == identity then
            table.insert(doomed, gid)
        end
    end
    for _, gid in ipairs(doomed) do
        mp_log(string.format("Reconnect: '%s' returned as id=%s -- removing stale ghost id=%s",
            tostring(identity), tostring(keepId), tostring(gid)))
        KCD2MP_RemoveGhost(gid)
    end
    return #doomed
end

function KCD2MP_SpawnGhost(id, x, y, z, rotZ)
    if KCD2MP.ghosts[id] then
        KCD2MP_RemoveGhost(id)
    end

    -- WO-27: same player, new connection id. Must run BEFORE the spawn, so
    -- there is never a moment with two ghosts for one person.
    local identity = mp_ghost_identity(id)
    if identity then
        KCD2MP_RemoveStaleGhostsForPlayer(identity, id)
    else
        mp_log("SpawnGhost id=" .. tostring(id) ..
               " has no Steam nick yet -- reconnect dedupe cannot run for this spawn")
    end

    local pos = {x=x, y=y, z=z}
    -- WO-66: the "kcd2mp_" prefix here (and in every other spawn name this
    -- file mints: kcd2mp_horse_, kcd2mp_npc_, kcd2mp_ianchor_) is RESERVED at
    -- the relay -- Protocol.NpcReservedNamePrefix in dotnet/KcdMp.Protocol/
    -- Protocol.cs makes the relay refuse NPC claims for names under it.
    -- If this naming scheme ever changes, change that constant too.
    local name = "kcd2mp_" .. id

    System.LogAlways(string.format("[KCD2-MP] Spawning ghost '%s' at %.1f,%.1f,%.1f", id, x, y, z))

    -- WO-20: deterministic real face. Keyed on the Steam name if it has
    -- already arrived (KCD2MP_SetGhostName runs at Handshake time on the
    -- server, before any Position packet -- see docs/WO-20-faces.md -- so in
    -- practice it almost always has), falling back to the same "Player<id>"
    -- string the nameplate itself falls back to so a spawn is never blocked
    -- waiting on the name.
    local faceKey = identity or ("Player" .. tostring(id))
    local facePick = KCD2MP_PickFaceForPlayer(faceKey)

    -- WO-27: an entity may still be standing under this exact spawn name with
    -- no KCD2MP.ghosts row behind it -- after a save load, after the mod
    -- reinitialised, or after a RemoveEntity that silently did nothing.
    -- Spawning over it would leave the old one in the world untracked, which
    -- is the other half of how WO-26 found three ghosts for one player.
    local preexisting = nil
    pcall(function() preexisting = System.GetEntityByName(name) end)
    if preexisting then
        mp_log("SpawnGhost: untracked entity already named " .. name .. " -- removing it first")
        mp_remove_entity_verified(preexisting.id, name, name)
    end

    -- WO-22: SharedSoulGuid is a TOP-LEVEL parameter of SpawnEntity's table, not
    -- something nested under Properties. Warhorse's own shipped scriptbind doc
    -- (C_ScriptBindXGenAIModule__SpawnEntity) gives a flat table -- Name,
    -- SharedSoulGuid, SoulArchetypeName, ClassName, Pos, Rot, NoAI,
    -- SchedulerProxyName, ... -- with no Properties key in it at all.
    --
    -- Passing it nested, as this did until WO-22, binds NO soul: the spawned
    -- ghost's SharedSoulGuid reads back all-zeroes and it gets an arbitrary
    -- engine-generated appearance. That is why every ghost was brainless --
    -- a Warhorse brain is a column on the soul row (brain_id in
    -- Libs/Tables/rpg/soul__*.xml), so no soul means no brain.
    --
    -- Passed correctly, the ghost gets the roster soul's real face, faction
    -- identity, reputation log and combat level -- and, verified live, it
    -- RECOVERS from being knocked unconscious (<=54s and <=26s over two
    -- cycles) where a brainless ghost stayed down forever. That is A1 from
    -- WO-16-release-candidate.md, fixed. See docs/WO-22-brain-lead.md.
    --
    -- SchedulerProxyName is deliberately NOT passed. It is what would make the
    -- ghost pick its own activities and walk off under its own power, which
    -- fights KCD2MP_InterpTick's position stream. It is not needed for the
    -- recovery fix -- the soul alone buys that -- so a ghost spawned this way
    -- stays byte-stationary, exactly as before. ForceMount is unaffected
    -- (re-tested against a real horse on this exact shape).
    --
    -- esModularBehaviorTree is gone rather than emptied: WO-21 proved it is
    -- inert and that "IdleSeq" names no tree anywhere in the shipped game
    -- data. It was never a live variable, so the aggro toggle's switch on it
    -- was a no-op. A soul-backed ghost's reactive combat (self-defense,
    -- joining nearby fights) comes from the engine's own AI/soul/brain
    -- system once SharedSoulGuid is bound here, and is always on regardless
    -- of the aggro toggle (WO-26). The toggle's own effect is a separate,
    -- additive native hostile-faction attach applied at hit-time, not at
    -- spawn (WO-27) -- see KCD2MP_EnableAggro above.
    -- WO-100.5 Phase 0: one decision, used by every spawn path below and by
    -- the spawn-verify comparison, so mp_ghost_nai cannot be half-applied.
    local ghostClass = KCD2MP_GhostClassName(facePick.className)
    local entity = nil
    pcall(function()
        -- WO-100.5: NoAI is a shipped SpawnEntity parameter. Passed only when
        -- the toggle is on, so the default spawn table is byte-identical to
        -- what every session before this one sent.
        local t = {
            Name           = name,
            ClassName      = ghostClass,
            Pos            = {x, y, z},
            SharedSoulGuid = facePick.guid,
        }
        if KCD2MP.ghostNoAi then t.NoAI = true end
        XGenAIModule.SpawnEntity(t)
        entity = System.GetEntityByName(name)
    end)
    if not entity then
        System.LogAlways("[KCD2-MP] XGenAI spawn failed, fallback System.SpawnEntity")
        local ok2, e2 = pcall(System.SpawnEntity, {
            class = ghostClass, position = pos, name = name,
            properties = { esFaction = "Civilians", guidSharedSoulId = facePick.guid },
        })
        if ok2 then entity = e2 end
    end
    System.LogAlways(string.format("[KCD2-MP] face pick for '%s': key=%s class=%s soul=%s guid=%s",
        id, faceKey, ghostClass, facePick.soulName, facePick.guid))

    if not entity then
        System.LogAlways("[KCD2-MP] SpawnEntity failed for ghost id=" .. tostring(id))
        return nil
    end
    mp_set_no_save(entity)   -- WO-106 Phase 5: never let a ghost body into the player's save

    -- WO-69: verify-after-spawn. The face-pick line above records what was
    -- ASKED FOR; on its own it is not evidence of what the engine built. A
    -- discarded SharedSoulGuid produces a soulless default body with no error
    -- of any kind (WO-22), and a roster soul absent from the loaded save is
    -- the same silent no-op (WO-33) -- both would have been invisible in
    -- every field log the project has ever collected. This line ships
    -- permanently, and stays even now that the roster is male-only, so a
    -- silent fallback can never again hide behind a correct-looking request.
    --
    -- entity.class is the authoritative gender read: gender comes from the
    -- CLASS ("NPC" vs "NPC_Female"), not from the soul, and it is proven
    -- readable on a real ghost. entity.soul.name is read as a soul-binding
    -- probe only, BEFORE KCD2MP_ApplyName overwrites it with the nickname.
    --
    -- Nil is "unknown", never "mismatch". ApplyName's own field logs show
    -- `before=nil` on live ghosts, so the soul is not reliably reachable at
    -- spawn+0; treating an empty read as a negative would respawn healthy
    -- ghosts forever. Only a DEFINITE, non-nil disagreement acts.
    local resolvedClass, resolvedSoul = nil, nil
    pcall(function() resolvedClass = entity.class end)
    pcall(function() resolvedSoul  = entity.soul and entity.soul.name end)
    System.LogAlways(string.format(
        "[KCD2-MP] spawn verify ghost '%s': requested class=%s soul=%s guid=%s | resolved class=%s soul=%s",
        tostring(id), ghostClass, facePick.soulName, facePick.guid,
        tostring(resolvedClass), tostring(resolvedSoul)))

    -- WO-90: does this body actually HAVE a model?
    --
    -- The 2026-09-12 prologue report was "nametags only, no model", and the
    -- logs bear it out: the prologue ghost could not resolve a single
    -- animation by name (GetAnimationLength(0, ...) = 0 for all four probe
    -- clips, host kcd.log 100655/100717) while the same probe succeeded on a
    -- post-switch ghost, and the engine printed "Combat actor init failed for
    -- actor 'kcd2mp_1'" 24 times against that one entity -- the only body in
    -- the whole session that ever failed it (24/24, vs 106/106 and 340/340
    -- successes for the two later ghosts). An entity with a transform, an
    -- inventory and script contexts but no character instance on slot 0 is
    -- exactly what "nametag, no model" looks like.
    --
    -- Every mod-side call around that spawn reported success, because nothing
    -- ever asked the one question that distinguishes the two cases. This does.
    -- Read-only, one call, at a spawn that already logs four other lines --
    -- and it turns a whole class of "the ghost was invisible" report from a
    -- log-archaeology exercise into a fact recorded at the moment it happens.
    -- docs/WO-90-findings.md finding 1.
    local cdf = nil
    pcall(function() cdf = entity:GetCharacterFileName(0) end)
    if cdf == nil or tostring(cdf) == "" then
        System.LogAlways(string.format(
            "[KCD2-MP] SPAWN NO MODEL ghost '%s': GetCharacterFileName(0) is %s -- the body has no"
            .. " character instance on slot 0 and will render as nothing (nameplate only)."
            .. " This is the WO-90 finding-1 signature; report it with the kcd.log.",
            tostring(id), cdf == nil and "nil" or "empty"))
    else
        System.LogAlways("[KCD2-MP] spawn model ghost '" .. tostring(id) .. "': " .. tostring(cdf))
    end

    if resolvedClass ~= nil and tostring(resolvedClass) ~= ghostClass then
        -- Loud: this is the failure mode that produced the field report and
        -- then hid from four sessions of logs.
        System.LogAlways(string.format(
            "[KCD2-MP] SPAWN MISMATCH ghost '%s': asked for class=%s, engine built class=%s"
            .. " -- respawning once on the deterministic fallback soul %s",
            tostring(id), ghostClass, tostring(resolvedClass),
            KCD2MP.faceFallback.soulName))
        mp_remove_entity_verified(entity.id, name, "mismatched ghost " .. tostring(id))
        entity = nil
        -- Exactly one re-attempt, never a loop, and never the engine default:
        -- a named male commoner whose guid is checked into this file.
        facePick = KCD2MP.faceFallback
        ghostClass = KCD2MP_GhostClassName(facePick.className)
        pcall(function()
            local t = {
                Name           = name,
                ClassName      = ghostClass,
                Pos            = {x, y, z},
                SharedSoulGuid = facePick.guid,
            }
            if KCD2MP.ghostNoAi then t.NoAI = true end
            XGenAIModule.SpawnEntity(t)
            entity = System.GetEntityByName(name)
        end)
        if not entity then
            System.LogAlways("[KCD2-MP] fallback respawn failed for ghost id=" .. tostring(id))
            return nil
        end
        mp_set_no_save(entity)   -- WO-106 Phase 5: this is a fresh entity, flag it too
        local reClass = nil
        pcall(function() reClass = entity.class end)
        System.LogAlways(string.format(
            "[KCD2-MP] spawn verify (fallback) ghost '%s': resolved class=%s soul=%s",
            tostring(id), tostring(reClass), facePick.soulName))
    end

    -- Set faction via AI system (XGenAIModule ignores Properties.esFaction at spawn time)
    --
    -- WO-84: this was ONE unlogged pcall wrapping both statements, so in the
    -- whole history of this project no field log has ever said whether either
    -- of them did anything. Split and reported, in the same spawn-verify
    -- discipline WO-69 applied to the class/soul read above.
    --
    -- Already established, not re-litigated here:
    --   * the property write takes and changes nothing -- WO-34 read
    --     props.esFaction back as "Civilians" live while the engine's own
    --     FactionNode still resolved to the soul's faction
    --     (docs/WO-34-findings.md 1.3).
    --   * AI.GetFactionOf does not exist on this build, so nothing could ever
    --     read the result back either.
    --
    -- What WO-84 adds is a measurement nobody had made. The engine DOES answer
    -- this call when it lands: the earlier 2026-09-11 host session shows the
    -- HORSE spawn path -- which runs the same AI.ChangeParameter with the same
    -- "Civilians" string, in its own pcall -- produce
    -- `[Warning] Validator: AI: Unknown faction 'Civilians' being set...`
    -- twice, immediately after 16 `NPC kcd2mp_horse_1 does not have a faction.`
    -- lines and immediately before `HorseSpawn OK id=1`. So on an entity the
    -- AI system owns, the call reaches the engine and the engine REJECTS THE
    -- VALUE: "Civilians" is not a faction id in this build's FactionTree.
    --
    -- The ghost path never emits that warning -- zero occurrences across all
    -- three logs in the bundle, over eight ghost spawns. Two readings fit and
    -- the logs cannot separate them: either the Properties write above throws
    -- and the shared pcall aborted before AI.ChangeParameter ever ran, or the
    -- ghost has no AI object for the call to act on (SpawnGhost deliberately
    -- passes no SchedulerProxyName, and the horse path's comment records that
    -- registering one fights our per-tick SetWorldPos). This block now records
    -- which, on the next session, in one line -- including whether the entity
    -- has an AI object at that moment, which is what tells the two apart.
    --
    -- This does NOT claim to fix ghost factions, and deliberately does not
    -- guess a replacement faction name: WO-34 live-observed that the soul's
    -- own FactionNode wins regardless, and WO-68 shipped civic isolation
    -- through script contexts instead, which made faction membership
    -- unnecessary for the problem it was being used to solve. The 265-266
    -- "does not have a faction" errors in that session are a different entity
    -- entirely (see KCD2MP_SweepStrayGhosts). What a real faction attach would
    -- take is native and is scoped in docs/WO-84-findings.md.
    local okProp, propErr = pcall(function() entity.Properties.esFaction = "Civilians" end)
    local hasAi = nil
    pcall(function() hasAi = (entity.AI ~= nil) end)
    local aiFn = (AI ~= nil) and type(AI.ChangeParameter) or "no AI table"
    local okAi, aiErr = false, nil
    if AIPARAM_FACTION == nil then
        aiErr = "AIPARAM_FACTION is nil -- call skipped"
    elseif aiFn ~= "function" then
        aiErr = "AI.ChangeParameter is " .. tostring(aiFn)
    else
        okAi, aiErr = pcall(function()
            AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
        end)
    end
    System.LogAlways(string.format(
        "[KCD2-MP] faction attempt ghost '%s': Properties.esFaction ok=%s err=%s | entity.AI=%s"
        .. " | AIPARAM_FACTION=%s AI.ChangeParameter=%s ok=%s err=%s",
        tostring(id), tostring(okProp), tostring(propErr), tostring(hasAi),
        tostring(AIPARAM_FACTION), tostring(aiFn), tostring(okAi), tostring(aiErr)))

    System.LogAlways("[KCD2-MP] Spawned entityId=" .. tostring(entity.id))

    -- Apply white/red armor preset (ClothingPreset first, then WeaponPreset + visor).
    --
    -- WO-20: white_red's item list is entirely male mesh variants ("_m0X").
    -- Confirmed live: an NPC_Female entity fault-freely accepts the preset
    -- call (pcall ok=true, no error) but nothing renders and
    -- EquippedArmorsByClassId reads back EMPTY afterwards -- not just missing
    -- the preset items, but stripped of the soul's own authored default
    -- outfit too, leaving her in the bare base layer. A plain NPC_Female
    -- spawned with NO preset call keeps her own default outfit fine (also
    -- confirmed live). So the preset call is actively destructive on a
    -- female-classed ghost, not merely ineffective -- skip it for her and
    -- let the soul's own authored outfit stand. The male path is unchanged.
    if facePick.className ~= "NPC_Female" then
        local p = KCD2MP.armorPresets.white_red
        pcall(function() entity.actor:EquipClothingPreset(p.preset) end)
        pcall(function() entity.actor:EquipWeaponPreset(p.weapons) end)
    end
    local ghostName = name
    Script.SetTimer(800, function()
        pcall(function() System.ExecuteCommand("closeVisorOn " .. ghostName) end)
    end)

    -- WO-17: human:DrawWeapon() is a real, visually-confirmed native mutation
    -- (unlike EquipWeaponPreset, which is cosmetic-only, WO-9). WO-17's own
    -- claim that it never flips CombatSoul.HasMeleeWeapon was disproved by
    -- WO-21: on a male ghost with a real equipped weapon item, this call does
    -- flip HasMeleeWeapon=true, and WO-22/23 confirmed it holds true for
    -- soul-backed, brained ghosts. On a female ghost (no weapon item to draw)
    -- the flag correctly stays false -- that is the item being absent, not a
    -- broken call. Whether a ghost actually lands a blow is a separate,
    -- emergent AI-brain decision (morale, odds, context) that this call does
    -- not control either way (WO-22/23: every hostile ghost tested so far
    -- chose to flee rather than fight, being outnumbered).
    if KCD2MP.aggroEnabled then
        Script.SetTimer(1000, function()
            local g = KCD2MP.ghosts[id]
            if g and g.entity and g.entity.human then
                pcall(function() g.entity.human:DrawWeapon() end)
            end
        end)
    end

    local r = rotZ or 0

    -- Interpolation state: buffer with prev packet (A) and target packet (B)
    -- alpha: 0 = at A, 1 = at B, >1 = dead reckoning beyond B
    -- alphaStep: how much alpha advances per 50ms tick (= 50ms / packetInterval)
    --   default assumes 200ms server tick -> step = 0.25 (reaches B in 4 ticks)
    local istate = {
        -- Previous packet (lerp source)
        px = x, py = y, pz = z, pr = r,
        -- Target packet (lerp destination)
        tx = x, ty = y, tz = z, tr = r,
        -- Current rendered position
        cx = x, cy = y, cz = z, cr = r,
        -- Interpolation progress
        alpha = 1.0,
        alphaStep = 0.25,
        -- Dead reckoning velocity (units/sec), computed from last two packets
        vx = 0, vy = 0, vz = 0,
        -- Last ACTUAL packet position (separate from tx/ty which DR extends)
        lastPacketX = x, lastPacketY = y,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
        -- Animation state
        animTag = "idle",     -- "idle"/"walk"/"run" - current animation state
        smoothedSpeed = 0,
        prevCx = x, prevCy = y,
        speedDropTicks = 0,   -- consecutive ticks with low speed after high speed
        -- WO-40 Phase 0: crash guard -- ForceMount must never race a fresh
        -- spawn's soul/equip initialization (host crash #2 died exactly at
        -- spawn+400ms mount). Mount waits until the ghost is >=3 s old.
        spawnedAtClock = os.clock(),
    }

    KCD2MP.ghosts[id] = {
        entity = entity,
        entityId = entity.id,
        istate = istate,
        facePick = facePick,
        faceKey = faceKey,
        -- WO-27: nil until the Steam nick has arrived. Refreshed by
        -- KCD2MP_SetGhostName if the name turns up after the spawn, so a late
        -- name still arms the reconnect dedupe for the NEXT reconnect.
        identity = identity,
        spawnName = name,
    }

    -- WO-46: report the ghost's raw CryEngine entity id to the agent, which
    -- feeds it to the native swing path (the DLL addresses actors by this id,
    -- not by name or guid). entity.id is a userdata whose tostring prints the
    -- id as zero-padded hex -- the ONLY faithful numeric form this sandbox
    -- can produce, since its 32-bit-float numbers lose integer precision
    -- above 2^24 (WO-20/WO-40). Re-emitted naturally on every respawn because
    -- all spawns funnel through here, so the agent's cache self-heals after
    -- a save reload rebuilds the ghost bodies.
    local hexid = string.match(tostring(entity.id), "(%x+)%s*$")
    if hexid then
        KCD2MP_EmitEvent("ghostid", tostring(id) .. " " .. hexid)
    else
        mp_log("SpawnGhost: could not extract entity id hex from " .. tostring(entity.id)
               .. " -- native swings unavailable for ghost " .. tostring(id))
    end

    -- WO-38 Phase 7: if the stimulus-deafness A/B toggle is on, new spawns
    -- get it too, or a reconnect would silently undo the experiment mid-test.
    -- WO-59: the result is now logged instead of discarded. A silently
    -- failed SetIgnorant leaves the ghost's brain fully perceptive -- a real
    -- crime witness -- and no log line ever recorded whether the one
    -- spawn-time call actually ran (Thread C: the caught-stealing kill).
    if KCD2MP.ghostsIgnorant then
        local igOk, igErr = pcall(function() AI.SetIgnorant(entity.id, 1) end)
        System.LogAlways("[KCD2-MP] SetIgnorant at spawn for ghost " .. tostring(id)
            .. " ok=" .. tostring(igOk) .. (igOk and "" or (" err=" .. tostring(igErr))))
    end

    -- WO-65: civic isolation, applied in the spawn path itself (not a timer --
    -- menus suspend timers and reload kills them). If the soul is not ready
    -- yet this logs and the settle pass below retries.
    KCD2MP_ApplyGhostIsolation(id, "spawn")

    -- Schedule name apply after entity fully inits (soul may not be ready at spawn time).
    -- Uses Steam nick if already received via 0x03, else fallback "Player<id>".
    local captId = id
    Script.SetTimer(1500, function()
        local displayName = KCD2MP.ghostNames[captId] or ("Player" .. captId)
        KCD2MP_ApplyGhostName(captId, displayName)
        -- WO-65: opportunistic re-assert on the existing settle timer, for the
        -- case where the soul was not reachable at spawn+0. No-ops if the
        -- spawn pass landed (ghost.isolated) or the toggle is off.
        KCD2MP_ApplyGhostIsolation(captId, "settle")
    end)

    -- Auto-start interp loop as soon as we have a ghost to move
    KCD2MP_StartInterp()

    return entity
end

-- ===== Ghost Name (Steam nick above head) =====

-- Actually applies name to a ready entity. Logs before/after to diagnose soul.name write.
function KCD2MP_ApplyGhostName(id, name)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then
        mp_log("ApplyName id=" .. id .. " no entity")
        return
    end
    local e = ghost.entity

    -- Read current soul.name before assignment (to see what the default is)
    local before = nil
    pcall(function() before = e.soul and e.soul.name end)

    -- Attempt 1: soul.name = plain string (KCD2 shows this in NPC nameplates)
    local ok1 = pcall(function() e.soul.name = name end)
    -- Attempt 2: soul.sName (alternative field name seen in some CryEngine versions)
    local ok2 = pcall(function() e.soul.sName = name end)

    -- WO-27: `e:SetName(name)` USED to be attempt 3 here, and is deliberately
    -- gone. It renamed the entity away from "kcd2mp_<id>" -- the name it was
    -- spawned under and, critically, the key the RPG SoulList continues to
    -- file its soul under. Confirmed live in WO-26: after the rename,
    -- SoulsByName/Player91 404s while SoulsByName/kcd2mp_91 resolves. So the
    -- rename made every by-name lookup -- ours and the agent's -- miss the
    -- entity it was trying to find, including the ones that clean it up.
    --
    -- Nothing wanted it. The nameplate a player actually sees is drawn by this
    -- mod from KCD2MP.ghostNames (see KCD2MP_InterpTick's labelCache write),
    -- and the game's own NPC nameplate reads soul.name, which attempt 1 sets.

    -- Read back to verify assignment succeeded
    local after = nil
    pcall(function() after = e.soul and e.soul.name end)

    mp_log(string.format("ApplyName id=%s name=%s ok1=%s ok2=%s before=%s after=%s",
        id, name, tostring(ok1), tostring(ok2), tostring(before), tostring(after)))
end

-- Store name; if ghost already exists apply with short delay, else applied at spawn (1.5s).
function KCD2MP_SetGhostName(id, name)
    -- WO-58: the agent re-asserts names on a slow cadence (a mid-connection
    -- game restart wipes this Lua state while the agent's relay session
    -- lives on, and nothing else re-delivers the name). Make the repeat
    -- call free: same name, already backfilled, correctly-keyed face --
    -- nothing to do, no timer, no log line.
    local ghost = KCD2MP.ghosts[id]
    if KCD2MP.ghostNames[id] == name and ghost and ghost.identity == name then
        return
    end
    KCD2MP.ghostNames[id] = name
    -- WO-58: a ghost that spawned before its nick arrived was face-picked
    -- from the "Player<id>" fallback key -- wrong face, and (hash parity)
    -- a coin-flip on gender: hash("Player1") is even, so that ghost spawns
    -- as a woman regardless of who the player is. Live-hit twice in the
    -- 2026-08-25/26 session (both joiner-side kcd.logs carry the "no Steam
    -- nick yet" spawn). If the real name resolves to a different look,
    -- remove the mispicked body; the next position packet respawns it
    -- through the normal path, which now has the name.
    if ghost and ghost.entity and ghost.identity == nil then
        local rightPick = KCD2MP_PickFaceForPlayer(name)
        local current = ghost.facePick
        if not current or current.soulName ~= rightPick.soulName
           or current.className ~= rightPick.className then
            mp_log(string.format(
                "SetGhostName: ghost %s wears the '%s' fallback face (%s) but '%s' resolves to %s -- respawning with the right one",
                tostring(id), tostring(ghost.faceKey), tostring(current and current.soulName),
                tostring(name), tostring(rightPick.soulName)))
            KCD2MP_RemoveGhost(id)
            return
        end
    end
    -- WO-27: a ghost that spawned before its nick arrived has identity=nil and
    -- could not be deduped. Backfill it now, and sweep any older ghost that
    -- turns out to belong to this same player, so the leak is closed even in
    -- the race where the Position packet beat the Name packet.
    if ghost then
        ghost.identity = name
        KCD2MP_RemoveStaleGhostsForPlayer(name, id)
    end
    if ghost and ghost.entity then
        -- Ghost already alive when name packet arrives ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â apply after 300ms
        local captId = id
        local captName = name
        Script.SetTimer(300, function()
            KCD2MP_ApplyGhostName(captId, captName)
        end)
    end
    -- No ghost yet: name stored in ghostNames, applied at spawn (1.5s delay there)
end

-- ===== Horse Ghost Spawn / Remove =====

-- WO-38 Phase 5. Called by the agent from a HorseInfoDown (0x2B): the
-- authored name of the horse that player is riding, "" for dismounted or
-- unknown. Stored for the next mount; if that ghost is ALREADY riding a
-- spawned proxy and the named world horse exists here, the proxy is swapped
-- out for the real horse -- the identity packet and the riding flag race on
-- two different channels, so late arrival is the normal case, not an error.
function KCD2MP_SetGhostHorse(id, name)
    id = tostring(id)
    name = tostring(name or "")
    KCD2MP.ghostHorseName[id] = name
    mp_log("GHOST_HORSE id=" .. id .. " name='" .. name .. "'")

    local hd = KCD2MP.horseGhosts[id]
    local ghost = KCD2MP.ghosts[id]
    if name ~= "" and hd and not hd.isWorldHorse and ghost and ghost.istate
       and ghost.istate.isRiding then
        local world = nil
        pcall(function() world = System.GetEntityByName(name) end)
        if world and tostring(world.class or "") == "Horse" then
            mp_log("GHOST_HORSE swapping proxy for world horse '" .. name .. "' id=" .. id)
            if ghost.istate.nativeMounted then
                pcall(function() ghost.entity.human:ForceDismount() end)
                ghost.istate.nativeMounted = false
            end
            KCD2MP_RemoveHorse(id)
            local wp = nil
            pcall(function() wp = ghost.entity:GetWorldPos() end)
            KCD2MP_SpawnHorse(id, wp and wp.x or 0, wp and wp.y or 0, wp and wp.z or 0,
                ghost.istate.tr or 0)
        end
    end
end

function KCD2MP_SpawnHorse(id, x, y, z, rotZ)
    if KCD2MP.horseGhosts[id] then
        KCD2MP_RemoveHorse(id)
    end

    -- WO-38 Phase 5: if we know WHICH horse that player mounted and this
    -- world has the same-named entity, adopt it instead of spawning the
    -- generic proxy. Right look (Section D's grey-horse report was the
    -- proxy's default appearance), and a real horse the local player can
    -- still interact with. Position is driven exactly like a proxy while
    -- ridden; on dismount the entry is dropped and the engine takes the
    -- horse back (the WO-32 release principle -- verified on human NPCs,
    -- horse behaviour is live-gated).
    local wantName = KCD2MP.ghostHorseName[id]
    -- WO-40 Phase 0: both real host crashes (19:25:05 / 20:23:54 in the
    -- 2026-08-18 bundles) landed within ~1.5 s of an inbound ghost mount.
    -- Two guards, both cheap:
    --   1. never adopt the horse the LOCAL player is riding -- ForceMounting
    --      a second rider onto an occupied horse was never tested and is the
    --      strongest suspect for crash #1 (PA was galloping when PB's mount
    --      flip arrived);
    --   2. adoption can be turned off entirely (mp_horse_adopt off) so field
    --      testers can separate "adoption crashes" from everything else.
    if wantName and wantName ~= "" and KCD2MP.horseAdoptEnabled == false then
        mp_log("HorseAdopt: disabled (mp_horse_adopt off); proxy for id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" and KCD2MP._mountedHorseName == wantName then
        mp_log("HorseAdopt: '" .. wantName .. "' is the LOCAL player's own mount -- proxy instead (crash guard) id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" then
        local world = nil
        pcall(function() world = System.GetEntityByName(wantName) end)
        -- WO-58: distance guard. The 2026-08-25 host freeze (16:55) is pinned
        -- to this exact path: kcd.log's final line is MountNPCOnHorse for a
        -- freshly-adopted world horse, the native sampler's per-frame log
        -- stops on the same tick, and the game never ran another frame --
        -- ForceMount hung the main thread. The adopted horse only has to
        -- EXIST to pass GetEntityByName; in that session the same-named
        -- horse lived in a different part of the host's world entirely
        -- (the ghost spawned ~2 km from where the host was playing).
        -- ForceMounting an NPC onto a far-away, unstreamed, AI-owned horse
        -- was never live-tested before that moment and froze the engine on
        -- its first execution. Adopt only a horse that is actually standing
        -- near the ghost; anything else gets the proven proxy.
        if world and tostring(world.class or "") == "Horse" then
            local wpos = nil
            pcall(function() wpos = world:GetWorldPos() end)
            local dx = (wpos and wpos.x or 1e9) - x
            local dy = (wpos and wpos.y or 1e9) - y
            local distSq = dx * dx + dy * dy
            if not wpos or distSq > (60 * 60) then
                mp_log(string.format(
                    "HorseAdopt: '%s' exists but is %s m away from the ghost -- proxy instead (WO-58 freeze guard) id=%s",
                    wantName, wpos and string.format("%.0f", math.sqrt(distSq)) or "?", id))
                world = nil
            end
        end
        if world and tostring(world.class or "") == "Horse" then
            KCD2MP.horseGhosts[id] = {
                entity = world,
                entityId = world.id,
                isWorldHorse = true,
                worldName = wantName,
            }
            mp_log("HorseAdopt OK id=" .. id .. " world horse '" .. wantName .. "'")
            Script.SetTimer(400, function()
                KCD2MP_MountNPCOnHorse(id)
            end)
            return world
        end
        mp_log("HorseAdopt: '" .. tostring(wantName) .. "' not loaded here; falling back to proxy id=" .. id)
    end

    local pos = {x=x, y=y, z=z}
    local horseName = "kcd2mp_horse_" .. id

    -- Use System.SpawnEntity only (XGenAIModule is async ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ creates orphan second entity)
    local horse = nil
    local ok2, h2 = pcall(System.SpawnEntity, {
        class = "Horse", position = {x=x, y=y, z=z},
        name = horseName, properties = { esFaction = "Civilians" },
    })
    if ok2 and h2 then horse = h2 end

    if not horse then
        mp_log("HorseSpawn FAILED id=" .. id)
        return nil
    end
    mp_set_no_save(horse)   -- WO-106 Phase 5: a mod-spawned proxy horse, never save it

    pcall(function() horse:SetWorldAngles({x=0, y=0, z=rotZ or 0}) end)
    pcall(function() horse:SetMountableByPlayer(false) end)
    -- Set faction directly. Do NOT use CryAction.RegisterWithAI - that gives the horse an
    -- AI object which fights against our SetWorldPos calls every tick.
    pcall(function() AI.ChangeParameter(horse.id, AIPARAM_FACTION, "Civilians") end)

    KCD2MP.horseGhosts[id] = {
        entity = horse,
        entityId = horse.id,
    }

    mp_log("HorseSpawn OK id=" .. id .. " entityId=" .. tostring(horse.id))

    Script.SetTimer(400, function()
        KCD2MP_MountNPCOnHorse(id)
    end)

    return horse
end

function KCD2MP_MountNPCOnHorse(id)
    local ghost     = KCD2MP.ghosts[id]
    local horseData = KCD2MP.horseGhosts[id]
    if not ghost or not ghost.entity or not horseData or not horseData.entity then
        mp_log("MountNPCOnHorse: missing entity id=" .. id)
        return
    end

    local horse = horseData.entity
    local human = ghost.entity.human
    mp_log(string.format("MountNPCOnHorse id=%s hasHuman=%s", id, tostring(human ~= nil)))

    if not human then
        local captId = id
        Script.SetTimer(1000, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: a ghost younger than 3 s is still settling
    -- (soul attach, inbound appearance equips). Host crash #2 (2026-08-18
    -- 20:23:54) died exactly at fresh-spawn + 400 ms ForceMount. Defer.
    local age = os.clock() - (ghost.istate and ghost.istate.spawnedAtClock or 0)
    if ghost.istate and ghost.istate.spawnedAtClock and age < 3.0 then
        local captId = id
        mp_log(string.format("MountNPCOnHorse: ghost %s is %.1fs old -- deferring mount (crash guard)", id, age))
        Script.SetTimer(1500, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: re-check occupancy at mount time too -- the
    -- local player may have mounted this horse during the timer delay.
    if horseData.isWorldHorse and horseData.worldName
       and KCD2MP._mountedHorseName == horseData.worldName then
        mp_log("MountNPCOnHorse: '" .. horseData.worldName .. "' now occupied by the LOCAL player -- swapping to proxy id=" .. id)
        KCD2MP.horseGhosts[id] = nil
        local wp = ghost.istate
        KCD2MP_SpawnHorse(id, wp and wp.tx or 0, wp and wp.ty or 0, wp and wp.tz or 0, wp and wp.tr or 0)
        return
    end

    local ok1 = pcall(function() human:ForceMount(horse.id) end)
    mp_log("ForceMount ok=" .. tostring(ok1) .. " id=" .. id)
    if not ok1 then return end

    -- Verify mount after short delay; if confirmed, try to suppress scheduler errors
    local captId = id
    Script.SetTimer(300, function()
        local g2 = KCD2MP.ghosts[captId]
        if not g2 then return end
        local mounted = false
        pcall(function() mounted = g2.entity.human and g2.entity.human:IsMounted() end)
        mp_log("IsMounted=" .. tostring(mounted) .. " id=" .. captId)
        if not mounted then return end

        g2.istate.nativeMounted = true
        mp_log("NATIVE MOUNT SUCCESS id=" .. captId)

        -- === OPTION C: suppress "No valid scheduler behavior while occupying stance" ===
        -- Try 1: send OnHorseMounted signal so scheduler updates its state
        local s1 = pcall(function() AI.Signal(SIGNALFILTER_SENDER, 1, "OnHorseMounted", g2.entity.id) end)
        -- Try 2: disable AI entirely so scheduler stops fighting the mount
        local s2 = pcall(function() g2.entity:EnableAI(false) end)
        -- Try 3: AI.AutoDisable keeps AI alive but prevents auto-sleep cycles
        local s3 = pcall(function() AI.AutoDisable(g2.entity.id, 0) end)
        -- Try 4: generic OnMount signal
        local s4 = pcall(function() AI.Signal(0, 1, "OnMount", g2.entity.id) end)
        mp_log(string.format("OptionC signals id=%s s1=%s s2=%s s3=%s s4=%s",
            captId, tostring(s1), tostring(s2), tostring(s3), tostring(s4)))
    end)
end

function KCD2MP_RemoveHorse(id)
    local horseData = KCD2MP.horseGhosts[id]
    if not horseData then return end
    if horseData.isWorldHorse then
        -- WO-38 Phase 5: an adopted world horse is REAL local content --
        -- never removed, just released. The engine restores its own
        -- behaviour once position writes stop (WO-32's release principle).
        KCD2MP.horseGhosts[id] = nil
        mp_log("ReleaseWorldHorse id=" .. id .. " '" .. tostring(horseData.worldName) .. "'")
        return
    end
    if horseData.entityId then
        pcall(function() System.RemoveEntity(horseData.entityId) end)
    end
    KCD2MP.horseGhosts[id] = nil
    mp_log("RemoveHorse id=" .. id)
end

-- ===== Ghost Update (called by server each packet) =====

-- WO-100.5 Phase 2: pace/dir/stance/animSpeedCenti are APPENDED parameters.
-- An agent older than 0.23.1 calls this with six arguments and they arrive nil,
-- which is exactly "this peer sent no body state" -- the legacy inference then
-- runs for that sample. No version negotiation, no probe: absence is the
-- signal.
function KCD2MP_UpdateGhost(id, x, y, z, rotZ, isRiding, bPace, bDir, bStance, bSpeedCenti)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet, then fall through to process isRiding on same call.
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        ghost = KCD2MP.ghosts[id]
        if not ghost or not ghost.entity then return end  -- spawn failed
    end

    local istate = ghost.istate
    if not istate then return end

    local r = rotZ or istate.tr

    -- Velocity from actual packet positions (for dead reckoning).
    -- Use real elapsed time between packets instead of fixed SERVER_INTERVAL
    -- (echo mode sends every ~10ms, not 50ms, so fixed interval gave 5x underestimate).
    local ddx = x - (istate.lastPacketX or x)
    local ddy = y - (istate.lastPacketY or y)
    local ddz = z - (istate.lastPacketZ or z)
    local now = os.clock()
    local dt = now - (istate.lastPacketTime or now)
    istate.lastPacketTime = now
    istate.lastPacketDt = dt
    -- WO-38 Phase 3: packets arrive in BURSTS, not on a clean cadence -- the
    -- agent batches ExecuteString and flushes per tick (WO-30 measured that
    -- channel at 60-130 ms warm), so several UpdateGhost calls often land
    -- microseconds apart. The old code set raw velocity to 0 for every
    -- burst packet (dt < 5 ms), halving the smoothed velocity each time and
    -- making the dead-reckoning estimate oscillate between 0 and real --
    -- one direct cause of the reported rubber-banding. A burst packet now
    -- leaves the velocity estimate alone instead of dragging it to zero.
    if dt > 0.005 and dt < 1.0 then
        istate.vx = lerpVal(istate.vx or 0, ddx / dt, 0.5)
        istate.vy = lerpVal(istate.vy or 0, ddy / dt, 0.5)
        -- Vertical rate, for jump detection (WO-38 Section A: a jumping
        -- player read as a stationary vertical teleport because animation
        -- selection only ever saw horizontal speed).
        istate.vz = lerpVal(istate.vz or 0, ddz / dt, 0.5)
    elseif dt >= 1.0 then
        istate.vx, istate.vy, istate.vz = 0, 0, 0
    end
    istate.lastPacketX = x
    istate.lastPacketY = y
    istate.lastPacketZ = z

    -- Log large target jumps; reset velocity on teleport/fast-travel
    -- Jump detection: XY only ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â Z changes from terrain must NOT reset velocity
    local jumpDist = math.sqrt(ddx*ddx + ddy*ddy)
    if jumpDist > 5.0 then
        istate.vx = 0
        istate.vy = 0
        mp_log(string.format("JUMP id=%s xyDist=%.2f vx/vy reset", id, jumpDist))
    elseif jumpDist > 2.0 then
        mp_log(string.format("JUMP id=%s xyDist=%.2f", id, jumpDist))
    end

    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    -- WO-100.5 Phase 2: the peer's live Mannequin tags. Resolved to NAMES here
    -- -- ordinal -> our own name table -- so an ordinal this build does not
    -- know is a specific, counted rejection instead of a silently different
    -- tag. Stored raw on istate; the animation selection reads it.
    if bPace ~= nil then
        local pn = KCD2MP.bodyPaceName[bPace]
        local dn = KCD2MP.bodyDirName[bDir or 0]
        local sn = KCD2MP.bodyStanceName[bStance or 0]
        if pn == nil or dn == nil or sn == nil then
            KCD2MP._animStats.rejected = KCD2MP._animStats.rejected + 1
            local key = string.format("p=%s d=%s s=%s", tostring(bPace), tostring(bDir), tostring(bStance))
            if not KCD2MP._animUnknown[key] then
                KCD2MP._animUnknown[key] = true
                mp_log("MP-ANIM reject=unknown-ordinal " .. key
                    .. " -- this build has no name for it; falling back to the inferred animation."
                    .. " The peer is running a newer body-state vocabulary than this pak.")
            end
            istate.body = nil
        else
            istate.body = { pace = pn, dir = dn, stance = sn,
                            speed = (bSpeedCenti or 0) / 100.0 }
        end
    else
        istate.body = nil
    end

    -- Horse riding sync
    local riding = (isRiding == true)
    local wasRiding = (istate.isRiding == true)
    istate.isRiding = riding

    if riding and not wasRiding then
        -- Player just mounted a horse: spawn horse ghost
        mp_log("Riding START id=" .. id)
        KCD2MP_SpawnHorse(id, x, y, z, r)
    elseif not riding and wasRiding then
        -- Player dismounted: remove horse ghost, restore walk animation
        mp_log("Riding STOP id=" .. id)
        -- Dismount if natively mounted
        if istate.nativeMounted then
            pcall(function() ghost.entity.human:ForceDismount() end)
            istate.nativeMounted = false
        end
        KCD2MP_RemoveHorse(id)
        istate.animTag = "idle"  -- force animation reset
    end

    if istate.packetCount % 40 == 1 then
        -- WO-76: raw_vx/raw_vy were never defined -- this nil-arithmetic
        -- error was thrown, inside the per-statement pcall, on roughly every
        -- 40th ghost packet, which is why no pkt#N line has ever appeared in
        -- a field log. istate.vx/vy (lines 3536-3537) is the same lerped
        -- velocity estimate this function already computes and stores.
        local svx, svy = istate.vx or 0, istate.vy or 0
        local spd = math.sqrt(svx*svx + svy*svy)
        mp_log(string.format("pkt#%d id=%s pos=%.1f,%.1f,%.1f spd=%.1f riding=%s",
            istate.packetCount, id, x, y, z, spd, tostring(riding)))
    end
end

-- ===== Exchange: read local player state + apply ghost from other player =====
-- Returns CSV "x,y,z,rotZ,stance"  (stance: "s"=stand, "c"=crouch/sneak)
-- gstance: other player's stance to apply to ghost
function KCD2MP_Exchange(ghost_id, gx, gy, gz, gr, gstance)
    -- Apply incoming ghost state
    if ghost_id and gx then
        KCD2MP_UpdateGhost(ghost_id, gx, gy, gz, gr, gstance)
    end
    -- Read and return local player state
    if not player then return "" end
    local pos = player:GetWorldPos()
    if not pos then return "" end
    local rot = 0
    pcall(function()
        local ang = player:GetWorldAngles()
        if ang then rot = ang.z or 0 end
    end)
    -- Stance: use OnAction-tracked flag (most reliable in KCD2)
    -- Fallback to engine API in case action hook missed something
    local stance = "s"
    if KCD2MP.playerSneaking then
        stance = "c"
    else
        pcall(function()
            local s = player:GetStance()
            if s == 2 or s == 3 then stance = "c" end
        end)
        if stance == "s" then
            pcall(function()
                if player.actor and player.actor.bSneaking then stance = "c" end
            end)
        end
    end
    return string.format("%.3f,%.3f,%.3f,%.4f,%s", pos.x, pos.y, pos.z, rot, stance)
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    -- Liveness, not the flag -- see the comment on tickAlive. A save load
    -- leaves interpRunning true over a dead timer chain, and the old
    -- flag-only guard here made that permanent: every remote ghost frozen for
    -- the rest of the session with no way to recover short of restarting the
    -- game.
    --
    -- WO-78: the liveness check is now the probe-confirmed gate (chainMayStart)
    -- -- a stale stamp during a menu/dialog/cutscene suspension no longer
    -- starts a second chain -- and every start claims a generation, the
    -- puppet chain's WO-69 instrument mirrored, so a chain still running
    -- under an old generation can say so (KCD2MP_InterpTick).
    if chainMayStart("interp", "interpRunning", "_interpAliveAt", KCD2MP_StartInterp) then
        KCD2MP.interpRunning = true
        KCD2MP._interpAliveAt = os.clock()
        KCD2MP.interpGen = (KCD2MP.interpGen or 0) + 1
        local myGen = KCD2MP.interpGen
        System.LogAlways("[KCD2-MP] Interp tick started (20ms) gen=" .. tostring(myGen))
        Script.SetTimer(20, function() KCD2MP_InterpTick(nil, myGen) end)
    end
    -- Start label render loop if not already running (8ms < 16.7ms frame = no flicker)
    if chainMayStart("label", "labelRunning", "_labelAliveAt", KCD2MP_StartInterp) then
        KCD2MP.labelRunning = true
        KCD2MP._labelAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Label render loop started (8ms)")
        Script.SetTimer(8, KCD2MP_LabelTick)
    end
end

-- Update horse positions at 8ms to avoid 20ms stutter (physics fights SetWorldPos less).
--
-- Split out of KCD2MP_LabelTick for WO-13's external pump. InterpTick only
-- computes horseData.render*; this is what actually applies it, so a pump that
-- drove InterpTick alone would leave a mounted ghost's horse standing still
-- while the rider slid along on top of it.
function KCD2MP_ApplyHorseTransforms()
    for id, horseData in pairs(KCD2MP.horseGhosts) do
        if horseData.entity and horseData.renderX then
            pcall(function()
                horseData.entity:SetWorldPos({x=horseData.renderX, y=horseData.renderY, z=horseData.renderZ})
                horseData.entity:SetWorldAngles({x=0, y=0, z=horseData.renderR})
            end)
        end
    end
end

-- WO-13: driven by the agent over ExecuteString while a LOCAL menu has focus.
-- Script.SetTimer -- which schedules every tick in this file -- is frozen for
-- the whole duration of a local menu (WO-12 s0.3), so without this the other
-- players' ghosts stand still on your own screen while you are the one in the
-- inventory. ExecuteString-driven Lua keeps executing throughout (WO-12 s0.4),
-- which is the whole reason this works.
--
-- Deliberately does NOT pump KCD2MP_LabelTick's drawing half. DrawLabel and
-- DrawText are immediate-mode -- one frame per call -- so pumping them would
-- draw a nameplate on some frames and not others, i.e. strobe rather than
-- render. Measured pump rate live is 35-86 Hz against a 60 fps frame, which
-- is fast enough for motion to look continuous but is NOT frame-locked, so
-- the strobing is real. Labels therefore stay hidden for the duration of the
-- menu -- exactly what already happens today. This fix is about ghost bodies
-- moving, not about labels.
function KCD2MP_InterpPump()
    KCD2MP_InterpTick("ext")
    KCD2MP_ApplyHorseTransforms()
    -- WO-40 Phase 2: pump the NPC puppet tick too, at its own 50 ms cadence
    -- (the pump loop runs at 40-70 Hz; the puppet tick's lerp/speed math
    -- assumes 50 ms, and per-tick StartAnimation restarts get worse, not
    -- better, when run faster -- WO-39's stomping lesson).
    local nowP = os.clock()
    if KCD2MP.npcPuppetRunning and (nowP - (KCD2MP._npcPuppetPumpAt or 0)) >= 0.045 then
        KCD2MP._npcPuppetPumpAt = nowP
        KCD2MP_NpcPuppetTick("ext")
    end
end

-- WO-13 Phase 2. Called by the agent when a PauseDown (0x1D) says a peer
-- entered or left a menu. Ghost ids are strings on this side (they key
-- KCD2MP.ghosts), so the caller must pass the same form it uses everywhere
-- else; tostring here rather than trusting that.
function KCD2MP_SetGhostMenuState(id, inMenu)
    id = tostring(id)
    KCD2MP.ghostInMenu[id] = inMenu and true or nil
    mp_log("GHOST_MENU id=" .. id .. " inMenu=" .. tostring(inMenu and true or false))
end

-- ===== Shared player combat (WO-28) =====

-- Flow A receiver. Called by the agent from a PlayerStateDown (0x20): this is
-- the owner's own authoritative health, so it is stored and rendered, never
-- reconciled against whatever this world's local copy of that ghost thinks.
--
-- It deliberately does NOT write the ghost entity's own health. Lua health
-- writes are inert in this sandbox (docs/PROJECT-STATE.md s2), and the ghost's
-- local health is a separate, local fact -- worlds are not shared, and the
-- honest deliverable is that every peer can SEE the right number, not that two
-- simulations are made to agree. What players actually read is the nameplate,
-- which this drives.
--
-- It does, however, reset the Flow B sensor baseline and skip one sample. That
-- is guard 2 from the design doc: an externally-written health shows up as a
-- delta on the next sample and would otherwise be re-reported as a fresh hit,
-- echoing forever. Implemented here rather than at the write site so it holds
-- whether or not a health write ever lands.
function KCD2MP_SetGhostHealth(id, health, stamina, flags)
    id = tostring(id)
    KCD2MP.ghostHealth[id] = {
        h = tonumber(health) or -1,
        s = tonumber(stamina) or -1,
        flags = tonumber(flags) or 0,
        at = os.clock(),
    }
    KCD2MP.ghostHpSkip[id] = true
end

-- Flow C receiver. Called by the agent from a PlayerDeathDown (0x24).
-- Idempotent: a repeat for an already-dead player changes nothing, which is
-- the contract Protocol 0x24 states.
--
-- The ghost entity is deliberately left standing. That player is reloading
-- their own most recent save and will be back in the world within seconds to a
-- minute; removing and respawning the entity would cost a full spawn cycle
-- (and, before WO-27's dedupe fix, was exactly how duplicates appeared). The
-- nameplate says what happened instead, and the ordinary position stream moves
-- the ghost to wherever their save point put them once their game is back.
-- Death-pose candidates (WO-38 Phase 4). The WO-28 design leaves a dead
-- player's ghost standing (cheap recovery for a player back in seconds), and
-- the real two-player test read that as a bug: "his body stands there as if
-- alive... no animation of the body falling". The [dead - reloading] tag
-- rides the nameplate, which is distance-scaled -- a body-level cue is
-- needed too. Same probe-on-first-use pattern as the jump list: none of
-- these names is confirmed on this build; a wrong candidate can never play,
-- and none-found keeps today's standing body.
local DEATH_ANIMS = {
    "relaxed_death", "death", "3d_death", "dead_pose",
    "relaxed_lie_pose", "lie_pose", "lying_idle", "3d_lying_idle",
    "relaxed_knockdown", "knockdown", "ko_pose", "unconscious_pose",
}
KCD2MP._deathAnim = nil   -- nil=not probed, false=none found, string=found

function KCD2MP_SetGhostDead(id, dead)
    id = tostring(id)
    local was = KCD2MP.ghostDead[id] and true or false
    local now = dead and true or false
    KCD2MP.ghostDead[id] = now or nil
    if was ~= now then
        mp_log("GHOST_DEATH id=" .. id .. " dead=" .. tostring(now))
        -- WO-38 Phase 4: on the owner dying, put the standing body into a
        -- fall/lie pose once. mp_ghost_is_corpse freezes all locomotion
        -- driving while dead, so a one-shot here is not overwritten; on the
        -- owner coming back the ordinary animation path resumes by itself.
        if now then
            local ghost = KCD2MP.ghosts[id]
            if ghost and ghost.entity then
                if KCD2MP._deathAnim == nil then
                    local found = nil
                    for _, nm in ipairs(DEATH_ANIMS) do
                        local len = 0
                        pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
                        if len > 0 then found = nm; break end
                    end
                    KCD2MP._deathAnim = found or false
                    mp_log("DeathAnim: " .. tostring(KCD2MP._deathAnim))
                end
                if KCD2MP._deathAnim then
                    pcall(function() ghost.entity:StartAnimation(0, KCD2MP._deathAnim, 0, 0.2, 1.0, false) end)
                end
            end
        end
    end
end

-- Rule 2 gate, set by the agent from a CombatRole (0x25) packet. When off, the
-- per-ghost health sampling in KCD2MP_InterpTick does not run at all -- the
-- cost is skipped as well as the send, and a client that was never told it
-- holds authority cannot generate a hit by accident.
function KCD2MP_SetHitSensor(on)
    local now = on and true or false
    local was = KCD2MP.hitSensorOn
    if was ~= now then
        mp_log("HIT_SENSOR " .. (now and "on (this client holds NPC damage authority)" or "off"))
    end
    KCD2MP.hitSensorOn = now
    if not now then
        KCD2MP.ghostHpSeen = {}
        KCD2MP.ghostHpSkip = {}
    end
    -- WO-102.5 Phase 4: departure handoff. Becoming the NEW authority (Rule 2
    -- moved here, e.g. the previous authority disconnected) starts the
    -- co-location state fresh -- the old authority's together/apart history
    -- does not apply, and this machine's OWN anchor is scanned regardless
    -- (mp_npc_rescan), so it starts owning what is near itself immediately
    -- without any handoff-specific code. Nothing to release: a fresh
    -- authority has nothing tracked yet.
    if now and not was then
        KCD2MP.wo1025.together = false
        KCD2MP._togetherWantSince = nil
        KCD2MP._colocatePendingRelease = {}
    end
end

-- Reports everything this WO added, in one place, so a live check needs one
-- command rather than a hand-written Lua chunk. Logs rather than returns: the
-- console swallows return values.
function KCD2MP_ReportVitals()
    local h, s, d, u = KCD2MP_ReadSelfVitals()
    System.LogAlways(string.format(
        "[KCD2-MP] VITALS self health=%.1f stamina=%.1f dead=%s unconscious=%s emitter=%s hitSensor=%s",
        h, s, tostring(d), tostring(u), EMIT_VERSION, tostring(KCD2MP.hitSensorOn)))
    for id, ghost in pairs(KCD2MP.ghosts) do
        local hs = KCD2MP.ghostHealth[id]
        local localHp = "?"
        if ghost and ghost.entity and ghost.entity.actor then
            pcall(function() localHp = string.format("%.1f", ghost.entity.actor:GetHealth()) end)
        end
        System.LogAlways(string.format(
            "[KCD2-MP] VITALS ghost %s name=%s owner_health=%s owner_stamina=%s dead=%s local_health=%s seen=%s",
            tostring(id), tostring(KCD2MP.ghostNames[id] or "?"),
            hs and string.format("%.1f", hs.h) or "none",
            hs and string.format("%.1f", hs.s) or "none",
            tostring(KCD2MP.ghostDead[id] and true or false), localHp,
            KCD2MP.ghostHpSeen[id] and string.format("%.1f", KCD2MP.ghostHpSeen[id]) or "none"))
    end
end

-- WO-34 issue D. Is this ghost a body rather than a stand-in right now?
--
-- Two independent ways it happens, and the reported one is the second:
--
--   1. The OWNER died and their client sent 0x23, so every peer got 0x24 and
--      set KCD2MP.ghostDead. The entity here is untouched and still standing
--      (KCD2MP_SetGhostDead deliberately leaves it), but it no longer stands
--      for anybody who is playing.
--   2. An NPC killed the ghost in THIS world. No packet is involved at all --
--      worlds are not shared (docs/WO-26-shared-combat-design.md s2), so the
--      owner may be alive and well and completely unaware. Nothing in the mod
--      had ever looked at the ghost entity's own death state, which is why
--      this case went unnoticed through WO-28.
--
-- The IsDead() read is per-ghost per-20ms-tick, which is the same cadence and
-- the same object sampleGhostHealth already calls GetHealth() on, so it adds
-- one native call to a path that was already making one. pcall'd and treated
-- as "not dead" on failure: guessing a ghost is dead would freeze a live
-- player in place, which is far worse than a corpse that slides for one more
-- reconcile cycle.
function mp_ghost_is_corpse(id, ghost)
    if KCD2MP.ghostDead[id] then return true end
    -- WO-38 Phase 6: the owner reporting themselves unconscious (0x1F/0x20
    -- flags bit 0) is also a body -- they are lying in their own world, so a
    -- position stream that keeps arriving is stale-by-definition and driving
    -- walk animation onto their slumped stand-in is the same walking-corpse
    -- shape WO-34 fixed for death.
    local gh = KCD2MP.ghostHealth[id]
    if gh and gh.flags and (math.floor(gh.flags) % 2) == 1 then return true end
    if not (ghost and ghost.entity and ghost.entity.actor) then return false end
    local dead = false
    pcall(function() dead = ghost.entity.actor:IsDead() and true or false end)
    if dead then return true end
    -- WO-38 Phase 6: an NPC knocked this ghost out in THIS world. KCD2's
    -- unconsciousness is a real state distinct from death (the original A1
    -- lesson), and an unconscious body must freeze for exactly the same
    -- reason a dead one does. Same read WO-28's self-vitals already proved
    -- (actor:IsUnconscious), same pcall discipline: on failure assume
    -- conscious, because wrongly freezing a live player is the worse error.
    local ko = false
    pcall(function() ko = ghost.entity.actor:IsUnconscious() and true or false end)
    return ko
end

-- Smallest health drop worth reporting as a hit. Below this it is sampling
-- noise or regeneration rounding, not a blow.
local HIT_MIN_DELTA = 0.05

-- Flow B sensor, called once per ghost per interp tick.
--
-- Guards, in the order docs/WO-26-shared-combat-design.md s4 lists them by how
-- easily they are got wrong:
--   1. host-only -- KCD2MP.hitSensorOn, checked by the caller and again here.
--   2. a delta caused by an inbound authoritative write is not a hit --
--      KCD2MP_SetGhostHealth sets ghostHpSkip, consumed below.
--   3. only NEGATIVE deltas are hits. Regeneration is not a hit.
local function sampleGhostHealth(id, ghost)
    if not KCD2MP.hitSensorOn then return end
    if not (ghost and ghost.entity and ghost.entity.actor) then return end

    local hp = nil
    pcall(function() hp = ghost.entity.actor:GetHealth() end)
    if type(hp) ~= "number" then return end

    local prev = KCD2MP.ghostHpSeen[id]
    KCD2MP.ghostHpSeen[id] = hp

    -- Guard 2: one sample is swallowed after an external write, then the
    -- baseline is simply whatever we just read. Note this consumes the flag
    -- even on the first-ever sample, which is correct -- there is no prior
    -- value to have lost.
    if KCD2MP.ghostHpSkip[id] then
        KCD2MP.ghostHpSkip[id] = nil
        return
    end
    if prev == nil then return end   -- first sample only primes the baseline

    local delta = prev - hp          -- positive = lost health
    if delta < HIT_MIN_DELTA then return end   -- guard 3: covers 0 and negatives

    -- Reported as a loss amount, matching CombatSoul::TakeDamage's own argument
    -- semantics on the other end. Stamina is not sampled: there is no confirmed
    -- Lua stamina binding (see probeStaminaReader), and inventing one here would
    -- make a receiver drain a real player's stamina on a guess.
    KCD2MP_EmitEvent("ghost_hit", string.format("%s %.2f", tostring(id), delta))
end

function KCD2MP_LabelTick()
    if not KCD2MP.labelRunning then return end
    Script.SetTimer(8, KCD2MP_LabelTick)
    KCD2MP._labelAliveAt = os.clock()
    KCD2MP_ApplyHorseTransforms()
    for id, lbl in pairs(KCD2MP.labelCache) do
        if lbl.size > 0 then
            pcall(function()
                System.DrawLabel({x=lbl.x, y=lbl.y, z=lbl.z}, lbl.size, lbl.name, 1, 1, 0, 1)
            end)
        end
    end
    -- Draw ping in top-left corner using 2D screen-space DrawText(x, y, text, size).
    if KCD2MP.pingText then
        pcall(function()
            System.DrawText(10, 10, KCD2MP.pingText, 2)
        end)
    end

    -- Interaction prompt (WO-2) shares this loop rather than adding a timer.
    pcall(KCD2MP_DrawInteractionUI)

    -- NOTE: the dice board deliberately does NOT ride this loop. This loop only
    -- starts when the agent connects and calls KCD2MP_StartInterp, so hanging
    -- the board off it meant the board silently never rendered with no agent
    -- running -- verified: labelRunning=false while diceOpen=true. The board is
    -- pushed into the game's own UI on state change instead, so it needs no
    -- per-frame loop at all.
end

-- ===== Animation Update =====

-- Sneak animation candidates (probed on first use, result cached).
local SNEAK_WALK_ANIMS = {
    "3d_sneak_walk_turn_strafe",
    "3d_sneaking_walk_turn_strafe",
    "3d_stealth_walk_turn_strafe",
    "3d_crouch_walk_turn_strafe",
}
local SNEAK_IDLE_ANIMS = {
    "sneak_idle_both",
    "sneaking_idle_both",
    "stealth_idle_both",
    "crouch_idle_both",
}
KCD2MP._sneakWalkAnim = nil
KCD2MP._sneakIdleAnim = nil

-- Jump animation candidates (WO-38 Phase 3, Section A). Same probe-on-first-
-- use pattern as every other list here: findAnim keeps the first name the
-- entity actually has (GetAnimationLength > 0), so unverified candidates
-- cost one probe each, once, and a wrong guess can never play. If none probe
-- out, the ghost keeps its locomotion animation while airborne (legs keep
-- moving), which is still strictly better than the reported stiff teleport.
--
-- WO-40 Phase 8: the list is now led by REAL clip names read from
-- Animations.pak's male.animevents this session (plain one-shot .caf files,
-- the class that renders via StartAnimation -- not the 1d_jump_* blendspaces,
-- which never render). The old WO-38 guesses stay as a tail.
local JUMP_ANIMS = {
    "relaxed_jump_idle",                 -- full in-place jump (Animations.pak, WO-40)
    "relaxed_run_jump_rleg_start",       -- moving jump, start half
    "relaxed_jump_start",                -- start half (pairs with land)
    "relaxed_walk_jump_lleg_start",
    "3d_relaxed_jump", "3d_jump", "relaxed_jump", "jump",
    "3d_relaxed_jump_turn_strafe", "jump_both", "relaxed_jump_both",
    "3d_relaxed_run_jump", "run_jump", "walk_jump",
}
KCD2MP._jumpAnim = nil   -- nil=not probed yet, false=probed and none found, string=found

-- WO-40 Phase 8: fence-vault candidates -- the same real-clip sweep. The
-- game's own JumpOver Mannequin fragment plays exactly
-- relaxed_jump_over_obstacle_idle_high (read from kcd_male_database.adb).
-- Same probe pattern; used by the airborne branch when the arc looks like a
-- vault (low vertical speed but a z step up), live-tuning deferred -- for
-- now the list rides behind mp_combat_frag-style manual probing and the
-- jump branch's fallback ordering.
local VAULT_ANIMS = {
    "relaxed_jump_over_obstacle_idle_low",
    "relaxed_jump_over_obstacle_idle_high",
    "relaxed_jump_over_obstacle_lleg_walk_low",
    "relaxed_jump_over_obstacle_lleg_run_low",
}
KCD2MP._vaultAnim = nil

-- Riding animation candidates (probed on first use, result cached).
-- false = probed but none found (avoid re-probing every tick).
local RIDING_IDLE_ANIMS = {
    -- Confirmed working on KCD2 NPC class:
    "horse_idle",
    -- Simple names
    "riding_idle", "riding_idle_both", "horse_riding_idle",
    "mounted_idle", "horseback_idle", "cavalry_idle",
    -- 3d_ prefix (confirmed KCD2 convention)
    "3d_riding_idle", "3d_riding_idle_both",
    "3d_horse_idle", "3d_horse_idle_both",
    "3d_horseback_idle", "3d_mounted_idle",
    "3d_relaxed_horse_idle", "3d_relaxed_horse_idle_both",
    "3d_relaxed_riding_idle", "3d_relaxed_riding_idle_both",
    -- relaxed_ prefix (confirmed KCD2 convention)
    "relaxed_riding_idle", "relaxed_riding_idle_both",
    "relaxed_horse_idle", "relaxed_horse_idle_both",
    -- wagon / sit (seated pose that might work)
    "wagon_idle", "wagon_idle_both", "wagon_ride_idle",
    "sit_idle", "sit_idle_both", "3d_sit_idle",
    "seated_idle", "seated_idle_both",
    -- combat horse
    "combat_horse_idle", "combat_horse_idle_both",
    "3d_combat_horse_idle", "3d_combat_horse_idle_both",
    -- act / mm prefix
    "act_horse_idle", "mm_horse_idle",
    -- npc specific
    "npc_horse_idle", "npc_riding_idle",
}
local RIDING_GALLOP_ANIMS = {
    -- Based on confirmed idle pattern: 1d_idle_slope_relaxed_idle_rider_01
    "1d_gallop_slope_relaxed_gallop_rider_01",
    "1d_canter_slope_relaxed_canter_rider_01",
    "1d_trot_slope_relaxed_trot_rider_01",
    "1d_walk_slope_relaxed_walk_rider_01",
    -- Other candidates
    "horse_gallop", "horse_run", "horse_trot", "horse_canter",
    "riding_gallop", "riding_gallop_both",
    "3d_riding_gallop", "3d_horse_gallop",
    "relaxed_horse_run", "combat_horse_run", "mounted_gallop",
}
KCD2MP._ridingIdleAnim  = nil   -- nil=not probed yet, false=not found, string=found
KCD2MP._ridingGallopAnim = nil

-- Horse entity animation candidates (Horse class entity, not NPC riding).
local HORSE_ENTITY_IDLE_ANIMS = {
    -- Confirmed present on KCD2 horse entities (from mp_scan_horse on real game horse):
    "relaxed_idle",
    -- Other candidates:
    "idle", "stand", "horse_idle", "animal_idle",
    "idle_loop", "horse_idle_loop", "stand_loop",
    "loco_idle", "act_idle", "mm_idle",
    "walk_idle", "stand_idle",
    "horse_stand", "horse_stand_idle", "horse_rest",
}
-- Separate walk vs gallop so we don't accidentally use relaxed_walk for full gallop.
local HORSE_ENTITY_WALK_ANIMS = {
    "relaxed_walk", "relaxed_trot",
    "horse_walk", "horse_trot", "walk", "trot",
}
local HORSE_ENTITY_GALLOP_ANIMS = {
    -- Fastest gaits first ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â confirmed on KCD2 horse entities:
    "relaxed_gallop", "relaxed_canter", "relaxed_run",
    -- Other candidates:
    "gallop", "canter", "run",
    "horse_gallop", "horse_canter", "horse_run",
    "horse_loco_gallop", "horse_loco_run",
    "animal_gallop", "animal_run",
    "loco_gallop", "loco_run",
}
KCD2MP._horseEntityIdleAnim   = nil  -- nil=not probed, false=not found, string=found
KCD2MP._horseEntityWalkAnim   = nil
KCD2MP._horseEntityGallopAnim = nil

local function findAnim(entity, candidates)
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = entity:GetAnimationLength(0, name) or 0 end)
        if len > 0 then return name end
    end
    return nil
end

-- ===== Combat visibility, inbound half (WO-39 Phase 1) =====
--
-- Swing/block one-shot candidates, LIVE-TUNED 2026-08-18 against the real
-- Mannequin databases (kcd_male_combat_database.adb + _generated.adb,
-- extracted from Animations.pak) and eyeball-verified on a live ghost.
-- What that session established, so nobody re-walks it:
--   - REAL full swings are 1d- blendspaces (parametric by attack angle).
--     StartAnimation "starts" them (returns true) but they never render,
--     and the plain "natk_slash_*_upper" clips are upper-guard partials
--     that read as blocking. Swings are Mannequin-locked on this build.
--   - Human.PlayAnim(fragment, tags) executes fault-free and renders
--     NOTHING for FreeAttack/CombatAttack/CombatHit/FreeBlock on a ghost.
--   - What DOES render correctly via StartAnimation: guard idles, the
--     dz "blk" block reactions, hit "flinch" reactions, and guard
--     TRANSITIONS. Naming decode: lg/rg = left/right guard (rg raises the
--     sword arm and reads correctly; lg raises the EMPTY left arm and
--     reads like phantom-shield blocking), sz = distance zone, az/dz =
--     attack/defense zone.
-- The swing cue therefore is a fast right-to-left guard transition -- a
-- big lateral sword move, human-confirmed "usable" as an attack read at a
-- few metres -- played at SWING_ANIM_SPEED. Not a true swing; the honest
-- reachable ceiling this build gives us.
local COMBAT_SWING_ANIMS = {
    "combat_rg_sz1_idle_to_lg_sz0_idle_lngsw",   -- CONFIRMED live 2026-08-18
    "combat_rg_sz1_idle_to_rg_sz5_idle_lngsw",   -- confirmed exists; second choice
}
local SWING_ANIM_SPEED = 1.6   -- the transition reads as a strike at this rate
local COMBAT_BLOCK_ANIMS = {
    "combat_rg_sz1_dz0_blk_slash_lngsw",         -- CONFIRMED live 2026-08-18
    "combat_free_blk_lngsw_player_over",         -- exists; long hold, worse read
}
-- Weapon-ready idle for a ghost whose owner has their weapon drawn, so the
-- drawn state reads at a glance even between swings. Right guard: the
-- sword arm is the raised one.
local COMBAT_IDLE_ANIMS = {
    "combat_rg_sz1_idle_lngsw_player",           -- CONFIRMED live 2026-08-18
    "combat_lg_sz0_idle_lngsw_player",           -- exists; reads shield-y (left guard)
}
KCD2MP._swingAnim = nil        -- nil=not probed, false=none found, string=found
KCD2MP._blockAnim = nil
KCD2MP._combatIdleAnim = nil

-- Mannequin escape hatch: Human.PlayAnim(fragmentName, tags) is documented
-- and may reach the real combat fragments that raw StartAnimation cannot.
-- Fragment names cannot be probed by GetAnimationLength, so this route stays
-- OFF until a live session finds a working name and sets it here (or via
-- mp_combat_frag). When set, it is tried before the CAF one-shot.
KCD2MP.combatSwingFragment = nil   -- e.g. "MeleeAttack"
KCD2MP.combatSwingFragTags = ""

-- WO-43: every prior live attempt on this route (WO-39 empty tags, WO-40
-- generic tags like "lngsw") used GUESSED fragment/tag data, never a real
-- shipped Mannequin row. docs/WO-42-findings.md ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â§9.2 extracted real rows
-- straight from Tables.pak; this is one, verbatim, for a human/human sync
-- attack (not invented -- do not substitute a guessed tag string here):
--   mp_combat_frag CombatAttackSyncGen l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
-- Untried before WO-43. If this still renders nothing on a real ghost in a
-- real fight, that is evidence against "the tags were just wrong" and for
-- the guard/gate explanation combat_playanim.cpp's native probe checks.

-- WO-40 Phase 6: paired takedown cue on a puppet KO transition. Called from
-- KCD2MP_ApplyNpcState (defined earlier; Lua resolves this global at call
-- time, after the whole file has loaded). Clip names come from the
-- Animations.pak sweep (plain .caf clips, the class that renders via
-- StartAnimation) -- probed with findAnim, none-found degrades to the
-- existing KO freeze.
local TAKEDOWN_MASTER_ANIMS = {
    "stealth_kill_hand_stand_success_start_m",   -- choke-out, perpetrator half
    "combat_takedown_back_nw_nw_m",              -- unarmed takedown, perpetrator
}
local TAKEDOWN_VICTIM_ANIMS = {
    "stealth_kill_hand_stand_success_start_s",   -- choke-out, victim half
    "combat_takedown_back_nw_nw_s",              -- unarmed takedown, victim
}
KCD2MP._takedownMasterAnim = nil   -- nil=not probed, false=none, string=found
KCD2MP._takedownVictimAnim = nil

function KCD2MP_NpcTakedownCue(name, e, x, y, z)
    local p = KCD2MP.npcPuppets[name]
    -- Victim half on the NPC itself.
    if KCD2MP._takedownVictimAnim == nil then
        KCD2MP._takedownVictimAnim = findAnim(e, TAKEDOWN_VICTIM_ANIMS) or false
        mp_log("TakedownVictimAnim: " .. tostring(KCD2MP._takedownVictimAnim))
    end
    if KCD2MP._takedownVictimAnim then
        local len = 0
        pcall(function() len = e:GetAnimationLength(0, KCD2MP._takedownVictimAnim) or 0 end)
        pcall(function() e:StartAnimation(0, KCD2MP._takedownVictimAnim, 0, 0.1, 1.0, false) end)
        if p then p.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5) end
    end
    -- Master half on the nearest ghost within arm's reach.
    local best, bestD2 = nil, 6.25
    for _, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            local gp = nil
            pcall(function() gp = g.entity:GetWorldPos() end)
            if gp then
                local gdx, gdy = gp.x - x, gp.y - y
                local d2 = gdx * gdx + gdy * gdy
                if d2 < bestD2 then best, bestD2 = g, d2 end
            end
        end
    end
    if best then
        if KCD2MP._takedownMasterAnim == nil then
            KCD2MP._takedownMasterAnim = findAnim(best.entity, TAKEDOWN_MASTER_ANIMS) or false
            mp_log("TakedownMasterAnim: " .. tostring(KCD2MP._takedownMasterAnim))
        end
        if KCD2MP._takedownMasterAnim then
            local len = 0
            pcall(function() len = best.entity:GetAnimationLength(0, KCD2MP._takedownMasterAnim) or 0 end)
            pcall(function() best.entity:StartAnimation(0, KCD2MP._takedownMasterAnim, 0, 0.1, 1.0, false) end)
            if best.istate then
                best.istate.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5)
            end
        end
    end
    mp_log(string.format("NPC-SYNC takedown cue %s (victim=%s master=%s ghost=%s)",
        name, tostring(KCD2MP._takedownVictimAnim), tostring(KCD2MP._takedownMasterAnim),
        best and "yes" or "none-near"))
end

-- WO-40 Phase 6: the puppet-side swing cue -- same clip, speed and one-shot
-- window as the ghost swing cue, applied to an NPC puppet.
function KCD2MP_PuppetSwingCue(name, p, e)
    if KCD2MP._swingAnim == nil then
        KCD2MP._swingAnim = findAnim(e, COMBAT_SWING_ANIMS) or false
        mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
    end
    if not KCD2MP._swingAnim then return end
    local len = 0
    pcall(function() len = e:GetAnimationLength(0, KCD2MP._swingAnim) or 0 end)
    pcall(function() e:StartAnimation(0, KCD2MP._swingAnim, 0, 0.08, SWING_ANIM_SPEED, false) end)
    local dur = (len > 0 and len or 0.8) / SWING_ANIM_SPEED
    p.oneShotUntil = os.clock() + math.min(dur, 1.5)
    p.animTag = "swing"   -- locomotion re-asserts itself after the window
    mp_log("NPC-SYNC swing cue " .. name)
end

-- WO-49: the Lua half of a NATIVE puppet swing (KCD2MP_GhostNativeSwingHold's
-- twin for NPC puppets): the agent queues the real Mannequin combat action
-- through the DLL; this only pauses the puppet's per-tick writes so they do
-- not stomp the playing action (WO-39's one-shot lesson). No clip is started
-- here -- the native action owns the render. Clears any pending Lua cue so a
-- packet that raced both paths cannot double-render.
function KCD2MP_NpcNativeSwingHold(name)
    local p = KCD2MP.npcPuppets[name]
    if p then
        p.swingCuePending = nil
        p.oneShotUntil = os.clock() + 0.9
        p.animTag = "swing"   -- locomotion re-asserts itself after the window
    end
end

-- WO-49: agent-called fallback when the native swing did not apply (DLL
-- absent, stale entity id after a save reload) -- re-arms the WO-40 cue the
-- agent stripped from the flags byte, late but visible.
function KCD2MP_NpcSwingCueFallback(name)
    local p = KCD2MP.npcPuppets[name]
    if p and not p.dead and not p.ko then p.swingCuePending = true end
end

-- WO-49: agent-pushed note that this NPC's main-hand weapon lives in the
-- Oversized equip slot; the puppet tick's draw then goes through
-- DrawFromInventory instead of DrawWeapon (see the draw branch).
function KCD2MP_NpcSetOversized(name, classGuid)
    KCD2MP.npcOversized = KCD2MP.npcOversized or {}
    KCD2MP.npcOversized[name] = tostring(classGuid)
end

-- WO-40 Phase 6: probe-once accessor for the weapon-ready guard idle, shared
-- with the ghost path's cache.
function KCD2MP_CombatIdleFor(e)
    if KCD2MP._combatIdleAnim == nil then
        KCD2MP._combatIdleAnim = findAnim(e, COMBAT_IDLE_ANIMS) or false
        mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
    end
    return KCD2MP._combatIdleAnim or nil
end

-- Applies one peer combat event to that peer's ghost. evt matches Protocol's
-- combat event bytes: 0=drawn, 1=sheathed, 2=swing, 3=block. Unknown values
-- are ignored, so a newer peer can emit events this build has no name for.
-- Everything here is cosmetic; no health is touched on any path.
function KCD2MP_GhostCombat(id, evt)
    id = tostring(id)
    evt = tonumber(evt)
    if evt == nil then return end
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity) then return end

    if evt == 0 or evt == 1 then
        local wantDrawn = (evt == 0)
        local isDrawn = KCD2MP.ghostWeaponDrawn[id] and true or false
        if isDrawn == wantDrawn then return end   -- heartbeat re-emits land here
        KCD2MP.ghostWeaponDrawn[id] = wantDrawn or nil
        if ghost.entity.human then
            if wantDrawn then
                -- Confirmed live (WO-16/17): draws the ghost's real equipped
                -- weapon item, when the appearance layer has given it one.
                pcall(function() ghost.entity.human:DrawWeapon() end)
            else
                pcall(function() ghost.entity.human:HolsterWeapon() end)
            end
        end
        mp_log("CombatViz: ghost " .. id .. (wantDrawn and " drew weapon" or " sheathed weapon"))
        return
    end

    if evt == 2 or evt == 3 then
        -- Mannequin route first, when a live session has configured it.
        if evt == 2 and KCD2MP.combatSwingFragment and ghost.entity.human then
            local ok = pcall(function()
                ghost.entity.human:PlayAnim(KCD2MP.combatSwingFragment, KCD2MP.combatSwingFragTags or "")
            end)
            if ok then
                if ghost.istate then ghost.istate.oneShotUntil = os.clock() + 1.0 end
                return
            end
        end

        local anim
        if evt == 2 then
            if KCD2MP._swingAnim == nil then
                KCD2MP._swingAnim = findAnim(ghost.entity, COMBAT_SWING_ANIMS) or false
                mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
            end
            anim = KCD2MP._swingAnim
        else
            if KCD2MP._blockAnim == nil then
                KCD2MP._blockAnim = findAnim(ghost.entity, COMBAT_BLOCK_ANIMS) or false
                mp_log("BlockAnim: " .. tostring(KCD2MP._blockAnim))
            end
            anim = KCD2MP._blockAnim
        end
        if not anim then return end

        -- Swings play fast (the guard transition reads as a strike at 1.6x,
        -- confirmed live); blocks at natural speed. The one-shot window is
        -- the played duration, so the speed divides the length.
        local speed = (evt == 2) and SWING_ANIM_SPEED or 1.0
        local len = 0
        pcall(function() len = ghost.entity:GetAnimationLength(0, anim) or 0 end)
        pcall(function() ghost.entity:StartAnimation(0, anim, 0, 0.08, speed, false) end)
        -- Hold the one-shot: KCD2MP_UpdateAnimation restarts locomotion every
        -- tick and would stomp this on the very next one (confirmed live:
        -- one-shots were invisible until the loop was suppressed). Capped so
        -- a bad length can never freeze the ghost for long. istate always
        -- exists on a spawned ghost; a half-spawned one has no loop to fight.
        if ghost.istate then
            local dur = (len > 0 and len or 0.8) / speed
            ghost.istate.oneShotUntil = os.clock() + math.min(dur, 1.5)
        end
    end
end

-- Local eyeball test: play a combat event on every ghost in this world with
-- no wire involved (mp_ghost_combat <0|1|2|3>). The apply path is identical
-- to a real inbound packet.
-- WO-46: the Lua half of a NATIVE swing. The agent queues the real Mannequin
-- combat action through the DLL (a full swing, WO-45); this only holds the
-- one-shot window so KCD2MP_UpdateAnimation's per-tick locomotion restart
-- does not fight the playing action on a moving ghost. No clip is started
-- here -- the native action owns the render.
function KCD2MP_GhostNativeSwingHold(id)
    local ghost = KCD2MP.ghosts[tostring(id)]
    if ghost and ghost.istate then
        ghost.istate.oneShotUntil = os.clock() + 0.9
    end
end

-- WO-47: draw a SPECIFIC inventory item into the ghost's hands, for weapon
-- classes DrawWeapon() ignores (equip_slot="Oversized": halberds/polearms).
-- Live-verified this session: EquipItem reports a polearm equipped but never
-- attaches the model, DrawWeapon() draws the sidearm instead, and
-- human:DrawFromInventory(item, 0, true) is the one call that puts the
-- polearm in hand. ORDER MATTERS (live-observed): DrawFromInventory AFTER a
-- DrawWeapon()-style draw suppressed native swing rendering entirely;
-- called INSTEAD of it, swings render. The agent routes a draw event here
-- (rather than KCD2MP_GhostCombat) when its weapon catalog says the ghost's
-- synced main-hand weapon is Oversized.
function KCD2MP_GhostDrawItem(id, classGuid)
    id = tostring(id)
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity and ghost.entity.human and ghost.entity.inventory) then return end
    if KCD2MP.ghostWeaponDrawn[id] then return end   -- heartbeat re-emits land here
    local drew = false
    pcall(function()
        local it = ghost.entity.inventory:FindItem(tostring(classGuid))
        if it then
            ghost.entity.human:DrawFromInventory(it, 0, true)
            drew = true
        end
    end)
    if drew then
        KCD2MP.ghostWeaponDrawn[id] = true
        mp_log("CombatViz: ghost " .. id .. " drew oversized item from inventory")
    else
        -- Item not in the ghost's inventory (appearance apply still in
        -- flight): fall back to the plain draw so the state flag and any
        -- sidearm still behave as before.
        KCD2MP_GhostCombat(id, 0)
    end
end

function KCD2MP_GhostCombatAll(arg)
    local evt = tonumber(arg)
    if evt == nil then
        System.LogAlways("[KCD2-MP] usage: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
        return
    end
    local n = 0
    for id in pairs(KCD2MP.ghosts) do
        KCD2MP_GhostCombat(id, evt)
        n = n + 1
    end
    System.LogAlways("[KCD2-MP] GhostCombatAll evt=" .. evt .. " applied to " .. n .. " ghost(s)")
end

-- One-command probe for the live session: registration checks on the Human
-- binds this layer calls, plus every combat anim candidate that exists on a
-- ghost (all hits, not just the first -- the lists get tuned from this).
function KCD2MP_CombatProbe()
    System.LogAlways("[KCD2-MP] === COMBAT VIZ PROBE ===")
    if player and player.human then
        System.LogAlways("[KCD2-MP] player.human.IsWeaponDrawn=" .. tostring(type(player.human.IsWeaponDrawn)))
        System.LogAlways("[KCD2-MP] player.human.DrawWeapon="    .. tostring(type(player.human.DrawWeapon)))
        System.LogAlways("[KCD2-MP] player.human.HolsterWeapon=" .. tostring(type(player.human.HolsterWeapon)))
        System.LogAlways("[KCD2-MP] player.human.PlayAnim="      .. tostring(type(player.human.PlayAnim)))
        local d = "?"
        pcall(function() d = tostring(player.human:IsWeaponDrawn()) end)
        System.LogAlways("[KCD2-MP] IsWeaponDrawn() now=" .. d)
    else
        System.LogAlways("[KCD2-MP] player.human is nil")
    end
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do if g.entity then ghost = g; break end end
    if not ghost then
        System.LogAlways("[KCD2-MP] no ghost to probe anims on (spawn one first)")
        return
    end
    local lists = { SWING = COMBAT_SWING_ANIMS, BLOCK = COMBAT_BLOCK_ANIMS, CIDLE = COMBAT_IDLE_ANIMS,
                    JUMP = JUMP_ANIMS, VAULT = VAULT_ANIMS,
                    TDWN_M = TAKEDOWN_MASTER_ANIMS, TDWN_S = TAKEDOWN_VICTIM_ANIMS }
    for label, list in pairs(lists) do
        local hits = {}
        for _, nm in ipairs(list) do
            local len = 0
            pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
            if len > 0 then hits[#hits + 1] = string.format("%s=%.2f", nm, len) end
        end
        System.LogAlways("[KCD2-MP] " .. label .. ": " .. (#hits > 0 and table.concat(hits, ", ") or "none"))
    end
    System.LogAlways("[KCD2-MP] ghost.human=" .. tostring(ghost.entity.human ~= nil)
        .. " HolsterWeapon=" .. tostring(ghost.entity.human and type(ghost.entity.human.HolsterWeapon) or "n/a")
        .. " PlayAnim=" .. tostring(ghost.entity.human and type(ghost.entity.human.PlayAnim) or "n/a"))
    System.LogAlways("[KCD2-MP] === END ===")
end

-- mp_entity_id [name] (WO-43): print the raw CryEngine entity id for a named
-- entity, or every current ghost's id if no name is given. This is the value
-- kcdmp-playanim.txt's first line needs for the arbitrary-actor case of the
-- native PlayAnim diagnostic in combat_playanim.cpp -- that file cannot look
-- an entity up by name itself, only by this numeric id.
function KCD2MP_ReportEntityId(name)
    name = tostring(name or "")
    if name ~= "" then
        local e = System.GetEntityByName(name)
        System.LogAlways("[KCD2-MP] " .. name .. " id=" .. tostring(e and e.id or "not found"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            System.LogAlways("[KCD2-MP] ghost " .. tostring(id) .. " (" ..
                tostring(g.spawnName or ("kcd2mp_" .. tostring(id))) .. ") id=" .. tostring(g.entity.id))
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no spawned ghosts to report") end
end

-- Hysteresis thresholds (m/s).
-- Different enter/exit speeds prevent oscillation when speed hovers at a boundary.
-- Enter: must EXCEED this speed to switch INTO this state.
-- Exit:  must DROP BELOW this speed to switch OUT of this state (go lower).
local ANIM_UP   = { walk=1.0, run=2.5, sprint=4.0 }
local ANIM_DOWN = { walk=0.4, run=1.8, sprint=3.2 }

local function calcAnimTag(speed, cur, stance)
    if stance == "c" then
        return speed > 0.3 and "sneak_walk" or "sneak_idle"
    end
    -- Start from current tag and check if we cross hysteresis bands.
    local t = cur or "idle"
    if t == "sprint" then
        if speed < ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed <  ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed >= ANIM_UP.run     then return "run"
        elseif speed <  ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    -- idle / sneak states
    if     speed >= ANIM_UP.sprint then return "sprint"
    elseif speed >= ANIM_UP.run    then return "run"
    elseif speed >= ANIM_UP.walk   then return "walk"
    else                                 return "idle" end
end

-- WO-100.5 Phase 2: choose the locomotion tag from the peer's ACTUAL Mannequin
-- state rather than from the speed we inferred between two position packets.
--
-- Returns nil when it cannot answer, and every caller falls back to
-- calcAnimTag on nil -- so this is strictly additive: the worst case is the
-- behaviour that shipped before it.
--
-- What is NOT done here, stated rather than glossed:
--   * `dir` is carried, resolved and logged, but this build's ghost clip set
--     has no directional variants to select -- there is no backward-walk tag
--     to pick. It rides the wire because the field costs nothing and the
--     receiver half needs it the moment a directional clip exists.
--   * nothing writes a Mannequin tag onto the remote body directly. A tag
--     WRITER (AI.SetAnimationTag / Action.PersistantEntityTag) exists as a
--     method-name string in CryAISystem.dll / CryAction.dll, but being a
--     string is not being registered (WO-65: pairs() is blind to scriptbind
--     methods, type() must probe it live) and no live session was available
--     to probe it. Driving the existing clip selection from authoritative
--     tags is what is reachable today; probing the writer is a WO-101
--     candidate.
--   * stopLegLeft / stopLegRight are never sent, so nothing here can key on
--     them. They alternate at footfall rate (~370 ms at a jog) and the
--     receiver's own animation system generates its own footfalls.
local function bodyAnimTag(body)
    if not body then return nil end
    if body.stance == "stealth" then
        return (body.pace ~= "none") and "sneak_walk" or "sneak_idle"
    end
    -- Horse/sitting/lying/leaning are postures the ghost body reaches by other
    -- means (ForceMount, and the interp tick's own riding branch). Answering
    -- "idle" for them here would fight those, so decline and let the existing
    -- path run.
    if body.stance ~= "upright" and body.stance ~= "other" then return nil end
    local p = body.pace
    if p == "none"   then return "idle"   end
    if p == "walk"   then return "walk"   end
    if p == "steps"  then return "walk"   end   -- the small-adjustment pace
    if p == "run"    then return "run"    end
    if p == "sprint" then return "sprint" end
    if p == "dash"   then return "sprint" end   -- horse pace; the fastest we have on foot
    return nil
end

-- WO-84: restart a LOOPED clip on a change, plus a keep-alive refresh -- never
-- on every tick.
--
-- Both ghost animation call sites used to call StartAnimation unconditionally
-- on every interp tick, to override Mannequin's own idle. That is 50 calls per
-- second from the 20 ms chain -- and 62-86 per second from the agent's menu
-- pump, whose own log lines measured 5,395 pumped frames in 62.8 s at 86.0 Hz
-- in the 2026-09-11 field session. A pumped frame lands while the game, and
-- with it the animation system that drains the queue, is not advancing.
--
-- That session logged 9,037 `Animation-queue overflow. More then 16 entries`
-- errors against a single ghost's character instance, out of 9,192 in the
-- whole 150,458-line log -- every other entity in the world combined
-- accounted for 155. 6,148 of the joiner's 9,037 (68%) fell inside local-menu
-- windows covering 14,884 lines, 10% of the session; the host's ghost showed
-- the same shape on a different soul and a different clip, so this is neither
-- soul-specific nor faction-related.
--
-- This is the same defect the NPC puppet path carried until WO-40 Phase 5,
-- and the same fix -- with one addition that path does not need: the guard
-- compares the CLIP NAME as well as the tag, because tag "idle" maps to two
-- different clips (relaxed_idle_both, and the combat guard idle when the
-- owner's weapon is drawn) and a tag-only guard could never switch between
-- them.
--
-- A pumped call gets the change-driven restart but never the keep-alive
-- refresh: refreshing a loop into a frozen animation system is precisely the
-- queue filling described above, and the pump exists to keep ghost BODIES
-- moving through a menu (WO-13), not to re-blend their animations.
--
-- `st` is any per-entity state table (a ghost's istate, a horse's data row);
-- `key` namespaces the two bookkeeping fields so one table can drive more
-- than one character. Declared here, ABOVE both call sites, deliberately: a
-- file-local declared later would bind as a nil global inside them (the
-- getFloorZ trap this file already records).
local function mp_anim_loop(st, key, ent, animName, blend, speed, pumped)
    if not (st and ent and animName) then return false end
    local nameField, atField = key .. "Name", key .. "At"
    local refreshS = KCD2MP.ghostAnimRefreshS or 1.0
    local now = os.clock()
    local changed = st[nameField] ~= animName
    local stale
    if refreshS <= 0 then
        stale = true                      -- rollback: the pre-WO-84 per-tick restart
    else
        stale = (not pumped) and (now - (st[atField] or 0)) > refreshS
    end
    if not (changed or stale) then return false end
    st[nameField] = animName
    st[atField] = now
    pcall(function() ent:StartAnimation(0, animName, 0, blend or 0.15, speed or 1.0, true) end)
    return true
end

function KCD2MP_UpdateAnimation(id, ghost, pumped)
    local istate = ghost.istate

    -- WO-39: a one-shot combat animation (swing/block) is mid-play. This
    -- function restarts locomotion every tick, which would stomp it on the
    -- next tick -- so hold off until the one-shot's window expires. Checked
    -- before everything else, jump included: a swing beats an air-frame.
    if istate.oneShotUntil then
        if os.clock() < istate.oneShotUntil then return end
        istate.oneShotUntil = nil
        -- WO-84: the one-shot replaced the looped clip on layer 0, so the
        -- change-driven guard below must not still believe that loop is
        -- playing -- otherwise a ghost holds its swing pose until the next
        -- keep-alive. Under the old per-tick restart this could not happen.
        istate.animLoopName = nil
    end

    local speed = istate.smoothedSpeed or 0
    local stance = istate.stance or "s"

    -- Sanity: can't be sneaking at running speeds (auto-clears bad toggle state)
    if stance == "c" and speed > 4.0 then stance = "s" end

    -- WO-100.5 Phase 2: prefer the peer's real Mannequin tags over our
    -- inference. Fail-closed at every step -- legacy toggle on, no body state
    -- this sample, or a posture this chooser declines all land on calcAnimTag,
    -- which is exactly what shipped before.
    local wantTag = nil
    if not KCD2MP.animLegacy then
        wantTag = bodyAnimTag(istate.body)
        if wantTag then
            KCD2MP._animStats.applied = KCD2MP._animStats.applied + 1
        elseif istate.body then
            KCD2MP._animStats.noBody = KCD2MP._animStats.noBody + 1
        end
    end
    if not wantTag then
        KCD2MP._animStats.legacy = KCD2MP._animStats.legacy + 1
        wantTag = calcAnimTag(speed, istate.animTag, stance)
    end

    -- WO-38 Phase 3 (Section A): a jump used to render as a stationary
    -- vertical teleport, because this function only ever saw horizontal
    -- speed. While the interp tick reports the ghost airborne, play a jump
    -- animation if this build has one; if the probe finds none, fall through
    -- to the ordinary locomotion tag rather than freezing.
    if istate.isAirborne and stance ~= "c" then
        -- WO-40 live battery: the MotionJump Mannequin fragment RENDERS via
        -- Human.PlayAnim on a ghost (eyeball-confirmed 2026-08-20 -- the
        -- first fragment ever seen rendering; combat fragments stay locked).
        -- It is the game's own jump, with proc layers a raw clip lacks, so
        -- it goes first: once per airborne episode, not per tick.
        if not istate.jumpFragPlayed and ghost.entity.human then
            istate.jumpFragPlayed = true
            local okJ = pcall(function() ghost.entity.human:PlayAnim("MotionJump", "") end)
            if okJ then
                istate.oneShotUntil = os.clock() + 0.9
                if istate.animTag ~= "jump" then
                    mp_log(string.format("Anim: %s %s->jump (MotionJump fragment)", id, istate.animTag or "?"))
                    istate.animTag = "jump"
                end
                return
            end
        end
        if istate.animTag == "jump" then return end  -- fragment already playing
        if KCD2MP._jumpAnim == nil then
            KCD2MP._jumpAnim = findAnim(ghost.entity, JUMP_ANIMS) or false
            mp_log("JumpAnim: " .. tostring(KCD2MP._jumpAnim))
        end
        if KCD2MP._jumpAnim then
            pcall(function() ghost.entity:StartAnimation(0, KCD2MP._jumpAnim, 0, 0.1, 1.0, false) end)
            -- WO-84: unlike every other one-shot site in this file, this one
            -- sets no oneShotUntil, so the expiry path above never runs for it
            -- and cannot clear the loop guard. Clear it here instead: a ghost
            -- that was running before the jump and is running after would
            -- otherwise match on clip name, skip the restart, and hold the
            -- jump pose until the next keep-alive. Under the old per-tick
            -- restart this could not arise.
            istate.animLoopName = nil
            if istate.animTag ~= "jump" then
                mp_log(string.format("Anim: %s %s->jump vz-driven", id, istate.animTag or "?"))
                istate.animTag = "jump"
            end
            return
        end
    elseif istate.jumpFragPlayed then
        istate.jumpFragPlayed = nil   -- re-arm for the next airborne episode
    end

    local animName
    if wantTag == "sneak_walk" then
        if not KCD2MP._sneakWalkAnim then
            KCD2MP._sneakWalkAnim = findAnim(ghost.entity, SNEAK_WALK_ANIMS)
                                    or "3d_relaxed_walk_turn_strafe"
            mp_log("SneakWalkAnim: " .. KCD2MP._sneakWalkAnim)
        end
        animName = KCD2MP._sneakWalkAnim
    elseif wantTag == "sneak_idle" then
        if not KCD2MP._sneakIdleAnim then
            KCD2MP._sneakIdleAnim = findAnim(ghost.entity, SNEAK_IDLE_ANIMS)
                                    or "relaxed_idle_both"
            mp_log("SneakIdleAnim: " .. KCD2MP._sneakIdleAnim)
        end
        animName = KCD2MP._sneakIdleAnim
    else
        local anims = {
            sprint = "3d_relaxed_sprint_turn_strafe",
            run    = "3d_relaxed_run_turn_strafe",
            walk   = "3d_relaxed_walk_turn_strafe",
            idle   = "relaxed_idle_both",
        }
        animName = anims[wantTag]
        -- WO-39: a ghost whose owner has their weapon drawn idles in a
        -- weapon-ready stance when this build has one, so the drawn state
        -- reads at a glance between swings. Probe-on-first-use like every
        -- other list; none-found keeps the relaxed idle.
        if wantTag == "idle" and KCD2MP.ghostWeaponDrawn[id] then
            if KCD2MP._combatIdleAnim == nil then
                KCD2MP._combatIdleAnim = findAnim(ghost.entity, COMBAT_IDLE_ANIMS) or false
                mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
            end
            if KCD2MP._combatIdleAnim then animName = KCD2MP._combatIdleAnim end
        end
    end

    -- WO-84: restart on a change (tag OR clip), plus a keep-alive refresh --
    -- was an unconditional call on every tick. See mp_anim_loop above for the
    -- field numbers that forced this.
    -- blend=0.15s: short enough to react quickly, long enough to not look choppy.
    mp_anim_loop(istate, "animLoop", ghost.entity, animName, 0.15, 1.0, pumped)

    -- Log only when tag actually changes
    if istate.animTag ~= wantTag then
        mp_log(string.format("Anim: %s %s->%s spd=%.2f", id, istate.animTag or "?", wantTag, speed))
        istate.animTag = wantTag
    end
end

-- ===== Interpolation Tick (20ms) =====

-- Floor detection: physics raycast hits real geometry (roads, rocks, bridges).
-- Falls back to terrain elevation if raycast unavailable.
local function getFloorZ(x, y, curZ)
    local floorZ = nil
    local reliable = false

    -- Physics raycast: origin 2m above ghost, ray goes 12m DOWN.
    -- Direction vector magnitude = ray length in CryEngine: {z=-12} = 12m downward.
    -- This covers range [curZ+2 .. curZ-10] - hits bridges, stairs, terrain.
    -- Flags 15 = ent_terrain(1)|ent_static(2)|ent_rigid(4)|ent_sleeping_rigid(8)
    pcall(function()
        local hits = Physics.RayWorldIntersection(
            {x=x, y=y, z=curZ + 2.0},
            {x=0,  y=0, z=-12},
            15,
            1
        )
        if hits and hits[1] then
            local h = hits[1]

            -- Log raycast field layout once (helps identify correct field name)
            if not KCD2MP._rayFmtLogged then
                KCD2MP._rayFmtLogged = true
                local parts = {}
                for k, v in pairs(h) do
                    if type(v) == "number" then
                        parts[#parts+1] = k .. "=" .. string.format("%.2f", v)
                    elseif type(v) == "table" then
                        parts[#parts+1] = k .. "={z=" .. tostring(v.z) .. "}"
                    end
                end
                mp_log("RAY_FORMAT: " .. table.concat(parts, " "))
            end

            -- CryEngine may return hit point as h.pt, h.pos, or h.point
            local hz = nil
            if     h.pt    then hz = h.pt.z
            elseif h.pos   then hz = h.pos.z
            elseif h.point then hz = h.point.z
            end
            -- Accept hits within 10m below current position
            if hz and hz > curZ - 10.0 then
                floorZ   = hz
                reliable = true
            end
        end
    end)

    -- Fallback to terrain mesh (underestimates height on bridges/platforms)
    if not floorZ then
        pcall(function()
            local gz = Terrain.GetElevation(x, y)
            if gz then floorZ = gz end
        end)
    end

    return floorZ, reliable
end

-- `arg` is the timer id when this fires from Script.SetTimer, and the string
-- "ext" when the agent pumps it in through ExecuteString while a local menu
-- has focus (WO-13). Compared against the sentinel rather than tested for
-- truthiness, because a real timer id is truthy too.
--
-- A pumped call must NOT reschedule. Script.SetTimer is frozen for the whole
-- duration of a local menu (WO-12 s0.3), so every timer queued by a pumped
-- call would still be pending when the menu closes and fire as one burst.
-- WO-106 Phase 2: scratch tables for KCD2MP_InterpTick -- _playerPos is one
-- read per tick; wp is read per FROZEN ghost per tick (mp_ghost_is_corpse),
-- immediately destructured into x/y/sz locals and never stored past the
-- closure, so one reused table per call site is safe.
local INTERPTICK_PLAYERPOS_SCRATCH = {}
local INTERPTICK_WP_SCRATCH        = {}
function KCD2MP_InterpTick(arg, gen)
    -- WO-84: absorb the orphan of a generation KCD2MP_Stop retired. Same
    -- mechanism as the puppet chain's retirement (see KCD2MP_NpcPuppetTick);
    -- preventative here, never observed in the field.
    if gen ~= nil and KCD2MP._interpRetired[gen] then
        KCD2MP._interpRetired[gen] = nil
        KCD2MP._interpRetiredN = (KCD2MP._interpRetiredN or 0) + 1
        return
    end
    if not KCD2MP.interpRunning then return end
    -- WO-78: chain identity, mirroring the puppet tick's WO-69 instrument.
    -- `gen` is nil for the external menu pump (never reschedules, cannot leak)
    -- and for any legacy bare reschedule. The 2026-09-11 field session had no
    -- detector on this path and had to infer 5-21 concurrent chains from the
    -- TICK_ALIVE interval by hand; this line is the direct confirmation.
    if gen ~= nil and gen ~= KCD2MP.interpGen then
        KCD2MP._chainLeakN.interp = (KCD2MP._chainLeakN.interp or 0) + 1
        if not KCD2MP._chainLeakSeen.interp then
            KCD2MP._chainLeakSeen.interp = true
            mp_log(string.format(
                "GHOST CHAIN LEAK CONFIRMED: interp chain gen=%s is still running while gen=%s"
                .. " is current -- two chains were rendering the same ghosts%s",
                tostring(gen), tostring(KCD2MP.interpGen),
                KCD2MP.ghostChainFix and " (stale chain exiting now)"
                                      or " (observe-only; `mp_ghost_chainfix on` to stop it)"))
            pcall(function() KCD2MP_ShowNativeToast("KCD2-MP: ghost chain leak detected -- see kcd.log") end)
        end
        if KCD2MP.ghostChainFix then return end   -- the stale chain stops rescheduling and dies here
    end
    if arg ~= "ext" then
        Script.SetTimer(20, function() KCD2MP_InterpTick(nil, gen) end)  -- reschedule FIRST: crash-safe, tick never stops
        -- Only a scheduled fire counts as the chain being alive. A pumped call
        -- must not stamp this, or the pump would make a dead chain look
        -- healthy and stop KCD2MP_StartInterp from ever rebuilding it.
        KCD2MP._interpAliveAt = os.clock()
    end

    -- WO-84: is this a pumped frame? Read by the animation layer to skip the
    -- keep-alive refresh (see mp_anim_loop). Kept on KCD2MP rather than as a
    -- local because this function is already enormous and Lua 5.1 caps locals
    -- per function at 200; a table field costs no slot. Single-threaded and
    -- non-reentrant within a frame, so a plain field is safe.
    KCD2MP._tickPumped = (arg == "ext")

    -- Heartbeat: confirm tick is alive (every ~5s = 250 * 20ms)
    KCD2MP._tickN = (KCD2MP._tickN or 0) + 1
    if KCD2MP._tickN % 250 == 0 then
        local gc = 0; for _ in pairs(KCD2MP.ghosts) do gc = gc + 1 end
        mp_log("TICK_ALIVE #" .. KCD2MP._tickN .. " ghosts=" .. gc)
    end

    -- Fetch player position once per tick for label distance calculations.
    local _playerPos = nil
    if player then pcall(function() _playerPos = player:GetWorldPos(INTERPTICK_PLAYERPOS_SCRATCH) end) end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local _ok, _err = pcall(function()  -- catch any crash, keep tick alive
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1

            -- WO-78: TIME-BASED ADVANCE (WO-75 s2.5's prescription for this
            -- path, the puppet renderer's discipline copied -- not shared --
            -- per WO-70 constraint 1). Every per-tick factor below used to
            -- assume "one 20 ms tick has passed": the 0.5/0.15 lerp, the DR
            -- projection in ticks, rendSpeed / 0.020, the 0.4 speed smoother,
            -- the horse's Z/yaw smoothers. N concurrent chains therefore
            -- applied N ticks' worth per 20 ms: at the joiner's measured
            -- 14-21 chains the lerp became a snap onto the DR-projected point
            -- and every correction against travel rendered at full strength
            -- -- the reported "2 steps forward, jitter, 1 step back".
            -- Everything now derives from the real elapsed time since THIS
            -- ghost was last rendered. A second chain fire in the same frame
            -- sees ~0 elapsed and does nothing; a chain at any other cadence
            -- (the 80 Hz menu pump, a frame-quantised 20 ms timer) renders
            -- the same trajectory.
            local nowClock = os.clock()
            local dt = nowClock - (istate.renderAt or (nowClock - 0.020))
            if dt < 0.002 then return end          -- same-frame duplicate (os.clock is ~1 ms on Windows)
            if dt > 1.0 then dt = 1.0 end          -- a resumed chain catches up, it does not explode
            istate.renderAt = nowClock
            local steps = dt / 0.020               -- how many nominal ticks this fire is worth

            -- If ghost drifted very far from target (>5m), teleport directly.
            -- Prevents STEP_CAP from locking ghost hundreds of meters away.
            local distSq = (istate.tx-istate.cx)*(istate.tx-istate.cx)
                         + (istate.ty-istate.cy)*(istate.ty-istate.cy)
                         + (istate.tz-istate.cz)*(istate.tz-istate.cz)
            if distSq > 25.0 then
                -- WO-100.5 Phase 2 item 6: the SNAP COUNT, recorded where the
                -- snap actually happens. WO-100 S7 asked for this next to the
                -- correction magnitude below.
                istate.corrSnaps = (istate.corrSnaps or 0) + 1
                mp_log(string.format("TELEPORT id=%s dist=%.1f", id, math.sqrt(distSq)))
                if KCD2MP_QuestHazard then KCD2MP_QuestHazard("teleport-ghost", string.format("ghost %s snapped %.0fm", tostring(id), math.sqrt(distSq))) end
                istate.cx = istate.tx
                istate.cy = istate.ty
                istate.cz = istate.tz
                istate.cr = istate.tr
            end

            -- Non-destructive DR: project render target forward WITHOUT touching istate.tx/ty.
            -- istate.tx/ty stays = last received packet. When next packet arrives it's
            -- simply overwritten - no snap-back rubber-band.
            -- DR just makes the ghost look ahead of the last-known position while waiting
            -- for the next packet, keeping movement smooth at sprint speeds.
            --
            -- WO-38 Phase 3 (Section A, the "two steps forward, one step
            -- back"): the old projection reverted to the bare last-packet
            -- position the moment the gap exceeded DR_MAX ticks -- and gaps
            -- exceed it constantly, because delivery is bursty (the
            -- ExecuteString channel runs 60-130 ms warm, WO-30). Every such
            -- revert moved the render target BACKWARD by the projected
            -- amount, which the 0.5 lerp then faithfully rendered as a
            -- visible step back. The projection now HOLDS at the DR_MAX
            -- point instead of reverting; the next real packet simply
            -- overwrites it.
            local renderX = istate.tx or istate.cx
            local renderY = istate.ty or istate.cy
            -- WO-78: projection by real time since the last packet (was
            -- ticksSincePacket x 20 ms, which N chains advanced N times).
            local DR_MAX_S = 0.060  -- 60 ms lookahead (covers a 50 ms packet gap)
            local sincePkt = nowClock - (istate.lastPacketTime or nowClock)
            if sincePkt > 0 then
                local vx = istate.vx or 0
                local vy = istate.vy or 0
                if math.sqrt(vx*vx + vy*vy) > 0.5 then
                    local proj = math.min(sincePkt, DR_MAX_S)
                    renderX = renderX + vx * proj
                    renderY = renderY + vy * proj
                end
            end

            -- Smooth ghost toward render target (DR-extended, never snaps back).
            --
            -- WO-38 Phase 3: corrections AGAINST the direction of travel are
            -- damped harder than corrections along it. A backward correction
            -- is almost always a stale/regressed target (burst jitter, DR
            -- overshoot), not the player actually moonwalking -- rendering it
            -- at full strength is the visible rubber-band. Forward and
            -- sideways corrections keep the responsive factor.
            local factor = 0.5
            local dxT = renderX - istate.cx
            local dyT = renderY - istate.cy
            local vxS = istate.vx or 0
            local vyS = istate.vy or 0
            if (vxS*vxS + vyS*vyS) > 0.25 and (dxT*vxS + dyT*vyS) < 0 then
                factor = 0.15
            end
            -- WO-78: the per-tick factor scaled to the real elapsed time.
            -- steps == 1 gives exactly the old 0.5 / 0.15; two fires 10 ms
            -- apart compose to the same result as one 20 ms fire.
            factor = 1 - (1 - factor) ^ steps
            -- WO-100.5 Phase 2 item 6: CORRECTION MAGNITUDE -- how far the
            -- body was from where the stream says it should be, sampled
            -- before the lerp closes the gap. This is the number that tunes
            -- the smoothing that already exists (WO-100 S7: do not build a
            -- third one, measure the two we have).
            --
            -- DEVIATION, recorded: WO-100 asked for these two "in the existing
            -- GhostAgg aggregation", which lives in the AGENT. They are
            -- computed here instead, because the agent cannot see them: it
            -- knows the packet positions but not where the ghost body actually
            -- is, and the gap between those two IS the correction. Putting a
            -- number the agent cannot observe into an agent-side aggregate
            -- would have meant inventing it.
            local corr = math.sqrt(dxT*dxT + dyT*dyT)
            local cw = istate.corrWin
            if not cw then cw = { n = 0, sum = 0, max = 0, since = nowClock }; istate.corrWin = cw end
            cw.n = cw.n + 1
            cw.sum = cw.sum + corr
            if corr > cw.max then cw.max = corr end
            if (nowClock - cw.since) > 10.0 and cw.n > 0 then
                mp_log(string.format(
                    "MP-GHOSTCORR ghost=%s n=%d corr_mean_m=%.3f corr_max_m=%.3f snaps=%d",
                    tostring(id), cw.n, cw.sum / cw.n, cw.max, istate.corrSnaps or 0))
                istate.corrWin = { n = 0, sum = 0, max = 0, since = nowClock }
            end

            local prevCx = istate.cx
            local prevCy = istate.cy
            local nx = lerpVal(istate.cx, renderX, factor)
            local ny = lerpVal(istate.cy, renderY, factor)
            local nz = istate.tz or istate.cz   -- Z tracks packet directly, no lerp (avoids sinking into rocks)

            istate.cx = nx
            istate.cy = ny
            istate.cz = nz
            istate.cr = lerpAngle(istate.cr, istate.tr, factor)

            local x = istate.cx
            local y = istate.cy
            local z = istate.cz
            local r = istate.cr

            -- WO-38 Phase 3 (Section A jump): airborne detection from the
            -- packet stream's vertical rate. While airborne, the snap-DOWN
            -- below must not fire -- a jump arc peaks well under its 2 m
            -- window, so the snap was flattening the whole arc back onto the
            -- floor. Held briefly past the last upward motion so the falling
            -- half of the arc isn't snapped either.
            if (istate.vz or 0) > 1.2 and not istate.isRiding then
                istate.airborneUntil = nowClock + 0.6
            end
            local airborne = (istate.airborneUntil or 0) > nowClock

            -- Floor snap: correct ghost Z against raycast floor.
            -- Snap-UP: underground up to 10m (handles slopes, slight embedding).
            -- Snap-DOWN: hovering up to 2m (hover fix; >2m cap prevents snapping off bridges).
            -- Skip floor snap when riding: horse engine handles terrain, NPC follows horse.
            local sz = z
            if not istate.isRiding then
                local floorZ, reliable = getFloorZ(x, y, z)
                if floorZ then
                    local diff = sz - floorZ
                    if diff < -0.05 and diff > -10.0 then
                        -- Underground up to 10m: snap up to floor
                        sz = floorZ
                        istate.cz = floorZ
                    elseif diff > 0.05 and diff < 2.0 and not airborne then
                        -- Hovering up to 2m above floor: snap down
                        sz = floorZ
                    end
                end
            end
            istate.isAirborne = airborne

            -- When nativeMounted, the engine links NPC to horse - skip manual NPC SetWorldPos.
            -- We only update horse position; rider follows automatically.
            --
            -- WO-34 issue D: a corpse must not be dragged. Position sync is an
            -- always-on channel, entirely separate from the 0x23/0x24 death
            -- notification, so until now a ghost that had died -- either
            -- because its owner died, or because an NPC killed it in THIS
            -- world -- kept having SetWorldPos written onto it every 20 ms and
            -- slid around the map tracking a live player. Reported from a real
            -- two-player session: "once the NPC killed his stand in the dead
            -- body moved around where he did."
            --
            -- Frozen means: stop writing position and stop driving animation,
            -- but keep the nameplate -- moved onto the body's ACTUAL world
            -- position, not the incoming stream's, or the label would fly off
            -- and leave a nameless corpse behind (the WO-28 Q3 failure shape).
            -- istate keeps integrating normally underneath, so when the ghost
            -- is recycled it starts from the current stream position.
            local ok = true
            local frozen = mp_ghost_is_corpse(id, ghost)
            -- WO-39: a one-shot combat animation (swing/block) pins the ghost
            -- for its duration (<= 1.5 s). Confirmed live: the per-tick
            -- SetWorldPos writes interrupt a one-shot before a single frame
            -- of it renders -- swings played to a stationary unstreamed ghost
            -- and never to a streamed one -- and the z floor-snap fighting
            -- the clip's root motion was the reported up/down phasing during
            -- blocks. istate keeps integrating underneath, exactly like the
            -- frozen case, so the ghost catches up the moment the window ends.
            local oneShot = istate.oneShotUntil and os.clock() < istate.oneShotUntil
            if frozen then
                local wp = nil
                pcall(function() wp = ghost.entity:GetWorldPos(INTERPTICK_WP_SCRATCH) end)
                if wp then x, y, sz = wp.x, wp.y, wp.z end
            elseif oneShot then
                -- no position/angle writes; the one-shot owns the body
            elseif not istate.nativeMounted then
                local _, err = pcall(function()
                    ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                    ghost.entity:SetWorldAngles({x=0, y=0, z=r})
                end)
                if err then
                    System.LogAlways("[KCD2-MP] InterpTick err '" .. id .. "': " .. tostring(err))
                    ghost.entity = nil
                    ok = false
                end
            end
            if ok then
                -- Speed from rendered XY movement this tick
                local movedDx = nx - prevCx
                local movedDy = ny - prevCy
                -- WO-78: over the real elapsed time, not a nominal tick.
                local rendSpeed = math.sqrt(movedDx*movedDx + movedDy*movedDy) / dt
                istate.smoothedSpeed = lerpVal(istate.smoothedSpeed or 0, rendSpeed, 1 - 0.6 ^ steps)

                if frozen then
                    -- WO-34 issue D: no animation on a corpse. Driving walk/run
                    -- onto a dead actor is what made the reported body look
                    -- like it was walking around rather than lying where it
                    -- fell. The horse half is skipped for the same reason.
                elseif istate.isRiding then
                    -- One-time riding diagnostic when interp tick first sees this ghost riding.
                    -- (% 50 == 1 never fires: interp=20ms, packets=10ms ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ only even counts seen)
                    if not istate._rideFirstTick then
                        istate._rideFirstTick = true
                        local hd = KCD2MP.horseGhosts[id]
                        local hasAI = false
                        pcall(function() hasAI = hd and hd.entity and hd.entity.AI ~= nil end)
                        mp_log(string.format("RIDE_FIRST id=%s hasHorse=%s hasAI=%s",
                            id, tostring(hd ~= nil), tostring(hasAI)))
                    end
                    -- Probe valid riding animations once (on first ghost that is riding).
                    if KCD2MP._ridingIdleAnim == nil then
                        KCD2MP._ridingIdleAnim = findAnim(ghost.entity, RIDING_IDLE_ANIMS) or false
                        mp_log("RideIdleAnim: " .. tostring(KCD2MP._ridingIdleAnim))
                    end
                    if KCD2MP._ridingGallopAnim == nil then
                        KCD2MP._ridingGallopAnim = findAnim(ghost.entity, RIDING_GALLOP_ANIMS) or false
                        mp_log("RideGallopAnim: " .. tostring(KCD2MP._ridingGallopAnim))
                    end

                    -- Engine sync auto-assigns idle rider anim at ForceMount time.
                    -- For gallop we must set it explicitly ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â engine does NOT auto-update.
                    -- ridingFallback: engine failed to mount, set all anims manually.
                    local isGallop = rendSpeed > 3.0
                    -- WO-84: this ghost is in the saddle, so whatever locomotion
                    -- clip KCD2MP_UpdateAnimation last pushed is gone. Forget it,
                    -- or a dismount would wait a keep-alive period before the
                    -- ghost stopped riding an imaginary horse.
                    istate.animLoopName = nil
                    if istate.nativeMounted then
                        -- Only override for gallop; leave idle to engine sync system.
                        if isGallop and KCD2MP._ridingGallopAnim then
                            mp_anim_loop(istate, "rideLoop", ghost.entity,
                                         KCD2MP._ridingGallopAnim, 0.3, 1.0, KCD2MP._tickPumped)
                        else
                            -- The engine owns the pose again -- forget which clip
                            -- we last pushed, or the next gallop would be
                            -- suppressed as "already playing".
                            istate.rideLoopName = nil
                        end
                    else
                        local rideAnim = (isGallop and KCD2MP._ridingGallopAnim)
                                      or KCD2MP._ridingIdleAnim
                        mp_anim_loop(istate, "rideLoop", ghost.entity, rideAnim, 0.3, 1.0, KCD2MP._tickPumped)
                    end

                    -- Horse entity origin = ground level (~1.5m below rider/saddle).
                    -- getFloorZ from sz can hit the horse's own physics body (rigid) and return
                    -- a Z close to sz, putting the horse on top of the NPC ghost.
                    -- Fix: use sz-1.5 as default; only accept raycast if it finds ground
                    -- at least 0.5m below saddle (rules out horse/player body hits).
                    local horseGroundZ = sz - 1.5
                    local hFloorZ, _ = getFloorZ(x, y, sz)
                    if hFloorZ and (sz - hFloorZ) >= 0.5 then
                        horseGroundZ = hFloorZ
                    end
                    local horseData = KCD2MP.horseGhosts[id]
                    if horseData and horseData.entity then
                        -- WO-78: `dt` is the ghost's real elapsed render time (above), not 0.020.
                        local vx = (x - (horseData.lastX or x)) / dt
                        local vy = (y - (horseData.lastY or y)) / dt
                        local spd = math.sqrt(vx*vx + vy*vy)
                        horseData.lastX = x
                        horseData.lastY = y

                        -- Smooth horse Z and rotation to remove raycast noise / snap artifacts
                        if not horseData.smoothZ then horseData.smoothZ = horseGroundZ end
                        horseData.smoothZ = lerpVal(horseData.smoothZ, horseGroundZ, 1 - 0.75 ^ steps)   -- WO-78: was 0.25/tick
                        if not horseData.smoothR then horseData.smoothR = r end
                        horseData.smoothR = lerpAngle(horseData.smoothR, r, 1 - 0.65 ^ steps)            -- WO-78: was 0.35/tick
                        local hz = horseData.smoothZ
                        local hr = horseData.smoothR

                        -- Probe horse entity animations once.
                        if KCD2MP._horseEntityIdleAnim == nil then
                            KCD2MP._horseEntityIdleAnim = findAnim(horseData.entity, HORSE_ENTITY_IDLE_ANIMS) or false
                            mp_log("HorseEntityIdleAnim: " .. tostring(KCD2MP._horseEntityIdleAnim))
                        end
                        if KCD2MP._horseEntityWalkAnim == nil then
                            KCD2MP._horseEntityWalkAnim = findAnim(horseData.entity, HORSE_ENTITY_WALK_ANIMS) or false
                            mp_log("HorseEntityWalkAnim: " .. tostring(KCD2MP._horseEntityWalkAnim))
                        end
                        if KCD2MP._horseEntityGallopAnim == nil then
                            KCD2MP._horseEntityGallopAnim = findAnim(horseData.entity, HORSE_ENTITY_GALLOP_ANIMS) or false
                            mp_log("HorseEntityGallopAnim: " .. tostring(KCD2MP._horseEntityGallopAnim))
                        end

                        -- Store render target for 8ms render loop (avoids 20ms stutter).
                        horseData.renderX = x
                        horseData.renderY = y
                        horseData.renderZ = hz
                        horseData.renderR = hr

                        -- Play horse entity animation based on speed.
                        -- relaxed_idle ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ engine sync assigns matching rider idle.
                        -- relaxed_gallop ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ we explicitly set rider gallop above.
                        local horseAnim
                        if spd > 3.0 then
                            horseAnim = KCD2MP._horseEntityGallopAnim or KCD2MP._horseEntityWalkAnim
                        elseif spd > 0.5 then
                            horseAnim = KCD2MP._horseEntityWalkAnim or KCD2MP._horseEntityGallopAnim
                        else
                            horseAnim = KCD2MP._horseEntityIdleAnim
                        end
                        -- WO-84: same change-plus-keep-alive rule as the rider.
                        mp_anim_loop(horseData, "gaitLoop", horseData.entity,
                                     horseAnim, 0.2, 1.0, KCD2MP._tickPumped)
                    end
                    -- NPC ghost Z = sz = packet player Z = saddle height (correct).
                    -- Already set above in the nativeMounted block. No extra offset needed.
                else
                    -- WO-84: tell the animation layer whether this is a pumped
                    -- frame. `arg` is KCD2MP_InterpTick's own parameter, an
                    -- upvalue here; "ext" means the agent's menu pump drove
                    -- this call, so the keep-alive refresh must be skipped.
                    istate.rideLoopName = nil
                    KCD2MP_UpdateAnimation(id, ghost, KCD2MP._tickPumped)
                end

                -- Update label cache for the render loop (runs at 8ms to avoid flicker).
                -- When riding: sz = saddle height, head ~1.3m above saddle.
                -- When on foot: sz = feet, head ~1.8m above feet.
                local displayName = KCD2MP.ghostNames[id] or ("Player" .. tostring(id))
                -- WO-13 Phase 2: a player in a menu is standing perfectly still
                -- and not responding, which reads as broken. Say so instead.
                -- No pose work needed -- KCD2MP_UpdateAnimation already settles
                -- a stationary ghost into its idle animation on its own.
                if KCD2MP.ghostInMenu[id] then
                    displayName = displayName .. " [in menu]"
                end
                -- WO-28 Flow C, before health: a dead player's remaining
                -- number is stale by definition, so saying "dead" and a health
                -- figure at once would be two answers to one question.
                if KCD2MP.ghostDead[id] then
                    displayName = displayName .. " [dead - reloading]"
                else
                    -- WO-28 Flow A. This is the owner's own authoritative
                    -- health, not this world's local copy of the ghost --
                    -- see KCD2MP_SetGhostHealth.
                    local hs = KCD2MP.ghostHealth[id]
                    if hs and hs.h and hs.h >= 0 then
                        displayName = string.format("%s  %d HP", displayName, math.floor(hs.h + 0.5))
                        if hs.s and hs.s >= 0 then
                            displayName = string.format("%s / %d ST", displayName, math.floor(hs.s + 0.5))
                        end
                    end
                end
                -- WO-28 Flow B: sample this ghost's LOCAL health for
                -- NPC-inflicted damage. No-op unless this client holds
                -- NPCÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢player damage authority.
                sampleGhostHealth(id, ghost)
                local labelZ = sz + (istate.isRiding and 1.1 or 1.8)
                local labelSize = 0  -- 0 = hidden (too far)
                if _playerPos then
                    local dx = x - _playerPos.x
                    local dy = y - _playerPos.y
                    local dz = labelZ - _playerPos.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist <= 60.0 then
                        labelSize = math.max(0.3, math.min(2.0, 10.0 / math.max(dist, 1.0)))
                    end
                end
                KCD2MP.labelCache[id] = {x=x, y=y, z=labelZ, size=labelSize, name=displayName}
            end
        end
        end)  -- end pcall for ghost update
        if not _ok then
            mp_log("InterpTick ERR id=" .. tostring(id) .. ": " .. tostring(_err))
        end
    end

    -- Update local player riding state every 5 ticks (~100ms)
    if KCD2MP._ridingCheckTick == nil then KCD2MP._ridingCheckTick = 0 end
    KCD2MP._ridingCheckTick = KCD2MP._ridingCheckTick + 1
    if KCD2MP._ridingCheckTick >= 5 then
        KCD2MP._ridingCheckTick = 0
        if player then
            local riding = false
            local mountName = nil
            -- Method 0: Find "Horse" class entity within 2.5m of player.
            -- When riding, horse origin is ~1.5m below saddle (player pos).
            -- Exclude our own ghost horses (kcd2mp_horse_*) to avoid false positives.
            pcall(function()
                local pos = player:GetWorldPos()
                if pos then
                    local ents = System.GetEntitiesInSphere(pos, 2.5)
                    if ents then
                        for _, e in ipairs(ents) do
                            local ec = "?"
                            local en = ""
                            pcall(function() ec = tostring(e.class or "?") end)
                            pcall(function() en = tostring(e:GetName() or "") end)
                            if ec == "Horse" and not en:find("kcd2mp_horse_") then
                                -- Require player to be >1.0m ABOVE horse pivot.
                                -- Horse entity pivot is at ground level; when mounted,
                                -- player Z = saddle height (~1.5m above ground).
                                -- Filters false positives when merely standing next to horse.
                                local horsePos = nil
                                pcall(function() horsePos = e:GetWorldPos() end)
                                if horsePos and (pos.z - horsePos.z) > 1.0 then
                                    riding = true
                                    -- WO-38 Phase 5: this IS the mounted horse.
                                    -- Only a plain authored name travels -- it is
                                    -- the cross-client key (same rule as NPC sync);
                                    -- a generated per-save name stays local and the
                                    -- receiver keeps its proxy fallback.
                                    if en ~= "" and string.find(en, "^[%w_]+$") then
                                        mountName = en
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            -- Method 1: KCD2 human:IsRiding() (returns nil in v1.5, kept as fallback)
            if not riding then
                pcall(function()
                    if player.human then
                        local r = player.human:IsRiding()
                        if r then riding = true end
                    end
                end)
            end
            -- Method 2: CryEngine linked parent
            if not riding then
                pcall(function()
                    local p = player:GetLinkedParent()
                    if p then riding = true end
                end)
            end
            KCD2MP.isRiding = riding

            -- WO-38 Phase 5: broadcast which horse we are on, by authored
            -- name, on change plus a slow re-emit while mounted (late
            -- joiners; the relay replays nothing). "-" = dismounted or a
            -- mount whose identity could not be read (methods 1/2 detect
            -- riding without identifying the horse).
            if not riding then mountName = nil end
            KCD2MP._mountedHorseName = mountName
            local wire = mountName or "-"
            local nowC = os.clock()
            if wire ~= KCD2MP._horseInfoSentName
               or (mountName and (nowC - (KCD2MP._horseInfoSentAt or 0)) > 30) then
                KCD2MP._horseInfoSentName = wire
                KCD2MP._horseInfoSentAt = nowC
                KCD2MP_EmitEvent("horse_info", wire)
            end
        end
    end

end

-- ===== Main Tick (500ms) - position reporting =====

function KCD2MP_Tick()
    KCD2MP.tickCount = KCD2MP.tickCount + 1
    local ok, err = pcall(function()
        KCD2MP_WritePos()

        if KCD2MP.tickCount % 20 == 0 then
            local ghostCount = 0
            for _ in pairs(KCD2MP.ghosts) do ghostCount = ghostCount + 1 end
            System.LogAlways(string.format("[KCD2-MP] tick=%d ghosts=%d",
                KCD2MP.tickCount, ghostCount))
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Tick error: " .. tostring(err))
    end
    if KCD2MP.running then
        Script.SetTimer(500, KCD2MP_Tick)
    end
end

-- ===== Ghost reconciliation after a save load (WO-28 Phase 0) =====
--
-- Measured live, 2026-08-07: loading a save destroys every ghost ENTITY in the
-- world, but KCD2MP.ghosts keeps holding the entity table it was given at spawn
-- time. That table stays non-nil -- it is a Lua value, and nothing about the
-- world unload reaches in and clears it -- so KCD2MP_UpdateGhost's own
-- "spawn if missing" test (`if not ghost or not ghost.entity`) reads as
-- "present" forever and the ghost is never respawned.
--
-- What that looks like in game, in the human's own words while it was
-- happening: *"the ghost is invisible for me but I can see its nametag
-- continuing in the same path"* -- because istate keeps taking position
-- packets and KCD2MP_InterpTick keeps writing labelCache from it, with no
-- body under the label. It never recovers on its own.
--
-- The check has to be a real world lookup by spawn name (never the display
-- name -- WO-26 established that is not a key anything resolves by), which is
-- too expensive for the 20 ms interp path. So the agent calls this on a slow
-- cadence instead, the same shape as WO-13's KCD2MP_StartInterp re-arm.
--
-- Deliberately drops only the bookkeeping rather than calling
-- KCD2MP_RemoveGhost: there is no entity left to remove, the display name and
-- menu/health/death tags are all still correct for that player, and the very
-- next position packet respawns the body through the ordinary path.
-- ===== WO-84: run WO-58's stray sweep during play, not only at shutdown =====
--
-- The 2026-09-11 field session logged 265 (host) and 266 (joiner)
-- `NPC kcd2mp_0 does not have a faction.` errors. They are not the live ghost:
--   * they arrive as five bursts of exactly 52 contiguous lines plus a single
--     trailing one, one set per savegame load;
--   * each 52-line burst sits inside the entity module's save reconciliation,
--     and the single one lands right after `EntityModuleOnPostLoadGame`;
--   * the first burst on each log precedes the mod's first ghost spawn that
--     session (joiner: burst at line 10062, spawn at 14085);
--   * on the HOST, whose live ghost is kcd2mp_1, every one of the 265 names
--     kcd2mp_0 -- a name that machine never spawned in that session, and a
--     name that exists nowhere in the shipped mod data because it is only
--     ever built at runtime;
--   * `Module EntityModule processed savegame data 2705 B of 2705 B` is
--     byte-identical across all ten loads and across BOTH machines, so that
--     record is coming out of a fixed save blob rather than live world state.
--
-- KCD2MP_SweepStrayGhosts below already described and handled exactly this,
-- in WO-58, and its reasoning needs no revision. The whole gap is that it was
-- only ever reachable from KCD2MP_RemoveAllGhosts -- that is, from
-- `mp_remove_all` or KCD2MP_Stop -- and neither ran in any of the three
-- sessions in that bundle, so no stray was ever swept while anyone was
-- playing. WO-84 does not re-solve it; it runs it.
--
-- Honest limit: whether the restored body then STANDS there for the session is
-- still not established. There is no removal line for it, and no further
-- faction errors after each burst, which fits both "the engine dropped it" and
-- "it stands there silently". This is why the sweep reports what it finds -- the
-- first session that runs it answers the question either way.
--
-- NOT claimed: that any of this has anything to do with a LIVE ghost's faction.
-- It does not. The same error text is emitted for a brand-new mod-spawned
-- entity: the earlier host session shows `[KCD2-MP] Riding START id=1`, then 16
-- consecutive `NPC kcd2mp_horse_1 does not have a faction.`, then `HorseSpawn
-- OK id=1`, 21,738 lines from the nearest save load. The message means "an NPC
-- with no faction was queried", nothing more.
KCD2MP.orphanSweep     = true   -- mp_ghost_sweep on|off|now
KCD2MP._orphanSweepAt  = 0
KCD2MP._orphanSeen     = {}     -- spawn name -> seen untracked on one sweep already
KCD2MP._orphanRemovedN = 0

-- WO-84: the rollback lever for the animation throttle. 0 restores the
-- pre-WO-84 per-tick restart, so a live session can A/B the fix on one build
-- rather than two deploys -- the same discipline WO-69 used for the chain-leak
-- toggles.
function KCD2MP_SetGhostAnimRefresh(arg)
    local n = tonumber(tostring(arg or ""))
    if n == nil or n < 0 then
        mp_log(string.format("mp_ghost_anim_refresh: expected seconds >= 0, got '%s' (currently %.2f)",
            tostring(arg), KCD2MP.ghostAnimRefreshS or 1.0))
        return
    end
    KCD2MP.ghostAnimRefreshS = n
    mp_log(string.format("GHOST ANIM refresh = %.2fs%s", n,
        n <= 0 and "  (restart every tick -- pre-WO-84 behaviour)" or ""))
end

function KCD2MP_SetOrphanSweep(arg)
    local s = tostring(arg or ""):lower()
    if s == "now" then
        local n = KCD2MP_SweepStrayGhosts(true)
        mp_log("mp_ghost_sweep now: removed " .. tostring(n))
        return n
    elseif s == "on" or s == "1" or s == "true" then
        KCD2MP.orphanSweep = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.orphanSweep = false
    else
        mp_log("mp_ghost_sweep: expected 'on', 'off' or 'now', got '" .. tostring(arg) .. "'")
        return
    end
    mp_log("ORPHAN SWEEP " .. (KCD2MP.orphanSweep and "enabled" or "disabled"))
end

function KCD2MP_ReconcileGhosts()
    -- WO-84: the agent calls this every 5 s. WO-58's stray sweep throttles
    -- itself to every 30 s from here, which is the caller it never had.
    pcall(function() KCD2MP_SweepStrayGhosts(false) end)
    local fixed = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost and ghost.entity then
            local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
            local live = nil
            pcall(function() live = System.GetEntityByName(spawnName) end)
            -- WO-34 issue D, the other half of the freeze. A ghost an NPC
            -- killed in THIS world is a corpse for good -- death is a one-way
            -- transition (WO-25 Phase 3: SetState health writes do not reverse
            -- IsDead) -- so freezing alone would leave its owner permanently
            -- invisible here while they carry on playing. Recycled through the
            -- same path a save-load-destroyed entity takes: drop the
            -- bookkeeping, let the next position packet spawn a fresh body.
            --
            -- Only the ENTITY being dead triggers this. A ghost whose OWNER
            -- died (KCD2MP.ghostDead, tagged "[dead - reloading]") is still a
            -- perfectly good standing body and must NOT be recycled -- WO-28
            -- chose to leave it exactly so a player back in seconds does not
            -- cost a full spawn cycle, and that reasoning is unchanged.
            -- WO-59 Thread B: the name resolving is NOT the tracked body
            -- surviving. A reload of a save that EMBEDS a same-id ghost body
            -- (saved while that ghost stood nearby, reloaded in the same
            -- session so the id matches) destroys the tracked entity but
            -- leaves GetEntityByName answering with the embedded copy -- a
            -- different entity. The old "did the name resolve" test then
            -- passed forever: interp writes went to the destroyed entity,
            -- the nameplate walked on (it renders from the interp table),
            -- and the player was invisible -- WO-28's eyewitness shape,
            -- WO-38 Section G's unexplained report. Compare identities and
            -- treat a mismatch as an imposter: remove the embedded body and
            -- fall through to the normal clear-and-respawn path.
            if live and ghost.entityId and tostring(live.id) ~= tostring(ghost.entityId) then
                mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                       "' resolves to a DIFFERENT entity (save-embedded body?) -- removing the imposter so a fresh ghost respawns")
                mp_remove_entity_verified(live.id, spawnName, "imposter ghost " .. tostring(id))
                live = nil
            end
            local corpse = false
            if live and live.actor then
                pcall(function() corpse = live.actor:IsDead() and true or false end)
            end
            if live and corpse then
                mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                       "' is DEAD in this world -- removing the body so a fresh ghost respawns")
                -- Remove the corpse rather than abandoning it. An untracked
                -- body is what WO-27 spent a session cleaning up, and this one
                -- is also a real lootable/grabbable object that another player
                -- can commit corpseViolation on (docs/WO-34-findings.md).
                mp_remove_entity_verified(ghost.entityId, spawnName, "ghost corpse " .. tostring(id))
                live = nil
            end
            if not live then
                if not corpse then
                    mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                           "' is gone from the world (save load?) -- clearing so it respawns")
                end
                -- The horse half is destroyed by the same unload and tracked
                -- separately, so it has to be dropped too or a remounting
                -- ghost would sit on a horse that no longer exists.
                KCD2MP.horseGhosts[id] = nil
                KCD2MP.ghosts[id] = nil
                KCD2MP.labelCache[id] = nil
                -- The Flow B baseline belonged to the destroyed entity. A
                -- fresh one starts at full health, so keeping it would read as
                -- a large positive delta -- harmless (guard 3 drops it) but
                -- meaningless, and clearing it is what makes that certain.
                KCD2MP.ghostHpSeen[id] = nil
                KCD2MP.ghostHpSkip[id] = nil
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 then
        System.LogAlways("[KCD2-MP] Reconcile: " .. fixed .. " ghost(s) had lost their entity; will respawn")
    end
    return fixed
end

-- ===== Ghost Remove =====

function KCD2MP_RemoveGhost(id)
    local ghost = KCD2MP.ghosts[id]
    if not ghost then return end
    -- Remove horse ghost first (if riding)
    KCD2MP_RemoveHorse(id)
    -- WO-27: was a single unchecked System.RemoveEntity. It returns without
    -- error while leaving the entity standing, which is how orphans survived
    -- every "removal" the mod thought it had done. Look the entity up by the
    -- spawn name -- NOT the display name, which since WO-26 is known not to be
    -- a key anything resolves by (and which this mod no longer sets).
    local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
    if ghost.entityId or spawnName then
        mp_remove_entity_verified(ghost.entityId, spawnName, "ghost " .. tostring(id))
    end
    KCD2MP.ghosts[id] = nil
    KCD2MP.labelCache[id] = nil
    -- A player who disconnects while in a menu must not leave a stale
    -- "[in menu]" tag behind for whoever next reuses this ghost id (WO-13).
    KCD2MP.ghostInMenu[id] = nil
    -- Same reasoning for every WO-28 per-ghost fact: relay ids are reassigned
    -- per connection, so a leftover health figure, death tag or sampler
    -- baseline would be attributed to whoever next gets this id. The sampler
    -- baseline especially -- a stale one would read as an enormous first
    -- delta and fire a fake hit at the new occupant.
    KCD2MP.ghostHealth[id] = nil
    KCD2MP.ghostDead[id] = nil
    KCD2MP.ghostHpSeen[id] = nil
    KCD2MP.ghostHpSkip[id] = nil
    -- WO-39: same id-reuse reasoning -- a stale drawn flag would make whoever
    -- next gets this id spawn weapon-ready for no reason.
    KCD2MP.ghostWeaponDrawn[id] = nil
    System.LogAlways("[KCD2-MP] Removed ghost: " .. id)
    -- Reset riding anim probes: if they were cached while NPC was ForceMount'd they may be
    -- wrong (false). Re-probe on next riding ghost (free NPC ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ correct results).
    KCD2MP._ridingIdleAnim = nil
    KCD2MP._ridingGallopAnim = nil
end

function KCD2MP_RemoveAllGhosts()
    local count = 0
    for id, _ in pairs(KCD2MP.ghosts) do
        KCD2MP_RemoveGhost(id)
        count = count + 1
    end
    -- Clean up any orphaned horse ghosts
    for id, _ in pairs(KCD2MP.horseGhosts) do
        KCD2MP_RemoveHorse(id)
    end
    KCD2MP_SweepStrayGhosts(true)   -- WO-84: shutdown wants it gone now, not next sweep
    System.LogAlways("[KCD2-MP] Removed " .. count .. " ghosts")
end

-- WO-58: remove ghost/horse bodies this Lua state does not know about.
-- Ghosts are real world entities, so KCD2's own save system captures one
-- standing nearby at save time exactly as it was. Reload that save in a
-- LATER session (game restarted, or days later on a new mod version) and
-- the embedded body is a stray: relay ids are per-connection, so the
-- returning player almost never gets the same id back, which means
-- SpawnGhost's own same-name preexisting check never fires and
-- RemoveStaleGhostsForPlayer (which only walks the TRACKED table) never
-- sees it. The stray stands there forever wearing whatever face the old
-- session picked -- including an old fallback-keyed female body, which is
-- exactly what a "player joined as the wrong gender" report looks like
-- from across the room. Spawn names are "kcd2mp_<relayId>" and relay ids
-- are single-byte and small in practice, so a bounded name probe finds
-- every possible stray cheaply. Untracked proxies only: a name the live
-- tables own is left alone, and adopted world horses are real local
-- content that is never removed by name.
-- WO-84 extends this in four ways, without touching the reasoning above:
--   * `immediate` -- true from the shutdown/`mp_remove_all` caller, which
--     wants the body gone now. False (the new periodic caller) requires a name
--     to be seen untracked on TWO consecutive sweeps before it is removed.
--     Single-threaded Lua already means a sweep cannot interleave with
--     KCD2MP_SpawnGhost's brief untracked window; the second look makes that
--     argument unnecessary rather than merely correct, at a cost of one 30 s
--     cycle against a body that has been standing there since a previous
--     session.
--   * a 30 s throttle, so the agent's existing 5 s KCD2MP_ReconcileGhosts call
--     is a safe host for it.
--   * ids 0..63 rather than 0..31: the relay's own cap is 64 players
--     (Max players: 64), so 31 could miss a real stray on a full server. It is
--     128 name lookups every 30 s.
--   * the horse branch removes through mp_remove_entity_verified like the ghost
--     branch, instead of a bare unverified System.RemoveEntity -- the same
--     silent-no-op failure mode WO-27 spent a session cleaning up.
local STRAY_SWEEP_MAX_ID  = 63
local STRAY_SWEEP_EVERY_S = 30

local function mp_stray_check(name, tracked, label, immediate, acc)
    if tracked then
        KCD2MP._orphanSeen[name] = nil
        return
    end
    local stray = nil
    pcall(function() stray = System.GetEntityByName(name) end)
    if not stray then
        KCD2MP._orphanSeen[name] = nil
        return
    end
    if not immediate and not KCD2MP._orphanSeen[name] then
        KCD2MP._orphanSeen[name] = true
        mp_log("SweepStrayGhosts: untracked " .. name ..
               " in the world (save-embedded or leaked) -- confirming on the next sweep")
        return
    end
    KCD2MP._orphanSeen[name] = nil
    mp_log("SweepStrayGhosts: untracked " .. name ..
           " in the world (save-embedded or leaked) -- removing")
    mp_remove_entity_verified(stray.id, name, label .. " " .. name)
    acc.n = acc.n + 1
end

function KCD2MP_SweepStrayGhosts(immediate)
    if not KCD2MP.orphanSweep and not immediate then return 0 end
    if not immediate then
        local now = os.clock()
        if (now - (KCD2MP._orphanSweepAt or 0)) < STRAY_SWEEP_EVERY_S then return 0 end
        KCD2MP._orphanSweepAt = now
    end
    local acc = { n = 0 }
    for i = 0, STRAY_SWEEP_MAX_ID do
        -- Ids key these tables as strings on this side, but a numeric key has
        -- turned up often enough in this file's history to be worth checking
        -- both: a false "untracked" here would delete a live ghost.
        local sid = tostring(i)
        mp_stray_check("kcd2mp_" .. sid,
                       (KCD2MP.ghosts[sid] ~= nil) or (KCD2MP.ghosts[i] ~= nil),
                       "stray ghost", immediate, acc)
        mp_stray_check("kcd2mp_horse_" .. sid,
                       (KCD2MP.horseGhosts[sid] ~= nil) or (KCD2MP.horseGhosts[i] ~= nil),
                       "stray ghost horse", immediate, acc)
    end
    if acc.n > 0 then
        KCD2MP._orphanRemovedN = (KCD2MP._orphanRemovedN or 0) + acc.n
        System.LogAlways("[KCD2-MP] SweepStrayGhosts: removed " .. acc.n
                         .. " stray bodies (session total " .. KCD2MP._orphanRemovedN .. ")")
    end
    return acc.n
end

-- ===== Start / Stop =====

function KCD2MP_Start()
    if KCD2MP.running then
        System.LogAlways("[KCD2-MP] Already running")
        return
    end
    KCD2MP.running = true
    KCD2MP.tickCount = 0
    System.LogAlways("[KCD2-MP] Starting (pos tick=500ms, interp tick=50ms)")
    Script.SetTimer(500, KCD2MP_Tick)
    KCD2MP_StartInterp()
end

function KCD2MP_Stop()
    KCD2MP.running = false
    KCD2MP.interpRunning = false
    -- WO-84: retire the generation whose timer is still in flight, so a
    -- Start right after this Stop cannot be told it has a leaked chain.
    if KCD2MP.interpGen then KCD2MP._interpRetired[KCD2MP.interpGen] = true end
    KCD2MP.labelRunning = false
    KCD2MP.labelCache = {}
    -- WO-102.5 Phase 1: guarantee resume on `mp_stop` (and any other path
    -- that reaches KCD2MP_Stop -- there is no live one today besides the
    -- console command, but a future one gets this for free). Before
    -- KCD2MP_RemoveAllGhosts, which would otherwise delete the puppet
    -- entries mp_wo102_reconcile_pauses uses to decide "still needed" --
    -- here every paused NPC is unpaused unconditionally. Agent shutdown and
    -- disconnect are a SEPARATE path (KCD2MP_Wo102ResumeAll, called from
    -- GameBridge.cs -- KCD2MP_Stop is never reached from there).
    if KCD2MP._npcPaused then
        local n = 0
        for _ in pairs(KCD2MP._npcPaused) do n = n + 1 end
        if n > 0 then mp_wo102_resume_all("mod-stop") end
    end
    if KCD2MP_NpcReplicaDemoteAll then KCD2MP_NpcReplicaDemoteAll("mod-stop") end   -- WO-104
    KCD2MP_RemoveAllGhosts()
    System.LogAlways("[KCD2-MP] Stopped")
end

-- ===== Test / Inspect =====

function KCD2MP_SpawnTest()
    if not player then return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local ox, oy = 3, 0
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end

    KCD2MP_SpawnGhost("test_ghost", pos.x + ox, pos.y + oy, pos.z, ang and ang.z or 0)
end

-- WO-100.5 Phase 0: the side-by-side the perception question needs.
-- Spawns TWO ghosts through the ordinary ghost path -- one NPC_NAI, one NPC --
-- three metres apart in front of the player, so "do other NPCs react to it?"
-- is a comparison in one scene rather than two runs separated by a respawn.
-- Both go through KCD2MP_SpawnGhost, so this also exercises item 4: whether
-- the class swap survives the roster's face-mapping and soul assignment.
-- Remove them with mp_remove_all.
function KCD2MP_Wo1005NaiAB()
    if not player then System.LogAlways("[KCD2-MP] NAI-AB: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then System.LogAlways("[KCD2-MP] NAI-AB: no player position"); return end
    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local az = ang and ang.z or 0
    local fx, fy = math.sin(az), math.cos(az)
    -- perpendicular, so the two stand beside each other facing the player
    local px, py = math.cos(az), -math.sin(az)

    local was = KCD2MP.ghostNai
    System.LogAlways("[KCD2-MP] NAI-AB: spawning nai_probe (NPC_NAI) and npc_probe (NPC)."
        .. " Watch both for guard reaction, crowd parting and head-tracking;"
        .. " then grep kcd.log for 'Registering NPC kcd2mp_' and behaviour-tree role errors.")
    KCD2MP.ghostNai = true
    KCD2MP_SpawnGhost("nai_probe", pos.x + fx * 4 + px * 1.5, pos.y + fy * 4 + py * 1.5, pos.z, az)
    KCD2MP.ghostNai = false
    KCD2MP_SpawnGhost("npc_probe", pos.x + fx * 4 - px * 1.5, pos.y + fy * 4 - py * 1.5, pos.z, az)
    KCD2MP.ghostNai = was
    System.LogAlways("[KCD2-MP] NAI-AB: done; mp_ghost_nai restored to " .. tostring(was))
end

-- WO-100.5 Phase 2: the body-state channel's counters, on demand.
function KCD2MP_AnimStats()
    local a = KCD2MP._animStats
    System.LogAlways(string.format(
        "[KCD2-MP] MP-ANIM section=apply legacy_toggle=%s applied=%d legacy=%d declined=%d rejected=%d",
        tostring(KCD2MP.animLegacy), a.applied, a.legacy, a.noBody, a.rejected))
    for id, g in pairs(KCD2MP.ghosts or {}) do
        local b = g.istate and g.istate.body
        if b then
            System.LogAlways(string.format(
                "[KCD2-MP] MP-ANIM section=peer ghost=%s pace=%s dir=%s stance=%s anim_speed=%.2f",
                tostring(id), b.pace, b.dir, b.stance, b.speed or 0))
        else
            System.LogAlways("[KCD2-MP] MP-ANIM section=peer ghost=" .. tostring(id) .. " body=none")
        end
    end
end

function KCD2MP_InspectGhost()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost. Run mp_spawn_test first.")
        return
    end

    local ent = ghost.entity
    local istate = ghost.istate
    System.LogAlways("[KCD2-MP] === GHOST INSPECT ===")
    pcall(function() System.LogAlways("[KCD2-MP] name=" .. tostring(ent:GetName())) end)
    pcall(function() System.LogAlways("[KCD2-MP] class=" .. tostring(ent.class)) end)
    if istate then
        System.LogAlways(string.format("[KCD2-MP] interp: alpha=%.3f step=%.3f ticksSince=%d packets=%d",
            istate.alpha, istate.alphaStep, istate.ticksSincePacket, istate.packetCount))
        System.LogAlways(string.format("[KCD2-MP] prev=%.1f,%.1f,%.1f  target=%.1f,%.1f,%.1f  cur=%.1f,%.1f,%.1f",
            istate.px, istate.py, istate.pz,
            istate.tx, istate.ty, istate.tz,
            istate.cx, istate.cy, istate.cz))
        System.LogAlways(string.format("[KCD2-MP] velocity=%.2f,%.2f,%.2f u/s",
            istate.vx, istate.vy, istate.vz))
    end
    pcall(function()
        local pos = ent:GetWorldPos()
        System.LogAlways(string.format("[KCD2-MP] entity pos=%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Discovery helpers (unchanged) =====

function KCD2MP_FindNPCs()
    System.LogAlways("[KCD2-MP] === FINDING HUMAN NPCs ===")
    if not player then return end

    local ppos = player:GetWorldPos()

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 100)
        if not ents then return end

        local npcCount = 0
        for _, ent in ipairs(ents) do
            local hasChar = false
            pcall(function() hasChar = ent:IsSlotCharacter(0) end)

            if hasChar then
                local isHuman = false
                pcall(function()
                    if ent.soul or ent.human or ent.actor then isHuman = true end
                end)

                if isHuman then
                    local name = "?"
                    local eclass = "?"
                    pcall(function() name = ent:GetName() end)
                    pcall(function() eclass = ent.class or "?" end)

                    npcCount = npcCount + 1
                    System.LogAlways(string.format("[KCD2-MP] NPC: name=%s class=%s",
                        tostring(name), tostring(eclass)))

                    if npcCount >= 10 then
                        System.LogAlways("[KCD2-MP] ... (first 10 only)")
                        break
                    end
                end
            end
        end

        System.LogAlways("[KCD2-MP] Found " .. npcCount .. " human NPCs within 100m")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] FindNPCs error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Animation Discovery =====

-- Probe animation names - only GetAnimationLength > 0 is reliable
function KCD2MP_ProbeAnims()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeAnims: no ghost.")
        return
    end
    local ent = ghost.entity

    -- Full CryEngine path variants (no extension) + short names
    local candidates = {
        -- Short names
        "idle", "run", "walk", "sprint", "jog",
        "Idle", "Run", "Walk", "Sprint",
        -- Full path guesses (KCD2 convention)
        "animations/humans/male/locomotion/run_loop",
        "animations/humans/male/locomotion/walk_loop",
        "animations/humans/male/locomotion/idle_loop",
        "animations/humans/male/locomotion/run_fwd",
        "animations/humans/male/locomotion/walk_fwd",
        "animations/humans/male/locomotion/sprint_loop",
        "animations/humans/male/locomotion/run",
        "animations/humans/male/locomotion/walk",
        "animations/humans/male/locomotion/idle",
        -- KCD1-style paths
        "animations/characters/humans/male/locomotion/run_loop",
        "animations/characters/humans/male/locomotion/walk_loop",
        "animations/characters/humans/male/locomotion/idle_loop",
        -- Assets subfolder
        "animations/assets/humans/locomotion/run_loop",
        "animations/assets/humans/locomotion/walk_loop",
        -- Mannequin fragment names
        "MotionIdle", "MotionRun", "MotionWalk",
        "LocomotionIdle", "LocomotionRun", "LocomotionWalk",
        "Locomotion", "locomotion",
    }

    System.LogAlways("[KCD2-MP] === PROBING ANIMS ON GHOST ===")
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] HIT: '%s' len=%.3f", name, len))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Real Horse Scanner =====
-- Scans a real KCD2 horse NPC within 20m to discover animation names, AI methods,
-- horse.horse component API, rider linkage, etc. Helps calibrate ghost horse behavior.
function KCD2MP_ScanNearbyHorse()
    if not player then
        System.LogAlways("[KCD2-MP] ScanHorse: no player")
        return
    end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === SCAN NEARBY HORSE ===")

    local ents = nil
    pcall(function() ents = System.GetEntitiesInSphere(ppos, 20) end)
    if not ents then
        System.LogAlways("[KCD2-MP] GetEntitiesInSphere failed")
        return
    end

    local animCandidates = {
        "idle","walk","trot","canter","gallop","run","stand",
        "idle_loop","walk_loop","trot_loop","canter_loop","gallop_loop","run_loop",
        "horse_idle","horse_walk","horse_trot","horse_canter","horse_gallop","horse_run",
        "horse_idle_loop","horse_walk_loop","horse_trot_loop","horse_gallop_loop",
        "horse_stand","horse_stand_idle","horse_rest",
        "horse_loco_idle","horse_loco_walk","horse_loco_trot","horse_loco_gallop",
        "animal_idle","animal_walk","animal_trot","animal_gallop","animal_run",
        "loco_idle","loco_walk","loco_run","loco_gallop","loco_trot",
        "act_idle","act_walk","act_run","act_gallop","act_trot",
        "mm_idle","mm_walk","mm_run","mm_gallop",
        "3d_idle","3d_walk","3d_run","3d_gallop","3d_trot",
        "relaxed_idle","relaxed_walk","relaxed_run",
        "stand_idle","stand_loop","rest_idle",
    }

    local found = 0
    for _, e in ipairs(ents) do
        local ec = "?"
        local en = ""
        pcall(function() ec = tostring(e.class or "?") end)
        pcall(function() en = tostring(e:GetName() or "") end)

        if ec == "Horse" and not en:find("kcd2mp_horse_") then
            found = found + 1
            System.LogAlways(string.format("[KCD2-MP] HORSE: name=%s id=%s", en, tostring(e.id)))

            -- Character file path (tells us the skeleton / animation set)
            pcall(function()
                local cf = e:GetCharacterFileName(0)
                System.LogAlways("[KCD2-MP] CharFile[0]: " .. tostring(cf))
            end)
            pcall(function()
                local cf = e:GetCharacterFileName(1)
                System.LogAlways("[KCD2-MP] CharFile[1]: " .. tostring(cf))
            end)

            -- Animation probe: slot 0 and slot 1
            local hits0, hits1 = {}, {}
            for _, nm in ipairs(animCandidates) do
                local l0 = 0; pcall(function() l0 = e:GetAnimationLength(0, nm) or 0 end)
                if l0 > 0 then hits0[#hits0+1] = nm .. "=" .. string.format("%.2f", l0) end
                local l1 = 0; pcall(function() l1 = e:GetAnimationLength(1, nm) or 0 end)
                if l1 > 0 then hits1[#hits1+1] = nm .. "=" .. string.format("%.2f", l1) end
            end
            System.LogAlways("[KCD2-MP] AnimSlot0: " .. (#hits0>0 and table.concat(hits0,", ") or "none"))
            System.LogAlways("[KCD2-MP] AnimSlot1: " .. (#hits1>0 and table.concat(hits1,", ") or "none"))

            -- horse.horse component
            local hc = nil; pcall(function() hc = e.horse end)
            if hc then
                local fns = {}
                pcall(function()
                    for k, v in pairs(hc) do
                        if type(v) == "function" then fns[#fns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] horse.horse fns: " .. table.concat(fns, ", "))
                pcall(function() System.LogAlways("[KCD2-MP] HasRider: " .. tostring(e.horse:HasRider())) end)
                pcall(function() System.LogAlways("[KCD2-MP] IsMountable: " .. tostring(e.horse:IsMountable())) end)
            else
                System.LogAlways("[KCD2-MP] horse.horse = nil")
            end

            -- AI component methods
            local hasAI = false; pcall(function() hasAI = e.AI ~= nil end)
            System.LogAlways("[KCD2-MP] hasAI: " .. tostring(hasAI))
            if hasAI then
                local aiFns = {}
                pcall(function()
                    for k, v in pairs(e.AI) do
                        if type(v) == "function" then aiFns[#aiFns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] AI fns: " .. table.concat(aiFns, ", "))
            end

            -- human / actor / soul
            pcall(function() System.LogAlways("[KCD2-MP] has human: " .. tostring(e.human ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has actor: " .. tostring(e.actor ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has soul: " .. tostring(e.soul ~= nil)) end)

            -- Properties
            pcall(function()
                if e.Properties then
                    local props = {}
                    for k, v in pairs(e.Properties) do
                        if type(v) ~= "table" then props[#props+1] = k .. "=" .. tostring(v) end
                    end
                    System.LogAlways("[KCD2-MP] Props: " .. table.concat(props, " | "))
                end
            end)

            if found >= 2 then break end
        end
    end

    if found == 0 then
        System.LogAlways("[KCD2-MP] No real horses within 20m (try within 20m of a horse NPC)")
    end
    System.LogAlways("[KCD2-MP] === END SCAN ===")
end

-- Find nearby HUMAN NPC and get their character model path, then copy to ghost
function KCD2MP_CopyNPCModel()
    if not player then return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HUMAN NPC + COPY MODEL ===")

    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost entity! Run server first.")
        return
    end

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 50)
        if not ents then return end

        local humanCount = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                -- Must have soul or human (real human NPC, not horse/door/chest)
                local isHuman = false
                pcall(function()
                    isHuman = (ent.soul ~= nil) or (ent.human ~= nil)
                end)
                if not isHuman then
                    -- Also accept NPCs with actor table
                    pcall(function()
                        if ent.actor and ent.actor.__this then isHuman = true end
                    end)
                end

                if isHuman then
                    local ename = "?"
                    pcall(function() ename = ent:GetName() end)
                    local eclass = "?"
                    pcall(function() eclass = ent.class or "?" end)
                    System.LogAlways(string.format("[KCD2-MP] HUMAN NPC: %s (class=%s)", ename, eclass))
                    humanCount = humanCount + 1

                    -- Try to get character filename
                    local cdfPath = nil
                    pcall(function()
                        local ch = ent:GetCharacter(0)
                        if ch then
                            cdfPath = ch:GetFilePath()
                            System.LogAlways("[KCD2-MP]   GetCharacter(0):GetFilePath() = " .. tostring(cdfPath))
                        end
                    end)
                    pcall(function()
                        local fn = ent:GetCharacterFileName(0)
                        System.LogAlways("[KCD2-MP]   GetCharacterFileName(0) = " .. tostring(fn))
                        if fn and not cdfPath then cdfPath = fn end
                    end)
                    -- Check Properties for model path
                    pcall(function()
                        if ent.Properties then
                            for k, v in pairs(ent.Properties) do
                                if type(v) == "string" and #v > 3 then
                                    if k:lower():find("model") or k:lower():find("cdf") or
                                       k:lower():find("file") or k:lower():find("char") then
                                        System.LogAlways("[KCD2-MP]   Props." .. k .. " = " .. v)
                                        if not cdfPath then cdfPath = v end
                                    end
                                end
                            end
                        end
                    end)

                    -- Probe animations on this NPC
                    local animCandidates = {
                        "idle", "run", "walk", "sprint", "jog",
                        "Idle", "Run", "Walk", "Sprint",
                        "run_loop", "walk_loop", "idle_loop", "sprint_loop",
                        "run_fwd", "walk_fwd", "run01", "walk01", "idle01",
                        "mm_run_fwd", "mm_walk_fwd", "mm_idle",
                        "loco_run", "loco_walk", "loco_idle",
                        "act_run", "act_walk", "act_idle",
                    }
                    for _, aname in ipairs(animCandidates) do
                        local len = 0
                        pcall(function() len = ent:GetAnimationLength(0, aname) or 0 end)
                        if len > 0 then
                            System.LogAlways(string.format("[KCD2-MP]   ANIM HIT '%s' len=%.3f", aname, len))
                        end
                    end

                    -- If we found a CDF, try loading it onto ghost
                    if cdfPath and cdfPath ~= "" then
                        System.LogAlways("[KCD2-MP]   Loading CDF onto ghost: " .. cdfPath)
                        local loadOk, loadErr = pcall(function()
                            ghost.entity:LoadCharacter(0, cdfPath)
                        end)
                        System.LogAlways("[KCD2-MP]   LoadCharacter result: " .. tostring(loadOk) .. " " .. tostring(loadErr))

                        if loadOk then
                            -- Now probe ghost again
                            System.LogAlways("[KCD2-MP]   Re-probing ghost after CDF load:")
                            for _, aname in ipairs(animCandidates) do
                                local len = 0
                                pcall(function() len = ghost.entity:GetAnimationLength(0, aname) or 0 end)
                                if len > 0 then
                                    System.LogAlways(string.format("[KCD2-MP]   GHOST HIT '%s' len=%.3f", aname, len))
                                end
                            end
                        end
                    end

                    if humanCount >= 3 then break end
                end
            end
        end
        System.LogAlways("[KCD2-MP] Found " .. humanCount .. " human NPCs")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test AI.SetForcedNavigation on ghost (try to drive locomotion animation via AI)
function KCD2MP_TestAINav()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] TestAINav: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] TestAINav: sending velocity {1,0,0} to entityId=" .. tostring(eid))

    -- Try passing velocity vector (tell AI it's moving forward)
    local ok1, e1 = pcall(function() AI.SetForcedNavigation(eid, {x=3, y=0, z=0}) end)
    System.LogAlways("[KCD2-MP]   SetForcedNavigation: " .. tostring(ok1) .. " " .. tostring(e1))

    local ok2, e2 = pcall(function() AI.SetSpeed(eid, 3) end)
    System.LogAlways("[KCD2-MP]   SetSpeed(3): " .. tostring(ok2) .. " " .. tostring(e2))

    local ok3, e3 = pcall(function() AI.Signal(0, 1, "OnMoveForward", eid) end)
    System.LogAlways("[KCD2-MP]   Signal OnMoveForward: " .. tostring(ok3) .. " " .. tostring(e3))
end

-- Deep scan: recursively list up to 3 levels, log files with .caf/.adb
function KCD2MP_ScanAnims()
    System.LogAlways("[KCD2-MP] === DEEP ANIM SCAN ===")

    local function scanDir(path, depth)
        local entries = nil
        pcall(function() entries = System.ScanDirectory(path) end)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = path .. "/" .. name
            -- Log CAF/ADB files immediately
            if name:find("%.caf$") or name:find("%.CAF$") then
                System.LogAlways("[KCD2-MP] CAF: " .. full)
            elseif name:find("%.adb$") or name:find("%.ADB$") then
                System.LogAlways("[KCD2-MP] ADB: " .. full)
            elseif depth < 3 then
                -- Recurse into subdirectory
                scanDir(full, depth + 1)
            end
        end
    end

    -- Scan humans animation tree
    scanDir("Animations/humans", 1)
    scanDir("Animations/assets", 1)
    scanDir("Animations/Mannequin/adb", 1)

    System.LogAlways("[KCD2-MP] === END DEEP SCAN ===")
end

-- Try AI.SetForcedNavigation to drive locomotion animation
-- dirX, dirY = movement direction (unit vector), speed = 0 to stop
function KCD2MP_SetGhostMovement(id, dirX, dirY, speed)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end

    local eid = ghost.entityId
    if speed > 0 then
        -- Tell AI the entity is moving in this direction at this speed
        pcall(function() AI.SetSpeed(eid, speed) end)
        pcall(function()
            AI.SetForcedNavigation(eid, {x=dirX, y=dirY, z=0})
        end)
    else
        pcall(function() AI.SetForcedNavigation(eid, {x=0, y=0, z=0}) end)
        pcall(function() AI.SetSpeed(eid, 0) end)
    end
end

-- Read Mannequin ADB via CryEngine XML loader (reads from PAK)
function KCD2MP_ReadADB()
    System.LogAlways("[KCD2-MP] === READ ADB ===")

    local adbPaths = {
        "Animations/Mannequin/ADB/kcd_male_database.adb",
        "Animations/Mannequin/adb/kcd_male_database.adb",
        "animations/mannequin/adb/kcd_male_database.adb",
    }

    -- Try CryEngine XML loader (reads files from PAK virtual filesystem)
    for _, path in ipairs(adbPaths) do
        local node = nil
        local ok, err = pcall(function()
            node = System.LoadXMLFile(path)
        end)
        System.LogAlways("[KCD2-MP] LoadXMLFile(" .. path .. "): ok=" .. tostring(ok) .. " node=" .. tostring(node) .. " err=" .. tostring(err))
        if ok and node then
            System.LogAlways("[KCD2-MP] XML loaded! Walking nodes...")
            -- Walk XML tree looking for Fragment names
            local function walkNode(n, depth)
                if depth > 4 then return end
                local tag = ""
                local name = ""
                pcall(function() tag = n:getTag() end)
                pcall(function() name = n:getAttr("name") end)
                if name and name ~= "" then
                    System.LogAlways("[KCD2-MP] " .. string.rep("  ", depth) .. tag .. " name='" .. name .. "'")
                end
                local count = 0
                pcall(function() count = n:getChildCount() end)
                for i = 0, count - 1 do
                    local child = nil
                    pcall(function() child = n:getChild(i) end)
                    if child then walkNode(child, depth + 1) end
                end
            end
            walkNode(node, 0)
            System.LogAlways("[KCD2-MP] === END ===")
            return
        end
    end

    -- Fallback: ScanDirectory
    System.LogAlways("[KCD2-MP] LoadXMLFile failed for all paths. Scanning directories...")
    local dirs = {
        "Animations/Mannequin/ADB",
        "Animations/Mannequin/adb",
        "Animations/Mannequin/adb/adb",
    }
    for _, d in ipairs(dirs) do
        local entries = nil
        pcall(function() entries = System.ScanDirectory(d) end)
        if entries and #entries > 0 then
            System.LogAlways("[KCD2-MP] " .. d .. " -> " .. #entries .. " entries:")
            for i, e in ipairs(entries) do
                System.LogAlways("[KCD2-MP]   " .. e)
                if i > 30 then break end
            end
        else
            System.LogAlways("[KCD2-MP] " .. d .. " -> empty/nil")
        end
    end

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Probe Mannequin animation tags on ghost via AI.SetAnimationTag
-- Tags drive which Mannequin fragments play (including locomotion)
function KCD2MP_ProbeAnimTags()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] ProbeAnimTags: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === PROBE ANIM TAGS ===")
    System.LogAlways("[KCD2-MP] entityId=" .. tostring(eid))

    -- Common Mannequin tag names for locomotion
    local tags = {
        "Moving", "moving", "Run", "run", "Walk", "walk",
        "Sprint", "sprint", "Locomotion", "locomotion",
        "Alert", "alert", "Relaxed", "relaxed",
        "InCombat", "Combat", "Idle", "idle",
        "Forward", "forward", "MoveForward",
        "Jogging", "Running", "Walking",
    }

    System.LogAlways("[KCD2-MP] Trying AI.SetAnimationTag:")
    for _, tag in ipairs(tags) do
        local ok, err = pcall(function()
            AI.SetAnimationTag(eid, tag)
        end)
        -- Log only errors or interesting results
        if not ok then
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' ERROR: " .. tostring(err))
        else
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' OK")
        end
    end

    -- Also try clearing tags
    pcall(function() AI.SetAnimationTag(eid, "") end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test the real animation names from ADB analysis
function KCD2MP_TestRunAnim()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] TestRunAnim: no ghost")
        return
    end
    local ent = ghost.entity
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === TEST REAL ANIM NAMES ===")

    local names = {
        "3d_relaxed_run_turn_strafe",
        "3d_relaxed_walk_turn_strafe",
        "relaxed_idle_both",
        "3d_armored_walk_turn_strafe",
        "3d_wounded_run_turn_strafe",
    }
    for _, name in ipairs(names) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        local started = false
        pcall(function() started = ent:StartAnimation(0, name) end)
        System.LogAlways(string.format("[KCD2-MP] '%s': len=%.3f started=%s",
            name, len, tostring(started)))
    end

    -- Also try AI tag "run"
    System.LogAlways("[KCD2-MP] Setting AI tag 'run'...")
    pcall(function() AI.SetAnimationTag(eid, "run") end)
    pcall(function() AI.SetSpeed(eid, 4) end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Terrain Debug =====

function KCD2MP_TerrainCheck()
    if not player then System.LogAlways("[KCD2-MP] TerrainCheck: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ok, gz = pcall(function() return Terrain.GetElevation(pos.x, pos.y) end)
    System.LogAlways(string.format("[KCD2-MP] TerrainCheck: player pos=%.2f,%.2f,%.2f | Terrain.GetElevation=ok=%s gz=%s",
        pos.x, pos.y, pos.z, tostring(ok), tostring(gz)))

    -- Check ghost position vs terrain
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local gpos = nil
            pcall(function() gpos = ghost.entity:GetWorldPos() end)
            local tgz = nil
            if gpos then
                pcall(function() tgz = Terrain.GetElevation(gpos.x, gpos.y) end)
                System.LogAlways(string.format("[KCD2-MP] Ghost '%s': entity z=%.2f | terrain z=%s | diff=%s",
                    id, gpos.z, tostring(tgz), tgz and string.format("%.2f", gpos.z - tgz) or "?"))
            end
        end
    end
end

-- ===== Stance Probe =====

function KCD2MP_ProbeStance()
    if not player then System.LogAlways("[KCD2-MP] ProbeStance: no player"); return end
    System.LogAlways("[KCD2-MP] === STANCE PROBE ===")
    local s1, s2, s3 = nil, nil, nil
    local ok1 = pcall(function() s1 = player:GetStance() end)
    System.LogAlways("[KCD2-MP] GetStance() ok=" .. tostring(ok1) .. " val=" .. tostring(s1))
    local ok2 = pcall(function()
        if player.actor then
            s2 = player.actor.bSneaking
            System.LogAlways("[KCD2-MP] actor.bSneaking=" .. tostring(s2))
        else
            System.LogAlways("[KCD2-MP] actor=nil")
        end
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== WO-88 -- dialogue-state probe (WO-80 s5 item 1), read-only =====
--
-- WO-57 documented human:IsInDialog() and Dialog.IsSoulInDialog(wuid); WO-80
-- could not probe either (no game reachable) and WO-65's rule stands: a
-- documented bind is not a verified one. This probe is the live check.
-- It changes nothing -- it reports the bind's type, its pcall result and
-- the soul-level alternative so a single console command answers "does the
-- bind exist on this build, and does it read true inside a conversation".
--
-- Field context for the next session (docs/WO-88-findings.md s2.3): in the
-- 2026-09-12 logs, six real player conversations (Ex/Ex participants,
-- non-bark flags) showed NO gap in the [KCD2-MP-DATA] stream and the NPC
-- emitter kept sending heartbeats through a 48 s arrest dialogue -- so on
-- this build a dialogue does NOT suspend the Script.SetTimer chains, and
-- pumping through one would not have changed what was observed. Run the
-- probe while in a conversation and read both this and the DATA cadence
-- before deciding the pump needs a dialogue input at all.
function KCD2MP_ProbeDialog()
    if not player then System.LogAlways("[KCD2-MP] ProbeDialog: no player"); return end
    System.LogAlways("[KCD2-MP] === DIALOG PROBE ===")
    local hType = type(player.human)
    System.LogAlways("[KCD2-MP] player.human type=" .. hType)
    if hType == "table" or hType == "userdata" then
        local fType = "nil"
        pcall(function() fType = type(player.human.IsInDialog) end)
        System.LogAlways("[KCD2-MP] player.human.IsInDialog type=" .. tostring(fType))
        if fType == "function" then
            local v = nil
            local ok, err = pcall(function() v = player.human:IsInDialog() end)
            System.LogAlways("[KCD2-MP] human:IsInDialog() ok=" .. tostring(ok)
                .. " val=" .. tostring(v) .. " valtype=" .. type(v)
                .. (ok and "" or (" err=" .. tostring(err))))
        end
    end
    local dType = type(Dialog)
    System.LogAlways("[KCD2-MP] Dialog global type=" .. dType)
    if dType == "table" then
        local sType = "nil"
        pcall(function() sType = type(Dialog.IsSoulInDialog) end)
        System.LogAlways("[KCD2-MP] Dialog.IsSoulInDialog type=" .. tostring(sType))
        if sType == "function" and player.soul then
            local wuid = nil
            pcall(function() wuid = player.soul:GetId() end)
            System.LogAlways("[KCD2-MP] player.soul:GetId() -> " .. tostring(wuid) .. " (" .. type(wuid) .. ")")
            if wuid ~= nil then
                local v = nil
                local ok, err = pcall(function() v = Dialog.IsSoulInDialog(wuid) end)
                System.LogAlways("[KCD2-MP] Dialog.IsSoulInDialog(wuid) ok=" .. tostring(ok)
                    .. " val=" .. tostring(v) .. (ok and "" or (" err=" .. tostring(err))))
            end
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== WO-65 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ghost civic isolation: Phase 0 probe =====
--
-- WO-34 proved a ghost is a full crime victim (real fines, jail, settlement
-- rep loss) and the Civilians faction override is inert. KCD2Online's answer
-- (WO-64 Phase 1, source-read @5777c15, never live-observed) is script
-- contexts: seven switch_disabled*/crime_disableReport contexts set via
-- Contexts.SetPersistentOption, then soul:RestrictDialog(true) +
-- human:InterruptDialogs(), verified with soul:HasScriptContext.
--
-- Static evidence on OUR build (checked 2026-08-27):
--   - all seven context names are real rows in Tables.pak
--     Libs/Tables/ai/ScriptContext.xml (crime_disableReport even carries
--     SideEffect="crimeDisableReport")
--   - HasScriptContext / RestrictDialog / InterruptDialogs: in Warhorse's
--     shipped scriptbind docs AND as strings in our module DLLs
--     (RPGModule/DialogModule/EntityModule); HasScriptContext is called by
--     shipped game Lua (BasicActor.lua, TriggerBase.lua)
--   - Contexts.SetPersistentOption: found NOWHERE -- not in any Modding
--     Tools module DLL, not in retail WHGame.dll, not in any pak's Lua.
--     KCD2Online itself only runtime-probes for it and skips if absent.
-- So this probe is authoritative for the setter; everything is read-only.
-- WO-68 Phase 3: the first seven (KCD2Online's block) were applied and
-- verified live -- and the WO-34 repro still outlawed the player. The game's
-- own AI data says why: the observer-side tree that turns a witnessed hit into
-- a crime (Scripts.pak :: AI/npc/basic/switch/handleAwareness_hitVolume.xml)
-- checks crime_ignoredNPCHitVolume on the VICTIM, and never checks
-- crime_disableReport against a victim at all. The last four are that family's
-- victim-side members, each from a real EntityContextCheck. Keep this list in
-- step with kIsolationContexts in native/KCDMP/script_context.cpp -- the
-- native side applies them, this list is what the readback reports.
KCD2MP.isolationContexts = {
    "switch_disabledInformationReaction",
    "switch_disabledHearingReaction",
    "switch_disabledPerceptionReaction",
    "switch_disabledPickpocketReaction",
    "switch_disabledNearMissReaction",
    "switch_disabledHitBehavioralReaction",
    "crime_disableReport",
    "crime_ignoredNPCHitVolume",
    "crime_ignoredUnconsciousBody",
    "crime_ignoredCorpse",
    "crime_ignoredPickpocket",
}

function KCD2MP_ProbeContexts()
    local function L(s) System.LogAlways("[KCD2-MP] " .. s) end
    L("=== CONTEXTS PROBE (WO-65) ===")

    -- 1. The Contexts global. Never found statically; type() here decides.
    L("global Contexts type=" .. type(Contexts))
    if type(Contexts) == "table" then
        pcall(function()
            L("Contexts.SetPersistentOption type=" .. type(Contexts.SetPersistentOption))
            local n = 0
            for k, v in pairs(Contexts) do
                L("  Contexts." .. tostring(k) .. " : " .. type(v))
                n = n + 1
                if n >= 40 then L("  ...truncated at 40 keys"); break end
            end
        end)
    end

    -- 2. Any global whose name mentions Context (catches a renamed table).
    pcall(function()
        if type(_G) ~= "table" then L("_G not iterable in this sandbox"); return end
        local n = 0
        for k, v in pairs(_G) do
            if type(k) == "string" and string.find(k, "ontext") then
                L("_G." .. k .. " : " .. type(v))
                n = n + 1
                if n >= 20 then L("...truncated at 20 globals"); break end
            end
        end
        if n == 0 then L("no *ontext* globals found") end
    end)

    -- 3. Method surface + pre-write context state, on a live ghost if one
    --    exists, and on the player as a known-good control (shipped game Lua
    --    calls player.soul:HasScriptContext, so the player half must work).
    local function probeBody(tag, e)
        if not e then L(tag .. ": no entity"); return end
        L(tag .. ": soul=" .. type(e.soul) .. " human=" .. type(e.human))
        pcall(function()
            if type(e.soul) == "table" then
                L(tag .. ".soul.HasScriptContext : " .. type(e.soul.HasScriptContext))
                L(tag .. ".soul.RestrictDialog   : " .. type(e.soul.RestrictDialog))
                L(tag .. ".soul.IsDialogRestricted : " .. type(e.soul.IsDialogRestricted))
                -- Candidate setters: enumerate, never guess. Any key whose
                -- name mentions Context/Option/Restrict is worth seeing.
                for k, v in pairs(e.soul) do
                    if type(k) == "string" and (string.find(k, "ontext") or string.find(k, "ption") or string.find(k, "estrict")) then
                        L(tag .. ".soul." .. k .. " : " .. type(v))
                    end
                end
            end
            if type(e.human) == "table" then
                L(tag .. ".human.InterruptDialogs : " .. type(e.human.InterruptDialogs))
                for k, v in pairs(e.human) do
                    if type(k) == "string" and (string.find(k, "ontext") or string.find(k, "ialog")) then
                        L(tag .. ".human." .. k .. " : " .. type(v))
                    end
                end
            end
        end)
        for _, ctx in ipairs(KCD2MP.isolationContexts) do
            local res = nil
            local ok, err = pcall(function() res = e.soul:HasScriptContext(ctx) end)
            L(tag .. " HasScriptContext('" .. ctx .. "') ok=" .. tostring(ok)
                .. " -> " .. tostring(res) .. (ok and "" or (" err=" .. tostring(err))))
        end
    end

    local gid, ghost = next(KCD2MP.ghosts)
    if ghost and ghost.entity then
        probeBody("ghost[" .. tostring(gid) .. "]", ghost.entity)
    else
        L("no live ghost -- spawn one (mp_spawn_test) and rerun for the ghost half")
    end
    probeBody("player", player)

    L("=== END CONTEXTS PROBE ===")
end

-- ===== WO-65 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ghost civic isolation (Phase 1) =====
--
-- What the live probe settled (2026-08-27, all observed in-game):
--   - Contexts global is nil; no script-context setter exists under any
--     plausible name on soul/entity/AI/Game/XGenAIModule/System/Script;
--     SetEntityScriptContext is not a console command ("Unknown command").
--     The seven isolation contexts CANNOT be set from Lua on this build --
--     the crime-report half of KCD2Online's block is native-only here.
--   - soul:RestrictDialog(true) is a REAL write: IsDialogRestricted flipped
--     false->true on a live ghost. human:InterruptDialogs() runs clean.
-- So this applies what the build offers (the dialog half), logs
-- missing-on-this-build for each context, and keeps a generic setter hook so
-- a future patch that ships Contexts.SetPersistentOption lights up the rest
-- without a code change.
--
-- Lifecycle: called directly in KCD2MP_SpawnGhost (spawn path, not a timer --
-- menus suspend Script.SetTimer and reload kills timers), and re-asserted
-- opportunistically from the existing 1500ms name-settle timer in case the
-- soul was not ready at spawn+0. All respawn paths funnel through SpawnGhost
-- (UpdateGhost respawns missing bodies, ReconcileGhosts recycles into the
-- next packet's spawn), so save-load re-application comes free.
--
-- Toggle semantics: mp_ghost_isolate off gates application at spawn. The
-- dialog half has a clean removal (RestrictDialog(false), verified readable)
-- and off takes it on live ghosts. Persistent context options would NOT be
-- cleanly removable -- moot while no setter exists; if one appears, off must
-- not pretend to strip them.
function KCD2MP_ApplyGhostIsolation(id, stage)
    if not KCD2MP.ghostIsolate then return end
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end
    if stage == "settle" and ghost.isolated then return end  -- spawn pass already landed
    local e = ghost.entity
    if type(e.soul) ~= "table" then
        mp_log("Isolate[" .. tostring(id) .. "] " .. tostring(stage)
            .. ": soul not ready -- settle pass will retry")
        return
    end

    -- Context half. setCtx stays nil on this build (probe: no setter).
    local setCtx = nil
    if type(Contexts) == "table" and type(Contexts.SetPersistentOption) == "function" then
        setCtx = function(ctx)
            local okSet = pcall(function() Contexts.SetPersistentOption(e, ctx, "KCDMPGhost") end)
            if not okSet then return "call-failed" end
            local has = nil
            pcall(function() has = e.soul:HasScriptContext(ctx) end)
            if has == true then return "applied-and-verified" end
            return "applied-but-not-readable"
        end
    end
    -- WO-68: the contexts are applied NATIVELY now. KCDMP.dll owns that half
    -- (script_context.cpp, driven by the agent off this ghost's spawn-time
    -- "ghostid" event over pipe 0x07), because WO-68 Phase 0 found the applier
    -- is C_ScriptContextManager in WHGame.dll with no Lua binding anywhere.
    -- The per-context readback lives in the native log; from here the honest
    -- statement is which side owns it. The generic setter hook below still
    -- lights up if a future patch ever ships Contexts.SetPersistentOption.
    for _, ctx in ipairs(KCD2MP.isolationContexts) do
        local verdict = setCtx and setCtx(ctx) or "native (KCDMP.dll, see SCTX lines)"
        mp_log("Isolate[" .. tostring(id) .. "] " .. ctx .. ": " .. verdict)
    end

    -- Dialog half (live-verified writes).
    --
    -- WO-90: the readback takes the ASKER's entity id. It was being called
    -- with no argument, which the engine rejected at every single ghost spawn
    -- on all three machines of the 2026-09-12 session:
    --   [Warning] Validator: [Script Error] Wrong parameter type. Function
    --   .IsDialogRestricted() expect parameter 1 of type Pointer
    --   (Provided type Null)  > ... (scripts/startup/kdcmp.lua: 7178)
    -- The pcall swallowed it, isR stayed nil, and the line still printed
    -- "applied-but-not-readable" -- so the "verified" half of this check has
    -- never actually run. The game's own use is the reference:
    -- Scripts/Entities/AI/Shared/BasicAIActions.lua asks
    -- `self.soul:IsDialogRestricted(player.id)` on the NPC being approached,
    -- and returns a disabled talk hint when it is true. Restriction is
    -- directional -- it gates being spoken TO by a given asker -- so "is this
    -- body restricted against the local player" is the only question worth
    -- asking here, and it is the one that decides whether the ghost can be
    -- talked to.
    local okR = pcall(function() e.soul:RestrictDialog(true) end)
    local isR = nil
    pcall(function() isR = e.soul:IsDialogRestricted(player and player.id) end)
    mp_log("Isolate[" .. tostring(id) .. "] RestrictDialog(true): ok=" .. tostring(okR)
        .. " readback=" .. tostring(isR)
        .. (isR == true and " (applied-and-verified)" or " (applied-but-not-readable)"))
    if type(e.human) == "table" then
        local okI = pcall(function() e.human:InterruptDialogs() end)
        mp_log("Isolate[" .. tostring(id) .. "] InterruptDialogs(): ok=" .. tostring(okI)
            .. " (no readback exists -- one-shot)")
    end
    ghost.isolated = true
end

-- mp_ghost_isolate on|off. on: applies to every live ghost immediately and
-- future spawns. off: future spawns skip isolation, and the dialog half is
-- cleanly removed from live ghosts (RestrictDialog(false) + readback).
function KCD2MP_SetGhostIsolate(arg)
    local s = tostring(arg or ""):lower()
    local on
    if s:find("on") then on = true
    elseif s:find("off") then on = false
    else
        System.LogAlways("[KCD2-MP] mp_ghost_isolate: expected on|off (currently "
            .. (KCD2MP.ghostIsolate and "on" or "off") .. ")")
        return
    end
    KCD2MP.ghostIsolate = on
    -- WO-68: one switch, two halves. The context half is native (no Lua setter
    -- exists on this build), so the toggle has to reach the agent, which drives
    -- KCDMP.dll's applier over pipe 0x07 for every ghost standing right now.
    KCD2MP_EmitEvent("isolate", on and "on" or "off")
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost and ghost.entity then
            if on then
                ghost.isolated = nil
                KCD2MP_ApplyGhostIsolation(id, "toggle")
            else
                ghost.isolated = nil
                pcall(function() ghost.entity.soul:RestrictDialog(false) end)
                local isR = nil
                -- WO-90: same malformed readback as the apply half above.
                pcall(function() isR = ghost.entity.soul:IsDialogRestricted(player and player.id) end)
                mp_log("Isolate[" .. tostring(id) .. "] RestrictDialog(false): readback=" .. tostring(isR))
            end
            n = n + 1
        end
    end
    System.LogAlways("[KCD2-MP] ghostIsolate=" .. tostring(on) .. " (touched " .. n .. " live ghosts)")
end

-- ===== Spawn NPC with custom armor =====

-- Preset table (name -> {items, preset})
KCD2MP.armorPresets = {
    ghost = {
        items  = "00b7ed62-a7bd-4269-acfa-8d852366579b,10ff6d35-8c14-4871-8656-bdc3476d8b12",
        preset = "dc000001-0000-0000-0000-000000000000",
    },
    -- White/Red: LegsBrigandine04 + LegsPadded01 + knackersGloves + GambesonLong01
    -- + Brigandine10 + ArmPlate04 + CoifMail01 + BascinetVisor05 + BootsKnee03
    -- weapon: kkut_menhart preset (sermiry_longSwordMenhart)
    white_red = {
        items  = "a8b22da0-e42e-4d79-abe7-52e6eebad6eb"  -- LegsBrigandine04_m04_A5 (spodnie)
              .. ",cc1adb78-fa5a-45c9-be7b-b7b50e182cb3"  -- LegsPadded01_m02_C3 (nogawice)
              .. ",36a701ed-2144-452a-b113-385efba2c0d1"  -- rasuvUcen_knackersGloves
              .. ",46b051c4-d4e2-4f3a-8b88-e3f64dae4618"  -- GambesonLong01_m03_C3 (przeszywanica)
              .. ",1aadf1e5-c37b-41c3-bc65-354187022c91"  -- Brigandine10_m09_A5 (plate armor)
              .. ",a5322fcd-27b4-4f4e-bfbf-49c519c74c74"  -- ArmPlate04_m08_A5 (naramienniki)
              .. ",cfc1fd72-dbb7-49a4-8713-6acf215a72be"  -- CoifMail01_m02_C2 (coif mail)
              .. ",b6fe59ec-c854-402a-848e-a77f55661c19"  -- BascinetVisor05_m04_C4 (bascinet)
              .. ",a06cfbf0-3d59-4003-89d4-69a82eb735af", -- BootsKnee03_m01_C (buty)
        preset  = "dc000003-0000-0000-0000-000000000000",
        weapons = "af2dd849-92a4-4081-9955-0afcb861fcd5", -- kkut_menhart (sermiry_longSwordMenhart)
    },
    -- LegsPadded01(pikowane) + GambesonShort01 + CoifMail02 + MailShort01
    -- + Cuirass07 + ArmPlate04 + Gauntlets08 + LegsPlate03 + BascinetVisor04
    -- + longSwordDuel (inventory only) - no boots
    knight = {
        items  = "078e439b-1a5b-40ca-b009-d4abf6fcf810"  -- LegsPadded01_m07_C3 (pikowane)
              .. ",00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
              .. ",0b383bf7-a67b-4caa-9db8-501ed8d6aa9f"  -- CoifMail02_mPrague_B3
              .. ",0364c89d-ac13-44ef-94d5-22b4047e7a26"  -- MailShort01_m03_C4
              .. ",a8723887-ac6e-45a0-a6a4-0cf905716b6d"  -- Brigandine05_m04_C3 (silesian body)
              .. ",dcc178b9-ed1c-41c4-b2e7-ebda930e8af9"  -- BrigandineArm05_m11_B4 (silesian)
              .. ",2dd6ea92-4024-4113-97ed-6a23f19b39d9"  -- Gauntlets08_m01_B4
              .. ",1972ac07-f8e1-41f0-9fb4-cf115b0088ec"  -- LegsPlate03_m03_A5
              .. ",96841ac9-4cdc-41e7-a84e-d212389a0d71"  -- BascinetVisorScaring_m01_closed
              .. ",00cca9e3-8ef2-46db-8cbf-86ec51930919", -- longSwordDuel (inventory)
        preset = "dc000002-0000-0000-0000-000000000000",
    },
}

-- ===== WO-20 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â deterministic face roster (guidSharedSoulId) =====
--
-- The appearance lever -- binding a spawned NPC's guidSharedSoulId spawn
-- property to a real soul's SharedSoulGuid, which makes the engine build a
-- full distinct head+body+hair+beard automatically -- is Jefferson25625's
-- find (AppearanceApi.md, github.com/DeepFriedDepp/kcd2-exports fork, used
-- with permission). Confirmed live against this project's own build
-- (docs/WO-20-faces.md), not trusted from their doc.
--
-- Their own soul_roster.lua (the actual 48-soul GUID list) was never
-- committed to the repo -- prose only, same pattern WO-18 found for their
-- whole C# stack. So this roster is our own: real, hand-placed souls pulled
-- live from this save's own SoulsByName and spread across settlements for
-- visual variety. SharedSoulGuid is the authored, cross-session-stable key
-- (NATIVE-PLUGIN-findings.md), so these values hold regardless of which save
-- or session picks them.
--
-- WO-69: it is now 19, all male. The 24-entry female table is gone -- see
-- KCD2MP_PickFaceForPlayer below for why (every player character in KCD2 is
-- Henry, so a female ghost was always wrong, and WO-23 established that zero
-- female combat armour exists in Warhorse's catalog, so gear sync could not
-- render on one either). All 19 male SharedSoulGuids below were read back
-- live from a running build during WO-69 and matched 19/19 -- observed, so
-- H2 (an unresolvable roster soul falling back to a default body) is ruled
-- out for the shipped roster, not merely assumed.
--
-- WO-83: seven of those 19 were AUTHORITY souls -- social classes whose
-- soul_crime_role_id is 2 ("soldier": guard 101 x3, soldier_crimeAuthority
-- 108 x3, huntsman_crimeAuthority 110 x1), read off Libs/Tables/rpg/
-- soul__*.xml -> social_class.xml -> soul_crime_role.xml. Such a soul
-- ENFORCES crime.xml's drawnWeapon crime: a ghost built from ttac_man_9 was
-- observed in the field speaking the guard "sees player with a drawn weapon"
-- bark 13 times and then fighting, while the other player's ghost
-- (ttro_man_59, class 33, crime role 1) never did (docs/WO-83-findings.md).
-- The lever is the class's crime role, not the faction name: ttkc_bailiffSon
-- (commonFolk faction, guard class) barks it; ttro_man_59 (soldiers_guards
-- faction, soldier class) does not.
--
-- Fixed by REPLACING those seven slots in place with commoners that are
-- already in this list (all 19 were REST-verified live in WO-69), NOT by
-- deleting them: the picker's modulus is #list, so a shorter list re-rolls
-- every player's face (WO-34 paid that price once). Twelve slots are
-- byte-identical; only players whose key landed on an authority slot
-- change, and they change to a live-verified commoner. Distinct faces go
-- from 19 to 12; fresh commoner candidates for widening the roster again
-- are listed in docs/WO-83-findings.md and need a live REST read first.
--
-- WO-34: it was 48 (24 male, 24 female) and it then became 43 (19 male, 24
-- female). Five of the male entries were NOT commoners -- tbuk_man_5,
-- tkop_man_1, tkop_man_2, tzda_man_6 and tzda_man_9 were bandits, and are
-- gone. Read off the shipped tables, not inferred:
--
--   soul__tkop.xml   factionName = trosecko_enemies_bandits_campKopanina
--                    social_class_id = 38  voice_group_name = Bandits
--   social_class.xml 38 -> social_class_name "bandit", soul_crime_role_id 3
--   soul_crime_role  3  -> "renegade"
--   FactionTree.xml  ancestor trosecko_enemies carries Labels="publicEnemy"
--                    and reputation="-1" toward every trosecko settlement,
--                    outskirt, miller and ally faction
--   text_ui_soul.xml soul_ui_name_ruffian -> "Ruffian"
--
-- Until WO-22 this was harmless: the GUID was passed nested under Properties
-- and bound no soul at all, so the roster was decorative and the faction
-- never applied. WO-22 made SharedSoulGuid a real top-level parameter, which
-- turned five of these slots into genuinely hostile public enemies. Live
-- two-player report (WO-34): players hostile to each other on sight, one
-- attacked by ambient NPCs, bandit combat barks, and a corpse labelled
-- "Ruffian". KCD2MP_SpawnGhost's AI.ChangeParameter(..., "Civilians")
-- override does not defeat the soul row.
--
-- Removing rather than replacing takes the male #list from 24 to 19, and
-- KCD2MP_PickFaceForPlayer's modulus is over #list, so EVERY male player's
-- face changes with this build, not only the five. Accepted deliberately
-- (see docs/WO-34-findings.md); appearance stability across a version was
-- already broken once by WO-22 for the same underlying reason.
KCD2MP.faceRoster = {
    male = {
        {"tpod_man_1",   "4e628918-2a38-c1ea-c786-2424123506ae"}, -- WO-83: was tneb_man_11 (soldier_crimeAuthority)
        {"tsem_man_21",  "4072c96a-3bb5-f744-078c-8ef89203a49c"}, -- WO-83: was tneb_man_18 (soldier_crimeAuthority)
        {"tpod_man_1",   "4e628918-2a38-c1ea-c786-2424123506ae"},
        {"tpod_man_5",   "4f45df7c-4667-77a0-a415-d03b0cd1e293"},
        {"tsem_man_21",  "4072c96a-3bb5-f744-078c-8ef89203a49c"},
        {"tsem_man_22",  "46356c7b-ab60-1377-e8e4-514c8a8dcfbb"},
        {"tsla_man_2",   "4166b913-6b12-1965-cbb6-509a49250ba6"},
        {"ttac_man_8",   "fd1af8c5-c500-4add-b0b6-6c0505fe80c2"},
        {"ttkc_man_26",  "cfa65480-f361-4cf8-80c5-1900b7846bc8"}, -- WO-83: was ttac_man_9 (guard) -- the field report
        {"ttkc_man_26",  "cfa65480-f361-4cf8-80c5-1900b7846bc8"},
        {"tzel_man_10",  "8158f557-018e-4016-95a4-024bb060bd18"}, -- WO-83: was ttkc_man_3 (guard)
        {"tvid_man_3",   "48ea5c5c-fcbb-6a90-be4d-8b7f7ad6a4ac"}, -- WO-83: was ttro_man_30 (soldier_crimeAuthority)
        {"ttro_man_59",  "7e4881d6-ffb7-416f-bbbe-49bc622747b2"},
        {"tvez_man_20",  "2f825ed0-1d9b-4df0-ad90-d6e2b136ce04"},
        {"tvez_man_21",  "4badc882-824c-407e-b823-059fa3e5df5b"},
        {"tvid_man_3",   "48ea5c5c-fcbb-6a90-be4d-8b7f7ad6a4ac"},
        {"tvez_man_20",  "2f825ed0-1d9b-4df0-ad90-d6e2b136ce04"}, -- WO-83: was tvid_man_7 (huntsman_crimeAuthority)
        {"tzel_man_10",  "8158f557-018e-4016-95a4-024bb060bd18"},
        {"tsla_man_2",   "4166b913-6b12-1965-cbb6-509a49250ba6"}, -- WO-83: was tzel_man_7 (guard)
    },
}

-- djb2-style string hash. Pure +/*/% arithmetic, deliberately no bitwise
-- ops -- this mod's sandbox is stripped Lua 5.1, which has no bit library.
--
-- WO-20 correction, found live: this engine's embedded Lua uses 32-bit
-- FLOAT numbers, not doubles -- confirmed by probing KCD2MP_HashString with
-- a %2147483647 modulus (the obvious choice) and watching tostring(h) print
-- in scientific notation ("1.93453e+08") with the low digits already gone,
-- which then made "h % 2" parity flip unpredictably and sent every test
-- name to the same roster slot (or an out-of-range one). Float32 is only
-- exact for integers up to 2^24 (~16.7M), so every intermediate value here
-- is kept under a 65521 modulus (largest prime below 2^16) -- h*33 then
-- tops out around 2.16M, safely inside the exact range.
function KCD2MP_HashString(s)
    local h = 5381 % 65521
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 65521
    end
    return h
end

-- Deterministic per-player face pick: same name key -> same soul, every
-- time, in this or any future session.
--
-- WO-69: gender is no longer derived from the hash. It used to be
-- `isFemale = (h % 2) == 0`, which made half of all name keys resolve to a
-- female body -- and every KCD2 player character is Henry, so that half was
-- wrong by construction, not by accident. The field report ("the host's
-- ghost often spawns as a female NPC") is this line, working exactly as
-- written: the tester's host nick hashes to 46000, which is even, so his
-- ghost was female on all four spawns of the reported session -- observed,
-- not inferred (docs/WO-69-findings.md). WO-58 had already fixed a *second*,
-- independent path to the same symptom (the "Player<id>" fallback key, whose
-- hash is also even for odd ids); that fix is intact and did not cover this.
--
-- Deliberately NOT changed: the hash, the `math.floor(h / 2)` term, and the
-- male table's contents and order. `#list` was already 19 here (the gender
-- branch chose the list BEFORE the modulus), so every player whose hash is
-- odd -- everyone who was already rendering correctly -- keeps the exact
-- same face across this upgrade. Only the ~50% who were rendering as women
-- change, and they change from a wrong body to a right one. Reordering or
-- "tidying" the male table would re-roll all 19 and break that property.
--
-- WO-83 kept that property the only way a fix can: same 19 slots, same
-- order, seven entries swapped in place. Recomputed with this exact
-- arithmetic: 8/8 keys that sat on an untouched slot resolve to the same
-- soul as before; keys on the seven authority slots move to a commoner.
function KCD2MP_PickFaceForPlayer(nameKey)
    local h = KCD2MP_HashString(tostring(nameKey or ""))
    local list = KCD2MP.faceRoster.male
    local idx = (math.floor(h / 2) % #list) + 1
    local pick = list[idx]
    return { className = "NPC", soulName = pick[1], guid = pick[2] }
end

-- WO-69: the deterministic fallback for a spawn that resolves to something
-- other than what was asked for. One specific, always-loaded male commoner --
-- never the engine's own default body, which is what a discarded
-- SharedSoulGuid silently produces (WO-22). Kuttenberg is the largest
-- always-streamed settlement in the game, and this soul's SharedSoulGuid was
-- read back live from a running build during WO-69 (19/19 male roster souls
-- resolved). WO-83: it WAS ttkc_man_3 (roster slot 11), which turned out to be
-- social class 101 "guard", crime role 2 -- an authority soul, the exact
-- defect WO-83 removes. Now ttkc_man_26 (roster slot 10, varlet, crime role
-- 1), the WO-34 live control that read back as "Hired hand".
KCD2MP.faceFallback = { className = "NPC", soulName = "ttkc_man_26",
                        guid = "cfa65480-f361-4cf8-80c5-1900b7846bc8" }

-- WO-100.5 Phase 0: the one place that decides a ghost's entity class.
-- Every spawn site calls this rather than reading facePick.className, so the
-- toggle cannot be half-applied (the spawn, the System.SpawnEntity fallback,
-- the fallback respawn and the spawn-verify comparison all agree by
-- construction). Only "NPC" is swapped: NPC_NAI has no female variant in this
-- build, so anything else passes through untouched.
function KCD2MP_GhostClassName(baseClass)
    local c = tostring(baseClass or "NPC")
    if KCD2MP.ghostNai and c == "NPC" then return "NPC_NAI" end
    return c
end

-- mp_ghost_nai on|off. Argless commands only: the console drops arguments
-- (live-verified -- "mp_x 35" answers "Too many arguments" and a bare call
-- passes the literal %LINE), so every toggle since WO-17 that took on|off
-- only ever worked as #Lua. These do not.
--
-- The class is chosen at spawn, so a flip does not move live ghosts; it takes
-- effect on the next spawn. Stated in the log rather than silently true.
function KCD2MP_SetGhostNai(on)
    KCD2MP.ghostNai = on and true or false
    local n = 0
    for _ in pairs(KCD2MP.ghosts or {}) do n = n + 1 end
    System.LogAlways(string.format(
        "[KCD2-MP] mp_ghost_nai=%s -- requested class is now %s."
        .. " %d ghost(s) already in the world keep the class they were built with.",
        tostring(KCD2MP.ghostNai), KCD2MP_GhostClassName("NPC"), n))
    if KCD2MP.ghostNai then
        -- Said every time it is switched on, because it is the opposite of
        -- what the name promises and it was established live.
        System.LogAlways(
            "[KCD2-MP] mp_ghost_nai WARNING: XGenAIModule.SpawnEntity -- the ghost path's"
            .. " PRIMARY spawn -- builds class NPC whatever ClassName says (live 2026-09-17,"
            .. " 3 of 3, with and without NoAI). So on the primary path this toggle changes"
            .. " NOTHING; it only bites on the System.SpawnEntity fallback. And where it does"
            .. " bite it is harmful: an NPC_NAI body registered 0 of N hits with the skirmish"
            .. " system. Use mp_ghost_noai_on instead -- see docs/WO-100.5-findings.md S1.")
    end
end

-- WO-100.5 Phase 2: mp_anim_legacy on|off, argless.
function KCD2MP_SetAnimLegacy(on)
    KCD2MP.animLegacy = on and true or false
    local a = KCD2MP._animStats
    System.LogAlways(string.format(
        "[KCD2-MP] mp_anim_legacy=%s -- ghost locomotion now comes from %s."
        .. " So far: applied=%d legacy=%d declined=%d rejected=%d",
        tostring(KCD2MP.animLegacy),
        KCD2MP.animLegacy and "the inferred packet speed (pre-0.23.1 behaviour)"
                           or "the peer's real Mannequin tags",
        a.applied, a.legacy, a.noBody, a.rejected))
end

-- WO-100.5 Phase 0: the toggle that actually works. See KCD2MP.ghostNoAi.
function KCD2MP_SetGhostNoAi(on)
    KCD2MP.ghostNoAi = on and true or false
    local n = 0
    for _ in pairs(KCD2MP.ghosts or {}) do n = n + 1 end
    System.LogAlways(string.format(
        "[KCD2-MP] mp_ghost_noai=%s -- new ghosts spawn %s a brain."
        .. " %d ghost(s) already in the world are unchanged; respawn them"
        .. " (mp_remove_all, or a reconnect) to apply this."
        .. " ON gives up WO-26 reactive self-defence and should remove the WO-98"
        .. " position tug-of-war; that half needs two machines to measure.",
        tostring(KCD2MP.ghostNoAi), KCD2MP.ghostNoAi and "WITHOUT" or "with", n))
end

-- Split "a,b,c" -> {"a","b","c"}, trims whitespace
local function splitCSV(s)
    local parts = {}
    for part in string.gmatch(s, "[^,]+") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

-- Spawn NPC in front of player, add items to inventory, optionally equip via ClothingPreset.
-- items_csv    : comma-separated item GUIDs (inventory)
-- preset_guid  : ClothingPreset GUID for visual equip (must exist in clothing_preset__kdcmp.xml)
-- weapon_preset: WeaponPreset GUID (from weapon_preset.xml) - equips weapon in hand slot
function KCD2MP_SpawnArmoredNPC(items_csv, preset_guid, weapon_preset)
    if not player then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: no player")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Spawn 3m in front of player
    local ox, oy = 3, 0
    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end
    local spawnPos = {x = pos.x + ox, y = pos.y + oy, z = pos.z}

    KCD2MP.spawnCount = (KCD2MP.spawnCount or 0) + 1
    local npcName = "kcd2mp_npc_" .. KCD2MP.spawnCount

    System.LogAlways(string.format("[KCD2-MP] SpawnArmoredNPC '%s' at %.1f,%.1f,%.1f",
        npcName, spawnPos.x, spawnPos.y, spawnPos.z))

    local npc = nil
    local ok1, e1 = pcall(function()
        npc = System.SpawnEntity({class="NPC", name=npcName, position=spawnPos})
    end)
    if not ok1 or not npc then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: SpawnEntity failed: " .. tostring(e1))
        return
    end
    System.LogAlways("[KCD2-MP] SpawnArmoredNPC: entityId=" .. tostring(npc.id))
    mp_set_no_save(npc)   -- WO-106 Phase 5: a mod test spawn, never save it

    -- Visually equip via ClothingPreset FIRST (may reset inventory state)
    if preset_guid and preset_guid ~= "" then
        local ok2, e2 = pcall(function()
            npc.actor:EquipClothingPreset(preset_guid)
        end)
        System.LogAlways("[KCD2-MP] EquipClothingPreset " .. preset_guid
            .. ": ok=" .. tostring(ok2)
            .. (ok2 and "" or (" err=" .. tostring(e2))))
    end

    -- Add items to inventory AFTER preset (so preset cannot wipe them)
    local guids = (items_csv and items_csv ~= "") and splitCSV(items_csv) or {}
    System.LogAlways("[KCD2-MP] Adding " .. #guids .. " items to inventory")
    for i, guid in ipairs(guids) do
        local ok, e = pcall(function()
            local item = ItemManager.CreateItem(guid, 1, 1)
            npc.inventory:AddItem(item)
        end)
        System.LogAlways(string.format("[KCD2-MP]   item[%d] %s: ok=%s%s",
            i, guid, tostring(ok), ok and "" or (" err=" .. tostring(e))))
    end

    -- Equip weapon via WeaponPreset (visual + inventory, works for swords/shields)
    if weapon_preset and weapon_preset ~= "" then
        local ok3, e3 = pcall(function()
            npc.actor:EquipWeaponPreset(weapon_preset)
        end)
        System.LogAlways("[KCD2-MP] EquipWeaponPreset " .. weapon_preset
            .. ": ok=" .. tostring(ok3)
            .. (ok3 and "" or (" err=" .. tostring(e3))))

        -- Close visor after short delay using native console command
        -- pattern from VIA mod: closeVisorOn <entityName>
        local npcNameRef = npcName
        Script.SetTimer(800, function()
            pcall(function()
                System.ExecuteCommand("closeVisorOn " .. npcNameRef)
                System.LogAlways("[KCD2-MP] closeVisorOn " .. npcNameRef)
            end)
        end)
    end

    mp_log(string.format("SpawnArmoredNPC '%s' items=%d preset=%s weapons=%s",
        npcName, #guids, tostring(preset_guid or "none"), tostring(weapon_preset or "none")))
end

-- Spawn white/red armored NPC (uses XML preset dc000003 + weapon preset kkut_menhart)
function KCD2MP_SpawnWhiteRed()
    local p = KCD2MP.armorPresets.white_red
    KCD2MP_SpawnArmoredNPC(p.items, p.preset, p.weapons)
end

-- Spawn fully armored knight (all 6 pieces, uses XML preset dc000002)
function KCD2MP_SpawnKnight()
    local p = KCD2MP.armorPresets.knight
    KCD2MP_SpawnArmoredNPC(p.items, p.preset)
end

-- ===== Horse Diagnostics =====

-- Runs in MOD context (has access to Terrain, player, etc).
-- Writes result to sv_servername so probe_riding.ps1 can read it.
function KCD2MP_DiagRideDetect()
    if not player then
        System.SetCVar("sv_servername", "player=nil")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then
        System.SetCVar("sv_servername", "GetWorldPos=nil")
        return
    end

    -- Find entities within 6m - list all classes to identify the horse
    local classes = {}
    pcall(function()
        local ents = System.GetEntitiesInSphere(pos, 6.0)
        if ents then
            for _, e in ipairs(ents) do
                if e ~= player then
                    local ec = "?"
                    local ep = nil
                    pcall(function() ec = tostring(e.class or "?") end)
                    if ec == "?" then pcall(function() ec = tostring(e:GetClass()) end) end
                    pcall(function() ep = e:GetWorldPos() end)
                    local d = ep and math.sqrt((ep.x-pos.x)^2+(ep.y-pos.y)^2+(ep.z-pos.z)^2) or 99
                    if d < 6 then
                        classes[#classes+1] = string.format("%s:%.1f", ec, d)
                    end
                end
            end
        end
    end)

    local clStr = table.concat(classes, " | ")
    if clStr == "" then clStr = "none" end
    -- Trim to fit CVar (max ~200 chars)
    if #clStr > 180 then clStr = clStr:sub(1,180) end
    System.SetCVar("sv_servername", clStr)
end

-- Probe ALL riding anim candidates on any ghost currently in riding state.
-- Shows which names have GetAnimationLength > 0.
-- Also tries to get current player animation name (for when player is on horse).
function KCD2MP_ProbeRidingAnims()
    -- Find first riding ghost
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do
        if g.istate and g.istate.isRiding then ghost = g; break end
    end
    -- Fall back to any ghost
    if not ghost then
        for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeRidingAnims: no ghost. Spawn one first.")
        return
    end

    System.LogAlways("[KCD2-MP] === PROBE RIDING ANIMS ===")
    local ent = ghost.entity
    local allCandidates = {}
    for _, v in ipairs(RIDING_IDLE_ANIMS)   do allCandidates[#allCandidates+1] = v end
    for _, v in ipairs(RIDING_GALLOP_ANIMS) do allCandidates[#allCandidates+1] = v end
    -- Extra patterns
    local extras = {
        "horse", "Horse", "riding", "Riding", "mounted", "Mounted",
        "3d_horse", "3d_riding", "3d_mounted",
        "horse_walk", "horse_run", "horse_idle", "horse_gallop",
        "act_horse", "act_riding", "act_mounted",
        "loco_horse", "loco_riding",
    }
    for _, v in ipairs(extras) do allCandidates[#allCandidates+1] = v end

    local hits = 0
    for _, name in ipairs(allCandidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] RIDING HIT: '%s' len=%.3f", name, len))
            hits = hits + 1
        end
    end
    System.LogAlways(string.format("[KCD2-MP] Riding anims found: %d / %d tested", hits, #allCandidates))

    -- Also try to read the current animation name from player (if riding a horse right now)
    local ok, an = pcall(function()
        if player then
            local n = nil
            pcall(function() n = player:GetCurrentAnimationName(0) end)
            return n
        end
    end)
    System.LogAlways("[KCD2-MP] Player current anim: " .. tostring(an) .. " (useful if player is on horse)")
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Find horse/animal entities near player and log their class names
function KCD2MP_FindHorses()
    if not player then System.LogAlways("[KCD2-MP] FindHorses: no player"); return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HORSES ===")

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 60)
        if not ents then System.LogAlways("[KCD2-MP] GetEntitiesInSphere returned nil"); return end

        local count = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                local eclass = "?"
                local ename  = "?"
                pcall(function() eclass = tostring(ent.class or "?") end)
                pcall(function() ename  = tostring(ent:GetName()) end)

                -- Log anything that looks like it could be a horse or animal
                local lc = eclass:lower()
                local ln = ename:lower()
                if lc:find("horse") or lc:find("animal") or lc:find("mount") or lc:find("creature")
                   or ln:find("horse") or ln:find("roach") or ln:find("pebbles") or ln:find("animal")
                then
                    local pos = nil
                    pcall(function() pos = ent:GetWorldPos() end)
                    local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or -1
                    System.LogAlways(string.format("[KCD2-MP] HORSE? class='%s' name='%s' dist=%.1fm",
                        eclass, ename, dist))
                    count = count + 1
                end
            end
        end

        -- Also just log ALL entity classes within 15m (to catch horses with unexpected class names)
        System.LogAlways("[KCD2-MP] --- All entities within 15m ---")
        for _, ent in ipairs(ents) do
            local eclass = "?"
            local ename  = "?"
            pcall(function() eclass = tostring(ent.class or "?") end)
            pcall(function() ename  = tostring(ent:GetName()) end)
            local pos = nil
            pcall(function() pos = ent:GetWorldPos() end)
            local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or 99
            if dist < 15 then
                System.LogAlways(string.format("[KCD2-MP]   class='%s' name='%s' dist=%.1fm",
                    eclass, ename, dist))
            end
        end
        System.LogAlways(string.format("[KCD2-MP] Horse-like entities found: %d", count))
    end)
    if not ok then System.LogAlways("[KCD2-MP] FindHorses error: " .. tostring(err)) end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Force-spawn a horse using several class name guesses to find what works in KCD2
function KCD2MP_SpawnHorseTest()
    if not player then System.LogAlways("[KCD2-MP] SpawnHorseTest: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Offset 4m to the right of player
    local spawnPos = {x = pos.x + 4, y = pos.y, z = pos.z}

    local classes = {
        "Horse", "Animal", "HorseAnimal", "horse", "animal",
        "kcd_horse", "RPGHorse", "CreatureAnimal", "Creature",
    }

    System.LogAlways("[KCD2-MP] === SPAWN HORSE TEST ===")
    for _, cls in ipairs(classes) do
        local ok, ent = pcall(System.SpawnEntity, {
            class    = cls,
            position = spawnPos,
            name     = "kcd2mp_horsetest_" .. cls,
        })
        if ok and ent then
            System.LogAlways(string.format("[KCD2-MP] SUCCESS class='%s' entityId=%s", cls, tostring(ent.id)))
            mp_set_no_save(ent)   -- WO-106 Phase 5: a mod test spawn, never save it
            -- Don't remove it - let user see which one appears in-game
        else
            System.LogAlways(string.format("[KCD2-MP] FAIL class='%s' err=%s", cls, tostring(ent)))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Log current riding detection state for the local player
function KCD2MP_RidingState()
    System.LogAlways("[KCD2-MP] === RIDING STATE ===")
    System.LogAlways("[KCD2-MP] KCD2MP.isRiding = " .. tostring(KCD2MP.isRiding))

    if not player then System.LogAlways("[KCD2-MP] player=nil"); return end

    -- Test method 1: human:IsRiding
    local ok1, r1 = pcall(function()
        if player.human then
            return player.human:IsRiding()
        end
        return "human=nil"
    end)
    System.LogAlways("[KCD2-MP] human:IsRiding() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))

    -- Test method 2: GetLinkedParent
    local ok2, r2 = pcall(function() return player:GetLinkedParent() end)
    System.LogAlways("[KCD2-MP] GetLinkedParent() ok=" .. tostring(ok2) .. " val=" .. tostring(r2))

    -- Test method 3: soul state
    local ok3, r3 = pcall(function()
        if player.soul then return player.soul.bRiding end
        return "soul=nil"
    end)
    System.LogAlways("[KCD2-MP] soul.bRiding ok=" .. tostring(ok3) .. " val=" .. tostring(r3))

    -- Test method 4: actor mount
    local ok4, r4 = pcall(function()
        if player.actor then return player.actor:GetMount() end
        return "actor=nil"
    end)
    System.LogAlways("[KCD2-MP] actor:GetMount() ok=" .. tostring(ok4) .. " val=" .. tostring(r4))

    System.LogAlways("[KCD2-MP] === END ===")
end

function KCD2MP_GhostState()
    System.LogAlways("[KCD2-MP] === GHOST STATE ===")
    local count = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        count = count + 1
        local istate = ghost.istate or {}
        local horseData = KCD2MP.horseGhosts[id]
        System.LogAlways(string.format(
            "[KCD2-MP] Ghost id=%s isRiding=%s nativeMounted=%s ridingFallback=%s hasHorse=%s",
            tostring(id),
            tostring(istate.isRiding),
            tostring(istate.nativeMounted),
            tostring(istate.ridingFallback),
            tostring(horseData ~= nil)
        ))
        -- Check if NPC has .human and if IsMounted works
        if ghost.entity then
            local ok, mounted = pcall(function() return ghost.human and ghost.human:IsMounted() end)
            System.LogAlways("[KCD2-MP]   IsMounted ok=" .. tostring(ok) .. " val=" .. tostring(mounted))
            -- Check if horse entity exists
            if horseData and horseData.entity then
                local ok2, hasRider = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:HasRider()
                end)
                local ok3, isMountable = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:IsMountable()
                end)
                System.LogAlways("[KCD2-MP]   horse.HasRider ok=" .. tostring(ok2) .. " val=" .. tostring(hasRider))
                System.LogAlways("[KCD2-MP]   horse.IsMountable ok=" .. tostring(ok3) .. " val=" .. tostring(isMountable))
            end
        end
    end
    System.LogAlways("[KCD2-MP] Total ghosts=" .. count .. " horseGhosts=" .. (function()
        local n=0; for _ in pairs(KCD2MP.horseGhosts) do n=n+1 end; return n
    end)())
end

-- ===== WO-38 Phase 7: ghost stimulus-deafness probe =====
-- Section B.1: a ghost's soul-assigned voice set fires real combat-distress
-- barks ("HELP! GET ME OUT OF HERE") that never stop -- plausibly because the
-- distress behaviour wants the body to flee and the interp tick pins it in
-- place, so the state never resolves. AI.SetIgnorant(entityId, 0|1) is
-- REGISTERED on this build (WO-32 s1f: "ignore system signals, visual and
-- sound stimuli") and is the obvious lever -- but it might also stop the
-- ghost being a valid combat TARGET, which would silently regress the
-- always-on reactive combat WO-26/27 shipped. So it ships as a toggle for a
-- live A/B, not as a default: turn it on, start a fight near a ghost, and
-- check (a) the barks stop and (b) NPCs still attack the ghost.
-- Usage: mp_ghost_ignorant on|off
function KCD2MP_SetGhostsIgnorant(arg)
    local s = tostring(arg or ""):lower()
    local on
    if s:find("on") then on = 1
    elseif s:find("off") then on = 0
    else
        System.LogAlways("[KCD2-MP] mp_ghost_ignorant: expected on|off")
        return
    end
    KCD2MP.ghostsIgnorant = (on == 1)
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local ok, err = pcall(function() AI.SetIgnorant(ghost.entity.id, on) end)
            System.LogAlways(string.format("[KCD2-MP] SetIgnorant(%s, %d) ok=%s err=%s",
                tostring(id), on, tostring(ok), tostring(err)))
            n = n + 1
        end
    end
    System.LogAlways("[KCD2-MP] mp_ghost_ignorant " .. s .. " applied to " .. n .. " ghost(s)"
        .. " -- new spawns " .. (KCD2MP.ghostsIgnorant and "WILL" or "will NOT") .. " get it")
end

-- WO-59 Thread C: re-assert stimulus-deafness on every live ghost. Called by
-- the agent on the same 2.5 s re-arm cadence as StartInterp/SetGhostName.
-- SetIgnorant was applied exactly once at spawn with its pcall result thrown
-- away; if that one call failed, or the engine dropped the flag somewhere no
-- doc covers, the ghost's brain was a full crime witness for the rest of the
-- session with zero evidence trail (the field report: a ghost catching a
-- sneaking player mid-theft, barking the authored catch line, and killing
-- them). Re-asserting is one flag write per ghost; the engine treats a
-- same-value write as a no-op, and a FAILURE is logged once per ghost id so
-- a field bundle finally shows whether this lever works when it matters.
function KCD2MP_ReassertGhostIgnorance()
    if not KCD2MP.ghostsIgnorant then return end
    KCD2MP._ignorantFailLogged = KCD2MP._ignorantFailLogged or {}
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local ok, err = pcall(function() AI.SetIgnorant(ghost.entity.id, 1) end)
            if not ok and not KCD2MP._ignorantFailLogged[id] then
                KCD2MP._ignorantFailLogged[id] = true
                System.LogAlways("[KCD2-MP] ReassertGhostIgnorance: SetIgnorant FAILED for ghost "
                    .. tostring(id) .. " err=" .. tostring(err))
            elseif ok and KCD2MP._ignorantFailLogged[id] then
                KCD2MP._ignorantFailLogged[id] = nil
                System.LogAlways("[KCD2-MP] ReassertGhostIgnorance: SetIgnorant recovered for ghost " .. tostring(id))
            end
        end
    end
end

-- ===== WO-40 Phase 9: hostility remediation + faction-bind probe =====
-- The footage's pickpocket incident left PB's ghost persistently hostile to
-- PA (aggro indicator + forced combat stance long after). Ignorant-by-default
-- prevents NEW incidents; this clears an already-aggroed ghost, and reports
-- the registration state of the per-pair hostility binds the retail-1.5 dump
-- says exist (AI.GetFactionOf was previously dismissed on a guessed
-- signature -- project memory corrected this WO).
function KCD2MP_GhostCalm()
    System.LogAlways("[KCD2-MP] AI.GetFactionOf="            .. tostring(AI and type(AI.GetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.SetFactionOf="            .. tostring(AI and type(AI.SetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.AddPersonallyHostile="    .. tostring(AI and type(AI.AddPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.RemovePersonallyHostile=" .. tostring(AI and type(AI.RemovePersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.IsPersonallyHostile="     .. tostring(AI and type(AI.IsPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.ResetPersonallyHostiles=" .. tostring(AI and type(AI.ResetPersonallyHostiles)))
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            n = n + 1
            if AI and type(AI.IsPersonallyHostile) == "function" and player then
                local ok, hostile = pcall(function() return AI.IsPersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s IsPersonallyHostile(player) ok=%s -> %s",
                    tostring(id), tostring(ok), tostring(hostile)))
            end
            -- Live-verified 2026-08-20: the engine's own parameter-check
            -- error revealed the real signature -- ResetPersonallyHostiles
            -- (entityID, hostileID), two args like Remove. Both called
            -- pairwise against the local player.
            if AI and type(AI.ResetPersonallyHostiles) == "function" and player then
                local ok, err = pcall(function() return AI.ResetPersonallyHostiles(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s ResetPersonallyHostiles(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
            if AI and type(AI.RemovePersonallyHostile) == "function" and player then
                local ok, err = pcall(function() return AI.RemovePersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s RemovePersonallyHostile(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to calm") end
end

-- ===== WO-38 Phase 8: map marker probe =====
-- The shipped scriptbind docs document GameRules.AddMinimapEntity(entityId,
-- type, lifetime) / RemoveMinimapEntity(entityId) -- exactly the shape a
-- "show connected players on the map" feature needs, because each ghost is
-- already a real local entity whose position the mod keeps synced; marking
-- the ENTITY means the map marker moves for free. But this is a Crysis-era
-- GameRules bind against KCD2's custom Warhorse map UI, and this project has
-- already met documented-but-unregistered binds (Actor.SetAIBrainId, WO-32)
-- and registered-but-inert ones (most AI writes). So the feature ships as a
-- PROBE first: run `mp_map_marker <type>` live with a ghost present, open
-- the map, and see. If a type value renders, wiring it into SpawnGhost is a
-- three-line follow-up.
-- Usage: mp_map_marker <typeInt>   (tries that icon type on every ghost)
--        mp_map_marker sweep       (tries types 0..15, one per ghost re-add)
function KCD2MP_ProbeMapMarker(arg)
    local hasBind = (GameRules ~= nil) and (type(GameRules.AddMinimapEntity) == "function")
    System.LogAlways("[KCD2-MP] MapMarker probe: GameRules.AddMinimapEntity registered=" .. tostring(hasBind))
    if not hasBind then return end

    local types = {}
    if tostring(arg or ""):lower() == "sweep" then
        for t = 0, 15 do types[#types+1] = t end
    else
        types[1] = tonumber(arg) or 1
    end

    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            for _, t in ipairs(types) do
                local ok, err = pcall(function()
                    GameRules.AddMinimapEntity(ghost.entity.id, t, 0)
                end)
                System.LogAlways(string.format("[KCD2-MP] MapMarker ghost=%s type=%d ok=%s err=%s",
                    tostring(id), t, tostring(ok), tostring(err)))
            end
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] MapMarker probe: no ghosts to mark -- connect a peer first") end
end

-- Test spawning entities via XGenAIModule with various class names.
-- Safe: each class wrapped in pcall, entity removed after 10s.
-- Usage: mp_test_xgen <ClassName>  (default: NullAI)
function KCD2MP_TestXGenSpawn(className)
    if not player then System.LogAlways("[KCD2-MP] TestXGenSpawn: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    className = (className and className ~= "") and className or "NullAI"
    local testName = "kcd2mp_xgen_test"
    System.LogAlways("[KCD2-MP] TestXGenSpawn: trying ClassName=" .. className)

    -- Remove previous test entity if exists
    pcall(function()
        local old = System.GetEntityByName(testName)
        if old then System.RemoveEntity(old.id) end
    end)

    -- Try XGenAIModule.SpawnEntity
    local ok, err = pcall(function()
        local eid = XGenAIModule.SpawnEntity{
            Name      = testName,
            ClassName = className,
            Pos       = {pos.x + 2, pos.y, pos.z},
            Properties = { esFaction = "Civilians" },
        }
        System.LogAlways("[KCD2-MP] TestXGenSpawn: XGenAI returned eid=" .. tostring(eid))
        local ent = System.GetEntityByName(testName)
        if ent then
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity found id=" .. tostring(ent.id)
                .. " class=" .. tostring(ent.class))
            mp_set_no_save(ent)   -- WO-106 Phase 5: belt-and-braces -- this already self-removes in 10s
            -- Check human/actor/horse sub-objects
            local hasSoul   = pcall(function() return ent.soul end)
            local hasHuman  = pcall(function() return ent.human end)
            local isMounted = pcall(function() return ent.human and ent.human:IsMounted() end)
            System.LogAlways("[KCD2-MP] TestXGenSpawn: hasSoul=" .. tostring(hasSoul)
                .. " hasHuman=" .. tostring(hasHuman)
                .. " IsMounted=" .. tostring(isMounted))
            -- Remove after 10s
            local eid2 = ent.id
            Script.SetTimer(10000, function()
                pcall(function() System.RemoveEntity(eid2) end)
                System.LogAlways("[KCD2-MP] TestXGenSpawn: removed test entity")
            end)
        else
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity NOT found by name after spawn")
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] TestXGenSpawn: CRASHED/ERROR: " .. tostring(err))
    end
end

-- ===== Dropped-item sync (WO-48) =====
--
-- A player deliberately drops an item; peers see it appear, and whoever picks
-- it up first gets it -- for everyone. TRANSACTIONAL (the time-skip shape):
-- a drop broadcasts once, sits inert, and resolves on the first claim the
-- relay echoes back. No continuous stream, no authority to hand off. Chests
-- and NPC pockets are deliberately NOT synced (independent loot pools).
--
-- The reachable surface, all live-verified in WO-48 Phase 1:
--   detect:      new PickableItem entity near the player (GetEntitiesInSphere)
--                + that class's inventory count DECREASED since last tick --
--                both halves required, which is what filters out world items
--                streaming in and NPCs dropping things nearby.
--   identity:    Properties.sItemClassId (the WO-9 ItemClass GUID) + nAmount
--                + fHealth read straight off the ground entity. The dropId
--                itself is minted by the agent (random uint32) and handled as
--                a STRING here -- this Lua's floats corrupt integers > 2^24.
--   spawn:       inventory:CreateItem on a ghost + ghost.human:PlaceItem to a
--                throwaway anchor entity at the drop position. Placing while
--                the player was 60 m away dropped the item through unstreamed
--                ground (observed: z -217), so pending drops only materialize
--                inside materializeRadius.
--   pickup:      the tracked ground entity vanishing WITHOUT this mod having
--                removed it = something in this world took it. Removal by the
--                mod flags removedByUs first (the damage layer's loop-
--                prevention idiom, local state, never on the wire).
KCD2MP.itemSync = {
    enabled           = true,  -- mp_item_sync on|off (the mp_npc_sync default-on precedent)
    scanMs            = 750,   -- one tick: detector + materializer + watcher
    dropRadius        = 8,     -- metres: new-pickable detection around the player
    materializeRadius = 70,    -- metres: spawn a pending drop only this near
    watchRadius       = 80,    -- metres: existence checks only trusted this near
    maxTracked        = 32,    -- hard cap on live tracked drops
}
KCD2MP.itemSyncRunning  = false
KCD2MP._itemSyncAliveAt = nil
KCD2MP._itemRestartSweep = false
-- dropIdStr -> {cls, amount, health, x, y, z, src, mine, state, entName,
--               wuid, removedByUs, pendingRemove, placeTries}
-- state machine: pending -> placing -> ground -> resolved | claimed_local -> resolved
KCD2MP.itemDrops     = {}
KCD2MP._itemSeen     = {}   -- tostring(entity.id) -> true, pickables accounted for
KCD2MP._itemInvCounts = nil -- classGuidStr -> total amount, from last tick

local function mp_item_inv_counts()
    local counts = nil
    pcall(function()
        local t = player.inventory:GetInventoryTable()
        local c = {}
        for i = 1, #t do
            local it = ItemManager.GetItem(t[i])
            if it and it.class then c[it.class] = (c[it.class] or 0) + (it.amount or 1) end
        end
        counts = c
    end)
    return counts
end

local function mp_item_tracked_count()
    local n = 0
    for _, d in pairs(KCD2MP.itemDrops) do
        if d.state ~= "resolved" then n = n + 1 end
    end
    return n
end

-- Reload discriminator for the restart sweep. Any timer gap > 1 s lands in
-- KCD2MP_StartItemSync's restart path, but a menu gap and a save load need
-- opposite handling: a menu leaves the world intact (and the player can drop
-- items from the inventory screen DURING it, which must still be detected on
-- resume), while a reload replaces every runtime entity and rewinds the
-- inventory (which would fake both halves of the detector's gate). A healthy
-- ghost entity proves no reload happened; a stale one proves it did. With no
-- ghost to judge by, assume menu -- with no peers connected a wrong guess
-- has nobody to mislead.
local function mp_item_world_reloaded()
    for _, g in pairs(KCD2MP.ghosts or {}) do
        if g.entity then
            local alive = false
            pcall(function() alive = System.GetEntityByName(g.entity:GetName()) ~= nil end)
            return not alive
        end
    end
    return false
end

local function mp_item_detect(pp)
    local counts = mp_item_inv_counts()
    local prev = KCD2MP._itemInvCounts
    if counts then KCD2MP._itemInvCounts = counts end
    local ents = System.GetEntitiesInSphere(pp, KCD2MP.itemSync.dropRadius) or {}
    for _, e in ipairs(ents) do
        if e.class == "PickableItem" then
            local key = tostring(e.id)
            if not KCD2MP._itemSeen[key] then
                KCD2MP._itemSeen[key] = true
                -- prev == nil is the baseline tick (fresh start or post-reload
                -- resweep): account for everything, emit for nothing.
                if prev and counts and mp_item_tracked_count() < KCD2MP.itemSync.maxTracked then
                    local cls, amt, hp, nm
                    pcall(function()
                        cls = e.Properties and e.Properties.sItemClassId
                        amt = (e.Properties and e.Properties.nAmount) or 1
                        hp  = (e.Properties and e.Properties.fHealth) or 1
                        nm  = e:GetName()
                    end)
                    if cls and nm and nm ~= "" and (prev[cls] or 0) > (counts[cls] or 0) then
                        local ok, ep = pcall(function() return e:GetWorldPos() end)
                        if ok and ep then
                            KCD2MP_EmitEvent("item_drop", string.format("%s %d %.4f %.3f %.3f %.3f %s",
                                cls, amt, hp, ep.x, ep.y, ep.z, nm))
                            mp_log("ITEM-SYNC local drop detected: " .. cls .. " x" .. amt .. " (" .. nm .. ")")
                        end
                    end
                end
            end
        end
    end
end

-- The agent minted a dropId for the drop this world just detected; from here
-- the local ground entity is tracked so its pickup (by us or by a peer's
-- claim) resolves like any other synced drop.
function KCD2MP_ItemDropRegistered(dropId, entName)
    local key = tostring(dropId)
    if KCD2MP.itemDrops[key] then return end
    local d = { mine = true, state = "ground", entName = tostring(entName) }
    pcall(function()
        local e = System.GetEntityByName(d.entName)
        if e then
            local p = e:GetWorldPos()
            d.x, d.y, d.z = p.x, p.y, p.z
            d.cls    = e.Properties and e.Properties.sItemClassId
            d.amount = (e.Properties and e.Properties.nAmount) or 1
            d.wuid   = e.item and e.item:GetId() or nil
        end
    end)
    KCD2MP.itemDrops[key] = d
    mp_log("ITEM-SYNC drop " .. key .. " registered -> " .. d.entName)
end

-- A peer dropped an item (ItemDropDown via the agent). Held pending until the
-- local player is near enough to materialize it safely. Heartbeats repeat
-- this call for late joiners; the dropId dedupe makes them free.
function KCD2MP_ItemDropAdd(dropId, cls, amount, health, x, y, z, srcGhostId)
    local key = tostring(dropId)
    if KCD2MP.itemDrops[key] then return end
    if mp_item_tracked_count() >= KCD2MP.itemSync.maxTracked then return end
    cls = tostring(cls or "")
    if not cls:match("^[0-9a-fA-F%-]+$") then return end
    KCD2MP.itemDrops[key] = {
        cls = cls, amount = tonumber(amount) or 1, health = tonumber(health) or 1,
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        src = tostring(srcGhostId), mine = false, state = "pending",
    }
    mp_log("ITEM-SYNC drop " .. key .. " pending: " .. cls .. " x" .. tostring(amount))
end

-- Spawn one pending drop: throwaway PickableItem shell as the position
-- anchor, the item created in a ghost's inventory (never the player's -- a
-- failure must not leave a stray item where a save could keep it), placed by
-- that ghost's human. The engine mints the real bound pickup entity; it is
-- located on the NEXT tick because entity creation and removal were both
-- observed to be deferred by a frame.
local function mp_item_spawn(key, d)
    local g = KCD2MP.ghosts[d.src] or KCD2MP.ghosts[tonumber(d.src) or -1]
    local ge = g and g.entity
    if not (ge and ge.inventory and ge.human) then
        for _, g2 in pairs(KCD2MP.ghosts) do
            if g2.entity and g2.entity.inventory and g2.entity.human then ge = g2.entity break end
        end
    end
    if not (ge and ge.inventory and ge.human) then
        if not d.warnedNoGhost then
            d.warnedNoGhost = true
            mp_log("ITEM-SYNC drop " .. key .. " waiting: no ghost entity to place through")
        end
        return
    end

    local anchorName = "kcd2mp_ianchor_" .. key
    local anchor = nil
    pcall(function()
        System.SpawnEntity{ class = "PickableItem", name = anchorName,
                            position = {x = d.x, y = d.y, z = d.z}, properties = {} }
        anchor = System.GetEntityByName(anchorName)
    end)
    if not anchor then return end
    mp_set_no_save(anchor)   -- WO-106 Phase 5: a one-tick placement scaffold, never save it
    KCD2MP._itemSeen[tostring(anchor.id)] = true

    -- Snapshot the pickables already at the drop spot BEFORE placing: the
    -- finalize pass identifies the engine-minted entity as "matching class,
    -- not in this snapshot". It cannot use the detector's seen-set for that
    -- -- the detector runs first in the same tick and will have marked the
    -- new entity seen before finalize ever looks (found live: every
    -- materialize failed with 'placed entity never appeared').
    d.preIds = {}
    pcall(function()
        local pre = System.GetEntitiesInSphere({x = d.x, y = d.y, z = d.z}, 3) or {}
        for _, e in ipairs(pre) do d.preIds[tostring(e.id)] = true end
    end)

    local created = nil
    pcall(function()
        local before = {}
        local bt = ge.inventory:GetInventoryTable()
        for i = 1, #bt do before[tostring(bt[i])] = true end
        ge.inventory:CreateItem(d.cls, d.health, d.amount)
        local at = ge.inventory:GetInventoryTable()
        for i = 1, #at do
            if not before[tostring(at[i])] then created = at[i] end
        end
    end)
    if not created then
        pcall(function() System.RemoveEntity(anchor.id) end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: CreateItem bound nothing for " .. d.cls)
        return
    end

    local okPlace = false
    pcall(function() ge.human:PlaceItem(created, anchor.id, false); okPlace = true end)
    if not okPlace then
        pcall(function() ge.inventory:DeleteItem(created, d.amount) end)
        pcall(function() System.RemoveEntity(anchor.id) end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: PlaceItem errored")
        return
    end
    d.anchorName = anchorName
    d.placeTries = 0
    d.state = "placing"
end

-- Second half of the spawn, one tick later: find the entity the engine
-- minted (same class, at the anchor, not yet accounted for), adopt it, and
-- only then discard the anchor.
local function mp_item_finalize(key, d)
    local placed = nil
    pcall(function()
        local ents = System.GetEntitiesInSphere({x = d.x, y = d.y, z = d.z}, 3) or {}
        for _, e in ipairs(ents) do
            if e.class == "PickableItem"
               and e.Properties and e.Properties.sItemClassId == d.cls
               and e:GetName() ~= d.anchorName
               and not (d.preIds and d.preIds[tostring(e.id)]) then
                placed = e
                break
            end
        end
    end)
    if placed then
        KCD2MP._itemSeen[tostring(placed.id)] = true
        d.entName = placed:GetName()
        pcall(function() d.wuid = placed.item and placed.item:GetId() or nil end)
        pcall(function()
            local a = System.GetEntityByName(d.anchorName)
            if a then System.RemoveEntity(a.id) end
        end)
        if d.pendingRemove then
            -- claimed while mid-spawn: it was never really here
            d.removedByUs = true
            pcall(function() System.RemoveEntity(placed.id) end)
            d.state = "resolved"
        else
            d.state = "ground"
            mp_log("ITEM-SYNC drop " .. key .. " materialized -> " .. d.entName)
        end
        return
    end
    d.placeTries = (d.placeTries or 0) + 1
    if d.placeTries >= 4 then
        pcall(function()
            local a = System.GetEntityByName(d.anchorName)
            if a then System.RemoveEntity(a.id) end
        end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: placed entity never appeared")
    end
end

local function mp_item_materialize(pp)
    local r2 = KCD2MP.itemSync.materializeRadius * KCD2MP.itemSync.materializeRadius
    for key, d in pairs(KCD2MP.itemDrops) do
        if d.state == "placing" then
            mp_item_finalize(key, d)
        elseif d.state == "pending" and not d.pendingRemove and d.x then
            local dx, dy = d.x - pp.x, d.y - pp.y
            if dx * dx + dy * dy <= r2 then mp_item_spawn(key, d) end
        end
    end
end

local function mp_item_watch(pp)
    local r2 = KCD2MP.itemSync.watchRadius * KCD2MP.itemSync.watchRadius
    for key, d in pairs(KCD2MP.itemDrops) do
        if d.state == "ground" and not d.removedByUs and d.entName then
            local dx, dy = (d.x or pp.x) - pp.x, (d.y or pp.y) - pp.y
            if dx * dx + dy * dy <= r2 then
                local e = System.GetEntityByName(d.entName)
                if not e then
                    d.state = "claimed_local"
                    KCD2MP_EmitEvent("item_claim", key)
                    mp_log("ITEM-SYNC drop " .. key .. " taken locally -> claim sent")
                end
            end
        end
    end
end

-- The relay's claim echo (ItemClaimDown via the agent) -- the ONLY thing that
-- resolves a drop, including our own pickups. First echo wins; repeats and
-- unknown dropIds fall through the guards.
function KCD2MP_ItemDropClaimed(dropId, claimer, isMine)
    local key = tostring(dropId)
    local d = KCD2MP.itemDrops[key]
    if not d or d.state == "resolved" then return end

    if d.state == "claimed_local" then
        if isMine then
            d.state = "resolved"   -- confirmed: the item stays picked up
        else
            -- lost the race: the pickup that landed here must be undone
            d.state = "resolved"
            if d.wuid then
                local ok = pcall(function() player.inventory:DeleteItem(d.wuid, d.amount or 1) end)
                mp_log("ITEM-SYNC drop " .. key .. " lost race, rollback ok=" .. tostring(ok))
            end
            pcall(function() KCD2MP_ShowInteractionMsg("Too slow -- someone already took that") end)
        end
        return
    end

    if d.state == "placing" then
        d.pendingRemove = true   -- mp_item_finalize removes it once it appears
        return
    end

    -- pending (never spawned here) or ground (still lying here): remove ours
    d.removedByUs = true
    if d.entName then
        pcall(function()
            local e = System.GetEntityByName(d.entName)
            if e then System.RemoveEntity(e.id) end
        end)
    end
    d.state = "resolved"
end

function KCD2MP_ItemSyncTick()
    if not KCD2MP.itemSyncRunning then return end
    Script.SetTimer(KCD2MP.itemSync.scanMs, KCD2MP_ItemSyncTick)  -- reschedule FIRST
    KCD2MP._itemSyncAliveAt = os.clock()
    if not KCD2MP.itemSync.enabled then return end
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    if KCD2MP._itemRestartSweep then
        KCD2MP._itemRestartSweep = false
        if mp_item_world_reloaded() then
            -- A save load replaced every runtime entity and rewound the
            -- inventory. Re-baseline the detector (or the rewound counts +
            -- new entity ids would fake a drop), and resweep the tracked set:
            -- our own vanished drop means the reload returned it to this
            -- world's save state -- claim it back so peers converge on that.
            -- A vanished materialized copy just needs re-materializing.
            KCD2MP._itemInvCounts = nil
            KCD2MP._itemSeen = {}
            for key, d in pairs(KCD2MP.itemDrops) do
                if (d.state == "ground" or d.state == "placing") and d.entName then
                    local e = System.GetEntityByName(d.entName)
                    if e then
                        KCD2MP._itemSeen[tostring(e.id)] = true
                    elseif d.mine then
                        d.state = "claimed_local"
                        KCD2MP_EmitEvent("item_claim", key)
                        mp_log("ITEM-SYNC drop " .. key .. " reclaimed after reload")
                    else
                        d.entName, d.wuid, d.anchorName = nil, nil, nil
                        d.state = "pending"
                        mp_log("ITEM-SYNC drop " .. key .. " back to pending after reload")
                    end
                end
            end
            mp_log("ITEM-SYNC restart sweep: reload detected, re-baselined")
        end
        -- else: a menu/pause gap -- the world is intact, prev counts are
        -- still valid, and a drop made INSIDE the inventory screen is about
        -- to be detected by the ordinary tick below.
    end

    pcall(mp_item_detect, pp)
    pcall(mp_item_materialize, pp)
    pcall(mp_item_watch, pp)
end

function KCD2MP_StartItemSync()
    if not chainMayStart("itemsync", "itemSyncRunning", "_itemSyncAliveAt", KCD2MP_StartItemSync) then return end  -- WO-78
    KCD2MP.itemSyncRunning = true
    KCD2MP._itemSyncAliveAt = os.clock()
    KCD2MP._itemRestartSweep = true
    mp_log("ITEM-SYNC tick started (" .. KCD2MP.itemSync.scanMs .. "ms)")
    Script.SetTimer(KCD2MP.itemSync.scanMs, KCD2MP_ItemSyncTick)
end

function KCD2MP_EnableItemSync(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.itemSync.enabled = true
    elseif s:find("off") then KCD2MP.itemSync.enabled = false
    else
        mp_log("mp_item_sync: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    if KCD2MP.itemSync.enabled then
        KCD2MP._itemInvCounts = nil   -- re-baseline; stale counts would fake a drop
        KCD2MP_StartItemSync()
    end
    mp_log("ITEM-SYNC " .. (KCD2MP.itemSync.enabled and "ENABLED" or "disabled"))
    pcall(function() KCD2MP_ShowInteractionMsg("Item sync: " .. (KCD2MP.itemSync.enabled and "ON" or "OFF")) end)
    return true
end

-- ===== Register Console Commands =====

local ok, err = pcall(function()
    System.AddCCommand("mp_pos",         "KCD2MP_GetPos()",         "Get player position")
    System.AddCCommand("mp_start",       "KCD2MP_Start()",          "Start MP sync")
    System.AddCCommand("mp_stop",        "KCD2MP_Stop()",           "Stop MP sync")
    System.AddCCommand("mp_spawn_test",  "KCD2MP_SpawnTest()",      "Spawn test ghost")
    System.AddCCommand("mp_remove_all",  "KCD2MP_RemoveAllGhosts()","Remove all ghosts")
    System.AddCCommand("mp_inspect",     "KCD2MP_InspectGhost()",   "Inspect ghost interp state")
    System.AddCCommand("mp_find_npcs",   "KCD2MP_FindNPCs()",       "Find nearby human NPCs")
    System.AddCCommand("mp_map_marker",  'KCD2MP_ProbeMapMarker("%line")', "WO-38: probe GameRules.AddMinimapEntity on ghosts (arg: type int, or 'sweep')")
    System.AddCCommand("mp_ghost_ignorant", 'KCD2MP_SetGhostsIgnorant("%line")', "WO-38/40: AI.SetIgnorant on all ghosts -- DEFAULT ON since WO-40 (pickpocket aggro): on|off")
    System.AddCCommand("mp_ghost_calm",  "KCD2MP_GhostCalm()", "WO-40: probe faction/hostility binds and clear per-pair hostility on every ghost")
    System.AddCCommand("mp_probe_anims",   "KCD2MP_ProbeAnims()",    "Probe anim names on ghost (GetAnimationLength)")
    System.AddCCommand("mp_copy_npc",     "KCD2MP_CopyNPCModel()",  "Find human NPC, copy CDF to ghost, probe anims")
    System.AddCCommand("mp_scan_anims",   "KCD2MP_ScanAnims()",     "Scan animation directories")
    System.AddCCommand("mp_test_ai_nav",  "KCD2MP_TestAINav()",     "Test AI.SetForcedNavigation on ghost")
    System.AddCCommand("mp_read_adb",     "KCD2MP_ReadADB()",       "Read kcd_male_database.adb via CryEngine XML loader")
    System.AddCCommand("mp_probe_tags",   "KCD2MP_ProbeAnimTags()", "Probe Mannequin animation tags on ghost")
    System.AddCCommand("mp_test_run",     "KCD2MP_TestRunAnim()",   "Test 3d_relaxed_run_turn_strafe on ghost")
    System.AddCCommand("mp_terrain",      "KCD2MP_TerrainCheck()",  "Check player/ghost vs terrain height")
    System.AddCCommand("mp_probe_stance", "KCD2MP_ProbeStance()",   "Log player stance value (for crouch detection calibration)")
    System.AddCCommand("mp_probe_dialog", "KCD2MP_ProbeDialog()",   "WO-88: log whether human:IsInDialog / Dialog.IsSoulInDialog exist and what they read right now -- run inside and outside a conversation; read-only")
    System.AddCCommand("mp_probe_contexts", "KCD2MP_ProbeContexts()", "WO-65: dump script-context isolation surface (Contexts global, soul/human methods, per-context HasScriptContext on ghost + player) -- read-only")
    System.AddCCommand("mp_ghost_isolate", 'KCD2MP_SetGhostIsolate("%line")', "WO-65: ghost civic isolation (default on). On this build: RestrictDialog+InterruptDialogs only -- the script-context crime fix has no Lua setter here: mp_ghost_isolate on|off")
    System.AddCCommand("mp_ghost_nai_on",  "KCD2MP_SetGhostNai(true)",  "WO-100.5: spawn ghosts as NPC_NAI (no local brain, no contention with the position stream). Applies to the NEXT spawn")
    System.AddCCommand("mp_ghost_nai_off", "KCD2MP_SetGhostNai(false)", "WO-100.5: spawn ghosts as the ordinary NPC class (brain and perception, WO-26 reactive combat)")
    System.AddCCommand("mp_nai_ab",        "KCD2MP_Wo1005NaiAB()",      "WO-100.5: spawn one NPC_NAI ghost and one NPC ghost side by side, for the perception comparison")
    System.AddCCommand("mp_ghost_noai_on",  "KCD2MP_SetGhostNoAi(true)",  "WO-100.5: spawn ghosts with NoAI=true -- keeps class NPC, perception, hit registration and the soul; removes the brain. Applies to the NEXT spawn")
    System.AddCCommand("mp_ghost_noai_off", "KCD2MP_SetGhostNoAi(false)", "WO-100.5: spawn ghosts with their ordinary brain (WO-26 reactive self-defence)")
    System.AddCCommand("mp_anim_legacy_on",  "KCD2MP_SetAnimLegacy(true)",  "WO-100.5: infer ghost locomotion from packet speed (pre-0.23.1 behaviour)")
    System.AddCCommand("mp_anim_legacy_off", "KCD2MP_SetAnimLegacy(false)", "WO-100.5: drive ghost locomotion from the peer's real Mannequin tags (default)")
    System.AddCCommand("mp_anim_stats",      "KCD2MP_AnimStats()",          "WO-100.5: print the body-state channel's counters")
    System.AddCCommand("mp_sneak_on",     "KCD2MP.playerSneaking=true;System.LogAlways('[KCD2-MP] SNEAK ON (manual)')",  "Force ghost into sneak mode")
    System.AddCCommand("mp_sneak_off",    "KCD2MP.playerSneaking=false;System.LogAlways('[KCD2-MP] SNEAK OFF (manual)')", "Force ghost out of sneak mode")
    -- mp_spawn_armor <guid1,guid2,...>  -- inventory only (no visual unless preset given as 2nd arg)
    System.AddCCommand("mp_spawn_armor",  'KCD2MP_SpawnArmoredNPC("%line")',  "Spawn NPC with items: mp_spawn_armor guid1,guid2,...")
    System.AddCCommand("mp_spawn_knight",    "KCD2MP_SpawnKnight()",    "Spawn fully armored knight (BascinetVisor04+Cuirass07+Gauntlets08+LegsPlate03+MailLong01)")
    System.AddCCommand("mp_spawn_white_red", "KCD2MP_SpawnWhiteRed()", "Spawn white/red armored NPC (Brigandine10+BascinetVisor05+sword)")
    System.AddCCommand("mp_scan_horse",      "KCD2MP_ScanNearbyHorse()", "Scan real horse NPC within 20m: anims, AI fns, horse.horse API")
    System.AddCCommand("mp_find_horses",     "KCD2MP_FindHorses()",     "Find horse entities near player - shows class names")
    System.AddCCommand("mp_spawn_horse_test","KCD2MP_SpawnHorseTest()", "Force-spawn a horse at player position (class probe)")
    System.AddCCommand("mp_riding_state",    "KCD2MP_RidingState()",    "Log current riding detection state")
    System.AddCCommand("mp_emit_on",         "KCD2MP_StartEmitter()",   "Start [KCD2-MP-DATA] state emitter (WO-1 log transport)")
    System.AddCCommand("mp_emit_off",        "KCD2MP_StopEmitter()",    "Stop the state emitter")
    System.AddCCommand("mp_emit_once",       "KCD2MP_EmitState()",      "Emit a single state line")
    System.AddCCommand("mp_accept",          "KCD2MP_AcceptInvite()",   "Accept a pending interaction invite")
    System.AddCCommand("mp_decline",         "KCD2MP_DeclineInvite()",  "Decline a pending interaction invite")
    System.AddCCommand("mp_sync_appearance", "KCD2MP_SyncAppearance()", "Force an immediate appearance resync to peers (WO-9)")
    System.AddCCommand("mp_slow_time",       "KCD2MP_SlowTime()",       "Toggle manually broadcasting a paused/unavailable state to peers (WO-11 fallback)")
    System.AddCCommand("mp_invite",          'KCD2MP_InviteNearest("%line")', "Invite the nearest player: mp_invite dice|duel")
    System.AddCCommand("mp_ghost_state",     "KCD2MP_GhostState()",     "Dump all ghost riding/mount state")
    System.AddCCommand("mp_horse_adopt",     'KCD2MP_SetHorseAdopt("%line")', "WO-40: adopt real world horses for ghosts (default on). off = proxy horses only -- use if the game crashes when a peer mounts")
    System.AddCCommand("mp_weather",         'KCD2MP_WeatherCmd("%line")', "WO-40: bare = report rain intensity; mp_weather <profile> = blend to a time_of_day profile locally (probe, not broadcast)")
    System.AddCCommand("mp_enable_aggro",    'KCD2MP_EnableAggro("%line")', "WO-17: opt-in NPC aggro on ghosts, this client only: mp_enable_aggro on|off")
    System.AddCCommand("mp_debug_hud",       'KCD2MP_DebugHud("%line")', "WO-50: toggle the CryEngine debug HUD (r_DisplayInfo), off by default in release: mp_debug_hud on|off")

    -- NPC sync (WO-32)
    System.AddCCommand("mp_npc_sync",    'KCD2MP_EnableNpcSync("%line")', "WO-32: stream nearby NPCs to peers (world authority only): mp_npc_sync on|off")
    System.AddCCommand("mp_npc_proximity", 'KCD2MP_EnableNpcProximity("%line")', "WO-60: non-authority claims NPCs near its own player (default on). off = pre-WO-60 host-only tracking: mp_npc_proximity on|off")
    -- WO-102: argless toggle pairs (the console drops arguments) + status.
    System.AddCCommand("mp_authority_host_on",  'KCD2MP_Wo102Set("authority_host", true)',  "WO-102: the damage-authority holder owns EVERY NPC permanently; no claims, no proximity, no expiry. Off = the 0.23.2 claim model")
    System.AddCCommand("mp_authority_host_off", 'KCD2MP_Wo102Set("authority_host", false)', "WO-102: back to the 0.23.2 per-NPC claim model (WO-39/WO-60), exactly")
    System.AddCCommand("mp_pos_native_on",      'KCD2MP_Wo102Set("pos_native", true)',      "WO-102: the agent reads position/rotation/riding over the DLL pipe instead of the kcd.log line")
    System.AddCCommand("mp_pos_native_off",     'KCD2MP_Wo102Set("pos_native", false)',     "WO-102: position back on the [KCD2-MP-DATA] log tail (0.23.2 path)")
    System.AddCCommand("mp_wo102_status",       "KCD2MP_Wo102Status()",                     "WO-102: log every WO-102 toggle's state and this client's authority role")
    System.AddCCommand("mp_authority_pause_on",  'KCD2MP_Wo102Set("authority_pause", true)',  "WO-102 Phase 4 / WO-108: under host authority the non-authority pauses every puppet's local brain with wh_ai_PauseNPC (resume on release + mp_resume_dwell). ON by default since 0.26.4: WO-107 showed the lever works and WO-104's 0/155 was a misread metric")
    System.AddCCommand("mp_authority_pause_off", 'KCD2MP_Wo102Set("authority_pause", false)', "WO-102 Phase 4: resume every paused NPC and stop pausing (0.26.3 behaviour; see also mp_preset_legacy)")
    System.AddCCommand("mp_npc_replica_on",      "KCD2MP_SetNpcReplica(true)",  "WO-104: under host authority, replace a CONTESTED puppet (MP-AUTHORITY-VIOLATION) with a brainless soul-bound replica. OFF by default since 0.26.4 -- structurally dead (WO-106 S5: SharedSoulGuid cannot address a live NPC; never promoted once); kept as a toggle")
    System.AddCCommand("mp_npc_replica_off",     "KCD2MP_SetNpcReplica(false)", "WO-104: demote every replica (NPCs return where their replica stood) and stop promoting")
    System.AddCCommand("mp_npc_replica_status",  "KCD2MP_NpcReplicaStatus()",   "WO-104: log the replica toggle, active replicas and the promote/demote/refuse/orphan counters")
    System.AddCCommand("mp_probe_npc_pause",     "KCD2MP_ProbeNpcPause()",                    "WO-102 Phase 3 live probe: pause the nearest NPC (<15 m) with wh_ai_PauseNPC, move it 2 m, watch 3 s, animate, resume -- MP-PAUSEPROBE lines in kcd.log. NOTE (WO-107 S4): its SNAPPED BACK verdict measures the engine position-relax, not a brain")
    System.AddCCommand("mp_preset_clean",        'KCD2MP_ApplyPreset("clean")',               "WO-108: re-apply the 0.26.4 defaults (pause lever ON, replicas OFF, yield OFF, 10 s resume dwell, shared values); logs every value as MP-PRESET; authority model untouched")
    System.AddCCommand("mp_preset_legacy",       'KCD2MP_ApplyPreset("legacy")',              "WO-108: the 0.26.3 defaults (pause lever OFF, replicas ON, yield ON, no dwell) -- one command back to the old behaviour; logs every value; authority model untouched")
    System.AddCCommand("mp_resume_all",          'KCD2MP_ResumeAllPaused("mp_resume_all")',   "WO-108 panic button: switch the pause lever OFF and wh_ai_ResumeNPC every NPC this session ever paused (mp_authority_pause_on or mp_preset_clean re-enables)")
    System.AddCCommand("mp_resume_dwell",        'KCD2MP_SetResumeDwell("%line")',            "WO-108: seconds a released puppet's brain pause is held before wh_ai_ResumeNPC (default 10; 0 = the 0.26.3 resume-at-once): mp_resume_dwell <s>; bare = report")
    -- WO-108 build marker: the first thing to grep for after a fresh load with
    -- nothing typed. If this line is missing or says off, the pak is stale
    -- (memory/kcd2mp-lua-deploy-gotcha.md), not the source.
    mp_log(string.format("WO108-BUILD pause_lever=%s npc_replica=%s npc_yield=%s resume_dwell_s=%.1f -- 0.26.4 defaults (mp_preset_legacy = 0.26.3)",
        KCD2MP.wo102.authorityPause and "on" or "off", KCD2MP.npcReplica.enabled and "on" or "off",
        KCD2MP.npcYield.enabled and "on" or "off", KCD2MP.wo1025.resumeDwellS or 0))
    System.AddCCommand("mp_resync_npcs",         "KCD2MP_NpcResyncRequest()",                 "WO-102 Phase 6: push (owner) or ask for (non-owner) a one-shot NPC position/life-state resync of every NPC near any player; needs mp_authority_host_on")
    System.AddCCommand("mp_npc_scan_native_on",  'KCD2MP_Wo102Set("npc_scan_native", true)',  "WO-102.5 Phase 2: mp_npc_rescan sources candidates from the agent's native scan push instead of System.GetEntitiesInSphere. UNMEASURED -- run mp_npc_scan_compare first")
    System.AddCCommand("mp_npc_scan_native_off", 'KCD2MP_Wo102Set("npc_scan_native", false)', "WO-102.5 Phase 2: back to the Lua GetEntitiesInSphere enumerate")
    System.AddCCommand("mp_npc_scan_compare",    "KCD2MP_NpcScanCompare()",                   "WO-102.5 Phase 2 known-answer check: diff the native scan's last pushed name set against a fresh Lua GetEntitiesInSphere enumerate over the same anchors/radius")
    System.AddCCommand("mp_npc_cull_on",         'KCD2MP_SetNpcCull("on")',                   "WO-102.5 Phase 3: under host authority, an owned NPC beyond cullRadius is tracked but not streamed (default on). Radius: mp_authority_radius <metres>")
    System.AddCCommand("mp_npc_cull_off",        'KCD2MP_SetNpcCull("off")',                  "WO-102.5 Phase 3: stream every owned NPC regardless of distance")
    System.AddCCommand("mp_authority_radius",    'KCD2MP_SetAuthorityRadius("%line")',        "WO-102.5/WO-106: set the host-authority NPC ownership radius: mp_authority_radius <metres> (default 300, floor 10)")
    System.AddCCommand("mp_together_params",     'KCD2MP_SetTogetherParams("%line")',         "WO-102.5/WO-106: set the together/apart hysteresis band: mp_together_params <enterM> <exitM> <dwellS>, or 'on' for defaults (60 90 10)")
    System.AddCCommand("mp_puppet_rate",         'KCD2MP_SetPuppetRate("%line")',              "WO-106 Phase 3 mitigation: set the puppet write/tick rate in ms, takes effect next tick, no reconnect needed: mp_puppet_rate <ms> (default 50, floor 10) -- lower it to test whether ground-collider sinking scales with write frequency")
    System.AddCCommand("mp_npc_read_native_on",  'KCD2MP_SetNpcReadNative("on")',              "WO-103 Phase 2: a tracked NPC's position/yaw comes from the agent's native scan push when fresh, falling back to the live e:GetWorldPos() read otherwise (default on)")
    System.AddCCommand("mp_npc_read_native_off", 'KCD2MP_SetNpcReadNative("off")',             "WO-103 Phase 2: always read position/yaw live off the entity, as before this WO")
    System.AddCCommand("mp_npc_read_compare",    "KCD2MP_NpcReadCompare()",                    "WO-103 Phase 2 known-answer check: diff the native push's position/yaw against a fresh live read for every currently-tracked name; a real mismatch fails mp_npc_read_native closed")

    -- Dropped-item sync (WO-48)
    System.AddCCommand("mp_item_sync",   'KCD2MP_EnableItemSync("%line")', "WO-48: share deliberately dropped items with peers: mp_item_sync on|off")
    System.AddCCommand("mp_npc_fight",   "KCD2MP_NpcFightReport()", "WO-40: dump per-puppet tug-of-war counts and competing attractor positions")
    System.AddCCommand("mp_npc_yield",     'KCD2MP_SetNpcYield("%line")', "WO-99: report the sub-8 m puppet yield arbitration state; thresholds via #KCD2MP_SetNpcYield(\"dispM ticks repinM\")")
    System.AddCCommand("mp_npc_yield_on",  'KCD2MP_SetNpcYield("on")',  "WO-99: yield a puppet to the local brain after sustained sub-8 m contention. OFF by default since 0.26.4 (inert under host authority, WO-102 P4); only reachable with mp_authority_host_off")
    System.AddCCommand("mp_npc_yield_off", 'KCD2MP_SetNpcYield("off")', "WO-99: pre-WO-99 behaviour -- write every puppet every tick below 8 m (live A/B)")
    System.AddCCommand("mp_npc_diverge", 'KCD2MP_SetNpcDiverge("%line")', "WO-90: release a puppeted NPC the local world keeps dragging far from the stream (two players at different story beats). on (default) | off (pre-WO-90 tug-of-war) | <metres>")
    -- WO-94: Shared Quests (main-story readiness prompt).
    -- WO-106 CORRECTION of the 2026-09-13 "console drops arguments" finding:
    -- the console never refused arguments. AddCCommand's placeholder lookup
    -- is case-sensitive and this file registered "%LINE" (uppercase) against
    -- the engine's lowercase "%line" -- which produced BOTH symptoms from one
    -- typo ("Too many arguments for: ..." when an arg was given, the literal
    -- placeholder text when none was). Fixed throughout this file by using
    -- the real, lowercase form. Every mp_* command below now takes its
    -- argument directly from the console; the `#KCD2MP_...(...)` Lua form
    -- still works too and is left in place for anyone with it in muscle
    -- memory (docs/WO-105-contradictions.md entry 1).
    System.AddCCommand("mp_quest_sync",   'KCD2MP_QuestSetSync("")',        "WO-94: status line for the main-quest readiness prompt (toggle with mp_quest_on / mp_quest_off)")
    System.AddCCommand("mp_quest_on",     'KCD2MP_QuestSetSync("on")',      "WO-94: enable the main-quest readiness prompt (default)")
    System.AddCCommand("mp_quest_off",    'KCD2MP_QuestSetSync("off")',     "WO-94: disable the main-quest readiness prompt (rollback: no detection, no prompt)")
    System.AddCCommand("mp_quest_radius", 'KCD2MP_QuestSetRadius("%line")', "WO-94: set the main-quest co-location detection radius: mp_quest_radius <metres> (default 35)")
    System.AddCCommand("mp_quest_window", 'KCD2MP_QuestSetWindow("%line")', "WO-94: set the main-quest readiness prompt window: mp_quest_window <seconds> (default 120)")
    System.AddCCommand("mp_quest_status", "KCD2MP_QuestStatus()",           "WO-94: log quest sync state and the current quest's beats with distances")
    System.AddCCommand("mp_quest_yes",    "KCD2MP_QuestAnswer(true)",       "WO-94: answer the readiness prompt YES (same as F11) -- fires wh_concept_HasteTrigger for the peer's beat")
    System.AddCCommand("mp_quest_no",     "KCD2MP_QuestAnswer(false)",      "WO-94: answer the readiness prompt NO (same as F12)")
    System.AddCCommand("mp_quest_fire",   'KCD2MP_QuestFire("%line", "console")', "WO-94 live probe: mp_quest_fire <quest.trigger> (disposable save!)")
    System.AddCCommand("mp_quest_test_prompt", 'KCD2MP_QuestTestPrompt("")', "WO-94 live probe: show the readiness prompt for the first registered beat with no peer (F11/F12 + overlay test); a specific beat: #KCD2MP_QuestTestPrompt(\"quest.trigger\")")
    System.AddCCommand("mp_quest_gap",    'KCD2MP_QuestSetGap("%line")',    "WO-96: set the minimum seconds between prompts per peer: mp_quest_gap <seconds> (default 60)")
    System.AddCCommand("mp_quest_hide",   "KCD2MP_QuestWaitingDismiss()",    "WO-96: hide the WAITING FOR PEER line until the story positions change (same as F12 with no prompt up)")
    System.AddCCommand("mp_npc_chainfix", 'KCD2MP_SetNpcChainFix("%line")', "WO-69/WO-78: on (default since WO-78) makes a leaked puppet-tick chain exit when detected; off logs it and leaves it running: mp_npc_chainfix on|off")
    System.AddCCommand("mp_ghost_chainfix", 'KCD2MP_SetGhostChainFix("%line")', "WO-78: on (default) makes a leaked ghost interp chain exit when detected; off logs it and leaves it running: mp_ghost_chainfix on|off")
    System.AddCCommand("mp_npc_smooth",  'KCD2MP_SetNpcSmooth("%line")', "WO-77: NPC puppet renderer -- on (default) = time-based interpolation-behind (1.2 x emit period), off = pre-WO-77 per-tick 0.5 lerp: mp_npc_smooth on|off")

    -- Shared player combat (WO-28)
    System.AddCCommand("mp_vitals",      "KCD2MP_ReportVitals()",   "WO-28: report this player's health/stamina/death and every ghost's known health")
    System.AddCCommand("mp_fake_death",  'KCD2MP_FakeDeath("%line")', "WO-28: report yourself dead for N seconds (default 20) so peers can be observed reacting -- test only")
    System.AddCCommand("mp_reconcile",   "KCD2MP_ReconcileGhosts()", "WO-28: respawn any ghost whose entity was destroyed by a save load")
    System.AddCCommand("mp_ghost_sweep", 'KCD2MP_SetOrphanSweep("%line")', "WO-84: remove kcd2mp_ bodies a savegame restored with no ghost behind them: mp_ghost_sweep on|off|now")
    System.AddCCommand("mp_npc_deathsync", 'KCD2MP_SetNpcDeathSync("%line")', "WO-86: NPC deaths cross to peers and a locally-dead body never follows a living stream; off = pre-WO-86 behaviour: mp_npc_deathsync on|off")
    System.AddCCommand("mp_ghost_anim_refresh", 'KCD2MP_SetGhostAnimRefresh("%line")', "WO-84: seconds a ghost's looped clip plays before a keep-alive restart; 0 = restart every tick (pre-WO-84 rollback)")

    -- Dice overlay (WO-6). These console commands are the SUPPORTED path: the
    -- keybinds below them are unverified action-name guesses, exactly as WO-2's
    -- accept/decline were. Everything here is reachable without a working key.
    System.AddCCommand("mp_dice",        "KCD2MP_InviteDiceAtTable()", "Challenge the nearest player to dice -- only at a real dice table")
    System.AddCCommand("mp_dice_wager",  'KCD2MP_SetDiceWager("%line")', "WO-33: set groschen staked on the next dice invite this client sends (0 = none)")
    System.AddCCommand("mp_dice_cast",   "KCD2MP_DiceConfirm()",       "Cast, or set aside the marked dice (depends on phase)")
    System.AddCCommand("mp_dice_mark",   'KCD2MP_DiceMark("%line")',   "Mark/unmark a die on the board: mp_dice_mark 1..6")
    System.AddCCommand("mp_dice_unmark_all", "KCD2MP_DiceUnmarkAll()", "Clear every pending mark without rerolling")
    System.AddCCommand("mp_dice_bank",   "KCD2MP_DiceBank()",          "Bank this hand and end thy turn")
    System.AddCCommand("mp_dice_yield",  "KCD2MP_DiceForfeit()",       "Yield the match")
    System.AddCCommand("mp_dice_close",  "KCD2MP_DiceClose()",         "Dismiss the dice board")
    System.AddCCommand("mp_dice_table",  "KCD2MP_ReportDiceTable()",   "Report the nearest dice table, for verifying table detection")
    System.AddCCommand("mp_dice_redraw", "KCD2MP_DiceRender()",        "Force the board to re-push (use if it ever goes stale)")
    System.AddCCommand("mp_dice_flush",  "KCD2MP_DiceFlush()",         "Clear every queued/shown tutorial panel -- fixes a stuck or flickering board")
    System.AddCCommand("mp_dice_scan",   'KCD2MP_ScanTables("%line")', "List nearby entity classes, to find a table's real class: mp_dice_scan 6")
    System.AddCCommand("mp_dice_seat",   "KCD2MP_ReportSeat()",        "Report the seat under you: distance, table id, teleport anchor")
    System.AddCCommand("mp_dice_gate",   'KCD2MP_DiceGate("%line")',   "Require a real table for mp_dice: mp_dice_gate on|off (default off for testing)")
    System.AddCCommand("mp_dice_demo",   "KCD2MP_DiceDemo()",          "Open the board with fake state, to review the visuals without a second player")
    System.AddCCommand("mp_combat_probe", "KCD2MP_CombatProbe()", "WO-39: registration + anim-candidate probe for combat visibility (needs a ghost for the anim half)")
    System.AddCCommand("mp_ghost_combat", 'KCD2MP_GhostCombatAll("%line")', "WO-39: play a combat event on every local ghost, no wire: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
    System.AddCCommand("mp_log_actions", 'KCD2MP_LogActions("%line")', "Log every OnAction name (floods log -- for discovering action names): mp_log_actions on|off")
    System.AddCCommand("mp_summary", 'KCD2MP_LogSummary("console")', "WO-98: write the MP-SUMMARY-MOD counters line to kcd.log now")
    System.AddCCommand("mp_combat_frag", 'KCD2MP_SetCombatFragment("%line")', "WO-39: set the Mannequin fragment tried for swings (empty to clear): mp_combat_frag <name> [tags]")
    System.AddCCommand("mp_entity_id", 'KCD2MP_ReportEntityId("%line")', "WO-43: print an entity's raw id by name, or every ghost's id with no argument")
    System.AddCCommand("mp_anim_tag",    'KCD2MP_AnimTagCmd("%line")', "WO-40: probe AI.Set/ClearAnimationTag on every ghost: mp_anim_tag set|clear <tag>")
    System.AddCCommand("mp_test_xgen_nullai", 'KCD2MP_TestXGenSpawn("NullAI")', "Test XGenAIModule.SpawnEntity ClassName=NullAI")
    System.AddCCommand("mp_test_xgen_npc",    'KCD2MP_TestXGenSpawn("NPC")',    "Test XGenAIModule.SpawnEntity ClassName=NPC")
    System.AddCCommand("mp_test_xgen_horse",  'KCD2MP_TestXGenSpawn("Horse")',  "Test XGenAIModule.SpawnEntity ClassName=Horse")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- mp_log_actions on|off (WO-39). The KCD2MP.logActions global existed since
-- WO-6 but had no console command -- discovering action names needed a
-- hand-typed Lua chunk. The live combat-input probe made it a first-class
-- command.
function KCD2MP_LogActions(arg)
    local on = tostring(arg or ""):lower()
    KCD2MP.logActions = (on == "on" or on == "true" or on == "1")
    System.LogAlways("[KCD2-MP] logActions=" .. tostring(KCD2MP.logActions))
end

-- mp_anim_tag set|clear <tag> (WO-40 Phase 6): probe AI.SetAnimationTag /
-- ClearAnimationTag (documented in the retail-1.5 dump, never tried here) on
-- every ghost. Mannequin tags select fragment variants -- potentially the
-- clean lever for stance/combat variants that raw StartAnimation cannot pick.
function KCD2MP_AnimTagCmd(line)
    line = tostring(line or "")
    local op, tag = line:match("^(%S+)%s+(%S+)$")
    if not op or not tag then
        System.LogAlways("[KCD2-MP] usage: mp_anim_tag set|clear <tag>  (applies to every ghost)")
        System.LogAlways("[KCD2-MP] AI.SetAnimationTag=" .. tostring(AI and type(AI.SetAnimationTag) or "no AI")
            .. " AI.ClearAnimationTag=" .. tostring(AI and type(AI.ClearAnimationTag) or "no AI"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            n = n + 1
            local ok, err
            if op == "set" then
                ok, err = pcall(function() return AI.SetAnimationTag(g.entity.id, tag) end)
            else
                ok, err = pcall(function() return AI.ClearAnimationTag(g.entity.id, tag) end)
            end
            System.LogAlways(string.format("[KCD2-MP] %s AnimationTag('%s') ghost %s ok=%s err=%s",
                op, tag, tostring(id), tostring(ok), tostring(err)))
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to tag") end
end

-- mp_combat_frag <name> [tags] (WO-39): configure the Mannequin fragment the
-- swing apply path tries before the CAF one-shot. Live-tuning tool -- once a
-- session finds a working fragment, it gets hardcoded as the default.
function KCD2MP_SetCombatFragment(line)
    line = tostring(line or "")
    local name, tags = line:match("^(%S+)%s*(.*)$")
    KCD2MP.combatSwingFragment = (name ~= "" and name) or nil
    KCD2MP.combatSwingFragTags = tags or ""
    System.LogAlways("[KCD2-MP] combatSwingFragment=" .. tostring(KCD2MP.combatSwingFragment)
        .. " tags='" .. tostring(KCD2MP.combatSwingFragTags) .. "'")
end

-- ===== Sneak action handler (shared, installed by both hook paths) =====

-- Toggle-style sneak actions (each press flips state).
-- NOTE: chat_init_with_focus is NOT sneak ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œ it's the focus/chat key (triggered by Tab/V).
-- Stance is detected via player:GetStance() polling in KCD2MP_Exchange (reliable fallback).
local SNEAK_TOGGLE_ACTIONS = {
    sneak_toggle=true, toggle_sneak=true,
}
-- Hold-style sneak: pressed=on, released=off (other games/bindings)
local SNEAK_HOLD_ACTIONS = {
    sneak=true, stealth=true, crouch=true,
    wh_sneak=true, wh_stealth=true,
    action_sneak=true, action_stealth=true,
    sneaking=true, stealth_mode=true,
}

-- Analog axis actions - ignore completely, they flood the log
local AXIS_ACTIONS = {
    combat_zone_mouse_x=true, combat_zone_mouse_y=true,
    mouse_x=true, mouse_y=true, look_lx=true, look_ly=true,
    move_lx=true, move_ly=true,
}

-- Combat visibility (WO-39 Phase 1): the local player's own attack/block
-- inputs, mirrored to peers as cosmetic one-shots on this player's ghost.
-- CONFIRMED by the mp_log_actions live pass 2026-08-18: real melee swings
-- fire 'attack_primary_mouse' press/release, one pair per swing; blocking
-- fires 'block' with activation 'hold' (spammed per frame while held) and
-- 'release' -- NEVER 'press', which is why the handler below edge-detects
-- the first hold. 'attack_abort' also fires on releases; deliberately not
-- listed (it is the abort, not the swing). The unconfirmed non-mouse
-- variants stay for gamepad input, same harmless-if-never-fires idiom as
-- the dialog_answerN guesses above.
local COMBAT_SWING_ACTIONS = {
    attack_primary_mouse=true,                        -- CONFIRMED live
    attack_secondary_mouse=true,                      -- same family (stab)
    attack_primary=true, attack_secondary=true,       -- gamepad guesses
}
local COMBAT_BLOCK_ACTIONS = {
    block=true,                                       -- CONFIRMED live (hold/release)
    combat_block=true, wh_block=true,                 -- gamepad guesses
}

-- Accept/decline keybinds (WO-2, real binds added WO-33).
--
-- dialog_answer1/2 etc. below are UNVERIFIED GUESSES, kept only because
-- removing them costs nothing and they might someday turn out real. The
-- actual primary path, added WO-33, reuses kcd2mp_dice_bank (F11) /
-- kcd2mp_dice_yield (F12) -- keys already live-verified safe and wired
-- end-to-end for in-match bank/yield (WO-6 comment block in
-- keybindSuperactions.xml). Reusing them costs zero new key-testing risk:
-- outside an active match (KCD2MP.dice.open false) these two actions are
-- never consumed by the dice-board block below, so they fall through here
-- unclaimed. mp_accept / mp_decline remain the documented console fallback.
local ACCEPT_ACTIONS  = { ["dialog_answer1"] = true, ["confirm"] = true, ["ui_accept"] = true,
                           ["kcd2mp_dice_bank"] = true }
local DECLINE_ACTIONS = { ["dialog_answer2"] = true, ["cancel"] = true, ["ui_cancel"] = true,
                           ["kcd2mp_dice_yield"] = true }

-- Dice-invite keybind (WO-5, real bind added WO-33). dialog_answer3/4 are the
-- same kind of unverified guess as above, kept harmlessly. The real primary
-- path reuses kcd2mp_dice_cast (F9) -- same reasoning as accept/decline: F9
-- is already proven safe and unclaimed outside an active match, since the
-- dice-board block below only consumes it (as "confirm/cast") when
-- KCD2MP.dice.open is true and returns early. KCD2MP_InviteDiceAtTable
-- itself refuses unless a DiceInteractor entity is actually in range, so a
-- spurious F9 press elsewhere in the world is a no-op, not an unwanted
-- invite. mp_invite dice remains the documented console fallback.
local DICE_INVITE_ACTIONS = { ["dialog_answer3"] = true, ["dialog_answer4"] = true,
                               ["kcd2mp_dice_cast"] = true }

-- Dice overlay keys (WO-6).
--
-- Second design. The first tried R/F/X/1-6 -- keys the game's OWN action map
-- already binds to something (toggle_torch, knock_out, call, action_qam_N) --
-- on the reasoning that our OnAction hook runs alongside the game's handler
-- and cannot consume input, so the key's normal side effect had to be
-- tolerable. Two things broke that plan in real play:
--   1. 1-6 also fires action_qam_N's WEAPON/food slot select, not just a
--      cosmetic toggle -- a live match drew a sword mid-game.
--   2. R (toggle_torch) turned out unreliable while seated -- exactly the
--      position this feature is for.
--
-- keybindSuperactions.xml (Libs/Config/, shipped in this mod's own pak) is
-- the actual fix: it is a plain, moddable XML action-map config, not
-- hardcoded, and a key can carry MULTIPLE named actions across different
-- `map=` contexts simultaneously. So instead of reusing an existing action
-- and hoping its side effect is harmless, this ships brand-new action names
-- (kcd2mp_dice_mark_1..6, kcd2mp_dice_cast, kcd2mp_dice_bank,
-- kcd2mp_dice_yield) on physical keys confirmed to have NOTHING else bound
-- to them anywhere in the file, so there is no side effect to tolerate at
-- all. map="interaction" was chosen because it was directly observed still
-- firing (use/talk/trigger_use) immediately after sitting down, unlike
-- "sitting"-shadowed actions.
--
-- Keys: F2, F4, F5, F6, F7, F8 mark dice 1-6 (see DICE_MARK_KEYS in the
-- panel code); F9 casts/sets aside; hold F11 banks; hold F12 yields; U
-- clears every pending mark without rerolling (KCD2MP_DiceUnmarkAll).
--
-- Four traps paid for finding these, none visible from this file alone:
--   1. Numpad 1-6 checked clean here (nothing else in this XML claims them)
--      but wasn't -- action_qam_N's weapon_slot_N sibling lives under
--      apse_qam_slots, which turned out to stay active during ordinary
--      play, not just with a menu open. Adding our own action to a key
--      never suppresses whatever else is already bound there.
--   2. The Numpad operator keys (*, +, -) and F1/F3/F10 are bound to
--      engine-level debug toggles (photo mode, flight mode, AI/animation
--      debug draw) entirely OUTSIDE this XML -- invisible to any check of
--      this file's contents. Numpad / is worse: it CRASHED the game.
--   3. H is also "clean" by this file's contents and is not safe either --
--      it opens a Modding Tools debug menu, same invisible-to-this-file
--      shape as trap 2. Every key actually used below was pressed live,
--      one at a time, and watched for anything happening at all -- that is
--      the only real proof; this file's contents are not enough on their
--      own, and neither is "nothing obviously bad happened" (Numpad 1-6).
--   4. Numpad . is a DIFFERENT kind of failure: not dangerous, just a dead
--      binding. "np_decimal" is not a control name this engine's action-map
--      recognises at all, so the whole entry silently never registers --
--      no crash, no debug menu, just nothing, indistinguishable at a glance
--      from a key that works but has nothing to do yet. Moved to U, which
--      is both unclaimed AND confirmed to actually fire once wired up.
--
-- Bank/yield tried U/Y briefly (to leave F11/F12 free for a future
-- invite-accept/decline bind) -- U/Y worked, but simplicity won: back on
-- F11/F12, which were already proven end-to-end, and U repurposed for
-- cancel instead of adding a fifth key family to the set.
--
-- All of these are gated on KCD2MP.dice.open, so none can fire outside a
-- match. The mp_dice_* console commands remain and always work.
local DICE_CONFIRM_ACTIONS = { ["kcd2mp_dice_cast"]  = true, ["toggle_torch"] = true }
local DICE_BANK_ACTIONS    = { ["kcd2mp_dice_bank"]  = true, ["knock_out"]    = true }  -- held
local DICE_YIELD_ACTIONS   = { ["kcd2mp_dice_yield"] = true, ["call"]         = true }  -- held
local DICE_CANCEL_ACTIONS  = { ["kcd2mp_dice_cancel"] = true }

-- Marking a die. kcd2mp_dice_mark_N's trailing digit is the die index, which
-- lines up with the numbered row drawn under the dice.
local function diceMarkIndex(action)
    local n = action:match("^kcd2mp_dice_mark_(%d)$")
    if n then
        local i = tonumber(n)
        if i and i >= 1 and i <= 6 then return i end
    end
    return nil
end

local function handleAction(action, activation, value)
    if AXIS_ACTIONS[action] then return end
    if KCD2MP.logActions then
        mp_log(string.format("ACT '%s' a=%s", tostring(action), tostring(activation)))
    end

    -- Only consume these while a prompt is actually up, so they never interfere
    -- with normal dialogue or menus.
    if KCD2MP.invite and activation == "press" then
        if ACCEPT_ACTIONS[action] then
            pcall(KCD2MP_AcceptInvite)
            return
        end
        if DECLINE_ACTIONS[action] then
            pcall(KCD2MP_DeclineInvite)
            return
        end
    end

    -- Dice overlay keys (WO-6). Checked BEFORE the invite key below, and every
    -- branch is gated on the board actually being open, so none of this can
    -- interfere with normal play -- or with an NPC dice game, which never opens
    -- this board.
    if KCD2MP.dice and KCD2MP.dice.open then
        if activation == "press" then
            local mark = diceMarkIndex(action)
            if mark then pcall(KCD2MP_DiceMark, mark); return end
            if DICE_CONFIRM_ACTIONS[action] then pcall(KCD2MP_DiceConfirm); return end
            if DICE_CANCEL_ACTIONS[action] then pcall(KCD2MP_DiceUnmarkAll); return end
            -- Bank and yield are irreversible, so they are hold-to-confirm:
            -- start the timer on press, and only KCD2MP_DiceHoldTick fires them.
            if DICE_BANK_ACTIONS[action]  then pcall(KCD2MP_DiceHoldBegin, "bank");    return end
            if DICE_YIELD_ACTIONS[action] then pcall(KCD2MP_DiceHoldBegin, "forfeit"); return end
        elseif activation == "release" then
            if DICE_BANK_ACTIONS[action] or DICE_YIELD_ACTIONS[action] then
                pcall(KCD2MP_DiceHoldEnd)
                return
            end
        end
    end

    -- WO-98 Phase 6: every F11/F12 press the hook actually receives, with the
    -- state it landed in. A prompt window with a reported press and no MP-KEY
    -- line means the input never reached Lua (cutscene input context).
    if activation == "press" and (action == "kcd2mp_dice_bank" or action == "kcd2mp_dice_yield") and KCD2MP.quest then
        KCD2MP._stats.keys = KCD2MP._stats.keys + 1
        mp_log(string.format("MP-KEY action=%s prompt=%d pending=%d waiting=%d cutscene=%d dice=%d",
            tostring(action), KCD2MP.quest.prompt and 1 or 0, KCD2MP.quest.pendingPrompt and 1 or 0,
            (KCD2MP_QuestWaitingVisible and KCD2MP_QuestWaitingVisible()) and 1 or 0,
            KCD2MP.cutsceneActive and 1 or 0, (KCD2MP.dice and KCD2MP.dice.open) and 1 or 0))
    end

    -- Shared Quests readiness prompt (WO-94). Same two actions as the
    -- dice-invite prompt above (kcd2mp_dice_bank = F11, kcd2mp_dice_yield =
    -- F12). Reaches here only when no invite is up (that branch returned)
    -- and no dice board is open (that branch returned for these actions),
    -- so the three prompts can never double-consume one press. Like every
    -- branch in this hook it runs AFTER the game's own handler and cannot
    -- block or intercept any other input.
    if KCD2MP.quest and KCD2MP.quest.prompt and activation == "press" then
        if ACCEPT_ACTIONS[action] then
            pcall(KCD2MP_QuestAnswer, true)
            return
        end
        if DECLINE_ACTIONS[action] then
            pcall(KCD2MP_QuestAnswer, false)
            return
        end
    end
    -- WO-96: with no prompt up, F12 hides a visible WAITING_FOR_PEER line
    -- (until the divergence pair changes). F11 alone does nothing here.
    if KCD2MP.quest and not KCD2MP.quest.prompt and activation == "press" and DECLINE_ACTIONS[action]
       and KCD2MP_QuestWaitingVisible and KCD2MP_QuestWaitingVisible() then
        pcall(KCD2MP_QuestWaitingDismiss)
        return
    end

    -- Challenge the nearest player to dice (WO-5, gated to a real table in
    -- WO-6). Unlike accept/decline this has no KCD2MP.invite-style gate to
    -- check first -- see the comment on DICE_INVITE_ACTIONS above for why
    -- that's an accepted risk here. KCD2MP_InviteDiceAtTable refuses unless a
    -- DiceInteractor entity is actually in range, so a spurious press is now a
    -- no-op rather than an unwanted invite.
    if DICE_INVITE_ACTIONS[action] and activation == "press" then
        pcall(KCD2MP_InviteDiceAtTable)
        return
    end

    -- Combat visibility (WO-39): mirror attack/block inputs to peers.
    -- Deliberately NO return -- this hook must never consume combat input;
    -- the game's own handler already ran (we are chained after it), and a
    -- swing that also triggered something else must keep doing so.
    if COMBAT_SWING_ACTIONS[action] then
        if activation == "press" or activation == 1 then
            local now = os.clock()
            if now - (KCD2MP._lastSwingEmit or 0) >= 0.15 then
                KCD2MP._lastSwingEmit = now
                KCD2MP_EmitEvent("combat", "swing")
            end
        end
    elseif COMBAT_BLOCK_ACTIONS[action] then
        -- 'block' never fires 'press' on this build -- only a per-frame
        -- 'hold' stream and a 'release' (confirmed live). Edge-detect the
        -- first hold so one raise of the guard is one event, not sixty.
        local held = (activation == "press" or activation == "hold"
                      or activation == 1 or activation == 2)
        if held and not KCD2MP._blockHeld then
            KCD2MP._blockHeld = true
            -- WO-40 Phase 6 (the choke miscue): the 'block' action also fires
            -- during weaponless grabs -- the footage's choke-out rendered as
            -- a phantom shield-block on the observer's screen. A block cue
            -- with no weapon out is never a real guard; drop it. Real
            -- unarmed blocking is rare and reads fine as nothing.
            if KCD2MP.weaponDrawn then
                KCD2MP_EmitEvent("combat", "block")
            end
        elseif activation == "release" then
            KCD2MP._blockHeld = false
        end
    end

    -- Toggle-style: each press of C flips sneak on/off
    if SNEAK_TOGGLE_ACTIONS[action] and activation == "press" then
        KCD2MP.playerSneaking = not KCD2MP.playerSneaking
        mp_log("SNEAK=" .. tostring(KCD2MP.playerSneaking) .. " toggle via '" .. action .. "'")
        return
    end

    -- Hold-style: press = on, release = off
    if SNEAK_HOLD_ACTIONS[action] then
        local pressed = (activation == "press" or activation == "hold"
                         or activation == 1 or activation == 2)
        if pressed ~= KCD2MP.playerSneaking then
            KCD2MP.playerSneaking = pressed
            mp_log("SNEAK=" .. tostring(pressed) .. " hold via '" .. action .. "'")
            KCD2MP.logActions = false
        end
    end
end

-- ============================================================================
-- ===== Shared Quests (WO-94) ================================================
-- ============================================================================
--
-- The readiness prompt. Scope is deliberately narrow: the 32 main-story
-- quests (ProductionCode M01-M51, base game). Side quests, activities,
-- events and DLC content have no registry entry and therefore trigger none
-- of this -- no detection, no prompt, no keys. They keep exactly the
-- behaviour multiplayer already has, with WO-90's divergence release as the
-- only safety net, unchanged.
--
-- Flow (docs/WO-94-findings.md):
--   1. This client's agent tells the mod which main quest it is on (from the
--      questNameOverride marker WO-90 already parses) and which level is
--      loaded (from the engine's "Loading level <name>" log line).
--   2. KCD2MP_QuestProximityTick (1 Hz, rides the emitter) compares the
--      player's position against that quest's positioned beats in the
--      generated registry below. Inside mp_quest_radius it emits ONE
--      "quest_approach <quest>.<trigger>" event, once per beat. Since WO-96
--      this is a HINT for which beat to offer, never the trigger.
--   3. WO-96: the trigger is the agent's story-divergence signal -- both
--      markers known and different, computed on every objective change with
--      no proximity condition (docs/WO-95-findings.md s5). The agent calls
--      KCD2MP_QuestDivergence with who is behind; the mod picks the peer
--      quest's beat (or enters WAITING_FOR_PEER when there is none to offer)
--      and calls KCD2MP_QuestShowPrompt. The prompt is a persistent DrawText
--      line in the same 8 ms label loop that draws the ping -- it stays until
--      it is answered or made moot. It intercepts nothing: the OnAction hook
--      runs AFTER the game's own handler and cannot consume input.
--   4. F11 = catch up, F12 = stay. These are kcd2mp_dice_bank / _yield, the
--      dice minigame's hold-to-bank / hold-to-yield keys, already reused by
--      the dice-invite prompt for accept/decline (WO-33). Safe by
--      construction, not by testing: the dice board consumes them ONLY while
--      KCD2MP.dice.open, and its branch runs first and returns, so a prompt
--      raised during a live match simply waits until the match ends.
--   5. Yes fires wh_concept_HasteTrigger <quest>.<trigger> through
--      System.ExecuteCommand (WO-92 s2.1, in production at closeVisorOn) and
--      opens a hazard window. Not answering is a first-class choice: nothing
--      happens, WO-90's divergence release keeps doing its job.
--   6. Nothing pauses, for anyone, on any path.
--
-- Hazard window (required by the maintainer's "fix it when we see it" plan):
-- while a catch-up fired HERE is draining, or a peer has told us one is
-- draining THERE, every death, teleport, clock change or chain suspension
-- this file already notices is ALSO logged as a distinct
-- "CATCHUP-HAZARD <kind> ..." line naming the beat, who fired it and how
-- long ago. The ordinary lines still print; this is an extra, greppable one.

KCD2MP.quest = {
    enabled        = true,     -- mp_quest_sync on|off
    radius         = 35.0,     -- metres; mp_quest_radius <m>
    windowS        = 120.0,    -- hazard window after a fire; mp_quest_window <s>
    rearmS         = 600.0,    -- a beat announces again only after this long
    level          = nil,      -- lowercase level name, from the agent
    current        = nil,      -- lowercase main-quest name, from the agent (nil = not on a main quest)
    announced      = {},       -- "<quest>.<trigger>" -> os.clock() of the last announce
    declined       = {},       -- "<quest>.<trigger>" -> true (F12 pressed; never re-prompted this session)
    prompt         = nil,      -- {ghostId, who, beat, shownAt}
    catchup        = nil,      -- {beat, who, startedAt, untilT}  -- a fire from THIS machine
    catchupRemote  = {},       -- ghostId -> {beat, who, startedAt, untilT}
    lastTickAt     = 0,
    lastPos        = nil,      -- {x,y,z,at} for local teleport detection inside a window
    hazardN        = 0,
    approachN      = 0,
    fireN          = 0,
    -- WO-96: divergence-gated prompting. The prompt is raised when the two
    -- players' story markers DIFFER (the agent's [story] divergence signal),
    -- not when a peer walks past a beat; proximity is now only a hint for
    -- WHICH beat to offer. When there is nothing left to offer the mod
    -- enters WAITING_FOR_PEER -- a status line, never a lock.
    promptGapS     = 60.0,     -- minimum interval between prompts per peer (debounce)
    fired          = {},       -- "<quest>.<trigger>" -> true: fired HERE this session (spent; never offered again)
    lastPromptAt   = {},       -- ghostId -> os.clock() of the last prompt raised for that peer
    hint           = {},       -- ghostId -> last quest_approach beat that peer announced (beat hint only)
    waiting        = {},       -- ghostId -> {who, rel, key, peerObj, localObj, title, why, since, dismissed, pendingBeat}
    divergeN       = 0,
    waitN          = 0,
}
local Q = KCD2MP.quest

-- @@WO94-MAINQUEST-REGISTRY-BEGIN@@
-- GENERATED by tools/Build-MainQuestRegistry.ps1 -- do not edit by hand.
-- Source: Quests/Final in Scripts.pak sha256 bf3eca1046f4c2cb619a005cada24ea8cb0b2c9a598b5882e4ec3d6160485166
-- 32 main quests (M01-M51, base game only), 1014 Haste triggers, 138 positioned, 53 fireable.
-- A beat is fireable when it is positioned (proximity can see it) AND cumulative
-- AND not one of Warhorse's own test/debug/gamescom entries
-- (it has Prerequisites or fires other triggers -- a real "set the world up for
-- this point" entry, not a lone setter or a bare teleport). See docs/WO-94-findings.md.
-- Fields: key = the questNameOverride marker stem the engine writes (matched
-- case-insensitively; NOT always the lowercased name); title = English journal title;
-- t = trigger name (fire as "<name>.<t>"); x,y,z = fixed point; e = level entity
-- resolved live; src = own|chain (where on the plan the position came from).
KCD2MP_MAINQUESTS = {
    { code = "M01", name = "prepadeni", key = "prepadeni", title = "Easy Riders", level = "trosecko", triggers = 22, beats = { } },
    { code = "M02", name = "zachrana", key = "zachrana", title = "Fortuna", level = "trosecko", triggers = 32, beats = { } },
    { code = "M03", name = "socky", key = "socky", title = "Laboratores", level = "trosecko", triggers = 9, beats = {
        { t = "_initAndStart", x = 2342.72, y = 2068.25, z = 112.25, src = "chain" },
    } },
    { code = "M05", name = "svatba", key = "svatba", title = "Wedding Crashers", level = "trosecko", triggers = 25, beats = {
        { t = "02_init_blacksmith", e = "ttac_blacksmith", src = "own" },
        { t = "03_init_concubine", e = "tvez_concubine", src = "own" },
    } },
    { code = "M06", name = "naTroskach", key = "natroskach", title = "For Whom the Bell Tolls", level = "trosecko", triggers = 16, beats = { } },
    { code = "M07", name = "nebakovPruzkum", key = "nebakovpruzkum", title = "Back in the Saddle", level = "trosecko", triggers = 24, beats = {
        { t = "skipToNebakovPolylog", e = "nebakovPruzkum_tagpoint_cutscene_nebakovArrival_playerHorse", src = "chain" },
        { t = "prepareNebakov", e = "nebakovPruzkum_tagpoint_cutscene_nebakovArrival_playerHorse", src = "own" },
        { t = "skipToNebakov", e = "nebakovPruzkum_tagpoint_cutscene_nebakovArrival_playerHorse", src = "own" },
    } },
    { code = "M08", name = "mucirna", key = "semin", title = "Necessary Evil", level = "trosecko", triggers = 34, beats = {
        { t = "InstantTourToSemin", x = 2441.97, y = 2641.28, z = 203.36, src = "chain" },
    } },
    { code = "M09", name = "utokNaNebakov", key = "utoknanebakov", title = "For Victory!", level = "trosecko", triggers = 43, beats = {
        { t = "startQuest_preparedForDialog", x = 2418.77, y = 2611.34, z = 219.15, src = "own" },
    } },
    { code = "M10", name = "bohutovaVlozka", key = "bohutovavlozka", title = "Divine Messenger", level = "trosecko", triggers = 30, beats = {
        { t = "01_initAndStart", e = "bohutovaVlozka_lastQuestStartingSpot", src = "chain" },
    } },
    { code = "M11", name = "nebakovObrana", key = "nebakovobrana", title = "The Finger of God", level = "trosecko", triggers = 51, beats = {
        { t = "97_nebakovObrana_start", x = 1909.00, y = 1209.00, z = 54.00, src = "own" },
        { t = "98_nebakovObrana_bitva", x = 1909.00, y = 1209.00, z = 54.00, src = "own" },
        { t = "99_nebakovObrana_bitva_withFriends", x = 1909.00, y = 1209.00, z = 54.00, src = "own" },
        { t = "99z_nebakovObrana_bitva_withFriends_fast", x = 1909.00, y = 1209.00, z = 54.00, src = "own" },
    } },
    { code = "M12", name = "vezniNaTroskach", key = "vezninatroskach", title = "Storm", level = "trosecko", triggers = 33, beats = {
        { t = "01_initAndStart", x = 1940.78, y = 1126.36, z = 54.04, src = "chain" },
    } },
    { code = "M30", name = "posledniPomazani", key = "poslednipomazani", title = "Last Rites", level = "kutnohorsko", triggers = 3, beats = { } },
    { code = "M31", name = "prijezdNaSuchdol", key = "prijezdnasuchdol", title = "The Sword and the Quill", level = "kutnohorsko", triggers = 10, beats = {
        { t = "01_initAndStart", e = "prijezdNaSuchdol_startFirstChat", src = "chain" },
    } },
    { code = "M32", name = "sedmStatecnych", key = "sedmstatecnych", title = "Speak of the Devil", level = "kutnohorsko", triggers = 18, beats = {
        { t = "01_initAndStart", e = "sedmStatecnych_playerStartQuest", src = "own" },
    } },
    { code = "M33", name = "hledaniLichtenstejna", key = "hledanilichtenstejna", title = "Into the Underworld", level = "kutnohorsko", triggers = 36, beats = {
        { t = "initAndStart", x = 3165.71, y = 653.04, z = 53.63, src = "chain" },
    } },
    { code = "M34", name = "kralovskeStribro", key = "kralovskestribro", title = "Via Argentum", level = "kutnohorsko", triggers = 19, beats = {
        { t = "01_initAndStart", x = 3228.60, y = 852.93, z = 51.55, src = "own" },
        { t = "02_startMines", x = 2913.14, y = 2226.35, z = 118.37, src = "own" },
        { t = "03_gatheredNumbers", x = 2943.04, y = 2259.88, z = 115.10, src = "own" },
        { t = "04_goToSmelter", x = 2931.86, y = 2239.91, z = 115.27, src = "own" },
        { t = "05_goToSecretMint", x = 3555.39, y = 1797.44, z = 107.00, src = "own" },
    } },
    { code = "M35", name = "zachranaPtacka", key = "zachranaptacka", title = "Taking French Leave", level = "kutnohorsko", triggers = 21, beats = {
        { t = "01_initAndStart", e = "zachranaPtacka_guardWaitingSpotArea", src = "chain" },
        { t = "03_afterDialogueWithRoza", e = "kmal_hastal", src = "own" },
    } },
    { code = "M37a", name = "setkaniVRatbori1", key = "setkanivratbori1", title = "The King's Gambit", level = "kutnohorsko", triggers = 53, beats = {
        { t = "02_initAndStart_cutscene", e = "setkaniVRatbori1_start_cutscene", src = "chain" },
        { t = "04_setTimeTo21", e = "setkaniVRatbori1_test_playerTeleport", src = "own" },
        { t = "36_jumpToZikmundAulitzGameplay", e = "setkaniVRatbori1_councillorsLeaving_playerPoint", src = "own" },
    } },
    { code = "M37b", name = "setkaniVRatbori2", key = "setkanivratbori2", title = "The Feast", level = "kutnohorsko", triggers = 16, beats = {
        { t = "01_init", x = 1423.10, y = 3820.92, z = 126.57, src = "chain" },
    } },
    { code = "M38", name = "sedmStatecnych2", key = "sedmstatecnych2", title = "The Devil's Pack", level = "kutnohorsko", triggers = 48, beats = {
        { t = "01_initAndStart", e = "kcer_kubenka", src = "own" },
    } },
    { code = "M42", name = "pogrom", key = "pogrom", title = "Exodus", level = "kutnohorsko", triggers = 40, beats = {
        { t = "_init_noDialogue", e = "pogrom_startPointPlayer", src = "chain" },
        { t = "_initAndStart", e = "pogrom_startPointPlayer", src = "chain" },
    } },
    { code = "M44a", name = "zikmunduvTabor", key = "zikmunduvtabor", title = "The Lion's Den", level = "kutnohorsko", triggers = 50, beats = { } },
    { code = "M44b", name = "utokNaMalesov", key = "utok_na_malesov", title = "Dancing with the Devil", level = "kutnohorsko", triggers = 36, beats = {
        { t = "init", e = "utokNaMalesov_playerInitialCertovkaPosition", src = "chain" },
    } },
    { code = "M45", name = "papezskyLegat", key = "papezskylegat", title = "Oratores", level = "kutnohorsko", triggers = 27, beats = {
        { t = "_initAndStart", x = 800.31, y = 3334.47, z = 142.61, src = "chain" },
        { t = "skipToChase", x = 3439.31, y = 992.24, z = 51.44, src = "own" },
    } },
    { code = "M46", name = "prepadeniVlasskehoDvora", key = "prepadenivlasskehod", title = "The Italian Job", level = "kutnohorsko", triggers = 39, beats = { } },
    { code = "M47", name = "erik", key = "erik", title = "Civitas Pragensis", level = "kutnohorsko", triggers = 15, beats = {
        { t = "00_erik_init", e = "erik_nocNaHradbach_player", src = "chain" },
        { t = "01_erik_startAndInit", e = "erik_nocNaHradbach_player", src = "chain" },
    } },
    { code = "M48a", name = "oblehaniSuchdole", key = "oblehanisuchdole", title = "So it beginsâ€¦", level = "kutnohorsko", triggers = 54, beats = {
        { t = "000_oblehaniStart", e = "oblehaniSuchdole_zizkaVezeZasobyAJeNapaden_player", src = "chain" },
    } },
    { code = "M48b", name = "rutinaAVypad", key = "m48b__rutina_a_vypad", title = "Besieged", level = "kutnohorsko", triggers = 66, beats = { } },
    { code = "M48c", name = "hladAZmar", key = "m48c__hlad_a_zmar", title = "Hunger and Despair", level = "kutnohorsko", triggers = 29, beats = { } },
    { code = "M49", name = "stealthMiseZaJindru", key = "stealthmisezajindru", title = "Reckoning", level = "kutnohorsko", triggers = 8, beats = { } },
    { code = "M50", name = "zoufalaObranaZaBohutu", key = "bitvazabohutu", title = "Last Rites", level = "kutnohorsko", triggers = 41, beats = { } },
    { code = "M51", name = "finale", key = "finale", title = "Judgement Day", level = "kutnohorsko", triggers = 66, beats = {
        { t = "01_initAndStart_Mikes_Kozlik_Sam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "02_initAndStart_Wolfram_Kozlik_Sam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "03_initAndStart_Mikes_Dobros_Sam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "04_initAndStart_Wolfram_Dobros_Sam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "05_initAndStart_Mikes_Kozlik_NoSam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "06_initAndStart_Mikes_Kozlik_Sam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "07_initAndStart_Mikes_Kozlik_NoSam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "08_initAndStart_Wolfram_Kozlik_NoSam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "09_initAndStart_Wolfram_Kozlik_Sam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "10_initAndStart_Wolfram_Kozlik_NoSam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "11_initAndStart_Mikes_Dobros_NoSam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "12_initAndStart_Mikes_Dobros_Sam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "13_initAndStart_Mikes_Dobros_NoSam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "14_initAndStart_Wolfram_Dobros_NoSam_Dog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "15_initAndStart_Wolfram_Dobros_Sam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
        { t = "16_initAndStart_Wolfram_Dobros_NoSam_NoDog", e = "finale_previousQuestEnd", src = "chain" },
    } },
}
-- @@WO94-MAINQUEST-REGISTRY-END@@

-- @@WO96-OBJECTIVE-FIXES-BEGIN@@
-- GENERATED by tools/Find-ObjectiveTriggers.ps1 -- do not edit by hand.
-- 17 of 626 main-quest objectives have a CLEAN narrow Haste trigger that grants them
-- (its OnTrigger drives only that objective's State node, no Prerequisites, no
-- ConsoleCommands, no other targets; WO-92 s6.1's targeted-setter population),
-- MINUS the 5 whose transitive On<State> pulse chain reaches a
-- CutsceneHandler.EnqueueCutscene (WO-97 Phase 0; KCD2MP_OBJECTIVE_FIX_HAZARDS).
-- The mod offers one only when the local player is IN that quest and the peer's
-- fingerprint shows the objective in exactly that state. Everything else --
-- 600-odd objectives, the sacks of M03 among them -- has no such trigger and is
-- reported as a gap only. See docs/WO-96-findings.md s4, docs/WO-97-findings.md s1.
KCD2MP_OBJECTIVE_FIXES = {
    { q = "zachrana", o = "goToSleep_visual", dir = "active", t = "zachrana.goToSleep_activate" },
    { q = "mucirna", o = "jed_s_vojaky_a_ptackem_na_semin", dir = "active", t = "mucirna._activateRideToSeminObjective" },
    { q = "nebakovObrana", o = "odraz_utok_na_branu", dir = "done", t = "nebakovObrana.bitva_7_branaOdrazeno" },
    { q = "sedmStatecnych", o = "zachran_sucheho_certa", dir = "done", t = "sedmStatecnych.certZachranen" },
    { q = "hledaniLichtenstejna", o = "searchForKozina", dir = "done", t = "hledaniLichtenstejna.05___complete_searchForKozina_baths" },
    { q = "hledaniLichtenstejna", o = "talkToKaterina", dir = "done", t = "hledaniLichtenstejna.03___complete_talkToKaterina" },
    { q = "kralovskeStribro", o = "jdi_do_ruthardky", dir = "done", t = "kralovskeStribro.complete_findRuthard" },
    { q = "zachranaPtacka", o = "dostan_se_tajnou_chodbou_na_malesov", dir = "done", t = "zachranaPtacka.07_startMalesovMeetupCutscene" },
    { q = "setkaniVRatbori1", o = "getDocument", dir = "done", t = "setkaniVRatbori1.06_getDocument" },
    { q = "pogrom", o = "probij_se_domem", dir = "done", t = "pogrom.03b_completeMothersPart" },
    { q = "zikmunduvTabor", o = "bring_deserters_report", dir = "active", t = "zikmunduvTabor.deserters_getItem" },
    { q = "prepadeniVlasskehoDvora", o = "prones_zaverecnou_rec", dir = "active", t = "prepadeniVlasskehoDvora.courtHall_finalVerdict" },
    { q = "oblehaniSuchdole", o = "odraz_nepratelsky_utok", dir = "done", t = "oblehaniSuchdole.012_konecBitvy" },
    { q = "hladAZmar", o = "dones_ptackovi_neco_k_jidlu", dir = "done", t = "hladAZmar.hideBeforeBattleMainObjective" },
    { q = "finale", o = "dojdi_nabrousit_hanusovi_mec", dir = "active", t = "finale._sharpenSwordObjectiveActive" },
    { q = "finale", o = "dojdi_nabrousit_hanusovi_mec", dir = "done", t = "finale._returnSwordToHanus" },
    { q = "finale", o = "setkej_se_s_rackem", dir = "active", t = "finale.talkToRacekObjective" },
}

-- @@WO96-OBJECTIVE-FIXES-END@@

-- WO-97 Phase 0: the five entries WO-96 shipped and this WO removed, kept here
-- as a named blocklist so KCD2MP_QuestIsRegistryBeat refuses them even if an
-- older peer, an older pak or a hand-typed console line names one. Each value
-- is the pulse chain that reaches a cutscene (code-verified).
KCD2MP_OBJECTIVE_FIX_HAZARDS = {
    ["vezniNaTroskach.startApolenaGameplay"]           = "cutscene: cin_m1280t_vezninatroskach__zikmund_letter.enqueue_cs",
    ["sedmStatecnych.sedmStatecnych_kubenkaZachranen"] = "cutscene: trialog_s_zizkou_a_kubenkou -> CutsceneHandler",
    ["setkaniVRatbori2.pickWineSkip"]                  = "cutscene: cin_m3780k_setkaniratbordva__ratbor_attack",
    ["pogrom.04a_cutscene_blockadeFire"]               = "cutscene: cin_m4220k_pogrom__blockade_fire",
    ["prepadeniVlasskehoDvora.init_end2"]              = "cutscene: fader_a_priprava_npc -> CutsceneHandler",
}

-- Lookup over the generated fix table: "<quest>|<objective>|<active|done>" -> entry,
-- and the set of fix trigger paths (a second, equally bounded registry that
-- KCD2MP_QuestIsRegistryBeat accepts, so a fix fires through the same
-- KCD2MP_QuestFire channel, hazard window and spent-gate as a catch-up beat).
KCD2MP._fixIndex = nil
local function fixIndex()
    if KCD2MP._fixIndex then return KCD2MP._fixIndex end
    local byKey, byPath, n = {}, {}, 0
    for _, f in ipairs(KCD2MP_OBJECTIVE_FIXES or {}) do
        byKey[f.q .. "|" .. f.o .. "|" .. f.dir] = f
        byPath[f.t] = f
        n = n + 1
    end
    KCD2MP._fixIndex = { byKey = byKey, byPath = byPath, n = n }
    return KCD2MP._fixIndex
end

-- Lookups over the generated table, built once on first use. The agent hands
-- us the quest token of the engine's @qname_ marker (suffix stripped,
-- lowercased) and it is matched against each quest's generated `key`, which
-- is the qname literal found in that quest's own XML root -- NOT the XML
-- name: six of the 32 differ (M08 mucirna is "@qname_semin" = Necessary
-- Evil; M44b utokNaMalesov is "utok_na_malesov"; M50 is "bitvazabohutu").
-- Beat paths are matched exactly: both ends run the same generated table.
KCD2MP._questIndex = nil
local function questIndex()
    if KCD2MP._questIndex then return KCD2MP._questIndex end
    local byLower, byPath, nQuests, nBeats = {}, {}, 0, 0
    for _, q in ipairs(KCD2MP_MAINQUESTS or {}) do
        nQuests = nQuests + 1
        byLower[string.lower(q.key or q.name)] = q
        for _, b in ipairs(q.beats or {}) do
            byPath[q.name .. "." .. b.t] = { quest = q, beat = b }
            nBeats = nBeats + 1
        end
    end
    KCD2MP._questIndex = { byLower = byLower, byPath = byPath, nQuests = nQuests, nBeats = nBeats }
    return KCD2MP._questIndex
end

-- True only for a beat the generated registry can fire. Everything this
-- section does downstream of a peer's message goes through here first, so a
-- string that is not one of the 32 quests' registered beats is refused
-- before it can reach ExecuteCommand or the screen.
function KCD2MP_QuestIsRegistryBeat(beat)
    if type(beat) ~= "string" or beat == "" or #beat > 128 then return false end
    if not beat:match("^[%w_%.]+$") then return false end
    -- WO-97: a path this WO withdrew is refused before anything else, so an
    -- older peer, an older pak or a typed console line cannot reach it.
    local haz = KCD2MP_OBJECTIVE_FIX_HAZARDS and KCD2MP_OBJECTIVE_FIX_HAZARDS[beat]
    if haz then
        mp_log("QUEST refused '" .. beat .. "': WO-97 hazard -- " .. haz)
        return false
    end
    return questIndex().byPath[beat] ~= nil or fixIndex().byPath[beat] ~= nil   -- WO-96: or a generated narrow fix
end

-- Agent -> mod. "Loading level <name>" from kcd.log, lowercased here.
function KCD2MP_QuestSetLevel(name)
    local s = tostring(name or ""):lower():gsub("%s+", "")
    if s == "" then return end
    if Q.level ~= s then
        Q.level = s
        mp_log("QUEST level is now '" .. s .. "'")
    end
end

-- Agent -> mod. The main quest this player is on, from the objective marker,
-- or "" when the marker names a quest outside the registry (side content).
function KCD2MP_QuestSetCurrent(questLower)
    local s = tostring(questLower or ""):lower():gsub("%s+", "")
    if s == "" then s = nil end
    if Q.current ~= s then
        local q = s and questIndex().byLower[s] or nil
        Q.current = s
        mp_log(string.format("QUEST current main quest: %s%s", tostring(s),
            (s and not q) and " (NOT in the main-quest registry -- side content, no detection)"
            or (q and string.format(" (%s %s, %d fireable beats)", q.code, tostring(q.title or q.name), #(q.beats or {})) or "")))
    end
end

-- Distance from the player to one registry beat, or nil when it cannot be
-- known right now (entity-positioned beat whose entity is not streamed in).
local function questBeatDist2(b, ppos)
    local bx, by, bz = b.x, b.y, b.z
    if b.e then
        local ent = System.GetEntityByName(b.e)
        if not ent then return nil end
        local ok, ep = pcall(function() return ent:GetWorldPos() end)
        if not ok or not ep then return nil end
        bx, by, bz = ep.x, ep.y, ep.z
    end
    if not bx then return nil end
    local dx, dy = bx - ppos.x, by - ppos.y
    return dx * dx + dy * dy      -- planar: a beat on a wall above or a cellar below still counts
end

-- 1 Hz, from KCD2MP_EmitTick. Announces the nearest un-announced beat of
-- the current main quest inside the radius. Also closes an expired hazard
-- window and watches for a local teleport while one is open.
function KCD2MP_QuestProximityTick()
    local now = os.clock()
    if now - (Q.lastTickAt or 0) < 1.0 then return end
    Q.lastTickAt = now

    KCD2MP_QuestWindowTick(now)
    if KCD2MP_QuestWaitingTick then pcall(KCD2MP_QuestWaitingTick, now) end   -- WO-96: deferred offers

    if not Q.enabled or not Q.current or not player then return end
    local q = questIndex().byLower[Q.current]
    if not q or not q.beats or #q.beats == 0 then return end
    -- Fixed-point beats are per level; the two maps' coordinate ranges
    -- overlap, so with the level known, a beat on the other map is skipped.
    -- Entity-positioned beats are level-safe by themselves (the entity is
    -- simply absent on the other map).
    local levelKnown = Q.level ~= nil
    local ppos = nil
    pcall(function() ppos = player:GetWorldPos() end)
    if not ppos then return end

    local r2 = Q.radius * Q.radius
    local best, bestD2 = nil, nil
    for _, b in ipairs(q.beats) do
        local skip = (not b.e) and levelKnown and q.level ~= Q.level
        if not skip then
            local path = q.name .. "." .. b.t
            local last = Q.announced[path]
            if not last or (now - last) >= Q.rearmS then
                local d2 = questBeatDist2(b, ppos)
                if d2 and d2 <= r2 and (not bestD2 or d2 < bestD2) then best, bestD2 = b, d2 end
            end
        end
    end
    if best then
        local path = q.name .. "." .. best.t
        Q.announced[path] = now
        Q.approachN = (Q.approachN or 0) + 1
        mp_log(string.format("QUEST-APPROACH %s (%s) at %.1fm -- announcing to peers", path, q.code, math.sqrt(bestD2)))
        KCD2MP_EmitEvent("quest_approach", path)
    end
end

-- Agent -> mod. diverged is 1 when the agent knows both objectives and they
-- differ; anything else means "do not prompt". Since WO-96 the agent calls
-- this from the divergence path (KCD2MP_QuestDivergence below), not from a
-- peer's proximity announce; reason is "divergence" or "test".
function KCD2MP_QuestShowPrompt(ghostId, who, beat, diverged, reason)
    beat = tostring(beat or "")
    if not KCD2MP_QuestIsRegistryBeat(beat) then
        mp_log("QUEST-PROMPT refused: '" .. beat .. "' is not a registered main-quest beat")
        return false
    end
    if not Q.enabled then
        mp_log("QUEST-PROMPT suppressed (mp_quest_sync off): " .. beat)
        return false
    end
    if tonumber(diverged) ~= 1 then
        mp_log("QUEST-PROMPT not shown for " .. beat .. ": objectives not known to differ")
        return false
    end
    if Q.declined[beat] then
        mp_log("QUEST-PROMPT not shown for " .. beat .. ": declined earlier this session")
        return false
    end
    if Q.catchup then
        mp_log("QUEST-PROMPT not shown for " .. beat .. ": a catch-up is already in progress here")
        return false
    end
    if Q.fired[beat] then
        mp_log("QUEST-PROMPT not shown for " .. beat .. ": already fired here this session (spent)")
        return false
    end
    -- WO-98 Phase 5: a prompt that can be shown but not acted on is worse
    -- than no prompt. Input does not reach the OnAction hook during a
    -- cutscene (observed: F11 pressed, zero CATCHUP/QuestFire lines), so the
    -- offer is parked and re-raised the moment the cutscene ends.
    if KCD2MP.cutsceneActive then
        Q.pendingPrompt = { ghostId = tostring(ghostId), who = tostring(who or ("player " .. tostring(ghostId))),
                            beat = beat, reason = tostring(reason or "divergence") }
        mp_log("QUEST-PROMPT held: a cutscene is playing (" .. tostring(KCD2MP.cutsceneName) .. ") -- "
            .. beat .. " will be offered when it ends")
        return "held"
    end
    local hit = questIndex().byPath[beat]
    Q.prompt = { ghostId = tostring(ghostId), who = tostring(who or ("player " .. tostring(ghostId))),
                 beat = beat, title = (hit and hit.quest.title ~= "" and hit.quest.title) or (hit and hit.quest.name) or beat,
                 shownAt = os.clock(), reason = tostring(reason or "divergence") }
    Q.lastPromptAt[Q.prompt.ghostId] = os.clock()
    Q.waiting[Q.prompt.ghostId] = nil      -- an offer replaces the waiting line for that peer
    Q.promptN = (Q.promptN or 0) + 1
    mp_log(string.format("QUEST-PROMPT shown (%s): %s is ahead in \"%s\" -- F11 catch up to %s / F12 stay (no timeout)",
        Q.prompt.reason, Q.prompt.who, tostring(Q.prompt.title), beat))
    return true
end

-- WO-98 Phase 5: cutscene edge -> hide a standing prompt (it returns when the
-- cutscene ends) / re-offer a parked one.
function KCD2MP_QuestOnCutscene(active)
    if active then
        if Q.prompt then
            Q.pendingPrompt = { ghostId = Q.prompt.ghostId, who = Q.prompt.who, beat = Q.prompt.beat, reason = Q.prompt.reason }
            mp_log("QUEST-PROMPT hidden: cutscene started -- " .. Q.prompt.beat
                .. " returns when it ends (input cannot reach the prompt during a cutscene)")
            Q.prompt = nil
        end
        return
    end
    local pp = Q.pendingPrompt
    if pp then
        Q.pendingPrompt = nil
        Q.lastPromptAt[pp.ghostId] = nil   -- the debounce must not swallow a re-offer
        mp_log("QUEST-PROMPT re-offered after the cutscene: " .. pp.beat)
        KCD2MP_QuestShowPrompt(pp.ghostId, pp.who, pp.beat, 1, pp.reason)
    end
end

-- Agent -> mod. The prompt is no longer relevant: the peer left, the two
-- objectives now agree, or the peer moved on to another beat. "peer left"
-- also ends that peer's WAITING_FOR_PEER state (WO-96).
function KCD2MP_QuestPromptMoot(reason, ghostId)
    if tostring(reason) == "peer left" and ghostId ~= nil and Q.waiting[tostring(ghostId)] then
        local w = Q.waiting[tostring(ghostId)]
        mp_log(string.format("WAITING_FOR_PEER exit (peer left): %s after %.0fs", w.who, os.clock() - w.since))
        Q.waiting[tostring(ghostId)] = nil
    end
    if tostring(reason) == "peer left" and ghostId ~= nil and Q.gap then Q.gap[tostring(ghostId)] = nil end
    -- WO-98 Phase 5: a parked (cutscene-held) offer is withdrawn on the same terms as a shown one.
    if Q.pendingPrompt and (ghostId == nil or tostring(ghostId) == Q.pendingPrompt.ghostId) then
        mp_log(string.format("QUEST-PROMPT pending offer withdrawn (%s): %s", tostring(reason), Q.pendingPrompt.beat))
        Q.pendingPrompt = nil
    end
    if not Q.prompt then return end
    if ghostId ~= nil and tostring(ghostId) ~= Q.prompt.ghostId then return end
    mp_log(string.format("QUEST-PROMPT withdrawn (%s): %s", tostring(reason), Q.prompt.beat))
    Q.prompt = nil
end

-- ---------------------------------------------------------------------------
-- WO-96: divergence-gated prompting and WAITING_FOR_PEER
-- ---------------------------------------------------------------------------
--
-- Why: in the 2026-09-13 session (docs/WO-95-findings.md s5) the prompt was
-- raised only when a peer walked within 35 m of a registry beat of ITS
-- current quest. M03 has exactly one such beat, so across five divergence
-- windows the players got three prompts, and for the whole stretch in which
-- one player was stuck the mechanism had nothing to say. The agent's
-- "[story] divergence" line, computed on every objective change with no
-- proximity condition, was correct every time. It is now the trigger.
--
-- Decision table (rel = who is behind, decided by the agent from the last
-- marker both players shared, refined here by production-code order when the
-- agent cannot tell):
--   we are BEHIND, peer's quest differs from ours, an unspent, undeclined
--     fireable beat of the peer's quest exists  -> readiness prompt (F11/F12)
--   we are BEHIND, same quest                   -> WAITING_FOR_PEER (reach it by play)
--   we are BEHIND, nothing fireable / all spent -> WAITING_FOR_PEER
--   we are AHEAD                                -> WAITING_FOR_PEER (peer is behind)
--   cannot tell                                 -> WAITING_FOR_PEER (diverged, unordered)
-- A beat fired HERE this session is spent: the 2026-09-13 host fired
-- socky._initAndStart twice and landed on the same point twice; a second
-- fire of a quest-start entry advances nothing. WAITING_FOR_PEER is a
-- status line: it blocks nothing, pauses nothing, gates no input. It exits
-- on convergence (the agent's next marker on either side agrees), on the
-- peer leaving, or on F12 (hidden until the divergence pair changes).
-- Scope: right for BEAT divergence only -- a sub-objective the ahead player
-- earned through ordinary play (dialogue, discovery) cannot be re-earned by
-- waiting; that is WO-96 Phase 2/3's problem, not this state's.

-- Numeric order of a quest from its production code: "M37a" -> 37.1.
local function questOrder(q)
    if not q or not q.code then return nil end
    local n, suffix = tostring(q.code):match("^M(%d+)(%a?)$")
    if not n then return nil end
    n = tonumber(n)
    if suffix and suffix ~= "" then n = n + (string.byte(suffix:lower()) - 96) / 10 end
    return n
end

-- "behind" / "ahead" / "unknown". The agent's verdict wins; production-code
-- order breaks a tie only when the two quests differ.
local function questRel(rel, peerQ, localQ)
    rel = tostring(rel or "unknown"):lower()
    if rel == "behind" or rel == "ahead" then return rel end
    if peerQ and localQ and peerQ ~= localQ then
        local a, b = questOrder(peerQ), questOrder(localQ)
        if a and b then
            if a > b then return "behind" elseif a < b then return "ahead" end
        end
    end
    return "unknown"
end

-- Distance^2 from a ghost's live position to a beat, or nil.
local function questGhostDist2(ghostId, b)
    local g = KCD2MP.ghosts and KCD2MP.ghosts[ghostId]
    if not g or not g.entity then return nil end
    local ok, gp = pcall(function() return g.entity:GetWorldPos() end)
    if not ok or not gp then return nil end
    return questBeatDist2(b, gp)
end

-- The beat to offer for a peer's quest: the peer's own approach hint when it
-- names a usable beat of that quest, else the usable beat nearest the peer's
-- ghost, else the first usable one. nil when every beat is spent/declined.
local function questPickBeat(ghostId, peerQ, hintBeat)
    local usable = {}
    for _, b in ipairs(peerQ.beats or {}) do
        local path = peerQ.name .. "." .. b.t
        if not Q.fired[path] and not Q.declined[path] then usable[#usable + 1] = { path = path, b = b } end
    end
    if #usable == 0 then return nil end
    if hintBeat and hintBeat ~= "" then
        for _, u in ipairs(usable) do if u.path == hintBeat then return u.path, "peer approach hint" end end
    end
    local best, bestD2 = nil, nil
    for _, u in ipairs(usable) do
        local d2 = questGhostDist2(ghostId, u.b)
        if d2 and (not bestD2 or d2 < bestD2) then best, bestD2 = u, d2 end
    end
    if best then return best.path, string.format("nearest to the peer, %.0fm", math.sqrt(bestD2)) end
    return usable[1].path, "first usable beat"
end

-- Agent -> mod on every [story] divergence (and re-pushed on the agent's
-- re-arm so a restarted game's fresh Lua gets it back). peerQuestLower is the
-- peer's marker quest token; peerObj / localObj are the humanised objective
-- strings for the screen; rel is the agent's behind|ahead|unknown; hintBeat
-- is the peer's last quest_approach path or "".
function KCD2MP_QuestDivergence(ghostId, who, peerQuestLower, peerObj, localObj, rel, hintBeat)
    ghostId = tostring(ghostId)
    who = tostring(who or ("player " .. ghostId))
    peerObj, localObj = tostring(peerObj or "?"), tostring(localObj or "?")
    hintBeat = tostring(hintBeat or ""):gsub("%s+", "")
    if not Q.enabled then
        mp_log("QUEST-DIVERGENCE ignored (mp_quest_sync off): " .. who)
        return "off"
    end
    local now = os.clock()
    local ix = questIndex()
    local pq = tostring(peerQuestLower or ""):lower():gsub("%s+", "")
    local peerQ  = pq ~= "" and ix.byLower[pq] or nil
    local localQ = Q.current and ix.byLower[Q.current] or nil
    rel = questRel(rel, peerQ, localQ)
    Q.divergeN = (Q.divergeN or 0) + 1
    local key = peerObj .. "|" .. localObj .. "|" .. rel

    -- 1. Is there a catch-up destination?
    local beat, pickWhy, why = nil, nil, nil
    if rel == "behind" then
        if not peerQ then
            why = "their quest is outside the main-quest registry"
        elseif localQ == peerQ then
            why = "same quest -- reach their objective through ordinary play"
        elseif #(peerQ.beats or {}) == 0 then
            why = string.format("%s \"%s\" has no fireable beat", peerQ.code, tostring(peerQ.title or peerQ.name))
        else
            beat, pickWhy = questPickBeat(ghostId, peerQ, hintBeat)
            if not beat then
                why = string.format("every fireable beat of %s \"%s\" is already used or declined here", peerQ.code, tostring(peerQ.title or peerQ.name))
            end
        end
    elseif rel == "ahead" then
        why = "they are behind you"
    else
        why = "cannot tell who is ahead"
    end
    -- WO-98 Phase 7: the agent re-pushes an unchanged divergence (restart
    -- safety net); log the full line only when something changed, and the
    -- repeats as one counter line per minute.
    local logKey = key .. "|" .. tostring(beat or why)
    if logKey ~= Q._lastDivergeLogKey then
        if (Q._divergeRepeat or 0) > 0 then
            mp_log(string.format("QUEST-DIVERGENCE previous pair was re-pushed x%d unchanged", Q._divergeRepeat))
        end
        Q._lastDivergeLogKey, Q._divergeRepeat, Q._divergeRepeatAt = logKey, 0, now
        mp_log(string.format("QUEST-DIVERGENCE #%d: %s (%s) is on \"%s\", we are on \"%s\" (%s) -- %s",
            Q.divergeN, who, rel, peerObj, localObj, tostring(Q.current), beat and ("offer " .. beat .. " [" .. pickWhy .. "]") or why))
    else
        Q._divergeRepeat = (Q._divergeRepeat or 0) + 1
        if (now - (Q._divergeRepeatAt or 0)) >= 60.0 then
            Q._divergeRepeatAt = now
            mp_log(string.format("QUEST-DIVERGENCE #%d unchanged (re-pushed x%d): %s", Q.divergeN, Q._divergeRepeat, logKey))
        end
    end

    -- 2. Offer it, unless the debounce says wait.
    if beat then
        local last = Q.lastPromptAt[ghostId]
        if Q.prompt and Q.prompt.ghostId == ghostId and Q.prompt.beat == beat then
            return "prompt-up"
        end
        if last and (now - last) < Q.promptGapS and not (Q.prompt and Q.prompt.ghostId == ghostId) then
            local w = Q.waiting[ghostId]
            if not w or w.key ~= key then
                Q.waiting[ghostId] = { who = who, rel = rel, key = key, peerObj = peerObj, localObj = localObj,
                    title = peerQ and (peerQ.title or peerQ.name) or "", since = now, dismissed = false,
                    pendingBeat = beat, why = string.format("prompt cooling down, %.0fs", Q.promptGapS - (now - last)) }
                mp_log(string.format("QUEST-DIVERGENCE prompt for %s deferred %.0fs (debounce %.0fs)", beat, Q.promptGapS - (now - last), Q.promptGapS))
            else
                w.pendingBeat = beat
            end
            return "deferred"
        end
        if KCD2MP_QuestShowPrompt(ghostId, who, beat, 1, "divergence") then return "prompt" end
        -- refused (catch-up running, declined meanwhile): fall through to waiting
        why = "prompt refused -- see the QUEST-PROMPT line above"
    end

    -- 3. Nothing to offer: WAITING_FOR_PEER, entered once per pair, updated in place.
    if Q.prompt and Q.prompt.ghostId == ghostId then
        -- the pair changed while an offer was up; the agent withdraws prompts on
        -- convergence, so an offer still standing is still valid -- keep it.
        return "prompt-up"
    end
    local w = Q.waiting[ghostId]
    if w and w.key == key then
        w.why = why; w.pendingBeat = nil
        return "waiting"
    end
    local relChanged = (not w) or (w.rel ~= rel)
    Q.waiting[ghostId] = { who = who, rel = rel, key = key, peerObj = peerObj, localObj = localObj,
        title = peerQ and (peerQ.title or peerQ.name) or (localQ and (localQ.title or localQ.name)) or "",
        since = (w and w.since) or now, dismissed = false, pendingBeat = nil, why = why }
    Q.waitN = (Q.waitN or 0) + 1
    mp_log(string.format("WAITING_FOR_PEER %s: %s is %s -- they are on \"%s\", we are on \"%s\" (%s)",
        w and "updated" or "entered", who, rel == "behind" and "ahead of us" or (rel == "ahead" and "behind us" or "elsewhere"), peerObj, localObj, why))
    if relChanged then
        KCD2MP_ShowNativeToast(rel == "behind" and (who .. " is ahead of you: \"" .. peerObj .. "\". Waiting for you to catch up.")
            or (rel == "ahead" and (who .. " is behind you: \"" .. peerObj .. "\". Waiting for them.")
            or (who .. " is on a different objective: \"" .. peerObj .. "\".")))
    end
    return "waiting"
end

-- Agent -> mod when the two markers agree again (either side's next
-- checkpoint): the prompt for that peer is moot and the waiting state ends.
function KCD2MP_QuestConverged(ghostId)
    ghostId = tostring(ghostId)
    local w = Q.waiting[ghostId]
    if w then
        mp_log(string.format("WAITING_FOR_PEER exit (converged): %s after %.0fs", w.who, os.clock() - w.since))
        Q.waiting[ghostId] = nil
    end
    if Q.prompt and Q.prompt.ghostId == ghostId then
        mp_log("QUEST-PROMPT withdrawn (objectives now agree): " .. Q.prompt.beat)
        Q.prompt = nil
    end
end

-- Agent -> mod (WO-96 Phase 2): the objective-level gap between us and a
-- peer inside one main quest, from the two machines' story fingerprints
-- (docs/WO-96-findings.md s3). theyHave = objectives the peer has reached
-- that we have not started; weHave = the reverse. Empty strings = no gap.
-- Logged as QUEST-GAP, toasted when it changes, and shown on that peer's
-- waiting row. Read-only: nothing here changes any state.
-- theyHaveSpec is the machine half of theyHave: "objectiveName=active;name=done",
-- in the same order as the labels. Phase 3 (WO-96 s4): when the local player
-- is IN that quest and the generated fix table has a clean narrow trigger for
-- one of those (objective, state) pairs, the readiness prompt offers it --
-- "F11 grants <objective>" -- through the same KCD2MP_QuestFire channel as a
-- catch-up beat (registry gate, hazard window, spent/declined). Whichever
-- player lacks the objective gets the offer: each side computes its own gap.
Q.gap = Q.gap or {}
function KCD2MP_QuestObjectiveGap(ghostId, who, questKey, questTitle, theyHave, weHave, theyHaveSpec)
    ghostId = tostring(ghostId)
    who = tostring(who or ("player " .. ghostId))
    questKey = tostring(questKey or ""):lower()
    theyHave, weHave = tostring(theyHave or ""), tostring(weHave or "")
    theyHaveSpec = tostring(theyHaveSpec or "")
    local key = theyHave .. "|" .. weHave
    local prev = Q.gap[ghostId]
    if theyHave == "" and weHave == "" then
        if prev then
            mp_log(string.format("QUEST-GAP closed with %s in \"%s\"", who, tostring(questTitle)))
            Q.gap[ghostId] = nil
            local w = Q.waiting[ghostId]; if w then w.gap = nil end
            if Q.prompt and Q.prompt.ghostId == ghostId and Q.prompt.reason == "gap" then
                mp_log("QUEST-PROMPT withdrawn (gap closed): " .. Q.prompt.beat)
                Q.prompt = nil
            end
        end
        return "none"
    end
    Q.gap[ghostId] = { who = who, quest = questKey, title = tostring(questTitle), theyHave = theyHave, weHave = weHave, key = key, at = os.clock() }
    local w = Q.waiting[ghostId]
    if w then w.gap = (theyHave ~= "" and ("they have: " .. theyHave) or "") .. ((theyHave ~= "" and weHave ~= "") and "; " or "") .. (weHave ~= "" and ("you have: " .. weHave) or "") end
    local changed = not (prev and prev.key == key)
    if changed then
        mp_log(string.format("QUEST-GAP with %s in \"%s\": they have [%s] you lack; you have [%s] they lack", who, tostring(questTitle), theyHave, weHave))
        if theyHave ~= "" then
            KCD2MP_ShowNativeToast(who .. " has an objective you do not: " .. theyHave)
        end
    end

    -- Phase 3: is there a clean narrow trigger for something they have and we lack?
    local q = questKey ~= "" and questIndex().byLower[questKey] or nil
    if not Q.enabled or not q or theyHaveSpec == "" then return changed and "changed" or "same" end
    if Q.current ~= questKey then
        if changed then mp_log("QUEST-GAP fix not considered: we are not in " .. questKey .. " (current " .. tostring(Q.current) .. ")") end
        return changed and "changed" or "same"
    end
    local fx = fixIndex()
    local offer, offerLabel, noFix = nil, nil, {}
    local i = 0
    for pair in theyHaveSpec:gmatch("[^;]+") do
        i = i + 1
        local oname, ostate = pair:match("^([%w_]+)=(%w+)$")
        if oname then
            local f = fx.byKey[q.name .. "|" .. oname .. "|" .. ostate]
            if f and not Q.fired[f.t] and not Q.declined[f.t] and not offer then
                offer = f
                -- the i-th label of theyHave belongs to this pair
                local j = 0
                for lab in theyHave:gmatch("[^;]+") do j = j + 1; if j == i then offerLabel = lab:gsub("^%s+", "") end end
            elseif not f then
                noFix[#noFix + 1] = oname .. "=" .. ostate
            end
        end
    end
    if #noFix > 0 and changed then
        mp_log("QUEST-GAP no narrow trigger exists for: " .. table.concat(noFix, ", ") .. " -- reported only")
    end
    if not offer then return changed and "changed" or "same" end
    if Q.prompt then
        if Q.prompt.beat == offer.t then return "prompt-up" end
        if Q.prompt.reason ~= "gap" then return "prompt-up" end   -- a catch-up offer stands; do not replace it
    end
    if Q.catchup then return changed and "changed" or "same" end
    Q.prompt = { ghostId = ghostId, who = who, beat = offer.t, title = tostring(questTitle), shownAt = os.clock(),
                 reason = "gap", fixLabel = tostring(offerLabel or offer.o), fixDir = offer.dir }
    Q.lastPromptAt[ghostId] = os.clock()
    mp_log(string.format("QUEST-PROMPT shown (gap): %s has \"%s\" (%s) and we do not -- F11 fires the narrow trigger %s / F12 stay",
        who, Q.prompt.fixLabel, offer.dir, offer.t))
    return "fix-offered"
end

-- The waiting line the player can currently see, if any (the first
-- undismissed one). Dismissal is per divergence pair: a new pair shows again.
function KCD2MP_QuestWaitingVisible()
    for id, w in pairs(Q.waiting) do
        if not w.dismissed then return w, id end
    end
    return nil
end

-- F12 with no prompt up hides the visible waiting line for this pair.
function KCD2MP_QuestWaitingDismiss()
    local w = KCD2MP_QuestWaitingVisible()
    if not w then return false end
    w.dismissed = true
    mp_log("WAITING_FOR_PEER hidden by the player (F12) for " .. w.who .. "; it returns if the divergence changes")
    KCD2MP_ShowInteractionMsg("Hidden until the story positions change")
    return true
end

-- 1 Hz from the proximity tick: a deferred offer is raised once its debounce
-- has elapsed and nothing else is up.
function KCD2MP_QuestWaitingTick(now)
    if Q.prompt or Q.catchup then return end
    for id, w in pairs(Q.waiting) do
        if w.pendingBeat then
            local last = Q.lastPromptAt[id]
            if not last or (now - last) >= Q.promptGapS then
                local beat = w.pendingBeat
                w.pendingBeat = nil
                if KCD2MP_QuestShowPrompt(id, w.who, beat, 1, "divergence") then return end
                w.why = "prompt refused -- see the QUEST-PROMPT line above"
            end
        end
    end
end

-- F11 / F12 / mp_quest_yes / mp_quest_no.
function KCD2MP_QuestAnswer(yes)
    if KCD2MP.cutsceneActive then
        -- WO-98 Phase 5: the console path (mp_quest_yes) can reach here mid-cutscene; a
        -- Haste trigger during a cutscene is the WO-97 hazard class. The offer is parked.
        mp_log("QUEST-PROMPT answer refused: a cutscene is playing (" .. tostring(KCD2MP.cutsceneName) .. ")")
        return false
    end
    local p = Q.prompt
    if not p then
        mp_log("QUEST-PROMPT: nothing to answer")
        return false
    end
    Q.prompt = nil
    if not yes then
        Q.declined[p.beat] = true
        mp_log("QUEST-PROMPT declined: staying on our own story for " .. p.beat)
        KCD2MP_EmitEvent("quest_catchup", "decline " .. p.beat)
        KCD2MP_ShowInteractionMsg("Staying on your own story")
        return true
    end
    return KCD2MP_QuestFire(p.beat, p.who)
end

-- The one write. Refuses anything outside the registry, fires the Haste
-- trigger over the console channel already in production, and opens the
-- hazard window. mp_quest_fire <quest>.<trigger> reaches this directly for
-- the live probe.
function KCD2MP_QuestFire(beat, who)
    beat = tostring(beat or "")
    if not KCD2MP_QuestIsRegistryBeat(beat) then
        mp_log("QUEST-CATCHUP refused: '" .. beat .. "' is not a registered main-quest beat")
        return false
    end
    if Q.catchup then
        mp_log("QUEST-CATCHUP refused: one is already in progress (" .. Q.catchup.beat .. ")")
        return false
    end
    who = tostring(who or "console")
    local now = os.clock()
    Q.catchup = { beat = beat, who = who, startedAt = now, untilT = now + Q.windowS }
    Q.fireN = (Q.fireN or 0) + 1
    Q.fired[beat] = true       -- WO-96: spent for this session; never offered again
    Q.lastPos = nil
    mp_log(string.format("QUEST-CATCHUP FIRE #%d: wh_concept_HasteTrigger %s (toward %s) -- hazard window %.0fs open",
        Q.fireN, beat, who, Q.windowS))
    KCD2MP_EmitEvent("quest_catchup", "begin " .. beat)
    local ok, err = pcall(function() System.ExecuteCommand("wh_concept_HasteTrigger " .. beat) end)
    -- A pcall that returns ok proves only that the Lua call did not throw
    -- (WO-43's lesson) -- whether the trigger fired is in the engine's own
    -- log lines, which is why the fire is logged before and after.
    mp_log(string.format("QUEST-CATCHUP ExecuteCommand returned %s%s", tostring(ok), ok and "" or (": " .. tostring(err))))
    local hit = questIndex().byPath[beat]
    local fix = fixIndex().byPath[beat]
    if fix then
        KCD2MP_ShowNativeToast("Granting objective " .. fix.o .. " (" .. fix.dir .. ") via " .. beat)
    else
        KCD2MP_ShowNativeToast("Catching up to " .. who .. "'s story: " .. tostring((hit and hit.quest.title ~= "" and hit.quest.title) or beat))
    end
    return ok
end

-- Agent -> mod: a PEER fired a catch-up (begin=1) or its window closed (0).
function KCD2MP_QuestCatchupRemote(ghostId, who, beat, begin)
    ghostId = tostring(ghostId)
    if tonumber(begin) == 1 then
        local now = os.clock()
        Q.catchupRemote[ghostId] = { beat = tostring(beat), who = tostring(who or ("player " .. ghostId)),
                                     startedAt = now, untilT = now + Q.windowS }
        mp_log(string.format("QUEST-CATCHUP peer %s fired %s -- watching for hazards crossing to us for %.0fs",
            Q.catchupRemote[ghostId].who, tostring(beat), Q.windowS))
    else
        local w = Q.catchupRemote[ghostId]
        if w then mp_log("QUEST-CATCHUP peer " .. w.who .. " window closed (" .. w.beat .. ")") end
        Q.catchupRemote[ghostId] = nil
    end
end

-- The open window, if any: the local one first, else the most recent remote.
function KCD2MP_QuestWindow()
    local now = os.clock()
    if Q.catchup and now < Q.catchup.untilT then return Q.catchup, "here" end
    local best = nil
    for _, w in pairs(Q.catchupRemote) do
        if now < w.untilT and (not best or w.startedAt > best.startedAt) then best = w end
    end
    if best then return best, "peer" end
    return nil
end

-- Expiry, and the local teleport watch. Called at 1 Hz from the proximity tick.
function KCD2MP_QuestWindowTick(now)
    if Q.catchup and now >= Q.catchup.untilT then
        mp_log(string.format("QUEST-CATCHUP window closed for %s after %.0fs (%d hazard lines this session)",
            Q.catchup.beat, now - Q.catchup.startedAt, Q.hazardN or 0))
        KCD2MP_EmitEvent("quest_catchup", "end " .. Q.catchup.beat)
        Q.catchup = nil
    end
    for id, w in pairs(Q.catchupRemote) do
        if now >= w.untilT then
            mp_log("QUEST-CATCHUP peer " .. w.who .. " window expired (" .. w.beat .. ")")
            Q.catchupRemote[id] = nil
        end
    end
    -- Local teleport: our own position moving faster than any horse between
    -- two 1 Hz samples while a window is open. 60 m/s is well above a
    -- gallop (~12 m/s) and below any goto.
    if KCD2MP_QuestWindow() and player then
        local ppos = nil
        pcall(function() ppos = player:GetWorldPos() end)
        if ppos then
            local lp = Q.lastPos
            if lp and (now - lp.at) > 0 then
                local d = math.sqrt((ppos.x - lp.x)^2 + (ppos.y - lp.y)^2 + (ppos.z - lp.z)^2)
                local v = d / (now - lp.at)
                if v > 60 then
                    KCD2MP_QuestHazard("teleport-local", string.format("player moved %.0fm in %.1fs (%.0f m/s)", d, now - lp.at, v))
                end
            end
            Q.lastPos = { x = ppos.x, y = ppos.y, z = ppos.z, at = now }
        end
    else
        Q.lastPos = nil
    end
end

-- Per-emitter-tick teleport watch (20 ms). A gallop covers ~0.25 m per tick;
-- a `goto` covers the whole distance in one. Anything over 4 m between two
-- consecutive emits less than 0.3 s apart is a teleport, whatever its size.
-- Live-verified need: the first real catch-up moved the player 19.5 m
-- (2346.8,2087.3 -> 2342.7,2068.3) and the 1 Hz / 60 m/s rule missed it.
KCD2MP._questTickPos = nil
function KCD2MP_QuestNotePos(x, y, z)
    if not KCD2MP_QuestWindow() then KCD2MP._questTickPos = nil; return end
    local now = os.clock()
    local lp = KCD2MP._questTickPos
    KCD2MP._questTickPos = { x = x, y = y, z = z, at = now }
    if not lp then return end
    local dt = now - lp.at
    if dt <= 0 or dt > 0.3 then return end
    local d = math.sqrt((x - lp.x)^2 + (y - lp.y)^2 + (z - lp.z)^2)
    if d > 4.0 then
        KCD2MP_QuestHazard("teleport-local", string.format("player jumped %.1fm in one %.0fms tick (%.1f,%.1f,%.1f -> %.1f,%.1f,%.1f)",
            d, dt * 1000, lp.x, lp.y, lp.z, x, y, z))
    end
end

-- The distinct line. Logs nothing outside a window, so every one of these
-- that appears in kcd.log IS a candidate for "the catch-up caused this".
function KCD2MP_QuestHazard(kind, detail)
    local w, where = KCD2MP_QuestWindow()
    if not w then return false end
    Q.hazardN = (Q.hazardN or 0) + 1
    mp_log(string.format("CATCHUP-HAZARD %s during catch-up %s (fired %s by %s %.1fs ago): %s",
        tostring(kind), w.beat, where, w.who, os.clock() - w.startedAt, tostring(detail)))
    return true
end

-- mp_quest_sync on|off, mp_quest_radius <m>, mp_quest_window <s>
function KCD2MP_QuestSetSync(arg)
    local s = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if s == "%line" then s = "" end   -- the console passes the literal when no argument is given
    if s == "on" then Q.enabled = true
    elseif s == "off" then Q.enabled = false; Q.prompt = nil
    elseif s ~= "" and s ~= "%line" then mp_log("mp_quest_sync: expected on|off, got '" .. s .. "'"); return end
    local ix = questIndex()
    mp_log(string.format("QUEST sync is %s (%d main quests, %d fireable beats, radius %.0fm, window %.0fs, prompt gap %.0fs; current=%s level=%s; %d approaches, %d divergences, %d waits, %d fires, %d hazard lines)",
        Q.enabled and "ON" or "OFF", ix.nQuests, ix.nBeats, Q.radius, Q.windowS, Q.promptGapS, tostring(Q.current), tostring(Q.level),
        Q.approachN or 0, Q.divergeN or 0, Q.waitN or 0, Q.fireN or 0, Q.hazardN or 0))
end
-- WO-96: #KCD2MP_QuestSetGap(<seconds>) -- minimum interval between prompts per peer.
function KCD2MP_QuestSetGap(arg)
    local n = tonumber(arg)
    if n and n >= 0 and n <= 3600 then Q.promptGapS = n; mp_log(string.format("QUEST prompt gap = %.0fs", n))
    else mp_log("mp_quest_gap: expected 0..3600 seconds, got '" .. tostring(arg) .. "'") end
end
function KCD2MP_QuestSetRadius(arg)
    local n = tonumber(arg)
    if n and n >= 5 and n <= 500 then Q.radius = n; mp_log(string.format("QUEST radius = %.0fm", n))
    else mp_log("mp_quest_radius: expected 5..500 metres, got '" .. tostring(arg) .. "'") end
end
function KCD2MP_QuestSetWindow(arg)
    local n = tonumber(arg)
    if n and n >= 10 and n <= 900 then Q.windowS = n; mp_log(string.format("QUEST hazard window = %.0fs", n))
    else mp_log("mp_quest_window: expected 10..900 seconds, got '" .. tostring(arg) .. "'") end
end

-- mp_quest_status: everything on one line plus the beats of the current quest.
function KCD2MP_QuestStatus()
    KCD2MP_QuestSetSync("")
    local q = Q.current and questIndex().byLower[Q.current] or nil
    if q then
        local ppos = nil
        pcall(function() ppos = player and player:GetWorldPos() end)
        for _, b in ipairs(q.beats or {}) do
            local d2 = ppos and questBeatDist2(b, ppos) or nil
            mp_log(string.format("  beat %s.%s %s -> %s", q.name, b.t,
                b.e and ("entity " .. b.e) or string.format("(%.1f, %.1f, %.1f)", b.x, b.y, b.z),
                d2 and string.format("%.1fm", math.sqrt(d2)) or "position unknown"))
        end
    end
    if Q.prompt then mp_log("  prompt up: " .. Q.prompt.who .. " -> " .. Q.prompt.beat) end
    for id, wt in pairs(Q.waiting) do
        mp_log(string.format("  WAITING_FOR_PEER %s: %s (%s) they=\"%s\" we=\"%s\" %s%s since %.0fs%s",
            tostring(id), wt.who, wt.rel, wt.peerObj, wt.localObj, tostring(wt.why),
            wt.pendingBeat and (" pending " .. wt.pendingBeat) or "", os.clock() - wt.since, wt.dismissed and " (hidden)" or ""))
    end
    for beat in pairs(Q.fired) do mp_log("  spent this session: " .. beat) end
    local w, where = KCD2MP_QuestWindow()
    if w then mp_log(string.format("  hazard window open (%s): %s by %s, %.0fs left", where, w.beat, w.who, w.untilT - os.clock())) end
end

-- mp_quest_test_prompt <beat> -- puts a prompt on screen with no peer, so the
-- keys and the overlay can be exercised solo. Answering Yes to a test prompt
-- REALLY fires the beat (that is the point of the live probe); use a
-- disposable save.
function KCD2MP_QuestTestPrompt(arg)
    local beat = tostring(arg or ""):gsub("%s+", "")
    if beat == "" or beat == "%LINE" then
        -- default to the first fireable beat in the registry
        for _, q in ipairs(KCD2MP_MAINQUESTS or {}) do
            if q.beats and q.beats[1] then beat = q.name .. "." .. q.beats[1].t; break end
        end
    end
    return KCD2MP_QuestShowPrompt("test", "TestPeer", beat, 1, "test")
end

-- Drawn from KCD2MP_DrawInteractionUI (the 8 ms label loop). Two lines below
-- the invite/message rows, persistent, DrawText only.
function KCD2MP_QuestDrawUI()
    local p = Q.prompt
    if p and p.reason == "gap" then
        -- WO-96 Phase 3: a narrow fix. Nothing moves the player; it flips one journal objective.
        mp_draw_row("quest_prompt", 10, 160, p.who .. " has \"" .. tostring(p.fixLabel) .. "\" (" .. tostring(p.fixDir) .. ") in \"" .. tostring(p.title) .. "\" and you do not", 2)
        mp_draw_row("quest_prompt_keys", 10, 184, "F11 grant it to me (narrow trigger " .. p.beat .. ", no teleport)  /  F12 stay  (or mp_quest_yes / mp_quest_no)", 1.6)
    elseif p then
        mp_draw_row("quest_prompt", 10, 160, p.who .. " is ahead of you in \"" .. tostring(p.title) .. "\"  -- catch up to " .. p.beat .. "?", 2)
        mp_draw_row("quest_prompt_keys", 10, 184, "F11 catch up (advance my story; you will be moved)  /  F12 stay  (or mp_quest_yes / mp_quest_no)", 1.6)
    end
    local w, where = KCD2MP_QuestWindow()
    if w then
        local stable = string.format("Catch-up in progress (%s): %s", where, w.beat)
        mp_draw_row("quest_window", 10, 208, string.format("%s  %.0fs", stable, w.untilT - os.clock()), 1.4, stable)
    end
    -- WO-96: WAITING_FOR_PEER, one row, informational. Not drawn under an
    -- open prompt for the same peer (ShowPrompt clears it).
    local wt = KCD2MP_QuestWaitingVisible and KCD2MP_QuestWaitingVisible() or nil
    if wt then
        local head
        if wt.rel == "behind" then head = "WAITING FOR PEER -- " .. wt.who .. " is ahead: they are on \"" .. wt.peerObj .. "\", you are on \"" .. wt.localObj .. "\""
        elseif wt.rel == "ahead" then head = "WAITING FOR PEER -- " .. wt.who .. " is behind you: they are on \"" .. wt.peerObj .. "\", you are on \"" .. wt.localObj .. "\""
        else head = "STORY DIVERGED -- " .. wt.who .. " is on \"" .. wt.peerObj .. "\", you are on \"" .. wt.localObj .. "\"" end
        mp_draw_row("quest_waiting", 10, 232, head .. ".  " .. tostring(wt.why) .. ".  (F12 hides)", 1.4)
        if wt.gap then mp_draw_row("quest_gap", 10, 256, "Objectives: " .. tostring(wt.gap), 1.4) end
    end
end

-- ===== Player hook =====

local ok2, err2 = pcall(function()
    if not (Player and Player.Client) then return end

    -- OnInit: fires when save is loaded
    local origOnInit = Player.Client.OnInit
    Player.Client.OnInit = function(self)
        if origOnInit then origOnInit(self) end
        System.LogAlways("[KCD2-MP] Player loaded!")
        KCD2MP_GetPos()

        -- Re-install OnAction hooks here (after player fully initialized).
        -- Player.Client.OnAction may be reset during game load; re-hooking in OnInit
        -- ensures our handler is always active.
        local origCA = Player.Client.OnAction
        Player.Client.OnAction = function(s, action, activation, value)
            if origCA then pcall(origCA, s, action, activation, value) end
            handleAction(action, activation, value)
        end
        System.LogAlways("[KCD2-MP] Client.OnAction hooked")
    end

    -- Also hook at mod-init time (catches actions before first save load)
    local origCA0 = Player.Client.OnAction
    Player.Client.OnAction = function(self, action, activation, value)
        if origCA0 then pcall(origCA0, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    -- Also try Player.OnAction (non-Client path, some CryEngine versions use this)
    local origPA = Player.OnAction
    Player.OnAction = function(self, action, activation, value)
        if origPA then pcall(origPA, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    System.LogAlways("[KCD2-MP] Player hooks OK (OnInit + OnAction x2)")
end)
if not ok2 then
    System.LogAlways("[KCD2-MP] Hook error: " .. tostring(err2))
end



