<#
.SYNOPSIS
    WO-110 R10: prove the published release payload is coherent and runs --
    relay up, agent connects, one round trip, both exit -- and fail otherwise.

.DESCRIPTION
    tools\Publish-Release.ps1 flat-merges four self-contained publishes into
    release\KCDMP; later projects overwrite shared DLLs (Microsoft.Extensions.*,
    Serilog.*, System.Text.Json, KcdMp.Protocol.dll). Before WO-110 nothing
    ever STARTED that folder before Setup embedded it: unit tests ran against
    bin\, the relay round-trip gate hosted the relay in-process from the test
    project, and the merged payload shipped unexecuted (docs/WO-109-audit.md
    R10). The 0.11.8 and WO-69/74 incidents were both "a DLL in the install
    directory was the wrong build" and neither would have been caught.

    The first run of this gate (2026-09-22, against the 0.26.4-era tree)
    found exactly that class of defect: the relay's publish overwrote the
    agent's System.Text.Json 8.0 with 10.0, which needs System.IO.Pipelines
    10.0 -- present in the folder but absent from KcdMpClient.deps.json, so
    the agent's loader could not see it and every JSON write in the shipped
    agent failed ("Could not load file or assembly 'System.IO.Pipelines,
    Version=10.0.0.0'"). Hence part A below.

    A. Static coherence report: for every *.deps.json in the payload, every
       runtime assembly it lists is compared against the merged folder's
       copy and each version difference is printed (higher / LOWER). This
       is a WARN, not a gate: the .NET host accepts a higher copy, and the
       launcher has always shipped a few lower type-forwarding facades.
       The failure that actually bit (an unlisted transitive dependency)
       is not visible statically; part B is the gate for it.
    B. Runtime smoke:
       1. copy the payload to a temp folder (byte-identical; a copy so the
          run's own kcdmp-client.json, agent.log and relay.log never land in
          the folder the installer embeds -- New-InstallManifest.ps1 would
          otherwise ship them);
       2. start KcdMpServer.exe from that copy on a free TCP port with its
          HTTP listener on a random loopback port (no clash with a live relay
          on 7778/5273, no master-server announce);
       3. run KcdMpClient.exe --relay-smoke against it: real Handshake with
          this build's protocol byte and release version, Ack, one Ping/Pong
          (RelaySmoke.cs); exit 0 with a RELAY-SMOKE ok line, else 1;
       4. the agent's stdout must carry no "Could not load file or assembly"
          / "Unhandled exception" line -- a caught-and-logged load failure
          is still a broken payload;
       5. stop the relay, delete the copy, exit non-zero on any failure.

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
$script:fail = 0
function Ok([string] $m)  { Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad([string] $m) { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }

Write-Host "`n=== WO-110 R10: payload coherence + smoke, $Payload ===`n"

# WO-127: KcdMp.Steam.dll -- the relay and the agent both load it (the Steam connection path).
foreach ($f in @('KcdMpServer.exe', 'KcdMpClient.exe', 'KcdMp.Protocol.dll', 'KcdMp.Steam.dll', 'appsettings.json', 'KcdMpClient.deps.json', 'KcdMpServer.deps.json')) {
    if (-not (Test-Path (Join-Path $Payload $f))) { Bad "payload is missing $f"; exit 1 }
}

# ---- A. static coherence of every deps.json against the merged folder ----
$depsFiles = Get-ChildItem $Payload -Filter '*.deps.json' -Recurse
$mismatches = New-Object System.Collections.Generic.List[string]
$checked = 0
foreach ($df in $depsFiles) {
    $folder = $df.DirectoryName
    $json = Get-Content $df.FullName -Raw | ConvertFrom-Json
    foreach ($targetProp in $json.targets.PSObject.Properties) {
        foreach ($libProp in $targetProp.Value.PSObject.Properties) {
            $lib = $libProp.Value
            if (-not $lib.runtime) { continue }
            foreach ($rtProp in $lib.runtime.PSObject.Properties) {
                $want = $rtProp.Value.assemblyVersion
                if (-not $want) { continue }
                $file = Join-Path $folder (Split-Path $rtProp.Name -Leaf)
                if (-not (Test-Path $file)) { continue }   # trimmed / not published: the host would fail loudly, not silently
                if ($file -notmatch '\.dll$') { continue }
                $checked++
                try { $have = [Reflection.AssemblyName]::GetAssemblyName($file).Version.ToString() }
                catch { continue }   # native or resource-only file
                # Compare as versions: "0.26.4" and "0.26.4.0" are the same
                # assembly version. A folder copy HIGHER than listed is what
                # the .NET host accepts (and what the flat merge produces on
                # purpose for shared DLLs); LOWER is a downgrade the loader
                # refuses -- except for type-forwarding facades, where the
                # launcher has shipped that way for every release. Neither is
                # provably fatal from here, so both are reported, not failed;
                # the runtime smoke below is the gate that catches the real
                # failure (an unlisted transitive dependency).
                $vWant = $null; $vHave = $null
                if ([Version]::TryParse($want, [ref]$vWant) -and [Version]::TryParse($have, [ref]$vHave) -and $vWant -ne $vHave) {
                    $dir = if ($vHave -gt $vWant) { 'higher' } else { 'LOWER' }
                    $mismatches.Add(("{0}: {1} lists {2}, folder holds {3} ({4})" -f $df.Name, (Split-Path $file -Leaf), $want, $have, $dir))
                }
            }
        }
    }
}
if ($checked -lt 50) { Bad "coherence check inspected only $checked assemblies -- the payload does not look self-contained" }
else { Ok "coherence check inspected $checked assembly entries across $($depsFiles.Count) deps.json files" }
if ($mismatches.Count -eq 0) { Ok "every deps.json-listed assembly is present at exactly its listed assembly version" }
else {
    Write-Host "  WARN  $($mismatches.Count) deps.json entries differ from the merged folder's assembly versions (the flat merge; informational -- the runtime smoke decides):" -ForegroundColor Yellow
    $mismatches | Sort-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}

# ---- B. runtime smoke from a byte-identical copy ----
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

$work = Join-Path ([IO.Path]::GetTempPath()) ("kcdmp-payload-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item (Join-Path $Payload '*') $work -Recurse -Force

$srcHash = (Get-FileHash (Join-Path $Payload 'KcdMpClient.exe')).Hash
$dstHash = (Get-FileHash (Join-Path $work 'KcdMpClient.exe')).Hash
if ($srcHash -ne $dstHash) { Bad "payload copy hash mismatch"; exit 1 }

$relay = $null
try {
    Write-Host "  payload smoke: relay on 127.0.0.1:$port from a copy of the payload"
    $relayOut = Join-Path $work 'relay-stdout.txt'
    $relayErr = Join-Path $work 'relay-stderr.txt'
    $relay = Start-Process -FilePath (Join-Path $work 'KcdMpServer.exe') `
        -ArgumentList @('--port', "$port", '--Urls', 'http://127.0.0.1:0') `
        -WorkingDirectory $work -PassThru -NoNewWindow `
        -RedirectStandardOutput $relayOut -RedirectStandardError $relayErr
    $null = $relay.Handle   # cache the handle so ExitCode is readable later (PS 5.1 quirk)

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
        Bad "published relay did not listen on $port within $TimeoutSec s (exited=$($relay.HasExited))"
        if (Test-Path $relayErr) { Get-Content $relayErr | Select-Object -First 20 | ForEach-Object { Write-Host "    relay: $_" } }
        if (Test-Path $relayOut) { Get-Content $relayOut | Select-Object -Last 20 | ForEach-Object { Write-Host "    relay: $_" } }
        exit 1
    }
    Ok "published relay listens"

    $agentOut = Join-Path $work 'agent-stdout.txt'
    $agent = Start-Process -FilePath (Join-Path $work 'KcdMpClient.exe') `
        -ArgumentList @('--relay-smoke', '--host', '127.0.0.1', '--port', "$port", '--name', 'payload-smoke', '--no-voice', '--no-discord') `
        -WorkingDirectory $work -PassThru -NoNewWindow -RedirectStandardOutput $agentOut
    $null = $agent.Handle
    if (-not $agent.WaitForExit($TimeoutSec * 1000)) {
        try { $agent.Kill() } catch {}
        Bad "published agent did not exit within $TimeoutSec s"
        exit 1
    }
    $agent.WaitForExit()   # flushes ExitCode after the timed wait
    $code = $agent.ExitCode
    $lines = @()
    if (Test-Path $agentOut) { $lines = Get-Content $agentOut }
    $smoke = $lines | Where-Object { $_ -match 'RELAY-SMOKE' } | Select-Object -Last 1
    if ($code -eq 0 -and $smoke -match 'RELAY-SMOKE ok') { Ok "$smoke" }
    else {
        Bad "agent exit=$code : $smoke"
        $lines | Select-Object -Last 15 | ForEach-Object { Write-Host "    agent: $_" }
        if (Test-Path $relayOut) { Get-Content $relayOut | Select-Object -Last 15 | ForEach-Object { Write-Host "    relay: $_" } }
    }
    $loadErrors = $lines | Where-Object { $_ -match 'Could not load file or assembly|Unhandled exception|FileNotFoundException|TypeLoadException' }
    if ($loadErrors.Count -eq 0) { Ok "published agent logged no assembly-load failure" }
    else {
        Bad "published agent logged $($loadErrors.Count) assembly-load failure line(s) -- the merged payload is not coherent for the agent"
        $loadErrors | Select-Object -First 5 | ForEach-Object { Write-Host "    agent: $_" -ForegroundColor Yellow }
    }

    $relayLog = Get-ChildItem $work -Filter 'relay*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    $relayText = @()
    if ($relayLog) { $relayText += Get-Content $relayLog.FullName }
    if (Test-Path $relayOut) { $relayText += Get-Content $relayOut }
    if (($relayText | Where-Object { $_ -match "'payload-smoke' connected" }).Count -ge 1) { Ok "published relay logged the smoke client's connect" }
    else { Bad "published relay never logged 'payload-smoke' connected" }
    $relayLoadErrors = $relayText | Where-Object { $_ -match 'Could not load file or assembly|Unhandled exception' }
    if ($relayLoadErrors.Count -eq 0) { Ok "published relay logged no assembly-load failure" }
    else {
        Bad "published relay logged $($relayLoadErrors.Count) assembly-load failure line(s)"
        $relayLoadErrors | Select-Object -First 5 | ForEach-Object { Write-Host "    relay: $_" -ForegroundColor Yellow }
    }
}
finally {
    if ($relay -and -not $relay.HasExited) { try { $relay.Kill() } catch {} }
    if ($relay) { try { $relay.WaitForExit(5000) | Out-Null } catch {} }
    Start-Sleep -Milliseconds 300
    try { Remove-Item $work -Recurse -Force -ErrorAction Stop } catch { Write-Host "  (temp folder $work left behind: $($_.Exception.Message))" }
}

Write-Host "`n--------------------------------------------"
Write-Host "  failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
exit 0
