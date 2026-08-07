# The wire protocol version, read from the wire protocol itself.
#
# Dot-source this:  . (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')
# then use:         $PROTOCOL_VERSION
#
# Why this file exists. Every synthetic-peer script here has to put a version
# byte in its Handshake, and the relay refuses any mismatch outright -- that is
# deliberate and correct, but it means a script whose pin has drifted does not
# fail in some subtle way, it simply cannot connect at all.
#
# The pins were hardcoded per script, and by WO-28 three of eleven had silently
# drifted and would have been refused on sight: Test-AppearanceE2E.ps1 pinned 5,
# Test-CombatE2E.ps1 pinned 3, Bot-DiceOpponent.ps1 pinned 4, against a relay
# speaking 6. Nobody had run them since the bumps. Three independent drifts is a
# mechanism problem, not three typos, so the number is now derived from
# Protocol.cs -- the one place it is actually defined -- instead of copied.
#
# Scripts that deliberately test a MISMATCH keep working unchanged, because they
# express it relative to this value ($PROTOCOL_VERSION + 1) rather than as
# another literal.

$script:ProtocolCsPath = Join-Path $PSScriptRoot '..\dotnet\KcdMp.Protocol\Protocol.cs'

function Get-KcdMpProtocolVersion {
    <#
    .SYNOPSIS Reads `public const byte Version = N;` out of Protocol.cs.
    .DESCRIPTION
        Throws rather than guessing if it cannot find it. A wrong version byte
        produces a flat connection refusal that reads like "the relay is down",
        which is a considerably worse half-hour than an explicit error here.
    #>
    if (-not (Test-Path $script:ProtocolCsPath)) {
        throw "cannot find Protocol.cs at $($script:ProtocolCsPath) -- run this script from the repo's tools\ directory"
    }
    $src = Get-Content $script:ProtocolCsPath -Raw
    if ($src -match 'public\s+const\s+byte\s+Version\s*=\s*(\d+)\s*;') {
        return [int]$Matches[1]
    }
    throw "could not find 'public const byte Version = N;' in $($script:ProtocolCsPath) -- has it been renamed?"
}

$PROTOCOL_VERSION = Get-KcdMpProtocolVersion
