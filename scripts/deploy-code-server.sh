#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROGRAM="star-coder deploy"
CONTEXT="auto"
PREFIX=""
WORKSPACE="${PWD}"
VERSION="latest"
INSTALL_SOURCE="auto"
ARCHIVE=""
BIND_ADDRESS="127.0.0.1"
PORT="auto"
PASSWORD_MODE="preserve-or-generate"
AUTOSTART="manual"
UPGRADE=0
START_NOW=1
CREATE_WORKSPACE=0
DRY_RUN=0
ALLOW_PUBLIC_HTTP=0
TEMP_PATHS=()

usage() {
  cat <<'USAGE'
Install and configure a self-contained code-server deployment.

Usage:
  deploy-code-server.sh [options]

Required deployment choices (defaults are safe for a local user install):
  --context TYPE          auto|native|container|hpc-login|hpc-compute|other
  --prefix DIR            Managed installation prefix
  --workspace DIR         Default workspace opened by code-server
  --version VERSION       latest or an exact code-server version
  --source SOURCE         auto|standalone|npm|archive|existing
  --archive FILE          Offline .tar.gz/.tar.xz archive; implies archive source
  --bind ADDRESS          Bind address (default: 127.0.0.1)
  --port PORT             Numeric port or auto (default: auto)
  --password-mode MODE    preserve-or-generate|generate|prompt
  --autostart MODE        auto|manual|systemd-user|cron|slurm|container

Behavior:
  --upgrade               Replace/update an existing installation
  --no-start              Configure but do not start now
  --create-workspace      Create the workspace if it does not exist
  --dry-run               Validate and print the resolved plan without changes
  --allow-public-http     Acknowledge non-loopback plain-HTTP exposure risk
  -h, --help              Show this help

Password handling:
  prompt mode reads silently from a TTY/stdin. Passwords are never accepted as
  command-line arguments. Generated/preserved passwords are stored at:
    <prefix>/etc/code-server/password
USAGE
}

log() {
  printf '[%s] %s\n' "$PROGRAM" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$PROGRAM" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  local path
  for path in "${TEMP_PATHS[@]:-}"; do
    if [[ -n "$path" && "$path" == /tmp/* && -e "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
}
trap cleanup EXIT

canonicalize() {
  local path="$1"
  case "$path" in
    '~') path="${HOME:?HOME is not set}" ;;
    '~/'*) path="${HOME:?HOME is not set}/${path#~/}" ;;
  esac
  if [[ "$path" != /* ]]; then
    path="${PWD}/${path}"
  fi
  if have realpath; then
    realpath -m -- "$path"
  elif have readlink && readlink -m / >/dev/null 2>&1; then
    readlink -m -- "$path"
  else
    printf '%s\n' "$path"
  fi
}

shell_quote() {
  printf '%q' "$1"
}

yaml_single_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

download() {
  local url="$1"
  local output="$2"
  if have curl; then
    curl -fL --retry 2 --connect-timeout 15 "$url" -o "$output"
  elif have wget; then
    wget -O "$output" "$url"
  else
    die "curl or wget is required for a network installation"
  fi
}

detect_context() {
  if [[ -n "${SLURM_JOB_ID:-}${PBS_JOBID:-}" ]]; then
    printf 'hpc-compute\n'
  elif have sbatch || have qsub; then
    printf 'hpc-login\n'
  elif [[ -f /.dockerenv ]] || { [[ -r /proc/1/cgroup ]] && grep -Eqi '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup; }; then
    printf 'container\n'
  else
    printf 'native\n'
  fi
}

systemd_user_available() {
  have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

port_in_use() {
  local port="$1"
  if have ss; then
    ss -ltnH 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit found ? 0 : 1}'
    return
  fi
  if have lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  if have netstat; then
    netstat -ltn 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit found ? 0 : 1}'
    return
  fi
  if have python3; then
    if python3 - "$BIND_ADDRESS" "$port" >/dev/null 2>&1 <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
s = socket.socket(family, socket.SOCK_STREAM)
try:
    s.bind((host, port))
finally:
    s.close()
PY
    then
      return 1
    fi
    return 0
  fi
  warn "cannot check port availability because ss, lsof, netstat, and python3 are unavailable"
  return 1
}

choose_port() {
  local candidate
  local candidates=()
  [[ -n "${CODE_SERVER_PORT:-}" ]] && candidates+=("$CODE_SERVER_PORT")
  [[ -n "${RESERVED_PORT_1:-}" ]] && candidates+=("$RESERVED_PORT_1")
  [[ -n "${RESERVED_PORT_2:-}" ]] && candidates+=("$RESERVED_PORT_2")
  for candidate in $(seq 18080 18099); do
    candidates+=("$candidate")
  done
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate > 0 && candidate < 65536 )) && ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  die "could not find an available port from reserved variables or 18080-18099"
}

validate_prefix() {
  case "$PREFIX" in
    /|/usr|/etc|/bin|/sbin|/lib|/lib64|"${HOME:-__unset__}")
      die "refusing broad managed prefix: $PREFIX"
      ;;
  esac
  if [[ "$PREFIX" == *$'\n'* ]]; then
    die "prefix must not contain a newline"
  fi
}

nearest_existing_parent() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != / ]]; do
    path="$(dirname -- "$path")"
  done
  printf '%s\n' "$path"
}

existing_version() {
  if [[ -x "$PREFIX/bin/code-server" ]]; then
    "$PREFIX/bin/code-server" --version 2>/dev/null | sed -n '1p'
  fi
}

install_standalone() {
  local installer
  local args=(--method standalone --prefix "$PREFIX")
  installer="$(mktemp /tmp/star-coder-installer.XXXXXX)"
  TEMP_PATHS+=("$installer")
  [[ "$VERSION" == "latest" ]] || args+=(--version "$VERSION")
  log "downloading the official code-server installer"
  download "https://code-server.dev/install.sh" "$installer" || return 1
  log "installing the standalone release into $PREFIX"
  sh "$installer" "${args[@]}" || return 1
}

install_npm() {
  local package="code-server"
  have npm || die "npm source selected but npm is unavailable"
  [[ "$VERSION" == "latest" ]] || package="code-server@${VERSION}"
  log "installing $package through the existing npm toolchain"
  npm install --global --prefix "$PREFIX" "$package"
}

install_archive() {
  local extract_dir binary root name destination
  [[ -f "$ARCHIVE" ]] || die "offline archive does not exist: $ARCHIVE"
  have tar || die "tar is required for an offline archive"
  extract_dir="$(mktemp -d /tmp/star-coder-archive.XXXXXX)"
  TEMP_PATHS+=("$extract_dir")
  log "extracting offline archive: $ARCHIVE"
  tar -xf "$ARCHIVE" -C "$extract_dir"
  binary="$(find "$extract_dir" -type f -path '*/bin/code-server' -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "archive does not contain an executable bin/code-server"
  root="$(dirname "$(dirname "$binary")")"
  name="$(basename "$root" | tr -cs 'A-Za-z0-9._-' '_')"
  destination="$PREFIX/lib/${name:-code-server-offline}"
  mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$destination"
  cp -a "$root/." "$destination/"
  ln -sfn "$destination/bin/code-server" "$PREFIX/bin/code-server"
}

install_code_server() {
  local current=""
  current="$(existing_version || true)"
  if [[ -n "$current" && "$UPGRADE" -eq 0 && "$INSTALL_SOURCE" != "archive" ]]; then
    log "reusing existing code-server: $current"
    return
  fi

  case "$INSTALL_SOURCE" in
    existing)
      [[ -n "$current" ]] || die "existing source selected but $PREFIX/bin/code-server is not usable"
      ;;
    archive)
      install_archive
      ;;
    standalone)
      install_standalone || die "official standalone installation failed; inspect platform compatibility and network access"
      ;;
    npm)
      install_npm
      ;;
    auto)
      if [[ -n "$ARCHIVE" ]]; then
        install_archive
      elif install_standalone; then
        :
      elif have npm; then
        warn "standalone installation failed; trying the existing npm toolchain"
        install_npm
      else
        die "standalone installation failed and no npm fallback is available"
      fi
      ;;
    *) die "invalid source: $INSTALL_SOURCE" ;;
  esac

  [[ -x "$PREFIX/bin/code-server" ]] || die "code-server was not installed at $PREFIX/bin/code-server"
  current="$(existing_version || true)"
  [[ -n "$current" ]] || die "installed binary cannot execute on this platform; check loader/glibc/architecture errors"
  log "installed: $current"
}

generate_password() {
  if have openssl; then
    openssl rand -hex 16
  elif [[ -r /dev/urandom ]] && have od; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  else
    die "cannot securely generate a password; use --password-mode prompt"
  fi
}

read_existing_yaml_password() {
  local config="$1"
  local value=""
  [[ -f "$config" ]] || return 1
  value="$(sed -n 's/^password:[[:space:]]*//p' "$config" | sed -n '1p')"
  [[ -n "$value" ]] || return 1
  if [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\'\'/\'}"
  fi
  printf '%s' "$value"
}

resolve_password() {
  local secret_file="$PREFIX/etc/code-server/password"
  local config_file="$PREFIX/etc/code-server/config.yaml"
  local password=""
  case "$PASSWORD_MODE" in
    preserve-or-generate)
      if [[ -s "$secret_file" ]]; then
        password="$(<"$secret_file")"
      else
        password="$(read_existing_yaml_password "$config_file" || true)"
      fi
      [[ -n "$password" ]] || password="$(generate_password)"
      ;;
    generate)
      password="$(generate_password)"
      ;;
    prompt)
      [[ -t 0 ]] && printf 'code-server password: ' >&2
      IFS= read -r -s password
      [[ -t 0 ]] && printf '\n' >&2
      [[ -n "$password" ]] || die "password must not be empty"
      ;;
    *) die "invalid password mode: $PASSWORD_MODE" ;;
  esac
  [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || die "password must be one line"
  printf '%s' "$password" > "$secret_file"
  chmod 600 "$secret_file"
  PASSWORD_VALUE="$password"
}

health_host_for_bind() {
  case "$BIND_ADDRESS" in
    0.0.0.0|127.*|localhost) printf '127.0.0.1\n' ;;
    ::|::1) printf '::1\n' ;;
    *) printf '%s\n' "$BIND_ADDRESS" ;;
  esac
}

write_config() {
  local config_file="$PREFIX/etc/code-server/config.yaml"
  local password_yaml
  password_yaml="$(yaml_single_quote "$PASSWORD_VALUE")"
  cat > "$config_file" <<CONFIG
bind-addr: ${BIND_ADDRESS}:${PORT}
auth: password
password: ${password_yaml}
cert: false
disable-telemetry: true
disable-update-check: true
CONFIG
  chmod 600 "$config_file"
}

write_environment() {
  local env_file="$PREFIX/etc/star-coder.env"
  local health_host
  health_host="$(health_host_for_bind)"
  {
    printf 'CODE_SERVER_BIN=%s\n' "$(shell_quote "$PREFIX/bin/code-server")"
    printf 'CONFIG_FILE=%s\n' "$(shell_quote "$PREFIX/etc/code-server/config.yaml")"
    printf 'WORKSPACE_DIR=%s\n' "$(shell_quote "$WORKSPACE")"
    printf 'LOG_FILE=%s\n' "$(shell_quote "$PREFIX/var/log/code-server.log")"
    printf 'PID_FILE=%s\n' "$(shell_quote "$PREFIX/var/run/code-server.pid")"
    printf 'USER_DATA_DIR=%s\n' "$(shell_quote "$PREFIX/var/lib/code-server/user-data")"
    printf 'EXTENSIONS_DIR=%s\n' "$(shell_quote "$PREFIX/var/lib/code-server/extensions")"
    printf 'BIND_ADDRESS=%s\n' "$(shell_quote "$BIND_ADDRESS")"
    printf 'HEALTH_HOST=%s\n' "$(shell_quote "$health_host")"
    printf 'PORT=%s\n' "$(shell_quote "$PORT")"
  } > "$env_file"
  chmod 600 "$env_file"
}

write_controller() {
  local controller="$PREFIX/bin/star-coder-ctl"
  cat > "$controller" <<'CONTROLLER'
#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_DIR="$(cd "$BIN_DIR/.." && pwd)"
# shellcheck disable=SC1090
. "$PREFIX_DIR/etc/star-coder.env"

health_url() {
  if [[ "$HEALTH_HOST" == *:* ]]; then
    printf 'http://[%s]:%s/healthz' "$HEALTH_HOST" "$PORT"
  else
    printf 'http://%s:%s/healthz' "$HEALTH_HOST" "$PORT"
  fi
}

health_check() {
  local url
  url="$(health_url)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 3 -O /dev/null "$url"
  else
    return 2
  fi
}

read_pid() {
  [[ -s "$PID_FILE" ]] && sed -n '1p' "$PID_FILE"
}

process_matches() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F -- "$CONFIG_FILE" >/dev/null
  fi
}

find_matching_pid() {
  local proc pid
  for proc in /proc/[0-9]*; do
    [[ -d "$proc" ]] || continue
    pid="${proc#/proc/}"
    if process_matches "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

status() {
  local pid="" health_status=0
  pid="$(read_pid || true)"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] || ! process_matches "$pid"; then
    pid="$(find_matching_pid || true)"
    if [[ -z "$pid" ]]; then
      printf 'stopped\n'
      return 1
    fi
    printf '%s\n' "$pid" > "$PID_FILE"
  fi
  if health_check; then
    printf 'running pid=%s health=%s\n' "$pid" "$(health_url)"
    return 0
  else
    health_status=$?
  fi
  case "$health_status" in
    2) printf 'running pid=%s health=not-checked\n' "$pid" ; return 0 ;;
    *) printf 'degraded pid=%s health=%s\n' "$pid" "$(health_url)" ; return 1 ;;
  esac
}

run_foreground() {
  unset VSCODE_IPC_HOOK_CLI
  exec "$CODE_SERVER_BIN" --config "$CONFIG_FILE" \
    --user-data-dir "$USER_DATA_DIR" \
    --extensions-dir "$EXTENSIONS_DIR" \
    "$WORKSPACE_DIR"
}

start() {
  local pid attempt
  if status >/dev/null 2>&1; then
    status
    return 0
  fi
  mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")" "$USER_DATA_DIR" "$EXTENSIONS_DIR"
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$BIN_DIR/star-coder-ctl" run >> "$LOG_FILE" 2>&1 < /dev/null
  else
    nohup "$BIN_DIR/star-coder-ctl" run >> "$LOG_FILE" 2>&1 < /dev/null &
  fi
  for attempt in $(seq 1 20); do
    pid="$(find_matching_pid || true)"
    if [[ -n "$pid" ]] && health_check; then
      printf '%s\n' "$pid" > "$PID_FILE"
      status
      return 0
    fi
    sleep 0.25
  done
  printf 'failed to start; inspect %s\n' "$LOG_FILE" >&2
  tail -n 60 "$LOG_FILE" >&2 || true
  return 1
}

stop() {
  local pid attempt
  pid="$(read_pid || true)"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] || ! process_matches "$pid"; then
    pid="$(find_matching_pid || true)"
    if [[ -z "$pid" ]]; then
      printf 'already stopped\n'
      rm -f -- "$PID_FILE"
      return 0
    fi
  fi
  kill "$pid"
  for attempt in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$PID_FILE"
      printf 'stopped\n'
      return 0
    fi
    sleep 0.25
  done
  printf 'process %s did not stop after 10 seconds; not sending SIGKILL automatically\n' "$pid" >&2
  return 1
}

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  case "$(basename "$0")" in
    star-coder-start) command_name=start ;;
    star-coder-stop) command_name=stop ;;
    star-coder-restart) command_name=restart ;;
    star-coder-status) command_name=status ;;
    star-coder-logs) command_name=logs ;;
    star-coder-run) command_name=run ;;
  esac
fi

case "$command_name" in
  start) start ;;
  stop) stop ;;
  restart) stop && start ;;
  status) status ;;
  logs) tail -n "${STAR_CODER_LOG_LINES:-100}" -f "$LOG_FILE" ;;
  run) run_foreground ;;
  *) printf 'Usage: %s {start|stop|restart|status|logs|run}\n' "$0" >&2; exit 2 ;;
esac
CONTROLLER
  chmod 755 "$controller"
  local name
  for name in start stop restart status logs run; do
    ln -sfn star-coder-ctl "$PREFIX/bin/star-coder-$name"
  done
}

write_systemd_user_unit() {
  local user_unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
  local unit="$user_unit_dir/star-code-server.service"
  [[ "$PREFIX" != *%* ]] || die "systemd mode does not support a prefix containing %"
  systemd_user_available || die "systemd --user is unavailable in this session; choose manual or cron explicitly"
  mkdir -p "$user_unit_dir"
  cat > "$unit" <<UNIT
[Unit]
Description=Star code-server
After=network.target

[Service]
Type=simple
ExecStart="${PREFIX}/bin/star-coder-ctl" run
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  if [[ "$START_NOW" -eq 1 ]]; then
    systemctl --user enable --now star-code-server.service
  else
    systemctl --user enable star-code-server.service
  fi
  log "systemd user unit: $unit"
}

write_cron_entry() {
  local tmp marker existing=""
  have crontab || die "cron mode selected but crontab is unavailable"
  [[ "$PREFIX" != *%* ]] || die "cron mode does not support a prefix containing %"
  marker="# star-coder-skill:${PREFIX}"
  tmp="$(mktemp /tmp/star-coder-cron.XXXXXX)"
  TEMP_PATHS+=("$tmp")
  existing="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$existing" | awk -v marker="$marker" '$0 != marker && index($0, marker) == 0' > "$tmp"
  printf '%s\n' "$marker" >> "$tmp"
  printf '@reboot "%s/bin/star-coder-start" # star-coder-skill:%s\n' "$PREFIX" "$PREFIX" >> "$tmp"
  crontab "$tmp"
  log "installed user cron @reboot entry"
  if [[ "$START_NOW" -eq 1 ]]; then
    "$PREFIX/bin/star-coder-ctl" start
  fi
}

write_slurm_job() {
  local job_dir="$PREFIX/share/star-coder"
  local job="$job_dir/star-code-server.slurm"
  mkdir -p "$job_dir"
  cat > "$job" <<JOB
#!/usr/bin/env bash
#SBATCH --job-name=star-code-server
#SBATCH --output=${PREFIX}/var/log/slurm-%j.log
# Add site-required account, partition, time, memory, and CPU directives.
set -euo pipefail
exec "${PREFIX}/bin/star-coder-ctl" run
JOB
  chmod 700 "$job"
  log "generated Slurm job (not submitted): $job"
  log "review site directives, then run: sbatch $(shell_quote "$job")"
}

resolve_autostart() {
  if [[ "$AUTOSTART" != auto ]]; then
    return
  fi
  case "$CONTEXT" in
    container) AUTOSTART=container ;;
    hpc-login|hpc-compute)
      if have sbatch; then AUTOSTART=slurm; else AUTOSTART=manual; fi
      ;;
    *)
      if systemd_user_available; then AUTOSTART=systemd-user; else AUTOSTART=manual; fi
      ;;
  esac
}

for arg in "$@"; do
  [[ "$arg" != *$'\n'* && "$arg" != *$'\r'* ]] || die "arguments must not contain newlines"
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) [[ $# -ge 2 ]] || die "$1 requires a value"; CONTEXT="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 ]] || die "$1 requires a value"; PREFIX="$2"; shift 2 ;;
    --workspace) [[ $# -ge 2 ]] || die "$1 requires a value"; WORKSPACE="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "$1 requires a value"; VERSION="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || die "$1 requires a value"; INSTALL_SOURCE="$2"; shift 2 ;;
    --archive) [[ $# -ge 2 ]] || die "$1 requires a value"; ARCHIVE="$2"; shift 2 ;;
    --bind) [[ $# -ge 2 ]] || die "$1 requires a value"; BIND_ADDRESS="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "$1 requires a value"; PORT="$2"; shift 2 ;;
    --password-mode) [[ $# -ge 2 ]] || die "$1 requires a value"; PASSWORD_MODE="$2"; shift 2 ;;
    --autostart) [[ $# -ge 2 ]] || die "$1 requires a value"; AUTOSTART="$2"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --no-start) START_NOW=0; shift ;;
    --create-workspace) CREATE_WORKSPACE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-public-http) ALLOW_PUBLIC_HTTP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s 2>/dev/null)" == Linux ]] || die "this deployment script supports Linux only"
case "$CONTEXT" in auto|native|container|hpc-login|hpc-compute|other) ;; *) die "invalid context: $CONTEXT" ;; esac
case "$INSTALL_SOURCE" in auto|standalone|npm|archive|existing) ;; *) die "invalid source: $INSTALL_SOURCE" ;; esac
case "$PASSWORD_MODE" in preserve-or-generate|generate|prompt) ;; *) die "invalid password mode: $PASSWORD_MODE" ;; esac
case "$AUTOSTART" in auto|manual|systemd-user|cron|slurm|container) ;; *) die "invalid autostart mode: $AUTOSTART" ;; esac

[[ "$CONTEXT" == auto ]] && CONTEXT="$(detect_context)"
if [[ -z "$PREFIX" ]]; then
  PREFIX="${HOME:?HOME is not set}/.local/opt/star-code-server"
fi
PREFIX="$(canonicalize "$PREFIX")"
WORKSPACE="$(canonicalize "$WORKSPACE")"
[[ -z "$ARCHIVE" ]] || ARCHIVE="$(canonicalize "$ARCHIVE")"
validate_prefix

if [[ "$PORT" == auto ]]; then
  PORT="$(choose_port)"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] || die "port must be numeric or auto: $PORT"
(( PORT > 0 && PORT < 65536 )) || die "port out of range: $PORT"

if port_in_use "$PORT"; then
  if [[ -x "$PREFIX/bin/star-coder-ctl" ]] && "$PREFIX/bin/star-coder-ctl" status >/dev/null 2>&1; then
    log "selected port is already owned by this deployment"
  else
    die "port $PORT is already listening; choose another port and do not stop the unknown owner"
  fi
fi

if [[ "$BIND_ADDRESS" != 127.0.0.1 && "$BIND_ADDRESS" != localhost && "$BIND_ADDRESS" != ::1 ]]; then
  if [[ "$CONTEXT" == hpc-login ]]; then
    warn "non-loopback binding on an HPC login node is usually unsafe and may violate site policy"
  fi
  if [[ "$ALLOW_PUBLIC_HTTP" -eq 0 ]]; then
    warn "binding to $BIND_ADDRESS exposes plain HTTP on reachable interfaces; use host firewall/forwarding, VPN, or a TLS reverse proxy"
  fi
fi

resolve_autostart
if [[ "$CONTEXT" == hpc-login && "$AUTOSTART" != slurm && "$AUTOSTART" != manual ]]; then
  die "refusing persistent autostart on an HPC login node; choose slurm or manual after policy review"
fi

parent="$(nearest_existing_parent "$PREFIX")"
[[ -w "$parent" ]] || die "installation parent is not writable without additional authorization: $parent"

log "resolved context: $CONTEXT"
log "resolved prefix: $PREFIX"
log "resolved workspace: $WORKSPACE"
log "resolved install: source=$INSTALL_SOURCE version=$VERSION upgrade=$UPGRADE"
log "resolved network: bind=$BIND_ADDRESS port=$PORT"
log "resolved lifecycle: $AUTOSTART start-now=$START_NOW"

if [[ "$DRY_RUN" -eq 1 ]]; then
  [[ -d "$WORKSPACE" || "$CREATE_WORKSPACE" -eq 1 ]] || die "workspace does not exist: $WORKSPACE"
  log "dry run complete; no files or services changed"
  exit 0
fi

mkdir -p "$PREFIX/bin" "$PREFIX/etc/code-server" "$PREFIX/var/log" "$PREFIX/var/run" \
  "$PREFIX/var/lib/code-server/user-data" "$PREFIX/var/lib/code-server/extensions" "$PREFIX/share/star-coder"
if [[ ! -d "$WORKSPACE" ]]; then
  [[ "$CREATE_WORKSPACE" -eq 1 ]] || die "workspace does not exist: $WORKSPACE"
  mkdir -p "$WORKSPACE"
fi

install_code_server
resolve_password
write_config
unset PASSWORD_VALUE
write_environment
write_controller

case "$AUTOSTART" in
  manual)
    if [[ "$START_NOW" -eq 1 ]]; then "$PREFIX/bin/star-coder-ctl" start; fi
    ;;
  systemd-user) write_systemd_user_unit ;;
  cron) write_cron_entry ;;
  slurm) write_slurm_job ;;
  container)
    log "container foreground command: $(shell_quote "$PREFIX/bin/star-coder-ctl") run"
    ;;
esac

if [[ "$AUTOSTART" == manual || "$AUTOSTART" == cron ]]; then
  if [[ "$START_NOW" -eq 1 ]]; then
    "$PREFIX/bin/star-coder-ctl" status
  fi
elif [[ "$AUTOSTART" == systemd-user && "$START_NOW" -eq 1 ]]; then
  systemctl --user --no-pager --full status star-code-server.service >/dev/null
fi

log "configuration: $PREFIX/etc/code-server/config.yaml"
log "password: cat $(shell_quote "$PREFIX/etc/code-server/password")"
log "control: $PREFIX/bin/star-coder-ctl {start|stop|restart|status|logs|run}"
log "local health: http://$(health_host_for_bind):$PORT/healthz"
if [[ "$BIND_ADDRESS" == 127.0.0.1 || "$BIND_ADDRESS" == localhost || "$BIND_ADDRESS" == ::1 ]]; then
  log "SSH tunnel example: ssh -N -L $PORT:127.0.0.1:$PORT user@host"
fi
