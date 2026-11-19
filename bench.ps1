# Cost channel: microseconds per client per tick for one build, scenario and bot count.
#   .\bench.ps1 -Build b8 -Scenario restricted -PerSide 20          one cell, -Runs repeats, mean and spread
#   .\bench.ps1 -Build b8 -Scenario none -Ladder                    10v10, 20v20, 32v32; stops at the first count that misses tickrate
#   .\bench.ps1 -Baseline                                           Beta 6 and b8, both scenarios, full ladder; writes the table
# Builds: beta6 = the 0.0.b6 source on main, b8 = commit f6d309f, current = scripting\disablescopes.sp in this tree.
# Runs on a private copy of the server (default C:\Users\user\cssds_bench, made with robocopy from cssds) on its own
# port, so it never touches the shared server that test.ps1 uses or collides with another run.
# Exit 0 = every cell finished and repeat runs agreed within -MarginPct; 1 = a run failed or disagreed; 2 = could not start.
# Method: the helper plugin (tests\disablescopes_bench.sp) spawns fake clients, equips them, runs `sm prof start`
# for -Seconds, logs ticks and tickrate, then dumps the vprof report. This script aggregates the report the way the
# AA Crew aggregate_vprof.py does (top-level frames of the plugin only, no double counting) and divides the plugin's
# total time by clients x ticks in the window. Both rules (in air, on ground) are on, so every client takes the
# plugin's full path; "none" holds knives, "restricted" holds the six restricted weapons in rotation.
param(
    [ValidateSet('beta6', 'b8', 'current')][string]$Build = 'current',
    [ValidateSet('none', 'restricted')][string]$Scenario = 'none',
    [int]$PerSide = 10,
    [switch]$Ladder,
    [switch]$Baseline,
    [int]$Runs = 3,
    [int]$Seconds = 30,
    [double]$MarginPct = 25,
    [int]$Tickrate = 66,
    [string]$OutDir = (Join-Path $PSScriptRoot 'bench-results'),
    [string]$ServerDir = $(if ($env:CSS_BENCH_SERVER_DIR) { $env:CSS_BENCH_SERVER_DIR } else { 'C:\Users\user\cssds_bench' }),
    [string]$Map = 'de_dust2',
    [int]$Port = 27135
)
$SourceModDir = Join-Path $ServerDir 'cstrike\addons\sourcemod'
$game = Join-Path $ServerDir 'cstrike'
$smLogs = Join-Path $game 'addons\sourcemod\logs'
$consoleLog = Join-Path $game 'console.log'
$benchLog = Join-Path $smLogs 'disablescopes_bench.log'
$plugins = Join-Path $SourceModDir 'plugins'
$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
$stage = Join-Path ([IO.Path]::GetTempPath()) 'disablescopes_bench'
$ladderSteps = @(10, 20, 32)
$gitRefs = @{ beta6 = 'main'; b8 = 'f6d309f' }

function Get-NewText([string]$path, [long]$from) {
    if (-not (Test-Path $path)) { return '' }
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    if ($from -gt $bytes.Length) { $from = 0 }
    return [Text.Encoding]::UTF8.GetString($bytes, $from, $bytes.Length - $from)
}
function Get-Size([string]$path) { if (Test-Path $path) { (Get-Item $path).Length } else { 0 } }

# Compile one build of the plugin under test into $stage\<build>\disablescopes.smx.
function Build-Plugin([string]$name) {
    $dir = Join-Path $stage $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $src = Join-Path $dir 'disablescopes.sp'
    if ($name -eq 'current') { Copy-Item (Join-Path $PSScriptRoot 'scripting\disablescopes.sp') $src -Force }
    else { & git -C $PSScriptRoot show "$($gitRefs[$name]):scripting/disablescopes.sp" | Set-Content $src -Encoding utf8 }
    & $spcomp $src "-i$SourceModDir\scripting\include" "-o$(Join-Path $dir 'disablescopes.smx')" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "compile failed for $name" }
    return (Join-Path $dir 'disablescopes.smx')
}

# Aggregate a vprof report: time in the plugin's top-level frames only, calls, peak single call.
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

# One server start: returns a result object or throws.
function Invoke-Run([string]$build, [string]$scenario, [int]$perSide, [string]$tag) {
    $mine = Join-Path $ServerDir 'srcds.exe'
    if (Get-Process srcds -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $mine }) { throw 'the bench server is already running; stop it first' }
    $clients = $perSide * 2
    Copy-Item $script:smx (Join-Path $plugins 'disablescopes.smx') -Force
    $sBench = Get-Size $benchLog; $sCon = Get-Size $consoleLog
    $sc = if ($scenario -eq 'restricted') { 1 } else { 0 }
    $a = "-console -game cstrike -condebug -tickrate $Tickrate -port $Port +sv_lan 1 +maxplayers 64 +bot_quota 0 " +
         "+disablescopes_bench_autorun 1 +disablescopes_bench_clients $clients +disablescopes_bench_scenario $sc " +
         "+disablescopes_bench_seconds $Seconds +disablescopes_bench_tickrate $Tickrate +map $Map"
    $proc = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $a -WorkingDirectory $ServerDir -PassThru
    if (-not $proc.WaitForExit(($Seconds + 180) * 1000)) {
        Stop-Process -Id $proc.Id -Force
        throw "server did not quit within $($Seconds + 180)s; killed"
    }
    $log = Get-NewText $benchLog $sBench
    $line = @($log -split "`r?`n" | Where-Object { $_ -match 'BENCH clients=' }) | Select-Object -Last 1
    if (-not $line) { throw 'no BENCH line in the helper log (helper not loaded, or the run died before the window ended)' }
    $kv = @{}
    foreach ($m in [regex]::Matches($line, '(\w+)=([\d.]+)')) { $kv[$m.Groups[1].Value] = [double]$m.Groups[2].Value }
    $con = @((Get-NewText $consoleLog $sCon) -split "`r?`n")
    $b = -1; $e = -1
    for ($i = 0; $i -lt $con.Count; $i++) {
        if ($b -lt 0 -and $con[$i] -match 'BEGIN VPROF REPORT') { $b = $i }
        if ($con[$i] -match 'END VPROF REPORT') { $e = $i }
    }
    if ($b -lt 0 -or $e -le $b) { throw 'no complete vprof report in console.log' }
    $report = $con[$b..$e]
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $report | Set-Content (Join-Path $OutDir "vprof-$tag.txt") -Encoding utf8
    $cost = Get-PluginCost $report 'disablescopes'
    if (-not $cost -or $cost.Calls -eq 0) { throw 'the plugin does not appear in the vprof report' }
    $clientTicks = $kv['clients'] * $kv['ticks']
    $expectHold = if ($sc -eq 1) { $kv['clients'] } else { 0 }
    return [pscustomobject]@{
        Clients = [int]$kv['clients']; Ticks = [int]$kv['ticks']; Seconds = $kv['seconds']; Tickrate = $kv['tickrate']
        Held = ($kv['held'] -eq 1); WeaponsOk = ($kv['holding'] -eq $expectHold -and $kv['alive'] -eq $kv['clients'])
        Holding = [int]$kv['holding']; Alive = [int]$kv['alive']
        UsPerClientTick = $cost.TotalMs * 1000.0 / $clientTicks
        PeakMs = $cost.PeakMs; Calls = $cost.Calls; TotalMs = $cost.TotalMs
    }
}

# Repeated runs of one cell: mean, spread, held, peak.
function Measure-Cell([string]$build, [string]$scenario, [int]$perSide) {
    $rs = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $tag = "$build-$scenario-${perSide}v$perSide-run$i"
        Write-Host "  run $i/$Runs $tag ..." -NoNewline
        $r = Invoke-Run $build $scenario $perSide $tag
        $note = if ($r.WeaponsOk) { '' } else { "  [WEAPONS: holding $($r.Holding)/$($r.Clients), alive $($r.Alive)]" }
        Write-Host (' {0:N3} us/client/tick, peak {1:N2} ms, tickrate {2:N2}{3}' -f $r.UsPerClientTick, $r.PeakMs, $r.Tickrate, $note)
        $rs += $r
    }
    $v = @($rs | ForEach-Object { $_.UsPerClientTick })
    $mean = ($v | Measure-Object -Average).Average
    $spread = 0
    if ($mean -gt 0) { $spread = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean }
    return [pscustomobject]@{
        Build = $build; Scenario = $scenario; PerSide = $perSide
        Us = $mean; SpreadPct = $spread; Agree = ($spread -le $MarginPct)
        PeakMs = ($rs | Measure-Object PeakMs -Maximum).Maximum
        Held = ((($rs | Measure-Object Tickrate -Average).Average) -ge 0.98 * $Tickrate)
        Tickrate = ($rs | Measure-Object Tickrate -Average).Average
        WeaponsOk = (@($rs | Where-Object { -not $_.WeaponsOk }).Count -eq 0)
    }
}

function Measure-Ladder([string]$build, [string]$scenario) {
    $cells = @()
    foreach ($n in $ladderSteps) {
        Write-Host "[$build / $scenario / ${n}v$n]"
        $c = Measure-Cell $build $scenario $n
        $cells += $c
        if (-not $c.Held) { Write-Host "  tickrate not held at ${n}v$n; ladder stops"; break }
    }
    return $cells
}

if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 2 }
& "$PSScriptRoot\build.ps1" -Deploy -SourceModDir $SourceModDir | Out-Null   # deploys the helper plugin and the tree's own build
if ($LASTEXITCODE -ne 0) { Write-Error 'build failed'; exit 2 }
$allCells = @()
$failed = $false
try {
    $builds = if ($Baseline) { @('beta6', 'b8') } else { @($Build) }
    $scenarios = if ($Baseline) { @('none', 'restricted') } else { @($Scenario) }
    foreach ($b in $builds) {
        $script:smx = Build-Plugin $b
        foreach ($s in $scenarios) {
            if ($Baseline -or $Ladder) { $allCells += Measure-Ladder $b $s }
            else { Write-Host "[$b / $s / ${PerSide}v$PerSide]"; $allCells += Measure-Cell $b $s $PerSide }
        }
    }
}
catch { Write-Host "ERROR: $_" -ForegroundColor Red; $failed = $true }
finally { & "$PSScriptRoot\build.ps1" -Deploy -SourceModDir $SourceModDir | Out-Null }   # leave the tree's own build on the bench server

$lines = @()
$lines += "| Build | Scenario | Bots | us/client/tick (mean of $Runs) | Spread | Peak single call (ms) | Mean tickrate | Held $Tickrate |"
$lines += '| --- | --- | --- | --- | --- | --- | --- | --- |'
foreach ($c in $allCells) {
    $over = if ($c.Agree) { '' } else { ' (over margin)' }
    $held = if ($c.Held) { 'yes' } else { 'no' }
    $lines += ('| {0} | {1} | {2}v{2} | {3:N3} | {4:N1}%{5} | {6:N2} | {7:N2} | {8} |' -f $c.Build, $c.Scenario, $c.PerSide, $c.Us, $c.SpreadPct, $over, $c.PeakMs, $c.Tickrate, $held)
}
$lines += ''
foreach ($g in ($allCells | Group-Object { "$($_.Build)/$($_.Scenario)" })) {
    $top = @($g.Group | Where-Object { $_.Held }) | Select-Object -Last 1
    $topText = 'none'
    if ($top) { $topText = "$($top.PerSide)v$($top.PerSide)" }
    $lines += "Highest count that held $Tickrate tick, $($g.Name): $topText"
}
$lines += "Margin: repeat runs of a cell agree when (max - min) / mean is within $MarginPct%."
$lines | ForEach-Object { Write-Host $_ }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$lines | Set-Content (Join-Path $OutDir 'table.md') -Encoding utf8
$bad = @($allCells | Where-Object { -not $_.Agree -or -not $_.WeaponsOk })
if ($failed -or $bad.Count -or -not $allCells.Count) { Write-Host 'RESULT: FAIL' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: PASS' -ForegroundColor Green
exit 0
