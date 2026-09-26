<#
.SYNOPSIS
    WO-127: synthetic test for the Lua half of the leash recorder:
    mp_leash_trace on|off and the host's once-a-second context answer.
    No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO127Synthetic.lua. The recorder itself is tested in the client
    tests and live -- see docs/WO-127-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO127Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO127Synthetic.lua') `
    -Title 'WO-127 synthetic leash recorder Lua test'
exit $LASTEXITCODE
