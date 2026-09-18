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
//   DLL -> agent
//     0x81 Result       [ok:1][seq:1]            (per applied command)
//     0x83 Pong         []
//     0x86 LocalState   [ok:1][seq:1][refuse:1][frame:8 LE]
//                       [x:4f][y:4f][z:4f][rotZ:4f][flags:1][haveBody:1]
//                       [pace:1][dir:1][stance:1][animSpeedCenti:2 LE]
//                       [unknownTags:1][haveCombat:1][inputClass:1][zone:1]
//                       [atkType:1][prepared:1]                      (40)
//                        WO-102 Phase 1. Always 40 bytes, refusal or not;
//                        the body block is byte-identical to 0x85's bytes
//                        2..12. flags bit 0 = riding (Stance reads horse).
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
constexpr uint8_t kResult             = 0x81;
constexpr uint8_t kPong               = 0x83;
constexpr uint8_t kClosureInfo        = 0x84;
constexpr uint8_t kBodyState          = 0x85;   // WO-100.5 Phase 2
constexpr uint8_t kLocalState         = 0x86;   // WO-102 Phase 1
constexpr uint8_t kLocalHit           = 0x90;

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
constexpr uint8_t kFlagSuppressHitReaction = 0x01;

/// Start the listener thread. Safe to call once; returns false if it could not
/// create the pipe.
bool start();

/// Stop listening and disconnect any client.
void stop();

/// Whether an agent is currently connected.
bool connected();

} // namespace kcdmp::pipe
