namespace KcdMp.Wire;

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
/// both leave. Dice (WO-5) and duelling are clients of this rather than
/// separate protocols.
/// C→S  0x0A  Invite:         [targetGhostId:1][kind:1][configLen:1][config:configLen]
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
/// [configLen:1][config:configLen] on Invite is new in WO-5 and optional: a
/// 2-byte Invite (no config) is still valid, matching the WO-2 wire exactly,
/// so the presence layer and old test scripts needed no changes. It carries
/// kind-specific open-time settings the same way SessionEvent carries
/// kind-specific in-play events -- opaque to this layer, interpreted only by
/// whichever kind reads it. Dice's config is
/// [targetScore:2 LE][debugSeedOverride:4 LE, optional, debug relay builds only].
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
/// Dice layer (WO-5). Unlike SessionEvent, these do not just relay -- the
/// relay itself is the authority (RNG, turn order, scoring, win detection),
/// so it terminates and interprets DiceIntent rather than forwarding it, and
/// DiceState is always the relay's own current snapshot, never a passthrough.
/// C→S  0x16  DiceIntent: [sessionId:2][intentType:1][data:N]
///              intentType: 0=Roll (no data), 1=Keep ([mask:1]), 2=Bank
///              (no data), 3=Forfeit (no data). mask bit i selects the i-th
///              die in the most recent DiceState's freeDice.
/// S→C  0x17  DiceState:  [sessionId:2][currentPlayerRole:1][scoreInitiator:4][scoreAcceptor:4]
///                        [turnTotal:4][targetScore:4][phase:1]
///                        [freeDiceCount:1][freeDiceFaces:freeDiceCount]
///                        [keptDiceCount:1][keptDiceFaces:keptDiceCount]
///                        [bustedDiceCount:1][bustedDiceFaces:bustedDiceCount]
///              A full snapshot, always -- never a delta. Sent to both
///              participants identically; each already knows its own role
///              from SessionStart. phase: 0=AwaitingRoll, 1=AwaitingKeep.
///              bustedDiceFaces is the roll that just busted, non-empty only
///              on the one snapshot immediately after a bust (freeDice is
///              already empty by then -- the engine clears it in the same
///              call that busts it, before this is ever sent). Appended
///              after the original WO-5 layout; a parser that stops after
///              keptDiceFaces still works, since the framing is
///              length-prefixed.
/// S→C  0x18  DiceError:  [sessionId:2][reason:1]  -- sent to the rejected
///              sender only. The game state is unchanged; retry with a
///              corrected intent.
/// S→C  0x19  DiceEnd:    [sessionId:2][outcome:1][scoreInitiator:4][scoreAcceptor:4]
///              outcome: 0=Initiator won, 1=Acceptor won. Sent to both
///              participants, immediately followed by a normal SessionEnd
///              (Completed) that removes the session.
///
/// Appearance layer (WO-9 armor, WO-10 weapons). Replicates the local
/// player's currently-equipped clothing/armor AND weapons onto their ghost,
/// per item, instead of the single hardcoded spawn-time preset.
/// C→S  0x1A  AppearanceUp:   [itemCount:1][itemClass:16]*itemCount
/// S→C  0x1B  AppearanceDown: [sourceGhostId:1][itemCount:1][itemClass:16]*itemCount
///
/// itemClass is the item's ItemClass GUID (the game's per-type id, e.g. every
/// "GambesonShort01_m04_D2" shares one), read from
/// EquipmentManager.EquippedArmorsByClassId AND EquippedWeaponsByClassId via
/// the reflection debug API -- NOT the SharedSoulGuid used by the combat
/// layer, and not an item instance id. Weapons (WO-10) were added to the same
/// message rather than a sibling one: EquipItem/UnequipItem/CreateItems are
/// item-class-agnostic (confirmed live, WO-10 -- the same calls that equip an
/// armor class equip a weapon class), so the wire payload and the receiver's
/// diff/apply logic need no new shape, only a second source map on the
/// outbound read. itemCount is small in practice (a full outfit plus one or
/// two weapons is under 20 slots) but bounded at
/// <see cref="Protocol.MaxAppearanceItems"/> so a malformed sender cannot
/// make a receiver allocate an unbounded array.
///
/// Sent only when the local player's equipped set changes, plus a slow
/// unconditional heartbeat (see GameBridge) so a peer who joins after the
/// last real change still converges -- the relay is stateless and does not
/// remember or replay appearance for a late joiner, exactly like it does not
/// for position.
///
/// The receiver diffs against what it last applied to that ghost (client-side
/// state, not on the wire) and only touches the slots that actually changed:
/// unequip what dropped out, equip what is new. This is the same
/// per-hit-authority, no-new-server-state shape as the combat layer.
///
/// Pause/world-halt mitigation layer (WO-11). KCD2's UI-state pauses (the
/// system menu, inventory, sleeping/skipping time) have no reachable native
/// veto (docs/WO-11-findings.md, tier A closed) -- the local player's own
/// tick keeps running, so this is not about un-pausing them. The problem is
/// the shared-world side effect. Each client runs its own full simulation
/// (HANDOFF-WO4-combat.md), so a player sitting in a menu stops advancing
/// relative to a peer who is not.
/// C→S  0x1C  PauseUp:   [state:1]                       (1 byte)
/// S→C  0x1D  PauseDown: [sourceGhostId:1][state:1]       (2 bytes)
///
/// state: 1 = entered a pausing-like UI state, 0 = exited. Sent on every
/// transition, not on a timer -- unlike Appearance there is no heartbeat,
/// because a late joiner who missed an "entered" they cannot still be
/// relevant to (the source's own tick has not stopped, so nothing about a
/// missed transition compounds the way a missed appearance change would).
///
/// Detected client-side by tailing kcd.log for engine-emitted markers that
/// bracket each state (docs/WO-11-findings.md addendum) -- no native hook,
/// since 0.2 showed none exists for these states. Only the log-tail
/// transport can see these lines; the HTTP transport never sends PauseUp.
///
/// **What a receiver does with it changed in WO-13.** WO-11 had every
/// receiver drop its own t_scale for as long as any peer reported paused.
/// That is retired and must not come back: it is correct for two players and
/// wrong at any real size, because in a 20-person session one player opening
/// their inventory would visibly slow the other nineteen. A player's own game
/// must never slow because someone else paused.
///
/// The packet survives as a pure presence signal: the receiver tags that
/// peer's ghost "[in menu]" so a motionless figure reads as "stepped away"
/// rather than broken. A manual `mp_slow_time` console command remains as an
/// independent, OR'd-in source of the same state, for states automatic
/// detection misses (tutorial popups and photo mode were never confirmed to
/// emit a log marker). Its name is now a misnomer -- it slows nothing; it
/// marks you as away.
///
/// Free type bytes for new features: 0x1E and up.
///
/// This file lives in the shared KcdMp.Protocol project (net8.0, no
/// dependencies). Both KcdMp.Client and KcdMp.Server reference it, so there is
/// exactly one copy of the wire contract to keep in sync with itself.
/// </summary>
public static class Protocol
{
    /// <summary>
    /// Protocol version, negotiated in the Handshake.
    ///
    /// Bumped to 6 for the pause-mitigation layer. The relay refuses any
    /// handshake version that isn't an exact match, so a peer that is
    /// actually connected always speaks the relay's own pause vocabulary --
    /// there is no separate "does the peer support this" gate to add on top
    /// of that, because a peer that didn't would never have gotten past
    /// Handshake.
    /// </summary>
    public const byte Version = 6;

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
    public const byte DiceIntent     = 0x16;
    public const byte AppearanceUp   = 0x1A;
    public const byte PauseUp        = 0x1C;

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
    public const byte DiceState        = 0x17;
    public const byte DiceError        = 0x18;
    public const byte DiceEnd          = 0x19;
    public const byte AppearanceDown   = 0x1B;
    public const byte PauseDown        = 0x1D;
    public const byte Ack              = 0xFF;

    /// <summary>Exact Position (0x01) payload length.</summary>
    public const int PositionPayloadLen = 17;

    /// <summary>Exact Ghost (0x02) payload length.</summary>
    public const int GhostPayloadLen = 18;

    /// <summary>Exact voice frame length: 20 ms of 16 kHz mono 16-bit PCM.</summary>
    public const int VoiceFrameLen = 640;

    /// <summary>Length of a SharedSoulGuid on the wire.</summary>
    public const int SoulGuidLen = 16;

    /// <summary>Exact Damage (0x12) upstream payload length.</summary>
    public const int DamageUpPayloadLen = SoulGuidLen + 4 + 4 + 1;

    /// <summary>Exact Damage (0x13) downstream payload length.</summary>
    public const int DamageDownPayloadLen = 1 + DamageUpPayloadLen;

    /// <summary>Exact Death (0x14) upstream payload length.</summary>
    public const int DeathUpPayloadLen = SoulGuidLen;

    /// <summary>Exact Death (0x15) downstream payload length.</summary>
    public const int DeathDownPayloadLen = 1 + SoulGuidLen;

    /// <summary>Damage flag: apply without playing a hit reaction.</summary>
    public const byte DamageFlagSuppressHitReaction = 0x01;

    /// <summary>Exact PauseUp (0x1C) payload length.</summary>
    public const int PauseUpPayloadLen = 1;

    /// <summary>Exact PauseDown (0x1D) payload length.</summary>
    public const int PauseDownPayloadLen = 2;

    /// <summary>PauseUp/PauseDown state byte: entered a pausing-like UI state.</summary>
    public const byte PauseStateEntered = 1;

    /// <summary>PauseUp/PauseDown state byte: exited it.</summary>
    public const byte PauseStateExited = 0;

    /// <summary>Length of an ItemClass GUID on the wire (Appearance layer).</summary>
    public const int ItemClassLen = 16;

    /// <summary>
    /// Upper bound on items in one Appearance packet. A full authored outfit
    /// tops out around 15 slots; this is headroom, not a measured ceiling, and
    /// exists so a malformed itemCount byte cannot make a receiver allocate
    /// 255 * 16 bytes on bad input.
    /// </summary>
    public const int MaxAppearanceItems = 32;

    /// <summary>How often the appearance layer resends unconditionally, so a peer who joins after the last real change still converges. The relay does not remember or replay it for a late joiner.</summary>
    public const int AppearanceHeartbeatSeconds = 30;

    /// <summary>
    /// How long an invite waits for a response before the relay expires it.
    /// Long enough to notice a prompt mid-game, short enough that a forgotten
    /// invite does not keep the target blocked.
    /// </summary>
    public const int InviteTimeoutSeconds = 30;

    /// <summary>Default Farkle target score, used when the Invite config omits it.</summary>
    public const int DefaultDiceTargetScore = 4000;
}

/// <summary>The sub-action inside a DiceIntent (0x16) payload.</summary>
public enum DiceIntentType : byte
{
    Roll = 0x00,
    Keep = 0x01,
    Bank = 0x02,
    Forfeit = 0x03,
}

/// <summary>What a DiceState (0x17) snapshot is currently waiting for.</summary>
public enum DicePhase : byte
{
    AwaitingRoll = 0x00,
    AwaitingKeep = 0x01,
}

/// <summary>Why a DiceIntent was rejected. Wire-facing mirror of KcdMp.Farkle's IntentRejectReason.</summary>
public enum DiceRejectReason : byte
{
    NotYourTurn = 0x01,
    WrongPhase = 0x02,
    EmptyKeep = 0x03,
    KeepIndexOutOfRange = 0x04,
    InvalidKeepSelection = 0x05,
    NothingToBank = 0x06,
    GameAlreadyOver = 0x07,
}

/// <summary>Who won a completed dice match, carried in DiceEnd (0x19).</summary>
public enum DiceOutcome : byte
{
    InitiatorWon = 0x00,
    AcceptorWon = 0x01,
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
