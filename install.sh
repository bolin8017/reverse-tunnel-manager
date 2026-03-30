#!/usr/bin/env bash
# install.sh — Bootstrap installer for Reverse Tunnel Manager.
# Designed for: curl -fsSL <URL> | bash
#
# Downloads the repository and hands off to setup.sh.
set -euo pipefail

readonly REPO_URL="https://github.com/bolin8017/reverse-tunnel-manager.git"
readonly REPO_NAME="reverse-tunnel-manager"
readonly TARBALL_URL="https://github.com/bolin8017/reverse-tunnel-manager/archive/refs/heads/main.tar.gz"

info()  { printf '\033[0;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

main() {
  info "Reverse Tunnel Manager — Installer"
  echo ""

  # ── Determine download location ──
  local install_dir="${HOME}/${REPO_NAME}"

  if [[ -d "${install_dir}" && -f "${install_dir}/setup.sh" ]]; then
    info "Found existing installation at ${install_dir}"
    exec bash "${install_dir}/setup.sh" < /dev/tty
  fi

  # ── Download ──
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "${tmp_dir}"' EXIT

  if command -v git &>/dev/null; then
    info "Downloading via git..."
    git clone --depth 1 "${REPO_URL}" "${tmp_dir}/${REPO_NAME}" 2>&1 | tail -1
  elif command -v curl &>/dev/null; then
    info "Downloading via curl..."
    curl -fsSL "${TARBALL_URL}" | tar -xz -C "${tmp_dir}"
    # GitHub tarballs extract to <repo>-<branch>/
    mv "${tmp_dir}/${REPO_NAME}-main" "${tmp_dir}/${REPO_NAME}"
  elif command -v wget &>/dev/null; then
    info "Downloading via wget..."
    wget -qO- "${TARBALL_URL}" | tar -xz -C "${tmp_dir}"
    mv "${tmp_dir}/${REPO_NAME}-main" "${tmp_dir}/${REPO_NAME}"
  else
    error "git, curl, or wget is required but none were found."
    error "Please install one and try again."
    exit 1
  fi

  if [[ ! -f "${tmp_dir}/${REPO_NAME}/setup.sh" ]]; then
    error "Download failed — setup.sh not found."
    exit 1
  fi

  info "Download complete."
  echo ""

  # ── Run setup (not exec — allow EXIT trap to clean up tmp_dir) ──
  bash "${tmp_dir}/${REPO_NAME}/setup.sh" < /dev/tty
}

main "$@"
