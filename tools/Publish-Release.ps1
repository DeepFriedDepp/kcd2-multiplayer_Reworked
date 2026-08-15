<#
.SYNOPSIS
    Assemble a self-contained release folder a friend can unzip and run --
    no .NET runtime install, no manual DLL copying.

.DESCRIPTION
    Publishes KCDMP_launcher, KcdMpClient, KcdMpServer and KcdMpMasterServer
    as self-contained win-x64 (via each project's FolderProfile.pubxml -- see
    docs/WO-7-progress.md for why that's set on the profile and not the
    .csproj), builds the native plugin/injector if not already built, and
    copies everything the launcher's AppSettings defaults expect to find
    beside it (KCDMP.dll, KCDMP_LauncherInjector.exe, KcdMpClient.exe,
    KcdMpServer.exe + their appsettings) into one folder.

    KcdMpMasterServer.exe goes into its own MasterServer\ subfolder instead
    of being flat-merged like the rest (WO-35). Confirmed live: flat-merging
    it let a later Copy-Item -- even a partial one republishing only the
    launcher -- silently overwrite one of its dependency DLLs with an
    incompatible version from another project's own bundle, crashing it with
    "Could not load Microsoft.Extensions.Configuration.Abstractions" on next
    launch. Isolating it removes the hazard rather than requiring every
    future partial update to remember not to trigger it.

    The native DLL statically links its C++ runtime
    (CMAKE_MSVC_RUNTIME_LIBRARY = MultiThreaded in native/CMakeLists.txt), so
    there is no VC++ redistributable to bundle or check for.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Publish-Release.ps1
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot "..\release\KCDMP")
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

if (-not $env:DOTNET_ROOT) {
    $env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
}

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null

# Publishes one project and leaves the output path in $script:PublishDir.
#
# The path comes back through a variable rather than as a return value on
# purpose. Everything a PowerShell function writes to the success stream is
# part of its return value, so logging with Write-Output made the caller
# receive an array of log lines with the path last ("Cannot find drive
# 'Publishing C'"); switching the logging to Write-Host fixed that but sent
# the MSBuild diagnostics somewhere a redirected or background run cannot
# capture, which is exactly when they are needed. This way logs stay on the
# success stream where any caller sees them, and the path is unambiguous.
function Publish-Project($csproj, $publishSubdir) {
    Write-Output "Publishing $csproj ..."
    & dotnet publish $csproj -c Release -p:PublishProfile=FolderProfile 2>&1 | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) { throw "publish failed: $csproj" }
    $dir = Join-Path (Split-Path $csproj -Parent) $publishSubdir
    if (-not (Test-Path $dir)) { throw "expected publish output not found: $dir" }
    $script:PublishDir = $dir
}

# --- Launcher (root of the release: everything else is copied beside it,
#     matching AppSettings' relative-path defaults for DllPath/AgentPath/
#     RelayPath) ---
Publish-Project (Join-Path $root "KCDMP_launcher\KCDMP_launcher.csproj") "bin\Release\net8.0-windows\publish"
$launcherPublish = $script:PublishDir
Copy-Item "$launcherPublish\*" $OutDir -Recurse -Force

# --- Agent ---
Publish-Project (Join-Path $root "dotnet\KcdMp.Client\KcdMp.Client.csproj") "bin\Release\net8.0\publish"
$clientPublish = $script:PublishDir
Copy-Item "$clientPublish\*" $OutDir -Recurse -Force

# --- Relay ---
Publish-Project (Join-Path $root "dotnet\KcdMp.Server\KcdMp.Server.csproj") "bin\Release\net8.0\publish"
$serverPublish = $script:PublishDir
Copy-Item "$serverPublish\*" $OutDir -Recurse -Force

# --- Master server (WO-35): auto-started by the launcher itself, not just
#     the relay -- see AppSettings.MasterServerPath / Home.razor.cs's
#     EnsureLocalMasterServerAsync. Must be present for the default
#     MasterServerUrl (a loopback address) to ever have anything answering it.
#     Its own subfolder, not flat-merged -- see the .SYNOPSIS note above for
#     why; AppModels.cs's MasterServerPath default matches this path. ---
Publish-Project (Join-Path $root "dotnet\KcdMp.MasterServer\KcdMp.MasterServer.csproj") "bin\Release\net8.0\publish"
$masterServerPublish = $script:PublishDir
$masterServerOutDir = Join-Path $OutDir "MasterServer"
New-Item -ItemType Directory -Path $masterServerOutDir -Force | Out-Null
Copy-Item "$masterServerPublish\*" $masterServerOutDir -Recurse -Force

# --- Native plugin + injector ---
$nativeDll = Join-Path $root "native\build\KCDMP\KCDMP.dll"
$nativeInjector = Join-Path $root "native\build\KCDMP_LauncherInjector\KCDMP_LauncherInjector.exe"
if (-not (Test-Path $nativeDll) -or -not (Test-Path $nativeInjector)) {
    Write-Output "Native artifacts missing, building..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root "native\Build-Native.ps1")
}
Copy-Item $nativeDll $OutDir -Force
Copy-Item $nativeInjector $OutDir -Force

Write-Output "`nRelease assembled at: $OutDir"
Write-Output "Contents:"
Get-ChildItem $OutDir -File | Select-Object Name, @{N='KB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table

