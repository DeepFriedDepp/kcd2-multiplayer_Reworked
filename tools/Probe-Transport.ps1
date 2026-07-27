<#
.SYNOPSIS
    Runs the WO-1 transport probes against a running KCD2 and reports what the
    Lua sandbox actually exposes.

.DESCRIPTION
    Sends each block of probe_transport.lua through the game's debug console
    endpoint, then reads the answers back out of kcd.log. No pak rebuild and no
    game restart are needed -- the probes define nothing and persist nothing.

    Requires KCD2 running via the Modding Tools entry with a save loaded.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-Transport.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-Transport.ps1 -ApiBase http://localhost:1404
#>
[CmdletBinding()]
param(
    [string] $ApiBase = 'http://localhost:1403',
    [string] $LuaFile = (Join-Path $PSScriptRoot 'probe_transport.lua'),
    [string] $KcdLog,
    [int]    $SettleMs = 1200
)

$ErrorActionPreference = 'Stop'

function Resolve-KcdLog {
    if ($KcdLog) { return $KcdLog }

    # Same discovery path the agent uses: Steam install dir, then every library
    # root in libraryfolders.vdf.
    $steam = $null
    foreach ($k in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
        } catch { }
    }
    if (-not $steam) { return $null }

    $roots = @($steam)
    $vdf = Join-Path $steam 'config\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"path"\s+"([^"]+)"') {
                $roots += $Matches[1].Replace('\\', '\')
            }
        }
    }
    foreach ($r in $roots) {
        $p = Join-Path $r 'steamapps\common\KingdomComeDeliverance2\kcd.log'
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Invoke-Lua([string] $Lua) {
    Add-Type -AssemblyName System.Web
    $encoded = [System.Web.HttpUtility]::UrlEncode('#' + $Lua)
    $url = "$ApiBase/api/System/Console/ExecuteString?command=$encoded"
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 | Out-Null
}

# --- preflight -------------------------------------------------------------

Write-Host '=== KCD2-MP WO-1 transport probe ===' -ForegroundColor Cyan

try {
    $cal = Invoke-WebRequest -Uri "$ApiBase/api/rpg/Calendar?depth=1" -UseBasicParsing -TimeoutSec 6
} catch {
    Write-Host "FAILED: no debug API at $ApiBase" -ForegroundColor Red
    Write-Host '  Launch KCD2 through the KCD2 Modding Tools entry and load a save.'
    exit 1
}
if ($cal.Content -notmatch 'GameTime="([^"]+)"' -or [double]$Matches[1] -le 0) {
    Write-Host 'FAILED: game is reachable but no save is loaded (GameTime = 0).' -ForegroundColor Red
    Write-Host '  The probes need an in-world context. Load a save and re-run.'
    exit 1
}
Write-Host "Game reachable at $ApiBase, save loaded." -ForegroundColor Green

$logPath = Resolve-KcdLog
if (-not $logPath) {
    Write-Host 'FAILED: could not locate kcd.log. Pass -KcdLog <path>.' -ForegroundColor Red
    exit 1
}
Write-Host "Reading results from $logPath"

if (-not (Test-Path $LuaFile)) {
    Write-Host "FAILED: probe source not found at $LuaFile" -ForegroundColor Red
    exit 1
}

# Only look at lines produced from here on, so repeat runs don't show stale hits.
$startLine = (Get-Content $logPath -ErrorAction SilentlyContinue | Measure-Object -Line).Lines

# --- split the Lua into blocks ---------------------------------------------

$blocks = [ordered]@{}
$name = $null
$buf = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content $LuaFile) {
    if ($line -match '^--@@BLOCK\s+(\S+)') {
        if ($name) { $blocks[$name] = ($buf -join "`n") }
        $name = $Matches[1]
        $buf.Clear()
    } elseif ($name) {
        $buf.Add($line)
    }
}
if ($name) { $blocks[$name] = ($buf -join "`n") }

Write-Host ("Sending {0} probe blocks: {1}" -f $blocks.Count, ($blocks.Keys -join ', '))

foreach ($k in $blocks.Keys) {
    Write-Host "  -> $k" -NoNewline
    try {
        Invoke-Lua $blocks[$k]
        Write-Host '  sent' -ForegroundColor Green
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 250
}

Write-Host "Waiting ${SettleMs}ms for the log to flush..."
Start-Sleep -Milliseconds $SettleMs

# --- collect ---------------------------------------------------------------

$all = Get-Content $logPath
$fresh = if ($all.Count -gt $startLine) { $all[$startLine..($all.Count - 1)] } else { @() }
$hits = $fresh | Where-Object { $_ -match '\[KCD2-MP-PROBE\]' }

if (-not $hits) {
    Write-Host ''
    Write-Host 'No probe output found in kcd.log.' -ForegroundColor Yellow
    Write-Host 'Either the console rejected the chunks, or LogAlways is not reaching this log.'
    exit 2
}

Write-Host ''
Write-Host "=== FINDINGS ($($hits.Count) lines) ===" -ForegroundColor Cyan

# lograte is a burst of 50; summarise rather than print every line.
$rate = $hits | Where-Object { $_ -match 'lograte\.seq=' }
$hits | Where-Object { $_ -notmatch 'lograte\.seq=' } | ForEach-Object {
    if ($_ -match '\[KCD2-MP-PROBE\]\s*(.+)$') { '  ' + $Matches[1] }
}

if ($rate) {
    Write-Host ''
    Write-Host "=== log burst: $($rate.Count)/50 lines reached kcd.log ===" -ForegroundColor Cyan
    $seqs = $rate | ForEach-Object { if ($_ -match 'seq=(\d+)') { [int]$Matches[1] } }
    $ordered = ($seqs -join ',') -eq (($seqs | Sort-Object) -join ',')
    Write-Host ("  ordering preserved: {0}" -f $(if ($ordered) { 'yes' } else { 'NO - reordered' }))
    if ($seqs.Count -lt 50) {
        Write-Host ("  DROPPED {0} of 50 lines" -f (50 - $seqs.Count)) -ForegroundColor Yellow
    }
}

$outFile = Join-Path $PSScriptRoot 'probe-results.txt'
$hits | Set-Content -Path $outFile -Encoding utf8
Write-Host ''
Write-Host "Full output written to $outFile" -ForegroundColor Green
Write-Host 'Paste that file back into the session to decide the transport.' -ForegroundColor Green
