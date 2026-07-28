using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using KCDMP_launcher.Components.Shared;
using KCDMP_launcher.Models;
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

            if (!ValidateIpAddr(ip, showError: false))
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

            if (!ValidateIpAddr(ip, showError: false))
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

        public async Task<List<ServerInfo>> GetServersFromMasterAsync(string masterUrl)
        {
            var resultList = new List<ServerInfo>();

            if (string.IsNullOrWhiteSpace(masterUrl) || !Uri.TryCreate(masterUrl, UriKind.Absolute, out _))
            {
                _uiService?.ShowError("Invalid Master Server URL in settings.");
                return resultList;
            }

            try
            {
                var dtoList = await _httpClient.GetFromJsonAsync<List<MasterServerEntry>>(masterUrl);

                if (dtoList != null)
                {
                    foreach (var entry in dtoList)
                    {
                        resultList.Add(new ServerInfo
                        {
                            Name = entry.Name,
                            Ip = entry.Ip,
                            Port = entry.Port,
                            // The master already knows the map from
                            // registration, so show it rather than a
                            // placeholder. The live poll refreshes it.
                            MapName = entry.MapName,
                            Ping = -1,
                            Players = 0,
                            MaxPlayers = 0
                        });
                    }
                }
            }
            catch (HttpRequestException ex)
            {
                _uiService?.LogError(ex, $"Could not connect to Master Server!");
            }
            catch (Exception ex)
            {
                _uiService?.LogError(ex, $"Error fetching server list!");
            }

            return resultList;
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
        /// An IPv6 literal has to be bracketed in a URL, or the colons in the
        /// address are read as the port separator and the request throws.
        /// </summary>
        private static string FormatHost(string ip) =>
            System.Net.IPAddress.TryParse(ip, out var parsed)
            && parsed.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? $"[{ip}]"
                : ip;

        /// <summary>
        /// Accepts anything the framework can parse as an address, IPv4 or IPv6.
        ///
        /// The hand-rolled four-octet check this replaces rejected every IPv6
        /// address, which matters now that relays self-register: the master
        /// server falls back to the address the registration arrived from, and
        /// that is "::1" for a relay on the same machine and can be a real IPv6
        /// address for a remote one. Those servers reached the browser and were
        /// then dropped as unreachable, having never been pinged.
        ///
        /// It also dropped the old "last octet cannot be 0" rule, which is not
        /// a real constraint on a host address.
        /// </summary>
        public bool ValidateIpAddr(string ip, bool showError = true)
        {
            if (!string.IsNullOrWhiteSpace(ip) && System.Net.IPAddress.TryParse(ip, out _))
            {
                return true;
            }

            if (showError)
            {
                _uiService.ShowError("Invalid IP address. Enter an IPv4 address such as 192.168.1.10, or an IPv6 address.");
            }
            return false;
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

        
    }
}