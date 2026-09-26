<#
.SYNOPSIS
    WO-124 Phase 6: synthetic test for the two 0.28.3 peer-test fixes (6a: the
    peer's avatar is taken off the horse before the native writer may have it;
    6b: a detach skipped for a conversation is retried once it ends). No game,
    relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO124FixesSynthetic.lua. Both fixes were also run live -- see
    docs/WO-124-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO124FixesSynthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO124FixesSynthetic.lua') `
    -Title 'WO-124 Phase 6 (6a avatar dismount, 6b detach retry) Lua test'
exit $LASTEXITCODE
