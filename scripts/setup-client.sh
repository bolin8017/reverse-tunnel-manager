#!/usr/bin/env bash
# setup-client.sh — Configure the client machine (laptop) to connect through
# a relay server to a remote machine via SSH reverse tunnel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

COMMON_LIB="${PROJECT_ROOT}/lib/common.sh"
readonly COMMON_LIB

if [[ ! -f "${COMMON_LIB}" ]]; then
  echo "[ERROR] Cannot find lib/common.sh at ${COMMON_LIB}" >&2
  echo "        Run this script from within the reverse-tunnel-manager directory." >&2
  exit 1
fi

# shellcheck source=../lib/common.sh
source "${COMMON_LIB}"

main() {
  echo ""
  echo "========================================="
  echo "  Reverse Tunnel Manager — Client Setup"
  echo "========================================="
  echo ""

  # -----------------------------------------------------------------
  # Platform check
  # -----------------------------------------------------------------
  case "$(uname -s)" in
    Linux|Darwin)
      info "Platform: $(uname -s)"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      warn "Windows detected ($(uname -s))."
      warn "This script has limited support on Windows."
      warn "Recommended: use WSL (Windows Subsystem for Linux) instead."
      ask "Continue anyway? [y/N] "
      read -r win_answer
      if [[ ! "${win_answer}" =~ ^[Yy]$ ]]; then
        info "Cancelled. Please re-run inside WSL."
        return 0
      fi
      ;;
    *)
      warn "Unrecognized platform: $(uname -s). Proceeding anyway."
      ;;
  esac

  # -----------------------------------------------------------------
  # Interactive parameter collection
  # -----------------------------------------------------------------
  local -r total_steps=7

  prompt_step 1 "${total_steps}" "Relay host" \
    "IP address or hostname of your relay server" ""
  local relay_host="${REPLY}"

  prompt_step 2 "${total_steps}" "Relay SSH port" \
    "Relay SSH port" "22"
  local relay_port="${REPLY}"
  validate_port "${relay_port}" "Relay SSH port" || return 1

  prompt_step 3 "${total_steps}" "Relay username" \
    "Relay username" "${USER}"
  local relay_user="${REPLY}"

  prompt_step 4 "${total_steps}" "Tunnel port" \
    "Reverse tunnel port (set during remote setup)" ""
  local tunnel_port="${REPLY}"
  validate_port "${tunnel_port}" "Reverse tunnel port" || return 1

  prompt_step 5 "${total_steps}" "Remote username" \
    "Remote machine username" "${USER}"
  local remote_user="${REPLY}"

  echo ""
  info "Step 6/${total_steps}: SSH key"
  prompt_ssh_key
  local ssh_key_path="${SSH_KEY_PATH}"

  prompt_step 7 "${total_steps}" "Connection alias" \
    "SSH config Host alias (connect with: ssh <alias>)" "my-remote"
  local connection_name="${REPLY}"

  print_summary \
    "Relay Host"      "${relay_host}" \
    "Relay Port"      "${relay_port}" \
    "Relay User"      "${relay_user}" \
    "Tunnel Port"     "${tunnel_port}" \
    "Remote User"     "${remote_user}" \
    "SSH Key"         "${ssh_key_path} (${KEY_TYPE})" \
    "Connection Name" "${connection_name}"

  confirm_or_exit "Proceed with these settings?"

  # -----------------------------------------------------------------
  # Verify current state
  # -----------------------------------------------------------------
  local expected_block="Host ${connection_name}
    HostName localhost
    Port ${tunnel_port}
    User ${remote_user}
    IdentityFile ${ssh_key_path}
    ProxyJump ${relay_user}@${relay_host}:${relay_port}
    ServerAliveInterval 60
    ServerAliveCountMax 3"

  local needs_ssh_config=false
  local existing_block=""

  info "Verifying current configuration..."
  if existing_block=$(extract_ssh_host_block "${HOME}/.ssh/config" "${connection_name}" 2>/dev/null); then
    if diff <(echo "${expected_block}") <(echo "${existing_block}") &>/dev/null; then
      info "SSH config — ${connection_name} block is correct"
    else
      warn "SSH config — ${connection_name} block exists but differs"
      needs_ssh_config=true
    fi
  else
    warn "SSH config — ${connection_name} block not found"
    needs_ssh_config=true
  fi

  # -----------------------------------------------------------------
  # SSH key handling
  # -----------------------------------------------------------------
  if [[ "${SSH_KEY_EXISTS}" == "true" ]]; then
    info "SSH key — using ${ssh_key_path}"
  else
    info "Generating ${KEY_TYPE} key at ${ssh_key_path}..."
    info "Leave the passphrase empty for automatic SSH connections."
    generate_ssh_key "${ssh_key_path}" "${KEY_TYPE}" "${KEY_BITS}" \
      "${USER}@$(hostname)-client" || return 1
    info "New SSH key generated: ${ssh_key_path}"
  fi

  # -----------------------------------------------------------------
  # Verify relay access and copy key if needed
  # -----------------------------------------------------------------
  info "Verifying SSH access to relay (${relay_user}@${relay_host}:${relay_port})..."
  if ssh -o ConnectTimeout=10 -o BatchMode=yes \
      -p "${relay_port}" -i "${ssh_key_path}" \
      "${relay_user}@${relay_host}" "true" 2>/dev/null; then
    info "SSH access to relay — OK"
  else
    warn "Cannot authenticate to relay with this key."
    echo ""
    ask "Automatically copy key to relay with ssh-copy-id? [Y/n] "
    read -r copy_answer
    if [[ ! "${copy_answer}" =~ ^[Nn]$ ]]; then
      info "Running ssh-copy-id (you may be prompted for the relay password)..."
      if ssh-copy-id -i "${ssh_key_path}" -p "${relay_port}" \
          "${relay_user}@${relay_host}"; then
        info "Key copied to relay successfully."
      else
        error "ssh-copy-id failed."
        echo ""
        info "You can try manually:"
        echo "  ssh-copy-id -i ${ssh_key_path} -p ${relay_port} ${relay_user}@${relay_host}"
        echo ""
        error "Please add the key to the relay, then re-run this script."
        return 1
      fi
    else
      warn "Relay access not configured. Connection test will likely fail."
    fi
  fi

  # -----------------------------------------------------------------
  # SSH config setup (only if needed)
  # -----------------------------------------------------------------
  if [[ "${needs_ssh_config}" == "true" ]]; then
    info "Writing SSH config block for host alias: ${connection_name}"
    upsert_ssh_host_block "${HOME}/.ssh/config" "${connection_name}" "${expected_block}"
    chmod 600 "${HOME}/.ssh/config"
    info "SSH config permissions set to 600."
  else
    info "SSH config is already up to date — skipping."
  fi

  # -----------------------------------------------------------------
  # Connection test (full path: client → relay → remote)
  # -----------------------------------------------------------------
  info "Testing connection to ${connection_name} ..."
  echo ""

  if ssh -o ConnectTimeout=10 -o BatchMode=yes \
      "${connection_name}" "echo 'Connection OK'" 2>/dev/null; then
    echo ""
    echo "========================================="
    echo "  Setup Complete — All Done!"
    echo "========================================="
    printf '  %-20s : %s\n' "SSH alias"   "${connection_name}"
    printf '  %-20s : %s\n' "Relay"       "${relay_user}@${relay_host}:${relay_port}"
    printf '  %-20s : %s\n' "Tunnel port" "${tunnel_port}"
    printf '  %-20s : %s\n' "Remote user" "${remote_user}"
    echo "========================================="
    echo ""
    info "Connect now:"
    echo "  ssh ${connection_name}"
    echo ""
  else
    echo ""
    warn "Connection test failed. SSH config was written successfully."
    echo ""
    warn "If connection fails, common causes:"
    echo "  1. Remote tunnel not running"
    echo "     -> On remote: systemctl --user status ssh-tunnel.service"
    echo "  2. Relay unreachable"
    echo "     -> Verify: ssh ${relay_user}@${relay_host} -p ${relay_port}"
    echo "  3. SSH key not authorized"
    echo "     -> Check authorized_keys on relay and remote"
    echo ""
    info "Verbose debug:"
    echo "  ssh -v ${connection_name}"
    echo ""
    info "Once the tunnel is active, connect with:"
    echo "  ssh ${connection_name}"
    echo ""
  fi
}

main "$@"
