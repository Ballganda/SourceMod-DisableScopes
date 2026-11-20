<#
Client-view channel: runs the client case with the real CS:S client and judges it against server state.
Called by test.ps1 -Client after the server-only suite; not meant to be run on its own.

Case: a player holding an AWP (restricted) jumps and presses scope while the in-air rule is on.
It passes only when the screen shows no scope in any attempt and server state agrees.

  1. deploys the disablescopes_client helper, starts srcds (minimised), launches the client with a
     generated cfg of binds and aliases (wait-based), waits for the helper's ready row,
  2. records a client demo while injecting keys: one ground scope cycle (allowed: the positive
     control) and $Reps jump-then-scope attempts, each from a fresh AWP,
  3. samples the screen the whole time (ScopeProbe.cs, live channel),
  4. disconnects (the helper then quits the server) and plays the demo back in the same client,
     sampling the screen again (playback channel, the one the spike chose for flicker),
  5. stops the client, restores every file under the client's cfg directory, removes the helper,
  6. matches both captures to the helper's per-command server log by time and judges the case.
Returns one object: Status (PASS, FAIL or SKIP), Name, Detail, and Problems (setup faults).
A SKIP means the case could not run; test.ps1 counts it as a failure.
#>
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$ClientDir,
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$SelfCheck,
    [int]$Reps = 3,
    [int]$Port = 27015,
    [string]$Map = 'de_dust2'
)
$ErrorActionPreference = 'Stop'
$caseName = 'client view: AWP jump + scope is blocked on screen and on the server (inair 1)'
$game = Join-Path $ServerDir 'cstrike'
$sm = Join-Path $game 'addons\sourcemod'
$clientGame = Join-Path $ClientDir 'cstrike'
$clientCfgDir = Join-Path $clientGame 'cfg'
$steam = Join-Path (Split-Path (Split-Path (Split-Path $ClientDir))) 'steam.exe'
$clientNames = 'cstrike_win64', 'cstrike', 'hl2'
$demo = 'dsc_case'
$helperSmx = Join-Path $sm 'plugins\disablescopes_client.smx'
$serverCsv = Join-Path $sm 'logs\disablescopes_client.csv'
$VK = @{ Playback = 0x71; Reset = 0x72; Ground = 0x76; Air = 0x77; Record = 0x78; Stop = 0x79 }   # F2 F3 F7 F8 F9 F10
$AirWindowMs = 2000      # an attempt is judged from its key press to this long after it
$problems = New-Object System.Collections.Generic.List[string]

function New-Result([string]$status, [string]$detail) {
    [pscustomobject]@{ Status = $status; Name = $caseName; Detail = $detail; Problems = @($problems) }
}

# ---------- client cfg directory: snapshot, restore, verify ----------
function Get-CfgHashes {
    $h = @{}
    Get-ChildItem $clientCfgDir -Recurse -File | ForEach-Object { $h[$_.FullName] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    return $h
}
function Restore-ClientCfg($hashes, [string]$backupDir) {
    $now = Get-CfgHashes
    foreach ($f in $now.Keys) {
        if (-not $hashes.ContainsKey($f)) { Remove-Item $f -Force }                     # written during the run
        elseif ($now[$f] -ne $hashes[$f]) { Copy-Item (Join-Path $backupDir $f.Substring($clientCfgDir.Length)) $f -Force }
    }
    foreach ($f in $hashes.Keys) {
        if (-not (Test-Path $f)) { Copy-Item (Join-Path $backupDir $f.Substring($clientCfgDir.Length)) $f -Force }
    }
    $after = Get-CfgHashes
    $changed = @($hashes.Keys | Where-Object { $after[$_] -ne $hashes[$_] }) + @($after.Keys | Where-Object { -not $hashes.ContainsKey($_) })
    foreach ($f in $changed) { $problems.Add("client config not restored: $f") }
}

# ---------- capture and server log parsing ----------
function Read-Capture([string]$path) {
    $marks = New-Object System.Collections.Generic.List[object]
    $iv = New-Object System.Collections.Generic.List[object]
    $start = $null; $last = 0.0
    foreach ($r in (Import-Csv $path)) {
        $t = [double]$r.t_ms; $last = $t
        if ($r.kind -eq 'mark') { $marks.Add([pscustomobject]@{ T = $t; Label = $r.value }) }
        elseif ($r.kind -eq 'state') {
            if ($r.value -eq '1' -and $null -eq $start) { $start = $t }
            elseif ($r.value -eq '0' -and $null -ne $start) { $iv.Add([pscustomobject]@{ S = $start; E = $t }); $start = $null }
        }
    }
    if ($null -ne $start) { $iv.Add([pscustomobject]@{ S = $start; E = $last }) }
    return [pscustomobject]@{ Marks = $marks; Scoped = $iv }
}
function Get-KeyTimes($capture, [string]$prefix) {
    @($capture.Marks | Where-Object { $_.Label -like "key $prefix*" } | ForEach-Object { $_.T })
}
function Get-ScopedIn($capture, [double]$from, [double]$to) {
    @($capture.Scoped | Where-Object { $_.E -gt $from -and $_.S -lt $to })
}
function Test-Zoomed($row) { $f = [int]$row.fov; return $f -gt 0 -and $f -lt 90 }

# ---------- the judgement ----------
# Live screen samples share the probe's clock with the key marks. Server rows carry the server's
# engine time. Every key also runs "dsc_mark", so each key has a probe time and a server time; the
# smallest server-minus-probe difference is the clock offset (the least-delayed mark), and every
# server row is placed on the probe's timeline with it. The playback capture has its own clock and
# is placed on the live timeline by its ground-control scope, the one long scope both must show.
function Measure-Case($live, $playback, $rows) {
    $why = New-Object System.Collections.Generic.List[string]
    $facts = New-Object System.Collections.Generic.List[string]

    $keyG = Get-KeyTimes $live 'ground'; $keyA = Get-KeyTimes $live 'air'; $keyR = Get-KeyTimes $live 'reset'
    $srvMarks = @($rows | Where-Object kind -eq 'mark')
    $srvG = @($srvMarks | Where-Object text -eq 'ground'); $srvA = @($srvMarks | Where-Object text -eq 'air')
    $srvScope = @($srvMarks | Where-Object text -eq 'scope')
    if ($srvG.Count -ne $keyG.Count -or $srvA.Count -ne $keyA.Count -or $srvScope.Count -ne $keyA.Count) {
        $why.Add("keys did not all reach the server (ground $($srvG.Count)/$($keyG.Count), air $($srvA.Count)/$($keyA.Count), scope $($srvScope.Count)/$($keyA.Count))")
        return [pscustomobject]@{ Pass = $false; Why = $why; Facts = $facts }
    }
    $diffs = @()
    for ($i = 0; $i -lt $keyG.Count; $i++) { $diffs += [double]$srvG[$i].engine_ms - $keyG[$i] }
    for ($i = 0; $i -lt $keyA.Count; $i++) { $diffs += [double]$srvA[$i].engine_ms - $keyA[$i] }
    $offset = ($diffs | Measure-Object -Minimum).Minimum
    $spread = ($diffs | Measure-Object -Maximum).Maximum - $offset
    $facts.Add(('clock offset spread {0:F0} ms over {1} marks' -f $spread, $diffs.Count))
    if ($spread -gt 150) { $why.Add(('server and screen clocks do not line up (mark delay spread {0:F0} ms)' -f $spread)) }
    $cmds = @($rows | Where-Object kind -eq 'cmd' | ForEach-Object {
        [pscustomobject]@{ T = [double]$_.engine_ms - $offset; OnGround = [int]$_.onground; Zoomed = (Test-Zoomed $_); Weapon = $_.weapon }
    })

    # positive control: the allowed ground scope must be on screen while the server has it zoomed
    $gFrom = $keyG[0]; $gTo = (@($keyR | Where-Object { $_ -gt $gFrom }) + @($keyA[0]))[0]
    $gLive = @(Get-ScopedIn $live $gFrom $gTo | Sort-Object { $_.S - $_.E } | Select-Object -First 1)
    if (-not $gLive) { $why.Add('positive control: the allowed ground scope never showed on the live screen') }
    else {
        $g = $gLive[0]
        $inside = @($cmds | Where-Object { $_.T -ge $g.S + 100 -and $_.T -le $g.E - 100 })
        $agree = @($inside | Where-Object Zoomed).Count
        $facts.Add(('ground control: live scoped {0:F0} ms, server zoomed in {1}/{2} matching cmds' -f ($g.E - $g.S), $agree, $inside.Count))
        if (-not $inside.Count -or $agree -lt 0.9 * $inside.Count) { $why.Add('positive control: server state does not match the scope on screen') }
    }

    # playback placed on the live timeline by the ground-control scope
    $pbOffset = $null
    if ($gLive -and $playback) {
        $want = $gLive[0].E - $gLive[0].S
        $cand = @($playback.Scoped | Where-Object { [math]::Abs(($_.E - $_.S) - $want) -le 400 } | Select-Object -First 1)
        if ($cand) { $pbOffset = $cand[0].S - $gLive[0].S; $facts.Add(('playback ground control {0:F0} ms' -f ($cand[0].E - $cand[0].S))) }
        else { $why.Add('playback: the ground-control scope never showed, so playback cannot be placed in time') }
    }
    elseif (-not $playback) { $why.Add('playback capture missing') }

    # the case: each jump-then-scope attempt
    $liveHits = 0; $pbHits = 0; $srvZoom = 0; $srvPress = 0
    for ($i = 0; $i -lt $keyA.Count; $i++) {
        $from = $keyA[$i]; $to = $from + $AirWindowMs
        $n = $i + 1
        $l = @(Get-ScopedIn $live $from $to)
        if ($l.Count) { $liveHits++; $why.Add(('attempt {0}: live screen scoped {1:F0} ms after the key, for {2:F0} ms' -f $n, ($l[0].S - $from), ($l[0].E - $l[0].S))) }
        if ($null -ne $pbOffset) {
            $p = @(Get-ScopedIn $playback ($from + $pbOffset) ($to + $pbOffset))
            if ($p.Count) { $pbHits++; $why.Add(('attempt {0}: playback screen scoped for {1:F0} ms' -f $n, ($p[0].E - $p[0].S))) }
        }
        $w = @($cmds | Where-Object { $_.T -ge $from -and $_.T -le $to })
        $air = @($w | Where-Object { $_.OnGround -eq 0 })
        $z = @($w | Where-Object Zoomed)
        $wrongWeapon = @($w | Where-Object { $_.Weapon -ne 'weapon_awp' })
        $scopeRow = $srvScope[$i]
        if ([int]$srvA[$i].ready2 -ne 1) { $why.Add("attempt ${n}: the AWP could not scope yet when the jump began (still deploying; case not exercised)") }
        if (-not $air.Count) { $why.Add("attempt ${n}: the server never saw the player in the air") }
        if ([int]$scopeRow.onground -ne 0) { $why.Add("attempt ${n}: the scope press reached the server while on the ground (case not exercised)") }
        else { $srvPress++ }
        if ($wrongWeapon.Count) { $why.Add("attempt ${n}: the player was not holding the AWP") }
        if ($z.Count) { $srvZoom++; $why.Add("attempt ${n}: server fov zoomed in $($z.Count) cmds ($(@($z | Where-Object { $_.OnGround -eq 0 }).Count) in the air)") }
    }
    $facts.Add("live scoped $liveHits/$($keyA.Count), playback scoped $(if ($null -ne $pbOffset) { $pbHits } else { '?' })/$($keyA.Count), server zoomed $srvZoom/$($keyA.Count), scope pressed in air $srvPress/$($keyA.Count)")
    return [pscustomobject]@{ Pass = ($why.Count -eq 0); Why = $why; Facts = $facts }
}

# ---------- run ----------
foreach ($p in @($steam, (Join-Path $ClientDir 'cstrike_win64.exe'))) {
    if (-not (Test-Path $p)) { return New-Result 'SKIP' "client not installed ($p not found)" }
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot 'ScopeProbe.cs') -ReferencedAssemblies System.Drawing

& (Join-Path $sm 'scripting\spcomp.exe') (Join-Path $PSScriptRoot 'disablescopes_client.sp') "-i$sm\scripting\include" "-o$helperSmx" | Out-Null
if ($LASTEXITCODE -ne 0) { return New-Result 'SKIP' 'disablescopes_client.sp failed to compile' }

$srv = $null; $skip = $null; $cfgHashes = $null
try {
$cfgHashes = Get-CfgHashes
$cfgBackup = Join-Path $OutDir 'client_cfg_backup'
Copy-Item $clientCfgDir $cfgBackup -Recurse -Force
@"
// DisableScopes client-view case (written by test.ps1 -Client; removed afterwards)
fps_max 100
cl_cmdrate 100
cl_updaterate 100
rate 100000
net_graph 0
cl_predict 1
alias dsc_scope "+attack2; wait 3; -attack2"
alias dsc_air "+jump; wait 6; dsc_mark scope; +attack2; wait 3; -attack2; wait 3; -jump"
bind F2 "disconnect; playdemo $demo"
bind F3 "dsc_reset"
bind F7 "dsc_mark ground; dsc_scope"
bind F8 "dsc_mark air; dsc_air"
bind F9 "record $demo"
bind F10 "stop"
"@ | Set-Content (Join-Path $clientCfgDir 'dsc_case.cfg') -Encoding ascii
Remove-Item (Join-Path $clientGame "$demo.dem") -ErrorAction SilentlyContinue
Remove-Item $serverCsv -ErrorAction SilentlyContinue

    $srcdsArgs = "-console -game cstrike -condebug -tickrate 100 -port $Port +sv_lan 1 +maxplayers 10 +bot_quota 0 " +
                 "+disablescopes_client_selfcheck $([int][bool]$SelfCheck) +map $Map"
    Write-Host 'Starting srcds for the client case...'
    $srv = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -WindowStyle Minimized -PassThru
    Start-Sleep 20
    $ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway)[0].IPv4Address.IPAddress
    Write-Host "Launching the client (connect ${ip}:27015)..."
    Start-Process $steam -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 +exec dsc_case.cfg +connect ${ip}:$Port"
    $deadline = (Get-Date).AddSeconds(240)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) {
        Start-Sleep 2
        $ready = (Test-Path $serverCsv) -and (Select-String -Path $serverCsv -Pattern '^ready' -Quiet)
        if ($srv.HasExited) { throw 'srcds exited before the client was ready' }
    }
    if (-not $ready) { throw 'client never became ready (no ready row from the helper)' }
    $cli = Get-Process $clientNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if (-not $cli) { throw 'client window not found' }
    $hwnd = $cli.MainWindowHandle
    [ScopeProbe]::Place($hwnd)
    Start-Sleep 3
    [ScopeProbe]::Focus($hwnd)
    Start-Sleep 1
    [ScopeProbe]::Key($hwnd, $VK.Reset, 'reset')
    Start-Sleep 2
    [ScopeProbe]::Snapshot($hwnd, (Join-Path $OutDir 'baseline.png'))
    if (-not (Select-String -Path $serverCsv -Pattern '^reset' -Quiet)) { throw 'injected key never reached the server (no reset row); see baseline.png' }
    $d = ''
    if ([ScopeProbe]::Classify($hwnd, [ref]$d) -ne 0) { throw "baseline screen classifies as scoped (edges $d); see baseline.png" }

    Write-Host 'Running the case (leave the game window alone)...'
    [ScopeProbe]::Start($hwnd)
    [ScopeProbe]::Key($hwnd, $VK.Record, 'record')
    Start-Sleep 2
    foreach ($i in 1..3) {                                   # ground: zoom 1, zoom 2, unzoom (allowed)
        [ScopeProbe]::Key($hwnd, $VK.Ground, "ground $i")
        Start-Sleep -Milliseconds 1500
    }
    foreach ($i in 1..$Reps) {                               # fresh AWP, then jump and scope (blocked)
        [ScopeProbe]::Key($hwnd, $VK.Reset, "reset $i")
        Start-Sleep -Milliseconds 2000                       # the fresh AWP finishes deploying (it cannot scope before)
        [ScopeProbe]::Key($hwnd, $VK.Air, "air $i")
        Start-Sleep -Milliseconds ($AirWindowMs + 500)
    }
    [ScopeProbe]::Key($hwnd, $VK.Stop, 'stop')
    Start-Sleep 1
    [ScopeProbe]::Stop((Join-Path $OutDir 'live.csv'))

    Write-Host 'Playing the demo back...'
    [ScopeProbe]::Start($hwnd)
    # the client disconnects before it plays the demo; the helper logs that, so a lost key is retried
    $left = $false
    foreach ($try in 1..3) {
        [ScopeProbe]::Key($hwnd, $VK.Playback, 'playdemo')
        $wait = (Get-Date).AddSeconds(6)
        while (-not $left -and (Get-Date) -lt $wait) {
            Start-Sleep -Milliseconds 250
            $left = Select-String -Path $serverCsv -Pattern '^disconnect' -Quiet
        }
        if ($left) { break }
    }
    if (-not $left) { [ScopeProbe]::Stop((Join-Path $OutDir 'playback.csv')); throw 'demo playback never started (the client did not disconnect after 3 key presses)' }
    $liveDur = [double](Import-Csv (Join-Path $OutDir 'live.csv') | Select-Object -Last 1).t_ms
    $end = (Get-Date).AddMilliseconds($liveDur + 25000)
    $n = 0
    while ((Get-Date) -lt $end) {
        Start-Sleep 3
        $n++
        if ($n % 3 -eq 0) { [ScopeProbe]::Snapshot($hwnd, (Join-Path $OutDir ('playback_{0:D2}.png' -f $n))) }
    }
    [ScopeProbe]::Stop((Join-Path $OutDir 'playback.csv'))
}
catch {
    $skip = "$_"
}
finally {
    Get-Process $clientNames -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($srv -and -not $srv.WaitForExit(15000)) { Stop-Process -Id $srv.Id -Force; $problems.Add('client-case srcds did not quit after the client left; it was killed') }
    Start-Sleep 2
    $dem = Join-Path $clientGame "$demo.dem"
    if (Test-Path $dem) { Move-Item $dem (Join-Path $OutDir "$demo.dem") -Force }
    if ($cfgHashes) { Restore-ClientCfg $cfgHashes $cfgBackup }
    Remove-Item $helperSmx -ErrorAction SilentlyContinue
    if (Test-Path $helperSmx) { $problems.Add("helper plugin still deployed: $helperSmx") }
    if (Test-Path $serverCsv) { Copy-Item $serverCsv (Join-Path $OutDir 'server.csv') -Force }
}
if ($skip) { return New-Result 'SKIP' "case did not run: $skip" }

$live = Read-Capture (Join-Path $OutDir 'live.csv')
$playback = if (Test-Path (Join-Path $OutDir 'playback.csv')) { Read-Capture (Join-Path $OutDir 'playback.csv') } else { $null }
$rows = @(Import-Csv (Join-Path $OutDir 'server.csv'))
$ready = @($rows | Where-Object kind -eq 'ready')
if ($SelfCheck -and $ready.Count -and $ready[-1].text -ne 'selfcheck') { $problems.Add('self-check requested but the helper did not disable the plugin') }
$v = Measure-Case $live $playback $rows
$detail = (@($v.Facts) + @($v.Why)) -join '; '
return New-Result $(if ($v.Pass) { 'PASS' } else { 'FAIL' }) $detail
