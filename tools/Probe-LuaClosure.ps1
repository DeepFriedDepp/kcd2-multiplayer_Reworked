<#
.SYNOPSIS
    WO-20 Phase 2 scratch probe: drives the DLL's new ResolveLuaClosure (0x05)
    pipe command directly, standing in for the agent -- same pattern as
    tools\Test-Aggro.ps1.

.DESCRIPTION
    Sends a Lua closure address (as printed by tostring(luaFn), hex, no
    0x prefix in this build) and prints back what the DLL's lua_closure.cpp
    resolved: the native callback address, which module it lives in, the RVA,
    a best-effort name string, and the first 48 bytes of the callback's own
    prologue for manual decoding.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-LuaClosure.ps1 -ClosureHex 000001EAC4365640
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $ClosureHex,
    [string] $PipeName = 'kcdmp'
)

$ErrorActionPreference = 'Stop'

$addr = [Convert]::ToUInt64($ClosureHex, 16)
$addrBytes = [BitConverter]::GetBytes($addr)  # little-endian on x64, matches the wire format

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(5000)

# Frame: [type:1][len:2 LE][payload]
$type = 0x05
$len = $addrBytes.Length
$frame = [byte[]]::new(3 + $len)
$frame[0] = $type
$frame[1] = $len -band 0xFF
$frame[2] = ($len -shr 8) -band 0xFF
[Array]::Copy($addrBytes, 0, $frame, 3, $len)
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
$body = Read-Exact $pipe $replyLen
$pipe.Dispose()

if ($replyType -ne 0x84) { Write-Host "unexpected reply type 0x$($replyType.ToString('X2'))" -ForegroundColor Red; exit 1 }

$o = 0
$ok = $body[$o]; $o += 1
$nativeAddr = [BitConverter]::ToUInt64($body, $o); $o += 8
$rva = [BitConverter]::ToUInt32($body, $o); $o += 4

function Read-Str([byte[]]$b, [ref]$off) {
    $n = $b[$off.Value]; $off.Value += 1
    if ($n -eq 0) { return "" }
    $s = [System.Text.Encoding]::ASCII.GetString($b, $off.Value, $n)
    $off.Value += $n
    return $s
}
$offRef = [ref]$o
$moduleName = Read-Str $body $offRef
$name = Read-Str $body $offRef
$prologueHex = Read-Str $body $offRef

Write-Host "ok           : $([bool]$ok)"
Write-Host "nativeAddr   : 0x$($nativeAddr.ToString('X'))"
Write-Host "module       : $moduleName + 0x$($rva.ToString('X'))"
Write-Host "name         : $name"
Write-Host "prologue     : $prologueHex"
