<#
.SYNOPSIS
    WO-97 Phase 1: drives the DLL's ConceptProbe (0x08) pipe command, standing
    in for the agent -- same pattern as tools\Probe-LuaClosure.ps1 and
    tools\Probe-GhostIsolate.ps1.

.DESCRIPTION
    READ-ONLY. The DLL enumerates C_ConceptManager's root modules by name (pure
    pointer reads, no engine call) and, when -Path is given, resolves it through
    C_ConceptManager::FindNode and reports node vs null. Nothing is triggered
    and no state is written; C_PortRef::Trigger is not reachable from this
    command.

    The DLL's pipe is created with nMaxInstances = 1 -- ONE client at a time --
    so the agent (KcdMpClient.exe) must be stopped before running this, exactly
    as for the two probes above. Restart it from the launcher afterwards.

    Results are printed by the DLL into the native log, not returned on the
    wire: the interesting payload is many lines of text. This script tails the
    mirror log for you when it can find it.

    Run with no -Path first: enumerating the roots is the half that settles what
    a concept path's FIRST segment must be. WO-96 guessed "Barbora" from the
    save tree's `_Barbora/...` shape and could never confirm it.

.EXAMPLE
    # roots only -- touches no engine code at all
    powershell -ExecutionPolicy Bypass -File tools\Probe-ConceptRead.ps1

.EXAMPLE
    # the known-answer check: the sacks objective on the 2026-09-13 host save
    powershell -ExecutionPolicy Bypass -File tools\Probe-ConceptRead.ps1 `
        -Path 'Barbora.trosecko.socky.hibernable.v_hospode.pytle_a_hadka'
#>
[CmdletBinding()]
param(
    [string] $Path = '',
    [string] $PipeName = 'kcdmp',
    [string] $MirrorLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcdmp-native.mirror.log',
    [int]    $TailLines = 40
)

$ErrorActionPreference = 'Stop'

if ($Path.Length -gt 480) { throw "-Path is $($Path.Length) bytes; the command caps at 480" }

$agent = Get-Process -Name KcdMpClient -ErrorAction SilentlyContinue
if ($agent) {
    Write-Host "KcdMpClient.exe (pid $($agent.Id -join ', ')) is running and holds the pipe." -ForegroundColor Yellow
    Write-Host "The DLL allows one client at a time -- stop the agent, then re-run this." -ForegroundColor Yellow
    exit 2
}

$before = 0
if (Test-Path $MirrorLog) { $before = (Get-Item $MirrorLog).Length }

$payload = [System.Text.Encoding]::UTF8.GetBytes($Path)   # no NUL, may be empty
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
try { $pipe.Connect(5000) }
catch { Write-Host "could not connect to \\.\pipe\$PipeName -- is the game running with KCDMP.dll injected?" -ForegroundColor Red; exit 1 }

# Frame: [type:1][len:2 LE][payload]
$len = $payload.Length
$frame = [byte[]]::new(3 + $len)
$frame[0] = 0x08
$frame[1] = $len -band 0xFF
$frame[2] = ($len -shr 8) -band 0xFF
if ($len) { [Array]::Copy($payload, 0, $frame, 3, $len) }
$pipe.Write($frame, 0, $frame.Length)
$pipe.Flush()

function Read-Exact([System.IO.Pipes.NamedPipeClientStream]$p, [int]$n) {
    $buf = [byte[]]::new($n)
    $off = 0
    while ($off -lt $n) {
        $r = $p.Read($buf, $off, $n - $off)
        if ($r -le 0) { throw "pipe closed after $off/$n bytes" }
        $off += $r
    }
    return $buf
}

$head = Read-Exact $pipe 3
$replyType = $head[0]
$replyLen = $head[1] -bor ($head[2] -shl 8)
$body = if ($replyLen) { Read-Exact $pipe $replyLen } else { [byte[]]::new(0) }
$pipe.Dispose()

if ($replyType -ne 0x81) {
    Write-Host "unexpected reply type 0x$($replyType.ToString('X2'))" -ForegroundColor Red
    exit 1
}
$ok = $body[0] -ne 0
Write-Host ("ConceptProbe(path='{0}') -> {1}" -f $Path, $(if ($ok) { 'ran' } else { 'FAILED' })) `
    -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
Write-Host "The result byte says the probe RAN, not what it found -- the finding is in the log." -ForegroundColor DarkGray

if (Test-Path $MirrorLog) {
    Write-Host "`n--- $MirrorLog (new CONCEPT lines) ---" -ForegroundColor Cyan
    $lines = Get-Content $MirrorLog -Tail $TailLines
    $lines | Where-Object { $_ -match 'CONCEPT|ConceptProbe' } | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "`nmirror log not found at $MirrorLog -- pass -MirrorLog, or read the DLL's own log." -ForegroundColor Yellow
}
