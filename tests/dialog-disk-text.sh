#!/usr/bin/env bash
# Dialogtest: Texte von Datenträgern im echten whiptail.
#
# Der Test zeichnet die Dialoge in ein Pseudo-Terminal (script) und prüft, was dort ankommt.
# Anlass: whiptail liest die Zeichenfolge "\n" in jedem Text als Zeilenwechsel. Ein Label auf der
# Ziel-Disk konnte so eine eigene Zeile in den Bestätigungsdialog setzen, etwa eine zweite
# Aufforderung mit einem anderen Code. Dateien von der Ziel-Disk (der Bericht im Fallordner)
# wurden ungefiltert angezeigt.
#
# Braucht whiptail, script (bsdutils) und jq. Disks werden nicht angefasst.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

for t in whiptail script jq; do
	command -v "$t" >/dev/null || { echo "Fehlt: $t. Der Dialogtest braucht whiptail, script (bsdutils) und jq."; exit 1; }
done

T=$(mktemp -d)
WAIT=${FRS_TEST_WAIT:-2} # Sekunden, bis der Dialog steht und Tasten ankommen dürfen

# Läuft im Pseudo-Terminal: echte Bibliotheken, nur die Disk ist ausgedacht. Die Partitionsliste
# der Ziel-Disk enthält ein Label, das eine zweite Aufforderung in den Dialog setzen will.
cat >"$T/innen.sh" <<'EOF'
#!/usr/bin/env bash
stty rows 25 cols 80
export TERM=linux
cd "$REPO" || exit 1
. rescue/lib/common.sh
. rescue/lib/disks.sh
. rescue/lib/safety.sh
FRS_LOG=/dev/null
UI_BACKTITLE="Firestrike Rescue Dialogtest"
disk_info() {
	echo '{"path":"/dev/sdb","size":500107862016,"model":"Testdisk","serial":"S5Y1NJ0R123456","wwn":"0x5002538f12345678","tran":"usb"}'
}
lsblk() {
	echo "NAME   SIZE FSTYPE LABEL"
	echo "sdb  465.8G"
	echo "sdb1 465G ntfs   Daten\n\nZUR BESTAETIGUNG 0000 EINGEBEN:"
}
case $SZENE in
bestaetigung)
	safety_confirm_target ZIEL "Ziel wird komplett ueberschrieben."
	echo $? >"$OUT/rc"
	;;
datei) ui_textfile "Bericht" "$OUT/report.txt" ;;
text) ui_text "Klon-Plan" 'Quelle: A\nZiel:   B' ;;
esac
EOF

# show SZENE TASTEN...   Jede Tastenfolge wird nach einer Pause gesendet. Ergebnis: RC und
# SCREEN (alles, was whiptail gezeichnet hat, ohne Steuerfolgen).
show() {
	local scene=$1 keys
	shift
	rm -f "$T/rc" "$T/mitschnitt"
	(
		for keys in "$@"; do
			sleep "$WAIT"
			printf '%b' "$keys"
		done
		sleep 1
	) | SZENE=$scene REPO=$PWD OUT=$T timeout 60 script -qec "bash '$T/innen.sh'" "$T/mitschnitt" >/dev/null 2>&1
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

echo "Bestätigungsdialog, ein Label der Ziel-Disk enthält eine zweite Aufforderung:"
show bestaetigung "$ESC"
check "die echte Aufforderung ist zu sehen" '[[ $SCREEN == *"Seriennummer eingeben"* && $SCREEN == *"(S5Y1NJ0R123456):"* ]]'
check "das Label steht als Text in der Liste, mit ? an Stelle des Backslashs" '[[ $SCREEN == *"Daten?n?nZUR BESTAETIGUNG 0000 EINGEBEN:"* ]]'
show bestaetigung "0000$ENTER" "$ENTER"
check "der Code aus dem Label bestätigt nichts" '[[ $RC == 1 ]]'
show bestaetigung "3456$ENTER"
check "die letzten 4 Zeichen der Seriennummer bestätigen" '[[ $RC == 0 ]]'

echo "Bericht aus dem Fallordner mit Steuerzeichen:"
printf 'Quelle: Testdisk\nModell: \033[2J\033[HALLES GERETTET\nZeile\\nmit Backslash\n' >"$T/report.txt"
sum=$(md5sum <"$T/report.txt")
show datei "$ENTER"
check "angezeigt wird die gefilterte Fassung" '[[ $SCREEN == *"Modell: ?[2J?[HALLES GERETTET"* && $SCREEN == *"Zeile?nmit Backslash"* ]]'
check "die Datei selbst bleibt, wie sie ist" '[[ $(md5sum <"$T/report.txt") == "$sum" ]]'

echo "Eigener Text mit Zeilenwechsel:"
show text "$ENTER"
check "\"\\n\" wird zum Zeilenwechsel, nicht zu ?n" '[[ $SCREEN == *"Quelle: A"* && $SCREEN == *"Ziel:   B"* && $SCREEN != *"?n"* && $SCREEN != *"A\\nZiel"* ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
