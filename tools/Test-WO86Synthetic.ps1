<#
.SYNOPSIS
    WO-86: synthetic test for NPC death sync -- the corpse-drag safeguard, the
    death observer, the remote-death marks and the emitter's dead bit. No game,
    relay or agent needed.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO86Synthetic.lua).

    Scenarios:
      (a) the field report's corpse: this world's copy dies while the inbound
          stream keeps walking it -- no writes, one DIVERGENCE line, one
          npc_death announcement
      (b) the WO-38 body-follow is preserved when the STREAM says the body is
          down; a stream-dead body on a living local copy is frozen and never
          announced by this world
      (c) observer semantics: first-seen-dead is silent, a witnessed death
          announces once, alive-again clears the marks, a second death
          announces again
      (d) KCD2MP_NpcRemoteDeath marks the death remote, flags the puppet dead,
          and the resulting local IsDead flip is not announced back
      (e) KCD2MP_NpcDeathAnnounced (the DLL's FATAL hit went first) keeps the
          observer quiet
      (f) mp_npc_deathsync off restores the pre-WO-86 behaviour verbatim and
          is mirrored to the agent; a bad argument is refused
      (g) the emitter sets dead bit 0 on npc_state after a local death, logs
          it once, and announces once as the emitter reader

    What this does NOT prove: that actor:IsDead() flips for a killed world NPC
    in the live game, that the DLL's ApplyDeath produces a corpse on the
    receiving machine, or that both humans see the same death. See
    docs/WO-86-findings.md for what a live session still has to answer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO86Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO86Synthetic.lua') `
    -Title 'WO-86 synthetic NPC death sync test'
exit $LASTEXITCODE
