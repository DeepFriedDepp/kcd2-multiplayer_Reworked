<#
.SYNOPSIS
    WO-6 R1/R2: labeled snapshots of the dice-minigame-adjacent reflected
    surface, for diffing across game states while a human plays a real NPC
    dice game.

.DESCRIPTION
    Read-only. Captures, in one call:
      - GUIModule.UIElements[22] (wh::guimodule::C_UIDice), depth=3
      - PlayerModule, depth=2
      - the player's own soul record, depth=1 (heavy subtrees excluded)
      - the named opponent NPC's soul record, depth=1, if -Opponent is given

    Each snapshot is written to tools\dice-probe-<Label>.xml. Run once per
    game state (before-sitting, at-table, mid-roll, keep-screen, on-bank,
    on-win) with a distinct -Label, then diff consecutive files by eye or
    with Compare-DiceProbe below.

    C_UIDice's index in GUIModule.UIElements was found by walking
    /api/gui?depth=1 and matching UIElementsByName -- index 22 as of the
    build this was probed against. If a game update reorders the array,
    re-derive the index with Find-DiceUIIndex before trusting this script.

.EXAMPLE
    . tools\Probe-Dice.ps1
    Save-DiceProbe -Label "01-before-sitting"
    # human sits down and starts a game
    Save-DiceProbe -Label "02-at-table"
#>

. (Join-Path $PSScriptRoot "KcdApi.ps1")

$script:DiceUIIndex = 22
$script:DiceProbeDir = $PSScriptRoot

function Find-DiceUIIndex {
    <#  .SYNOPSIS Re-derive C_UIDice's index in GUIModule.UIElements if it ever moves.  #>
    $xml = Invoke-KcdApi -Path "/api/gui/UIElements?depth=1" -MaxBytes 65536
    $lines = $xml -split "`n"
    $idx = 0
    foreach ($line in $lines) {
        if ($line -match '<C_UIDice\s*/?>') { return $idx }
        if ($line -match '<C_UI\w+\s*/?>') { $idx++ }
    }
    return -1
}

function Save-DiceProbe {
    <#
    .SYNOPSIS One labeled snapshot of everything dice-adjacent, read-only.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [string]$Opponent = $null
    )

    if (-not (Test-KcdApi)) {
        Write-Error "Debug API not answering on localhost:1403."
        return
    }

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("<!-- dice probe '$Label' captured $(Get-Date -Format o) -->")

    [void]$sb.AppendLine("<C_UIDice>")
    [void]$sb.AppendLine((Invoke-KcdApi -Path "/api/gui/UIElements/$($script:DiceUIIndex)?depth=3" -MaxBytes 131072))
    [void]$sb.AppendLine("</C_UIDice>")

    [void]$sb.AppendLine("<PlayerModule>")
    [void]$sb.AppendLine((Invoke-KcdApi -Path "/api/player?depth=2" -MaxBytes 131072))
    [void]$sb.AppendLine("</PlayerModule>")

    $exclude = "DerivedStatsByName,Buffs,Roles,StaticData,PersistentData,Archetype," +
               "Inventory,CompanionManager,EquipmentManager,FactionNode,SoulClass," +
               "SocialClass,StormDebug"
    [void]$sb.AppendLine("<PlayerSoul>")
    [void]$sb.AppendLine((Invoke-KcdApi -Path "/api/rpg/SoulList/PlayerSoul?depth=2&exclude=$exclude" -MaxBytes 262144))
    [void]$sb.AppendLine("</PlayerSoul>")

    if ($Opponent) {
        [void]$sb.AppendLine("<OpponentSoul name=`"$Opponent`">")
        [void]$sb.AppendLine((Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$Opponent?depth=2&exclude=$exclude" -MaxBytes 262144))
        [void]$sb.AppendLine("</OpponentSoul>")
    }

    $outFile = Join-Path $script:DiceProbeDir "dice-probe-$Label.xml"
    $sb.ToString() | Out-File -FilePath $outFile -Encoding UTF8
    Write-Output "Saved $outFile ($((Get-Item $outFile).Length) bytes)"
}

function Compare-DiceProbe {
    <#  .SYNOPSIS Line-diff two labeled snapshots.  #>
    param(
        [Parameter(Mandatory=$true)][string]$LabelA,
        [Parameter(Mandatory=$true)][string]$LabelB
    )
    $a = Get-Content (Join-Path $script:DiceProbeDir "dice-probe-$LabelA.xml")
    $b = Get-Content (Join-Path $script:DiceProbeDir "dice-probe-$LabelB.xml")
    Compare-Object -ReferenceObject $a -DifferenceObject $b
}
