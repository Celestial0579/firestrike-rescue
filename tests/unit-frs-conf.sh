#!/usr/bin/env bash
# Unit-Test: Was die Vorlage der frs.conf nennt, wirkt. Und nichts darüber hinaus.
#
# Die Vorlage für /etc/frs/frs.conf nannte drei Einstellungen. Der Assistent las und prüfte sie,
# benutzte aber keine. Jetzt gilt:
#   - FRS_TARGET_FS wählt beim Formatieren einer Ziel-Disk das Dateisystem vor. Der Techniker
#     entscheidet weiter selbst und bestätigt danach wie immer.
#   - FRS_TECHNIKER steht im Rettungsbericht. Der Name geht als eigenes Argument an
#     frs-rescue-run, nie als Befehlstext, und kommt im Bericht nur als Text an.
#   - FRS_SSH_AUTOSTART gibt es nicht: Nichts auf dem Stick schaltet von selbst einen Dienst ein.
#
# Die Vorauswahl wird mit echtem whiptail in einem Pseudo-Terminal geprüft, der Bericht mit dem
# echten frs-rescue-run (lsblk, ddrescue und Co. sind Attrappen). Ohne root und ohne Disks.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

for t in whiptail script jq; do
	command -v "$t" >/dev/null || { echo "Fehlt: $t. Der Test braucht whiptail, script (bsdutils) und jq."; exit 1; }
done

T=$(mktemp -d)
WAIT=${FRS_TEST_WAIT:-2} # Sekunden, bis der Dialog steht und Tasten ankommen dürfen
FRS_RUN=$T
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/casefile.sh
# shellcheck disable=SC1091
. rescue/lib/persist.sh
# shellcheck disable=SC1091
. rescue/lib/target.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
FRS_LOG=$T/log
: >"$FRS_LOG"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/MARKE-*" >/dev/null; }

# ---------------------------------------------------------------------------
echo "Die Vorlage nennt genau die Einstellungen, die der Assistent kennt und benutzt:"
template=$(sed -n "/cat >\"\$PERSIST_CONFIG\" <<-'EOF'/,/^[[:space:]]*EOF\$/p" rescue/lib/persist.sh)
mapfile -t NAMES < <(grep -o '^[[:space:]]*#FRS_[A-Z_]*=' <<<"$template" | tr -d '#= \t' | sort -u)
known=$(declare -f persist_config_pattern | grep -o 'FRS_[A-Z_]*' | sort -u | tr '\n' ' ')
check "die Vorlage nennt Einstellungen" '((${#NAMES[@]} >= 2))'
check "es sind dieselben, die frs.conf setzen darf" '[[ "${NAMES[*]} " == "$known" ]]'
# used NAME   Benutzt eine Datei des Rettungssystems außer persist.sh die Einstellung?
used() { grep -l -- "$1" rescue/lib/*.sh rescue/bin/* rescue/frs | grep -qv '^rescue/lib/persist\.sh$'; }
for n in "${NAMES[@]}"; do
	check "$n wird benutzt, nicht nur gelesen" 'used "$n"'
done
check "FRS_SSH_AUTOSTART gibt es nicht: Nichts auf dem Stick schaltet einen Dienst ein" '! persist_config_pattern FRS_SSH_AUTOSTART >/dev/null && ! grep -rq FRS_SSH_AUTOSTART rescue/ build/ docs/ README.md'

# ---------------------------------------------------------------------------
echo "FRS_TARGET_FS wählt beim Formatieren nur vor:"
disk_resolve() { echo /dev/sdz; }
# Das Menü schreibt seine Argumente mit, je Zeile eines, und bricht ab ("Zurück").
ui_menu() {
	printf '%s\n' "$@" >"$T/menu"
	return 1
}
# preset [WERT]   Ruft target_format mit FRS_TARGET_FS=WERT auf (ohne WERT: nicht gesetzt).
# Ergebnis: PRE (Wert hinter --default-item, sonst leer), TEXT (Text des Menüs).
preset() {
	rm -f "$T/menu"
	if (($#)); then FRS_TARGET_FS=$1; else unset FRS_TARGET_FS; fi
	target_format ZIEL
	PRE=$(awk '$0 == "--" { exit } want { print; exit } $0 == "--default-item" { want = 1 }' "$T/menu" 2>/dev/null)
	TEXT=$(sed -n 2p "$T/menu" 2>/dev/null)
	unset FRS_TARGET_FS
}
preset
check "ohne Einstellung: keine Vorauswahl, kein Hinweis" '[[ -s $T/menu && -z $PRE && $TEXT != *Vorausgew* ]]'
preset exfat
check "exfat: Das Menü bekommt --default-item exfat" '[[ $PRE == exfat ]]'
check "der Text sagt, woher die Vorauswahl kommt" '[[ $TEXT == *"Vorausgewählt ist exfat (FRS_TARGET_FS in der frs.conf)"* ]]'
preset ext4
check "ext4: Das Menü bekommt --default-item ext4" '[[ $PRE == ext4 ]]'
for bad in ntfs "--title" "exfat --title x" ""; do
	preset "$bad"
	check "Wert \"$bad\" (nicht ext4 oder exfat): keine Vorauswahl, der Wert erreicht das Menü nicht" '[[ -s $T/menu && -z $PRE && $TEXT != *Vorausgew* ]]'
done

echo "Mit echtem whiptail, bis zur Bestätigung:"
cat >"$T/innen.sh" <<'EOF'
#!/usr/bin/env bash
stty rows 25 cols 80
export TERM=linux
cd "$REPO" || exit 1
FRS_RUN=$OUT
. rescue/lib/common.sh
. rescue/lib/target.sh
FRS_LOG=/dev/null
UI_BACKTITLE="Firestrike Rescue Dialogtest"
disk_resolve() { echo /dev/sdz; }
# Bis zur Bestätigung und nicht weiter: Der Test hält fest, wofür sie verlangt würde.
safety_confirm_target() {
	printf '%s' "$2" >"$OUT/aktion"
	return 1
}
unset FRS_TARGET_FS
[[ -n ${VORGABE:-} ]] && FRS_TARGET_FS=$VORGABE
target_format ZIEL
echo $? >"$OUT/rc"
EOF
# dialog TASTEN [VORGABE]   Zeigt "Ziel formatieren" mit FRS_TARGET_FS=VORGABE und sendet die
# Tasten. Ergebnis: ACTION (wofür die Bestätigung verlangt würde), SCREEN (was whiptail zeichnete).
dialog() {
	local keys=$1 k
	rm -f "$T/rc" "$T/aktion" "$T/mitschnitt"
	(
		for k in $keys; do
			sleep "$WAIT"
			printf '%b' "$k"
		done
		sleep 1
	) | REPO=$PWD OUT=$T VORGABE=${2:-} timeout 60 script -qec "bash '$T/innen.sh'" "$T/mitschnitt" >/dev/null 2>&1
	ACTION=$(cat "$T/aktion" 2>/dev/null)
	SCREEN=$(sed -E '1{/^S[ck]ript /d}; s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][0-9A-Za-z]//g' "$T/mitschnitt" 2>/dev/null | tr -d '\r\016\017')
}
ENTER='\r'
UP='\033[A'
dialog "$ENTER"
check "ohne Einstellung steht die Auswahl auf ext4" '[[ $ACTION == *"als ext4 formatiert"* && $SCREEN != *Vorausgew* ]]'
dialog "$ENTER" exfat
check "mit FRS_TARGET_FS=exfat steht sie auf exfat, und der Dialog sagt es" '[[ $ACTION == *"als exfat formatiert"* && $SCREEN == *"Vorausgewählt ist exfat"* ]]'
dialog "$UP $ENTER" exfat
check "der Techniker wählt trotzdem frei: Pfeil hoch nimmt ext4" '[[ $ACTION == *"als ext4 formatiert"* ]]'

# ---------------------------------------------------------------------------
echo "FRS_TECHNIKER geht als eigenes Argument an frs-rescue-run:"
# tmux_run schreibt mit, was gestartet würde: erst die Zahl der Argumente, dann je Zeile eines.
tmux_run() { printf '%s\n' "$#" "$@" >"$T/tmux"; }
tmux() { return 1; }
ui_msg() { :; }
mkdir -p "$T/fall"
casefile_create "$T/fall/case.env" "SRC_ID=GIBT-ES-DOCH-4711" "SRC_SIZE=500107862016" "STATE=interrupted"
# started [NAME]   Ruft recover_run mit FRS_TECHNIKER=NAME auf. Ergebnis: N (Zahl der Argumente), LAST.
started() {
	rm -f "$T/tmux"
	if (($#)); then FRS_TECHNIKER=$1; else unset FRS_TECHNIKER; fi
	recover_run "$T/fall" /dev/sdz
	N=$(sed -n 1p "$T/tmux" 2>/dev/null)
	LAST=$(tail -n 1 "$T/tmux" 2>/dev/null)
	unset FRS_TECHNIKER
}
started
check "ohne Namen: der Aufruf wie bisher" '[[ $N == 5 && $(sed -n 2,6p "$T/tmux" | tr "\n" " ") == "frs-rettung sudo frs-rescue-run $T/fall /dev/sdz " ]]'
started ""
check "leerer Name: kein Argument" '[[ $N == 5 ]]'
started "Tim Beispiel"
check "mit Namen: ein Argument mehr, der Name darin im Ganzen" '[[ $N == 6 && $LAST == "--techniker=Tim Beispiel" ]]'
EVIL="a'; touch $T/MARKE-name; echo '"
started "$EVIL"
check "ein Name mit Hochkomma und Semikolon bleibt ein Argument" '[[ $N == 6 && $LAST == "--techniker=$EVIL" ]]'

# ---------------------------------------------------------------------------
# Ganzer Durchlauf des echten Skripts ohne root und ohne Disk, wie in unit-casefile.sh.
mkdir -p "$T/attrappen"
cat >"$T/attrappen/lsblk" <<'EOF'
#!/bin/sh
echo '{"blockdevices":[{"path":"/dev/sdz","serial":"GIBT-ES-DOCH-4711","wwn":null,"size":500107862016}]}'
EOF
cat >"$T/attrappen/ddrescue" <<'EOF'
#!/bin/sh
for last; do :; done
: >>"$last"
exit 0
EOF
for tool in blockdev smartctl ddrescuelog; do printf '#!/bin/sh\nexit 0\n' >"$T/attrappen/$tool"; done
printf '#!/bin/sh\necho ext4\n' >"$T/attrappen/findmnt"
chmod +x "$T/attrappen"/*
# job NAME [ARGUMENT...]   Legt den Fall NAME an und startet das echte Skript mit den Argumenten.
# Ergebnis: RC, REPORT (Inhalt des Berichts).
job() {
	local name=$1
	shift
	mkdir -p "$T/$name"
	casefile_create "$T/$name/case.env" "SRC_ID=GIBT-ES-DOCH-4711" "SRC_SIZE=500107862016" \
		"SRC_LABEL=Testdisk (500 GB)" "STATE=new"
	PATH="$T/attrappen:$PATH" bash rescue/bin/frs-rescue-run "$T/$name" /dev/sdz --no-pause "$@" >"$T/$name.out" 2>&1 </dev/null
	RC=$?
	REPORT=$(cat "$T/$name/report.txt" 2>/dev/null)
}

echo "Der Name steht im Bericht, als Text:"
job ohne
check "ohne Namen: Bericht ohne die Zeile" '[[ $RC == 0 && $REPORT == *"Quelle:      Testdisk (500 GB)"* && $REPORT != *Techniker:* ]]'
job mit "--techniker=Tim Beispiel"
check "mit Namen: Der Bericht nennt ihn" '[[ $RC == 0 ]] && grep -qx "Techniker:   Tim Beispiel" "$T/mit/report.txt"'
job vorn
PATH="$T/attrappen:$PATH" bash rescue/bin/frs-rescue-run "--techniker=Erika Muster" "$T/vorn" /dev/sdz --no-pause >"$T/vorn.out" 2>&1 </dev/null
check "die Stelle im Aufruf ist gleich" 'grep -qx "Techniker:   Erika Muster" "$T/vorn/report.txt"'
job boese "--techniker=$EVIL"
check "Hochkomma und Semikolon stehen wörtlich im Bericht, nichts wurde ausgeführt" '[[ $RC == 0 ]] && grep -qxF "Techniker:   $EVIL" "$T/boese/report.txt" && ! markers'
job zeilen "--techniker=Zeile1"$'\n'"Quelle:      gefälscht"$'\033'"[2J"
check "Zeilenwechsel und ESC werden zu _" '[[ $RC == 0 ]] && grep -qxF "Techniker:   Zeile1_Quelle:      gefälscht_[2J" "$T/zeilen/report.txt"'
check "der Name erzeugt keine zweite Zeile \"Quelle:\"" '[[ $(grep -c "^Quelle:" "$T/zeilen/report.txt") == 1 ]]'
check "kein Steuerzeichen im Bericht" '! LC_ALL=C grep -q "[[:cntrl:]]" "$T/zeilen/report.txt"'
job ersetzung "--techniker=\$(touch $T/MARKE-e) \`touch $T/MARKE-b\` \"x\" \\"
check "die Zeichen \" \$ \` \\ werden zu _, nichts wurde ausgeführt" '[[ $RC == 0 ]] && grep -qxF "Techniker:   _(touch $T/MARKE-e) _touch $T/MARKE-b_ _x_ _" "$T/ersetzung/report.txt" && ! markers'
job lang "--techniker=$(printf 'x%.0s' {1..300})"
check "mehr als 100 Zeichen werden gekürzt" 'grep -qxE "Techniker:   x{100}" "$T/lang/report.txt"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
