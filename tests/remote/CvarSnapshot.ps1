<#
Record and restore the server cvars a remote run changes (issue #10: "server cvars changed for the run are restored").
Values are read and set through the server console (`./cssserver send`), never by restarting. Secret cvars
(password, gslt, token) are refused by name.

  .\tests\remote\CvarSnapshot.ps1 -Action Snapshot -File out\cvars-before.json      record the run's cvars
  .\tests\remote\CvarSnapshot.ps1 -Action Diff     -File out\cvars-before.json      show what differs now (exit 1 if anything)
  .\tests\remote\CvarSnapshot.ps1 -Action Restore  -File out\cvars-before.json      put every changed cvar back and verify (exit 1 if one stuck)

-Cvars adds names to the default list in RemoteLib.ps1 ($script:RunCvars). Invoke-VisualMatrix.ps1 -Remote and
Invoke-RemoteBench.ps1 take and restore a snapshot themselves; use this script to do it by hand or to double-check.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Snapshot', 'Diff', 'Restore')][string]$Action,
    [Parameter(Mandatory)][string]$File,
    [string]$HostAlias = 'regs1',
    [string]$RemoteSmDir = '',
    [string[]]$Cvars = @()
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RemoteLib.ps1"
try { Initialize-Remote $HostAlias $RemoteSmDir; [void](Invoke-RemoteBash 'true') }
catch { Write-Host "COULD NOT REACH: $_" -ForegroundColor Red; exit 2 }

if ($Action -eq 'Snapshot') {
    $r = Save-CvarSnapshot (@($script:RunCvars) + $Cvars | Select-Object -Unique) $File
    Write-Host "saved $($r.Saved) cvar(s) to $File"
    if ($r.Missing.Count) { Write-Host "not answered by the server (plugin not loaded?): $($r.Missing -join ', ')" }
    exit 0
}
if ($Action -eq 'Diff') {
    $snap = Get-Content $File -Raw | ConvertFrom-Json
    $names = @($snap.Cvars.PSObject.Properties | ForEach-Object { $_.Name })
    $now = Get-RemoteCvars $names
    $diff = 0
    foreach ($p in $snap.Cvars.PSObject.Properties) {
        if ($now[$p.Name] -ne "$($p.Value)") { $diff++; Write-Host "DIFF $($p.Name): recorded '$($p.Value)', now '$($now[$p.Name])'" }
    }
    if ($diff) { exit 1 }
    Write-Host "OK: all $($names.Count) cvars match the snapshot"
    exit 0
}
$r = Restore-CvarSnapshot $File
Write-Host "restored: $(if ($r.Restored.Count) { $r.Restored -join ', ' } else { 'nothing to restore' })"
if ($r.Problems.Count) { $r.Problems | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
exit 0
