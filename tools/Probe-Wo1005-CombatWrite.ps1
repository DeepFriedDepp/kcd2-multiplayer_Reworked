<#
.SYNOPSIS  WO-100.5 Phase 1 -- drive the first combat write, and read the answer back.
.DESCRIPTION
    Writes one line into the game root's kcdmp-combatwrite.txt and prints the
    new KCDMP.dll log lines it produced. The native side is ONE-SHOT: it fires
    only when the file's contents change, so re-running with the same command
    does nothing on purpose.

    -Inject first injects KCDMP.dll straight from the build directory
    (WO-100 S10's deploy route -- nothing is copied, so the AppData redirect
    never applies) and verifies the LOADED module's ModuleMemorySize against
    the file's SizeOfImage, which is the only admissible check.

.EXAMPLE  powershell -File tools\Probe-Wo1005-CombatWrite.ps1 -Inject
.EXAMPLE  powershell -File tools\Probe-Wo1005-CombatWrite.ps1 -Command 'player flags'
.EXAMPLE  powershell -File tools\Probe-Wo1005-CombatWrite.ps1 -Command 'player setflag 0 1'
.EXAMPLE  powershell -File tools\Probe-Wo1005-CombatWrite.ps1 -Command 'player action 6 1 0'
#>
param(
    [string] $Command,
    [switch] $Inject,
    [switch] $Clear,
    [string] $GameRoot = 'D:\SteamLibrary\steamapps\common\KCD2Mod',
    [string] $Repo     = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$Dll      = Join-Path $Repo 'native\build\KCDMP\KCDMP.dll'
$Injector = Join-Path $Repo 'native\build\KCDMP_LauncherInjector\KCDMP_LauncherInjector.exe'
$Trigger  = Join-Path $GameRoot 'kcdmp-combatwrite.txt'
# Two logs exist: the DLL writes beside itself (inside the repo, when injected
# from the build dir) and mirrors into the game root. Prefer the repo one.
$NativeLog = Join-Path $Repo 'native\build\KCDMP\kcdmp-native.log'
if (-not (Test-Path $NativeLog)) { $NativeLog = Join-Path $GameRoot 'kcdmp-native.mirror.log' }

function Get-GamePid {
    $p = Get-Process -ErrorAction SilentlyContinue |
         Where-Object { $_.ProcessName -match 'KingdomCome|WHGame' } |
         Select-Object -First 1
    if (-not $p) { throw 'No game process found (looked for KingdomCome*/WHGame*).' }
    return $p
}

if ($Inject) {
    $p = Get-GamePid
    Write-Host ("game pid {0} ({1})" -f $p.Id, $p.ProcessName) -ForegroundColor Cyan
    if (-not (Test-Path $Dll)) { throw "KCDMP.dll not built: $Dll" }
    & $Injector --pid $p.Id --dll $Dll
    Start-Sleep -Milliseconds 800

    # The only admissible verification: the LOADED module, never the file.
    $p.Refresh()
    $mod = $p.Modules | Where-Object { $_.ModuleName -eq 'KCDMP.dll' }
    if (-not $mod) { Write-Host 'KCDMP.dll is NOT in the process module list -- injection failed.' -ForegroundColor Red; exit 1 }
    $bytes = [IO.File]::ReadAllBytes($Dll)
    $pe    = [BitConverter]::ToInt32($bytes, 0x3c)
    $sizeOfImage = [BitConverter]::ToInt32($bytes, $pe + 24 + 56)
    Write-Host ("loaded ModuleMemorySize = {0}   file SizeOfImage = {1}   {2}" -f `
        $mod.ModuleMemorySize, $sizeOfImage,
        $(if ($mod.ModuleMemorySize -eq $sizeOfImage) { 'MATCH' } else { 'MISMATCH -- an OLDER KCDMP.dll is loaded' })) `
        -ForegroundColor $(if ($mod.ModuleMemorySize -eq $sizeOfImage) { 'Green' } else { 'Red' })
    Write-Host ("native log: {0}" -f $NativeLog)
    exit 0
}

if ($Clear) {
    Set-Content -Path $Trigger -Value '' -Encoding ascii
    Write-Host "cleared $Trigger" -ForegroundColor Green
    exit 0
}

if (-not $Command) { throw 'Give -Command, -Inject or -Clear.' }

$before = 0
if (Test-Path $NativeLog) { $before = (Get-Content $NativeLog | Measure-Object -Line).Lines }

Set-Content -Path $Trigger -Value $Command -Encoding ascii
Write-Host "fired: $Command" -ForegroundColor Cyan
Start-Sleep -Milliseconds 1500

if (-not (Test-Path $NativeLog)) { Write-Host "no native log at $NativeLog" -ForegroundColor Red; exit 1 }
$lines = Get-Content $NativeLog
$new = $lines | Select-Object -Skip $before
if (-not $new) { Write-Host '  (no new native log lines -- is the DLL injected, and is the trigger file in the game working directory?)' -ForegroundColor Yellow }
$new | Where-Object { $_ -match 'CW' } | ForEach-Object { Write-Host "  $_" }
