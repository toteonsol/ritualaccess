<#
.SYNOPSIS
    run.ps1 - manage a recurring sovereign agent on Ritual testnet (chain 1979).
    Commands: deploy (default), status, topup, restart, stop. Windows companion to
    run.sh (pwsh 7+). Auto-installs foundry + uv. Needs foundry (cast, forge) and uv.
#>
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

$HERE = $PSScriptRoot

### ---------- look and feel ----------
# Color only when stdout is a real console and the user has not opted out via NO_COLOR.
$ESC = [char]27
$script:UseColor = (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)
if ($UseColor) {
    $RESET = "$ESC[0m"; $BOLD = "$ESC[1m"; $DIM = "$ESC[2m"; $CLR = "$ESC[K"
    $ACCENT = "$ESC[38;5;141m"; $OKC = "$ESC[38;5;78m"; $BADC = "$ESC[38;5;203m"
    $WARNC = "$ESC[38;5;214m"; $MUTED = "$ESC[38;5;244m"; $HIDE = "$ESC[?25l"; $SHOW = "$ESC[?25h"
} else {
    $RESET = $BOLD = $DIM = $CLR = $ACCENT = $OKC = $BADC = $WARNC = $MUTED = $HIDE = $SHOW = ''
}

function Fail([string]$m) { Write-Host ""; Write-Host "  ${BADC}ERROR$RESET $m"; exit 1 }
function Hr { Write-Host "  $MUTED--------------------------------------------$RESET" }

# Paint a short string letter by letter through a purple-to-pink ramp.
function Gradient([string]$t) {
    if (-not $UseColor) { return $t }
    $ramp = 99, 105, 141, 147, 183, 219, 213
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $t.Length; $i++) { [void]$sb.Append("$ESC[1;38;5;$($ramp[$i % $ramp.Count])m$($t[$i])") }
    [void]$sb.Append($RESET); return $sb.ToString()
}

$script:BannerShown = $false
function Banner {
    if ($script:BannerShown) { return }; $script:BannerShown = $true
    Write-Host ""; Write-Host "  $(Gradient 'RITUAL SOVEREIGN AGENT')"
    Write-Host "  ${DIM}recurring keyless agent - Ritual testnet (1979)$RESET"
    Write-Host "  ${MUTED}built by Zun  ${ACCENT}https://x.com/Zun2025$RESET"; Hr
}
function Step([string]$m) { Write-Host ""; Write-Host "  $ACCENT>$RESET $BOLD$m$RESET" }
function Info([string]$m) { Write-Host "    $MUTED$m$RESET" }
function Ok([string]$m)   { Write-Host "  ${OKC}ok$RESET $m" }
function Warn([string]$m) { Write-Host "  $WARNC!$RESET  $m" }
function Kv([string]$k, [string]$v) { Write-Host ("  $MUTED{0,-11}$RESET {1}" -f $k, $v) }

# Run a process behind a braille spinner; output is captured and shown only on failure, and left
# in $script:SpinOut. $Retries re-runs the command that many times (for flaky network steps).
$script:SpinOut = ''
function Spin {
    param([string]$Msg, [string]$Exe, [string[]]$CmdArgs, [int]$Retries = 1)
    $errtxt = ''
    $frames = [char[]](0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $resolved = Get-Command $Exe -ErrorAction SilentlyContinue
        $psi.FileName = if ($resolved) { $resolved.Source } else { $Exe }
        foreach ($a in $CmdArgs) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # drain both pipes concurrently so a noisy installer cannot deadlock on a full buffer
        $outT = $p.StandardOutput.ReadToEndAsync(); $errT = $p.StandardError.ReadToEndAsync()
        if ($UseColor) {
            [Console]::Write($HIDE); $i = 0
            while (-not $p.HasExited) {
                [Console]::Write("`r  $ACCENT$($frames[$i % $frames.Length])$RESET $Msg")
                Start-Sleep -Milliseconds 80; $i++
            }
            [Console]::Write($SHOW)
        } else { Write-Host "  $Msg ..." -NoNewline }
        $p.WaitForExit()
        $script:SpinOut = $outT.Result; $errtxt = $errT.Result
        if ($p.ExitCode -eq 0) {
            if ($UseColor) { Write-Host "`r  ${OKC}ok$RESET $Msg$CLR" } else { Write-Host " ok" }
            return
        }
        if ($attempt -lt $Retries) {
            if ($UseColor) { Write-Host "`r  ${WARNC}~$RESET $Msg (retry $($attempt + 1)/$Retries)$CLR" } else { Write-Host " (retry $($attempt + 1)/$Retries)" }
            Start-Sleep -Seconds 1
        }
    }
    if ($UseColor) { Write-Host "`r  ${BADC}x$RESET $Msg$CLR" } else { Write-Host " failed" }
    (("$script:SpinOut`n$errtxt") -split "`n") | ForEach-Object { if ($_.Trim()) { Write-Host "      $_" } }
    Fail "step failed: $Msg"
}

function Show-Usage {
    Banner
    Write-Host "  ${BOLD}Usage$RESET  pwsh run.ps1 [command] [args]"
    Write-Host ""
    Write-Host "  ${ACCENT}deploy$RESET                    deploy + fund + arm (asks before a 2nd agent)"
    Write-Host "  ${ACCENT}status$RESET [address]          list your agents, or detail one by address"
    Write-Host "  ${ACCENT}topup$RESET [address] [wei]     deposit more RITUAL (re-arms if stopped)"
    Write-Host "  ${ACCENT}restart$RESET [address]         re-arm an agent"
    Write-Host "  ${ACCENT}stop$RESET [address]            stop an agent"
    Write-Host "  ${ACCENT}help$RESET                      show this help"
    Write-Host ""
    Write-Host "  No address -> the agent for SALT in .env. Lock duration: LOCK_BLOCKS (default 100000)."
}

# command + optional positional arg (no param() block so leading '--' is not eaten)
$CMD = if ($args.Count -ge 1) { ([string]$args[0]) -replace '^--', '' } else { 'deploy' }
$ARG1 = if ($args.Count -ge 2) { [string]$args[1] } else { $null }
$ARG2 = if ($args.Count -ge 3) { [string]$args[2] } else { $null }
if ($CMD -in @('help', '-h', '')) { Show-Usage; exit 0 }

if (-not (Test-Path "$HERE\.env")) { Fail ".env not found. Run: copy .env.example .env  then edit it." }

# Load .env: skip blank lines and comments, strip surrounding quotes from values
Get-Content "$HERE\.env" | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$' -and $_ -notmatch '^\s*#') {
        $val = $Matches[2] -replace '^[\"'']|[\"'']$'
        [System.Environment]::SetEnvironmentVariable($Matches[1], $val, 'Process')
    }
}

# Ritual testnet system contracts
$FACTORY       = "0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304"
$RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948"
$env:REGISTRY  = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F"
$LOCK_BLOCKS   = if ($env:LOCK_BLOCKS) { $env:LOCK_BLOCKS } else { "100000" }

function Need-Deposit  { if (-not $env:DEPOSIT_WEI) { Fail "DEPOSIT_WEI is required" } }
function Num([string]$s) { ($s -split ' ')[0] }  # strip cast's trailing "[1.5e16]" label

# Run a read-only cast call, retrying on empty output (the public RPC can be flaky).
function Invoke-Rpc([string[]]$RpcArgs) {
    for ($i = 1; $i -le 3; $i++) {
        $out = (& cast @RpcArgs 2>$null)
        if ($out) { return (($out | Out-String).Trim()) }
        Start-Sleep -Seconds 1
    }
    return ''
}
function Test-Addr([string]$s) { return ($s -match '^0x[0-9a-fA-F]{40}$') }
function Get-Harness([string]$us) {
    ((Invoke-Rpc @('call', $FACTORY, 'predictHarness(address,bytes32)(address,bytes32)', $env:WALLET_ADDRESS, $us, '--rpc-url', $env:RPC_URL)) -split "`n")[0].Trim()
}

### ---------- keystore signer ----------
$script:KS_PASSWORD = ''

# Read a password showing one '*' per char (backspace supported).
function Read-Masked([string]$prompt) {
    Write-Host -NoNewline $prompt
    $sb = [System.Text.StringBuilder]::new()
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; break }
        elseif ($k.Key -eq 'Backspace') { if ($sb.Length -gt 0) { $sb.Length--; Write-Host -NoNewline "`b `b" } }
        elseif ($k.KeyChar) { [void]$sb.Append($k.KeyChar); Write-Host -NoNewline '*' }
    }
    return $sb.ToString()
}

# Set or replace KEY=VALUE in .env so the name and address persist across runs.
function Set-EnvVar([string]$k, [string]$v) {
    $f = "$HERE\.env"
    $lines = if (Test-Path $f) { @(Get-Content $f) } else { @() }
    if ($lines -match "^$k=") {
        ($lines | ForEach-Object { if ($_ -match "^$k=") { "$k=$v" } else { $_ } }) | Set-Content -Path $f -Encoding UTF8
    } else { Add-Content -Path $f -Value "$k=$v" -Encoding UTF8 }
}

# First run: ask name + key + password, create the encrypted keystore, save name + address.
function Import-Keystore {
    Banner
    Step "Set up your wallet keystore"
    $name = $env:KEYSTORE_ACCOUNT
    if (-not $name) { $name = Read-Host "  name for your keystore [ritual-deployer]"; if (-not $name) { $name = "ritual-deployer" } }
    if (Test-Path (Join-Path "$HOME\.foundry\keystores" $name)) {   # name already exists -> adopt it
        $env:KEYSTORE_ACCOUNT = $name; Set-EnvVar "KEYSTORE_ACCOUNT" $name
        Unlock
        $env:WALLET_ADDRESS = (& cast wallet address --account $name --password $script:KS_PASSWORD 2>$null)
        if (-not $env:WALLET_ADDRESS) { Fail "wrong keystore password" }
        Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
        Ok "using existing keystore '$name' for $env:WALLET_ADDRESS"; return
    }
    $key = Read-Masked "  paste your wallet private key: "
    if (-not $key) { Fail "no private key entered" }
    if ($key -notmatch '^0x') { $key = "0x$key" }
    $p1 = ''
    for ($i = 1; $i -le 3; $i++) {
        $p1 = Read-Masked "  set a keystore password: "
        $p2 = Read-Masked "  confirm password: "
        if ($p1 -and $p1 -eq $p2) { break }
        if (-not $p1) { Warn "empty password ($i/3)" } else { Warn "passwords do not match ($i/3)" }
        $p1 = ''
    }
    if (-not $p1) { Fail "could not set a password after 3 tries" }
    Spin "creating encrypted keystore" "cast" @('wallet', 'import', $name, '--private-key', $key, '--unsafe-password', $p1)
    $env:WALLET_ADDRESS = (& cast wallet address --private-key $key 2>$null)
    if (-not $env:WALLET_ADDRESS) { Fail "invalid private key" }
    $env:KEYSTORE_ACCOUNT = $name; $script:KS_PASSWORD = $p1
    Set-EnvVar "KEYSTORE_ACCOUNT" $name
    Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
    Ok "keystore '$name' ready for $env:WALLET_ADDRESS"
}

# Ensure a keystore + public address exist (import on first run). Reads never need the password.
function Resolve-Signer {
    $name = $env:KEYSTORE_ACCOUNT
    if (-not $name -or -not (Test-Path (Join-Path "$HOME\.foundry\keystores" $name))) { Import-Keystore; return }
    $env:KEYSTORE_ACCOUNT = $name
    if (-not $env:WALLET_ADDRESS) {
        Unlock
        $env:WALLET_ADDRESS = (& cast wallet address --account $name --password $script:KS_PASSWORD 2>$null)
        if (-not $env:WALLET_ADDRESS) { Fail "wrong keystore password" }
        Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
    }
}

# Ask the keystore password once per run (masked) and verify it decrypts the keystore.
function Unlock {
    if ($script:KS_PASSWORD) { return }
    for ($i = 1; $i -le 3; $i++) {
        $pw = Read-Masked "  keystore password: "
        & cast wallet address --account $env:KEYSTORE_ACCOUNT --password $pw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:KS_PASSWORD = $pw; return }
        Warn "wrong password ($i/3)"
    }
    Fail "wrong keystore password after 3 tries"
}

# Next salt for a fresh agent: bump a trailing number, else append -2 (agent-1 -> agent-2).
function Next-Salt([string]$s) {
    if ($s -match '^(.*[^0-9])([0-9]+)$') { return $Matches[1] + ([int]$Matches[2] + 1) }
    elseif ($s -match '^([0-9]+)$') { return [string]([int]$s + 1) }
    else { return "$s-2" }
}

# Fixed gas for configure/restart. Ritual's estimateGas lies here (~192M for a call that really
# uses ~2.1M), so we ignore it - a real deploy went through on 3.5M. 5M leaves room and stays
# well under the 200M block limit. The cast call below still catches a genuinely bad request.
$SCHED_GAS = "5000000"

### ---------- prerequisites (auto-install, no prompts) ----------
# Foundry lands in ~/.foundry/bin, uv in ~/.local/bin. Put both on PATH for this run...
function Ensure-PathNow {
    foreach ($d in @("$HOME\.foundry\bin", "$HOME\.local\bin")) {
        if (($env:PATH -split ';') -notcontains $d) { $env:PATH = "$d;$env:PATH" }
    }
}
# ...and once in the User PATH so future shells see it too (idempotent).
function Persist-Path([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (($userPath -split ';') -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('PATH', "$Dir;$userPath", 'User')
    }
}

function Install-Foundry {
    Step "Installing Foundry (cast, forge)"
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Fail "Foundry needs bash to install on Windows - install Git Bash, or use run.sh instead." }
    Spin "fetch foundryup"      $bash.Source @('-c', 'curl -fsSL https://foundry.paradigm.xyz | bash') 3
    Ensure-PathNow
    Spin "install cast + forge" $bash.Source @('-c', '~/.foundry/bin/foundryup') 3
    Persist-Path "$HOME\.foundry\bin"
}

function Install-Uv {
    Step "Installing uv"
    $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { (Get-Command powershell).Source }
    Spin "fetch + install uv" $ps @('-NoProfile', '-Command', 'irm https://astral.sh/uv/install.ps1 | iex') 3
    Ensure-PathNow
    Persist-Path "$HOME\.local\bin"
}

function Ensure-Tools {
    Ensure-PathNow
    if (-not (Get-Command cast -ErrorAction SilentlyContinue) -or -not (Get-Command forge -ErrorAction SilentlyContinue)) { Install-Foundry }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Install-Uv }
    Ensure-PathNow
    foreach ($b in 'cast', 'forge', 'uv') {
        if (-not (Get-Command $b -ErrorAction SilentlyContinue)) { Fail "$b still missing after install - open a new shell and retry" }
    }
}

# install tools, then ensure a keystore + public address exist (imports your wallet on first run)
Ensure-Tools
Resolve-Signer

# deterministic harness address (also the delivery target) - needed by every command
$SALT_VAL = if ($env:SALT) { $env:SALT } else { "ritual-agent-1" }
$USERSALT = (& cast keccak $SALT_VAL).Trim()
$env:HARNESS = Get-Harness $USERSALT

function Test-Deployed { (Invoke-Rpc @('code', $env:HARNESS, '--rpc-url', $env:RPC_URL)).Length -gt 2 }

# Live = a contract is deployed at this harness AND it has already been configured.
function Test-Live([string]$h) {
    if ((Invoke-Rpc @('code', $h, '--rpc-url', $env:RPC_URL)).Length -le 2) { return $false }
    return ((Invoke-Rpc @('call', $h, 'configured()(bool)', '--rpc-url', $env:RPC_URL)) -eq "true")
}

# Print one agent row: salt, address, state, balance.
function Show-Agent([string]$salt, [string]$h) {
    $cf = Invoke-Rpc @('call', $h, 'configured()(bool)', '--rpc-url', $env:RPC_URL)
    $wake = Num (Invoke-Rpc @('call', $h, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL))
    $raw = Num (Invoke-Rpc @('call', $RITUAL_WALLET, 'balanceOf(address)(uint256)', $h, '--rpc-url', $env:RPC_URL))
    $bal = & cast to-unit $(if ($raw) { $raw } else { '0' }) ether
    $state = if ($cf -ne "true") { "${WARNC}unconfigured$RESET" } elseif ($wake -eq "1") { "${OKC}armed$RESET" } else { "${MUTED}stopped$RESET" }
    Write-Host ("  $BOLD{0,-18}$RESET {1}  {2}  {3} RITUAL" -f $salt, $h, $state, $bal)
}

# Detailed view of a single agent by address (used when an address is passed to status).
function Show-AgentDetail([string]$h) {
    if ((Invoke-Rpc @('code', $h, '--rpc-url', $env:RPC_URL)).Length -le 2) { Warn "no contract at $h (not deployed)"; return }
    $raw = Num (Invoke-Rpc @('call', $RITUAL_WALLET, 'balanceOf(address)(uint256)', $h, '--rpc-url', $env:RPC_URL))
    $lock = Num (Invoke-Rpc @('call', $RITUAL_WALLET, 'lockUntil(address)(uint256)', $h, '--rpc-url', $env:RPC_URL))
    Hr
    Kv "agent"      $h
    Kv "configured" (Invoke-Rpc @('call', $h, 'configured()(bool)', '--rpc-url', $env:RPC_URL))
    Kv "wakeMode"   "$(Num (Invoke-Rpc @('call', $h, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL)))  (1 armed / 0 stopped)"
    Kv "balance"    "$(& cast to-unit $(if ($raw) { $raw } else { '0' }) ether) RITUAL"
    Kv "lockUntil"  "block $(if ($lock) { $lock } else { '?' })  (now $(Invoke-Rpc @('block-number', '--rpc-url', $env:RPC_URL)))"
}

# status            -> list every agent you deployed (salt series agent-1, agent-2, ...).
# status <address>  -> detailed view of one agent (paste any harness address).
function Invoke-Status([string]$arg) {
    Banner
    Kv "Owner" $env:WALLET_ADDRESS
    Kv "Chain" "$(& cast chain-id --rpc-url $env:RPC_URL)"
    if (Test-Addr $arg) { Step "Agent"; Show-AgentDetail $arg; return }
    Step "Your agents"
    $salt = if ($env:SALT) { $env:SALT } else { "ritual-agent-1" }
    $miss = 0; $found = 0
    while ($miss -lt 2 -and $found -lt 100) {
        $us = (& cast keccak $salt).Trim()
        $h = Get-Harness $us
        $code = (& cast code $h --rpc-url $env:RPC_URL 2>$null)
        if (-not $code -or $code.Trim().Length -le 2) { $miss++; $salt = Next-Salt $salt; continue }
        $miss = 0; $found++
        Show-Agent $salt $h
        $salt = Next-Salt $salt
    }
    if ($found -eq 0) { Info "no agents yet - run: pwsh run.ps1 deploy" }
    else { Hr; Info "$found agent(s). Manage one: pwsh run.ps1 restart|stop|topup <agent-address>" }
}

# Read wakeMode and report it with the correct label (1+ = armed, 0 = stopped).
function Show-Wake {
    $wm = Num (Invoke-Rpc @('call', $env:HARNESS, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL))
    if ($wm -eq "0") { Ok "wakeMode 0 (stopped)" } else { Ok "wakeMode $(if ($wm) { $wm } else { '?' }) (armed)" }
}

function Invoke-Restart([string]$target) {
    if (Test-Addr $target) { $env:HARNESS = $target }
    if (-not (Test-Deployed)) { Fail "harness not deployed yet - run: pwsh run.ps1 deploy" }
    Banner
    Step "Re-arm agent"
    Kv "agent" $env:HARNESS
    & cast call $env:HARNESS "restart()" --from $env:WALLET_ADDRESS --rpc-url $env:RPC_URL 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "restart() reverts on-chain - the agent is already armed, or its schedule has ended" }
    Unlock
    Spin "broadcasting restart()" "cast" @('send', $env:HARNESS, 'restart()', '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--gas-limit', $SCHED_GAS)
    Show-Wake
}

function Invoke-Stop([string]$target) {
    if (Test-Addr $target) { $env:HARNESS = $target }
    if (-not (Test-Deployed)) { Fail "harness not deployed" }
    Banner
    Step "Stop agent"
    Kv "agent" $env:HARNESS
    & cast call $env:HARNESS "stop()" --from $env:WALLET_ADDRESS --rpc-url $env:RPC_URL 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "stop() reverts on-chain - the agent is not in a stoppable state (its schedule may have already ended)" }
    Unlock
    Spin "broadcasting stop()" "cast" @('send', $env:HARNESS, 'stop()', '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--gas-limit', '3500000')
    Show-Wake
}

function Invoke-Topup([string]$a1, [string]$a2) {
    Need-Deposit
    if (Test-Addr $a1) { $env:HARNESS = $a1; $amount = if ($a2) { $a2 } else { $env:DEPOSIT_WEI } }
    else { $amount = if ($a1) { $a1 } else { $env:DEPOSIT_WEI } }
    if (-not (Test-Deployed)) { Fail "harness not deployed yet - run: pwsh run.ps1 deploy" }
    Banner
    Step "Deposit $(& cast to-unit $amount ether) RITUAL"
    Kv "agent" $env:HARNESS
    Info "lock $LOCK_BLOCKS blocks"
    Unlock
    Spin "depositing" "cast" @('send', $RITUAL_WALLET, 'depositFor(address,uint256)', $env:HARNESS, $LOCK_BLOCKS, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--value', $amount)
    if ((Num (Invoke-Rpc @('call', $env:HARNESS, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL))) -eq "0") {
        Warn "agent was stopped; re-arming"
        Invoke-Restart
    } else {
        $bal = Invoke-Rpc @('call', $RITUAL_WALLET, 'balanceOf(address)(uint256)', $env:HARNESS, '--rpc-url', $env:RPC_URL)
        Ok "topped up. balance $(& cast to-unit (Num $bal) ether) RITUAL (still armed)"
    }
}

function Invoke-Deploy {
    Need-Deposit
    Banner
    Kv "Owner"   $env:WALLET_ADDRESS
    Kv "Chain"   "$(& cast chain-id --rpc-url $env:RPC_URL)"
    Kv "Balance" "$(& cast balance $env:WALLET_ADDRESS --ether --rpc-url $env:RPC_URL) RITUAL"

    # Resolve the agent for SALT. If it is already live, ask before making another; on yes,
    # advance to the first free salt (agent-1 -> agent-2 -> ...).
    Step "Select agent"
    $salt = if ($env:SALT) { $env:SALT } else { "ritual-agent-1" }
    $n = 0
    $USERSALT = (& cast keccak $salt).Trim()
    $env:HARNESS = Get-Harness $USERSALT
    if (Test-Live $env:HARNESS) {
        Warn "you already have an agent live:"
        Kv "  salt"  $salt
        Kv "  agent" $env:HARNESS
        $reply = Read-Host "`n  Deploy another (new) agent? [y/N]"
        if ($reply -notmatch '^(y|Y|yes|YES)$') { Info "left it running - inspect with: pwsh run.ps1 status"; exit 0 }
        while (Test-Live $env:HARNESS) {
            $salt = Next-Salt $salt
            $USERSALT = (& cast keccak $salt).Trim()
            $env:HARNESS = Get-Harness $USERSALT
            $n++; if ($n -gt 200) { Fail "200+ live agents - set a fresh SALT in .env" }
        }
        Ok "new slot: $salt"
    }
    Kv "Salt"    $salt
    Kv "Deposit" "$(& cast to-unit $env:DEPOSIT_WEI ether) RITUAL"
    Kv "Harness" $env:HARNESS
    Unlock

    # build the encrypted, ABI-encoded configureFundAndStart payload (Python -> temp file)
    Step "Build request"
    $PY_SCRIPT = @'
import os
from ecies import encrypt as ecies_encrypt
from ecies.config import ECIES_CONFIG
from eth_abi.abi import encode
from web3 import Web3

ECIES_CONFIG.symmetric_nonce_length = 12
w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
reg_abi = [{"name": "getServicesByCapability", "type": "function", "stateMutability": "view",
            "inputs": [{"name": "c", "type": "uint8"}, {"name": "v", "type": "bool"}],
            "outputs": [{"name": "", "type": "tuple[]", "components": [
                {"name": "node", "type": "tuple", "components": [
                    {"name": "paymentAddress", "type": "address"}, {"name": "teeAddress", "type": "address"},
                    {"name": "teeType", "type": "uint8"}, {"name": "publicKey", "type": "bytes"},
                    {"name": "endpoint", "type": "string"}, {"name": "certPubKeyHash", "type": "bytes32"},
                    {"name": "capability", "type": "uint8"}]},
                {"name": "isValid", "type": "bool"}, {"name": "workloadId", "type": "bytes32"}]}]}]
reg = w3.eth.contract(address=Web3.to_checksum_address(os.environ["REGISTRY"]), abi=reg_abi)
svc = reg.functions.getServicesByCapability(0, True).call()
if not svc:
    raise SystemExit("no valid executors in TEEServiceRegistry")
node = svc[0][0]
executor = Web3.to_checksum_address(node[1])
pub = bytes(node[3])

harness = Web3.to_checksum_address(os.environ["HARNESS"])
enc = ecies_encrypt(pub.hex(), b'{"LLM_PROVIDER":"ritual"}')
delivery_selector = Web3.keccak(text="onSovereignAgentResult(bytes32,bytes)")[:4]
max_poll_block = w3.eth.block_number + 10_000_000

params = (
    executor, 500, b"", 5, max_poll_block, "SOVEREIGN_AGENT_TASK", harness, delivery_selector,
    3_000_000, 1_000_000_000, 100_000_000, int(os.environ["CLI_TYPE"]), os.environ["PROMPT"], enc,
    ("", "", ""), ("", "", ""), [], ("", "", ""), os.environ["MODEL"], [], 5, 2048, "",
)
schedule = (800_000, 180, 500, 1_000_000_000, 100_000_000, 0)
rolling = (1, 5000, 1)

PT = ("(address,uint256,bytes,uint64,uint64,string,address,bytes4,uint256,uint256,uint256,uint16,"
      "string,bytes,(string,string,string),(string,string,string),(string,string,string)[],"
      "(string,string,string),string,string[],uint16,uint32,string)")
ST = "(uint32,uint32,uint32,uint256,uint256,uint256)"
RT = "(uint32,uint16,uint16)"
selector = Web3.keccak(text=f"configureFundAndStart({PT},{ST},{RT},uint256)")[:4]
data = selector + encode([PT, ST, RT, "uint256"], [params, schedule, rolling, 100_000])
print("EXECUTOR=" + executor)
print("CONFIG_CALLDATA=0x" + data.hex())
'@
    $tmpPy = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ritual_deploy_$([System.IO.Path]::GetRandomFileName()).py")
    $PY_SCRIPT | Set-Content -Path $tmpPy -Encoding UTF8
    try {
        Spin "discover executor, encrypt secret, encode calldata" `
            "uv" @('run', '--quiet', '--with', 'eciespy', '--with', 'eth-abi', '--with', 'web3', 'python', $tmpPy) 3
    } finally {
        Remove-Item $tmpPy -ErrorAction SilentlyContinue
    }
    $OUT = $script:SpinOut
    $EXECUTOR        = ($OUT -split "`n" | Where-Object { $_ -match '^EXECUTOR=' })        -replace '^EXECUTOR=', '' -replace '\s', ''
    $CONFIG_CALLDATA = ($OUT -split "`n" | Where-Object { $_ -match '^CONFIG_CALLDATA=' }) -replace '^CONFIG_CALLDATA=', '' -replace '\s', ''
    if (-not $CONFIG_CALLDATA) { Write-Host $OUT; Fail "failed to build request" }
    Ok "executor $EXECUTOR"

    # deploy the harness if it is not on-chain yet (CREATE3 needs ~2.5M gas)
    Step "Deploy harness"
    $CODE = (& cast code $env:HARNESS --rpc-url $env:RPC_URL).Trim()
    if ($CODE.Length -le 2) {
        Spin "deploying harness" "cast" @('send', $FACTORY, 'deployHarness(bytes32)', $USERSALT, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--gas-limit', '3500000')
        Ok "harness deployed"
    } else {
        Ok "already on-chain - skipping"
    }

    for ($i = 0; $i -lt 10; $i++) {
        $CODE = (& cast code $env:HARNESS --rpc-url $env:RPC_URL 2>$null).Trim()
        if ($CODE.Length -gt 2) { break }
    }
    if ($CODE.Length -le 2) { Fail "harness has no code after deploy" }

    # verify, simulate (no spend), then fund + arm
    Step "Fund and arm"
    Spin "simulate configureFundAndStart (no spend)" `
        "cast" @('call', $env:HARNESS, $CONFIG_CALLDATA, '--from', $env:WALLET_ADDRESS, '--value', $env:DEPOSIT_WEI, '--rpc-url', $env:RPC_URL) 3
    Spin "fund and arm (configureFundAndStart)" `
        "cast" @('send', $env:HARNESS, $CONFIG_CALLDATA, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--value', $env:DEPOSIT_WEI, '--gas-limit', $SCHED_GAS)
    Ok "funded and armed"

    Write-Host ""; Hr
    Write-Host "  ${BOLD}${OKC}Congratulations - your sovereign agent is live!$RESET`n"
    Write-Host "  ${MUTED}Your sovereign agent contract address:$RESET"
    Write-Host "  ${BOLD}${ACCENT}$env:HARNESS$RESET`n"
    Kv "configured" "$(Invoke-Rpc @('call', $env:HARNESS, 'configured()(bool)', '--rpc-url', $env:RPC_URL))"
    Kv "wakeMode"   "$(Num (Invoke-Rpc @('call', $env:HARNESS, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL)))  (1 armed)"
    Hr
}

switch ($CMD) {
    'deploy'  { Invoke-Deploy }
    'status'  { Invoke-Status $ARG1 }
    'view'    { Invoke-Status $ARG1 }
    'topup'   { Invoke-Topup $ARG1 $ARG2 }
    'fund'    { Invoke-Topup $ARG1 $ARG2 }
    'restart' { Invoke-Restart $ARG1 }
    'revive'  { Invoke-Restart $ARG1 }
    'stop'    { Invoke-Stop $ARG1 }
    default   { Show-Usage; Fail "unknown command: $CMD" }
}
