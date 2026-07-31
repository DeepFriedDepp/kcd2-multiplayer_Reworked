<#
.SYNOPSIS
    End-to-end appearance replication: synthetic peer -> relay -> agent -> ghost.

.DESCRIPTION
    Plays the part of a second player without needing one, the same trick
    Test-CombatE2E.ps1 uses. A synthetic TCP client handshakes with the relay,
    sends one Position packet (so the running agent spawns a real ghost NPC
    for it via KCD2MP_SpawnGhost -- appearance has nothing to apply to until a
    ghost exists), then sends an Appearance packet naming real item-class
    GUIDs -- armor and one weapon (WO-10). The running agent receives it over
    the relay exactly as it would from a real peer, and applies it to the
    synthetic ghost through the native EquipmentManager reflection calls
    proven in WO-9 Phase 0 (armor) and WO-10 (weapons, identical mechanism,
    confirmed live: EquipItem/UnequipItem/CreateItems do not care whether an
    item class is armor or a weapon).

    Verified through the debug REST API: the ghost's own
    EquipmentManager.EquippedArmorsByClassId AND EquippedWeaponsByClassId
    must contain the pushed classes afterward. This is the "two-agent local
    test" from the WO-9 definition of done -- one side is synthetic because
    there is one machine and no second player, exactly the constraint every
    other test script here works around.

    Needs: relay running, agent running and connected to it, game running via
    Modding Tools. No native DLL/injection required -- unlike combat,
    appearance never goes through the pipe; it is REST-only both ends.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-AppearanceE2E.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    # BootsAnkle03 + belt_2slot + GambesonShort02 + HoseSeparate04: four of the
    # five items the live player was actually observed wearing in WO-9 Phase 0.
    # Hood08 is deliberately excluded -- Phase 0 found it does not equip
    # while a Helmet-category item already occupies the head slot, and the
    # ghost's own spawn-time preset (white_red) equips a Bascinet visor before
    # this packet ever arrives. That is a real head-slot exclusivity in the
    # game, not a bug in this sync path -- see docs/WO-9-appearance-sync.md.
    # alias_zachrana_huntingSword (WO-10): a real weapon class read live off
    # the actual player's EquippedWeaponsByClassId, standing in for the
    # weapon-sync path the same way the four armor classes above stand in for
    # the armor path. Confirmed live outside this harness (WO-10 Phase 0)
    # that CreateItems+EquipItem on this exact class equips and reads back on
    # a spawned ghost -- this test exercises the same call through the wire
    # instead of a raw manual probe.
    [string[]] $ItemClasses = @(
        '2a169fbe-251a-49f8-85d1-0b9a651f61d1',
        '7da54a04-67c4-4767-8b60-ee9211cc465e',
        '73b9efe7-4082-4d5a-a879-4b5c7bdc5ea2',
        '993d563a-7a0b-46d9-8aba-5a9d689bfa03',
        'b867dd0e-1bfe-40e9-b114-4b126a3ff1b0'
    ),
    # Measured live (WO-9 Phase 2): under the agent's normal concurrent load
    # the debug API's write path can take up to ~10s to actually commit even
    # though EquipItem returns true immediately -- see GameBridge's
    # VerifyAndRetryAsync. 16s gives that its full retry schedule plus margin.
    [int] $SettleSeconds = 16
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACK = 0xFF; $POSITION = 0x01; $APPEARANCE_UP = 0x1A
$VERSION = 5

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    $head = New-Object byte[] 3; $got = 0
    while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
    while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
}

if (-not (Test-KcdApi)) { throw "debug API not answering (game running via Modding Tools?)" }

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 5000
$nb = [System.Text.Encoding]::UTF8.GetBytes('synthetic-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused (type $($ackPkt.Type)) - relay and agent on the same build?" }
$ghostId = $ackPkt.Payload[0]
Write-Host "peer connected to relay as ghost id $ghostId"

# One Position packet, so the real agent's receive loop spawns a ghost NPC
# for this synthetic peer via KCD2MP_SpawnGhost. Position is near the real
# player's last known spot from Phase 0 so the ghost is easy to find in-game;
# exact placement does not matter to this test.
$posPayload = New-Object byte[] 17
[Array]::Copy([BitConverter]::GetBytes([float]2345.0), 0, $posPayload, 0, 4)
[Array]::Copy([BitConverter]::GetBytes([float]2081.0), 0, $posPayload, 4, 4)
[Array]::Copy([BitConverter]::GetBytes([float]110.7),  0, $posPayload, 8, 4)
[Array]::Copy([BitConverter]::GetBytes([float]0.0),    0, $posPayload, 12, 4)
$posPayload[16] = 0
Send-Packet $s $POSITION $posPayload
Write-Host "sent Position -> agent should spawn ghost 'kcd2mp_$ghostId'"
Start-Sleep -Seconds 2

$classes = $ItemClasses | ForEach-Object { [Guid]::Parse($_) }
$body = New-Object byte[] (1 + $classes.Count * 16)
$body[0] = [byte]$classes.Count
$o = 1
foreach ($g in $classes) {
    [Array]::Copy($g.ToByteArray(), 0, $body, $o, 16)
    $o += 16
}
Send-Packet $s $APPEARANCE_UP $body
Write-Host "sent Appearance: $($classes.Count) item class(es)"

Write-Host "waiting ${SettleSeconds}s for the agent to apply it..."
Start-Sleep -Seconds $SettleSeconds

$soulName = "kcd2mp_$ghostId"
$xml = $null
$missing = @()

# The production design does not give up after one bounded retry burst: a
# real peer keeps sending its (unchanged) equipped set on the heartbeat every
# Protocol.AppearanceHeartbeatSeconds, and the receiver's diff naturally
# retries anything still missing on each one. A synthetic peer has no
# automatic heartbeat of its own, so this loop resends the same Appearance
# packet to stand in for it -- this is what "self-heals eventually" actually
# means for a real connection, not a single deadline.
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $armorXml = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$soulName/EquipmentManager/EquippedArmorsByClassId?depth=1" -MaxBytes 40000
    if ($armorXml -match '^ERR') {
        Write-Host "`nFAIL - ghost '$soulName' not found (agent connected and running against this game?)" -ForegroundColor Red
        $tcp.Close(); exit 1
    }
    # Weapons (WO-10) live in a separate map -- a pushed weapon class will
    # never appear in EquippedArmorsByClassId, so both must be checked.
    $weaponXml = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$soulName/EquipmentManager/EquippedWeaponsByClassId?depth=1" -MaxBytes 40000
    $xml = "$armorXml`n$weaponXml"

    $missing = @()
    foreach ($g in $ItemClasses) {
        if ($xml -notmatch [regex]::Escape($g)) { $missing += $g }
    }
    if ($missing.Count -eq 0) { break }

    if ($attempt -lt 3) {
        Write-Host "attempt $attempt`: $($missing.Count) still missing -- resending Appearance (simulated heartbeat) and waiting ${SettleSeconds}s more..."
        Send-Packet $s $APPEARANCE_UP $body
        Start-Sleep -Seconds $SettleSeconds
    }
}

Write-Host "`n--- ghost EquippedArmorsByClassId + EquippedWeaponsByClassId ---"
Write-Host $xml

if ($missing.Count -eq 0) {
    Write-Host "`nPASS - all $($ItemClasses.Count) pushed item classes are equipped on the ghost" -ForegroundColor Green
} else {
    Write-Host "`nFAIL - $($missing.Count) of $($ItemClasses.Count) pushed item classes never equipped: $($missing -join ', ')" -ForegroundColor Red
}

$tcp.Close()
