using System.Text.Json.Serialization;
using System.Threading.Tasks;
using KCDMP_launcher.Services;

namespace KCDMP_launcher.Models
{
    public class ServerInfo
    {
        public string? Token { get; set; } = null; // Unique identifier for the server, will be used for caching mods profiles.
        public string Name { get; set; } = "";
        public string Ip { get; set; } = "";
        public int Port { get; set; }

        public string MapName { get; set; } = "";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
        public int Ping { get; set; } = -1;

        public bool IsOnline { get; set; } = false;
    }

    // DTO for one entry of GET /servers/servers_list.
    //
    // The field names are Server.to_dict() in the master server's models.py,
    // not a guess: it emits "ip_address" and "map_name", so the "ip" this used
    // to bind never matched and every server arrived with a blank address.
    public class MasterServerEntry
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = "";

        [JsonPropertyName("ip_address")]
        public string Ip { get; set; } = "";

        [JsonPropertyName("port")]
        public int Port { get; set; }

        [JsonPropertyName("map_name")]
        public string MapName { get; set; } = "";

        [JsonPropertyName("tags")]
        public List<string> Tags { get; set; } = new();
    }

    public class DedicatedServerInfoData
    {
        public string MapName { get; set; } = "Unknown";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
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

        // The master server's listing endpoint. The Flask app registers the
        // blueprint at url_prefix="/servers" with a "/servers_list" route, so
        // the "/api/servers" this used to default to was never a real URL.
        // !IMPORTANT change the host in release
        public string MasterServerUrl { get; set; } = "http://localhost:5000/servers/servers_list";

        // The relay's HTTP listener for /api/information, which is a different
        // port from the TCP port peers connect on. The master server records
        // only the TCP port, so the browser assumes this one is the same for
        // every relay — true for a default build (appsettings.json binds 5273),
        // and an assumption rather than something the master tells us.
        public int ServerInfoPort { get; set; } = 5273;

        // Where the locally-running agent's dice IPC listener binds (see
        // dotnet/KcdMp.Client/DiceIpcServer.cs). Local-machine only, unlike
        // ServerInfoPort -- there is no per-relay value to guess here.
        public int DiceIpcPort { get; set; } = 5901;

        public string Language { get; set; } = "en";
    }
}