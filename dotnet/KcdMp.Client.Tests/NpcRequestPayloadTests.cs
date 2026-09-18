using KcdMp.Client;
using KcdMp.Wire;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-102 Phase 5: the NpcRequest payload codec and its passage through the
/// shipped ActionOutbox/ActionInbox pair (in-process). The wire crossing is
/// the relay round-trip gate's job (RelayRoundTripTests).
/// </summary>
public class NpcRequestPayloadTests
{
    [Fact]
    public void Round_trips_through_bytes()
    {
        var p = new NpcRequestPayload(new AttackPayload(1, 3, 2, AttackPayload.FlagPrepared), "ttkc_man_20");
        var b = p.ToBytes();
        Assert.Equal(NpcRequestPayload.FixedLen + 11, b.Length);
        Assert.True(NpcRequestPayload.TryFromBytes(b, out var q));
        Assert.Equal(p, q);
        Assert.Contains("target=ttkc_man_20", q.ToString());
    }

    [Fact]
    public void Name_at_the_limit_fits_and_one_over_is_refused_to_build()
    {
        string ok = new string('a', NpcRequestPayload.MaxNameLen);
        var b = new NpcRequestPayload(new AttackPayload(0, 0, 0, 0), ok).ToBytes();
        Assert.Equal(Protocol.ActionPayloadMaxLen, b.Length);   // exactly the channel's ceiling
        Assert.True(NpcRequestPayload.TryFromBytes(b, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => new NpcRequestPayload(new AttackPayload(0, 0, 0, 0), ok + "b").ToBytes());
    }

    [Theory]
    [InlineData("bad name")]
    [InlineData("kcd2mp_1;os.exit()")]
    [InlineData("")]
    public void Names_that_are_not_authored_entity_names_are_refused(string name)
    {
        var b = new byte[NpcRequestPayload.FixedLen + Math.Max(1, name.Length)];
        var nb = System.Text.Encoding.UTF8.GetBytes(name);
        b[AttackPayload.Len] = (byte)nb.Length;
        nb.CopyTo(b, NpcRequestPayload.FixedLen);
        Assert.False(NpcRequestPayload.TryFromBytes(b, out _));
    }

    [Fact]
    public void Lying_length_byte_is_refused()
    {
        var b = new NpcRequestPayload(new AttackPayload(0, 0, 0, 0), "abc").ToBytes();
        b[AttackPayload.Len] = 40;   // claims more bytes than the frame holds
        Assert.False(NpcRequestPayload.TryFromBytes(b, out _));
    }

    [Fact]
    public void Passes_through_the_action_channel_in_process()
    {
        var outbox = new ActionOutbox();
        var inbox = new ActionInbox();
        var p = new NpcRequestPayload(new AttackPayload(1, 4, 2, 1), "ttkc_jakes");
        var packet = outbox.Build(ActionKind.NpcRequest, ActionPhase.Commit, p.ToBytes());
        // relay shape: [sourceGhostId] + body verbatim
        var down = new byte[1 + packet.Length - 3];
        down[0] = 7;
        Array.Copy(packet, 3, down, 1, packet.Length - 3);
        var a = inbox.Accept(down, out var reject);
        Assert.NotNull(a);
        Assert.Equal(ActionReject.None, reject);
        Assert.Equal(ActionKind.NpcRequest, a!.Value.Kind);
        Assert.Equal(ActionPhase.Commit, a.Value.Phase);
        Assert.True(NpcRequestPayload.TryFromBytes(a.Value.Payload, out var q));
        Assert.Equal(p, q);
    }
}
