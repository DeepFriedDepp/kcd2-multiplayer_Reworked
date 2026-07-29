using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using KCDMP_launcher.Components;
using KCDMP_launcher.Models;
using KCDMP_launcher.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.JSInterop;
using Serilog;


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

        private DotNetObjectReference<Home>? objRef;
        private AppSettings settings = new AppSettings();
        private ServerInfo? serverToEdit = null;
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
            await RefreshApp();
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

        public void Dispose() => objRef?.Dispose();

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

            var fetchedServers = await NetService.GetServersFromMasterAsync(settings.MasterServerUrl);
            servers = fetchedServers;
            StateHasChanged();

            var tasks = servers.Concat(customServers).Select(async server =>
            {
                server.Ping = await NetService.SendPingServerAsync(server.Ip);

                // The info endpoint is a different port from the one peers
                // connect on; see AppSettings.ServerInfoPort.
                var details = await NetService.GetDedicatedServerInfoAsync(server.Ip, settings.ServerInfoPort);

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
        /// Start the three things the system actually needs: the game, the
        /// injected DLL, and the agent.
        ///
        /// This was written against a design that did not exist yet, and every
        /// assumption in it has since been settled by the native-plugin work:
        ///
        /// - It passed "+map &lt;name&gt;" to boot straight into a level. KCD2
        ///   loads a save; there is no level to boot into, so the argument and
        ///   the level-directory check that guarded it are both gone.
        /// - It never started KcdMpClient.exe, which is the only process that
        ///   talks to the relay. Launching the game alone connected nothing.
        /// - It injected 3 seconds after Process.Start. The DLL hooks
        ///   WHGame.dll's import of C_ModulesManager::Update, so it needs that
        ///   module loaded; 3 seconds in it is not. It now waits for the module
        ///   to appear rather than guessing at a delay.
        ///
        /// The game must be the Modding Tools build. That is checked here
        /// rather than left to fail confusingly later — see AppSettings.GamePath.
        /// </summary>
        private async Task LaunchGame(ServerInfo server)
        {
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
                    WorkingDirectory = Path.GetDirectoryName(settings.GamePath)
                };

                var gameProcess = Process.Start(gameStartInfo);
                if (gameProcess == null)
                {
                    UiService.ShowError("The game process could not be started.");
                    return;
                }

                if (!await WaitForInjectableAsync(gameProcess, settings.InjectDelaySeconds))
                {
                    UiService.ShowError(gameProcess.HasExited
                        ? "Game process exited unexpectedly before injection."
                        : $"WHGame.dll did not load within {settings.InjectDelaySeconds}s, so the DLL was not injected.");
                    return;
                }

                var injectorStartInfo = new ProcessStartInfo
                {
                    FileName = injectorPath,
                    Arguments = $"--pid {gameProcess.Id} --dll \"{dllFullPath}\"",
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
                            return;
                        }
                    }
                }

                // The agent waits for a save to load on its own, so starting it
                // now is fine even though the player is still at the main menu.
                var agentStartInfo = new ProcessStartInfo
                {
                    FileName = agentPath,
                    Arguments = $"--host {server.Ip} --port {server.Port}",
                    UseShellExecute = false,
                    WorkingDirectory = Path.GetDirectoryName(agentPath)
                };

                Process.Start(agentStartInfo);
            }
            catch (Exception ex)
            {
                errorMessage = ex.Message;
                UiService.ShowError($"Critical Launch Error: {ex.Message}");
            }
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


        private void ConfirmExit() => Environment.Exit(0);

        // Persistence
        private void LoadFavorites() { try { if (File.Exists(FavoritesFileName)) favoriteIps = JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(FavoritesFileName)) ?? new(); } catch { } }
        private void SaveFavorites() { try { File.WriteAllText(FavoritesFileName, JsonSerializer.Serialize(favoriteIps)); } catch { } }

        private void LoadSettings() { try { if (File.Exists(SettingsFileName)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsFileName)) ?? new(); } catch { } }
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

