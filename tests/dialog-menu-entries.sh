#!/usr/bin/env bash
# Dialogtest für Menüs: Einträge, die wie Optionen aussehen, bleiben Einträge.
#
# Der Test zeichnet ui_menu mit echtem whiptail in ein Pseudo-Terminal (script) und prüft, was
# dort ankommt und was die Auswahl liefert. Anlass: Menüeinträge stammen oft von Datenträgern
# (Ordnernamen unter FRS/, Seriennummern). Ein Eintrag "--title" verschwand aus der Liste und
# ersetzte den Titel des Dialogs durch seine Beschreibung, bei "--yesno" kam statt des Menüs
# der Hilfetext von whiptail und die Auswahl war nicht mehr möglich.
#
# Braucht whiptail und script (bsdutils). Disks werden nicht angefasst.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

for t in whiptail script; do
	command -v "$t" >/dev/null || { echo "Fehlt: $t. Der Dialogtest braucht whiptail und script (bsdutils)."; exit 1; }
done

T=$(mktemp -d)
WAIT=${FRS_TEST_WAIT:-2} # Sekunden, bis der Dialog steht und Tasten ankommen dürfen

# Läuft im Pseudo-Terminal: die echte Bibliothek, die Argumente für ui_menu stehen zeilenweise
# in einer Datei.
cat >"$T/innen.sh" <<'EOF'
#!/usr/bin/env bash
stty rows 25 cols 80
export TERM=linux
cd "$REPO" || exit 1
. rescue/lib/common.sh
FRS_LOG=/dev/null
UI_BACKTITLE="Firestrike Rescue Dialogtest"
mapfile -t ARGS <"$OUT/args"
sel=$(ui_menu "${ARGS[@]}")
echo $? >"$OUT/rc"
printf '%s' "$sel" >"$OUT/sel"
EOF

# menu TASTEN ARGUMENT...   Zeigt ui_menu ARGUMENT... und sendet die Tasten (durch Leerzeichen
# getrennte Folgen, jede nach einer Pause). Ergebnis: RC, SEL (Auswahl) und SCREEN (alles, was
# whiptail gezeichnet hat, ohne Steuerfolgen).
menu() {
	local keys=$1 k
	shift
	rm -f "$T/rc" "$T/sel" "$T/mitschnitt"
	printf '%s\n' "$@" >"$T/args"
	(
		for k in $keys; do
			sleep "$WAIT"
			printf '%b' "$k"
		done
		sleep 1
	) | REPO=$PWD OUT=$T timeout 60 script -qec "bash '$T/innen.sh'" "$T/mitschnitt" >/dev/null 2>&1
	RC=$(cat "$T/rc" 2>/dev/null || echo "kein Ergebnis")
	SEL=$(cat "$T/sel" 2>/dev/null)
	# Die erste Zeile stammt von script selbst, danach folgt, was whiptail an das Terminal schickt.
	SCREEN=$(sed -E '1{/^S[ck]ript /d}; s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][0-9A-Za-z]//g' "$T/mitschnitt" 2>/dev/null | tr -d '\r\016\017')
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

ESC='\033'
ENTER='\r'
DOWN='\033[B'
FALL="20261112-0900_WDC_X"

echo "Eintrag \"--title\":"
menu "$ENTER" "Fortsetzen" "Welcher Rettungsfall?" -- "--title" "[new]" "$FALL" "[interrupted]"
check "der Eintrag steht im Menü" '[[ $SCREEN == *"--title"* && $SCREEN == *"[new]"* ]]'
check "der Titel des Dialogs bleibt" '[[ $SCREEN == *"Fortsetzen"* ]]'
check "die Auswahl liefert genau den Eintrag" '[[ $RC == 0 && $SEL == "--title" ]]'

echo "Eintrag \"--yesno\":"
menu "$ENTER" "Fortsetzen" "Welcher Rettungsfall?" -- "--yesno" "[new]" "$FALL" "[interrupted]"
check "das Menü erscheint, kein Hilfetext" '[[ $SCREEN == *"Welcher Rettungsfall?"* && $SCREEN == *"$FALL"* && $SCREEN != *"Box options"* ]]'
check "die Auswahl liefert genau den Eintrag" '[[ $RC == 0 && $SEL == "--yesno" ]]'
menu "$DOWN $ENTER" "Fortsetzen" "Welcher Rettungsfall?" -- "--yesno" "[new]" "$FALL" "[interrupted]"
check "der Eintrag darunter bleibt wählbar" '[[ $RC == 0 && $SEL == "$FALL" ]]'

echo "Weitere Einträge mit Bindestrich am Anfang:"
for tag in "-x" "--output-fd=1" "--menu" "--"; do
	menu "$ENTER" "Fortsetzen" "Welcher Rettungsfall?" -- "$tag" "[new]" "$FALL" "[interrupted]"
	check "\"$tag\" wird angezeigt und geliefert" '[[ $RC == 0 && $SEL == "$tag" && $SCREEN == *"$FALL"* ]]'
done

echo "Text mit Bindestrich am Anfang:"
menu "$ENTER" "SMART" "--msgbox ist hier nur Text" -- a "Eintrag A" b "Eintrag B"
check "der Text wird angezeigt, das Menü bleibt ein Menü" '[[ $SCREEN == *"--msgbox ist hier nur Text"* && $SCREEN == *"Eintrag B"* && $RC == 0 && $SEL == a ]]'

echo "Was vorher ging, geht weiter:"
menu "$ENTER" "Firestrike Rescue" "Empfehlung" --default-item b -- a "Eintrag A" b "Eintrag B"
check "Optionen vor den Einträgen gelten (--default-item)" '[[ $RC == 0 && $SEL == b ]]'
menu "$ESC" "Fortsetzen" "Welcher Rettungsfall?" -- "--title" "[new]" "$FALL" "[interrupted]"
check "Abbrechen liefert nichts" '[[ $RC != 0 && -z $SEL ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
