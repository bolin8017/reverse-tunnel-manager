# Reverse Tunnel Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

> **[English](../../README.md)**

一組 Shell 腳本，使用 [autossh](https://www.harding.motd.ca/autossh/) 和 systemd
建立持久的 SSH 反向隧道。讓位於 NAT 或防火牆後方的主機（無需公開 IP）透過中繼伺服器
接受 SSH 連線。

## 架構

```
remote（內部主機）──autossh RemoteForward──>  relay（公開 IP）<──ProxyJump──  client（筆電）
```

| 角色       | 說明 |
|------------|------|
| **remote** | 位於 NAT / 防火牆後方的主機。執行 `autossh` 維持反向隧道到 relay。 |
| **relay**  | 擁有公開 IP 的伺服器，作為跳板主機。 |
| **client** | 你的筆電或工作站。透過 relay 連接到 remote。 |

## 支援平台

| 角色       | Linux (RHEL/Rocky/CentOS/Fedora/Alma) | Linux (Ubuntu/Debian) | macOS | Windows (PowerShell) |
|------------|:--------------------------------------:|:---------------------:|:-----:|:--------------------:|
| **remote** | 支援 | 支援 | - | - |
| **relay**  | 支援 | 支援 | - | - |
| **client** | 支援 | 支援 | 支援 | 支援 |

## 快速開始

**Linux / macOS / WSL — 一鍵安裝：**

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

**Windows PowerShell — 一鍵安裝：**

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

安裝程式會下載程式庫並啟動互動式角色選擇選單。

**若已 clone 程式庫：**

```bash
bash setup.sh        # Linux / macOS / WSL
```

```powershell
.\setup.ps1          # Windows PowerShell
```

**或直接執行個別腳本：**

**步驟 1** — 在 relay 伺服器上：

```bash
bash scripts/setup-relay.sh
```

**步驟 2** — 在 remote（內部）主機上：

```bash
bash scripts/setup-remote.sh
```

**步驟 3** — 在 client（筆電）上：

```bash
bash scripts/setup-client.sh          # Linux / macOS / WSL
```

```powershell
.\scripts\setup-client.ps1            # Windows PowerShell
```

設定完成後，隨時連線到 remote 主機：

```bash
ssh my-remote
```

詳細說明請參閱[設定指南](getting-started.md)。

## 常用指令

```bash
# remote 主機 — 管理隧道服務
systemctl --user status ssh-tunnel.service
systemctl --user restart ssh-tunnel.service
journalctl --user -u ssh-tunnel.service -f

# relay — 檢查隧道埠
ss -tlnp | grep sshd
```

## 文件

| 文件 | 說明 |
|------|------|
| [設定指南](getting-started.md) | 詳細的安裝步驟、前置需求與參數說明 |
| [架構說明](architecture.md) | 系統設計、資料流向與埠管理 |
| [常見問題排解](troubleshooting.md) | FAQ、常見錯誤、除錯指令與解除安裝 |

## 開發

```bash
make check    # 語法檢查所有腳本
make lint     # 執行 shellcheck
```

本專案遵循 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)。

## 授權

[MIT](../../LICENSE)
