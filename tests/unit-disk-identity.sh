#!/usr/bin/env bash
# Unit-Test: Eine Disk ist nur über eine eindeutige Kennung wählbar, und bestätigt wird genau
# das Gerät, auf das danach geschrieben wird.
#
# 1. Kennungen. Der Assistent führt eine Disk unter ihrer Seriennummer, sonst unter der WWN,
#    sonst unter dem Gerätepfad. Baugleiche USB-Adapter melden oft dieselbe feste Seriennummer,
#    und ein präpariertes Gerät meldet, was es will. Bisher nahm disk_resolve den ersten
#    Treffer: Wer die zweite Disk wählte, arbeitete auf der ersten.
# 2. Gerätepfad. Die Aufrufer lösen den Pfad vor der Bestätigung auf und schreiben danach
#    darauf. Ändert sich der Name, solange der Dialog offen ist, wäre die richtige Disk
#    bestätigt und die falsche beschrieben.
#
# Ohne echte Disks und ohne whiptail: lsblk ist eine Attrappe mit einer gedachten Maschine.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
LF_RUN=$T
LF_LOG=$T/log
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/safety.sh

_ui_size() { UI_H=20 UI_W=76; }
boot_disk() { return 1; }
disk_smart() { echo "OK|"; }
ui_msg() { printf '%s' "$2" >"$T/msg"; }
# Das Menü merkt sich Text und Einträge und "wählt" den Eintrag PICK.
ui_menu() {
	printf '%s' "$2" >"$T/menutext"
	shift 2
	while [[ $# -gt 0 && $1 != -- ]]; do shift; done
	shift
	: >"$T/tags"
	while [[ $# -gt 1 ]]; do
		printf '%s\n' "$1" >>"$T/tags"
		shift 2
	done
	printf '%s' "${PICK:-}"
}
# Die Eingabe tippt TYPE. Mit DURING läuft vorher ein Befehl: So ändert sich die Maschine,
# während der Dialog offen ist.
ui_input() {
	printf '%s' "$2" >"$T/ask"
	[[ -z ${DURING:-} ]] || eval "$DURING"
	printf '%s' "$TYPE"
}

# Die gedachte Maschine: je Disk eine Zeile "NAME GRÖSSE SERIENNUMMER WWN" in $T/disks.
# "-" steht für eine fehlende Angabe.
machine() { printf '%s\n' "$@" >"$T/disks"; }
lsblk() {
	if [[ " $* " == *" -J "* ]]; then
		jq -Rn '{blockdevices: [inputs | split(" ") | {name: .[0], path: ("/dev/" + .[0]), size: (.[1] | tonumber),
			model: "Testdisk", serial: (if .[2] == "-" then null else .[2] end),
			wwn: (if .[3] == "-" then null else .[3] end), tran: "usb", rota: false, type: "disk", rm: false,
			"log-sec": 512, "phy-sec": 512}]}' "$T/disks"
	else
		echo "NAME   SIZE FSTYPE LABEL"
		echo "sdX  465.8G"
	fi
}
G=500107862016

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
ids() { disks_json | while IFS= read -r j; do disk_id "$j"; done | tr '\n' ' '; }

# ---------------------------------------------------------------------------
echo "Alle Kennungen eindeutig: wie bisher"
machine "sda $G AAA111 0x5000c500aaaa0001" "sdb $G BBB222 -" "sdc $G - -"
check "jede Disk unter Seriennummer, sonst unter ihrem Pfad" '[[ $(ids) == "AAA111 BBB222 /dev/sdc " ]]'
check "Seriennummer führt zum Pfad" '[[ $(disk_resolve BBB222) == /dev/sdb ]]'
check "WWN führt zum Pfad" '[[ $(disk_resolve 0x5000c500aaaa0001) == /dev/sda ]]'
check "Pfad führt zum Pfad" '[[ $(disk_resolve /dev/sdc) == /dev/sdc ]]'
check "keine Disk ist als mehrdeutig markiert" '[[ -z $(disks_json | jq -r "select(.dup) | .path") ]]'
PICK=BBB222 disk_pick "Ziel" "Welche Disk?" >/dev/null
check "die Auswahl nennt keinen Hinweis" '[[ $(cat "$T/menutext") == "Welche Disk?" ]]'

echo "Zwei Disks melden dieselbe Seriennummer (baugleiche Adapter)"
machine "sda $G AAA111 -" "sdb $G 0123456789AB -" "sdc $G 0123456789AB -"
check "beide stehen unter ihrem Pfad, die dritte unter ihrer Seriennummer" '[[ $(ids) == "AAA111 /dev/sdb /dev/sdc " ]]'
check "die gemeinsame Seriennummer führt zu keiner Disk" '[[ -z $(disk_resolve 0123456789AB) ]]'
check "zu ihr gibt es auch keine Angaben" '[[ -z $(disk_info 0123456789AB) ]]'
check "die zweite Disk ist über ihren Pfad erreichbar" '[[ $(disk_resolve /dev/sdc) == /dev/sdc ]]'
check "beide sind markiert" '[[ $(disks_json | jq -r "select(.dup) | .path" | tr "\n" " ") == "/dev/sdb /dev/sdc " ]]'
PICK=/dev/sdc
picked=$(disk_pick "Ziel" "Welche Disk?")
check "im Menü hat jede Disk einen eigenen Eintrag" '[[ $(sort "$T/tags" | uniq -d | wc -l) == 0 && $(wc -l <"$T/tags") == 3 ]]'
check "die Wahl der zweiten Disk führt zur zweiten Disk" '[[ $(disk_resolve "$picked") == /dev/sdc ]]'
check "die Auswahl sagt, warum dort Gerätenamen stehen" '[[ $(cat "$T/menutext") == *"Mehrere Disks melden dieselbe Seriennummer"* ]]'
check "ausgeschlossen wird nur die gemeinte Disk" '[[ $(PICK=x disk_pick "Ziel" "Welche?" /dev/sdb >/dev/null; tr "\n" " " <"$T/tags") == "AAA111 /dev/sdc " ]]'
check "die Disk-Zeile nennt die Seriennummer nicht als Kennung" '[[ $(disk_label "$(disk_info /dev/sdc)") == *"SN nicht eindeutig"* ]]'
safety_confirm_token "$(disk_info /dev/sdc)"
check "bestätigt wird über Gerätename und Größe" '[[ $SAFETY_WANT == sdc-466GiB ]]'
check "die Aufforderung nennt den Grund" '[[ $SAFETY_ASK == *"dieselbe Seriennummer"* ]]'
TYPE=89AB DURING=""
safety_confirm_target /dev/sdc "Ziel wird überschrieben." /dev/sdc
check "die letzten vier Zeichen der gemeinsamen Seriennummer bestätigen nichts" '[[ $? != 0 ]]'
rm -f "$T/ask" "$T/msg"
safety_confirm_target 0123456789AB "Ziel wird überschrieben."
rc=$?
check "eine früher gemerkte, jetzt mehrdeutige Kennung wird nicht bestätigt" '[[ $rc != 0 && ! -e $T/ask && $(cat "$T/msg") == *"nicht mehr eindeutig"* ]]'

echo "Dieselbe Seriennummer, aber eigene WWN"
machine "sdb $G 0123456789AB 0x5000c500bbbb0002" "sdc $G 0123456789AB 0x5000c500cccc0003"
check "beide stehen unter ihrer WWN" '[[ $(ids) == "0x5000c500bbbb0002 0x5000c500cccc0003 " ]]'
safety_confirm_token "$(disk_info 0x5000c500cccc0003)"
check "bestätigt wird über die WWN" '[[ $SAFETY_WANT == 0003 && $SAFETY_ASK == *"dieselbe Seriennummer"*"WWN"* ]]'

echo "Eine Disk meldet als Seriennummer die WWN einer anderen"
machine "sda $G AAA111 0x5000c500aaaa0001" "sdb $G 0x5000c500aaaa0001 -"
check "die Kennung führt zu keiner Disk" '[[ -z $(disk_resolve 0x5000c500aaaa0001) ]]'
check "die erste Disk bleibt über ihre Seriennummer erreichbar" '[[ $(disk_resolve AAA111) == /dev/sda ]]'
check "die zweite steht unter ihrem Pfad" '[[ $(ids) == "AAA111 /dev/sdb " ]]'

echo "Leere und unbekannte Kennung"
machine "sda $G - -" "sdb $G - -"
check "eine leere Kennung führt zu keiner Disk" '[[ -z $(disk_resolve "") && -z $(disk_info "") ]]'
check "eine unbekannte auch nicht" '[[ -z $(disk_resolve NICHTDA) ]]'

# ---------------------------------------------------------------------------
echo "Bestätigt wird das Gerät, auf das geschrieben wird"
machine "sda $G AAA111 -" "sdb $G BBB222 -"
TYPE=B222 DURING=""
rm -f "$T/ask" "$T/msg"
safety_confirm_target BBB222 "Ziel wird überschrieben." /dev/sdb
rc=$?
check "unveränderter Pfad: bestätigt, der Pfad steht in SAFETY_DEV" '[[ $rc == 0 && ${SAFETY_DEV-} == /dev/sdb ]]'
check "safety_still erkennt denselben Pfad" 'safety_still BBB222 /dev/sdb'
check "safety_still erkennt einen anderen Pfad" '! safety_still BBB222 /dev/sda'

rm -f "$T/ask" "$T/msg"
safety_confirm_target BBB222 "Ziel wird überschrieben." /dev/sdx
rc=$?
check "der Aufrufer arbeitet mit einem alten Pfad: kein Dialog, keine Bestätigung" '[[ $rc != 0 && ! -e $T/ask && -z ${SAFETY_DEV-} ]]'
check "die Meldung nennt beide Namen" '[[ $(cat "$T/msg") == *"vorher /dev/sdx, jetzt /dev/sdb"* ]]'

# Während der Dialog offen ist, tauschen die beiden Disks ihre Namen (Reset am USB-Hub).
machine "sda $G AAA111 -" "sdb $G BBB222 -"
DURING='machine "sda $G BBB222 -" "sdb $G AAA111 -"'
rm -f "$T/ask" "$T/msg"
safety_confirm_target BBB222 "Ziel wird überschrieben." /dev/sdb
rc=$?
check "Namen tauschen während der Eingabe: trotz richtiger Eingabe nicht bestätigt" '[[ $rc != 0 && -e $T/ask && -z ${SAFETY_DEV-} ]]'
check "die Meldung sagt, dass nichts geändert wurde" '[[ $(cat "$T/msg") == *"Während der Bestätigung"*"nichts geändert"* ]]'

machine "sda $G AAA111 -" "sdb $G BBB222 -"
DURING='machine "sda $G AAA111 -"'
safety_confirm_target BBB222 "Ziel wird überschrieben." /dev/sdb
check "die Disk verschwindet während der Eingabe: nicht bestätigt" '[[ $? != 0 && -z ${SAFETY_DEV-} ]]'

# Eine zweite Disk mit derselben Seriennummer taucht auf, während der Dialog offen ist.
machine "sda $G AAA111 -" "sdb $G BBB222 -"
DURING='machine "sda $G AAA111 -" "sdb $G BBB222 -" "sdc $G BBB222 -"'
safety_confirm_target BBB222 "Ziel wird überschrieben." /dev/sdb
check "die Kennung wird während der Eingabe mehrdeutig: nicht bestätigt" '[[ $? != 0 && -z ${SAFETY_DEV-} ]]'
DURING=""

echo "Jeder schreibende Weg nennt der Bestätigung seinen Pfad"
n=$(grep -c 'safety_confirm_target "\$tid"' rescue/lib/target.sh rescue/lib/clone.sh rescue/lib/resize.sh | awk -F: '{s += $2} END {print s}')
with=$(grep -c 'safety_confirm_target "\$tid" .*"\$t\?dev" ||' rescue/lib/target.sh rescue/lib/clone.sh rescue/lib/resize.sh | awk -F: '{s += $2} END {print s}')
check "alle Aufrufe bis auf die Expertenwerkzeuge übergeben den Pfad ($with von $n)" '[[ $n -ge 9 && $with == $((n - 1)) ]]'
check "die Expertenwerkzeuge lösen den Pfad nach der Bestätigung neu auf" 'grep -A3 "safety_confirm_target \"\$tid\" \"\$t arbeitet" rescue/lib/resize.sh | grep -q "dev=\$(disk_resolve \"\$tid\")"'
check "nach einem weiteren Dialog wird vor dem Schreiben noch einmal geprüft (Löschen, gdisk)" '[[ $(grep -c "safety_still \"\$tid\" \"\$dev\"" rescue/lib/resize.sh) == 2 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
