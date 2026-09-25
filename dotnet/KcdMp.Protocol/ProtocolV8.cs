using System.Buffers.Binary;

namespace KcdMp.Wire;

// ---------------------------------------------------------------------------
// WO-121 -- movement and combat, protocol v8 (docs/WO-121-findings.md,
// design in docs/WO-119-action-fidelity.md s5).
//
// The rule this layer follows: replicate the INPUTS the engine consumes (a
// state block) and the DECISIONS it makes once (events); never "play clip X".
// Every enum crosses as one of OUR append-only ordinals keyed on the shipped
// table NAME (combat_zone.xml, combat_guard_stance.xml), and every attack,
// block and dodge row crosses as its authored mn_fragment_guid -- never as an
// engine index.
//
// Three pieces:
//
//   1. BODY STATE 2 (Position/Ghost flag 0x10, 12 bytes). Supersedes the
//      WO-100.5 0x04 block, which a v8 sender never sets and a v8 relay no
//      longer accepts. Change-gated at the sender: present when any field
//      differs from the last one sent, and at least every
//      BodyState2HeartbeatMs while anything is non-zero, so a late joiner
//      converges. Layout (LE):
//        [speedCm:u16]     planar speed of the sender's requested velocity, cm/s
//        [moveDir:i8]      heading of that velocity minus the body's facing,
//                          in 1/256 of a turn (1.40625 deg)
//        [bits:u8]         BodyState2Bits
//        [guardZone:u8]    WireZone
//        [guardStance:u8]  WireGuardStance
//        [atkZone:u8]      WireZone (the requested attack zone)
//        [charge:u8]       ranged charge 0..255 (0 when no ranged weapon drawn)
//        [aimYaw:i16]      ranged aim yaw, 1/10000 rad (0 when not aiming)
//        [aimPitch:i16]    ranged aim pitch, 1/10000 rad
//      Tail order after the flags byte: [bodyState2:12 if 0x10][senderMs:4 if 0x08].
//      Position lengths 17/21/29/33, Ghost 18/22/30/34 -- exact, never a range.
//
//   2. EVENTS on the ActionUp/ActionDown channel (0x3B/0x3C), new kinds. Each
//      v8 event payload starts with the sender's u32 ms stamp (the same clock
//      as the Position frame's), so a receiver drops an event that is more
//      than EventStaleMs behind the newest Position it has from that sender,
//      and counts it. Ordering by (sender, kind) seq and validity by gen are
//      the WO-100.5 channel's own.
//
//   3. PLAYER HIT (0x44 up / 0x45 down): friendly fire. The attacker's machine
//      catches its local hit on a peer's avatar at the combat-hit chokepoint,
//      keeps it off the avatar, and (friendly fire on) sends the damage to the
//      victim's machine, which applies it to its own Henry with NO attacker
//      attached. Routed to the victim alone; never authority-gated (any player
//      can hit any player). Friendly fire off: nothing is sent.
//
// Plus two small ones: NpcDamage (0x30/0x31) gains flag 0x04 ATTRIBUTED (the
// sender's own player dealt the hit; the NPC's authority books the peer's
// avatar as the attacker), and the host-only SessionSetting event carries the
// session-wide friendly-fire lever.
// ---------------------------------------------------------------------------

/// <summary>WO-121: a combat zone, by the name in the shipped combat_zone.xml. APPEND-ONLY.</summary>
public enum WireZone : byte
{
    Undefined = 0, Head = 1, UpperLeft = 2, UpperRight = 3, LowerLeft = 4, LowerRight = 5, Lower = 6,
}

/// <summary>WO-121: a guard stance, by the name in the shipped combat_guard_stance.xml. APPEND-ONLY.</summary>
public enum WireGuardStance : byte
{
    None = 0, Left = 1, Right = 2,
}

/// <summary>WO-121: the bits byte of BodyState2.</summary>
[Flags]
public enum BodyState2Bits : byte
{
    None = 0,
    /// <summary>The sender's combat model reads CombatMode (a real fight stance, not just a drawn weapon).</summary>
    CombatMode = 0x01,
    /// <summary>A block is held (the combat model's block mode, any scope).</summary>
    BlockHeld = 0x02,
    /// <summary>Crouched (the state expansion's crouch desire).</summary>
    Crouched = 0x04,
    /// <summary>A ranged weapon is drawn and aiming; charge/aim fields are meaningful.</summary>
    RangedAim = 0x08,
    /// <summary>The sender is locked on an opponent (combat model opponent pointer set).</summary>
    Locked = 0x10,
}

/// <summary>WO-121: the 12 replicated-state bytes (Position/Ghost flag 0x10).</summary>
public readonly record struct BodyState2(
    ushort SpeedCm, sbyte MoveDir, BodyState2Bits Bits, WireZone GuardZone, WireGuardStance GuardStance,
    WireZone AtkZone, byte Charge, short AimYaw, short AimPitch)
{
    public const int Len = 12;

    public float SpeedMps => SpeedCm / 100f;
    /// <summary>moveDir in radians, (-pi, pi].</summary>
    public float MoveDirRad => MoveDir * (MathF.PI / 128f);
    public bool CombatMode => (Bits & BodyState2Bits.CombatMode) != 0;
    public bool BlockHeld  => (Bits & BodyState2Bits.BlockHeld) != 0;
    public bool Crouched   => (Bits & BodyState2Bits.Crouched) != 0;

    public void Write(Span<byte> o)
    {
        BinaryPrimitives.WriteUInt16LittleEndian(o, SpeedCm);
        o[2] = unchecked((byte)MoveDir);
        o[3] = (byte)Bits;
        o[4] = (byte)GuardZone;
        o[5] = (byte)GuardStance;
        o[6] = (byte)AtkZone;
        o[7] = Charge;
        BinaryPrimitives.WriteInt16LittleEndian(o[8..], AimYaw);
        BinaryPrimitives.WriteInt16LittleEndian(o[10..], AimPitch);
    }

    public static BodyState2 Read(ReadOnlySpan<byte> b) => new(
        BinaryPrimitives.ReadUInt16LittleEndian(b), unchecked((sbyte)b[2]), (BodyState2Bits)b[3],
        (WireZone)b[4], (WireGuardStance)b[5], (WireZone)b[6], b[7],
        BinaryPrimitives.ReadInt16LittleEndian(b[8..]), BinaryPrimitives.ReadInt16LittleEndian(b[10..]));

    /// <summary>
    /// The pre-v8 body state the LEGACY Lua gait path consumes, derived from
    /// this block, so that turning the native gait off gives 0.28.x back with
    /// no second wire block. Pace from speed with the engine's own gait bands
    /// measured live on Henry (walk ~1.5, run 3.05, sprint ~5.5 m/s); dir from
    /// moveDir; stance from the crouch bit.
    /// </summary>
    public BodyState ToLegacy(bool riding)
    {
        float s = SpeedMps;
        var pace = s < 0.15f ? BodyPace.None : s < 2.3f ? BodyPace.Walk : s < 4.3f ? BodyPace.Run : BodyPace.Sprint;
        float d = MathF.Abs(MoveDirRad);
        var dir = pace == BodyPace.None ? BodyDir.None
                : d <= MathF.PI / 4 ? BodyDir.Forward
                : d >= 3 * MathF.PI / 4 ? BodyDir.Backward
                : MoveDir > 0 ? BodyDir.Left : BodyDir.Right;
        var stance = riding ? BodyStance.Horse : Crouched ? BodyStance.Stealth : BodyStance.Upright;
        return new BodyState(pace, dir, stance, SpeedCm);
    }

    public override string ToString() => FormattableString.Invariant(
        $"speed={SpeedMps:F2} dir={MoveDirRad:F2} combat={(CombatMode ? 1 : 0)} block={(BlockHeld ? 1 : 0)} crouch={(Crouched ? 1 : 0)} guard={GuardZone}/{GuardStance} atk={AtkZone} locked={((Bits & BodyState2Bits.Locked) != 0 ? 1 : 0)}");
}

/// <summary>WO-121: SessionSetting keys (the host's session-wide levers). APPEND-ONLY.</summary>
public static class SessionSettingKey
{
    public const byte FriendlyFire = 1;
    public static string Name(byte k) => k switch { FriendlyFire => "friendly_fire", _ => $"unknown-{k}" };
}

/// <summary>
/// WO-121: the v8 Attack event payload --
/// <c>[senderMs:4][inputClass:1][zone:1 WireZone][attackType:1][flags:1][rowGuid:16]</c>, 24 bytes.
/// The ROW GUID selects what the receiver plays (the row's own fragment and
/// tags, from its own Tables.pak); input class and attack type are
/// informational and never select anything.
/// </summary>
public readonly record struct AttackEvent(uint SenderMs, sbyte InputClass, WireZone Zone, sbyte AttackType, byte Flags, Guid Row)
{
    public const int Len = 4 + 4 + 16;
    public const byte FlagCombo = 0x01;

    public byte[] ToBytes()
    {
        var b = new byte[Len];
        BinaryPrimitives.WriteUInt32LittleEndian(b, SenderMs);
        b[4] = unchecked((byte)InputClass); b[5] = (byte)Zone; b[6] = unchecked((byte)AttackType); b[7] = Flags;
        Row.TryWriteBytes(b.AsSpan(8));
        return b;
    }

    public static bool TryFromBytes(ReadOnlySpan<byte> b, out AttackEvent e)
    {
        e = default;
        if (b.Length < Len) return false;
        e = new AttackEvent(BinaryPrimitives.ReadUInt32LittleEndian(b), unchecked((sbyte)b[4]), (WireZone)b[5],
                            unchecked((sbyte)b[6]), b[7], new Guid(b.Slice(8, 16)));
        return true;
    }

    public override string ToString() =>
        $"row={Row} zone={Zone} input={Protocol.CombatInputClassName(InputClass)} type={Protocol.CombatAttackTypeName(AttackType)} ms={SenderMs}";
}

/// <summary>
/// WO-121: the payload of the row-carrying one-shot events (BlockImpulse,
/// Dodge, NpcAttack): <c>[senderMs:4][flags:1][rowGuid:16][nameLen:1][name]</c>.
/// The name is empty except for NpcAttack (the host NPC's authored entity name,
/// validated <c>[A-Za-z0-9_]+</c> like NpcState's).
/// </summary>
public readonly record struct RowEvent(uint SenderMs, byte Flags, Guid Row, string Name)
{
    public const int FixedLen = 4 + 1 + 16 + 1;
    public const int MaxNameLen = Protocol.ActionPayloadMaxLen - FixedLen;
    /// <summary>BlockImpulse flag: a perfect block (the row is a combat_action_perfect_block row).</summary>
    public const byte FlagPerfect = 0x01;

    public byte[] ToBytes()
    {
        var nb = System.Text.Encoding.UTF8.GetBytes(Name ?? "");
        if (nb.Length > MaxNameLen) throw new ArgumentOutOfRangeException(nameof(Name));
        var b = new byte[FixedLen + nb.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(b, SenderMs);
        b[4] = Flags;
        Row.TryWriteBytes(b.AsSpan(5));
        b[21] = (byte)nb.Length;
        nb.CopyTo(b, FixedLen);
        return b;
    }

    public static bool TryFromBytes(ReadOnlySpan<byte> b, out RowEvent e)
    {
        e = default;
        if (b.Length < FixedLen) return false;
        int n = b[21];
        if (n > MaxNameLen || b.Length != FixedLen + n) return false;
        string name = System.Text.Encoding.UTF8.GetString(b.Slice(FixedLen, n));
        foreach (char c in name)
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '_')) return false;
        e = new RowEvent(BinaryPrimitives.ReadUInt32LittleEndian(b), b[4], new Guid(b.Slice(5, 16)), name);
        return true;
    }
}

/// <summary>
/// WO-121: PlayerHit (0x44 up / 0x45 down) -- one friendly-fire hit.
/// Up: <c>[victimGhostId:1][stamina:4f][health:4f][flags:1][material:1]</c> (11).
/// Down: <c>[attackerGhostId:1]</c> + the up body (12).
/// stamina/health are LOSS amounts, as TakeDamage takes them.
/// </summary>
public readonly record struct PlayerHitV8(byte Victim, float Stamina, float Health, byte Flags, byte Material)
{
    public const int UpLen = 11;
    public const int DownLen = 12;
    /// <summary>The attacker had no weapon in hand: a fist hit (a knockdown, never a grave).</summary>
    public const byte FlagUnarmed = 0x01;
    /// <summary>A missile (arrow/bolt) hit, from the combat soul's missile slot.</summary>
    public const byte FlagMissile = 0x02;

    public byte[] BuildUp()
    {
        var p = new byte[3 + UpLen];
        p[0] = Protocol.PlayerHitV8Up;
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(1), UpLen);
        p[3] = Victim;
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(4), Stamina);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(8), Health);
        p[12] = Flags; p[13] = Material;
        return p;
    }

    /// <summary>Decodes a 0x45 body; the attacker id comes back separately.</summary>
    public static bool TryDecodeDown(ReadOnlySpan<byte> b, out byte attacker, out PlayerHitV8 hit)
    {
        attacker = 0; hit = default;
        if (b.Length != DownLen) return false;
        attacker = b[0];
        float st = BinaryPrimitives.ReadSingleLittleEndian(b[2..]);
        float hp = BinaryPrimitives.ReadSingleLittleEndian(b[6..]);
        if (!float.IsFinite(st) || !float.IsFinite(hp) || st < 0 || hp < 0 || hp > 1000 || st > 1000) return false;
        hit = new PlayerHitV8(b[1], st, hp, b[10], b[11]);
        return true;
    }

    public bool Unarmed => (Flags & FlagUnarmed) != 0;
    public override string ToString() => FormattableString.Invariant(
        $"victim={Victim} hp={Health:F2} st={Stamina:F2} unarmed={(Unarmed ? 1 : 0)} missile={((Flags & FlagMissile) != 0 ? 1 : 0)} material={Material}");
}

public static partial class Protocol
{
    // ---- WO-121 type bytes ----
    public const byte PlayerHitV8Up   = 0x44;
    public const byte PlayerHitV8Down = 0x45;

    // ---- WO-121 Position/Ghost ----
    /// <summary>WO-121: Position/Ghost flag -- BodyState2 (12 bytes) follows the flags byte.</summary>
    public const byte PositionFlagBodyState2 = 0x10;
    public const int BodyState2Len = BodyState2.Len;
    /// <summary>WO-121: while any state field is non-zero the block is re-sent at least this often.</summary>
    public const int BodyState2HeartbeatMs = 1000;

    /// <summary>
    /// WO-121: an event older than this against the newest Position stamp from
    /// the same sender is dropped (and counted) -- a swing that arrives a
    /// second late would play against a body that has moved on.
    /// </summary>
    public const int EventStaleMs = 1000;

    /// <summary>WO-121: NpcDamage flag -- the sender's own player dealt this hit; the NPC's authority books the sender's avatar as the attacker.</summary>
    public const byte NpcDamageFlagAttributed = 0x04;

    // ---- WO-121 zone/stance name tables (shipped Libs/Tables/combat) ----
    // Engine table id -> our ordinal, and both directions by NAME. The engine
    // ids are the shipped XML's authored ids; the mapping is asserted against
    // the game's own Tables.pak by KcdMp.Client.Tests when it is present.
    public static readonly (int TableId, string Name, WireZone Wire)[] ZoneTable =
    {
        (-1, "undefined", WireZone.Undefined), (0, "head", WireZone.Head), (1, "upper_left", WireZone.UpperLeft),
        (2, "upper_right", WireZone.UpperRight), (3, "lower_left", WireZone.LowerLeft),
        (4, "lower_right", WireZone.LowerRight), (5, "lower", WireZone.Lower),
    };
    public static readonly (int TableId, string Name, WireGuardStance Wire)[] GuardStanceTable =
    {
        (-1, "none", WireGuardStance.None), (0, "left", WireGuardStance.Left), (1, "right", WireGuardStance.Right),
    };

    public static WireZone ZoneFromTableId(int id)
    {
        foreach (var z in ZoneTable) if (z.TableId == id) return z.Wire;
        return WireZone.Undefined;
    }
    public static int ZoneToTableId(WireZone w)
    {
        foreach (var z in ZoneTable) if (z.Wire == w) return z.TableId;
        return -1;
    }
    public static WireGuardStance StanceFromTableId(int id)
    {
        foreach (var s in GuardStanceTable) if (s.TableId == id) return s.Wire;
        return WireGuardStance.None;
    }

    /// <summary>WO-121: Position lengths when the v8 state block rides along.</summary>
    public const int PositionPayloadLenV8 = PositionPayloadLen + BodyState2Len;            // 29
    public const int PositionPayloadLenV8Max = PositionPayloadLen + BodyState2Len + SenderMsLen;   // 33
    public const int GhostPayloadLenV8 = GhostPayloadLen + BodyState2Len;                  // 30
    public const int GhostPayloadLenV8Max = GhostPayloadLen + BodyState2Len + SenderMsLen; // 34
}
