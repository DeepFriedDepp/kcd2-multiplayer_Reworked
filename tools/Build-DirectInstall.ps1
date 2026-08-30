<#
.SYNOPSIS
    Build release\KCDMP-DirectInstall-<version>.zip -- the update-only zip a
    player who already has the mod installed unpacks over the top, instead of
    re-running Setup.exe.

.DESCRIPTION
    The zip holds exactly two folders, and the split matches the two places
    Setup.exe writes to:

      App\  -> %LocalAppData%\KCDMP
               The whole tools\Publish-Release.ps1 output (launcher, agent,
               relay, KCDMP.dll, the injector, and the self-contained .NET
               runtime beside them). The install root is DefaultDirName in
               installer\KCDMP.iss -- that file is the source of truth if it
               ever moves.

      Mod\  -> <KCD2 Modding Tools>\Mods\kdcmp
               mod.manifest and Data\kdcmp.pak, and DELIBERATELY NOTHING ELSE.
               kdcmp\Data\ also holds the pak's *sources* (Libs\Tables\...,
               Libs\Config\..., Scripts\Startup\..., Scripts\KCD2MP\...). Shipping those
               loose breaks the game outright: a loose Data\Libs\Tables inside
               a mod takes over the engine's table root and every base table
               fails to resolve ("114 tables are not loaded"). The [Files]
               section of installer\KCDMP.iss ships these same two files and
               only these two, for the same reason -- keep the two in step.

    The version comes from the VERSION file at the repo root and from nowhere
    else, the same way tools\Build-Installer.ps1 reads it, so the two build
    steps cannot drift apart on version number.

    Version numbers are the user's call, never a session's -- see
    docs\VERSIONING.md before changing VERSION or running this.

.PARAMETER SkipPublish
    Zip whatever release\KCDMP already contains instead of republishing.
    Use this right after tools\Build-Installer.ps1, which has just published
    that folder itself -- a full publish is minutes.

.PARAMETER Version
    Override the VERSION file. For rebuilding an older zip; normal runs should
    not pass this.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-DirectInstall.ps1

.EXAMPLE
    # Straight after Build-Installer.ps1, which already published release\KCDMP
    powershell -ExecutionPolicy Bypass -File tools\Build-DirectInstall.ps1 -SkipPublish
#>
param(
    [switch]$SkipPublish,
    [string]$Version
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

if (-not $Version) {
    $versionFile = Join-Path $root "VERSION"
    if (-not (Test-Path $versionFile)) { throw "VERSION file not found at $versionFile" }
    $Version = (Get-Content $versionFile -TotalCount 1).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "VERSION must be numeric dotted (it matches the Setup.exe built beside it), got: '$Version'"
}

$payload = Join-Path $root "release\KCDMP"

# Same reason Build-Installer.ps1 does this: kdcmp.pak is a build artifact that
# happens to be tracked in git, so without a rebuild the zip can ship a pak
# that does not match the Lua and XML next to it in the repo. -NoInstall: this
# only rebuilds, it does not touch any game folder.
#
# WO-74: NOT under -SkipPublish. That switch means "package what
# Build-Installer.ps1 just built", and kdcmp.pak is not byte-deterministic --
# rebuilding it here gives the zip a different pak from the one embedded in
# the Setup.exe built moments earlier, under the same version number. The two
# artifacts stay byte-identical only if this step is skipped with the publish.
if (-not $SkipPublish) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Build-And-Install-Mod.ps1") -NoInstall
    if ($LASTEXITCODE -ne 0) { throw "Build-And-Install-Mod.ps1 failed (is the game running?)" }
}

if (-not $SkipPublish) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Publish-Release.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Publish-Release.ps1 failed" }
}

# An empty or missing payload folder would zip happily into an update that
# updates nothing.
if (-not (Test-Path (Join-Path $payload "KCDMP_launcher.exe"))) {
    throw "release payload incomplete: $payload\KCDMP_launcher.exe not found (run without -SkipPublish)"
}

$staging = Join-Path $env:TEMP "kcdmp-directinstall-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $staging "App") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $staging "Mod\Data") | Out-Null

Write-Host "Staging App\ from $payload ..."
Copy-Item "$payload\*" (Join-Path $staging "App") -Recurse -Force

Write-Host "Staging Mod\ (mod.manifest + Data\kdcmp.pak only) ..."
foreach ($pair in @(
    @{ From = "kdcmp\mod.manifest";    To = "Mod" },
    @{ From = "kdcmp\Data\kdcmp.pak";  To = "Mod\Data" }
)) {
    $src = Join-Path $root $pair.From
    if (-not (Test-Path $src)) { throw "mod file missing: $src" }
    Copy-Item $src (Join-Path $staging $pair.To) -Force
}

# Generated from what was actually staged, not copied from the payload. The
# payload's own manifest describes the pak that Build-Installer.ps1 embedded;
# a standalone run of this script republishes (which wipes release\KCDMP,
# manifest included) and may rebuild the pak to different bytes. Regenerating
# here makes the zip self-consistent however it was reached.
& (Join-Path $PSScriptRoot "New-InstallManifest.ps1") `
    -AppDir (Join-Path $staging "App") `
    -ModFiles @{ "mod.manifest"   = (Join-Path $staging "Mod\mod.manifest")
                 "Data\kdcmp.pak" = (Join-Path $staging "Mod\Data\kdcmp.pak") } `
    -OutFile (Join-Path $staging "App\install-manifest.txt")

# WO-74: the zip now carries its own applier. "Unpack it over the top" is the
# instruction that produces a half-applied install -- Explorer merges folders,
# silently skips whatever is in use, and reports success. Apply.ps1 does what
# Setup does instead: gate on running processes, copy, remove files no release
# ships, verify every component by sha256, and exit non-zero if anything is
# wrong. Setup.exe grew that in WO-32 and WO-74; this route had none of it.
Write-Host "Staging Apply.ps1 ..."
Copy-Item (Join-Path $PSScriptRoot "Apply-DirectInstall.ps1") (Join-Path $staging "Apply.ps1") -Force
Set-Content -Path (Join-Path $staging "README.txt") -Encoding ASCII -Value @"
KCD2 Multiplayer $Version -- update-only package

Close the launcher, the agent, the relay, the master server and the game
first. Then, from this folder:

    powershell -ExecutionPolicy Bypass -File Apply.ps1

Apply.ps1 copies both halves into place, removes files that this release does
not ship, checks every component by sha256, and tells you -- loudly, and with
a non-zero exit code -- if anything did not land. It writes its verdict to
install-verify.txt in the install folder.

Copying App\ and Mod\ over the top by hand still works, but nothing checks it
and a file that was in use is skipped in silence. That is how an install ends
up half applied. Use Apply.ps1, or the full Setup.exe.

  App\  -> the install folder (%LocalAppData%\KCDMP by default)
  Mod\  -> <KCD2 Modding Tools>\Mods\kdcmp
"@

$zip = Join-Path $root "release\KCDMP-DirectInstall-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging "App"), (Join-Path $staging "Mod"),
                       (Join-Path $staging "Apply.ps1"), (Join-Path $staging "README.txt") `
                 -DestinationPath $zip -CompressionLevel Optimal

Remove-Item $staging -Recurse -Force

if (-not (Test-Path $zip)) { throw "Compress-Archive reported success but $zip is missing" }

$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ""
Write-Host "DirectInstall zip: $zip ($mb MB)"
Write-Host "  App\  -> %LocalAppData%\KCDMP"
Write-Host "  Mod\  -> <KCD2 Modding Tools>\Mods\kdcmp"
