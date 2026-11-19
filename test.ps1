# Builds and deploys the plugin and the suite, runs the suite on the local test server
# unattended, then scans every log line written during the run.
#   .\test.ps1                 full run; exit 0 = PASS, 1 = FAIL, 2 = could not start
#   .\test.ps1 -NoBuild        skip build/deploy, test what is already on the server
#   .\test.ps1 -InjectError    self-check: the suite logs a deliberate error, so this run MUST fail
#   .\test.ps1 -Client         also run the client-view case with the real CS:S client (about 2 min;
#                              leave the desktop alone). A client case that cannot run is a failure.
#   .\test.ps1 -Client -ClientSelfCheck
#                              self-check: the plugin is disabled for the client case, so the case
#                              and this run MUST fail (proves the screen channel sees a scope)
param(
    [switch]$NoBuild,
    [switch]$InjectError,
    [switch]$Client,
    [switch]$ClientSelfCheck,
    [string]$ClientDir = $(if ($env:CSS_CLIENT_DIR) { $env:CSS_CLIENT_DIR } else { 'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source' }),
    [string]$ServerDir = $(if ($env:CSS_SERVER_DIR) { $env:CSS_SERVER_DIR } else { 'C:\Users\user\cssds' }),
    [string]$Map = 'de_dust2',
    [int]$TimeoutSec = 120
)
$game = Join-Path $ServerDir 'cstrike'
$smLogs = Join-Path $game 'addons\sourcemod\logs'
$consoleLog = Join-Path $game 'console.log'
$testLog = Join-Path $smLogs 'disablescopes_tests.log'

# Lines that look like errors but are normal on this server.
$benign = @(
    'metamod[\/]bin[\/]win64[\/]server',      # x64 VDF on a 32-bit server
    'vscript_convar_allowlist\.txt',
    '\[(PASS|FAIL|SKIP)\]', 'tests (started|finished)'   # the suite's own output (judged separately)
)
# Always a failure: script errors, plugins or extensions that did not load, engine faults.
$hard = '\[SM\] (Exception|Blaming|Call stack|Unable to load|Failed to load|Plugin .* failed|Fatal)|' +
        'Exception reported|Native ".*" (reported|was not found)|Script execution timed out|' +
        '<(Failed|Error|Bad Load)>|Could not find required file|Host_Error|Engine Error|' +
        'Segmentation fault|Access violation|Failed to load plugin|Plugin failed to load|required extension'

function Get-LogSizes {
    $sizes = @{}
    $files = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue)
    if (Test-Path $consoleLog) { $files += Get-Item $consoleLog }
    foreach ($f in $files) { $sizes[$f.FullName] = $f.Length }
    return $sizes
}

# Text appended to a log since the snapshot (the whole file if it is new or was rotated).
function Get-NewLines([string]$path, $before) {
    if (-not (Test-Path $path)) { return @() }
    # open shared: the server may still hold its log open
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $from = 0
    if ($before.ContainsKey($path) -and $before[$path] -le $bytes.Length) { $from = $before[$path] }
    if ($from -ge $bytes.Length) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $from, $bytes.Length - $from)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

function Remove-LogPrefix([string]$line, [string]$tag) { return $line -replace "^.*?(\[$tag\])", '$1' }

function Test-Benign([string]$line) {
    foreach ($b in $benign) { if ($line -match $b) { return $true } }
    return $false
}

$problems = New-Object System.Collections.Generic.List[string]

# Only a server started from this ServerDir is in the way (other test servers use their own dir and port).
$srcdsExe = Join-Path $ServerDir 'srcds.exe'
if (Get-Process srcds -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $srcdsExe }) {
    Write-Error "srcds.exe is already running from $ServerDir; stop it first (the suite needs its own server instance)."
    exit 2
}
if ($ClientSelfCheck -and -not $Client) { Write-Error '-ClientSelfCheck needs -Client'; exit 2 }
if ($Client -and (Get-Process cstrike_win64, cstrike, hl2 -ErrorAction SilentlyContinue)) {
    Write-Error 'a CS:S client is already running; close it first (the client case drives its own client).'
    exit 2
}
if (-not $NoBuild) {
    & "$PSScriptRoot\build.ps1" -Deploy | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error 'build failed'; exit 2 }
}

$before = Get-LogSizes
$inject = [int][bool]$InjectError
$srcdsArgs = "-console -game cstrike -condebug -tickrate 100 +sv_lan 1 +maxplayers 10 +bot_quota 0 " +
             "+disablescopes_test_autorun 1 +disablescopes_test_inject_error $inject +map $Map"
Write-Host "Starting srcds ($Map)..."
$proc = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -PassThru
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    Stop-Process -Id $proc.Id -Force
    $problems.Add("server did not quit within ${TimeoutSec}s (suite hung or never started); it was killed")
}

# --- the suite's own results (only lines written during this run) ---
$results = Get-NewLines $testLog $before
$passed = @($results | Where-Object { $_ -match '\[PASS\]' })
$failed = @($results | Where-Object { $_ -match '\[FAIL\]' })
$summary = @($results | Where-Object { $_ -match 'tests finished: (\d+) passed, (\d+) failed' }) | Select-Object -Last 1
$started = @($results | Where-Object { $_ -match 'tests started \((\d+) cases\)' }) | Select-Object -Last 1
if (-not $results.Count) { $problems.Add('the suite wrote nothing to disablescopes_tests.log (test plugin not loaded?)') }
elseif (-not $summary) { $problems.Add('the suite started but never reached its summary line') }
if ($started -match 'tests started \((\d+) cases\)' -and ($passed.Count + $failed.Count) -lt [int]$Matches[1]) {
    $problems.Add("only $($passed.Count + $failed.Count) of $($Matches[1]) cases reported a result")
}
foreach ($l in $failed) { $problems.Add('test: ' + (Remove-LogPrefix $l 'FAIL')) }

# --- client-view case (a second server instance, with the real client connected) ---
$clientLine = $null
if ($Client) {
    $clientOut = Join-Path $PSScriptRoot ('tests\client\out\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $cc = & (Join-Path $PSScriptRoot 'tests\client\Invoke-ClientCase.ps1') -ServerDir $ServerDir -ClientDir $ClientDir -OutDir $clientOut -SelfCheck:$ClientSelfCheck
    $clientLine = "[$($cc.Status)] $($cc.Name) - $($cc.Detail)"
    if ($cc.Status -ne 'PASS') { $problems.Add('test: ' + $clientLine) }
    foreach ($p in $cc.Problems) { $problems.Add("client case: $p") }
    Write-Host "client-case artefacts: $clientOut"
}
else { $clientLine = '[SKIP] client view cases - not requested (run with -Client)' }

# --- every other log the run touched ---
$logs = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $testLog })
if (Test-Path $consoleLog) { $logs += Get-Item $consoleLog }
foreach ($f in $logs) {
    $isErrorLog = $f.Name -like 'errors_*'
    foreach ($l in (Get-NewLines $f.FullName $before)) {
        if (Test-Benign $l) { continue }
        if ($isErrorLog -or $l -match $hard) { $problems.Add("$($f.Name): $l") }
    }
}

# --- report ---
Write-Host ''
foreach ($l in $passed) { Write-Host (Remove-LogPrefix $l 'PASS') -ForegroundColor DarkGreen }
foreach ($l in $failed) { Write-Host (Remove-LogPrefix $l 'FAIL') -ForegroundColor Red }
if ($summary) { Write-Host ($summary -replace '^.*?tests finished', 'tests finished') }
$clientColour = if ($clientLine -match '^\[PASS\]') { 'DarkGreen' } elseif ($Client) { 'Red' } else { 'DarkYellow' }
Write-Host $clientLine -ForegroundColor $clientColour
if ($problems.Count) {
    Write-Host "`nProblems ($($problems.Count)):" -ForegroundColor Red
    $problems | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "`nRESULT: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "`nRESULT: PASS" -ForegroundColor Green
exit 0
