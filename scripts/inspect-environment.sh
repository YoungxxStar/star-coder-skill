#!/usr/bin/env bash
set -u

# Read-only preflight for code-server deployment decisions.

have() {
  command -v "$1" >/dev/null 2>&1
}

value_or_unknown() {
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1"
  else
    printf 'unknown'
  fi
}

os_id=""
os_version=""
os_name=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  os_name="${PRETTY_NAME:-}"
fi

container="no"
if [[ -f /.dockerenv ]]; then
  container="docker-compatible"
elif [[ -r /proc/1/cgroup ]] && grep -Eqi '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup; then
  container="detected"
elif [[ -n "${container:-}" ]]; then
  container="${container}"
fi

scheduler="none-detected"
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
  scheduler="slurm-allocation:${SLURM_JOB_ID}"
elif have sbatch; then
  scheduler="slurm-client"
elif [[ -n "${PBS_JOBID:-}" ]]; then
  scheduler="pbs-allocation:${PBS_JOBID}"
elif have qsub; then
  scheduler="pbs-client"
fi

init_name="unknown"
if [[ -r /proc/1/comm ]]; then
  init_name="$(tr -d '\n' < /proc/1/comm)"
fi

systemd_user="unavailable"
if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
  systemd_user="available"
fi

glibc="not-detected"
if have ldd; then
  glibc="$(ldd --version 2>&1 | sed -n '1s/.* //p')"
  glibc="${glibc:-not-detected}"
fi

fs_type="unknown"
if have findmnt; then
  fs_type="$(findmnt -n -o FSTYPE -T "${PWD}" 2>/dev/null || true)"
  fs_type="${fs_type:-unknown}"
fi

printf 'kernel=%s\n' "$(uname -sr 2>/dev/null || printf unknown)"
printf 'architecture=%s\n' "$(uname -m 2>/dev/null || printf unknown)"
printf 'distribution_id=%s\n' "$(value_or_unknown "$os_id")"
printf 'distribution_version=%s\n' "$(value_or_unknown "$os_version")"
printf 'distribution_name=%s\n' "$(value_or_unknown "$os_name")"
printf 'user=%s uid=%s home=%s\n' "$(id -un 2>/dev/null || printf unknown)" "$(id -u 2>/dev/null || printf unknown)" "${HOME:-unknown}"
printf 'cwd=%s filesystem=%s\n' "$PWD" "$fs_type"
printf 'container=%s init=%s\n' "$container" "$init_name"
printf 'scheduler=%s\n' "$scheduler"
printf 'systemd_user=%s\n' "$systemd_user"
printf 'glibc=%s\n' "$glibc"
printf 'reserved_ports=RESERVED_PORT_1:%s RESERVED_PORT_2:%s CODE_SERVER_PORT:%s\n' \
  "${RESERVED_PORT_1:-unset}" "${RESERVED_PORT_2:-unset}" "${CODE_SERVER_PORT:-unset}"

printf 'commands='
for cmd in curl wget tar gzip xz ss lsof netstat openssl setsid npm node systemctl crontab sbatch qsub; do
  if have "$cmd"; then
    printf '%s:yes ' "$cmd"
  else
    printf '%s:no ' "$cmd"
  fi
done
printf '\n'

if [[ "$container" != "no" ]]; then
  printf 'note=Container detected; host port publication and restart policy must be configured outside the container.\n'
fi
if [[ "$scheduler" == slurm-* || "$scheduler" == pbs-* ]]; then
  printf 'note=Scheduler detected; verify site policy and prefer a compute allocation over a login-node daemon.\n'
fi
