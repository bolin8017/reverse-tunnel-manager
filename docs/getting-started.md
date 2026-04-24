# Getting Started

This guide walks through setting up a persistent SSH reverse tunnel from an
internal machine to a relay server, and configuring a client to connect through
it.

## One-Liner Install (Recommended)

**Linux / macOS / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

The installer downloads the repo and launches an interactive role selection menu.
If you have already cloned the repo, run `bash setup.sh` (Linux/macOS/WSL) or
`.\setup.ps1` (Windows PowerShell) directly.

## Prerequisites

### Remote machine

- Linux (RHEL, Rocky, CentOS, Fedora, AlmaLinux, Ubuntu, or Debian)
- `sudo` access (only required if `autossh` is not yet installed)
- SSH key pair (the script can generate one)
- Network access to the relay server

### Relay server

- Linux (RHEL, Rocky, CentOS, Fedora, AlmaLinux, Ubuntu, or Debian)
- `sshd` running with a public IP address
- `sudo` access (only required if `sshd_config` settings need to change)

### Client machine

- Linux, macOS, Windows 10+ (with built-in OpenSSH), or Windows (WSL)
- SSH client (`ssh` command available)
- SSH key pair (the script can generate one)
- Network access to the relay server

## Step 1: Configure the Relay Server

Run on the **relay** machine. The script checks `sshd_config` and applies
changes only if needed.

```bash
bash scripts/setup-relay.sh
```

**What it does:**

1. Reads `/etc/ssh/sshd_config` and verifies four settings:

   | Option                 | Value | Purpose |
   |------------------------|-------|---------|
   | `ClientAliveInterval`  | `30`  | Send keepalive every 30 seconds |
   | `ClientAliveCountMax`  | `3`   | Drop connection after 3 missed keepalives (~90 s) |
   | `AllowTcpForwarding`   | `yes` | Required for `RemoteForward` to work |
   | `PubkeyAuthentication` | `yes` | Required for pubkey-based tunnel authentication |

2. If all settings are correct, reports success without requiring `sudo`.
3. If changes are needed, requests `sudo` to modify, validate, and reload `sshd`.
4. Automatically detects the SSH service name (`ssh` on Ubuntu/Debian, `sshd` on
   RHEL).

**No sudo available?** The script shows the required settings. Ask your system
administrator to apply them, then re-run the script to verify.

## Step 2: Set Up the Remote Machine

Run on the **remote** (internal) machine. The script collects parameters
interactively.

```bash
bash scripts/setup-remote.sh
```

### Parameters

| Parameter                   | Default              | Description |
|-----------------------------|----------------------|-------------|
| Relay server IP or hostname | *(required)*         | Public IP or hostname of the relay |
| Relay SSH port              | `22`                 | SSH port on the relay |
| Relay username              | `$USER`              | Your username on the relay |
| Reverse tunnel port         | *(required)*         | Port exposed on the relay for this machine (must be unique) |
| Local SSH port              | `22`                 | SSH port on this machine |
| SSH private key path        | `~/.ssh/id_rsa`      | Key for authenticating to the relay |

### What it does

1. **Verifies current state** — checks if `autossh`, SSH key, SSH config, and
   the systemd service are already configured. If everything is correct, reports
   success and exits.
2. **Installs autossh** — only if not already installed. This is the only step
   that requires `sudo`.
3. **SSH key handling** — checks if the key exists. Offers to generate an
   Ed25519 (default) or RSA-4096 key if missing.
4. **Verifies relay access** — tests SSH authentication to the relay. If it
   fails, offers to run `ssh-copy-id` automatically.
5. **SSH config** — writes a `relay-tunnel` Host block to `~/.ssh/config`
   using the template in `templates/ssh-config-relay.template`.
6. **systemd user service** — creates `~/.config/systemd/user/ssh-tunnel.service`,
   enables it, and starts it. Enables `loginctl linger` so the tunnel persists
   across logouts and reboots.
7. **Legacy cleanup** — detects and offers to remove old SSH-related crontab
   entries and zombie `ssh -Nf` processes.
8. **Verification** — confirms the service is active.

## Step 3: Configure the Client

Run on your **client** machine (laptop, workstation).

```bash
bash scripts/setup-client.sh          # Linux / macOS / WSL
```

```powershell
.\scripts\setup-client.ps1            # Windows PowerShell
```

### Parameters

| Parameter                        | Default         | Description |
|----------------------------------|-----------------|-------------|
| Relay server IP or hostname      | *(required)*    | Public IP or hostname of the relay |
| Relay SSH port                   | `22`            | SSH port on the relay |
| Relay username                   | `$USER`         | Your username on the relay |
| Reverse tunnel port              | *(required)*    | The port set on the remote machine |
| Remote machine username          | `$USER`         | Your username on the remote machine |
| SSH private key path             | `~/.ssh/id_rsa` | Key for authenticating to the relay |
| SSH config Host alias            | `my-remote`     | Alias for the connection |

### What it does

1. **Platform check** — detects the OS. Runs natively on Linux, macOS, and
   Windows PowerShell (`setup-client.ps1`).
2. **Verifies current state** — checks if the SSH config block already exists
   and is correct. If everything is configured, skips directly to the
   connection test.
3. **SSH key handling** — checks if the key exists. Offers to generate an
   Ed25519 (default) or RSA-4096 key if missing.
4. **Verifies relay access** — tests SSH authentication. If it fails, offers to
   run `ssh-copy-id` automatically.
5. **SSH config** — writes a Host block using `ProxyJump` for seamless
   multi-hop SSH (only if the block needs to be created or updated).
6. **Connection test** — attempts `ssh <alias>` to verify end-to-end
   connectivity.

### Connecting

After setup, connect to the remote machine at any time with:

```bash
ssh my-remote
```

## Port Assignment

Each remote machine must use a **unique tunnel port** on the relay. Keep track
of assignments to avoid conflicts:

| User / Machine      | Tunnel Port | Notes |
|----------------------|-------------|-------|
| alice — workstation  | `52022`     | Primary work machine |
| alice — lab-server   | `52023`     | Secondary machine |
| bob — desktop        | `52100`     | Different user, different range |

The scripts do not enforce uniqueness. If two machines bind the same port, the
second one fails with `remote port forwarding failed`.

## Installation Without Git

If `git` is not available, the one-liner installer handles this automatically —
it downloads and extracts the repo using `curl` (Linux/macOS/WSL) or
`Invoke-WebRequest` (Windows PowerShell) without requiring `git`. See the
[One-Liner Install](#one-liner-install-recommended) section at the top of this
guide.
