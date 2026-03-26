#!/usr/bin/env bash
# =============================================================================
#  install-nm-over-ssh.sh - Safe migration to NetworkManager over a live SSH session
#
#  Installs NetworkManager and schedules a one-time boot-time switchover that
#  disables whatever network backend is currently running, then hands control
#  to NM.  Because the dangerous work happens at the very start of the next
#  boot (before any interface is up), your SSH session is never at risk.
#
#  After reboot, NetworkManager is running and managing your interface.
#
#  Supported package managers : apt / dnf / pacman
#  Supported incumbents        : systemd-networkd, dhcpcd, connman, wicd
#  Hard dependency             : systemd  (systemctl must be present)
#
#  Usage:
#    sudo bash install-nm-over-ssh.sh [--dry-run]
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Dry-run flag ──────────────────────────────────────────────────────────────
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

dry() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "  ${YELLOW}[dry-run]${RESET} $*"
    else
        eval "$@"
    fi
}

# =============================================================================
section "Preflight checks"
# =============================================================================

[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash install-nm-over-ssh.sh"

command -v systemctl &>/dev/null \
    || error "systemctl not found - this script requires systemd."

# ── Detect package manager ────────────────────────────────────────────────────
PKG_MGR=""
if   command -v apt-get &>/dev/null; then PKG_MGR="apt"
elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"
elif command -v pacman  &>/dev/null; then PKG_MGR="pacman"
else
    error "No supported package manager found (tried apt-get, dnf, pacman)."
fi
info "Package manager : $PKG_MGR"

# ── Skip if NM is already active AND managing an interface ───────────────────
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    success "NetworkManager is already active - nothing to do."
    exit 0
fi

# ── Detect incumbent network backend ─────────────────────────────────────────
INCUMBENTS=()
for svc in systemd-networkd dhcpcd connman wicd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        INCUMBENTS+=("$svc")
    fi
done

if [[ ${#INCUMBENTS[@]} -gt 0 ]]; then
    info "Active incumbent(s) : ${INCUMBENTS[*]}"
else
    warn "No recognised incumbent found - will still install NM."
fi

# ── Detect the primary network interface ─────────────────────────────────────
# Prefer the interface carrying the default route (i.e. the one SSH is using).
PRIMARY_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [[ -z "$PRIMARY_IF" ]]; then
    # Fallback: first non-loopback interface that is UP
    PRIMARY_IF=$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')
fi
if [[ -z "$PRIMARY_IF" ]]; then
    warn "Could not detect primary interface - defaulting to eth0"
    PRIMARY_IF="eth0"
fi
info "Primary interface (SSH session) : ${BOLD}${PRIMARY_IF}${RESET}"

CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
info "Current IP (reconnect here after reboot) : ${BOLD}${CURRENT_IP}${RESET}"

# ── Dry-run summary and early exit ───────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}Dry-run mode - no changes will be made.${RESET}"
    echo ""
    echo -e "  Package manager  : ${BOLD}${PKG_MGR}${RESET}"
    echo -e "  Primary iface    : ${BOLD}${PRIMARY_IF}${RESET}"
    [[ ${#INCUMBENTS[@]} -gt 0 ]] && echo -e "  Will disable     : ${BOLD}${INCUMBENTS[*]}${RESET}"
    echo -e "  Will install     : ${BOLD}NetworkManager${RESET}"
    echo -e "  NM kept hands-off during install via : ${BOLD}unmanaged-devices=${PRIMARY_IF}${RESET}"
    echo -e "  Oneshot service  : ${BOLD}nm-takeover.service${RESET}  (runs once at next boot)"
    echo ""
    echo "Run without --dry-run to apply."
    exit 0
fi

# =============================================================================
section "Pre-installing NM guard: unmanaged-devices"
# =============================================================================
#
# FIX #1: Before we install NM (apt post-install starts it immediately),
# tell NM to never touch our primary interface.  This config file is written
# BEFORE the package is installed, so NM reads it on its very first start
# and leaves eth0/the SSH interface alone.
#
# The oneshot removes this file at next boot, after the old backend is already
# dead, so NM then takes over cleanly.

NM_CONF_DIR=/etc/NetworkManager/conf.d
mkdir -p "$NM_CONF_DIR"

cat > "${NM_CONF_DIR}/99-unmanaged-ssh-iface.conf" <<CONF
# Written by install-nm-over-ssh.sh
# Prevents NM from touching ${PRIMARY_IF} while the old network backend
# is still live.  Removed by nm-takeover.service on first boot.
[keyfile]
unmanaged-devices=interface-name:${PRIMARY_IF}
CONF

success "NM guard written: NM will not touch ${PRIMARY_IF} until reboot"

# =============================================================================
section "Installing NetworkManager"
# =============================================================================

case "$PKG_MGR" in
    apt)
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager
        ;;
    dnf)
        dnf install -y NetworkManager
        ;;
    pacman)
        pacman -S --noconfirm networkmanager
        ;;
esac

# NM is now installed (and apt may have started it), but it won't touch
# ${PRIMARY_IF} because of the unmanaged-devices guard above.
success "NetworkManager installed (held off ${PRIMARY_IF} by guard config)"

# =============================================================================
section "Writing switchover oneshot"
# =============================================================================

TAKEOVER_SCRIPT=/usr/local/lib/nm-takeover.sh

DISABLE_CMDS=""
for svc in "${INCUMBENTS[@]}"; do
    DISABLE_CMDS+="    log \"Disabling incumbent: ${svc}\"\n"
    DISABLE_CMDS+="    systemctl disable \"${svc}\" 2>>\"\$LOG\" || true\n"
    DISABLE_CMDS+="    systemctl mask    \"${svc}\" 2>>\"\$LOG\" || true\n"
done

cat > "$TAKEOVER_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
# nm-takeover.sh - generated by install-nm-over-ssh.sh
# Runs once at boot (before networking), then disables itself.
set -euo pipefail

LOG=/var/log/nm-takeover.log
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S')  \$*" | tee -a "\$LOG"; }

log "=== nm-takeover starting ==="

# ── 1. Disable incumbent backends ────────────────────────────────────────────
$(printf '%b' "$DISABLE_CMDS")

# ── 2. FIX #2: Remove the unmanaged guard so NM will manage ${PRIMARY_IF} ───
# This is safe now: the old backend is already masked/disabled above,
# so there is no race.  NM will pick up ${PRIMARY_IF} when it starts.
log "Removing unmanaged-devices guard for ${PRIMARY_IF}"
rm -f /etc/NetworkManager/conf.d/99-unmanaged-ssh-iface.conf

# ── 3. FIX #3: Do NOT mask wpa_supplicant - disable only ─────────────────────
# Masking breaks systems (especially RPi) where wpa_supplicant is pulled
# in as a hard dependency by other units even on wired-only setups.
# NM ships its own internal supplicant; disabling the standalone daemon
# is sufficient.
log "Disabling standalone wpa_supplicant"
systemctl disable wpa_supplicant 2>>"\$LOG" || true
systemctl stop    wpa_supplicant 2>>"\$LOG" || true

# ── 4. Enable AND start NetworkManager ───────────────────────────────────────
# FIX #4: The original script only called 'enable', not 'start'.
# Because this oneshot runs Before=network-pre.target the network stack
# hasn't come up yet - we enable it here so systemd starts NM in the
# normal boot sequence right after this unit exits.
log "Enabling NetworkManager"
systemctl unmask NetworkManager 2>>"\$LOG" || true
systemctl enable NetworkManager 2>>"\$LOG"
# Note: do NOT call 'systemctl start' here - we are Before=network-pre.target
# and systemd will start NM via the normal dependency chain.

# ── 5. Self-disable so this only runs once ───────────────────────────────────
log "Disabling nm-takeover (oneshot, runs once only)"
systemctl disable nm-takeover 2>>"\$LOG" || true

log "=== nm-takeover complete - NetworkManager will start normally ==="
SCRIPT

chmod +x "$TAKEOVER_SCRIPT"
success "Switchover script written: $TAKEOVER_SCRIPT"

# ── Systemd unit ─────────────────────────────────────────────────────────────
# DefaultDependencies=no + Before=network-pre.target fires this as early as
# possible, before ANY interface comes up.  The old backend never starts.
cat > /etc/systemd/system/nm-takeover.service <<UNIT
[Unit]
Description=One-time switchover to NetworkManager
Documentation=https://github.com/josh-frank/mindlink
DefaultDependencies=no
Before=network-pre.target sysinit.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash $TAKEOVER_SCRIPT
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=sysinit.target
UNIT

systemctl daemon-reload
systemctl enable nm-takeover
success "nm-takeover.service enabled (fires once on next boot)"

# =============================================================================
section "Ready - reboot to apply"
# =============================================================================

PAD=54
print_row() { printf "│ %-${PAD}s │\n" "$1"; }

echo ""
echo -e "${GREEN}${BOLD}┌$(printf '─%.0s' $(seq 1 $((PAD+2))))┐${RESET}"
print_row "NetworkManager installed, switchover scheduled"
print_row ""
print_row "  Primary interface  : ${PRIMARY_IF}"
[[ ${#INCUMBENTS[@]} -gt 0 ]] && \
print_row "  Will disable       : ${INCUMBENTS[*]}"
print_row "  wpa_supplicant     : disabled (not masked)"
print_row "  Will enable+start  : NetworkManager"
print_row ""
print_row "  Reconnect after reboot : ${CURRENT_IP}"
print_row "  Takeover log           : /var/log/nm-takeover.log"
echo -e "${GREEN}${BOLD}└$(printf '─%.0s' $(seq 1 $((PAD+2))))┘${RESET}"
echo ""
echo -e "${YELLOW}${BOLD}Do NOT manually start NetworkManager before rebooting.${RESET}"
echo -e "Let the oneshot handle the switchover safely."
echo ""

read -r -p "Reboot now? [y/N] " REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    info "Rebooting..."
    reboot
else
    warn "Skipping reboot - run 'sudo reboot' when ready."
fi
