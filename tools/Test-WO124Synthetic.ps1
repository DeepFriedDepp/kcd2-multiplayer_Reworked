<#
.SYNOPSIS
    WO-124: synthetic test for the Lua half of the joiner's side of the join
    (the host's session mode, the save lock under it, where the game is, the
    lock/Henry replies, the load command, mp_join_henry). The Phase 6 fixes
    have their own file, Test-WO124FixesSynthetic.ps1. No game, relay or
    agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO124Synthetic.lua. The join itself is live-tested -- see
    docs/WO-124-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO124Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO124Synthetic.lua') `
    -Title 'WO-124 synthetic joiner Lua test'
exit $LASTEXITCODE
