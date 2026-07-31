<#
.SYNOPSIS
    Assemble a self-contained release folder a friend can unzip and run --
    no .NET runtime install, no manual DLL copying.

.DESCRIPTION
    Publishes KCDMP_launcher, KcdMpClient and KcdMpServer as self-contained
    win-x64 (via each project's FolderProfile.pubxml -- see
    docs/WO-7-progress.md for why that's set on the profile and not the
    .csproj), builds the native plugin/injector if not already built, and
    copies everything the launcher's AppSettings defaults expect to find
    beside it (KCDMP.dll, KCDMP_LauncherInjector.exe, KcdMpClient.exe,
    KcdMpServer.exe + its appsettings) into one folder.

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

function Publish-Project($csproj, $publishSubdir) {
    # Everything progress-ish goes to the host stream, never the success
    # stream: this function's return value is a path, and a single stray
    # Write-Output turns that return into an array whose first element is a
    # log line ("Cannot find drive 'Publishing C'").
    #
    # dotnet's own output is teed rather than left to stream straight through,
    # so a failure carries its MSBuild diagnostics even when this runs
    # non-interactively -- that is how a broken FolderProfile.pubxml managed to
    # report nothing but "publish failed".
    Write-Host "Publishing $csproj ..."
    $log = & dotnet publish $csproj -c Release -p:PublishProfile=FolderProfile 2>&1
    $log | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "publish failed: $csproj" }
    $publishDir = Join-Path (Split-Path $csproj -Parent) $publishSubdir
    if (-not (Test-Path $publishDir)) { throw "expected publish output not found: $publishDir" }
    return $publishDir
}

# --- Launcher (root of the release: everything else is copied beside it,
#     matching AppSettings' relative-path defaults for DllPath/AgentPath/
#     RelayPath) ---
$launcherPublish = Publish-Project (Join-Path $root "KCDMP_launcher\KCDMP_launcher.csproj") "bin\Release\net8.0-windows\publish"
Copy-Item "$launcherPublish\*" $OutDir -Recurse -Force

# --- Agent ---
$clientPublish = Publish-Project (Join-Path $root "dotnet\KcdMp.Client\KcdMp.Client.csproj") "bin\Release\net8.0\publish"
Copy-Item "$clientPublish\*" $OutDir -Recurse -Force

# --- Relay ---
$serverPublish = Publish-Project (Join-Path $root "dotnet\KcdMp.Server\KcdMp.Server.csproj") "bin\Release\net8.0\publish"
Copy-Item "$serverPublish\*" $OutDir -Recurse -Force

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
