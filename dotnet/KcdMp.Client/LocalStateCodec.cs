using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// WO-102 Phase 1: one native read of the local player -- position, yaw,
/// riding, and the WO-100.5 body state, from ONE frame, over the DLL pipe
/// (command 0x0A, reply 0x86). This replaces the [KCD2-MP-DATA] log line as
/// the position source when <c>mp_pos_native_on</c> is set; the log line stays
/// the fallback and still carries vitals and every event.
/// </summary>
/// <param name="Frame">The DLL's main-thread frame counter when the read ran. Two reads on one frame are one sample.</param>
/// <param name="Flags">bit 0: riding (the Mannequin Stance group reads <c>horse</c>).</param>
/// <param name="Body">The body state read in the same frame, or null when that half refused.</param>
/// <param name="State2">WO-121: the v8 state block read in the same frame, or null (an older DLL, or that half refused).</param>
public readonly record struct LocalState(
    ulong Frame, float X, float Y, float Z, float RotZ, byte Flags, LocalBodyState? Body,
    KcdMp.Wire.BodyState2? State2 = null)
{
    public bool IsRiding => (Flags & 0x01) != 0;
}

/// <summary>
/// Why the DLL refused a local-state read. Mirrors <c>kcdmp::localstate::Refuse</c>
/// in <c>native/KCDMP/local_state.h</c> by number; append-only.
/// </summary>
public enum LocalStateRefuse : byte
{
    Ok = 0,
    /// <summary>EntityModule / CryEntitySystem not loaded.</summary>
    ModuleMissing = 1,
    /// <summary>C_EntityModule::GetPlayerActor returned null (no world yet).</summary>
    NoPlayerActor = 2,
    /// <summary>The actor-to-entity hop is not mapped on this build (offsets are the placeholders) -- the path is disabled by construction, not by failure.</summary>
    EntityHopUnmapped = 3,
    /// <summary>A memory read or virtual call faulted (SEH).</summary>
    ReadFaulted = 4,
    /// <summary>The engine returned a non-finite coordinate.</summary>
    NonFinite = 5,
    /// <summary>The entity's vtable is not the class the offsets were mapped against.</summary>
    VtableMismatch = 6,
    /// <summary>The DLL is older than this agent and does not know the command (agent-side classification of "no answer").</summary>
    Unknown = 255,
}

/// <summary>
/// The 0x86 reply body. Fixed 40 bytes in every case so a refusal and a
/// success have one shape:
/// <code>
/// [ok:1][seq:1][refuse:1][frame:8 LE][x:4f][y:4f][z:4f][rotZ:4f][flags:1][haveBody:1]
/// [pace:1][dir:1][stance:1][animSpeedCenti:2 LE][unknownTags:1]
/// [haveCombat:1][inputClass:1][zone:1][atkType:1][prepared:1]
/// </code>
/// The body block is byte-identical to the 0x85 BodyState reply's bytes 2..12
/// so the two decoders cannot drift apart.
///
/// WO-121 appends <c>[haveState2:1][state2:12]</c> (53 bytes): the v8 state
/// block (speed, move direction, combat mode, guard, block, crouch) read in
/// the same frame. A 40-byte reply is still parsed (no State2).
/// </summary>
public static class LocalStateCodec
{
    public const int Len = 40;
    public const int LenV8 = Len + 1 + KcdMp.Wire.BodyState2.Len;

    public static bool TryParse(ReadOnlySpan<byte> body, out LocalState state, out LocalStateRefuse refuse)
    {
        state = default;
        refuse = LocalStateRefuse.Unknown;
        if (body.Length < 3) return false;
        refuse = (LocalStateRefuse)body[2];
        if (body[0] != 1) return false;
        if (body.Length < Len) { refuse = LocalStateRefuse.Unknown; return false; }

        ulong frame = BinaryPrimitives.ReadUInt64LittleEndian(body[3..]);
        float x    = BinaryPrimitives.ReadSingleLittleEndian(body[11..]);
        float y    = BinaryPrimitives.ReadSingleLittleEndian(body[15..]);
        float z    = BinaryPrimitives.ReadSingleLittleEndian(body[19..]);
        float rotZ = BinaryPrimitives.ReadSingleLittleEndian(body[23..]);
        byte flags = body[27];
        bool haveBody = body[28] == 1;
        if (!float.IsFinite(x) || !float.IsFinite(y) || !float.IsFinite(z) || !float.IsFinite(rotZ))
        {
            refuse = LocalStateRefuse.NonFinite;
            return false;
        }

        LocalBodyState? lb = null;
        if (haveBody)
        {
            var bs = new BodyState((BodyPace)body[29], (BodyDir)body[30], (BodyStance)body[31],
                                   BinaryPrimitives.ReadUInt16LittleEndian(body[32..]));
            // body[34] = unknownTags (counted by the caller), body[35] = haveCombat
            lb = new LocalBodyState(bs, body[35] == 1, (sbyte)body[36], (sbyte)body[37], (sbyte)body[38], body[39] != 0);
        }
        KcdMp.Wire.BodyState2? st2 = null;
        if (body.Length >= LenV8 && body[Len] == 1)
            st2 = KcdMp.Wire.BodyState2.Read(body[(Len + 1)..]);
        state = new LocalState(frame, x, y, z, rotZ, flags, lb, st2);
        refuse = LocalStateRefuse.Ok;
        return true;
    }

    /// <summary>unknownTags from a successful reply (0 when refused or no body).</summary>
    public static byte UnknownTags(ReadOnlySpan<byte> body) =>
        body.Length >= Len && body[0] == 1 && body[28] == 1 ? body[34] : (byte)0;
}
