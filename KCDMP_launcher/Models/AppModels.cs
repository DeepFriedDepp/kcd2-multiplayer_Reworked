using System.Threading.Tasks;
using KCDMP_launcher.Services;

namespace KCDMP_launcher.Models
{
    public class ServerInfo
    {
        public string? Token { get; set; } = null; // The master server's listing id (WO-35), or null for a manually-added server.
        public string Name { get; set; } = "";
        public string Ip { get; set; } = "";
        public int Port { get; set; }

        // The relay's own /api/information port, as the master server
        // published it (WO-35). 0 for a manually-added server, which falls
        // back to AppSettings.ServerInfoPort instead -- there is nothing to
        // publish it for one of those.
        public int InfoPort { get; set; } = 0;

        public string MapName { get; set; } = "";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
        public int Ping { get; set; } = -1;

        public bool IsOnline { get; set; } = false;

        // WO-127: a host reached through Steam (its join code) instead of Ip:Port.
        // Never stored in custom_servers.json: built on the fly by the Steam join window.
        [System.Text.Json.Serialization.JsonIgnore]
        public string? SteamCode { get; set; }
    }

    // WO-127: mirrors AgentConnectionStatus.Json (dotnet/KcdMp.Client/ConnectionTools.cs).
    public class ConnectionStatusData
    {
        public string State { get; set; } = "";
        public string Via { get; set; } = "direct";
        public string Kind { get; set; } = "None";
        public string Message { get; set; } = "";
        public string Next { get; set; } = "";
        public bool Fatal { get; set; }
        public int Failures { get; set; }
    }

    // WO-127: the host's relay, GET api/local/status (loopback only).
    public class RelayLocalStatusData
    {
        public string Release { get; set; } = "";
        public RelaySteamData Steam { get; set; } = new();
        public int Players { get; set; }
        public bool HostConnected { get; set; }
        public string? RefusedRelease { get; set; }
        public int RefusedSecondsAgo { get; set; } = -1;
    }

    public class RelaySteamData
    {
        public string State { get; set; } = "off";
        public string Message { get; set; } = "";
        public uint AppId { get; set; }
        public string AppName { get; set; } = "";
        public string? Code { get; set; }
        public int Peers { get; set; }
    }

    // WO-127: KcdMpClient.exe --test-connection (ConnectionTest.Result.ToJson).
    public class TestConnectionData
    {
        public bool Reachable { get; set; }
        public string Via { get; set; } = "";
        public int RttMs { get; set; } = -1;
        public int ConnectMs { get; set; } = -1;
        public string? HostRelease { get; set; }
        public string MyRelease { get; set; } = "";
        public bool VersionMatch { get; set; }
        public bool? HostConnected { get; set; }
        public int Players { get; set; } = -1;
        public string Kind { get; set; } = "";
        public string Message { get; set; } = "";
        public string Next { get; set; } = "";
        public int SteamPingMs { get; set; } = -1;
        public bool? Relayed { get; set; }
        public string Detail { get; set; } = "";
    }

    // WO-127: KcdMpClient.exe --steam-friends (SteamFriendsList). Names are shown, never logged.
    public class SteamFriendsData
    {
        public string State { get; set; } = "";
        public string Message { get; set; } = "";
        public string Next { get; set; } = "";
        public string App { get; set; } = "";
        public List<SteamFriendData> Friends { get; set; } = new();
    }

    public class SteamFriendData
    {
        public string Name { get; set; } = "";
        public string Code { get; set; } = "";
        public string Release { get; set; } = "";
    }

    public class DedicatedServerInfoData
    {
        public string MapName { get; set; } = "Unknown";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
    }

    // Mirrors VersionStatusDto/PeerVersionDto in dotnet/KcdMp.Client/VersionIpcServer.cs (WO-19).
    public class VersionStatusData
    {
        public string MyReleaseVersion { get; set; } = "";
        public List<PeerVersionData> Peers { get; set; } = new();
    }

    // Mirrors GameBridge.JoinStatusJson (dotnet/KcdMp.Client/GameBridge.Wo123.cs, WO-123):
    // the joiner's world transfer, for "Receiving the world... 62%".
    public class JoinStatusData
    {
        public string State { get; set; } = "idle";
        public double Percent { get; set; }
        public long Bytes { get; set; }
        public long Total { get; set; }
        public double EtaS { get; set; }
        public string Message { get; set; } = "";
    }

    public class PeerVersionData
    {
        public byte GhostId { get; set; }
        public string ReleaseVersion { get; set; } = "";
    }

    public class AppSettings
    {
        // KCD2 must be started through the Modding Tools build: the debug REST
        // API on port 1403 that KcdMpClient talks to exists only there, and the
        // retail executable is monolithic and exports nothing to hook. Pointing
        // this at the base game produces a running game the agent cannot reach.
        public string GamePath { get; set; } = "";

        public string DllPath { get; set; } = "KCDMP.dll";

        // The agent. Launching the game and injecting the DLL is only half the
        // system — without this process nothing talks to the relay at all.
        public string AgentPath { get; set; } = "KcdMpClient.exe";

        // How long to let the game get far enough along to be injected. The
        // injector needs the target's modules loaded, not just a live pid.
        public int InjectDelaySeconds { get; set; } = 20;

        // Where the master server IS, not an endpoint on it (WO-35: the C#
        // master server replaces the old Flask service) -- the launcher
        // appends MasterApi.ListPath itself, tolerating a URL that already
        // names it. 127.0.0.1 rather than "localhost": resolving "localhost"
        // tried this machine's IPv6 loopback first, which sat in SYN_SENT
        // rather than refusing outright, and made the very first fetch of
        // every launch look like the master could not be reached even once
        // it was actually up. Confirmed live -- see docs/WO-35-findings.md.
        // !IMPORTANT change the host in release
        public string MasterServerUrl { get; set; } = "http://127.0.0.1:5100";

        // The relay's HTTP listener for /api/information, which is a different
        // port from the TCP port peers connect on. The master server records
        // only the TCP port, so the browser assumes this one is the same for
        // every relay — true for a default build (appsettings.json binds 5273),
        // and an assumption rather than something the master tells us.
        public int ServerInfoPort { get; set; } = 5273;

        // Where the locally-running agent's dice IPC listener binds (see
        // dotnet/KcdMp.Client/DiceIpcServer.cs). Local-machine only, unlike
        // ServerInfoPort -- there is no per-relay value to guess here.
        //
        // WO-6 retired the launcher's dice window: dice is played in game now,
        // and nothing in this process reads this any more. Kept as a settings
        // field so an existing settings.json still round-trips unchanged, and
        // because the agent-side endpoint itself is still there as a debug
        // mirror -- see docs/WO-6-progress.md for that decision.
        public int DiceIpcPort { get; set; } = 5901;

        // Where the locally-running agent's release-version IPC listener
        // binds (see dotnet/KcdMp.Client/VersionIpcServer.cs, WO-19). Local
        // machine only, matching KcdMp.Client's own VersionIpcPort default --
        // this one is live: it is how the version-mismatch notification
        // learns the connected peer's release version at all.
        public int VersionIpcPort { get; set; } = 5902;

        public string Language { get; set; } = "en";

        // The relay executable, started locally when the player clicks "Host".
        // Same resolution rule as AgentPath/DllPath: relative means "next to
        // the launcher", which is where a packaged release puts it.
        public string RelayPath { get; set; } = "KcdMpServer.exe";

        // The master server executable (WO-35), auto-started alongside the
        // launcher itself -- not on Host, unlike RelayPath -- whenever
        // MasterServerUrl names a loopback address, since a default install
        // otherwise has nothing answering it there. See Home.razor.cs's
        // EnsureLocalMasterServerAsync. Resolved the same way as
        // RelayPath/AgentPath/DllPath (relative to the launcher), but in its
        // own subfolder rather than flat-merged with everything else:
        // confirmed live, sharing a folder let another project's publish
        // step silently overwrite one of its dependency DLLs with an
        // incompatible version, crashing it on next launch. See
        // tools/Publish-Release.ps1, which places it here.
        public string MasterServerPath { get; set; } = "MasterServer\\KcdMpMasterServer.exe";

        // TCP port the locally-hosted relay listens on, and what a joining
        // friend needs in their own address bar. Matches KcdMp.Server's own
        // default (Tcp:Port in appsettings.json) so the common case needs no
        // coordination.
        public int HostPort { get; set; } = 7778;

        // Mirrors KcdMp.Client's --voice/--no-voice. Exposed as a normal
        // setting rather than something only reachable via the command line.
        public bool VoiceChatEnabled { get; set; } = true;

        // WO-127: "Also allow Steam" in the Host window (the relay also listens on Steam P2P).
        public bool HostAllowSteam { get; set; } = true;

        // WO-127 (Settings, advanced): the Steam app id both players use. 2429020 is the
        // game's own (Modding Tools); 480 and 1771300 are selectable. The maintainer decides
        // the final default after the WO-128 test.
        public uint SteamAppId { get; set; } = 2429020;

        // WO-127: the last Steam code typed in the Join window (this machine only).
        public string LastSteamCode { get; set; } = "";
    }
}