<#
Remote cost channel: microseconds per client per tick of the plugin loaded on the remote server (issue #10),
with the same table as bench.ps1 so it can be compared with docs/stage-a-b9.md.

  .\tests\remote\Invoke-RemoteBench.ps1                                  10v10, both scenarios, 3 runs of 30 s
  .\tests\remote\Invoke-RemoteBench.ps1 -Scenario restricted -PerSide 10 -Runs 1

Needs the remote build of the bench helper loaded on the server (Build-RemoteHelpers.ps1; the deploy agent
copies it over). The helper spawns AI-less fake clients, equips them, runs `sm prof start` for -Seconds, logs one
BENCH line and dumps the vprof report to the console. This script starts each run with the server command
`disablescopes_bench_run` (`./cssserver send`), reads the BENCH line from the SourceMod log and the vprof report
from the LinuxGSM console log over ssh, and aggregates it exactly as bench.ps1 does. The helper kicks its bots
at the end and never quits the server. This script never restarts the server.
The run changes mp_* cvars and the plugin's inair/onground cvars: they are recorded first and restored in
`finally` (-NoRestore leaves them for CvarSnapshot.ps1 -Action Restore). It refuses to run while a human is
connected. Exit 0 = every cell finished and repeat runs agreed within -MarginUs; 1 = a run failed or disagreed;
2 = could not start.
#>
param(
    [ValidateSet('none', 'restricted', 'both')][string]$Scenario = 'both',
    [int]$PerSide = 10,
    [int]$Runs = 3,
    [int]$Seconds = 30,
    [double]$MarginUs = 0.3,
    [int]$Tickrate = 66,
    [string]$HostAlias = 'regs1',
    [string]$RemoteSmDir = '',
    [string]$OutDir = (Join-Path $PSScriptRoot 'out\bench'),
    [switch]$NoRestore
)
. "$PSScriptRoot\RemoteLib.ps1"
$benchLogRel = $null

# Same aggregation as bench.ps1 Get-PluginCost (copied: bench.ps1 is a script, not a module).
function Get-PluginCost([string[]]$report, [string]$plugin) {
    $start = -1
    for ($i = 0; $i -lt $report.Count; $i++) { if ($report[$i] -match 'Hierarchical Call Graph') { $start = $i; break } }
    if ($start -lt 0) { return $null }
    $rx = '^\s*([\d.]+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+(\d+)\s+([\d.]+)\s+(.*)$'
    $stack = New-Object System.Collections.Generic.List[string]
    $r = [pscustomobject]@{ TotalMs = 0.0; Calls = 0L; PeakMs = 0.0 }
    for ($i = $start + 1; $i -lt $report.Count; $i++) {
        if ($report[$i] -match '^-- ') { break }
        if ($report[$i] -notmatch $rx) { continue }
        $tot = [double]$Matches[1]; $cnt = [long]$Matches[3]; $peak = [double]$Matches[4]; $raw = $Matches[5]
        $depth = ([regex]::Matches($raw, '\|  ')).Count
        $nm = $raw.Replace('|  ', '').Trim()
        if ($stack.Count -gt $depth) { $stack.RemoveRange($depth, $stack.Count - $depth) }
        if ($nm -like "$plugin.smx::*") {
            $nested = $false
            foreach ($s in $stack) { if ($s -like '*.smx::*') { $nested = $true; break } }
            if (-not $nested) {
                $r.TotalMs += $tot; $r.Calls += $cnt
                if ($peak -gt $r.PeakMs) { $r.PeakMs = $peak }
            }
        }
        $stack.Add($nm)
    }
    return $r
}

function Invoke-Run([string]$scenario, [int]$perSide, [string]$tag) {
    $clients = $perSide * 2
    $sc = if ($scenario -eq 'restricted') { 1 } else { 0 }
    $nBench = Get-RemoteLineCount $benchLogRel
    $nCon = Get-RemoteLineCount $script:RemoteConsoleLog
    [void](Send-RemoteCommands @(
        "disablescopes_bench_clients $clients", "disablescopes_bench_scenario $sc", "disablescopes_bench_seconds $Seconds",
        "disablescopes_bench_tickrate $Tickrate", 'disablescopes_bench_run') -GapSec 0.4 -WaitSec 0.5)
    $deadline = (Get-Date).AddSeconds($Seconds + 120)
    $line = $null; $report = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        if (-not $line) {
            $line = @(Get-RemoteLines $benchLogRel $nBench | Where-Object { $_ -match 'BENCH clients=' }) | Select-Object -Last 1
        }
        if ($line) {
            $con = @(Get-RemoteLines $script:RemoteConsoleLog $nCon)
            $b = -1; $e = -1
            for ($i = 0; $i -lt $con.Count; $i++) {
                if ($b -lt 0 -and $con[$i] -match 'BEGIN VPROF REPORT') { $b = $i }
                if ($con[$i] -match 'END VPROF REPORT') { $e = $i }
            }
            if ($b -ge 0 -and $e -gt $b) { $report = $con[$b..$e]; break }
        }
    }
    if (-not $line) { throw 'no BENCH line in the helper log (helper not loaded, run did not start, or it died before the window ended)' }
    if (-not $report) { throw 'no complete vprof report in the server console log' }
    $kv = @{}
    foreach ($m in [regex]::Matches($line, '(\w+)=([\d.]+)')) { $kv[$m.Groups[1].Value] = [double]$m.Groups[2].Value }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $report | Set-Content (Join-Path $OutDir "vprof-$tag.txt") -Encoding utf8
    # The server runs the plugin as sm_disablescopes.smx (the deployed name), not disablescopes.smx.
    $cost = Get-PluginCost $report 'sm_disablescopes'
    if (-not $cost -or $cost.Calls -eq 0) { throw 'the plugin does not appear in the vprof report' }
    $clientTicks = $kv['clients'] * $kv['ticks']
    $expectHold = if ($sc -eq 1) { $kv['clients'] } else { 0 }
    Start-Sleep 5   # the helper kicks its bots 3 s after the dump
    return [pscustomobject]@{
        Clients = [int]$kv['clients']; Ticks = [int]$kv['ticks']; Seconds = $kv['seconds']; Tickrate = $kv['tickrate']
        Held = ($kv['held'] -eq 1); WeaponsOk = ($kv['holding'] -eq $expectHold -and $kv['alive'] -eq $kv['clients'])
        Holding = [int]$kv['holding']; Alive = [int]$kv['alive']
        UsPerClientTick = $cost.TotalMs * 1000.0 / $clientTicks
        PeakMs = $cost.PeakMs; Calls = $cost.Calls; TotalMs = $cost.TotalMs
    }
}

function Measure-Cell([string]$build, [string]$scenario, [int]$perSide) {
    $rs = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $tag = "$build-$scenario-${perSide}v$perSide-run$i"
        Write-Host "  run $i/$Runs $tag ..." -NoNewline
        $r = Invoke-Run $scenario $perSide $tag
        $note = if ($r.WeaponsOk) { '' } else { "  [WEAPONS: holding $($r.Holding)/$($r.Clients), alive $($r.Alive)]" }
        Write-Host (' {0:N3} us/client/tick, peak {1:N2} ms, tickrate {2:N2}{3}' -f $r.UsPerClientTick, $r.PeakMs, $r.Tickrate, $note)
        $rs += $r
    }
    $v = @($rs | ForEach-Object { $_.UsPerClientTick })
    $mean = ($v | Measure-Object -Average).Average
    $spreadUs = ($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum
    $spread = 0
    if ($mean -gt 0) { $spread = 100.0 * $spreadUs / $mean }
    return [pscustomobject]@{
        Build = $build; Scenario = $scenario; PerSide = $perSide
        Us = $mean; SpreadUs = $spreadUs; SpreadPct = $spread; Agree = ($spreadUs -le $MarginUs)
        PeakMs = ($rs | Measure-Object PeakMs -Maximum).Maximum
        Held = ((($rs | Measure-Object Tickrate -Average).Average) -ge 0.98 * $Tickrate)
        Tickrate = ($rs | Measure-Object Tickrate -Average).Average
        WeaponsOk = (@($rs | Where-Object { -not $_.WeaponsOk }).Count -eq 0)
    }
}

# ---------- preconditions ----------
$snapFile = Join-Path $OutDir 'cvars-before.json'
$restoreNeeded = $false
try {
    Initialize-Remote $HostAlias $RemoteSmDir
    $benchLogRel = "$($script:RemoteSmDir)/logs/disablescopes_bench.log"
    $helper = @(Get-RemotePluginLines | Where-Object { $_ -match 'disablescopes_bench' -and $_ -match '-remote' })
    if (-not $helper.Count) { Write-Error 'the remote build of the bench helper is not loaded (a helper whose version ends in "-remote"); build it with Build-RemoteHelpers.ps1 and ask the deploy agent to load it'; exit 2 }
    $counts = Get-RemotePlayerCounts
    if (-not $counts) { Write-Error 'could not read the player counts from `status`'; exit 2 }
    if ($counts.Humans -gt 0) { Write-Error "$($counts.Humans) human(s) are connected; the bench changes game cvars and spawns bots, so it will not run"; exit 2 }
    $vl = @(Send-RemoteCommand 'sm_disablescopes_version' | Where-Object { $_ -match '"sm_disablescopes_version"\s*=\s*"([^"]*)"' }) | Select-Object -First 1
    if (-not $vl) { Write-Error 'the plugin under test is not loaded (sm_disablescopes_version unreadable)'; exit 2 }
    [void]($vl -match '"sm_disablescopes_version"\s*=\s*"([^"]*)"')
    $build = "$($Matches[1]) ($($script:RemoteHost))"
}
catch { Write-Error "$_"; exit 2 }

$allCells = @()
$failed = $false
try {
    $snap = Save-CvarSnapshot $script:RunCvars $snapFile
    $restoreNeeded = -not $NoRestore
    Write-Host "recorded $($snap.Saved) cvar(s) to $snapFile"
    $scenarios = if ($Scenario -eq 'both') { @('none', 'restricted') } else { @($Scenario) }
    foreach ($s in $scenarios) { Write-Host "[$build / $s / ${PerSide}v$PerSide]"; $allCells += Measure-Cell $build $s $PerSide }
}
catch { Write-Host "ERROR: $(Protect-Text "$_")" -ForegroundColor Red; $failed = $true }
finally {
    if ($restoreNeeded) {
        try {
            $r = Restore-CvarSnapshot $snapFile
            Write-Host "cvars restored: $(if ($r.Restored.Count) { $r.Restored -join ', ' } else { 'none changed' })"
            foreach ($p in $r.Problems) { Write-Host "ERROR: $p" -ForegroundColor Red; $failed = $true }
        }
        catch { Write-Host "ERROR: cvar restore failed: $(Protect-Text "$_")" -ForegroundColor Red; $failed = $true }
    }
}

$lines = @()
$lines += "| Build | Scenario | Bots | us/client/tick (mean of $Runs) | Spread | Peak single call (ms) | Mean tickrate | Held $Tickrate |"
$lines += '| --- | --- | --- | --- | --- | --- | --- | --- |'
foreach ($c in $allCells) {
    $over = if ($c.Agree) { '' } else { ' (over margin)' }
    $held = if ($c.Held) { 'yes' } else { 'no' }
    $lines += ('| {0} | {1} | {2}v{2} | {3:N3} | {9:N3} us ({4:N1}%){5} | {6:N2} | {7:N2} | {8} |' -f $c.Build, $c.Scenario, $c.PerSide, $c.Us, $c.SpreadPct, $over, $c.PeakMs, $c.Tickrate, $held, $c.SpreadUs)
}
$lines += ''
foreach ($g in ($allCells | Group-Object { "$($_.Build)/$($_.Scenario)" })) {
    $top = @($g.Group | Where-Object { $_.Held }) | Select-Object -Last 1
    $topText = 'none'
    if ($top) { $topText = "$($top.PerSide)v$($top.PerSide)" }
    $lines += "Highest count that held $Tickrate tick, $($g.Name): $topText"
}
$lines += "Margin: repeat runs of a cell agree when max - min is within $MarginUs us."
$lines | ForEach-Object { Write-Host $_ }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$lines | Set-Content (Join-Path $OutDir 'table.md') -Encoding utf8
$bad = @($allCells | Where-Object { -not $_.Agree -or -not $_.WeaponsOk })
if ($failed -or $bad.Count -or -not $allCells.Count) { Write-Host 'RESULT: FAIL' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: PASS' -ForegroundColor Green
exit 0
