using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using KCDMP_launcher.Components.Shared;
using KCDMP_launcher.Models;
using Serilog;

namespace KCDMP_launcher.Pages
{
    /// <summary>
    /// WO-127: Steam as a connection path, plain connection errors, Test
    /// connection. The network work runs in the agent (KcdMpClient.exe), as a
    /// one-shot helper here (AgentHelper) or as the session agent; this file
    /// only shows what it says. Nothing identifying is logged: no Steam code,
    /// no persona names.
    /// </summary>
    public partial class Home
    {
        #region WO-127 state
        // Host
        private string hostSteamState = "off";
        private string hostSteamMessage = "";
        private string? hostSteamCode;
        private string hostSteamAppName = "";
        private string hostRefusedNotice = "";
        private string? lastRefusedShownKey;
        private CancellationTokenSource? hostPollCts;

        // Join through Steam
        private bool showJoinSteam;
        private string steamCodeInput = "";
        private List<SteamFriendData>? steamFriends;
        private string steamFriendsNote = "";
        private string steamResultMessage = "";
        private bool steamResultOk;
        private bool steamBusy;
        private string steamBusyText = "";

        // Message modal (test results, Steam fallback)
        private bool showMessage;
        private string messageTitle = "";
        private string messageText = "";
        private string messageNext = "";
        private bool messageAddressFallback;
        private string fallbackAddress = "";

        // The agent's connection, in plain words
        private string connStatusLine = "";
        private bool connStatusBad;
        private bool steamFallbackShown;
        #endregion

        private static string SteamAppNameOf(uint app) => app switch
        {
            2429020 => "KCD2 Modding Tools (2429020)",
            480 => "Spacewar (480)",
            1771300 => "KCD2 retail (1771300)",
            _ => $"app {app}",
        };

        private string SteamGameArg =>
            string.IsNullOrWhiteSpace(settings.GamePath) ? "" : $" --steam-game \"{settings.GamePath}\"";

        // ------------------------------------------------------------ host

        /// <summary>The relay's command line: the TCP port as before, plus Steam when allowed.</summary>
        private string RelayArguments() =>
            $"--port {settings.HostPort}" +
            (settings.HostAllowSteam ? $" --steam true --steam-app {settings.SteamAppId}{SteamGameArg}" : "");

        /// <summary>"Also allow Steam" flipped in the Host window: restart the relay with the new choice.</summary>
        private async Task SetHostAllowSteamAsync(bool on)
        {
            if (settings.HostAllowSteam == on) return;
            settings.HostAllowSteam = on;
            try { File.WriteAllText(SettingsFileName, JsonSerializer.Serialize(settings)); } catch { }
            Log.Information("Host: Also allow Steam = {On}; restarting the relay", on);
            StopHostedRelay();
            hostSteamState = "off"; hostSteamCode = null; hostSteamMessage = on ? "Starting Steam..." : "";
            await Task.Delay(300);
            await OpenHostModal();
        }

        /// <summary>While this launcher hosts: the relay's Steam state and code, and refused joiner versions.</summary>
        private void StartHostStatusPoll()
        {
            hostPollCts?.Cancel();
            var cts = hostPollCts = new CancellationTokenSource();
            _ = Task.Run(async () =>
            {
                while (!cts.IsCancellationRequested)
                {
                    bool running = hostedRelayProcess != null && !hostedRelayProcess.HasExited;
                    if (!running) { await Task.Delay(1000); if (hostedRelayProcess == null) break; continue; }
                    var st = await NetService.GetRelayLocalStatusAsync(settings.ServerInfoPort);
                    if (st is not null) await ApplyHostStatusAsync(st);
                    await Task.Delay(1500);
                }
            });
        }

        private async Task ApplyHostStatusAsync(RelayLocalStatusData st)
        {
            bool changed = st.Steam.State != hostSteamState || st.Steam.Message != hostSteamMessage || st.Steam.Code != hostSteamCode;
            hostSteamState = st.Steam.State;
            hostSteamMessage = settings.HostAllowSteam ? st.Steam.Message : "";
            hostSteamCode = st.Steam.Code;
            hostSteamAppName = st.Steam.AppName;

            // The mixed-build check on the host's side (the joiner sees its own message).
            string notice = "";
            if (st.RefusedRelease is { Length: > 0 } rel && st.RefusedSecondsAgo is >= 0 and < 600)
            {
                notice = $"A player tried to join with version {rel}; you run {st.Release}. Both players need the same version: whoever is older installs the newer one.";
                string key = rel + "@" + (DateTime.UtcNow.AddSeconds(-st.RefusedSecondsAgo)).ToString("HHmm");
                if (key != lastRefusedShownKey && !showHostInfo)
                {
                    lastRefusedShownKey = key;
                    ShowMessage("VERSION MISMATCH", notice, "");
                    changed = true;
                }
                lastRefusedShownKey ??= key;
            }
            if (notice != hostRefusedNotice) { hostRefusedNotice = notice; changed = true; }
            if (changed) await InvokeAsync(StateHasChanged);
        }

        // ------------------------------------------------------------ join through Steam

        private void OpenJoinSteam()
        {
            showJoinSteam = true;
            steamCodeInput = settings.LastSteamCode ?? "";
            steamResultMessage = "";
            steamFriendsNote = "";
            steamFriends = null;
            StateHasChanged();
        }

        private string? AgentPathOrError()
        {
            string agentPath = ResolveAgainstLauncher(settings.AgentPath);
            if (File.Exists(agentPath)) return agentPath;
            UiService.ShowError("The multiplayer agent (KcdMpClient.exe) is missing. Reinstall, or check the Agent Path in Settings.");
            return null;
        }

        private async Task FindSteamFriendsAsync()
        {
            if (AgentPathOrError() is not { } agent) return;
            steamBusy = true; steamBusyText = "Asking Steam which friends are hosting..."; steamFriendsNote = ""; StateHasChanged();
            var r = await AgentHelper.RunAsync<SteamFriendsData>(agent, $"--steam-friends --steam-app {settings.SteamAppId}{SteamGameArg}", "STEAM-FRIENDS", TimeSpan.FromSeconds(25));
            steamBusy = false;
            if (r is null) steamFriendsNote = "Steam didn't answer. Type the host's code instead.";
            else if (r.State != "ok") steamFriendsNote = $"{r.Message} {r.Next}".Trim();
            else
            {
                steamFriends = r.Friends;
                steamFriendsNote = r.Friends.Count == 0
                    ? "No friends are hosting right now. Friends only show up here while they host, and only when both of you use the same Steam app. Their code works either way."
                    : "Click a friend to use their code.";
            }
            Log.Information("Steam friends lookup: state={State} hosting={Count}", r?.State ?? "no-answer", r?.Friends.Count ?? 0);
            StateHasChanged();
        }

        private async Task TestSteamConnectionAsync()
        {
            if (AgentPathOrError() is not { } agent) return;
            string code = steamCodeInput.Trim();
            steamBusy = true; steamBusyText = "Testing (up to 20 seconds)..."; steamResultMessage = ""; StateHasChanged();
            var r = await AgentHelper.RunAsync<TestConnectionData>(agent,
                $"--test-connection --steam \"{code}\" --steam-app {settings.SteamAppId}{SteamGameArg}", "TEST-CONNECTION", TimeSpan.FromSeconds(45));
            steamBusy = false;
            (steamResultMessage, steamResultOk) = DescribeTest(r);
            StateHasChanged();
        }

        private async Task JoinThroughSteamAsync()
        {
            string code = steamCodeInput.Trim();
            if (code.Length == 0) return;
            settings.LastSteamCode = code;
            try { File.WriteAllText(SettingsFileName, JsonSerializer.Serialize(settings)); } catch { }
            showJoinSteam = false;
            Log.Information("Join through Steam (app {App})", settings.SteamAppId);
            await LaunchGame(new ServerInfo { Name = "(Steam)", Ip = "", Port = 0, Ping = 0, SteamCode = code });
        }

        // ------------------------------------------------------------ Test connection (address)

        private Task TestServerConnectionAsync(ServerInfo server) => ShowConnectionTestAsync(server, launching: false);

        private async Task ShowConnectionTestAsync(ServerInfo server, bool launching)
        {
            if (AgentPathOrError() is not { } agent) return;
            ShowMessage("TESTING...", server.SteamCode is null ? "Reaching the host..." : "Reaching the host through Steam (up to 20 seconds)...", "");
            var r = await AgentHelper.RunAsync<TestConnectionData>(agent, server.SteamCode is null
                    ? $"--test-connection --host {server.Ip} --port {server.Port}"
                    : $"--test-connection --steam \"{server.SteamCode}\" --steam-app {settings.SteamAppId}{SteamGameArg}",
                "TEST-CONNECTION", TimeSpan.FromSeconds(45));
            var (msg, ok) = DescribeTest(r);
            ShowMessage(ok ? "CONNECTION OK" : launching ? "CAN'T REACH THE HOST" : "CONNECTION TEST", msg, "");
        }

        /// <summary>The one line the tester reads; the detail goes to the log only.</summary>
        private static (string Message, bool Ok) DescribeTest(TestConnectionData? r)
        {
            if (r is null)
            {
                Log.Warning("Connection test: no answer from the agent helper");
                return ("The test didn't finish. Try again; if it keeps failing, send the logs with Report a bug.", false);
            }
            Log.Information("Connection test via={Via} kind={Kind} reachable={Reachable} rttMs={Rtt} connectMs={Connect} hostRelease={Rel} hostConnected={Host} steamPingMs={Ping} relayed={Relayed} detail={Detail}",
                r.Via, r.Kind, r.Reachable, r.RttMs, r.ConnectMs, r.HostRelease, r.HostConnected, r.SteamPingMs, r.Relayed, r.Detail);
            bool ok = r.Kind == "None";
            string msg = ok && r.SteamPingMs > 0 ? $"{r.Message} Steam ping {r.SteamPingMs} ms{(r.Relayed == true ? " (through Steam's relays)" : "")}." : r.Message;
            return ((msg + " " + r.Next).Trim(), ok);
        }

        private void ShowMessage(string title, string text, string next, bool addressFallback = false)
        {
            messageTitle = title; messageText = text; messageNext = next; messageAddressFallback = addressFallback;
            showMessage = true;
            _ = InvokeAsync(StateHasChanged);
        }

        // ------------------------------------------------------------ the session agent

        /// <summary>Starts the session agent for <paramref name="server"/> (address or Steam code), replacing any running one.</summary>
        private void StartAgent(ServerInfo server)
        {
            string agentPath = ResolveAgainstLauncher(settings.AgentPath);
            // WO-50: --hosting is also WO-127's host claim (the relay makes this agent
            // the authority whatever order people connect in).
            bool isHosting = hostedRelayProcess != null && !hostedRelayProcess.HasExited;
            string target = server.SteamCode is { } code
                ? $"--steam \"{code}\" --steam-app {settings.SteamAppId}{SteamGameArg}"
                : $"--host {server.Ip} --port {server.Port}";
            var agentArgs = target +
                (settings.VoiceChatEnabled ? "" : " --no-voice") +
                (isHosting ? " --hosting" : "");

            var agentStartInfo = new ProcessStartInfo
            {
                FileName = agentPath,
                Arguments = agentArgs,
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(agentPath)
            };

            StopExistingAgent();
            agentProcess = Process.Start(agentStartInfo);
            Log.Information("Agent started via {Via}", server.SteamCode is null ? "address" : "Steam");
            pendingServer = server;
            steamFallbackShown = false;
            connStatusLine = server.SteamCode is null ? "Connecting to your host..." : "Connecting to your host through Steam...";
            connStatusBad = false;

            versionPollCts?.Cancel();
            versionPollCts = new CancellationTokenSource();
            _ = PollVersionMismatchAsync(versionPollCts.Token);
            _ = PollJoinStatusAsync(versionPollCts.Token);   // WO-123: same lifetime as the version poll
        }

        /// <summary>The agent's /connection-status, as one plain line at the bottom of the window.</summary>
        private async Task RefreshConnectionStatusAsync()
        {
            var cs = await NetService.GetConnectionStatusAsync(settings.VersionIpcPort);
            if (cs is null) return;
            string line; bool bad = false;
            switch (cs.State)
            {
                case "connected": line = ""; break;
                case "failed":
                    line = (cs.Message + " " + cs.Next).Trim();
                    bad = true;
                    // Steam failed: offer the address right here, in this same launch.
                    if (cs.Via == "steam" && !steamFallbackShown && cs.Kind != "Lost")
                    {
                        steamFallbackShown = true;
                        ShowMessage("STEAM CONNECTION FAILED", cs.Message, "", addressFallback: true);
                    }
                    break;
                default: line = cs.Message; break;
            }
            if (line != connStatusLine || bad != connStatusBad)
            {
                connStatusLine = line;
                connStatusBad = bad;
                await InvokeAsync(StateHasChanged);
            }
        }

        /// <summary>After a Steam failure: the same game, the agent restarted with the host's address.</summary>
        private async Task ConnectByAddressAfterSteamAsync()
        {
            string text = fallbackAddress.Trim();
            string host = text; int port = settings.HostPort;
            int colon = text.LastIndexOf(':');
            if (colon > 0 && text.IndexOf(':') == colon && int.TryParse(text[(colon + 1)..], out int p)) { host = text[..colon]; port = p; }
            if (!NetService.ValidateServerAddress(host, showError: false) || port is <= 0 or > 65535)
            {
                ShowMessage("STEAM CONNECTION FAILED", "That address doesn't look right. Type it like 203.0.113.7:7778 or myhost.example.net:7778.", "", addressFallback: true);
                return;
            }
            showMessage = false;
            var server = new ServerInfo { Name = "(Address)", Ip = host, Port = port };
            bool gameUp = agentProcess != null && launchStage == LaunchStage.Connected;
            if (gameUp) StartAgent(server);
            else await LaunchGame(server);
            StateHasChanged();
        }
    }
}
