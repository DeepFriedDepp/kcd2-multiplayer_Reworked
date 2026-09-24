#pragma once
// The agent <-> DLL channel.
//
// The DLL hosts, the agent connects. The DLL's lifetime is the game's, which is
// the more stable endpoint: the agent can be restarted, reconnect, or not be
// running at all, and the game carries on regardless.
//
// A named pipe rather than a socket: it is local-only by construction, so there
// is no port to collide with the relay or the debug server and nothing
// listening on a network interface. Throughput is irrelevant here -- these are
// discrete combat events, not a per-frame stream.
//
// Framing matches the relay wire protocol so the two are read the same way:
//     [type:1][payloadLen:2 LE][payload:N]
//
//   agent -> DLL
//     0x01 ApplyDamage  [guid:16][stamina:4f][health:4f][flags:1]   (25)
//     0x02 ApplyDeath   [guid:16]                                   (16)
//     0x03 Ping         []                       -> replies 0x83
//     0x04 SetFactionHostile [guid:16][hostile:1]                   (17)
//     0x05 ResolveLuaClosure [closureAddr:8]      -> replies 0x84   (8)
//     0x06 GhostSwing   [entityId:4 LE][fragSpec:N utf8, no NUL]    (5..196)
//                        WO-46: queue a real combat-swing animation on the
//                        ghost with this CryEngine entity id (the WO-45
//                        rung-2 route; combat_swing.h). fragSpec is a real
//                        "FragmentId, tag1+tag2" row from Tables.pak. The
//                        entity id comes from the Lua spawn report, not a
//                        guid -- entity ids are the address the combat
//                        machinery natively resolves.
//     0x07 GhostIsolate [guid:16][on:1]                            (17)
//                        WO-68: apply (on=1) or remove (on=0) the seven civic
//                        isolation script contexts on this ghost natively --
//                        the crime half WO-65 proved has no Lua setter on this
//                        build (script_context.h). The guid is the GHOST's own
//                        Soul::Guid, exactly as SetFactionHostile, and for the
//                        same reason. Idempotent (the engine's store is
//                        refcounted, so a context already in the wanted state
//                        is left alone) and fail-closed (the first fault
//                        disarms the feature for the rest of the process; a
//                        ghost spawn is never blocked by it).
//
//     0x09 ReadBodyState [entityId:4 LE]           -> replies 0x85   (4)
//                        WO-100.5 Phase 2: read one actor's live Mannequin
//                        tag state and reduce it to the four continuous wire
//                        fields (pace / dir / stance / animSpeed).
//                        entityId 0 means "the local player". STRICTLY
//                        READ-ONLY -- three virtual getters the game calls
//                        every frame, then plain memory reads; the same five
//                        refusal gates WO-100 Phase 0 shipped.
//                        Queried at the position stream's own cadence, so it
//                        must stay quiet: refusals are reported through the
//                        reply's ok byte and counted by the agent, not logged
//                        per sample.
//
//     0x0A ReadLocalState [entityId:4 LE]          -> replies 0x86   (4)
//                        WO-102 Phase 1: the local player's position, yaw,
//                        riding flag and body state, all from ONE frame
//                        (local_state.h). entityId must be 0 (the player);
//                        the field is reserved for a per-entity read.
//                        STRICTLY READ-ONLY. Queried at the position
//                        stream's cadence, so quiet: refusals travel in the
//                        reply's ok/refuse bytes, one native log line per
//                        verdict change.
//
//     0x0B ScanNpcs [anchorCount:1][radius:4f]
//                   [anchor: x:4f,y:4f,z:4f]*anchorCount -> replies 0x87
//                        WO-102.5 Phase 2: one batched native NPC scan
//                        (npc_scan.h) replacing the enumerate+read half of
//                        Lua's mp_npc_rescan. anchorCount 1..8. STRICTLY
//                        READ-ONLY. Quiet like 0x09/0x0A: the reply's
//                        refuse byte carries every gate, one native log
//                        line per verdict change.
//
//     0x08 ConceptProbe [path:N utf8, no NUL, may be empty]        (0..480)
//                        WO-97: read-only probe of the quest concept tree.
//                        Enumerates C_ConceptManager's root modules by name
//                        (pure pointer reads, no engine call) and, when path
//                        is non-empty, resolves it through
//                        C_ConceptManager::FindNode and reports node vs null.
//                        Results go to the native log, not the wire: this is a
//                        diagnostic run from tools/Probe-ConceptRead.ps1 with
//                        the agent stopped, exactly like 0x05/0x07's probes.
//                        NOTHING IS TRIGGERED -- see concept_read.h.
//
//     0x0C SetSession   [on:1]                                     (1)
//                        WO-113: the agent says a multiplayer session is live
//                        (relay connected, Ack received) or over. The death
//                        guard arms only while this is on; the pipe dropping
//                        clears it. Idempotent -- the agent re-sends it on every
//                        pipe (re)connect and as a heartbeat.
//     0x0D SetRespawn   [on:1]                                     (1)
//                        WO-113: mp_respawn on/off, forwarded by the agent
//                        when the toggle is typed on the Lua side. The DLL's
//                        own native console command sets the same flag.
//     0x0E MirrorGrave  [op:1][owner:1][graveId:8 LE][x:4f][y:4f][z:4f]  (22)
//                        WO-113: op 1 = add a peer's gravestone + marker
//                        (never lootable, never saved), op 0 = remove it,
//                        op 2 = remove every mirror of `owner` (0xFF = all).
//     0x0F ListGraves   []                           -> replies 0x88
//                        WO-113: every grave this player still owns, for the
//                        agent's on-connect re-announce.
//
//     0x10 NpcSamples   [count:1]{[src:1][nameLen:1][name][x:4f][y:4f][z:4f][rot:4f]
//                        [flags:1][seq:2][senderMs:4][arrivalQpc:8]}*count   (<= 4096)
//                        WO-118: every inbound NPC sample the agent handed Lua,
//                        for the native per-frame writer (npc_drive.h). Queued
//                        on the pipe thread, no main-thread hop; Result ok.
//     0x11 NpcBind      [on:1][eid:4][wuid:8][ax:4f][ay:4f][az:4f][delayMs:2]
//                        [nameLen:1][name]
//                        WO-118: Lua's decision to (un)bind one puppet. Verified
//                        on the main thread (entity id, name, WUID, parent,
//                        living body) before any write; Result reason = the
//                        npcdrive::Reason code.
//     0x12 NpcHold      [ms:2][nameLen:1][name]
//                        WO-118: no writes for this puppet for ms (a swing).
//     0x13 NpcConfig    [nativeOn:1][senderClockOn:1]
//                        WO-118: mp_npc_native_write / mp_npc_senderclock.
//     0x14 NpcStatus    []                           -> replies 0x89
//     0x15 NpcTrace     [seconds:2][nameLen:1][name]  (seconds 0 = stop)
//                        WO-118 Phase 5: mp_npc_trace (npc_trace.h).
//
//   DLL -> agent
//     0x81 Result       [ok:1][seq:1]            (per applied command)
//     0x89 NpcStatus    [ok:1][seq:1][armed:1][nativeOn:1][bound:2][writing:2]
//                       [framesWritten:4][writes:4][drops:4][samples:4]   (24)
//                        WO-118 reply to 0x14 (the agent's 1 Hz heartbeat).
//     0x94 NpcDropped   [reason:1][nameLen:1][name]      (unsolicited)
//                        WO-118: the native writer stopped a bound puppet on
//                        its own (entity gone, silence, fault, pipe closed).
//     0x95 NpcTraceDone [rows:4][pathLen:1][path]        (unsolicited)
//     0x88 GraveList    [ok:1][seq:1][count:1] { [graveId:8][x:4f][y:4f][z:4f] }*count
//                        WO-113 reply to 0x0F; at most 40 graves.
//     0x91 LocalDowned  [on:1][kind:1]                   (unsolicited, 2)
//                        WO-113: the player hit the floor (on=1) or the
//                        respawn/wake-up finished (on=0). kind: 0 death,
//                        1 knockdown, 2 execution. The agent sets 0x1F flags
//                        bit 0 while on -- NOT 0x23: a downed player's vitals
//                        read 1.0 and would clear a peer's death tag.
//     0x92 LocalRespawned [x:4f][y:4f][z:4f][reason:1]   (unsolicited, 13)
//                        WO-113: where the player stands after the sequence.
//     0x93 LocalGrave   [op:1][graveId:8][x:4f][y:4f][z:4f] (unsolicited, 21)
//                        WO-113: op 1 a grave was made, op 0 it is gone
//                        (looted empty or expired).
//     0x83 Pong         []
//     0x86 LocalState   [ok:1][seq:1][refuse:1][frame:8 LE]
//                       [x:4f][y:4f][z:4f][rotZ:4f][flags:1][haveBody:1]
//                       [pace:1][dir:1][stance:1][animSpeedCenti:2 LE]
//                       [unknownTags:1][haveCombat:1][inputClass:1][zone:1]
//                       [atkType:1][prepared:1]                      (40)
//                        WO-102 Phase 1. Always 40 bytes, refusal or not;
//                        the body block is byte-identical to 0x85's bytes
//                        2..12. flags bit 0 = riding (Stance reads horse).
//     0x87 NpcScanResult [ok:1][seq:1][refuse:1][truncated:1]
//                        [totalWalked:4 LE][nameRejects:4 LE][droppedCount:4 LE][count:2 LE]
//                        { [nameLen:1][name:N][x:4f][y:4f][z:4f][yaw:4f][isHorse:1] }*count
//                        WO-102.5 Phase 2, header extended WO-103 Phase 1
//                        (droppedCount). Variable length (18-byte header +
//                        count entries, each nameLen+17 bytes). No exclusion
//                        policy applied natively (mod bodies, mounted horse,
//                        name pattern beyond a printable-ASCII read gate) --
//                        every matching entity within radius of any anchor is
//                        returned; Lua applies its existing filters against
//                        this list exactly as it did against
//                        System.GetEntitiesInSphere's result. droppedCount is
//                        how many further matches were found after the
//                        kMaxReplyBytes budget was hit (0 when !truncated) --
//                        this used to be silently discarded (WO-103).
//     0x85 BodyState    [ok:1][seq:1][pace:1][dir:1][stance:1]
//                       [animSpeedCenti:2 LE][unknownTags:1]        (8)
//                        WO-100.5 Phase 2. seq sits at body[1], exactly where
//                        the Result frame carries it, so the agent's
//                        sequence-matching (WO-100 S3.1) applies unchanged.
//                        ok=0 means a gate refused; every other field is then
//                        meaningless and the agent must not send one.
//
//     0x84 ClosureInfo  [ok:1][nativeAddr:8][rva:4]
//                        [moduleNameLen:1][moduleName:N]
//                        [nameLen:1][name:N]
//                        [prologueLen:1][prologueHex:N]
//                        (WO-20 Phase 2 diagnostic -- see lua_closure.h.
//                        A one-shot introspection query, not part of the
//                        normal combat/appearance/aggro traffic.)
//     0x90 LocalHit     [guid:16][stamina:4f][health:4f][died:1]   (outbound)
//                        Emitted by rttr::sample_health via send_local_hit
//                        (pipe_server.cpp) whenever a tracked nearby soul
//                        loses health this client did not apply on a peer's
//                        behalf. WO-86: the trailing `died` byte (1 = that
//                        drop took the soul to <= 0 hp, reported once per
//                        soul) is the frame-accurate NPC death signal the
//                        agent forwards as the FATAL bit on 0x30; it was
//                        computed since WO-4 and dropped at the frame edge
//                        until WO-86. A pre-WO-86 agent reads 24 bytes and
//                        ignores it.
//
// guid is the SharedSoulGuid in the game's in-memory byte order: the raw 16
// bytes of the SoulsByGuid key, NOT the text form. The agent converts.
//
// SetFactionHostile (WO-17) is the exception: its guid is the GHOST's own
// Soul::Guid, not a SharedSoulGuid -- a locally-spawned ghost proxy carries
// SharedSoulGuid=0, so the identity that actually resolves through
// SoulsByGuid for it is Guid. hostile=1 attaches the ghost to the mod's one
// v1 hostile faction (rttr::set_ghost_faction_hostile); hostile=0 detaches
// back to its pre-attach orphan state. This is the real runtime trigger the
// gitignored kcdmp-faction.txt research file was always meant to be replaced
// by once the mod's normal runtime had a real reason to call it.

#include <cstdint>

namespace kcdmp::pipe {

constexpr uint8_t kApplyDamage        = 0x01;
constexpr uint8_t kApplyDeath         = 0x02;
constexpr uint8_t kPing               = 0x03;
constexpr uint8_t kSetFactionHostile  = 0x04;
constexpr uint8_t kResolveLuaClosure  = 0x05;
constexpr uint8_t kGhostSwing         = 0x06;
constexpr uint8_t kGhostIsolate       = 0x07;
constexpr uint8_t kConceptProbe       = 0x08;   // WO-97, read-only
constexpr uint8_t kReadBodyState      = 0x09;   // WO-100.5 Phase 2, read-only
constexpr uint8_t kReadLocalState     = 0x0A;   // WO-102 Phase 1, read-only
constexpr uint8_t kScanNpcs           = 0x0B;   // WO-102.5 Phase 2, read-only
constexpr uint8_t kSetSession         = 0x0C;   // WO-113
constexpr uint8_t kSetRespawn         = 0x0D;   // WO-113
constexpr uint8_t kMirrorGrave        = 0x0E;   // WO-113
constexpr uint8_t kListGraves         = 0x0F;   // WO-113
constexpr uint8_t kGraveList          = 0x88;   // WO-113 reply
constexpr uint8_t kLocalDowned        = 0x91;   // WO-113, unsolicited
constexpr uint8_t kLocalRespawned     = 0x92;   // WO-113, unsolicited
constexpr uint8_t kLocalGrave         = 0x93;   // WO-113, unsolicited
constexpr int     kMirrorGraveLen     = 1 + 1 + 8 + 12;
constexpr int     kMaxGraveList       = 40;
constexpr uint8_t kResult             = 0x81;
constexpr uint8_t kPong               = 0x83;
constexpr uint8_t kClosureInfo        = 0x84;
constexpr uint8_t kBodyState          = 0x85;   // WO-100.5 Phase 2
constexpr uint8_t kLocalState         = 0x86;   // WO-102 Phase 1
constexpr uint8_t kNpcScanResult      = 0x87;   // WO-102.5 Phase 2
constexpr uint8_t kLocalHit           = 0x90;
constexpr uint8_t kNpcSamples         = 0x10;   // WO-118
constexpr uint8_t kNpcBind            = 0x11;   // WO-118
constexpr uint8_t kNpcHold            = 0x12;   // WO-118
constexpr uint8_t kNpcConfig          = 0x13;   // WO-118
constexpr uint8_t kNpcStatus          = 0x14;   // WO-118
constexpr uint8_t kNpcTrace           = 0x15;   // WO-118
constexpr uint8_t kNpcStatusReply     = 0x89;   // WO-118
constexpr uint8_t kNpcDropped         = 0x94;   // WO-118, unsolicited
constexpr uint8_t kNpcTraceDone       = 0x95;   // WO-118, unsolicited
constexpr int     kNpcSamplesMaxLen   = 4096;

constexpr int kGuidLen                  = 16;
constexpr int kApplyDamageLen           = kGuidLen + 4 + 4 + 1;
constexpr int kApplyDeathLen            = kGuidLen;
constexpr int kSetFactionHostileLen     = kGuidLen + 1;
constexpr int kResolveLuaClosureLen     = 8;
constexpr int kGhostSwingMinLen         = 4 + 1;      // entityId + at least one spec byte
constexpr int kGhostSwingMaxLen         = 4 + 191;    // spec cap matches combat_swing.h
constexpr int kGhostIsolateLen          = kGuidLen + 1;
constexpr int kConceptProbeMaxLen       = 480;    // matches concept_read.cpp's kMaxPath
constexpr int kReadBodyStateLen         = 4;      // entityId LE; 0 means "the player"
constexpr int kReadLocalStateLen        = 4;      // WO-102: entityId LE, must be 0 (the player)
constexpr int kLocalStateLen            = 40;     // WO-102: the fixed 0x86 reply body
constexpr int kScanNpcsAnchorMax        = 8;       // WO-102.5: self + up to 7 peer ghosts
constexpr int kScanNpcsMinLen           = 1 + 4 + 1 * 12;               // anchorCount + radius + >=1 anchor
constexpr int kScanNpcsMaxLen           = 1 + 4 + kScanNpcsAnchorMax * 12;
constexpr uint8_t kFlagSuppressHitReaction = 0x01;

/// Start the listener thread. Safe to call once; returns false if it could not
/// create the pipe.
bool start();

/// Stop listening and disconnect any client.
void stop();

/// Whether an agent is currently connected.
bool connected();

} // namespace kcdmp::pipe
