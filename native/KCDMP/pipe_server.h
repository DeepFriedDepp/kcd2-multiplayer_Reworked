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
//
//   DLL -> agent
//     0x81 Result       [ok:1][seq:1]            (per applied command)
//     0x83 Pong         []
//     0x90 LocalHit     [guid:16][stamina:4f][health:4f]   (outbound, not yet
//                        emitted -- the hook that detects a local hit does not
//                        exist. Reserved so the agent side can be written once.)
//
// guid is the SharedSoulGuid in the game's in-memory byte order: the raw 16
// bytes of the SoulsByGuid key, NOT the text form. The agent converts.

#include <cstdint>

namespace kcdmp::pipe {

constexpr uint8_t kApplyDamage = 0x01;
constexpr uint8_t kApplyDeath  = 0x02;
constexpr uint8_t kPing        = 0x03;
constexpr uint8_t kResult      = 0x81;
constexpr uint8_t kPong        = 0x83;
constexpr uint8_t kLocalHit    = 0x90;

constexpr int kGuidLen           = 16;
constexpr int kApplyDamageLen    = kGuidLen + 4 + 4 + 1;
constexpr int kApplyDeathLen     = kGuidLen;
constexpr uint8_t kFlagSuppressHitReaction = 0x01;

/// Start the listener thread. Safe to call once; returns false if it could not
/// create the pipe.
bool start();

/// Stop listening and disconnect any client.
void stop();

/// Whether an agent is currently connected.
bool connected();

} // namespace kcdmp::pipe
