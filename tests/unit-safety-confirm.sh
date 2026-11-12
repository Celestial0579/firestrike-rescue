#!/usr/bin/env bash
# Unit-Test für die Ziel-Bestätigung (safety_confirm_target), ohne echte Disks und ohne whiptail.
# Prüft, was eingetippt werden muss, je nachdem welche Kennung die Disk meldet, dass eine leere
# Eingabe nie bestätigt und dass die Aufforderung auch bei vielen Partitionen im Dialog bleibt.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
FRS_RUN=$T
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/safety.sh

# Fester Bildschirm: Textkonsole mit 24 Zeilen und 80 Spalten.
_ui_size() { UI_H=20 UI_W=76; }

# Die Dialoge laufen teils in $(…), also in einer Subshell. Deshalb landet alles in Dateien.
log() { printf '%s\n' "$*" >>"$T/log"; }
ui_msg() { printf '%s' "$2" >"$T/msg"; }
ui_input() {
	printf '%s' "$2" >"$T/ask"
	((CANCEL)) && return 1
	printf '%s' "$INPUT"
}
disk_info() { printf '%s' "$DISK"; }
lsblk() {
	local i
	echo "NAME   SIZE FSTYPE LABEL"
	echo "sdb  465.8G"
	for ((i = 1; i <= PARTS; i++)); do echo "├─sdb$i  10G ntfs   Daten$i"; done
}

disk() { # disk SERIENNUMMER WWN [GRÖSSE] [PFAD]   (WWN "null" = Feld fehlt)
	local wwn=\"$2\"
	[[ $2 == null ]] && wwn=null
	DISK="{\"name\":\"sdb\",\"path\":\"${4:-/dev/sdb}\",\"size\":${3:-500107862016},\"model\":\"Testdisk\",\"serial\":\"$1\",\"wwn\":$wwn,\"tran\":\"usb\"}"
}

# confirm EINGABE   -> RC, ASK (Dialogtext), MSG (Meldung), LOG
confirm() {
	INPUT=$1
	rm -f "$T/ask" "$T/msg" "$T/log"
	safety_confirm_target ZIEL "Ziel wird überschrieben."
	RC=$?
	ASK=$(cat "$T/ask" 2>/dev/null)
	MSG=$(cat "$T/msg" 2>/dev/null)
	LOG=$(cat "$T/log" 2>/dev/null)
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

CANCEL=0
PARTS=2

echo "Seriennummer mit 14 Zeichen:"
disk S5Y1NJ0R123456 0x5002538f12345678
confirm 3456
check "letzte 4 Zeichen bestätigen" '[[ $RC == 0 ]]'
check "Dialog verlangt die Seriennummer" '[[ $ASK == *"letzten 4 Zeichen der Seriennummer eingeben (S5Y1NJ0R123456):" ]]'
check "Bestätigung steht im Protokoll" '[[ $LOG == *"Ziel bestätigt: /dev/sdb (Seriennummer S5Y1NJ0R123456)"* ]]'
confirm ""
check "leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
check "Meldung nennt den Grund" '[[ $MSG == *"nichts eingegeben"* ]]'
check "keine Bestätigung im Protokoll" '[[ $LOG != *"Ziel bestätigt"* ]]'
confirm "   "
check "nur Leerzeichen werden abgelehnt" '[[ $RC != 0 ]]'
confirm 0000
check "falsche Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
check "Meldung: nichts geändert" '[[ $MSG == *"nichts geändert"* ]]'
confirm 23456
check "mehr als verlangt wird abgelehnt" '[[ $RC != 0 ]]'
confirm " 3456 "
check "Leerzeichen um die Eingabe stören nicht" '[[ $RC == 0 ]]'
CANCEL=1
confirm 3456
check "Abbrechen bestätigt nicht" '[[ $RC != 0 ]]'
CANCEL=0

echo "Groß-/Kleinschreibung:"
disk WD-WCC6Y0ABCDEF null
confirm cdef
check "klein getippt passt" '[[ $RC == 0 ]]'
confirm CDEF
check "groß getippt passt" '[[ $RC == 0 ]]'

echo "Seriennummer mit weniger als 4 Zeichen:"
disk A1 null
confirm ""
check "leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
confirm a1
check "ganze Seriennummer bestätigt" '[[ $RC == 0 ]]'
check "Dialog verlangt die ganze Seriennummer" '[[ $ASK == *"nur 2 Zeichen"*"die ganze Seriennummer eingeben (A1):" ]]'
check "Dialog spricht nicht von 4 Zeichen" '[[ $ASK != *"letzten 4 Zeichen"* ]]'
disk XYZ null
confirm YZ
check "ein Teil der kurzen Seriennummer reicht nicht" '[[ $RC != 0 ]]'
confirm XYZ
check "drei Zeichen ganz getippt passen" '[[ $RC == 0 ]]'
disk 7 null
confirm ""
check "ein Zeichen: leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
confirm 7
check "ein Zeichen: ganz getippt passt" '[[ $RC == 0 ]]'

echo "Nur WWN:"
disk "" 0x50014ee2b1c2d3e4
confirm D3E4
check "letzte 4 Zeichen der WWN bestätigen" '[[ $RC == 0 ]]'
check "Dialog nennt die WWN" '[[ $ASK == *"keine Seriennummer"*"letzten 4 Zeichen der WWN eingeben (0x50014ee2b1c2d3e4):" ]]'
check "Dialog verlangt keine Seriennummer" '[[ $ASK != *"der Seriennummer eingeben"* ]]'
check "Disk-Zeile zeigt einen Strich statt einer Seriennummer" '[[ $ASK == *"GiB · SN – · usb"* ]]'
confirm ""
check "leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
confirm sdb
check "der Gerätename reicht nicht" '[[ $RC != 0 ]]'

echo "Weder Seriennummer noch WWN (sdb, 500 GB):"
disk "" null
confirm ""
check "leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
confirm sdb
check "der Gerätename allein reicht nicht" '[[ $RC != 0 ]]'
confirm sdb-466GiB
check "Gerätename und Größe bestätigen" '[[ $RC == 0 ]]'
check "Dialog sagt, dass die Kennungen fehlen" '[[ $ASK == *"weder Seriennummer noch WWN"* ]]'
check "Dialog zeigt genau die verlangte Eingabe" '[[ $ASK == *"genau so: sdb-466GiB" ]]'
check "Dialog verlangt keine Seriennummer" '[[ $ASK != *"Seriennummer eingeben"* ]]'
confirm SDB-466gib
check "Groß-/Kleinschreibung egal" '[[ $RC == 0 ]]'
confirm sdb-465GiB
check "falsche Größe wird abgelehnt" '[[ $RC != 0 ]]'
disk "   " "" 21474836480 /dev/vda
confirm vda-20GiB
check "Leerraum als Seriennummer zählt als keine (vda, 20 GiB)" '[[ $RC == 0 ]]'
disk "" null 536870912
confirm sdb-512MiB
check "kleine Disk in MiB" '[[ $RC == 0 ]]'

echo "Disk nicht mehr vorhanden:"
DISK=""
confirm ""
check "leere Eingabe wird abgelehnt" '[[ $RC != 0 ]]'
check "es wird gar nicht erst gefragt" '[[ -z $ASK ]]'
check "Meldung nennt den Grund" '[[ $MSG == *"nicht mehr zu finden"* ]]'
DISK="kein JSON"
confirm ""
check "unlesbare Angaben: abgelehnt" '[[ $RC != 0 && -z $ASK ]]'

echo "Platz im Dialog (24 Zeilen, 80 Spalten):"
disk S5Y1NJ0R123456 null
PARTS=40
confirm 3456
lines=$(ui_fold "$ASK" | wc -l)
check "Text passt bei 40 Partitionen in die Box" '((lines <= $(ui_input_room)))'
check "Aufforderung ist die letzte Zeile" '[[ $(ui_fold "$ASK" | tail -n1) == *"(S5Y1NJ0R123456):" ]]'
check "gekürzte Liste ist gekennzeichnet" '[[ $ASK == *"weitere Einträge)"* ]]'
check "Bestätigung klappt trotzdem" '[[ $RC == 0 ]]'
disk "" null
confirm sdb-466GiB
lines=$(ui_fold "$ASK" | wc -l)
check "auch der längere Text ohne Kennung passt" '((lines <= $(ui_input_room)))'
check "die verlangte Eingabe steht in der letzten Zeile" '[[ $(ui_fold "$ASK" | tail -n1) == *"sdb-466GiB" ]]'
PARTS=2
confirm sdb-466GiB
check "kurze Liste bleibt vollständig" '[[ $ASK == *"sdb2"* && $ASK != *"weitere Einträge"* ]]'

echo "Disk-Zeile und Umbruch:"
disk S5Y1NJ0R123456 null
check "Größe vor der Seriennummer, SN davor" '[[ $(disk_label "$DISK") == "/dev/sdb · Testdisk · 465.8GiB · SN S5Y1NJ0R123456 · usb" ]]'
check "Umbruch am Leerzeichen" '[[ $(ui_fold "$(printf "%080d" 0 | tr 0 a) bbb" | wc -l) == 2 ]]'
check "\\n wird zum Zeilenwechsel" '[[ $(ui_fold "eins\nzwei\n\ndrei" | wc -l) == 4 ]]'
check "Wort ohne Leerzeichen wird hart getrennt" '[[ $(ui_fold " $(printf "%0150d" 0)" | wc -l) == 3 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
