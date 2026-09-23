<#
.SYNOPSIS
    WO-113: synthetic test for the Lua half of death without Game Over -- the
    mp_respawn toggle and its forward to the agent, and the WO113-BUILD
    marker. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO113Synthetic.lua. The respawn policy itself is native and is not
    exercised here -- see docs/WO-113-progress.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO113Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO113Synthetic.lua') `
    -Title 'WO-113 synthetic respawn-toggle test'
exit $LASTEXITCODE
