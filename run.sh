#!/usr/bin/env bash
# run.sh - manage a recurring sovereign agent on Ritual testnet (chain 1979).
# Commands: deploy (default), status, topup, restart, stop. Keyless Ritual LLM, signs from an
# encrypted keystore (set up on first run), and auto-installs foundry + uv if missing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

### ---------- look and feel ----------
# Color only when stdout is a real terminal and the user has not opted out via NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ESC=$'\033'
  RESET="${ESC}[0m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; CLR="${ESC}[K"
  ACCENT="${ESC}[38;5;141m"; OKC="${ESC}[38;5;78m"; BADC="${ESC}[38;5;203m"
  WARNC="${ESC}[38;5;214m"; MUTED="${ESC}[38;5;244m"; HIDE="${ESC}[?25l"; SHOW="${ESC}[?25h"
  USE_COLOR=1
else
  ESC=; RESET=; BOLD=; DIM=; CLR=; ACCENT=; OKC=; BADC=; WARNC=; MUTED=; HIDE=; SHOW=; USE_COLOR=0
fi

LOGFILE="$(mktemp)"
cleanup() { printf '%s' "$SHOW"; rm -f "$LOGFILE" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Paint a short ASCII string letter by letter through a purple-to-pink ramp.
gradient() {
  if [ "$USE_COLOR" != 1 ]; then printf '%s' "$1"; return; fi
  local text="$1" ramp=(99 105 141 147 183 219 213) i=0
  while [ "$i" -lt "${#text}" ]; do
    printf '%s[1;38;5;%sm%s' "$ESC" "${ramp[i % ${#ramp[@]}]}" "${text:i:1}"
    i=$((i + 1))
  done
  printf '%s' "$RESET"
}

BANNER_SHOWN=0
hr()     { printf '  %s--------------------------------------------%s\n' "$MUTED" "$RESET"; }
banner() {
  [ "$BANNER_SHOWN" = 1 ] && return 0; BANNER_SHOWN=1
  printf '\n  '; gradient "RITUAL SOVEREIGN AGENT"; printf '\n'
  printf '  %srecurring keyless agent - Ritual testnet (1979)%s\n' "$DIM" "$RESET"
  printf '  %sbuilt by Zun  %shttps://x.com/Zun2025%s\n' "$MUTED" "$ACCENT" "$RESET"; hr
}
step() { printf '\n  %s>%s %s%s%s\n' "$ACCENT" "$RESET" "$BOLD" "$1" "$RESET"; }
info() { printf '    %s%s%s\n' "$MUTED" "$1" "$RESET"; }
ok()   { printf '  %sok%s %s\n' "$OKC" "$RESET" "$1"; }
warn() { printf '  %s!%s  %s\n' "$WARNC" "$RESET" "$1"; }
kv()   { printf '  %s%-11s%s %s\n' "$MUTED" "$1" "$RESET" "$2"; }

# Run a command behind a braille spinner; output is captured and shown only on failure. An
# optional leading integer retries the command that many times (for flaky network steps).
SPIN_FRAMES=($'⠋' $'⠙' $'⠹' $'⠸' $'⠼' $'⠴' $'⠦' $'⠧' $'⠇' $'⠏')
spin() {
  local tries=1
  case "$1" in '' | *[!0-9]*) ;; *) tries="$1"; shift ;; esac
  local msg="$1"; shift
  local attempt rc=1 pid i
  for attempt in $(seq 1 "$tries"); do
    if [ "$USE_COLOR" != 1 ]; then
      printf '  %s ... ' "$msg"
      if "$@" >"$LOGFILE" 2>&1; then echo "ok"; return 0; else rc=$?; fi
    else
      "$@" >"$LOGFILE" 2>&1 &
      pid=$!; i=0; printf '%s' "$HIDE"
      while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$ACCENT" "${SPIN_FRAMES[i % ${#SPIN_FRAMES[@]}]}" "$RESET" "$msg"
        i=$((i + 1)); sleep 0.08
      done
      if wait "$pid"; then rc=0; else rc=$?; fi
      printf '%s' "$SHOW"
      if [ "$rc" -eq 0 ]; then printf '\r  %sok%s %s%s\n' "$OKC" "$RESET" "$msg" "$CLR"; return 0; fi
    fi
    [ "$attempt" -lt "$tries" ] && { printf '\r  %s~%s %s (retry %s/%s)%s\n' "$WARNC" "$RESET" "$msg" "$((attempt + 1))" "$tries" "$CLR"; sleep 1; }
  done
  [ "$USE_COLOR" = 1 ] && printf '\r  %sx%s %s%s\n' "$BADC" "$RESET" "$msg" "$CLR" || echo "failed"
  sed 's/^/      /' "$LOGFILE"
  return "$rc"
}

usage() {
  banner
  cat <<EOF
  ${BOLD}Usage${RESET}  bash run.sh [command] [args]

  ${ACCENT}deploy${RESET}                    deploy + fund + arm (asks before making a 2nd agent)
  ${ACCENT}status${RESET} [address]          list your agents, or detail one by address
  ${ACCENT}topup${RESET} [address] [wei]     deposit more RITUAL (re-arms if stopped)
  ${ACCENT}restart${RESET} [address]         re-arm an agent
  ${ACCENT}stop${RESET} [address]            stop an agent
  ${ACCENT}help${RESET}                      show this help

  No address -> the agent for SALT in .env. Lock duration: LOCK_BLOCKS (default 100000).
EOF
}

### ---------- config + helpers ----------
CMD="${1:-deploy}"; shift || true
CMD="${CMD#--}"
case "$CMD" in help|-h|"") usage; exit 0 ;; esac

fail() { printf '\n  %sERROR%s %s\n' "$BADC" "$RESET" "$1" >&2; exit 1; }

[ -f "$HERE/.env" ] || fail ".env not found. Run: cp .env.example .env  then edit it."
# Parse .env instead of sourcing it: keep values with spaces (PROMPT) literal, strip CRLF and
# surrounding quotes, skip blanks/comments. Sourcing would run "Say hello world" as a command.
while IFS='=' read -r key val || [ -n "$key" ]; do
  key="${key%$'\r'}"; val="${val%$'\r'}"
  case "$key" in ''|\#*|*[!A-Za-z0-9_]*) continue ;; esac
  case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
  export "$key=$val"
done < "$HERE/.env"

# Ritual testnet system contracts
FACTORY="0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304"
RITUAL_WALLET="0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948"
export REGISTRY="0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F"
LOCK_BLOCKS="${LOCK_BLOCKS:-100000}"

need_deposit() { [ -n "${DEPOSIT_WEI:-}" ] || fail "DEPOSIT_WEI is required"; }
num() { printf '%s' "${1%% *}"; }  # strip cast's trailing "[1.5e16]" label

# Run a read-only cast call, retrying on an empty result (the public RPC can be flaky). Always
# exits 0 with the value or "", so callers never abort under set -e on a transient error.
rpc_read() {
  local i out=""
  for i in 1 2 3; do
    out="$("$@" 2>/dev/null)" && [ -n "$out" ] && break
    sleep 1
  done
  printf '%s' "$out"
}
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
predict_harness() { rpc_read cast call "$FACTORY" "predictHarness(address,bytes32)(address,bytes32)" "$WALLET_ADDRESS" "$1" --rpc-url "$RPC_URL" | head -1; }
deployed() { local c; c="$(rpc_read cast code "$HARNESS" --rpc-url "$RPC_URL")"; [ "${#c}" -gt 2 ]; }

### ---------- keystore signer ----------
KEYSTORE_DIR="$HOME/.foundry/keystores"
KS_PASSWORD=""

# Read a secret showing one '*' per char (backspace supported) into REPLY_SECRET.
read_masked() {
  local ch p=""; printf '%s' "$1" >&2
  while IFS= read -rsn1 ch < /dev/tty; do
    [ -z "$ch" ] && break
    if [ "$ch" = $'\177' ] || [ "$ch" = $'\b' ]; then
      [ -n "$p" ] && { p="${p%?}"; printf '\b \b' >&2; }
    else p="$p$ch"; printf '*' >&2; fi
  done
  printf '\n' >&2; REPLY_SECRET="$p"
}

# Set or replace KEY=VALUE in .env so the name and address persist across runs.
set_env_var() {
  local k="$1" v="$2" f="$HERE/.env" tmp
  if grep -q "^$k=" "$f" 2>/dev/null; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$k="*) printf '%s=%s\n' "$k" "$v" ;; *) printf '%s\n' "${line%$'\r'}" ;; esac
    done < "$f" > "$tmp"
    mv "$tmp" "$f"
  else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}

# First run: ask name + key + password, create the encrypted keystore, save name + address.
import_keystore() {
  banner
  step "Set up your wallet keystore"
  local name="${KEYSTORE_ACCOUNT:-}" key p1 p2 i
  if [ -z "$name" ]; then
    printf '  %sname for your keystore [ritual-deployer]:%s ' "$ACCENT" "$RESET" >&2
    IFS= read -r name < /dev/tty || name=""; [ -z "$name" ] && name="ritual-deployer"
  fi
  if [ -f "$KEYSTORE_DIR/$name" ]; then          # name already exists -> adopt it, don't re-import
    KEYSTORE_ACCOUNT="$name"; set_env_var KEYSTORE_ACCOUNT "$name"
    unlock
    WALLET_ADDRESS="$(cast wallet address --account "$name" --password "$KS_PASSWORD" 2>/dev/null)" || fail "wrong keystore password"
    set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
    ok "using existing keystore '$name' for $WALLET_ADDRESS"; return
  fi
  read_masked "  paste your wallet private key: "; key="$REPLY_SECRET"
  [ -n "$key" ] || fail "no private key entered"
  case "$key" in 0x*) ;; *) key="0x$key" ;; esac
  for i in 1 2 3; do
    read_masked "  set a keystore password: "; p1="$REPLY_SECRET"
    read_masked "  confirm password: ";        p2="$REPLY_SECRET"
    [ -n "$p1" ] && [ "$p1" = "$p2" ] && break
    { [ -z "$p1" ] && warn "empty password ($i/3)"; } || warn "passwords do not match ($i/3)"
    p1=""
  done
  [ -n "$p1" ] || fail "could not set a password after 3 tries"
  spin "creating encrypted keystore" cast wallet import "$name" --private-key "$key" --unsafe-password "$p1"
  WALLET_ADDRESS="$(cast wallet address --private-key "$key" 2>/dev/null)" || fail "invalid private key"
  key=""; KEYSTORE_ACCOUNT="$name"; KS_PASSWORD="$p1"
  set_env_var KEYSTORE_ACCOUNT "$name"
  set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
  ok "keystore '$name' ready for $WALLET_ADDRESS"
}

# Ensure a keystore + public address exist (import on first run). Reads never need the password.
resolve_signer() {
  local name="${KEYSTORE_ACCOUNT:-}"
  if [ -z "$name" ] || [ ! -f "$KEYSTORE_DIR/$name" ]; then import_keystore; return; fi
  KEYSTORE_ACCOUNT="$name"
  if [ -z "${WALLET_ADDRESS:-}" ]; then
    unlock
    WALLET_ADDRESS="$(cast wallet address --account "$name" --password "$KS_PASSWORD" 2>/dev/null)" || fail "wrong keystore password"
    set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
  fi
}

# Ask the keystore password once per run (masked), retrying up to 3 times if it is wrong.
unlock() {
  [ -n "$KS_PASSWORD" ] && return 0
  local i pw
  for i in 1 2 3; do
    read_masked "  keystore password: "; pw="$REPLY_SECRET"
    if cast wallet address --account "$KEYSTORE_ACCOUNT" --password "$pw" >/dev/null 2>&1; then
      KS_PASSWORD="$pw"; return 0
    fi
    warn "wrong password ($i/3)"
  done
  fail "wrong keystore password after 3 tries"
}

# Next salt for a fresh agent: bump a trailing number, else append -2 (agent-1 -> agent-2).
next_salt() {
  local s="$1"
  if [[ "$s" =~ ^(.*[^0-9])([0-9]+)$ ]]; then printf '%s%s' "${BASH_REMATCH[1]}" "$(( BASH_REMATCH[2] + 1 ))"
  elif [[ "$s" =~ ^([0-9]+)$ ]]; then printf '%s' "$(( s + 1 ))"
  else printf '%s-2' "$s"; fi
}

# Fixed gas for configure/restart. Ritual's estimateGas lies here (~192M for a call that really
# uses ~2.1M), so we ignore it - a real deploy went through on 3.5M. 5M leaves room and stays
# well under the 200M block limit. The cast call below still catches a genuinely bad request.
SCHED_GAS=5000000

### ---------- prerequisites (auto-install, no prompts) ----------
# Foundry lands in ~/.foundry/bin, uv in ~/.local/bin. Put both on PATH for this run...
ensure_path_now() {
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac
  case ":$PATH:" in *":$HOME/.foundry/bin:"*) ;; *) PATH="$HOME/.foundry/bin:$PATH";; esac
  export PATH
}
# ...and once in ~/.bashrc so future shells see it too (idempotent, marker-guarded).
persist_path() {
  local dir="$1" rc="$HOME/.bashrc"
  [ -f "$rc" ] || : >"$rc"
  grep -qF "ritual-path:$dir" "$rc" 2>/dev/null && return 0
  printf '\n# ritual-path:%s\nexport PATH="%s:$PATH"\n' "$dir" "$dir" >>"$rc"
}

# Make sure curl is available (the foundry + uv installers need it). Auto-install via the system
# package manager when missing; Git Bash and macOS already ship it.
ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  step "Installing curl"
  info "this may ask for your sudo password"
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y curl
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y curl
  elif command -v yum     >/dev/null 2>&1; then sudo yum install -y curl
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm curl
  elif command -v zypper  >/dev/null 2>&1; then sudo zypper --non-interactive install curl
  elif command -v apk     >/dev/null 2>&1; then sudo apk add curl
  elif command -v brew    >/dev/null 2>&1; then brew install curl
  else fail "curl is missing and no known package manager was found - install curl, then re-run"
  fi || true
  command -v curl >/dev/null 2>&1 || fail "could not install curl automatically - install it manually, then re-run"
}

install_foundry() {
  step "Installing Foundry (cast, forge)"
  ensure_curl
  spin 3 "fetch foundryup"      bash -c 'curl -fsSL https://foundry.paradigm.xyz | bash'
  ensure_path_now
  spin 3 "install cast + forge" "$HOME/.foundry/bin/foundryup"
  persist_path "$HOME/.foundry/bin"
}

install_uv() {
  step "Installing uv"
  ensure_curl
  spin 3 "fetch + install uv" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  ensure_path_now
  persist_path "$HOME/.local/bin"
}

ensure_tools() {
  ensure_path_now
  { command -v cast >/dev/null 2>&1 && command -v forge >/dev/null 2>&1; } || install_foundry
  command -v uv >/dev/null 2>&1 || install_uv
  ensure_path_now
  local miss=
  for bin in cast forge uv; do command -v "$bin" >/dev/null 2>&1 || miss="$miss $bin"; done
  [ -z "$miss" ] || fail "still missing after install:$miss - open a new shell and retry"
}

# install tools, then ensure a keystore + public address exist (imports your wallet on first run)
ensure_tools
resolve_signer

# deterministic harness address (also the delivery target) - needed by every command
USERSALT="$(cast keccak "${SALT:-ritual-agent-1}")"
HARNESS="$(predict_harness "$USERSALT")"
export HARNESS

# Live = a contract is deployed at this harness AND it has already been configured (armed/stopped).
is_live() {
  local h="$1" c
  c="$(rpc_read cast code "$h" --rpc-url "$RPC_URL")"
  [ "${#c}" -le 2 ] && return 1
  [ "$(rpc_read cast call "$h" 'configured()(bool)' --rpc-url "$RPC_URL")" = "true" ]
}

# Print one agent row: salt, address, state, balance.
print_agent() {
  local salt="$1" h="$2" cf wake bal state
  cf="$(rpc_read cast call "$h" 'configured()(bool)' --rpc-url "$RPC_URL")"
  wake="$(num "$(rpc_read cast call "$h" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")"
  bal="$(num "$(rpc_read cast call "$RITUAL_WALLET" 'balanceOf(address)(uint256)' "$h" --rpc-url "$RPC_URL")")"
  bal="$(cast to-unit "${bal:-0}" ether)"
  if [ "$cf" != "true" ]; then state="${WARNC}unconfigured${RESET}"
  elif [ "$wake" = "1" ]; then state="${OKC}armed${RESET}"
  else state="${MUTED}stopped${RESET}"; fi
  printf '  %s%-18s%s %s  %b  %s RITUAL\n' "$BOLD" "$salt" "$RESET" "$h" "$state" "$bal"
}

# Detailed view of a single agent by address (used when an address is passed to status).
print_agent_detail() {
  local h="$1" c bal lock
  c="$(rpc_read cast code "$h" --rpc-url "$RPC_URL")"
  [ "${#c}" -gt 2 ] || { warn "no contract at $h (not deployed)"; return; }
  bal="$(num "$(rpc_read cast call "$RITUAL_WALLET" 'balanceOf(address)(uint256)' "$h" --rpc-url "$RPC_URL")")"
  lock="$(num "$(rpc_read cast call "$RITUAL_WALLET" 'lockUntil(address)(uint256)' "$h" --rpc-url "$RPC_URL")")"
  hr
  kv "agent" "$h"
  kv "configured" "$(rpc_read cast call "$h" 'configured()(bool)' --rpc-url "$RPC_URL")"
  kv "wakeMode" "$(num "$(rpc_read cast call "$h" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")  (1 armed / 0 stopped)"
  kv "balance" "$(cast to-unit "${bal:-0}" ether) RITUAL"
  kv "lockUntil" "block ${lock:-?}  (now $(rpc_read cast block-number --rpc-url "$RPC_URL"))"
}

# status            -> list every agent you deployed (salt series agent-1, agent-2, ...).
# status <address>  -> detailed view of one agent (paste any harness address).
cmd_status() {
  local arg="${1:-}"
  banner
  kv "Owner" "$WALLET_ADDRESS"
  kv "Chain" "$(cast chain-id --rpc-url "$RPC_URL")"
  if is_addr "$arg"; then step "Agent"; print_agent_detail "$arg"; return; fi
  step "Your agents"
  local salt="${SALT:-ritual-agent-1}" miss=0 found=0 us h code
  while [ "$miss" -lt 2 ] && [ "$found" -lt 100 ]; do
    us="$(cast keccak "$salt")"
    h="$(predict_harness "$us")"
    code="$(rpc_read cast code "$h" --rpc-url "$RPC_URL")"
    if [ "${#code}" -le 2 ]; then miss=$((miss + 1)); salt="$(next_salt "$salt")"; continue; fi
    miss=0; found=$((found + 1))
    print_agent "$salt" "$h"
    salt="$(next_salt "$salt")"
  done
  if [ "$found" -eq 0 ]; then info "no agents yet - run: bash run.sh deploy"
  else hr; info "$found agent(s). Manage one: bash run.sh restart|stop|topup <agent-address>"; fi
}

# Read wakeMode and report it with the correct label (1+ = armed, 0 = stopped).
report_wake() {
  local wm; wm="$(num "$(rpc_read cast call "$HARNESS" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")"
  { [ "$wm" = "0" ] && ok "wakeMode 0 (stopped)"; } || ok "wakeMode ${wm:-?} (armed)"
}

cmd_restart() {
  if is_addr "${1:-}"; then HARNESS="$1"; fi
  deployed || fail "harness not deployed yet - run: bash run.sh deploy"
  banner
  step "Re-arm agent"
  kv "agent" "$HARNESS"
  cast call "$HARNESS" "restart()" --from "$WALLET_ADDRESS" --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    || fail "restart() reverts on-chain - the agent is already armed, or its schedule has ended"
  unlock
  spin "broadcasting restart()" \
    cast send "$HARNESS" "restart()" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --gas-limit "$SCHED_GAS"
  report_wake
}

cmd_stop() {
  if is_addr "${1:-}"; then HARNESS="$1"; fi
  deployed || fail "harness not deployed"
  banner
  step "Stop agent"
  kv "agent" "$HARNESS"
  cast call "$HARNESS" "stop()" --from "$WALLET_ADDRESS" --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    || fail "stop() reverts on-chain - the agent is not in a stoppable state (its schedule may have already ended)"
  unlock
  spin "broadcasting stop()" \
    cast send "$HARNESS" "stop()" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --gas-limit 3500000
  report_wake
}

cmd_topup() {
  need_deposit
  local amount
  if is_addr "${1:-}"; then HARNESS="$1"; amount="${2:-$DEPOSIT_WEI}"; else amount="${1:-$DEPOSIT_WEI}"; fi
  deployed || fail "harness not deployed yet - run: bash run.sh deploy"
  banner
  step "Deposit $(cast to-unit "$amount" ether) RITUAL"
  kv "agent" "$HARNESS"
  info "lock $LOCK_BLOCKS blocks"
  unlock
  spin "depositing" \
    cast send "$RITUAL_WALLET" "depositFor(address,uint256)" "$HARNESS" "$LOCK_BLOCKS" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --value "$amount"
  if [ "$(num "$(rpc_read cast call "$HARNESS" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")" = "0" ]; then
    warn "agent was stopped; re-arming"
    cmd_restart
  else
    ok "topped up. balance $(cast to-unit "$(num "$(rpc_read cast call "$RITUAL_WALLET" 'balanceOf(address)(uint256)' "$HARNESS" --rpc-url "$RPC_URL")")" ether) RITUAL (still armed)"
  fi
}

cmd_deploy() {
  need_deposit
  banner
  kv "Owner" "$WALLET_ADDRESS"
  kv "Chain" "$(cast chain-id --rpc-url "$RPC_URL")"
  kv "Balance" "$(cast balance "$WALLET_ADDRESS" --ether --rpc-url "$RPC_URL") RITUAL"

  # Resolve the agent for the configured SALT. If it is already live, ask before making another;
  # on yes, advance to the first free salt (agent-1 -> agent-2 -> ...).
  step "Select agent"
  local salt="${SALT:-ritual-agent-1}" reply n=0
  USERSALT="$(cast keccak "$salt")"
  HARNESS="$(predict_harness "$USERSALT")"
  if is_live "$HARNESS"; then
    warn "you already have an agent live:"
    kv "  salt" "$salt"
    kv "  agent" "$HARNESS"
    printf '\n  %sDeploy another (new) agent? [y/N]%s ' "$ACCENT" "$RESET"
    read -r reply < /dev/tty 2>/dev/null || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) printf '\n'; info "left it running - inspect with: bash run.sh status"; exit 0 ;;
    esac
    while is_live "$HARNESS"; do
      salt="$(next_salt "$salt")"
      USERSALT="$(cast keccak "$salt")"
      HARNESS="$(predict_harness "$USERSALT")"
      n=$((n + 1)); [ "$n" -gt 200 ] && fail "200+ live agents - set a fresh SALT in .env"
    done
    ok "new slot: $salt"
  fi
  export HARNESS
  kv "Salt" "$salt"
  kv "Deposit" "$(cast to-unit "$DEPOSIT_WEI" ether) RITUAL"
  kv "Harness" "$HARNESS"
  unlock

  # build the encrypted, ABI-encoded configureFundAndStart payload
  step "Build request"
  local PYTMP; PYTMP="$(mktemp)"
  cat >"$PYTMP" <<'PY'
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
PY
  spin 3 "discover executor, encrypt secret, encode calldata" \
    uv run --quiet --with eciespy --with eth-abi --with web3 python3 "$PYTMP"
  rm -f "$PYTMP"
  local OUT EXECUTOR CONFIG_CALLDATA
  OUT="$(cat "$LOGFILE")"
  EXECUTOR="$(printf '%s\n' "$OUT" | awk -F= '$1=="EXECUTOR"{print $2}')"
  CONFIG_CALLDATA="$(printf '%s\n' "$OUT" | awk -F= '$1=="CONFIG_CALLDATA"{print $2}')"
  [ -n "$CONFIG_CALLDATA" ] || { printf '%s\n' "$OUT"; fail "failed to build request"; }
  ok "executor $EXECUTOR"

  # deploy the harness if it is not on-chain yet (CREATE3 needs ~2.5M gas)
  step "Deploy harness"
  local CODE; CODE="$(rpc_read cast code "$HARNESS" --rpc-url "$RPC_URL")"
  if [ "${#CODE}" -le 2 ]; then
    spin "deploying harness" \
      cast send "$FACTORY" "deployHarness(bytes32)" "$USERSALT" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --gas-limit 3500000
    ok "harness deployed"
  else
    ok "already on-chain - skipping"
  fi

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(cast code "$HARNESS" --rpc-url "$RPC_URL" 2>/dev/null || true)"
    [ "${#CODE}" -gt 2 ] && break
  done
  [ "${#CODE}" -gt 2 ] || fail "harness has no code after deploy"

  # verify, simulate (no spend), then fund + arm
  step "Fund and arm"
  spin 3 "simulate configureFundAndStart (no spend)" \
    cast call "$HARNESS" "$CONFIG_CALLDATA" --from "$WALLET_ADDRESS" --value "$DEPOSIT_WEI" --rpc-url "$RPC_URL"
  spin "fund and arm (configureFundAndStart)" \
    cast send "$HARNESS" "$CONFIG_CALLDATA" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --value "$DEPOSIT_WEI" --gas-limit "$SCHED_GAS"
  ok "funded and armed"

  printf '\n'; hr
  printf '  %sCongratulations - your sovereign agent is live!%s\n\n' "${BOLD}${OKC}" "$RESET"
  printf '  %sYour sovereign agent contract address:%s\n' "$MUTED" "$RESET"
  printf '  %s%s%s\n\n' "${BOLD}${ACCENT}" "$HARNESS" "$RESET"
  kv "configured" "$(rpc_read cast call "$HARNESS" 'configured()(bool)' --rpc-url "$RPC_URL")"
  kv "wakeMode" "$(num "$(rpc_read cast call "$HARNESS" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")  (1 armed)"
  hr
}

case "$CMD" in
  deploy)         cmd_deploy ;;
  status|view)    cmd_status "${1:-}" ;;
  topup|fund)     cmd_topup "${1:-}" "${2:-}" ;;
  restart|revive) cmd_restart "${1:-}" ;;
  stop)           cmd_stop "${1:-}" ;;
  *)              usage; fail "unknown command: $CMD" ;;
esac
