#!/usr/bin/env bash
# setup-relay.sh — Configure sshd on the relay server for reverse tunnel support.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# Source lib/common.sh if available; otherwise define minimal fallback helpers.
if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
  # shellcheck source=../lib/common.sh
  source "${PROJECT_ROOT}/lib/common.sh"
else
  if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
  fi
  info()  { printf '%b[INFO]%b %s\n' "${GREEN}" "${NC}" "$*"; }
  warn()  { printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
  error() {
    printf '%b[ERROR %s]%b %s\n' \
      "${RED}" "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${NC}" "$*" >&2
  }
  ask()   { printf '%b[?]%b %s' "${BLUE}" "${NC}" "$*"; }
fi

#######################################
# Display relay completion message with next-step guidance.
# Reads relay connection info interactively for the "next steps" display.
#######################################
show_relay_completion() {
  echo ""
  echo "========================================="
  echo "  Relay Setup Complete"
  echo "========================================="
  printf '  %-24s : %s\n' "Config file"         "${SSHD_CONFIG}"
  printf '  %-24s : %s\n' "ClientAliveInterval"  "30"
  printf '  %-24s : %s\n' "ClientAliveCountMax"  "3"
  printf '  %-24s : %s\n' "AllowTcpForwarding"   "yes"
  echo "========================================="
  echo ""
  info "Relay server is ready."
  echo ""

  info "To set up the next machine, provide your relay connection info:"
  echo ""

  ask "Relay hostname or IP (how other machines reach this server): "
  read -r relay_display_host
  while [[ -z "${relay_display_host}" ]]; do
    warn "This field is required"
    ask "Relay hostname or IP: "
    read -r relay_display_host
  done

  ask "Relay SSH port [22]: "
  read -r relay_display_port
  relay_display_port="${relay_display_port:-22}"

  ask "Username for tunnel connections [${USER}]: "
  read -r relay_display_user
  relay_display_user="${relay_display_user:-${USER}}"

  echo ""
  echo "  Next: run the installer on your Remote (internal machine)"
  echo "  ---------------------------------------------------------"
  echo "    curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash"
  echo ""
  echo "  You will need these values for remote setup:"
  printf '    %-14s : %s\n' "Relay Host" "${relay_display_host}"
  printf '    %-14s : %s\n' "Relay Port" "${relay_display_port}"
  printf '    %-14s : %s\n' "Relay User" "${relay_display_user}"
  echo ""
}

readonly SSHD_CONFIG="/etc/ssh/sshd_config"

#######################################
# Set or update an sshd_config option.
#   - Already correct (uncommented, exact value) → skip.
#   - Commented out or wrong value               → sed replace.
#   - Not present at all                         → append.
# Globals:
#   SSHD_CONFIG  — path to sshd_config.
#   CHANGES_MADE — set to "true" when a change is applied.
# Arguments:
#   keyword — sshd option name.
#   value   — desired value.
#######################################
set_sshd_option() {
  local keyword="$1"
  local value="$2"

  # Already correctly set?
  if sudo grep -qE \
      "^[[:space:]]*${keyword}[[:space:]]+${value}[[:space:]]*$" \
      "${SSHD_CONFIG}"; then
    info "${keyword} is already set to '${value}' — no change needed"
    return
  fi

  # Line exists (possibly commented or with wrong value)?
  # Use awk to replace only the first matching line, avoiding duplicates.
  if sudo grep -qiE \
      "^[[:space:]]*#?[[:space:]]*${keyword}[[:space:]]" \
      "${SSHD_CONFIG}"; then
    local tmp_sshd
    tmp_sshd=$(mktemp)
    if ! sudo awk -v kw="${keyword}" -v val="${value}" '
      !done && /^[[:space:]]*#?[[:space:]]*/ && tolower($0) ~ tolower(kw) {
        print kw " " val; done=1; next
      }
      { print }
    ' "${SSHD_CONFIG}" | tee "${tmp_sshd}" > /dev/null; then
      error "Failed to process sshd_config for: ${keyword}"
      rm -f "${tmp_sshd}"
      return 1
    fi
    if ! sudo cp "${tmp_sshd}" "${SSHD_CONFIG}"; then
      error "Failed to write sshd_config for: ${keyword}"
      rm -f "${tmp_sshd}"
      return 1
    fi
    rm -f "${tmp_sshd}"
    info "Updated ${keyword} to '${value}'"
  else
    echo "${keyword} ${value}" | sudo tee -a "${SSHD_CONFIG}" > /dev/null
    info "Appended ${keyword} ${value} to ${SSHD_CONFIG}"
  fi

  CHANGES_MADE=true
}

main() {
  echo ""
  echo "========================================="
  echo "  Reverse Tunnel Manager — Relay Setup"
  echo "========================================="
  echo ""

  # -------------------------------------------------------------------
  # Detect SSH service name (ssh on Debian/Ubuntu, sshd on RHEL/others)
  # -------------------------------------------------------------------
  local sshd_service="sshd"
  if systemctl cat ssh.service &>/dev/null; then
    sshd_service="ssh"
  fi
  info "SSH service name: ${sshd_service}"

  # -------------------------------------------------------------------
  # Verify current sshd_config settings
  # -------------------------------------------------------------------
  info "Checking current sshd_config settings..."

  local needs_change=false
  local missing_settings=()

  # Try reading sshd_config (often world-readable).
  local config_content=""
  if [[ -r "${SSHD_CONFIG}" ]]; then
    config_content=$(cat "${SSHD_CONFIG}")
  elif sudo -n cat "${SSHD_CONFIG}" &>/dev/null; then
    config_content=$(sudo -n cat "${SSHD_CONFIG}")
  else
    warn "Cannot read ${SSHD_CONFIG} — unable to verify settings."
  fi

  local keyword value
  if [[ -n "${config_content}" ]]; then
    for pair in "ClientAliveInterval 30" "ClientAliveCountMax 3" "AllowTcpForwarding yes"; do
      keyword="${pair%% *}"
      value="${pair#* }"
      if echo "${config_content}" | grep -qE "^[[:space:]]*${keyword}[[:space:]]+${value}[[:space:]]*$"; then
        info "${keyword} ${value} — OK"
      else
        warn "${keyword} ${value} — NOT SET or incorrect"
        missing_settings+=("${keyword} ${value}")
        needs_change=true
      fi
    done
  else
    needs_change=true
    missing_settings+=("ClientAliveInterval 30" "ClientAliveCountMax 3" "AllowTcpForwarding yes")
  fi

  # -------------------------------------------------------------------
  # All settings correct — done
  # -------------------------------------------------------------------
  if [[ "${needs_change}" == "false" ]]; then
    show_relay_completion
    return 0
  fi

  # -------------------------------------------------------------------
  # Settings need changes — try with sudo
  # -------------------------------------------------------------------
  warn "The following settings need to be applied:"
  for setting in "${missing_settings[@]}"; do
    echo "      ${setting}"
  done
  echo ""

  local has_sudo=false
  if sudo -n true 2>/dev/null; then
    has_sudo=true
    info "sudo access confirmed (passwordless)"
  elif sudo true; then
    has_sudo=true
    info "sudo access confirmed"
  fi

  if [[ "${has_sudo}" == "false" ]]; then
    warn "No sudo access. Cannot modify sshd_config automatically."
    echo ""
    echo "  Please ask your system administrator to apply the settings above, then run:"
    echo "      sudo sshd -t && sudo systemctl reload ${sshd_service}"
    echo ""
    echo "  After that, re-run this script to verify."
    return 1
  fi

  # -------------------------------------------------------------------
  # Apply changes with sudo
  # -------------------------------------------------------------------
  local backup_file
  backup_file="/etc/ssh/sshd_config.bak.$(date +%Y%m%d)"

  CHANGES_MADE=false

  if [[ ! -f "${backup_file}" ]]; then
    sudo cp "${SSHD_CONFIG}" "${backup_file}"
    info "Backed up ${SSHD_CONFIG} to ${backup_file}"
  else
    info "Today's backup already exists: ${backup_file} — skipping backup"
  fi

  set_sshd_option "ClientAliveInterval" "30"
  set_sshd_option "ClientAliveCountMax" "3"
  set_sshd_option "AllowTcpForwarding"  "yes"

  if [[ "${CHANGES_MADE}" == "false" ]]; then
    info "sshd_config already has all required settings — nothing to do."
    return 0
  fi

  # -------------------------------------------------------------------
  # Validate and reload
  # -------------------------------------------------------------------
  info "Validating sshd configuration..."
  if sudo sshd -t; then
    info "Configuration valid — reloading ${sshd_service}..."
    sudo systemctl reload "${sshd_service}"
  else
    error "sshd configuration validation failed."
    error "Restoring backup from ${backup_file} ..."
    sudo cp "${backup_file}" "${SSHD_CONFIG}"
    error "Backup restored. Please review ${SSHD_CONFIG} manually."
    return 1
  fi

  # -------------------------------------------------------------------
  # Completion summary
  # -------------------------------------------------------------------
  show_relay_completion
}

main "$@"
