#!/usr/bin/env bash
# Unit-Test (GHSA-72hw-w482-prv6): Das ISO enthält keine SSH-Hostschlüssel. Jeder Start erzeugt
# eigene (lf-ssh-hostkeys.service), und der Assistent zeigt ihre Fingerabdrücke, wenn er SSH
# einschaltet. Ohne Schlüssel startet er ssh nicht.
#
# Hier wird kein ssh gestartet: sudo, systemctl, is_online, ip und die Dialoge sind Attrappen.
# Die Schlüssel entstehen mit dem echten ssh-keygen in einem eigenen Ordner.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/tools.sh
LF_LOG="$T/log"
LF_SSH_DIR="$T/ssh"
mkdir -p "$LF_SSH_DIR"
UNIT=build/overlay/etc/systemd/system/lf-ssh-hostkeys.service

KEYGEN_OK=1
is_online() { return 0; }
systemctl() { return 3; } # is-active: ssh läuft nicht
ip() { echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"; }
ui_msg() { printf '%s\n%s\n' "$1" "$2" >>"$T/dialog"; }
ui_yesno() { return 1; }
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case "$1 ${2:-}" in
	"ssh-keygen -A")
		((KEYGEN_OK)) || return 1
		[[ -e $LF_SSH_DIR/ssh_host_ed25519_key ]] ||
			command ssh-keygen -q -t ed25519 -N '' -C test -f "$LF_SSH_DIR/ssh_host_ed25519_key"
		;;
	"chpasswd "*) cat >/dev/null ;;
	esac
	return 0
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Image:"
last_install=$(grep -n 'apt-get install' build/chroot-setup.sh | tail -n1 | cut -d: -f1)
rm_line=$(grep -n '^rm -f /etc/ssh/ssh_host_\*$' build/chroot-setup.sh | cut -d: -f1)
check "chroot-setup löscht die Hostschlüssel nach der letzten Paketinstallation" '[[ -n $rm_line && $rm_line -gt $last_install ]]'
check "build.sh baut kein squashfs, solange Hostschlüssel im chroot liegen" 'grep -q "compgen -G \"\$CHROOT/etc/ssh/ssh_host_\*\"" build/build.sh && [[ $(grep -n "compgen -G \"\$CHROOT/etc/ssh/ssh_host_" build/build.sh | cut -d: -f1) -lt $(grep -n "^	mksquashfs" build/build.sh | cut -d: -f1) ]]'

echo "Dienst für jeden Start:"
check "lf-ssh-hostkeys erzeugt fehlende Schlüssel vor ssh" 'grep -qx "ExecStart=/usr/bin/ssh-keygen -A" "$UNIT" && grep -qx "Before=ssh.service ssh.socket shutdown.target" "$UNIT" && grep -qx "Type=oneshot" "$UNIT"'
check "kein Zyklus mit ssh.socket: ohne Standard-Abhängigkeiten, nach local-fs" 'grep -qx "DefaultDependencies=no" "$UNIT" && grep -qx "After=local-fs.target" "$UNIT" && ! grep -q "^After=.*basic.target" "$UNIT"'
check "er läuft bei jedem Start und vor jedem Start von ssh" 'grep -qx "WantedBy=multi-user.target ssh.service ssh.socket" "$UNIT"'
check "chroot-setup schaltet ihn ein" 'grep -q "^systemctl enable .*lf-ssh-hostkeys.service" build/chroot-setup.sh'

echo "SSH einschalten im Assistenten:"
tools_ssh
fp=$(command ssh-keygen -l -E sha256 -f "$LF_SSH_DIR/ssh_host_ed25519_key.pub" | awk '{print $2}')
keygen_at=$(grep -n "^ssh-keygen -A" "$T/sudo" | head -n1 | cut -d: -f1)
start_at=$(grep -n "^systemctl start ssh" "$T/sudo" | head -n1 | cut -d: -f1)
check "Schlüssel erzeugt, dann Passwort gesetzt und ssh gestartet" '[[ -n $keygen_at && -n $start_at ]] && ((keygen_at < start_at)) && grep -q "^chpasswd" "$T/sudo"'
check "der Dialog zeigt den Fingerabdruck dieses Starts" '[[ $fp == SHA256:* ]] && grep -qF "$fp (ED25519)" "$T/dialog"'
check "das Protokoll nennt ihn, aber nicht das Passwort" '[[ $fp == SHA256:* ]] && grep -qF "$fp" "$LF_LOG" && ! grep -q "Passwort (nur" "$LF_LOG"'

rm -f "$T/sudo" "$T/dialog" "$LF_SSH_DIR"/ssh_host_*
KEYGEN_OK=0
tools_ssh
check "ohne Hostschlüssel: kein Passwort, kein ssh, ein Hinweis" '! grep -q "^chpasswd\|^systemctl start ssh" "$T/sudo" && grep -q "SSH bleibt aus" "$T/dialog"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
