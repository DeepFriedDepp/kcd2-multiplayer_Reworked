<#
.SYNOPSIS
    Answers two different questions that are easy to confuse: did the build
    produce the right files, and did the installer actually put them on disk.

.DESCRIPTION
    Written in WO-34 after a 0.11.8 install turned out to be half-applied --
    the mod pak updated, the agent did not -- which made WO-32's NPC sync a
    silent no-op: the Lua half was present and waiting, the agent half was a
    build old and never called it. Nothing errored. Nothing looked wrong.

    Three layers are checked independently, because a failure in any one of
    them looks identical from the game:

      BUILT     release\KCDMP\*        what Publish-Release.ps1 produced
      SHIPPED   kdcmp\Data\kdcmp.pak   what Build-And-Install-Mod.ps1 produced
      INSTALLED %LocalAppData%\KCDMP   what the player's machine is running
                <ModdingTools>\Mods\kdcmp\Data\kdcmp.pak

    Feature presence is probed by string literal, not by version number. A
    .NET assembly keeps the same AssemblyVersion across builds, so "is it the
    new one" cannot be answered from metadata -- but the Lua entry points the
    agent calls (KCD2MP_ApplyNpcState and friends) are plain literals in
    GameBridge.cs and land verbatim in the assembly's string heap. If the
    literal is absent, the code that calls it is absent.

    Read-only. Touches nothing.

.PARAMETER AppDir
    Override the installed app directory. Defaults to %LocalAppData%\KCDMP,
    which is DefaultDirName in installer\KCDMP.iss.

.PARAMETER ModDir
    Override the installed mod directory (the folder holding Data\kdcmp.pak).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Verify-Install.ps1
#>
[CmdletBinding()]
param(
    [string] $AppDir = (Join-Path $env:LOCALAPPDATA 'KCDMP'),
    [string] $ModDir = 'D:\SteamLibrary\steamapps\common\KCD2Mod\Mods\kdcmp'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$rel  = Join-Path $root 'release\KCDMP'
$fail = 0

function Get-Strings([string] $path) {
    # Both encodings: .NET string literals live in the #US heap as UTF-16,
    # but metadata names and native strings are ASCII/UTF-8.
    #
    # The two decodes from offset 0 AND offset 1 are not paranoia -- they are
    # the whole correctness of this probe. A UTF-16 literal can begin at either
    # byte parity, and decoding only from 0 silently misses every literal that
    # starts on an odd offset. That is a coin flip per string, and it changes
    # between builds as the heap shifts. It cost a false "WO-28 regression"
    # alarm the first time this script ran: KCD2MP_ReconcileGhosts read as
    # ABSENT from a build that contained it perfectly well.
    #
    # A miss here reads as "the feature is not in this build", which is exactly
    # the conclusion this script exists to make trustworthy.
    $b = [IO.File]::ReadAllBytes($path)
    $u0 = [Text.Encoding]::Unicode.GetString($b, 0, $b.Length - ($b.Length % 2))
    $u1 = [Text.Encoding]::Unicode.GetString($b, 1, $b.Length - 1 - (($b.Length - 1) % 2))
    $u0 + "`n" + $u1 + "`n" + [Text.Encoding]::ASCII.GetString($b)
}

# marker -> the work order that would break if it were missing
$AsmMarkers = @(
    @{ File = 'KcdMpClient.dll'; Marker = 'KCD2MP_ApplyNpcState';   Owner = 'WO-32 NPC sync (agent half)' },
    @{ File = 'KcdMpClient.dll'; Marker = 'KCD2MP_ReconcileGhosts'; Owner = 'WO-28/34 ghost reconcile' },
    @{ File = 'KcdMpClient.dll'; Marker = 'KCD2MP_SetGhostDead';    Owner = 'WO-28/34 death tag' },
    @{ File = 'KcdMpServer.dll'; Marker = 'MasterAnnounce';         Owner = 'WO-35 master server' },
    @{ File = 'KcdMp.Protocol.dll'; Marker = 'MasterApi';           Owner = 'WO-35 master API' }
)

$PakMarkers = @(
    @{ Marker = 'function mp_ghost_is_corpse';     Owner = 'WO-34 corpse freeze' },
    @{ Marker = 'local frozen = mp_ghost_is_corpse'; Owner = 'WO-34 InterpTick freeze' },
    @{ Marker = 'is DEAD in this world';           Owner = 'WO-34 corpse recycling' },
    @{ Marker = 'function KCD2MP_ApplyNpcState';   Owner = 'WO-32 NPC sync (mod half)' },
    @{ Marker = 'npc_state';                       Owner = 'WO-32 npc_state event' }
)

function Test-Assembly($dir, $label) {
    Write-Host "`n[$label] $dir" -ForegroundColor Cyan
    if (-not (Test-Path $dir)) { Write-Host "  MISSING DIRECTORY" -ForegroundColor Red; $script:fail++; return }
    foreach ($m in $AsmMarkers) {
        $p = Join-Path $dir $m.File
        if (-not (Test-Path $p)) {
            Write-Host ("  {0,-22} {1,-24} FILE MISSING" -f $m.File, $m.Marker) -ForegroundColor Red
            $script:fail++; continue
        }
        $ok = (Get-Strings $p) -match [regex]::Escape($m.Marker)
        $colour = if ($ok) { 'Green' } else { 'Red' }
        if (-not $ok) { $script:fail++ }
        Write-Host ("  {0,-22} {1,-24} {2,-7} {3}" -f $m.File, $m.Marker, $(if($ok){'present'}else{'ABSENT'}), $m.Owner) -ForegroundColor $colour
    }
}

function Test-Pak($pak, $label) {
    Write-Host "`n[$label] $pak" -ForegroundColor Cyan
    if (-not (Test-Path $pak)) { Write-Host "  MISSING" -ForegroundColor Red; $script:fail++; return }
    $f = Get-Item $pak
    Write-Host ("  {0:N0} bytes   modified {1}   created {2}" -f $f.Length, $f.LastWriteTime, $f.CreationTime)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($pak)
    try {
        $e = $z.Entries | Where-Object { $_.FullName -match 'kdcmp\.lua$' }
        if (-not $e) { Write-Host "  kdcmp.lua NOT IN PAK" -ForegroundColor Red; $script:fail++; return }
        $sr = New-Object IO.StreamReader($e.Open())
        $lua = $sr.ReadToEnd(); $sr.Close()
    } finally { $z.Dispose() }

    # Roster size is the WO-34 fix's own signature: 24 male entries means the
    # five bandit souls are back (or this pak predates the fix).
    $seg   = $lua.Substring($lua.IndexOf('KCD2MP.faceRoster = {'), 4000)
    $male  = ([regex]'male = \{(?s)(.*?)\n    \},').Match($seg).Groups[1].Value
    $count = ([regex]'\{"').Matches($male).Count
    $ok    = ($count -eq 19)
    if (-not $ok) { $script:fail++ }
    Write-Host ("  {0,-48} {1,-7} {2}" -f 'male roster entries', $count, 'WO-34 expects 19') -ForegroundColor $(if($ok){'Green'}else{'Red'})

    $bandits = @('tbuk_man_5','tkop_man_1','tkop_man_2','tzda_man_6','tzda_man_9') |
               Where-Object { $male -match [regex]::Escape($_) }
    if ($bandits) {
        Write-Host ("  HOSTILE SOULS BACK IN THE ROSTER: {0}" -f ($bandits -join ', ')) -ForegroundColor Red
        $script:fail++
    }

    foreach ($m in $PakMarkers) {
        $hit = $lua -match [regex]::Escape($m.Marker)
        if (-not $hit) { $script:fail++ }
        Write-Host ("  {0,-48} {1,-7} {2}" -f $m.Marker, $(if($hit){'present'}else{'ABSENT'}), $m.Owner) -ForegroundColor $(if($hit){'Green'}else{'Red'})
    }
}

Write-Host '=== KCD2-MP install verification ===' -ForegroundColor Cyan
Write-Host 'BUILT = what the build produced.  INSTALLED = what this machine runs.'
Write-Host 'They disagree when an installer could not overwrite a file that was in use.'

Test-Assembly $rel     'BUILT     app'
Test-Assembly $AppDir  'INSTALLED app'
Test-Pak (Join-Path $root 'kdcmp\Data\kdcmp.pak') 'BUILT     pak'
Test-Pak (Join-Path $ModDir 'Data\kdcmp.pak')     'INSTALLED pak'

# A file that is byte-identical in both places is the only proof the install
# actually landed -- timestamps are preserved by Inno and lie about this.
Write-Host "`n[BUILT vs INSTALLED] size comparison" -ForegroundColor Cyan
foreach ($n in @('KcdMpClient.dll','KcdMpServer.dll','KcdMp.Protocol.dll','KCDMP_launcher.dll')) {
    $b = Get-Item (Join-Path $rel $n)    -ErrorAction SilentlyContinue
    $i = Get-Item (Join-Path $AppDir $n) -ErrorAction SilentlyContinue
    if (-not $b -or -not $i) { Write-Host ("  {0,-22} cannot compare" -f $n) -ForegroundColor Yellow; continue }
    $same = ($b.Length -eq $i.Length)
    if (-not $same) { $script:fail++ }
    Write-Host ("  {0,-22} built {1,9:N0}   installed {2,9:N0}   {3}" -f `
        $n, $b.Length, $i.Length, $(if($same){'match'}else{'STALE INSTALL'})) -ForegroundColor $(if($same){'Green'}else{'Red'})
}

# Anything holding the install open is why a re-run would fail the same way.
$busy = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'KCDMP_launcher|KcdMpClient|KcdMpServer' }
if ($busy) {
    Write-Host "`nRUNNING -- these lock the files an installer needs to replace:" -ForegroundColor Yellow
    $busy | ForEach-Object { "  pid {0,-6} {1,-16} {2}" -f $_.Id, $_.ProcessName, $_.Path }
    Write-Host "  Close them before re-running Setup." -ForegroundColor Yellow
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red
exit 1
