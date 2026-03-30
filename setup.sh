#!/usr/bin/env bash
# setup.sh — Unified entry point for Reverse Tunnel Manager.
# Displays role selection menu and dispatches to the appropriate setup script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Color helpers (inline — this script does not source common.sh).
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
info()  { printf '%b[INFO]%b %s\n' "${GREEN}" "${NC}" "$*"; }
warn()  { printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
error() { printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$*" >&2; }
ask()   { printf '%b[?]%b %s' "${BLUE}" "${NC}" "$*"; }

#######################################
# Display the welcome screen with architecture diagram and role menu.
# Returns the user's choice in the global ROLE_CHOICE.
#######################################
show_menu() {
  echo ""
  echo "========================================="
  echo "  Reverse Tunnel Manager"
  echo "========================================="
  echo ""
  echo "  Architecture:"
  echo ""
  echo "    ┌──────────┐         ┌──────────┐         ┌──────────┐"
  echo "    │  Remote   │ ──SSH──>│  Relay   │<──SSH── │  Client  │"
  echo "    │ internal  │ tunnel  │  public  │ProxyJump│  laptop  │"
  echo "    │ no pub IP │         │  has IP  │         │          │"
  echo "    └──────────┘         └──────────┘         └──────────┘"
  echo ""
  echo "  Which role should this machine play?"
  echo ""
  echo "    1) Relay  — Public server (set up FIRST)              [Linux]"
  echo "    2) Remote — Internal machine behind NAT/firewall      [Linux]"
  echo "    3) Client — Your laptop/workstation                   [All platforms]"
  echo ""
  echo "    q) Quit"
  echo ""
  ask "Choose [1/2/3/q]: "
}

#######################################
# Validate platform for the selected role.
# Arguments:
#   role — "relay", "remote", or "client".
# Returns:
#   0 if allowed, 1 if blocked.
#######################################
validate_platform() {
  local role="$1"
  local platform
  platform="$(uname -s)"

  case "${platform}" in
    Linux)
      return 0
      ;;
    Darwin)
      if [[ "${role}" == "client" ]]; then
        return 0
      fi
      warn "${role^} setup requires systemd, which macOS does not support natively."
      warn "Typically the ${role} is a Linux server (e.g., a VPS)."
      ask "Continue anyway? [y/N] "
      read -r answer
      if [[ "${answer}" =~ ^[Yy]$ ]]; then
        return 0
      fi
      return 1
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if [[ "${role}" == "client" ]]; then
        warn "Detected Git Bash on Windows."
        warn "For the best experience, use the native PowerShell version:"
        echo "  irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex"
        ask "Continue with bash version? [y/N] "
        read -r answer
        if [[ "${answer}" =~ ^[Yy]$ ]]; then
          return 0
        fi
        return 1
      fi
      error "${role^} setup requires a Linux environment (systemd + sshd)."
      error "Detected: Windows (${platform})"
      echo ""
      echo "  Suggestions:"
      echo "    1. SSH into your Linux server, then run this script there"
      echo "    2. Use WSL: wsl bash setup.sh"
      echo ""
      ask "Press Enter to return to menu..."
      read -r
      return 1
      ;;
    *)
      warn "Unrecognized platform: ${platform}. Proceeding anyway."
      return 0
      ;;
  esac
}

main() {
  while true; do
    show_menu
    read -r choice

    case "${choice}" in
      1)
        if validate_platform "relay"; then
          exec bash "${SCRIPT_DIR}/scripts/setup-relay.sh"
        fi
        ;;
      2)
        if validate_platform "remote"; then
          exec bash "${SCRIPT_DIR}/scripts/setup-remote.sh"
        fi
        ;;
      3)
        if validate_platform "client"; then
          exec bash "${SCRIPT_DIR}/scripts/setup-client.sh"
        fi
        ;;
      q|Q)
        info "Bye."
        return 0
        ;;
      *)
        warn "Invalid choice. Please enter 1, 2, 3, or q."
        ;;
    esac
  done
}

main "$@"
