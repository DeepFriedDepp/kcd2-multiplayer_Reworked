<#
.SYNOPSIS
    WO-99: synthetic test for the sub-8 m puppet yield arbitration
    (MP-NPCYIELD yield/re-pin, thresholds, the mp_npc_yield toggle) and the
    Phase 0 local-player name exclusion. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO99Synthetic.lua). See that file's header for the scenario list
    and for what this deliberately does NOT prove.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO99Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO99Synthetic.lua') `
    -Title 'WO-99 synthetic puppet-yield / player-exclusion test'
exit $LASTEXITCODE
