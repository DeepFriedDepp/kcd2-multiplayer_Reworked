<#
.SYNOPSIS
    WO-104: synthetic test for (Phase 0) the world-time wire formatting past
    1e6 and (Phases 1-2) the brainless-replica path for contested NPCs and
    the pause lever's new default. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO104Synthetic.lua. See that file's header for the scenario list and
    for what this deliberately does NOT prove.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO104Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO104Synthetic.lua') `
    -Title 'WO-104 synthetic time-format + replica test'
exit $LASTEXITCODE
