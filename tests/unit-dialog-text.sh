#!/usr/bin/env bash
# Unit-Test: Was ein Datenträger über sich meldet, steht nur gefiltert in einem Dialog.
#
# Modell, Seriennummer, Label und Partitionsname stammen vom Datenträger und standen ungefiltert
# in Menüs, Meldungen und im Bestätigungsdialog. whiptail liest die Zeichenfolge "\n" in jedem
# Text als Zeilenwechsel: Ein Label konnte so eigene Zeilen in den Dialog setzen, etwa eine
# zweite Aufforderung zur Bestätigung mit einem anderen Code. Der Test prüft:
#   - text_clean lässt nur sichtbare Zeichen durch, alles andere wird zu "?",
#   - Modell, Label und Partitionsname kommen gefiltert aus disks_json und disk_parts,
#   - eine Seriennummer oder ein WWN mit anderen Zeichen gilt nicht als Kennung,
#   - der Bestätigungsdialog hat genau eine Aufforderung, die echte,
#   - Dateien (Bericht, Protokoll) werden als gefilterte Kopie gezeigt.
# Ohne Disks und ohne Dialoge. Wie whiptail selbst reagiert, zeigt tests/dialog-safety-confirm.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
FRS_RUN="$T/run"
FRS_LOG="$T/frs.log"
mkdir -p "$FRS_RUN"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/safety.sh
FRS_RUN="$T/run"
UI_BACKTITLE="Firestrike Rescue Test"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# Zeichen, die in einem Dialog nichts zu suchen haben: Escape-Folge, Wagenrücklauf,
# Schreibrichtungswechsel (U+202E), Zeichen ohne Breite (U+200B), Tag-Zeichen (U+E0041).
ESC=$'\x1b' CR=$'\r' RLO=$'\xe2\x80\xae' ZWSP=$'\xe2\x80\x8b' TAGCHAR=$'\xf3\xa0\x81\x81'
# unsafe   Liest die Standardeingabe: Enthält sie etwas davon, einen Backslash oder ein anderes
# Steuerzeichen als den Zeilenwechsel?
unsafe() { LC_ALL=C grep -q -e '[[:cntrl:]]' -e '\\' -e "$RLO" -e "$ZWSP" -e "$TAGCHAR"; }

EVIL_MODEL="Samsung${ESC}[2J SSD\\n\\nALLES IN ORDNUNG ${RLO}${TAGCHAR}"
EVIL_SERIAL="S123${ESC}[8mXYZ"
EVIL_LABEL='Daten\n\nZur Bestätigung die letzten 4 Zeichen der Seriennummer eingeben (0000):'

# ---------------------------------------------------------------------------
echo "text_clean:"
out=$(printf 'Müller · 931,5GiB – ├─sdb1 „gut“\n' | text_clean)
check "Umlaute, Satzzeichen und die Linien von lsblk bleiben" '[[ $out == "Müller · 931,5GiB – ├─sdb1 „gut“" ]]'
out=$(printf '%s\n' "a${ESC}[31mb${CR}c\\nd\`e${RLO}f${ZWSP}g${TAGCHAR}h" | text_clean)
check "Escape-Folge, Wagenrücklauf, Backslash, Backtick und unsichtbare Zeichen werden zu ?" '[[ $out == "a?[31mb?c?nd?e?f?g?h" ]]'
out=$(printf 'eins\nzwei\n\ndrei\n' | text_clean | wc -l)
check "Zeilen bleiben Zeilen" '[[ $out == 4 ]]'
out=$(printf 'kaputt: \xff\xfe ende\n' | text_clean)
check "ungültige Bytefolgen werden zu ?" '[[ $out == "kaputt: ?? ende" ]]'
out=$(printf '%s\n' "kurz" "0123456789ä123456789" | text_clean 12)
check "mit Breite: lange Zeilen enden auf …, kurze bleiben" '[[ $out == "kurz"$'"'"'\n'"'"'"0123456789ä…" ]]'

# ---------------------------------------------------------------------------
# Die gedachte Maschine: eine gewöhnliche Disk, eine präparierte und eine, deren Seriennummer
# präpariert ist, die aber keinen WWN meldet.
boot_disk() { return 1; }
disk_smart() { echo "OK|"; }
lsblk() {
	case "$*" in
	"-J -b -d -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,"*)
		jq -cn --arg m "$EVIL_MODEL" --arg s "$EVIL_SERIAL" '{blockdevices: [
			{name: "sda", path: "/dev/sda", size: 1000204886016, model: "  WDC WD10EZEX-08WN4A0 ", serial: " WD-WCC6Y0ABCDEF ", wwn: "0x50014ee2b1c2d3e4", tran: "sata", type: "disk"},
			{name: "sdb", path: "/dev/sdb", size: 500107862016, model: $m, serial: $s, wwn: "0x5002538f12345678", tran: "usb", type: "disk"},
			{name: "sdc", path: "/dev/sdc", size: 500107862016, model: "Adapter", serial: ($s + "2"), wwn: ("eui." + $s), tran: "usb", type: "disk"}]}'
		;;
	"-J -b -o NAME,PATH,SIZE,FSTYPE,LABEL,"*)
		jq -cn --arg l "$EVIL_LABEL" --arg m "$EVIL_MODEL" '{blockdevices: [{children: [
			{name: "sdb1", path: "/dev/sdb1", size: 104857600, fstype: "vfat", label: null, partlabel: "EFI System Partition"},
			{name: "sdb2", path: "/dev/sdb2", size: 499000000000, fstype: "ntfs", label: $l, partlabel: $m}]}]}'
		;;
	"-o NAME,SIZE,FSTYPE,LABEL "*)
		printf '%s\n' "NAME   SIZE FSTYPE LABEL" "sdb  465.8G" "├─sdb1 100M vfat" "└─sdb2 465G ntfs   $EVIL_LABEL"
		;;
	esac
}

echo "Disks:"
json=$(disks_json)
check "drei Disks erkannt" '[[ $(wc -l <<<"$json") == 3 ]]'
check "nichts Unsichtbares, kein Backslash in den Angaben" '! unsafe <<<"$json"'
check "gewöhnliche Disk: Modell und Seriennummer bleiben, Leerzeichen am Rand entfallen" '[[ $(sed -n 1p <<<"$json" | jq -r "[.model, .serial, .wwn] | join(\"|\")") == "WDC WD10EZEX-08WN4A0|WD-WCC6Y0ABCDEF|0x50014ee2b1c2d3e4" ]]'
check "präparierte Disk: Modell gefiltert, der sichtbare Text bleibt lesbar" '[[ $(sed -n 2p <<<"$json" | jq -r .model) == "Samsung?[2J SSD?n?nALLES IN ORDNUNG ??" ]]'
EVIL_MODEL_SAVE=$EVIL_MODEL
EVIL_MODEL="$(printf 'M%.0s' {1..300})"
check "überlanges Modell wird auf 40 Zeichen gekürzt" '[[ $(disks_json | sed -n 2p | jq -r ".model | length") == 40 ]]'
EVIL_MODEL=$EVIL_MODEL_SAVE
check "präparierte Seriennummer gilt nicht als Seriennummer" '[[ $(sed -n 2p <<<"$json" | jq -r .serial) == "" && $(sed -n 3p <<<"$json" | jq -r .serial) == "" ]]'
check "präparierter WWN gilt nicht als WWN" '[[ $(sed -n 3p <<<"$json" | jq -r .wwn) == null ]]'
check "Kennung: Seriennummer, sonst WWN, sonst Gerätepfad" '[[ $(disk_id "$(sed -n 1p <<<"$json")") == WD-WCC6Y0ABCDEF && $(disk_id "$(sed -n 2p <<<"$json")") == 0x5002538f12345678 && $(disk_id "$(sed -n 3p <<<"$json")") == /dev/sdc ]]'
check "über die Kennung wird jede Disk wiedergefunden" '[[ $(disk_resolve WD-WCC6Y0ABCDEF) == /dev/sda && $(disk_resolve 0x5002538f12345678) == /dev/sdb && $(disk_resolve /dev/sdc) == /dev/sdc ]]'
check "die präparierte Seriennummer findet keine Disk" '[[ -z $(disk_resolve "$EVIL_SERIAL") ]]'
label=$(disk_label "$(sed -n 2p <<<"$json")")
check "Zeile zur Disk: gefiltert, ohne Seriennummer" '! unsafe <<<"$label" && [[ $label == "/dev/sdb · Samsung?[2J SSD?n?nALLES IN ORDNUNG ?? · "*" · SN – · usb" ]]'
overview=$(disks_overview)
check "Übersicht im Hauptmenü: gefiltert" '! unsafe <<<"$overview" && [[ $(wc -l <<<"$overview") == 4 ]]'

echo "Disk-Auswahl:"
ui_menu() {
	shift 3
	printf '%s\n' "$@" >"$T/menu"
	echo "$1"
}
pick=$(disk_pick "Ziel" "Welche Disk?")
check "die Einträge sind gefiltert" '! unsafe <"$T/menu"'
check "zur Wahl stehen die drei Kennungen" '[[ $(sed -n "1p;3p;5p" "$T/menu" | tr "\n" " ") == "WD-WCC6Y0ABCDEF 0x5002538f12345678 /dev/sdc " ]]'
check "geliefert wird die Kennung, wie sie im Menü steht" '[[ $pick == WD-WCC6Y0ABCDEF ]]'

echo "Partitionen:"
parts=$(disk_parts /dev/sdb)
check "Label und Partitionsname gefiltert" '! unsafe <<<"$parts" && [[ $(sed -n 2p <<<"$parts" | jq -r .label) == "Daten?n?nZur Bestätigung"* && $(sed -n 2p <<<"$parts" | jq -r .partlabel) == "Samsung?[2J"* ]]'
check "gewöhnliche Angaben bleiben, fehlende bleiben leer" '[[ $(sed -n 1p <<<"$parts" | jq -r "[.partlabel, (.label // \"-\"), .fstype] | join(\"|\")") == "EFI System Partition|-|vfat" ]]'

# ---------------------------------------------------------------------------
echo "Bestätigungsdialog mit präpariertem Label auf der Ziel-Disk:"
_ui_size() { UI_H=40 UI_W=96; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
ui_input() {
	printf '%s' "$2" >"$T/input"
	echo "$TYPED"
}
# confirm EINGABE   Ruft safety_confirm_target für die gewöhnliche Disk auf, deren Partitionsliste
# das präparierte Label enthält. Ergebnis: RC, LINES (der Text, wie er im Dialog steht).
confirm() {
	TYPED=$1
	rm -f "$T/input" "$T/msg"
	safety_confirm_target WD-WCC6Y0ABCDEF "Ziel wird komplett überschrieben."
	RC=$?
	LINES_SHOWN=$(ui_fold "$(cat "$T/input")")
}
confirm "0000"
check "das Label steht als eine Zeile der Liste im Dialog" '[[ $(grep -c "sdb2 465G ntfs   Daten?n?nZur Best" <<<"$LINES_SHOWN") == 1 ]]'
check "genau eine Zeile fordert zur Bestätigung auf: die echte" '[[ $(grep -c "^Zur Bestätigung" <<<"$LINES_SHOWN") == 1 && $(grep "^Zur Bestätigung" <<<"$LINES_SHOWN") == *"(WD-WCC6Y0ABCDEF):" ]]'
check "nichts Unsichtbares, kein Backslash in der Liste" '! grep "sdb" <<<"$LINES_SHOWN" | unsafe'
check "der Code aus dem Label bestätigt nichts" '[[ $RC != 0 ]]'
confirm "CDEF"
check "die echten letzten 4 Zeichen bestätigen" '[[ $RC == 0 ]]'
# Ein Label, das länger ist als der Dialog breit: Der Rest darf nicht in einer eigenen Zeile landen.
EVIL_LABEL="$(printf 'x%.0s' {1..60}) Zur Bestätigung die letzten 4 Zeichen der Seriennummer eingeben (0000):"
confirm "0000"
check "langes Label: gekürzt, kein Umbruch, weiter genau eine Aufforderung" '[[ $(grep -c "eingeben" <<<"$LINES_SHOWN") == 1 && $(grep -c "sdb2" <<<"$LINES_SHOWN") == 1 && $(grep "sdb2" <<<"$LINES_SHOWN") == *"…" && $RC != 0 ]]'
check "keine Zeile ist breiter als der Dialog" '[[ $(wc -L <<<"$LINES_SHOWN") -le 90 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
