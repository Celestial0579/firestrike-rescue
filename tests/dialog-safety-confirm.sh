#!/usr/bin/env bash
# Dialogtest für die Ziel-Bestätigung: zeichnet den Dialog mit echtem whiptail in ein
# Pseudo-Terminal (script) und prüft, was dort ankommt und wie die Eingabe gewertet wird.
#
# Der Unit-Test daneben rechnet nur nach, wie viele Zeilen der Text hat. Ob whiptail sie auch
# zeigt, sieht man erst hier. Anlass: Die Eingabebox war fest 12 Zeilen hoch, whiptail schnitt
# den Text nach sechs Zeilen stillschweigend ab, und die Aufforderung "… eingeben" erschien nie.
#
# Braucht whiptail, script (bsdutils) und jq. Disks werden nicht angefasst: disk_info und
# lsblk sind durch feste Angaben ersetzt.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

for t in whiptail script jq; do
	command -v "$t" >/dev/null || { echo "Fehlt: $t. Der Dialogtest braucht whiptail, script (bsdutils) und jq."; exit 1; }
done

T=$(mktemp -d)
WAIT=${FRS_TEST_WAIT:-2} # Sekunden, bis der Dialog steht und Tasten ankommen dürfen

# Läuft im Pseudo-Terminal: echte Bibliotheken, nur die Disk ist ausgedacht.
cat >"$T/innen.sh" <<'EOF'
#!/usr/bin/env bash
stty rows "$ROWS" cols "$COLS"
export TERM=linux
cd "$REPO" || exit 1
. rescue/lib/common.sh
. rescue/lib/disks.sh
. rescue/lib/safety.sh
FRS_LOG=/dev/null
UI_BACKTITLE="Firestrike Rescue Dialogtest"
disk_info() {
	case $FALL in
	sn) echo '{"path":"/dev/sdb","size":500107862016,"model":"Testdisk","serial":"S5Y1NJ0R123456","wwn":"0x5002538f12345678","tran":"usb"}' ;;
	kurz) echo '{"path":"/dev/sdb","size":500107862016,"model":"Testdisk","serial":"A1","wwn":null,"tran":"usb"}' ;;
	wwn) echo '{"path":"/dev/sdb","size":500107862016,"model":"Testdisk","serial":"","wwn":"0x50014ee2b1c2d3e4","tran":"sata"}' ;;
	ohne) echo '{"path":"/dev/sdb","size":500107862016,"model":"Testdisk","serial":"","wwn":null,"tran":"usb"}' ;;
	esac
}
lsblk() {
	local i
	echo "NAME   SIZE FSTYPE LABEL"
	echo "sdb  465.8G"
	for ((i = 1; i <= PARTS; i++)); do echo "sdb$i  10G ntfs   Daten$i"; done
}
safety_confirm_target ZIEL "Ziel wird komplett ueberschrieben."
echo $? >"$OUT/rc"
EOF

# show FALL ZEILEN SPALTEN PARTITIONEN TASTEN...
# Jede Tastenfolge wird nach einer Pause gesendet. Ergebnis: RC (Rückgabe von
# safety_confirm_target) und SCREEN (alles, was whiptail gezeichnet hat, ohne Steuerfolgen).
show() {
	local fall=$1 rows=$2 cols=$3 parts=$4 keys
	shift 4
	rm -f "$T/rc" "$T/mitschnitt"
	(
		for keys in "$@"; do
			sleep "$WAIT"
			printf '%b' "$keys"
		done
		sleep 1
	) | FALL=$fall ROWS=$rows COLS=$cols PARTS=$parts REPO=$PWD OUT=$T \
		timeout 60 script -qec "bash '$T/innen.sh'" "$T/mitschnitt" >/dev/null 2>&1
	RC=$(cat "$T/rc" 2>/dev/null || echo "kein Ergebnis")
	# Die erste Zeile stammt von script selbst, danach folgt, was whiptail an das Terminal schickt.
	SCREEN=$(sed -E '1{/^S[ck]ript /d}; s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][0-9A-Za-z]//g' "$T/mitschnitt" 2>/dev/null | tr -d '\r\016\017')
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

ESC='\033'
ENTER='\r'

echo "Aufforderung sichtbar (Textkonsole 25x80, 4 Partitionen):"
show sn 25 80 4 "$ESC"
check "Seriennummer: Aufforderung" '[[ $SCREEN == *"Seriennummer eingeben"* && $SCREEN == *"(S5Y1NJ0R123456):"* ]]'
check "Abbrechen bestätigt nicht" '[[ $RC == 1 ]]'
show kurz 25 80 4 "$ESC"
check "kurze Seriennummer: ganze verlangt" '[[ $SCREEN == *"Seriennummer eingeben (A1):"* ]]'
show wwn 25 80 4 "$ESC"
check "nur WWN: Aufforderung" '[[ $SCREEN == *"der WWN eingeben"* && $SCREEN == *"(0x50014ee2b1c2d3e4):"* ]]'
show ohne 25 80 4 "$ESC"
check "ohne Kennung: verlangte Eingabe" '[[ $SCREEN == *"genau so: sdb-466GiB"* ]]'

echo "Aufforderung sichtbar trotz 40 Partitionen:"
show sn 25 80 40 "$ESC"
check "25x80: Aufforderung" '[[ $SCREEN == *"Seriennummer eingeben"* && $SCREEN == *"(S5Y1NJ0R123456):"* ]]'
check "25x80: Liste gekürzt und gekennzeichnet" '[[ $SCREEN == *"weitere Eintr"* && $SCREEN != *"Daten40"* ]]'
show ohne 25 80 40 "$ESC"
check "25x80 ohne Kennung: verlangte Eingabe" '[[ $SCREEN == *"genau so: sdb-466GiB"* ]]'
show sn 67 240 40 "$ESC"
check "67x240: Aufforderung und ganze Liste" '[[ $SCREEN == *"(S5Y1NJ0R123456):"* && $SCREEN == *"Daten40"* ]]'

echo "Eingabe mit echtem whiptail:"
show ohne 25 80 4 "$ENTER" "$ENTER"
check "ohne Kennung: nur Enter wird abgelehnt" '[[ $RC == 1 ]]'
show ohne 25 80 4 "sdb-466GiB$ENTER"
check "ohne Kennung: Gerätename und Größe bestätigen" '[[ $RC == 0 ]]'
show kurz 25 80 4 "$ENTER" "$ENTER"
check "kurze Seriennummer: nur Enter wird abgelehnt" '[[ $RC == 1 ]]'
show sn 25 80 4 "3456$ENTER"
check "Seriennummer: letzte 4 Zeichen bestätigen" '[[ $RC == 0 ]]'
show sn 25 80 4 "0000$ENTER" "$ENTER"
check "Seriennummer: falsche Eingabe wird abgelehnt" '[[ $RC == 1 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
