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

# WO-32 follow-up: write a size manifest of the payload so the installer can
# verify, after installing, that every file actually landed. Motivated by a
# real half-applied install: Setup 0.11.8 ran while agent/relay processes were
# alive, silently left KcdMpClient.dll and KcdMpServer.dll on an old build,
# and the newly-shipped NPC sync was inert with no error anywhere. The
# manifest is written AFTER publish so it describes exactly what ships, and
# it ships inside the payload itself so the post-install check needs no
# second source of truth. Format: <relative path>|<size>, one per line.
$manifestPath = Join-Path $payload "install-manifest.txt"
Remove-Item $manifestPath -ErrorAction SilentlyContinue   # never list a stale self
$payloadFull = (Get-Item $payload).FullName
$lines = Get-ChildItem $payloadFull -Recurse -File | ForEach-Object {
    "{0}|{1}" -f $_.FullName.Substring($payloadFull.Length + 1), $_.Length
}
Set-Content -Path $manifestPath -Value $lines -Encoding ASCII
Write-Host "Install manifest: $($lines.Count) files"

$iss = Join-Path $root "installer\KCDMP.iss"
Write-Host "Compiling $iss (version $Version) ..."
& $iscc "/DAppVersion=$Version" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $root "release\KCDMP-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "ISCC reported success but $setup is missing" }

$mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer: $setup ($mb MB)"
