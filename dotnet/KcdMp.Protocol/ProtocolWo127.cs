using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;

namespace KcdMp.Wire;

// ---------------------------------------------------------------------------
// WO-127 -- Steam as a connection path, plain connection errors, the
// connection test. Still protocol v9: no new message type, no new length.
//
// * Position flag 0x40 HOST CLAIM: the sender runs the session (the launcher
//   started the relay for it, or it runs a shared world from inside a world).
//   The relay reads it for the authority decision and CLEARS it before the
//   Ghost fan-out, so receivers see exactly what they saw before.
// * Connection test: a Handshake whose release field is
//   ConnectionTestRelease. Every relay since WO-110 R9 answers a release it
//   does not run with 0x3D [its release] and closes, so the test never becomes
//   a session (no id, no Name broadcast, no ghost). A WO-127 relay appends
//   "\0ready=<n>;host=<0|1>" to that one reply and logs it as a test, not a
//   refusal. Only a test ever sends that release, so no real agent sees the
//   suffix.
// ---------------------------------------------------------------------------

public static partial class Protocol
{
    /// <summary>WO-127: Position flags bit -- the sender claims the session host (see file header).</summary>
    public const byte PositionFlagHostClaim = 0x40;

    /// <summary>WO-127: the release string a connection test sends (never a real release: it doesn't parse).</summary>
    public const string ConnectionTestRelease = "?connection-test";
}

/// <summary>WO-127: the relay's answer to a connection test.</summary>
public readonly record struct ConnectionTestReply(string Release, int Ready, bool HostConnected, bool HasDetail)
{
    public static byte[] BuildPayload(string release, int ready, bool hostConnected) =>
        Encoding.UTF8.GetBytes($"{release}\0ready={ready};host={(hostConnected ? 1 : 0)}");

    /// <summary>Decodes a 0x3D payload (a pre-WO-127 relay sends the release alone).</summary>
    public static ConnectionTestReply Decode(ReadOnlySpan<byte> payload)
    {
        string s = Encoding.UTF8.GetString(payload);
        int nul = s.IndexOf('\0');
        if (nul < 0) return new ConnectionTestReply(s, -1, false, false);
        int ready = -1; bool host = false;
        foreach (var part in s[(nul + 1)..].Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = part.Split('=', 2);
            if (kv.Length != 2) continue;
            if (kv[0] == "ready" && int.TryParse(kv[1], out int r)) ready = r;
            if (kv[0] == "host") host = kv[1] == "1";
        }
        return new ConnectionTestReply(s[..nul], ready, host, true);
    }
}

/// <summary>
/// WO-127: every way a connection can fail, on either path. Each maps to one
/// plain sentence and one next step (<see cref="PlainConnectionError"/>); the
/// raw detail goes to the log only.
/// </summary>
public enum ConnectionTrouble
{
    None,
    Refused,           // something answered at the address, nothing listens on the port
    TimedOut,          // no answer at all
    WrongAddress,      // the name doesn't resolve / the address is malformed
    HostNotRunning,    // the relay answers, the host's own game isn't connected
    VersionMismatch,   // release versions differ (the 0.28.3 mixed-build check)
    ProtocolMismatch,  // wire versions differ (an older/newer build family)
    AppIdMismatch,     // Steam app ids differ
    SteamNotRunning,
    SteamNotLoggedIn,
    SteamUnavailable,  // no Steam DLL, or Steam refused this app id
    SteamNoRoute,      // no P2P route within the time limit
    BadCode,           // the Steam code doesn't decode
    OwnCode,           // the Steam code is this account's own
    ServerFull,
    Lost,              // was connected, the connection dropped
    Unknown,
}

public readonly record struct PlainConnectionError(ConnectionTrouble Kind, string Sentence, string NextStep)
{
    public string Text => $"{Sentence} {NextStep}";

    public static readonly TimeSpan SteamRouteTimeout = TimeSpan.FromSeconds(20);

    /// <summary>The one sentence and next step for <paramref name="kind"/>. <paramref name="theirs"/>/<paramref name="mine"/> fill version and app-id texts.</summary>
    public static PlainConnectionError For(ConnectionTrouble kind, string? theirs = null, string? mine = null) => kind switch
    {
        ConnectionTrouble.None => new(kind, "Connected.", ""),
        ConnectionTrouble.Refused => new(kind,
            "The host's computer answered, but nothing is listening for the game on that port.",
            "Ask the host to click Host in their launcher, and check the port number."),
        ConnectionTrouble.TimedOut => new(kind,
            "The host didn't answer in time.",
            "Check the address. If the host is on another network, their router must forward the port, or connect through Steam instead."),
        ConnectionTrouble.WrongAddress => new(kind,
            "That address doesn't exist.",
            "Check how the host's address is spelled."),
        ConnectionTrouble.HostNotRunning => new(kind,
            "The host's multiplayer is running, but their game isn't connected yet.",
            "Ask the host to load their save and click Connect, then try again."),
        ConnectionTrouble.VersionMismatch => new(kind,
            $"The host runs version {theirs ?? "?"} and you run {mine ?? "?"}.",
            "Both players need the same version: whoever is older installs the newer one."),
        ConnectionTrouble.ProtocolMismatch => new(kind,
            $"The host runs a different version of the mod ({theirs ?? "?"}; yours is {mine ?? "?"}).",
            "Both players need the same version: whoever is older installs the newer one."),
        ConnectionTrouble.AppIdMismatch => new(kind,
            $"The host uses Steam app {theirs ?? "?"}, and your launcher is set to {mine ?? "?"}.",
            "Pick the same Steam app on both computers (Settings, Advanced)."),
        ConnectionTrouble.SteamNotRunning => new(kind,
            "Steam isn't running on this computer.",
            "Start Steam, log in, and try again, or use the host's address."),
        ConnectionTrouble.SteamNotLoggedIn => new(kind,
            "Steam is running but isn't logged in (or is in offline mode).",
            "Log in to Steam online and try again, or use the host's address."),
        ConnectionTrouble.SteamUnavailable => new(kind,
            "Steam couldn't be used for multiplayer on this computer.",
            "Choose KCD2 Modding Tools as the Steam app (Settings, Advanced), or use the host's address."),
        ConnectionTrouble.SteamNoRoute => new(kind,
            $"Steam couldn't reach the host within {(int)SteamRouteTimeout.TotalSeconds} seconds.",
            "Check the code and that the host's launcher says \"Steam: ready\", or use the host's address."),
        ConnectionTrouble.BadCode => new(kind,
            "That code isn't right. It looks like ABCD-EFG.",
            "Ask the host to read it out again."),
        ConnectionTrouble.OwnCode => new(kind,
            "That's this computer's own Steam code.",
            "Type the host's code, not yours."),
        ConnectionTrouble.ServerFull => new(kind,
            "The host's game is full.",
            "Wait until someone leaves, then try again."),
        ConnectionTrouble.Lost => new(kind,
            "The connection to the host was lost.",
            "It reconnects by itself; if it doesn't, check the host is still playing."),
        _ => new(ConnectionTrouble.Unknown,
            "Couldn't connect to the host.",
            "Try again. If it keeps failing, send the logs with Report a bug."),
    };

    /// <summary>The short reason inside "Couldn't connect through Steam: ...".</summary>
    public static string SteamReason(ConnectionTrouble kind, string? theirs = null, string? mine = null) => kind switch
    {
        ConnectionTrouble.SteamNotRunning => "Steam isn't running",
        ConnectionTrouble.SteamNotLoggedIn => "Steam isn't logged in",
        ConnectionTrouble.SteamUnavailable => "Steam couldn't be started for the game",
        ConnectionTrouble.SteamNoRoute => $"no route to the host within {(int)SteamRouteTimeout.TotalSeconds} seconds",
        ConnectionTrouble.BadCode => "that code isn't right",
        ConnectionTrouble.OwnCode => "that's your own code, not the host's",
        ConnectionTrouble.AppIdMismatch => $"the host uses Steam app {theirs ?? "?"}, you use {mine ?? "?"}",
        ConnectionTrouble.HostNotRunning => "the host's game isn't connected yet",
        ConnectionTrouble.VersionMismatch => $"the host runs {theirs ?? "?"}, you run {mine ?? "?"}",
        ConnectionTrouble.ProtocolMismatch => "the host runs a different version of the mod",
        ConnectionTrouble.ServerFull => "the host's game is full",
        ConnectionTrouble.Lost => "the connection dropped",
        _ => "something went wrong",
    };

    /// <summary>The WO-127 fallback message: "Couldn't connect through Steam: &lt;reason&gt;. Try the host's address instead."</summary>
    public static string SteamFallback(ConnectionTrouble kind, string? theirs = null, string? mine = null) =>
        $"Couldn't connect through Steam: {SteamReason(kind, theirs, mine)}. Try the host's address instead.";

    /// <summary>Which trouble a failed direct connect/handshake was. The exception text itself is for the log.</summary>
    public static ConnectionTrouble Classify(Exception ex)
    {
        for (var e = ex; e is not null; e = e.InnerException)
        {
            switch (e)
            {
                case SocketException se:
                    return se.SocketErrorCode switch
                    {
                        SocketError.ConnectionRefused => ConnectionTrouble.Refused,
                        SocketError.TimedOut or SocketError.HostUnreachable or SocketError.NetworkUnreachable
                            or SocketError.NetworkDown or SocketError.HostDown => ConnectionTrouble.TimedOut,
                        SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain
                            or SocketError.AddressNotAvailable or SocketError.AddressFamilyNotSupported => ConnectionTrouble.WrongAddress,
                        SocketError.ConnectionReset or SocketError.ConnectionAborted or SocketError.Shutdown => ConnectionTrouble.Lost,
                        _ => ConnectionTrouble.Unknown,
                    };
                case TimeoutException:
                case OperationCanceledException:
                    return ConnectionTrouble.TimedOut;
                case ArgumentException:
                case FormatException:
                    return ConnectionTrouble.WrongAddress;
                case EndOfStreamException:
                    return ConnectionTrouble.Lost;
            }
        }
        return ConnectionTrouble.Unknown;
    }
}
