using System.Reflection;

namespace KcdMp.Client;

/// <summary>
/// This agent's own release version (WO-19), read from the assembly's
/// InformationalVersion attribute rather than a hardcoded constant. The SDK
/// sets that attribute from the csproj's $(Version), which
/// KcdMp.Client.csproj now reads from the repo-root VERSION file at build
/// time (see the csproj's VersionFileContent property) -- so this is always
/// whatever VERSION said at the moment this exe was built, with no second
/// place to forget to update. VERSION itself is never touched here or by
/// anything this feature adds; see docs/VERSIONING.md.
/// </summary>
public static class ReleaseVersionInfo
{
    public static readonly string Current =
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "0.0.0";
}
