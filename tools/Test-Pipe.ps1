<#
.SYNOPSIS
    Drives the DLL's agent pipe directly, standing in for the agent.

.DESCRIPTION
    Proves the inbound half of combat replication without a second player, a
    second copy of the game, or the agent existing yet: this script plays the
    role a remote peer's damage would, and the effect is verified against the
    debug REST API.

    Requires the game running via Modding Tools with KCDMP.dll injected.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Pipe.ps1 -SoulName ttkc_man_32
#>
[CmdletBinding()]
param(
    [string] $SoulName = 'ttkc_man_32',
    [float]  $Health = 4.0,
    [switch] $Kill
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$APPLY_DAMAGE = 0x01
$APPLY_DEATH  = 0x02
$PING         = 0x03
$RESULT       = 0x81
$PONG         = 0x83

function Send-Frame($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3)
    if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Frame($stream) {
    $head = New-Object byte[] 3
    $got = 0
    while ($got -lt 3) {
        $n = $stream.Read($head, $got, 3 - $got)
        if ($n -le 0) { return $null }
        $got += $n
    }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len, 1))
    $got = 0
    while ($got -lt $len) {
        $n = $stream.Read($body, $got, $len - $got)
        if ($n -le 0) { return $null }
        $got += $n
    }
    # New-Object emits the array it creates when $len is 0, which polluted the
    # return value and made a valid Pong read as "no reply".
    return New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
}

# The wire carries the guid in the game's in-memory byte order, which is the
# text form with the first three fields byte-reversed.
function ConvertTo-WireGuid([string] $text) {
    $h = ($text -replace '-', '')
    $b = for ($i = 0; $i -lt 32; $i += 2) { [Convert]::ToByte($h.Substring($i, 2), 16) }
    $b = [byte[]]$b
    [byte[]]@($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6]) + $b[8..15]
}

if (-not (Test-KcdApi)) { throw "debug API not answering - is the game running via Modding Tools?" }

$soulPath = "/api/rpg/SoulList/SoulsByName/$([uri]::EscapeDataString($SoulName))"
$guidText = Get-KcdValue "$soulPath/Guid"
if ($guidText -match '^ERR') { throw "soul '$SoulName' not found" }
$before = Get-KcdValue "$soulPath/GetState?State=health"
Write-Host "target : $SoulName  guid=$guidText  health=$before"

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'kcdmp', [System.IO.Pipes.PipeDirection]::InOut)
try { $pipe.Connect(3000) } catch { throw "cannot connect to \\.\pipe\kcdmp - is KCDMP.dll injected?" }
Write-Host "connected to the DLL pipe"

Send-Frame $pipe $PING $null
$reply = Read-Frame $pipe
Write-Host ("ping   : {0}" -f $(if ($reply -and $reply.Type -eq $PONG) { 'pong' } else { 'NO REPLY' }))

$wire = ConvertTo-WireGuid $guidText

if ($Kill) {
    Send-Frame $pipe $APPLY_DEATH $wire
} else {
    $payload = New-Object byte[] 25
    [Array]::Copy($wire, 0, $payload, 0, 16)
    [Array]::Copy([BitConverter]::GetBytes([float]0.0),     0, $payload, 16, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]$Health), 0, $payload, 20, 4)
    $payload[24] = 1   # suppress hit reaction
    Send-Frame $pipe $APPLY_DAMAGE $payload
}

$res = Read-Frame $pipe
Write-Host ("result : {0}" -f $(if ($res -and $res.Type -eq $RESULT) {
    if ($res.Payload[0] -eq 1) { 'applied' } else { 'refused (soul not loaded?)' }
} else { 'NO REPLY' }))

Start-Sleep -Milliseconds 600
$after = Get-KcdValue "$soulPath/GetState?State=health"
$dead  = Get-KcdValue "$soulPath/IsDead"
Write-Host "health : $before -> $after   IsDead=$dead"

$applied = ($res -and $res.Type -eq $RESULT -and $res.Payload[0] -eq 1)
$moved   = ([double]$after -lt [double]$before) -or ($dead -eq 'true')
if ($applied -and $moved) { Write-Host "`nPASS - a remote peer's damage reached the game" -ForegroundColor Green }
else                      { Write-Host "`nFAIL - no observable effect" -ForegroundColor Red }

$pipe.Dispose()
