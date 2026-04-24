# Design — Pubkey Auth Flow

**Date:** 2026-04-24
**Branch:** `feat/pubkey-auth-flow`

## Problem

The current setup flow has three failure modes that leave the user stuck:

1. **Silent broken tunnel.** `setup-remote.sh` marks setup complete without
   verifying that the remote's pubkey is actually installed on the relay.
   If the key isn't in `authorized_keys` (or the relay's sshd has
   `PubkeyAuthentication no`), the systemd service starts, `autossh` keeps
   retrying, and the user sees "Setup Complete" while the tunnel never
   connects.

2. **Dead-end key generation.** Both `setup-remote.sh` and `setup-client.sh`
   either generate a key (remote) or require one (client), then tell the
   user to copy the public key to the relay themselves. Because the final
   probe uses `BatchMode=yes`, there is no opportunity to type a password,
   so the user hangs waiting for a connection that cannot succeed until
   they intervene out-of-band.

3. **Windows BOM error.** Users running a PowerShell client setup hit
   `#Requires : 無法辨識 ... #Requires 詞彙` because the file was saved as
   UTF-8-with-BOM. The U+FEFF byte before `#Requires` breaks PowerShell
   5.1's parser.

## Goals

- Remote and client setup establish working pubkey auth end-to-end, or fail
  loudly before any systemd state is touched.
- Key installation uses `ssh-copy-id` (bash) / a de-duplicating `ssh` pipe
  (PowerShell), which interactively prompts for the target host's password.
  One password prompt per host during first-time setup.
- Relay setup guarantees `PubkeyAuthentication yes` so the server side is
  never the cause of a silent failure.
- A new `scripts/setup-client.ps1` provides native Windows support, saved
  as UTF-8 without BOM.
- Re-runs stay idempotent: if pubkey auth already works, no password is
  requested, no key is re-appended.

## Non-goals

- `setup-remote.ps1` — no Windows remote-host scenario is in scope.
- `lib/common.ps1` — not needed for a single PowerShell script; extract
  later if a second PS script appears.
- Automated retry loops on wrong-password entry. `ssh-copy-id` already
  retries once internally; on a second failure the script aborts and the
  user re-runs.
- Changes to systemd / SSH config templates.

## Architecture

```
                               setup-relay.sh
                     (ensures PubkeyAuthentication yes)
                                     │
                                     ▼
   setup-remote.sh ──── ssh-copy-id ────▶ relay (authorized_keys)
          │                                         ▲
          │                                         │
          └─── autossh RemoteForward ───────────────┘
                                     
   setup-client.{sh,ps1} ── ssh-copy-id ─▶ relay (authorized_keys)
                        └── ssh-copy-id ─▶ remote (via ProxyJump)
```

Three new helpers live in `lib/common.sh` and encapsulate the verify →
install → re-verify pattern. Each setup script calls `ensure_pubkey_on_host`
once per target; idempotency and error handling live in one place.

## `lib/common.sh` — new helpers

### `verify_pubkey_auth destination port key_path [proxy_jump]`

Runs `ssh -o BatchMode=yes -o PreferredAuthentications=publickey
-o IdentitiesOnly=yes -o ConnectTimeout=10 -i <key_path> -p <port>
[-o ProxyJump=<proxy_jump>] <destination> true`. Returns 0 if pubkey auth
succeeds, non-zero otherwise. `IdentitiesOnly=yes` is critical — without
it, an unrelated agent-loaded key could give a false positive.

### `install_pubkey destination port key_path [proxy_jump]`

Thin wrapper over `ssh-copy-id -i <key_path>.pub -p <port>
[-o ProxyJump=<proxy_jump>] <destination>`. Prompts interactively for the
target password. Returns `ssh-copy-id`'s exit status.

### `ensure_pubkey_on_host label destination port key_path [proxy_jump]`

Orchestrator:

```
info "Checking pubkey auth to <label>..."
if verify ok → info "OK" → return 0
warn "not working — installing key"
info "You'll be prompted for the <label> password."
install_pubkey ... || error "ssh-copy-id failed" → return 1
if verify ok → info "verified" → return 0
error "install succeeded but probe still fails"
error "check PubkeyAuthentication / authorized_keys perms on <label>"
return 1
```

## `setup-relay.sh`

Single additive change. Append `"PubkeyAuthentication yes"` to the managed
options list in both the verify loop and the apply block:

```bash
for pair in "ClientAliveInterval 30" \
            "ClientAliveCountMax 3" \
            "AllowTcpForwarding yes" \
            "PubkeyAuthentication yes"; do
  ...
done
```

```bash
set_sshd_option "ClientAliveInterval"   "30"
set_sshd_option "ClientAliveCountMax"   "3"
set_sshd_option "AllowTcpForwarding"    "yes"
set_sshd_option "PubkeyAuthentication"  "yes"
```

Add `PubkeyAuthentication` to the completion summary table. Backup /
validate / reload flow already handles the new option.

## `setup-remote.sh`

Replace the block that prints the pubkey, shows the `ssh-copy-id` hint, and
asks "Is this key already in the relay's authorized_keys? [Y/n]" with a
single call to `ensure_pubkey_on_host`:

```bash
# (key generation block — unchanged)
if [[ "${needs_key}" == "true" ]]; then
  ssh-keygen -t ed25519 -f "${ssh_key_path}" -C "${USER}@$(hostname)-tunnel"
  ...
fi

# (pub key display — kept for debug context if install fails later)

if ! ensure_pubkey_on_host \
      "relay" \
      "${relay_user}@${relay_host}" \
      "${relay_port}" \
      "${ssh_key_path}"; then
  error "Cannot establish pubkey auth to the relay. Aborting before systemd."
  error "Check: relay has PubkeyAuthentication yes (re-run setup-relay.sh),"
  error "and that the relay user can log in."
  return 1
fi

# (SSH config + systemd — unchanged)
```

Behavioural changes:

1. Script now actually runs `ssh-copy-id` instead of telling the user to.
2. Script aborts before `systemctl enable/start` if the post-install probe
   fails — no more "Setup Complete" while autossh silently retries.
3. The "Is this key already in the relay's authorized_keys?" prompt and
   the `ssh-copy-id` hint are removed (both redundant).

## `setup-client.sh`

New responsibilities (key path prompt, optional key gen, pubkey copy to
both relay and remote):

```
1. (existing) Platform check, prompt params, summary, confirm.
2. NEW prompt: "SSH private key path" (default ~/.ssh/id_ed25519).
3. Verify current state:
     - SSH config has the "my-remote" block?
     - NEW: does the key exist at key_path?
4. If key missing: offer ssh-keygen -t ed25519 or abort.
5. Write SSH config — now with IdentityFile <key_path>.
6. NEW: ensure_pubkey_on_host "relay"  <relay_user>@<relay_host>  <relay_port>  <key_path>
7. NEW: ensure_pubkey_on_host "remote" <remote_user>@localhost    <tunnel_port> <key_path> <relay_user>@<relay_host>:<relay_port>
8. (existing) Final BatchMode test via the "my-remote" alias.
```

Step 5 is moved before the key installs so the final test can use the
alias. Step 6 must run before step 7: copying to the remote via `ProxyJump`
needs the relay pubkey already installed (`ProxyJump` uses pubkey auth, not
the password typed for the remote).

Updated expected SSH config block gains one line:

```
Host my-remote
    HostName localhost
    Port <tunnel_port>
    User <remote_user>
    IdentityFile <key_path>
    ProxyJump <relay_user>@<relay_host>:<relay_port>
    ServerAliveInterval 60
```

If either `ensure_pubkey_on_host` call fails, abort before the final test.

## `scripts/setup-client.ps1`

New file. Feature-parity with `setup-client.sh`, Windows-native.

```powershell
#Requires -Version 5.1
<# setup-client.ps1 — Windows/PowerShell port of setup-client.sh. #>

[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

# Inline helpers (no lib/common.ps1 — extract if another PS script appears):
#   Write-Info / Write-Warn / Write-Err / Read-Value / Test-Port
#   Get-SshHostBlock / Remove-SshHostBlock / Set-SshHostBlock
#   Test-PubkeyAuth / Install-Pubkey / Assert-PubkeyOnHost

function main {
  foreach ($bin in 'ssh','ssh-keygen') {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
      Write-Err "$bin not found. Install 'OpenSSH Client' via Settings > Apps > Optional Features."
      exit 1
    }
  }
  # prompt params, optional ssh-keygen, write SSH config,
  # Assert-PubkeyOnHost for relay, then for remote, then BatchMode test.
}

main
```

Implementation notes specific to PowerShell:

1. **Encoding.** Every file write uses
   `[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding $false))`.
   `Out-File -Encoding utf8` emits a BOM on PS 5.1; the `$false` argument
   to `UTF8Encoding` disables it. `scripts/setup-client.ps1` itself must
   be saved the same way.

2. **ACLs.** After writing `~/.ssh/config` (and any generated private
   keys), lock ACLs so OpenSSH accepts them:

   ```powershell
   icacls $path /inheritance:r | Out-Null
   icacls $path /grant:r "$($env:USERNAME):(R,W)" | Out-Null
   ```

3. **`Install-Pubkey` equivalent.** Windows OpenSSH doesn't ship
   `ssh-copy-id`. The PS helper pipes the pubkey over `ssh` with a POSIX
   dedup snippet executed on the target:

   ```powershell
   $pub = (Get-Content -Raw $PubKeyPath).Trim()
   $sshArgs = @('-p', $Port, '-o', 'IdentitiesOnly=yes', '-i', $KeyPath)
   if ($ProxyJump) { $sshArgs += @('-o', "ProxyJump=$ProxyJump") }
   $sshArgs += @($Destination, @'
     set -e
     mkdir -p ~/.ssh && chmod 700 ~/.ssh
     touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
     KEY=$(cat)
     if ! grep -qxF -- "$KEY" ~/.ssh/authorized_keys; then
       printf '%s\n' "$KEY" >> ~/.ssh/authorized_keys
       echo INSTALLED
     else
       echo ALREADY_PRESENT
     fi
'@)
   $pub | & ssh @sshArgs
   ```

   The pubkey is streamed over stdin rather than embedded in the command
   line, sidestepping PowerShell/sh double-quoting. `grep -qxF` dedups.

4. **Progress output** uses `Write-Host -ForegroundColor` matching the
   bash colour scheme (green/yellow/red/blue).

## Error handling summary

| Failure | Behaviour |
|---|---|
| `ssh-copy-id` fails (wrong password, unreachable) | Error printed, `return 1`. User re-runs. |
| Install succeeds but probe still fails | Error lists likely causes (`PubkeyAuthentication no`, `authorized_keys` perms, wrong user), `return 1`. |
| `setup-remote.sh` probe fails | Abort before `systemctl enable/start`. |
| `setup-client.sh` relay probe fails | Abort before remote copy. |
| `setup-client.sh` remote probe fails | Abort before final BatchMode test. |
| `setup-client.ps1`: OpenSSH Client missing | Clear error with install path, exit 1 before any prompts. |

## Idempotency

- `verify_pubkey_auth` runs every time. If pubkey already works,
  `ensure_pubkey_on_host` skips install — no password prompt, no appended
  key.
- On Windows, `grep -qxF` dedup prevents duplicate appends when
  `Install-Pubkey` is called with a key that's already present.
- `setup-relay.sh` keeps its "already-correct → skip" check; adding
  `PubkeyAuthentication yes` fits the existing pattern.

## Security

- All probes use `IdentitiesOnly=yes` to prevent unrelated agent keys from
  giving false positives.
- Private keys never leave the machine they're generated on.
- Passwords are typed directly into `ssh-copy-id` / `ssh`; never
  captured in variables or logs.
- Windows SSH config and private key files get restrictive ACLs via
  `icacls`.

## Testing plan

1. **Syntax / lint**
   - `make check` — `bash -n` on all `.sh`.
   - `make lint` — shellcheck.
   - PowerShell: `powershell -NoProfile -Command "Get-Content setup-client.ps1 | Out-Null"` parses without error.
   - BOM check: `hexdump -C scripts/setup-client.ps1 | head -1` — first
     bytes must not be `EF BB BF`. Expected: `23 52 65 71 75 69 72 65 73`
     (`#Requires`).

2. **Manual end-to-end** (three machines, user-driven)
   - **Fresh install.** No keys anywhere. Expected prompts:
     `setup-remote.sh` → 1 password (relay). `setup-client.sh` → 2
     passwords (relay, remote). `setup-client.ps1` → 2 passwords.
   - **Re-run.** All configured. Expected: zero password prompts, all
     scripts report "already configured".
   - **Relay with `PubkeyAuthentication no`.** Expected: `setup-remote.sh`
     aborts with clear error after install succeeds but probe fails.
   - **Wrong password.** Expected: `ssh-copy-id` rejects, script aborts
     cleanly.

3. **Windows**
   - Fresh run with OpenSSH Client present — full flow, two prompts.
   - `ssh.exe` missing — aborts with install instructions.
   - Committed `.ps1` file BOM check as above.
