using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using KcdMp.Server;
using KcdMp.Wire;
using Microsoft.AspNetCore.Builder;
using Xunit;

namespace KcdMp.Relay.Tests;

// =============================================================================
// WO-102.5 Phase 4: departure handoff must be caught by a timeout, not only a
// clean disconnect (FIN) or an immediate reset (RST). A peer whose machine or
// network vanishes silently -- cable pulled, hard crash -- leaves the relay's
// read parked with neither signal. ClientSession sets NetworkStream.ReadTimeout
// (Tcp:IdleTimeoutMs, TcpSocketService); this is the one test that proves an
// idle connection is actually torn down and damage authority (Rule 2, the
// lowest ready id) actually moves to whoever remains -- not just that the
// field compiles.
//
// Runs its own relay (not RelayFixture's) so its idle timeout can be short
// (300 ms) without shortening the 30 s production default or affecting any
// other test's shared relay.
// =============================================================================
public class IdleTimeoutTests
{
    [Fact]
    public async Task Silent_peer_is_dropped_and_damage_authority_moves_to_the_survivor()
    {
        int tcpPort = FreePort();
        int httpPort = FreePort();
        await using var app = Program.CreateApp(new[]
        {
            "--port", tcpPort.ToString(),
            "--Urls", $"http://127.0.0.1:{httpPort}",
            "--Serilog:WriteTo:1:Name", "Console",
            "--Tcp:IdleTimeoutMs", "300",
        });
        await app.StartAsync();
        await WaitForBindAsync(tcpPort);

        var a = await Peer.ConnectAsync(tcpPort, "alpha");
        var b = await Peer.ConnectAsync(tcpPort, "bravo");

        // Rule 2: the lowest ready id is the damage authority -- alpha connected first.
        var roleA = await a.ReadUntilAsync(Protocol.CombatRole, TimeSpan.FromSeconds(2));
        var roleB = await b.ReadUntilAsync(Protocol.CombatRole, TimeSpan.FromSeconds(2));
        Assert.Equal(1, roleA[0]);
        Assert.Equal(0, roleB[0]);

        // Alpha goes silent -- no FIN, no RST, no Ping, nothing. Its socket
        // is simply never touched again. Bravo pings every 100 ms (well
        // under the 300 ms idle timeout) so ONLY alpha's silence is under
        // test -- a real client's own 2 s position heartbeat plays the same
        // role against the 30 s production default.
        var deadline = DateTime.UtcNow + TimeSpan.FromMilliseconds(900);
        while (DateTime.UtcNow < deadline)
        {
            await b.SendRawAsync(BuildPing());
            await Task.Delay(100);
        }

        // Bravo is told it is now the authority -- the relay noticed alpha's
        // read time out, tore the connection down, and re-ran Rule 2 over
        // the set that remains, exactly as a clean disconnect would.
        var newRole = await b.ReadUntilAsync(Protocol.CombatRole, TimeSpan.FromSeconds(2));
        Assert.Equal(1, newRole[0]);

        await a.DisposeAsync();
        await b.DisposeAsync();
        await app.StopAsync();
    }

    private static async Task WaitForBindAsync(int port)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            try
            {
                using var probe = new TcpClient();
                await probe.ConnectAsync(IPAddress.Loopback, port);
                return;
            }
            catch (SocketException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(50);
            }
        }
    }

    private static byte[] BuildPing()
    {
        var packet = new byte[3 + 8];
        packet[0] = Protocol.Ping;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 8);
        BinaryPrimitives.WriteInt64LittleEndian(packet.AsSpan(3), DateTime.UtcNow.Ticks);
        return packet;
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}
