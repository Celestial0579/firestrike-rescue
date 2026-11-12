#!/usr/bin/env bash
# Unit-Test: Die Expertenwerkzeuge (gdisk, fdisk, parted, cfdisk) starten erst nach der
# Ziel-Bestätigung, und zwar auf der Disk, die bestätigt wurde. Ohne echte Disks und ohne Dialoge.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/resize.sh

# Die Auswahl läuft in $(…), also in einer Subshell. Deshalb landet alles in Dateien.
disk_pick() {
	((PICK_RC)) && return 1
	echo "ZIEL-DISK"
}
# Erster Aufruf: Pfad bei der Auswahl. Zweiter Aufruf: Pfad nach der Bestätigung.
disk_resolve() {
	echo x >>"$T/resolve"
	if (($(wc -l <"$T/resolve") == 1)); then echo "$PATH_BEFORE"; else echo "$PATH_AFTER"; fi
}
ui_menu() {
	((MENU_RC)) && return 1
	echo "$TOOL"
}
ui_msg() { :; }
die() {
	printf '%s' "$*" >"$T/die"
	return 1
}
safety_confirm_target() {
	printf '%s|%s\n' "$1" "$2" >>"$T/confirm"
	return "$CONFIRM_RC"
}
sudo() { printf '%s\n' "$*" >>"$T/sudo"; }

# expert   Ruft resize_expert auf. Ergebnis: CONFIRM (Bestätigungen), STARTED (gestartete Werkzeuge).
expert() {
	rm -f "$T/resolve" "$T/confirm" "$T/sudo" "$T/die"
	resize_expert
	CONFIRM=$(cat "$T/confirm" 2>/dev/null)
	STARTED=$(cat "$T/sudo" 2>/dev/null)
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

PICK_RC=0 MENU_RC=0 PATH_BEFORE=/dev/sdb PATH_AFTER=/dev/sdb

for TOOL in gdisk fdisk parted cfdisk; do
	echo "$TOOL:"
	CONFIRM_RC=1
	expert
	check "Bestätigung wird für die gewählte Disk verlangt" '[[ $CONFIRM == "ZIEL-DISK|$TOOL arbeitet direkt auf dieser Disk"* ]]'
	check "ohne Bestätigung kein Start" '[[ -z $STARTED ]]'
	CONFIRM_RC=0
	expert
	check "nach der Bestätigung genau ein Start auf der Disk" '[[ $STARTED == "$TOOL /dev/sdb" ]]'
done

echo "Abbruch vor der Bestätigung:"
TOOL=fdisk CONFIRM_RC=0
PICK_RC=1
expert
check "keine Disk gewählt: keine Bestätigung, kein Start" '[[ -z $CONFIRM && -z $STARTED ]]'
PICK_RC=0 MENU_RC=1
expert
check "kein Werkzeug gewählt: keine Bestätigung, kein Start" '[[ -z $CONFIRM && -z $STARTED ]]'
MENU_RC=0

echo "Gerätepfad ändert sich zwischen Auswahl und Bestätigung:"
PATH_AFTER=/dev/sdc
expert
check "Start auf dem Pfad der bestätigten Disk" '[[ $STARTED == "fdisk /dev/sdc" ]]'
PATH_AFTER=""
expert
check "Disk verschwunden: kein Start, mit Meldung" '[[ -z $STARTED && $(cat "$T/die") == *"nicht mehr zu finden"* ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
