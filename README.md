# Reverse Tunnel Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **[繁體中文文件](docs/zh-tw/README.md)**

A set of shell scripts for setting up persistent SSH reverse tunnels using
[autossh](https://www.harding.motd.ca/autossh/) and systemd. SSH into machines
behind NAT or firewalls (no public IP required) by bouncing through a relay
server.

## Architecture

```
remote (internal)  ──autossh RemoteForward──>  relay (public IP)  <──ProxyJump──  client (laptop)
```

| Role       | Description |
|------------|-------------|
| **remote** | Machine behind NAT/firewall. Runs `autossh` to maintain a persistent reverse tunnel to the relay. |
| **relay**  | Server with a public IP. Acts as a jump host. |
| **client** | Your laptop or workstation. Connects through the relay to the remote. |

## Supported Platforms

| Role       | Linux (RHEL/Rocky/CentOS/Fedora/Alma) | Linux (Ubuntu/Debian) | macOS | Windows (PowerShell) |
|------------|:--------------------------------------:|:---------------------:|:-----:|:--------------------:|
| **remote** | Yes | Yes | - | - |
| **relay**  | Yes | Yes | - | - |
| **client** | Yes | Yes | Yes | Yes |

## Quick Start

**Linux / macOS / WSL — one-liner install:**

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

**Windows PowerShell — one-liner install:**

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

The installer downloads the repo and launches an interactive role selection menu.

**If you already cloned the repo:**

```bash
bash setup.sh        # Linux / macOS / WSL
```

```powershell
.\setup.ps1          # Windows PowerShell
```

**Or run individual scripts directly:**

**Step 1** — On the relay server:

```bash
bash scripts/setup-relay.sh
```

**Step 2** — On the remote (internal) machine:

```bash
bash scripts/setup-remote.sh
```

**Step 3** — On your client (laptop):

```bash
bash scripts/setup-client.sh          # Linux / macOS / WSL
```

```powershell
.\scripts\setup-client.ps1            # Windows PowerShell
```

After setup, connect to the remote machine with:

```bash
ssh my-remote
```

See the [Getting Started Guide](docs/getting-started.md) for detailed
instructions, parameter explanations, and SSH key setup.

## Common Commands

```bash
# Remote machine — manage the tunnel service
systemctl --user status ssh-tunnel.service
systemctl --user restart ssh-tunnel.service
journalctl --user -u ssh-tunnel.service -f

# Relay — verify tunnel ports
ss -tlnp | grep sshd
```

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](docs/getting-started.md) | Detailed setup guide with prerequisites and parameters |
| [Architecture](docs/architecture.md) | System design, data flow, and port management |
| [Troubleshooting](docs/troubleshooting.md) | FAQ, common errors, debug commands, and uninstall |

All documents are also available in [繁體中文](docs/zh-tw/README.md).

## Development

```bash
make check    # Syntax-check all scripts
make lint     # Run shellcheck
```

This project follows the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).

## License

[MIT](LICENSE)
