<#
Shared helpers for the remote (Oracle, regs1) test tooling. Dot-source it: . "$PSScriptRoot\RemoteLib.ps1"

Rules it enforces (see the theREG-AAcrew docs/ssh-access.md):
  - the server is reached only through the ssh alias (default regs1); IP, user and key live in ~/.ssh/config
  - Windows OpenSSH, BatchMode, the remote script goes in on stdin (no quoting through PowerShell, LF endings)
  - server commands go through LinuxGSM `./cssserver send`; the answer is read from the console log, so no
    rcon password is needed; if one is supplied (CSS_RCON_PASSWORD, or the file named by
    CSS_RCON_PASSWORD_FILE) it is only used to redact, and everything read back passes Protect-Text
  - nothing here starts, stops or restarts the server
PowerShell 5.1 syntax only.
#>
$script:RemoteHost = 'regs1'
$script:RemoteSmDir = $(if ($env:CSS_REMOTE_SM_DIR) { $env:CSS_REMOTE_SM_DIR } else { 'serverfiles/cstrike/addons/sourcemod' })
$script:RemoteConsoleLog = 'log/console/cssserver-console.log'
$script:RemoteGsm = './cssserver'
$script:Ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$script:Secrets = New-Object System.Collections.Generic.List[string]

# cvars the run tooling may change on the server (snapshot before, restore after)
$script:RunCvars = @(
    'mp_ignore_round_win_conditions', 'mp_autokick', 'mp_freezetime', 'mp_roundtime', 'mp_timelimit',
    'mp_limitteams', 'mp_autoteambalance', 'bot_quota',
    'sm_disablescopes_enable', 'sm_disablescopes_awp', 'sm_disablescopes_scout', 'sm_disablescopes_autosnipers',
    'sm_disablescopes_weaksnipers', 'sm_disablescopes_inair', 'sm_disablescopes_onground'
)

function Initialize-Remote([string]$HostAlias = '', [string]$SmDir = '') {
    if ($HostAlias) { $script:RemoteHost = $HostAlias }
    if ($SmDir) { $script:RemoteSmDir = $SmDir.Trim('/') }
    if ($script:RemoteHost -notmatch '^[A-Za-z0-9_.-]+$') { throw 'invalid ssh alias' }
    if ($script:RemoteSmDir -notmatch '^[A-Za-z0-9_./-]+$') { throw 'invalid remote SourceMod directory' }
    if (-not (Test-Path $script:Ssh)) { throw "Windows OpenSSH not found at $($script:Ssh)" }
    # secrets are read only to be redacted from output; never printed or stored
    $pw = $env:CSS_RCON_PASSWORD
    if (-not $pw -and $env:CSS_RCON_PASSWORD_FILE -and (Test-Path $env:CSS_RCON_PASSWORD_FILE)) {
        $pw = (Get-Content $env:CSS_RCON_PASSWORD_FILE -TotalCount 1)
    }
    if ($pw) { $script:Secrets.Add($pw.Trim()) }
}

# Redact anything that looks like a password or token. Applied to everything read from the server.
function Protect-Text([string]$text) {
    if ($null -eq $text) { return '' }
    foreach ($s in $script:Secrets) { if ($s) { $text = $text.Replace($s, 'REDACTED') } }
    $text = [regex]::Replace($text, '(?i)\b(rcon_password|sv_password|sv_setsteamaccount|gslt\w*|steam_?token\w*)\b(["'']?\s*[=:]?\s*)("[^"\r\n]*"|\S+)', '$1$2REDACTED')
    $text = [regex]::Replace($text, '\b[0-9A-Fa-f]{32}\b', 'REDACTED')   # a GSLT is 32 hex characters
    return $text
}

# Run a bash script on the server over ssh (script on stdin). Returns the redacted output as one string.
function Invoke-RemoteBash([string]$bash, [switch]$AllowFail) {
    # Sent as base64 in the command, not on stdin: Windows PowerShell 5.1 prepends a UTF-8 BOM to native stdin, and bash then fails on "\xEF\xBB\xBFcd".
    $body = ($bash -replace "`r", '') + "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
    $out = & $script:Ssh -o BatchMode=yes -o ConnectTimeout=15 $script:RemoteHost "echo $b64 | base64 -d | bash"
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw ("ssh $($script:RemoteHost) failed (exit $code). If it says permission denied or no identities, the user must re-add the key with ssh-add; never supply a passphrase. " + (Protect-Text ($out -join "`n")))
    }
    return (Protect-Text (($out | ForEach-Object { "$_" }) -join "`n"))
}

function Get-RemoteHostAddress {
    $line = @(& $script:Ssh -G $script:RemoteHost | Where-Object { $_ -match '^hostname ' }) | Select-Object -First 1
    if (-not $line) { throw "no hostname for ssh alias $($script:RemoteHost)" }
    return ($line -replace '^hostname ', '').Trim()
}

function Test-RemotePath([string]$p) { if ($p -notmatch '^[A-Za-z0-9_./*-]+$') { throw "unsafe remote path: $p" } }

function Clear-ConsoleLine([string]$l) {
    $l = $l -replace "`r", '' -replace "\x1b\[[0-9;?]*[A-Za-z]", ''
    return ($l -replace '^\[\s*\d{4}-\d\d-\d\d[^\]]*\]\s*', '')
}
function Get-RemoteLineCount([string]$relPath) {
    Test-RemotePath $relPath
    $o = Invoke-RemoteBash "cd ~ && if [ -f '$relPath' ]; then wc -l < '$relPath'; else echo 0; fi"
    return [int]($o.Trim() -replace '\D', '')
}
# Lines after line number $after (0 = whole file); returns a string[] with console decoration removed.
function Get-RemoteLines([string]$relPath, [int]$after = 0) {
    Test-RemotePath $relPath
    $o = Invoke-RemoteBash "cd ~ && tail -n +$($after + 1) '$relPath' 2>/dev/null" -AllowFail
    return @($o -split "`n" | ForEach-Object { Clear-ConsoleLine $_ })
}

# Type commands into the server console and return what the console printed meanwhile (read-only commands, or
# the cvar changes the run needs). Only a conservative character set is allowed.
function Send-RemoteCommands([string[]]$cmds, [double]$GapSec = 0.5, [double]$WaitSec = 1.5) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('cd ~ || exit 1')
    [void]$sb.AppendLine("log='$($script:RemoteConsoleLog)'")
    [void]$sb.AppendLine('n=$(wc -l < "$log")')
    foreach ($c in $cmds) {
        if ($c -notmatch '^[A-Za-z0-9_ ."/+:=,-]+$') { throw "refusing to send an unsafe console command: $c" }
        if ($c -match '(?i)\b(quit|exit|restart|_restart|rcon_password|sv_password|sv_setsteamaccount|exec|ent_fire)\b') { throw "refusing to send: $c" }
        [void]$sb.AppendLine("$($script:RemoteGsm) send '$c' > /dev/null")
        [void]$sb.AppendLine("sleep $GapSec")
    }
    [void]$sb.AppendLine("sleep $WaitSec")
    [void]$sb.AppendLine('tail -n +$((n+1)) "$log"')
    $o = Invoke-RemoteBash $sb.ToString()
    return @($o -split "`n" | ForEach-Object { Clear-ConsoleLine $_ })
}
function Send-RemoteCommand([string]$cmd, [double]$WaitSec = 1.5) { return (Send-RemoteCommands @($cmd) -WaitSec $WaitSec) }

# ---- cvars ----
function Test-SafeCvarName([string]$n) {
    if ($n -notmatch '^[A-Za-z0-9_]+$') { throw "bad cvar name: $n" }
    if ($n -match '(?i)password|gslt|token|setsteamaccount') { throw "never read or write a secret cvar: $n" }
}
# Returns a hashtable name -> value for the cvars the console answered for (others are left out).
function Get-RemoteCvars([string[]]$names) {
    foreach ($n in $names) { Test-SafeCvarName $n }
    $lines = Send-RemoteCommands $names -GapSec 0.4
    $h = @{}
    foreach ($l in $lines) {
        if ($l -match '^"([A-Za-z0-9_]+)"\s*=\s*"([^"]*)"') { if ($names -contains $Matches[1]) { $h[$Matches[1]] = $Matches[2] } }
    }
    return $h
}
function Set-RemoteCvars([hashtable]$values) {
    $cmds = New-Object System.Collections.Generic.List[string]
    foreach ($k in $values.Keys) {
        Test-SafeCvarName $k
        if ("$($values[$k])" -notmatch '^[A-Za-z0-9_. :/-]*$') { throw "unsafe value for $k" }
        $cmds.Add("$k `"$($values[$k])`"")
    }
    [void](Send-RemoteCommands $cmds.ToArray() -GapSec 0.4)
}
function Save-CvarSnapshot([string[]]$names, [string]$path) {
    $h = Get-RemoteCvars $names
    $o = [ordered]@{}
    foreach ($n in $names) { if ($h.ContainsKey($n)) { $o[$n] = $h[$n] } }
    $missing = @($names | Where-Object { -not $h.ContainsKey($_) })
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    ([pscustomobject]@{ Taken = (Get-Date -Format 's'); Host = $script:RemoteHost; Cvars = $o; Missing = $missing } | ConvertTo-Json -Depth 4) |
        Set-Content $path -Encoding utf8
    return [pscustomobject]@{ Saved = $o.Count; Missing = $missing }
}
# Put every changed cvar back, re-read, and return the list restored and any problems (empty = restored).
function Restore-CvarSnapshot([string]$path) {
    $snap = Get-Content $path -Raw | ConvertFrom-Json
    $names = @($snap.Cvars.PSObject.Properties | ForEach-Object { $_.Name })
    $now = Get-RemoteCvars $names
    $todo = @{}
    foreach ($p in $snap.Cvars.PSObject.Properties) {
        if (-not $now.ContainsKey($p.Name) -or $now[$p.Name] -ne "$($p.Value)") { $todo[$p.Name] = "$($p.Value)" }
    }
    $changed = @($todo.Keys | Sort-Object)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($todo.Count) {
        Set-RemoteCvars $todo
        $after = Get-RemoteCvars $changed
        foreach ($n in $changed) {
            if (-not $after.ContainsKey($n) -or $after[$n] -ne $todo[$n]) { $problems.Add("cvar $n not restored (wanted $($todo[$n]), now $($after[$n]))") }
        }
    }
    return [pscustomobject]@{ Restored = $changed; Problems = $problems.ToArray() }
}

# ---- server state ----
function Get-RemotePlayerCounts {
    $l = @(Send-RemoteCommand 'status' | Where-Object { $_ -match 'players\s*:\s*(\d+)\s+humans?,\s*(\d+)\s+bots?' }) | Select-Object -First 1
    if (-not $l) { return $null }
    [void]($l -match 'players\s*:\s*(\d+)\s+humans?,\s*(\d+)\s+bots?')
    return [pscustomobject]@{ Humans = [int]$Matches[1]; Bots = [int]$Matches[2] }
}
function Get-RemotePluginLines { return @(Send-RemoteCommand 'sm plugins list' -WaitSec 2 | Where-Object { $_ -match '^\s*\d+\s+"' }) }
