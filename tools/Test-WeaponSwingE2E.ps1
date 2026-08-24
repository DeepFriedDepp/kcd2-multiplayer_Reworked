<#
.SYNOPSIS
    WO-47 E2E: synthetic peer whose ghost carries a CHOSEN weapon, then swings.

    Extends WO-39/46's Test-CombatVizE2E with one step: after the ghost
    spawns, the peer sends an Appearance packet (0x1A) carrying the standard
    ghost armor preset plus -WeaponGuid. The agent equips it on the ghost
    (replacing the preset longsword via the normal WO-10 diff), and the
    following swing events must then resolve through the WO-47 catalog to that
    weapon's own fragment rows -- watch the agent console for
    "[combatviz] ghost N swing as <class>: <spec>" and the ghost for the swing.

    A human at the machine says whether the swings rendered; this script can
    only prove the packets flowed.

.EXAMPLE
    # mace (default):
    powershell -ExecutionPolicy Bypass -File tools\Test-WeaponSwingE2E.ps1 -RelayPort 7778
    # axe:
    powershell -File tools\Test-WeaponSwingE2E.ps1 -WeaponGuid 1fc42528-2bef-4dde-bf8a-04febeef41c8 -WeaponLabel axeWork01
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    # 7778 = the launcher-hosted relay's actual TCP port (WO-46 trap: 5273 is
    # its Kestrel HTTP endpoint and hangs a raw TCP client).
    [int]    $RelayPort = 7778,
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [string] $WeaponGuid = 'cff7ae16-d134-41bd-9394-89e8c3970f94',  # maceClub
    [string] $WeaponLabel = 'maceClub',
    [int]    $ListenSeconds = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')

$HANDSHAKE = 0x00; $POSITION = 0x01; $ACK_TYPE = 0xFF
$COMBAT_UP = 0x2C; $APPEARANCE_UP = 0x1A
$EVT_NAMES = @{ 0 = 'draw'; 1 = 'sheathe'; 2 = 'swing'; 3 = 'block' }

# The ghost armor preset the agent seeds every ghost's diff with (GameBridge.
# GhostSpawnPresetItems minus its longsword) -- sent so the ghost keeps its
# armor and ONLY the weapon changes.
$presetArmor = @(
    'a8b22da0-e42e-4d79-abe7-52e6eebad6eb', # LegsBrigandine04
    'cc1adb78-fa5a-45c9-be7b-b7b50e182cb3', # LegsPadded01
    '36a701ed-2144-452a-b113-385efba2c0d1', # knackersGloves
    '46b051c4-d4e2-4f3a-8b88-e3f64dae4618', # GambesonLong01
    '1aadf1e5-c37b-41c3-bc65-354187022c91', # Brigandine10
    'a5322fcd-27b4-4f4e-bfbf-49c519c74c74', # ArmPlate04
    'cfc1fd72-dbb7-49a4-8713-6acf215a72be', # CoifMail01
    'b6fe59ec-c854-402a-848e-a77f55661c19', # BascinetVisor05
    'a06cfbf0-3d59-4003-89d4-69a82eb735af'  # BootsKnee03
)

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    try {
        $head = New-Object byte[] 3; $got = 0
        while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
        $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
        $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
        while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
        New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
    } catch [System.IO.IOException] { $null }
}

function Get-PlayerPos {
    $line = Get-Content $KcdLog -Tail 400 | Where-Object { $_ -match '\[KCD2-MP-DATA\] v2 ' } | Select-Object -Last 1
    if (-not $line) { return $null }
    $f = ($line -replace '.*\[KCD2-MP-DATA\] ', '') -split ' '
    New-Object psobject -Property @{ X = [float]$f[3]; Y = [float]$f[4]; Z = [float]$f[5]; Rot = [float]$f[6] }
}

function Send-Position($stream, [float]$x, [float]$y, [float]$z, [float]$rot) {
    $p = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes($x), 0, $p, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($y), 0, $p, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes($z), 0, $p, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes($rot), 0, $p, 12, 4)
    $p[16] = 0
    Send-Packet $stream $POSITION $p
}

function Send-Appearance($stream, [string[]] $guids) {
    $p = New-Object byte[] (1 + 16 * $guids.Count)
    $p[0] = [byte]$guids.Count
    for ($i = 0; $i -lt $guids.Count; $i++) {
        [Array]::Copy([guid]::Parse($guids[$i]).ToByteArray(), 0, $p, 1 + 16 * $i, 16)
    }
    Send-Packet $stream $APPEARANCE_UP $p
}

$pp = Get-PlayerPos
if (-not $pp) { throw "no [KCD2-MP-DATA] v2 line in $KcdLog -- is the game + emitter up?" }
Write-Host ("player at {0:F1},{1:F1},{2:F1} -- ghost will stand 2 m away" -f $pp.X, $pp.Y, $pp.Z)
Write-Host ("test weapon: {0} ({1})" -f $WeaponLabel, $WeaponGuid)

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $RelayPort)
$s = $tcp.GetStream(); $s.ReadTimeout = 150
# Same peer name as WO-39/46's harness: hashes MALE, so the ghost can hold weapons.
$nb = [System.Text.Encoding]::UTF8.GetBytes('wo39-combat-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$s.ReadTimeout = 8000
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK_TYPE) { throw "handshake refused" }
Write-Host "connected as ghost id $([int]$ackPkt.Payload[0])"
$s.ReadTimeout = 100

# Appearance goes out at 8s (ghost needs to exist first -- it spawns off the
# early positions); the equip + verify loop needs a few seconds after that,
# so combat starts at 35s.
$schedule = @(
    @{ At = 35; Evt = 0 },   # draw
    @{ At = 40; Evt = 2 },   # swing (rotation: row 1)
    @{ At = 45; Evt = 2 },   # swing (rotation: row 2)
    @{ At = 50; Evt = 2 },   # swing (rotation: row 1 again)
    @{ At = 55; Evt = 1 }    # sheathe
)
$sent = @{}
$appearanceSent = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastPos = [DateTime]::MinValue
$seqEnd = 57

Write-Host "`n--- FIND THE GHOST NOW (2 m east of you) ---"
Write-Host "--- weapon swap @8s, draw @35s, swings @40/45/50s, sheathe @55s ---"
Write-Host "--- watch: does each swing render with the $WeaponLabel? ---`n"

while ($sw.Elapsed.TotalSeconds -lt ($seqEnd + $ListenSeconds)) {
    if (([DateTime]::UtcNow - $lastPos).TotalMilliseconds -ge 100) {
        $lastPos = [DateTime]::UtcNow
        $cur = Get-PlayerPos
        if ($cur) { $pp = $cur }
        Send-Position $s ($pp.X + 2.0) ($pp.Y) ($pp.Z) ($pp.Rot)
    }
    if (-not $appearanceSent -and $sw.Elapsed.TotalSeconds -ge 8) {
        $appearanceSent = $true
        Send-Appearance $s ($presetArmor + $WeaponGuid)
        Write-Host ("[{0,5:F1}s] SENT appearance: preset armor + {1}" -f $sw.Elapsed.TotalSeconds, $WeaponLabel)
    }
    foreach ($step in $schedule) {
        if (-not $sent[$step.At] -and $sw.Elapsed.TotalSeconds -ge $step.At) {
            $sent[$step.At] = $true
            Send-Packet $s $COMBAT_UP ([byte[]]@([byte]$step.Evt))
            Write-Host ("[{0,5:F1}s] SENT {1}" -f $sw.Elapsed.TotalSeconds, $EVT_NAMES[$step.Evt])
        }
    }
    $null = Read-Packet $s
}
$tcp.Close()
Write-Host "`ndone. Check the agent console for '[combatviz] ghost N swing as ...' lines."
