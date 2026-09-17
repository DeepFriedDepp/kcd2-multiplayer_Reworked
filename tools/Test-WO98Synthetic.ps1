<#
.SYNOPSIS
    WO-98: synthetic test for the instrumentation channels (MP-TOAST,
    MP-SCREEN, MP-KEY, MP-CUTSCENE, MP-SUMMARY-MOD, the mod-clock stamp), the
    cutscene-held readiness prompt, and the collapsed QUEST-DIVERGENCE
    re-push logging. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO98Synthetic.lua). See that file's header for the scenario list
    and for what this deliberately does NOT prove.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO98Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO98Synthetic.lua') `
    -Title 'WO-98 synthetic instrumentation / cutscene-held prompt test'
exit $LASTEXITCODE
