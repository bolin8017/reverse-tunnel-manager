# 設定指南

本指南說明如何從內部主機建立持久的 SSH 反向隧道到中繼伺服器，並設定客戶端透過隧道
連線。

## 一鍵安裝（推薦）

**Linux / macOS / WSL：**

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

**Windows PowerShell：**

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

安裝程式會下載程式庫並啟動互動式角色選擇選單。若已 clone 程式庫，可直接執行
`bash setup.sh`（Linux/macOS/WSL）或 `.\setup.ps1`（Windows PowerShell）。

## 前置需求

### Remote 主機（內部主機）

- Linux（RHEL、Rocky、CentOS、Fedora、AlmaLinux、Ubuntu 或 Debian）
- `sudo` 權限（僅在 `autossh` 尚未安裝時需要）
- SSH 金鑰對（腳本可自動生成）
- 可連線到 relay 伺服器

### Relay 伺服器（中繼伺服器）

- Linux（RHEL、Rocky、CentOS、Fedora、AlmaLinux、Ubuntu 或 Debian）
- 正在執行 `sshd` 且擁有公開 IP 位址
- `sudo` 權限（僅在 `sshd_config` 需要修改時需要）

### Client 主機（客戶端）

- Linux、macOS、Windows 10+（內建 OpenSSH）或 Windows（WSL）
- SSH 客戶端（`ssh` 指令可用）
- SSH 金鑰對（腳本可自動生成）
- 可連線到 relay 伺服器

## 步驟 1：設定 Relay 伺服器

在 **relay** 主機上執行。腳本會先檢查 `sshd_config`，僅在需要時才修改。

```bash
bash scripts/setup-relay.sh
```

**腳本會做的事：**

1. 讀取 `/etc/ssh/sshd_config` 並驗證四項設定：

   | 選項                   | 值    | 用途 |
   |------------------------|-------|------|
   | `ClientAliveInterval`  | `30`  | 每 30 秒發送 keepalive |
   | `ClientAliveCountMax`  | `3`   | 3 次未回應後斷開連線（約 90 秒） |
   | `AllowTcpForwarding`   | `yes` | 允許 `RemoteForward` 運作 |
   | `PubkeyAuthentication` | `yes` | Tunnel 需使用公鑰認證 |

2. 如果所有設定正確，直接報告成功，不需要 `sudo`。
3. 如果需要修改，要求 `sudo` 來修改、驗證並重新載入 `sshd`。
4. 自動偵測 SSH 服務名稱（Ubuntu/Debian 為 `ssh`，RHEL 為 `sshd`）。

**沒有 sudo 權限？** 腳本會顯示需要的設定。請系統管理員套用後，重新執行腳本進行驗證。

## 步驟 2：設定 Remote 主機

在 **remote**（內部）主機上執行。腳本會互動式收集參數。

```bash
bash scripts/setup-remote.sh
```

### 參數

| 參數                   | 預設值              | 說明 |
|------------------------|---------------------|------|
| Relay 伺服器 IP 或主機名 | *（必填）*          | relay 的公開 IP 或主機名 |
| Relay SSH 埠           | `22`                | relay 上的 SSH 埠 |
| Relay 使用者名稱       | `$USER`             | 你在 relay 上的帳號 |
| 反向隧道埠             | *（必填）*          | 在 relay 上開放的埠（每台主機必須唯一） |
| 本地 SSH 埠            | `22`                | 此主機的 SSH 埠 |
| SSH 私鑰路徑           | `~/.ssh/id_rsa`     | 用於認證到 relay 的金鑰 |

### 腳本會做的事

1. **驗證目前狀態** — 檢查 `autossh`、SSH 金鑰、SSH 設定和 systemd 服務是否已正確
   設定。如果全部正確，報告成功並結束。
2. **安裝 autossh** — 僅在尚未安裝時執行。這是唯一需要 `sudo` 的步驟。
3. **SSH 金鑰處理** — 檢查金鑰是否存在。如果缺少，提供生成 Ed25519（預設）或 RSA-4096 金鑰的選項。
4. **驗證 relay 存取** — 測試到 relay 的 SSH 認證。如果失敗，提供自動執行
   `ssh-copy-id` 的選項。
5. **SSH 設定** — 使用 `templates/ssh-config-relay.template` 模板，在
   `~/.ssh/config` 寫入 `relay-tunnel` Host 區塊。
6. **systemd 使用者服務** — 建立
   `~/.config/systemd/user/ssh-tunnel.service`，啟用並啟動。執行
   `loginctl linger` 使隧道在登出和重新開機後持續運作。
7. **清理舊設定** — 偵測並提供移除舊的 SSH 相關 crontab 項目和殭屍
   `ssh -Nf` 程序的選項。
8. **驗證** — 確認服務正在運作。

## 步驟 3：設定 Client

在 **client** 主機（筆電、工作站）上執行。

```bash
bash scripts/setup-client.sh          # Linux / macOS / WSL
```

```powershell
.\scripts\setup-client.ps1            # Windows PowerShell
```

### 參數

| 參數                        | 預設值          | 說明 |
|-----------------------------|-----------------|------|
| Relay 伺服器 IP 或主機名    | *（必填）*      | relay 的公開 IP 或主機名 |
| Relay SSH 埠                | `22`            | relay 上的 SSH 埠 |
| Relay 使用者名稱            | `$USER`         | 你在 relay 上的帳號 |
| 反向隧道埠                  | *（必填）*      | remote 主機上設定的埠 |
| Remote 主機使用者名稱       | `$USER`         | 你在 remote 主機上的帳號 |
| SSH 私鑰路徑                | `~/.ssh/id_rsa` | 用於認證到 relay 的金鑰 |
| SSH 設定 Host 別名          | `my-remote`     | 連線的別名 |

### 腳本會做的事

1. **平台檢查** — 偵測作業系統。原生支援 Linux、macOS 及 Windows PowerShell
   （`setup-client.ps1`）。
2. **驗證目前狀態** — 檢查 SSH 設定區塊是否已存在且正確。如果一切已設定完成，
   直接跳到連線測試。
3. **SSH 金鑰處理** — 檢查金鑰是否存在。如果缺少，提供生成 Ed25519（預設）或 RSA-4096 金鑰的選項。
4. **驗證 relay 存取** — 測試 SSH 認證。如果失敗，提供自動執行 `ssh-copy-id` 的選項。
5. **SSH 設定** — 使用 `ProxyJump` 寫入 Host 區塊，實現無縫多跳 SSH
   （僅在區塊需要建立或更新時執行）。
6. **連線測試** — 嘗試 `ssh <別名>` 驗證端對端連線。

### 連線

設定完成後，隨時使用以下指令連線到 remote 主機：

```bash
ssh my-remote
```

## 埠分配

每台 remote 主機必須使用 relay 上**唯一的隧道埠**。請自行管理分配以避免衝突：

| 使用者 / 主機       | 隧道埠    | 備註 |
|----------------------|-----------|------|
| alice — 工作站       | `52022`   | 主要工作機 |
| alice — 實驗室伺服器 | `52023`   | 次要主機 |
| bob — 桌機           | `52100`   | 不同使用者，不同埠範圍 |

腳本不會強制唯一性。如果兩台主機綁定相同的埠，第二台會出現
`remote port forwarding failed` 錯誤。

## 不使用 Git 安裝

若沒有 `git`，一鍵安裝程式可自動處理——在 Linux/macOS/WSL 上使用 `curl`，在
Windows PowerShell 上使用 `Invoke-WebRequest` 下載並解壓縮程式庫，無需 `git`。
請參閱本指南頂部的[一鍵安裝](#一鍵安裝推薦)章節。
