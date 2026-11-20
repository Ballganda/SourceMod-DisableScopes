<#
Read-only deploy check of the remote server (issue #10): which build is loaded, which files are on disk, and the
SourceMod error log tail. Never changes anything on the server.

  .\tests\remote\Check-RemoteDeploy.ps1 -ExpectVersion 0.0.b9                   loaded version, plugin list, files, error log tail
  .\tests\remote\Check-RemoteDeploy.ps1 -SaveBaseline out\err-before.json         record the error log line counts before a run
  .\tests\remote\Check-RemoteDeploy.ps1 -Since out\err-before.json                after a run: new error log lines since then (exit 1 if any)
  .\tests\remote\Check-RemoteDeploy.ps1 -ExpectNoHelper                           fails if a test helper (matrix, bench, tests) is loaded or on disk

Exit 0 = every requested expectation holds; 1 = one failed; 2 = could not reach the server.
-RemoteSmDir is the SourceMod directory relative to the ssh login directory (default serverfiles/cstrike/addons/sourcemod,
or CSS_REMOTE_SM_DIR). Output is passed through the redaction in RemoteLib.ps1.
#>
param(
    [string]$HostAlias = 'regs1',
    [string]$RemoteSmDir = '',
    [string]$ExpectVersion = '',
    [switch]$ExpectNoHelper,
    [string]$SaveBaseline = '',
    [string]$Since = '',
    [int]$Tail = 25
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RemoteLib.ps1"
$fail = New-Object System.Collections.Generic.List[string]
try {
    Initialize-Remote $HostAlias $RemoteSmDir
    $sm = $script:RemoteSmDir
    [void](Invoke-RemoteBash 'true')
}
catch { Write-Host "COULD NOT REACH: $_" -ForegroundColor Red; exit 2 }

Write-Host "== plugin files ($sm/plugins) =="
$files = Invoke-RemoteBash "cd ~ && ls -l --time-style=long-iso '$sm/plugins' '$sm/plugins/disabled' 2>/dev/null | grep -i 'disablescopes'" -AllowFail
Write-Host $files
Write-Host '== loaded plugins =='
$pl = Get-RemotePluginLines
$ours = @($pl | Where-Object { $_ -match '(?i)scope' })
if ($ours.Count) { $ours | ForEach-Object { Write-Host $_ } } else { Write-Host '(no plugin with "scope" in its name is loaded)' }
$vl = @(Send-RemoteCommand 'sm_disablescopes_version' | Where-Object { $_ -match '^"sm_disablescopes_version"\s*=\s*"([^"]*)"' }) | Select-Object -First 1
$version = if ($vl -and ($vl -match '"sm_disablescopes_version"\s*=\s*"([^"]*)"')) { $Matches[1] } else { '' }
Write-Host "loaded version (sm_disablescopes_version): $(if ($version) { $version } else { 'not readable' })"
if ($ExpectVersion) {
    if ($version -ne $ExpectVersion) { $fail.Add("expected version $ExpectVersion, loaded '$version'") }
    else { Write-Host "OK: version $ExpectVersion is loaded" }
}
if ($ExpectNoHelper) {
    $helpersLoaded = @($pl | Where-Object { $_ -match '(?i)disablescopes_(matrix|bench|tests)' })
    $helpersOnDisk = @($files -split "`n" | Where-Object { $_ -match '(?i)disablescopes_(matrix|bench|tests)' })
    if ($helpersLoaded.Count) { $fail.Add('a test helper is still loaded: ' + ($helpersLoaded -join ' | ')) }
    if ($helpersOnDisk.Count) { $fail.Add('a test helper file is still on disk: ' + ($helpersOnDisk -join ' | ')) }
    if (-not $helpersLoaded.Count -and -not $helpersOnDisk.Count) { Write-Host 'OK: no test helper loaded or on disk' }
}

Write-Host "== error logs ($sm/logs/errors_*.log) =="
$counts = Invoke-RemoteBash "cd ~ && for f in '$sm'/logs/errors_*.log; do [ -f ""`$f"" ] && echo ""`$(wc -l < ""`$f"") `$f""; done; true" -AllowFail
$now = [ordered]@{}
foreach ($l in ($counts -split "`n")) { if ($l -match '^\s*(\d+)\s+(\S+)$') { $now[$Matches[2]] = [int]$Matches[1] } }
if (-not $now.Count) { Write-Host '(no error log files)' }
foreach ($k in $now.Keys) { Write-Host ("{0,6} lines  {1}" -f $now[$k], $k) }
if ($now.Count) {
    $newest = @($now.Keys | Sort-Object)[-1]
    Write-Host "-- last $Tail lines of $newest --"
    (Invoke-RemoteBash "cd ~ && tail -n $Tail '$newest'" -AllowFail) | Write-Host
}
if ($SaveBaseline) {
    $bdir = Split-Path -Parent $SaveBaseline
    if ($bdir) { New-Item -ItemType Directory -Force $bdir | Out-Null }
    ([pscustomobject]@{ Taken = (Get-Date -Format 's'); Counts = $now } | ConvertTo-Json -Depth 4) | Set-Content $SaveBaseline -Encoding utf8
    Write-Host "baseline saved: $SaveBaseline"
}
if ($Since) {
    $base = Get-Content $Since -Raw | ConvertFrom-Json
    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $now.Keys) {
        $was = 0
        $p = $base.Counts.PSObject.Properties[$k]
        if ($p) { $was = [int]$p.Value }
        if ($now[$k] -gt $was) {
            foreach ($l in (Invoke-RemoteBash "cd ~ && tail -n +$($was + 1) '$k'" -AllowFail) -split "`n") { if ($l.Trim()) { $newLines.Add($l) } }
        }
    }
    if ($newLines.Count) { $fail.Add("$($newLines.Count) new error log line(s) since $Since"); $newLines | Select-Object -First 40 | ForEach-Object { Write-Host "  NEW: $_" } }
    else { Write-Host "OK: no new error log lines since $Since" }
}
if ($fail.Count) { $fail | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
exit 0
