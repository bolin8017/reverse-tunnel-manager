# 架構說明

## 概述

Reverse Tunnel Manager 使用 SSH 反向埠轉發，讓位於 NAT 或防火牆後方的主機可被存取。
系統包含三個角色：remote、relay 和 client。

## 網路拓撲

```
                              Internet
                                 |
  remote（內部主機）             |          client（你的筆電）
    |                            |               |
    |--- autossh 隧道 --------->|<--- SSH -------|
    |  RemoteForward PORT        |  ProxyJump     |
    |                       relay（跳板伺服器）   |
    |                       擁有公開 IP           |
```

## 資料流向

1. **Remote 到 Relay** — `autossh` 建立持久的 SSH 連線到 relay，使用
   `RemoteForward TUNNEL_PORT localhost:22`。這會在 relay 上將
   `127.0.0.1:TUNNEL_PORT` 綁定到 remote 的 22 埠。

2. **Client 到 Remote** — 客戶端執行 `ssh my-remote`，透過 `ProxyJump` 先連接到
   relay，再連接到 relay 上的 `localhost:TUNNEL_PORT`，最終到達 remote 的 22 埠。

## 元件

### `lib/common.sh`

設定腳本共用的函式庫。`setup-remote.sh` 和 `setup-client.sh` 必須依賴此檔案；
`setup-relay.sh` 包含內嵌備援函式，可獨立執行。提供：

- 彩色輸出函式（`info`、`warn`、`error`、`ask`）
- 作業系統偵測（`detect_os`）— 設定 `PLATFORM`、`OS_FAMILY`、`PKG_MGR`
- SSH 設定操作（`extract_ssh_host_block`、`remove_ssh_host_block`、
  `upsert_ssh_host_block`）
- 輸入驗證（`validate_port`）
- 互動式提示（`prompt_value`、`confirm_or_exit`）

### `scripts/setup-relay.sh`

設定 relay 伺服器的 `sshd_config`。修改前先驗證設定。自動偵測 SSH 服務名稱
（`ssh` 或 `sshd`）。

### `scripts/setup-remote.sh`

設定內部主機。安裝 `autossh`、寫入 SSH 設定、建立 systemd 使用者服務，並驗證隧道
是否運作。僅對尚未正確設定的元件進行變更。

### `scripts/setup-client.sh`

設定 Linux、macOS 或 WSL 客戶端主機。使用 `ProxyJump` 寫入 SSH 設定、管理 SSH
金鑰，並測試連線。需要 `lib/common.sh`。

### `scripts/setup-client.ps1`

`setup-client.sh` 的 Windows PowerShell 版本。使用 `ProxyJump` 寫入 SSH 設定、
管理 SSH 金鑰，並測試連線。支援與 Bash 版本相同的互動式參數。

### `setup.sh` / `setup.ps1`

統一入口點，顯示互動式角色選擇選單（relay / remote / client）及架構示意圖，
再委派給對應的角色腳本。`setup.sh` 適用於 Linux/macOS/WSL；`setup.ps1` 適用於
Windows PowerShell。

### `install.sh` / `install.ps1`

一鍵安裝引導腳本。`install.sh` 使用 `curl` + `tar`（或 `git clone`）下載程式庫
並啟動 `setup.sh`。`install.ps1` 使用 `Invoke-WebRequest` 下載並解壓縮程式庫，
再啟動 `setup.ps1`。設計為可直接從網路管線執行：

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/bolin8017/reverse-tunnel-manager/main/install.ps1 | iex
```

### `templates/`

- `ssh-config-relay.template` — remote 主機連接 relay 的 SSH 設定區塊。
- `ssh-tunnel.service.template` — `autossh` 的 systemd 使用者服務單元。

模板使用 `{{PLACEHOLDER}}` 語法，在設定時由 `sed` 替換。

## Keepalive 與重連機制

| 元件 | 機制 | 時間 |
|------|------|------|
| **Relay sshd** | `ClientAliveInterval 30` + `ClientAliveCountMax 3` | 約 90 秒內偵測到斷線 |
| **Remote SSH 設定** | `ServerAliveInterval 30` + `ServerAliveCountMax 3` | 約 90 秒內偵測到 relay 不可達 |
| **Client SSH 設定** | `ServerAliveInterval 60` + `ServerAliveCountMax 3` | 約 180 秒內偵測到隧道斷線 |
| **autossh** | 監控 SSH 子程序 | 退出時立即重啟 |
| **systemd** | `Restart=always` + `RestartSec=10` | 10 秒內重啟 `autossh` |
| **loginctl linger** | 維持使用者服務持續執行 | 登出和重新開機後仍運作 |

網路中斷後最壞情況的重連時間：約 100 秒（90 秒偵測 + 10 秒重啟）。

## 安全性說明

- 反向隧道綁定在 relay 的 `127.0.0.1`（非 `0.0.0.0`）。只有來自或經由 relay
  代理的連線才能到達 remote 主機。
- 需要 SSH 金鑰認證。腳本生成 Ed25519（預設）或 RSA-4096 金鑰，並提供透過
  `ssh-copy-id` 複製的選項。
- `ExitOnForwardFailure yes` 確保 `autossh` 在隧道埠被佔用時正常退出，
  讓 systemd 進行重試。
