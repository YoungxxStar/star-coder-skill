# Troubleshooting Guide

Diagnose before reinstalling. Preserve `<prefix>/var/log/code-server.log` and the generated configuration.

## Binary Exits Immediately

- Run `<prefix>/bin/code-server --version` and inspect loader errors.
- `GLIBC_* not found` or `GLIBCXX_* not found` means the standalone build is incompatible. Use a newer host/container, an approved offline compatible build, or npm with an already compatible Node toolchain.
- `Exec format error` means the release architecture does not match `uname -m`.
- On VS Code Remote sessions, remove `VSCODE_IPC_HOOK_CLI`. The generated controller already unsets it.

## Port Or Health Check Fails

- Run `ss -ltnp`, `lsof -i`, or `netstat -ltnp` when available and identify the owner before changing ports.
- Inspect `<prefix>/var/log/code-server.log`; do not kill an unrelated listener.
- Confirm the configured bind address exists in the current network namespace. Container host ports are not the same as container ports.
- For `0.0.0.0`, probe health through `127.0.0.1`. For IPv6 loopback, use `http://[::1]:PORT/healthz`.
- Firewalls, cloud security groups, scheduler node isolation, and host port publishing are outside code-server configuration.

## Service Does Not Survive Reboot Or Logout

- `manual` mode is intentionally not reboot-persistent.
- Verify `systemctl --user status star-code-server.service`; do not infer success from the unit file existing.
- Check whether the user manager survives logout and whether lingering is permitted.
- In a container, configure the orchestrator to execute `<prefix>/bin/star-coder-ctl run` and apply its restart policy.
- In Slurm/PBS, request another allocation or configure an approved recurring workflow; a scheduler job is not a boot service.

## Broken Symlinks Or Interrupted Upgrade

- Resolve links with `readlink -f` and compare their target with the selected prefix.
- Remove or replace only links inside the selected managed prefix, or a user-level link whose existing target is demonstrably within that prefix.
- Never recursively clean `$HOME`, `.local`, `/usr`, or another shared prefix.
- Re-run with `--upgrade` only after confirming the prefix belongs to this deployment.

## Workspace And Extensions

- Verify the workspace exists and is searchable by the deployment user. Use `--create-workspace` only when creating it is intended.
- NFS/Lustre/GPFS metadata latency can make extension scanning and file watching expensive. Keep large generated trees out of the workspace and follow site storage guidance.
- Multiple projects can share one code-server process by using a multi-root `.code-workspace`; separate servers isolate sessions but usually duplicate extension-host memory. User-level extension directories may still be shared if deliberately configured.

## Blank PNG, PDF, Or Webview Preview

- Confirm the browser address starts with trusted `https://`, or with `http://localhost` through an SSH tunnel. A remote `http://IP:PORT` or `http://hostname` URL is not a secure context even when traffic crosses a VPN.
- Browser webviews depend on service workers. If code and Markdown text load but image/PDF previews stay blank, inspect the browser console for service-worker or secure-context errors before reinstalling extensions.
- `0.0.0.0` is only a server listen address. Put a trusted TLS reverse proxy or Tailscale Serve HTTPS in front of it and keep the local health check on HTTP.
- Avoid untrusted self-signed certificates for browser webviews. Use a certificate the browser trusts and preserve WebSocket upgrade, `Host`, and forwarded scheme headers at the proxy.

## Password And Configuration

- The code-server YAML configuration contains the password and must remain mode `0600`.
- Preserve an existing password unless rotation was requested. Use prompt mode for a supplied password and avoid command-line arguments or shell history.
- If a reverse proxy loops at login, check WebSocket support, cookies, scheme forwarding, and the external URL path.
