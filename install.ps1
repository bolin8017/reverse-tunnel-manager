#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap installer for Reverse Tunnel Manager on Windows.
  Designed for: irm <URL> | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoUrl     = 'https://github.com/bolin8017/reverse-tunnel-manager.git'
$RepoName    = 'reverse-tunnel-manager'
$ZipUrl      = 'https://github.com/bolin8017/reverse-tunnel-manager/archive/refs/heads/main.zip'

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Err  { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Main {
  Write-Info 'Reverse Tunnel Manager — Installer'
  Write-Host ''

  # ── Check for existing installation ──
  $installDir = Join-Path $env:USERPROFILE $RepoName
  if ((Test-Path (Join-Path $installDir 'setup.ps1'))) {
    Write-Info "Found existing installation at $installDir"
    & (Join-Path $installDir 'setup.ps1')
    return
  }

  # ── Download ──
  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "rtm-install-$(Get-Random)"
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

  try {
    if (Get-Command git -ErrorAction SilentlyContinue) {
      Write-Info 'Downloading via git...'
      git clone --depth 1 $RepoUrl (Join-Path $tmpDir $RepoName) 2>&1 | Out-Null
    }
    else {
      Write-Info 'Downloading via Invoke-WebRequest...'
      $zipPath = Join-Path $tmpDir 'repo.zip'
      Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
      Expand-Archive -Path $zipPath -DestinationPath $tmpDir
      Rename-Item (Join-Path $tmpDir "$RepoName-main") (Join-Path $tmpDir $RepoName)
    }

    $setupScript = Join-Path $tmpDir $RepoName 'setup.ps1'
    if (-not (Test-Path $setupScript)) {
      Write-Err 'Download failed — setup.ps1 not found.'
      return
    }

    Write-Info 'Download complete.'
    Write-Host ''

    & $setupScript
  }
  finally {
    if (Test-Path $tmpDir) {
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
  }
}

Main
