namespace KcdMp.Server;

/// <summary>
/// The relay wire protocol.
///
/// Framing (every packet):  [type:1][payloadLen:2 LE][payload:N]
/// Floats are little-endian IEEE-754.
///
/// Presence layer:
/// C→S  0x00  Handshake:  [version:1][nameLen:1][name:UTF-8]
/// C→S  0x01  Position:   [x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (17 bytes)
///                          flags bit 0: isRiding
/// C→S  0x04  Ping:       [timestamp:8 LE int64]
/// C→S  0x07  Voice:      [pcm:640]  (16 kHz mono 16-bit, 20 ms frame)
/// S→C  0x02  Ghost:      [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (18 bytes)
/// S→C  0x03  Name:       [ghostId:1][name:UTF-8]
/// S→C  0x05  Pong:       [timestamp:8 LE int64]  (echo of Ping)
/// S→C  0x06  Disconnect: [ghostId:1]
/// S→C  0x08  Voice:      [sourceId:1][pcm:640]
/// S→C  0x09  VersionMismatch: [serverVersion:1]
/// S→C  0xFF  Ack:        [assignedId:1]
///
/// Interaction layer (WO-2). Opt-in paired interactions: one player invites,
/// the other accepts or declines, both enter a session the relay arbitrates,
/// both leave. Dice (WO-3) and duelling (WO-5) are clients of this rather than
/// separate protocols.
/// C→S  0x0A  Invite:         [targetGhostId:1][kind:1]
/// S→C  0x0B  InviteReceived: [sessionId:2][fromGhostId:1][kind:1]
/// C→S  0x0C  InviteResponse: [sessionId:2][accept:1]
/// S→C  0x0D  SessionStart:   [sessionId:2][peerGhostId:1][kind:1][role:1]
/// C→S  0x0E  SessionEvent:   [sessionId:2][payload:N]
/// S→C  0x0F  SessionEvent:   [sessionId:2][fromGhostId:1][payload:N]
/// C→S  0x10  SessionLeave:   [sessionId:2][reason:1]
/// S→C  0x11  SessionEnd:     [sessionId:2][reason:1]
///
/// Session event payloads are deliberately opaque to this layer. Each
/// interaction kind defines its own, so dice scoring or duel arbitration can
/// change without touching the session framing.
///
/// Combat layer (WO-4). Replicates damage and death against shared NPCs.
/// C→S  0x12  Damage: [targetGuid:16][stamina:4f][health:4f][flags:1]  (25 bytes)
/// S→C  0x13  Damage: [sourceGhostId:1][targetGuid:16][stamina:4f][health:4f][flags:1]  (26)
/// C→S  0x14  Death:  [targetGuid:16]  (16 bytes)
/// S→C  0x15  Death:  [sourceGhostId:1][targetGuid:16]  (17 bytes)
///                      flags bit 0: suppressHitReaction
///
/// targetGuid is the NPC's SharedSoulGuid, in the same 16-byte order the game
/// stores it. It is authored content shipped in the level data, so it is
/// byte-identical on every installation — which is what makes a raw GUID a
/// valid cross-client key at all. Entity ids and pointers are not: the same
/// soul has different addresses in each process, and a runtime-spawned NPC has
/// a different GUID per save, so only hand-placed souls may be addressed here.
///
/// The relay stays stateless, exactly as for voice: it orders and forwards and
/// holds no world state. Authority is per-hit and belongs to the client whose
/// player landed the blow.
///
/// Death is a separate packet, NOT inferred from health reaching zero. Two
/// clients computing "dead" independently from slightly divergent health will
/// eventually disagree, and disagreement about who is alive does not
/// self-correct the way a health value does. Receivers must treat Death as
/// idempotent and ignore a repeat for a soul already dead.
///
/// Loop prevention is the receiving client's job: damage applied because a
/// Damage packet arrived must never itself be broadcast, or two clients will
/// bounce a hit back and forth forever. That is local state, so it is
/// deliberately not on the wire.
///
/// Free type bytes for new features: 0x16 and up.
///
/// NOTE: this file is duplicated as dotnet/KcdMp.Client/Protocol.cs. The two
/// projects share no assembly, so the constants are mirrored by hand — change
/// both together. Extracting a shared KcdMp.Protocol project is a separate
/// work order.
/// </summary>
public static class Protocol
{
	/// <summary>
	/// Protocol version, negotiated in the Handshake.
	///
	/// Bumped to 3 for the combat layer. A v2 peer has no damage or death
	/// packets, and because the relay rejects a mismatch at handshake rather
	/// than letting it misparse later, an old agent gets a clear refusal instead
	/// of silently dropping hits — which would present as "damage does not
	/// replicate" rather than as a version problem.
	/// </summary>
	public const byte Version = 3;

	// C→S
	public const byte Handshake      = 0x00;
	public const byte Position       = 0x01;
	public const byte Ping           = 0x04;
	public const byte VoiceUp        = 0x07;
	public const byte Invite         = 0x0A;
	public const byte InviteResponse = 0x0C;
	public const byte SessionEventUp = 0x0E;
	public const byte SessionLeave   = 0x10;
	public const byte DamageUp       = 0x12;
	public const byte DeathUp        = 0x14;

	// S→C
	public const byte Ghost            = 0x02;
	public const byte Name             = 0x03;
	public const byte Pong             = 0x05;
	public const byte Disconnect       = 0x06;
	public const byte VoiceDown        = 0x08;
	public const byte VersionMismatch  = 0x09;
	public const byte InviteReceived   = 0x0B;
	public const byte SessionStart     = 0x0D;
	public const byte SessionEventDown = 0x0F;
	public const byte SessionEnd       = 0x11;
	public const byte DamageDown       = 0x13;
	public const byte DeathDown        = 0x15;
	public const byte Ack              = 0xFF;

	/// <summary>Exact Position (0x01) payload length.</summary>
	public const int PositionPayloadLen = 17;

	/// <summary>Exact voice frame length: 20 ms of 16 kHz mono 16-bit PCM.</summary>
	public const int VoiceFrameLen = 640;

	/// <summary>Length of a SharedSoulGuid on the wire.</summary>
	public const int SoulGuidLen = 16;

	/// <summary>Exact Damage (0x12) upstream payload length.</summary>
	public const int DamageUpPayloadLen = SoulGuidLen + 4 + 4 + 1;

	/// <summary>Exact Death (0x14) upstream payload length.</summary>
	public const int DeathUpPayloadLen = SoulGuidLen;

	/// <summary>Damage flag: apply without playing a hit reaction.</summary>
	public const byte DamageFlagSuppressHitReaction = 0x01;

	/// <summary>
	/// How long an invite waits for a response before the relay expires it.
	/// Long enough to notice a prompt mid-game, short enough that a forgotten
	/// invite does not keep the target blocked.
	/// </summary>
	public const int InviteTimeoutSeconds = 30;
}

/// <summary>What kind of interaction a session is running.</summary>
public enum InteractionKind : byte
{
	Dice = 0x01,
	Duel = 0x02,
}

/// <summary>
/// Which side of the session a participant is on. Interactions needing an
/// asymmetry — dice turn order, who strikes first — derive it from this rather
/// than negotiating separately.
/// </summary>
public enum SessionRole : byte
{
	Initiator = 0x00,
	Acceptor  = 0x01,
}

/// <summary>Why a session ended. Sent in SessionEnd so clients can tell the player.</summary>
public enum SessionEndReason : byte
{
	/// <summary>Ran to a natural conclusion.</summary>
	Completed = 0x00,
	/// <summary>Invitee said no.</summary>
	Declined = 0x01,
	/// <summary>Nobody answered the invite in time.</summary>
	Timeout = 0x02,
	/// <summary>The other participant dropped off the relay.</summary>
	PeerDisconnected = 0x03,
	/// <summary>A participant walked away deliberately.</summary>
	Left = 0x04,
	/// <summary>Target was already in a session.</summary>
	TargetBusy = 0x05,
	/// <summary>No such target, or the target is not ready.</summary>
	TargetUnavailable = 0x06,
	/// <summary>Malformed or out-of-order request.</summary>
	ProtocolError = 0x07,
}
