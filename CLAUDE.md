# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Shell-based automation for setting up persistent SSH reverse tunnels via autossh and systemd. Enables SSH access to machines behind NAT/firewalls by bouncing through a relay server with a public IP.

Three scripts in `scripts/`, each run on a different machine in order:
1. `scripts/setup-relay.sh` — relay server (public IP): verifies/adjusts sshd_config
2. `scripts/setup-remote.sh` — internal machine (no public IP): installs autossh, creates systemd user service
3. `scripts/setup-client.sh` — user's laptop: writes SSH config with ProxyJump

## Architecture

```
remote (internal)  --autossh RemoteForward-->  relay (public IP)  <--ProxyJump--  client (laptop)
```

- `lib/common.sh` provides shared utilities (color output, OS detection, SSH config manipulation, interactive prompts)
- `templates/` contains SSH config and systemd service templates used by scripts/setup-remote.sh
- Scripts use `PROJECT_ROOT` to resolve paths to `lib/` and `templates/` relative to the repo root
- All scripts verify current state before making changes (verify-first pattern)
- sudo is only requested when actually needed (autossh install, sshd_config modification)

## Common Commands

```bash
make check    # Syntax-check all scripts
make lint     # Run shellcheck

bash scripts/setup-relay.sh      # on relay
bash scripts/setup-remote.sh     # on remote
bash scripts/setup-client.sh     # on client
```

## Style Guide

This project follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html):

- **Indent**: 2 spaces (no tabs)
- **main()**: all scripts wrap top-level logic in `main()`, called via `main "$@"`
- **Function docs**: `#######` block format with Globals/Arguments/Outputs/Returns
- **Constants**: declare with `readonly`; separate declaration from command substitution
- **Output**: use `printf` over `echo -e`; `warn()` and `error()` write to stderr
- **Quoting**: prefer `"${var}"` with braces
- **Validation**: use `validate_port()` for all user-supplied port values
- **Templates**: `{{PLACEHOLDER}}` syntax replaced with `sed`
- **SSH keys**: RSA-4096 for key generation

## Documentation

Bilingual docs (English + Traditional Chinese) in `docs/`:
- `docs/*.md` — English
- `docs/zh-tw/*.md` — Traditional Chinese
