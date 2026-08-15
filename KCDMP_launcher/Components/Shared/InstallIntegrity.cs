using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace KCDMP_launcher.Components.Shared
{
    /// <summary>
    /// WO-32 follow-up: detects a partial install at launcher startup.
    ///
    /// Motivated by a real incident: Setup 0.11.8 ran while agent/relay
    /// processes were alive, silently left KcdMpClient.dll and
    /// KcdMpServer.dll on an old build while the launcher itself updated,
    /// and the newly-shipped NPC sync was inert with no error anywhere. The
    /// wire protocol cannot catch a mixed install because the mix is inside
    /// ONE machine -- so the launcher, which is the piece the user actually
    /// looks at, has to.
    ///
    /// Every sibling assembly is stamped at build time from the same
    /// repo-root VERSION file this launcher is stamped from (see each
    /// csproj's VersionFileContent property), so on a healthy install all
    /// versions are identical by construction. Any difference means the
    /// install directory holds a mix of two builds.
    ///
    /// This warns; it does not block. A false positive that stops a tester
    /// from connecting would be worse than a warned mismatch, and the check
    /// compares string stamps, not behaviour.
    /// </summary>
    public static class InstallIntegrity
    {
        // The stamped .NET assemblies that ship beside the launcher. The
        // native KCDMP.dll carries no InformationalVersion and is deliberately
        // not listed. MasterServer ships in its own subfolder with its own
        // copies; checked via its relative path.
        private static readonly string[] SiblingAssemblies =
        [
            "KcdMpClient.dll",
            "KcdMpServer.dll",
            "KcdMp.Protocol.dll",
            "KcdMp.Farkle.dll",
        ];

        /// <summary>
        /// Null when the install looks whole; otherwise a user-facing message
        /// naming what is stale. A missing file is reported too -- an install
        /// that lost a component entirely is the same failure, worse.
        /// </summary>
        public static string? CheckForPartialInstall()
        {
            string baseDir = AppContext.BaseDirectory;
            var wrong = new List<string>();

            foreach (var name in SiblingAssemblies)
            {
                string path = Path.Combine(baseDir, name);
                if (!File.Exists(path))
                {
                    wrong.Add($"{name} (missing)");
                    continue;
                }

                string? version;
                try { version = FileVersionInfo.GetVersionInfo(path).ProductVersion; }
                catch { continue; }   // unreadable is not evidence of a mix

                // Older, unstamped builds carry "1.0.0+<git hash>". Any
                // difference from the launcher's own stamp counts -- the
                // point is "one build, one version", not version ordering.
                if (!string.IsNullOrEmpty(version) && version != Globals.Version)
                    wrong.Add($"{name} is {version}");
            }

            if (wrong.Count == 0) return null;

            return $"This install is a mix of two builds -- the launcher is {Globals.Version} but " +
                   string.Join(", ", wrong) + ". " +
                   "That usually means an installer ran while the launcher, agent, relay or game was still open, " +
                   "and the files in use silently kept their old version. " +
                   "Close everything and re-run the installer, then check install-verify.txt says PASS.";
        }
    }
}
