<#
.SYNOPSIS
    WO-68: drives the DLL's GhostIsolate (0x07) pipe command directly, standing
    in for the agent -- same pattern as tools\Probe-LuaClosure.ps1 and
    tools\Test-Pipe.ps1.

.DESCRIPTION
    Applies (default) or removes the seven civic-isolation script contexts on a
    locally-spawned ghost, and reports the DLL's own verdict. The per-context
    readback lines land in kcdmp-native.log (mirrored into the game root as
    kcdmp-native.mirror.log) as "SCTX: isolate <name>: ..." -- read those, not
    just the boolean here: a false result can mean "the soul is not spawned
    yet", which is routine, or "the feature disarmed after a fault", which is
    not.

    The soul identity is the ghost's own Soul.Guid, resolved by name through the
    debug REST API exactly as the agent does, and byte-reordered into the
    game's in-memory form the same way Test-Pipe does.

    Requires the game running with KCDMP.dll injected AND no agent attached --
    the DLL's pipe accepts one client at a time, so KcdMpClient.exe must not be
    connected while this runs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-GhostIsolate.ps1 -GhostId test_ghost

.EXAMPLE
    # Take the contexts back off again
    powershell -ExecutionPolicy Bypass -File tools\Probe-GhostIsolate.ps1 -GhostId test_ghost -Off
#>
[CmdletBinding()]
param(
    [string] $GhostId = 'test_ghost',
    [switch] $Off,
    [string] $PipeName = 'kcdmp'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

# The wire carries the guid in the game's in-memory byte order: the text form
# with the first three fields byte-reversed (Test-Pipe.ps1's ConvertTo-WireGuid).
function ConvertTo-WireGuid([string] $text) {
    $h = ($text -replace '-', '')
    $bl = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt 32; $i += 2) { $bl.Add([Convert]::ToByte($h.Substring($i, 2), 16)) }
    $b = $bl.ToArray()
    [byte[]]@($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6]) + $b[8..15]
}

if (-not (Test-KcdApi)) { throw "debug API not answering - is the game running via Modding Tools?" }

$soulName = "kcd2mp_$GhostId"
$guidText = Get-KcdValue "/api/rpg/SoulList/SoulsByName/$([uri]::EscapeDataString($soulName))/Guid"
if ($guidText -match '^ERR') { throw "soul '$soulName' not found - is that ghost spawned?" }
Write-Host "target : $soulName  guid=$guidText  on=$(-not $Off)"

$wire = ConvertTo-WireGuid $guidText
$payload = [byte[]]::new(17)
[Array]::Copy($wire, 0, $payload, 0, 16)
$payload[16] = if ($Off) { 0 } else { 1 }

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
try { $pipe.Connect(5000) }
catch { throw "cannot connect to \\.\pipe\$PipeName - is KCDMP.dll injected, and is the agent disconnected? (one client at a time)" }

# Frame: [type:1][len:2 LE][payload]
$frame = [byte[]]::new(3 + $payload.Length)
$frame[0] = 0x07
$frame[1] = $payload.Length -band 0xFF
$frame[2] = ($payload.Length -shr 8) -band 0xFF
[Array]::Copy($payload, 0, $frame, 3, $payload.Length)
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
$len  = [int]$head[1] -bor ([int]$head[2] -shl 8)
$body = if ($len -gt 0) { Read-Exact $pipe $len } else { [byte[]]::new(0) }
$pipe.Dispose()

if ($head[0] -ne 0x81) { throw ("unexpected reply type 0x{0:X2}" -f $head[0]) }
$ok = $body[0] -ne 0
Write-Host ("result : {0} (seq {1})" -f ($(if ($ok) { 'all seven in state' } else { 'NOT fully applied' })), $body[1])
Write-Host "Read the SCTX lines in kcdmp-native.log for the per-context readback."
if (-not $ok) { exit 1 }
