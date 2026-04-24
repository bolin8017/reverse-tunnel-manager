# Troubleshooting

## FAQ

### How long does auto-reconnect take after a network interruption?

Worst case ~100 seconds. The relay's `ClientAliveInterval 30` +
`ClientAliveCountMax 3` detects a dead connection within ~90 seconds. Then
`autossh` restarts and systemd adds up to 10 seconds (`RestartSec=10`).

### The tunnel says "remote port forwarding failed"

The tunnel port is already bound on the relay, usually by a stale connection
from a previous session. The relay's keepalive settings will clear it within
~90 seconds.

To clear it immediately on the relay:

```bash
# Find the process holding the port (e.g., 52022)
ss -tlnp | grep 52022

# Kill it
sudo kill <PID>
```

### Can multiple users share the same relay?

Yes. Each user must use a **different tunnel port**. As long as ports do not
collide, the relay handles many concurrent tunnels.

### Will the tunnel restart after a reboot?

Yes. `setup-remote.sh` runs `loginctl enable-linger` so systemd user services
start at boot without requiring a login session. The service is also set to
`Restart=always`.

### `loginctl enable-linger` fails

This command may require admin privileges on some systems. Ask your system
administrator to run:

```bash
sudo loginctl enable-linger <your-username>
```

Without linger, the tunnel only runs while you have an active login session.

## Debugging

### Check service status on the remote machine

```bash
systemctl --user status ssh-tunnel.service
```

### View logs

```bash
# Last 50 lines
journalctl --user -u ssh-tunnel.service -n 50 --no-pager

# Follow live logs
journalctl --user -u ssh-tunnel.service -f
```

### Test the SSH connection manually

```bash
# From the remote machine — test connection to relay
ssh -v relay-tunnel

# From the relay — test if the tunnel port is listening
ss -tlnp | grep <TUNNEL_PORT>

# From the client — test with verbose output
ssh -v my-remote
```

### Verify relay sshd settings

```bash
# On the relay
sudo sshd -T | grep -E 'allowtcpforwarding|clientalive|pubkeyauthentication'
```

## Uninstall

### Remote machine

```bash
# Stop and disable the tunnel service
systemctl --user stop ssh-tunnel.service
systemctl --user disable ssh-tunnel.service

# Remove the service file
rm ~/.config/systemd/user/ssh-tunnel.service
systemctl --user daemon-reload

# Disable linger (optional — prevents user services from starting at boot)
loginctl disable-linger "$USER"

# Remove the relay-tunnel Host block from SSH config
# Open ~/.ssh/config and delete the "Host relay-tunnel" block.

# Optionally remove autossh
# RHEL/Rocky/CentOS/Fedora:
sudo dnf remove autossh
# Debian/Ubuntu:
sudo apt-get remove autossh
```

### Client machine

Open `~/.ssh/config` and delete the `Host my-remote` block (or whichever alias
you chose) and all indented lines beneath it.

### Relay server

If you modified `sshd_config` and want to revert, restore from the backup:

```bash
# Backups are saved as /etc/ssh/sshd_config.bak.YYYYMMDD
sudo cp /etc/ssh/sshd_config.bak.<DATE> /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh   # or sshd on RHEL
```
