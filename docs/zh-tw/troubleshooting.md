# 常見問題排解

## 常見問題

### 網路中斷後自動重連需要多久？

最壞情況約 100 秒。Relay 的 `ClientAliveInterval 30` + `ClientAliveCountMax 3`
會在約 90 秒內偵測到斷線。接著 `autossh` 重啟，systemd 增加最多 10 秒
（`RestartSec=10`）。

### 隧道顯示 "remote port forwarding failed"

隧道埠在 relay 上已被佔用，通常是上一個 session 的殘留連線。Relay 的 keepalive
設定會在約 90 秒內清除。

如需立即清除，在 relay 上執行：

```bash
# 找到佔用埠的程序（例如 52022）
ss -tlnp | grep 52022

# 終止該程序
sudo kill <PID>
```

### 多個使用者可以共用同一台 relay 嗎？

可以。每個使用者必須使用**不同的隧道埠**。只要埠不衝突，relay 可以同時處理多個
反向隧道。

### 重新開機後隧道會自動重啟嗎？

會。`setup-remote.sh` 會執行 `loginctl enable-linger`，使 systemd 使用者服務在
開機時自動啟動，不需要登入。服務也設定為 `Restart=always`。

### `loginctl enable-linger` 失敗

此指令在某些系統上可能需要管理員權限。請系統管理員執行：

```bash
sudo loginctl enable-linger <你的使用者名稱>
```

如果沒有啟用 linger，隧道只會在你有活躍的登入 session 時運作。

## 除錯

### 在 remote 主機上檢查服務狀態

```bash
systemctl --user status ssh-tunnel.service
```

### 查看日誌

```bash
# 最近 50 行
journalctl --user -u ssh-tunnel.service -n 50 --no-pager

# 即時追蹤日誌
journalctl --user -u ssh-tunnel.service -f
```

### 手動測試 SSH 連線

```bash
# 從 remote 主機 — 測試到 relay 的連線
ssh -v relay-tunnel

# 從 relay — 測試隧道埠是否在監聽
ss -tlnp | grep <TUNNEL_PORT>

# 從 client — 以詳細模式測試
ssh -v my-remote
```

### 驗證 relay 的 sshd 設定

```bash
# 在 relay 上
sudo sshd -T | grep -E 'allowtcpforwarding|clientalive'
```

## 解除安裝

### Remote 主機

```bash
# 停止並停用隧道服務
systemctl --user stop ssh-tunnel.service
systemctl --user disable ssh-tunnel.service

# 移除服務檔案
rm ~/.config/systemd/user/ssh-tunnel.service
systemctl --user daemon-reload

# 停用 linger（選擇性 — 防止使用者服務在開機時自動啟動）
loginctl disable-linger "$USER"

# 從 SSH 設定中移除 relay-tunnel Host 區塊
# 開啟 ~/.ssh/config，刪除 "Host relay-tunnel" 區塊。

# 選擇性移除 autossh
# RHEL/Rocky/CentOS/Fedora：
sudo dnf remove autossh
# Debian/Ubuntu：
sudo apt-get remove autossh
```

### Client 主機

開啟 `~/.ssh/config`，刪除 `Host my-remote`（或你選擇的別名）區塊及其下方所有
縮排的行。

### Relay 伺服器

如果修改了 `sshd_config` 並想還原，從備份恢復：

```bash
# 備份儲存為 /etc/ssh/sshd_config.bak.YYYYMMDD
sudo cp /etc/ssh/sshd_config.bak.<日期> /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh   # RHEL 上為 sshd
```
