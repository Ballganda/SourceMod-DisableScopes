<#
Compile the two test helpers in their remote builds (local only; touches nothing on the server):
  disablescopes_matrix.smx   (-DSC_REMOTE: never quits the server, never touches sv_cheats or net_fakelag)
  disablescopes_bench.smx    (-DSB_REMOTE: no quit, starts on `disablescopes_bench_run`, kicks its bots when done)
Both report a version ending in "-remote"; the remote scripts refuse to run against a helper without it.
The deploy step (copying the .smx into addons/sourcemod/plugins and loading it) is the deploy agent's job.

  .\tests\remote\Build-RemoteHelpers.ps1 -OutDir tests\remote\out\helpers
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'out\helpers'),
    [string]$SourceModDir = $(if ($env:SOURCEMOD_DIR) { $env:SOURCEMOD_DIR } else { 'C:\Users\user\cssds\cstrike\addons\sourcemod' })
)
$ErrorActionPreference = 'Stop'
$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 2 }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tests = Split-Path $PSScriptRoot
$jobs = @(
    @{ Src = Join-Path $tests 'client\disablescopes_matrix.sp'; Define = 'DSC_REMOTE=1'; Out = 'disablescopes_matrix.smx' },
    @{ Src = Join-Path $tests 'disablescopes_bench.sp'; Define = 'DSB_REMOTE=1'; Out = 'disablescopes_bench.smx' }
)
foreach ($j in $jobs) {
    & $spcomp $j.Src $j.Define "-i$SourceModDir\scripting\include" "-o$(Join-Path $OutDir $j.Out)" | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "compile failed: $($j.Src)"; exit 1 }
}
Write-Host "built into $OutDir"
exit 0
