#!/usr/bin/env bash
# Läuft im chroot: Pakete, Claude, Dienste, Sicherheits-Defaults.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }

# Fingerprint des Anthropic-Signaturschlüssels für das Claude-Desktop-Repo
# (laut https://code.claude.com/docs/en/desktop-linux).
CLAUDE_DESKTOP_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# Kein Dienststart im chroot
cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

log "System aktualisieren"
apt-get update -qq
apt-get full-upgrade -y -qq

log "Pakete installieren"
mapfile -t required < <(grep -v '^\s*#' /tmp/packages.list | grep -v '?$' | awk 'NF {print $1}')
mapfile -t optional < <(grep -v '^\s*#' /tmp/packages.list | grep '?$' | awk 'NF {sub(/\?$/, "", $1); print $1}')
apt-get install -y -qq --no-install-recommends "${required[@]}"
for p in "${optional[@]}"; do
	if apt-cache show "$p" >/dev/null 2>&1; then
		apt-get install -y -qq --no-install-recommends "$p" || echo "WARNUNG: optionales Paket $p nicht installierbar"
	else
		echo "HINWEIS: optionales Paket $p nicht im Archiv, übersprungen"
	fi
done

log "Claude Desktop aus dem offiziellen Anthropic-Repo"
key=/usr/share/keyrings/claude-desktop-archive-keyring.asc
curl -fsSL -o "$key" https://downloads.claude.ai/claude-desktop/key.asc
fpr="$(gpg --show-keys --with-colons "$key" | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ $fpr != "$CLAUDE_DESKTOP_FPR" ]]; then
	echo "FEHLER: Claude-Desktop-Schlüssel hat Fingerprint '$fpr', erwartet $CLAUDE_DESKTOP_FPR" >&2
	exit 1
fi
echo "deb [arch=amd64 signed-by=$key] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
	>/etc/apt/sources.list.d/claude-desktop.list
apt-get update -qq
# Ohne Recommends: QEMU/OVMF für Cowork wird im Rettungssystem nicht gebraucht.
apt-get install -y -qq --no-install-recommends claude-desktop

log "Claude Code CLI (nativer Installer)"
inst_home="$(mktemp -d)"
HOME="$inst_home" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
claude_real="$(readlink -f "$inst_home/.local/bin/claude")"
install -m 0755 "$claude_real" /usr/local/bin/claude
rm -rf "$inst_home"
/usr/local/bin/claude --version

log "Live-Benutzer und Autologin"
# casper legt den Benutzer beim Boot an (sudo ohne Passwort).
cat >/etc/casper.conf <<'EOF'
export USERNAME="rescue"
export USERFULLNAME="Firestrike Rescue"
export HOST="frs"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="Ubuntu"
EOF

log "Locale und Tastatur (Deutsch)"
sed -i 's/^# *\(de_DE.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=de_DE.UTF-8
cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT="nodeadkeys"
XKBOPTIONS=""
BACKSPACE="guess"
EOF
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime

log "Sicherheits-Defaults für fremde Datenträger"
# mdadm: keine automatische Assemblierung (ein Resync würde auf die Quell-Disk schreiben)
install -d /etc/mdadm
echo 'AUTO -all' >/etc/mdadm/mdadm.conf
# LVM: keine Auto-Aktivierung
if [[ -f /etc/lvm/lvm.conf ]]; then
	sed -i 's/^\(\s*\)#\?\s*event_activation = .*/\1event_activation = 0/' /etc/lvm/lvm.conf
	grep -q 'auto_activation_volume_list' /etc/lvm/lvm.conf ||
		sed -i '/^activation {/a\	auto_activation_volume_list = []' /etc/lvm/lvm.conf
fi
# Kein automatisches Swap auf gefundenen Partitionen
systemctl mask swap.target >/dev/null 2>&1 || true

log "Dienste"
systemctl enable frs-theme.service frs-ready.service frs-selftest.service NetworkManager.service
# SSH nur auf Wunsch über den Assistenten
systemctl disable ssh.service ssh.socket >/dev/null 2>&1 || true
# Keine Wartezeit auf Netzwerk beim Booten
systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service >/dev/null 2>&1 || true
# Keine automatischen Updates im Live-System
systemctl mask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true

log "initramfs neu bauen"
update-initramfs -u -k all

log "Aufräumen"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/apt/* /root/.cache
rm -f /usr/sbin/policy-rc.d
: >/etc/machine-id
