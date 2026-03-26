#!/usr/bin/env bash
# =============================================================================
#  install-nm-over-ssh.sh - Safe migration to NetworkManager over a live SSH session
#
#  Installs NetworkManager and schedules a one-time boot-time switchover that
#  disables whatever network backend is currently running, then hands control
#  to NM.  Because the dangerous work happens at the very start of the next
#  boot (before any interface is up), your SSH session is never at risk.
#
#  After reboot, NetworkManager is running and in control.  This script makes
#  no NM connection profiles - configure NM however you like afterward.
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
    # In dry-run mode: print what would run, don't run it.
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "  ${YELLOW}[dry-run]${RESET} $*"
    else
        eval "$@"
    fi
}

# =============================================================================
section "Preflight checks"
# =============================================================================

# ── Must be root ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash install-nm-over-ssh.sh"

# ── Must have systemd ─────────────────────────────────────────────────────────
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

# ── Skip if NM is already the active backend ──────────────────────────────────
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    success "NetworkManager is already active - nothing to do."
    exit 0
fi

# ── Detect incumbent network backend ─────────────────────────────────────────
# We check by active service.  If nothing is active we still proceed - we'll
# just skip the disable step and rely on NM winning by default.
INCUMBENTS=()
for svc in systemd-networkd dhcpcd connman wicd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        INCUMBENTS+=("$svc")
    fi
done

if [[ ${#INCUMBENTS[@]} -gt 0 ]]; then
    info "Active incumbent(s) : ${INCUMBENTS[*]}"
else
    warn "No recognised incumbent found - will still install NM and mask wpa_supplicant."
fi

# ── Capture current IP for the user's reference ───────────────────────────────
CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
info "Current IP (reconnect here after reboot) : ${BOLD}${CURRENT_IP}${RESET}"

# ── Dry-run summary and early exit ───────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}Dry-run mode - no changes will be made.${RESET}"
    echo ""
    echo -e "  Package manager  : ${BOLD}${PKG_MGR}${RESET}"
    if [[ ${#INCUMBENTS[@]} -gt 0 ]]; then
        echo -e "  Will disable     : ${BOLD}${INCUMBENTS[*]}${RESET}"
    fi
    echo -e "  Will mask        : ${BOLD}wpa_supplicant${RESET}  (always)"
    echo -e "  Will install     : ${BOLD}NetworkManager${RESET}"
    echo -e "  Oneshot service  : ${BOLD}nm-takeover.service${RESET}  (runs once at next boot)"
    echo ""
    echo "Run without --dry-run to apply."
    exit 0
fi

# =============================================================================
section "Installing NetworkManager"
# =============================================================================

# Safe - just installs the package.  NM is not started or activated here.
# Your SSH session is unaffected.

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

# We do NOT stop, mask, or kill NM here.
#
# The apt postinstall already started NM - fighting it now races with
# networkd and can briefly drop the interface, killing SSH.  It's safe
# to leave NM running alongside networkd until reboot: NM has no
# connection profiles yet so it won't reconfigure any interface.
# The oneshot masks networkd and takes full control at the start of next boot.

success "NetworkManager installed (not yet active)"

# =============================================================================
section "Writing switchover oneshot"
# =============================================================================

# The companion script - runs as the oneshot's ExecStart.
# Logs every step to /var/log/nm-takeover.log for post-mortem if needed.
TAKEOVER_SCRIPT=/usr/local/lib/nm-takeover.sh

# Build the disable block dynamically from detected incumbents.
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

$(printf '%b' "$DISABLE_CMDS")

log "Masking wpa_supplicant"
systemctl mask wpa_supplicant 2>>"\$LOG" || true

log "Enabling NetworkManager"
systemctl unmask NetworkManager 2>>"\$LOG" || true
systemctl enable NetworkManager 2>>"\$LOG"

log "Disabling nm-takeover (oneshot, runs once only)"
systemctl disable nm-takeover 2>>"\$LOG" || true

log "=== nm-takeover complete - NetworkManager will start normally ==="
SCRIPT

chmod +x "$TAKEOVER_SCRIPT"
success "Switchover script written: $TAKEOVER_SCRIPT"

# The oneshot systemd unit.
# DefaultDependencies=no + Before=network-pre.target ensures this fires
# as early as possible, before ANY network interface comes up.
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

PAD=50
print_row() { printf "│ %-${PAD}s │\n" "$1"; }

echo ""
echo -e "${GREEN}${BOLD}┌$(printf '─%.0s' $(seq 1 $((PAD+2))))┐${RESET}"
print_row "NetworkManager installed, switchover scheduled"
print_row ""
if [[ ${#INCUMBENTS[@]} -gt 0 ]]; then
    print_row "  Will disable : ${INCUMBENTS[*]}"
fi
print_row "  Will mask    : wpa_supplicant"
print_row "  Will enable  : NetworkManager"
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
