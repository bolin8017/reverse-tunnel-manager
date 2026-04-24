#!/usr/bin/env bash
# setup-remote.sh — Configure this machine as a reverse-tunnel client.
# Sets up autossh, SSH config, and a systemd user service to maintain
# a persistent reverse tunnel to a relay server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

COMMON_LIB="${PROJECT_ROOT}/lib/common.sh"
readonly COMMON_LIB

if [[ ! -f "${COMMON_LIB}" ]]; then
  echo "[ERROR] Cannot find lib/common.sh at ${COMMON_LIB}" >&2
  exit 1
fi

# shellcheck source=../lib/common.sh
source "${COMMON_LIB}"

main() {
  echo ""
  echo "========================================="
  echo "  Reverse Tunnel Manager — Remote Setup"
  echo "========================================="
  echo ""

  detect_os

  # -----------------------------------------------------------------
  # Interactive parameter collection
  # -----------------------------------------------------------------
  local -r total_steps=6

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
    "Reverse tunnel port on relay (must be unique per machine)" ""
  local tunnel_port="${REPLY}"
  validate_port "${tunnel_port}" "Reverse tunnel port" || return 1

  prompt_step 5 "${total_steps}" "Local SSH port" \
    "Local SSH port on this machine" "22"
  local local_ssh_port="${REPLY}"
  validate_port "${local_ssh_port}" "Local SSH port" || return 1

  echo ""
  info "Step 6/${total_steps}: SSH key"
  prompt_ssh_key
  # shellcheck disable=SC2153  # SSH_KEY_PATH set by prompt_ssh_key
  local ssh_key_path="${SSH_KEY_PATH}"

  local -r ssh_host_alias="relay-tunnel"

  print_summary \
    "Relay Host"     "${relay_host}" \
    "Relay Port"     "${relay_port}" \
    "Relay User"     "${relay_user}" \
    "Tunnel Port"    "${tunnel_port}" \
    "Local SSH Port" "${local_ssh_port}" \
    "SSH Key"        "${ssh_key_path} (${KEY_TYPE})" \
    "SSH Host Alias" "${ssh_host_alias}"

  confirm_or_exit "Proceed with these settings?"

  # -----------------------------------------------------------------
  # Port conflict check on relay
  # -----------------------------------------------------------------
  info "Checking if port ${tunnel_port} is available on relay..."
  local port_check_result=0
  check_port_on_relay "${relay_user}" "${relay_host}" "${relay_port}" \
    "${tunnel_port}" "${ssh_key_path}" || port_check_result=$?

  case "${port_check_result}" in
    0)
      info "Port ${tunnel_port} is available on relay."
      ;;
    1)
      while [[ "${port_check_result}" -eq 1 ]]; do
        warn "Port ${tunnel_port} is already in use on relay."
        ask "Enter a different port (or 's' to skip check): "
        read -r new_port
        if [[ "${new_port}" == "s" ]]; then
          warn "Skipping port check. Ensure port ${tunnel_port} is free on the relay."
          break
        fi
        validate_port "${new_port}" "Tunnel port" || continue
        tunnel_port="${new_port}"
        port_check_result=0
        check_port_on_relay "${relay_user}" "${relay_host}" "${relay_port}" \
          "${tunnel_port}" "${ssh_key_path}" || port_check_result=$?
        if [[ "${port_check_result}" -eq 0 ]]; then
          info "Port ${tunnel_port} is available on relay."
        fi
      done
      ;;
    2)
      warn "Could not verify port on relay (SSH connection failed)."
      warn "Skipping check — ensure port ${tunnel_port} is free on the relay."
      ;;
  esac

  # -----------------------------------------------------------------
  # Verify current state
  # -----------------------------------------------------------------
  info "Verifying current configuration..."
  echo ""

  local needs_autossh=false
  local needs_ssh_config=false
  local needs_service=false

  # Check autossh
  if command -v autossh &>/dev/null; then
    local autossh_version
    autossh_version=$(autossh -V 2>&1 || true)
    info "autossh — installed (${autossh_version})"
  else
    warn "autossh — not installed"
    needs_autossh=true
  fi

  # Check SSH key (prompt_ssh_key already detected existence)
  local needs_key=false
  if [[ "${SSH_KEY_EXISTS}" == "true" ]]; then
    info "SSH key — found at ${ssh_key_path}"
  else
    warn "SSH key — will be generated at ${ssh_key_path}"
    needs_key=true
  fi

  # Build expected SSH config block for comparison.
  local template_file="${PROJECT_ROOT}/templates/ssh-config-relay.template"
  local expected_ssh_block
  if [[ -f "${template_file}" ]]; then
    expected_ssh_block=$(sed \
      -e "s|{{SSH_HOST_ALIAS}}|${ssh_host_alias}|g" \
      -e "s|{{RELAY_HOST}}|${relay_host}|g" \
      -e "s|{{RELAY_PORT}}|${relay_port}|g" \
      -e "s|{{RELAY_USER}}|${relay_user}|g" \
      -e "s|{{SSH_KEY_PATH}}|${ssh_key_path}|g" \
      -e "s|{{TUNNEL_PORT}}|${tunnel_port}|g" \
      -e "s|{{LOCAL_SSH_PORT}}|${local_ssh_port}|g" \
      "${template_file}")
  else
    expected_ssh_block="Host ${ssh_host_alias}
    HostName ${relay_host}
    Port ${relay_port}
    User ${relay_user}
    IdentityFile \"${ssh_key_path}\"
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    RemoteForward ${tunnel_port} localhost:${local_ssh_port}"
  fi

  # Check SSH config
  local existing_block=""
  if existing_block=$(extract_ssh_host_block "${HOME}/.ssh/config" "${ssh_host_alias}" 2>/dev/null); then
    if diff <(echo "${expected_ssh_block}") <(echo "${existing_block}") &>/dev/null; then
      info "SSH config — ${ssh_host_alias} block is correct"
    else
      warn "SSH config — ${ssh_host_alias} block exists but differs"
      needs_ssh_config=true
    fi
  else
    warn "SSH config — ${ssh_host_alias} block not found"
    needs_ssh_config=true
  fi

  # Check systemd service
  local expected_service
  local service_template="${PROJECT_ROOT}/templates/ssh-tunnel.service.template"
  local service_file="${HOME}/.config/systemd/user/ssh-tunnel.service"
  if [[ -f "${service_template}" ]]; then
    expected_service=$(sed -e "s|{{SSH_HOST_ALIAS}}|${ssh_host_alias}|g" "${service_template}")
  else
    expected_service="[Unit]
Description=SSH Reverse Tunnel to relay via autossh
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N ${ssh_host_alias}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target"
  fi

  if systemctl --user is-active --quiet ssh-tunnel.service 2>/dev/null; then
    if [[ -f "${service_file}" ]] \
        && diff <(echo "${expected_service}") "${service_file}" &>/dev/null; then
      info "ssh-tunnel.service — active and up to date"
    else
      warn "ssh-tunnel.service — active but service file differs"
      needs_service=true
    fi
  else
    warn "ssh-tunnel.service — not running"
    needs_service=true
  fi

  echo ""

  # -----------------------------------------------------------------
  # All good — nothing to do
  # -----------------------------------------------------------------
  if [[ "${needs_autossh}" == "false" \
      && "${needs_key}" == "false" \
      && "${needs_ssh_config}" == "false" \
      && "${needs_service}" == "false" ]]; then
    echo "========================================="
    echo "  All Configured — Tunnel is Active"
    echo "========================================="
    printf '  %-22s : %s\n' "Relay"          "${relay_user}@${relay_host}:${relay_port}"
    printf '  %-22s : %s\n' "Tunnel Port"    "${tunnel_port} (on relay)"
    printf '  %-22s : %s\n' "Local SSH Port" "${local_ssh_port}"
    printf '  %-22s : %s\n' "SSH Alias"      "${ssh_host_alias}"
    echo "========================================="
    echo ""
    info "Nothing to change. Tunnel is already running."
    return 0
  fi

  info "Applying needed changes..."

  # -----------------------------------------------------------------
  # Install autossh (only if needed — only step requiring sudo)
  # -----------------------------------------------------------------
  if [[ "${needs_autossh}" == "true" ]]; then
    check_sudo
    if [[ "${HAS_SUDO}" != "true" ]]; then
      error "sudo is required to install autossh."
      error "Please install autossh manually, then re-run this script."
      return 1
    fi

    info "Installing autossh via ${PKG_MGR}..."
    case "${PKG_MGR}" in
      dnf|yum)
        sudo "${PKG_MGR}" install -y autossh
        ;;
      apt)
        sudo apt-get update -y
        sudo apt-get install -y autossh
        ;;
      *)
        error "Unknown package manager: ${PKG_MGR}"
        return 1
        ;;
    esac

    if ! command -v autossh &>/dev/null; then
      error "autossh installation failed. Please install it manually."
      return 1
    fi
    info "autossh installed successfully."
  fi

  # -----------------------------------------------------------------
  # SSH key handling (only if needed)
  # -----------------------------------------------------------------
  if [[ "${needs_key}" == "true" ]]; then
    info "Generating ${KEY_TYPE} key at ${ssh_key_path}..."
    info "Leave the passphrase empty so autossh can connect without prompting."
    generate_ssh_key "${ssh_key_path}" "${KEY_TYPE}" "${KEY_BITS}" \
      "${USER}@$(hostname)-tunnel" || return 1
    info "New SSH key generated: ${ssh_key_path}"
  fi

  # Show the public key only when it was just generated — first-run
  # context. On re-runs, ensure_pubkey_on_host's verify-first probe
  # short-circuits silently and there's no need to echo the key.
  if [[ "${needs_key}" == "true" ]]; then
    local pub_key=""
    local pub_key_path="${ssh_key_path}.pub"
    if [[ -f "${pub_key_path}" ]]; then
      pub_key=$(cat "${pub_key_path}")
    else
      info ".pub file not found. Deriving public key from private key..."
      pub_key=$(ssh-keygen -y -f "${ssh_key_path}" 2>/dev/null) || true
      if [[ -z "${pub_key}" ]]; then
        error "Could not derive public key from ${ssh_key_path}"
        return 1
      fi
    fi

    echo ""
    info "Public key that will be installed on the relay:"
    echo "---"
    echo "${pub_key}"
    echo "---"
    echo ""
  fi

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

  # -----------------------------------------------------------------
  # SSH config (only if needed)
  # -----------------------------------------------------------------
  if [[ "${needs_ssh_config}" == "true" ]]; then
    info "Configuring SSH host block for alias: ${ssh_host_alias}"
    upsert_ssh_host_block "${HOME}/.ssh/config" "${ssh_host_alias}" "${expected_ssh_block}"
    chmod 600 "${HOME}/.ssh/config"
    info "SSH config updated and permissions set to 600."

    # autossh does not monitor ~/.ssh/config for changes; restart needed.
    if [[ "${needs_service}" == "false" ]]; then
      info "Restarting ssh-tunnel.service to apply updated SSH config..."
      systemctl --user restart ssh-tunnel.service
      info "ssh-tunnel.service restarted."
    fi
  fi

  # -----------------------------------------------------------------
  # systemd user service (only if needed)
  # -----------------------------------------------------------------
  if [[ "${needs_service}" == "true" ]]; then
    info "Setting up systemd user service: ssh-tunnel.service"

    local service_dir="${HOME}/.config/systemd/user"
    mkdir -p "${service_dir}"

    echo "${expected_service}" > "${service_file}"
    systemctl --user daemon-reload
    info "Service file written and daemon reloaded."

    if loginctl enable-linger "${USER}" 2>/dev/null; then
      info "Linger enabled for user: ${USER}"
    else
      warn "Could not enable linger for ${USER}. The tunnel may stop when you log out."
      warn "Run manually: loginctl enable-linger ${USER}"
    fi

    systemctl --user enable ssh-tunnel.service
    info "ssh-tunnel.service enabled."

    systemctl --user restart ssh-tunnel.service
    info "ssh-tunnel.service started."
  fi

  # -----------------------------------------------------------------
  # Cleanup old settings (interactive)
  # -----------------------------------------------------------------
  info "Checking for legacy SSH-related crontab entries..."

  local cron_ssh_entries
  cron_ssh_entries=$(crontab -l 2>/dev/null \
    | grep -iE "(autossh|ssh\s+-[NfLR]|ssh-tunnel|reverse.tunnel)" || true)

  if [[ -n "${cron_ssh_entries}" ]]; then
    warn "Found SSH tunnel-related crontab entries:"
    echo "---"
    echo "${cron_ssh_entries}"
    echo "---"
    ask "Remove these crontab entries? [y/N] "
    read -r cron_answer
    if [[ "${cron_answer}" =~ ^[Yy]$ ]]; then
      crontab -l 2>/dev/null \
        | grep -ivE "(autossh|ssh\s+-[NfLR]|ssh-tunnel|reverse.tunnel)" | crontab -
      info "SSH tunnel-related crontab entries removed."
    else
      info "Keeping existing crontab entries."
    fi
  else
    info "No SSH-related crontab entries found."
  fi

  info "Checking for zombie 'ssh -Nf' processes..."

  local zombie_pids
  zombie_pids=$(pgrep -u "${USER}" -f "ssh -Nf" 2>/dev/null || true)

  if [[ -n "${zombie_pids}" ]]; then
    warn "Found lingering 'ssh -Nf' processes:"
    echo "---"
    local pid
    for pid in ${zombie_pids}; do
      ps -p "${pid}" -o pid,args --no-headers 2>/dev/null \
        || echo "PID ${pid} (could not read args)"
    done
    echo "---"
    ask "Kill these processes? [y/N] "
    read -r kill_answer
    if [[ "${kill_answer}" =~ ^[Yy]$ ]]; then
      for pid in ${zombie_pids}; do
        if kill "${pid}" 2>/dev/null; then
          info "Killed PID ${pid}"
        else
          warn "Could not kill PID ${pid}"
        fi
      done
    else
      info "Leaving existing processes running."
    fi
  else
    info "No zombie 'ssh -Nf' processes found."
  fi

  # -----------------------------------------------------------------
  # Final verification
  # -----------------------------------------------------------------
  if [[ "${needs_service}" == "true" ]]; then
    info "Waiting 5 seconds for the service to stabilize..."
    sleep 5
  fi

  if systemctl --user is-active --quiet ssh-tunnel.service; then
    echo ""
    echo "========================================="
    echo "  Remote Setup Complete — Tunnel Active"
    echo "========================================="
    printf '  %-22s : %s\n' "Relay"          "${relay_user}@${relay_host}:${relay_port}"
    printf '  %-22s : %s\n' "Tunnel Port"    "${tunnel_port} (on relay)"
    printf '  %-22s : %s\n' "Local SSH Port" "${local_ssh_port}"
    printf '  %-22s : %s\n' "SSH Alias"      "${ssh_host_alias}"
    echo "========================================="
    echo ""
    info "Verify tunnel status:"
    echo "  systemctl --user status ssh-tunnel.service"
    echo ""
    echo "  Next: run the installer on your Client (laptop)"
    echo "  ------------------------------------------------"
    echo "    curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash"
    echo "    irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex  # Windows"
    echo ""
    echo "  You will need these values for client setup:"
    printf '    %-14s : %s\n' "Relay Host"  "${relay_host}"
    printf '    %-14s : %s\n' "Relay Port"  "${relay_port}"
    printf '    %-14s : %s\n' "Relay User"  "${relay_user}"
    printf '    %-14s : %s\n' "Tunnel Port" "${tunnel_port}"
    echo ""
  else
    error "ssh-tunnel.service is NOT active after setup."
    echo ""
    warn "Last 20 log lines:"
    journalctl --user -u ssh-tunnel.service -n 20 --no-pager || true
    echo ""
    error "To retry manually: systemctl --user restart ssh-tunnel.service"
    return 1
  fi
}

main "$@"
