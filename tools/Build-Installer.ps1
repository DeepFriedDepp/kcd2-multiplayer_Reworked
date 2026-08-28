<#
.SYNOPSIS
    One command, one Setup.exe.

.DESCRIPTION
    Runs tools\Publish-Release.ps1 to assemble release\KCDMP, then compiles
    installer\KCDMP.iss with Inno Setup's command-line compiler into
    release\KCDMP-Setup-<version>.exe.

    The version comes from the VERSION file at the repo root and from nowhere
    else: it is stamped into the Setup filename, the installer's Add/Remove
    Programs entry, and the exe's own version resource.

.PARAMETER SkipPublish
    Compile the installer against whatever release\KCDMP already contains.
    Only useful when iterating on the .iss -- a full publish is minutes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
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
    throw "VERSION must be numeric dotted (Inno stamps it into a Win32 version resource), got: '$Version'"
}

function Get-Iscc {
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Inno Setup 6 not found. Install it with: winget install --id JRSoftware.InnoSetup"
}

$iscc = Get-Iscc
Write-Host "Inno Setup compiler: $iscc"

$payload = Join-Path $root "release\KCDMP"

# Rebuild kdcmp.pak from its sources before packaging it. The pak is a build
# artifact that happens to be tracked in git, so without this a release can
# quietly ship a pak that does not match the Lua and XML next to it in the
# repo. -NoInstall: this only rebuilds, it does not touch any game folder.
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Build-And-Install-Mod.ps1") -NoInstall
if ($LASTEXITCODE -ne 0) { throw "Build-And-Install-Mod.ps1 failed (is the game running?)" }

if (-not $SkipPublish) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Publish-Release.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Publish-Release.ps1 failed" }
}

# The .iss embeds this folder wholesale, so an empty or missing one would
# compile happily into an installer that installs nothing.
if (-not (Test-Path (Join-Path $payload "KCDMP_launcher.exe"))) {
    throw "release payload incomplete: $payload\KCDMP_launcher.exe not found (run without -SkipPublish)"
}

# WO-32 follow-up, rewritten in WO-74: write a manifest of everything this
# Setup carries so the installer can prove, after installing, that every file
# actually landed -- and that nothing ELSE is sitting in the install directory
# pretending to belong there.
#
# Motivated by two real incidents:
#   * Setup 0.11.8 ran while agent/relay processes were alive, silently left
#     KcdMpClient.dll and KcdMpServer.dll on an old build, and the
#     newly-shipped NPC sync was inert with no error anywhere (WO-32).
#   * A relay that could not cold-start because the install directory held a
#     Microsoft.Extensions.Configuration.* assembly from a foreign publish
#     -- a file no release ever shipped, so no overwrite could ever fix it
#     and the size-only whitelist could not see it (WO-69, WO-74).
#
# Format (v2, WO-74) -- <kind>|<relative path>|<size>|<sha256>:
#   APP  a file in the install directory, relative to it
#   MOD  a file in <ModdingTools>\Mods\kdcmp, relative to that folder
#
# APP is a CLOSED set: the installer deletes any .dll/.exe/.pdb/.deps.json/
# .runtimeconfig.json in the install directory that is not listed here. MOD
# entries exist because the mod half lands in the game folder, outside the
# install directory, and was previously verified by nothing at all -- an
# install that deployed no pak still reported PASS.
#
# tools\New-InstallManifest.ps1 owns the format; both delivery routes call it.
# It runs AFTER the pak rebuild and AFTER publish, and BEFORE ISCC, so it
# describes exactly the bytes this Setup is about to embed. That order is
# load-bearing: kdcmp.pak is NOT byte-deterministic (same size, different
# sha256 on a rebuild from identical sources -- observed 2026-08-28), so a
# manifest written before a later rebuild describes a pak that no longer
# exists and fails verification on a perfectly good artifact.
& (Join-Path $PSScriptRoot "New-InstallManifest.ps1") `
    -AppDir $payload `
    -ModFiles @{ "mod.manifest"    = (Join-Path $root "kdcmp\mod.manifest")
                 "Data\kdcmp.pak"  = (Join-Path $root "kdcmp\Data\kdcmp.pak") } `
    -OutFile (Join-Path $payload "install-manifest.txt")

$iss = Join-Path $root "installer\KCDMP.iss"
Write-Host "Compiling $iss (version $Version) ..."
& $iscc "/DAppVersion=$Version" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $root "release\KCDMP-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "ISCC reported success but $setup is missing" }

$mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer: $setup ($mb MB)"
