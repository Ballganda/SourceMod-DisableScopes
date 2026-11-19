<#
Ticket #4 spike: does a client-recorded demo show a scope the client predicted and the server corrected?

Reproduces a predicted-then-corrected scope on demand on the local cssds server, with the real CS:S client:
  1. deploys the plugin under test (build.ps1 -Deploy) plus the scope_spike helper, starts srcds,
  2. launches the client with scope_spike.cfg (binds F2-F10 to the spike aliases), waits for the helper
     to put it on CT with an AWP,
  3. records a client demo while it injects keys: per simulated latency (server net_fakelag), a ground
     scope cycle (allowed: positive control) and N jump-then-scope attempts (blocked by inair=1),
  4. samples the screen the whole time (ScopeProbe.cs: scoped / unscoped per sample),
  5. plays the demo back in the same client and samples the screen again,
  6. mines the demo, the server log and both captures (mine_spike.py) into summary.json / summary.txt.
Leave the game window alone during the run. Restores the client config.cfg and removes the helper.
Usage: .\tests\spike\Run-ScopeSpike.ps1 [-Lags 0,150,250] [-Reps 5]
Exit: 0 done (read the summary), 2 could not start / aborted.
#>
param(
    [int[]]$Lags = @(0, 150, 250),
    [int]$Reps = 5,
    [string]$ServerDir = $(if ($env:CSS_SERVER_DIR) { $env:CSS_SERVER_DIR } else { 'C:\Users\user\cssds' }),
    [string]$ClientDir = $(if ($env:CSS_CLIENT_DIR) { $env:CSS_CLIENT_DIR } else { 'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source' }),
    [string]$OutDir = (Join-Path $PSScriptRoot ('out\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))),
    [switch]$NoBuild,
    [string]$PlaybackOnly = ''     # a run dir: replay its scope_spike.dem offline in the client, write playback.csv again
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$game = Join-Path $ServerDir 'cstrike'
$sm = Join-Path $game 'addons\sourcemod'
$clientGame = Join-Path $ClientDir 'cstrike'
$steam = Join-Path (Split-Path (Split-Path (Split-Path $ClientDir))) 'steam.exe'
$demoName = 'scope_spike'
$lagKeys = @{ 0 = 0x74; 150 = 0x75; 250 = 0x73 }   # F5, F6, F4
foreach ($l in $Lags) { if (-not $lagKeys.ContainsKey($l)) { Write-Error "lag $l has no key (use 0, 150, 250)"; exit 2 } }

$exe = Join-Path $ServerDir 'srcds.exe'
if (Get-Process srcds -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) { Write-Error "srcds already running from $ServerDir"; exit 2 }
if (Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue) { Write-Error 'a CS:S client is already running'; exit 2 }
Add-Type -Path (Join-Path $PSScriptRoot '..\client\ScopeProbe.cs') -ReferencedAssemblies System.Drawing

# Samples the screen while the client plays the demo; a snapshot every 3 s shows what the probe saw.
function Watch-Playback($hwnd, [int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    $n = 0
    while ((Get-Date) -lt $end) {
        Start-Sleep 3
        $n++
        [ScopeProbe]::Snapshot($hwnd, (Join-Path $OutDir ('playback_{0:D2}.png' -f $n)))
    }
    [ScopeProbe]::Stop((Join-Path $OutDir 'playback.csv'))
}

if ($PlaybackOnly) {
    $OutDir = $PlaybackOnly
    Copy-Item (Join-Path $OutDir "$demoName.dem") (Join-Path $clientGame "$demoName.dem") -Force
    try {
        Start-Process $steam -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +fps_max 100 +playdemo $demoName"
        $deadline = (Get-Date).AddSeconds(90)
        do { Start-Sleep 1; $cli = Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue | Select-Object -First 1 }
        while ((-not $cli -or $cli.MainWindowHandle -eq [IntPtr]::Zero) -and (Get-Date) -lt $deadline)
        if (-not $cli) { Write-Error 'client did not start'; exit 2 }
        $hwnd = $cli.MainWindowHandle
        [ScopeProbe]::Place($hwnd)
        [ScopeProbe]::Start($hwnd)
        [ScopeProbe]::Mark('key playdemo')
        $tail = Import-Csv (Join-Path $OutDir 'live.csv') | Where-Object kind -eq 'mark' | Select-Object -Last 1
        Watch-Playback $hwnd ([math]::Ceiling([double]$tail.t_ms / 1000) + 40)
    }
    finally {
        Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        Remove-Item (Join-Path $clientGame "$demoName.dem") -ErrorAction SilentlyContinue
    }
    python -I (Join-Path $PSScriptRoot 'mine_spike.py') $OutDir
    exit 0
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

if (-not $NoBuild) {
    & (Join-Path $repo 'build.ps1') -Deploy | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error 'build failed'; exit 2 }
}
& (Join-Path $sm 'scripting\spcomp.exe') (Join-Path $PSScriptRoot 'scope_spike.sp') "-i$sm\scripting\include" "-o$sm\plugins\scope_spike.smx" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error 'scope_spike.sp failed to compile'; exit 2 }

$cfgPath = Join-Path $clientGame 'cfg\config.cfg'
$cfgBackup = Join-Path $OutDir 'client_config.cfg.bak'
Copy-Item $cfgPath $cfgBackup
@'
// scope spike client settings (written by Run-ScopeSpike.ps1; config.cfg is restored afterwards)
fps_max 100
cl_cmdrate 100
cl_updaterate 100
rate 100000
net_graph 0
cl_predict 1
alias spike_scope "+attack2; wait 3; -attack2"
alias spike_air "+jump; wait 6; +attack2; wait 3; -attack2; wait 3; -jump"
bind F2 "disconnect; playdemo scope_spike"
bind F3 "spike_reset"
bind F4 "spike_lag 250"
bind F5 "spike_lag 0"
bind F6 "spike_lag 150"
bind F7 "spike_scope"
bind F8 "spike_air"
bind F9 "record scope_spike"
bind F10 "stop"
'@ | Set-Content (Join-Path $clientGame 'cfg\scope_spike.cfg') -Encoding ascii
Remove-Item (Join-Path $clientGame "$demoName.dem") -ErrorAction SilentlyContinue

$csv = Join-Path $sm 'logs\scope_spike.csv'
Remove-Item $csv -ErrorAction SilentlyContinue
$srv = $null; $cli = $null
try {
    $srcdsArgs = '-console -game cstrike -condebug -tickrate 100 +sv_lan 1 +maxplayers 10 +bot_quota 0 +map de_dust2'
    $srv = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -PassThru
    Start-Sleep 20
    $ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway)[0].IPv4Address.IPAddress
    Start-Process $steam -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +exec scope_spike.cfg +connect ${ip}:27015"
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 2
        if ((Test-Path $csv) -and (Select-String -Path $csv -Pattern '^ready' -Quiet)) { break }
    }
    if (-not ((Test-Path $csv) -and (Select-String -Path $csv -Pattern '^ready' -Quiet))) { throw 'client never became ready (scope_spike.csv has no ready row)' }
    $cli = Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue | Select-Object -First 1
    $hwnd = $cli.MainWindowHandle
    [ScopeProbe]::Place($hwnd)
    Start-Sleep 3
    [ScopeProbe]::Focus($hwnd)
    Start-Sleep 1
    [ScopeProbe]::Key($hwnd, 0x72, 'reset')          # F3: fresh AWP, view set, unscoped
    Start-Sleep 2
    [ScopeProbe]::Snapshot($hwnd, (Join-Path $OutDir 'baseline.png'))
    if (-not (Select-String -Path $csv -Pattern '^reset' -Quiet)) { throw 'injected key F3 never reached the server (no reset row); see baseline.png' }
    $d = ''
    if ([ScopeProbe]::Classify($hwnd, [ref]$d) -ne 0) { throw "baseline classifies as scoped (edges $d); see baseline.png" }

    # --- live run, recorded as a client demo ---
    [ScopeProbe]::Start($hwnd)
    [ScopeProbe]::Key($hwnd, 0x78, 'record')
    Start-Sleep 2
    foreach ($lag in $Lags) {
        [ScopeProbe]::Key($hwnd, [byte]$lagKeys[$lag], "lag $lag")
        Start-Sleep 2
        foreach ($i in 1..3) {                        # ground: zoom 1, zoom 2, unzoom (allowed)
            [ScopeProbe]::Key($hwnd, 0x76, "ground $lag $i")
            Start-Sleep -Milliseconds 1500
        }
        foreach ($i in 1..$Reps) {                    # jump then scope (blocked in air)
            [ScopeProbe]::Key($hwnd, 0x77, "air $lag $i")
            Start-Sleep -Milliseconds 2500
        }
    }
    [ScopeProbe]::Key($hwnd, 0x74, 'lag 0')
    Start-Sleep 1
    [ScopeProbe]::Key($hwnd, 0x79, 'stop')
    Start-Sleep 1
    [ScopeProbe]::Stop((Join-Path $OutDir 'live.csv'))
    $liveSec = [math]::Ceiling([ScopeProbe]::Now() / 1000)

    # --- demo playback in the same client ---
    [ScopeProbe]::Start($hwnd)
    [ScopeProbe]::Key($hwnd, 0x71, 'playdemo')
    Watch-Playback $hwnd ([math]::Ceiling([ScopeProbe]::Now() / 1000) + 20)
}
catch {
    Write-Host "ABORTED: $_" -ForegroundColor Red
    $failed = $true
}
finally {
    $c = Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue
    if ($c) { $c | Stop-Process -Force }
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force }
    Start-Sleep 2
    Copy-Item $cfgBackup $cfgPath -Force
    Remove-Item (Join-Path $clientGame 'cfg\scope_spike.cfg') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $sm 'plugins\scope_spike.smx') -ErrorAction SilentlyContinue
    if (Test-Path $csv) { Copy-Item $csv (Join-Path $OutDir 'server.csv') }
    $dem = Join-Path $clientGame "$demoName.dem"
    if (Test-Path $dem) { Move-Item $dem (Join-Path $OutDir "$demoName.dem") -Force }
}
if ($failed) { exit 2 }
python -I (Join-Path $PSScriptRoot 'mine_spike.py') $OutDir
Write-Host "results: $OutDir"
exit 0
