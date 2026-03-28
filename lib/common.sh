#!/usr/bin/env bash
# common.sh — Shared helper functions for reverse-tunnel-manager.
#
# Source this file from setup scripts:
#   source "${SCRIPT_DIR}/lib/common.sh"

# Guard against direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: common.sh should be sourced, not executed directly." >&2
  exit 1
fi

# Disable color when output is not a terminal.
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

#######################################
# Print an info message to stdout.
# Arguments:
#   Message string.
#######################################
info() { printf '%b[INFO]%b %s\n' "${GREEN}" "${NC}" "$*"; }

#######################################
# Print a warning message to stderr.
# Arguments:
#   Message string.
#######################################
warn() { printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$*" >&2; }

#######################################
# Print an error message with timestamp to stderr.
# Arguments:
#   Message string.
#######################################
error() {
  printf '%b[ERROR %s]%b %s\n' \
    "${RED}" "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${NC}" "$*" >&2
}

#######################################
# Print a prompt/question to stdout (no trailing newline).
# Arguments:
#   Message string.
#######################################
ask() { printf '%b[?]%b %s' "${BLUE}" "${NC}" "$*"; }

#######################################
# Detect the operating system and set the package manager.
# Globals:
#   OS_FAMILY — set to "rhel", "debian", or "macos".
#   PKG_MGR  — set to "dnf", "yum", "apt", or "brew".
#   PLATFORM — set to "linux", "macos", or "windows".
# Returns:
#   1 if OS is unsupported or undetectable.
#######################################
# Globals are used by callers after sourcing.
# shellcheck disable=SC2034
detect_os() {
  case "$(uname -s)" in
    Linux)
      PLATFORM="linux"
      if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect Linux distribution (/etc/os-release not found)"
        return 1
      fi
      # shellcheck source=/dev/null
      . /etc/os-release
      case "${ID}" in
        rocky|centos|rhel|fedora|almalinux)
          OS_FAMILY="rhel"
          if command -v dnf &>/dev/null; then
            PKG_MGR="dnf"
          else
            PKG_MGR="yum"
          fi
          ;;
        ubuntu|debian|linuxmint|pop)
          OS_FAMILY="debian"
          PKG_MGR="apt"
          ;;
        *)
          error "Unsupported Linux distribution: ${ID}"
          error "Supported: Rocky/CentOS/RHEL/Fedora/AlmaLinux/Ubuntu/Debian"
          return 1
          ;;
      esac
      info "Detected OS: ${PRETTY_NAME} (${OS_FAMILY}, package manager: ${PKG_MGR})"
      ;;
    Darwin)
      PLATFORM="macos"
      OS_FAMILY="macos"
      if command -v brew &>/dev/null; then
        PKG_MGR="brew"
      else
        PKG_MGR=""
        warn "Homebrew not found. Package installation may require manual steps."
      fi
      info "Detected OS: macOS $(sw_vers -productVersion 2>/dev/null || echo '(unknown version)')"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM="windows"
      OS_FAMILY="windows"
      PKG_MGR=""
      warn "Running under Windows ($(uname -s)). Some features may not be available."
      ;;
    *)
      error "Unsupported platform: $(uname -s)"
      return 1
      ;;
  esac
}

#######################################
# Check if sudo access is available.
# Globals:
#   HAS_SUDO — set to "true" or "false".
#######################################
# shellcheck disable=SC2034
check_sudo() {
  if sudo -n true 2>/dev/null; then
    HAS_SUDO=true
    info "sudo access confirmed (passwordless)"
  elif sudo true; then
    HAS_SUDO=true
    info "sudo access confirmed"
  else
    HAS_SUDO=false
    warn "No sudo access (some operations may require manual setup)"
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
# Outputs:
#   Writes the matching Host block to stdout.
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
# If the host already exists, prompt the user before replacing.
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
# Ensure ~/.ssh directory exists with correct permissions (700).
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
#   Alternating key-value pairs: "key1" "value1" "key2" "value2" ...
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
