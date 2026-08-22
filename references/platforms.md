# Platform Selection Notes

Read the section matching the detected target before deploying.

## Containers

- Install into a persistent volume if the installation and extensions must survive container recreation.
- Bind to `0.0.0.0` only when the container port is intentionally published. A host mapping such as `127.0.0.1:18080:18080` is safer than publishing on every host interface.
- `0.0.0.0` is a listen address, not a browser URL. If the host port is reached by a remote hostname or IP, terminate trusted HTTPS before code-server and pass that URL with `--external-url`.
- A background process started interactively does not survive container restart. Use `<prefix>/bin/star-coder-ctl run` as an entrypoint/Compose command, or configure the existing supervisor.
- Do not install systemd in a container solely for code-server.

## HPC And Shared Hosts

- Check site policy before running a web service. Login nodes commonly prohibit persistent or compute-heavy processes.
- Prefer a compute allocation. For Slurm, deploy with `--autostart slurm`, inspect the generated job script, add site-required account/partition/time directives, and submit it with `sbatch`.
- Bind to `127.0.0.1` and use an SSH tunnel:

  ```bash
  ssh -N -L 18080:127.0.0.1:18080 user@cluster-host
  ```

- A compute node may require a two-hop tunnel through a login host. Use `ProxyJump` or forward from the login host to the allocated node according to site documentation.
- For private tailnet access, keep code-server on loopback and publish it with Tailscale Serve HTTPS, for example `tailscale serve --https=443 http://127.0.0.1:18080`. Plain Tailscale HTTP is encrypted on the wire but is not a browser secure context.
- Scheduler jobs are not reboot services. They end at time limits and may be queued. Do not configure cron or lingering user services on a cluster unless administrators permit them.
- Home directories are often NFS-mounted. Installation there is portable but extension scanning and file watching may be slow. Prefer approved scratch/project storage for workspaces and persistent home/project storage for configuration.
- Avoid selecting a port solely from the login host when the server will run on a compute node; verify it inside the allocation.

## Native Linux With systemd

- Prefer `systemd --user` for an unprivileged deployment. It does not require a root-owned unit.
- User services may stop at logout unless lingering is enabled. `loginctl enable-linger USER` is an administrator/site-policy decision and is not performed by this skill.
- If the user bus is unavailable over a non-interactive SSH session, use manual mode or ask the user to log in normally before enabling the unit.
- Use a system-wide service only after explicit authorization and a deliberate service-account/path review.

## Cron

- Use cron only when the user explicitly selects it and local policy permits `@reboot` jobs.
- Cron inherits a minimal environment. The generated control script uses absolute paths, but network mounts or secrets may still be unavailable early in boot.
- Cron is not appropriate for ephemeral containers or most HPC clusters.

## Old glibc, musl, And Unsupported Architectures

- Official standalone builds require a compatible glibc and supported CPU architecture. Verify by executing `<prefix>/bin/code-server --version`; filename/architecture checks alone are insufficient.
- On Alpine/musl, old enterprise Linux, or an unsupported standalone platform, try `--source npm` only when a compatible Node.js/npm and native build prerequisites already exist.
- Do not automatically install compilers, Python, Node.js, or OS packages. Report missing prerequisites and ask before changing the operating system.
- For offline systems, download an official code-server release archive on a connected machine, transfer it through an approved channel, and use `--source archive --archive /path/to/archive`.

## Public Access

- code-server's built-in password over plain HTTP is not sufficient for direct public exposure.
- Bind to loopback behind an authenticated TLS reverse proxy, VPN, or zero-trust tunnel. Configure WebSocket proxying and preserve `Host`/forwarded headers according to the proxy's documentation.
- Require a browser-facing `https://` URL with a trusted certificate. Network-layer VPN encryption alone does not enable browser service workers or secure cookies.
- Keep authentication enabled even behind a proxy unless the surrounding identity and network controls have been explicitly reviewed.
