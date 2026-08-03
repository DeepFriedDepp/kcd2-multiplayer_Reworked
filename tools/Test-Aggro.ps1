<#
.SYNOPSIS
    Drives the DLL's agent pipe directly to exercise WO-17's SetFactionHostile
    message -- both attach and, for the first time, detach.

.DESCRIPTION
    Standing in for the C# agent, same idea as Test-Pipe.ps1 for combat: this
    script plays the role GameBridge's TriggerReactiveAggroAsync/
    DetachGhostAggroAsync would, so the native half of reactive aggro can be
    verified without running the full relay + agent + second peer.

    Spawns a fresh ghost with aggro enabled (mp_enable_aggro on, mp_spawn_test),
    reads its own Soul.Guid, sends SetFactionHostile(hostile=1) and verifies
    FactionNode/Parent resolves to the hostile faction over HTTP, then sends
    SetFactionHostile(hostile=0) and verifies Parent reads back null/orphan --
    the detach path's first live exercise, so this checks it deliberately
    rather than assuming the attach path's precedent covers it.

    Requires the game running via Modding Tools, the mod loaded, and KCDMP.dll
    injected (this build, with the SetFactionHostile pipe message).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Aggro.ps1
#>
[CmdletBinding()]
param(
    [string] $GhostId = 'test_ghost'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$SET_FACTION_HOSTILE = 0x04
$RESULT              = 0x81
$PONG                = 0x83
$PING                = 0x03

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
    return New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
}

function ConvertTo-WireGuid([string] $text) {
    $h = ($text -replace '-', '')
    $b = for ($i = 0; $i -lt 32; $i += 2) { [Convert]::ToByte($h.Substring($i, 2), 16) }
    $b = [byte[]]$b
    [byte[]]@($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6]) + $b[8..15]
}

if (-not (Test-KcdApi)) { throw "debug API not answering - is the game running via Modding Tools?" }

Write-Host "1. enabling aggro and spawning a fresh ghost..."
Invoke-KcdApi -Path "/api/System/Console/ExecuteString?command=mp_enable_aggro%20on" | Out-Null
Start-Sleep -Milliseconds 300
Invoke-KcdApi -Path "/api/System/Console/ExecuteString?command=mp_remove_all" | Out-Null
Start-Sleep -Milliseconds 300
Invoke-KcdApi -Path "/api/System/Console/ExecuteString?command=mp_spawn_test" | Out-Null
Start-Sleep -Seconds 2

$soulName = "kcd2mp_$GhostId"
$soulPath = "/api/rpg/SoulList/SoulsByName/$soulName"
$guidText = Get-KcdValue "$soulPath/Guid"
if ($guidText -match '^ERR') { throw "ghost soul '$soulName' not found -- spawn failed?" }
Write-Host "   ghost: $soulName  guid=$guidText"

$wire = ConvertTo-WireGuid $guidText

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'kcdmp', [System.IO.Pipes.PipeDirection]::InOut)
try { $pipe.Connect(3000) } catch { throw "cannot connect to \\.\pipe\kcdmp - is KCDMP.dll injected?" }
Write-Host "2. connected to the DLL pipe"

Send-Frame $pipe $PING $null
$reply = Read-Frame $pipe
Write-Host ("   ping: {0}" -f $(if ($reply -and $reply.Type -eq $PONG) { 'pong' } else { 'NO REPLY' }))

Write-Host "3. SetFactionHostile(hostile=1) -- attach"
$payload = New-Object byte[] 17
[Array]::Copy($wire, 0, $payload, 0, 16)
$payload[16] = 1
Send-Frame $pipe $SET_FACTION_HOSTILE $payload
$res = Read-Frame $pipe
$attachOk = ($res -and $res.Type -eq $RESULT -and $res.Payload[0] -eq 1)
Write-Host ("   result: {0}" -f $(if ($attachOk) { 'applied' } else { 'REFUSED' }))

Start-Sleep -Milliseconds 500
$parentAfterAttach = Get-KcdValue "$soulPath/FactionNode/Parent/Name"
Write-Host "   FactionNode/Parent/Name = '$parentAfterAttach'"
$attachVerified = $parentAfterAttach -eq 'trosecko_enemies_bandits_prepadeniAmbushers_group1'

Write-Host "4. waiting 5s, re-verifying attach held (not just an immediate read-back)..."
Start-Sleep -Seconds 5
$parentHeld = Get-KcdValue "$soulPath/FactionNode/Parent/Name"
Write-Host "   FactionNode/Parent/Name = '$parentHeld'"
$attachHeld = $parentHeld -eq 'trosecko_enemies_bandits_prepadeniAmbushers_group1'

Write-Host "5. SetFactionHostile(hostile=0) -- detach (first live exercise of this path)"
$payload2 = New-Object byte[] 17
[Array]::Copy($wire, 0, $payload2, 0, 16)
$payload2[16] = 0
Send-Frame $pipe $SET_FACTION_HOSTILE $payload2
$res2 = Read-Frame $pipe
$detachOk = ($res2 -and $res2.Type -eq $RESULT -and $res2.Payload[0] -eq 1)
Write-Host ("   result: {0}" -f $(if ($detachOk) { 'applied' } else { 'REFUSED' }))

Start-Sleep -Milliseconds 500
$parentAfterDetach = Get-KcdValue "$soulPath/FactionNode/Parent?depth=0"
Write-Host "   FactionNode/Parent (raw) = '$parentAfterDetach'"
# An orphan Parent renders as an empty <Faction /> element with no Name
# attribute at all -- Get-KcdValue strips tags and returns '(empty)' for that.
$detachVerified = $parentAfterDetach -eq '(empty)'

Write-Host "6. game process / debug API still healthy?"
$healthy = Test-KcdApi
Write-Host "   $healthy"

$pipe.Dispose()

Write-Host ""
Write-Host "attach applied=$attachOk verified=$attachVerified held-after-5s=$attachHeld"
Write-Host "detach applied=$detachOk verified=$detachVerified"
Write-Host "process healthy=$healthy"

if ($attachOk -and $attachVerified -and $attachHeld -and $detachOk -and $detachVerified -and $healthy) {
    Write-Host "`nPASS - attach and detach both applied, verified over a window, process healthy" -ForegroundColor Green
} else {
    Write-Host "`nFAIL - see fields above" -ForegroundColor Red
}
