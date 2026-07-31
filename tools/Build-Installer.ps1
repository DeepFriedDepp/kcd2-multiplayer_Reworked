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

if (-not $SkipPublish) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Publish-Release.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Publish-Release.ps1 failed" }
}

# The .iss embeds this folder wholesale, so an empty or missing one would
# compile happily into an installer that installs nothing.
if (-not (Test-Path (Join-Path $payload "KCDMP_launcher.exe"))) {
    throw "release payload incomplete: $payload\KCDMP_launcher.exe not found (run without -SkipPublish)"
}

$iss = Join-Path $root "installer\KCDMP.iss"
Write-Host "Compiling $iss (version $Version) ..."
& $iscc "/DAppVersion=$Version" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $root "release\KCDMP-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "ISCC reported success but $setup is missing" }

$mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer: $setup ($mb MB)"
