<#
.SYNOPSIS
    WO-110 R10: execute the published release payload once -- relay up, agent
    connects, one round trip, both exit -- and fail if it does not.

.DESCRIPTION
    tools\Publish-Release.ps1 flat-merges four self-contained publishes into
    release\KCDMP; later projects overwrite shared DLLs (Microsoft.Extensions.*,
    Serilog.*, KcdMp.Protocol.dll). Before WO-110 nothing ever STARTED that
    folder before Setup embedded it: unit tests ran against bin\, the relay
    round-trip gate hosted the relay in-process from the test project, and
    the merged payload shipped unexecuted (docs/WO-109-audit.md R10). The
    0.11.8 and WO-69/74 incidents were both "a DLL in the install directory
    was the wrong build" and neither would have been caught by anything.

    This script:
      1. copies the payload to a temp folder (byte-identical; a copy so the
         run's own kcdmp-client.json, agent.log and relay.log never land in
         the folder the installer embeds -- New-InstallManifest.ps1 would
         otherwise ship them);
      2. starts KcdMpServer.exe from that copy on a free TCP port with its
         HTTP listener on a random loopback port (no clash with a live relay
         on 7778/5273, no master-server announce);
      3. runs KcdMpClient.exe --relay-smoke against it: real Handshake with
         this build's protocol byte and release version, Ack, one Ping/Pong
         (RelaySmoke.cs); exit 0 with a RELAY-SMOKE ok line, else 1;
      4. stops the relay, deletes the copy, and exits with the agent's code.

    Same-build only by construction: both exes come from the same payload,
    so a release-version refusal (WO-110 R9) cannot fire here -- that path
    has its own relay gate test.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-PayloadSmoke.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-PayloadSmoke.ps1 -Payload C:\somewhere\KCDMP
#>
[CmdletBinding()]
param(
    [string] $Payload = (Join-Path $PSScriptRoot "..\release\KCDMP"),
    [int] $TimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
$Payload = (Resolve-Path $Payload).Path

foreach ($f in @('KcdMpServer.exe', 'KcdMpClient.exe', 'KcdMp.Protocol.dll', 'appsettings.json')) {
    if (-not (Test-Path (Join-Path $Payload $f))) { Write-Host "  FAIL  payload is missing $f"; exit 1 }
}

# A free TCP port, then release it for the relay to bind.
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

$work = Join-Path ([IO.Path]::GetTempPath()) ("kcdmp-payload-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item (Join-Path $Payload '*') $work -Recurse -Force

# The published bytes are what is under test: prove the copy IS the payload.
$srcHash = (Get-FileHash (Join-Path $Payload 'KcdMpClient.exe')).Hash
$dstHash = (Get-FileHash (Join-Path $work 'KcdMpClient.exe')).Hash
if ($srcHash -ne $dstHash) { Write-Host "  FAIL  payload copy hash mismatch"; exit 1 }

$relay = $null
$code = 1
try {
    Write-Host "  payload smoke: relay on 127.0.0.1:$port from a copy of $Payload"
    $relayOut = Join-Path $work 'relay-stdout.txt'
    $relayErr = Join-Path $work 'relay-stderr.txt'
    $relay = Start-Process -FilePath (Join-Path $work 'KcdMpServer.exe') `
        -ArgumentList @('--port', "$port", '--Urls', 'http://127.0.0.1:0') `
        -WorkingDirectory $work -PassThru -NoNewWindow `
        -RedirectStandardOutput $relayOut -RedirectStandardError $relayErr

    # Wait for the relay to listen (bounded), rather than sleeping a guess.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $listening = $false
    while ((Get-Date) -lt $deadline) {
        if ($relay.HasExited) { break }
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $t.Connect('127.0.0.1', $port); $t.Dispose(); $listening = $true; break
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $listening) {
        Write-Host "  FAIL  published relay did not listen on $port within $TimeoutSec s (exited=$($relay.HasExited))"
        if (Test-Path $relayErr) { Get-Content $relayErr | Select-Object -First 20 | ForEach-Object { Write-Host "    relay: $_" } }
        if (Test-Path $relayOut) { Get-Content $relayOut | Select-Object -Last 20 | ForEach-Object { Write-Host "    relay: $_" } }
        exit 1
    }

    $agentOut = Join-Path $work 'agent-stdout.txt'
    $agent = Start-Process -FilePath (Join-Path $work 'KcdMpClient.exe') `
        -ArgumentList @('--relay-smoke', '--host', '127.0.0.1', '--port', "$port", '--name', 'payload-smoke', '--no-voice', '--no-discord') `
        -WorkingDirectory $work -PassThru -NoNewWindow -RedirectStandardOutput $agentOut
    if (-not $agent.WaitForExit($TimeoutSec * 1000)) {
        try { $agent.Kill() } catch {}
        Write-Host "  FAIL  published agent did not exit within $TimeoutSec s"
        exit 1
    }
    $code = $agent.ExitCode
    $lines = @()
    if (Test-Path $agentOut) { $lines = Get-Content $agentOut }
    $smoke = $lines | Where-Object { $_ -match 'RELAY-SMOKE' } | Select-Object -Last 1
    if ($code -eq 0 -and $smoke -match 'RELAY-SMOKE ok') {
        Write-Host "  PASS  $smoke"
    } else {
        Write-Host "  FAIL  agent exit=$code : $smoke"
        $lines | Select-Object -Last 15 | ForEach-Object { Write-Host "    agent: $_" }
        if (Test-Path $relayOut) { Get-Content $relayOut | Select-Object -Last 15 | ForEach-Object { Write-Host "    relay: $_" } }
        $code = 1
    }
    # The relay must have logged the connect: proves the published relay's
    # session path (not just its socket) ran.
    $relayLog = Get-ChildItem $work -Filter 'relay*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    $relayText = @()
    if ($relayLog) { $relayText += Get-Content $relayLog.FullName }
    if (Test-Path $relayOut) { $relayText += Get-Content $relayOut }
    if (($relayText | Where-Object { $_ -match "'payload-smoke' connected" }).Count -ge 1) {
        Write-Host "  PASS  published relay logged the smoke client's connect"
    } else {
        Write-Host "  FAIL  published relay never logged 'payload-smoke' connected"
        $code = 1
    }
}
finally {
    if ($relay -and -not $relay.HasExited) { try { $relay.Kill() } catch {} }
    if ($relay) { try { $relay.WaitForExit(5000) | Out-Null } catch {} }
    Start-Sleep -Milliseconds 300
    try { Remove-Item $work -Recurse -Force -ErrorAction Stop } catch { Write-Host "  (temp folder $work left behind: $($_.Exception.Message))" }
}
exit $code
