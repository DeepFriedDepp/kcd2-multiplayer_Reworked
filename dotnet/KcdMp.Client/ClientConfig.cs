using System.Text.Json;
using System.Text.Json.Serialization;

namespace KcdMp.Client;

/// <summary>
/// Agent settings, read from kcdmp-client.json next to the executable.
///
/// The file is created with defaults on first run, so a fresh install has
/// something to edit rather than requiring the old positional argv form.
/// Precedence: command line &gt; config file &gt; defaults.
///
/// Deliberately hand-rolled on System.Text.Json: the agent otherwise depends
/// only on NAudio, and Microsoft.Extensions.Configuration is not part of the
/// shared framework for a plain console app.
/// </summary>
public sealed class ClientConfig
{
    public const string FileName = "kcdmp-client.json";

    /// <summary>Host or IP of the relay server.</summary>
    public string ServerHost { get; set; } = "localhost";

    /// <summary>Relay server port.</summary>
    public int ServerPort { get; set; } = 7778;

    /// <summary>
    /// Display name. Null or empty means auto-detect: KCD2's kcd.log, then
    /// Steam's loginusers.vdf, then the machine name.
    /// </summary>
    public string? PlayerName { get; set; }

    /// <summary>
    /// Base URL of the local game debug API. The game listens on 1403; the
    /// agent only ever talks to its own machine, so no port proxy is needed.
    /// </summary>
    public string GameApiBase { get; set; } = "http://localhost:1403";

    /// <summary>
    /// Whether to open the microphone for proximity voice chat. Off means the
    /// mic is never captured and no voice frames are sent.
    /// </summary>
    public bool VoiceChatEnabled { get; set; } = true;

    /// <summary>
    /// WO-40 Phase 3: whether this agent participates in session weather
    /// sync (arbitrating when it holds damage authority, applying inbound
    /// profiles either way). Off means vanilla per-machine weather.
    /// </summary>
    public bool WeatherSyncEnabled { get; set; } = true;

    /// <summary>
    /// WO-100.5 Phase 4: whether the guid-addressed damage fallback (0x12/0x14)
    /// may fire.
    ///
    /// These are the ONLY two wire paths left that carry unstable identity
    /// (WO-100 S3.4's audit). The 16-byte guid is documented as a
    /// SharedSoulGuid but WO-39 Phase 3 proved it is the PER-SAVE Soul Guid,
    /// and WO-40 field-confirmed it resolves on some NPCs and not others --
    /// 571 of 571 failures on one machine, 176 of 176 successes on another. So
    /// on the evidence this path silently does nothing on the majority of
    /// NPCs.
    ///
    /// It already fires only when the name lookup failed, which is the gate
    /// WO-100.5 asked for. What it lacked was a way to SEE it: every use now
    /// prints MP-DMG with route=guid-fallback and is counted, so a field
    /// session can answer "how often does this fire, and how often does it
    /// land" instead of inferring it.
    ///
    /// DEFAULT TRUE -- true is exactly the behaviour every previous release
    /// had. Setting it false removes the fallback entirely, which is the
    /// experiment this toggle exists to make possible; it has never been run,
    /// so it is not the default.
    /// </summary>
    public bool GuidDamageFallbackEnabled { get; set; } = true;

    /// <summary>
    /// WO-102 Phase 4: the damage-authority holder owns EVERY NPC permanently
    /// (no claims, no proximity, no expiry). Off = the 0.23.2 per-NPC claim
    /// model, exactly. Pushed into the mod at connect as the session's
    /// starting state; flips at runtime from the console
    /// (mp_authority_host_on|off) without a restart.
    ///
    /// SHIPS ON (WO-102 end gate). The 0.23.2 behaviour it replaces is
    /// known-broken from the 2026-09-17 bundles -- claims expiring mid-fight
    /// and 24-97 m divergences -- so leaving it off to guard against an
    /// unproven improvement is the wrong side of the trade; the claim model
    /// stays one console command away (mp_authority_host_off), which is the
    /// actual safety. Synthetic evidence only (109/109); no live session yet.
    /// </summary>
    public bool HostAuthorityEnabled { get; set; } = true;

    /// <summary>
    /// WO-102 Phase 1: read the local position/rotation/riding state through
    /// the DLL pipe (one read per frame, alongside the body state) instead of
    /// the [KCD2-MP-DATA] log line. Off = the 0.23.2 log-tail path. The log
    /// tail keeps running either way (it carries vitals and every event line)
    /// and is the fallback when the pipe refuses.
    ///
    /// SHIPS OFF (WO-102 end gate): the interval comparison it exists for
    /// has not been measured (findings S1.4 runbook). What settles it: two
    /// MP-POSCADENCE windows per path from one solo session with the native
    /// path measurably steadier at p95.
    /// </summary>
    public bool NativePositionEnabled { get; set; } = false;

    /// <summary>
    /// WO-102.5 Phase 2: the agent periodically calls the DLL's batched NPC
    /// scan (pipe 0x0B) around its own position and every peer ghost, and
    /// pushes the resulting name list into the mod as
    /// <c>KCD2MP_ApplyNativeScan(...)</c>. When <c>KCD2MP.wo102.npcScanNative</c>
    /// (mirrored here) is on and the push is fresh, Lua's mp_npc_rescan reads
    /// candidate names from it instead of walking System.GetEntitiesInSphere
    /// per anchor -- the enumerate+read moves to C++, ranking/cap/tracking
    /// stays in Lua (docs/WO-102.5-findings.md Phase 2).
    ///
    /// SHIPS OFF: the known-answer check (native set == Lua set for one
    /// scene) and the cost comparison this toggle exists to earn have not run
    /// live. See docs/WO-102.5-findings.md Phase 2's runbook.
    /// </summary>
    public bool NpcScanNativeEnabled { get; set; } = false;

    /// <summary>
    /// How the agent reads player state from the game.
    ///
    ///   "logtail" — the mod pushes state into kcd.log and the agent tails it.
    ///               No round trips per read, and sv_servername is left alone.
    ///               Needs the mod installed and loaded.
    ///   "http"    — poll the debug API. Always works, costs a round trip per
    ///               read, and hijacks sv_servername for yaw and mount state.
    ///
    /// Defaults to logtail, falling back to http automatically if kcd.log
    /// cannot be found or the emitter never produces a frame.
    /// </summary>
    public string Transport { get; set; } = "logtail";

    /// <summary>
    /// Interval the mod's state emitter is asked to run at, in milliseconds.
    /// Script.SetTimer is frame-bound, so the delivered rate is capped by the
    /// frame rate regardless of what is requested here.
    /// </summary>
    public int EmitIntervalMs { get; set; } = 20;

    /// <summary>
    /// Local port the dice IPC listener binds (see DiceIpcServer). The
    /// launcher polls this to show the dice window; nothing else uses it.
    /// </summary>
    public int DiceIpcPort { get; set; } = 5901;

    /// <summary>
    /// Local port the release-version IPC listener binds (see
    /// VersionIpcServer, WO-19). The launcher polls this after starting the
    /// agent to show the version-mismatch notification.
    /// </summary>
    public int VersionIpcPort { get; set; } = 5902;

    /// <summary>
    /// WO-50: whether to show a Discord Rich Presence status while connected.
    /// Off means DiscordPresence never opens the IPC pipe at all.
    /// </summary>
    public bool DiscordPresenceEnabled { get; set; } = true;

    /// <summary>
    /// WO-50: this project's Discord Application ID. Not a secret — it is
    /// the public identifier Discord's client uses to look up the Rich
    /// Presence art assets and shows up in every Discord user's own client
    /// regardless. Shipped as the real default so a fresh install needs no
    /// configuration; still overridable for anyone running their own fork
    /// under their own Discord application.
    /// </summary>
    public string DiscordClientId { get; set; } = "1541566715140243506";

    /// <summary>
    /// WO-50: the Rich Presence Art Asset key uploaded under this
    /// application (Discord Developer Portal → Rich Presence → Art Assets).
    /// </summary>
    public string DiscordLargeImageKey { get; set; } = "kcd_mp_color_2";

    /// <summary>
    /// WO-50: set by the launcher (--hosting) when it also started the relay
    /// this agent is connecting to, so Discord can show "Hosting" instead of
    /// "Playing". Not derivable from ServerHost alone — a host on a LAN
    /// address looks identical to a joiner pointed at the same address.
    /// </summary>
    public bool IsHosting { get; set; } = false;

    [JsonIgnore]
    public static string DefaultPath =>
        Path.Combine(
            Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory,
            FileName);

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// <summary>
    /// Loads the config, writing a default file if none exists. Never throws:
    /// a malformed or unreadable file falls back to defaults with a warning,
    /// because failing to start over a stray comma is worse than ignoring it.
    /// </summary>
    public static ClientConfig Load(string? path = null)
    {
        path ??= DefaultPath;

        try
        {
            if (!File.Exists(path))
            {
                var fresh = new ClientConfig();
                fresh.Save(path);
                Console.WriteLine($"[config] Wrote defaults to {path}");
                return fresh;
            }

            var config = JsonSerializer.Deserialize<ClientConfig>(File.ReadAllText(path), Options);
            if (config is null)
            {
                Console.WriteLine($"[config] {path} is empty, using defaults.");
                return new ClientConfig();
            }

            Console.WriteLine($"[config] Loaded {path}");
            return config;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[config] Could not read {path} ({ex.Message}); using defaults.");
            return new ClientConfig();
        }
    }

    /// <summary>Writes the config back out. Never throws.</summary>
    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(this, Options));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[config] Could not write {path}: {ex.Message}");
        }
    }

    /// <summary>
    /// Applies command-line overrides on top of the loaded config.
    ///
    /// Both forms are accepted:
    ///   named:      --host 192.168.1.10 --port 7778 --name Henry
    ///               --game-api http://localhost:1403 --no-voice
    ///   positional: &lt;host&gt; &lt;port&gt; &lt;name&gt; &lt;gameApiBase&gt;   (the pre-config form,
    ///               kept so existing shortcuts and the README examples still work)
    /// </summary>
    public void ApplyCommandLine(string[] args)
    {
        // Named flags win, and their presence disables positional parsing so
        // "--port 7778" is never also read as a positional host.
        bool named = args.Any(a => a.StartsWith("--", StringComparison.Ordinal));

        if (named)
        {
            for (int i = 0; i < args.Length; i++)
            {
                // Value flags consume the following argument; bare flags do not.
                string? value = i + 1 < args.Length ? args[i + 1] : null;

                switch (args[i])
                {
                    case "--host" when value is not null:
                        ServerHost = value;
                        i++;
                        break;
                    case "--port" when value is not null:
                        if (int.TryParse(value, out int p)) ServerPort = p;
                        else Console.WriteLine($"[config] --port '{value}' is not a number, keeping {ServerPort}");
                        i++;
                        break;
                    case "--name" when value is not null:
                        PlayerName = value;
                        i++;
                        break;
                    case "--game-api" when value is not null:
                        GameApiBase = value;
                        i++;
                        break;
                    case "--transport" when value is not null:
                        Transport = value;
                        i++;
                        break;
                    case "--dice-ipc-port" when value is not null:
                        if (int.TryParse(value, out int dip)) DiceIpcPort = dip;
                        else Console.WriteLine($"[config] --dice-ipc-port '{value}' is not a number, keeping {DiceIpcPort}");
                        i++;
                        break;
                    case "--version-ipc-port" when value is not null:
                        if (int.TryParse(value, out int vip)) VersionIpcPort = vip;
                        else Console.WriteLine($"[config] --version-ipc-port '{value}' is not a number, keeping {VersionIpcPort}");
                        i++;
                        break;
                    case "--voice":
                        VoiceChatEnabled = true;
                        break;
                    case "--no-voice":
                        VoiceChatEnabled = false;
                        break;
                    case "--guid-damage-fallback":
                        GuidDamageFallbackEnabled = true;
                        break;
                    case "--no-guid-damage-fallback":
                        GuidDamageFallbackEnabled = false;
                        break;
                    case "--weather-sync":
                        WeatherSyncEnabled = true;
                        break;
                    case "--no-weather-sync":
                        WeatherSyncEnabled = false;
                        break;
                    case "--discord":
                        DiscordPresenceEnabled = true;
                        break;
                    case "--no-discord":
                        DiscordPresenceEnabled = false;
                        break;
                    case "--hosting":
                        IsHosting = true;
                        break;
                    case "--authority-host":
                        HostAuthorityEnabled = true;
                        break;
                    case "--no-authority-host":
                        HostAuthorityEnabled = false;
                        break;
                    case "--pos-native":
                        NativePositionEnabled = true;
                        break;
                    case "--no-pos-native":
                        NativePositionEnabled = false;
                        break;
                    case "--npc-scan-native":
                        NpcScanNativeEnabled = true;
                        break;
                    case "--no-npc-scan-native":
                        NpcScanNativeEnabled = false;
                        break;
                    case "--benchmark":
                        // Handled in Program before the agent starts; listed
                        // here so it is not reported as an unknown argument.
                        break;
                    default:
                        Console.WriteLine($"[config] Ignoring unknown or incomplete argument '{args[i]}'");
                        break;
                }
            }
            return;
        }

        if (args.Length > 0) ServerHost = args[0];
        if (args.Length > 1 && int.TryParse(args[1], out int port)) ServerPort = port;
        if (args.Length > 2) PlayerName = args[2];
        if (args.Length > 3) GameApiBase = args[3];
    }
}
