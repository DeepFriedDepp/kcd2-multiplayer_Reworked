<#
.SYNOPSIS
    WO-129: synthetic test for the Lua halves of the first-session fixes:
    the host's join bar (stages + seconds) and shared-world NPC scan anchors.
    No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO129Synthetic.lua. The gait fix is native (native\tests) and live
    (docs/WO-129-findings.md).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO129Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO129Synthetic.lua') `
    -Title 'WO-129 synthetic join bar + shared-world anchors Lua test'
exit $LASTEXITCODE
