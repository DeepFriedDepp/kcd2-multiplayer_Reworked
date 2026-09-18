using DiscordRPC;
using DiscordRPC.Logging;

namespace KcdMp.Client;

/// <summary>
/// WO-50: Discord Rich Presence, owned by the agent rather than the launcher
/// (see docs/WO-50-findings.md) — this is the process that actually persists
/// for a play session; the launcher tells the player it's safe to close once
/// connected.
///
/// Follows the same discipline as every other optional agent feature: Discord
/// not running, no internet, or a dead IPC pipe all degrade to "no presence
/// shown", never to an agent crash. DiscordRpcClient runs its own background
/// connection thread and retries on its own — SetPresence before it connects
/// just queues the update, so callers don't need to check readiness.
/// </summary>
public sealed class DiscordPresence : IDisposable
{
    private readonly DiscordRpcClient? _client;
    private readonly string _largeImageKey;
    private readonly Timestamps _startTimestamp = Timestamps.Now;

    private bool _isHosting;
    private int _peerCount;

    public DiscordPresence(ClientConfig config)
    {
        _isHosting = config.IsHosting;
        _largeImageKey = config.DiscordLargeImageKey;

        if (!config.DiscordPresenceEnabled || string.IsNullOrWhiteSpace(config.DiscordClientId))
        {
            Console.WriteLine("[discord] presence disabled (config)");
            return;
        }

        try
        {
            _client = new DiscordRpcClient(config.DiscordClientId)
            {
                Logger = new ConsoleLogger(LogLevel.Warning)
            };
            _client.OnConnectionFailed += (_, _) =>
                Console.WriteLine("[discord] Discord is not running or the IPC pipe is unavailable — presence stays off for this session");
            _client.OnError += (_, e) =>
                Console.WriteLine($"[discord] error: {e.Message}");
            _client.OnReady += (_, e) =>
                Console.WriteLine($"[discord] ready, connected as {e.User?.Username}");
            _client.OnPresenceUpdate += (_, e) =>
                Console.WriteLine($"[discord] presence ack: details='{e.Presence?.Details}' state='{e.Presence?.State}'");
            bool initOk = _client.Initialize();
            Console.WriteLine($"[discord] Initialize() returned {initOk}, IsInitialized={_client.IsInitialized}");

            PushState("Connecting...");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[discord] init failed, continuing without presence: {ex.Message}");
            _client = null;
        }
    }

    /// <summary>Call once the relay connection is actually established.</summary>
    public void SetConnected(bool isHosting)
    {
        _isHosting = isHosting;
        PushState(null);
    }

    /// <summary>
    /// Cheap to call often (e.g. once per incoming Ghost position packet) —
    /// it no-ops unless the count actually changed, so it never spams
    /// Discord's IPC pipe with an update per tick.
    /// </summary>
    public void SetPeerCount(int otherPeers)
    {
        if (otherPeers == _peerCount) return;
        _peerCount = otherPeers;
        PushState(null);
    }

    /// <summary>Relay connection dropped and RunLoopAsync is about to retry.</summary>
    public void ResetForReconnect()
    {
        _peerCount = 0;
        PushState("Connecting...");
    }

    private void PushState(string? detailsOverride)
    {
        if (_client is null) return;

        string details = detailsOverride ?? (_isHosting ? "Hosting" : "Playing");
        string state = $"v{ReleaseVersionInfo.Current}" +
            (_peerCount > 0 ? $" · {_peerCount + 1} players" : " · solo");

        Console.WriteLine($"[discord] SetPresence details='{details}' state='{state}' key='{_largeImageKey}' IsInitialized={_client.IsInitialized}");

        try
        {
            _client.SetPresence(new RichPresence
            {
                Details = details,
                State = state,
                Assets = new Assets
                {
                    LargeImageKey = _largeImageKey,
                    LargeImageText = "Kingdom Come: Deliverance II Multiplayer",
                    // WO-50 set this to "" believing it stopped DiscordRPC
                    // 1.6.1's Assets.Merge NRE. WO-101 field logs (every
                    // bundle since) show it does not: the null is on the
                    // OTHER side. Discord's ack echoes the presence back
                    // without a small_image field, the library merges that
                    // reply into ours, and other._smallimagekey.StartsWith()
                    // throws on the reply's null. The library catches it on
                    // its own read thread and logs "Unhandled Exception while
                    // processing event"; the presence itself was already sent
                    // and shows, later SetPresence calls work, and the only
                    // loss is the OnPresenceUpdate callback (our
                    // "[discord] presence ack" line never prints). Benign.
                    // Upstream has the null guard on master but the only
                    // newer NuGet package (1.143.0) is deprecated/unlisted
                    // "critical bugs", so there is nothing to upgrade to.
                    // Kept at "" -- harmless -- rather than a second real
                    // asset key, which would put a badge on the art.
                    SmallImageKey = ""
                },
                Timestamps = _startTimestamp
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[discord] SetPresence failed: {ex.Message}");
        }
    }

    public void Dispose()
    {
        try { _client?.Dispose(); }
        catch { /* best-effort on shutdown, matches the rest of Program.cs */ }
    }
}
