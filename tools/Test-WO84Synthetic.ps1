<#
.SYNOPSIS
    WO-84: synthetic test for the ghost animation throttle, the puppet-chain
    generation retirement, and the orphan ghost-body sweep -- no game, relay
    or agent needed.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO84Synthetic.lua).

    Scenarios:
      (a) the throttle: 2 s of 20 ms ticks on a stationary ghost issues 3
          StartAnimation calls, not 101
      (b) a pumped frame gets the change-driven restart but never the
          keep-alive -- 2 s of 80 Hz pumping adds nothing
      (c) a clip change under an UNCHANGED tag still restarts (idle ->
          combat guard idle when the owner draws)
      (d) a tag change restarts on the same tick
      (e) a one-shot suppresses the loop while it plays and releases the
          guard when it expires
      (f) mp_ghost_anim_refresh 0 restores the pre-WO-84 per-tick restart,
          and a bad argument is refused
      (g) KCD2MP_InterpTick marks pumped vs scheduled frames correctly
      (h) the self-stop race: "puppet tick stopped (no puppets)" retires the
          generation, a packet starts the next one, and the orphaned timer is
          absorbed silently instead of being reported as a leak
      (i) an UNRETIRED stale generation is still reported as a leak, with the
          toast -- the WO-69 detector is not blinded
      (j) the same retirement on the ghost interp chain (preventative; this
          one has never been seen in a field log)
      (k) the orphan sweep: a save-embedded body is confirmed on one sweep and
          removed on the next, tracked ghosts are never touched under either a
          string or a numeric key, and the throttle and off switch work

    What this does NOT prove: that the game's animation queue stops
    overflowing, that a ghost still looks right to a human, or that a
    save-embedded body really stands in a loaded world. See
    docs/WO-84-findings.md for what a live session still has to answer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO84Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO84Synthetic.lua') `
    -Title 'WO-84 synthetic anim-throttle / chain-retirement / orphan-sweep test'
exit $LASTEXITCODE
