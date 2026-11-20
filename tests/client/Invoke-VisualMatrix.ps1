<#
Visual matrix: every case with an on-screen result, run through the client-view channel at
simulated latency of 0, 50, 150 and 250 ms in one unattended run (ticket #7).
Called by test.ps1 -Matrix after the server-only suite; it can also run on its own, with
-Ref to measure another build (for example the Beta 6 tag) as a baseline.

  1. deploys the plugin under test (the working tree, or -Ref compiled from git) and the
     disablescopes_matrix helper, starts srcds (minimised, on -Port), launches the client with a
     generated cfg of binds and aliases, waits for the helper's ready row,
  2. for each latency (the helper sets server net_fakelag): for each case the client selects the
     case (helper sets the cvars and gives the weapon), then injects the case's keys,
  3. samples the screen the whole time (ScopeProbe.cs, live channel), and reads the client's own
     console log for the shots the client shows,
  4. stops the client, restores every file under the client's cfg directory, removes the helper,
  5. judges every (case, latency) against the rule from the helper's per-command server log, the
     live screen capture and the client's shot lines.

On-screen results exist for weapons whose scope paints the black overlay the probe reads (AWP,
scout, G3SG1, SG550). SG552 and AUG zoom without an overlay; they stay in the server-state suite.

Case verdicts (the client's shot is a change of the clip counter on its ammo HUD, read from the screen):
  blocked   scoped screen time only within one round trip (latency plus 100 ms) of the window key
            that starts the block, none after it (issues #7, #9); no zoomed command in a blocked
            state on the server
  allowed   scoped screen time of at least 300 ms in the window and a zoomed command on the server
  shots     every shot the client shows is a shot the server registered (counts per case equal),
            and a shot in a blocked state has an unzoomed field of view on the server
Remote mode (-Remote <ssh alias>, issue #10): no local srcds. The local client connects to the remote server
(address from `ssh -G <alias>`, port -Port) and the matrix runs at the real ping instead of simulated latency
(one pass; the helper's dsc_lag only logs a row). Needs the remote build of disablescopes_matrix (version ending
in -remote, from tests\remote\Build-RemoteHelpers.ps1) already loaded by the deploy agent, and no other human on the
server. Server-side numbers (the helper's csv) are read over ssh; the ping comes from the client's own `status`
output (client name dsc_probe), sampled before and after the run; the blocked-scope allowance is that ping plus
the usual 100 ms. The run changes mp_* and plugin cvars: they are recorded first and restored afterwards. The
server is never restarted. See tests\remote\RemoteLib.ps1 for the ssh rules.

Returns one object: Status (PASS, FAIL or SKIP), Name, Detail, Problems (setup faults), Rows.
A SKIP means the matrix could not run; test.ps1 counts it as a failure.
#>
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Local')][string]$ServerDir,
    [Parameter(Mandatory, ParameterSetName = 'Remote')][string]$Remote,   # ssh alias of the remote server (regs1)
    [Parameter(ParameterSetName = 'Remote')][string]$RemoteSmDir = '',
    [Parameter(ParameterSetName = 'Remote')][switch]$NoRestore,
    [Parameter(Mandatory)][string]$ClientDir,
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$SelfCheck,
    [int]$Port = 27015,
    [int[]]$Lags = @(0, 50, 150, 250),
    [string]$Ref = '',               # git ref of the build to measure; empty = the working tree
    [string]$Map = 'de_dust2'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$remoteMode = ($PSCmdlet.ParameterSetName -eq 'Remote')
# .NET (Bitmap.Save, the ScopeProbe writers) resolves relative paths against the process directory, not PowerShell's; that made the baseline Save fail with "generic error in GDI+".
$OutDir = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $OutDir))
if ($remoteMode) {
    $Lags = @(0)    # one pass at the real ping; the lag chain still runs once (its row is logged, nothing is simulated)
    $caseName = "visual matrix: every on-screen case at real ping to $Remote"
    . (Join-Path (Split-Path $PSScriptRoot) 'remote\RemoteLib.ps1')
}
else { $caseName = 'visual matrix: every on-screen case at simulated latency ' + ($Lags -join '/') + ' ms' }
if (-not $remoteMode) {
    $game = Join-Path $ServerDir 'cstrike'
    $sm = Join-Path $game 'addons\sourcemod'
}
$clientGame = Join-Path $ClientDir 'cstrike'
$clientCfgDir = Join-Path $clientGame 'cfg'
$clientLog = Join-Path $clientGame 'console.log'
$steam = Join-Path (Split-Path (Split-Path (Split-Path $ClientDir))) 'steam.exe'
$clientNames = 'cstrike_win64', 'cstrike', 'hl2'
if (-not $remoteMode) {
    $helperSmx = Join-Path $sm 'plugins\disablescopes_matrix.smx'
    $pluginSmx = Join-Path $sm 'plugins\disablescopes.smx'
    $serverCsv = Join-Path $sm 'logs\disablescopes_matrix.csv'
}
$PingMs = 0.0             # remote: the worst ping the client reported; added to the blocked-scope allowance
$problems = New-Object System.Collections.Generic.List[string]

$RoundTripSlackMs = 100   # a blocked scope may show until latency plus this after the block starts (issues #7, #9)
$AllowedMinMs = 300       # an allowed scope must show at least this long
# Only function keys reach the client reliably (letters and digits did not fire their binds). Cases and
# latencies are stepped through alias chains: NextCase (F3) runs the next case alias, NextLag (F4) the next
# latency alias, ResetCases (F5) rewinds the case chain.
$VK = @{ Ping = 0x7B; NextCase = 0x72; NextLag = 0x73; ResetCases = 0x74; Scope = 0x75; Air = 0x76; Jump = 0x77; AirFire = 0x78; Fire = 0x79; End = 0x7A }   # F2..F11

# Weapon -> restriction cvar index in the rule tuple (awp, scout, auto, weak, inair, onground).
$weaponRule = @{ weapon_awp = 0; weapon_scout = 1; weapon_g3sg1 = 2; weapon_sg550 = 2 }

# Case table. Rule = awp, scout, autosnipers, weaksnipers, inair, onground. Steps = key, label, sleep after (ms).
# The window for the screen judgement starts at the step labelled 'win' and lasts WinMs.
$all = @(1, 1, 1, 1, 1, 0)
$cases = @(
    @{ N = 'AWP ground scope (allowed)';              W = 'weapon_awp';   R = $all;                Ex = 'allowed'; Steps = @(,@('Scope', 'win', 1500)); WinMs = 2000 }
    @{ N = 'AWP jump then scope (blocked in air)';    W = 'weapon_awp';   R = $all;                Ex = 'blocked'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200; Air = $true }
    @{ N = 'AWP scoped on ground then jump (forced unscope)'; W = 'weapon_awp'; R = $all;          Ex = 'blocked'; Steps = @(@('Scope', 'pre', 1500), @('Jump', 'win', 2000)); WinMs = 2200 }
    @{ N = 'AWP ground scope blocked by on-ground rule'; W = 'weapon_awp'; R = @(1, 1, 1, 1, 1, 1); Ex = 'blocked'; Steps = @(,@('Scope', 'win', 1500)); WinMs = 2000 }
    @{ N = 'AWP jump then scope allowed (in-air rule off)'; W = 'weapon_awp'; R = @(1, 1, 1, 1, 0, 0); Ex = 'allowed'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200 }
    @{ N = 'AWP unrestricted (awp cvar off), jump then scope'; W = 'weapon_awp'; R = @(0, 1, 1, 1, 1, 0); Ex = 'allowed'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200 }
    @{ N = 'scout ground scope (allowed)';            W = 'weapon_scout'; R = $all;                Ex = 'allowed'; Steps = @(,@('Scope', 'win', 1500)); WinMs = 2000 }
    @{ N = 'scout jump then scope (blocked in air)';  W = 'weapon_scout'; R = $all;                Ex = 'blocked'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200; Air = $true }
    @{ N = 'G3SG1 ground scope (allowed)';            W = 'weapon_g3sg1'; R = $all;                Ex = 'allowed'; Steps = @(,@('Scope', 'win', 1500)); WinMs = 2000 }
    @{ N = 'G3SG1 jump then scope (blocked in air)';  W = 'weapon_g3sg1'; R = $all;                Ex = 'blocked'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200; Air = $true }
    @{ N = 'SG550 ground scope (allowed)';            W = 'weapon_sg550'; R = $all;                Ex = 'allowed'; Steps = @(,@('Scope', 'win', 1500)); WinMs = 2000 }
    @{ N = 'SG550 jump then scope (blocked in air)';  W = 'weapon_sg550'; R = $all;                Ex = 'blocked'; Steps = @(,@('Air', 'win', 2000)); WinMs = 2200; Air = $true }
    @{ N = 'AWP shot while jumping, scope blocked';   W = 'weapon_awp';   R = $all;                Ex = 'blocked'; Steps = @(,@('AirFire', 'win', 2200)); WinMs = 2400; Air = $true; Shots = 'air'; ShotKey = 'win' }
    @{ N = 'AWP shot on ground, on-ground rule blocks scope'; W = 'weapon_awp'; R = @(1, 1, 1, 1, 1, 1); Ex = 'blocked'; Steps = @(@('Scope', 'win', 1200), @('Fire', 'fire', 1500)); WinMs = 2700; Shots = 'blocked'; ShotKey = 'fire' }
    @{ N = 'AWP scoped shot on ground (allowed)';     W = 'weapon_awp';   R = $all;                Ex = 'allowed'; Steps = @(@('Scope', 'win', 1200), @('Fire', 'fire', 1500)); WinMs = 1200; Shots = 'any'; ShotKey = 'fire' }
)
$caseIdx = 0..($cases.Count - 1)

function New-Result([string]$status, [string]$detail, $rows = @()) {
    [pscustomobject]@{ Status = $status; Name = $caseName; Detail = $detail; Problems = @($problems); Rows = $rows }
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
        if (-not $hashes.ContainsKey($f)) { Remove-Item $f -Force }
        elseif ($now[$f] -ne $hashes[$f]) { Copy-Item (Join-Path $backupDir $f.Substring($clientCfgDir.Length)) $f -Force }
    }
    foreach ($f in $hashes.Keys) {
        if (-not (Test-Path $f)) { Copy-Item (Join-Path $backupDir $f.Substring($clientCfgDir.Length)) $f -Force }
    }
    $after = Get-CfgHashes
    $changed = @($hashes.Keys | Where-Object { $after[$_] -ne $hashes[$_] }) + @($after.Keys | Where-Object { -not $hashes.ContainsKey($_) })
    foreach ($f in $changed) { $problems.Add("client config not restored: $f") }
}

# ---------- capture and log parsing ----------
function Read-Capture([string]$path) {
    $marks = New-Object System.Collections.Generic.List[object]
    $iv = New-Object System.Collections.Generic.List[object]
    $ammo = New-Object System.Collections.Generic.List[double]
    $start = $null; $last = 0.0
    foreach ($r in (Import-Csv $path)) {
        $t = [double]$r.t_ms; $last = $t
        if ($r.kind -eq 'ammo') { $ammo.Add($t) }
        elseif ($r.kind -eq 'mark') { $marks.Add([pscustomobject]@{ T = $t; Label = $r.value }) }
        elseif ($r.kind -eq 'state') {
            if ($r.value -eq '1' -and $null -eq $start) { $start = $t }
            elseif ($r.value -eq '0' -and $null -ne $start) { $iv.Add([pscustomobject]@{ S = $start; E = $t }); $start = $null }
        }
    }
    if ($null -ne $start) { $iv.Add([pscustomobject]@{ S = $start; E = $last }) }
    return [pscustomobject]@{ Marks = $marks; Scoped = $iv; Ammo = $ammo }
}
function Get-MarkTime($capture, [string]$label) {
    $m = @($capture.Marks | Where-Object { $_.Label -eq "key $label" } | Select-Object -First 1)
    if ($m.Count) { return $m[0].T } else { return $null }
}
function Get-ScopedOverlap($capture, [double]$from, [double]$to) {
    $total = 0.0; $n = 0
    foreach ($i in $capture.Scoped) {
        $o = [math]::Min($i.E, $to) - [math]::Max($i.S, $from)
        if ($o -gt 0) { $total += $o; $n++ }
    }
    return [pscustomobject]@{ Ms = $total; Count = $n }
}
function Test-Zoomed($row) { $f = [int]$row.fov; return $f -gt 0 -and $f -lt 90 }

# Server rows grouped into one block per (latency, case), in file order.
function Read-ServerBlocks($rows) {
    $blocks = @{}; $cur = $null; $lag = 0
    foreach ($r in $rows) {
        if ($r.kind -eq 'lag') { $lag = [int]$r.text; $cur = $null }
        elseif ($r.kind -eq 'case') {
            $idx = [int](($r.text -split ' ')[0])
            $cur = [pscustomobject]@{ Idx = $idx; Lag = $lag; Rows = (New-Object System.Collections.Generic.List[object]) }
            $blocks["$idx@$lag"] = $cur
        }
        elseif ($cur) { $cur.Rows.Add($r) }
    }
    return $blocks
}

# ---------- the judgement of one (case, latency) ----------
function Measure-Case([int]$idx, [int]$lag, $capture, $blocks) {
    $c = $cases[$idx]
    $why = New-Object System.Collections.Generic.List[string]
    $facts = New-Object System.Collections.Generic.List[string]
    $blk = $blocks["$idx@$lag"]
    if (-not $blk) { return [pscustomobject]@{ Pass = $false; Why = @('the case never reached the server'); Facts = @() } }
    $rows = $blk.Rows
    $cmds = @($rows | Where-Object kind -eq 'cmd')
    $ruleIdx = $weaponRule[$c.W]
    $restricted = [bool]$c.R[$ruleIdx]
    $blockedState = { param($onground) $restricted -and ([int]$(if ($onground) { $c.R[5] } else { $c.R[4] }) -eq 1) }
    $zoomBlocked = @($cmds | Where-Object { (Test-Zoomed $_) -and (& $blockedState ([int]$_.onground -eq 1)) })
    $zoomAny = @($cmds | Where-Object { Test-Zoomed $_ })
    $facts.Add("server cmds $($cmds.Count), zoomed $($zoomAny.Count), zoomed while blocked $($zoomBlocked.Count)")

    $win = Get-MarkTime $capture "c$idx@$lag win"
    if ($null -eq $win) { $why.Add('the window key was never injected'); return [pscustomobject]@{ Pass = $false; Why = $why; Facts = $facts } }
    $ov = Get-ScopedOverlap $capture $win ($win + $c.WinMs)
    $facts.Add(('screen scoped {0:F0} ms in {1} interval(s)' -f $ov.Ms, $ov.Count))

    # the case must actually have been exercised
    if ($c.Air) {
        $pre = @($rows | Where-Object { $_.kind -eq 'mark' -and $_.text -eq 'air' } | Select-Object -First 1)
        $sc = @($rows | Where-Object { $_.kind -eq 'mark' -and $_.text -eq 'scope' } | Select-Object -First 1)
        if (-not $sc.Count -or -not $pre.Count) { $why.Add('the in-air scope press never reached the server (case not exercised)') }
        else {
            if ([int]$sc[0].onground -ne 0) { $why.Add('the scope press reached the server while on the ground (case not exercised)') }
            # ready2 is read before the jump: once airborne the plugin itself pushes the next-secondary-attack time out
            if ([int]$pre[0].ready2 -ne 1) { $why.Add('the weapon could not scope yet when the jump began (still deploying; case not exercised)') }
        }
    }

    if ($c.Steps[0][0] -eq 'Scope' -and -not (& $blockedState $true)) {
        $g = @($rows | Where-Object { $_.kind -eq 'mark' -and $_.text -eq 'ground' } | Select-Object -First 1)
        if (-not $g.Count) { $why.Add('the ground scope press never reached the server (case not exercised)') }
        elseif ([int]$g[0].ready2 -ne 1) { $why.Add('the weapon could not scope yet when the press came (still deploying; case not exercised)') }
    }

    if ($c.Ex -eq 'blocked') {
        # Issues #7/#9 (user-approved): a blocked scope may show within one round trip (latency plus
        # RoundTripSlackMs) after the block starts at the window key, and none after that.
        $graceMs = $lag + $script:PingMs + $RoundTripSlackMs
        $late = Get-ScopedOverlap $capture ($win + $graceMs) ($win + $c.WinMs)
        if ($late.Ms -gt 0) { $why.Add(('blocked, but the screen showed a scope for {0:F0} ms after the {1} ms round-trip allowance' -f $late.Ms, $graceMs)) }
        if ($zoomBlocked.Count) { $why.Add("server fov zoomed in $($zoomBlocked.Count) cmds while the scope was blocked") }
    }
    else {
        if ($ov.Ms -lt $AllowedMinMs) { $why.Add(('allowed, but the screen showed a scope for only {0:F0} ms' -f $ov.Ms)) }
        if (-not $zoomAny.Count) { $why.Add('allowed, but the server never saw the scope zoomed') }
    }

    if ($c.Shots) {
        # one fire press per case: the client shows the shot as a change of its clip counter within 2 s of it
        $from = Get-MarkTime $capture "c$idx@$lag $($c.ShotKey)"
        $shown = @($capture.Ammo | Where-Object { $_ -ge $from -and $_ -le $from + 2000 }).Count
        $shots = @($rows | Where-Object kind -eq 'shot')
        $facts.Add("shots: server $($shots.Count), client clip counter changes $shown")
        if ($shots.Count -ne 1) { $why.Add("the server registered $($shots.Count) shots for one fire press (expected 1)") }
        if ($shown -lt 1) { $why.Add('the client did not show the shot (clip counter unchanged)') }
        foreach ($s in $shots) {
            if ((& $blockedState ([int]$s.onground -eq 1)) -and (Test-Zoomed $s)) { $why.Add("a shot in a blocked state had a zoomed field of view (fov $($s.fov)): not unscoped accuracy") }
            if ($c.Shots -eq 'air' -and [int]$s.onground -ne 0) { $why.Add('the shot was fired on the ground (case not exercised)') }
        }
    }
    return [pscustomobject]@{ Pass = ($why.Count -eq 0); Why = $why; Facts = $facts }
}

# ---------- the helper's server csv: local file, or read over ssh in remote mode ----------
$csvBase = 0   # remote: lines already in the csv before this run (earlier runs); only the rows after them count
function Get-ServerCsvLines {
    if ($remoteMode) {
        $all = @((Invoke-RemoteBash "cd ~ && cat '$remoteCsv' 2>/dev/null" -AllowFail) -split "`n" | Where-Object { $_.Trim() })
        if ($script:csvBase -gt 0 -and $all.Count -gt $script:csvBase) { return @($all[0]) + @($all[$script:csvBase..($all.Count - 1)]) }
        if ($script:csvBase -gt 0) { return @($all[0]) }
        return $all
    }
    if (Test-Path $serverCsv) { return @(Get-Content $serverCsv) } else { return @() }
}
function Test-ServerCsv([string]$prefix) { return (@(Get-ServerCsvLines | Where-Object { $_ -match "^$prefix" }).Count -gt 0) }

# ---------- run ----------
$remoteIp = $null; $remoteCsv = $null; $remoteVersion = ''; $restoreNeeded = $false
if ($remoteMode) {
    try {
        Initialize-Remote $Remote $RemoteSmDir
        $remoteCsv = "$($script:RemoteSmDir)/logs/disablescopes_matrix.csv"
        $remoteIp = Get-RemoteHostAddress
        $helper = @(Get-RemotePluginLines | Where-Object { $_ -match 'disablescopes_matrix' -and $_ -match '-remote' })
        if (-not $helper.Count) { return New-Result 'SKIP' 'the remote build of the matrix helper is not loaded (a disablescopes_matrix whose version ends in -remote); build it with tests\remote\Build-RemoteHelpers.ps1 and have the deploy agent load it' }
        $counts = Get-RemotePlayerCounts
        if (-not $counts) { return New-Result 'SKIP' 'could not read the player counts from the remote status' }
        if ($counts.Humans -gt 0) { return New-Result 'SKIP' "$($counts.Humans) human(s) already on the remote server; the helper takes the first real player and changes game cvars" }
        $vl = @(Send-RemoteCommand 'sm_disablescopes_version' | Where-Object { $_ -match '"sm_disablescopes_version"\s*=\s*"([^"]*)"' }) | Select-Object -First 1
        if (-not $vl) { return New-Result 'SKIP' 'the plugin under test is not loaded on the remote server' }
        [void]($vl -match '"sm_disablescopes_version"\s*=\s*"([^"]*)"')
        $remoteVersion = $Matches[1]
    }
    catch { return New-Result 'SKIP' "remote server not usable: $(Protect-Text "$_")" }
}
foreach ($p in @($steam, (Join-Path $ClientDir 'cstrike_win64.exe'))) {
    if (-not (Test-Path $p)) { return New-Result 'SKIP' "client not installed ($p not found)" }
}
if (Get-Process $clientNames -ErrorAction SilentlyContinue) { return New-Result 'SKIP' 'a CS:S client is already running; close it first' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot 'ScopeProbe.cs') -ReferencedAssemblies System.Drawing

if ($Ref -and $remoteMode) { return New-Result 'SKIP' '-Ref measures a locally compiled build; the remote mode measures whatever the server has loaded' }
if (-not $remoteMode) {
    $spcomp = Join-Path $sm 'scripting\spcomp.exe'
    & $spcomp (Join-Path $PSScriptRoot 'disablescopes_matrix.sp') "-i$sm\scripting\include" "-o$helperSmx" | Out-Null
    if ($LASTEXITCODE -ne 0) { return New-Result 'SKIP' 'disablescopes_matrix.sp failed to compile' }
}
if ($Ref) {
    $src = Join-Path $OutDir 'disablescopes.sp'
    # the tag for Beta 6 predates the scripting/ folder
    $bytes = $null
    $ErrorActionPreference = 'Continue'     # git writes to stderr for a path that is not in the ref
    foreach ($path in 'scripting/disablescopes.sp', 'sm_disablescopes.sp') {
        $bytes = & git -C $repo show "${Ref}:$path" 2>$null
        if ($LASTEXITCODE -eq 0) { break }
    }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { return New-Result 'SKIP' "git ref $Ref has no plugin source" }
    $bytes | Set-Content $src -Encoding ascii
    & $spcomp $src "-i$sm\scripting\include" "-o$pluginSmx" | Out-Null
    if ($LASTEXITCODE -ne 0) { return New-Result 'SKIP' "build $Ref failed to compile" }
}
$build = if ($remoteMode) { "$Remote, plugin $remoteVersion" } elseif ($Ref) { $Ref } else { 'working tree' }
$snapFile = Join-Path $OutDir 'remote_cvars_before.json'

$srv = $null; $skip = $null; $cfgHashes = $null; $logOffset = 0
try {
$cfgHashes = Get-CfgHashes
$cfgBackup = Join-Path $OutDir 'client_cfg_backup'
Copy-Item $clientCfgDir $cfgBackup -Recurse -Force
$cfg = New-Object System.Collections.Generic.List[string]
$cfg.Add('// DisableScopes visual matrix (written by Invoke-VisualMatrix.ps1; removed afterwards)')
foreach ($l in 'fps_max 100', 'cl_cmdrate 100', 'cl_updaterate 100', 'rate 100000', 'net_graph 0', 'cl_predict 1') { $cfg.Add($l) }
$cfg.Add('alias dsc_scope "dsc_mark ground; +attack2; wait 3; -attack2"')
$cfg.Add('alias dsc_air "dsc_mark air; +jump; wait 6; dsc_mark scope; +attack2; wait 3; -attack2; wait 3; -jump"')
$cfg.Add('alias dsc_jump "+jump; wait 30; -jump"')
$cfg.Add('alias dsc_airfire "dsc_mark air; +jump; wait 6; dsc_mark scope; +attack2; wait 3; -attack2; wait 3; +attack; wait 3; -attack; wait 3; -jump"')
$cfg.Add('alias dsc_fire "+attack; wait 3; -attack"')
$cfg.Add('bind F3 "dsc_cn"'); $cfg.Add('bind F4 "dsc_ln"'); $cfg.Add('bind F5 "alias dsc_cn dsc_cs0"')
$cfg.Add('bind F6 "dsc_scope"'); $cfg.Add('bind F7 "dsc_air"'); $cfg.Add('bind F8 "dsc_jump"'); $cfg.Add('bind F9 "dsc_airfire"')
$cfg.Add('bind F10 "dsc_fire"'); $cfg.Add('bind F11 "echo DSC_END"')
$cfg.Add('alias dsc_ping "echo DSC_PING; status"'); $cfg.Add('bind F12 "dsc_ping"')
for ($k = 0; $k -lt $Lags.Count; $k++) {          # latency chain: each press applies the next latency
    $next = ($k + 1) % $Lags.Count
    $cfg.Add("alias dsc_ls$k `"echo DSC_LAG $($Lags[$k]); dsc_lag $($Lags[$k]); alias dsc_ln dsc_ls$next`"")
}
$cfg.Add('alias dsc_ln dsc_ls0')
for ($i = 0; $i -lt $cases.Count; $i++) {         # case chain: each press selects the next case
    $c = $cases[$i]
    $next = ($i + 1) % $cases.Count
    $cfg.Add("alias dsc_cs$i `"echo DSC_BEGIN $i; dsc_case $i $($c.W) $($c.R -join ' '); alias dsc_cn dsc_cs$next`"")
}
$cfg.Add('alias dsc_cn dsc_cs0')
$cfg.Add('echo DSC_CFG_LOADED')
$cfg | Set-Content (Join-Path $clientCfgDir 'dsc_matrix.cfg') -Encoding ascii
if (-not $remoteMode) { Remove-Item $serverCsv -ErrorAction SilentlyContinue }
if (Test-Path $clientLog) { $logOffset = (Get-Item $clientLog).Length }

if ($remoteMode) {
    $snap = Save-CvarSnapshot $script:RunCvars $snapFile
    $restoreNeeded = -not $NoRestore
    Write-Host "recorded $($snap.Saved) server cvar(s) to $snapFile (restored at the end)"
    $csvBase = Get-RemoteLineCount $remoteCsv
    Write-Host "Connecting the client to $Remote (port $Port); the address is not printed."
    Start-Process $steam -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +name dsc_probe +exec dsc_matrix.cfg +connect ${remoteIp}:$Port"
    $deadline = (Get-Date).AddSeconds(240)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) { Start-Sleep 4; $ready = Test-ServerCsv 'ready' }
    if (-not $ready) { throw 'client never became ready (no ready row from the remote helper)' }
}
else {
$srcdsArgs = "-console -game cstrike -condebug -tickrate 100 -port $Port +sv_lan 1 +maxplayers 10 +bot_quota 0 " +
             "+disablescopes_matrix_selfcheck $([int][bool]$SelfCheck) +map $Map"
Write-Host "Starting srcds for the visual matrix (port $Port, build $build)..."
$srv = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -WindowStyle Minimized -PassThru
Start-Sleep 20
$ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway)[0].IPv4Address.IPAddress
Write-Host "Launching the client (connect ${ip}:$Port)..."
Start-Process $steam -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +exec dsc_matrix.cfg +connect ${ip}:$Port"
$deadline = (Get-Date).AddSeconds(240)
$ready = $false
while (-not $ready -and (Get-Date) -lt $deadline) {
    Start-Sleep 2
    $ready = (Test-Path $serverCsv) -and (Select-String -Path $serverCsv -Pattern '^ready' -Quiet)
    if ($srv.HasExited) { throw 'srcds exited before the client was ready' }
}
if (-not $ready) { throw 'client never became ready (no ready row from the helper)' }
}
$cli = Get-Process $clientNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
if (-not $cli) { throw 'client window not found' }
$hwnd = $cli.MainWindowHandle
[ScopeProbe]::Place($hwnd)
Start-Sleep 3
[ScopeProbe]::Focus($hwnd)
Start-Sleep 1
[ScopeProbe]::Key($hwnd, $VK.NextLag, 'baseline lag')
Start-Sleep 1
[ScopeProbe]::Key($hwnd, $VK.NextCase, 'baseline case')
Start-Sleep 3
Add-Content (Join-Path $OutDir 'steps.log') 'before snapshot'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
if (-not ('WinState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinState {
    [StructLayout(LayoutKind.Sequential)] public struct RC { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
}
$wr = New-Object WinState+RC
[void][WinState]::GetWindowRect($hwnd, [ref]$wr)
Add-Content (Join-Path $OutDir 'steps.log') ("window: iconic=" + [WinState]::IsIconic($hwnd) + " visible=" + [WinState]::IsWindowVisible($hwnd) + " rect=" + "$($wr.L),$($wr.T),$($wr.R),$($wr.B)" + " screen=" + [System.Windows.Forms.Screen]::PrimaryScreen.Bounds + " virtual=" + [System.Windows.Forms.SystemInformation]::VirtualScreen)
[ScopeProbe]::Snapshot($hwnd, (Join-Path $OutDir 'baseline.png'))
Add-Content (Join-Path $OutDir 'steps.log') 'after snapshot'
if ($remoteMode) { [ScopeProbe]::Key($hwnd, $VK.Ping, 'ping before') }
if (-not (Test-ServerCsv 'case')) { throw 'injected key never reached the server (no case row); see baseline.png' }
$d = ''
if ([ScopeProbe]::Classify($hwnd, [ref]$d) -ne 0) { throw "baseline screen classifies as scoped (edges $d); see baseline.png" }

Write-Host 'Running the matrix (leave the game window alone)...'
Add-Content (Join-Path $OutDir 'steps.log') 'classified ok, starting matrix'
[ScopeProbe]::Start($hwnd)
Add-Content (Join-Path $OutDir 'steps.log') 'probe started'
$firstLag = $true
foreach ($lag in $Lags) {
    if ($firstLag) { $firstLag = $false } else { [ScopeProbe]::Key($hwnd, $VK.NextLag, "lag $lag") }   # the first latency was applied by the baseline step
    [ScopeProbe]::Key($hwnd, $VK.ResetCases, "rewind c@$lag")
    Start-Sleep -Milliseconds 2000
    foreach ($i in $caseIdx) {
        $c = $cases[$i]
        [ScopeProbe]::Key($hwnd, $VK.NextCase, "c$i@$lag select")
        Start-Sleep -Milliseconds 3000                         # fresh weapon deploys (it cannot scope before) and the server catches up
        foreach ($s in $c.Steps) {
            [ScopeProbe]::Key($hwnd, $VK[$s[0]], "c$i@$lag $($s[1])")
            Start-Sleep -Milliseconds $s[2]
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "  latency $lag ms done"
}
if ($remoteMode) { [ScopeProbe]::Key($hwnd, $VK.Ping, 'ping after'); Start-Sleep 1 }
[ScopeProbe]::Key($hwnd, $VK.End, 'end')
Start-Sleep 1
[ScopeProbe]::Stop((Join-Path $OutDir 'live.csv'))
}
catch {
    $skip = "$_"
    Add-Content (Join-Path $OutDir 'steps.log') ("caught: " + "$_" + " at " + $_.InvocationInfo.ScriptLineNumber)
    try { [ScopeProbe]::Stop((Join-Path $OutDir 'live_partial.csv')) } catch {}
}
finally {
    Get-Process $clientNames -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($srv -and -not $srv.WaitForExit(15000)) { Stop-Process -Id $srv.Id -Force; $problems.Add('matrix srcds did not quit after the client left; it was killed') }
    Start-Sleep 2
    if ($cfgHashes) { Restore-ClientCfg $cfgHashes $cfgBackup }
    if ($remoteMode) {
        try { Get-ServerCsvLines | Set-Content (Join-Path $OutDir 'server.csv') -Encoding ascii } catch { $problems.Add("could not read the remote csv: $(Protect-Text "$_")") }
        if ($restoreNeeded) {
            try {
                $rr = Restore-CvarSnapshot $snapFile
                Write-Host "server cvars restored: $(if ($rr.Restored.Count) { $rr.Restored -join ', ' } else { 'none changed' })"
                foreach ($pp in $rr.Problems) { $problems.Add($pp) }
            }
            catch { $problems.Add("server cvar restore failed (run tests\remote\CvarSnapshot.ps1 -Action Restore -File $snapFile): $(Protect-Text "$_")") }
        }
    }
    else {
        Remove-Item $helperSmx -ErrorAction SilentlyContinue
        if (Test-Path $helperSmx) { $problems.Add("helper plugin still deployed: $helperSmx") }
        if (Test-Path $serverCsv) { Copy-Item $serverCsv (Join-Path $OutDir 'server.csv') -Force }
    }
    if (Test-Path $clientLog) {
        $fs = New-Object IO.FileStream($clientLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $b = New-Object byte[] $fs.Length; [void]$fs.Read($b, 0, $b.Length) } finally { $fs.Dispose() }
        $o = if ($logOffset -le $b.Length) { $logOffset } else { 0 }
        $slice = $b[$o..($b.Length - 1)]
        if ($remoteMode -and $remoteIp) {      # the connect line carries the server address; keep it out of saved files
            $txt = [Text.Encoding]::UTF8.GetString($slice).Replace($remoteIp, 'REMOTE-IP')
            $slice = [Text.Encoding]::UTF8.GetBytes($txt)
        }
        [IO.File]::WriteAllBytes((Join-Path $OutDir 'client_console.log'), $slice)
    }
}
if ($skip) { return New-Result 'SKIP' "matrix did not run: $skip" }

$pingSamples = @()
if ($remoteMode) {
    # the client's own `status` table: "# userid name uniqueid connected ping loss state rate"
    $pingSamples = @(Get-Content (Join-Path $OutDir 'client_console.log') | ForEach-Object {
        if ($_ -match '^#\s+\d+(?:\s+\d+)?\s+"dsc_probe"\s+\S+\s+\S+\s+(\d+)\s+(\d+)') { [int]$Matches[1] } })
    if (-not $pingSamples.Count) { $problems.Add('no ping sample: the client console log has no status row for dsc_probe') }
    else { $PingMs = [double]($pingSamples | Measure-Object -Maximum).Maximum }
}
$live = Read-Capture (Join-Path $OutDir 'live.csv')
$srvRows = @(Import-Csv (Join-Path $OutDir 'server.csv'))
$ready = @($srvRows | Where-Object kind -eq 'ready')
if ($SelfCheck -and $ready.Count -and $ready[-1].text -ne 'selfcheck') { $problems.Add('self-check requested but the helper did not disable the plugin') }
$blocks = Read-ServerBlocks $srvRows
$totalClientShots = $live.Ammo.Count

$results = New-Object System.Collections.Generic.List[object]
foreach ($i in $caseIdx) {
    foreach ($lag in $Lags) {
        $v = Measure-Case $i $lag $live $blocks
        $results.Add([pscustomobject]@{ Idx = $i; Case = $cases[$i].N; Lag = $lag; Pass = $v.Pass; Detail = ((@($v.Facts) + @($v.Why)) -join '; ') })
    }
}

# ---------- record ----------
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Visual matrix: $build" + $(if ($SelfCheck) { ' (self-check: plugin disabled)' } else { '' }))
$md.Add('')
$latNote = 'Simulated latency is server net_fakelag.'
if ($remoteMode -and $pingSamples.Count) {
    $pm = $pingSamples | Measure-Object -Minimum -Maximum -Average
    $latNote = 'Real ping to the remote server, as reported by the client (status, ' + $pingSamples.Count + ' samples): min ' + $pm.Minimum + ' ms, mean ' + ('{0:F0}' -f $pm.Average) + ' ms, max ' + $pm.Maximum + ' ms; blocked-scope allowance ' + ($PingMs + $RoundTripSlackMs) + ' ms.'
}
elseif ($remoteMode) { $latNote = 'Real ping to the remote server (no client ping sample).' }
$md.Add("$latNote Run $(Get-Date -Format 'yyyy-MM-dd HH:mm'); client clip-counter changes seen in total: $totalClientShots.")
$md.Add('')
$lagHead = if ($remoteMode) { 'real ping' } else { (($Lags | ForEach-Object { "$_ ms" }) -join ' | ') }
$md.Add('| Case | ' + $lagHead + ' |')
$md.Add('| --- | ' + (($Lags | ForEach-Object { '---' }) -join ' | ') + ' |')
foreach ($i in $caseIdx) {
    $cells = foreach ($lag in $Lags) { $r = $results | Where-Object { $_.Idx -eq $i -and $_.Lag -eq $lag }; if ($r.Pass) { 'pass' } else { 'FAIL' } }
    $md.Add("| $($cases[$i].N) | " + ($cells -join ' | ') + ' |')
}
$md.Add('')
$md.Add('## Detail')
foreach ($r in $results) { $md.Add("- $($r.Case) @ $($r.Lag) ms: $(if ($r.Pass) { 'pass' } else { 'FAIL' }) - $($r.Detail)") }
$md | Set-Content (Join-Path $OutDir 'matrix.md') -Encoding utf8

$failed = @($results | Where-Object { -not $_.Pass })
if ($totalClientShots -eq 0) { $problems.Add('the client screen showed no clip-counter change at all (ammo HUD channel did not work)') }
$detail = "$($results.Count - $failed.Count)/$($results.Count) (case, latency) results pass; record: $(Join-Path $OutDir 'matrix.md')"
foreach ($f in @($failed | Select-Object -First 40)) { $detail += "; [$($f.Lag) ms] $($f.Case): $($f.Detail)" }
return New-Result $(if ($failed.Count -eq 0 -and $totalClientShots -gt 0) { 'PASS' } else { 'FAIL' }) $detail $results.ToArray()   # @() of a generic List as an argument throws "Argument types do not match" on PowerShell 5.1
