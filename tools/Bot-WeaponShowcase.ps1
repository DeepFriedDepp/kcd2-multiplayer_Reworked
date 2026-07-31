<#
.SYNOPSIS
    Visual confirmation for WO-10 weapon sync: spawns a test ghost in front of
    you and cycles it through several real weapon classes so you can watch
    each one actually load on the model, before trusting the mechanism enough
    to commit.

.DESCRIPTION
    Does not go through the relay/agent/wire path at all -- this drives the
    exact same native calls GameBridge.ApplyAppearanceAsync uses
    (EquipmentManager.EquipItem/UnequipItem, Inventory.CreateItems) directly
    against the debug REST API, the same way WO-9/WO-10's own manual probes
    did. That is deliberate: it isolates "does the equip mechanism render
    every weapon category" from "does the wire/relay/diff plumbing deliver
    it," which is already covered by tools\Test-AppearanceE2E.ps1. This
    script is for your eyes, not for CI.

    Every item class below was read live off the real player's own
    Inventory (?depth=2), not guessed -- CreateItems on a wrong GUID fails
    silently (returns an empty ItemClassDescriptor either way), so nothing
    here is invented.

    Sequence (7 steps, each held on screen for -DwellSec so you can look):
      0. spawn        -- ghost appears in the white/red preset, already
                          carrying its spawn weapon (sermiry_longSwordMenhart)
                          -- this is "sword #1", already visible at spawn.
      1. sword2        -- longswordHenry_reforged
      2. sword3        -- alias_zachrana_huntingSword
      3. axe           -- axeTraining
      4. mace          -- mace02 (bonus -- not asked for, added when it
                          turned out to be easier to get into inventory than
                          a second true axe)
      5. shield+sword  -- shieldKite_twitch equipped ALONGSIDE sword3,
                          rather than replacing it -- shield and one-handed
                          weapon occupy different slots in
                          EquippedWeaponsByClassId, the same way the real
                          player was observed carrying a torch and a sword
                          at once (WO-10 Phase 0).
      6. crossbow      -- crossbowLightNormal01, melee weapons unequipped
                          first so the ghost is holding only the crossbow --
                          unambiguous on screen.

    Each step: unequip what dropped out, CreateItems (once per class, this
    ghost is fresh so nothing is a repeat) + EquipItem what's new, then
    read EquipmentManager.EquippedWeaponsByClassId back with a short retry
    (same "a fault-free EquipItem is not a successful one" trap WO-9/WO-10
    already documented) before declaring the step ready to look at.

.PARAMETER DwellSec
    Seconds to hold on each weapon before moving to the next. Default 12 --
    long enough to alt-tab and actually look.

.PARAMETER Cleanup
    Remove the test ghost (mp_remove_all -- removes every ghost, so don't
    use this if something else spawned one) and exit.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-WeaponShowcase.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-WeaponShowcase.ps1 -DwellSec 8

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-WeaponShowcase.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    [int]    $DwellSec = 12,
    [switch] $Cleanup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$GhostSoul = 'kcd2mp_test_ghost'

function Invoke-Lua([string] $Lua) {
    # EscapeDataString, not UrlEncode: percent-encodes spaces rather than
    # turning them into '+'. A bare '+' silently becoming a space over HTTP
    # is exactly the false "it's broken" trap WO-9's own postmortem hit.
    $encoded = [uri]::EscapeDataString('#' + $Lua)
    Invoke-WebRequest -Uri "http://localhost:1403/api/System/Console/ExecuteString?command=$encoded" `
        -UseBasicParsing -TimeoutSec 15 | Out-Null
}

function Get-EquippedWeaponClasses {
    $xml = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$GhostSoul/EquipmentManager/EquippedWeaponsByClassId?depth=1" -MaxBytes 40000
    if ($xml -match '^ERR') { return @() }
    $rx = [regex]'ItemClass="([0-9a-fA-F-]{36})"'
    @($rx.Matches($xml) | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
}

function Unequip-Class([string] $cls) {
    Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$GhostSoul/EquipmentManager/UnequipItem?itemClassId=$cls" -MaxBytes 512 | Out-Null
}

function Equip-Class([string] $cls, [bool] $createFirst) {
    if ($createFirst) {
        Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$GhostSoul/Inventory/CreateItems?ItemClass=$cls&Amount=1&ShowUINotification=false" -MaxBytes 512 | Out-Null
    }
    Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$GhostSoul/EquipmentManager/EquipItem?itemClassId=$cls" -MaxBytes 512 | Out-Null
}

if ($Cleanup) {
    Write-Host "Removing all ghosts (mp_remove_all)..."
    Invoke-Lua "KCD2MP_RemoveAllGhosts()"
    Write-Host "Done."
    exit 0
}

if (-not (Test-KcdApi)) { throw "debug API not answering (game running via Modding Tools, save loaded?)" }

# Real item classes, read live off the actual player's own Inventory
# (?depth=2) this session -- nothing here is guessed.
$Sermiry      = '204c1852-dd30-42ae-9317-bc3123a3e301'  # sermiry_longSwordMenhart -- the ghost's own spawn weapon
$Henry        = '62096670-22ca-473c-adc3-bc63a9369550'  # longswordHenry_reforged
$HuntingSword = 'b867dd0e-1bfe-40e9-b114-4b126a3ff1b0'  # alias_zachrana_huntingSword
$Axe          = 'e86cf667-1449-4111-9bb5-17329a526278'  # axeTraining
$Mace         = 'c67de991-e22a-4a19-8b68-9369919c41dd'  # mace02
$Shield       = '90c3b622-1c1d-4bd1-bee7-6b1c04072c5c'  # shieldKite_twitch
$Crossbow     = 'cb6ee20b-6eee-434c-af4c-8031502e2bec'  # crossbowLightNormal01

Write-Host "=== WO-10 weapon showcase ===" -ForegroundColor Cyan
Write-Host "Spawning test ghost 3m in front of you (mp_spawn_test)..."
Invoke-Lua "KCD2MP_SpawnTest()"
Start-Sleep -Seconds 3

$applied = [System.Collections.Generic.HashSet[string]]::new()
$applied.Add($Sermiry) | Out-Null   # the spawn-preset weapon, already on the model
$known = [System.Collections.Generic.HashSet[string]]::new()
$known.Add($Sermiry) | Out-Null

function Show-Step([string] $Label, [string] $LookFor, [string[]] $Target) {
    $targetSet = [System.Collections.Generic.HashSet[string]]::new([string[]]($Target | ForEach-Object { $_.ToLowerInvariant() }))

    $toRemove = @($applied | Where-Object { -not $targetSet.Contains($_) })
    $toAdd    = @($targetSet | Where-Object { -not $applied.Contains($_) })

    foreach ($cls in $toRemove) { Unequip-Class $cls; $applied.Remove($cls) | Out-Null }
    foreach ($cls in $toAdd) {
        $createFirst = $known.Add($cls)   # true only the first time this class is seen on this ghost
        Equip-Class $cls $createFirst
        $applied.Add($cls) | Out-Null
    }

    Write-Host ""
    Write-Host "--- $Label ---" -ForegroundColor Magenta
    Write-Host "    LOOK FOR: $LookFor" -ForegroundColor Magenta

    # Same "a fault-free EquipItem is not a successful one" trap as
    # GameBridge.VerifyAndRetryAsync -- read back before trusting it applied.
    $ok = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Start-Sleep -Milliseconds 800
        $actual = Get-EquippedWeaponClasses
        $missing = @($targetSet | Where-Object { $actual -notcontains $_ })
        if ($missing.Count -eq 0) { $ok = $true; break }
        if ($attempt -eq 5) {
            Write-Host "    (still not confirmed via read-back after retries: $($missing -join ', '))" -ForegroundColor Yellow
        }
    }
    if ($ok) { Write-Host "    read-back confirms it took." -ForegroundColor DarkGray }

    for ($s = $DwellSec; $s -gt 0; $s--) {
        Write-Host ("`r    displaying... {0,2}s " -f $s) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r    done.               "
}

Write-Host ""
Write-Host "--- 0. spawn (sword #1) ---" -ForegroundColor Magenta
Write-Host "    LOOK FOR: full white/red plate armor, already holding sermiry_longSwordMenhart." -ForegroundColor Magenta
for ($s = $DwellSec; $s -gt 0; $s--) {
    Write-Host ("`r    displaying... {0,2}s " -f $s) -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
Write-Host "`r    done.               "

Show-Step "1. sword #2" "longswordHenry_reforged replaces the spawn sword." @($Henry)
Show-Step "2. sword #3" "alias_zachrana_huntingSword replaces sword #2." @($HuntingSword)
Show-Step "3. axe" "axeTraining replaces the hunting sword." @($Axe)
Show-Step "4. mace (bonus)" "mace02 replaces the axe." @($Mace)
Show-Step "5. shield + sword" "shieldKite_twitch equips ALONGSIDE the hunting sword -- both should be visible at once." @($HuntingSword, $Shield)
Show-Step "6. crossbow" "crossbowLightNormal01 only -- sword and shield are gone, ghost holds just the crossbow." @($Crossbow)

Write-Host ""
Write-Host "=== showcase complete ===" -ForegroundColor Cyan
Write-Host "Ghost 'test_ghost' is still spawned for a closer look."
Write-Host "Run this script again with -Cleanup to remove it (removes ALL ghosts)."
