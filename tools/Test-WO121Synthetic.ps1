<#
.SYNOPSIS
    WO-121: synthetic test for the Lua half of movement and combat -- the seven
    toggles, the WO121-BUILD marker, the clip park, the gait gate and the
    engagement edge. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO121Synthetic.lua. The policy itself is native and is not
    exercised here -- see docs/WO-121-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO121Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO121Synthetic.lua') `
    -Title 'WO-121 synthetic movement/combat Lua test'
exit $LASTEXITCODE
