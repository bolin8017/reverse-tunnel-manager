#Requires -Version 5.1
<#
.SYNOPSIS
  Unified entry point for Reverse Tunnel Manager on Windows.
  Offers Client role setup; Relay and Remote require Linux.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Main {
  Write-Host ''
  Write-Host '========================================='
  Write-Host '  Reverse Tunnel Manager — Windows'
  Write-Host '========================================='
  Write-Host ''
  Write-Host '  Architecture:'
  Write-Host ''
  Write-Host '    ┌──────────┐         ┌──────────┐         ┌──────────┐'
  Write-Host '    │  Remote  │ ──SSH──>│  Relay   │<──SSH── │  Client  │  <-- you'
  Write-Host '    │ internal │ tunnel  │  public  │ProxyJump│  laptop  │'
  Write-Host '    └──────────┘         └──────────┘         └──────────┘'
  Write-Host ''
  Write-Host '  This script will configure the Client role'
  Write-Host '  (connect to an internal machine through a relay).'
  Write-Host ''
  Write-Host '  For Relay and Remote setup, run on a Linux machine:'
  Write-Host '    curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash'
  Write-Host ''

  Write-Host '[?] Continue with Client setup? [Y/n] ' -ForegroundColor Cyan -NoNewline
  $answer = Read-Host
  if ($answer -match '^[Nn]$') {
    Write-Host '[INFO] Bye.' -ForegroundColor Green
    return
  }

  $clientScript = Join-Path $ScriptDir 'scripts' 'setup-client.ps1'
  if (-not (Test-Path $clientScript)) {
    Write-Host "[ERROR] Cannot find $clientScript" -ForegroundColor Red
    return
  }

  & $clientScript
}

Main
