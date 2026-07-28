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
                    case "--voice":
                        VoiceChatEnabled = true;
                        break;
                    case "--no-voice":
                        VoiceChatEnabled = false;
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
