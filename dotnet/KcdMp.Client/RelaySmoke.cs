using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// WO-110 R10: <c>KcdMpClient.exe --relay-smoke --host h --port p</c>.
///
/// Connects to a relay, completes the real Handshake with this build's
/// protocol byte and release version, waits for the Ack, sends one Ping and
/// waits for the matching Pong, prints one <c>RELAY-SMOKE</c> line and exits
/// 0. Any refusal, mismatch or timeout prints why and exits 1.
///
/// Why this exists: the release gate ran unit tests and an in-process relay,
/// but the MERGED publish folder -- four self-contained publishes flat-copied
/// over each other, later projects overwriting shared DLLs
/// (tools/Publish-Release.ps1) -- was never executed by anything before the
/// installer embedded it (docs/WO-109-audit.md R10). This is the smallest
/// thing that proves the published agent and the published relay start,
/// load their assemblies, agree on the protocol byte and the release
/// version, and complete one round trip. It never touches the game, so it
/// needs no save, no mod and no kcd.log, and it never writes a config file
/// (Program.cs handles the flag before ClientConfig is saved).
/// </summary>
public static class RelaySmoke
{
    public static async Task<int> RunAsync(string host, int port, string name, TimeSpan timeout)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var cts = new CancellationTokenSource(timeout);
            using var tcp = new TcpClient();
            await tcp.ConnectAsync(host, port, cts.Token);
            var stream = tcp.GetStream();

            // The exact handshake GameBridge.ConnectAndRunAsync sends.
            var nameBytes = Encoding.UTF8.GetBytes(name);
            var rel = Encoding.UTF8.GetBytes(ReleaseVersionInfo.Current);
            int len = 2 + nameBytes.Length + rel.Length;
            var hs = new byte[3 + len];
            hs[0] = Protocol.Handshake;
            BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)len);
            hs[3] = Protocol.Version;
            hs[4] = (byte)nameBytes.Length;
            nameBytes.CopyTo(hs, 5);
            rel.CopyTo(hs, 5 + nameBytes.Length);
            await stream.WriteAsync(hs, cts.Token);

            var (type, payload) = await ReadPacketAsync(stream, cts.Token);
            if (type == Protocol.VersionMismatch)
            {
                Console.WriteLine($"RELAY-SMOKE FAIL protocol mismatch: relay speaks v{payload[0]}, this agent v{Protocol.Version}");
                return 1;
            }
            if (type != Protocol.Ack)
            {
                Console.WriteLine($"RELAY-SMOKE FAIL expected Ack 0x{Protocol.Ack:X2}, got 0x{type:X2} ({payload.Length} bytes)");
                return 1;
            }
            byte id = payload[0];

            // One Ping / Pong: the smallest real round trip the relay answers itself.
            var ping = new byte[3 + 8];
            ping[0] = Protocol.Ping;
            BinaryPrimitives.WriteUInt16LittleEndian(ping.AsSpan(1), 8);
            long stamp = DateTime.UtcNow.Ticks;
            BinaryPrimitives.WriteInt64LittleEndian(ping.AsSpan(3), stamp);
            await stream.WriteAsync(ping, cts.Token);

            // The relay also queues Name/ReleaseVersion/CombatRole for a fresh
            // client; skip anything that is not our Pong.
            while (true)
            {
                var (t2, p2) = await ReadPacketAsync(stream, cts.Token);
                if (t2 != Protocol.Pong) continue;
                if (p2.Length != 8 || BinaryPrimitives.ReadInt64LittleEndian(p2) != stamp)
                {
                    Console.WriteLine("RELAY-SMOKE FAIL Pong payload does not echo the Ping stamp");
                    return 1;
                }
                break;
            }

            Console.WriteLine($"RELAY-SMOKE ok id={id} protocol=v{Protocol.Version} release={ReleaseVersionInfo.Current} rtt_ms={sw.Elapsed.TotalMilliseconds:F0}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"RELAY-SMOKE FAIL {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static async Task<(byte Type, byte[] Payload)> ReadPacketAsync(NetworkStream s, CancellationToken ct)
    {
        var header = new byte[3];
        await ReadExactAsync(s, header, ct);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
        var payload = new byte[len];
        await ReadExactAsync(s, payload, ct);
        return (header[0], payload);
    }

    private static async Task ReadExactAsync(NetworkStream s, byte[] buf, CancellationToken ct)
    {
        int off = 0;
        while (off < buf.Length)
        {
            int n = await s.ReadAsync(buf.AsMemory(off), ct);
            if (n == 0) throw new EndOfStreamException("relay closed the connection");
            off += n;
        }
    }
}
