Does exactly what it says on the can. A script to migrate safely to NetworkManager over a live SSH session.

```
sudo bash install-nm-over-ssh.sh [--dry-run]
```

It installs NetworkManager and schedules a one-time boot-time switchover that disables current network backend, then hands control to NM.  Because this happens at the start of the next boot (before any interface is up), SSH session is never at risk.

After reboot, NetworkManager is running and in control.  This script makes no NM connection profiles — configure NM however you like afterward.
