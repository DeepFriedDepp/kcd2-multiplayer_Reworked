<#
.SYNOPSIS
    WO-78: synthetic test for the GHOST interp chain (kdcmp.lua's
    KCD2MP_UpdateGhost / KCD2MP_InterpTick / KCD2MP_StartInterp) and the shared
    chain-restart gate -- no game, relay or agent needed.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-GhostInterpSynthetic.lua). Ghost and puppet scenarios stay in
    separate files like the code they test (WO-70 constraint 1).

    Scenarios:
      (ga) single chain, steady 1.5 m/s stream: monotonic, bounded advance
      (gc) 3 same-frame chain fires + 1 STALE-generation fire per step render
           the identical position to (ga); the stale chain is detected
           (GHOST CHAIN LEAK CONFIRMED), toasted, and exits (mp_ghost_chainfix
           default on)
      (gc2) two chains 10 ms out of phase reproduce the single-chain
           trajectory (time-based advance composes)
      (gd) restart gate, suspension: a stale stamp during a "menu" does NOT
           start a second chain; the probe finds the resumed chain and logs
           "suspended, not dead"
      (ge) restart gate, real death: the probe fires with no heartbeat and
           the chain restarts exactly once
      (gg) the menu pump entry (arg "ext") renders, never reschedules, never
           stamps the chain alive

    What this does NOT prove: how a ghost looks to a human in a two-player
    session, and that the game's own Lua VM accepts the code.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-GhostInterpSynthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-GhostInterpSynthetic.lua') `
    -Title 'WO-78 synthetic ghost-interp / chain-gate test'
exit $LASTEXITCODE
