global using Serilog;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;

namespace KCDMP_launcher.Components.Shared
{
    public static class Globals
    {
        public static string AppData { get; } = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        public static string AppFolder { get; } = Path.Combine(AppData, "KCDMP_Launcher");

        public static bool IsMasterOnline { get; set; } = false;

        /// <summary>
        /// WO-19: was a hardcoded "0.1.0", stale against the real shipped
        /// version (VERSION said 0.9.5 at the time this was found). Now read
        /// from the assembly's InformationalVersion, which the csproj sets
        /// from VERSION at build time -- see KCDMP_launcher.csproj's
        /// VersionFileContent property. One source, not two to keep in sync.
        /// </summary>
        public static string Version { get; } =
            Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "0.0.0";
        public static string ConfigFilePath { get; } = Path.Combine(AppFolder, "config.json");

        public static StyleProfile CurrentStyleProfile { get; set; } = new StyleProfile();
        public static short MaxStyleProfilesHistory { get; } = 5;
        public static string StylesHistoryFilePath { get; } = Path.Combine(AppFolder, "style_profiles_history.json");
        public static string StylesProfilesDirectoryPath { get; } = Path.Combine(AppFolder, "StyleProfiles");

        public static event Action? OnStyleChanged;

        public static ModsProfile CurrentModsProfile { get; set; } = new ModsProfile();
        public static string ModsProfilesFilePath { get; } = Path.Combine(AppFolder, "mods_profiles.json");
        public static string ModsProfilesDirectoryPath { get; } = Path.Combine(AppFolder, "ModsProfiles");


        static Globals()
        {
            // Ensure the application folder exists
            if (!Directory.Exists(AppFolder))
            {
                Directory.CreateDirectory(AppFolder);
            }
        }
        public static void NotifyStyleChanged()
        {
            OnStyleChanged?.Invoke();
        }
    }
}
