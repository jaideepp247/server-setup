#!/usr/bin/env bash
#
# One-command app setup for a fresh Ubuntu server.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/jaideepp247/server-setup/main/setup.sh)
#
# Installs Node 24, npm, yarn and pm2, deploys a GitHub repo, checks that it
# works, and optionally adds a CI/CD pipeline and a domain with HTTPS (Caddy).
# Safe to run again on the same server.
#
# Security notes for maintainers:
#  - The GitHub token lives only in the unexported shell variable TOKEN. It must
#    never be exported: pm2 saves its environment to disk, so an exported token
#    would end up in ~/.pm2/dump.pm2. Pass it per command with GH_TOKEN="$TOKEN".
#  - Secrets are never written to the log file.
#
# Everything is inside main() so a half-downloaded script cannot run partially.

set -Eeuo pipefail

NODE_MAJOR=24
TOTAL_STEPS=8
WORKFLOW_PATH=".github/workflows/staging.yml"

LOG="$HOME/server-setup.log"
TMP=""
TOKEN=""
OWNER_REPO=""
APP=""
APP_DIR=""
BRANCH=""
INSTALL_CMD=""
BUILD_CMD=""
START_CMD=""
PORT=""
PUBLIC_IP=""
DOMAIN=""
PIPELINE_DONE=0
DOMAIN_LIVE=0
CRASHED=0
BASE_PORTS=""
SUDO=""
STTY_SAVED=""

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

# ── Output helpers ───────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '  %s✘ %s%s\n' "$RED" "$*" "$RESET"; }
step() { printf '\n%s━━ Step %s of %s: %s%s\n' "$BOLD$BLUE" "$1" "$TOTAL_STEPS" "$2" "$RESET"; }
die()  {
  printf '\n'; err "$1"
  [ $# -gt 1 ] && say "    $2"
  say "    Full log: $LOG"
  say "    You can safely run the setup command again after fixing this."
  exit 1
}

# ── Input helpers (always read from the keyboard, never from a pipe) ─────────
ask() {  # ask VAR "Question" [default]
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  if [ -n "$__def" ]; then
    printf '  %s [%s]: ' "$__q" "$__def" >/dev/tty
  else
    printf '  %s: ' "$__q" >/dev/tty
  fi
  IFS= read -r __ans </dev/tty || true
  __ans=${__ans//$'\r'/}
  __ans="$(printf '%s' "$__ans" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_secret() {  # ask_secret VAR "Question"  (typing is hidden)
  local __var=$1 __q=$2 __ans=""
  printf '  %s (hidden while you paste): ' "$__q" >/dev/tty
  IFS= read -rs __ans </dev/tty || true
  printf '\n' >/dev/tty
  __ans="$(printf '%s' "$__ans" | tr -d '[:space:]')"
  printf -v "$__var" '%s' "$__ans"
}

ask_yes() {  # ask_yes "Question" y|n   -> returns 0 for yes
  local __q=$1 __def=${2:-y} __ans="" __hint="Y/n"
  [ "$__def" = "n" ] && __hint="y/N"
  while true; do
    printf '  %s [%s]: ' "$__q" "$__hint" >/dev/tty
    IFS= read -r __ans </dev/tty || true
    __ans="$(printf '%s' "${__ans:-$__def}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$__ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     say "  Please type y or n." ;;
    esac
  done
}

read_blob() {  # read_blob /path/to/file : pasted text until a line that says END
  local __out=$1 __line
  : >"$__out"
  # Normal terminal mode cuts lines at 4095 characters, which would silently
  # corrupt long values, so line mode is switched off while pasting.
  STTY_SAVED="$(stty -g </dev/tty)"
  stty -icanon min 1 time 0 </dev/tty
  while IFS= read -r __line </dev/tty; do
    __line=${__line%$'\r'}
    [ "$(printf '%s' "$__line" | tr -d '[:space:]')" = "END" ] && break
    printf '%s\n' "$__line" >>"$__out"
  done
  stty "$STTY_SAVED" </dev/tty
  STTY_SAVED=""
}

# ── Run a slow command quietly with a timer; output goes to the log ──────────
run() {  # run "Description" command...
  local desc=$1; shift
  local start=$SECONDS pid rc=0
  printf '\n===== %s =====\n' "$desc" >>"$LOG"
  "$@" >>"$LOG" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ -t 1 ] && printf '\r  … %s (%ss)   ' "$desc" "$((SECONDS - start))"
    sleep 1
  done
  wait "$pid" || rc=$?
  [ -t 1 ] && printf '\r\033[K'
  if [ "$rc" -eq 0 ]; then ok "$desc"; else err "$desc failed"; fi
  return "$rc"
}

log_tail() { tail -n "${1:-25}" "$LOG" | sed 's/^/    /'; }

explain_error() {  # plain-English hints for common failures in the given text
  local text=$1
  say ""
  say "  ${BOLD}What this probably means:${RESET}"
  local hit=0
  hint() { say "   • $1"; hit=1; }
  grep -qiE 'EADDRINUSE|address already in use' <<<"$text" && hint "Another program is already using the app's port."
  grep -qiE "Cannot find module|MODULE_NOT_FOUND" <<<"$text" && hint "A file or package is missing. The build may have failed, or a package is not listed in package.json."
  grep -qiE 'ECONNREFUSED|ENOTFOUND|ETIMEDOUT|getaddrinfo|connection refused' <<<"$text" && hint "The app cannot reach a database or another service. Check those addresses in your env values, and that the service allows this server."
  grep -qiE 'password authentication failed|access denied|authentication failed|bad auth' <<<"$text" && hint "A username or password in your env values looks wrong."
  grep -qiE 'env|environment variable|config validation|is required|undefined|must be defined' <<<"$text" && hint "An env value may be missing or wrong. Compare what you pasted with what the app needs."
  grep -qiE 'heap out of memory|ENOMEM|Killed' <<<"$text" && hint "The server ran out of memory. Use a bigger instance, such as t3.medium or t4g.medium."
  grep -qiE 'ENOSPC|no space left' <<<"$text" && hint "The server's disk is full. Increase the disk size in your cloud console."
  grep -qiE 'incompatible with this module|engine .* is incompatible|Unsupported engine' <<<"$text" && hint "This project needs a different Node version than $NODE_MAJOR. Ask a developer."
  grep -qiE 'EACCES|permission denied' <<<"$text" && hint "The app is trying to use something it has no permission for. Ports below 1024 need a different PORT value."
  [ "$hit" -eq 1 ] || say "   • Not a common error. Please send the lines above to a developer."
  say ""
}

cleanup() {
  [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" </dev/tty 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP"
  TOKEN=""
}

on_error() {
  local rc=$? line=$1
  trap - ERR
  printf '\n'
  err "Something unexpected went wrong (line $line)."
  say "    Last lines of the log:"
  log_tail 15
  say "    Full log: $LOG"
  say "    You can safely run the setup command again."
  exit "$rc"
}

# ── Step 1: system preparation ───────────────────────────────────────────────
apt_get() {
  # Lock timeout: fresh servers run automatic updates at boot, which hold the apt lock.
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
    -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

preflight() {
  [ -r /dev/tty ] && : </dev/tty || die "This script needs a real terminal." "Connect to the server over SSH and run the command there."
  grep -qiE '^ID(_LIKE)?=.*(ubuntu|debian)' /etc/os-release 2>/dev/null \
    || die "This server is not Ubuntu." "Create the instance again and choose Ubuntu as the operating system."
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
    command -v sudo >/dev/null 2>&1 || die "'sudo' is not available on this server."
    sudo -n true 2>/dev/null || { say "  Your server password is needed for setup."; sudo -v </dev/tty; }
  fi
  TMP="$(mktemp -d)"
  chmod 700 "$TMP"
  : >"$LOG"
  chmod 600 "$LOG"
}

add_swap() {
  $SUDO fallocate -l 2G /swapfile
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile
  $SUDO swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab
}

install_node() {
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$TMP/nodesource.sh"
  $SUDO env DEBIAN_FRONTEND=noninteractive bash "$TMP/nodesource.sh"
  apt_get install nodejs
}

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

step_install() {
  step 1 "Installing Node $NODE_MAJOR, npm, yarn and pm2"
  say "  This takes a few minutes on a new server."
  run "Updating package lists" apt_get update || die "Could not update packages." "Check that the server has internet access."
  run "Installing basic tools" apt_get install git curl ca-certificates gnupg iproute2 procps build-essential python3 \
    || die "Could not install basic tools."

  local mem_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [ "$mem_mb" -lt 4000 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ] && [ ! -e /swapfile ]; then
    run "Adding 2 GB swap so builds don't run out of memory" add_swap || warn "Could not add swap. Continuing without it."
  fi

  if [ "$(node_major)" = "$NODE_MAJOR" ]; then
    ok "Node $(node -v) is already installed"
  else
    run "Installing Node $NODE_MAJOR" install_node || die "Could not install Node $NODE_MAJOR."
  fi
  hash -r
  command -v yarn >/dev/null 2>&1 || run "Installing yarn" $SUDO npm install -g yarn || die "Could not install yarn."
  command -v pm2  >/dev/null 2>&1 || run "Installing pm2"  $SUDO npm install -g pm2  || die "Could not install pm2."
  hash -r
  ok "Node $(node -v), npm $(npm -v), yarn $(yarn -v), pm2 $(pm2 -v 2>/dev/null | tail -n1)"
}

# ── Step 2: clone ────────────────────────────────────────────────────────────
parse_repo() {  # accepts URL, SSH address, or owner/name
  local v=$1
  v=${v#https://}; v=${v#http://}; v=${v#www.}; v=${v#git@}
  v=${v#github.com/}; v=${v#github.com:}
  v=${v%/}; v=${v%.git}
  if [[ "$v" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then printf '%s' "$v"; fi
}

git_auth() {
  # The token reaches git through a helper reading GH_TOKEN, so it never appears
  # in the process list or in .git/config. GH_TOKEN is set per call by callers.
  if [ -n "${GH_TOKEN:-}" ]; then
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
      -c 'credential.helper=!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f' "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

clone_fresh() {
  local url="https://github.com/${OWNER_REPO}.git"
  if [ -n "$BRANCH" ]; then
    GH_TOKEN="$TOKEN" git_auth clone --branch "$BRANCH" "$url" "$APP_DIR"
  else
    GH_TOKEN="$TOKEN" git_auth clone "$url" "$APP_DIR"
  fi
}

update_existing() {
  local b=${BRANCH:-$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)}
  GH_TOKEN="$TOKEN" git_auth -C "$APP_DIR" fetch origin "$b"
  git -C "$APP_DIR" checkout -B "$b" FETCH_HEAD
}

step_clone() {
  step 2 "Getting your code from GitHub"
  say "  Your token is used only while this script runs. It is never saved on the server."
  say ""
  while true; do
    local input=""
    ask input "GitHub repo link (e.g. https://github.com/company/my-app)"
    OWNER_REPO="$(parse_repo "$input")"
    if [ -z "$OWNER_REPO" ]; then
      err "That doesn't look like a GitHub repo link. Please try again."
      continue
    fi
    ask_secret TOKEN "GitHub token (just press Enter if the repo is public)"
    ask BRANCH "Branch to deploy (press Enter for the repo's main branch)"
    if [ -n "$BRANCH" ] && ! [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      err "That branch name has characters that aren't allowed."
      continue
    fi

    APP="${OWNER_REPO#*/}"
    APP_DIR="$HOME/$APP"

    local origin="" rc=0
    if [ -d "$APP_DIR/.git" ]; then
      # Raw config value, compared by owner/name, so URL variations still match
      origin="$(parse_repo "$(git -C "$APP_DIR" config --get remote.origin.url 2>/dev/null || true)")"
    fi
    if [ -n "$origin" ] && [ "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$OWNER_REPO" | tr '[:upper:]' '[:lower:]')" ]; then
      say "  This repo is already on the server, so it will be updated."
      run "Updating code" update_existing || rc=$?
    else
      if [ -e "$APP_DIR" ]; then
        local old
        old="$APP_DIR.old-$(date +%Y%m%d-%H%M%S)"
        mv "$APP_DIR" "$old"
        warn "A different folder was already at $APP_DIR. It was kept as $old"
      fi
      run "Downloading code" clone_fresh || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      BRANCH="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"
      ok "Code is in $APP_DIR (branch: $BRANCH)"
      # Keeps .env safe from 'git clean' in the pipeline, even if the repo doesn't ignore it
      grep -qxF '.env' "$APP_DIR/.git/info/exclude" 2>/dev/null || echo '.env' >>"$APP_DIR/.git/info/exclude"
      return 0
    fi

    local out
    out="$(tail -n 8 "$LOG")"
    if grep -qiE 'Remote branch .* not found|couldn.t find remote ref' <<<"$out"; then
      err "The branch '$BRANCH' doesn't exist in this repo."
    elif grep -qiE 'Authentication failed|could not read Username|not found|403|terminal prompts disabled|does not appear to be a git|repository exists' <<<"$out"; then
      err "GitHub refused access. The link may be wrong, or the token may be wrong, expired, or not allowed to read this repo."
    elif grep -qiE 'Could not resolve host|unable to access' <<<"$out"; then
      err "The server couldn't reach GitHub. Check its internet connection."
    else
      err "Couldn't download the code:"
      log_tail 6
    fi
    say "  Let's try again."
    say ""
  done
}

# ── Step 3: env ──────────────────────────────────────────────────────────────
paste_env() {
  local blob="$TMP/env"
  while true; do
    say ""
    say "  Paste your whole env file now."
    say "  When it's all pasted: press Enter, type ${BOLD}END${RESET}, press Enter."
    say "  (No env file? Just type END and press Enter.)"
    say ""
    read_blob "$blob"
    local names count
    names="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$blob")"
    count="$(printf '%s' "$names" | grep -c . || true)"
    say ""
    if [ "$count" -eq 0 ]; then
      if ask_yes "No settings were found. Continue without an env file?" n; then
        return 0
      fi
      continue
    fi
    say "  Found $count settings:"
    printf '%s\n' "$names" | paste -sd' ' | fold -s -w 70 | sed 's/^/    /'
    say ""
    if ask_yes "Does this look right?" y; then
      ( umask 077; cp "$blob" "$APP_DIR/.env" )
      chmod 600 "$APP_DIR/.env"
      ok "Saved to $APP_DIR/.env"
      return 0
    fi
  done
}

step_env() {
  step 3 "Adding your env settings"
  if [ -s "$APP_DIR/.env" ] && ask_yes "This app already has an env file on the server. Keep it?" y; then
    ok "Keeping the existing env file"
    return 0
  fi
  paste_env
}

# ── Step 4: detect and build ─────────────────────────────────────────────────
detect_commands() {
  [ -f "$APP_DIR/package.json" ] || die "No package.json was found in this repo." "This script only works for Node.js apps with package.json in the main folder."
  local detected
  detected="$(cd "$APP_DIR" && node -e '
    const fs = require("fs");
    let p;
    try { p = JSON.parse(fs.readFileSync("package.json", "utf8")); }
    catch (e) { console.log("BADJSON"); process.exit(0); }
    const s = p.scripts || {};
    const pinned = String(p.packageManager || "").split("@")[0];
    const pm = ["yarn", "npm", "pnpm"].includes(pinned) ? pinned
      : fs.existsSync("yarn.lock") ? "yarn"
      : fs.existsSync("pnpm-lock.yaml") ? "pnpm"
      : fs.existsSync("package-lock.json") ? "npm" : "yarn";
    const start = ["start:prod", "start:production", "prod", "start", "serve", "preview"].find(k => s[k]) || "";
    const install = pm === "npm" ? (fs.existsSync("package-lock.json") ? "npm ci" : "npm install")
      : pm === "pnpm" ? "pnpm install" : "yarn";
    const runner = pm === "yarn" ? "yarn" : pm + " run";
    console.log([pm, install, s.build ? (pm === "yarn" ? "yarn run build" : pm + " run build") : "", start ? runner + " " + start : ""].join("\t"));
  ')"
  [ "$detected" = "BADJSON" ] && die "package.json in this repo is not valid." "Ask a developer to fix it."
  local pm
  IFS=$'\t' read -r pm INSTALL_CMD BUILD_CMD START_CMD <<<"$detected"
  if [ "$pm" = "pnpm" ] && ! command -v pnpm >/dev/null 2>&1; then
    run "Installing pnpm" $SUDO npm install -g pnpm || die "Could not install pnpm."
    hash -r
  fi
}

show_commands() {
  say "  These commands will be used:"
  say "    Install:  ${BOLD}$INSTALL_CMD${RESET}"
  say "    Build:    ${BOLD}${BUILD_CMD:-(none needed)}${RESET}"
  say "    Start:    ${BOLD}${START_CMD:-(not found)}${RESET}"
  say ""
}

run_shell_in_app() { ( cd "$APP_DIR" && bash -c "$1" ); }

do_build() {
  [ -n "$BUILD_CMD" ] || return 0
  run "Building the app (often 1-5 minutes)" run_shell_in_app "$BUILD_CMD"
}

step_build() {
  step 4 "Installing and building your app"
  detect_commands
  show_commands
  if [ -z "$START_CMD" ]; then
    warn "No start command was found in package.json."
    while [ -z "$START_CMD" ]; do ask START_CMD "Type the start command (ask a developer, e.g. node dist/main.js)"; done
  elif ! ask_yes "Use these commands?" y; then
    ask INSTALL_CMD "Install command" "$INSTALL_CMD"
    ask BUILD_CMD "Build command (type none to skip)" "${BUILD_CMD:-none}"
    [ "$BUILD_CMD" = "none" ] && BUILD_CMD=""
    ask START_CMD "Start command" "$START_CMD"
  fi

  if ! run "Installing packages (often 1-5 minutes)" run_shell_in_app "$INSTALL_CMD"; then
    log_tail 25; explain_error "$(tail -n 60 "$LOG")"
    die "Installing packages failed."
  fi
  if ! do_build; then
    log_tail 25; explain_error "$(tail -n 60 "$LOG")"
    die "Building the app failed." "A missing env value is a common cause. Run the setup again and paste the env file again."
  fi
}

# ── Step 5: start and find the port ──────────────────────────────────────────
pm2_info() {  # prints: pid status restarts
  pm2 jlist 2>/dev/null | APP_NAME="$APP" node -e '
    let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
      let l = []; try { l = JSON.parse(d.slice(d.indexOf("["))); } catch (e) {}
      const a = l.find(x => x.name === process.env.APP_NAME);
      console.log(a ? [a.pid || 0, a.pm2_env.status, a.pm2_env.restart_time || 0].join(" ") : "0 missing 0");
    });'
}

process_tree() {  # the pid and all its descendants, one per line
  ps -eo pid=,ppid= | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      seen[root] = 1; changed = 1
      while (changed) { changed = 0
        for (p in parent) if (!(p in seen) && (parent[p] in seen)) { seen[p] = 1; changed = 1 } }
      for (p in seen) print p
    }'
}

listening_ports() { ss -ltnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -u; }

app_ports() {  # ports the app's processes are listening on
  local root=$1 tree line port pid found
  tree=" $(process_tree "$root" | tr '\n' ' ') "
  found="$($SUDO ss -ltnpH 2>/dev/null | while IFS= read -r line; do
    port="$(awk '{print $4}' <<<"$line")"; port=${port##*:}
    for pid in $(grep -oE 'pid=[0-9]+' <<<"$line" | cut -d= -f2); do
      case "$tree" in *" $pid "*) echo "$port"; break ;; esac
    done
  done | sort -un)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  else
    # Some environments hide process details: use ports that are new since the app started
    comm -13 <(printf '%s\n' "$BASE_PORTS") <(listening_ports)
  fi
}

http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null || true; }

responds() {  # any real answer counts: an API can return 404 on "/" and still be fine
  local code
  code="$(http_code "$1")"
  [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -lt 500 ]
}

start_app() {
  pm2 flush "$APP" >/dev/null 2>&1 || true   # so errors shown are from this run only
  pm2 delete "$APP" >/dev/null 2>&1 || true
  sleep 1
  BASE_PORTS="$(listening_ports)"
  ( cd "$APP_DIR" && pm2 start "$START_CMD" --name "$APP" ) >>"$LOG" 2>&1
}

wait_for_app() {  # sets PORT and returns 0 when the app answers
  local tries=0 pid status restarts ports p
  PORT=""
  CRASHED=0
  while [ "$tries" -lt 90 ]; do
    read -r pid status restarts <<<"$(pm2_info)"
    [ -t 1 ] && printf '\r  … Waiting for the app to start (%ss)   ' "$tries"
    if [ "$status" = "errored" ] || [ "$status" = "stopped" ] || [ "${restarts:-0}" -ge 3 ]; then
      [ -t 1 ] && printf '\r\033[K'
      CRASHED=1
      pm2 stop "$APP" >/dev/null 2>&1 || true   # end the restart loop
      return 1
    fi
    if [ "$status" = "online" ] && [ "${pid:-0}" -gt 0 ]; then
      ports="$(app_ports "$pid")"
      for p in $ports; do
        if responds "$p"; then PORT=$p; break 2; fi
      done
    fi
    sleep 1
    tries=$((tries + 1))
  done
  [ -t 1 ] && printf '\r\033[K'
  [ -n "$PORT" ] || return 1
  [ -t 1 ] && printf '\r\033[K'

  # Still alive a few seconds later? Catches apps that start and then crash.
  local before=$restarts
  sleep 8
  read -r pid status restarts <<<"$(pm2_info)"
  if [ "$status" = "online" ] && [ "$restarts" = "$before" ] && responds "$PORT"; then
    return 0
  fi
  CRASHED=1
  pm2 stop "$APP" >/dev/null 2>&1 || true
  return 1
}

ask_port_manually() {  # for a healthy process whose port could not be seen
  local env_port="" p=""
  [ -f "$APP_DIR/.env" ] && env_port="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?PORT=["'\'']?([0-9]+).*/\2/p' "$APP_DIR/.env" | head -n1)"
  local _pid status _r
  [ "$CRASHED" = "0" ] || return 1
  read -r _pid status _r <<<"$(pm2_info)"
  [ "$status" = "online" ] || return 1
  warn "The app is running, but it isn't answering on any port yet."
  ask p "Which port does your app use? (press Enter if you don't know)" "$env_port"
  [[ "$p" =~ ^[0-9]{2,5}$ ]] || return 1
  responds "$p" || return 1
  PORT=$p
}

show_app_errors() {
  err "The app is not working yet. Here is what it reported:"
  say ""
  local logs
  # pm2 prints error logs on stderr. Crash loops repeat lines, so show each once.
  logs="$( { pm2 logs "$APP" --err --nostream --lines 40 --raw 2>&1 || true; } | grep -vE '^[[:space:]]*$|last [0-9]+ lines:$|Tailing last' | awk '!seen[$0]++' | tail -n 30 )"
  if [ -z "$logs" ]; then
    logs="$( { pm2 logs "$APP" --out --nostream --lines 40 --raw 2>&1 || true; } | grep -vE '^[[:space:]]*$|last [0-9]+ lines:$|Tailing last' | awk '!seen[$0]++' | tail -n 30 )"
  fi
  if [ -n "$logs" ]; then printf '%s\n' "$logs" | sed 's/^/    /'; else say "    (the app printed nothing)"; fi
  explain_error "$logs"
}

step_start() {
  step 5 "Starting your app and checking it works"
  while true; do
    start_app || die "pm2 could not start the app."
    ok "Started with pm2 as '$APP'"
    if wait_for_app || ask_port_manually; then
      ok "App is working on port $PORT"
      break
    fi
    show_app_errors
    say "  What would you like to do?"
    say "    1) Paste the env file again and retry"
    say "    2) Stop here (a developer can look at it)"
    local choice=""
    ask choice "Type 1 or 2" "1"
    if [ "$choice" = "1" ]; then
      paste_env
      if ! do_build; then
        log_tail 25; explain_error "$(tail -n 60 "$LOG")"
      fi
    else
      pm2 stop "$APP" >/dev/null 2>&1 || true
      die "Setup stopped because the app is not working." "To see its errors later, run: pm2 logs $APP"
    fi
  done

  pm2 save >>"$LOG" 2>&1 || warn "Could not save the pm2 process list."
  if $SUDO env PATH="$PATH" pm2 startup systemd -u "$(id -un)" --hp "$HOME" >>"$LOG" 2>&1; then
    ok "App will start again automatically if the server restarts"
  else
    warn "Could not set up auto-start after server restarts."
  fi
}

# ── Step 6 and 7: CI/CD ──────────────────────────────────────────────────────
public_ip() {
  local t ip=""
  t="$(curl -fsS -m 2 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  [ -n "$t" ] && ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $t" 'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(curl -fsS -m 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$ip"
  return 0
}

ensure_public_ip() {
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(public_ip)"
  while [ -z "$PUBLIC_IP" ]; do
    local v=""
    warn "Could not find this server's public IP automatically."
    ask v "Type the server's public IP (shown in your cloud console)"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && PUBLIC_IP=$v
  done
}

install_gh() {
  local arch; arch="$(dpkg --print-architecture)"
  $SUDO mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$TMP/gh.gpg"
  $SUDO install -m 644 "$TMP/gh.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  apt_get update
  apt_get install gh
}

gh_ok() { GH_TOKEN="$TOKEN" gh api "repos/$OWNER_REPO/actions/secrets/public-key" --silent >>"$LOG" 2>&1; }

set_secret() {  # set_secret NAME /path/to/value-file
  GH_TOKEN="$TOKEN" gh secret set "$1" --repo "$OWNER_REPO" <"$2" >>"$LOG" 2>&1
}

choose_ssh_key() {  # writes the private key to the given path
  local keyfile=$1 pub choice=""
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  say ""
  say "  GitHub needs an SSH key to log in to this server and deploy."
  say "    1) Create a new key for me (recommended, nothing to paste)"
  say "    2) I'll paste my own key (the contents of the .pem file)"
  while true; do
    ask choice "Type 1 or 2" "1"
    if [ "$choice" = "1" ]; then
      rm -f "$keyfile" "$keyfile.pub"
      ssh-keygen -q -t ed25519 -N "" -C "github-deploy-$APP" -f "$keyfile"
      cat "$keyfile.pub" >>"$HOME/.ssh/authorized_keys"
      ok "Created a new deploy key"
      return 0
    fi
    say ""
    say "  Paste the whole key, including the BEGIN and END lines."
    say "  Then press Enter, type ${BOLD}END${RESET}, press Enter."
    say ""
    read_blob "$keyfile"
    chmod 600 "$keyfile"
    if pub="$(ssh-keygen -y -P "" -f "$keyfile" 2>/dev/null)"; then
      # Compare on type + key body, because the comment can differ
      if ! grep -qF "$(awk '{print $1" "$2}' <<<"$pub")" "$HOME/.ssh/authorized_keys"; then
        printf '%s\n' "$pub" >>"$HOME/.ssh/authorized_keys"
        ok "Allowed this key to log in to the server"
      fi
      ok "SSH key looks good"
      return 0
    fi
    err "That isn't a valid private key (or it has a password). Please try again."
  done
}

render_workflow() {  # render_workflow <with-gitleaks 0|1> > file
  local gitleaks=$1 build_block start_cmd=${START_CMD//\"/\\\"}
  if [ -n "$BUILD_CMD" ]; then build_block="$BUILD_CMD"; else build_block="# (this app has no build step)"; fi

  cat <<EOF
name: Staging

on:
  push:
    branches:
      - $BRANCH

jobs:
EOF

  if [ "$gitleaks" = "1" ]; then
    cat <<'EOF'
  # ─── Job 1: Secret scanning ───────────────────────────────────────────────
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history scan, not just latest commit

      - name: Run Gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}

EOF
  fi

  cat <<'EOF'
  # ─── Job 2: Deploy ────────────────────────────────────────────────────────
  deploy:
    runs-on: ubuntu-latest
EOF
  [ "$gitleaks" = "1" ] && echo "    needs: gitleaks"
  cat <<'EOF'
    permissions:
      contents: read

    steps:
      # ─── 1. Checkout ────────────────────────────────────────────────────
      - name: Checkout repository
        uses: actions/checkout@v4

      # ─── 2. Deploy to EC2 ───────────────────────────────────────────────
      - name: Deploy to EC2
        uses: appleboy/ssh-action@v1.0.3
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          host: ${{ secrets.DEV_HOST }}
          username: ${{ secrets.DEV_USERNAME }}
          key: ${{ secrets.DEV_SSH_KEY }}
          envs: GH_TOKEN
          command_timeout: 10m
          script: |
            set -euo pipefail
EOF
  cat <<EOF
            cd $APP_DIR

            # ── Auth ────────────────────────────────────────────────────────
EOF
  cat <<'EOF'
            git config --local credential.helper \
            '!f() { echo "username=x-access-token"; echo "password='"$GH_TOKEN"'"; }; f'

EOF
  cat <<EOF
            # ── Pull latest ─────────────────────────────────────────────────
            git fetch origin
            git reset --hard origin/$BRANCH
            git clean -fd

            # ── Install & build ─────────────────────────────────────────────
            $INSTALL_CMD
            $build_block

            # ── Graceful restart ────────────────────────────────────────────
            pm2 reload $APP || pm2 start "$start_cmd" --name $APP
            pm2 save

            # ── Cleanup ─────────────────────────────────────────────────────
            git config --local --unset credential.helper

            # ── Health check ─────────────────────────────────────────────
            echo "Running health check..."
            MAX_RETRIES=12
            RETRY_INTERVAL=5
            HEALTH_URL="http://localhost:$PORT"
EOF
  cat <<'EOF'
            SUCCESS=false

            for i in $(seq 1 $MAX_RETRIES); do
              STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")
              # Any answer below 500 means the app is up (an API may return 404 on "/")
              if [ "$STATUS" != "000" ] && [ "$STATUS" -lt 500 ]; then
                echo "Health check passed (attempt $i) — app is live"
                SUCCESS=true
                break
              fi
              echo "Attempt $i/$MAX_RETRIES — got HTTP $STATUS, retrying in ${RETRY_INTERVAL}s..."
              sleep $RETRY_INTERVAL
            done

            if [ "$SUCCESS" != "true" ]; then
              echo "Health check FAILED after $MAX_RETRIES attempts — aborting pipeline"
              exit 1
            fi

      # ─── 3. Notify on failure ──────────────────────────────────────────────
      - name: Notify on failure
        if: failure()
        run: echo "::error::Deployment failed on $(date -u). Check deploy logs."
EOF
}

push_workflow() {
  local file=$1 sha="" args=()
  sha="$(GH_TOKEN="$TOKEN" gh api "repos/$OWNER_REPO/contents/$WORKFLOW_PATH?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    if ! ask_yes "This repo already has a pipeline file ($WORKFLOW_PATH). Replace it?" n; then
      warn "Kept the existing pipeline file."
      return 0
    fi
    args=(-f "sha=$sha")
  fi
  base64 -w0 "$file" >"$TMP/workflow.b64"
  GH_TOKEN="$TOKEN" gh api --method PUT "repos/$OWNER_REPO/contents/$WORKFLOW_PATH" \
    -f message="Add deploy pipeline" -f branch="$BRANCH" \
    -F "content=@$TMP/workflow.b64" "${args[@]}" --silent >>"$LOG" 2>&1
}

step_pipeline() {
  step 6 "Automatic deploys (CI/CD)"
  say "  With this on, every push to '$BRANCH' deploys to this server automatically."
  say ""
  if ! ask_yes "Do you want to set this up?" y; then
    say "  Skipping automatic deploys."
    step 7 "Setting up the pipeline (skipped)"
    return 0
  fi

  ensure_public_ip
  if ! command -v gh >/dev/null 2>&1; then
    run "Installing GitHub tools" install_gh || die "Could not install GitHub tools."
  fi

  until [ -n "$TOKEN" ] && gh_ok; do
    err "This token can't manage this repo's secrets."
    say "    It needs these repository permissions: Contents (read and write),"
    say "    Secrets (read and write), Workflows (read and write)."
    ask_secret TOKEN "Paste a GitHub token with those permissions (or press Enter to skip the pipeline)"
    if [ -z "$TOKEN" ]; then
      warn "Skipping automatic deploys."
      step 7 "Setting up the pipeline (skipped)"
      return 0
    fi
  done
  ok "Token has the right permissions"

  local gitleaks_key="" with_gitleaks=1
  say ""
  ask_secret gitleaks_key "Gitleaks license key (press Enter to skip secret scanning)"
  [ -n "$gitleaks_key" ] || with_gitleaks=0

  local keyfile="$TMP/deploy_key"
  choose_ssh_key "$keyfile"

  step 7 "Setting up the pipeline"
  printf '%s' "$PUBLIC_IP" >"$TMP/v_host"
  id -un | tr -d '\n' >"$TMP/v_user"
  run "Saving DEV_HOST ($PUBLIC_IP)" set_secret DEV_HOST "$TMP/v_host" || die "Could not save GitHub secrets."
  run "Saving DEV_USERNAME ($(id -un))" set_secret DEV_USERNAME "$TMP/v_user" || die "Could not save GitHub secrets."
  run "Saving DEV_SSH_KEY" set_secret DEV_SSH_KEY "$keyfile" || die "Could not save GitHub secrets."
  if [ "$with_gitleaks" = "1" ]; then
    printf '%s' "$gitleaks_key" >"$TMP/v_gitleaks"
    run "Saving GITLEAKS_LICENSE" set_secret GITLEAKS_LICENSE "$TMP/v_gitleaks" || die "Could not save GitHub secrets."
  fi
  gitleaks_key=""
  rm -f "$keyfile" "$keyfile.pub" "$TMP"/v_*

  render_workflow "$with_gitleaks" >"$TMP/staging.yml"
  push_workflow "$TMP/staging.yml" || die "Could not add the pipeline file to the repo." "If branch '$BRANCH' is protected, ask a developer to allow this, then run the setup again."
  ok "Pipeline is set up on branch '$BRANCH'"
  say "    See it run at: https://github.com/$OWNER_REPO/actions"
  PIPELINE_DONE=1
}

# ── Step 8: domain ───────────────────────────────────────────────────────────
install_caddy() {
  apt_get install debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor >"$TMP/caddy.gpg"
  $SUDO install -m 644 "$TMP/caddy.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt_get update
  apt_get install caddy
}

clean_domain() {
  local d
  d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  d=${d#https://}; d=${d#http://}; d=${d%%/*}
  if [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then printf '%s' "$d"; fi
}

wait_for_dns() {
  local resolved="" answer=""
  while true; do
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' || true)"
    if grep -qw "$PUBLIC_IP" <<<"$resolved"; then
      ok "$DOMAIN points to this server"
      return 0
    fi
    say ""
    if [ -z "$resolved" ]; then
      warn "$DOMAIN isn't set up yet."
    else
      warn "$DOMAIN currently points to: $resolved"
    fi
    say "    In your domain provider, add this record:"
    say "      Type: ${BOLD}A${RESET}    Name: ${BOLD}$DOMAIN${RESET}    Value: ${BOLD}$PUBLIC_IP${RESET}"
    say "    Using Cloudflare? Set it to 'DNS only' (grey cloud) for now."
    say "    Changes usually take a few minutes."
    say ""
    ask answer "Press Enter to check again, or type skip to continue anyway"
    if [ "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" = "skip" ]; then
      warn "Continuing. HTTPS will start working once the domain points here."
      return 0
    fi
  done
}

free_web_ports() {
  local holders
  holders="$($SUDO ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy"' | grep -oE '"[a-z0-9_-]+"' | tr -d '"' | sort -u | paste -sd' ' || true)"
  [ -n "$holders" ] || return 0
  warn "These programs are using web ports 80/443: $holders"
  local svc
  for svc in nginx apache2; do
    if grep -qw "${svc/apache2/apache2}" <<<"$holders" && ask_yes "Stop $svc so Caddy can use those ports?" y; then
      $SUDO systemctl disable --now "$svc" >>"$LOG" 2>&1 || true
    fi
  done
  holders="$($SUDO ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy"' || true)"
  [ -z "$holders" ] || die "Ports 80/443 are still in use, so Caddy can't start." "Ask a developer to check what's running on the server."
}

configure_caddy() {
  $SUDO mkdir -p /etc/caddy/sites
  printf '%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "$DOMAIN" "$PORT" | $SUDO tee "/etc/caddy/sites/$APP.caddy" >/dev/null
  if ! $SUDO grep -q '^import /etc/caddy/sites/' /etc/caddy/Caddyfile 2>/dev/null; then
    [ -f /etc/caddy/Caddyfile ] && $SUDO cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup-$(date +%Y%m%d-%H%M%S)"
    echo 'import /etc/caddy/sites/*.caddy' | $SUDO tee /etc/caddy/Caddyfile >/dev/null
  fi
  $SUDO caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  $SUDO systemctl enable caddy
  $SUDO systemctl restart caddy
}

https_works() {
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -lt 500 ]
}

step_domain() {
  step 8 "Domain and HTTPS"
  if ! ask_yes "Do you want to connect a domain?" y; then
    say "  Skipping the domain."
    return 0
  fi
  ensure_public_ip
  while true; do
    local input=""
    ask input "Your domain (e.g. app.company.com)"
    DOMAIN="$(clean_domain "$input")"
    [ -n "$DOMAIN" ] && break
    err "That doesn't look like a domain. Example: app.company.com"
  done
  wait_for_dns
  free_web_ports
  if ! command -v caddy >/dev/null 2>&1; then
    run "Installing Caddy" install_caddy || die "Could not install Caddy."
  fi
  run "Connecting $DOMAIN to port $PORT" configure_caddy || die "Could not configure Caddy."

  local tries=0
  while [ "$tries" -lt 24 ]; do
    [ -t 1 ] && printf '\r  … Getting the HTTPS certificate (%ss)   ' "$((tries * 5))"
    if https_works; then
      [ -t 1 ] && printf '\r\033[K'
      ok "https://$DOMAIN is live"
      DOMAIN_LIVE=1
      return 0
    fi
    sleep 5
    tries=$((tries + 1))
  done
  [ -t 1 ] && printf '\r\033[K'
  warn "https://$DOMAIN isn't answering yet."
  say "    Check that ports 80 and 443 are open in your cloud firewall and that the"
  say "    domain points to $PUBLIC_IP. Caddy keeps trying by itself, so it may start"
  say "    working on its own in a few minutes."
  $SUDO journalctl -u caddy -n 30 --no-pager >>"$LOG" 2>&1 || true
}

# ── Finish ───────────────────────────────────────────────────────────────────
summary() {
  ensure_public_ip
  say ""
  say "${BOLD}${GREEN}━━ All done! ━━${RESET}"
  say ""
  say "  App:       $APP (branch: $BRANCH)"
  say "  Folder:    $APP_DIR"
  say "  Port:      $PORT"
  if [ -n "$DOMAIN" ]; then
    say "  Website:   ${BOLD}https://$DOMAIN${RESET}"
    [ "$DOMAIN_LIVE" = "1" ] || say "             Not answering yet. See the note above."
  else
    say "  Website:   http://$PUBLIC_IP:$PORT"
    say "             This only opens if port $PORT is allowed in your cloud firewall."
    say "             Or run this setup again and connect a domain."
  fi
  if [ "$PIPELINE_DONE" = "1" ]; then
    say "  Deploys:   automatic on every push to '$BRANCH'"
  else
    say "  Deploys:   manual (no pipeline)"
  fi
  say ""
  say "  Useful commands:"
  say "    pm2 status          see whether the app is running"
  say "    pm2 logs $APP       see the app's messages (Ctrl+C to leave)"
  say "    pm2 restart $APP    restart the app"
  say ""
}

main() {
  trap 'on_error $LINENO' ERR
  trap cleanup EXIT
  trap 'printf "\n"; say "  Setup cancelled. You can run it again at any time."; exit 130' INT

  say ""
  say "${BOLD}Server setup${RESET}: this will put your app online, step by step."
  say "Press Ctrl+C at any time to cancel."

  preflight
  step_install
  step_clone
  step_env
  step_build
  step_start
  step_pipeline
  step_domain
  summary
}

main "$@"
