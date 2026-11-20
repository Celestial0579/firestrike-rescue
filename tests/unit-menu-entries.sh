#!/usr/bin/env bash
# Unit-Test: Jeder Menüpunkt startet unter set -u, ohne abzubrechen oder hängen zu bleiben (#70).
#
# #68 fiel nicht auf, weil kein Test das Menü startete. Dieser Test lädt rescue/lf ohne den
# Startteil und ruft jeden Menüpunkt auf. Dialoge sind Attrappen, und für alle Disk- und
# Systembefehle liegen Attrappen im PATH, auch für sudo. Kein echter Befehl berührt eine Disk.
# Zwei Durchläufe:
#   - abbrechen: Jeder Dialog wird abgebrochen.
#   - erster:    Menüs nehmen den ersten Eintrag, Ja/Nein bekommt Nein, Eingaben werden
#                abgebrochen. Nach vier Menüs wird abgebrochen.
# Fehler sind "unbound variable", ein unbekannter Befehl, ein Syntaxfehler oder ein Menüpunkt,
# der nach 30 Sekunden noch läuft.
# Zähler stehen in Dateien: ui_menu läuft in $( … ), eine Variable ginge dort verloren (#68).
set -u
cd "$(dirname "$0")/.." || exit 1
# Englische Meldungen der Shell, damit die Suche unten sie findet.
export LC_ALL=C.UTF-8
unset LANGUAGE

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/home"
for c in sudo dd sgdisk wipefs mkfs mkfs.ext4 mkfs.vfat mkfs.ntfs mkfs.exfat parted partprobe ddrescue mount umount \
	cryptsetup losetup dmsetup qemu-img qemu-nbd ssh scp rsync systemctl reboot poweroff shutdown smartctl blkid lsblk \
	tmux whiptail dialog nmcli ip ntfsfix ntfsresize e2fsck resize2fs xfs_growfs btrfs blockdev hdparm nvme dmesg \
	chntpw claude cage foot sfdisk fdisk gdisk partclone.ntfs ntfsclone pv nc socat curl wget ping lf-aufgabe \
	lf-freigabe lf-lesen lf-claude pkill setsid chvt openvt loginctl udevadm shred; do
	printf '#!/bin/sh\necho "ATTRAPPE %s $*" >>"%s/aufrufe"\nexit 1\n' "$c" "$T" >"$T/bin/$c"
	chmod +x "$T/bin/$c"
done
export PATH="$T/bin:$PATH" HOME="$T/home"
LF_LIB="$PWD/rescue/lib" LF_RUN="$T/run" LF_LOG="$T/lf.log"
export LF_LIB
sed '/^case \${1:-} in$/,$d' rescue/lf >"$T/lf-funktionen"
# shellcheck disable=SC1091
. "$T/lf-funktionen"
LF_RUN="$T/run" LF_LOG="$T/lf.log"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

disks_json() {
	printf '%s\n' '{"path":"/dev/sda","model":"Alte HDD","serial":"S1","size":500107862016,"tran":"sata"}' \
		'{"path":"/dev/sdb","model":"Neue SSD","serial":"S2","size":1000204886016,"tran":"usb"}'
}
disk_smart() { echo 'WARN|3 umgelagerte Sektoren'; }

MODUS=abbrechen
erster_eintrag() { # Kennung nach "--"
	local a nach=0
	for a in "$@"; do
		((nach)) && {
			echo "$a"
			return 0
		}
		[[ $a == -- ]] && nach=1
	done
	return 1
}
ui_menu() {
	echo "MENU $1" >>"$T/dialoge"
	[[ $MODUS == abbrechen ]] && return 1
	local n
	n=$(($(cat "$T/menues") + 1))
	echo "$n" >"$T/menues"
	((n > 4)) && return 1
	erster_eintrag "$@"
}
ui_yesno() { echo "JANEIN $1" >>"$T/dialoge"; return 1; }
ui_msg() { echo "MELDUNG $1" >>"$T/dialoge"; }
ui_text() { echo "TEXT $1" >>"$T/dialoge"; }
ui_textfile() { echo "DATEI $1" >>"$T/dialoge"; }
ui_info() { :; }
ui_input() { echo "EINGABE $1" >>"$T/dialoge"; return 1; }
ui_input_room() { echo "EINGABE $1" >>"$T/dialoge"; return 1; }
ui_password() { echo "KENNWORT $1" >>"$T/dialoge"; return 1; }

for MODUS in abbrechen erster; do
	echo "Durchlauf $MODUS:"
	for w in recover_wizard clone_wizard resize_wizard p2v_wizard recover_resume claude_start claude_desktop tools_menu power_menu; do
		echo 0 >"$T/menues"
		: >"$T/dialoge"
		(
			set -u
			"$w"
		) </dev/null >"$T/ausgabe" 2>&1 &
		pid=$!
		# Wache: beendet einen hängenden Menüpunkt nach 30 s. Wird sie vorher beendet,
		# nimmt sie ihr sleep mit, und sie hält die Ausgabe nicht offen.
		(
			trap 'kill "$s" 2>/dev/null; exit 0' TERM
			sleep 30 &
			s=$!
			wait "$s"
			kill -9 "$pid" 2>/dev/null
		) >/dev/null 2>&1 &
		wache=$!
		wait "$pid"
		rc=$?
		kill "$wache" 2>/dev/null
		wait "$wache" 2>/dev/null
		check "$w: kein Abbruch" '! grep -qE "unbound variable|command not found|syntax error|bad substitution|ambiguous redirect" "$T/ausgabe"'
		check "$w: endet" '((rc != 137))'
		check "$w: zeigt einen Dialog" '[[ -s $T/dialoge ]]'
	done
done

if ((fails)); then
	echo "--- letzte Ausgabe:"
	tail -n 20 "$T/ausgabe"
	echo "unit-menu-entries: $fails Fehler"
	exit 1
fi
echo "unit-menu-entries: alles ok"
