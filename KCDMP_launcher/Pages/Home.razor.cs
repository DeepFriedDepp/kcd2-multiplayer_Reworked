using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using KCDMP_launcher.Components;
using KCDMP_launcher.Components.Shared;
using KCDMP_launcher.Models;
using KCDMP_launcher.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.JSInterop;
using Serilog;
using KcdMp.Wire;


// TO DO
// SPLIT THIS MF INTO SEVERAL COMPONENTS, THIS FILE IS GETTING OUT OF HAND

namespace KCDMP_launcher.Pages
{
    public partial class Home
    {

        [Inject] public required IJSRuntime JSRuntime { get; set; }
        [Inject] public required UiService UiService { get; set; }

        [Inject] public required NetService NetService { get; set; }

        #region Constants
        private const string FavoritesFileName = "favorites.json";
        private const string SettingsFileName = "settings.json";
        private ServerList? serverListComponent;
        #endregion

        #region State
        private bool isLoading = false;
        private string errorMessage = "";



        // Modals
        private bool showExitConfirm = false;
        private bool showSettings = false;
        private bool showHostInfo = false;
        private bool showReportBug = false;
        private bool showVersionMismatch = false;
        private string versionMismatchMessage = "";
        private CancellationTokenSource? versionPollCts;

        private DotNetObjectReference<Home>? objRef;
        private AppSettings settings = new AppSettings();
        private ServerInfo? serverToEdit = null;
        #endregion

        #region Host state
        private Process? hostedRelayProcess = null;
        private List<string> hostLanAddresses = new List<string>();
        private string hostErrorMessage = "";
        #endregion

        #region Master server state (WO-35)
        private Process? hostedMasterServerProcess = null;
        #endregion

        #region Launch/connect state
        // The launcher used to inject the instant WHGame.dll became loadable,
        // which happens well before the game finishes loading a save -- the
        // native DLL's own liveness check then finds zero engine ticks and
        // silently aborts (see docs/VERIFICATION-REPORT.md, "Real finding").
        // Re-injecting the same DLL path a second time does not help: Windows
        // does not re-run DllMain for an already-loaded module. So injection
        // now happens exactly once, gated on the player confirming they are
        // actually in a loaded world, and the result is verified against the
        // DLL's own log rather than trusted from the injector's exit code.
        private enum LaunchStage { Idle, WaitingForConnect, Injecting, Verifying, Connected, Failed }
        private LaunchStage launchStage = LaunchStage.Idle;
        private Process? pendingGameProcess = null;
        private ServerInfo? pendingServer = null;
        private string? pendingDllPath = null;
        private string launchStatusMessage = "";
        // WO-27: the agent started by ConnectToGame, tracked so a later Connect
        // (e.g. after the game was closed and relaunched without restarting the
        // launcher) can kill the old one first instead of leaving it running
        // alongside a new one. Two agents both claiming the same local player
        // identity to the relay was observed live to cause an infinite
        // reconnect/respawn war -- ~4000 spawn cycles in ~10 minutes -- because
        // neither side's ghost could ever be cleanly removed while the other
        // kept reasserting it. See docs/WO-27-findings.md.
        private Process? agentProcess = null;
        #endregion

        #region Filter State
        private bool isFilterOpen = false;
        private string filterName = "";
        private string filterMap = "";
        private int? filterMinPlayers;
        private int? filterMaxPlayers;
        private int? filterMinPing;
        private int? filterMaxPing;
        private bool filterShowFavorites = false;
        private bool filterHideUnreachable = false;
        #endregion

        #region Data & Logic
        private HashSet<string> favoriteIps = new HashSet<string>();
        private string currentSortColumn = "Players";
        private bool isAscending = false;

        // Dummy Data
        private List<ServerInfo> servers = new List<ServerInfo>();
    //    private List<ServerInfo> servers = new List<ServerInfo>
    //{
    //    new ServerInfo { Name = "Official PL Server #1", Ip = "127.0.0.1", Port = 27015, MapName = "skalitz_survival", Players = 12, MaxPlayers = 64, Ping = 25 },
    //    new ServerInfo { Name = "Roleplay Tavern", Ip = "192.168.1.5", Port = 7777, MapName = "rataje_city", Players = 60, MaxPlayers = 64, Ping = 42 },
    //    new ServerInfo { Name = "High Ping Test", Ip = "10.0.0.2", Port = 28000, MapName = "debug_map", Players = 1, MaxPlayers = 10, Ping = 150 },
    //    new ServerInfo { Name = "Laggy Server", Ip = "10.0.0.2", Port = 28000, MapName = "forest", Players = 5, MaxPlayers = 10, Ping = 80 },
    //    new ServerInfo { Name = "Polish Hussars", Ip = "10.0.0.5", Port = 28000, MapName = "skalitz_survival", Players = 32, MaxPlayers = 64, Ping = 30 },
    //};
        private const string CustomServersFileName = "custom_servers.json";
        private bool showAddServer = false;
        private List<ServerInfo> customServers = new List<ServerInfo>();

        public void DisplayError()
        {
            UiService.ShowError("This is a test error message!");
        }

        private IEnumerable<ServerInfo> filteredAndSortedServers
        {
            get
            {
                var allServers = servers.Concat(customServers).AsEnumerable();
                var query = allServers;

                if (!string.IsNullOrWhiteSpace(filterName))
                    query = query.Where(s => s.Name != null && s.Name.Contains(filterName, StringComparison.OrdinalIgnoreCase));

                if (!string.IsNullOrWhiteSpace(filterMap) && filterMap != "All Maps")
                    query = query.Where(s => s.MapName == filterMap);

                if (filterMinPlayers.HasValue) query = query.Where(s => s.Players >= filterMinPlayers.Value);
                if (filterMaxPlayers.HasValue) query = query.Where(s => s.Players <= filterMaxPlayers.Value);

                if (filterMinPing.HasValue) query = query.Where(s => s.Ping >= filterMinPing.Value);
                if (filterMaxPing.HasValue) query = query.Where(s => s.Ping <= filterMaxPing.Value);

                if (filterHideUnreachable)
                {
                    query = query.Where(s => s.Ping >= 0);
                }

                if (filterShowFavorites)
                    query = query.Where(s => favoriteIps.Contains(s.Ip));

                return currentSortColumn switch
                {
                    "Name" => isAscending ? query.OrderBy(s => s.Name) : query.OrderByDescending(s => s.Name),
                    "Map" => isAscending ? query.OrderBy(s => s.MapName) : query.OrderByDescending(s => s.MapName),
                    "Players" => isAscending ? query.OrderBy(s => s.Players) : query.OrderByDescending(s => s.Players),
                    "Ping" => isAscending ? query.OrderBy(s => s.Ping) : query.OrderByDescending(s => s.Ping),
                    _ => query
                };
            }
        }
        private List<string> availableMaps => servers.Select(s => s.MapName).Distinct().ToList();

        private void ResetFilters()
        {
            filterName = "";
            filterMap = "";
            filterMinPlayers = null;
            filterMaxPlayers = null;
            filterMinPing = null;
            filterMaxPing = null;
            filterShowFavorites = false;
            filterHideUnreachable = true;
            StateHasChanged();
        }
        #endregion

        #region Lifecycle & Methods
        protected override async Task OnInitializedAsync()
        {
            LoadFavorites();
            LoadSettings();
            LoadCustomServers();
            CheckGamePathOnStartup();
            CheckInstallIntegrity();
            Globals.OnStyleChanged += OnStyleChanged;
            await EnsureLocalMasterServerAsync();
            await RefreshApp();
        }

        /// <summary>
        /// WO-32 follow-up: a mixed install (some DLLs from one build, some
        /// from another -- the half-applied-installer failure) is invisible
        /// to the wire protocol because the mix is inside one machine, so
        /// the launcher checks for it the moment it starts. Reuses the
        /// version-mismatch modal: same shape of problem, same "someone
        /// needs to update" conversation, just with yourself.
        /// </summary>
        private void CheckInstallIntegrity()
        {
            var problem = InstallIntegrity.CheckForPartialInstall();
            if (problem is null) return;
            Log.Warning("Partial install detected: {Problem}", problem);
            versionMismatchMessage = problem;
            showVersionMismatch = true;
        }

        private void OnStyleChanged() => _ = ApplyStyleProfile();

        /// <summary>
        /// Pushes the current StyleProfile's palette over site.css's :root
        /// defaults (see StyleProfile.ToCssVariables). Called once after first
        /// render -- JS interop is not available before then -- and again on
        /// every Globals.OnStyleChanged, so switching or editing a profile
        /// takes effect immediately without a restart.
        /// </summary>
        private async Task ApplyStyleProfile()
        {
            try { await JSRuntime.InvokeVoidAsync("applyKcdTheme", Globals.CurrentStyleProfile.ToCssVariables()); }
            catch (Exception ex) { Log.Debug(ex, "Could not apply the style profile"); }
        }

        /// <summary>
        /// The installer pre-seeds settings.json with the game path it found,
        /// so the normal case never sees this. It exists for the person who
        /// unzipped a release by hand, or whose game moved between Steam
        /// libraries: rather than letting them find out at the moment they
        /// press Launch, open Settings straight away and say what is wrong.
        /// </summary>
        private void CheckGamePathOnStartup()
        {
            if (string.IsNullOrWhiteSpace(settings.GamePath) || !File.Exists(settings.GamePath))
            {
                showSettings = true;
                UiService.ShowError(
                    "No game found yet. Point 'Game Path' at the KingdomCome.exe inside your " +
                    "KCD2 Modding Tools install (…\\KCD2Mod\\Bin\\Win64ReleaseSteamLTO_DLL).");
                return;
            }

            if (!IsModdingToolsBuild(settings.GamePath))
            {
                showSettings = true;
                UiService.ShowError(
                    "The saved game path is the retail build. KCD2 must be launched from the Modding " +
                    "Tools build (KCD2Mod) — it is the only one with the debug API on port 1403 and the " +
                    "separate module DLLs the plugin hooks.");
            }
        }

        //CUSTOM SERVERS LOGIC 
        private void LoadCustomServers()
        {
            try
            {
                if (File.Exists(CustomServersFileName))
                {
                    var json = File.ReadAllText(CustomServersFileName);
                    var loaded = JsonSerializer.Deserialize<List<ServerInfo>>(json);
                    if (loaded != null) customServers = loaded;
                }
            }
            catch { }
        }

        private void AddCustomServer(ServerInfo newServer)
        {
            if (!customServers.Any(s => s.Ip == newServer.Ip && s.Port == newServer.Port))
            {
                customServers.Add(newServer);
                SaveCustomServers();
            }
            showAddServer = false;
            StateHasChanged();
        }
        private void OpenAddModal()
        {
            serverToEdit = null;
            showAddServer = true;
            StateHasChanged();
        }

        public void OpenEditModal(ServerInfo server)
        {
            serverToEdit = server;
            showAddServer = true;
            StateHasChanged();
        }

        private void HandleServerUpdate(ServerInfo updatedServer)
        {
            SaveCustomServers();
            StateHasChanged();
        }


        private void RemoveCustomServer(ServerInfo server)
        {
            var customToRemove = customServers.FirstOrDefault(s => s.Ip == server.Ip && s.Port == server.Port);

            if (customToRemove != null)
            {
                customServers.Remove(customToRemove);

                SaveCustomServers();
                serverListComponent?.ClearSelection();
                StateHasChanged();
            }
        }

        private void SaveCustomServers()
        {
            try
            {
                var json = JsonSerializer.Serialize(customServers);
                File.WriteAllText(CustomServersFileName, json);
            }
            catch { }
        }

        protected override async Task OnAfterRenderAsync(bool firstRender)
        {
            if (firstRender)
            {
                objRef = DotNetObjectReference.Create(this);
                await JSRuntime.InvokeVoidAsync("registerGlobalKeys", objRef);
                await ApplyStyleProfile();

                await JSRuntime.InvokeVoidAsync("eval", @"
                document.addEventListener('keydown', (e) => {
                    if(e.key === 'F10') {
                        e.preventDefault();
                        DotNet.invokeMethodAsync('KCDMP_launcher', 'ToggleSettingsStatic');
                    }
                })
            ");
            }
        }

        public void Dispose()
        {
            Globals.OnStyleChanged -= OnStyleChanged;
            objRef?.Dispose();
        }

        // JS Invokables
        [JSInvokable("ToggleSettingsStatic")] public static void ToggleSettingsStatic() { }

        [JSInvokable]
        public void ToggleFiltersJS()
        {
            isFilterOpen = !isFilterOpen;
            StateHasChanged();
        }

        [JSInvokable]
        public void ToggleSettingsJS()
        {
            showSettings = !showSettings;
            StateHasChanged();
        }

        [JSInvokable]
        public void ExitApp()
        {
            if (showSettings) { showSettings = false; StateHasChanged(); return; }
            if (isFilterOpen) { isFilterOpen = false; StateHasChanged(); return; }
            showExitConfirm = true;
            StateHasChanged();
        }

        [JSInvokable]
        public async Task RefreshApp()
        {
            if (isLoading) return;
            isLoading = true;
            StateHasChanged();

            // Independent of the list fetch below: an empty list is what "the
            // master is fine and nobody is hosting" looks like too, and the
            // status bar must not show that as "offline" (WO-35).
            Globals.IsMasterOnline = await NetService.IsMasterServerOnlineAsync(settings.MasterServerUrl);

            var fetchedServers = await NetService.GetServersFromMasterAsync(settings.MasterServerUrl);
            servers = fetchedServers;
            StateHasChanged();

            var tasks = servers.Concat(customServers).Select(async server =>
            {
                server.Ping = await NetService.SendPingServerAsync(server.Ip);

                // The info endpoint is a different port from the one peers
                // connect on. The master server (WO-35) now publishes each
                // relay's real one; fall back to the configured guess only
                // for a manually-added server, which the master never told
                // us about.
                var infoPort = server.InfoPort > 0 ? server.InfoPort : settings.ServerInfoPort;
                var details = await NetService.GetDedicatedServerInfoAsync(server.Ip, infoPort);

                if (details != null)
                {
                    server.MapName = details.MapName;
                    server.Players = details.Players;
                    server.MaxPlayers = details.MaxPlayers;
                    server.IsOnline = true;
                }
                else
                {
                    // Registered with the master but not answering. Leave the
                    // registered map name in place and say it is offline rather
                    // than showing counts we do not have.
                    server.IsOnline = false;
                }
                await InvokeAsync(StateHasChanged);
            });

            await Task.WhenAll(tasks);

            isLoading = false;
            StateHasChanged();
        }


        // Actions
        private void SortTable(string columnName) 
        { 
            if (currentSortColumn == columnName) 
            { 
                isAscending = !isAscending; 
            }
            else 
            { 
                currentSortColumn = columnName; isAscending = true; 
            } 
        }

        private void ToggleFavorite(ServerInfo server)
        {
            if (favoriteIps.Contains(server.Ip)) favoriteIps.Remove(server.Ip);
            else favoriteIps.Add(server.Ip);
            SaveFavorites();
        }

        /// <summary>
        /// Start the game and wait until it is ready to be injected into.
        ///
        /// This was written against a design that did not exist yet, and every
        /// assumption in it has since been settled by the native-plugin work:
        ///
        /// - It passed "+map &lt;name&gt;" to boot straight into a level. KCD2
        ///   loads a save; there is no level to boot into, so the argument and
        ///   the level-directory check that guarded it are both gone.
        /// - It injected the instant WHGame.dll became loadable, and started
        ///   the agent right after. Both happened well before the game's own
        ///   per-frame update loop was actually ticking, which is what the DLL
        ///   itself checks for -- see ConnectToGame below.
        ///
        /// The game must be the Modding Tools build. That is checked here
        /// rather than left to fail confusingly later — see AppSettings.GamePath.
        /// </summary>
        private async Task LaunchGame(ServerInfo server)
        {
            if (launchStage != LaunchStage.Idle && launchStage != LaunchStage.Failed)
            {
                UiService.ShowError("A launch is already in progress.");
                return;
            }

            if (string.IsNullOrEmpty(settings.GamePath) || !File.Exists(settings.GamePath))
            {
                UiService.ShowError("Game Executable not found! Please check Settings.");
                return;
            }

            if (!IsModdingToolsBuild(settings.GamePath))
            {
                UiService.ShowError(
                    "That looks like the retail game. KCD2 must be launched from the Modding Tools build " +
                    "(KCD2Mod), which is the only one with the debug API on port 1403 and the separate " +
                    "module DLLs the plugin hooks. Check Settings.");
                return;
            }

            if (!IsServerReachable(server))
            {
                UiService.ShowError("Server is unreachable. Cannot launch.");
                return;
            }

            string dllFullPath = ResolveAgainstLauncher(settings.DllPath);
            if (!File.Exists(dllFullPath))
            {
                UiService.ShowError($"Multiplayer DLL not found at: {dllFullPath}");
                return;
            }

            string injectorPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KCDMP_LauncherInjector.exe");
            if (!File.Exists(injectorPath))
            {
                UiService.ShowError($"Injector executable not found at: {injectorPath}");
                return;
            }

            string agentPath = ResolveAgainstLauncher(settings.AgentPath);
            if (!File.Exists(agentPath))
            {
                UiService.ShowError($"Agent (KcdMpClient.exe) not found at: {agentPath}");
                return;
            }

            try
            {
                var gameStartInfo = new ProcessStartInfo
                {
                    FileName = settings.GamePath,
                    UseShellExecute = false,
                    WorkingDirectory = GameRootOf(settings.GamePath)
                };

                var gameProcess = Process.Start(gameStartInfo);
                if (gameProcess == null)
                {
                    UiService.ShowError("The game process could not be started.");
                    return;
                }

                launchStage = LaunchStage.WaitingForConnect;
                launchStatusMessage = "Waiting for the game to start...";
                StateHasChanged();

                if (!await WaitForInjectableAsync(gameProcess, settings.InjectDelaySeconds))
                {
                    UiService.ShowError(gameProcess.HasExited
                        ? "Game process exited unexpectedly before injection."
                        : $"WHGame.dll did not load within {settings.InjectDelaySeconds}s, so the DLL was not injected.");
                    ResetLaunchState();
                    return;
                }

                pendingGameProcess = gameProcess;
                pendingServer = server;
                pendingDllPath = dllFullPath;
                launchStatusMessage = "Load into your save, then click CONNECT once you can see and move your character.";
                StateHasChanged();
            }
            catch (Exception ex)
            {
                errorMessage = ex.Message;
                UiService.ShowError($"Critical Launch Error: {ex.Message}");
                ResetLaunchState();
            }
        }

        /// <summary>
        /// The second half of launching: inject and start the agent. Split out
        /// from LaunchGame and gated on the player clicking CONNECT because the
        /// native DLL only works once the game is actually ticking frames --
        /// which, per docs/VERIFICATION-REPORT.md, does not happen until well
        /// past the splash/menu screens and into a loaded save. Injecting the
        /// moment WHGame.dll is merely loadable (the old behaviour) attaches a
        /// DLL that immediately finds zero frames and aborts on its own
        /// liveness check -- silently, since the injector's exit code is still
        /// 0 (LoadLibrary succeeded; the DLL just gave up after that).
        ///
        /// There is no retry if this fires too early: Windows does not re-run
        /// DllMain for a module that is already loaded at that path, so a
        /// second injector run against the same game process is a no-op. The
        /// only way back from a failed verification is a fresh game launch.
        /// </summary>
        private async Task ConnectToGame()
        {
            if (pendingGameProcess == null || pendingServer == null || pendingDllPath == null)
            {
                return;
            }

            if (pendingGameProcess.HasExited)
            {
                UiService.ShowError("The game process has already exited.");
                ResetLaunchState();
                return;
            }

            string injectorPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KCDMP_LauncherInjector.exe");
            string agentPath = ResolveAgainstLauncher(settings.AgentPath);

            try
            {
                launchStage = LaunchStage.Injecting;
                launchStatusMessage = "Injecting...";
                StateHasChanged();

                var injectorStartInfo = new ProcessStartInfo
                {
                    FileName = injectorPath,
                    Arguments = $"--pid {pendingGameProcess.Id} --dll \"{pendingDllPath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var injector = Process.Start(injectorStartInfo))
                {
                    if (injector != null)
                    {
                        await injector.WaitForExitAsync();
                        if (injector.ExitCode != 0)
                        {
                            UiService.ShowError($"Injection failed (exit code {injector.ExitCode}).");
                            ResetLaunchState();
                            return;
                        }
                    }
                }

                launchStage = LaunchStage.Verifying;
                launchStatusMessage = "Verifying the plugin actually attached...";
                StateHasChanged();

                var verdict = await VerifyInjectionAsync(pendingDllPath, pendingGameProcess.Id);
                if (!verdict)
                {
                    UiService.ShowError(
                        "The plugin loaded but never saw the game running -- you likely clicked Connect before " +
                        "the save had fully loaded. It cannot retry from here: Windows will not reload an " +
                        "already-loaded DLL into the same game process. Close the game, click Launch again, and " +
                        "wait until you can move your character before clicking Connect.");
                    launchStage = LaunchStage.Failed;
                    launchStatusMessage = "Injection did not take. Restart the game to try again.";
                    StateHasChanged();
                    return;
                }

                // WO-50: --hosting is purely cosmetic (Discord Rich Presence
                // text) -- the agent otherwise treats hosting and joining
                // identically. hostedRelayProcess is set by OpenHostModal
                // before LaunchAsHost ever reaches here, so its liveness at
                // this point is a reliable "this session is hosting" signal;
                // ServerHost/Ip alone is not, since a LAN host address looks
                // identical to a joiner pointed at the same address.
                bool isHosting = hostedRelayProcess != null && !hostedRelayProcess.HasExited;
                var agentArgs = $"--host {pendingServer.Ip} --port {pendingServer.Port}" +
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

                launchStage = LaunchStage.Connected;
                launchStatusMessage = "Connected. You can close this once you're playing.";
                StateHasChanged();

                versionPollCts?.Cancel();
                versionPollCts = new CancellationTokenSource();
                _ = PollVersionMismatchAsync(versionPollCts.Token);
            }
            catch (Exception ex)
            {
                errorMessage = ex.Message;
                UiService.ShowError($"Critical Connect Error: {ex.Message}");
                ResetLaunchState();
            }
        }

        /// <summary>
        /// WO-19. Polls the just-started agent's release-version IPC endpoint
        /// (dotnet/KcdMp.Client/VersionIpcServer.cs) for a bounded window,
        /// looking for the first connected peer whose release version
        /// differs from this launcher's own (<see cref="Globals.Version"/> --
        /// launcher and its bundled agent always ship under the same VERSION,
        /// so there is no need to also ask the agent for "its own" version).
        ///
        /// Deliberately does NOT run on every protocol mismatch: that case
        /// never gets this far, because the relay's hard refusal
        /// (ProtocolVersionMismatchException on the agent side) already
        /// prevents a connection, so this endpoint would report no peer at
        /// all. This only ever fires for a connection that *succeeded* but
        /// carries a different release version -- exactly the case the WO
        /// asked for, kept separate from the existing hard refusal rather
        /// than replacing any part of it.
        ///
        /// Stops after showing the notice once, after finding a same-version
        /// peer (nothing to say), or after the window elapses with no peer
        /// seen at all (solo session, or the agent never got that far).
        /// </summary>
        private async Task PollVersionMismatchAsync(CancellationToken ct)
        {
            var deadline = DateTime.UtcNow.AddMinutes(5);
            while (!ct.IsCancellationRequested && DateTime.UtcNow < deadline)
            {
                await Task.Delay(3000, ct).ContinueWith(_ => { });
                if (ct.IsCancellationRequested) return;

                var status = await NetService.GetVersionStatusAsync(settings.VersionIpcPort);
                var peer = status?.Peers.FirstOrDefault();
                if (peer is null) continue; // agent not up yet, or no peer connected yet -- keep waiting

                var comparison = ReleaseVersionCompare.Compare(Globals.Version, peer.ReleaseVersion);
                if (comparison == ReleaseVersionComparison.Equal) return; // nothing to say

                versionMismatchMessage = comparison switch
                {
                    ReleaseVersionComparison.LocalIsOlder =>
                        $"You're on {Globals.Version}, your host is on {peer.ReleaseVersion} -- you'll need to update.",
                    ReleaseVersionComparison.LocalIsNewer =>
                        $"You're on {Globals.Version}, your host is on {peer.ReleaseVersion} -- they'll need to update.",
                    _ => "Versions don't match -- make sure everyone's on the latest release.",
                };
                showVersionMismatch = true;
                await InvokeAsync(StateHasChanged);
                return;
            }
        }

        /// <summary>
        /// Confirms the injection actually took by reading the DLL's own log
        /// next to it (see native/KCDMP/log.h -- it always writes beside the
        /// loaded module) rather than trusting the injector's exit code, which
        /// only proves LoadLibrary succeeded, not that the plugin found a live
        /// game to attach to.
        ///
        /// Looks for this run's own "pid=&lt;pid&gt;" attach line and the
        /// liveness sample that follows it. WO-10 changed the native DLL from
        /// a single 1s sample-and-abort to a poll (up to 5 minutes) so an
        /// early injection retries instead of permanently failing -- see
        /// dllmain.cpp and docs/WO-10-injection-fix.md. That changed the log
        /// line's wording, so this regex must track it:
        ///   success: "MAIN: N frames after ~M ms -- tick is live" (N &gt; 0)
        ///   failure: "MAIN: tick never fired after M ms -- ..."
        /// This 8s window is unchanged: by the time the player clicks CONNECT
        /// here (WO-7's own gate -- they can already see and move their
        /// character), the tick is essentially always already live, so the
        /// native side's first 1s sample should log success well inside 8s.
        /// The native poll's longer ceiling exists for injection paths
        /// without that human gate (a developer running
        /// KCDMP_LauncherInjector.exe directly, or a future automatic
        /// injector), not for this UI flow.
        /// </summary>
        private static async Task<bool> VerifyInjectionAsync(string dllPath, int pid)
        {
            var dir = Path.GetDirectoryName(dllPath) ?? "";
            var logPath = Path.Combine(dir, "kcdmp-native.log");
            var deadline = DateTime.UtcNow.AddSeconds(8);
            var attachMarker = $"pid={pid}";

            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    if (File.Exists(logPath))
                    {
                        string text;
                        using (var stream = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                        using (var reader = new StreamReader(stream))
                        {
                            text = await reader.ReadToEndAsync();
                        }

                        var attachIdx = text.LastIndexOf(attachMarker, StringComparison.Ordinal);
                        if (attachIdx >= 0)
                        {
                            var tail = text[attachIdx..];
                            var match = Regex.Match(tail, @"MAIN: (\d+) frames after ~\d+ ms -- tick is live");
                            if (match.Success)
                            {
                                return int.Parse(match.Groups[1].Value) > 0;
                            }
                            if (tail.Contains("tick never fired"))
                            {
                                return false;
                            }
                        }
                    }
                }
                catch (IOException)
                {
                    // The DLL still holds a write handle at the moment we try
                    // to open it; retry rather than treating this as failure.
                }

                await Task.Delay(300);
            }

            // Timed out without conclusive evidence either way -- treat as
            // failure rather than optimistically starting the agent. The
            // native side may still be polling past this point (it now has
            // up to 5 minutes) -- that is fine: WO-7's gate means the tick
            // should already be live by the time CONNECT is clicked, so a
            // timeout here is a real problem (clicked too early, or the save
            // never actually finished loading), not this fix under-waiting.
            return false;
        }

        private void ResetLaunchState()
        {
            launchStage = LaunchStage.Idle;
            pendingGameProcess = null;
            pendingServer = null;
            pendingDllPath = null;
            launchStatusMessage = "";
            versionPollCts?.Cancel();
            versionPollCts = null;
            StateHasChanged();
        }

        private void CancelPendingConnect() => ResetLaunchState();

        // WO-27: kill any agent this launcher already started, plus a
        // by-name sweep for any other KcdMpClient.exe still running (e.g.
        // orphaned by a launcher window that survived a game restart, which
        // is what actually happened live). Only one agent should ever
        // represent this local player to a relay at a time -- a second one
        // fights the first over the same ghost identity forever, since
        // neither's removal of the other's ghost can ever stick while the
        // other keeps respawning it. Called right before starting a new
        // agent, not on every failure path, so a Connect retry that never
        // got as far as starting an agent does not kill an unrelated one.
        private void StopExistingAgent()
        {
            try
            {
                if (agentProcess != null && !agentProcess.HasExited)
                {
                    agentProcess.Kill();
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Failed to stop the tracked agent process");
            }
            agentProcess = null;

            try
            {
                foreach (var proc in Process.GetProcessesByName("KcdMpClient"))
                {
                    try { proc.Kill(); }
                    catch (Exception ex) { Log.Warning(ex, "Failed to stop stray KcdMpClient.exe (pid {Pid})", proc.Id); }
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Failed to enumerate KcdMpClient.exe processes");
            }
        }

        // Host flow: start a local relay, show the address a friend needs to
        // join it, and launch the game connected to it (127.0.0.1, since the
        // host's own agent always talks to a relay on this machine regardless
        // of what address a friend uses to reach it).
        private async Task OpenHostModal()
        {
            hostErrorMessage = "";
            hostLanAddresses = NetService.GetLocalIPv4Addresses();

            if (hostedRelayProcess == null || hostedRelayProcess.HasExited)
            {
                string relayPath = ResolveAgainstLauncher(settings.RelayPath);
                if (!File.Exists(relayPath))
                {
                    hostErrorMessage = $"Relay executable not found at: {relayPath}. Check Settings.";
                }
                else
                {
                    try
                    {
                        var relayStartInfo = new ProcessStartInfo
                        {
                            FileName = relayPath,
                            Arguments = $"--port {settings.HostPort}",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                            WorkingDirectory = Path.GetDirectoryName(relayPath)
                        };
                        hostedRelayProcess = Process.Start(relayStartInfo);
                        // Give it a moment to bind before anyone tries to connect.
                        await Task.Delay(500);
                        if (hostedRelayProcess == null || hostedRelayProcess.HasExited)
                        {
                            hostErrorMessage = "The relay process exited immediately -- check app.log.";
                            hostedRelayProcess = null;
                        }
                    }
                    catch (Exception ex)
                    {
                        hostErrorMessage = $"Could not start the relay: {ex.Message}";
                        hostedRelayProcess = null;
                    }
                }
            }

            showHostInfo = true;
            StateHasChanged();
        }

        private Task LaunchAsHost()
        {
            showHostInfo = false;
            var hostServer = new ServerInfo
            {
                Name = "(Hosting)",
                Ip = "127.0.0.1",
                Port = settings.HostPort,
                Ping = 0
            };
            return LaunchGame(hostServer);
        }

        private void StopHostedRelay()
        {
            try
            {
                if (hostedRelayProcess != null && !hostedRelayProcess.HasExited)
                {
                    hostedRelayProcess.Kill();
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Failed to stop the hosted relay process");
            }
            hostedRelayProcess = null;
        }

        /// <summary>
        /// Starts the master server locally, alongside the launcher itself,
        /// so a default install has something answering MasterServerUrl
        /// instead of showing "Could not connect to Master Server!" on every
        /// launch (WO-35). Unlike the relay, this runs unconditionally at
        /// startup rather than only on Host -- the browser fetches the list
        /// immediately in OnInitializedAsync, before the player has done
        /// anything.
        ///
        /// Only when the configured URL is loopback: pointing MasterServerUrl
        /// at a friend's real address means their instance is the one meant
        /// to answer, and starting a private, empty one of our own here would
        /// just be a wasted background process that nobody's relay announces
        /// to.
        /// </summary>
        private async Task EnsureLocalMasterServerAsync()
        {
            Log.Debug("EnsureLocalMasterServerAsync: MasterServerUrl = \"{Url}\"", settings.MasterServerUrl);

            if (!Uri.TryCreate(settings.MasterServerUrl, UriKind.Absolute, out var uri) || !IsLoopbackHost(uri.Host))
            {
                Log.Debug("EnsureLocalMasterServerAsync: not a loopback URL, not starting a local instance.");
                return;
            }

            if (await IsMasterServerRespondingAsync(uri))
            {
                Log.Debug("EnsureLocalMasterServerAsync: something is already answering on port {Port}.", uri.Port);
                return;
            }

            if (hostedMasterServerProcess != null && !hostedMasterServerProcess.HasExited)
            {
                return;
            }

            string masterServerPath = ResolveAgainstLauncher(settings.MasterServerPath);
            if (!File.Exists(masterServerPath))
            {
                Log.Warning("Master server executable not found at: {Path}. The status bar will read \"Master: Offline\" until one is installed or Settings -> Master Server URL points elsewhere.", masterServerPath);
                return;
            }

            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = masterServerPath,
                    Arguments = $"--urls http://0.0.0.0:{uri.Port}",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = Path.GetDirectoryName(masterServerPath)
                };
                hostedMasterServerProcess = Process.Start(startInfo);
                if (hostedMasterServerProcess is null)
                {
                    Log.Warning("Process.Start returned null for the master server; not retrying this launch.");
                    return;
                }
                Log.Information("Starting local master server: {Path} (pid {Pid})", masterServerPath, hostedMasterServerProcess.Id);

                // Polled rather than a single fixed delay: a self-contained
                // ASP.NET Core app's cold start (JIT, Kestrel bind) can take
                // longer than any one guessed wait, and a single check right
                // after Process.Start can race RefreshApp's first fetch --
                // exactly what this replaces, found live: the process started
                // and kept running, but RefreshApp's request landed before
                // Kestrel had actually opened the port.
                var deadline = DateTime.UtcNow.AddSeconds(8);
                var up = false;
                while (DateTime.UtcNow < deadline)
                {
                    if (hostedMasterServerProcess.HasExited)
                    {
                        // The most common real reason: two launcher instances
                        // both decided to start one (this check and
                        // Process.Start above are not atomic together), and
                        // this one lost the port to the other. That other
                        // instance's copy is a perfectly good master server,
                        // so check for it once before giving up rather than
                        // reporting a failure that is not actually happening.
                        Log.Information("This launcher's own master server process exited early (code {Code}); checking whether another instance already claimed the port.",
                            hostedMasterServerProcess.ExitCode);
                        up = await IsMasterServerRespondingAsync(uri);
                        break;
                    }

                    if (await IsMasterServerRespondingAsync(uri))
                    {
                        up = true;
                        break;
                    }

                    await Task.Delay(200);
                }

                if (up)
                {
                    Log.Information("Master server is up on port {Port}.", uri.Port);
                }
                else
                {
                    Log.Warning("Local master server did not answer on port {Port} within 8s; giving up for this launch.", uri.Port);
                    hostedMasterServerProcess = null;
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Could not start the local master server");
                hostedMasterServerProcess = null;
            }
        }

        /// <summary>Cheap liveness probe: is anything answering the master API at all, ours or someone else's.</summary>
        private static async Task<bool> IsMasterServerRespondingAsync(Uri baseUri)
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(1) };
                using var response = await http.GetAsync(new Uri(baseUri, MasterApi.StatusPath));
                return response.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        private static bool IsLoopbackHost(string host) =>
            host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
            (System.Net.IPAddress.TryParse(host, out var ip) && System.Net.IPAddress.IsLoopback(ip));

        private void StopHostedMasterServer()
        {
            try
            {
                if (hostedMasterServerProcess != null && !hostedMasterServerProcess.HasExited)
                {
                    hostedMasterServerProcess.Kill();
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Failed to stop the hosted master server process");
            }
            hostedMasterServerProcess = null;
        }

        /// <summary>
        /// Both builds name their executable KingdomCome.exe, so the filename
        /// cannot tell them apart, and neither can WHGame.dll — retail ships
        /// that one too. What actually differs is that the Modding Tools build
        /// links its engine modules as separate DLLs (45 of them beside the
        /// executable) while retail is monolithic (6, none of these).
        ///
        /// Framework.dll and CrySystem.dll are the two the plugin depends on
        /// specifically: the IAT hook rewrites WHGame.dll's import of
        /// Framework.dll's C_ModulesManager::Update, and the reflection ABI is
        /// exported from CrySystem.dll. So this tests for what is needed rather
        /// than for an install path.
        /// </summary>
        public static bool IsModdingToolsBuild(string gamePath)
        {
            string dir = Path.GetDirectoryName(gamePath) ?? "";
            if (dir.Length == 0) return false;

            return File.Exists(Path.Combine(dir, "Framework.dll"))
                && File.Exists(Path.Combine(dir, "CrySystem.dll"));
        }

        /// <summary>
        /// The install root, two levels above KingdomCome.exe
        /// (&lt;root&gt;\Bin\&lt;config&gt;\KingdomCome.exe) -- where Warhorse ships
        /// steam_appid.txt for the Modding Tools build, not beside the exe.
        ///
        /// This matters because we start the game with Process.Start rather
        /// than through Steam itself, so there is no Steam-injected app-id
        /// context for the process -- SteamAPI_Init() falls back to reading
        /// steam_appid.txt from the process's *working directory*. Launching
        /// with WorkingDirectory set to the exe's own folder (the previous
        /// behavior) means that file is never found, which is consistent with
        /// what WO-31 observed: the game runs, but any save referencing DLC
        /// content is greyed out in the load list, matching a process that
        /// never established which App ID it should check DLC ownership
        /// against. See docs/WO-31-findings.md.
        ///
        /// Falls back to the exe's own directory -- the old behavior -- if
        /// steam_appid.txt cannot be found within a few levels, so an
        /// unexpected install layout degrades to what shipped before rather
        /// than breaking outright.
        /// </summary>
        public static string GameRootOf(string gamePath)
        {
            string dir = Path.GetDirectoryName(gamePath) ?? "";
            string fallback = dir;

            for (int i = 0; i < 4 && dir.Length > 0; i++)
            {
                if (File.Exists(Path.Combine(dir, "steam_appid.txt")))
                    return dir;
                dir = Path.GetDirectoryName(dir) ?? "";
            }

            return fallback;
        }

        /// <summary>
        /// WO-39, item K: where the log bundle should look for kcd.log --
        /// derived from the configured game path; empty when unconfigured
        /// (LogBundle skips what it cannot find).
        /// </summary>
        private string LogBundleGameRoot =>
            string.IsNullOrWhiteSpace(settings.GamePath) ? "" : GameRootOf(settings.GamePath);

        /// <summary>WO-39, item K: where the agent writes agent.log.</summary>
        private string LogBundleAgentDirectory =>
            Path.GetDirectoryName(ResolveAgainstLauncher(settings.AgentPath)) ?? "";

        /// <summary>
        /// A relative path in settings means "next to the launcher", which is
        /// where a packaged build puts the DLL, the injector and the agent.
        /// </summary>
        private static string ResolveAgainstLauncher(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return "";
            if (!Path.IsPathRooted(path))
                path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, path);
            return Path.GetFullPath(path);
        }

        /// <summary>
        /// True once the DLL's hook target is loadable. The injector only needs
        /// a live pid, but the DLL's install() looks up WHGame.dll's import of
        /// Framework.dll's C_ModulesManager::Update and gives up if it is not
        /// there — injecting before then attaches a DLL that hooks nothing.
        ///
        /// Falls back to a plain wait if the module list cannot be read, which
        /// happens when the launcher and the game differ in bitness or the
        /// process is still initialising.
        /// </summary>
        private static async Task<bool> WaitForInjectableAsync(Process game, int timeoutSeconds)
        {
            var deadline = DateTime.UtcNow.AddSeconds(Math.Max(5, timeoutSeconds));

            while (DateTime.UtcNow < deadline)
            {
                if (game.HasExited) return false;

                try
                {
                    game.Refresh();
                    foreach (ProcessModule module in game.Modules)
                    {
                        if (string.Equals(module.ModuleName, "WHGame.dll", StringComparison.OrdinalIgnoreCase))
                            return true;
                    }
                }
                catch (Exception ex)
                {
                    Log.Debug($"Could not read the game's module list yet: {ex.Message}");
                }

                await Task.Delay(500);
            }

            return !game.HasExited;
        }

        private bool IsServerReachable(ServerInfo server)
        {
            if (server.Ping < 0)
            {
                return false;
            }
            return true;
        }


        private void ConfirmExit()
        {
            versionPollCts?.Cancel();
            StopHostedRelay();
            StopHostedMasterServer();
            Environment.Exit(0);
        }

        // Persistence
        private void LoadFavorites() { try { if (File.Exists(FavoritesFileName)) favoriteIps = JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(FavoritesFileName)) ?? new(); } catch { } }
        private void SaveFavorites() { try { File.WriteAllText(FavoritesFileName, JsonSerializer.Serialize(favoriteIps)); } catch { } }

        private void LoadSettings()
        {
            try { if (File.Exists(SettingsFileName)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsFileName)) ?? new(); }
            catch { }

            MigrateStaleMasterServerUrl();
            MigrateStaleMasterServerPath();
        }

        /// <summary>
        /// An existing settings.json predating WO-35 has the old Flask-shaped
        /// default baked in ("http://localhost:5000/servers/servers_list") --
        /// a fresh AppSettings() only supplies the new default
        /// (EnsureLocalMasterServerAsync's own logic) for a settings.json that
        /// does not exist yet. Migrated only when it is exactly that known old
        /// literal, never when it looks like something the player configured
        /// on purpose.
        /// </summary>
        private static readonly string[] KnownStaleMasterServerUrls =
        [
            "http://localhost:5000/servers/servers_list", // pre-WO-35 (Flask)
            "http://localhost:5100",                      // WO-35's first pass -- see AppModels.cs
        ];

        /// <summary>
        /// Same idea as <see cref="MigrateStaleMasterServerUrl"/>: a
        /// settings.json saved before the master server got its own
        /// MasterServer\ subfolder (see AppModels.cs and
        /// tools/Publish-Release.ps1) would otherwise keep pointing at a bare
        /// filename that no longer exists there.
        /// </summary>
        private static readonly string[] KnownStaleMasterServerPaths =
        [
            "KcdMpMasterServer.exe", // flat-merged, pre-subfolder-isolation
        ];

        private void MigrateStaleMasterServerUrl()
        {
            if (Array.IndexOf(KnownStaleMasterServerUrls, settings.MasterServerUrl) >= 0)
            {
                settings.MasterServerUrl = new AppSettings().MasterServerUrl;
            }
        }

        private void MigrateStaleMasterServerPath()
        {
            if (Array.IndexOf(KnownStaleMasterServerPaths, settings.MasterServerPath) >= 0)
            {
                settings.MasterServerPath = new AppSettings().MasterServerPath;
            }
        }

        private void SaveSettings()
        {
            try
            {
                File.WriteAllText(SettingsFileName, JsonSerializer.Serialize(settings));
                showSettings = false;
            }
            catch (Exception ex) { errorMessage = ex.Message; }
        }


        #endregion
    }
}

