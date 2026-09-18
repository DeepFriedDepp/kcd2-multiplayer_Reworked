using KcdMp.Client;
using KcdMp.Wire;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-100.5 Phase 3 -- the discrete action channel.
///
/// Every test here is (synthetic). No game, no relay, no DLL. What they prove
/// is that the ordering, the generation rule and the edge machine behave as
/// docs/WO-100.5-findings.md S3 says; what they cannot prove is that a real
/// attack produces the edges the detector expects at a 250 ms sampling
/// cadence, which needs a live session.
/// </summary>
public class ActionChannelTests
{
    // The relay prefixes the sender id and forwards the rest verbatim, so a
    // test can build an ActionDown from an ActionUp exactly as the relay does.
    private static byte[] Down(byte sender, byte[] up)
    {
        // up = [type:1][len:2][body...]
        var body = up.AsSpan(3).ToArray();
        var payload = new byte[1 + body.Length];
        payload[0] = sender;
        body.CopyTo(payload, 1);
        return payload;
    }

    [Fact]
    public void Build_roundtrips_through_the_inbox()
    {
        var outbox = new ActionOutbox();
        var inbox = new ActionInbox();
        var payload = new AttackPayload(1, 2, 1, AttackPayload.FlagPrepared);

        var up = outbox.Build(ActionKind.Attack, ActionPhase.Commit, payload.ToBytes());
        Assert.Equal(Protocol.ActionUp, up[0]);

        var a = inbox.Accept(Down(7, up), out var reject);
        Assert.Equal(ActionReject.None, reject);
        Assert.NotNull(a);
        Assert.Equal(7, a!.Value.SourceGhostId);
        Assert.Equal(ActionKind.Attack, a.Value.Kind);
        Assert.Equal(ActionPhase.Commit, a.Value.Phase);

        var got = AttackPayload.FromBytes(a.Value.Payload);
        Assert.Equal(payload, got);
        Assert.Equal("attack_heavy", got.InputClassName);
        Assert.Equal("upper_right", got.ZoneName);
        Assert.Equal("slash", got.AttackTypeName);
    }

    [Fact]
    public void A_replayed_packet_is_stale_not_accepted_twice()
    {
        var outbox = new ActionOutbox();
        var inbox = new ActionInbox();
        var up = outbox.Build(ActionKind.Attack, ActionPhase.Press, new byte[] { 0, 0, 0, 0 });

        Assert.NotNull(inbox.Accept(Down(1, up), out _));
        Assert.Null(inbox.Accept(Down(1, up), out var reject));
        Assert.Equal(ActionReject.StaleOrDuplicate, reject);
        Assert.Equal(1, inbox.Stale);
    }

    [Fact]
    public void Ordering_is_per_sender_and_per_kind()
    {
        var inbox = new ActionInbox();
        var a = new ActionOutbox();
        var b = new ActionOutbox();

        // Two senders each start at seq 1; neither may shadow the other.
        Assert.NotNull(inbox.Accept(Down(1, a.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _));
        Assert.NotNull(inbox.Accept(Down(2, b.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _));

        // Same sender, different kind: also its own sequence space.
        Assert.NotNull(inbox.Accept(Down(1, a.Build(ActionKind.Jump, ActionPhase.Press, Array.Empty<byte>())), out _));
        Assert.Equal(0, inbox.Stale);
    }

    [Fact]
    public void Sequence_comparison_survives_the_16_bit_wrap()
    {
        // The whole point of a half-range window: 0 must be NEWER than 65535,
        // not 65535 packets older. A naive `>` makes a wrap look like a flood
        // of stale packets and the channel goes deaf for the rest of the
        // session.
        Assert.True(Protocol.SeqIsNewer(0, ushort.MaxValue));
        Assert.True(Protocol.SeqIsNewer(5, ushort.MaxValue - 2));
        Assert.False(Protocol.SeqIsNewer(ushort.MaxValue, 0));
        Assert.False(Protocol.SeqIsNewer(3, 3));
        Assert.True(Protocol.SeqIsNewer(4, 3));
    }

    [Fact]
    public void An_action_from_a_previous_body_is_expired()
    {
        var inbox = new ActionInbox();
        var outbox = new ActionOutbox();

        // Learn generation 1.0.0 from the first packet.
        Assert.NotNull(inbox.Accept(Down(1, outbox.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _));

        // The sender respawns: incarnation moves forward, and seq restarts.
        var fresh = new ActionOutbox();
        fresh.BumpIncarnation();   // 2.0.0
        Assert.NotNull(inbox.Accept(Down(1, fresh.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _));

        // Now a straggler from the OLD body arrives late. It must be expired,
        // not applied to the body that replaced it.
        var straggler = new ActionOutbox();
        for (int i = 0; i < 5; i++) straggler.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>());
        var late = straggler.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>());
        Assert.Null(inbox.Accept(Down(1, late), out var reject));
        Assert.Equal(ActionReject.Expired, reject);
        Assert.Equal(1, inbox.Expired);
    }

    [Fact]
    public void A_new_incarnation_resets_the_ordering_rather_than_rejecting_it()
    {
        // seq restarts at 1 with a new body. If the inbox kept the old
        // last-seq, every packet from the new body would look stale -- the
        // failure this test exists to prevent.
        var inbox = new ActionInbox();
        var old = new ActionOutbox();
        for (int i = 0; i < 50; i++)
            inbox.Accept(Down(1, old.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _);

        var fresh = new ActionOutbox();
        fresh.BumpIncarnation();
        Assert.NotNull(inbox.Accept(Down(1, fresh.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out var r));
        Assert.Equal(ActionReject.None, r);
    }

    [Fact]
    public void A_reconnect_epoch_moves_forward_and_is_accepted()
    {
        var inbox = new ActionInbox();
        var outbox = new ActionOutbox();
        inbox.Accept(Down(1, outbox.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out _);

        outbox.BumpEpoch();
        Assert.NotNull(inbox.Accept(Down(1, outbox.Build(ActionKind.Attack, ActionPhase.Press, Array.Empty<byte>())), out var r));
        Assert.Equal(ActionReject.None, r);
    }

    [Fact]
    public void A_truncated_packet_is_malformed_not_a_crash()
    {
        var inbox = new ActionInbox();
        Assert.Null(inbox.Accept(new byte[] { 1, 1, 0 }, out var reject));
        Assert.Equal(ActionReject.Malformed, reject);

        // A len byte that lies about the body is the case a verbatim relay
        // forward would otherwise hand straight to the decoder.
        var lying = new byte[] { 1, (byte)ActionKind.Attack, 1, 0, 0, 1, 0, 0, 0, 40 };
        Assert.Null(inbox.Accept(lying, out reject));
        Assert.Equal(ActionReject.Malformed, reject);
        Assert.Equal(2, inbox.Malformed);
    }

    [Fact]
    public void An_unknown_kind_is_named_rather_than_guessed()
    {
        var inbox = new ActionInbox();
        var packet = new byte[] { 1, 200, 1, 0, 0, 1, 0, 0, 0, 0 };
        Assert.Null(inbox.Accept(packet, out var reject));
        Assert.Equal(ActionReject.UnknownKind, reject);
    }

    [Fact]
    public void Gen_packs_and_unpacks()
    {
        var g = new ActionGen(0xBEEF, 0x12, 0x34);
        Assert.Equal(g, ActionGen.Unpack(g.Pack()));
        Assert.Equal("48879.18.52", g.ToString());
    }

    [Fact]
    public void Payload_over_the_cap_is_refused_at_the_sender()
    {
        var outbox = new ActionOutbox();
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            outbox.Build(ActionKind.Attack, ActionPhase.Press, new byte[Protocol.ActionPayloadMaxLen + 1]));
    }

    // --- the edge detector --------------------------------------------------

    [Fact]
    public void Press_then_commit_then_release_is_press_commit_complete()
    {
        var d = new AttackEdgeDetector();
        Assert.Null(d.Feed(true, -1, -1, -1, false));                   // at rest

        var press = d.Feed(true, 1, 2, 1, false);
        Assert.Equal(ActionPhase.Press, press!.Value.Phase);

        var commit = d.Feed(true, 1, 2, 1, true);
        Assert.Equal(ActionPhase.Commit, commit!.Value.Phase);
        Assert.Equal(AttackPayload.FlagPrepared, commit.Value.Payload.Flags);

        var done = d.Feed(true, -1, -1, -1, false);
        Assert.Equal(ActionPhase.Complete, done!.Value.Phase);
    }

    [Fact]
    public void A_press_that_never_commits_cancels()
    {
        // The case that makes this the INPUT rather than the result: a press
        // the player abandoned is a real thing the remote body should show and
        // then drop, and it must not look like a completed attack.
        var d = new AttackEdgeDetector();
        Assert.Equal(ActionPhase.Press, d.Feed(true, 0, 1, 1, false)!.Value.Phase);
        Assert.Equal(ActionPhase.Cancel, d.Feed(true, -1, -1, -1, false)!.Value.Phase);
    }

    [Fact]
    public void Non_attack_input_classes_do_not_produce_attack_edges()
    {
        // 3..6 are move_*, 7 is block. They travel on the combat model too and
        // must not be published as attacks.
        var d = new AttackEdgeDetector();
        Assert.Null(d.Feed(true, 7, -1, -1, false));
        Assert.Null(d.Feed(true, 5, -1, -1, false));
        Assert.Null(d.Feed(true, -1, -1, -1, false));
    }

    [Fact]
    public void Losing_the_combat_actor_clears_without_emitting_a_cancel()
    {
        // No combat actor means no fight has begun -- the ordinary resting
        // state. Emitting a cancel for it would put a phantom event on the
        // wire every time a fight ended.
        var d = new AttackEdgeDetector();
        Assert.Equal(ActionPhase.Press, d.Feed(true, 1, 0, 0, false)!.Value.Phase);
        Assert.Null(d.Feed(false, -1, -1, -1, false));
        // and the machine is clean afterwards
        Assert.Equal(ActionPhase.Press, d.Feed(true, 1, 0, 0, false)!.Value.Phase);
    }

    [Fact]
    public void A_steady_hold_does_not_re_emit()
    {
        var d = new AttackEdgeDetector();
        Assert.NotNull(d.Feed(true, 1, 2, 1, false));
        Assert.Null(d.Feed(true, 1, 2, 1, false));
        Assert.Null(d.Feed(true, 1, 2, 1, false));
    }
}
