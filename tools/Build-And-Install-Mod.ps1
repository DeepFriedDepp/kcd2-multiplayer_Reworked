<#
.SYNOPSIS
    Rebuilds kdcmp.pak from source and installs the mod into the KCD2 Modding
    Tools instance.

.DESCRIPTION
    The game must be CLOSED: it holds kdcmp.pak open while running, and the
    Modding Tools instance only reads Mods\ at startup.

    Entries are stored uncompressed, matching how the existing pak was built --
    the game's pak loader is happier with stored entries and the file is small
    enough that compression buys nothing.

    Installs to <ModdingTools>\Mods\kdcmp\ as:
        mod.manifest
        Data\kdcmp.pak

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-And-Install-Mod.ps1

.EXAMPLE
    # Rebuild the pak but do not copy it anywhere
    powershell -ExecutionPolicy Bypass -File tools\Build-And-Install-Mod.ps1 -NoInstall
#>
[CmdletBinding()]
param(
    [string] $GameDir,
    [switch] $NoInstall
)

$ErrorActionPreference = 'Stop'

$ScriptDir =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { (Get-Location).Path }

$RepoRoot = Split-Path -Parent $ScriptDir
$SrcRoot  = Join-Path $RepoRoot 'kdcmp\Data'
$PakPath  = Join-Path $SrcRoot 'kdcmp.pak'
$Manifest = Join-Path $RepoRoot 'kdcmp\mod.manifest'

# Paths inside the pak, relative to kdcmp\Data.
$Files = @(
    'Scripts\Startup\kdcmp.lua',
    'Libs\Tables\item\clothing_preset__kdcmp.xml'
)

Write-Host '=== KCD2-MP build and install ===' -ForegroundColor Cyan

# --- the game must be closed -----------------------------------------------

$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'KingdomCome|KCD' }
if ($running) {
    Write-Host 'FAILED: the game is still running.' -ForegroundColor Red
    $running | ForEach-Object { "  pid $($_.Id)  $($_.ProcessName)" }
    Write-Host '  Close it first: the pak is locked while it runs, and Mods\ is only read at startup.'
    exit 1
}

try {
    $null = Invoke-WebRequest -Uri 'http://localhost:1403/api/rpg/Calendar?depth=1' -UseBasicParsing -TimeoutSec 3
    Write-Host 'FAILED: the debug API is still answering on 1403, so the game is up.' -ForegroundColor Red
    exit 1
} catch { }   # not answering is what we want

# --- rebuild the pak --------------------------------------------------------

foreach ($rel in $Files) {
    $full = Join-Path $SrcRoot $rel
    if (-not (Test-Path $full)) {
        Write-Host "FAILED: missing source file $full" -ForegroundColor Red
        exit 1
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $PakPath) { Remove-Item $PakPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($PakPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in $Files) {
        $entry  = $zip.CreateEntry($rel.Replace('\', '/'), [System.IO.Compression.CompressionLevel]::NoCompression)
        $stream = $entry.Open()
        $bytes  = [System.IO.File]::ReadAllBytes((Join-Path $SrcRoot $rel))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        "  packed {0,-50} {1,8:N0} bytes" -f $rel, $bytes.Length
    }
} finally { $zip.Dispose() }

Write-Host ("Built {0} ({1:N0} bytes)" -f $PakPath, (Get-Item $PakPath).Length) -ForegroundColor Green

if ($NoInstall) { Write-Host 'Skipping install (-NoInstall).'; exit 0 }

# --- locate the Modding Tools install ---------------------------------------

if (-not $GameDir) {
    $steam = $null
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam','HKCU:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
        } catch { }
    }
    $roots = @()
    if ($steam) {
        $roots += $steam
        $vdf = Join-Path $steam 'config\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in Get-Content $vdf) {
                if ($line -match '"path"\s+"([^"]+)"') { $roots += $Matches[1].Replace('\\','\') }
            }
        }
    }

    # The Modding Tools entry is its own install and is the one that must be
    # modded; the base game folder will not do. Prefer a folder that looks like
    # the tools install, and require kcd.log to confirm it has actually run.
    $candidates = @()
    foreach ($r in ($roots | Sort-Object -Unique)) {
        $common = Join-Path $r 'steamapps\common'
        if (-not (Test-Path $common)) { continue }
        Get-ChildItem $common -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Kingdom|KCD' } |
            ForEach-Object { $candidates += $_.FullName }
    }
    $GameDir = $candidates | Where-Object { $_ -match 'Mod' } | Select-Object -First 1
    if (-not $GameDir) { $GameDir = $candidates | Select-Object -First 1 }
}

if (-not $GameDir -or -not (Test-Path $GameDir)) {
    Write-Host 'FAILED: could not find the Modding Tools install. Pass -GameDir <path>.' -ForegroundColor Red
    exit 1
}
Write-Host "Installing into $GameDir"

$dest = Join-Path $GameDir 'Mods\kdcmp'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $dest 'Data')

Copy-Item $Manifest (Join-Path $dest 'mod.manifest') -Force
Copy-Item $PakPath  (Join-Path $dest 'Data\kdcmp.pak') -Force

Write-Host 'Installed:' -ForegroundColor Green
Get-ChildItem $dest -Recurse -File | ForEach-Object {
    "  {0,-60} {1,8:N0} bytes" -f $_.FullName.Substring($dest.Length + 1), $_.Length
}

Write-Host ''
Write-Host 'Next: launch KCD2 through the KCD2 Modding Tools entry, load a save,' -ForegroundColor Cyan
Write-Host 'then confirm the mod loaded by looking for this in kcd.log:' -ForegroundColor Cyan
Write-Host '    [KCD2-MP] === MOD INIT ===' -ForegroundColor Cyan
