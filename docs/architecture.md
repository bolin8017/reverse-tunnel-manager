# Architecture

## Overview

Reverse Tunnel Manager uses SSH reverse port forwarding to make machines behind
NAT or firewalls accessible. The system has three roles: remote, relay, and
client.

## Network Topology

```
                              Internet
                                 |
  remote (internal machine)      |          client (your laptop)
    |                            |               |
    |--- autossh tunnel -------->|<--- SSH -------|
    |  RemoteForward PORT        |  ProxyJump     |
    |                       relay (jump server)   |
    |                       has public IP         |
```

## Data Flow

1. **Remote to Relay** — `autossh` opens a persistent SSH connection to the
   relay with `RemoteForward TUNNEL_PORT localhost:22`. This binds
   `127.0.0.1:TUNNEL_PORT` on the relay to port 22 on the remote.

2. **Client to Remote** — The client runs `ssh my-remote`, which uses
   `ProxyJump` to first connect to the relay, then connects to
   `localhost:TUNNEL_PORT` on the relay, arriving at port 22 on the remote.

## Components

### `lib/common.sh`

Shared function library sourced by setup scripts. `setup-remote.sh` requires it;
`setup-relay.sh` and `setup-client.sh` include inline fallbacks for standalone
use. Provides:

- Colored output helpers (`info`, `warn`, `error`, `ask`)
- OS detection (`detect_os`) — sets `PLATFORM`, `OS_FAMILY`, `PKG_MGR`
- SSH config manipulation (`extract_ssh_host_block`, `remove_ssh_host_block`,
  `upsert_ssh_host_block`)
- Input validation (`validate_port`)
- Interactive prompts (`prompt_value`, `confirm_or_exit`)

### `scripts/setup-relay.sh`

Configures the relay server's `sshd_config`. Verifies settings before
modifying. Detects the SSH service name (`ssh` vs `sshd`) automatically.

### `scripts/setup-remote.sh`

Configures the internal machine. Installs `autossh`, writes SSH config,
creates a systemd user service, and verifies the tunnel is active. Only applies
changes for components that are not already correctly configured.

### `scripts/setup-client.sh`

Configures the client machine on Linux, macOS, or WSL. Writes SSH config with
`ProxyJump`, manages SSH keys, and tests the connection. Includes full inline
fallback of `lib/common.sh` for standalone use.

### `scripts/setup-client.ps1`

Windows PowerShell equivalent of `setup-client.sh`. Writes SSH config with
`ProxyJump`, manages SSH keys, and tests the connection. Supports the same
interactive parameters as the Bash version.

### `setup.sh` / `setup.ps1`

Unified entry points that present an interactive role selection menu
(relay / remote / client) with an architecture diagram, then delegate to the
appropriate role script. `setup.sh` targets Linux/macOS/WSL; `setup.ps1`
targets Windows PowerShell.

### `install.sh` / `install.ps1`

One-liner bootstrap scripts. `install.sh` uses `curl` + `tar` (or `git clone`)
to download the repo and launch `setup.sh`. `install.ps1` uses
`Invoke-WebRequest` to download and extract the repo, then launches `setup.ps1`.
Designed to be piped directly from the internet:

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

### `templates/`

- `ssh-config-relay.template` — SSH config block for the remote machine's
  connection to the relay.
- `ssh-tunnel.service.template` — systemd user service unit for `autossh`.

Templates use `{{PLACEHOLDER}}` syntax, replaced with `sed` at setup time.

## Keepalive and Reconnection

| Component | Mechanism | Timing |
|-----------|-----------|--------|
| **Relay sshd** | `ClientAliveInterval 30` + `ClientAliveCountMax 3` | Detects dead connections within ~90 s |
| **Remote SSH config** | `ServerAliveInterval 30` + `ServerAliveCountMax 3` | Remote detects relay unreachable within ~90 s |
| **Client SSH config** | `ServerAliveInterval 60` + `ServerAliveCountMax 3` | Client detects tunnel drop within ~180 s |
| **autossh** | Monitors SSH child process | Restarts on exit |
| **systemd** | `Restart=always` + `RestartSec=10` | Restarts `autossh` within 10 s |
| **loginctl linger** | Keeps user services running | Survives logout and reboot |

Worst-case reconnection time after a network interruption: ~100 seconds
(90 s detection + 10 s restart).

## Security Notes

- The reverse tunnel binds to `127.0.0.1` on the relay (not `0.0.0.0`).
  Only connections originating from or proxied through the relay can reach the
  remote machine.
- SSH key authentication is required. The scripts generate Ed25519 (default)
  or RSA-4096 keys and offer to copy them via `ssh-copy-id`.
- `ExitOnForwardFailure yes` ensures `autossh` exits cleanly if the tunnel
  port is already in use, allowing systemd to retry.
