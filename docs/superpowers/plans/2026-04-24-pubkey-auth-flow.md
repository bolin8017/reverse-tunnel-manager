# Pubkey Auth Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add verify-first pubkey install to the setup scripts so first-run setups don't hang silently, guarantee the relay's sshd has `PubkeyAuthentication yes`, and ship a native Windows PowerShell client script that's UTF-8 without BOM.

**Architecture:** Three new helper functions in `lib/common.sh` (`verify_pubkey_auth`, `install_pubkey`, `ensure_pubkey_on_host`) centralize the probe → `ssh-copy-id` → re-probe pattern. `setup-relay.sh` adds `PubkeyAuthentication yes` to its managed sshd options. `setup-remote.sh` and `setup-client.sh` call `ensure_pubkey_on_host` and abort before any systemd / final-test step if pubkey auth cannot be established. `scripts/setup-client.ps1` is a new Windows-native port that substitutes a `Get-Content | ssh` dedup pipe for `ssh-copy-id` (which Windows OpenSSH doesn't ship).

**Tech Stack:** Bash 4+, OpenSSH (`ssh`, `ssh-copy-id`, `ssh-keygen`), systemd user services, autossh, PowerShell 5.1+ with built-in Windows OpenSSH Client.

**Spec:** `docs/superpowers/specs/2026-04-24-pubkey-auth-flow-design.md`

**Branch:** `feat/pubkey-auth-flow`

---

## File Structure

### Files to modify

- `lib/common.sh` — add 3 pubkey helpers at the end of the file, after
  `confirm_or_exit`. Each helper is independent and ~20 lines. The file
  stays under 400 lines.

- `scripts/setup-relay.sh` — additive: one more entry in the managed
  sshd options list (touches 3 locations: verify loop, else branch, apply
  block, two summary tables).

- `scripts/setup-remote.sh` — replace one ~25-line "show pub key + ask if
  it's installed" block with a ~10-line `ensure_pubkey_on_host` call.

- `scripts/setup-client.sh` — grows by ~60 lines (key path prompt, key
  generation, `IdentityFile` in config template, two
  `ensure_pubkey_on_host` calls, inline fallback copies of the 3 new
  helpers matching the existing pattern).

- `README.md` — one new paragraph in the Usage section noting the new
  password-prompt step, and one note in Troubleshooting about the PS BOM.

### Files to create

- `scripts/setup-client.ps1` — new ~260-line PowerShell script, UTF-8
  *without* BOM. Feature-parity with `setup-client.sh` for Windows.

- `docs/superpowers/plans/2026-04-24-pubkey-auth-flow.md` — this plan (already exists by the time tasks begin).

### Files to delete

None.

---

### Task 1: Add `verify_pubkey_auth` helper to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (append after the last function)

- [ ] **Step 1: Add the function**

Append to `lib/common.sh` (after `confirm_or_exit`):

```bash

#######################################
# Test pubkey authentication to a host using a specific key.
# Uses BatchMode (never prompts) and IdentitiesOnly=yes (ignores other
# keys that may be loaded in ssh-agent) so a false positive from an
# unrelated key is not possible. Accepts unknown host keys on first
# contact via StrictHostKeyChecking=accept-new.
# Arguments:
#   destination — user@host.
#   port        — SSH port.
#   key_path    — private key path.
#   proxy_jump  — optional "user@host:port" for ProxyJump (may be empty).
# Returns:
#   0 if pubkey auth succeeds, non-zero otherwise.
#######################################
verify_pubkey_auth() {
  local destination="$1"
  local port="$2"
  local key_path="$3"
  local proxy_jump="${4:-}"

  local -a ssh_opts=(
    -o BatchMode=yes
    -o PreferredAuthentications=publickey
    -o IdentitiesOnly=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -i "${key_path}"
    -p "${port}"
  )
  if [[ -n "${proxy_jump}" ]]; then
    ssh_opts+=(-o "ProxyJump=${proxy_jump}")
  fi

  ssh "${ssh_opts[@]}" "${destination}" true 2>/dev/null
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/common.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck lib/common.sh`
Expected: no new warnings introduced by this change.

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "$(cat <<'EOF'
feat(common): add verify_pubkey_auth helper

Probe helper that tests pubkey-only SSH auth with BatchMode and
IdentitiesOnly to avoid false positives from agent-loaded keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `install_pubkey` helper to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (append after `verify_pubkey_auth`)

- [ ] **Step 1: Add the function**

Append:

```bash

#######################################
# Install a public key on a remote host via ssh-copy-id.
# Prompts interactively for the target host's password.
# Arguments:
#   destination — user@host.
#   port        — SSH port.
#   key_path    — private key path (public key is ${key_path}.pub).
#   proxy_jump  — optional "user@host:port" for ProxyJump (may be empty).
# Returns:
#   ssh-copy-id's exit status.
#######################################
install_pubkey() {
  local destination="$1"
  local port="$2"
  local key_path="$3"
  local proxy_jump="${4:-}"

  local -a opts=(-i "${key_path}.pub" -p "${port}")
  if [[ -n "${proxy_jump}" ]]; then
    opts+=(-o "ProxyJump=${proxy_jump}")
  fi

  ssh-copy-id "${opts[@]}" "${destination}"
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/common.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck lib/common.sh`
Expected: no new warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "$(cat <<'EOF'
feat(common): add install_pubkey helper

Thin wrapper over ssh-copy-id that adds optional ProxyJump support.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `ensure_pubkey_on_host` orchestrator to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (append after `install_pubkey`)

- [ ] **Step 1: Add the function**

Append:

```bash

#######################################
# Ensure pubkey auth to a host works: probe → install if needed → probe
# again. Idempotent: a host that already works needs no password prompt.
# Arguments:
#   label       — human-readable label for logs (e.g., "relay", "remote").
#   destination — user@host.
#   port        — SSH port.
#   key_path    — private key path.
#   proxy_jump  — optional "user@host:port" for ProxyJump (may be empty).
# Outputs:
#   Progress messages via info / warn / error.
# Returns:
#   0 if pubkey auth is working at the end; 1 if still failing.
#######################################
ensure_pubkey_on_host() {
  local label="$1"
  local destination="$2"
  local port="$3"
  local key_path="$4"
  local proxy_jump="${5:-}"

  info "Checking pubkey auth to ${label} (${destination})..."
  if verify_pubkey_auth "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
    info "Pubkey auth to ${label} — OK"
    return 0
  fi

  warn "Pubkey auth to ${label} not working — installing key now."
  info "You will be prompted for the ${label} password (for ssh-copy-id)."
  if ! install_pubkey "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
    error "ssh-copy-id failed for ${label} (${destination})."
    error "Verify the password and network reachability, then re-run."
    return 1
  fi

  if verify_pubkey_auth "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
    info "Pubkey auth to ${label} — verified"
    return 0
  fi

  error "Key installed on ${label}, but pubkey auth still fails."
  error "Possible causes:"
  error "  1. ${label} sshd has PubkeyAuthentication no — re-run setup-relay.sh on the relay."
  error "  2. ~/.ssh or ~/.ssh/authorized_keys permissions too loose on ${label}."
  error "  3. sshd is restricting the user (AllowUsers / Match block)."
  return 1
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/common.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck lib/common.sh`
Expected: no new warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "$(cat <<'EOF'
feat(common): add ensure_pubkey_on_host orchestrator

Verify-first helper: probes pubkey auth, runs ssh-copy-id only if the
probe fails, then re-probes. Idempotent re-runs emit no password prompt.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Enforce `PubkeyAuthentication yes` in `setup-relay.sh`

**Files:**
- Modify: `scripts/setup-relay.sh:109` (verify-loop pair list)
- Modify: `scripts/setup-relay.sh:122` (else-branch missing_settings)
- Modify: `scripts/setup-relay.sh:134-136` (already-set summary)
- Modify: `scripts/setup-relay.sh:187-189` (apply block)
- Modify: `scripts/setup-relay.sh:219-222` (post-apply summary)

- [ ] **Step 1: Extend the verify-loop pair list**

Change line 109 from:

```bash
    for pair in "ClientAliveInterval 30" "ClientAliveCountMax 3" "AllowTcpForwarding yes"; do
```

to:

```bash
    for pair in "ClientAliveInterval 30" \
                "ClientAliveCountMax 3" \
                "AllowTcpForwarding yes" \
                "PubkeyAuthentication yes"; do
```

- [ ] **Step 2: Extend the else-branch missing_settings**

Change line 122 from:

```bash
    missing_settings+=("ClientAliveInterval 30" "ClientAliveCountMax 3" "AllowTcpForwarding yes")
```

to:

```bash
    missing_settings+=( \
      "ClientAliveInterval 30" \
      "ClientAliveCountMax 3" \
      "AllowTcpForwarding yes" \
      "PubkeyAuthentication yes" \
    )
```

- [ ] **Step 3: Extend the already-set summary table (around line 134)**

Add after the `"AllowTcpForwarding"` line in the all-correct summary:

```bash
    printf '  %-24s : %s\n' "PubkeyAuthentication"  "yes"
```

So the block reads:

```bash
    printf '  %-24s : %s\n' "Config file"          "${SSHD_CONFIG}"
    printf '  %-24s : %s\n' "ClientAliveInterval"   "30"
    printf '  %-24s : %s\n' "ClientAliveCountMax"   "3"
    printf '  %-24s : %s\n' "AllowTcpForwarding"    "yes"
    printf '  %-24s : %s\n' "PubkeyAuthentication"  "yes"
```

- [ ] **Step 4: Extend the apply block**

Add after line 189:

```bash
  set_sshd_option "PubkeyAuthentication" "yes"
```

So the block reads:

```bash
  set_sshd_option "ClientAliveInterval" "30"
  set_sshd_option "ClientAliveCountMax" "3"
  set_sshd_option "AllowTcpForwarding"  "yes"
  set_sshd_option "PubkeyAuthentication" "yes"
```

- [ ] **Step 5: Extend the post-apply summary table (around line 219)**

Add after the `"AllowTcpForwarding"` line:

```bash
  printf '  %-24s : %s\n' "PubkeyAuthentication"  "yes"
```

- [ ] **Step 6: Syntax-check**

Run: `bash -n scripts/setup-relay.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Shellcheck**

Run: `shellcheck scripts/setup-relay.sh`
Expected: no new warnings.

- [ ] **Step 8: Commit**

```bash
git add scripts/setup-relay.sh
git commit -m "$(cat <<'EOF'
feat(relay): enforce PubkeyAuthentication yes

Adds PubkeyAuthentication to the managed sshd options so the relay
cannot silently reject pubkey auth after setup-remote / setup-client
have installed keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `ensure_pubkey_on_host` into `setup-remote.sh`

**Files:**
- Modify: `scripts/setup-remote.sh:261-276` (replace "show & confirm" block)

- [ ] **Step 1: Replace the confirmation prompt block**

Locate this block in `scripts/setup-remote.sh` (approximately lines 261-276):

```bash
  echo ""
  info "Your public key (add this to ${relay_user}@${relay_host}:~/.ssh/authorized_keys):"
  echo "---"
  echo "${pub_key}"
  echo "---"
  echo ""
  info "You can copy it with:"
  echo "  ssh-copy-id -i ${ssh_key_path} -p ${relay_port} ${relay_user}@${relay_host}"
  echo ""

  ask "Is this key already in the relay's authorized_keys? [Y/n] "
  read -r key_confirmed
  if [[ "${key_confirmed}" =~ ^[Nn]$ ]]; then
    info "Please add the public key to the relay server, then re-run this script."
    return 0
  fi
```

Replace with:

```bash
  echo ""
  info "Public key that will be installed on the relay:"
  echo "---"
  echo "${pub_key}"
  echo "---"
  echo ""

  # Verify-first pubkey install on the relay. Abort before systemd if
  # auth cannot be established, so the tunnel is never left silently
  # retrying behind a "Setup Complete" message.
  if ! ensure_pubkey_on_host \
        "relay" \
        "${relay_user}@${relay_host}" \
        "${relay_port}" \
        "${ssh_key_path}"; then
    error "Cannot establish pubkey auth to the relay. Aborting before systemd."
    error "Re-run setup-relay.sh on the relay to ensure PubkeyAuthentication yes,"
    error "or confirm ${relay_user} can log in, then re-run this script."
    return 1
  fi
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/setup-remote.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck scripts/setup-remote.sh`
Expected: no new warnings.

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-remote.sh
git commit -m "$(cat <<'EOF'
feat(remote): install pubkey on relay and abort on auth failure

Replaces the "did you copy the key?" prompt with a verify-first
ensure_pubkey_on_host call. ssh-copy-id prompts for the relay password
once; on verify failure the script aborts before touching systemd so
users no longer see "Setup Complete" while autossh silently retries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add key setup and pubkey install to `setup-client.sh`

**Files:**
- Modify: `scripts/setup-client.sh` — inline fallback block (add 3 helper functions matching the pattern) and main flow (add key prompt, key gen, IdentityFile, two `ensure_pubkey_on_host` calls).

- [ ] **Step 1: Extend inline fallback block with new helpers**

In the `else` branch (after `confirm_or_exit`, before the closing `fi` at around line 226), insert:

```bash

  #######################################
  # Test pubkey authentication to a host using a specific key.
  # Arguments: destination port key_path [proxy_jump].
  # Returns: 0 on pubkey auth success, non-zero otherwise.
  #######################################
  verify_pubkey_auth() {
    local destination="$1"
    local port="$2"
    local key_path="$3"
    local proxy_jump="${4:-}"

    local -a ssh_opts=(
      -o BatchMode=yes
      -o PreferredAuthentications=publickey
      -o IdentitiesOnly=yes
      -o ConnectTimeout=10
      -o StrictHostKeyChecking=accept-new
      -i "${key_path}"
      -p "${port}"
    )
    if [[ -n "${proxy_jump}" ]]; then
      ssh_opts+=(-o "ProxyJump=${proxy_jump}")
    fi

    ssh "${ssh_opts[@]}" "${destination}" true 2>/dev/null
  }

  #######################################
  # Install a pubkey on a remote host via ssh-copy-id.
  # Arguments: destination port key_path [proxy_jump].
  #######################################
  install_pubkey() {
    local destination="$1"
    local port="$2"
    local key_path="$3"
    local proxy_jump="${4:-}"

    local -a opts=(-i "${key_path}.pub" -p "${port}")
    if [[ -n "${proxy_jump}" ]]; then
      opts+=(-o "ProxyJump=${proxy_jump}")
    fi

    ssh-copy-id "${opts[@]}" "${destination}"
  }

  #######################################
  # Ensure pubkey auth works: probe, install if needed, re-probe.
  # Arguments: label destination port key_path [proxy_jump].
  # Returns: 0 on success, 1 otherwise.
  #######################################
  ensure_pubkey_on_host() {
    local label="$1"
    local destination="$2"
    local port="$3"
    local key_path="$4"
    local proxy_jump="${5:-}"

    info "Checking pubkey auth to ${label} (${destination})..."
    if verify_pubkey_auth "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
      info "Pubkey auth to ${label} — OK"
      return 0
    fi

    warn "Pubkey auth to ${label} not working — installing key now."
    info "You will be prompted for the ${label} password (for ssh-copy-id)."
    if ! install_pubkey "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
      error "ssh-copy-id failed for ${label} (${destination})."
      error "Verify the password and network reachability, then re-run."
      return 1
    fi

    if verify_pubkey_auth "${destination}" "${port}" "${key_path}" "${proxy_jump}"; then
      info "Pubkey auth to ${label} — verified"
      return 0
    fi

    error "Key installed on ${label}, but pubkey auth still fails."
    error "Possible causes:"
    error "  1. ${label} sshd has PubkeyAuthentication no — re-run setup-relay.sh on the relay."
    error "  2. ~/.ssh or ~/.ssh/authorized_keys permissions too loose on ${label}."
    error "  3. sshd is restricting the user (AllowUsers / Match block)."
    return 1
  }
```

- [ ] **Step 2: Add SSH key path prompt to main flow**

In `main`, after the `SSH config Host alias` prompt (around line 279):

```bash
  prompt_value "SSH config Host alias" "my-remote"
  local connection_name="${REPLY}"
```

Insert:

```bash

  prompt_value "SSH private key path" "${HOME}/.ssh/id_ed25519"
  local ssh_key_path="${REPLY}"
```

- [ ] **Step 3: Extend the summary table**

Change the `print_summary` call to include `"SSH Key Path"`:

```bash
  print_summary \
    "Relay Host"      "${relay_host}" \
    "Relay Port"      "${relay_port}" \
    "Relay User"      "${relay_user}" \
    "Tunnel Port"     "${tunnel_port}" \
    "Remote User"     "${remote_user}" \
    "Connection Name" "${connection_name}" \
    "SSH Key Path"    "${ssh_key_path}"
```

- [ ] **Step 4: Add `IdentityFile` line to the expected config block**

Change the existing `expected_block` from:

```bash
  local expected_block="Host ${connection_name}
    HostName localhost
    Port ${tunnel_port}
    User ${remote_user}
    ProxyJump ${relay_user}@${relay_host}:${relay_port}
    ServerAliveInterval 60"
```

to:

```bash
  local expected_block="Host ${connection_name}
    HostName localhost
    Port ${tunnel_port}
    User ${remote_user}
    IdentityFile ${ssh_key_path}
    ProxyJump ${relay_user}@${relay_host}:${relay_port}
    ServerAliveInterval 60"
```

- [ ] **Step 5: Add SSH key existence check**

Just before `info "Verifying current configuration..."`, add a tracker
variable and replace the `info`-line-then-config-check with a combined
block:

Change from:

```bash
  local needs_ssh_config=false
  local existing_block=""

  info "Verifying current configuration..."
  if existing_block=$(extract_ssh_host_block "${HOME}/.ssh/config" "${connection_name}" 2>/dev/null); then
```

to:

```bash
  local needs_ssh_config=false
  local needs_key=false
  local existing_block=""

  info "Verifying current configuration..."

  # SSH key existence.
  if [[ -f "${ssh_key_path}" ]]; then
    info "SSH key — found at ${ssh_key_path}"
  else
    warn "SSH key — not found at ${ssh_key_path}"
    needs_key=true
  fi

  # SSH config block.
  if existing_block=$(extract_ssh_host_block "${HOME}/.ssh/config" "${connection_name}" 2>/dev/null); then
```

- [ ] **Step 6: Add key generation after verification block**

After the SSH config verify-and-maybe-write block ends, and **before**
the connection test, insert:

```bash

  # -----------------------------------------------------------------
  # Generate SSH key if missing
  # -----------------------------------------------------------------
  if [[ "${needs_key}" == "true" ]]; then
    ask "Generate a new ed25519 key at ${ssh_key_path}? [y/N] "
    read -r gen_answer
    if [[ "${gen_answer}" =~ ^[Yy]$ ]]; then
      mkdir -p "$(dirname "${ssh_key_path}")"
      chmod 700 "$(dirname "${ssh_key_path}")"
      ssh-keygen -t ed25519 -f "${ssh_key_path}" -C "${USER}@$(hostname)-client"
      if [[ ! -f "${ssh_key_path}" ]]; then
        error "Key generation failed."
        return 1
      fi
      info "New SSH key generated: ${ssh_key_path}"
    else
      error "An SSH key is required. Exiting."
      return 1
    fi
  fi

  # -----------------------------------------------------------------
  # Install pubkey on relay (prompts for relay password if needed)
  # -----------------------------------------------------------------
  if ! ensure_pubkey_on_host \
        "relay" \
        "${relay_user}@${relay_host}" \
        "${relay_port}" \
        "${ssh_key_path}"; then
    error "Cannot establish pubkey auth to the relay. Aborting."
    return 1
  fi

  # -----------------------------------------------------------------
  # Install pubkey on remote (via ProxyJump through the relay)
  # -----------------------------------------------------------------
  if ! ensure_pubkey_on_host \
        "remote" \
        "${remote_user}@localhost" \
        "${tunnel_port}" \
        "${ssh_key_path}" \
        "${relay_user}@${relay_host}:${relay_port}"; then
    error "Cannot establish pubkey auth to the remote."
    error "Verify the remote's reverse tunnel is active (run setup-remote.sh on it)."
    return 1
  fi
```

- [ ] **Step 7: Syntax-check**

Run: `bash -n scripts/setup-client.sh`
Expected: no output, exit 0.

- [ ] **Step 8: Shellcheck**

Run: `shellcheck scripts/setup-client.sh`
Expected: no new warnings.

- [ ] **Step 9: Sanity-diff the full script**

Run: `git diff --stat scripts/setup-client.sh`
Expected: `scripts/setup-client.sh | ~150 insertions(+), ~5 deletions(-)`
(approximate — the key check is that only `setup-client.sh` is touched).

- [ ] **Step 10: Commit**

```bash
git add scripts/setup-client.sh
git commit -m "$(cat <<'EOF'
feat(client): add key setup and pubkey install on relay + remote

Prompts for a key path (default ~/.ssh/id_ed25519), offers to generate
one if missing, and now installs the pubkey on BOTH the relay and the
remote (remote via ProxyJump). Two password prompts on first run, zero
on idempotent re-runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Create `scripts/setup-client.ps1` (UTF-8 without BOM)

**Files:**
- Create: `scripts/setup-client.ps1` (~260 lines, UTF-8 **no BOM**).

> **CRITICAL:** The file must be saved without a UTF-8 BOM. When using
> the `Write` tool, the content starts with `#Requires` (bytes
> `23 52 65 71 75 69 72 65 73`). If the tool adds `EF BB BF` prefix, the
> file will reproduce the exact bug this task is fixing.

- [ ] **Step 1: Write the full file**

Write the following content to `scripts/setup-client.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
  Configure this Windows machine (client) to connect through a relay
  server to a remote machine via SSH reverse tunnel.

.DESCRIPTION
  PowerShell counterpart of scripts/setup-client.sh. Writes the SSH
  config block for the target, generates an SSH key if missing, and
  installs the pubkey on both relay and remote (remote via ProxyJump).

  MUST be saved as UTF-8 WITHOUT BOM. Any U+FEFF prefix breaks the
  #Requires directive on PowerShell 5.1.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------
# Output helpers (colour-coded to match the bash scripts)
# --------------------------------------------------------------------
function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  {
  param([string]$Msg)
  $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
  Write-Host "[ERROR $stamp] $Msg" -ForegroundColor Red
}
function Write-Ask  { param([string]$Msg) Write-Host "[?] $Msg" -NoNewline -ForegroundColor Cyan }

# --------------------------------------------------------------------
# Input helpers
# --------------------------------------------------------------------
function Read-Value {
  param(
    [Parameter(Mandatory)][string]$Description,
    [string]$Default = ''
  )
  while ($true) {
    if ($Default) {
      Write-Ask "$Description [default: $Default]: "
    } else {
      Write-Ask "${Description}: "
    }
    $reply = Read-Host
    if (-not $reply -and $Default) { return $Default }
    if ($reply) { return $reply }
    Write-Warn "This field is required"
  }
}

function Test-Port {
  param([Parameter(Mandatory)][string]$Value, [string]$Label = 'Port')
  $n = 0
  if (-not [int]::TryParse($Value, [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
    Write-Err "$Label must be a number between 1 and 65535, got: '$Value'"
    return $false
  }
  return $true
}

function Confirm-Or-Exit {
  param([string]$Message = 'Confirm settings above?')
  Write-Ask "$Message [y/N] "
  $ans = Read-Host
  if ($ans -notmatch '^[Yy]$') {
    Write-Info 'Cancelled'
    exit 0
  }
}

# --------------------------------------------------------------------
# UTF-8 no-BOM file write (PS 5.1's Out-File -Encoding utf8 emits a BOM)
# --------------------------------------------------------------------
function Write-FileNoBom {
  param([Parameter(Mandatory)][string]$Path, [string]$Content = '')
  $enc = New-Object System.Text.UTF8Encoding $false  # $false = no BOM
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# --------------------------------------------------------------------
# SSH config I/O (mirrors the awk-based functions in lib/common.sh)
# --------------------------------------------------------------------
function Get-SshConfigPath { Join-Path $env:USERPROFILE '.ssh\config' }

function Ensure-SshDir {
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
    Write-Info "Created $sshDir"
  }
  # Tighten ACLs so OpenSSH accepts files inside.
  icacls $sshDir /inheritance:r | Out-Null
  icacls $sshDir /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
}

function Get-SshHostBlock {
  param([string]$ConfigFile, [string]$HostName)
  if (-not (Test-Path $ConfigFile)) { return $null }
  $lines = Get-Content -LiteralPath $ConfigFile
  $inBlock = $false
  $block = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match '^\s*Host\s+(\S+)') {
      if ($inBlock) { break }
      if ($Matches[1] -eq $HostName) { $inBlock = $true }
    }
    if ($inBlock) { $block.Add($line) | Out-Null }
  }
  if ($block.Count -eq 0) { return $null }
  return ($block -join "`n")
}

function Remove-SshHostBlock {
  param([string]$ConfigFile, [string]$HostName)
  if (-not (Test-Path $ConfigFile)) { return }
  $kept = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in Get-Content -LiteralPath $ConfigFile) {
    if ($line -match '^\s*Host\s+(\S+)') {
      $skip = ($Matches[1] -eq $HostName)
    } elseif ($line -match '^\S') {
      $skip = $false
    }
    if (-not $skip) { $kept.Add($line) | Out-Null }
  }
  # Trim trailing blanks.
  while ($kept.Count -gt 0 -and -not $kept[$kept.Count - 1].Trim()) {
    $kept.RemoveAt($kept.Count - 1)
  }
  Write-FileNoBom -Path $ConfigFile -Content (($kept -join "`n") + "`n")
}

function Set-SshHostBlock {
  param([string]$ConfigFile, [string]$HostName, [string]$BlockContent)
  Ensure-SshDir
  if (-not (Test-Path $ConfigFile)) {
    Write-FileNoBom -Path $ConfigFile -Content ($BlockContent + "`n")
    Write-Info "Created $ConfigFile"
    icacls $ConfigFile /inheritance:r | Out-Null
    icacls $ConfigFile /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    return
  }
  $existing = Get-SshHostBlock -ConfigFile $ConfigFile -HostName $HostName
  if ($existing) {
    Write-Warn "Host $HostName already exists in SSH config:"
    Write-Host '---'
    Write-Host $existing
    Write-Host '---'
    Write-Ask 'Update to new settings? [y/N] '
    $ans = Read-Host
    if ($ans -match '^[Yy]$') {
      Copy-Item $ConfigFile "$ConfigFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
      Remove-SshHostBlock -ConfigFile $ConfigFile -HostName $HostName
      Add-Content -LiteralPath $ConfigFile -Value "`n$BlockContent" -Encoding UTF8
      Write-Info "Updated Host $HostName block"
    } else {
      Write-Info 'Keeping existing settings, skipped'
    }
  } else {
    Add-Content -LiteralPath $ConfigFile -Value "`n$BlockContent" -Encoding UTF8
    Write-Info "Added Host $HostName block to $ConfigFile"
  }
  icacls $ConfigFile /inheritance:r | Out-Null
  icacls $ConfigFile /grant:r "$($env:USERNAME):(R,W)" | Out-Null
}

# --------------------------------------------------------------------
# Pubkey install/verify helpers
# (Windows OpenSSH does NOT ship ssh-copy-id; we pipe the pubkey over
#  ssh and append with a POSIX dedup snippet running on the target.)
# --------------------------------------------------------------------
function Test-PubkeyAuth {
  param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$KeyPath,
    [string]$ProxyJump = ''
  )
  $args = @(
    '-o', 'BatchMode=yes',
    '-o', 'PreferredAuthentications=publickey',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-i', $KeyPath,
    '-p', "$Port"
  )
  if ($ProxyJump) { $args += @('-o', "ProxyJump=$ProxyJump") }
  $args += @($Destination, 'true')
  & ssh @args 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Install-Pubkey {
  param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$KeyPath,
    [string]$ProxyJump = ''
  )
  $pubPath = "$KeyPath.pub"
  if (-not (Test-Path $pubPath)) {
    Write-Err "Public key not found at $pubPath"
    return $false
  }
  $pub = (Get-Content -Raw $pubPath).Trim()

  $args = @(
    '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-i', $KeyPath,
    '-p', "$Port"
  )
  if ($ProxyJump) { $args += @('-o', "ProxyJump=$ProxyJump") }
  # Single-quoted here-string: no PowerShell interpolation. sh reads $KEY
  # from stdin via 'read' instead of arg quoting to avoid injection.
  $remote = @'
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
'@
  $args += @($Destination, $remote)

  $pub | & ssh @args
  return ($LASTEXITCODE -eq 0)
}

function Assert-PubkeyOnHost {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$KeyPath,
    [string]$ProxyJump = ''
  )
  Write-Info "Checking pubkey auth to $Label ($Destination)..."
  if (Test-PubkeyAuth -Destination $Destination -Port $Port -KeyPath $KeyPath -ProxyJump $ProxyJump) {
    Write-Info "Pubkey auth to $Label -- OK"
    return $true
  }
  Write-Warn "Pubkey auth to $Label not working -- installing key now."
  Write-Info "You will be prompted for the $Label password."
  if (-not (Install-Pubkey -Destination $Destination -Port $Port -KeyPath $KeyPath -ProxyJump $ProxyJump)) {
    Write-Err "Pubkey install failed for $Label ($Destination)."
    return $false
  }
  if (Test-PubkeyAuth -Destination $Destination -Port $Port -KeyPath $KeyPath -ProxyJump $ProxyJump) {
    Write-Info "Pubkey auth to $Label -- verified"
    return $true
  }
  Write-Err "Key installed on $Label, but pubkey auth still fails."
  Write-Err "Possible causes: PubkeyAuthentication no on the relay, loose perms on ~/.ssh, sshd AllowUsers restriction."
  return $false
}

# --------------------------------------------------------------------
# Main
# --------------------------------------------------------------------
function main {
  Write-Host ''
  Write-Host '========================================='
  Write-Host '  Reverse Tunnel Manager -- Client Setup (PowerShell)'
  Write-Host '========================================='
  Write-Host ''

  foreach ($bin in 'ssh', 'ssh-keygen') {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
      Write-Err "$bin not found. Install 'OpenSSH Client' via: Settings > Apps > Optional Features > Add > OpenSSH Client."
      exit 1
    }
  }

  $relayHost    = Read-Value 'Relay server IP or hostname'
  $relayPort    = Read-Value 'Relay SSH port' '22'
  if (-not (Test-Port $relayPort 'Relay SSH port')) { exit 1 }
  $relayUser    = Read-Value 'Relay username' $env:USERNAME
  $tunnelPort   = Read-Value 'Reverse tunnel port (set on remote machine)'
  if (-not (Test-Port $tunnelPort 'Reverse tunnel port')) { exit 1 }
  $remoteUser   = Read-Value 'Remote machine username' $env:USERNAME
  $connection   = Read-Value 'SSH config Host alias' 'my-remote'
  $defaultKey   = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
  $keyPath      = Read-Value 'SSH private key path' $defaultKey

  Write-Host ''
  Write-Host '========================================='
  Write-Host '  Configuration Summary'
  Write-Host '========================================='
  @(
    @('Relay Host',      $relayHost),
    @('Relay Port',      $relayPort),
    @('Relay User',      $relayUser),
    @('Tunnel Port',     $tunnelPort),
    @('Remote User',     $remoteUser),
    @('Connection Name', $connection),
    @('SSH Key Path',    $keyPath)
  ) | ForEach-Object { Write-Host ("  {0,-20}: {1}" -f $_[0], $_[1]) }
  Write-Host '========================================='
  Write-Host ''

  Confirm-Or-Exit 'Proceed with these settings?'

  $expectedBlock = @"
Host $connection
    HostName localhost
    Port $tunnelPort
    User $remoteUser
    IdentityFile $keyPath
    ProxyJump $relayUser@${relayHost}:$relayPort
    ServerAliveInterval 60
"@
  $expectedBlock = $expectedBlock.TrimEnd()

  Write-Info 'Verifying current configuration...'

  if (Test-Path $keyPath) {
    Write-Info "SSH key -- found at $keyPath"
    $needsKey = $false
  } else {
    Write-Warn "SSH key -- not found at $keyPath"
    $needsKey = $true
  }

  $configFile = Get-SshConfigPath
  $existing   = Get-SshHostBlock -ConfigFile $configFile -HostName $connection
  $needsCfg   = $true
  if ($existing -and $existing.Trim() -eq $expectedBlock.Trim()) {
    Write-Info "SSH config -- $connection block is correct"
    $needsCfg = $false
  } elseif ($existing) {
    Write-Warn "SSH config -- $connection block exists but differs"
  } else {
    Write-Warn "SSH config -- $connection block not found"
  }

  if ($needsKey) {
    Write-Ask "Generate a new ed25519 key at $keyPath? [y/N] "
    $ans = Read-Host
    if ($ans -match '^[Yy]$') {
      $keyDir = Split-Path -Parent $keyPath
      if (-not (Test-Path $keyDir)) {
        New-Item -ItemType Directory -Path $keyDir | Out-Null
      }
      & ssh-keygen -t ed25519 -f $keyPath -C "$env:USERNAME@$env:COMPUTERNAME-client"
      if (-not (Test-Path $keyPath)) {
        Write-Err 'Key generation failed.'
        exit 1
      }
      Write-Info "New SSH key generated: $keyPath"
      icacls $keyPath /inheritance:r | Out-Null
      icacls $keyPath /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    } else {
      Write-Err 'An SSH key is required. Exiting.'
      exit 1
    }
  }

  if ($needsCfg) {
    Write-Info "Writing SSH config block for host alias: $connection"
    Set-SshHostBlock -ConfigFile $configFile -HostName $connection -BlockContent $expectedBlock
  } else {
    Write-Info 'SSH config is already up to date -- skipping.'
  }

  if (-not (Assert-PubkeyOnHost -Label 'relay' `
            -Destination "$relayUser@$relayHost" `
            -Port [int]$relayPort `
            -KeyPath $keyPath)) {
    Write-Err 'Cannot establish pubkey auth to the relay. Aborting.'
    exit 1
  }

  if (-not (Assert-PubkeyOnHost -Label 'remote' `
            -Destination "$remoteUser@localhost" `
            -Port [int]$tunnelPort `
            -KeyPath $keyPath `
            -ProxyJump "$relayUser@${relayHost}:$relayPort")) {
    Write-Err 'Cannot establish pubkey auth to the remote.'
    Write-Err 'Verify the remote tunnel is active (run setup-remote.sh on the remote).'
    exit 1
  }

  Write-Info "Testing connection to $connection ..."
  Write-Host ''

  & ssh -o ConnectTimeout=10 -o BatchMode=yes $connection "echo 'Connection OK'" 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Setup Complete -- Connection Successful'
    Write-Host '========================================='
    @(
      @('SSH alias',   $connection),
      @('Relay',       "$relayUser@${relayHost}:$relayPort"),
      @('Tunnel port', $tunnelPort),
      @('Remote user', $remoteUser)
    ) | ForEach-Object { Write-Host ("  {0,-20}: {1}" -f $_[0], $_[1]) }
    Write-Host '========================================='
    Write-Host ''
    Write-Info 'Connect to the remote machine any time with:'
    Write-Host "  ssh $connection"
    Write-Host ''
  } else {
    Write-Host ''
    Write-Warn 'Connection test failed, but SSH config and keys are in place.'
    Write-Host ''
    Write-Warn 'Troubleshooting tips:'
    Write-Host '  1. Remote tunnel may not be running -- check setup-remote.sh on the remote.'
    Write-Host "  2. Relay may be unreachable -- verify ${relayHost}:${relayPort} is accessible."
    Write-Host ''
    Write-Info 'For verbose debug output:'
    Write-Host "  ssh -v $connection"
    Write-Host ''
  }
}

main
```

- [ ] **Step 2: Verify file has no BOM**

Run: `hexdump -C scripts/setup-client.ps1 | head -1`
Expected first bytes: `23 52 65 71 75 69 72 65 73` (`#Requires`).
**Must not** start with `ef bb bf`. If it does, rewrite the file using a
shell `printf` redirect that guarantees no BOM, e.g.:

```bash
python3 -c 'import sys; sys.stdout.buffer.write(open("scripts/setup-client.ps1","rb").read().lstrip(b"\xef\xbb\xbf"))' > /tmp/setup-client.ps1.nobom
mv /tmp/setup-client.ps1.nobom scripts/setup-client.ps1
```

- [ ] **Step 3: Parse-check (if pwsh is available)**

Run: `command -v pwsh && pwsh -NoProfile -Command "\$null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/setup-client.ps1', [ref]\$null, [ref]\$null)"`
Expected: no parser errors. If `pwsh` is not installed locally, skip
this step — the Windows manual test in Task 9 covers it.

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-client.ps1
git commit -m "$(cat <<'EOF'
feat(client): add Windows PowerShell setup script

New scripts/setup-client.ps1 — native Windows companion to
setup-client.sh. Saved as UTF-8 without BOM (fixes the #Requires
parse error on PowerShell 5.1). Replaces ssh-copy-id (unavailable on
Windows OpenSSH) with a Get-Content | ssh pipe that uses grep -qxF
on the target to dedup authorized_keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Update README.md with new flow and BOM note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a short paragraph to the Usage section**

Find the section that documents the three-script flow (likely a "Usage"
or "Quick Start" heading). After the existing description of
`setup-remote.sh` / `setup-client.sh`, add this paragraph (exact text):

```markdown
### Password prompts during first-time setup

The first run of `setup-remote.sh` will prompt once for the **relay**
user's SSH password (to install the remote's pubkey). The first run of
`setup-client.sh` (or `setup-client.ps1`) will prompt twice — once for
the **relay** user, once for the **remote** user — to install the
client's pubkey on both. Re-runs use verify-first checks and do not
prompt again if pubkey auth already works.
```

- [ ] **Step 2: Add a troubleshooting note about the Windows BOM**

Find the Troubleshooting section (or create one at the end) and append:

```markdown
### Windows: PowerShell complains about `#Requires`

If running `setup-client.ps1` prints an error like
`#Requires : 無法辨識 '#Requires' 詞彙是否為 Cmdlet`
the file was saved with a UTF-8 BOM (a U+FEFF byte before `#Requires`)
that PowerShell 5.1 cannot parse.

Check with `hexdump -C scripts/setup-client.ps1 | head -1`. If the
first three bytes are `ef bb bf`, re-save the file as UTF-8 *without*
BOM. In VS Code: bottom-right status bar → "UTF-8 with BOM" → pick
"Save with Encoding" → "UTF-8".

The committed version in this repo is already BOM-free; this only
affects copies re-saved in Windows Notepad or a misconfigured editor.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document password prompts and Windows BOM gotcha

Adds a Usage note explaining the one (remote) and two (client) password
prompts during first-time setup, and a Troubleshooting entry for the
PowerShell UTF-8 BOM error users may hit if they re-save the file in
Notepad.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Final verification

**Files:**
- None to modify — verification only.

- [ ] **Step 1: Run `make check` (syntax-only)**

Run: `make check`
Expected: prints `bash -n ...` lines for each script, exits 0.

- [ ] **Step 2: Run `make lint`**

Run: `make lint`
Expected: `shellcheck` passes on every `.sh` in the repo, exit 0. No new
warnings introduced by this branch.

- [ ] **Step 3: BOM check on PowerShell file**

Run: `hexdump -C scripts/setup-client.ps1 | head -1`
Expected: line begins with `23 52 65 71 75 69 72 65 73` (`#Requires`).
Must **not** be `ef bb bf`.

- [ ] **Step 4: Diffstat summary**

Run: `git log --stat master..HEAD`
Expected: touches only `lib/common.sh`, `scripts/setup-relay.sh`,
`scripts/setup-remote.sh`, `scripts/setup-client.sh`,
`scripts/setup-client.ps1`, `README.md`, and the two docs files
(spec + plan). No stray files.

- [ ] **Step 5: Manual end-to-end test plan (user-driven, three machines)**

This step produces no code; it's a hand-off checklist for the human
operator. Record the results in the PR description.

Fresh install (no keys anywhere):
1. Run `bash scripts/setup-relay.sh` on relay. Expect all four options
   (`ClientAliveInterval`, `ClientAliveCountMax`, `AllowTcpForwarding`,
   `PubkeyAuthentication`) to be applied and sshd reloaded.
2. Run `bash scripts/setup-remote.sh` on remote. Expect: offer to
   generate key → **one** password prompt (relay) → probe passes →
   systemd service starts → "Setup Complete — Tunnel is Active".
3. Run `bash scripts/setup-client.sh` on client. Expect: offer to
   generate key → **two** password prompts (relay, then remote) → both
   probes pass → final `ssh my-remote echo` succeeds.
4. On Windows client, run `powershell -File scripts/setup-client.ps1`.
   Expect the same flow as step 3 — two password prompts, no BOM error.

Re-run (already configured):
5. Re-run each script in order. Expect zero password prompts and
   "already configured" messages from every script.

Negative cases:
6. Set `PubkeyAuthentication no` on relay manually, then re-run
   `setup-remote.sh`. Expect abort after install succeeds but probe
   fails, with the `PubkeyAuthentication no` diagnostic message.
7. Enter a wrong password at the ssh-copy-id prompt. Expect clean abort.

- [ ] **Step 6: Open PR**

Run: `git push -u origin feat/pubkey-auth-flow` (only once the user
confirms they're ready — pushing is a shared-state action that should
be gated on their word). Then open a PR with the spec link and the
manual test results pasted into the description.

---

## Self-review

### Spec coverage

| Spec section | Task(s) |
|---|---|
| `verify_pubkey_auth` | Task 1 |
| `install_pubkey` | Task 2 |
| `ensure_pubkey_on_host` | Task 3 |
| `setup-relay.sh` + `PubkeyAuthentication yes` | Task 4 |
| `setup-remote.sh` integration | Task 5 |
| `setup-client.sh` integration | Task 6 |
| `setup-client.ps1` new file | Task 7 |
| `PubkeyAuthentication` in `setup-relay.sh` summary | Task 4 steps 3 & 5 |
| Windows `Install-Pubkey` via `Get-Content | ssh` dedup | Task 7 `Install-Pubkey` function |
| UTF-8 no-BOM | Task 7 Step 1 header comment + Step 2 BOM check |
| ACL lockdown on Windows | Task 7 `Ensure-SshDir` and `Set-SshHostBlock` |
| `IdentitiesOnly=yes` in probe | Task 1 (and mirrored in Task 7) |
| Error-handling table | Mapped across Tasks 3, 5, 6, 7 |
| Idempotency | Task 3 (verify-first), Task 7 (`grep -qxF` dedup) |
| README notes | Task 8 |
| Syntax / lint / BOM checks | Task 9 |

No spec section is missing a task.

### Placeholder scan

No `TBD`, `TODO`, `implement later`, `add validation`, or unreferenced
identifier. Every code step contains runnable code.

### Type consistency

- Helper names: `verify_pubkey_auth`, `install_pubkey`,
  `ensure_pubkey_on_host` — consistent across Tasks 1-6.
- PS equivalents: `Test-PubkeyAuth`, `Install-Pubkey`,
  `Assert-PubkeyOnHost` — consistent within Task 7.
- Argument order for all three helpers is fixed: `(label,) destination,
  port, key_path, [proxy_jump]` — identical at every call site.
- `ssh_key_path` variable name used consistently across tasks 5 and 6.
- `PubkeyAuthentication yes` capitalization matches sshd_config's
  canonical form in every occurrence.
