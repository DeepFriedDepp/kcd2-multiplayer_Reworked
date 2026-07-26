using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using KcdMp.Server.Features.Tcp;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// Handles one connected client agent.
///
/// See <see cref="Protocol"/> for the framing and packet layouts.
/// </summary>
public class ClientSession
{
    private static int _idCounter;

    private readonly ILogger _logger;
    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly TcpBroadcastService _broadcastService;
    private readonly Channel<byte[]> _writeQueue = Channel.CreateUnbounded<byte[]>();

    public byte Id { get; } = (byte)Interlocked.Increment(ref _idCounter);
    public string? Name { get; private set; }
    public bool IsReady => Name is not null;

    public ClientSession(ILogger logger, TcpClient tcp, TcpBroadcastService broadcastService)
    {
        _logger = logger;
        _tcp = tcp;
        _stream = tcp.GetStream();
        _broadcastService = broadcastService;
    }

    public async Task RunAsync()
    {
        var writeTask = WriteLoopAsync();
        try
        {
            // --- Handshake:  [version:1][nameLen:1][name:UTF-8] ---
            var header = new byte[3];
            await ReadExactAsync(header);

            if (header[0] != Protocol.Handshake)
            {
                _logger.Warning("[!] Client sent bad handshake type 0x{Type:X2}, dropping.", header[0]);
                return;
            }

            int handshakeLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
            if (handshakeLen < 2)
            {
                // Pre-versioning clients sent [nameLen:1][name] with no version
                // byte. Their payload is the bare name, so there is nothing to
                // negotiate — reject rather than misread the first byte as a version.
                _logger.Warning("[!] Handshake payload too short ({Len} bytes) — client predates version negotiation. Rejecting.", handshakeLen);
                EnqueueRaw(BuildPacket(Protocol.VersionMismatch, [Protocol.Version]));
                return;
            }

            var handshakePayload = new byte[handshakeLen];
            await ReadExactAsync(handshakePayload);

            byte clientVersion = handshakePayload[0];
            if (clientVersion != Protocol.Version)
            {
                _logger.Warning("[!] Rejecting client with protocol v{ClientVersion}; this relay speaks v{ServerVersion}.",
                    clientVersion, Protocol.Version);
                EnqueueRaw(BuildPacket(Protocol.VersionMismatch, [Protocol.Version]));
                return;
            }

            int nameLen = handshakePayload[1]; // single byte, max 255
            if (nameLen > handshakeLen - 2)
            {
                _logger.Warning("[!] Handshake declares a {NameLen}-byte name but carries {Available}. Dropping.",
                    nameLen, handshakeLen - 2);
                return;
            }
            Name = Encoding.UTF8.GetString(handshakePayload, 2, nameLen);

            _logger.Information("[+] '{Name}' connected (id={Id}, protocol v{Version}) from {ClientRemoteEndPoint}.",
                Name, Id, clientVersion, _tcp.Client.RemoteEndPoint);

            // Send Ack with assigned ID
            EnqueueRaw(BuildPacket(Protocol.Ack, [Id]));

            // Broadcast this client's name to all others; send existing names to this client
            _broadcastService.BroadcastName(this);
            _broadcastService.SendAllNamesTo(this);

            // --- Position receive loop ---
            // Payload length is now exact: the version byte replaced the old
            // 16-vs-17-byte sniffing, and a v1 peer always sends 17.
            var posPayload = new byte[Protocol.PositionPayloadLen];
            while (true)
            {
                await ReadExactAsync(header);
                int type = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));

                if (type == Protocol.Ping && payloadLen == 8)
                {
                    // Ping → echo back as Pong with same 8-byte timestamp
                    var tsBytes = new byte[8];
                    await ReadExactAsync(tsBytes);
                    EnqueueRaw(BuildPacket(Protocol.Pong, tsBytes));
                    continue;
                }

                if (type == Protocol.VoiceUp && payloadLen == Protocol.VoiceFrameLen)
                {
                    // Voice frame → relay to all other ready clients
                    var pcm = new byte[Protocol.VoiceFrameLen];
                    await ReadExactAsync(pcm);
                    _broadcastService.BroadcastVoice(this, pcm);
                    continue;
                }

                if (type != Protocol.Position || payloadLen != Protocol.PositionPayloadLen)
                {
                    // Skip unknown/malformed packet
                    if (payloadLen > 0)
                    {
                        var skip = new byte[payloadLen];
                        await ReadExactAsync(skip);
                    }
                    continue;
                }

                await ReadExactAsync(posPayload, Protocol.PositionPayloadLen);

                float x    = ReadFloat(posPayload, 0);
                float y    = ReadFloat(posPayload, 4);
                float z    = ReadFloat(posPayload, 8);
                float rotZ = ReadFloat(posPayload, 12);
                byte  flags = posPayload[16];

                _broadcastService.Broadcast(this, x, y, z, rotZ, flags);
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException)
        {
            // Normal disconnect
        }
        finally
        {
            _writeQueue.Writer.Complete();
            await writeTask;
            _tcp.Dispose();
        }
    }

    /// <summary>Thread-safe: enqueue a Ghost packet to be sent to this client.</summary>
    public void EnqueueGhost(byte ghostId, float x, float y, float z, float rotZ, byte flags)
    {
        var payload = new byte[18];
        payload[0] = ghostId;
        WriteFloat(payload, 1, x);
        WriteFloat(payload, 5, y);
        WriteFloat(payload, 9, z);
        WriteFloat(payload, 13, rotZ);
        payload[17] = flags;
        EnqueueRaw(BuildPacket(Protocol.Ghost, payload));
    }

    /// <summary>Thread-safe: enqueue a Disconnect packet (0x06) to be sent to this client.</summary>
    public void EnqueueDisconnect(byte ghostId) =>
        EnqueueRaw(BuildPacket(Protocol.Disconnect, [ghostId]));

    /// <summary>Thread-safe: enqueue a Voice packet (0x08) to be sent to this client.</summary>
    public void EnqueueVoice(byte sourceId, byte[] pcm)
    {
        var payload = new byte[1 + pcm.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(pcm, 0, payload, 1, pcm.Length);
        EnqueueRaw(BuildPacket(Protocol.VoiceDown, payload));
    }

    /// <summary>Thread-safe: enqueue a Name packet (0x03) to be sent to this client.</summary>
    public void EnqueueName(byte ghostId, string name)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var payload = new byte[1 + nameBytes.Length];
        payload[0] = ghostId;
        nameBytes.CopyTo(payload, 1);
        EnqueueRaw(BuildPacket(Protocol.Name, payload));
    }

    private void EnqueueRaw(byte[] packet) =>
        _writeQueue.Writer.TryWrite(packet);

    private async Task WriteLoopAsync()
    {
        await foreach (var packet in _writeQueue.Reader.ReadAllAsync())
        {
            try { await _stream.WriteAsync(packet); }
            catch { break; }
        }
    }

    // ---- Helpers ----

    private static byte[] BuildPacket(byte type, byte[] payload)
    {
        var packet = new byte[3 + payload.Length];
        packet[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payload.Length);
        payload.CopyTo(packet, 3);
        return packet;
    }

    private static float ReadFloat(byte[] buf, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(offset)));

    private static void WriteFloat(byte[] buf, int offset, float value) =>
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(offset), BitConverter.SingleToInt32Bits(value));

    private Task ReadExactAsync(byte[] buffer) => ReadExactAsync(buffer, buffer.Length);

    private async Task ReadExactAsync(byte[] buffer, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int n = await _stream.ReadAsync(buffer, offset, count - offset);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }
}
