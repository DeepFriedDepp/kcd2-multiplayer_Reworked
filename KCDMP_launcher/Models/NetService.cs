using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using KCDMP_launcher.Components.Shared;
using KCDMP_launcher.Models;
using KcdMp.Wire;
using Microsoft.AspNetCore.Components;

namespace KCDMP_launcher.Services
{
    public class NetService
    {
        private readonly UiService _uiService;

        private readonly HttpClient _httpClient;

        private string Prefix { get; } = "[NetService]";

        public NetService(UiService _uiService)
        {
            this._uiService = _uiService;
            this._httpClient = new HttpClient();
            this._httpClient.Timeout = TimeSpan.FromSeconds(5);
        }

        public int SendPingServer(string ip)
        {
            Log.Information($"{Prefix} Performing ping for IP: {ip}");
            int pingTime = -1;

            if (!ValidateServerAddress(ip, showError: false))
            {
                return -1;
            }

            try
            {
                using (Ping ping = new Ping())
                {
                    PingReply reply = ping.Send(ip, 1000);
                    if (reply.Status == IPStatus.Success)
                    {
                        pingTime = (int)reply.RoundtripTime;
                    }
                    else
                    {
                        //Ping is performed for every server on the list so I assume no errors should be shown to the user,
                        //just return -1 if ping fails for any reason
                        //serverList component will handle the display of ping times
                        //show "N/A" or similar for servers that couldn't be reached (ping < 0)

                        Log.Error(ip, $"Ping failed with status: {reply.Status}");
                    }
                }
            }
            catch (Exception ex)
            {
                //Same as above
                Log.Error(ex, "Error pinging server " + ip);

            }
            return pingTime;
        }

        public async Task<int> SendPingServerAsync(string ip)
        {
            Log.Information($"Performing ping async for IP: {ip}");
            int pingTime = -1;

            if (!ValidateServerAddress(ip, showError: false))
            {
                return -1;
            }

            try
            {
                using (Ping ping = new Ping())
                {
                    PingReply reply = await ping.SendPingAsync(ip, 1000);
                    if (reply.Status == IPStatus.Success)
                    {
                        return (int)reply.RoundtripTime;
                    }

                    return -1;
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, $"An error occurred while pinging {ip}");
            }
            return pingTime;
        }

        /// <summary>
        /// The master server is optional -- a launcher with a host's address
        /// joins without it -- so nothing here ever surfaces a popup. A
        /// missing or unreachable master used to raise a blocking "Could not
        /// connect to Master Server!" error dialog on every single launch for
        /// as long as nothing answered it, which is confusing for exactly the
        /// non-technical users this feature is supposed to help (WO-35). Any
        /// failure here is logged to app.log only; the caller just gets an
        /// empty list, indistinguishable from "the master is fine and nobody
        /// is hosting" -- which is also why the status bar's Master:
        /// Online/Offline (Globals.IsMasterOnline, set from
        /// IsMasterServerOnlineAsync) exists as the one place this is still
        /// visible, passively rather than as an interruption.
        /// </summary>
        public async Task<List<ServerInfo>> GetServersFromMasterAsync(string masterUrl)
        {
            var resultList = new List<ServerInfo>();

            if (!TryBuildMasterUri(masterUrl, MasterApi.ListPath, out var uri, out var uriError))
            {
                Log.Warning("Master Server URL could not be used: {Error}", uriError);
                return resultList;
            }

            try
            {
                var response = await _httpClient.GetFromJsonAsync<ServerListResponse>(uri, MasterApi.Json);

                if (response is null)
                {
                    return resultList;
                }

                if (response.ApiVersion != MasterApi.Version)
                {
                    Log.Warning(
                        "The master server speaks master API v{TheirVersion}; this launcher speaks v{OurVersion}. Update whichever is older.",
                        response.ApiVersion, MasterApi.Version);
                    return resultList;
                }

                foreach (var entry in response.Servers)
                {
                    resultList.Add(new ServerInfo
                    {
                        // The master's listing id, kept for future use (mods
                        // profile caching) -- see AppModels.ServerInfo.Token.
                        Token = entry.Id,
                        Name = entry.Name,
                        Ip = entry.Address,
                        Port = entry.Port,
                        InfoPort = entry.InfoPort,
                        // The master already knows the map and player counts
                        // from the relay's own push, so show them rather than
                        // a placeholder. The live poll below refreshes them.
                        MapName = entry.MapName,
                        Players = entry.Players,
                        MaxPlayers = entry.MaxPlayers,
                        Ping = -1,
                    });
                }
            }
            catch (HttpRequestException ex)
            {
                Log.Debug(ex, "Could not connect to the master server (non-fatal, the feature is optional): {Message}", ex.Message);
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Error fetching the server list from the master (non-fatal): {Message}", ex.Message);
            }

            return resultList;
        }

        /// <summary>
        /// The operator configures where the master server IS
        /// ("http://master.example.com:5100"), not the path within it -- the
        /// path belongs to the API (WO-35, <see cref="MasterApi"/>), same rule
        /// the relay's own MasterAnnounceService follows. Tolerates a URL that
        /// already names the endpoint, so an operator who copied one out of
        /// the docs is not punished for it.
        /// </summary>
        private static bool TryBuildMasterUri(string configured, string path, out Uri uri, out string error)
        {
            uri = null!;

            if (string.IsNullOrWhiteSpace(configured) || !Uri.TryCreate(configured.Trim(), UriKind.Absolute, out var parsed))
            {
                error = "Invalid Master Server URL in settings.";
                return false;
            }

            var existingPath = parsed.AbsolutePath.TrimEnd('/');

            var builder = new UriBuilder(parsed)
            {
                Path = existingPath.EndsWith(path, StringComparison.OrdinalIgnoreCase)
                    ? existingPath
                    : existingPath + path,
            };

            uri = builder.Uri;
            error = "";
            return true;
        }

        /// <summary>
        /// Is the master server actually reachable, regardless of whether it
        /// is listing anyone -- what the launcher's status bar shows (WO-35).
        /// A separate, cheap request rather than inferred from
        /// <see cref="GetServersFromMasterAsync"/>'s result: an empty list is
        /// what "the master is fine and nobody is hosting" looks like too, and
        /// the two must not be shown as the same thing. Mirrors exactly what
        /// <c>MasterApi.StatusPath</c>'s own doc comment says it is for.
        /// </summary>
        public async Task<bool> IsMasterServerOnlineAsync(string masterUrl)
        {
            if (!TryBuildMasterUri(masterUrl, MasterApi.StatusPath, out var uri, out _))
            {
                return false;
            }

            try
            {
                using var response = await _httpClient.GetAsync(uri);
                return response.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Live detail for one relay, read from the HTTP endpoint the relay
        /// already serves. This used to return random numbers behind a "TODO:
        /// actual udp" — which meant the browser showed a plausible-looking
        /// map and player count for servers that were not even running.
        ///
        /// Returns null when the relay does not answer, so the caller can leave
        /// the row marked offline instead of inventing values for it.
        /// </summary>
        public async Task<DedicatedServerInfoData?> GetDedicatedServerInfoAsync(string ip, int infoPort)
        {
            try
            {
                var info = await _httpClient.GetFromJsonAsync<DedicatedServerInfoData>(
                    $"http://{FormatHost(ip)}:{infoPort}/api/information");

                return info;
            }
            catch (Exception ex)
            {
                Log.Error($"Failed to get info for server {ip}:{infoPort} - {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Polls the locally-running agent's release-version IPC endpoint
        /// (WO-19, see dotnet/KcdMp.Client/VersionIpcServer.cs). Returns null
        /// when the agent hasn't started that listener yet (too early after
        /// launch), isn't running at all, or connects to no relay yet -- all
        /// of which the caller treats the same way: nothing to compare yet,
        /// try again on the next poll.
        /// </summary>
        public async Task<VersionStatusData?> GetVersionStatusAsync(int port)
        {
            try
            {
                return await _httpClient.GetFromJsonAsync<VersionStatusData>($"http://localhost:{port}/version-status");
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// An IPv6 literal has to be bracketed in a URL, or the colons in the
        /// address are read as the port separator and the request throws.
        /// </summary>
        private static string FormatHost(string ip) =>
            System.Net.IPAddress.TryParse(ip, out var parsed)
            && parsed.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? $"[{ip}]"
                : ip;

        /// <summary>
        /// Accepts a DNS hostname or an IP literal, IPv4 or IPv6 -- anything
        /// the connection path itself can take, which is a plain string all
        /// the way down to TcpClient.ConnectAsync(string, int).
        ///
        /// The IPAddress.TryParse check this replaces (WO-55) rejected every
        /// hostname, so a friend with a Dynamic DNS address could not join at
        /// all: their real, working name was refused at the Add Server form
        /// without ever being tried. Uri.CheckHostName is the framework's own
        /// syntax check for exactly this "host" position; whether the name
        /// actually resolves is DNS's job at connect time, same as any client.
        /// </summary>
        public bool ValidateServerAddress(string address, bool showError = true)
        {
            if (!string.IsNullOrWhiteSpace(address)
                && Uri.CheckHostName(address.Trim()) != UriHostNameType.Unknown)
            {
                return true;
            }

            if (showError)
            {
                _uiService.ShowError("Invalid server address. Enter a hostname such as myserver.duckdns.org, or an IP address.");
            }
            return false;
        }

        /// <summary>
        /// Can a TCP connection actually be opened to this host and port --
        /// the same operation the agent's own relay connect performs, so it is
        /// the truthful reachability test. Exists because ICMP ping is not:
        /// home routers (exactly where a Dynamic DNS name points) commonly
        /// drop WAN ping while forwarding the relay's TCP port fine, and the
        /// launch gate used to trust ping alone (WO-55).
        /// </summary>
        public async Task<bool> CanConnectTcpAsync(string host, int port, int timeoutMs = 3000)
        {
            try
            {
                using var tcp = new TcpClient();
                using var cts = new CancellationTokenSource(timeoutMs);
                await tcp.ConnectAsync(host.Trim(), port, cts.Token);
                return true;
            }
            catch (Exception ex)
            {
                Log.Debug("TCP reachability probe to {Host}:{Port} failed: {Message}", host, port, ex.Message);
                return false;
            }
        }

        public bool ValidatePort(int port, bool showError = true)
        {
            if (port < 1024 || port > 65535)
            {
                if (showError)
                {
                    _uiService.ShowError("Invalid port number. Port must be between 1024 and 65535.");
                }
                return false;
            }

            return true;
        }

        /// <summary>
        /// IPv4 addresses of this machine's own network interfaces, excluding
        /// loopback and anything not currently up. This is what a friend on
        /// the same LAN or VPN overlay (Tailscale/ZeroTier/Radmin/Hamachi)
        /// needs to type in -- there can be more than one (real LAN + a VPN
        /// adapter), so the host is shown all of them rather than a guess.
        /// </summary>
        public List<string> GetLocalIPv4Addresses()
        {
            var result = new List<string>();
            try
            {
                foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;

                    foreach (var addr in nic.GetIPProperties().UnicastAddresses)
                    {
                        if (addr.Address.AddressFamily == AddressFamily.InterNetwork)
                        {
                            result.Add(addr.Address.ToString());
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Could not enumerate local network interfaces");
            }
            return result;
        }
    }
}