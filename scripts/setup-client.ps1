#Requires -Version 5.1
<#
.SYNOPSIS
  Configure the client machine (laptop) to connect through a relay server
  to a remote machine via SSH reverse tunnel.
.DESCRIPTION
  PowerShell native equivalent of scripts/setup-client.sh for Windows.
  Requires Windows 10+ with built-in OpenSSH client.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Color helpers ──────────────────────────────────────────────────
function Write-Info  { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] $Msg" -ForegroundColor Red }
function Write-Ask   { param([string]$Msg) Write-Host "[?] $Msg" -ForegroundColor Cyan -NoNewline }

# ── Utility functions ──────────────────────────────────────────────

function Expand-TildePath {
  param([string]$Path)
  return ($Path -replace '^~', $env:USERPROFILE)
}

function Test-ValidPort {
  param([string]$Value, [string]$Label = 'Port')
  $port = 0
  if (-not [int]::TryParse($Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    Write-Err "$Label must be a number between 1 and 65535, got: '$Value'"
    return $false
  }
  return $true
}

function Read-PromptValue {
  param([string]$Description, [string]$Default = '')
  if ($Default) {
    Write-Ask "$Description [default: $Default]: "
    $reply = Read-Host
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply.Trim()
  }
  else {
    Write-Ask "${Description}: "
    $reply = Read-Host
    while ([string]::IsNullOrWhiteSpace($reply)) {
      Write-Warn 'This field is required'
      Write-Ask "${Description}: "
      $reply = Read-Host
    }
    return $reply.Trim()
  }
}

function Read-PromptStep {
  param(
    [int]$Step, [int]$Total, [string]$Title,
    [string]$Description, [string]$Default = ''
  )
  Write-Host ''
  Write-Info "Step $Step/$($Total): $Title"
  return (Read-PromptValue -Description $Description -Default $Default)
}

function Show-Summary {
  param([hashtable[]]$Items)
  Write-Host ''
  Write-Host '========================================='
  Write-Host '  Configuration Summary'
  Write-Host '========================================='
  foreach ($item in $Items) {
    Write-Host ("  {0,-20} : {1}" -f $item.Key, $item.Value)
  }
  Write-Host '========================================='
  Write-Host ''
}

# ── SSH config helpers ─────────────────────────────────────────────

function Get-SshConfigPath {
  return (Join-Path (Join-Path $env:USERPROFILE '.ssh') 'config')
}

function Ensure-SshDirectory {
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-Info "Created $sshDir"
  }
}

function Get-SshHostBlock {
  param([string]$ConfigPath, [string]$HostName)
  if (-not (Test-Path $ConfigPath)) { return $null }
  $lines = Get-Content $ConfigPath
  $found = $false
  $block = @()
  foreach ($line in $lines) {
    if ($line -match '^Host\s+') {
      if ($found) { break }
      if ($line -match "^Host\s+$([regex]::Escape($HostName))\s*$") {
        $found = $true
      }
    }
    if ($found) { $block += $line }
  }
  if ($block.Count -gt 0) { return ($block -join "`n") }
  return $null
}

function Remove-SshHostBlock {
  param([string]$ConfigPath, [string]$HostName)
  $lines = Get-Content $ConfigPath
  $skip = $false
  $output = @()
  foreach ($line in $lines) {
    if ($line -match '^Host\s+') {
      if ($line -match "^Host\s+$([regex]::Escape($HostName))\s*$") {
        $skip = $true
        continue
      }
      else { $skip = $false }
    }
    elseif ($line -match '^\S' -and $line -notmatch '^Host\s+') {
      $skip = $false
    }
    if (-not $skip) { $output += $line }
  }
  # Trim trailing blank lines
  while ($output.Count -gt 0 -and [string]::IsNullOrWhiteSpace($output[-1])) {
    $output = $output[0..($output.Count - 2)]
  }
  Set-Content -Path $ConfigPath -Value ($output -join "`n") -NoNewline
  Add-Content -Path $ConfigPath -Value ''
}

function Set-SshHostBlock {
  param([string]$ConfigPath, [string]$HostName, [string]$BlockContent)
  Ensure-SshDirectory
  if (-not (Test-Path $ConfigPath)) {
    Set-Content -Path $ConfigPath -Value $BlockContent
    Write-Info "Created $ConfigPath"
    return
  }
  $existing = Get-SshHostBlock -ConfigPath $ConfigPath -HostName $HostName
  if ($null -ne $existing) {
    Write-Warn "Host $HostName already exists in SSH config:"
    Write-Host '---'
    Write-Host $existing
    Write-Host '---'
    Write-Ask 'Update to new settings? [y/N] '
    $answer = Read-Host
    if ($answer -match '^[Yy]$') {
      $backup = "$ConfigPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
      Copy-Item $ConfigPath $backup
      Remove-SshHostBlock -ConfigPath $ConfigPath -HostName $HostName
      Add-Content -Path $ConfigPath -Value "`n$BlockContent"
      Write-Info "Updated Host $HostName block"
    }
    else {
      Write-Info 'Keeping existing settings, skipped'
    }
  }
  else {
    Add-Content -Path $ConfigPath -Value "`n$BlockContent"
    Write-Info "Added Host $HostName block to $ConfigPath"
  }
}

# ── ssh-copy-id equivalent ────────────────────────────────────────

function Copy-SshKeyToRelay {
  param(
    [string]$KeyPath, [string]$RelayUser,
    [string]$RelayHost, [string]$RelayPort
  )
  $pubKeyPath = "$KeyPath.pub"
  if (-not (Test-Path $pubKeyPath)) {
    Write-Err "Public key not found: $pubKeyPath"
    return $false
  }
  $pubKey = (Get-Content $pubKeyPath -Raw).Trim()
  Write-Info 'Copying public key to relay (you may be prompted for the password)...'
  try {
    ssh -p $RelayPort "$RelayUser@$RelayHost" `
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    return $true
  }
  catch {
    Write-Err "Failed to copy key to relay: $_"
    return $false
  }
}

# ── Main ───────────────────────────────────────────────────────────

function Main {
  Write-Host ''
  Write-Host '========================================='
  Write-Host '  Reverse Tunnel Manager — Client Setup'
  Write-Host '========================================='
  Write-Host ''

  # Check OpenSSH availability
  if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Err 'ssh is not available. Please enable OpenSSH Client in Windows Settings.'
    Write-Err 'Settings > Apps > Optional Features > OpenSSH Client'
    return
  }

  $totalSteps = 7

  # ── Parameter collection ──
  $relayHost = Read-PromptStep 1 $totalSteps 'Relay host' `
    'IP address or hostname of your relay server'

  $relayPort = Read-PromptStep 2 $totalSteps 'Relay SSH port' `
    'Relay SSH port' '22'
  if (-not (Test-ValidPort $relayPort 'Relay SSH port')) { return }

  $relayUser = Read-PromptStep 3 $totalSteps 'Relay username' `
    'Relay username' $env:USERNAME

  $tunnelPort = Read-PromptStep 4 $totalSteps 'Tunnel port' `
    'Reverse tunnel port (set during remote setup)'
  if (-not (Test-ValidPort $tunnelPort 'Tunnel port')) { return }

  $remoteUser = Read-PromptStep 5 $totalSteps 'Remote username' `
    'Remote machine username' $env:USERNAME

  # SSH key selection — detect existing keys
  Write-Host ''
  Write-Info "Step 6/$($totalSteps): SSH key"
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  $optLabels = @()
  $optPaths = @()
  $optTypes = @()
  $optBits = @()
  $optExists = @()

  $ed25519Path = Join-Path $sshDir 'id_ed25519'
  $rsaPath = Join-Path $sshDir 'id_rsa'

  if (Test-Path $ed25519Path) {
    $optLabels += "Use $ed25519Path (Ed25519)"
    $optPaths += $ed25519Path; $optTypes += 'ed25519'; $optBits += ''; $optExists += $true
  }
  if (Test-Path $rsaPath) {
    $optLabels += "Use $rsaPath (RSA)"
    $optPaths += $rsaPath; $optTypes += 'rsa'; $optBits += '4096'; $optExists += $true
  }

  $existingCount = $optLabels.Count
  if ($existingCount -gt 0) {
    Write-Host '  Found existing keys:'
    for ($i = 0; $i -lt $existingCount; $i++) {
      Write-Host ("    [{0}] {1}" -f ($i + 1), $optLabels[$i])
    }
    Write-Host '  Generate new:'
  }
  else {
    Write-Host "  No existing keys found in $sshDir/"
  }

  $optLabels += 'Generate new Ed25519 key (recommended)'
  $optPaths += $ed25519Path; $optTypes += 'ed25519'; $optBits += ''; $optExists += $false
  $optLabels += 'Generate new RSA-4096 key'
  $optPaths += $rsaPath; $optTypes += 'rsa'; $optBits += '4096'; $optExists += $false

  for ($i = $existingCount; $i -lt $optLabels.Count; $i++) {
    Write-Host ("    [{0}] {1}" -f ($i + 1), $optLabels[$i])
  }

  $maxOpt = $optLabels.Count
  Write-Ask "Choose [1-$maxOpt, default: 1]: "
  $keyChoice = Read-Host
  if (-not $keyChoice) { $keyChoice = '1' }
  $keyIdx = [int]$keyChoice - 1
  if ($keyIdx -lt 0 -or $keyIdx -ge $maxOpt) { $keyIdx = 0 }

  $sshKeyPath = $optPaths[$keyIdx]
  $keyType = $optTypes[$keyIdx]
  $keyBits = $optBits[$keyIdx]
  $sshKeyExists = $optExists[$keyIdx]

  $connectionName = Read-PromptStep 7 $totalSteps 'Connection alias' `
    'SSH config Host alias (connect with: ssh <alias>)' 'my-remote'

  # ── Summary ──
  Show-Summary @(
    @{Key='Relay Host';      Value=$relayHost},
    @{Key='Relay Port';      Value=$relayPort},
    @{Key='Relay User';      Value=$relayUser},
    @{Key='Tunnel Port';     Value=$tunnelPort},
    @{Key='Remote User';     Value=$remoteUser},
    @{Key='SSH Key';         Value="$sshKeyPath ($keyType)"},
    @{Key='Connection Name'; Value=$connectionName}
  )

  Write-Ask 'Proceed with these settings? [y/N] '
  $confirm = Read-Host
  if ($confirm -notmatch '^[Yy]$') {
    Write-Info 'Cancelled'
    return
  }

  # ── SSH config block ──
  $expectedBlock = @"
Host $connectionName
    HostName localhost
    Port $tunnelPort
    User $remoteUser
    IdentityFile $sshKeyPath
    ProxyJump ${relayUser}@${relayHost}:${relayPort}
    ServerAliveInterval 60
    ServerAliveCountMax 3
"@

  $configPath = Get-SshConfigPath
  $needsSshConfig = $false

  Write-Info 'Verifying current configuration...'
  $existingBlock = Get-SshHostBlock -ConfigPath $configPath -HostName $connectionName
  if ($null -ne $existingBlock) {
    if ($existingBlock.Trim() -eq $expectedBlock.Trim()) {
      Write-Info "SSH config — $connectionName block is correct"
    }
    else {
      Write-Warn "SSH config — $connectionName block exists but differs"
      $needsSshConfig = $true
    }
  }
  else {
    Write-Warn "SSH config — $connectionName block not found"
    $needsSshConfig = $true
  }

  # ── SSH key handling ──
  if ($sshKeyExists) {
    Write-Info "SSH key — using $sshKeyPath"
  }
  else {
    Write-Info "Generating $keyType key at $sshKeyPath..."
    Write-Info 'Leave the passphrase empty for automatic SSH connections.'
    $keygenArgs = @('-t', $keyType, '-f', $sshKeyPath, '-C', "$env:USERNAME@$env:COMPUTERNAME-client")
    if ($keyBits) { $keygenArgs += @('-b', $keyBits) }
    & ssh-keygen @keygenArgs
    if (-not (Test-Path $sshKeyPath)) {
      Write-Err 'Key generation failed.'
      return
    }
    Write-Info "New SSH key generated: $sshKeyPath"
  }

  # ── Verify relay access ──
  Write-Info "Verifying SSH access to relay ($relayUser@${relayHost}:$relayPort)..."
  $sshTest = $null
  try {
    $sshTest = & ssh -o ConnectTimeout=10 -o BatchMode=yes `
      -p $relayPort -i $sshKeyPath `
      "$relayUser@$relayHost" 'echo ok' 2>$null
  }
  catch {}

  if ($sshTest -eq 'ok') {
    Write-Info 'SSH access to relay — OK'
  }
  else {
    Write-Warn 'Cannot authenticate to relay with this key.'
    Write-Ask 'Automatically copy key to relay? [Y/n] '
    $copyAnswer = Read-Host
    if ($copyAnswer -notmatch '^[Nn]$') {
      $copyResult = Copy-SshKeyToRelay -KeyPath $sshKeyPath `
        -RelayUser $relayUser -RelayHost $relayHost -RelayPort $relayPort
      if (-not $copyResult) {
        Write-Err 'Failed to copy key. Please add it manually, then re-run.'
        Write-Host "  ssh-keygen -y -f $sshKeyPath | ssh -p $relayPort $relayUser@$relayHost `"cat >> ~/.ssh/authorized_keys`""
        return
      }
      Write-Info 'Key copied to relay successfully.'
    }
    else {
      Write-Warn 'Relay access not configured. Connection test will likely fail.'
    }
  }

  # ── Write SSH config ──
  if ($needsSshConfig) {
    Write-Info "Writing SSH config block for alias: $connectionName"
    Set-SshHostBlock -ConfigPath $configPath -HostName $connectionName -BlockContent $expectedBlock
  }
  else {
    Write-Info 'SSH config is already up to date — skipping.'
  }

  # ── Connection test ──
  Write-Info "Testing connection to $connectionName ..."
  Write-Host ''

  $testResult = $null
  try {
    $testResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes `
      $connectionName 'echo Connection OK' 2>$null
  }
  catch {}

  if ($testResult -match 'Connection OK') {
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Setup Complete — All Done!'
    Write-Host '========================================='
    Write-Host ("  {0,-20} : {1}" -f 'SSH alias', $connectionName)
    Write-Host ("  {0,-20} : {1}" -f 'Relay', "${relayUser}@${relayHost}:${relayPort}")
    Write-Host ("  {0,-20} : {1}" -f 'Tunnel port', $tunnelPort)
    Write-Host ("  {0,-20} : {1}" -f 'Remote user', $remoteUser)
    Write-Host '========================================='
    Write-Host ''
    Write-Info 'Connect now:'
    Write-Host "  ssh $connectionName"
    Write-Host ''
  }
  else {
    Write-Host ''
    Write-Warn 'Connection test failed. SSH config was written successfully.'
    Write-Host ''
    Write-Warn 'If connection fails, common causes:'
    Write-Host '  1. Remote tunnel not running'
    Write-Host '     -> On remote: systemctl --user status ssh-tunnel.service'
    Write-Host "  2. Relay unreachable"
    Write-Host "     -> Verify: ssh ${relayUser}@${relayHost} -p ${relayPort}"
    Write-Host '  3. SSH key not authorized'
    Write-Host '     -> Check authorized_keys on relay and remote'
    Write-Host ''
    Write-Info 'Verbose debug:'
    Write-Host "  ssh -v $connectionName"
    Write-Host ''
    Write-Info 'Once the tunnel is active, connect with:'
    Write-Host "  ssh $connectionName"
    Write-Host ''
  }
}

Main
