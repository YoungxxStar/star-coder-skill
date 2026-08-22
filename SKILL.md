---
name: star-coder-skill
description: Interactively inspect, install, configure, start, and troubleshoot Coder code-server on varied Linux systems, including Ubuntu, Debian, RHEL-family distributions, containers, remote servers, and HPC clusters with or without root or systemd. Use when Codex needs to deploy a browser-accessible VS Code/code-server environment, choose safe paths and ports, repair a prior installation, create lifecycle scripts, configure user-level autostart, or adapt deployment to Slurm and restricted Linux environments. This skill targets code-server, not the separate Coder workspace orchestration product.
---

# Star Coder Deploy

Deploy code-server only after inspecting the target and collecting the user's deployment choices. Prefer a user-writable, self-contained installation and make every generated service reversible.

## Workflow

1. Run `scripts/inspect-environment.sh` before asking questions. Treat it as read-only evidence, not authorization to install.
2. Read `references/platforms.md` when the target is an HPC cluster, container, old Linux distribution, musl system, shared host, or lacks systemd. Read `references/troubleshooting.md` after any failed check or when repairing an installation.
3. Ask one grouped round containing at most the eight questions below. Omit questions already answered by the user. Show detected values and a recommended default so the user can answer compactly. Do not mutate the system before receiving the answers unless the user explicitly requests recommended defaults.
4. Summarize the resolved non-secret configuration, including the internal bind address, browser-facing URL, and TLS terminator. Warn before binding to a public interface, disabling authentication, writing a system-wide service, or running on an HPC login node.
5. Run `scripts/deploy-code-server.sh` with explicit options. Use `--dry-run` first when paths, permissions, service policy, or platform compatibility remain uncertain.
6. Verify the generated status command and local HTTP health endpoint. For any browser URL that is not localhost, also verify a trusted HTTPS entrypoint. Report the access URL or SSH tunnel, password retrieval location, control commands, log path, and whether startup survives reboot/container recreation.

## Core Questions

Ask no more than these eight deployment questions. Combine related details in one numbered item and accept `recommended` as an answer.

1. What is the deployment context: normal Linux host, Docker/container, HPC login node, HPC compute allocation, or other restricted environment?
2. What absolute installation prefix should contain the program, configuration, logs, PID, and control scripts?
3. Which existing directory should code-server open as its default workspace?
4. Install the latest release, pin a version, reuse an existing binary, use an offline release archive, or use npm for a platform incompatible with standalone releases?
5. How will it be accessed: localhost, SSH tunnel, container host-port mapping, trusted TLS reverse proxy, Tailscale Serve, or another gateway? Resolve the internal bind address, browser-facing URL, and TLS terminator separately. Default to `127.0.0.1`; use `0.0.0.0` only when container/LAN forwarding requires it.
6. Which port should be used? Consider scheduler/container-provided reserved-port variables and verify availability; default to an available port beginning with `18080`.
7. Should the existing password be preserved, should a strong password be generated, or will the user provide one? Never echo a supplied password or place it in command arguments.
8. What lifecycle is desired: manual background start, `systemd --user`, explicit cron `@reboot`, scheduler job such as Slurm, container-managed startup, or automatic safe selection?

## Defaults And Safety

- Recommend `${HOME}/.local/opt/star-code-server` as the prefix when it is writable. Do not repurpose a broad system directory such as `/`, `/usr`, `/etc`, or the user's home directory itself as the managed prefix.
- Preserve an existing valid installation and password unless replacement was requested. Use `--upgrade` only when requested.
- Use password authentication. Do not configure `auth: none` through this skill.
- Use an interactive TTY with `--password-mode prompt` for a user-supplied password. Feed the already supplied secret to stdin; never interpolate it into the shell command. Use `preserve-or-generate` otherwise.
- Never invoke `sudo`, install OS packages, edit firewall rules, or create a system-wide unit without separate explicit authorization.
- Never kill by a broad process pattern. Use only the generated PID file and verify the process command line before stopping it.
- Never expose plain HTTP directly to the public internet. Require a trusted TLS reverse proxy, VPN, or SSH tunnel.
- A VPN does not make a remote `http://` URL a browser secure context. Remote hostname/IP access must use a trusted `https://` endpoint so code-server webviews, service workers, media previews, and secure cookies work. HTTP is acceptable only for localhost/SSH-tunnel access or as a loopback backend behind TLS termination.
- Do not solve webview failures with an untrusted self-signed certificate. Prefer a publicly trusted certificate, Tailscale Serve HTTPS, or another trusted TLS endpoint.
- On HPC, respect site policy. Prefer a compute allocation and scheduler script. Do not promise reboot persistence for scheduler jobs or login-node processes.
- Treat container autostart as an orchestrator concern. Return the generated foreground command for an entrypoint, Compose command, or Kubernetes manifest.

## Deployment Command

Run from the skill directory. Pass all resolved non-secret values explicitly:

```bash
bash scripts/deploy-code-server.sh \
  --context container \
  --prefix /home/user/.local/opt/star-code-server \
  --workspace /work/project \
  --version latest \
  --source auto \
  --bind 0.0.0.0 \
  --port 18080 \
  --external-url https://coder.example.com \
  --password-mode preserve-or-generate \
  --autostart manual
```

For a supplied secret, launch the same command in a TTY with `--password-mode prompt`. For an offline release add `--source archive --archive /absolute/path/code-server.tar.gz`. Use `--no-start` to configure without starting and `--dry-run` for a preflight-only pass.

## Completion Checks

Require all applicable checks before reporting success:

- `<prefix>/bin/code-server --version` succeeds.
- `<prefix>/etc/code-server/config.yaml` exists with mode `0600`.
- `<prefix>/bin/star-coder-ctl status` succeeds after a manual or service start.
- `curl` or `wget` reaches `/healthz` through the local health address.
- A non-local browser endpoint uses trusted HTTPS, and a webview-based preview loads through it.
- The chosen port belongs to the expected code-server process.
- Generated start, stop, restart, status, logs, and foreground commands are executable.
- Autostart status is verified rather than inferred. For Slurm/container modes, report the generated command as pending external scheduling/orchestration.

If verification fails, preserve logs and configuration, avoid repeated blind reinstalls, and diagnose using `references/troubleshooting.md`.
