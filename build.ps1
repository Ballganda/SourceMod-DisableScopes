# Compiles scripting\*.sp (the plugin) and tests\*.sp (the suite) with the spcomp that ships
# with the SourceMod install on the local test server.
#   .\build.ps1            compile only
#   .\build.ps1 -Deploy    compile, then copy the .smx files to the server
param(
    [switch]$Deploy,
    [string]$SourceModDir = $(if ($env:SOURCEMOD_DIR) { $env:SOURCEMOD_DIR } else { 'C:\Users\user\cssds\cstrike\addons\sourcemod' })
)

$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 1 }

$out = Join-Path $PSScriptRoot 'plugins'
New-Item -ItemType Directory -Force $out | Out-Null

# The plugin was built as disablescopes.smx before it was renamed to sm_disablescopes.smx; a leftover copy
# would load next to the new one, so remove it from the output folder and, when deploying, from the server.
Remove-Item (Join-Path $out 'disablescopes.smx') -ErrorAction SilentlyContinue
if ($Deploy) { Remove-Item (Join-Path $SourceModDir 'plugins\disablescopes.smx') -ErrorAction SilentlyContinue }

$failed = 0
$targets = @(Get-ChildItem (Join-Path $PSScriptRoot 'scripting') -Filter *.sp) + @(Get-ChildItem (Join-Path $PSScriptRoot 'tests') -Filter *.sp -ErrorAction SilentlyContinue)
foreach ($sp in $targets) {
    $smx = Join-Path $out ($sp.BaseName + '.smx')
    & $spcomp $sp.FullName "-i$SourceModDir\scripting\include" "-o$smx"
    if ($LASTEXITCODE -ne 0) { $failed++; continue }
    if ($Deploy) {
        Copy-Item $smx (Join-Path $SourceModDir 'plugins') -Force
        Write-Host "Deployed $($sp.BaseName).smx"
    }
}
if ($failed) { Write-Error "$failed plugin(s) failed to compile"; exit 1 }
