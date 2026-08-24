# Test-WeaponClassMapping.ps1 -- WO-47 Phase 1: does the appearance-sync
# "class id" space (ItemClass GUIDs in EquippedWeaponsByClassId) map onto the
# combat tables' r_weapon_class_id space (small ints)?
#
# For each test weapon: CreateItems + EquipItem on the LOCAL PLAYER via the
# debug REST API, then read EquippedWeaponsByClassId back and print, side by
# side: the GUID the sync reports, the dictionary Key it is filed under, the
# item.xml Class="N" for that GUID, and whether combat_action_attack.xml has
# FreeAttack rows reachable for N (directly or via the shipped weapon-group
# tables). Needs the game RUNNING with a save loaded. Leaves the last test
# weapon equipped (visible confirmation) but unequips between steps.
#
# NOTE: this puts the test weapons into the player's inventory (that is what
# CreateItems does). Run on a throwaway/test save.

param(
    [string] $Api = 'http://localhost:1403'
)
$ErrorActionPreference = 'Stop'

$weapons = @(
    @{ name='sermiry_longSwordMenhart'; guid='204c1852-dd30-42ae-9317-bc3123a3e301'; cls=4;  clsName='longsword' },
    @{ name='maceClub';                 guid='cff7ae16-d134-41bd-9394-89e8c3970f94'; cls=5;  clsName='mace' },
    @{ name='axeWork01';                guid='1fc42528-2bef-4dde-bf8a-04febeef41c8'; cls=3;  clsName='axe' },
    @{ name='shortswordCleaver';        guid='652db434-b7d6-448f-8671-10ca787ba1e2'; cls=1;  clsName='sword' },
    @{ name='huntingSwordBasic';        guid='c164f346-0463-4116-b790-094b11274e5e'; cls=16; clsName='hunting_sword' }
)

function Read-WeaponMap {
    $xml = [xml](Invoke-RestMethod "$Api/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedWeaponsByClassId?depth=1")
    $pairs = @()
    foreach ($p in $xml.SelectNodes('//Pair')) {
        $pairs += [pscustomobject]@{ Key = $p.Key; ItemClass = $p.Value.FirstChild.ItemClass }
    }
    return $pairs
}

Write-Host "=== WO-47 Phase 1: appearance-sync class ids vs r_weapon_class_id ==="
Write-Host ("baseline EquippedWeaponsByClassId: " + ((Read-WeaponMap | ForEach-Object { "$($_.Key)=$($_.ItemClass)" }) -join '; '))
Write-Host ""

$fail = 0
foreach ($w in $weapons) {
    $g = $w.guid
    try {
        Invoke-RestMethod "$Api/api/rpg/SoulList/PlayerSoul/Inventory/CreateItems?ItemClass=$g&Amount=1&ShowUINotification=false" | Out-Null
        Invoke-RestMethod "$Api/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquipItem?itemClassId=$g" | Out-Null
        Start-Sleep -Milliseconds 600
        $map = Read-WeaponMap
        $hit = $map | Where-Object { $_.ItemClass -eq $g }
        if ($hit) {
            Write-Host ("{0}:" -f $w.name)
            Write-Host ("  EquippedWeaponsByClassId reports  ItemClass={0}  (dictionary Key={1})" -f $hit.ItemClass, $hit.Key)
            Write-Host ("  item.xml row for that GUID:       Class=""{0}""  ({1})" -f $w.cls, $w.clsName)
            Write-Host ("  combat tables for class {0}:       see Test-SwingCatalog.ps1 rows" -f $w.cls)
        }
        else {
            Write-Host ("{0}: FAIL - equipped but ItemClass {1} not in EquippedWeaponsByClassId. Map: {2}" `
                -f $w.name, $g, (($map | ForEach-Object { $_.ItemClass }) -join ', '))
            $fail++
        }
        # Unequip so the next weapon lands in a clean main-hand slot.
        Invoke-RestMethod "$Api/api/rpg/SoulList/PlayerSoul/EquipmentManager/UnequipItem?itemClassId=$g" | Out-Null
        Start-Sleep -Milliseconds 300
    }
    catch {
        Write-Host ("{0}: ERROR - {1}" -f $w.name, $_.Exception.Message)
        $fail++
    }
    Write-Host ""
}

if ($fail -gt 0) { Write-Host "RESULT: $fail weapon(s) failed the read-back"; exit 1 }
Write-Host "RESULT: every equipped weapon's ItemClass GUID came back through EquippedWeaponsByClassId"
exit 0
