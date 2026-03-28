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

if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=../lib/common.sh
  source "${COMMON_LIB}"
else
  # Inline fallbacks — used when this script is run standalone.

  # Color helpers (disabled when not a terminal).
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

  #######################################
  # Ensure ~/.ssh exists with correct permissions.
  #######################################
  ensure_ssh_dir() {
    if [[ ! -d "${HOME}/.ssh" ]]; then
      mkdir -p "${HOME}/.ssh"
      chmod 700 "${HOME}/.ssh"
      info "Created ${HOME}/.ssh/"
    fi
    local perm
    perm=$(stat -c '%a' "${HOME}/.ssh" 2>/dev/null \
        || stat -f '%Lp' "${HOME}/.ssh" 2>/dev/null)
    if [[ "${perm}" != "700" ]]; then
      chmod 700 "${HOME}/.ssh"
      warn "Fixed ${HOME}/.ssh/ permissions to 700"
    fi
  }

  #######################################
  # Validate that a value is a valid TCP port number (1–65535).
  # Arguments:
  #   port_value — the value to validate.
  #   label      — human-readable name for error messages.
  # Returns:
  #   1 if invalid.
  #######################################
  validate_port() {
    local port_value="$1"
    local label="${2:-Port}"
    if ! [[ "${port_value}" =~ ^[0-9]+$ ]] \
        || (( port_value < 1 || port_value > 65535 )); then
      error "${label} must be a number between 1 and 65535, got: '${port_value}'"
      return 1
    fi
  }

  #######################################
  # Extract a Host block from an SSH config file.
  # Arguments:
  #   config_file — path to SSH config file.
  #   host_name   — the Host block name to extract.
  # Returns:
  #   0 if found, 1 if not found.
  #######################################
  extract_ssh_host_block() {
    local config_file="$1"
    local host_name="$2"
    [[ -f "${config_file}" ]] || return 1

    local result
    result=$(awk -v host="${host_name}" '
      /^Host / { if ($2 == host) found=1; else if (found) exit }
      found { print }
    ' "${config_file}")

    if [[ -n "${result}" ]]; then
      printf '%s\n' "${result}"
      return 0
    fi
    return 1
  }

  #######################################
  # Remove a Host block from an SSH config file.
  # Arguments:
  #   config_file — path to SSH config file.
  #   host_name   — the Host block name to remove.
  #######################################
  remove_ssh_host_block() {
    local config_file="$1"
    local host_name="$2"
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "${tmp_file}"' RETURN

    awk -v host="${host_name}" '
      /^Host / {
        if ($2 == host) { skip=1; next } else { skip=0 }
      }
      /^[^ \t]/ && !/^Host / { skip=0 }
      !skip { print }
    ' "${config_file}" > "${tmp_file}"

    # Remove trailing blank lines (portable: command substitution strips them).
    local content
    content=$(cat "${tmp_file}")
    printf '%s\n' "${content}" > "${tmp_file}"

    mv "${tmp_file}" "${config_file}"
  }

  #######################################
  # Append or update a Host block in an SSH config file.
  # Arguments:
  #   config_file   — path to SSH config file.
  #   host_name     — the Host block name.
  #   block_content — full Host block including the "Host ..." line.
  #######################################
  upsert_ssh_host_block() {
    local config_file="$1"
    local host_name="$2"
    local block_content="$3"

    ensure_ssh_dir

    if [[ ! -f "${config_file}" ]]; then
      printf '%s\n' "${block_content}" > "${config_file}"
      chmod 600 "${config_file}"
      info "Created ${config_file}"
      return
    fi

    local existing
    if existing=$(extract_ssh_host_block "${config_file}" "${host_name}" 2>/dev/null); then
      warn "Host ${host_name} already exists in SSH config:"
      echo "---"
      echo "${existing}"
      echo "---"
      ask "Update to new settings? [y/N] "
      read -r answer
      if [[ "${answer}" =~ ^[Yy]$ ]]; then
        cp "${config_file}" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        remove_ssh_host_block "${config_file}" "${host_name}"
        printf '\n%s\n' "${block_content}" >> "${config_file}"
        info "Updated Host ${host_name} block"
      else
        info "Keeping existing settings, skipped"
      fi
    else
      printf '\n%s\n' "${block_content}" >> "${config_file}"
      info "Added Host ${host_name} block to ${config_file}"
    fi
  }

  #######################################
  # Prompt for a value with an optional default.
  # Globals:
  #   REPLY — set to the user's answer or the default.
  # Arguments:
  #   description — prompt text.
  #   default     — default value (empty string for required fields).
  #######################################
  prompt_value() {
    local description="$1"
    local default="$2"
    if [[ -n "${default}" ]]; then
      ask "${description} [default: ${default}]: "
      read -r REPLY
      REPLY="${REPLY:-${default}}"
    else
      ask "${description}: "
      read -r REPLY
      while [[ -z "${REPLY}" ]]; do
        warn "This field is required"
        ask "${description}: "
        read -r REPLY
      done
    fi
  }

  #######################################
  # Print a configuration summary table.
  # Arguments:
  #   Alternating key-value pairs.
  #######################################
  print_summary() {
    echo ""
    echo "========================================="
    echo "  Configuration Summary"
    echo "========================================="
    while (( $# > 0 )); do
      printf '  %-20s : %s\n' "$1" "$2"
      shift 2
    done
    echo "========================================="
    echo ""
  }

  #######################################
  # Ask for confirmation; return 1 if not confirmed.
  # Arguments:
  #   message — optional prompt text.
  #######################################
  confirm_or_exit() {
    ask "${1:-Confirm settings above?} [y/N] "
    read -r answer
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
      info "Cancelled"
      return 1
    fi
  }
fi

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
  prompt_value "Relay server IP or hostname" ""
  local relay_host="${REPLY}"

  prompt_value "Relay SSH port" "22"
  local relay_port="${REPLY}"
  validate_port "${relay_port}" "Relay SSH port" || return 1

  prompt_value "Relay username" "${USER}"
  local relay_user="${REPLY}"

  prompt_value "Reverse tunnel port (set on remote machine)" ""
  local tunnel_port="${REPLY}"
  validate_port "${tunnel_port}" "Reverse tunnel port" || return 1

  prompt_value "Remote machine username" "${USER}"
  local remote_user="${REPLY}"

  prompt_value "SSH private key path" "${HOME}/.ssh/id_rsa"
  local ssh_key_path="${REPLY}"

  prompt_value "SSH config Host alias" "my-remote"
  local connection_name="${REPLY}"

  print_summary \
    "Relay Host"      "${relay_host}" \
    "Relay Port"      "${relay_port}" \
    "Relay User"      "${relay_user}" \
    "Tunnel Port"     "${tunnel_port}" \
    "Remote User"     "${remote_user}" \
    "SSH Key Path"    "${ssh_key_path}" \
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
  if [[ -f "${ssh_key_path}" ]]; then
    info "SSH key — found at ${ssh_key_path}"
  else
    warn "SSH key not found at: ${ssh_key_path}"
    ask "Generate a new RSA key at ${ssh_key_path}? [y/N] "
    read -r gen_answer
    if [[ "${gen_answer}" =~ ^[Yy]$ ]]; then
      info "Leave the passphrase empty for automatic SSH connections."
      ssh-keygen -t rsa -b 4096 -f "${ssh_key_path}" -C "${USER}@$(hostname)-client"
      if [[ ! -f "${ssh_key_path}" ]]; then
        error "Key generation failed."
        return 1
      fi
      info "New SSH key generated: ${ssh_key_path}"
    else
      error "An SSH key is required to connect to the relay. Exiting."
      return 1
    fi
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
    echo "  Setup Complete — Connection Successful"
    echo "========================================="
    printf '  %-20s : %s\n' "SSH alias"   "${connection_name}"
    printf '  %-20s : %s\n' "Relay"       "${relay_user}@${relay_host}:${relay_port}"
    printf '  %-20s : %s\n' "Tunnel port" "${tunnel_port}"
    printf '  %-20s : %s\n' "Remote user" "${remote_user}"
    echo "========================================="
    echo ""
    info "Connect to the remote machine at any time with:"
    echo "  ssh ${connection_name}"
    echo ""
  else
    echo ""
    warn "Connection test failed. SSH config was written successfully."
    echo ""
    warn "Troubleshooting tips:"
    echo "  1. Remote tunnel may not be running — start the tunnel service on the remote machine."
    echo "  2. Relay may be unreachable — verify ${relay_host}:${relay_port} is accessible."
    echo "  3. SSH key may not be configured — ensure your public key is in the relay's"
    echo "     authorized_keys and also on the remote machine."
    echo ""
    info "Run the following for verbose debug output:"
    echo "  ssh -v ${connection_name}"
    echo ""
    info "Once the tunnel is active, connect with:"
    echo "  ssh ${connection_name}"
    echo ""
  fi
}

main "$@"
