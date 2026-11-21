#!/usr/bin/env bash
# Unit-Test: "Dateien kopieren" aus einem Image wählt die Optionen von rsync nach dem Dateisystem,
# das eingehängt ist, und das Fenster zeigt sofort, was wohin kopiert wird.
#
# ntfs3 liefert Windows-Attribute wie $LXUID als erweiterte Attribute ohne Namensraum, auch für
# Dateien, die Linux angelegt hat. Mit -X konnte rsync sie auf ext4 nicht setzen: Jede Kopie von
# NTFS endete mit Exit-Code 23 und drei Fehlern je Datei (#78). Bis rsync die ersten Dateien
# überträgt, blieb das Fenster lf-kopie leer (#79).
# Ohne Disks und ohne root: Einhängen, findmnt, tmux, sudo und die Menüs sind Attrappen.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
LF_RUN="$T/run"
LF_IMAGE_MNT="$T/mnt"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

image_attach() { echo /dev/loop7; }
image_pick_part() { echo /dev/loop7p2; }
part_mount_ro() { return 0; }
ui_menu() { echo all; }
target_fs() { echo "$ZIEL_FS"; }
findmnt() { echo "$QUELL_FS"; }
# Je Argument eine Zeile: 1 lf-kopie, 2 bash, 3 -c, 4 Befehlstext, 5 _, 6 Optionen, 7 Quelle,
# 8 Ziel, 9 Protokoll.
tmux_run() { printf '%s\n' "$@" >"$T/tmux"; }

# kopie QUELL-FS ZIEL-FS   Ergebnis: OPTS (Optionen von rsync), SKRIPT (Befehlstext im Fenster)
kopie() {
	QUELL_FS=$1 ZIEL_FS=$2
	rm -f "$T/tmux"
	image_copy_files "$T/fall" "$T/fall/image.img"
	SKRIPT=$(sed -n 4p "$T/tmux" 2>/dev/null)
	OPTS=$(sed -n 6p "$T/tmux" 2>/dev/null)
}

echo "Optionen von rsync nach eingehängtem Dateisystem (#78):"
kopie ntfs3 ext4
check "NTFS über ntfs3 auf ext4: ohne -A und -X" '[[ $OPTS == "-aH" ]]'
kopie fuseblk ext4
check "NTFS über ntfs-3g oder BitLocker (fuseblk) auf ext4: ohne -A und -X" '[[ $OPTS == "-aH" ]]'
kopie ext4 ext4
check "ext4 auf ext4: mit ACLs und erweiterten Attributen wie bisher" '[[ $OPTS == "-aHAX" ]]'
kopie ntfs3 exfat
check "Ziel exFAT: wie bisher nur Inhalt und Zeiten" '[[ $OPTS == "-rt --modify-window=2" ]]'

echo "Startzeile im Fenster lf-kopie (#79):"
kopie ntfs3 ext4
# Den Befehlstext so laufen lassen, wie tmux ihn startet. sudo ist eine Attrappe, die nur meldet.
sudo() { echo "AUFRUF $*"; }
export -f sudo
bash -c "$SKRIPT" _ "$OPTS" /quelle /ziel "$T/kopie.log" </dev/null >"$T/fenster" 2>&1
unset -f sudo
check "die erste Zeile nennt die Quelle, die zweite das Ziel" '[[ $(sed -n 1p "$T/fenster") == "Kopiere /quelle" && $(sed -n 2p "$T/fenster") == "nach /ziel" ]]'
check "der Hinweis auf Dateiliste und Protokoll steht vor dem Aufruf von rsync" '(($(grep -n "zählt zuerst" "$T/fenster" | cut -d: -f1) < $(grep -n "^AUFRUF rsync -aH --info=progress2" "$T/fenster" | cut -d: -f1))) && grep -q "Protokoll: $T/kopie.log" "$T/fenster"'
check "Pfade bleiben eigene Argumente von rsync" 'grep -qx "AUFRUF rsync -aH --info=progress2 --ignore-errors /quelle/ /ziel/" "$T/fenster"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
