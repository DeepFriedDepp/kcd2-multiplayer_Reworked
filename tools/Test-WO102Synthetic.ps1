<#
.SYNOPSIS
    WO-102: synthetic test for the host-authority toggle set and, as the
    phases land, the MP-AUTHORITY instrumentation, the host-authority
    emitter/receiver gates and the NPC resync. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO102Synthetic.lua. See that file's header for the scenario list and
    for what this deliberately does NOT prove.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO102Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO102Synthetic.lua') `
    -Title 'WO-102 synthetic host-authority test'
exit $LASTEXITCODE
